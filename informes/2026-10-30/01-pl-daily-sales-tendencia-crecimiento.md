# pl_daily_sales: tendencia por ejecución, patrón de carga y crecimiento de las tablas Delta

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-10-30 |
| **Áreas** | Spark runs → Delta tables (pivot por ficheros/`_delta_log` de las tablas leídas) → Spark resources (solo configuración efectiva, sin hallazgo propio) |
| **Ámbito** | workspace `DataSaturday` · `pl_daily_sales`, `nb_01_ingest_bronze`, `nb_02_bronze_to_silver`, `nb_03_silver_to_gold`, `nb_04_refresh_model` y 18 tablas de `lh_bronze`, `lh_silver`, `lh_gold` |
| **Ventana analizada** | 2026-10-29 21:16 → 2026-10-30 00:22 UTC (10 ejecuciones del pipeline, las únicas que devuelve la API) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli (cabecera `x-ms-fabric-skill=spark-cli`) |
| **Modo** | Solo lectura (no se ejecutó ninguna acción de Tier B) |
| **Severidad global** | Media |
| **Confianza global** | Alta (tendencias medidas directamente); Media en la atribución de causa a la fragmentación de `silver.customers` |

## Resumen

- **Pregunta:** por qué `pl_daily_sales` tarda cada día más, con la tendencia de cada actividad y notebook (incluido shuffle y nº de jobs Spark), el patrón full/incremental de cada notebook y la evolución de las tablas y su `_delta_log`.
- **Conclusión:** el pipeline pasa de 1123 s (R1) a 1376 s (R10), +23 %, con pendiente de +30 s por ejecución. El 90 % de ese crecimiento está en `Bronze to silver` (370 → 646 s, +27 s/ejecución, r = 0,92). Crece por dos mecanismos distintos. (1) Reconstrucción completa de `silver.sales` desde todo el histórico de `bronze.sales_raw`: el shuffle de lectura de la actividad sube de 0,96 a 7,75 GB (coste O(n) por día). (2) El `MERGE` incremental de clientes sobre `silver.customers`, cuyo borrado/actualización toca miles de ficheros diminutos: la celda pasa de 138 a 376 s, y es la que más aporta al aumento (+238 s de los +283 s de la suma por celdas). `Ingest bronze` y `Refresh semantic model` no crecen.
- **Impacto:** +253 s por ejecución entre R1 y R10, con proyección lineal de unos 30 s más cada día. Aún no se supera la regla de regresión de la skill (R10 es 1,12× la mediana de las 5 anteriores en `Bronze to silver`; umbral 2×), por eso un umbral no lo detectaba.
- **Primera acción:** R1, hacer incremental el `MERGE` de clientes (menos particiones de shuffle, compactación y purga de deletion vectors de `silver.customers`) y R2, sustituir la reconstrucción completa de `silver.sales` por una carga incremental. Ambas requieren confirmación porque cambian código y datos.

## Alcance

**Pregunta original:** "El pipeline pl_daily_sales del workspace DataSaturday tarda cada día más (cada ejecución simula un día de negocio). No me vale un umbral de regresión: quiero la tendencia de cada actividad y de cada notebook entre ejecuciones, incluido el shuffle y el número de jobs de Spark. Revisa cómo lee y escribe cada notebook (carga completa o incremental) y cómo evolucionan las tablas que toca (ficheros, commits y checkpoints del _delta_log). ¿Qué crece y por qué?"

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| 10 ejecuciones de `pl_daily_sales` (R1..R10, la R6 fallida), sus 4 actividades, las sesiones Spark de `nb_01`..`nb_04`, las 18 tablas que escriben o leen (excluida `store_snapshot`) | `pl_store_snapshot` y la tabla `silver.store_snapshot` (otro escenario). Modelo semántico `sm_sales` (la actividad 4 solo lanza la petición de refresco). Capacidad (sin síntomas de cola, ver D3). |

**Hipótesis de partida:** (a) cargas completas que reprocesan todo el histórico acumulado; (b) fragmentación de tablas Delta (ficheros pequeños, deletion vectors, `_delta_log` sin checkpoint) que encarece lecturas y MERGE; (c) crecimiento del volumen diario de entrada; (d) cola/arranque de sesión o deriva de configuración.

**Recorrido:** Spark runs (duración por actividad y métricas de jobs/stages por sesión) → la celda del MERGE de clientes crece con shuffle casi nulo (E5), lo que apunta a coste de metadatos/ficheros y no a datos → Delta tables (listado de ficheros y lectura completa de los commits JSON, E6-E8) → Spark resources solo para confirmar la configuración de los environments (E10), que fija 2000 particiones de shuffle con AQE desactivado.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad | `353a0ed6-2bba-456c-bac7-009fc42e4b94` (SKU y región no consultados, no necesarios) | E3 |
| Runtime de Spark | 1.3 | E3, E10 |
| Environment / pool | `env_bronze`/`env_silver`: 8 cores, 56 g, 1-4 executores dinámicos. `env_gold`: pool y tamaño parametrizados, asignación dinámica desactivada | E10 |
| Configuración Spark relevante | `env_silver`: `spark.sql.shuffle.partitions=2000`, AQE y skewJoin desactivados, `autoBroadcastJoinThreshold=-1`. `nb_02` repite los mismos `spark.conf.set`. `env_bronze`: `optimizeWrite` y `autoCompact` desactivados. `nb_03`: AQE desactivado | E9, E10 |
| Permisos con los que se ejecutó | Usuario del tenant con acceso de lectura a API Fabric y a OneLake (todas las lecturas devolvieron datos) | E1-E8 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| pl_daily_sales | Pipeline | Orquestación | a1987c47-3861-40bc-a158-61eb02aa70e3 |
| nb_01_ingest_bronze | Notebook | Bronce | 3ad82227-2807-494c-a04b-539277f71ee4 |
| nb_02_bronze_to_silver | Notebook | Plata | 29d1d22c-7de4-4dc8-b9b7-b972129da393 |
| nb_03_silver_to_gold | Notebook | Oro | 212122f8-c8e5-47ff-8d67-c101eb77853c |
| nb_04_refresh_model | Notebook | Refresco del modelo | 599a7705-10b5-439e-92b0-2df8cf5d5b2b |
| lh_bronze / lh_silver / lh_gold | Lakehouse | Almacenamiento | ab14b76b-… / 0eec9e16-… / 23c33315-… |

## Evidencia

### Métricas clave

Ejecuciones R1..R10 (R6 falló en `Ingest bronze` con el error de esquema de `amount`; no avanzó la capa de plata ni oro).

**Duración por actividad y pipeline (segundos)** (E1, E2)

| Ejecución | R1 | R2 | R3 | R4 | R5 | R6 | R7 | R8 | R9 | R10 | Pendiente s/ejec. (r) |
|-----------|----|----|----|----|----|----|----|----|----|-----|----------------------|
| Pipeline | 1123 | 991 | 1161 | 1324 | 1143 | 66 (F) | 1250 | 1396 | 1228 | 1376 | +30,2 (0,74) |
| Ingest bronze | 234 | 218 | 187 | 212 | 203 | 51 (F) | 170 | 189 | 218 | 234 | -0,7 (-0,10) |
| Bronze to silver | 370 | 427 | 492 | 579 | 549 | - | 578 | 640 | 608 | 646 | +27,3 (0,92) |
| Silver to gold | 312 | 311 | 434 | 350 | 339 | - | 432 | 522 | 341 | 432 | +12,3 (0,55) |
| Refresh semantic model | 175 | 20 | 23 | 159 | 36 | - | 52 | 22 | 37 | 39 | sin tendencia |

Retraso entre `activityRunStart` y `runStartTime` de Spark: 3-4 s en todas las actividades salvo R4 `Ingest bronze` (43 s), y `durationInQueue` de 1 s (E2).

**Jobs, stages, tareas y shuffle por sesión Spark** (E4; stages sin los `SKIPPED`; GB = shuffle total de la sesión)

`nb_02_bronze_to_silver` (la que crece):

| Ejecución | R1 | R2 | R3 | R4 | R5 | R7 | R8 | R9 | R10 |
|-----------|----|----|----|----|----|----|----|----|-----|
| Jobs | 62 | 73 | 77 | 76 | 74 | 74 | 74 | 74 | 74 |
| Stages | 94 | 127 | 138 | 134 | 129 | 129 | 129 | 129 | 129 |
| Tareas | 39 570 | 48 636 | 59 450 | 57 786 | 49 945 | 50 499 | 50 853 | 51 238 | 51 645 |
| Shuffle read GB | 0,96 | 1,84 | 2,71 | 3,56 | 4,41 | 5,26 | 6,09 | 6,92 | 7,75 |
| Shuffle write GB | 0,68 | 1,31 | 1,95 | 2,56 | 3,16 | 3,77 | 4,36 | 4,96 | 5,55 |
| Tiempo de ejecutores (min) | 36,4 | 71,1 | 105,2 | 113,4 | 116,4 | 143,9 | 151,3 | 161,5 | 174,9 |

`nb_03_silver_to_gold`:

| Ejecución | R1 | R2 | R3 | R4 | R5 | R7 | R8 | R9 | R10 |
|-----------|----|----|----|----|----|----|----|----|-----|
| Jobs / stages | 52 / 76 | 53 / 88 | 53 / 88 | 53 / 87 | 53 / 87 | 53 / 87 | 53 / 87 | 53 / 87 | 54 / 88 |
| Tareas | 3137 | 3239 | 3356 | 3261 | 3363 | 3469 | 3569 | 3670 | 3743 |
| Shuffle read = write GB | 0,02 | 0,04 | 0,05 | 0,06 | 0,07 | 0,08 | 0,09 | 0,11 | 0,12 |
| Tiempo de ejecutores (min) | 13,9 | 17,8 | 22,0 | 24,8 | 30,2 | 32,0 | 33,8 | 41,7 | 44,1 |

`nb_01_ingest_bronze` (estable: 218-229 jobs, 217-226 stages, shuffle 0,12 GB constante; R6 fallida con 30 jobs): tareas 1611, 2370, 1600, 1612, 1624, (302), 1646, 1654, 1641, 2177; tiempo de ejecutores 4,8 → 9,5 min (R1 → R10) con duración de pared plana (E4).

`nb_04_refresh_model`: 5 jobs, 3 stages, 5 tareas y 0 GB de shuffle en R2, R3, R5, R7-R10. R1 y R4 devolvieron lista de jobs vacía (E4).

**Tiempo de pared por celda de `nb_02` (s / jobs / tareas / shuffle read)** (E4, agrupando jobs por `jobGroup` = nº de sentencia)

| Celda (sentencia) | R1 | R4 | R10 |
|-------------------|----|----|-----|
| 4: MERGE de `customers` | 138 / 13 / 10 251 / 0,01 GB | 343 / 19 / 27 169 / 0,02 GB | 376 / 17 / 19 734 / 0,04 GB |
| 5: `stores` y `products` (overwrite) | 43 / 16 / 4284 | 23 / 20 / 4534 | 18 / 20 / 4574 |
| 6: reconstrucción de `sales` | 78 / 16 / 20 820 / 0,95 GB | 118 / 18 / 21 663 / 3,54 GB | 160 / 18 / 22 897 / 7,70 GB |
| 7: `inventory_levels` | 41 / 8 / 4198 | 30 / 10 / 4403 | 29 / 10 / 4423 |

Serie completa de la celda 4: 138, 209, 284, 343, 317, 337, 365, 350, 376 s. Serie de la celda 6: 78, 82, 82, 118, 116, 131, 146, 152, 160 s (E4). Variación R1 → R10: +238 s (celda 4) y +82 s (celda 6) frente a -25 s y -12 s en las celdas 5 y 7; suma +283 s frente a +276 s de la actividad.

En R10, el stage 19 de `nb_02` (`first at … ipykernel … :15`, es decir el `.first()` de `SELECT COALESCE(MAX(source_run_seq),0) FROM customers`) usa 490 tareas y 30,0 min de ejecutor; otros dos stages del MERGE usan 25,2 y 10,9 min con 490 y 2000 tareas (E4).

**Patrón de lectura y escritura por notebook** (E8, código del repositorio `demo-setup/items/notebooks/`; la ejecución real coincide con el texto de las sentencias que aparece en las descripciones de job de E4)

| Notebook / escritura | Lee | Patrón | Evidencia en el código |
|----------------------|-----|--------|------------------------|
| nb_01 `sales_raw` | Genera `rows_per_day` filas sintéticas | Incremental, append de un día (1 M filas) con `repartition(400)` | `.repartition(WRITE_PARTITIONS).write…mode("append").saveAsTable("sales_raw")`; `WRITE_PARTITIONS = 400` |
| nb_01 `customer_changes` | Delta del CRM (7 % de clientes tras el primer día) | Incremental, append | `.write.mode("append").saveAsTable("customer_changes")` |
| nb_01 `inventory_events` | 30 almacenes × 200 filas | Incremental, append en bucle: 1 commit por almacén (30 por ejecución) | `for store_id in range(1, inventory_stores + 1): … .coalesce(1).write.mode("append")`; `delta.checkpointInterval = 1000` |
| nb_01 `stores_raw`, `products_raw`, `dim_*` iniciales | - | Una sola vez | `if not spark.catalog.tableExists(...)` |
| nb_02 `customers` | `customer_changes` con `run_seq > last_applied` | Incremental por MERGE, pero con 2000 particiones de shuffle y deletion vectors | `.merge(...)`, `spark.conf.set("spark.sql.shuffle.partitions","2000")`, `delta.enableDeletionVectors = true` |
| nb_02 `stores`, `products` | Tablas de referencia completas | Carga completa (overwrite), tamaño constante | `.write.mode("overwrite").saveAsTable("stores")` |
| nb_02 `sales` | Todo `bronze.sales_raw` | **Carga completa**: dedup por `sale_id` con ventana sobre todo el histórico, UDF y overwrite | comentario "rebuild the conformed table from the bronze history"; `row_number().over(Window.partitionBy("sale_id")…)`; `.write.mode("overwrite")` |
| nb_02 `inventory_levels` | Todo `bronze.inventory_events` | **Carga completa**: `groupBy` sobre todos los eventos y overwrite | `.groupBy("store_id","product_code").agg(…).write.mode("overwrite")` |
| nb_03 `fact_sales` | Todo `silver.sales` | **Carga completa** con overwrite | `fact_sales.write.mode("overwrite")…saveAsTable("fact_sales")` |
| nb_03 `dim_customer`, `dim_store`, `dim_product` | Todas las filas de plata | Carga completa con overwrite | `.write.mode("overwrite").option("overwriteSchema","true")` |
| nb_03 `daily_store_sales` | Todo `fact_sales` | **Carga completa**: agregación sobre todo el histórico | `.groupBy("sale_date","store_id").agg(…).write.mode("overwrite")` |
| nb_04 | - | Petición de refresco `full` del modelo, sin esperar el resultado | `fabric.refresh_dataset(dataset=…, refresh_type="full")` |

**Evolución de las tablas** (E6-E8; "activos" = ficheros vivos según el log; "físicos" = `.parquet` presentes en el directorio de la tabla; MB medio = tamaño activo / activos)

| Tabla | Commits (versiones) | Checkpoints | Ficheros activos (primera → última versión) | MB medio | Tamaño activo | Ficheros físicos | JSON del log (suma) |
|-------|---------------------|-------------|---------------------------------------------|----------|---------------|------------------|---------------------|
| bronze.sales_raw | 9 | 0 | 400 → 3600 (+400/día) | 0,239 | 95,7 → 861,5 MB (+95,7 MB/día) | 3600 | 4,87 MB |
| bronze.customer_changes | 10 | 0 | 8 → 80 (+8/día) | 0,084 | 4,0 → 6,7 MB | 80 | 0,07 MB |
| bronze.inventory_events | 271 | 0 | 1 → 270 (+30/día) | 0,005 | 1,3 MB | 270 | 0,28 MB |
| bronze.ctl_pipeline_runs | 11 | 1 (versión 10) | 1 → 10 | 0,0 | ~0 | 20 | 0,01 MB |
| silver.customers | 10 | 0 | 2000 → 5969 | 0,004 | 12,8 → 24,8 MB | 17 889 | **56,2 MB** (commit de 1,5 MB a 8,8 MB) |
| silver.inventory_levels | 9 | 0 | 1899 → 2000 | 0,003 | 5,5 → 6,6 MB | 17 896 | 13,3 MB |
| silver.sales | 9 | 0 | 64 → 64 | 10,69 | 84,3 → 684,3 MB (+~75 MB/día) | 576 | 1,09 MB |
| silver.stores / products | 9 | 0 | 8 | 0,01 | constante | 72 | ~0,05 MB |
| gold.fact_sales | 9 | 0 | 34 → 64 | 7,77 | 61,5 → 497,3 MB | 534 | 0,74 MB |
| gold.dim_customer | 9 | 0 | 63 → 549 (+~60/día) | 0,011 | 4,8 → 6,0 MB | 2772 | 2,35 MB |
| gold.daily_store_sales | 9 | 0 | 44 → 179 | 0,003 | 0,1 → 0,6 MB | 1141 | 0,86 MB |
| gold.dim_store / dim_product | 9 | 0 | 8 | 0,0-0,01 | constante | 72 | ~0,06 MB |
| gold.dim_date / promotions, bronze.stores_raw / products_raw | 1 | 0 | 1-8 | - | constante | 1-8 | ~0 |

Detalle del MERGE sobre `silver.customers` (E8): las versiones 2-9 añaden entre 3982 y 7601 ficheros y quitan entre 1999 y 5691; en la versión 9, 5445 de 7424 `add` y 3984 de 5535 `remove` llevan deletion vector. La mediana del tamaño de fichero añadido es de 4,2 KB. Filas modificadas por MERGE: ~9,7 k (v9) sobre 200 k clientes, es decir, el MERGE toca ~5,4 k ficheros para cambiar menos del 5 % de las filas.

Ningún `TableMaintenance` registrado en los tres lakehouses (E9). Los ficheros físicos de tablas con overwrite (silver.sales 576 frente a 64 activos; gold.fact_sales 534 frente a 64; 3494 MB frente a 684 MB y 2555 MB frente a 497 MB) revelan versiones antiguas sin `VACUUM` (E6, E7).

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces/{ws}/items/{pipeline}/jobs/instances` | 10 instancias (21:16 → 00:22 UTC), 9 `Completed` y 1 `Failed` (R6, `errorCode 2451`), sin `continuationToken` |
| E2 | REST | `POST /v1/workspaces/{ws}/datapipelines/pipelineruns/{id}/queryactivityruns` (10 llamadas) | Duración, `sessionId`, `runStartTime` y errores de cada actividad; datos disponibles ~8 h después |
| E3 | REST | `GET /v1/workspaces/{ws}/notebooks/{nb}/livySessions` (4 notebooks) | 10, 9, 9 y 9 sesiones con `sparkApplicationId`, `runtimeVersion=1.3`, `capacityId`, `queuedDuration` |
| E4 | REST | `GET …/notebooks/{nb}/livySessions/{livy}/applications/{app}/jobs` y `/stages` (37 sesiones × 2) | Jobs, stages, tareas, shuffle, spill, `executorRunTime`, `jobGroup`. Jobs vacíos solo en `nb_04` R1 y R4 |
| E5 | Cálculo | Agregación local de E4 por `jobGroup` (celda) y por stage | Tablas de métricas clave anteriores |
| E6 | REST OneLake | `GET https://onelake.dfs.fabric.microsoft.com/{ws}?resource=filesystem&directory={lh}/Tables[/{t}]&recursive=true` (3 lakehouses, 19 tablas) | Nº y tamaño de `.parquet` y de ficheros `_delta_log` por tabla |
| E7 | REST OneLake | `GET …/{lh}/Tables/{t}/_delta_log/{v}.json` (todos los commits de 18 tablas, ~690 ficheros) | Operación, `add`/`remove`, tamaño, deletion vectors, métricas de MERGE y tamaño de cada commit; listado de checkpoints y `_last_checkpoint` |
| E8 | Fichero local | Lectura de `demo-setup/items/notebooks/nb_0*.py` y `pipelines/pl_daily_sales.json` | Código de carga de cada notebook (tabla de patrones) |
| E9 | REST | `GET /v1/workspaces/{ws}/items/{lh}/jobs/instances` (3 lakehouses) | 0 instancias (ningún `TableMaintenance`) |
| E10 | Fichero local | `demo-setup/items/environments/env_*.yml` | Configuración efectiva de los environments |
| E11 | REST | `POST /v1/workspaces/{ws}/notebooks/{nb}/getDefinition` (nb_01..nb_03) | Respuesta vacía (202 de operación larga sin seguir), definición desplegada no decodificada |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | El MERGE de clientes de `nb_02` es la celda que más crece (138 → 376 s) por fragmentación de `silver.customers` y su `_delta_log` sin checkpoint | Media | Media | E4, E5, E7, E8, E10 |
| H2 | `nb_02` reconstruye `silver.sales` completa cada día: shuffle de 0,96 → 7,75 GB por sesión | Media | Alta | E4, E5, E8 |
| H3 | `nb_03` recalcula todo el oro (fact, dims, mart) y `dim_customer` hereda la fragmentación de clientes (63 → 549 ficheros) | Baja | Alta | E4, E7, E8 |
| H4 | Escrituras que generan ficheros diminutos y logs largos sin checkpoint (`sales_raw`, `inventory_events`, `inventory_levels`, `daily_store_sales`) | Baja | Alta | E6, E7, E8 |
| H5 | No hay mantenimiento Delta: los ficheros de versiones antiguas se acumulan | Baja | Alta | E6, E7, E9 |

### H1 · MERGE de clientes sobre una tabla fragmentada (principal motor del aumento)

- **Qué ocurre:** la celda 4 de `nb_02` pasa de 138 s (R1) a 376 s (R10) con shuffle prácticamente nulo (0,01 → 0,04 GB). Aporta +238 s de los +276 s que crece la actividad. En R10 el `.first()` de `MAX(source_run_seq)` consume 30,0 min de ejecutor en 490 tareas. `silver.customers` pasa de 2000 a 5969 ficheros activos de 4 KB de media, y el JSON de su log suma 56,2 MB sin ningún checkpoint (commits de 1,5 MB a 8,8 MB).
- **Por qué:** el código es incremental en cuanto a datos (`run_seq > last_applied`), pero los ~14 k cambios diarios se reparten al azar entre 200 k clientes y la tabla se escribe con 2000 particiones de shuffle (`env_silver` y `nb_02`, AQE desactivado). Cada MERGE vuelve a emitir entre 4,6 k y 7,6 k ficheros y deja un deletion vector en la mayoría (v9: 5445 `add` con DV), por lo que cada ejecución lee más ficheros y reconstruye un log mayor. La tabla nunca llega al décimo commit para su primer checkpoint porque solo hay 10 versiones. La regla de la skill indica que se debe revisar la fragmentación antes de culpar al código (`spark-runs.md` § 5, trampa "Regression needs a baseline"; `performance-patterns.md` § Small File Problem, umbral 32 MB de tamaño medio).
- **Impacto:** +238 s por ejecución en 9 días y creciente. La confianza es Media porque no se aisló el tiempo de lectura de metadatos frente al de reescritura (no se midió con `DESCRIBE DETAIL` ni con el plan SQL).

### H2 · Reconstrucción completa de `silver.sales`

- **Qué ocurre:** la celda 6 pasa de 78 s a 160 s y el shuffle read de la sesión de 0,96 a 7,75 GB (+0,84 GB por día, lineal). En R10 hay un stage con 1,71 GB de shuffle write, por encima del umbral de 1 GB por stage (`performance-patterns.md` § Detection Thresholds, MEDIUM). El tiempo de ejecutores de `nb_02` pasa de 36,4 a 174,9 min.
- **Por qué:** `nb_02` lee todo `bronze.sales_raw` (+1 M filas/día, +95,7 MB/día), aplica la ventana de deduplicación por `sale_id` y reescribe `silver.sales` con overwrite (E8). El trabajo es proporcional al histórico acumulado. No hay spill (`diskBytesSpilled` = 0 en todos los stages) ni sesgo medido (D2).
- **Impacto:** +82 s en la celda hoy; el coste de pared crece por debajo del de ejecutores porque la sesión absorbe parte con paralelismo (máx. 4 ejecutores).

### H3 · Oro: recálculo total

- **Qué ocurre:** `nb_03` pasa de 312 a 432 s con pendiente de +12 s/ejecución y correlación débil (r = 0,55), mientras el tiempo de ejecutores sube de 13,9 a 44,1 min y las tareas de 3137 a 3743. La celda `dim_customer` sube de 26 a 66 s y sus tareas de 1104 a 2064.
- **Por qué:** `fact_sales`, las tres dims y `daily_store_sales` se sobrescriben con todo el histórico (E8). `dim_customer` se escribe con un fichero por partición de lectura, así que hereda los ~6 k ficheros de `silver.customers` (63 → 549 activos). `daily_store_sales` genera 44 → 179 ficheros de 3 KB por las 200 particiones de shuffle con AQE desactivado.
- **Impacto:** moderado, ruido alto de pared entre ejecuciones (p. ej. 522 s en R8 y 341 s en R9).

### H4 y H5 (Baja)

- `bronze.sales_raw` suma 400 ficheros de 0,24 MB por día (`WRITE_PARTITIONS = 400` para ~96 MB/día). `inventory_events` genera 30 commits por ejecución (271 versiones, `checkpointInterval=1000` impide el checkpoint: la tabla se lee reproduciendo 271 JSON). `inventory_levels` se reescribe con 2000 ficheros de 3 KB por ejecución y suma 13,3 MB de log. Hoy su efecto en pared es pequeño (celda 7 de `nb_02`: 41 → 29 s), pero crece lineal.
- Sin mantenimiento: ficheros físicos 5-9 veces los activos en las tablas de overwrite (E6, E7, E9). Afecta a almacenamiento y listados, no a la duración medida.

## Recomendaciones

Ordenadas por impacto/esfuerzo.

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Reducir las particiones de shuffle del MERGE de clientes, compactar y purgar deletion vectors de `silver.customers` | H1 | Alto | Bajo | Bajo | Sí |
| R2 | Pasar `silver.sales` (y `fact_sales`) a carga incremental por `run_seq` | H2, H3 | Alto | Medio | Medio | Sí |
| R3 | Escribir `inventory_events` en un solo commit por ejecución y quitar `checkpointInterval=1000` | H4 | Medio | Bajo | Bajo | Sí |
| R4 | Ajustar `WRITE_PARTITIONS` y activar `optimizeWrite` en bronce | H4 | Medio | Bajo | Bajo | Sí |
| R5 | Mantenimiento programado `OPTIMIZE` + `VACUUM` de las 18 tablas | H1, H4, H5 | Medio | Bajo | Medio | Sí |

### R1 · MERGE de clientes con menos ficheros

- **Cambio propuesto:**

  ```python
  # nb_02, antes del MERGE de customers
  spark.conf.set("spark.sql.shuffle.partitions", "16")      # ~14 k filas de cambios
  spark.conf.set("spark.sql.adaptive.enabled", "true")
  # one-off por un humano o FabricAdmin
  # OPTIMIZE silver.customers;  REORG TABLE silver.customers APPLY (PURGE);
  ```

- **Impacto esperado:** volver a un orden de cientos de ficheros activos y a un log de pocos MB; la celda 4 debería acercarse a los 138 s de R1. Estimación basada en que R1 tenía 2000 ficheros y 1,5 MB de log.
- **Cómo validarlo:** repetir este análisis: wall de la celda 4, ficheros activos y tamaño del commit JSON de `silver.customers`, y presencia de `*.checkpoint.parquet`.
- **Reversión:** restaurar los `spark.conf.set` originales; `OPTIMIZE` no se revierte pero no cambia datos.
- **Requiere confirmación:** Sí, cambia código y reescribe una tabla.

### R2 · `silver.sales` incremental

- **Cambio propuesto:** en lugar de `groupBy` histórico y overwrite, leer solo `lh_bronze.sales_raw` con `run_seq = <última>` (y las correcciones tardías que se quieran admitir) y hacer `MERGE` por `sale_id` sobre `silver.sales`; derivar `fact_sales` y `daily_store_sales` solo de las particiones del día.
- **Impacto esperado:** el shuffle por ejecución pasa de crecer 0,84 GB/día a ser constante (~1 M filas/día); se elimina la pendiente de la celda 6 (+82 s en 9 días).
- **Cómo validarlo:** shuffle read de `nb_02` y de `nb_03` estable entre ejecuciones; duración de las celdas 6 y de oro sin pendiente.
- **Reversión:** volver al overwrite actual.
- **Requiere confirmación:** Sí (cambia semántica de carga y datos de plata/oro).

### R3 · `inventory_events` en un commit

- **Cambio propuesto:** construir los 30 DataFrames con `unionByName` y escribir una vez; eliminar `'delta.checkpointInterval' = '1000'` (valor por defecto 10).
- **Impacto esperado:** de 30 a 1 commit diario; checkpoints automáticos; menos jobs en `nb_01` (181 → ~6 en la celda).
- **Cómo validarlo:** nº de versiones y checkpoints de `inventory_events`; jobs de `nb_01`.
- **Reversión:** restaurar el bucle y la propiedad.
- **Requiere confirmación:** Sí.

### R4 · Ficheros de bronce

- **Cambio propuesto:** `WRITE_PARTITIONS` ≈ 4-8 (~96 MB/día) o `spark.databricks.delta.optimizeWrite.enabled=true` en `env_bronze`; `OPTIMIZE` puntual de `sales_raw`.
- **Impacto esperado:** de +400 ficheros/día a pocos ficheros de decenas de MB.
- **Cómo validarlo:** ficheros activos de `sales_raw` y tareas de escaneo en la celda 6 de `nb_02`.
- **Reversión:** revertir la configuración.
- **Requiere confirmación:** Sí.

### R5 · Mantenimiento Delta

- **Cambio propuesto:** `TableMaintenance` programado (OPTIMIZE y VACUUM con la retención por defecto de 7 días) sobre las tablas con overwrite y las que acumulan ficheros.
- **Impacto esperado:** ficheros físicos ≈ activos (p. ej. silver.sales 576 → ~64).
- **Cómo validarlo:** recuento físico/activo con el mismo método de E6-E7.
- **Reversión:** `VACUUM` es irreversible para versiones eliminadas; conviene validar la retención antes.
- **Requiere confirmación:** Sí, escribe en las tablas y la ejecuta un humano o `FabricAdmin`.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Crece el volumen diario de entrada | E4, E6 | `outputRecords` de `nb_01` ≈ 1,02 M cada día y 95,7 MB de `sales_raw` por commit; lo que crece es lo acumulado |
| D2 | Spill o sesgo de datos | E4 | `diskBytesSpilled` = 0 en todos los stages. El sesgo (`max/median` de tiempo de tarea) no se midió con `taskSummary`, queda sin verificar |
| D3 | Cola o arranque de sesión | E2 | 3-4 s entre `activityRunStart` y `runStartTime`, `durationInQueue` 1 s |
| D4 | `Ingest bronze` crece | E1, E2, E4 | Pendiente -0,7 s/ejecución, r = -0,10, jobs y shuffle constantes |
| D5 | `Refresh semantic model` crece | E2, E4 | 20-52 s sin tendencia salvo dos valores de arranque (175 s y 159 s) en R1 y R4; 5 jobs y 0 GB de shuffle |
| D6 | Regresión detectable por umbral | E1, E2 | Con la regla de `job-diagnostics.md` § Detect Regressions (>2× la mediana de las 5 anteriores) no se dispara: `Bronze to silver` R10 = 646 s frente a mediana 579 s |

## Siguientes pasos

- [ ] Decidir R1 y R2 y aplicarlos en un entorno de prueba — responsable: ingeniería de datos · relacionado con: R1, R2
- [ ] Aplicar R3-R5 — responsable: ingeniería de datos / `FabricAdmin` · relacionado con: R3, R4, R5
- [ ] Repetir el análisis tras aplicar R1-R2 para validar el impacto
- [ ] Corregir el fallo de esquema de `amount` de R6 (`schema_drift_every`): el día 6 consumió `run_seq` en `ctl_pipeline_runs` y `customer_changes` sin escribir `sales_raw` (E7); fuera de este análisis de rendimiento

## Notas

### Limitaciones

- Solo 10 ejecuciones disponibles en la API. El CSV local `demo-setup/.state/DataSaturday-history.csv` registra otro lote anterior (13:02-15:20 hora local del 29/10) que ya no aparece en E1; no se usó como evidencia.
- Los datos de stages y jobs siguen disponibles ~8 h después de la ejecución, más de lo que asume la skill ("minutos a horas"); se recomienda lanzar el análisis cuanto antes.
- La atribución por celda usa el `jobGroup` (nº de sentencia) y el texto de la descripción de los jobs. La cadena `Delta:` de jobs auxiliares puede agruparse en la sentencia de origen.
- Los ficheros físicos incluyen todas las versiones sin `VACUUM`; "activos" se calculó a partir del log (sin DV aplicados).

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| `DESCRIBE DETAIL`, `DESCRIBE HISTORY` y plan `EXPLAIN` vía Livy | No hay aprobación previa del usuario (Tier B) y no era necesario: los ficheros, commits y checkpoints se leyeron directamente de OneLake | Ninguno en las cifras de ficheros. Baja la confianza de H1 (no se separó lectura de metadatos y reescritura) |
| Definición desplegada de los notebooks (`getDefinition`) | La llamada devolvió 202 sin cuerpo (operación larga no seguida) | Se usó el código del repositorio (E8), coherente con el texto de las sentencias en E4 y con los 2000 tasks por stage de shuffle |
| Jobs de `nb_04` en R1 y R4 | La API devolvió lista vacía | Sin efecto: D5 se apoya en 7 ejecuciones |
| Sesgo de tareas (`taskSummary`) | No se consultó por stage | D2 solo descarta spill |
| `sys.sp_get_table_health_metrics` | No ejecutado; el análisis de OneLake cubre el mismo objetivo | Ninguno |
| Otra información de `pl_store_snapshot` | Fuera de alcance | `silver.store_snapshot` tiene 96 ficheros y ningún commit en el log (residuo de escrituras fallidas): no se analiza aquí |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Retención de `queryActivityRuns` | `pipeline-diagnosis.md` Step P2 la presenta como la más larga; la tabla de retención de `automated-diagnostic-workflow.md` la sitúa en ~1 h | No verificada con Microsoft Learn en este análisis | En este caso ambos orígenes seguían disponibles ~8 h después de la ejecución; no se infiere nada más |
| Retención de jobs/stages | "Minutos a horas" | Medido: ≥ 8 h | Se usó el dato medido |

## Anexo

### Consultas completas

Las agregaciones de E4 y E5 se hicieron en local sobre los JSON devueltos: para cada sesión se sumaron `shuffleReadBytes`, `shuffleWriteBytes`, `diskBytesSpilled`, `inputBytes`, `outputBytes` y `executorRunTime` de los stages con `status != SKIPPED`, y se agruparon los jobs por `jobGroup`; el tiempo de pared de cada celda es `max(completionTime) - min(submissionTime)` de sus jobs.

### Configuración efectiva

`env_silver`: `driver/executor_cores=8`, memoria 56 g, asignación dinámica 1-4, `spark.sql.adaptive.enabled=false`, `spark.sql.adaptive.skewJoin.enabled=false`, `spark.sql.autoBroadcastJoinThreshold=-1`, `spark.sql.shuffle.partitions=2000`, runtime 1.3. `env_bronze`: `resourceProfile=readHeavyForPBI`, `vorder=true`, `optimizeWrite=false`, `autoCompact=false`. `env_gold`: `resourceProfile=writeHeavy`, `vorder=false`, `optimizeWrite=false`, asignación dinámica desactivada (E10).
