# Escenarios de la demo: qué está sembrado y qué debería encontrar el agente

Hay dos formas de hacer la demo: como una [conversación](#conversaciones) que empieza en general y
baja al detalle (o al revés), o escenario a escenario. Para cada escenario: el problema construido en
el workspace, dónde está, un prompt para el agente y los hallazgos esperados. Los escenarios son
también la plantilla de respuestas de los turnos de las conversaciones. Los números de ejecución
suponen el valor por defecto `-SimulatedDays 10`; usa `-SimulatedDays 15` o más si el escenario 1
necesita una tendencia más clara (cada ejecución tarda 15-20 minutos).

Los prompts piden la evidencia que destapa cada problema sin nombrar la causa. Los detalles de las
ejecuciones de Spark (stages, tareas) solo se conservan unas horas, así que lanza los escenarios de
Spark poco después de la fase History.

## Antes de ejecutar el agente

Los problemas sembrados no están comentados en el código de los items, así que el agente tiene que
encontrarlos a partir de la evidencia. Este fichero y `demo-setup/` los delatarían. Mientras el agente
analiza, saca `demo-setup/` del repositorio o, en Claude Code, deniega al agente el acceso en
`.claude/settings.local.json`:

```json
{ "permissions": { "deny": ["Read(demo-setup/**)", "Grep(demo-setup/**)", "Glob(demo-setup/**)"] } }
```

Ese fichero solo sirve para Claude Code. Con GitHub Copilot, saca `demo-setup/` del repositorio.

## Conversaciones

Una conversación es una cadena de repreguntas cortas, cada una reaccionando a lo que el agente acaba
de responder. Muestra cómo el agente pasa de un área a otra en lugar de responder a un único prompt largo.

- **El turno 1** pide el análisis a la sesión principal, que lo delega en `FabricPerfAnalyst`.
- **Los turnos siguientes** se escriben en el mismo chat. La sesión principal continúa con el mismo agente
  (`SendMessage` en Claude Code, `write_agent` en GitHub Copilot) o, si ya no está disponible, arranca uno
  nuevo indicando el informe previo. El agente reutiliza el alcance y los hallazgos de ese informe y solo
  recoge la evidencia que le falta.
- **Cada turno deja su propio informe** en `informes/AAAA-MM-DD/` con el siguiente `<nn>`, citando el
  anterior en Alcance.

Los prompts de abajo suponen que el agente encontró lo que espera el escenario. Si respondió otra cosa,
adapta la repregunta a su respuesta, pero no nombres la causa sembrada: pide la evidencia. Lanza la
conversación de Spark poco después de la fase History, porque los detalles de las ejecuciones de Spark
caducan a las pocas horas.

### Conversación A: del pipeline al detalle

Empieza con un síntoma general y baja a la configuración de Spark, el skew, el tamaño del clúster y las tablas.

| Turno | Prompt | Escenario | Qué debería aportar el agente |
|-------|--------|-----------|-------------------------------|
| 1 | El pipeline `pl_daily_sales` del workspace FabricPerfLab tarda cada día más. ¿Qué es lo que crece entre ejecuciones? | [1](#1-pipeline-cada-vez-más-lento) | Tendencia por actividad y notebook; "Bronze to silver" y su shuffle crecen, la ingesta se mantiene plana; recarga completa en silver |
| 2 | Dices que el paso de Bronze to silver es el que más crece y que además hay joins con shuffle. ¿Hay data skew o time skew? ¿Qué stages pesan más y qué estrategia usa cada join? | [3](#3-data-skew-time-skew-y-shuffle-pesado) | Tarea máxima frente a mediana por stage, sort-merge joins, 2000 tareas casi vacías, stages repetidos, UDF de Python |
| 3 | Si está desactivado el broadcast y AQE, creo que la configuración no es correcta. Revísala para las tres capas: bronze, silver y gold. | [4](#4-configuración-de-spark-por-capa-medallion) | Tabla de declarado frente a notebook frente a efectivo por capa; sobrescrituras en el notebook; V-Order y resource profiles |
| 4 | Gold usa otro pool. ¿Ese clúster está bien dimensionado para lo que hace `nb_03_silver_to_gold`? | [2](#2-clúster-de-spark-sobredimensionado) | Cores ociosos con ejecutores Large fijos; starter pool o nodos Medium con asignación dinámica; extra: `nb_04` |
| 5 | Me has comentado de compactar customer, antes de hacerlo me gustaría analizar todo. ¿Qué tablas de los tres lakehouses necesitan mantenimiento? | [6](#6-tablas-delta-que-necesitan-mantenimiento) | Veredicto por tabla, `dim_date` sin tocar, VACUUM programado en lugar de ejecutarlo ahora |
| 6 | También he visto que el pipeline a veces falla, ¿puedes revisar las ejecuciones fallidas y el motivo? | [5](#5-fallos-de-spark-y-oom) | Schema drift en la ejecución 6, tipos de OOM en `pl_store_snapshot`, coste del reintento |

### Conversación B: de una medida lenta a todo el flujo

Empieza con una medida concreta y se amplía al modelo, sus refrescos y el pipeline que lo alimenta.

| Turno | Prompt | Escenario | Qué debería aportar el agente |
|-------|--------|-----------|-------------------------------|
| 1 | La tarjeta de "Avg Ticket" del informe `rpt_sales` tarda mucho en cargar. | [8](#8-rendimiento-dax) (solo Q1) | Encuentra el informe y reconstruye la consulta de la tarjeta (Q1); `Avg Ticket` es la medida lenta, reescritura en `DEFINE` con el mismo resultado; los demás KPI están bien |
| 2 | Sabiendo que esa medida está mal, quiero que revises el resto de la página. | [8](#8-rendimiento-dax) | Reconstruye Q2-Q5 a partir de los demás visuales; medidas lentas con sus reescrituras; `Enterprise Sales` y `Active Customers` medidas y sin tocar |
| 3 | Varias medidas filtran sobre `fact_sales` en lugar de una tabla de fechas. ¿El modelo `sm_sales` cumple las buenas prácticas de modelado? | [7](#7-buenas-prácticas-del-modelo-semántico) | Relaciones, tipos de datos, columnas calculadas, tabla de fechas, ubicación de las medidas; clientes en blanco rastreados hasta los borrados RGPD |
| 4 | Dame el tamaño en memoria del modelo, de cada tabla y de cada columna |  |  |
| 5 | Los usuarios dicen que a veces ven los datos de ayer o el informe da error. ¿Se refresca bien el modelo? | [9](#9-refrescos-del-modelo-semántico) | Fallos intermitentes por `category`, refresco no esperado en `nb_04`, programación desalineada con el pipeline |
| 6 | Si el refresco depende de `pl_daily_sales`, ¿cómo va ese pipeline y está bien configurada la capa gold que lee el modelo? | [1](#1-pipeline-cada-vez-más-lento), [4](#4-configuración-de-spark-por-capa-medallion) | Pipeline que crece y sobrescritura completa de gold; V-Order y resource profile de gold, y qué cambia si el modelo pasa a Direct Lake |

En una charla suelen bastar tres o cuatro turnos de una conversación; cada turno de Spark tarda
varios minutos.

## Resumen

| # | Escenario | Item principal | Fichero de área del agente |
|---|-----------|----------------|----------------------------|
| 1 | Pipeline cada vez más lento | `pl_daily_sales` | spark-runs |
| 2 | Clúster de Spark sobredimensionado | `env_gold`, `pool_gold_xl` | spark-resources |
| 3 | Data skew, time skew, shuffle pesado | `nb_02_bronze_to_silver` | spark-runs |
| 4 | Configuración de Spark por capa medallion | `env_bronze`, `env_silver`, `env_gold` | spark-resources |
| 5 | Fallos de Spark y OOM | `pl_daily_sales` ejecución 6, `pl_store_snapshot` | spark-runs |
| 6 | Tablas Delta que necesitan mantenimiento | `lh_bronze`, `lh_silver`, `lh_gold` | delta-tables |
| 7 | Buenas prácticas del modelo | `sm_sales` | semantic-models |
| 8 | Rendimiento DAX | medidas de `sm_sales`, visuales de `rpt_sales` (`dax/report-queries.dax`) | semantic-models |
| 9 | Refrescos del modelo | historial de refrescos de `sm_sales` | semantic-models |

---

## 1. Pipeline cada vez más lento

> El pipeline `pl_daily_sales` del workspace FabricPerfLab tarda cada día más.
> No me vale un umbral de regresión: quiero la tendencia de cada actividad y de
> cada notebook entre ejecuciones, incluido el shuffle y el número de jobs de Spark. Revisa cómo lee
> y escribe cada notebook (carga completa o incremental) y cómo evolucionan las tablas que toca
> (ficheros, commits y checkpoints del `_delta_log`). ¿Qué crece y por qué?

| Causa sembrada | Dónde | Evidencia que puede usar el agente |
|----------------|-------|------------------------------------|
| Silver reconstruye todo el historial de bronze en cada ejecución (`sales_raw` se lee entero, se deduplica y se sobrescribe) | `nb_02` | La duración de la actividad "Bronze to silver" crece con cada ejecución mientras "Ingest bronze" se mantiene plana |
| 400 ficheros pequeños añadidos a `sales_raw` por ejecución, nunca compactados | `nb_01` (`WRITE_PARTITIONS`, optimize write desactivado en el notebook porque el perfil `readHeavyForPBI` de `env_bronze` lo activaría) | Número de ficheros y tamaño medio de fichero de `sales_raw` |
| 30 commits diminutos por ejecución en `inventory_events` con `delta.checkpointInterval = 1000` | `nb_01` | `_delta_log` largo sin checkpoint; lecturas más lentas de la tabla en `nb_02` |
| `count()` llamado dos veces sobre DataFrames sin caché, así que la ventana de deduplicación se vuelve a ejecutar antes de la escritura | `nb_02` | Jobs repetidos sobre la misma entrada en la aplicación de Spark |
| Gold sobrescribe `fact_sales` entera y el modelo hace un refresco completo | `nb_03`, `nb_04` | La duración de la actividad de gold y del refresco crece con el total de filas |

Recomendación esperada: carga incremental (MERGE del nuevo día de negocio), compactación, restaurar el
intervalo de checkpoint, cachear o eliminar las acciones de más.

Con pocas ejecuciones la duración total crece despacio y queda muy por debajo del umbral habitual de
regresión de 2x; el shuffle de `nb_02` (pasó de unos 450 MB a 3,7 GB en 9 ejecuciones) y el número de
ficheros muestran la tendencia con más claridad que las duraciones.

## 2. Clúster de Spark sobredimensionado

> ¿Está sobredimensionado el clúster de Spark que usa la capa gold (`env_gold`, pool
> `pool_gold_xl`)? Compara el tamaño de nodo, la asignación dinámica y los ejecutores con el uso
> real de cores de las últimas sesiones de `nb_03_silver_to_gold`, contrástalo con `env_bronze` y
> `env_silver`, y propón el tamaño adecuado.

- `env_gold` corre en `pool_gold_xl` (nodos Large por defecto) con la **asignación dinámica desactivada** y un
  número fijo de ejecutores (máx. nodos − 1), cada uno con 16 cores y 112 GB.
- `nb_03` lee unos pocos millones de filas y después escribe varias tablas pequeñas una tras otra, así que
  la mayoría de los cores de los ejecutores están ociosos.
- Esperado: baja eficiencia de cores / tiempo ocioso de ejecutores; recomendar el starter pool o nodos Medium
  con asignación dinámica. Contrastar con `env_bronze` y `env_silver`, que usan el starter pool.
- Extra que puede encontrar el agente: `nb_04` abre una sesión de Spark solo para llamar a la API de refresco,
  así que sus cores están ociosos; la actividad nativa de refresco de modelo semántico lo evitaría.

## 3. Data skew, time skew y shuffle pesado

> ¿Hay data skew o time skew en `nb_02_bronze_to_silver`? ¿Qué stages tienen el shuffle más pesado?
> Para cada join indica la estrategia del plan (broadcast o sort-merge) y compárala con la
> configuración Spark efectiva de la sesión. Por stage: registros y bytes de la tarea máxima frente
> a la mediana, spill, número de tareas y stages que se repiten en varios jobs.

| Caso | Sembrado en `nb_02` | Qué muestran las métricas de Spark |
|------|---------------------|------------------------------------|
| **Data skew** | El 60 % de las ventas pertenece a `store_id = 1` ("Flagship Madrid"). El join con `stores` es un sort-merge join porque el broadcast está desactivado y AQE (con skew join) está apagado en `env_silver` y otra vez en el notebook. | Una tarea del stage del join lee muchos más registros y bytes que la mediana |
| **Time skew sin data skew** | `repartitionByRange(64, "sale_ts")` agrupa las ventas de la noche; la UDF de Python `classify_note` solo hace trabajo pesado para las horas ≥ 22. | Tareas con número de registros parecido pero duraciones muy distintas |
| **Shuffle pesado** | Ventana de deduplicación `partitionBy("sale_id")` sobre todo el historial, y el join con `customers` (200k filas) sin broadcast. | Shuffle write/read grande en esos stages, creciendo en cada ejecución |
| **Spill** | La partición sesgada del join concentra alrededor del 60 % de las filas en una tarea. | Spill a memoria y disco en esa tarea, si la partición supera la memoria de ejecución (depende del volumen) |
| **Demasiadas tareas pequeñas** | `spark.sql.shuffle.partitions = 2000` (environment y notebook) para un join sobre 50 claves de tienda. | Miles de tareas casi vacías; sobrecoste del scheduler |
| **Recálculo** | Dos acciones `count()` antes de la escritura, sin caché. | Los mismos stages aparecen en varios jobs |
| **Sobrecoste de UDF de Python** | `classify_note` es una UDF de Python fila a fila. | `BatchEvalPython` en el plan; tiempo en los workers de Python |

Otros casos habituales, no sembrados: joins que explotan (claves duplicadas en ambos lados), `collect()`
de resultados grandes al driver, skew en agregaciones `groupBy`, broadcast de una tabla demasiado grande,
y pérdida de partition pruning por una función sobre la columna de partición.

## 4. Configuración de Spark por capa medallion

> ¿La configuración de Spark de cada capa de la arquitectura medallion es correcta? Para bronze,
> silver y gold, haz una tabla con lo declarado en el environment, lo que sobrescribe el notebook con
> `spark.conf.set` y lo efectivo, frente a lo que necesita la capa según su carga. Gold la consume
> `sm_sales`; ten en cuenta que podría pasar a Direct Lake.

| Capa | Sembrado (environment + notebook) | Esperado para esa capa |
|------|-----------------------------------|------------------------|
| Bronze (carga de escritura) | `resourceProfile = readHeavyForPBI`, V-Order **activado**, optimize write desactivado, auto compact desactivado; el notebook vuelve a desactivar optimize write | `writeHeavy`, V-Order desactivado, optimize write / auto compact activados |
| Silver (equilibrada) | AQE desactivado, skew join desactivado, broadcast deshabilitado (`-1`), 2000 particiones de shuffle; el notebook vuelve a fijar las cuatro | AQE y skew join activados, umbral de broadcast por defecto, particiones dimensionadas según los datos |
| Gold (carga de lectura para Power BI) | `resourceProfile = writeHeavy`, V-Order **desactivado**, optimize write desactivado; el notebook desactiva AQE | `readHeavyForPBI` o V-Order + optimize write activados, AQE activado. También válido: V-Order desactivado mientras `sm_sales` siga en modo Import y activado en cuanto pase a Direct Lake (Learn recomienda V-Order solo para consumidores Direct Lake) |
| Todas | Native execution engine desactivado | Valorar activarlo |

El agente debería señalar las sobrescrituras con `spark.conf.set` a nivel de notebook (prevalecen sobre
el environment) y la discrepancia de la clave de V-Order que figura en las trampas de
`fabric-perf-analysis`. Un resource profile también fija propiedades (`readHeavyForPBI` activa optimize
write), así que el agente debería comparar los valores declarados con los efectivos en lugar de fiarse
solo del environment.

## 5. Fallos de Spark y OOM

> ¿Qué ejecuciones de Spark han fallado en FabricPerfLab y por qué? ¿Alguna por memoria? Revisa
> todos los pipelines, cuenta los reintentos y lo que cuestan, distingue el OOM de driver, el de
> ejecutor y los límites internos de Spark, e indica qué datos faltan aguas abajo por cada fallo.

| Fallo | Cuándo | Causa |
|-------|--------|-------|
| `pl_daily_sales` falla en "Ingest bronze" | Ejecución 6 (cada `schema_drift_every` = 6 ejecuciones) | El origen envía `amount` como texto; el append Delta falla por un desajuste de esquema (double frente a string). Ese día de negocio falta aguas abajo. |
| `pl_store_snapshot`, `export_format = nested` | Fase History, después de las ejecuciones diarias | `collect_list` de documentos JSON por tienda: la tienda caliente genera una única fila enorme, así que el ejecutor se queda sin memoria o supera el límite de 2 GB por fila de Spark. La actividad reintenta una vez, así que el coste se paga dos veces. |
| `pl_store_snapshot`, `export_format = pairs` | Fase History, después de las ejecuciones diarias | `toPandas()` de la tabla de ventas y después un self-merge de pandas por `store_id`: `MemoryError` en el driver. |

El fallo "nested" depende del volumen de datos (la tienda caliente necesita unos pocos millones de filas,
que con los valores por defecto se alcanzan hacia el día 8). Si terminó bien, consulta la tabla de
solución de problemas del README.

## 6. Tablas Delta que necesitan mantenimiento

> ¿Qué tablas Delta de `lh_bronze`, `lh_silver` y `lh_gold` necesitan mantenimiento y qué operación
> propones? Dame un veredicto por tabla, también para las que no necesitan nada: ficheros pequeños,
> checkpoints, deletion vectors, ficheros sin referenciar con su retención y V-Order según quién lee
> cada capa.

| Tabla | Problema | Propuesta esperada |
|-------|----------|--------------------|
| `lh_bronze.sales_raw` | Unos 400 ficheros pequeños por ejecución, nunca optimizados | `OPTIMIZE` (decidir sobre V-Order en bronze) |
| `lh_bronze.inventory_events` | 30 commits por ejecución, sin checkpoint (`checkpointInterval = 1000`), ficheros diminutos | Restaurar el intervalo de checkpoint, `OPTIMIZE` |
| `lh_silver.customers` | Deletion vectors con actualizaciones diarias y borrados RGPD: se acumulan filas borradas lógicamente | `OPTIMIZE` / `REORG TABLE ... APPLY (PURGE)` y después `VACUUM` |
| `lh_silver.sales`, `lh_gold.fact_sales` | Se sobrescriben enteras en cada ejecución, los ficheros antiguos nunca se limpian con VACUUM | `VACUUM` con una retención que respete las necesidades de time travel |
| `lh_gold.*` | Escritas con V-Order desactivado, las lee el modelo semántico | `OPTIMIZE ... VORDER` |
| `lh_gold.dim_date` | Tabla de control sana, escrita una vez | Ninguna acción: comprueba que el agente no recomienda de más |
| `lh_gold.daily_store_sales` | No sembrado a propósito: muchos ficheros diminutos por ejecución por la escritura de gold | Corregir la escritura (menos particiones) u `OPTIMIZE`; un hallazgo extra válido |

`VACUUM` no puede liberar nada hasta que los ficheros superen la retención por defecto de 7 días, así
que en una instalación recién hecha la respuesta esperada es programarlo, no ejecutarlo ahora.

## 7. Buenas prácticas del modelo semántico

> Revisa si el modelo semántico `sm_sales` cumple las buenas prácticas de modelado. Usa la
> definición completa del modelo y no solo INFO.VIEW: tipos de datos exactos (también los de las
> claves de relación), cardinalidad comprobada con los datos, columnas calculadas en tablas de
> hechos, anotaciones del modelo, tabla de fechas y en qué tabla viven las medidas. Si ves problemas
> de integridad, rastrea su origen en el lakehouse.

- Relación bidireccional `fact_sales` ↔ `dim_customer`.
- Relación muchos a muchos y bidireccional `promotions` ↔ `dim_product` aunque `product_code` es
  único en `dim_product`.
- Relación sobre una clave de texto (`product_code`).
- Columnas de alta cardinalidad cargadas pero innecesarias para el análisis: `sale_id` (GUID), `sale_ts`
  (datetime al segundo), `email`.
- Columnas calculadas en la tabla de hechos (`line_margin`, `year_month`) en lugar de calcularlas aguas arriba.
- `double` para columnas de importes en lugar de decimal fijo.
- Columnas clave visibles y resumidas con `sum` (`store_id`, `customer_id`).
- `dim_date` existe pero no está marcada como tabla de fechas; la inteligencia de tiempo usa `fact_sales[sale_date]`.
- Anotación de fecha/hora automática activada; las medidas implícitas no están desaconsejadas.
- Medidas sin format string ni descripción, y todas en la tabla de hechos.
- `IFERROR` en lugar de `DIVIDE`; `FILTER` sobre toda la tabla de hechos dentro de `CALCULATE`.
- Efecto colateral, no sembrado a propósito: los borrados RGPD en `silver.customers` dejan ventas cuyo
  `customer_id` ya no existe en `dim_customer` (alrededor del 14 % de `fact_sales`), así que los totales
  por cliente caen en blanco. Un hallazgo válido si el agente lo rastrea hasta los borrados.

## 8. Rendimiento DAX

> La página "Sales overview" del informe `rpt_sales` (workspace FabricPerfLab) va lenta. Analiza
> el rendimiento de las medidas de `sm_sales` que usan sus visuales. Mide la consulta de cada
> visual y cada medida aislada, con trazas si están disponibles, y para las lentas prueba la
> reescritura en `DEFINE` comprobando que da el mismo resultado. Indica también qué medidas no
> hace falta tocar.

El agente lee los visuales de `rpt_sales` (desplegado por `setup.ps1`, o por separado con
`-Phase Report`) y reconstruye una consulta por visual; deberían coincidir con estas, de
[`dax/report-queries.dax`](dax/report-queries.dax). Q1 es la tarjeta de varios valores, Q2 la matriz,
Q3 el gráfico de líneas, Q4 el gráfico de barras y Q5 la tabla.

```DAX
// Q1 - KPI cards
EVALUATE
ROW(
    "Total Sales", [Total Sales],
    "Margin %", [Margin %],
    "Avg Ticket", [Avg Ticket],
    "Active Customers", [Active Customers]
)

// Q2 - Sales by store and month
EVALUATE
SUMMARIZECOLUMNS(
    dim_store[store_name],
    fact_sales[year_month],
    "Total Sales", [Total Sales],
    "Enterprise Sales", [Enterprise Sales],
    "Margin %", [Margin %]
)

// Q3 - Daily trend with running total
EVALUATE
SUMMARIZECOLUMNS(
    fact_sales[sale_date],
    "Total Sales", [Total Sales],
    "Sales Running Total", [Sales Running Total]
)

// Q4 - Top customers by city
EVALUATE
SUMMARIZECOLUMNS(
    dim_store[city],
    "Top 100 Customers Sales", [Top 100 Customers Sales]
)

// Q5 - Category performance with promotions
EVALUATE
SUMMARIZECOLUMNS(
    dim_product[category],
    promotions[promo_name],
    "Total Sales", [Total Sales],
    "Sales LY", [Sales LY]
)
```

Si el informe no está desplegado, pega estas consultas en su lugar (están en la carpeta oculta).
Las trazas necesitan el servidor local `powerbi-modeling-mcp` con su EULA aceptado; acéptalo antes, o el
agente solo podrá cronometrar las consultas sin el desglose FE/SE.

| Medida | Por qué es lenta | Mejor patrón |
|--------|------------------|--------------|
| `Avg Ticket` | `AVERAGEX` sobre todas las filas de hechos con `CALCULATE` dentro: transición de contexto por fila en una tabla sin clave | `DIVIDE([Total Sales], COUNTROWS(fact_sales))` |
| `Sales Running Total` | `FILTER(ALL(fact_sales))` sobre la columna datetime, evaluado para cada punto | Filtrar `dim_date[date]` en lugar de la tabla de hechos |
| `Top 100 Customers Sales` | `RANKX` dentro de `SUMX` sobre 200k clientes: trabajo cuadrático | `TOPN` una vez y después `SUMX` sobre esa tabla |
| `Enterprise Sales` | `FILTER(fact_sales, RELATED(...))` itera la tabla de hechos | `CALCULATE([Total Sales], dim_customer[segment] = "Enterprise")` |
| `Active Customers` | `FILTER` + `CALCULATE` por cliente | `DISTINCTCOUNT(fact_sales[customer_id])` |
| `Margin %` | `IFERROR` | `DIVIDE` |
| `Total Sales`, `Total Quantity` | Sumas simples | Medidas de control: no se espera ningún cambio |

Con 10 días simulados (unos 9 M de filas) `Avg Ticket`, `Sales Running Total` y `Top 100 Customers
Sales` tardan segundos, mientras que `Enterprise Sales` y `Active Customers` se quedan por debajo de
150 ms: el motor resuelve bien esos patrones con este volumen. Si el agente los mide y los deja como
están, es la respuesta correcta: demuestra que no recomienda de más. El mejor patrón sigue siendo
válido por legibilidad y para volúmenes mayores.

## 9. Refrescos del modelo semántico

> ¿El modelo `sm_sales` se refresca correctamente? Cruza el historial de refrescos (incluidos los
> fallidos y su mensaje de error), la programación del modelo y las horas de inicio y fin de
> `pl_daily_sales`, y revisa cómo lanza y vigila el refresco `nb_04`. ¿Cuánto tarda cada refresco,
> por qué falla y está alineado con el pipeline?

| Sembrado | Dónde | Hallazgo esperado |
|----------|-------|-------------------|
| En las ejecuciones 4 y 8 la capa gold renombra `dim_product.category` a `product_category`; la siguiente ejecución lo restaura | `nb_03` (`product_schema_v2_every = 4`) | Fallos intermitentes de refresco: no se encuentra la columna `category` |
| El refresco se solicita sin esperar a que termine, y los errores solo se imprimen | `nb_04` | El pipeline sale en verde mientras el refresco falla: nadie recibe aviso |
| Refresco programado a las 05:30, antes del pipeline de las 06:00 | Programación de refresco | Ese refresco carga los datos del día anterior |
| Refresco programado a las 06:30, con el pipeline aún en marcha, más el refresco que solicita `nb_04` al final | Programación de refresco, `nb_04` | Refrescos solapados o redundantes; datos cargados a mitad del pipeline |
| Refresco completo de una tabla de hechos que crece cada día | Modelo, `nb_03` | La duración del refresco crece con el pipeline |
| Sin sincronización de metadatos del SQL endpoint después de las escrituras de gold | `nb_04` | Posible: el refresco lee el SQL endpoint antes de que vea la nueva versión Delta |

Las filas de la programación solo aparecen después de que la fase Schedule haya funcionado al menos un día real.
