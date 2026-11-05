# pl_daily_sales: qué crece entre ejecuciones

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-05 |
| **Áreas** | Spark runs → Delta tables |
| **Ámbito** | workspace `FabricPerfLab` · `pl_daily_sales`, `nb_01_ingest_bronze`, `nb_02_bronze_to_silver`, `nb_03_silver_to_gold`, `nb_04_refresh_model`, tablas de `lh_bronze`, `lh_silver` y `lh_gold` que tocan |
| **Ventana analizada** | 2026-10-30 17:11 → 2026-11-05 05:31 UTC (todas las ejecuciones retenidas del pipeline) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli |
| **Modo** | Solo lectura |
| **Severidad global** | Media |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** qué crece entre ejecuciones de `pl_daily_sales`, con tendencia por actividad y, dentro de cada notebook, de shuffle, jobs y ficheros/commits de las tablas, y si cada notebook carga completo o incremental.
- **Conclusión:** crece `nb_02_bronze_to_silver` (280 s → 882 s en 15 ejecuciones completadas), por dos causas medidas. (1) Reconstruye `silver.sales` completo desde todo el histórico de `bronze.sales_raw` en cada ejecución: el shuffle read sube de 911 MB a 12.063 MB, unos 800 MB más por carga. (2) La tabla `silver.customers` acumula ficheros diminutos: de 2.000 a 28.149 ficheros (media 0,004 MB) con un `MERGE` por ejecución, y el tiempo de ejecutor de ese `MERGE` pasa de 730 s a 9.095 s. `nb_03` también crece por reescribir todo y por leer esos ficheros pequeños. `nb_01` y `nb_04` no muestran tendencia.
- **Impacto:** el pipeline programado pasó de 1.500 s (2 nov) a 1.839 s (5 nov), +22,6 % en 3 días. En la última ejecución, el `MERGE` de customers consume 9.095 s de los 15.055 s de ejecutor de `nb_02` (60 %) y la reconstrucción de ventas 5.214 s (35 %).
- **Primera acción:** R1, compactar con `OPTIMIZE` las tablas con ficheros pequeños y arreglar la configuración que los genera (2.000 particiones de shuffle con AQE desactivado). Requiere confirmación. Después R2 (ventas incremental).

## Alcance

**Pregunta original:** "El pipeline pl_daily_sales del workspace FabricPerfLab tarda cada día más. ¿Qué es lo que crece entre ejecuciones? Quiero la tendencia por actividad y, dentro de cada notebook, del shuffle, del número de jobs y de los ficheros y commits de las tablas que toca. Lee el código de los notebooks para ver si cada uno carga completo o incremental."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| `pl_daily_sales` y sus 4 actividades (17 ejecuciones retenidas, 30 oct – 5 nov). Los 4 notebooks (código leído con `getDefinition`). 16 tablas Delta de bronze, silver y gold que tocan. | `pl_store_snapshot` y `nb_05_store_snapshot` (no forman parte de `pl_daily_sales`). Modelo semántico `sm_sales` y su rendimiento DAX. Capacidad (CU). |

**Hipótesis de partida:** H-a, el volumen de datos crece y algún notebook reprocesa todo el histórico. H-b, tablas Delta que se fragmentan (muchos commits o ficheros pequeños) encarecen lecturas y escrituras. H-c, el retraso viene de arranque o cola de sesión, no del cómputo.

**Recorrido:** Spark runs (tendencia de actividades, jobs y stages por sesión, código de notebooks) → Delta tables, al ver que los stages más lentos de `nb_02` y `nb_03` leen y escriben `silver.customers` con 800 o más tareas pequeñas. No se usó Livy: `_delta_log` en OneLake da ficheros, bytes y commits por versión con lecturas Tier A, y `DESCRIBE DETAIL` no cambiaba ninguna conclusión.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad | `353a0ed6-2bba-456c-bac7-009fc42e4b94` (SKU y región no consultados) | E1 |
| Runtime de Spark | 2.0 (campo `runtimeVersion` de las sesiones) | E5 |
| Configuración Spark relevante (del código) | `nb_02`: `spark.sql.shuffle.partitions=2000`, AQE desactivado, `autoBroadcastJoinThreshold=-1`. `nb_01`: `optimizeWrite` desactivado, `repartition(400)`. `nb_03`: AQE desactivado. | E7 |
| Permisos con los que se ejecutó | Usuario con lectura de workspace, Spark Monitoring y OneLake | E1–E8 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| pl_daily_sales | DataPipeline | Orquestación diaria 05:00 UTC | bd706b1d-499f-4a0d-bb22-222312944ca1 |
| nb_01_ingest_bronze | Notebook | Ingesta bronze | 4240632d-3ce1-422f-a1b2-ddb55d8736e0 |
| nb_02_bronze_to_silver | Notebook | Bronze → silver | 4205418f-cee2-4a3d-9390-328618160264 |
| nb_03_silver_to_gold | Notebook | Silver → gold | c7cca4b7-3722-4bec-9946-504520f6be21 |
| nb_04_refresh_model | Notebook | Refresco de `sm_sales` | 3a609552-4721-406a-8e9c-f801c0a43b59 |
| lh_bronze / lh_silver / lh_gold | Lakehouse | Capas | 53249a1b-… / b01f7911-… / 3aee923d-… |

## Evidencia

### Métricas clave

**Pipeline y actividades: duración en segundos, ejecuciones programadas (05:00 UTC)**

| Ejecución | Pipeline | nb_01 | nb_02 | nb_03 | nb_04 | Evidencia |
|-----------|----------|-------|-------|-------|-------|-----------|
| 31 oct | 1.573 | 301 | 701 | 373 | 159 | E3, E4 |
| 1 nov | Fallida en nb_01 (70 s) | 70 | – | – | – | E3, E4 |
| 2 nov | 1.500 | 274 | 735 | 432 | 38 | E3, E4 |
| 3 nov | 1.556 | 267 | 748 | 382 | 145 | E3, E4 |
| 4 nov | 1.672 | 305 | 792 | 401 | 159 | E3, E4 |
| 5 nov | 1.839 | 266 | 882 | 522 | 144 | E3, E4 |

La serie completa de las 15 ejecuciones completadas (incluye las 9 manuales del 30 oct y una manual el 3 nov) tiene `nb_02` de 280 s a 882 s y `nb_03` de 342 s a 522 s (con picos de 704 s). Referencia: `job-diagnostics.md` § Detect Regressions marca regresión si la última ejecución supera 2x la mediana de las 5 anteriores. Aquí `nb_02` es 882 / 735 = 1,20x y el pipeline 1.839 / 1.556 = 1,18x: no se alcanza el umbral, pero la tendencia es monótona.

**Spark por notebook: ejecuciones completadas, primera → última (E6)**

| Notebook | Jobs | Stages | Shuffle read (MB) | Shuffle write (MB) | Input (MB) | Spill |
|----------|------|--------|-------------------|--------------------|------------|-------|
| nb_01 | 229 → 221 (plano) | 307 → 297 | 111 → 111 (plano) | 111 → 111 | 1 → 17 | 0 |
| nb_02 | 62 → 81 | 120 → 165 | 911 → 12.063 (+~800 por carga, lineal) | 645 → 8.612 | 131 → 2.056 | 0 |
| nb_03 | 52 → 63 | 82 → 108 | 18 → 176 | 18 → 176 | 126 → 1.771 | 0 |
| nb_04 | 0–5 | 0–3 | 0 | 0 | 0 | 0 |

Los jobs de `nb_02` suben sobre todo en la 2.ª ejecución (62 → 76) y luego se estabilizan en 74–87. La tendencia relevante no es el número de jobs, sino el tiempo y el shuffle por job.

**Dentro de `nb_02`: tiempo de ejecutor (s) y shuffle read por statement (E9)**

| Statement (celda) | 30 oct 17:15 (1.ª) | 31 oct | 5 nov (última) |
|-------------------|--------------------|--------|----------------|
| Customers `MERGE` (celda 3) | 730 s · 7 MB | 6.836 s · 59 MB | 9.095 s · 55 MB |
| Reference data (celda 4) | 54 s | 20 s | 43 s |
| Sales rebuild (celda 5) | 658 s · 898 MB | 3.886 s · 8.114 MB | 5.214 s · 11.988 MB |
| Inventory levels (celda 6) | 456 s | 712 s | 703 s |
| Total ejecutor | 1.898 s | 11.454 s | 15.055 s |

**Dentro de `nb_03`: tiempo de ejecutor (s)**

| Statement | 1.ª | 31 oct | 5 nov |
|-----------|-----|--------|-------|
| `fact_sales` (celda 4) | 226 s | 335 s | 211 s |
| `dim_customer`, `dim_store`, `dim_product` (celda 5) | 268 s | 2.099 s | 3.209 s |
| `daily_store_sales` (celda 7) | 101 s | 123 s | 125 s |
| Total ejecutor | 771 s | 2.642 s | 3.604 s |

**Ficheros y commits de las tablas, por ejecución completada (E8)**

| Tabla | Operación y commits por ejecución | Ficheros activos 1.ª → última | MB totales | Tamaño medio de fichero |
|-------|-----------------------------------|-------------------------------|------------|-------------------------|
| bronze.sales_raw | append, 1 commit | 400 → 6.000 (+400 por carga) | 91 → 1.369 | 0,23 MB |
| bronze.inventory_events | append, 30 commits (uno por tienda) | 30 → 450 (451 versiones) | 0 → 2 | ~0,005 MB |
| bronze.customer_changes | append, 1 commit | 8 → 136 | 4 → 9 | 0,47 → 0,06 MB |
| bronze.ctl_pipeline_runs | append, 1 commit | 1 → 17 | 0 | – |
| silver.customers | `MERGE`, 1 commit | 2.000 → 28.149 (+~1.900 por carga) | 12 → 117 | 0,004 MB |
| silver.sales | overwrite, 1 commit | 64 → 64 | 80 → 1.068 | 1,3 → 16,7 MB |
| silver.inventory_levels | overwrite, 1 commit | 1.897 → 2.000 | 5 → 7 | ~0,003 MB |
| silver.products, silver.stores | overwrite, 1 commit | 8 → 8 | 0 | – |
| gold.fact_sales | overwrite, 1 commit | 33 → 35 (64 hasta el 4 nov) | 59 → 752 | 1,8 → 21,5 MB |
| gold.dim_customer | overwrite, 1 commit | 63 → 880 (+~55 por carga) | 5 → 7 | 0,07 → 0,008 MB |
| gold.daily_store_sales | overwrite, 1 commit | 44 → 198 | 0 → 1 | ~0,005 MB |
| gold.dim_store, gold.dim_product | overwrite, 1 commit | 8 → 8 | 0 | – |

Referencia: `performance-patterns.md` § Small File Problem, media de fichero < 32 MB indica problema de ficheros pequeños. Los ficheros se cuentan como altas menos bajas en `_delta_log` y no tienen en cuenta deletion vectors; `silver.customers` tiene `delta.enableDeletionVectors=true` y no se midió su efecto.

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces` (filtrado por nombre) | Workspace `FabricPerfLab` = 23ca4a73-3312-4242-9714-0289816895aa, capacidad 353a0ed6-… |
| E2 | REST | `GET /v1/workspaces/{ws}/items` | 5 notebooks, 2 pipelines, 3 lakehouses, 3 environments, modelo `sm_sales` |
| E3 | REST | `GET /v1/workspaces/{ws}/items/{pl}/jobs/instances` | 17 ejecuciones (30 oct – 5 nov): 15 completadas, 2 fallidas (30 oct 18:43 y 1 nov 05:00, `DELTA_FAILED_TO_MERGE_FIELDS` en `amount`) |
| E4 | REST (lectura) | `POST /v1/workspaces/{ws}/datapipelines/pipelineruns/{id}/queryactivityruns` ×17 | Duraciones por actividad, `notebookId` y `sessionId` de cada una; sin ForEach ni reintentos; sin sesiones de alta concurrencia (`highConcurrencyModeStatus` nulo) |
| E5 | REST | `GET /v1/workspaces/{ws}/spark/livySessions` | 79 sesiones desde 30 oct 17:05; las 62 de las actividades completadas están presentes |
| E6 | REST | `GET /v1/workspaces/{ws}/notebooks/{nb}/livySessions/{livy}/applications/{app}/jobs` y `/stages` ×62 | Jobs, stages, shuffle, input, output y spill sumados por sesión (tabla anterior). Sin errores 404: los datos de las 62 sesiones siguen retenidos |
| E7 | REST (lectura) | `POST /v1/workspaces/{ws}/notebooks/{nb}/getDefinition?format=ipynb` ×4 | Código de `nb_01` a `nb_04` (ver H5) |
| E8 | OneLake | `GET` de `Tables/{tabla}/_delta_log/*.json` de 16 tablas (DFS API) | Altas, bajas, bytes y operación por commit; ficheros activos acumulados por ejecución |
| E9 | Derivada de E6 | Agrupación de jobs por `jobGroup` (número de statement) y suma de `executorRunTime` y `shuffleReadBytes` de sus stages | Desglose por celda de `nb_02` y `nb_03` |

No se ejecutaron acciones Tier B (ni Livy ni `ClearCache`). No se consultó `/advice` ni capacidad.

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | La duración del pipeline crece y el aumento está en `nb_02` (y en segundo lugar `nb_03`); `nb_01` y `nb_04` no crecen | Media | Alta | E3, E4 |
| H2 | `silver.customers` acumula ficheros diminutos con cada `MERGE` y es el mayor consumidor de `nb_02`, además de frenar `nb_03` | Alta | Alta (medición) / Media (mecanismo) | E6, E7, E8, E9 |
| H3 | `nb_02` reconstruye `silver.sales` entero desde todo el histórico de bronze en cada ejecución | Media | Alta | E6, E7, E8, E9 |
| H4 | `nb_03` reescribe toda la capa gold cada día; el volumen leído crece 14x | Media | Alta | E6, E7, E8 |
| H5 | Estado de carga completo o incremental de cada notebook | Informativo | Alta | E7 |
| H6 | `nb_01` es incremental pero deja tablas bronze con ficheros pequeños y 30 commits por ejecución en `inventory_events` | Baja | Alta | E7, E8 |

### H1 · El crecimiento está en nb_02 y nb_03

- **Qué ocurre:** con las ejecuciones programadas, el pipeline pasa de 1.500 s (2 nov) a 1.839 s (5 nov). `nb_02` sube de 735 a 882 s y `nb_03` de 432 a 522 s. `nb_01` está en 266–305 s sin tendencia y `nb_04` oscila entre 38 y 159 s sin tendencia.
- **Por qué:** `nb_02` y `nb_03` son los que reprocesan o leen estructuras que crecen (H2, H3, H4). En `nb_01`, shuffle (111 MB), jobs (221–229) y duración son planos (E6). La diferencia de `nb_04` entre 38 s y 145–159 s no se relaciona con shuffle ni datos (0 MB, 0 jobs en la mayoría); no se investigó su causa.
- **Impacto:** +339 s (+22,6 %) en tres días de datos; a este ritmo el pipeline añade unos 100–120 s por carga. La ratio frente a la mediana de las cinco ejecuciones anteriores es 1,18–1,20x, por debajo del 2x de `job-diagnostics.md` § Detect Regressions; por eso la severidad es Media.

### H2 · silver.customers: ficheros diminutos y tiempo de MERGE

- **Qué ocurre:** `silver.customers` pasa de 2.000 a 28.149 ficheros activos (~1.900 más por carga) para 117 MB (media 0,004 MB). El `MERGE` de la celda 3 de `nb_02` pasa de 730 s a 9.095 s de ejecutor (12x), con solo 55 MB de shuffle. En la última ejecución el stage más pesado lee la tabla con 827 tareas (`first at ipykernel`, línea que calcula `MAX(source_run_seq)`) y otro stage de `MERGE` usa 827 tareas, 3.269 s y 2.741 s. Aguas abajo, la lectura de customers y la creación de `gold.dim_customer` en `nb_03` pasan de 268 s a 3.209 s y `dim_customer` crece de 63 a 880 ficheros.
- **Por qué:** `nb_02` fija `spark.sql.shuffle.partitions=2000` con AQE desactivado y el `MERGE` reescribe la tabla en esas particiones; cada commit añade ~1.900 ficheros pequeños y ninguno se compacta (15 commits `MERGE` y ninguno de mantenimiento en el log). Cada lectura de la tabla (el `MAX`, el `MERGE`, `nb_03`) paga un coste por fichero que crece linealmente. La configuración efectiva en tiempo de ejecución no se leyó (no hubo Livy), por eso la confianza del mecanismo es Media; el efecto medido (ficheros y tiempos) es Alta.
- **Impacto:** 9.095 s de los 15.055 s de ejecutor de `nb_02` (60 %) y 3.209 de los 3.604 s de `nb_03` (89 %) en la última ejecución. Es la causa dominante del aumento de tiempo. Referencia: `performance-patterns.md` § Small File Problem (< 32 MB de media), superada por varios órdenes de magnitud.

### H3 · Reconstrucción completa de silver.sales

- **Qué ocurre:** el shuffle read del statement de ventas sube de 898 MB a 11.988 MB (+~800 MB por carga, lineal) y su tiempo de ejecutor de 658 s a 5.214 s. `bronze.sales_raw` crece 400 ficheros y ~91 MB por carga (1 M filas), hasta 6.000 ficheros y 1.369 MB.
- **Por qué:** la celda 5 de `nb_02` lee toda `lh_bronze.sales_raw`, cuenta dos veces (`count()` antes y después de la deduplicación, es decir, dos recorridos adicionales), deduplica con `row_number()` sobre `sale_id` en una ventana, aplica un UDF de Python (`classify_note`, con 100 pasadas de regex para ventas posteriores a las 22:00 con comentario) y sobrescribe `sales`. El comentario del código lo justifica: "rebuild ... so late corrections are picked up". Además `autoBroadcastJoinThreshold=-1` obliga a joins con shuffle de tablas de 50 tiendas y de customers. Que el UDF aparezca como `BatchEvalPython` en el plan no se verificó (no se leyó el plan); solo se vio en el código.
- **Impacto:** 5.214 s de ejecutor (35 % de `nb_02`) y creciendo cada carga. Es el siguiente factor tras H2 y el que seguirá creciendo aunque se arregle H2.

### H4 · nb_03 reescribe todo

- **Qué ocurre:** `fact_sales` lee 126 MB → 1.771 MB de entrada y escribe 63 → 759 MB. Se reescriben con `overwrite` `fact_sales`, `dim_customer`, `dim_store`, `dim_product` y `daily_store_sales` en cada ejecución. El shuffle es pequeño (176 MB).
- **Por qué:** código de las celdas 4, 5 y 7 de `nb_03` (E7). El tiempo de `fact_sales` es estable (211–335 s) porque su coste está dominado por la lectura de silver; lo que crece es la lectura de customers (H2).
- **Impacto:** moderado hoy (aporta +90 s en la última ejecución según la serie de E4), pero crecerá linealmente con el histórico.

### H5 · Carga completa o incremental por notebook

| Notebook | Tabla | Carga | Fuente en el código |
|----------|-------|-------|--------------------|
| nb_01 | `sales_raw` | Incremental: 1 día por ejecución (`run_seq` de `ctl_pipeline_runs`), `append` | celda 7 |
| nb_01 | `customer_changes` | Incremental (7 % del universo tras el primer día), `append` | celda 6 |
| nb_01 | `inventory_events` | Incremental: 30 `append` por ejecución | celda 8 |
| nb_01 | `stores_raw`, `products_raw` | Una sola vez (`tableExists`) | celda 5 |
| nb_02 | `customers` | Incremental: `MERGE` solo con cambios `run_seq > last_applied` (la lógica es incremental; el problema está en el layout, H2) | celda 3 |
| nb_02 | `sales` | **Completa**: todo `sales_raw`, `overwrite` | celda 5 |
| nb_02 | `inventory_levels` | **Completa**: agrega todo `inventory_events`, `overwrite` | celda 6 |
| nb_02 | `stores`, `products` | Completa (tablas pequeñas), `overwrite` | celda 4 |
| nb_03 | `fact_sales`, `dim_customer`, `dim_store`, `dim_product`, `daily_store_sales` | **Completa**, `overwrite` con `overwriteSchema` | celdas 4, 5, 7 |
| nb_03 | `dim_date`, `promotions` | Una sola vez (`tableExists`) | celda 6 |
| nb_04 | `sm_sales` | Refresco completo (`refresh_type="full"`) | celda 3 |

### H6 · Ficheros pequeños y commits en bronze

- **Qué ocurre:** `sales_raw` añade 400 ficheros de 0,23 MB por ejecución, `inventory_events` 30 commits y 30 ficheros de pocos KB, `customer_changes` 8 ficheros por ejecución.
- **Por qué:** `repartition(400)` con `optimizeWrite` desactivado en la celda 3/7 de `nb_01`; un `append` por tienda en bucle en la celda 8 (`inventory_stores = 30`).
- **Impacto:** `nb_01` no crece hoy, pero estos ficheros se leen completos cada día en `nb_02` (H3) y condicionan su coste (6.000 ficheros de 0,23 MB frente al umbral de 32 MB). Severidad Baja porque no se midió su efecto aislado.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Compactar `silver.customers`, `gold.dim_customer` y las tablas bronze con ficheros pequeños, y corregir la causa en `nb_02` | H2, H6 | Alto | Bajo | Bajo | Sí |
| R2 | Hacer incremental la reconstrucción de `silver.sales` | H3 | Alto | Medio | Medio | Sí |
| R3 | Hacer incremental `nb_03` (`fact_sales`, `daily_store_sales`) | H4 | Medio | Medio | Medio | Sí |
| R4 | Reducir commits y ficheros en `nb_01` | H6 | Bajo | Bajo | Bajo | Sí |

### R1 · Compactar y corregir el origen de los ficheros pequeños

- **Cambio propuesto** (un humano o `FabricAdmin` lo aplica):

  ```sql
  OPTIMIZE lh_silver.customers;
  OPTIMIZE lh_gold.dim_customer;
  OPTIMIZE lh_bronze.sales_raw;
  OPTIMIZE lh_bronze.inventory_events;
  OPTIMIZE lh_bronze.customer_changes;
  ```

  Y en `nb_02`, celda 2, retirar `spark.sql.shuffle.partitions=2000` y `spark.sql.adaptive.enabled=false` (dejar los valores por defecto del runtime) para que el `MERGE` no escriba ~1.900 ficheros por carga. Programar mantenimiento periódico de las tablas que se reescriben.
- **Impacto esperado:** el tiempo del `MERGE` y las lecturas de customers dependen del número de ficheros (28.149 con 117 MB); compactar a unos pocos ficheros debería devolver ese statement y la celda 5 de `nb_03` a los valores de las primeras ejecuciones (730 s y 268 s de ejecutor, frente a 9.095 s y 3.209 s). Es una estimación basada en E9, no una medición.
- **Cómo validarlo:** repetir el cálculo de ficheros activos de `_delta_log` (E8) y el tiempo de ejecutor por statement (E9) en las 2–3 ejecuciones siguientes; esperar ficheros de `silver.customers` por debajo de unos cientos y que no vuelvan a crecer ~1.900 por carga.
- **Reversión:** `OPTIMIZE` no cambia los datos y se puede deshacer con `RESTORE` a la versión anterior (el log conserva los ficheros hasta el siguiente `VACUUM`); restaurar la configuración Spark es volver a escribir las dos líneas.
- **Requiere confirmación:** Sí, escribe en tablas y consume CU (el agente nunca ejecuta `OPTIMIZE`).

### R2 · Ventas incremental en nb_02

- **Cambio propuesto:** en la celda 5, procesar solo las filas de bronze con `run_seq` mayor que el último aplicado en silver y hacer `MERGE` por `sale_id` (conserva la corrección de datos tardíos para los días tratados) en lugar de `overwrite` completo.

  ```python
  last = spark.sql("SELECT COALESCE(MAX(run_seq),0) FROM lh_silver.sales").first()[0]
  new = spark.read.table("lh_bronze.sales_raw").where(F.col("run_seq") > last)
  # dedup, enrich y classify_note solo sobre `new`; luego
  # DeltaTable.forName(spark, "sales").alias("t").merge(new.alias("s"), "t.sale_id = s.sale_id")...
  ```

  Si hay correcciones tardías que llegan en días posteriores, definir una ventana (por ejemplo los últimos N días) en lugar de todo el histórico.
- **Impacto esperado:** el trabajo por carga pasa a ser el de un día (1 M filas) en lugar del histórico; el shuffle de este statement dejaría de crecer ~800 MB por carga. Estimación basada en E6/E9.
- **Cómo validarlo:** shuffle read del statement de ventas y duración de `nb_02` en las siguientes ejecuciones; debe ser estable y no crecer.
- **Reversión:** volver a la versión anterior del notebook (historial de Fabric o Git).
- **Requiere confirmación:** Sí, modifica un notebook y la semántica de carga; hay que decidir con el dueño del dato cómo se tratan las correcciones tardías.

### R3 · nb_03 incremental

- **Cambio propuesto:** `fact_sales` y `daily_store_sales` actualizados solo para las `sale_date` nuevas (por ejemplo `replaceWhere` por fecha o `MERGE`), y mantener `overwrite` solo en las dimensiones pequeñas una vez compactadas.
- **Impacto esperado:** evita leer y reescribir 1,8 GB (y creciendo) por carga. Menor que R1 y R2 hoy.
- **Cómo validarlo:** input bytes y duración de `nb_03` en las siguientes ejecuciones.
- **Reversión:** versión anterior del notebook.
- **Requiere confirmación:** Sí, cambio de notebook; la tabla alimenta el modelo `sm_sales`.

### R4 · Menos commits y ficheros en nb_01

- **Cambio propuesto:** en la celda 8, construir un único DataFrame (`union` de las 30 tiendas) y escribirlo en un solo `append`; en la celda 7, quitar `repartition(400)` o activar `spark.databricks.delta.optimizeWrite.enabled` para escribir ficheros de tamaño razonable.
- **Impacto esperado:** `inventory_events` de 30 commits a 1 por carga, y `sales_raw` con ficheros más grandes. Reduce el coste de lectura en `nb_02`.
- **Cómo validarlo:** commits por ejecución y tamaño medio de fichero en E8.
- **Reversión:** versión anterior del notebook.
- **Requiere confirmación:** Sí, cambio de notebook.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | `nb_01` (ingesta) es la causa del aumento | E4, E6 | Duración 266–305 s sin tendencia, shuffle (111 MB) y jobs (221–229) planos en 15 ejecuciones; carga incremental (H5) |
| D2 | Retraso por cola o arranque de sesión | E4 | La diferencia entre `activityRunStart` y `runStartTime` es de unos 4 a 27 s en todas las actividades y no crece (por ejemplo 5 nov: 21 s, 4 s, 4 s y 3 s) |
| D3 | Spill a disco | E6 | `diskBytesSpilled` = 0 en las 62 sesiones |
| D4 | `nb_04` (refresco del modelo) crece con el tiempo | E4, E6 | 23–159 s sin tendencia, sin shuffle |

## Siguientes pasos

- [ ] Aplicar R1 (`OPTIMIZE` y configuración de `nb_02`) — responsable: dueño de datos / `FabricAdmin` · relacionado con: R1
- [ ] Decidir la política de correcciones tardías de ventas y aplicar R2 — responsable: ingeniería de datos · relacionado con: R2
- [ ] Planificar mantenimiento periódico de tablas — responsable: ingeniería de datos · relacionado con: R1
- [ ] Repetir el análisis tras 2–3 ejecuciones con R1 y R2 aplicadas para validar el impacto

## Notas

### Limitaciones

- La retención de Spark Monitoring cubría las 62 sesiones (desde el 30 oct 17:05), pero los datos de stages y jobs de Spark caducan en horas o días (`spark-runs.md` § Known traps); si se repite el análisis más tarde, las sesiones más antiguas pueden haber expirado.
- El 30 oct hay 9 ejecuciones manuales seguidas (cargas de días simulados) y el 3 nov una manual a las 08:05. Se incluyen en la tendencia por carga, no por día natural.
- `silver.customers` tiene `delta.enableDeletionVectors=true`. El conteo de ficheros activos no descuenta deletion vectors y no se midió su efecto.
- Dos ejecuciones fallaron en `nb_01` con `DELTA_FAILED_TO_MERGE_FIELDS` (30 oct 18:43 y 1 nov 05:00): no se analizaron en profundidad. La del 1 nov implica que ese día no se cargó.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| `DESCRIBE DETAIL`, `DESCRIBE HISTORY`, `spark.conf.get` efectivos | No se creó sesión Livy: el `_delta_log` ya daba ficheros, bytes y commits, y no cambiaba ninguna conclusión | La configuración Spark efectiva se infiere del código de los notebooks; mecanismo de H2 con confianza Media |
| Plan de ejecución (`BatchEvalPython`) del UDF `classify_note` | No se leyó el plan | La contribución del UDF a H3 no está cuantificada |
| Spark Advisor (`/advice`) y `taskSummary` (skew) | No necesarios para decidir las hipótesis: el crecimiento es de volumen y de ficheros, no de skew (spill 0) | Skew no evaluado |
| Causa de la variación 38 s – 159 s de `nb_04` | Fuera del alcance de la pregunta; sin shuffle ni datos asociados | Sin efecto en las conclusiones |
| Capacidad (CU) | Fuera del alcance | No se evaluó throttling |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Retención de `queryActivityRuns` | `pipeline-diagnosis.md` Step P2 afirma que tiene la retención más larga | `automated-diagnostic-workflow.md` § Data Retention Summary indica retención corta (~1 h) y los job instances duran días | Aquí `queryActivityRuns` devolvió datos de las 17 ejecuciones (hasta 6 días), así que la retención observada es mayor que la documentada. No se contrastó con Microsoft Learn; se registra como observación |

## Anexo

### Consultas completas

- E3/E4: ejecuciones obtenidas con `GET .../jobs/instances`; para cada una, `POST .../queryactivityruns` con `lastUpdatedAfter` = inicio − 1 h y `lastUpdatedBefore` = fin + 1 h.
- E6: para cada `sessionId` de E4, `GET /v1/workspaces/{ws}/notebooks/{nbId}/livySessions/{livyId}/applications/{sparkApplicationId}/jobs` y `/stages`.
- E8: `GET https://onelake.dfs.fabric.microsoft.com/{ws}?resource=filesystem&directory={lakehouseId}/Tables/{tabla}/_delta_log` y lectura de cada `.json` de commit. Ficheros activos = suma de `add` − suma de `remove` hasta el fin de cada ejecución del pipeline.

### Configuración efectiva

Sin datos medidos: no se leyó la configuración efectiva por sesión (ver Notas › Datos no obtenidos). Configuración declarada en el código:

- `nb_02` celda 2: `spark.sql.shuffle.partitions=2000`, `spark.sql.adaptive.enabled=false`, `spark.sql.adaptive.skewJoin.enabled=false`, `spark.sql.autoBroadcastJoinThreshold=-1`.
- `nb_01` celda 3: `spark.databricks.delta.optimizeWrite.enabled=false`, `WRITE_PARTITIONS=400`.
- `nb_03` celda 3: `spark.sql.adaptive.enabled=false`.
