# nb_02_bronze_to_silver: data skew, time skew, shuffle y estrategia de joins frente a la configuración efectiva

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-10-31 |
| **Áreas** | Spark runs → Delta tables → Spark runs |
| **Ámbito** | workspace `FabricPerfLab` · notebook `nb_02_bronze_to_silver` (actividad "Bronze to silver" de `pl_daily_sales`) · tablas `lh_bronze.sales_raw`, `lh_silver.customers`, `lh_silver.stores`, `lh_silver.sales` |
| **Ventana analizada** | 2026-10-30 17:15 → 2026-10-31 05:17 UTC (detalle de stages: ejecución 2026-10-31 05:05 → 05:16 UTC) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli, sqldw-cli, search-consumption-cli |
| **Modo** | Lectura + diagnóstico activo (Livy) |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** si `nb_02_bronze_to_silver` tiene data skew o time skew, qué stages mueven más shuffle, qué estrategia usa cada join frente a la configuración Spark efectiva, y qué stages se repiten entre jobs.
- **Conclusión:** sí hay **data skew** (H1): `store_id = 1` concentra 5.999.852 de las 10.000.000 filas de ventas, y una sola tarea lee 652 MB y 6 M de registros en el SortMergeJoin con `stores` (stages 127/133/139, entre 238× y 535× la duración mediana). También hay **time skew** sin data skew en el stage 140 (H3): 3,8× en duración con solo 1,3× en registros, causado por la UDF Python `classify_note`, que es muy cara para las ventas de 22 h en adelante. Los 7 joins del plan son SortMergeJoin y ninguno BroadcastHashJoin (H2). La configuración de arranque dice otra cosa: umbral de broadcast de 25 MB y AQE por defecto. Durante la sesión el código la cambia: AQE apagado en 104 de 106 ejecuciones SQL, 2000 particiones de shuffle y broadcast desactivado. Por eso `stores` (18.209 bytes, 50 filas) no se difunde y AQE no puede partir la partición sesgada.
- **Impacto:** el skew y la UDF cuestan unos 51 s de muro (stages 127+133+139+140). El mayor coste está en otra parte: el MERGE de `customers` ocupa 404 s de los 671 s del notebook (H4). La tabla tiene 19.433 ficheros de unos 4,4 KB, un 42,9 % de filas borradas por deletion vectors y ningún checkpoint, y cada MERGE añade unos 2000 ficheros por `shuffle.partitions = 2000`. El notebook pasó de 269 s a 671 s en 10 ejecuciones.
- **Primera acción:** R1, quitar los overrides de sesión (AQE apagado, 2000 particiones, broadcast desactivado) y difundir `stores` y `customers` de forma explícita. Esto elimina el shuffle por `store_id`, y con él el skew, y deja de generar unos 2000 ficheros por MERGE. Después, R2: compactar `customers` y purgar sus deletion vectors.

## Alcance

**Pregunta original:** "¿Hay data skew o time skew en nb_02_bronze_to_silver? ¿Qué stages tienen el shuffle más pesado? Para cada join indica la estrategia del plan (broadcast o sort-merge) y compárala con la configuración Spark efectiva de la sesión. Por stage: registros y bytes de la tarea máxima frente a la mediana, spill, número de tareas y stages que se repiten en varios jobs."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Última ejecución completada del notebook (job instance `4cfd2b3f…`, Livy `88afdede…`, app `application_1793422990874_0001`), lanzada por la ejecución programada de `pl_daily_sales` `524c4c37…` (2026-10-31 05:00 UTC). Como línea base, las ejecuciones Livy `801336fb…` (2026-10-30 19:55) y `583587ae…` (2026-10-30 17:15), y el histórico de las 10 job instances. | Los demás notebooks del pipeline (`nb_01`, `nb_03`, `nb_04`), que no se pidieron. Las celdas 1-3 del notebook: no lanzan jobs Spark y no se decodificó la definición del notebook (`operations.md` § Must/Prefer/Avoid). Event log completo (Tier 2), porque `copyEventLog` escribe en OneLake. |

**Hipótesis de partida:** (a) data skew en una clave de join o de ventana, por la pregunta y por el Advisor; (b) time skew por un coste por fila no uniforme (UDF); (c) joins sort-merge en dimensiones pequeñas por una configuración de broadcast o AQE alterada; (d) recomputación de stages entre jobs por acciones repetidas sin `cache`.

**Recorrido:** Spark runs (Advisor, jobs, stages, `taskSummary`, planes SQL, entorno) → Delta tables: el Advisor (E5) y los 549-608 tasks de unos 80 KB que tardan unos 3,5 s cada uno al leer `customers` (E8) apuntaban a fragmentación; se ejecutó `sp_get_table_health_metrics` y `DESCRIBE DETAIL/HISTORY` (E15, E16, E19, E22) → vuelta a Spark runs para cerrar la configuración efectiva (E11, E20, E21) y la causa del time skew (E18).

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad (SKU · región) | capacidad `353a0ed6-…` (SKU no consultado) | E1 |
| Runtime de Spark | Fabric Runtime 1.3, Java 11.0.27, Scala 2.12.18 | E4, E11 |
| Environment / pool | Medium (8 cores / 56 GB driver y executor), dynamic allocation 1-4 executors (máximo 32 cores usados), no high-concurrency | E4, E11, E13 |
| Configuración Spark relevante (arranque) | `spark.sql.autoBroadcastJoinThreshold=26214400`; `spark.native.enabled=false`; sin `spark.sql.adaptive.*` ni `spark.sql.shuffle.partitions` en `sparkProperties` | E11 |
| Configuración Spark relevante (efectiva en los planes) | AQE desactivado, `hashpartitioning(…, 2000)`, ningún broadcast ni siquiera con `LocalTableScan` | E9, E10 |
| Permisos con los que se ejecutó | Usuario delegado con acceso al workspace (lecturas de monitorización, SQL endpoint y Livy sin errores de permiso) | E1-E22 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| `nb_02_bronze_to_silver` | Notebook | Bronze → Silver | `4205418f-cee2-4a3d-9390-328618160264` |
| `pl_daily_sales` | DataPipeline | Orquestación (actividad "Bronze to silver") | `bd706b1d-499f-4a0d-bb22-222312944ca1` |
| `lh_bronze` | Lakehouse (SQL endpoint `03c34de1-…`) | Origen `sales_raw` | `53249a1b-e8a9-4270-9cb4-0f2ce3b10feb` |
| `lh_silver` | Lakehouse (SQL endpoint `bd96d99c-…`) | Destino `customers`, `stores`, `sales`, `inventory_levels` | `b01f7911-28fd-4dc2-ac51-1d19ed841238` |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Duración del notebook (últimas 10 ejecuciones) | 269 → 435 → 458 → 506 → 499 → 568 → 620 → 606 → 620 → 671 s | Regresión: `job-diagnostics.md` § Job Instance History | E2 |
| Duración por sentencia (última ejecución) | st. 4 (MERGE `customers`) 404 s · st. 6 (ventas) 173 s · st. 7 (inventario) 32 s · st. 5 (referencias) 17 s | — | E6 |
| Skew de lectura de la tarea máxima (stages 127/133/139) | 652,17 MB y 5.999.852 registros en 1 tarea; mediana 0 registros (127, 139) y 81.628 (133) | `maxExecutorRunTime / median` > 3× = HIGH (`diagnostic-workflow.md` § Severity Thresholds) | E5, E8 |
| Duración de la tarea máxima frente a la mediana (127 / 133 / 139) | 5,48 s / 0,02 s (238×) · 5,15 / 0,40 (13×) · 12,85 / 0,02 (535×) | > 3× HIGH (ídem) | E8 |
| Distribución de `store_id` | `store_id=1`: 5.999.852 filas de 10.000.000 (60 %); el siguiente, 82.180; 50 tiendas, 0 nulos | — | E17 |
| Time skew del stage 140 (UDF) | duración 23,94 / 6,25 s (3,8×); registros 200.637 / 154.847 (1,3×) | > 3× HIGH (ídem) | E8 |
| Filas que activan la rama cara de `classify_note` | 833.639 filas con hora ≥ 22, de ellas 250.819 con `notes` | — | E7, E18 |
| Shuffle write por stage > 1 GB | 124: 1.785,7 MB · 122: 1.232,9 MB · 139: 1.186,8 MB · 125: 1.158,7 MB | > 1 GB = MEDIUM (`diagnostic-workflow.md` § Severity Thresholds) | E7 |
| Shuffle total de la aplicación | write 5.862,7 MB · read 8.190,1 MB | — | E7 |
| Spill (memoria y disco) | 0 en los 137 stages ejecutados | `diskBytesSpilled` > 0 = MEDIUM (ídem) | E7, E8 |
| Joins del plan físico | 7 SortMergeJoin, 0 BroadcastHashJoin | — | E9 |
| Ejecuciones SQL con `AdaptiveSparkPlan` | 2 de 106 (las de sistema 5 y 6, antes de la sentencia 4) | — | E10 |
| Tamaño de `stores` | 50 filas, 8 ficheros, 18.209 bytes | Umbral de arranque de 25 MB (E11) | E16, E17 |
| `customers` (salud) | 19.433 ficheros, 85.694.861 bytes (unos 4,4 KB/fichero, unas 15 filas/fichero), 127.225 de 296.452 filas borradas (42,9 %), 13.120 deletion vectors, sin checkpoint (versión 10) | Anomalía 2 "Too many deleted rows detected" (`lakehouse-health.md` § Health procedure) | E15 |
| `sales_raw` (salud) | 4.000 ficheros, 957.198.969 bytes (unos 239 KB/fichero) | Anomalía 3 "Too many small files detected" (ídem) | E15 |
| MERGE de `customers` (historial) | unos 1979-2000 ficheros añadidos por MERGE; `executionTimeMs` 80.785 → 195.852; `scanTimeMs` 16.613 → 140.991 (versiones 1 → 10) | — | E19 |
| Stages de 2000 tareas | 19 stages, 38.000 de 42.484 tareas; 14 de ellos leen menos de 10 MB de shuffle | "Too Many Small Partitions" (`performance-patterns.md` § Anti-Patterns) | E7 |
| Eficiencia de cores / tiempo ocioso | `coreEfficiency` 0,77 · idle 81 s de 669 s (12 %) | < 0,3 HIGH · > 40 % MEDIUM (ídem): no se supera | E13 |
| Espera de arranque Spark en el pipeline | actividad 05:05:34.68 → `runStartTime` 05:05:39.22 (unos 4,5 s) | `pipeline-diagnosis.md` Step P4 | E14 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces` · `GET /v1/workspaces/{FabricPerfLab}/items` | Notebook `nb_02_bronze_to_silver` encontrado solo en `FabricPerfLab` (`23ca4a73-…`), junto a `lh_bronze`, `lh_silver`, `pl_daily_sales` y `env_*` |
| E2 | REST | `GET /v1/workspaces/{ws}/items/{nb02}/jobs/instances` · `GET …/items/{pl_daily_sales}/jobs/instances` | 10 instancias `PipelineRunNotebook` Completed (2026-10-30 17:15 → 2026-10-31 05:05), duraciones de 269 s a 671 s; última ejecución de pipeline `524c4c37…` Scheduled, Completed |
| E3 | REST | `GET /v1/workspaces/{ws}/notebooks/{nb02}/livySessions` | 10 sesiones Succeeded, runtime 1.3; última `88afdede…` / `application_1793422990874_0001`, 670 s |
| E4 | REST | `GET …/notebooks/{nb02}/livySessions/88afdede…` | driver y executor 8 cores / 56 GB, `numExecutors` 1 (inicial), `isHighConcurrency=false`, `queuedDuration` 0 s |
| E5 | REST | `GET …/applications/{app}/advice` | 9 avisos: DataSkew `warn` en stages 127, 133 y 139 (max 652,17 MB frente a una media de 0,58 / 24,14 / 0,58 MB); small files `info` en `lh_silver.customers` (exec 9, 22, 25), `lh_bronze.sales_raw` (exec 71, 81) y `lh_bronze.inventory_events` (exec 98) |
| E6 | REST | `GET …/applications/{app}/jobs` | 79 jobs, 0 tareas fallidas; grupos 4 (404 s), 5 (17 s), 6 (173 s), 7 (32 s); las descripciones de job group incluyen el código de las sentencias 4-7 |
| E7 | REST | `GET …/applications/{app}/stages` | 167 stages (137 COMPLETE, 30 SKIPPED); shuffle write total 5.862,7 MB, read 8.190,1 MB; spill 0 |
| E8 | REST | `GET …/applications/{app}/stages/{id}/0/taskSummary?quantiles=0.25,0.5,0.75,0.95,1.0` para 20 stages (19, 29, 31, 33, 34, 35, 44, 45, 47, 103, 104, 122, 123, 124, 125, 127, 133, 139, 140, 159) | Cuantiles de duración, run time, registros, bytes, spill y GC por stage (tabla del Anexo) |
| E9 | REST | `GET …/applications/{app}/sql?offset=0&length=500` | 106 ejecuciones SQL; SortMergeJoin en exec 22 (×2), 25, 28, 29 y 81 (×2); ningún BroadcastHashJoin; exec 81 con `BatchEvalPython classify_note` y `rangepartitioning(sale_ts, 64)` |
| E10 | REST | Ídem E9 (análisis de raíz del plan y particionado) | `AdaptiveSparkPlan` solo en exec 5 y 6 (sistema); todas las `hashpartitioning` usan 2000 particiones; SMJ incluso entre dos `LocalTableScan` (exec 29) |
| E11 | REST | `GET …/applications/{app}/environment` | `sparkProperties` de arranque: `autoBroadcastJoinThreshold=26214400`, `spark.native.enabled=false`, `dynamicAllocation` 1-4, sin claves `spark.sql.adaptive.*` ni `spark.sql.shuffle.partitions` |
| E12 | REST | `GET …/applications/{app}/allexecutors` | 5 executors de 8 cores (el 1 se retira a las 05:08:54; el 2 entra a las 05:07:26, el 3 a las 05:08:16, el 4 y el 5 a las 05:10:35-37); GC total 106 s |
| E13 | REST | `GET …/applications/{app}/resourceUsage` | `coreEfficiency` 0,769, `idleTime` 81.142 ms de 669.095 ms, máximo de 32 cores asignados, `capacityExceeded=false` |
| E14 | REST | `POST /v1/workspaces/{ws}/datapipelines/pipelineruns/524c4c37…/queryactivityruns` (consulta de lectura) | "Bronze to silver" Succeeded, 700.564 ms, sesión `88afdede…`, `runStartTime` 05:05:39.22 |
| E15 | SQL | `EXEC sys.sp_get_table_health_metrics @table_name = 'dbo.customers'` (lh_silver) · ídem `'dbo.sales_raw'` (lh_bronze) | customers: anomalía 2 "Too many deleted rows detected. Query performance may degrade.", 19.433 ficheros, 13.120 DV, 127.225 de 296.452 filas borradas, 15.977 ficheros de 1-9 filas, todos de 1-16 KiB, sin `CheckpointVersion`. sales_raw: anomalía 3 "Too many small files detected. Query performance may degrade.", 4.000 ficheros de 16-256 KiB y 1K-10K filas |
| E16 | Livy | `DESCRIBE DETAIL` de `lh_silver.stores`, `lh_silver.customers`, `lh_bronze.sales_raw`, `lh_silver.sales` | stores 8 ficheros / 18.209 B; customers 19.433 / 85.694.861 B (`delta.enableDeletionVectors=true`); sales_raw 4.000 / 957.198.969 B; sales 64 / 756.888.497 B |
| E17 | Livy | `SELECT store_id, COUNT(*) … GROUP BY store_id ORDER BY n DESC LIMIT 5` · `SELECT COUNT(*), COUNT(store_id), COUNT(DISTINCT store_id) FROM lh_bronze.sales_raw` · `SELECT COUNT(*) FROM lh_silver.stores` | store 1: 5.999.852; stores 26, 11, 47 y 13: unas 82.100 cada una; 10.000.000 filas, 0 nulos, 50 tiendas; `stores` 50 filas |
| E18 | Livy | `SELECT CASE WHEN hour(sale_ts) >= 22 … COUNT(*), COUNT(notes), AVG(length(notes)) FROM lh_bronze.sales_raw GROUP BY 1` | ≥ 22 h: 833.639 filas, 250.819 con notas; < 22 h: 9.166.361 filas, 2.750.404 con notas; longitud media 91 en ambas franjas |
| E19 | Livy | `DESCRIBE HISTORY lh_silver.customers` | v0 CREATE TABLE (2026-10-30 17:15:56); v1-v10 MERGE con `numTargetFilesAdded` entre 1979 y 2000, `numTargetDeletionVectorsAdded` de 0 a 5902, `executionTimeMs` de 80.785 a 195.852 |
| E20 | Livy | `spark.conf.get(<clave>, None)` para 11 claves | Fijadas en la sesión de diagnóstico: solo `autoBroadcastJoinThreshold=26214400` y `spark.native.enabled=false`; el resto sin fijar (`None`); `spark.version` 4.1.1.5.5… (la primera variante con valor por defecto `"unset"` falló con `INVALID_CONF_VALUE.TYPE_MISMATCH`) |
| E21 | Livy | `spark.conf.get(<clave>)` para los valores por defecto | `adaptive.enabled=true`, `skewJoin.enabled=true`, `skewedPartitionFactor=5.0`, `skewedPartitionThresholdInBytes=268435456b`, `shuffle.partitions=200`, `coalescePartitions.enabled=true`, `advisoryPartitionSizeInBytes=67108864b`, `adaptive.autoBroadcastJoinThreshold=None`, `files.openCostInBytes=4194304b` |
| E22 | Livy | `POST /v1/workspaces/{ws}/lakehouses/{lh_silver}/livyapi/versions/2023-12-01/sessions` (15:58:46 UTC) · `DELETE …/sessions/ae23625f…` (16:03:16 UTC) | Sesión propia `ae23625f-b2a3-4fe8-bd01-8417838af4e6` en `lh_silver` con el pool por defecto y sin `conf`: idle a las 16:00:27; 7 sentencias; borrada, estado `killed` |
| E23 | REST | `GET …/notebooks/{nb02}/livySessions/{801336fb…, 583587ae…}/applications/{app}/{advice,stages,jobs}` | Línea base. 2026-10-30 19:55: DataSkew en stages 118/124/130, max 586,96 MB; `sales_raw` 9 M filas; scans de `customers` de 490-549 tareas. 2026-10-30 17:15: DataSkew en stages 88/94/100, max 66,55 MB; `sales_raw` 1 M filas; scans de `customers` de 63 tareas |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | Data skew en el SortMergeJoin `sales ⟕ stores` por la clave caliente `store_id = 1` (60 % de las filas), presente en todas las ejecuciones con datos | Alta | Alta | E5, E8, E9, E17, E23 |
| H2 | Los 7 joins son SortMergeJoin porque el notebook desactiva AQE, fija 2000 particiones y desactiva el broadcast durante la sesión, lo que contradice la configuración de arranque | Alta | Alta (efecto) / Media (origen exacto) | E9, E10, E11, E16, E20, E21 |
| H3 | Time skew sin data skew en el stage 140, por la UDF Python `classify_note` (rama de 100 `re.sub` para las ventas de 22 h en adelante) combinada con `rangepartitioning(sale_ts, 64)` | Alta | Alta | E6, E8, E9, E18 |
| H4 | El MERGE de `customers` es el mayor coste (404 s de 671 s): 19.433 ficheros diminutos, 42,9 % de filas borradas, sin checkpoint, y unos 2000 ficheros nuevos por ejecución | Alta | Alta | E5, E6, E8, E15, E16, E19, E2 |
| H5 | Shuffle pesado (4 stages > 1 GB) y 19 stages de 2000 tareas, en su mayoría casi vacías | Media | Alta | E7, E8, E10 |
| H6 | Stages recomputados en varios jobs: el SMJ con `stores` se ejecuta 3 veces (jobs 62/63/64), la deduplicación de ventas 2 veces y `customers` se escanea 4 veces | Media | Media | E6, E7, E8, E9 |

### H1 · Data skew por `store_id = 1` en el join con `stores`

- **Qué ocurre:** en los stages 127, 133 y 139, que ejecutan el `SortMergeJoin LeftOuter` por `store_id` (nodo 28 del plan de la exec 81), una sola tarea lee 652,17 MB y 5.999.852 registros de los 1.158,7 MB y 10.000.050 registros que entran al stage. La mediana de registros es 0 en los stages de 2000 tareas (127, 139) y 81.628 en el de 48 (133). Duración máxima frente a mediana: 238× (5,48 s / 0,02 s), 13× (5,15 / 0,40) y 535× (12,85 / 0,02). La fuente confirma la clave: `store_id = 1` tiene 5.999.852 filas y la siguiente tienda 82.180 (E17). El join previo por `customer_id` (stage 125) no tiene skew: 7.149 frente a 5.080 registros (1,4×) y 1,19 frente a 0,89 MB (E8).
- **Por qué:** el shuffle por `hashpartitioning(store_id, 2000)` envía todas las filas de la tienda 1 a la misma partición (E9). Sin AQE (H2) no actúa `skewJoin`, aunque por defecto sí trocearía esa partición: 652 MB supera los 256 MB y más de 5 veces la mediana (E21). Sin broadcast, el shuffle por `store_id` existe aunque `stores` ocupe 18 KB (E16). El skew aparece en las tres ejecuciones medidas y crece con el volumen: 66,55 MB con 1 M filas y 586,96 MB con 9 M (E23).
- **Impacto:** unos 23 s de tarea caliente acumulados (5,45 + 5,09 + 12,83 s de run time) que fijan la duración de los tres stages (26 s de muro entre los tres), con el resto de los 32 cores ociosos durante ese tiempo. El impacto es moderado hoy, pero crece de forma lineal con el volumen de la tienda 1.

### H2 · Estrategia de joins frente a la configuración efectiva

- **Qué ocurre:** todos los joins del plan son SortMergeJoin (E9):

  | Exec SQL (sentencia) | Join | Clave | Lado izquierdo | Lado derecho | Estrategia |
  |----------------------|------|-------|----------------|--------------|------------|
  | 81 (st. 6) | LeftOuter | `customer_id` | ventas deduplicadas, 10 M filas, shuffle 1.785,7 MB (stage 124) | `customers` filtrada (DV) y proyectada a 2 columnas: 169.227 filas, shuffle 3,2 MB (stage 123) | SortMergeJoin |
  | 81 (st. 6) | LeftOuter | `store_id` | resultado anterior, 10 M filas, shuffle 1.158,7 MB (stage 125) | `stores`: 50 filas, 18.209 B (E16, E17) | SortMergeJoin |
  | 22 (st. 4, MERGE) | Inner | `customer_id` | `mergeMaterializedSource` (cambios pendientes) | `customers` | SortMergeJoin |
  | 22 (st. 4, MERGE) | LeftOuter | `filePath = path` | ficheros tocados | `LocalTableScan` (driver) | SortMergeJoin |
  | 25 (st. 4, MERGE) | LeftOuter | `customer_id` | `mergeMaterializedSource` | `customers` | SortMergeJoin |
  | 28 (st. 4) | Inner | `path` | estado de la tabla Delta `customers/_delta_log` | `LocalTableScan` | SortMergeJoin |
  | 29 (st. 4) | Inner | `path` | `LocalTableScan` | `LocalTableScan` | SortMergeJoin |

- **Comparación con la configuración:**

  | Clave | Arranque (`sparkProperties`, E11) | Valor por defecto (E21) | Efectivo según el plan (E9, E10) | ¿Coherente con el join elegido? |
  |-------|-----------------------------------|-------------------------|----------------------------------|---------------------------------|
  | `spark.sql.autoBroadcastJoinThreshold` | 26214400 (25 MB) | — | Desactivado: SMJ con `stores` de 18 KB y entre dos `LocalTableScan` | No. Con 25 MB, `stores` y los `LocalTableScan` habrían sido BroadcastHashJoin; el plan solo se explica con un valor de -1 o menor de 18 KB fijado en la sesión |
  | `spark.sql.adaptive.enabled` | sin fijar | true | false: sin `AdaptiveSparkPlan` en 104 de 106 ejecuciones; solo las de sistema 5 y 6 (antes de la sentencia 4) lo tienen | No. Con AQE, el umbral de broadcast en ejecución y el `skewJoin` habrían podido cambiar la estrategia |
  | `spark.sql.adaptive.skewJoin.*` | sin fijar | enabled=true, factor 5, umbral 256 MB | Inactivo (depende de AQE) | La partición de 652 MB cumplía las dos condiciones de split |
  | `spark.sql.adaptive.autoBroadcastJoinThreshold` | sin fijar | None (hereda el umbral estático) | Inactivo | — |
  | `spark.sql.shuffle.partitions` | sin fijar | 200 | 2000 (`hashpartitioning(…, 2000)` en todas las ejecuciones) | Explica las 2000 tareas casi vacías (H5) y los unos 2000 ficheros por MERGE (H4) |
  | `spark.sql.adaptive.coalescePartitions.*` | sin fijar | enabled=true, advisory 64 MB | Inactivo (depende de AQE) | Sin coalesce, 14 stages de 2000 tareas leen menos de 10 MB |
  | `spark.native.enabled` (NEE) | false | — | Plan con `ColumnarToRow` y `Scan parquet`, sin nodos nativos | NEE apagado; la UDF Python (`BatchEvalPython`) no se ejecutaría en nativo de todos modos |

- **Por qué:** ninguna de las tres claves alteradas aparece en las propiedades de arranque (E11), y la sesión de diagnóstico, con el mismo pool por defecto, tampoco las fija (E20). Por tanto se cambian durante la ejecución del notebook, después del arranque y antes de la sentencia 4, que es donde desaparece `AdaptiveSparkPlan` (E10). Lo más probable es un `spark.conf.set` en las celdas 1-3. `%%configure` habría aparecido en `sparkProperties`. Esto se infiere: no se leyó el código de esas celdas (Notas).
- **Impacto:** fuerza los shuffles por `store_id` y `customer_id` (unos 2,9 GB de write en los stages 124 y 125), crea el skew de H1, impide que AQE lo mitigue y multiplica las tareas y los ficheros (H4, H5).

### H3 · Time skew en el stage 140 por la UDF `classify_note`

- **Qué ocurre:** el stage 140 (64 tareas, escritura de `lh_silver.sales`) dura 23,94 s en la tarea máxima frente a 6,25 s de mediana (3,8×), con registros casi uniformes: 200.637 frente a 154.847 (1,3×) y 23,78 frente a 18,37 MB (E8). Hay time skew, pero no data skew.
- **Por qué:** el plan aplica `BatchEvalPython classify_note(notes, hour(sale_ts))` después de `rangepartitioning(sale_ts, 64)` (E9). El código de la sentencia 6 (E6) solo ejecuta 100 iteraciones de `re.sub` cuando `hour >= 22` y `notes` no es nulo, y eso afecta a 250.819 filas (E18). Al ordenar por `sale_ts`, cada partición cubre un intervalo de tiempo, y las que concentran franjas de 22-24 h pagan la rama cara. La relación entre cada partición concreta y su franja horaria no se midió (habría hecho falta el detalle por tarea del event log); por eso la causa por partición es una inferencia sobre una medición directa del coste.
- **Impacto:** el stage dura 25,1 s de muro (E7), fijado por la tarea más lenta.

### H4 · El MERGE de `customers` domina la duración y crece en cada ejecución

- **Qué ocurre:** la sentencia 4 tarda 404 s de los 671 s del notebook (E6). Hay cuatro escaneos de `customers` (E7, E8):

  | Stage | Uso | Tareas | Muro | Mediana de tarea |
  |-------|-----|--------|------|------------------|
  | 19 | `MAX(source_run_seq) … .first()` | 549 | 157,5 s | 3,57 s |
  | 29 | MERGE | 549 | 106,8 s | 3,20 s |
  | 34 | MERGE | 188 | 23,3 s | 3,65 s |
  | 123 | join de la sentencia 6 | 608 | 76,8 s | 2,94 s |

  Cada tarea tarda unos 3 s y lee unos 0,08 MB. La tabla tiene 19.433 ficheros de 1-16 KiB (15.977 con 1-9 filas), 13.120 deletion vectors, el 42,9 % de las filas borradas y ningún checkpoint (E15, E16). Además, los stages 45 y 47 (32 tareas de 11,6-14,0 s, sobre `LocalTableScan` y `DeltaThreadPool`) suman 55 s dentro de la misma sentencia.
- **Por qué:** cada MERGE añade entre 1979 y 2000 ficheros (E19), lo que coincide con `shuffle.partitions = 2000` (H2), y suma entre 2586 y 5902 deletion vectors desde la versión 3. `scanTimeMs` pasa de 16,6 s a 141,0 s y `executionTimeMs` de 80,8 s a 195,9 s en 10 versiones (E19). El Advisor lo señala como small files (E5). Que los stages 45 y 47 procesen el estado del log, con sus unas 19 K entradas y sin checkpoint, es una inferencia de confianza baja.
- **Impacto:** es la causa principal de que el notebook pase de 269 s a 671 s en 10 ejecuciones (E2). Un escaneo completo para leer un `MAX` (stage 19) cuesta 157 s.

### H5 · Shuffle pesado y particiones casi vacías

- **Qué ocurre:** ranking por shuffle write: 124 (1.785,7 MB), 122 (1.232,9 MB), 139 (1.186,8 MB), 125 (1.158,7 MB), 103 (428,4 MB). Por shuffle read: 125 (1.788,9 MB), 124 (1.232,9 MB), 140 (1.186,8 MB), 127/133/139 (1.158,7 MB cada uno), 104 (428,4 MB). Los cuatro primeros superan 1 GB de write (MEDIUM, `diagnostic-workflow.md` § Severity Thresholds). Hay 19 stages de 2000 tareas (38.000 de las 42.484 tareas de la aplicación) y 14 de ellos leen menos de 10 MB. En el stage 31, por ejemplo, la mediana de run time es 0,01 s frente a 1,11 s de máximo (E7, E8).
- **Por qué:** la cadena de la sentencia 6 baraja el dataset completo de 10 M filas cuatro veces: por `sale_id` (ventana), por `customer_id`, por `store_id` y por rango de `sale_ts` (E9). Dos de esas cuatro sobran si las dimensiones se difunden. El número fijo de 2000 particiones, sin coalesce, genera la sobrecarga de tareas vacías (H2).
- **Impacto:** 5,9 GB de write y 8,2 GB de read por ejecución, sin spill (E7).

### H6 · Stages repetidos entre jobs

- **Qué ocurre (E6, E7, E8):**
  - **SMJ `sales ⟕ stores`:** se recomputa en los jobs 62 (stage 127, 2000 tareas), 63 (stage 133, 48 tareas) y 64 (stage 139, 2000 tareas, el único que escribe shuffle: 1.186,8 MB). Los tres leen los mismos 1.158,7 MB y 10.000.050 registros, y la tarea caliente de H1 se ejecuta tres veces. Los jobs 63 y 64 se saltan 5 stages cada uno, porque reutilizan los ficheros de shuffle anteriores.
  - **Deduplicación de ventas:** se calcula dos veces. Primero en los stages 103 y 104 (job 53, `count()` de "Deduplicated rows": 10 M registros y 428,4 MB de shuffle) y otra vez en los stages 122 y 124 (job 62, escritura). `sales_raw` se lee dos veces (380,9 MB y 688,9 MB, por la poda de columnas distinta).
  - **`customers`:** se escanea 4 veces (stages 19, 29, 34 y 123).
  - **Stages internos de Delta:** la firma de 32 tareas sobre `LocalTableScan` aparece 10 veces, pero solo pesa en los jobs 23 y 24 (24,7 s y 30,2 s).
- **Por qué:** en la sentencia 6, el `repartitionByRange` por `sale_ts` (`rangepartitioning(…, 64)`, `REPARTITION_BY_NUM`) obliga a `RangePartitioner` a muestrear su entrada antes de escribir. El job 62 es el muestreo, que no escribe shuffle; el job 63 vuelve a muestrear 48 particiones desequilibradas, precisamente porque la tienda 1 llena una partición; y el job 64 es la escritura. La entrada no está persistida, así que el SMJ se recalcula cada vez. Esta lectura se basa en la forma de los jobs y en el plan, no en el event log (confianza media). Los dos `count()` de la sentencia 6 son acciones repetidas sin `cache` (código en E6). El `MAX(source_run_seq)` previo al MERGE es una acción independiente que escanea la tabla entera.
- **Impacto:** unos 26 s de muro recomputando el SMJ, unos 17 s recomputando la deduplicación (stages 103 y 104) y 157 s del escaneo para el `MAX`.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Quitar los overrides de sesión (AQE, 2000 particiones, broadcast) y difundir `stores` y `customers` de forma explícita | H1, H2, H4, H5 | Alto | Bajo | Bajo | Sí |
| R2 | Compactar `customers` y purgar sus deletion vectors; programar mantenimiento | H4 | Alto | Bajo | Medio | Sí |
| R3 | Sustituir la lectura completa para `MAX(source_run_seq)` y los `count()` de control | H4, H6 | Medio | Bajo | Bajo | Sí |
| R4 | Reescribir `classify_note` con funciones nativas o como Pandas UDF; quitar o persistir antes del `repartitionByRange` | H3, H6 | Medio | Medio | Bajo | Sí |
| R5 | Compactar `lh_bronze.sales_raw` (4000 ficheros de unos 239 KB) | H5 | Bajo | Bajo | Bajo | Sí |
| R6 | Evaluar el Native Execution Engine en `env_silver` cuando la UDF Python haya desaparecido | H2, H3 | Bajo | Bajo | Medio | Sí |

### R1 · Restaurar AQE y difundir las dimensiones pequeñas

- **Cambio propuesto:** retirar de las celdas iniciales del notebook los `spark.conf.set` que desactivan AQE y el broadcast y fijan las 2000 particiones (localizar su línea exacta, que no se leyó). Después, hacer explícito el broadcast de las dimensiones:

  ```python
  # Remove: spark.conf.set("spark.sql.adaptive.enabled", "false")
  # Remove: spark.conf.set("spark.sql.autoBroadcastJoinThreshold", "-1")
  # Remove: spark.conf.set("spark.sql.shuffle.partitions", "2000")
  from pyspark.sql import functions as F

  stores_dim = spark.read.table("stores").select("store_id", "store_name", "city")
  customers_dim = spark.read.table("customers").select("customer_id", "segment")

  sales_enriched = (
      sales
      .join(F.broadcast(stores_dim), "store_id", "left")
      .join(F.broadcast(customers_dim), "customer_id", "left")
  )
  ```

- **Impacto esperado:** desaparecen los shuffles por `store_id` y `customer_id` (unos 2,9 GB de write en los stages 124 y 125, E7) y, con el de `store_id`, la partición de 652 MB de H1. `stores` ocupa 18 KB y `customers` proyectada unos 3,2 MB de shuffle (E8, E16), muy por debajo de 25 MB (E11). AQE vuelve a coalescer las particiones vacías y a partir el skew de cualquier shuffle restante (valores por defecto en E21). El MERGE dejaría de añadir unos 2000 ficheros por ejecución (E19).
- **Cómo validarlo:** tras la siguiente ejecución, repetir E9 y comprobar que la exec de la sentencia 6 empieza por `AdaptiveSparkPlan` y muestra `BroadcastHashJoin` para `stores` y `customers`. Repetir E5 y E8: sin avisos DataSkew y con una relación máximo/mediana por debajo de 3×. Repetir E19: `numTargetFilesAdded` del nuevo MERGE muy por debajo de 2000.
- **Reversión:** volver a poner los `spark.conf.set` retirados y quitar `F.broadcast`.
- **Requiere confirmación:** Sí: cambia el código del notebook y su comportamiento en producción.

### R2 · Mantenimiento de `customers`

- **Cambio propuesto:** desde un notebook de mantenimiento (o con Table maintenance de Lakehouse), fuera de la ventana del pipeline:

  ```sql
  OPTIMIZE lh_silver.customers;
  REORG TABLE lh_silver.customers APPLY (PURGE);
  ```

  Programarlo con regularidad, por ejemplo cada N ejecuciones de `pl_daily_sales`.
- **Impacto esperado:** pasar de 19.433 ficheros de unos 4,4 KB (E15) a unos pocos ficheros de tamaño normal, eliminar las 127.225 filas marcadas como borradas y escribir checkpoint. Así se reducen los cuatro escaneos de la sentencia 4 y la 6, que hoy suman unos 364 s de muro (E7), y probablemente los stages 45 y 47.
- **Cómo validarlo:** repetir E15 (`FileCount`, `DeletedRowCount`, `CheckpointVersion`) y E16. En la siguiente ejecución, repetir E6 y E7: duración del grupo 4 y número de tareas de los scans de `customers`.
- **Reversión:** no aplica a los datos (`OPTIMIZE` y `REORG` no cambian el contenido lógico). Las versiones anteriores siguen disponibles por time travel hasta un `VACUUM`.
- **Requiere confirmación:** Sí: es una escritura sobre la tabla y consume CU.

### R3 · Evitar escaneos y acciones de control redundantes

- **Cambio propuesto:** guardar `last_applied` como metadato (por ejemplo en `TBLPROPERTIES`, en una tabla de control o derivado del `DESCRIBE HISTORY`) en lugar de calcular `MAX(source_run_seq)` sobre `customers`. En la sentencia 6, quitar el `count()` de "Deduplicated rows" o calcularlo a partir de las métricas de escritura (`operationMetrics.numOutputRows`).
- **Impacto esperado:** quitar el stage 19 (157,5 s, E7) y los stages 103 y 104 (unos 17 s).
- **Cómo validarlo:** repetir E6 y E7: el grupo 4 sin el job de `first()` y el grupo 6 sin el job 53.
- **Reversión:** restaurar las dos líneas.
- **Requiere confirmación:** Sí: es un cambio de código.

### R4 · UDF y particionado por rango

- **Cambio propuesto:** expresar `classify_note` con funciones nativas. Si la transformación de 100 iteraciones es imprescindible, implementarla como Pandas UDF o precalcularla solo para las filas con `hour >= 22` y `notes` no nulo (250.819 filas, E18). Valorar si el `repartitionByRange(64, "sale_ts")` es necesario; si lo es, persistir su entrada para no recalcular el join en el muestreo:

  ```python
  enriched = sales_enriched.persist()
  (enriched.repartitionByRange(64, "sale_ts")
      .write.mode("overwrite").saveAsTable("sales"))
  enriched.unpersist()
  ```

- **Impacto esperado:** quitar el time skew de 3,8× del stage 140 (25,1 s, E7, E8) y los dos recálculos del join (jobs 62 y 63, unos 12 s).
- **Cómo validarlo:** repetir E8 sobre el stage de escritura (máximo/mediana por debajo de 3×) y E6 (los jobs del grupo 6 dejan de leer tres veces los 1.158,7 MB).
- **Reversión:** volver a la UDF y al flujo actuales.
- **Requiere confirmación:** Sí: es un cambio de código. Además, `persist` consume memoria del executor.

### R5 · Compactar `sales_raw`

- **Cambio propuesto:** `OPTIMIZE lh_bronze.sales_raw;` en la ventana de mantenimiento, y revisar el escritor de `nb_01_ingest_bronze` (optimize write) para que no vuelvan a aparecer ficheros pequeños.
- **Impacto esperado:** menos tareas de lectura en los stages 103 y 122 (130 tareas cada uno, E7). Impacto bajo, porque esos stages duran entre 14 y 28 s.
- **Cómo validarlo:** repetir E15 (anomalía 3) y E7.
- **Reversión:** no aplica (no cambia el contenido lógico).
- **Requiere confirmación:** Sí: es una escritura.

### R6 · Native Execution Engine

- **Cambio propuesto:** cuando la UDF Python haya desaparecido (R4), probar `spark.native.enabled = true` en `env_silver` (hoy `false`, E11) y comparar una ejecución.
- **Impacto esperado:** no estimado. Depende de cuánto del plan pase a nativo; en el plan actual no hay nodos nativos (E9).
- **Cómo validarlo:** repetir E9 (nodos nativos en el plan) y E2 (duración).
- **Reversión:** volver a poner `spark.native.enabled = false`.
- **Requiere confirmación:** Sí: requiere publicar el environment, que afecta a todos sus notebooks.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Spill a memoria o disco como causa de lentitud | E7, E8 | `memoryBytesSpilled` y `diskBytesSpilled` valen 0 en los 137 stages y en los cuantiles de los 20 analizados |
| D2 | Skew en `customer_id` (join de ventas con `customers`) | E8 | En el stage 125, la tarea máxima lee 7.149 registros frente a 5.080 de mediana (1,4×) y 1,19 frente a 0,89 MB |
| D3 | Skew en la ventana por `sale_id` | E8 | Stage 124: 5.267 frente a 5.000 registros, y 0,34 frente a 0,11 s de duración (3×), con un máximo absoluto de 0,34 s |
| D4 | Claves `store_id` nulas como origen del skew | E17 | 0 nulos; el skew procede de un valor concreto (`store_id = 1`) |
| D5 | Presión de GC | E8, E12 | El GC máximo por tarea es de 0,34 s (stage 29), y el GC total de los executors es de 106 s frente a más de 12.500 s de tarea; por debajo del 20 % (`diagnostic-workflow.md` § Severity Thresholds) |
| D6 | Infrautilización del cluster o espera de arranque | E13, E14 | `coreEfficiency` 0,77 (umbral < 0,3), idle del 12 % (umbral > 40 %) y unos 4,5 s entre el inicio de la actividad y el arranque de Spark |

## Siguientes pasos

- [ ] Localizar y retirar los `spark.conf.set` de las celdas iniciales, y añadir los `broadcast` — responsable: ingeniería de datos · relacionado con: R1
- [ ] Ejecutar `OPTIMIZE` + `REORG … APPLY (PURGE)` sobre `lh_silver.customers` y programar el mantenimiento — responsable: ingeniería de datos / `FabricAdmin` · relacionado con: R2
- [ ] Sustituir el cálculo de `last_applied` y los `count()` de control — responsable: ingeniería de datos · relacionado con: R3
- [ ] Reescribir `classify_note` y revisar el `repartitionByRange` — responsable: ingeniería de datos · relacionado con: R4
- [ ] Repetir el análisis tras aplicar R1 y R2 para validar el impacto (E2, E5, E8, E9, E15, E19)

## Notas

### Limitaciones

- No se leyeron las celdas 1-3 del notebook: no lanzan jobs Spark, así que no aparecen en las descripciones de job group, y no se decodificó la definición del notebook (`operations.md` § Must/Prefer/Avoid). Que los overrides se hagan con `spark.conf.set` en esas celdas se infiere de E10, E11 y E20.
- La sesión Livy de diagnóstico corre en otro runtime (`spark.version` 4.1.1.5.5…, E20) que el notebook (runtime 1.3, E3). Sus valores por defecto (E21) son referencia de Spark, no del runtime 1.3. Las claves comparadas tienen los mismos valores por defecto en Spark 3.5, pero eso no se midió en el runtime 1.3.
- La relación entre cada partición del stage 140 y su franja horaria, y el mecanismo de `RangePartitioner` en los jobs 62 y 63, se deducen de la forma de los jobs y del plan, no del detalle por tarea del event log.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Valor exacto de `autoBroadcastJoinThreshold`, `adaptive.enabled` y `shuffle.partitions` dentro de la sesión del notebook | La API de monitorización solo expone `sparkProperties` de arranque; las propiedades modificadas por ejecución SQL solo están en el event log, que exige `copyEventLog` (Tier C) | Efecto deducido de forma directa del plan (confianza alta); valor literal y línea de código, no verificados |
| Detalle por tarea (índice de partición, rango de `sale_ts`) de los stages 139 y 140 | Igual: requiere el event log o el Spark UI completo (Tier 2) | Confianza media en el mecanismo de H3 y H6 |
| Primera variante de E20 (`spark.conf.get(clave, "unset")`) | Falló con `INVALID_CONF_VALUE.TYPE_MISMATCH`; se repitió con `None` | Ninguno |
| SKU de la capacidad | No era necesario para la pregunta | Ninguno |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Retención de `queryActivityRuns` | `automated-diagnostic-workflow.md` § Data Retention Summary: "~1 hour"; `pipeline-diagnosis.md` Step P2: "longest data retention" | Medido: la ejecución de 05:00 UTC seguía disponible a las 15:56 UTC (unas 11 h después, E14) | Se usó el dato medido; la ventana real de retención de esa API queda sin confirmar |

## Anexo

### Consultas completas

**Tabla por stage (E7, E8)**: cuantiles de `taskSummary`, mediana (q 0,5) frente a máximo (q 1,0). "Rec./MB" son registros y MB de entrada o de shuffle read, según cuál domine en el stage. Spill máximo por tarea en MB (memoria / disco).

| Stage (job) | Tareas | Duración med / máx (s) | Ratio | Rec. med / máx | MB med / máx | Shuffle write total (MB) | Spill máx (mem / disco) |
|-------------|--------|------------------------|-------|----------------|--------------|--------------------------|-------------------------|
| 19 (12) | 549 | 3,57 / 11,03 | 3,1× | 183 / 4.018 (entrada) | 0,08 / 0,09 | 0,0 | 0 / 0 |
| 29 (18) | 549 | 3,20 / 13,24 | 4,1× | 183 / 4.018 (entrada) | 0,08 / 0,11 | 6,6 | 0 / 0 |
| 31 (18) | 2000 | 0,04 / 1,77 | 44× | 85 / 122 | 0,00 / 0,00 | 1,8 | 0 / 0 |
| 33 (18) | 2000 | 0,35 / 1,12 | 3,2× | 3 / 10 | 0,00 / 0,00 | 0,0 | 0 / 0 |
| 34 (19) | 188 | 3,65 / 4,87 | 1,3× | 256 / 4.018 (entrada) | 0,10 / 0,19 | 1,1 | 0 / 0 |
| 35 (19) | 2000 | 0,23 / 1,61 | 7× | 6 / 18 | 0,00 / 0,00 | 0,0 | 0 / 0 |
| 44 (22) | 1 | 0,06 / 0,06 | 1× | 32 / 32 | 0,01 / 0,01 | 0,0 | 0 / 0 |
| 45 (23) | 32 | 11,60 / 12,21 | 1,1× | 0 / 0 | 0 / 0 | 0,0 | 0 / 0 |
| 47 (24) | 32 | 14,05 / 15,98 | 1,1× | 0 / 0 | 0 / 0 | 0,3 | 0 / 0 |
| 103 (53) | 130 | 3,17 / 4,05 | 1,3× | 77.499 / 77.525 (entrada) | 2,95 / 2,95 | 428,4 | 0 / 0 |
| 104 (53) | 2000 | 0,04 / 0,13 | 3,3× | 5.000 / 5.267 | 0,21 / 0,22 | 0,1 | 0 / 0 |
| 122 (62) | 130 | 2,72 / 4,29 | 1,6× | 77.499 / 77.525 (entrada) | 4,11 / 7,15 | 1.232,9 | 0 / 0 |
| 123 (62) | 608 | 2,94 / 4,97 | 1,7× | 182 / 4.018 (entrada) | 0,07 / 0,11 | 3,2 | 0 / 0 |
| 124 (62) | 2000 | 0,11 / 0,34 | 3,1× | 5.000 / 5.267 | 0,62 / 0,65 | 1.785,7 | 0 / 0 |
| 125 (62) | 2000 | 0,26 / 0,61 | 2,3× | 5.080 / 7.149 | 0,89 / 1,19 | 1.158,7 | 0 / 0 |
| **127 (62)** | 2000 | 0,02 / 5,48 | **238×** | 0 / 5.999.853 | 0,00 / 652,17 | 0,0 | 0 / 0 |
| **133 (63)** | 48 | 0,40 / 5,15 | **13×** | 81.628 / 5.999.853 | 10,38 / 652,17 | 0,0 | 0 / 0 |
| **139 (64)** | 2000 | 0,02 / 12,85 | **535×** | 0 / 5.999.853 | 0,00 / 652,17 | 1.186,8 | 0 / 0 |
| **140 (64)** | 64 | 6,25 / 23,94 | **3,8×** | 154.847 / 200.637 | 18,37 / 23,78 | 0,0 | 0 / 0 |
| 159 (74) | 2000 | 0,28 / 0,70 | 2,5× | 29 / 53 | 0,00 / 0,00 | 0,0 | 0 / 0 |

**Sentencias Livy (E16-E21)**: todas enviadas como `{"kind": "pyspark", "code": …}` con `spark.sql("<SELECT | DESCRIBE …>").show()` o `print(spark.conf.get(…))`:

```text
DESCRIBE DETAIL lh_silver.stores | lh_silver.customers | lh_bronze.sales_raw | lh_silver.sales
SELECT store_id, COUNT(*) AS n FROM lh_bronze.sales_raw GROUP BY store_id ORDER BY n DESC LIMIT 5
SELECT COUNT(*) AS total, COUNT(store_id) AS non_null_store, COUNT(DISTINCT store_id) AS distinct_store FROM lh_bronze.sales_raw
SELECT COUNT(*) AS stores_rows FROM lh_silver.stores
SELECT CASE WHEN hour(sale_ts) >= 22 THEN '>=22h' ELSE '<22h' END AS franja, COUNT(*) AS n, COUNT(notes) AS with_notes, AVG(length(notes)) AS avg_len FROM lh_bronze.sales_raw GROUP BY 1
DESCRIBE HISTORY lh_silver.customers
spark.conf.get(<clave>, None) / spark.conf.get(<clave>)  -- adaptive.*, skewJoin.*, autoBroadcastJoinThreshold, shuffle.partitions, coalescePartitions.enabled, advisoryPartitionSizeInBytes, native.enabled, files.openCostInBytes
```

### Configuración efectiva

Fragmento del plan de la exec 81 (sentencia 6), E9:

```text
* Project (32)
+- BatchEvalPython (31)                         classify_note(notes, hour(sale_ts))
   +- Exchange (30)                              rangepartitioning(sale_ts ASC, 64), REPARTITION_BY_NUM
      +- * SortMergeJoin LeftOuter (28)          store_id = store_id
         :- Exchange (22)                        hashpartitioning(store_id, 2000)
         :  +- * SortMergeJoin LeftOuter (20)    customer_id = customer_id
         :     :- Exchange (11)                  hashpartitioning(customer_id, 2000)
         :     :  +- Window / WindowGroupLimit   row_number() over (partition by sale_id order by ingested_at desc)
         :     :     +- Exchange (5)             hashpartitioning(sale_id, 2000)
         :     :        +- Scan parquet lh_bronze.sales_raw
         :     +- Exchange (18)                  hashpartitioning(customer_id, 2000)
         :        +- Scan parquet lh_silver.customers  (PushedFilters: __delta_internal_is_row_deleted = 0)
         +- Exchange (26)                        hashpartitioning(store_id, 2000)
            +- Scan parquet lh_silver.stores
```

`sparkProperties` de arranque relevantes (E11): `spark.sql.autoBroadcastJoinThreshold=26214400`, `spark.native.enabled=false`, `spark.dynamicAllocation.enabled=true` (min 1, max 4), `spark.executor.cores=8`, `spark.executor.memory=56g`, `spark.sql.files.maxPartitionBytes=134217728`, `spark.sql.parquet.vorder.default=false`.
