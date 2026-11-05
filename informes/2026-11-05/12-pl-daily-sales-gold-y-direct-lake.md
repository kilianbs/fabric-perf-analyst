# pl_daily_sales y la capa gold que lee sm_sales: salud, configuración y paso a Direct Lake

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-05 |
| **Áreas** | Spark runs (pipeline) → Spark resources (environment de gold) → Delta tables (escritura de gold) → Semantic models (Direct Lake) |
| **Ámbito** | workspace `FabricPerfLab` · pipeline `pl_daily_sales` · `env_gold`, `nb_03`, `nb_04` · tablas de `lh_gold` · modelo `sm_sales` |
| **Ventana analizada** | 2026-10-30 17:11 → 2026-11-05 10:56 UTC |
| **Agente / host** | Claude Code · skills: spark-cli, semantic-model-authoring, fabric-perf-analysis |
| **Modo** | Lectura + diagnóstico activo (Livy) |
| **Severidad global** | Media |
| **Confianza global** | Alta (estado actual) / Media (valoraciones de Direct Lake) |

## Resumen

- **Pregunta:** si el refresco de `sm_sales` depende de `pl_daily_sales`, cómo va ese pipeline y si la capa gold que lee el modelo está bien configurada; y qué cambiaría con Direct Lake.
- **Conclusión:** el pipeline completa 14 de 16 ejecuciones y tarda 1.839 s la última programada, un 17 % más que la del 31-oct (1.572 s). La actividad más lenta es `Bronze to silver` (881 s, 48 %). Las dos ejecuciones fallidas son deterministas (ingesta, runs 6 y 12) y el pipeline no vigila el refresco del modelo (informe 11). Gold se escribe con perfil `writeHeavy`, sin V-Order, sin `OPTIMIZE`/`VACUUM`, con reescritura completa diaria (`CREATE OR REPLACE`), y `dim_customer` tiene 880 ficheros de mediana 6,3 KB. No es una configuración pensada para su consumidor.
- **Direct Lake:** es viable en volumen (15 M filas frente a un límite de 1.500 M) pero hoy no es adoptable tal cual: faltan V-Order, row groups mayores de 1 M de filas y columnas calculadas pasadas a la tabla, y el renombrado de `category` rompería el marco del modelo igual que rompe el refresco. Lo que sí desaparece es la copia completa de datos (8-11 min por refresco) y, con Direct Lake on OneLake, la dependencia del retardo del SQL endpoint.
- **Primera acción:** R1, estabilizar el contrato de gold (sin renombrado de `category` ni cambio de tipo de `amount`) y R2, dejar los escritores de gold listos para consumo (V-Order o `readHeavyForPBI`, `OPTIMIZE` de `dim_customer`, `autoCompact`). Requieren confirmación; no se aplicó nada.

## Alcance

**Pregunta original:** "si el refresco del modelo depende de pl_daily_sales, ¿cómo va ese pipeline y está bien configurada la capa gold que lee el modelo? ... (1) salud del pipeline ...; (2) environment de los notebooks/Spark de la capa gold ...; (3) escritura de gold ...; (4) qué cambiaría si sm_sales pasa a Direct Lake ... Distingue evidencia medida de inferencia."

**Informes previos reutilizados** (todos de 2026-11-05): `01-pl-daily-sales-tendencia-crecimiento.md`, `03-config-spark-capas-y-direct-lake.md`, `04-dimensionamiento-sesiones-spark-pipeline.md`, `05-mantenimiento-tablas-delta.md`, `06-fallos-pipelines-y-coste-reintentos.md`, `09-sm-sales-buenas-practicas-modelado.md`, `10-sm-sales-memoria-modelo.md`, `11-sm-sales-refrescos-datos-ayer.md`. Sus cifras siguen vigentes (se verificaron las de configuración y layout; ver Evidencia).

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Historial de ejecuciones y actividades de `pl_daily_sales`; `env_gold`, pools y ajustes del workspace; propiedades y layout de las tablas de gold; requisitos y efectos de Direct Lake en `sm_sales` | `nb_01` y `nb_02` (informes 01, 02, 03 y 06); coste en CU (no medido); medición real de Direct Lake (no existe un modelo de prueba) |

**Hipótesis de partida:** H-a) el pipeline es sano pero cada vez más lento por ficheros pequeños; H-b) gold no está pensado para su consumidor; H-c) Direct Lake resolvería el refresco pero no los problemas de contrato y de integridad de gold.

**Recorrido:** Spark runs (pipeline) → Spark resources (`env_gold` y pools) → Delta tables (propiedades, ficheros e historial de gold) → Semantic models (requisitos de Direct Lake). Pivote a Delta tables porque el layout condiciona tanto el refresco Import como Direct Lake.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad | FTL64 (trial), West Europe, activa. Se trata como F64 (Learn lista F64/FT1/P1): inferido | informe 11 (E11), E8 |
| Runtime | Environments en 1.3; el valor por defecto del workspace es 2.0 (una sesión Livy por defecto devolvió `spark.version` 4.1.1.5.5) | E3, E5 |
| Pool de gold | `pool_gold_xl`: Large, MemoryOptimized, autoescalado 1-4 nodos, ejecutores dinámicos 1-3; `env_gold` desactiva la asignación dinámica y fija 3 ejecutores de 16 cores y 112 g (driver 16 cores, 112 g) | E3, E4 |
| Pool de bronze y silver | `Starter Pool`: Medium, autoescalado 1-10 nodos, ejecutores dinámicos 1-9 (los environments limitan a 1-4) | E4 |
| Librerías en `env_gold` | Ninguna (`EnvironmentLibrariesNotFound`) | E3 |
| Alta concurrencia en pipelines | Desactivada (`notebookPipelineRunEnabled = false`) | E5 |
| Modo de almacenamiento del modelo | Import, lectura del SQL endpoint de `lh_gold` | informe 09 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| pl_daily_sales | DataPipeline | Orquestación (05:00 UTC, diario) | bd706b1d-499f-4a0d-bb22-222312944ca1 |
| env_gold / nb_03 | Environment / Notebook | Gold | b8c2f706-500a-4507-89fa-f460f81ce7d7 / c7cca4b7-3722-4bec-9946-504520f6be21 |
| nb_04 | Notebook | Refresco del modelo | 3a609552-4721-406a-8e9c-f801c0a43b59 |
| lh_gold | Lakehouse | Gold | 3aee923d-121b-415b-872c-4d5bb70664c0 |
| sm_sales | SemanticModel | Consumo | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |

## Evidencia

### Métricas clave

**Ejecuciones de `pl_daily_sales` (UTC; duración en segundos; E1, E2)**

| Inicio | Disparo | Estado | Total | Ingest bronze | Bronze to silver | Silver to gold | Refresh semantic model |
|--------|---------|--------|-------|---------------|------------------|----------------|------------------------|
| 10-30 17:11 | Manual | Completada | 914 | 221 | 279 | 341 | 53 |
| 10-30 17:27 | Manual | Completada | 1.160 | 219 | 458 | 343 | 126 |
| 10-30 17:46 | Manual | Completada | 977 | 156 | 458 | 309 | 35 |
| 10-30 18:03 | Manual | Completada | 1.214 | 203 | 522 | 435 | 36 |
| 10-30 18:23 | Manual | Completada | 1.118 | 189 | 519 | 338 | 58 |
| 10-30 18:43 | Manual | **Fallida** | 62 | 52 (falla) | – | – | – |
| 10-30 18:44 | Manual | Completada | 1.338 | 232 | 579 | 369 | 143 |
| 10-30 19:07 | Manual | Completada | 1.404 | 188 | 638 | 524 | 37 |
| 10-30 19:30 | Manual | Completada | 1.221 | 202 | 611 | 369 | 22 |
| 10-30 19:51 | Manual | Completada | 1.621 | 217 | 649 | 704 | 36 |
| 10-31 05:00 | Programada | Completada | 1.572 | 301 | 700 | 372 | 159 |
| 11-01 05:00 | Programada | **Fallida** | 79 | 70 (falla) | – | – | – |
| 11-02 05:00 | Programada | Completada | 1.499 | 274 | 735 | 431 | 37 |
| 11-03 05:00 | Programada | Completada | 1.555 | 267 | 747 | 381 | 145 |
| 11-03 08:05 | Manual | Completada | 1.517 | 254 | 731 | 372 | 145 |
| 11-04 05:00 | Programada | Completada | 1.672 | 304 | 792 | 400 | 158 |
| 11-05 05:00 | Programada | Completada | 1.839 | 265 | 881 | 522 | 143 |

**Configuración de gold, verificada hoy (E3, E5, E6, E7)**

| Elemento | Valor medido | Valoración |
|----------|--------------|------------|
| `env_gold` (staging = publicado, `publishDetails.state = Success`) | `pool_gold_xl`, driver y ejecutor 16 cores/112 g, `dynamicExecutorAllocation.enabled = false`, runtime 1.3; `spark.fabric.resourceProfile = writeHeavy`, `spark.sql.parquet.vorder.default = false`, `spark.databricks.delta.optimizeWrite.enabled = false` | Idéntico a lo medido en el informe 03; sin cambios |
| `nb_03` (código) | `spark.conf.set("spark.sql.adaptive.enabled", "false")`; `mode("overwrite")` + `overwriteSchema=true` en las 5 tablas que escribe en cada ejecución; `dim_date` y `promotions` solo si no existen | informe 11 (E7) |
| Sesión Livy por defecto del workspace | `spark.sql.parquet.vorder.default = false`, `spark.fabric.resourceProfile = writeHeavy`, `spark.microsoft.delta.optimizeWrite.enabled` sin valor | Los defaults del workspace tampoco activan V-Order |
| Uso real de `nb_03` (informe 04, 15 ejecuciones) | 48 cores fijos; eficiencia 0,121-0,347 (0,255 la última); idle/duración 0,56-0,88; cola de Livy 61-287 s (mediana 76); 3,8 mil s de tareas; spill 0 | No se volvió a medir hoy; el environment y el pool no han cambiado |

**Layout de gold hoy (E6, E7)**

| Tabla | Ficheros | Tamaño | Filas por fichero (mín / mediana / máx) | Etiquetas V-Order en los ficheros | Escritor |
|-------|---------:|-------:|-----------------------------------------|-----------------------------------|----------|
| fact_sales | 35 | 751,8 MB (14,0 / 23,3 / 26,7 MB por fichero) | 268.148 / 454.773 / 523.209 | 0 de 35 | `CREATE OR REPLACE TABLE AS SELECT` |
| dim_customer | 880 | 6,7 MB (3,9 / 6,3 / 31,9 KB por fichero) | 21 / 112 / 1.247 | 0 de 880 | ídem |
| dim_product | 8 | 0,1 MB | 625 | 0 de 8 | ídem |
| dim_store | 8 | ~0 MB | 6-7 | – | ídem |
| daily_store_sales | 198 | 0,6 MB | 1 / 3 / 10 | – | ídem |
| dim_date, promotions | 1 y 2 | < 0,1 MB | – | – | `CREATE TABLE` (una sola versión) |

Propiedades (`DESCRIBE DETAIL`, `SHOW TBLPROPERTIES`): sin particionado (`partitionColumns = []`) en las 7 tablas; solo `delta.stats.extended.collect/inject = true`; protocolo lector 1 y escritor 2 (`appendOnly`, `invariants`); sin deletion vectors ni `delta.columnMapping`. `DESCRIBE HISTORY` de `fact_sales`, `dim_customer`, `dim_product` (informe 11): solo `CREATE OR REPLACE TABLE AS SELECT`; ninguna operación `OPTIMIZE` ni `VACUUM`. `dim_product` tiene un checkpoint en la versión 10 (intervalo estándar).

**Direct Lake: límites y requisitos (Learn, E8) frente al estado actual**

| Requisito o límite (F64/FT1) | Valor de Learn | `sm_sales` / gold hoy |
|------------------------------|----------------|-----------------------|
| Ficheros Parquet por tabla | 5.000 | fact_sales 35; dim_customer 880 (+~55/carga) |
| Row groups por tabla | 5.000 | fact_sales ≥ 35 (≥ 1 por fichero; no leídos) |
| Filas por tabla | 1.500 M | 15 M |
| Memoria máxima | 25 GB | Import actual: 1,03 GB (informe 10) |
| Row group recomendado | 1-16 M de filas | fact_sales ≤ 523.209 filas por fichero, así que < 1 M |
| V-Order | Recomendado en tablas Spark consumidas por Direct Lake (o `readHeavyForPBI`) | No: perfil `writeHeavy`, V-Order `false`, 0 ficheros etiquetados |
| Patrón de actualización | Preferir solo añadir; el sobrescritura completa impide el enmarcado incremental | Reescritura completa diaria de todas las tablas |
| Columnas calculadas | No admitidas en Direct Lake on SQL; en on OneLake solo con contexto de usuario (preview) | `line_margin`, `year_month` |
| Claves del lado "uno" | Únicas, o la consulta falla | `customer_id` y `product_code` únicos (informes 09 y 10) |
| Tipos | Sin complejos, binarios ni GUID; relaciones con el mismo tipo | Solo texto, enteros, doble, fecha y marca de tiempo; mismo tipo en ambos lados |
| Tabla de fechas | Se admite marcar la propia | `dim_date` existe y no está marcada (informe 09) |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces/{ws}/items/{pipeline}/jobs/instances` | 16 ejecuciones desde 2026-10-30 17:11; 2 `Failed` (mensaje de `Ingest bronze`: `DELTA_FAILED_TO_MERGE_FIELDS 'amount'`) |
| E2 | REST | `POST /v1/workspaces/{ws}/datapipelines/pipelineruns/{id}/queryactivityruns` (lectura) ×16 | Duración por actividad (tabla anterior) |
| E3 | REST | `GET .../environments/{env_gold}/sparkcompute`, `/libraries`, detalle | Valores de la tabla de configuración; sin librerías |
| E4 | REST | `GET .../spark/pools` | Starter Pool y `pool_gold_xl` |
| E5 | REST | `GET .../spark/settings` | Runtime por defecto 2.0, alta concurrencia en pipeline desactivada, timeout 20 min |
| E6 | Livy | Sesión sobre `lh_gold` creada a las 10:50 UTC y eliminada a las 10:54 UTC (pool por defecto, sin `conf`): `DESCRIBE DETAIL` de 7 tablas, `SHOW TBLPROPERTIES fact_sales`, `spark.conf.get` | Ver layout y propiedades; la última de las lecturas de `spark.conf.get` (clave `spark.databricks...`) devolvió error y no se repitió |
| E7 | OneLake | Lectura de `_delta_log/*.json` de `fact_sales`, `dim_customer`, `dim_product` (última versión) | Tamaño, filas y etiquetas de los `add`; configuración de la tabla |
| E8 | Docs | Microsoft Learn: Direct Lake overview; Understand Direct Lake query performance; Cross-workload table maintenance; Schema evolution | Límites, requisitos y patrones de actualización citados arriba |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | El pipeline funciona pero se alarga (+17 % programado en 5 días) y la actividad dominante es `Bronze to silver`; fallos deterministas; el refresco no se vigila | Media | Alta | E1, E2, informes 01, 06, 11 |
| H2 | Gold usa un pool fijo de 48 cores con eficiencia 0,255 | Baja | Alta (configuración) / Media (uso, de informe 04) | E3, E4, informe 04 |
| H3 | La escritura de gold no sirve a su consumidor: `writeHeavy`, sin V-Order, ficheros pequeños, `dim_customer` con 880 ficheros, reescritura completa sin mantenimiento | Media | Alta | E3, E6, E7 |
| H4 | Direct Lake es viable en volumen pero requiere preparar gold; los requisitos incumplidos hoy son V-Order, row groups y columnas calculadas | Media | Alta (estado) / Media (valoración) | E6, E7, E8 |
| H5 | Con Direct Lake el renombrado de `category`, las claves huérfanas y la tabla de fechas siguen siendo problemas de contrato y de integridad | Media | Media | E8, informes 09 y 11 |

### H1 · Salud del pipeline (medido)

- **Estado:** 14 de 16 ejecuciones completadas (87,5 %); 2 fallidas en `Ingest bronze` a los 52 y 70 s: runs 6 y 12 (30-oct 18:43 manual y 1-nov 05:00 programada). Causa (informe 06): `nb_01` convierte `amount` a texto cuando `run_seq % 6 == 0`; el siguiente será el run 18 (6-nov 05:00 UTC).
- **Tendencia (programadas completadas):** 1.572 s (31-oct), 1.499, 1.555, 1.672 y 1.839 s (5-nov): +267 s (+17 %) en 5 días de datos. Por actividad entre el 31-oct y el 5-nov: `Bronze to silver` 700 → 881 s (+26 %), `Silver to gold` 372 → 522 s (+40 %, aunque el 2-nov fue 431 y el 4-nov 400), `Ingest bronze` estable (265-304 s), `Refresh semantic model` 37-159 s según la cola de la sesión (informe 04). Referencia de regresión: ratio contra la mediana de las cinco anteriores 1,18-1,20x, por debajo del umbral de 2x (`job-diagnostics.md` § Detect Regressions, citado en informe 01).
- **Actividad más lenta:** `Bronze to silver` con 881 s (47,9 % de los 1.839 s) y creciendo; le sigue `Silver to gold` con 522 s (28,4 %).
- **Causas conocidas (informes 01, 02 y 05):** ficheros pequeños en `silver.customers` (28.149) y reescritura completa de ventas; no se repiten.
- **Relación con el modelo:** `Refresh semantic model` termina `Succeeded` incluso con refrescos fallidos, y las dos ejecuciones fallidas dejan sin ejecutar `nb_03` y `nb_04` ese día (informes 06 y 11).

### H2 · Environment y pool de gold (medido / informe 04)

- **Qué hay:** `env_gold` fija 3 ejecutores de 16 cores y 112 g sin asignación dinámica sobre un pool propio bajo demanda (cola de Livy de 61-287 s); un `Starter Pool` de silver y bronze con ejecutores dinámicos 1-4. Sin librerías.
- **Coincidencia con la carga (del informe 04, no re-medida hoy):** 48 cores fijos, eficiencia de cores 0,255, 9,5 cores en uso de media, 3,8 mil s de tareas en total y un solo stage grande (880 tareas, lectura de `silver.customers`). No hay spill. El clúster no limita la duración; sobra cómputo y se paga por 3 ejecutores durante toda la sesión.
- **Impacto:** bajo en duración, no medido en CU. Un pool dinámico más pequeño (silver: 1-4 ejecutores de 8 cores) bastaría con la carga actual (inferencia basada en eficiencia). Sin librerías, el tiempo de arranque no se explica por instalación.

### H3 · Escritura de gold frente a su consumidor (medido salvo lo marcado)

- **Perfil y V-Order:** `writeHeavy` y `vorder.default = false` en el environment y en la sesión por defecto; 0 de 923 ficheros muestreados llevan etiqueta V-Order. Learn recomienda `readHeavyForPBI` o V-Order para tablas Spark consumidas por Direct Lake, y no activarlo solo para SQL endpoint o Spark; con Import por SQL endpoint, hoy V-Order no aporta.
- **Tamaño y número de ficheros:** `fact_sales` 35 ficheros de 14-27 MB (la guía de la skill pide 128 MB-1 GB para gold: `spark-monitoring-best-practices` en Learn) y 268.148-523.209 filas por fichero. `dim_customer`: 880 ficheros de mediana 6,3 KB (mediana de 112 filas) frente a un umbral de 32 MB de la skill, +58 ficheros por carga de media (63 → 880 en 14 versiones). `daily_store_sales`: 198 ficheros de 3 filas.
- **Particionado, mantenimiento y checkpoint:** sin particionado; en ninguna tabla hay `OPTIMIZE` ni `VACUUM` en el historial (solo `CREATE OR REPLACE`). La carpeta `Tables` conserva ficheros sin referenciar que ocupan más que las tablas activas (informe 05: 3,25 GiB); `dim_product` tiene checkpoint cada 10 versiones (normal).
- **Efecto en la lectura del modelo en Import (inferencia):** el refresco lee por el SQL endpoint, con `dim_customer` en 880 ficheros y reescrituras completas diarias. Learn atribuye mayor latencia de sincronización del endpoint a muchos ficheros pequeños (`sql-endpoint-performance`). Es coherente con el retardo de más de 1-3 min inferido en el informe 11, pero no se midió. Los refrescos programados tardan 2-11 min (informe 11, E1).
- **Efecto en Direct Lake (inferencia, Learn):** cada `CREATE OR REPLACE` es un patrón destructivo que impide el enmarcado incremental, de modo que tras cada carga el modelo vuelve a un estado frío; `fact_sales` con row groups < 1 M filas genera más segmentos que lo recomendado; `dim_customer` con 880 ficheros pequeños añade trabajo de transcodificación y se acerca a su límite (5.000 ficheros) en unas 71 cargas sin compactar ((5.000 − 880) / 58).

### H4 · Qué requiere y qué aporta Direct Lake

- **Cabe en los límites:** 15 M filas frente a 1.500 M; memoria 1,03 GB del modelo Import frente a 25 GB; ficheros y row groups por debajo de 5.000 (con la salvedad de `dim_customer`).
- **Cambios obligatorios en gold o el modelo:** (a) `line_margin` y `year_month` no se admiten como columnas calculadas en Direct Lake on SQL, y en on OneLake solo con contexto de usuario (preview): pasar a la tabla en `nb_03` (`year_month` mejor en `dim_date`); (b) V-Order o `readHeavyForPBI` en el escritor de gold; (c) compactar `dim_customer`, y subir `fact_sales` por encima de 1 M filas por row group (Learn sugiere `spark.sql.parquet.native.writer.maxRowGroupRowCount` con un valor probado; validar con Delta Analyzer); (d) marcar `dim_date` como tabla de fechas y relacionarla (informe 09).
- **Qué aporta:** el refresco pasa a enmarcado de metadatos (segundos) en vez de copiar 15 M de filas (2-11 min hoy); solo se cargan en memoria las columnas consultadas, así que las 719 MB de `sale_id` no se cargarían si ningún visual la usa (inferencia a partir de Learn: "solo se carga lo necesario para responder la consulta"); Direct Lake no mejora por sí mismo el DAX de `Avg Ticket` y similares (informes 07 y 08).
- **Tipo de Direct Lake:** on OneLake no hace fallback a DirectQuery; si se supera un límite, el refresco falla. On SQL sí hace fallback y requiere el SQL endpoint para descubrir tablas y permisos. Con on OneLake el modelo no depende de la sincronización del endpoint.

### H5 · Qué pasa con el renombrado, las claves huérfanas y la tabla de fechas

| Tema | Con Import (hoy) | Con Direct Lake | Qué cambia |
|------|------------------|-----------------|-----------|
| Renombrado de `category` (v3, v6, v13 de `dim_product`) | El refresco falla con `The 'category' column does not exist in the rowset` y el modelo se queda con la última carga buena (informe 11) | El modelo mapea la columna física por nombre; el enmarcado (y, si la versión enmarcada ya no existe, las consultas) fallaría hasta corregirlo (inferencia: Learn dice que los renombrados rompen modelos y que Direct Lake trabaja contra una versión Delta fija). Las actualizaciones automáticas se suspenden tras un error no recuperable hasta un refresco correcto | No desaparece: sigue siendo un problema de contrato (R1). Cambia el síntoma: sin copia de datos, la frescura la determina el enmarcado, no el refresco de 8-11 min |
| Esquema cambiante por `overwriteSchema` | Visible como fallo de refresco | Visible como fallo de enmarcado; Learn pide tratar `overwriteSchema` como operación de alto impacto y usar column mapping para renombrar | Mismo origen |
| Claves huérfanas (38.121 clientes en el modelo; 41.050 en gold hoy, informe 09) | Miembro en blanco en `dim_customer`; `Active Customers` y `Top 100` falseados | Igual: es un problema de datos de gold, no del modo (inferencia: la integridad referencial se resuelve en consulta en ambos modos). Direct Lake solo falla si el lado "uno" tiene duplicados, y no los hay | No desaparece (informe 09, R1) |
| Columnas calculadas (`line_margin`, `year_month`) | Evaluadas en el refresco | No admitidas (SQL) o con límites (OneLake) | Hay que moverlas al origen (informes 09 y 10, R6/R4) |
| `dim_date` | Existe sin marcar; no se usa | Se admite marcar la propia; las medidas deben usarla | Igual de necesario (informe 09, R3) |
| Frescura | Refresco programado 04:30/05:30 UTC y petición de `nb_04`, sin espera ni verificación; retardo del endpoint | Con actualizaciones automáticas: enmarcado por tabla al detectar cambios, con ventana de inconsistencia mientras `nb_03` reescribe las tablas en secuencia (`fact_sales` 05:23:57, `dim_customer` 05:27:09, `dim_store` 05:27:22, `dim_product` 05:27:30 el 5-nov: ~3,5 min). Sin ellas: enmarcado explícito al terminar el pipeline | La frescura por enmarcado desaparece los problemas de copia y de retardo del endpoint (si es on OneLake), pero exige decidir cuándo enmarcar |

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Estabilizar el contrato de gold (sin renombrar `category`, sin cambiar el tipo de `amount`) | H1, H5 | Alto | Bajo | Bajo | Sí |
| R2 | Preparar el escritor de gold para su consumidor (V-Order o `readHeavyForPBI`, `OPTIMIZE` de `dim_customer`, `autoCompact`) | H3, H4 | Medio | Medio | Medio | Sí |
| R3 | Pool de gold dinámico y más pequeño | H2 | Bajo | Bajo | Bajo | Sí |
| R4 | Probar Direct Lake on OneLake en una copia del modelo | H4, H5 | Medio | Alto | Medio | Sí |
| R5 | Pasar a cargas incrementales de `fact_sales` y borrado lógico de clientes | H3, H5 | Alto | Alto | Medio | Sí |
| R6 | Vigilancia del refresco/enmarcado en el pipeline y avisos | H1 | Alto | Bajo | Bajo | Sí |

### R1 a R3

- **R1:** en `nb_03` poner `product_schema_v2_every = 0` y en `nb_01` `schema_drift_every = 0` (o aislar la deriva), de modo que el run 18 del 6-nov no falle. Validar con los siguientes runs (18, 20, 24) y con E1/E2. Reversión: restaurar los valores. Confirmación: Sí (edita notebooks).
- **R2:** en `env_gold` usar `readHeavyForPBI` (o `spark.sql.parquet.vorder.default = true`) solo cuando se decida R4; activar `autoCompact` y `optimizeWrite`; ejecutar `OPTIMIZE` sobre `dim_customer` (y `fact_sales` para row groups ≥ 1 M, validando con Delta Analyzer). Como `nb_03` reescribe las tablas cada noche, el `OPTIMIZE` puntual se pierde si no se corrige antes el escritor (informe 05). Validar con `DESCRIBE DETAIL` (número de ficheros), etiquetas V-Order en los `add` y tamaño de fichero. Reversión: volver a `writeHeavy` y no ejecutar `OPTIMIZE`. Confirmación: Sí (cambio de environment y de datos).
- **R3:** quitar `dynamicExecutorAllocation.enabled = false` y usar 1-4 ejecutores de 8 cores como en silver, o un pool de menor tamaño. Impacto esperado: menos CU y arranque más rápido (cola 61-287 s es del pool propio). Validar con `resourceUsage` (eficiencia > 0,5). Estimación: no se midió ningún tamaño alternativo. Confirmación: Sí.

### R4 a R6

- **R4:** crear una copia del modelo con tablas Direct Lake on OneLake sobre `lh_gold` tras R1 y R2; con las columnas calculadas movidas a gold; actualizaciones automáticas desactivadas y enmarcado explícito al final del pipeline. Validar con Delta Analyzer (filas por row group, ficheros), tiempos de la primera consulta tras la carga y del enmarcado, y los valores de las medidas contra `sm_sales` (informes 07 y 08). Reversión: seguir con Import. Confirmación: Sí.
- **R5:** `fact_sales` en modo añadir (por `business_date`) y `dim_customer` con borrado lógico (informe 09, R1). Impacto: permite el enmarcado incremental y elimina las claves huérfanas. Validar con `DESCRIBE HISTORY` (operaciones `WRITE` en modo `Append`) y E5/E9 del informe 09. Reversión: restaurar el `overwrite`. Confirmación: Sí.
- **R6:** sustituir `nb_04` por la actividad nativa de refresco del pipeline (informes 04, R1, y 11, R2) o, con Direct Lake, por el enmarcado explícito vigilado; alinear los calendarios y activar los avisos de fallo (informe 11, R4 y R5). Confirmación: Sí.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Gold se queda corto de cómputo (el pool limita la duración) | E3, informe 04 | Eficiencia 0,255, spill 0 y 99 s sin ningún job; el único stage grande es la lectura de `customers` |
| D2 | Hay librerías o runtime incompatibles en `env_gold` | E3 | Sin librerías; runtime 1.3 coherente con los otros environments |
| D3 | Alguna tabla de gold ya tiene V-Order o particionado | E6, E7 | 0 ficheros etiquetados y `partitionColumns = []` |
| D4 | `OPTIMIZE`/`VACUUM` se ejecutan en gold | informe 11, E9 | Solo `CREATE OR REPLACE` en el historial |
| D5 | Direct Lake superaría los límites de la capacidad | E8 | 15 M de filas frente a 1.500 M; 880 ficheros frente a 5.000 |

## Siguientes pasos

- [ ] Aprobar y aplicar R1 antes del run 18 (6-nov 05:00 UTC) — responsable: ingeniería de datos · relacionado con: R1
- [ ] Decidir R2 y R5 según el calendario de Direct Lake — responsable: ingeniería de datos / propietario del modelo · relacionado con: R2, R5
- [ ] Preparar la copia de prueba en Direct Lake on OneLake (R4) — responsable: propietario del modelo · relacionado con: R4
- [ ] Repetir el análisis tras aplicar R# para validar el impacto

## Notas

### Limitaciones

- **Medido hoy:** historial de ejecuciones, duración por actividad, `env_gold`, pools, ajustes del workspace, propiedades y layout de las tablas de gold, historial Delta, valores de Learn.
- **Del informe 04 (no re-medido):** eficiencia, idle, cola de Livy y composición de los stages de `nb_03`.
- **Inferencia:** efecto de los ficheros pequeños sobre el retardo del endpoint, comportamiento del enmarcado ante un renombrado, tratamiento de huérfanos en Direct Lake, memoria cargada por columnas consultadas, estimación de 71 cargas hasta el límite de ficheros.
- **Row groups reales:** no se leyeron los pies de página de Parquet ni se ejecutó Delta Analyzer; solo se conocen las filas por fichero, que acotan el tamaño del row group.
- **Direct Lake:** no existe un modelo de prueba; no se midió ningún tiempo de enmarcado ni de consulta.
- Livy: una sesión (10:50-10:54 UTC), solo lecturas (`DESCRIBE DETAIL`, `SHOW TBLPROPERTIES`, `spark.conf.get`); una de las lecturas de configuración devolvió error y se omitió.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Row groups por fichero | No se leyó el pie de página de Parquet | La valoración contra 1-16 M filas se basa en filas por fichero |
| CU consumidas por `nb_03` y por el refresco | No se consultó Capacity Metrics | H2 sin cifra de CU |
| Coste de sincronización del SQL endpoint | No se midió la hora de sincronización | Efecto de los ficheros pequeños inferido |
| `spark.databricks.delta.optimizeWrite.enabled` en la sesión por defecto | La lectura devolvió error | Se usa el valor declarado en `env_gold` (`false`) |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Perfil para gold | `e2e-medallion-architecture` y las guías de la skill: gold en lectura con V-Order | Learn: V-Order o `readHeavyForPBI` solo si Direct Lake es consumidor principal; no activarlo para SQL endpoint ni Spark | Con Import por SQL endpoint hoy no se recomienda V-Order; sí al pasar a Direct Lake (R2 condicionada a R4) |
| Tamaño de fichero en gold | La skill usa 32 MB como umbral de ficheros pequeños | Learn: 128 MB-1 GB y row groups de 1-2 M filas (otra guía: 1-16 M para Direct Lake) | Se citan ambos; `fact_sales` (14-27 MB) queda por debajo de las dos referencias |

## Anexo

### Configuración efectiva

```json
// env_gold sparkcompute (E3)
{
  "driverCores": 16, "driverMemory": "112g",
  "executorCores": 16, "executorMemory": "112g",
  "dynamicExecutorAllocation": { "enabled": false },
  "instancePool": { "name": "pool_gold_xl", "type": "Workspace" },
  "runtimeVersion": "1.3",
  "sparkProperties": {
    "spark.databricks.delta.optimizeWrite.enabled": "false",
    "spark.fabric.resourceProfile": "writeHeavy",
    "spark.sql.parquet.vorder.default": "false"
  }
}
```
