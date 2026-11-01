# Mantenimiento de tablas Delta en lh_bronze, lh_silver y lh_gold (19 tablas)

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-10-31 |
| **Áreas** | Delta tables · (pivotes de lectura) Semantic models, SQL endpoint |
| **Ámbito** | workspace `FabricPerfLab` · lakehouses `lh_bronze`, `lh_silver`, `lh_gold` (todas sus tablas) · modelo `sm_sales` como lector de gold |
| **Ventana analizada** | 2026-10-30 17:12 → 2026-10-31 16:02 UTC (historial Delta completo de las tablas; Query Insights desde 2026-10-30 17:11) |
| **Agente / host** | Claude Code · skills: sqldw-cli (`lakehouse-health.md`), spark-cli (Livy, `performance-patterns.md`), semantic-model-authoring (getDefinition) |
| **Modo** | Lectura + diagnóstico activo (Livy) |
| **Severidad global** | Alta |
| **Confianza global** | Alta (Media en H5, ver el hallazgo) |

## Resumen

- **Pregunta:** qué tablas Delta de las tres lakehouses necesitan mantenimiento y qué operación corresponde, con veredicto por tabla (también las sanas): ficheros pequeños, checkpoints, deletion vectors, ficheros sin referenciar con su retención y V-Order según el lector de cada capa.
- **Conclusión:** de las 19 tablas, 11 tienen alguna acción y 8 no necesitan nada. El problema más grave es la fragmentación: `silver.customers` (19.433 ficheros de 4,4 KB de media, 42,9 % de filas borradas por deletion vectors) y `bronze.sales_raw` (4.000 ficheros de 239 KB). En silver y gold, 7 tablas se reescriben enteras en cada ejecución, así que `OPTIMIZE` no es duradero allí: la causa está en cómo escribe el notebook. Hay 6,16 GB de ficheros sin referenciar, pero hoy ninguno es elegible para `VACUUM` con la retención por defecto de 7 días.
- **Impacto:** `silver.customers` propaga su fragmentación a `gold.dim_customer` (63 → 608 ficheros en 10 ejecuciones) y a la importación de `sm_sales`. No se midió el efecto en duración de notebooks (fuera de alcance de este análisis).
- **Primera acción:** R1, `OPTIMIZE` de `silver.customers` fuera de la ventana del pipeline; compacta los 19.433 ficheros y purga los deletion vectors de los ficheros con más de un 5 % de filas afectadas.

## Alcance

**Pregunta original:** "¿Qué tablas Delta de lh_bronze, lh_silver y lh_gold necesitan mantenimiento y qué operación propones? Dame un veredicto por tabla, también para las que no necesitan nada: ficheros pequeños, checkpoints, deletion vectors, ficheros sin referenciar con su retención y V-Order según quién lee cada capa."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Las 19 tablas listadas por la API de las tres lakehouses; salud de ficheros, checkpoints, DV, propiedades, historial, ficheros sin referenciar, lectores por capa | Duración de notebooks y pipelines (área `spark-runs`); causa del fallo de `nb_05` (solo se registra el hecho); MLV (no hay vistas materializadas en el ámbito); capacidad |

**Hipótesis de partida:** (a) las tablas con escrituras `append` frecuentes acumulan ficheros pequeños; (b) las tablas con MERGE y DV acumulan filas borradas; (c) las reescrituras completas dejan muchos ficheros sin referenciar; (d) V-Order solo importa si hay lectores del SQL endpoint o de Direct Lake.

**Recorrido:** Delta tables (salud con `sp_get_table_health_metrics` y diagnóstico Livy) → semantic-models y sql-endpoint solo para identificar lectores de gold (`sm_sales` es Import sobre el SQL endpoint de gold, E18, E19). Sin pivote a `spark-runs`: se anota `nb_05` como hallazgo colateral.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Spark (sesión Livy) | `4.1.1.5.5.20260929.238183312`; `spark.sql.parquet.vorder.default` = `false` | E15 |
| Modo de almacenamiento del modelo | Import, las 6 particiones, origen `Sql.Database(... "lh_gold")` | E18 |
| Permisos con los que se ejecutó | Lectura de items, SQL endpoint (`VIEW DEFINITION` suficiente: la salud devolvió datos) y OneLake | E5-E7, E17 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| lh_bronze | Lakehouse (SQL endpoint `03c34de1-3d8a-4a26-bd4d-cb5084ae92ce`) | Bronze | `53249a1b-e8a9-4270-9cb4-0f2ce3b10feb` |
| lh_silver | Lakehouse (SQL endpoint `bd96d99c-58c8-4904-89ba-eda833882013`) | Silver | `b01f7911-28fd-4dc2-ac51-1d19ed841238` |
| lh_gold | Lakehouse (SQL endpoint `da36bf45-abe8-4f5d-a5d7-a06e7be62f2e`) | Gold | `3aee923d-121b-415b-872c-4d5bb70664c0` |
| sm_sales | SemanticModel | Lector de gold (Import) | `a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9` |
| Workspace FabricPerfLab | Workspace | | `23ca4a73-3312-4242-9714-0289816895aa` |

### Lectores por capa

| Capa | SQL endpoint | Direct Lake | Spark | Evidencia |
|------|--------------|-------------|-------|-----------|
| Bronze | Solo `MCP-SqlEndpoint` (12 peticiones, de los análisis) | No | `nb_02` lee 5 tablas (`customer_changes`, `stores_raw`, `products_raw`, `sales_raw`, `inventory_events`) | E19, código del repositorio |
| Silver | Solo `MCP-SqlEndpoint` (12 peticiones) | No | `nb_03` lee `customers`, `stores`, `products`, `sales`; `nb_05` lee `sales` | E19, código del repositorio |
| Gold | `Mashup Engine`: 576 + 7 peticiones, 3.509 MB leídos de almacenamiento remoto en la ventana (importación de `sm_sales`) | No: las 6 particiones son Import | `nb_03` deriva `daily_store_sales` de `fact_sales` | E18, E19 |

## Evidencia

### Métricas clave

Umbrales: ficheros pequeños, media < 32 MB y objetivo 128 MB-1 GB (`spark-cli/references/operations/performance-patterns.md` § Small File Problem); códigos de anomalía 0-4 (`sqldw-cli/references/operations/lakehouse-health.md` § Health procedure); purga automática de DV en ficheros con más del 5 % de registros afectados (Learn, *Deletion vectors for Delta tables*, E21). "Sin ref." = bytes físicos bajo `Tables/<t>` fuera de `_delta_log` menos `sizeInBytes` de `DESCRIBE DETAIL` (E17 menos E10-E12).

| Tabla | Anomalía (E5-E7) | Ficheros vivos | Tamaño vivo | Media/fichero | Filas físicas / borradas | Versión snapshot · checkpoint | Ficheros sin ref. (bytes) | V-Order (propiedad) |
|-------|------------------|----------------|-------------|---------------|--------------------------|-------------------------------|---------------------------|---------------------|
| bronze.ctl_pipeline_runs | 0 | 11 | 32.157 B | 2,9 KB | 11 / 0 | 10 · log tiene checkpoint | 11 (13.607) | true |
| bronze.stores_raw | 0 | 8 | 18.921 B | 2,3 KB | 50 / 0 | 0 · no necesita | 0 | true |
| bronze.products_raw | 0 | 8 | 147.264 B | 18 KB | 5.000 / 0 | 0 · no necesita | 0 | true |
| bronze.customer_changes | 3 | 88 | 7.050.600 B | 80 KB | 339.884 / 0 | 10 · checkpoint en v10 | 0 | true |
| bronze.sales_raw | 3 | 4.000 | 957.198.969 B | 239 KB | 10.000.000 / 0 | 9 · sin checkpoint (<10 versiones) | 0 | true |
| bronze.inventory_events | 3 | 300 | 1.421.407 B | 4,7 KB | 60.000 / 0 | 298 (endpoint) / 300 (log) · sin checkpoint en el log | 0 | true; `delta.checkpointInterval`=1000 |
| silver.customers | 2 | 19.433 | 85.694.861 B | 4,4 KB | 296.452 / 127.225 (42,9 %); 13.120 DV | 10 · checkpoint en v10 | 888 (3.667.624) + DV huérfanos | no definida; `enableDeletionVectors`=true |
| silver.stores | 0 | 8 | 18.209 B | 2,3 KB | 50 / 0 | 9 | 72 (163.881) | no definida |
| silver.products | 0 | 8 | 147.684 B | 18 KB | 5.000 / 0 | 9 | 72 (1.329.156) | no definida |
| silver.sales | 3 | 64 | 756.888.497 B | 11,3 MiB | 10.000.000 / 0 | 9 | 576 (3.493.770.603) | no definida |
| silver.inventory_levels | 3 | 2.000 | 6.733.756 B | 3,4 KB | 49.337 / 0 | 9 | 17.889 (56.053.041) | no definida |
| silver.store_snapshot | No evaluada (objeto inexistente en el endpoint) | no es tabla Delta: 96 parquet, sin commits | 929.637.144 B en disco | n/a | n/a | sin `_delta_log` JSON | todo el contenido | n/a |
| gold.fact_sales | 3 | 64 | 549.101.140 B | 8,2 MiB | 10.000.000 / 0 | 9 | 535 (2.555.718.152) | no definida |
| gold.dim_customer | 3 | 608 | 6.201.883 B | 10 KB | 169.227 / 0 | 9 | 2.772 (48.689.466) | no definida |
| gold.dim_store | 0 | 8 | 18.233 B | 2,3 KB | 50 / 0 | 9 | 72 (164.097) | no definida |
| gold.dim_product | 0 | 8 | 147.708 B | 18 KB | 5.000 / 0 | 9 | 72 (1.330.268) | no definida |
| gold.dim_date | 0 | 1 | 7.231 B | 7 KB | 730 / 0 | 0 | 0 | no definida |
| gold.promotions | 0 | 2 | 18.188 B | 8,9 KB | 2.052 / 0 | 0 | 1 (1.142) | no definida |
| gold.daily_store_sales | 0 | 185 | 595.226 B | 3,1 KB | 500 / 0 | 9 | 1.141 (3.643.953) | no definida |

Total sin referenciar: 6.164.544.990 B (6,16 GB) en 23.239 ficheros, repartido en silver (3,55 GB) y gold (2,61 GB); bronze solo 13.607 B. Más 929,6 MB de datos huérfanos de `store_snapshot` (no cuentan para `VACUUM`).

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Tablas con anomalía de ficheros pequeños (código 3) | 8 (customer_changes, sales_raw, inventory_events, silver.sales, inventory_levels, fact_sales, dim_customer; más `customers` con código 2) | `lakehouse-health.md` § Health procedure | E5-E7 |
| Histórico con `OPTIMIZE`/`VACUUM` | 0 operaciones en el historial leído (hasta 12 versiones por tabla); 0 ejecuciones `TableMaintenance` en los items | `automated-diagnostic-workflow.md` Step 1 | E14, E20 |
| Propiedades de retención (`delta.deletedFileRetentionDuration`, `delta.logRetentionDuration`) | No definidas en ninguna tabla → valores por defecto (7 días para VACUUM) | Learn, *VACUUM Delta tables* | E13, E21 |
| Antigüedad de la reescritura más antigua | 2026-10-30 ~17:17 UTC (≈ 23 h) | Retención 7 días | E14 |
| Crecimiento de `dim_customer` por ejecución | 63 → 125 → 187 → 249 → 310 → 369 → 430 → 490 → 549 → 608 ficheros | n/a | E14 |
| Ejecuciones de `nb_05_store_snapshot` | 4 `Failed` entre 2026-10-30 20:18 y 20:26 | n/a | E20 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces` | Workspace `FabricPerfLab` = `23ca4a73-...` |
| E2 | REST | `GET /v1/workspaces/{ws}/items` | 3 Lakehouse, 3 SQLEndpoint, `sm_sales`, 5 notebooks, 2 pipelines, 3 environments |
| E3 | REST | `GET /v1/workspaces/{ws}/lakehouses/{id}` ×3 | `sqlEndpointProperties.id` de cada lakehouse (tabla de items); provisioning `Success` |
| E4 | REST | `GET /v1/workspaces/{ws}/lakehouses/{id}/tables` ×3 | 6 + 6 + 7 = 19 tablas, todas "Managed / delta" |
| E5 | SQL | `EXEC sys.sp_get_table_health_metrics @table_name='dbo.<t>'` ×6 sobre el endpoint de bronze (2026-10-31 ~15:51 UTC) | Ver Métricas clave. Códigos: ctl 0, stores_raw 0, products_raw 0, customer_changes 3, sales_raw 3, inventory_events 3 |
| E6 | SQL | Ídem ×6 sobre silver (~15:52 UTC) | customers 2 ("Too many deleted rows detected. Query performance may degrade."), stores 0, products 0, sales 3, inventory_levels 3; `store_snapshot`: error -32002 "Cannot find the object" → No evaluada |
| E7 | SQL | Ídem ×7 sobre gold (~15:52 UTC) | fact_sales 3, dim_customer 3, dim_store 0, dim_product 0, dim_date 0, promotions 0, daily_store_sales 0 |
| E8 | REST | `POST /v1/workspaces/{ws}/lakehouses/b01f79.../livyapi/versions/2023-12-01/sessions` (2026-10-31 15:52:46 UTC) | Sesión `d28139c6-f236-4b43-abc6-dd39a5d986be` creada sobre `lh_silver`, sin `conf` |
| E9 | REST | `GET .../sessions/{id}` hasta `idle` | `idle` tras ~100 s; `applicationId` `application_1793462022652_0001` |
| E10 | Livy | `DESCRIBE DETAIL delta.\`abfss://.../Tables/<t>\`` ×6, bronze (sentencia 1) | `numFiles`, `sizeInBytes`, `properties`, `tableFeatures` (ver Métricas clave) |
| E11 | Livy | Ídem ×6, silver (sentencia 2) | 5 tablas OK; `store_snapshot` → `[DELTA_MISSING_DELTA_TABLE] ... is not a Delta table.` |
| E12 | Livy | Ídem ×7, gold (sentencia 3) | 7 tablas OK |
| E13 | Livy | `SHOW TBLPROPERTIES delta.\`...\`` bronze, silver (5 tablas), gold (sentencias 4, 5, 6, 10) | Sin propiedades de retención. Bronze: `delta.parquet.vorder.enabled=true` en las 6; inventory_events además `delta.checkpointInterval=1000`. Silver: `customers` con `delta.enableDeletionVectors=true`, `delta.feature.deletionVectors=supported`, reader 3 / writer 7; resto reader 1 / writer 2. Sentencia 10 (`store_snapshot`): `DELTA_MISSING_DELTA_TABLE` |
| E14 | Livy | `DESCRIBE HISTORY delta.\`...\`` con `LIMIT 12` por tabla (sentencias 7, 8, 9) | Sin `OPTIMIZE` ni `VACUUM`. bronze: solo `WRITE Append`/`CREATE`; silver: `MERGE` en customers (9 MERGE, 3.614-4.167 filas borradas por MERGE) y `CREATE OR REPLACE TABLE AS SELECT` en el resto; gold: `CREATE OR REPLACE` en todas salvo dim_date y promotions (`CREATE TABLE AS SELECT` única vez). `inventory_events`: 1 fichero y 200 filas por commit |
| E15 | Livy | `spark.version`, `spark.sparkContext.applicationId`, `spark.conf.get('spark.sql.parquet.vorder.default')`, `spark.conf.get('spark.microsoft.delta.optimizeWrite.enabled')` (sentencia 11) | Versión y appId arriba; `vorder.default=false`; la segunda clave no existe (`SQL_CONF_NOT_FOUND`) |
| E16 | REST | `DELETE .../sessions/d28139c6-f236-4b43-abc6-dd39a5d986be` (2026-10-31 16:02:42 UTC) | Sesión eliminada; el listado posterior de sesiones de `lh_silver` volvió vacío |
| E17 | OneLake | `GET https://onelake.dfs.fabric.microsoft.com/{ws}?resource=filesystem&recursive=true&directory={lh}/Tables/<t>` ×19, y `_delta_log` de 3 tablas | Ficheros parquet físicos por tabla (comparados con E10-E12). `inventory_events/_delta_log`: 301 JSON (0-300), sin `_last_checkpoint` ni `.checkpoint.parquet`. `customers` y `customer_changes`: `00000000000000000010.checkpoint.parquet` + `_last_checkpoint`. `store_snapshot`: 96 parquet de datos creados 2026-10-30 20:19-20:22, sin ningún JSON de commit |
| E18 | REST | `POST /v1/workspaces/{ws}/semanticModels/{id}/getDefinition?format=TMDL` (lectura) | 6 particiones `mode: import`, origen `Sql.Database(<endpoint de lh_gold>, "lh_gold")`; tablas: fact_sales, dim_customer, dim_product, dim_store, dim_date, promotions |
| E19 | SQL | `SELECT LEFT(program_name,30), COUNT(*), MIN/MAX(start_time)... FROM queryinsights.exec_requests_history GROUP BY ...` sobre los 3 endpoints | gold: `Mashup Engine (PowerBIPremium-` 576 peticiones (2026-10-30 17:26 → 2026-10-31 05:35, 3.509 MB remotos, máx. 88.923 ms), `Mashup Engine` 7, `MCP-SqlEndpoint` 16. silver y bronze: solo `MCP-SqlEndpoint` (12 cada uno) |
| E20 | REST | `GET /v1/workspaces/{ws}/items/{id}/jobs/instances` para `nb_05` y las 3 lakehouses | `nb_05`: 4 `Failed` ("System cancelled the Spark session due to statement execution failures"); lakehouses: solo `LivySession`, ningún `TableMaintenance` |
| E21 | Docs | Microsoft Learn: *VACUUM Delta tables*, *Deletion vectors for Delta tables*, *Optimize Delta Lake tables with V-order*, *Spark monitoring and performance optimization best practices*, *Cross-workload table maintenance* | Retención por defecto 7 días (168 h); `OPTIMIZE` purga ficheros con más del 5 % de registros en DV; V-Order desactivado por defecto; impacto por consumidor (Direct Lake 40-60 % en frío, SQL endpoint ~10 %, Spark sin beneficio y escrituras 15-33 % más lentas) |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | `silver.customers`: 19.433 ficheros de 4,4 KB y 42,9 % de filas borradas por DV | Alta | Alta | E6, E10-E11, E13, E14, E17 |
| H2 | `bronze.sales_raw`: 4.000 ficheros de 239 KB (957 MB), 400 más por ejecución | Alta | Alta | E5, E10, E14 |
| H3 | `bronze.inventory_events`: 300 commits, 300 ficheros de 4,7 KB y sin checkpoint (intervalo 1000) | Media | Alta | E5, E13, E14, E17 |
| H4 | 6,16 GB sin referenciar en silver y gold, hoy no eliminables con la retención de 7 días | Media | Alta | E10-E14, E17, E21 |
| H5 | `silver.store_snapshot` no es una tabla Delta: 930 MB de datos sin commit tras 4 fallos de `nb_05` | Media | Media | E4, E6, E11, E17, E20 |
| H6 | Siete tablas se reescriben enteras cada ejecución con pocos ficheros grandes o muchos pequeños; el mantenimiento no es duradero | Media | Alta | E10-E12, E14 |
| H7 | `bronze.customer_changes` (88 ficheros de 80 KB, +8 por ejecución) con anomalía 3 | Baja | Alta | E5, E10, E14 |
| H8 | V-Order: activo en bronze (sin lectores que lo aprovechen) y ausente en gold (lector SQL endpoint) | Baja | Alta | E13, E15, E18, E19, E21 |

### H1 · `silver.customers`: ficheros diminutos y deletion vectors acumulados

- **Qué ocurre:** 19.433 ficheros vivos de 85,7 MB (4,4 KB de media), 296.452 filas físicas de las que 127.225 (42,9 %) están marcadas como borradas, con 13.120 bitmaps de DV (anomalía 2). En disco hay 20.321 ficheros parquet y 18.065 ficheros `.bin` de DV, frente a 13.120 bitmaps vivos.
- **Por qué:** la tabla se actualiza con 9 `MERGE` (cada uno borra o reescribe 3.614-4.167 filas) con `delta.enableDeletionVectors=true`, y nunca se ha ejecutado `OPTIMIZE`. Por lectura del código del repositorio (no del notebook desplegado) `nb_02` fija `spark.sql.shuffle.partitions=2000`, lo que explica los ficheros diminutos; esto es una inferencia (confianza Media en la causa, Alta en el estado). Ambos umbrales están claramente superados: media < 32 MB (`performance-patterns.md`) y DV por encima del 5 % por fichero (Learn).
- **Impacto:** `nb_02` hace MERGE contra esta tabla en cada ejecución y `nb_03` la lee para `gold.dim_customer`, cuyo número de ficheros crece con cada reescritura (63 → 608, E14), de modo que la fragmentación se propaga a la importación de `sm_sales`.

### H2 · `bronze.sales_raw`: 4.000 ficheros de 239 KB

- **Qué ocurre:** 4.000 ficheros para 957 MB (anomalía 3); 400 ficheros por ejecución, 10 `append` de 1.000.000 filas cada uno; sin `OPTIMIZE` ni VACUUM. `nb_02` lee la tabla completa en cada ejecución.
- **Por qué:** cada `append` de 1.000.000 filas escribe 400 ficheros (≈ 239 KB cada uno). Según el código del repositorio, `nb_01` reparte en `WRITE_PARTITIONS` particiones y desactiva `optimizeWrite`; no pude confirmar la configuración efectiva (la clave de `optimizeWrite` no existe en la sesión, E15).
- **Impacto:** crece linealmente (+400 ficheros por ejecución); es la tabla con más pérdida de lectura de la capa bronze, sin lector SQL endpoint real (E19).

### H3 · `bronze.inventory_events`: sin checkpoint y 300 commits de un fichero

- **Qué ocurre:** 300 versiones con un fichero de 200 filas cada una (4,7 KB de media). El log contiene 301 JSON (0-300) y ningún checkpoint ni `_last_checkpoint`; la tabla tiene `delta.checkpointInterval=1000`, y las demás tablas (`customers`, `customer_changes`) tienen checkpoint en la versión 10.
- **Por qué:** el intervalo de checkpoint de 1000 está fijado explícitamente en la tabla; con 300 commits, todo lector debe reproducir los 301 JSON. `sp_get_table_health_metrics` devuelve solo la anomalía más grave (3) y reportó snapshot 298 / checkpoint 297, que no coincide con el log (ver Notas): la ausencia de checkpoint se confirma directamente en OneLake (E17).
- **Impacto:** cada lectura (Spark o SQL endpoint) paga la reproducción del log y 300 aperturas de fichero para 1,4 MB.

### H4 · 6,16 GB sin referenciar y retención

- **Qué ocurre:** 23.239 ficheros sin referenciar: `silver.sales` 3,49 GB (82 % de su carpeta), `gold.fact_sales` 2,56 GB (82 %), más `inventory_levels` 56 MB, `dim_customer` 48,7 MB y el resto de poca cuantía. Ninguna tabla define retención propia, así que rige el valor por defecto de 7 días para `VACUUM`.
- **Por qué:** `CREATE OR REPLACE TABLE AS SELECT` en cada ejecución (10 versiones en 12 h) deja los ficheros de las versiones anteriores sin referenciar; nunca se ha ejecutado `VACUUM` (E14, E20).
- **Impacto:** almacenamiento OneLake ≈ 6,2 GB por encima del activo. **Hoy `VACUUM` con retención por defecto no borraría nada**: la reescritura más antigua es de hace ≈ 23 h (2026-10-30 ~17:17 UTC). Será efectivo a partir de 2026-11-06 ~17:17 UTC y de forma progresiva. La edad se infiere de la marca de tiempo del commit de borrado; no se ejecutó `VACUUM ... DRY RUN` (es una operación `VACUUM`, no permitida en el agente).

### H5 · `silver.store_snapshot` no es una tabla Delta

- **Qué ocurre:** la API de lakehouse la lista como tabla Delta, pero `DESCRIBE DETAIL` devuelve `DELTA_MISSING_DELTA_TABLE` y el SQL endpoint no la encuentra. En disco: 96 parquet de datos (929,6 MB) creados 2026-10-30 20:19-20:22 y ninguna entrada JSON en `_delta_log`. `nb_05` falló 4 veces entre 20:18 y 20:26.
- **Por qué:** las escrituras se interrumpieron antes de confirmar el commit; los datos quedaron huérfanos. La causa del fallo de `nb_05` no se investigó (es de `spark-runs`; confianza Media).
- **Impacto:** 930 MB de almacenamiento inútil; ningún `OPTIMIZE`/`VACUUM` aplica porque no hay tabla. La tabla además es invisible al SQL endpoint.

### H6 · Reescrituras completas: el mantenimiento no persiste

- **Qué ocurre:** silver.stores, products, sales, inventory_levels y gold.fact_sales, dim_customer, dim_store, dim_product, daily_store_sales se reescriben con `CREATE OR REPLACE` en cada ejecución (E14). Cualquier `OPTIMIZE` sobre ellas se pierde en la siguiente ejecución. Las que tienen problema de tamaño: `sales` y `fact_sales` (64 ficheros de 8-12 MiB, bajo el objetivo de 128 MB), `inventory_levels` (2.000 ficheros de 3,4 KB), `dim_customer` (608 de 10 KB; herencia de H1) y `daily_store_sales` (185 ficheros para 500 filas, 3,1 KB; la salud devuelve 0 porque solo ve el máximo de gravedad, pero 2,7 filas por fichero es desproporcionado).
- **Por qué:** el número de ficheros lo fija la escritura (particiones de shuffle/repartition), no la acumulación.
- **Impacto:** moderado en bytes (`sales` y `fact_sales` son GB, el resto MB). `fact_sales` es lo que más lee la importación de `sm_sales` (E19).

### Hallazgos de severidad Baja

- **H7** `bronze.customer_changes`: 88 ficheros de 80 KB (7 MB), +8 por ejecución; checkpoint presente; baja por tamaño absoluto.
- **H8** V-Order: bronze tiene `delta.parquet.vorder.enabled=true` en las 6 tablas, pero sus únicos lectores son Spark, donde V-Order no aporta lectura y encarece la escritura un 15-33 % (E21). Gold no lo tiene y la importación de `sm_sales` lee por SQL endpoint (mejora estimada ~10 %, E21). No hay Direct Lake que justifique más. Silver (solo Spark) correctamente sin V-Order.

## Recomendaciones

Todas modifican datos o propiedades de tablas: ninguna se ejecutó.

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | `OPTIMIZE silver.customers` (sin VORDER) fuera de la ventana del pipeline | H1 | Alto | Bajo | Bajo | Sí |
| R2 | `OPTIMIZE bronze.sales_raw` y corregir el número de particiones de escritura en `nb_01` | H2 | Alto | Medio | Bajo | Sí |
| R3 | `bronze.inventory_events`: quitar `checkpointInterval=1000` y `OPTIMIZE` | H3 | Medio | Bajo | Bajo | Sí |
| R4 | `VACUUM` semanal con retención por defecto desde 2026-11-06 (silver y gold) | H4 | Medio | Bajo | Medio | Sí |
| R5 | Corregir `nb_05` y retirar los datos huérfanos de `store_snapshot` | H5 | Medio | Medio | Medio | Sí |
| R6 | Dimensionar la escritura de `sales`, `fact_sales`, `inventory_levels`, `dim_customer`, `daily_store_sales` en lugar de `OPTIMIZE` | H6 | Medio | Medio | Bajo | Sí |
| R7 | `OPTIMIZE bronze.customer_changes` o auto compaction | H7 | Bajo | Bajo | Bajo | Sí |
| R8 | V-Order: quitar la propiedad en bronze; valorar activarlo en gold | H8 | Bajo | Bajo | Bajo | Sí |

### R1 · OPTIMIZE de `silver.customers`

- **Cambio propuesto:** en un notebook de `lh_silver`, con el pipeline `pl_daily_sales` parado (el `MERGE` de `nb_02` y `OPTIMIZE` pueden entrar en conflicto), o con un job `TableMaintenance` (Learn, *Manage a lakehouse with the REST API*):

  ```sql
  OPTIMIZE customers;
  ```

  `OPTIMIZE` compacta y purga automáticamente los DV de los ficheros con más del 5 % de registros afectados (Learn, E21); `REORG ... APPLY (PURGE)` solo haría falta para filas por debajo de ese umbral, y aquí no es necesario.
- **Impacto esperado:** de 19.433 ficheros a unos pocos (85,7 MB vivos), y 127.225 filas borradas físicamente reescritas. Mejora la lectura de `nb_02`/`nb_03` y reduce el crecimiento de `gold.dim_customer`. La magnitud en tiempo no está medida.
- **Cómo validarlo:** repetir `sp_get_table_health_metrics @table_name='dbo.customers'` (esperado: anomalía 0, `FileCount` de unidades/decenas, `DeletedRowCount` 0) y `DESCRIBE DETAIL`; comparar la duración de `nb_02` antes/después.
- **Reversión:** no hay reversión de datos (el contenido lógico no cambia); la versión previa sigue accesible por time travel hasta el `VACUUM`.
- **Requiere confirmación:** Sí, escritura que reescribe ficheros y consume CU.

### R2 · OPTIMIZE y escritura de `bronze.sales_raw`

- **Cambio propuesto:**

  ```sql
  OPTIMIZE sales_raw;   -- en lh_bronze; sin VORDER (lectores: Spark)
  ```

  y en `nb_01`, sustituir el `repartition(WRITE_PARTITIONS)` por un número de particiones que dé ficheros grandes (cada `append` de 1.000.000 filas pesa ≈ 96 MB, así que 1 fichero por escritura y compactar con `OPTIMIZE` hasta 128 MB-1 GB) o activar auto compaction (`spark.databricks.delta.autoCompact.enabled`, Learn E21).
- **Impacto esperado:** de 4.000 ficheros a ~8-10 (957 MB a 128 MB-1 GB por fichero); detiene el crecimiento de +400 ficheros por ejecución.
- **Cómo validarlo:** salud de `dbo.sales_raw` (anomalía 0) y `numFiles` tras la siguiente ejecución del pipeline.
- **Reversión:** el `OPTIMIZE` no cambia datos lógicos; el cambio en `nb_01` se revierte restaurando el valor anterior.
- **Requiere confirmación:** Sí, escritura y cambio de notebook.

### R3 · `bronze.inventory_events`

- **Cambio propuesto:**

  ```sql
  ALTER TABLE inventory_events UNSET TBLPROPERTIES ('delta.checkpointInterval');
  OPTIMIZE inventory_events;
  ```

- **Impacto esperado:** vuelve el intervalo por defecto (el resto de tablas checkpointea en la versión 10) y 300 ficheros de 4,7 KB pasan a uno. Si los micro-commits de 200 filas son intencionados, valorar agruparlos en la escritura.
- **Cómo validarlo:** `_delta_log` con `_last_checkpoint`/`.checkpoint.parquet` en OneLake y `numFiles` ≈ 1.
- **Reversión:** `ALTER TABLE ... SET TBLPROPERTIES ('delta.checkpointInterval'='1000')`.
- **Requiere confirmación:** Sí, cambio de propiedad y escritura.

### R4 · VACUUM con retención por defecto

- **Cambio propuesto:** programar semanalmente `VACUUM <tabla>` (sin `RETAIN`, 168 h) sobre las tablas con ficheros sin referenciar, después de `OPTIMIZE`/escrituras (Learn, *VACUUM Delta tables*). Primer momento útil: **a partir de 2026-11-06 ~17:17 UTC**; se recomienda usar antes `VACUUM ... DRY RUN`. Prioridad: `silver.sales` (3,49 GB), `gold.fact_sales` (2,56 GB), `inventory_levels`, `dim_customer`. No acortar la retención por debajo de 7 días: Fabric lo bloquea por defecto y exige desactivar `spark.databricks.delta.retentionDurationCheck.enabled`, con riesgo para lectores concurrentes y time travel (Learn, E21).
- **Impacto esperado:** recuperar hasta ≈ 6,16 GB (cifra a fecha de hoy; crecerá ≈ 0,55 GB por ejecución de pipeline mientras no se ejecute).
- **Cómo validarlo:** comparar bytes físicos bajo `Tables/<t>` (OneLake) con `sizeInBytes` de `DESCRIBE DETAIL`; deben converger.
- **Reversión:** irreversible (se pierde el time travel más allá de 7 días).
- **Requiere confirmación:** Sí, borra ficheros.

### R5 · `silver.store_snapshot`

- **Cambio propuesto:** (1) diagnosticar y corregir `nb_05` (fallos de las 20:18-20:26, derivar a análisis de `spark-runs`); (2) comprobar que la carpeta `Tables/store_snapshot` no contiene datos útiles y eliminarla; (3) relanzar `nb_05` para que cree la tabla.
- **Impacto esperado:** recupera 930 MB y hace visible la tabla en el SQL endpoint.
- **Cómo validarlo:** `DESCRIBE DETAIL` devuelve la tabla; `sp_get_table_health_metrics @table_name='dbo.store_snapshot'` responde.
- **Reversión:** el borrado de la carpeta no es reversible; copiar antes si hay dudas.
- **Requiere confirmación:** Sí, borrado y ejecución de notebook.

### R6 · Dimensionar la escritura de las tablas reescritas

- **Cambio propuesto:** en `nb_02`/`nb_03`, antes de `saveAsTable`, ajustar particiones para ficheros ≥ 128 MB: `sales`/`fact_sales` (≈ 757 MB / 549 MB → 4-6 ficheros), `inventory_levels` (6,7 MB → 1 fichero; revisar `spark.sql.shuffle.partitions=2000`), `daily_store_sales` y `dim_customer` (1 fichero). Alternativa: `spark.microsoft.delta.optimizeWrite.enabled=true` o auto compaction.
- **Impacto esperado:** ficheros adecuados en cada ejecución sin depender de `OPTIMIZE`; menos ficheros sin referenciar que `VACUUM` deba limpiar.
- **Cómo validarlo:** `numFiles` y media por fichero tras la siguiente ejecución, y duración de `nb_03`.
- **Reversión:** restaurar el código anterior del notebook.
- **Requiere confirmación:** Sí, cambio de notebooks.

### R7 · `bronze.customer_changes`

- **Cambio propuesto:** `OPTIMIZE customer_changes;` dentro de la ventana de mantenimiento de R2, o auto compaction en `nb_01`.
- **Impacto esperado:** 88 ficheros a 1; impacto pequeño (7 MB).
- **Cómo validarlo:** salud de `dbo.customer_changes` (anomalía 0).
- **Reversión:** no aplica a los datos lógicos.
- **Requiere confirmación:** Sí.

### R8 · V-Order por capa

- **Cambio propuesto:** bronze: `ALTER TABLE <t> UNSET TBLPROPERTIES ('delta.parquet.vorder.enabled')` en las 6 tablas (los escribe y lee solo Spark; Learn: sin beneficio de lectura y 15-33 % de coste de escritura). Silver: dejar como está. Gold: opcional, activar V-Order en las tablas que lee `sm_sales` si la importación por SQL endpoint se quiere acelerar (~10 % según Learn); pasa a ser prioritario solo si el modelo migra a Direct Lake (40-60 % en frío).
- **Impacto esperado:** escrituras de bronze más rápidas; lectura de gold ligeramente mejor.
- **Cómo validarlo:** duración de `nb_01` y de la actualización de `sm_sales` antes y después.
- **Reversión:** restaurar la propiedad.
- **Requiere confirmación:** Sí.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | `VACUUM` ya puede recuperar espacio | E14, E21 | La reescritura más antigua tiene ≈ 23 h; con 7 días de retención por defecto, nada es elegible hasta 2026-11-06 |
| D2 | Checkpoints obsoletos como problema general | E17, E5-E7 | Solo `inventory_events` carece de checkpoint; `customers`, `customer_changes` y `ctl_pipeline_runs` lo tienen en v10; el resto no ha llegado a 10 versiones |
| D3 | Deletion vectors en otras tablas | E13 | Solo `silver.customers` tiene la feature `deletionVectors`; las demás son `appendOnly`/`invariants` |
| D4 | Guardrails de Direct Lake / V-Order para Direct Lake | E18 | `sm_sales` es Import; no hay modelo Direct Lake sobre estas tablas |
| D5 | Ficheros sin referenciar en bronze | E17, E10 | Bronze solo hace `append`/overwrite único; físico = vivo, salvo 11 ficheros diminutos en `ctl_pipeline_runs` (13,6 KB) |
| D6 | Retención personalizada (acortada o ampliada) en las tablas | E13 | Ninguna tabla define `deletedFileRetentionDuration` ni `logRetentionDuration` |

## Siguientes pasos

- [ ] Confirmar el calendario del pipeline y reservar una ventana para R1, R2, R3, R7 — responsable: ingeniería de datos · relacionado con: R1, R2, R3, R7
- [ ] Diagnosticar el fallo de `nb_05` (derivar a análisis `spark-runs`) — responsable: ingeniería de datos · relacionado con: R5
- [ ] Planificar `VACUUM` semanal con `DRY RUN` previo, a partir del 2026-11-06 — responsable: ingeniería de datos · relacionado con: R4
- [ ] Revisar la configuración de escritura de `nb_01`, `nb_02` y `nb_03` — responsable: ingeniería de datos · relacionado con: R2, R6
- [ ] Repetir este análisis tras aplicar R1-R4 para validar el impacto

## Notas

### Limitaciones

- Los lectores de bronze y silver (Spark) y las causas de escritura (particiones, `optimizeWrite`) se deducen del código en `demo-setup/items/notebooks/` del repositorio, no del notebook desplegado en el workspace; no leí la definición viva de los notebooks. La configuración efectiva de Spark de los notebooks no se pudo comprobar.
- `DESCRIBE HISTORY` se limitó a 12 versiones por tabla (el cap acotado); en `inventory_events` (301 versiones) el historial completo no se leyó. La ausencia de `OPTIMIZE` allí se apoya en que `numFiles` (300) iguala a las versiones.
- Los ficheros sin referenciar se obtienen por diferencia entre OneLake (E17) y `DESCRIBE DETAIL` (E10-E12), no con `VACUUM ... DRY RUN`. No incluyen el tamaño de los `.bin` de DV huérfanos de `customers`.
- Query Insights solo cubre desde 2026-10-30 17:11; otros análisis concurrentes sobre el mismo workspace aparecen como `MCP-SqlEndpoint` y sesiones `LivySession` en el mismo intervalo.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| `sp_get_table_health_metrics` de `silver.store_snapshot` | Error -32002: el objeto no existe en el SQL endpoint | "No evaluada", no sana; explicada por H5 |
| Configuración efectiva `spark.microsoft.delta.optimizeWrite.enabled` | `SQL_CONF_NOT_FOUND` en la sesión Livy | La causa de los ficheros pequeños es inferencia (confianza Media) |
| Duración de notebooks antes/después de la fragmentación | Fuera del alcance | No se cuantifica el impacto en tiempo |
| Causa del fallo de `nb_05` | Fuera del alcance (área `spark-runs`) | H5 con confianza Media |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Versión de snapshot y checkpoint de `inventory_events` | `sp_get_table_health_metrics` devolvió snapshot 298 / checkpoint 297 | `_delta_log` en OneLake: JSON hasta la versión 300 y ningún checkpoint | Prevalece el log de OneLake (medición directa); la diferencia sugiere retraso de sincronización del SQL endpoint o una definición distinta del campo, sin verificar |
| Código de anomalía único | `lakehouse-health.md`: solo la más grave | `daily_store_sales` (185 ficheros para 500 filas) y `inventory_events` (sin checkpoint, código 3) devuelven un código que no refleja todo | Se complementó con `DESCRIBE DETAIL` y el listado OneLake |
| Sesión Livy "pool por defecto, sin `conf`" | El agente pide solo pool por defecto | La skill `spark-cli` indica que el cuerpo plano exige memoria y núcleos | Se envió `name`, `driverMemory`/`executorMemory` 28g y 4 núcleos, sin `conf` ni pool |
| Rutas del cuerpo en el guard de Livy | El guard exige ruta literal en `--body @` | Las sentencias 2 y 3 se enviaron con una variable de shell en la ruta (`$f`); el guard no las bloqueó. El código era solo `DESCRIBE DETAIL` | Se registra la desviación; el resto de sentencias usaron rutas literales |

## Anexo

### Consultas completas

- E5-E7: `EXEC sys.sp_get_table_health_metrics @table_name = 'dbo.<tabla>';` una vez por tabla y endpoint.
- E10-E12: por tabla, `spark.sql("DESCRIBE DETAIL delta.`abfss://{ws}@onelake.dfs.fabric.microsoft.com/{lh}/Tables/{t}`").selectExpr("'{t}' as t","numFiles","sizeInBytes","partitionColumns","clusteringColumns","lastModified","properties","tableFeatures").toJSON().collect()`.
- E13: `spark.sql("SHOW TBLPROPERTIES delta.`...`").toJSON().collect()`.
- E14: `spark.sql("DESCRIBE HISTORY delta.`...`").selectExpr("'{t}' as t","version","timestamp","operation","operationParameters","operationMetrics").limit(12).toJSON().collect()`.
- E19: `SELECT LEFT(program_name,30) AS prog, COUNT(*) AS n, MIN(CONVERT(varchar(16),start_time,120)) AS first_t, MAX(CONVERT(varchar(16),start_time,120)) AS last_t, SUM(CAST(data_scanned_remote_storage_mb AS float)) AS remote_mb, MAX(total_elapsed_time_ms) AS max_ms FROM queryinsights.exec_requests_history GROUP BY LEFT(program_name,30) ORDER BY n DESC;` (en bronze y silver sin las dos últimas métricas).

### Configuración efectiva

- Sesión Livy: `lh_silver`, `driverCores`/`executorCores` 4, memoria 28g, sin `conf`; `spark.sql.parquet.vorder.default=false`.
- Propiedades por tabla: bronze `delta.parquet.vorder.enabled=true`, `delta.stats.extended.collect/inject=true` (`inventory_events` con `delta.checkpointInterval=1000`); silver `customers` con `delta.enableDeletionVectors=true`; gold y el resto de silver solo `delta.stats.extended.*`.
