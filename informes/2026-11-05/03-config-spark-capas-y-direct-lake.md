# Configuración Spark por capa (declarada, sobrescrita, efectiva) y viabilidad de Direct Lake para sm_sales

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-05 |
| **Áreas** | Spark resources → Spark runs → Delta tables → Semantic models |
| **Ámbito** | workspace `FabricPerfLab` · `env_bronze`, `env_silver`, `env_gold`, `nb_01`, `nb_02`, `nb_03`, tablas de `lh_gold`, modelo `sm_sales` |
| **Ventana analizada** | Sesiones Spark de la ejecución programada del 2026-11-05 05:00–05:30 UTC; definiciones y estado leídos el 2026-11-05 |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli, semantic-model-authoring |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Alta (declarado y sobrescrito) / Media (efectivo, inferido de propiedades de arranque y planes) |

## Resumen

- **Pregunta:** ¿es correcta la configuración Spark de `nb_02` (broadcast, AQE y skew join desactivados)? Revisar bronze, silver y gold en tres niveles (environment, notebook, sesión). Valorar si `sm_sales` podría pasar a Direct Lake.
- **Conclusión:** el usuario tiene razón en silver. `env_silver` y la celda 2 de `nb_02` declaran lo mismo (AQE off, skewJoin off, `autoBroadcastJoinThreshold=-1`, `shuffle.partitions=2000`) y las propiedades de arranque de la sesión no las traen, pero los planes demuestran que la sobrescritura del notebook sí está activa (105 de 107 planes sin `AdaptiveSparkPlan`, 7 `SortMergeJoin`, stages de 2.000 tareas). No hay ninguna razón medida que la justifique y causa lo visto en los informes 01 y 02. Bronze y gold tienen incoherencias menores. `sm_sales` es 100 % Import hoy; pasar a Direct Lake es viable con requisitos previos (columnas calculadas, V-Order, filas por row group, fragmentación de `dim_customer`, deriva de esquema).
- **Impacto:** en silver, la combinación produce el sesgo de `store_id` (9,0 M de 15 M de filas en una tarea), ~1.900 ficheros nuevos por carga en `silver.customers` y joins sort-merge de una tabla de 50 filas (informes 01 y 02).
- **Primera acción:** R1, quitar las cuatro propiedades tanto de `env_silver` como de `nb_02` (quitar solo una de las dos deja la otra). Requiere confirmación. Después R3 (prerequisitos para Direct Lake).

## Alcance

**Pregunta original:** "el usuario cree que la configuración Spark de nb_02 (broadcast desactivado, AQE desactivado, skewJoin desactivado) no es correcta. Revísala para las tres capas (bronze, silver y gold): (1) lo declarado en el environment de cada capa, (2) lo que sobrescribe el notebook (%%configure, spark.conf.set, builder), (3) lo efectivo en la sesión. [...] Comprueba también el modo de almacenamiento de sm_sales [...] y valora que podría pasar a Direct Lake: qué requisitos o impactos tiene para las tablas gold (ficheros, tamaño de row groups, V-Order, columnas, fallback a DirectQuery)."

**Informes previos:** `2026-11-05/01-pl-daily-sales-tendencia-crecimiento.md` (crecimiento por ficheros pequeños y cargas completas) y `2026-11-05/02-nb02-skew-stages-joins.md` (skew y joins de `nb_02`). Sus conclusiones no se repiten.

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Environments de las tres capas (publicado y staging), configuración del workspace, código y metadatos de `nb_01` a `nb_04`, propiedades de arranque de las sesiones de la ejecución del 5 nov, planes SQL, definición del modelo `sm_sales`, estado actual de las tablas gold | `lh_bronze` y `lh_silver` más allá de lo ya medido en 01. Rendimiento DAX del modelo y su historial de refrescos. Coste en CU |

**Hipótesis de partida:** H-a, el environment de silver declara lo mismo que el notebook y por eso el valor efectivo es el declarado. H-b, el notebook sobrescribe al environment. H-c, la configuración por capa no sigue la guía de la skill (bronze escritura, silver equilibrado, gold lectura).

**Recorrido:** Spark resources (environments y configuración por capa) → Spark runs (propiedades de arranque y planes de las sesiones, para saber qué es efectivo) → Delta tables (layout actual de gold) → Semantic models (modo de almacenamiento y requisitos de Direct Lake). El pivote a Delta tables lo motivó la guía de Direct Lake de `spark-resources.md` § 7.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad (SKU · región) | `FTL64` (trial) · West Europe | E9 |
| Runtime de los environments | 1.3 (los tres). El valor por defecto del workspace es 2.0 | E1, E2 |
| Runtime de las sesiones de notebook | 1.3 (`nb_02`) | E5 |
| Pool del workspace | `Starter Pool`, `customizeComputeEnabled=true`, `sessionTimeoutInMinutes=20`, `conservativeJobAdmissionEnabled=false`, alta concurrencia en pipeline desactivada | E1 |
| Modo de almacenamiento del modelo | Import en las 6 tablas (partición M sobre `Sql.Database` del SQL endpoint de `lh_gold`) | E7 |
| Permisos con los que se ejecutó | Lectura de workspace, Spark Monitoring, OneLake y `getDefinition` | E1–E9 |

Corrección al informe 01: allí se indicó "Runtime de Spark 2.0" a partir de la primera sesión de la lista del workspace, que era una sesión de diagnóstico ajena a la tubería. Las sesiones del pipeline usan runtime 1.3 (E5).

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| env_bronze / nb_01 | Environment / Notebook | Bronze | ed7daf54-76f9-4505-8a11-9eed95f8accb / 4240632d-… |
| env_silver / nb_02 | Environment / Notebook | Silver | 1cd0a99e-2c23-4c2f-8a9c-7f8a1a336358 / 4205418f-… |
| env_gold / nb_03 | Environment / Notebook | Gold | b8c2f706-500a-4507-89fa-f460f81ce7d7 / c7cca4b7-… |
| sm_sales | Modelo semántico | Consumo | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |

## Evidencia

### Métricas clave

**Configuración Spark por capa: declarada, sobrescrita y efectiva**

Leyenda: **D** = declarado en el environment (publicado y en staging, idénticos). **S** = sobrescrito en el notebook por `spark.conf.set` (no hay `%%configure`, `SparkSession.builder` ni otros overrides en ningún notebook; `nb_01`/`nb_02` solo añaden `spark.synapse.nbs.session.timeout=1200000` en sus metadatos). **E** = efectivo. Los valores marcados "(propiedad de arranque)" salen de `GET .../applications/{app}/environment`, que es la configuración con la que arranca la aplicación. Una `spark.conf.set` de SQL posterior **no** aparece ahí; por eso, el efecto de las sobrescrituras se infiere de los planes ("(inferido de planes)").

| Propiedad | Bronze (`nb_01`) | Silver (`nb_02`) | Gold (`nb_03`) |
|-----------|------------------|------------------|----------------|
| Recursos | D: Starter Pool, 8 cores, 56 g, ejecutores dinámicos 1–4. E: igual (propiedad de arranque) | D: Starter Pool, 8 cores, 56 g, dinámico 1–4. E: igual | D: `pool_gold_xl`, 16 cores, 112 g, **sin** asignación dinámica. E: 3 ejecutores fijos de 16 cores y 112 g (propiedad de arranque) |
| Perfil de recursos | D: `readHeavyForPBI`. E: `readHeavyForPBI` | D: ninguno. E: `writeHeavy` (por defecto) | D: `writeHeavy`. E: `writeHeavy` |
| V-Order (`spark.sql.parquet.vorder.default`) | D: `true`. E: `true` | D: ninguno. E: `false` | D: `false`. E: `false` |
| `optimizeWrite.enabled` | D: `false`. **S: `false`** (`nb_01` celda 3). E (arranque): `true`, el que trae el perfil. Efecto en ejecución: `false` (inferido de código y de ficheros de 0,23 MB, ver H2) | D: ninguno. S: ninguno | D: `false`. S: ninguno |
| `autoCompact.enabled` | D: `false`. E: no aparece, valor por defecto | D: ninguno | D: ninguno |
| AQE (`spark.sql.adaptive.enabled`) | D: ninguno. S: ninguno. E: activo por defecto (7 de 20 planes con `AdaptiveSparkPlan`) | **D: `false`. S: `false`** (celda 2). E (arranque): sin la propiedad. E (planes): **desactivado** | D: ninguno. **S: `false`** (celda 3). E (planes): desactivado (0 de 20 planes con `AdaptiveSparkPlan`) |
| `adaptive.skewJoin.enabled` | D: ninguno | **D: `false`. S: `false`**. E: sin propiedad de arranque; sin AQE no actúa (inferido) | D: ninguno |
| `autoBroadcastJoinThreshold` | D: ninguno. E: 26.214.400 (25 MB) | **D: `-1`. S: `-1`**. E (arranque): 26.214.400. E (planes): broadcast desactivado, 7 `SortMergeJoin` y ningún broadcast, incluida una tabla de 50 filas | D: ninguno. E: 26.214.400. Un `BroadcastHashJoin` en los 20 planes |
| `spark.sql.shuffle.partitions` | D: ninguno. E: por defecto | **D: `2000`. S: `2000`**. E (planes): stages de 2.000 tareas | D: ninguno. E: por defecto |
| Entorno aplicado a la sesión | Sin `spark.fabric.environmentDetails` en el arranque | Sin `spark.fabric.environmentDetails` en el arranque | `spark.fabric.environmentDetails` = `env_gold`, `spark.fabric.pool.name=pool_gold_xl` |

Referencias: la guía de la skill para Silver es "equilibrado, AQE activado" y para Gold "lectura, V-Order" (`data-engineering-patterns.md` § Spark Session Configurations for Performance, `e2e-medallion-architecture/SKILL.md` § Environment Optimization); para Bronze, "escritura, V-Order desactivado, autoCompact activado".

**Modelo `sm_sales` (E7)**

| Elemento | Valor |
|----------|-------|
| Modo de almacenamiento | `mode: import` en las 6 tablas (`fact_sales`, `dim_customer`, `dim_product`, `dim_store`, `dim_date`, `promotions`); origen `Sql.Database(...datawarehouse.fabric.microsoft.com, "lh_gold")` |
| Columnas calculadas en `fact_sales` | `line_margin = amount - quantity * unit_cost`, `year_month = FORMAT(sale_date, "yyyy-MM")` |
| Relaciones | 5; `fact_sales–dim_customer` y `promotions–dim_product` en doble sentido (esta última muchos a muchos) |
| Roles RLS/OLS | Ninguno en la definición |
| Refresco | Lo pide `nb_04` con `refresh_type="full"` |

**Tablas gold hoy (estado actual del `_delta_log`, E8)**

| Tabla | Ficheros | Filas | Tamaño | Filas por fichero (mín / mediana / máx) | Columnas | Etiqueta V-Order en los ficheros |
|-------|----------|-------|--------|------------------------------------------|----------|----------------------------------|
| fact_sales | 35 | 15.000.000 | 752 MB | 268.148 / 454.773 / 523.209 | 14 | No (`tags` vacíos) |
| dim_customer | 880 | 158.950 | 7 MB | 21 / 112 / 1.247 | 5 | No |
| dim_product | 8 | 5.000 | 0 MB | 625 | 5 | No |
| dim_store | 8 | 50 | 0 MB | 6–7 | 3 | No |
| daily_store_sales | 198 | 750 | 1 MB | 1 / 3 / 10 | 5 | No |
| dim_date, promotions | 1 y 2 | 730 y 2.052 | 0 MB | – | – | – |

Todas con escritor `CREATE OR REPLACE TABLE AS SELECT`, protocolo Delta reader 1 / writer 2 (sin deletion vectors), sin propiedades de V-Order, y sin deletion vectors en ningún fichero activo.

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces/{ws}/spark/settings` | Starter Pool, runtime por defecto 2.0, timeout 20 min, `highConcurrency.notebookPipelineRunEnabled=false` |
| E2 | REST | `GET /v1/workspaces/{ws}/environments/{id}`, `/sparkcompute` y `/staging/sparkcompute` ×3 | Propiedades declaradas de cada environment; publicado = staging; los tres con `publishDetails.state=Success` |
| E3 | REST (lectura) | `POST /v1/workspaces/{ws}/notebooks/{id}/getDefinition?format=ipynb` ×4 | Código y metadatos: environment y lakehouse por defecto de cada notebook; `spark.conf.set` en `nb_01`, `nb_02`, `nb_03`; sin `%%configure` ni `builder` |
| E4 | REST | `GET .../notebooks/{nb}/livySessions/{livy}/applications/{app}/environment` ×3 (última ejecución de `nb_01`, `nb_02`, `nb_03`) | Propiedades de arranque (350–400 propiedades por sesión) |
| E5 | REST | `GET .../notebooks/{nb02}/livySessions/{livy}` | `runtimeVersion` 1.3, 8 cores, 56 g, 1 ejecutor |
| E6 | REST | `GET .../applications/{app}/sql?details=true&offset=0&length=1000` ×3 | `nb_02`: 107 planes, 2 con `AdaptiveSparkPlan` (los ids 5 y 6, de calentamiento anteriores a la celda 2); `nb_01`: 20 planes devueltos, 7 adaptativos; `nb_03`: 20 planes devueltos, 0 adaptativos, 1 `BroadcastHashJoin` |
| E7 | REST (lectura) | `POST /v1/workspaces/{ws}/semanticModels/{id}/getDefinition` | TMDL del modelo (ver arriba) |
| E8 | OneLake | `GET Tables/{tabla}/_delta_log/*.json` de las 7 tablas gold; instantánea actual (altas menos bajas) | Ficheros, filas por fichero (`stats.numRecords`), tamaño, columnas, propiedades |
| E9 | REST | `GET /v1/capacities` | `FTL64`, West Europe |
| E10 | Docs | Microsoft Learn: Direct Lake overview; Cross-workload table maintenance and optimization | Requisitos, límites por SKU y recomendaciones (ver H5) |

No se creó sesión Livy. Una sesión propia mostraría los valores por defecto del workspace (Starter Pool, runtime 2.0), no los de las sesiones de `nb_01`/`nb_02`/`nb_03`, que no se pueden reproducir. Las propiedades de arranque de las propias sesiones del pipeline (E4) y sus planes (E6) responden mejor a "qué es efectivo". Por eso se dejó fuera, y la parte efectiva de las sobrescrituras en tiempo de ejecución queda marcada como inferida.

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | Silver: la configuración de `env_silver` y `nb_02` (AQE off, skewJoin off, broadcast off, 2.000 particiones) es incorrecta y está activa | Alta | Alta (declarado y sobrescrito) / Media (efectivo) | E2, E3, E4, E6 |
| H2 | Bronze: el perfil y el notebook se contradicen y producen ficheros pequeños | Media | Media | E2, E3, E4 |
| H3 | Gold: V-Order y perfil de escritura no coinciden con su consumidor; AQE desactivado sin motivo; pool fijo grande | Baja | Media | E2, E3, E4, E6, E8 |
| H4 | Las propiedades del environment de bronze y silver no aparecen en el arranque de sus sesiones; solo gold las trae | Media | Media | E2, E4 |
| H5 | `sm_sales` es Import; pasar a Direct Lake es viable, con requisitos previos en gold | Media | Alta (estado actual) / Media (valoración) | E7, E8, E9, E10 |

### H1 · Silver: configuración incorrecta y activa

- **Qué ocurre:** `env_silver` declara cuatro propiedades (AQE `false`, `skewJoin.enabled` `false`, `autoBroadcastJoinThreshold` `-1`, `shuffle.partitions` `2000`) y `nb_02` repite las mismas cuatro con `spark.conf.set` en la celda 2. Los planes muestran que están en vigor: 105 de 107 planes no tienen `AdaptiveSparkPlan` (los 2 que sí, ids 5 y 6, son de calentamiento), los 7 joins son `SortMergeJoin` (incluido el de la tabla `stores` de 50 filas y 17,8 KiB) y los stages de shuffle tienen 2.000 tareas.
- **Por qué es incorrecto:** la guía de la skill para Silver pide AQE activado. Con AQE desactivado, Spark no puede dividir la partición sesgada ni fusionar las 2.000 particiones casi vacías; con broadcast desactivado, `stores` (50 filas) se baraja entero (15 M de filas); con 2.000 particiones, cada `MERGE` de `customers` escribe ~1.900 ficheros pequeños. Esto es lo que midieron los informes 01 (28.149 ficheros, 117 MB) y 02 (9,0 M de filas en una tarea, 7 `SortMergeJoin`). Ninguna evidencia recogida justifica los valores: el notebook no comenta el motivo y el spill es 0 en todos los stages (informe 02, D1).
- **Impacto:** dominante en el aumento de duración de `nb_02` (informe 01, H2, H3). Qué es declarado, sobrescrito y efectivo: declarado y sobrescrito, idénticos; efectivo, confirmado por los planes para AQE, broadcast y particiones (Media, inferido de planes); `skewJoin` es inferido (sin AQE no actúa).

### H2 · Bronze: perfil, V-Order y optimizeWrite se contradicen

- **Qué ocurre:** `env_bronze` declara `readHeavyForPBI` (V-Order `true`) para la capa de escritura masiva, con `optimizeWrite` y `autoCompact` en `false`. `nb_01` vuelve a fijar `optimizeWrite=false`. En el arranque de la sesión `optimizeWrite.enabled` figura `true` (lo trae el perfil), y la propiedad del environment (`false`) no se ve. La ejecución añade 400 ficheros de 0,23 MB a `sales_raw` (`WRITE_PARTITIONS=400`), 30 commits a `inventory_events` y 8 ficheros a `customer_changes` (informe 01, H6).
- **Por qué:** la guía de la skill para Bronze es escritura (V-Order desactivado, `autoCompact` activado). V-Order en bronze añade coste de escritura sin consumidor. Los 400 ficheros por carga, un número exacto igual a `WRITE_PARTITIONS`, concuerdan con que `optimizeWrite` esté en `false` durante la escritura; es una inferencia de código y de ficheros, no una lectura de la configuración en ejecución.
- **Impacto:** medio, por los ficheros pequeños que `nb_02` lee cada día (informe 01, H3, H6).

### H3 · Gold: sin V-Order, AQE off, pool fijo

- **Qué ocurre:** `env_gold` declara `writeHeavy` y V-Order `false`, y los ficheros de las tablas gold no llevan etiqueta V-Order. `nb_03` desactiva AQE en la celda 3 sin otra propiedad que lo requiera. El pool `pool_gold_xl` (16 cores, 112 g) tiene asignación dinámica desactivada y 3 ejecutores fijos, frente al pool de silver (8 cores, 56 g, dinámico 1–4).
- **Por qué:** la guía de la skill para Gold es lectura con V-Order, y Learn recomienda V-Order o `readHeavyForPBI` para tablas Spark que consume Direct Lake (E10). Hoy el modelo es Import por SQL endpoint, así que V-Order no aporta (Learn: no activarlo solo por el SQL endpoint): el desajuste solo importa si se adopta Direct Lake (H5). El dimensionamiento del pool no se midió (eficiencia de cores no consultada), así que no se concluye sobre exceso de tamaño.
- **Impacto:** bajo hoy.

### H4 · Las propiedades de los environments de bronze y silver no llegan al arranque

- **Qué ocurre:** en el arranque de las sesiones de `nb_01` y `nb_02` no hay `spark.fabric.environmentDetails` ni `spark.fabric.pool.name`, y no figuran `adaptive.enabled`, `shuffle.partitions` ni `optimizeWrite=false`; `autoBroadcastJoinThreshold` aparece con el valor por defecto 26.214.400, no con `-1`. La sesión de `nb_03` sí trae `environmentDetails`, el pool `pool_gold_xl` y 3 ejecutores fijos. En bronze sí aparece el perfil `readHeavyForPBI`.
- **Por qué:** no se determinó. Ambas sesiones salen del `Starter Pool` (`spark.synapse.pool.name` con GUID de pool, `session-warmup.enabled=true`), mientras que gold usa un pool propio bajo demanda. Se puede pensar que las propiedades del environment no se aplican al arrancar desde el Starter Pool, pero es una inferencia.
- **Impacto:** si es cierto, las propiedades de `env_silver` no tienen efecto hoy en el pipeline, y solo `spark.conf.set` del notebook cuenta. Eso importa para R1: quitar solo las del notebook dejaría las del environment, que podrían activarse en otro modo de arranque; quitar solo las del environment no cambia nada hoy. Hay que quitar ambas.

### H5 · sm_sales: Import hoy, Direct Lake viable con requisitos

- **Qué ocurre:** las 6 tablas están en Import y leen el SQL endpoint de `lh_gold`. `nb_04` pide un refresco completo tras cada carga (23–159 s de actividad, informe 01).
- **Valoración:** pasar a Direct Lake evita copiar 15 M de filas en cada refresco (el refresco pasa a ser solo de metadatos). Hay que cumplir lo siguiente, según Learn (E10) y las tablas actuales (E8):

| Requisito o impacto | Estado en gold / modelo | Consecuencia |
|---------------------|-------------------------|--------------|
| Columnas calculadas | `fact_sales` tiene 2 (`line_margin`, `year_month`) | No se admiten en Direct Lake on SQL; en Direct Lake on OneLake solo en vista previa y solo contexto de usuario. Hay que calcularlas en `nb_03` y guardarlas como columnas de la tabla |
| Tipos de datos | Solo `string`, `int`, `double`, `date`, `timestamp` | Compatible; sin tipos complejos, binarios ni GUID |
| Límites por SKU (guardrails) | `FTL64` se trata como `F64` (inferido; Learn lista `F64/FT1/P1`): 5.000 ficheros, 5.000 row groups, 1.500 M de filas por tabla, memoria máx. 25 GB. `fact_sales`: 35 ficheros, 15 M de filas. `dim_customer`: 880 ficheros, con ~55 ficheros más por carga | Dentro de los límites hoy. `dim_customer` llegaría a 5.000 ficheros en unas 75 cargas si no se compacta; al superarlo, con Direct Lake on SQL hay fallback a DirectQuery, y con Direct Lake on OneLake el refresco falla |
| Tamaño de row group | `fact_sales`: 268.148–523.209 filas por fichero, así que ningún row group puede superar ese número. Los row groups reales no se leyeron | Learn: lo mejor es entre 1 M y 16 M de filas por row group; evitar row groups pequeños. Aquí quedan por debajo de 1 M (Media). `dim_customer`: 21–1.247 filas por fichero |
| V-Order | Ninguna tabla gold lo tiene; `env_gold` lo desactiva | Learn lo recomienda para tablas Spark consumidas por Direct Lake (o perfil `readHeavyForPBI`) |
| Patrón de escritura | Todas las tablas se reescriben enteras cada día (`CREATE OR REPLACE`) | Learn prefiere patrones de solo añadir para conservar ficheros y permitir el framing incremental. Con reescritura completa cada carga, el primer acceso a las columnas utilizadas vuelve a transcodificar todo |
| Deriva de esquema | `nb_03` renombra `category` a `product_category` cada 4.ª ejecución (`product_schema_v2_every = 4`) | En Direct Lake el modelo depende de las columnas físicas: un renombrado rompe el mapeo y el refresco/consulta falla hasta corregir el modelo |
| Unicidad del lado "uno" | `dim_customer`: 158.950 filas; unicidad de `customer_id` no comprobada | Direct Lake falla las consultas si encuentra duplicados en el lado uno. El informe 02 (H5) dejó una unión con 45 M de filas de salida sin explicar: conviene comprobar esto antes |
| Fallback a DirectQuery | Sin RLS ni vistas en gold | Solo Direct Lake on SQL hace fallback (por guardrails, vistas o RLS del endpoint); Direct Lake on OneLake no hace fallback |
| Relaciones y medidas | Doble sentido, muchos a muchos, medidas DAX costosas (`Avg Ticket`, `Enterprise Sales`) | Se mantienen; Direct Lake no mejora el DAX por sí mismo |

- **Impacto:** viable, pero no basta con cambiar el modo: sin los requisitos previos, el modelo se degradaría (fallback o fallos de refresco) en lugar de ganar. La parte de cómo medir DAX o el refresco actual no se analizó.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Quitar las cuatro propiedades de `env_silver` y de la celda 2 de `nb_02` | H1, H4 | Alto | Bajo | Bajo | Sí |
| R2 | Alinear bronze y gold con la guía por capa | H2, H3 | Medio | Bajo | Bajo | Sí |
| R3 | Preparar gold para Direct Lake antes de cambiar el modelo | H5 | Medio | Medio | Medio | Sí |

### R1 · Silver: quitar la configuración

- **Cambio propuesto:** en `env_silver` (staging y publicación) y en `nb_02` celda 2, quitar `spark.sql.adaptive.enabled`, `spark.sql.adaptive.skewJoin.enabled`, `spark.sql.autoBroadcastJoinThreshold` y `spark.sql.shuffle.partitions`, para volver a los valores de la plataforma. Añadir si se quiere forzar:

  ```python
  spark.conf.set("spark.sql.adaptive.enabled", "true")
  spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")
  ```

  Opcional, con `broadcast()` explícito para `stores` como en el informe 02, R1.
- **Impacto esperado:** vuelven el broadcast de tablas pequeñas, la fusión de particiones y el reparto de la partición sesgada, y desaparecen las 2.000 particiones fijas. La mejora cuantificada está en los informes 01 y 02; esta recomendación no añade una cifra.
- **Cómo validarlo:** en la siguiente ejecución, comprobar con `/sql` que los planes tienen `AdaptiveSparkPlan` y `BroadcastHashJoin` para `stores`, que `taskSummary` ya no muestra 9 M de registros en una tarea y que `silver.customers` no crece ~1.900 ficheros por carga.
- **Reversión:** volver a poner las cuatro propiedades.
- **Requiere confirmación:** Sí (publicar un environment y cambiar un notebook son cambios de Fabric).

### R2 · Bronze y gold

- **Cambio propuesto:** en `env_bronze`, usar el perfil de escritura (`writeHeavy`) con V-Order `false` y activar `autoCompact`; quitar `repartition(400)` o activar `optimizeWrite` en `nb_01`. En `env_gold`, usar `readHeavyForPBI` (o V-Order `true`) solo si se adopta Direct Lake (R3); quitar `spark.conf.set("spark.sql.adaptive.enabled", "false")` de `nb_03`.
- **Impacto esperado:** menos ficheros pequeños en bronze; gold preparado para su consumidor.
- **Cómo validarlo:** ficheros y tamaño medio por commit en `_delta_log` de bronze; etiqueta V-Order en los `add` de gold.
- **Reversión:** restaurar las propiedades anteriores.
- **Requiere confirmación:** Sí (cambios de environment y notebook).

### R3 · Preparar Direct Lake

- **Cambio propuesto:** (1) en `nb_03`, calcular `line_margin` y `year_month` y escribirlas en `fact_sales`; (2) compactar `dim_customer` (`OPTIMIZE`) y reescribir `fact_sales` con V-Order y, si hay que forzarlo, `spark.sql.parquet.native.writer.maxRowGroupRowCount` (ejemplo de Learn: 8.000.000), validando antes con Delta Analyzer; (3) pasar a cargas incrementales de `fact_sales` (informe 01, R3); (4) fijar el esquema de `dim_product` (sin renombrar `category`) o planificar el cambio del modelo; (5) comprobar la unicidad de `customer_id`; (6) crear una copia del modelo en Direct Lake on OneLake y comparar antes de sustituir `sm_sales`.
- **Impacto esperado:** el refresco pasa a reframing de metadatos; la primera consulta tras cada carga transcodifica las columnas usadas. No medido.
- **Cómo validarlo:** Delta Analyzer (filas por row group, ficheros), tiempo de las primeras consultas tras la carga y refrescos del modelo, antes y después.
- **Reversión:** volver al modo Import (el modelo actual se conserva).
- **Requiere confirmación:** Sí (escribe en tablas, cambia notebooks y modelo).

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | El notebook usa `%%configure`, `SparkSession.builder` u otros mecanismos de configuración | E3 | Ninguno de los 4 notebooks los tiene; solo `spark.conf.set` en `nb_01`, `nb_02` y `nb_03` |
| D2 | El environment publicado difiere del de staging (cambios sin publicar) | E2 | Publicado y staging son idénticos en las tres capas |
| D3 | Las tablas gold ya están en V-Order | E8, E2 | Sin etiqueta V-Order en los ficheros, V-Order `false` en `env_gold` |
| D4 | `sm_sales` ya usa Direct Lake o tiene tablas híbridas | E7 | Las 6 particiones son `mode: import` |
| D5 | Los guardrails de Direct Lake se superan hoy | E8, E10 | `fact_sales` 35 ficheros, 15 M de filas; `dim_customer` 880 ficheros; todos por debajo de 5.000 ficheros y 1.500 M de filas (asumiendo F64) |

## Siguientes pasos

- [ ] Aplicar R1 en `env_silver` y en `nb_02` — responsable: ingeniería de datos / `FabricAdmin` · relacionado con: R1
- [ ] Decidir si se adopta Direct Lake para `sm_sales` y aplicar R3 en gold si se adopta — responsable: dueño del modelo · relacionado con: R3
- [ ] Comprobar la unicidad de `customer_id` en `silver.customers` y `gold.dim_customer` — responsable: ingeniería de datos · relacionado con: R3
- [ ] Repetir el análisis tras aplicar R1 para validar el impacto

## Notas

### Limitaciones

- No se creó sesión Livy (ver Evidencia). La configuración **efectiva** de las sobrescrituras en tiempo de ejecución es inferida de los planes, no leída con `SET`/`spark.conf.get` en la sesión del notebook. Con `SET` o `spark.conf.get` en una sesión propia solo se vería la configuración por defecto de esa sesión.
- `GET .../environment` devuelve la configuración de arranque; no refleja `spark.conf.set` posteriores.
- Los planes de `nb_01` y `nb_03` se limitan a los 20 primeros devueltos por la API (el parámetro `length=1000` ya se aplicó, pero esas sesiones devolvieron 20); no son exhaustivos. Los de `nb_02` son los 107 completos.
- Los row groups reales de gold no se leyeron (no hay lector de Parquet disponible sin instalar software; el análisis usa filas por fichero, que acota los row groups).
- Se asume `FTL64` equivalente a `F64` para los guardrails; Learn no lista `FTL64`.
- No se midieron refrescos ni DAX de `sm_sales`.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| `spark.conf.get` en la sesión de `nb_02` | No reproducible desde una sesión Livy propia | El efecto de las sobrescrituras se infiere de los planes (Media) |
| Motivo por el que bronze y silver no traen `environmentDetails` en el arranque | No se pudo determinar con las rutas de lectura disponibles | H4 queda como hipótesis |
| Row groups reales, `DESCRIBE DETAIL` de gold | Sin Livy ni lector de Parquet | H5: tamaño de row group acotado, no medido |
| Unicidad de `customer_id` | Requiere una consulta (Livy o SQL endpoint) no lanzada | Riesgo de Direct Lake sin comprobar |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Clave de V-Order | `data-engineering-patterns.md` usa `spark.microsoft.delta.parquet.vorder.enabled`; `e2e-medallion-architecture/SKILL.md` usa `spark.sql.parquet.vorder.default` | Learn documenta `spark.sql.parquet.vorder.default` (sesión), `delta.parquet.vorder.enabled` (propiedad de tabla) | Se recomienda la clave de Learn; los environments de este workspace usan `spark.sql.parquet.vorder.default` |
| Optimize write en Gold | La skill de medallion lo activa, `data-engineering-patterns.md` lo desactiva | Learn: `readHeavyForPBI` lo activa para Direct Lake | Depender del consumidor (R2/R3) |
| Gold = lectura | `data-engineering-patterns.md` y medallion piden V-Order | Learn: no activar V-Order solo por el SQL endpoint; sí para Direct Lake | Hoy el consumidor es Import por SQL endpoint, así que el desajuste es Baja (H3) |
| Fallback de Direct Lake | La skill no lo recoge (`semantic-models.md` § 5) | Learn: solo Direct Lake on SQL hace fallback; Direct Lake on OneLake falla el refresco al superar guardrails | Se aplicó lo de Learn |

## Anexo

### Consultas completas

- E2: `GET /v1/workspaces/23ca4a73-3312-4242-9714-0289816895aa/environments/{ed7daf54-…|1cd0a99e-…|b8c2f706-…}` y `/sparkcompute`, `/staging/sparkcompute`.
- E4: `GET /v1/workspaces/{ws}/notebooks/{nb}/livySessions/{livy}/applications/{app}/environment`, con `nb_01`/`d5666c4d-…`/`application_1793854533248_0001`, `nb_02`/`ac30d635-…`/`application_1793855021534_0001`, `nb_03`/`6bb3eedb-…`/`application_1793856024555_0001`. Todas las llamadas a `api.fabric.microsoft.com` con cabecera `x-ms-fabric-skill`.
- E8: instantánea de cada tabla = suma de `add` menos `remove` de todos los JSON de `_delta_log`.

### Configuración efectiva

Ver la tabla "Configuración Spark por capa" en Métricas clave: contiene lo declarado, lo sobrescrito y lo efectivo, con la fuente de cada valor.
