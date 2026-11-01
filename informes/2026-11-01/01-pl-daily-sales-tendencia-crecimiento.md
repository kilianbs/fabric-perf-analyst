# Tendencia de pl_daily_sales: qué crece en cada actividad, cada notebook y cada tabla, y por qué

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-01 (datos recogidos el 2026-10-31 y la comprobación final el 2026-11-01 09:47 UTC) |
| **Áreas** | Spark runs → Delta tables → Spark resources (arranque del pool de gold) |
| **Ámbito** | workspace `FabricPerfLab` · `pl_daily_sales` (12 ejecuciones), los 4 notebooks, 18 tablas Delta de `lh_bronze`, `lh_silver` y `lh_gold` |
| **Ventana analizada** | 2026-10-30 17:11 → 2026-11-01 05:01 UTC (todo el historial del pipeline) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli, sqldw-cli (lakehouse-health) |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** qué crece entre ejecuciones de `pl_daily_sales` (por actividad y por notebook, con shuffle y número de jobs de Spark, y en las tablas Delta: ficheros, commits y checkpoints) y por qué.
- **Conclusión:** entre las 10 ejecuciones correctas, el pipeline pasa de 915 s a 1.573 s (+58,8 s por ejecución, R² 0,78). La mayor parte del aumento está en `Bronze to silver` (Spark 267 → 668 s, +31,9 s por ejecución, R² 0,88). Tiene dos causas medidas.
  1. El `MERGE` sobre `lh_silver.customers`, con AQE desactivado y 2.000 particiones de shuffle, añade ~2.000 ficheros por ejecución. La tabla pasa de 2.000 a 19.433 ficheros de 4,3 KB, con deletion vectors en 13.120 y un 42,9 % de las filas borradas lógicamente. Su celda tarda 108 → 404 s.
  2. La celda de ventas reconstruye `silver.sales` cada día desde todo el histórico de bronze (1 → 10 M filas). El shuffle write sube de 677 a 6.147 MB (+523 MB por ejecución, R² 0,99).

  El número de jobs de Spark no crece (62–79 por ejecución en `Bronze to silver`). Crece el volumen por job. `Silver to gold` no tiene tendencia (R² 0,26); su variación viene de la cola del pool propio.
- **Impacto:** +658 s por ejecución en 10 días de negocio, y creciendo de forma lineal. Además, **la ejecución programada del 2026-11-01 05:00 UTC (`run_seq` 12) ya ha fallado** en `Ingest bronze` con `DELTA_FAILED_TO_MERGE_FIELDS` sobre `amount`. Es el mismo error de la ejecución 6, y dos días de negocio (2026-09-06 y 2026-09-12) se quedan sin ventas.
- **Primera acción:** R2 (evitar la deriva de `amount` y mover la fila de control al final), porque el pipeline falla cada 6 ejecuciones. Después R1 (compactar `customers` y recuperar AQE en silver) para el mayor contribuyente al crecimiento. Ambas requieren confirmación.

## Alcance

**Pregunta original:** "El pipeline pl_daily_sales del workspace FabricPerfLab tarda cada día más. No me vale un umbral de regresión: quiero la tendencia de cada actividad y de cada notebook entre ejecuciones, incluido el shuffle y el número de jobs de Spark. Revisa cómo lee y escribe cada notebook (carga completa o incremental) y cómo evolucionan las tablas que toca (ficheros, commits y checkpoints del _delta_log). ¿Qué crece y por qué?"

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Las 12 ejecuciones de `pl_daily_sales` (10 correctas, 2 fallidas) y 41 ejecuciones de actividad con detalle completo. | `pl_store_snapshot` y `nb_05`: solo se comprobó que no se solapan (E27). |
| Código de los 4 notebooks (getDefinition, pedido por el usuario), environments y pools. | Diagnóstico de `sm_sales`: solo su historial de refrescos (E24). |
| Jobs, stages, Advisor y cuantiles de tareas de las 41 sesiones. | Coste en moneda: no se llamó a la API de precios. |
| `_delta_log` completo de 18 tablas y procedimiento de salud en 4. | Sesión Livy: no se ejecutó (justificado en Notas › Datos no obtenidos). |

**Hipótesis de partida:** (a) carga completa que crece con el histórico; (b) fragmentación de tablas, más ficheros y commits sin checkpoint; (c) más jobs, spill o skew; (d) presión de capacidad o colas.

**Recorrido:** Spark runs: la serie por actividad localiza el crecimiento en `Bronze to silver` (E5). Los stages y el Advisor (E10–E13) señalan lecturas de `customers` con muchos ficheros pequeños → Delta tables, para leer el `_delta_log` y el procedimiento de salud (E14–E20). En `Silver to gold` la duración apenas depende de los jobs → Spark resources, para medir cola y pool (E8, E22, E23).

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad | `FTL64` · West Europe · Active | E2 |
| Runtime de Spark | 1.3 en las 41 sesiones | E8 |
| Environment / pool | bronze y silver: Starter Pool (Medium, 8 cores, ejecutores 1–4). gold: `pool_gold_xl` (Large, 16 cores, autoescala 1–4 nodos, asignación dinámica desactivada en el environment) | E22, E23 |
| Configuración Spark | `env_silver` y `nb_02`: AQE off, skewJoin off, `autoBroadcastJoinThreshold=-1`, `shuffle.partitions=2000`. `nb_03`: AQE off. `nb_01`: optimize write off, `repartition(400)`. bronze: `readHeavyForPBI` con V-Order. gold: `writeHeavy` sin V-Order | E7, E22 |
| Alta concurrencia en pipelines | Desactivada: una sesión por actividad | E23 |
| Programación | Diaria 06:00 Romance Standard Time (05:00 UTC), activa hasta 2026-11-30 | E26 |
| Permisos con los que se ejecutó | Lectura de items, monitorización, OneLake, endpoint SQL y Power BI; ninguna llamada devolvió 401/403 | E1–E29 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| `pl_daily_sales` | DataPipeline | 4 notebooks en serie | `bd706b1d-499f-4a0d-bb22-222312944ca1` |
| `nb_01_ingest_bronze` | Notebook | Bronze | `4240632d-3ce1-422f-a1b2-ddb55d8736e0` |
| `nb_02_bronze_to_silver` | Notebook | Silver | `4205418f-cee2-4a3d-9390-328618160264` |
| `nb_03_silver_to_gold` | Notebook | Gold | `c7cca4b7-3722-4bec-9946-504520f6be21` |
| `nb_04_refresh_model` | Notebook | Refresco de `sm_sales` | `3a609552-4721-406a-8e9c-f801c0a43b59` |
| `lh_bronze` / `lh_silver` / `lh_gold` | Lakehouse | Almacenamiento | `53249a1b-…`, `b01f7911-…`, `3aee923d-…` |
| `sm_sales` | SemanticModel | Consumidor (solo refrescos) | `a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9` |

### Cómo lee y escribe cada notebook (E7)

| Notebook | Lee | Escribe | Tipo de carga |
|----------|-----|---------|---------------|
| `nb_01` | `ctl_pipeline_runs` (`MAX(run_seq)`) | `ctl_pipeline_runs` (append de 1 fila **al principio**); `customer_changes` (append: 200.000 filas el primer día y luego ~14.000); `sales_raw` (append de 1 M filas con `repartition(400)`); `inventory_events` (30 appends de 200 filas, uno por tienda; tabla con `delta.checkpointInterval=1000`) | Incremental (append). Si `run_seq % 6 == 0`, convierte `amount` en texto |
| `nb_02` | `customer_changes` incremental; **`sales_raw` completo**; **`inventory_events` completo** | `customers` (`MERGE` con deletion vectors); `stores` y `products` (overwrite); **`sales` (overwrite de todo el histórico: `row_number()` por `sale_id`, joins sin broadcast, `repartitionByRange(64)`, UDF de Python)**; `inventory_levels` (overwrite) | `customers` incremental; el resto, **carga completa** |
| `nb_03` | `silver.sales` completo, `products`, `customers`, `stores` | `fact_sales`, `dim_*`, `daily_store_sales` (overwrite con `overwriteSchema`). Si `run_seq % 4 == 0`, renombra `category` → `product_category` en `dim_product` | **Carga completa** |
| `nb_04` | — | Pide un refresco `full` de `sm_sales`; si falla, captura la excepción y solo imprime un aviso | No espera el resultado |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Duración del pipeline (10 ejecuciones correctas) | 915 → 1.573 s; +58,8 s por ejecución, R² 0,78 | Regla de la skill (última frente a mediana de las 5 anteriores > 2×): 1.573/1.338 = 1,18×, no marcaría regresión | E4 |
| Spark de `Bronze to silver` | 267 → 668 s; +31,9 s por ejecución, R² 0,88 | — | E5 |
| Shuffle write de `Bronze to silver` | 677 → 6.147 MB; +522,8 MB por ejecución, R² 0,99 | — | E10 |
| Máximo shuffle write de un stage | 230 → 1.872 MB; > 1 GB desde la ejecución 5 | > 1 GB por stage = MEDIUM (`diagnostic-workflow.md` § Severity Thresholds) | E10 |
| Tiempo de ejecutor de `Bronze to silver` | 1.938 → 11.511 s·tarea; R² 0,93 | — | E10 |
| Jobs de Spark | Ingest 218–229; Bronze→silver 62–79; Silver→gold 52–55; Refresh 0–5 | Sin tendencia (≤ 0,6 jobs por ejecución) | E9 |
| Celda `MERGE` de `customers` | 108 → 404 s; +20,3 s por ejecución, R² 0,71 | — | E11 |
| Celda de ventas | 64 → 173 s; +10,9 s por ejecución, R² 0,99 | — | E11 |
| Ficheros de `lh_silver.customers` | 2.000 → 19.433 (4,3 KB de media); 13.120 con DV; 127.225 de 296.452 filas borradas (42,9 %) | Anomalía 2 y media < 32 MB (`lakehouse-health.md`; `performance-patterns.md` § Small File Problem) | E15–E17 |
| Ficheros de `lh_bronze.sales_raw` | 400 → 4.000 (234 KB de media) | Anomalía 3 (`lakehouse-health.md`) | E15, E18 |
| `lh_bronze.inventory_events` | 301 commits JSON, sin checkpoint en `_delta_log` | Anomalía 3 | E14, E19 |
| Skew en `Bronze to silver` (ejecución 11) | Stage 127: máximo/mediana 5.451/1 ms, una tarea lee 684 MB. Stage 140: 3,9× | > 3× = HIGH (`diagnostic-workflow.md`) | E12, E13 |
| Spill y GC | 0 bytes de spill en 41 sesiones; GC ≤ 0,95 % del tiempo de ejecutor | Spill > 0 y GC > 20 % = MEDIUM: no se superan | E10 |
| Cola del pool de gold | `queuedDuration` 61–287 s; jobs activos 46–80 s de sesiones de 290–686 s | Pool propio grande: 3–6 min en frío (`session-health.md`) | E8, E11 |

### Series por ejecución

Duración de actividad = `durationInMs`; Spark = `runEndTime − runStartTime`; arranque = `runStartTime − activityRunStart` (`spark-runs.md` § Known traps).

Pipeline (segundos):

| # | Run | Inicio actividad 1 (UTC) | Estado | Pipeline | Ingest | Bronze→silver | Silver→gold | Refresh |
|---|-----|--------------------------|--------|----------|--------|---------------|-------------|---------|
| 1 | `4355527f` | 10-30 17:11 | Completed | 915 | 222 | 280 | 342 | 54 |
| 2 | `d479707c` | 10-30 17:27 | Completed | 1160 | 220 | 458 | 343 | 127 |
| 3 | `9461100c` | 10-30 17:46 | Completed | 977 | 157 | 458 | 309 | 35 |
| 4 | `afc9f93f` | 10-30 18:03 | Completed | 1215 | 203 | 522 | 436 | 36 |
| 5 | `18ce7b9a` | 10-30 18:24 | Completed | 1118 | 189 | 520 | 339 | 58 |
| 6 | `1c7c087c` | 10-30 18:43 | **Failed** | 62 | 52 | — | — | — |
| 7 | `5afbd9f3` | 10-30 18:44 | Completed | 1338 | 232 | 579 | 369 | 144 |
| 8 | `639635f9` | 10-30 19:07 | Completed | 1405 | 189 | 639 | 524 | 38 |
| 9 | `007a944c` | 10-30 19:30 | Completed | 1221 | 202 | 611 | 370 | 23 |
| 10 | `a7e0b3a4` | 10-30 19:51 | Completed | 1622 | 218 | 650 | 704 | 37 |
| 11 | `524c4c37` | 10-31 05:00 | Completed | 1573 | 301 | 701 | 373 | 159 |
| 12 | `5d856136` | 11-01 05:00 | **Failed** | ~79 | 70 | — | — | — |

`nb_01` / `Ingest bronze`:

| # | Act. (s) | Spark (s) | Arranque (s) | Jobs | Stages | Tareas | Shuffle W (MB) | Shuffle R (MB) | Input (MB) | Output (MB) | Ejecutor (s·tarea) | GC (s) | Spill |
|---|----------|-----------|--------------|------|--------|--------|----------------|----------------|------------|-------------|--------------------|--------|-------|
| 1 | 222 | 196 | 22 | 229 | 307 | 1791 | 116 | 116 | 1 | 100 | 296 | 6 | 0 |
| 2 | 220 | 207 | 6 | 218 | 294 | 1812 | 116 | 116 | 3 | 96 | 363 | 9 | 0 |
| 3 | 157 | 142 | 4 | 218 | 294 | 1600 | 116 | 116 | 5 | 96 | 277 | 6 | 0 |
| 4 | 203 | 187 | 3 | 218 | 294 | 1612 | 116 | 116 | 7 | 96 | 347 | 10 | 0 |
| 5 | 189 | 175 | 3 | 218 | 294 | 1624 | 116 | 116 | 9 | 96 | 342 | 8 | 0 |
| 6 | 52 | 42 | 3 | 30 | 43 | 302 | 0 | 0 | 3 | 0 | 43 | 1 | 0 |
| 7 | 232 | 223 | 3 | 218 | 294 | 1930 | 116 | 116 | 11 | 96 | 456 | 13 | 0 |
| 8 | 189 | 174 | 4 | 218 | 294 | 1654 | 116 | 116 | 13 | 96 | 397 | 11 | 0 |
| 9 | 202 | 187 | 4 | 218 | 294 | 1689 | 116 | 116 | 15 | 96 | 456 | 11 | 0 |
| 10 | 218 | 206 | 3 | 223 | 305 | 2062 | 116 | 116 | 17 | 96 | 511 | 15 | 0 |
| 11 | 301 | 230 | 68 | 224 | 306 | 2064 | 116 | 116 | 20 | 96 | 589 | 12 | 0 |

`nb_02` / `Bronze to silver`:

| # | Act. (s) | Spark (s) | Arranque (s) | Jobs | Stages | Tareas | Shuffle W (MB) | Shuffle R (MB) | Máx. shuffle W/stage (MB) | Input (MB) | Output (MB) | Ejecutor (s·tarea) | GC (s) | Spill |
|---|----------|-----------|--------------|------|--------|--------|----------------|----------------|---------------------------|------------|-------------|--------------------|--------|-------|
| 1 | 280 | 267 | 5 | 62 | 120 | 39546 | 677 | 955 | 230 | 138 | 103 | 1938 | 26 | 0 |
| 2 | 458 | 429 | 3 | 76 | 165 | 58834 | 1324 | 1850 | 446 | 279 | 180 | 4723 | 51 | 0 |
| 3 | 458 | 451 | 3 | 77 | 167 | 59450 | 1947 | 2714 | 649 | 443 | 255 | 5958 | 60 | 0 |
| 4 | 522 | 501 | 7 | 76 | 165 | 57850 | 2563 | 3566 | 842 | 662 | 330 | 6299 | 66 | 0 |
| 5 | 520 | 495 | 4 | 75 | 160 | 50094 | 3162 | 4409 | 1026 | 730 | 405 | 6644 | 71 | 0 |
| 7 | 579 | 567 | 3 | 74 | 158 | 50499 | 3769 | 5255 | 1205 | 974 | 480 | 8289 | 87 | 0 |
| 8 | 639 | 618 | 4 | 76 | 165 | 59254 | 4375 | 6090 | 1377 | 1167 | 553 | 9565 | 91 | 0 |
| 9 | 611 | 599 | 5 | 74 | 158 | 51246 | 4958 | 6922 | 1546 | 1313 | 627 | 8876 | 93 | 0 |
| 10 | 650 | 617 | 13 | 74 | 158 | 51645 | 5548 | 7750 | 1711 | 1538 | 699 | 10017 | 99 | 0 |
| 11 | 701 | 668 | 5 | 79 | 167 | 52132 | 6147 | 8588 | 1872 | 1595 | 772 | 11511 | 109 | 0 |

Tiempo de jobs por celda de `nb_02` (s):

| Celda | 1 | 2 | 3 | 4 | 5 | 7 | 8 | 9 | 10 | 11 |
|-------|---|---|---|---|---|---|---|---|----|----|
| 4 · `MERGE` de `customers` | 108 | 271 | 286 | 301 | 295 | 341 | 394 | 347 | 355 | 404 |
| 6 · `sales` desde todo el histórico | 64 | 73 | 83 | 104 | 111 | 129 | 133 | 150 | 168 | 173 |
| 6 · shuffle write (MB) | 668 | 1306 | 1923 | 2535 | 3139 | 3738 | 4331 | 4922 | 5508 | 6085 |
| 7 · `inventory_levels` | 37 | 25 | 23 | 29 | 24 | 24 | 28 | 26 | 26 | 32 |
| 5 · referencia | 24 | 22 | 18 | 18 | 20 | 26 | 20 | 31 | 19 | 16 |

`nb_03` / `Silver to gold`:

| # | Act. (s) | Spark (s) | Arranque (s) | Jobs | Stages | Tareas | Shuffle W (MB) | Input (MB) | Output (MB) | Ejecutor (s·tarea) | GC (s) | Cola `queuedDuration` (s) |
|---|----------|-----------|--------------|------|--------|--------|----------------|------------|-------------|--------------------|--------|---------------------------|
| 1 | 342 | 314 | 4 | 52 | 82 | 3134 | 19 | 132 | 67 | 797 | 22 | 62 |
| 2 | 343 | 326 | 6 | 53 | 99 | 3241 | 36 | 287 | 126 | 1037 | 42 | 98 |
| 3 | 309 | 291 | 3 | 53 | 99 | 3357 | 53 | 441 | 184 | 1313 | 48 | 71 |
| 4 | 436 | 421 | 4 | 53 | 98 | 3262 | 55 | 573 | 239 | 1432 | 30 | 137 |
| 5 | 339 | 308 | 3 | 53 | 98 | 3364 | 69 | 700 | 293 | 1758 | 29 | 66 |
| 7 | 369 | 342 | 3 | 53 | 98 | 3469 | 82 | 850 | 346 | 1869 | 30 | 61 |
| 8 | 524 | 495 | 4 | 53 | 98 | 3570 | 95 | 987 | 399 | 2008 | 32 | 287 |
| 9 | 370 | 336 | 4 | 53 | 98 | 3670 | 107 | 1122 | 452 | 2362 | 35 | 76 |
| 10 | 704 | 686 | 3 | 54 | 99 | 3743 | 120 | 1190 | 504 | 2446 | 36 | 215 |
| 11 | 373 | 354 | 4 | 55 | 100 | 3783 | 125 | 1246 | 556 | 2680 | 41 | 76 |

`nb_04` / `Refresh semantic model`: duración 23–159 s; jobs 5 (ejecuciones 1, 3, 4, 5, 8, 9, 10) o 0 (2, 7, 11). Las tres con 0 jobs son las más lentas (127, 144 y 159 s). Shuffle 0 y ejecutor ≤ 10 s·tarea.

### Evolución de las tablas (`_delta_log` en OneLake)

`lh_silver.customers`, versión a versión. Los ficheros vivos se cuentan por `path` + deletion vector, y coinciden con `numOfAddFiles` = 19.433 del checkpoint v10 (E16):

| Versión | Commit (UTC) | Operación | add | remove | Ficheros vivos | Con DV | Filas físicas | Filas borradas por DV | Commit JSON (bytes) | `executionTimeMs` |
|---------|--------------|-----------|-----|--------|----------------|--------|---------------|-----------------------|---------------------|-------------------|
| 0 | 10-30 17:15 | CREATE TABLE | 0 | 0 | 0 | 0 | 0 | 0 | 1461 | — |
| 1 | 17:17 | MERGE | 2000 | 0 | 2000 | 0 | 200000 | 0 | 1514572 | 80785 |
| 2 | 17:35 | MERGE | 3982 | 1999 | 3983 | 1999 | 209848 | 14015 | 3984507 | 92828 |
| 3 | 17:54 | MERGE | 4575 | 2588 | 5970 | 2589 | 219685 | 27690 | 4962104 | 96251 |
| 4 | 18:12 | MERGE | 5103 | 3134 | 7939 | 3549 | 229473 | 41096 | 5646741 | 128283 |
| 5 | 18:32 | MERGE | 5576 | 3617 | 9898 | 4741 | 239238 | 54267 | 6266406 | 163563 |
| 6 | 18:54 | MERGE | 7601 | 5691 | 11808 | 7129 | 258140 | 79146 | 8894229 | 172425 |
| 7 | 19:16 | MERGE | 6797 | 4862 | 13743 | 8723 | 267865 | 91635 | 7892952 | 126877 |
| 8 | 19:40 | MERGE | 7053 | 5140 | 15656 | 10115 | 277373 | 103588 | 8276323 | 177995 |
| 9 | 20:01 | MERGE | 7424 | 5535 | 17545 | 11576 | 286829 | 115410 | 8787486 | 177939 |
| 10 | 10-31 05:12 | MERGE | 7885 | 5997 | 19433 | 13120 | 296452 | 127225 | 9406414 | 195852 |

Las 18 tablas (versión actual, commits JSON, checkpoint, ficheros de v0 a la actual):

| Tabla | Versión | Commits JSON | Checkpoint en `_delta_log` | Ficheros v0 → actual | Tamaño medio | Filas | Escritura |
|-------|---------|--------------|----------------------------|----------------------|--------------|-------|-----------|
| bronze.ctl_pipeline_runs | 11 | 12 | v10 | 1 → 11 | ~0 KB | 11 | append |
| bronze.stores_raw | 0 | 1 | ninguno | 8 → 8 | ~0 KB | 50 | una vez |
| bronze.products_raw | 0 | 1 | ninguno | 8 → 8 | 12 KB | 5.000 | una vez |
| bronze.customer_changes | 10 | 11 | v10 | 8 → 88 | 79 KB | 339.884 | append |
| bronze.sales_raw | 9 | 10 | ninguno | 400 → 4.000 | 234 KB | 10 M | append |
| bronze.inventory_events | 300 | 301 | **ninguno** | 1 → 300 | 4,6 KB | 60.000 | 30 appends por ejecución |
| silver.customers | 10 | 11 | v10 | 2.000 → 19.433 | 4,3 KB | 169.227 lógicas | MERGE |
| silver.stores | 9 | 10 | ninguno | 8 → 8 | ~0 KB | 50 | overwrite |
| silver.products | 9 | 10 | ninguno | 8 → 8 | 12 KB | 5.000 | overwrite |
| silver.sales | 9 | 10 | ninguno | 64 → 64 | 11,5 MB | 10 M | overwrite completo (84 → 757 MB) |
| silver.inventory_levels | 9 | 10 | ninguno | 1.897 → 2.000 | 3,3 KB | 49.337 | overwrite |
| gold.fact_sales | 9 | 10 | ninguno | 33 → 64 | 8,4 MB | 10 M | overwrite completo (61 → 549 MB) |
| gold.dim_customer | 9 | 10 | ninguno | 63 → 608 | 10 KB | 169.227 | overwrite |
| gold.dim_store | 9 | 10 | ninguno | 8 → 8 | ~0 KB | 50 | overwrite |
| gold.dim_product | 9 | 10 | ninguno | 8 → 8 | 12 KB | 5.000 | overwrite; esquema alterna `category` / `product_category` |
| gold.dim_date | 0 | 1 | ninguno | 1 | ~0 KB | 730 | una vez |
| gold.promotions | 0 | 1 | ninguno | 2 | ~0 KB | 2.052 | una vez |
| gold.daily_store_sales | 9 | 10 | ninguno | 44 → 185 | 3,2 KB | 500 | overwrite |

Solo hay checkpoint (v10) en `ctl_pipeline_runs`, `customer_changes` y `customers`. `inventory_events` crea 30 commits por ejecución (bloques de 30 commits: 101 s en v1–30 → 147 s en v271–300) y no tendrá checkpoint hasta la versión 1.000. El `_delta_log` de las demás tablas aún es corto.

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces` (filtro `FabricPerfLab`) | `23ca4a73-3312-4242-9714-0289816895aa` |
| E2 | REST | `GET /v1/capacities` | `FTL64`, West Europe, Active |
| E3 | REST | `GET /v1/workspaces/{ws}/items` | 17 items |
| E4 | REST | `GET …/items/{pl_daily_sales}/jobs/instances` | 11 instancias el 2026-10-31 (10 `Completed`, 1 `Failed`), sin `continuationToken`. Segunda lectura el 2026-11-01: aparece la 12ª, `Scheduled`, `Failed` (E29) |
| E5 | REST | `POST …/datapipelines/pipelineruns/{runId}/queryactivityruns` × 11 | 41 actividades `TridentNotebook`, sin reintentos ni alta concurrencia |
| E6 | REST | E5 del run `1c7c087c` | `AnalysisException [DELTA_FAILED_TO_MERGE_FIELDS] Failed to merge fields 'amount' and 'amount'` en `Cell In[26], line 30` (`saveAsTable("sales_raw")`); `failureType` UserError, `errorCode` 2451 |
| E7 | REST | `POST …/notebooks/{id}/getDefinition` × 4 + LRO | Código de los 4 notebooks |
| E8 | REST | `GET …/notebooks/{nb}/livySessions/{livyId}` × 41 | Runtime 1.3; gold con 3 ejecutores de 16 cores; `queuedDuration` 61–287 s |
| E9 | REST | `GET …/applications/{appId}/jobs` × 41 | Jobs en las series. Hay jobs `FAILED` aislados (uno por sesión) en `Bronze to silver` de las ejecuciones 2, 3, 4 y 8, con la actividad `Succeeded` |
| E10 | REST | `GET …/applications/{appId}/stages` × 41 | Shuffle, input/output, ejecutor, GC y spill |
| E11 | Cálculo | Agregación de E9/E10 por sentencia | Tiempos por celda; jobs activos de `Silver to gold`: 46, 55, 50, 59, 60, 69, 66, 80, 79, 79 s |
| E12 | REST | `GET …/applications/{appId}/advice` (`Bronze to silver` ejecuciones 1 y 11; `Silver to gold` ejecución 10) | Ejecución 11: compactar `lh_silver.customers` (6 info) y skew en jobs 62–64 (warn; stage 127: máximo 652,17 MB frente a media 0,58 MB). Ejecución 1: compactar `lh_bronze.sales_raw` y skew en jobs 47–49 |
| E13 | REST | `GET …/stages/{id}/0/taskSummary?quantiles=0.5,0.95,1.0` (stages 127, 123, 140, 19 de la ejecución 11) | 127: [1; 14; 5.451] ms, shuffle read máximo 683.850.104 B. 140: [6.147; 18.576; 23.821] ms. 123: [2.925; 4.077; 4.964] ms para ~90 KB por tarea. 19: [3.556; 5.307; 9.216] ms |
| E14 | OneLake | Listado de `_delta_log` × 18 tablas | Commits y checkpoints (tabla anterior) |
| E15 | OneLake | Lectura de todas las versiones JSON de las 18 tablas | add/remove, DV, `operationMetrics`, tamaño de commit |
| E16 | OneLake | `customers/_delta_log/_last_checkpoint` | version 10, `numOfAddFiles` 19.433, `sizeInBytes` 4.053.355 |
| E17 | SQL | `EXEC sys.sp_get_table_health_metrics 'dbo.customers'` (endpoint `lh_silver`) | Anomalía 2 "Too many deleted rows detected…"; snapshot 10; 296.452 filas, 127.225 borradas; 19.433 ficheros, 13.120 bitmaps; todos en [1 KiB, 16 KiB) |
| E18 | SQL | Ídem `dbo.sales_raw` (`lh_bronze`) | Anomalía 3; 4.000 ficheros en [16 KiB, 256 KiB); 10 M filas |
| E19 | SQL | Ídem `dbo.inventory_events` | Anomalía 3; snapshot 298; `CheckpointVersion` 297; 300 ficheros |
| E20 | SQL | Ídem `dbo.inventory_levels` (`lh_silver`) | Anomalía 3; 2.000 ficheros (1.999 con 10–99 filas) para 49.337 filas |
| E21 | SQL | `SELECT TOP 20` de `ctl_pipeline_runs` con recuento por `run_seq` en `sales_raw` y `customer_changes` (en el Anexo) | `run_seq` 6 (2026-09-06): 13.958 cambios de clientes y **ninguna fila de ventas**; el resto, 1.000.000 |
| E22 | REST | `GET …/environments/{id}/sparkcompute` × 3 | Configuración por capa (Anexo) |
| E23 | REST | `GET …/spark/pools` y `…/spark/settings` | Starter Pool Medium 1–10 nodos; `pool_gold_xl` Large 1–4 nodos; alta concurrencia en pipelines desactivada |
| E24 | REST (Power BI) | `GET /v1.0/myorg/groups/{ws}/datasets/{sm_sales}/refreshes?$top=20` | 2 refrescos `Failed` (10-30 18:42:16 y 19:50:58) con "The 'category' column does not exist in the rowset.", ambos `ViaEnhancedApi` |
| E25 | OneLake | `dim_product/_delta_log/{v}.json` v0–v9 | `product_category` en v3 (18:22) y v6 (19:29); `category` en v0, v4 y v7 |
| E26 | REST | `GET …/items/{pl}/jobs/Pipeline/schedules` | Diaria 06:00 Romance Standard Time, activa |
| E27 | REST | `GET …/items/{pl_store_snapshot}/jobs/instances` | 2 ejecuciones `Failed` el 10-30 20:18–20:26 UTC, sin solape con `pl_daily_sales` |
| E28 | Learn | `microsoft_docs_search` sobre retención de `queryActivityRuns` y de las API de Spark | Learn no documenta la retención por API; el Monitoring Hub conserva 30 días |
| E29 | REST | E4 y E5 de la ejecución `5d856136` (2026-11-01 05:00:02 → 05:01:21 UTC, Scheduled) | `Ingest bronze` Failed, 70 s, `AnalysisException [DELTA_FAILED_TO_MERGE_FIELDS] Failed to merge fields 'amount' and 'amount'`; el resto de actividades no se ejecutó |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | `MERGE` de `customers` con AQE desactivado y 2.000 particiones: 19.433 ficheros diminutos con DV; su celda crece +296 s | Alta | Alta | E7, E11–E13, E15–E17, E22 |
| H2 | `silver.sales` y `gold.fact_sales` se reconstruyen cada día desde todo el histórico: shuffle +523 MB por ejecución | Alta | Alta | E7, E10, E11, E15 |
| H3 | Skew sin mitigar en el join por `store_id` y en la UDF (stage 127: 5.451×; stage 140: 3,9×) | Alta | Alta | E7, E12, E13, E22 |
| H4 | La deriva de `amount` rompe el pipeline cada 6 ejecuciones: ya falló dos veces (`run_seq` 6 y 12) y dejó 2 días sin ventas | Alta | Alta | E6, E7, E21, E29 |
| H5 | Ficheros pequeños y commits sin checkpoint en bronze y agregados: `sales_raw` +400 ficheros por ejecución, `inventory_events` 30 commits por ejecución, `inventory_levels` 2.000 ficheros | Media | Alta | E7, E14, E15, E18–E20 |
| H6 | El refresco de `sm_sales` falló 2 veces sin que el pipeline lo detectara | Media | Media | E7, E24, E25 |
| H7 | `Silver to gold` no tiene tendencia; su variación es la cola del pool propio (61–287 s) | Baja | Media | E8, E11, E22, E23 |

### H1 · `customers` se fragmenta con cada `MERGE` y su celda es la que más crece

- **Qué ocurre:** la celda 4 de `nb_02` pasa de 108 a 404 s (+296 s de los +401 s de Spark de `Bronze to silver`, E11). El `executionTimeMs` del `MERGE` pasa de 80.785 a 195.852 ms (E15). En la ejecución 11, el stage que calcula `MAX(source_run_seq)` sobre `customers` (stage 19, 549 tareas) tarda 158 s de reloj para leer 48 MB: 3,6–9,2 s por tarea para ~90 KB (E13). La tabla se lee de nuevo en el join de ventas (stage 123, 1.810 s·tarea) y en `nb_03`, donde la celda de `dim_customer` pasa de 23 a 63 s (E11). El Advisor recomienda compactarla (E12).
- **Por qué:** `env_silver` y la primera celda de `nb_02` fijan `shuffle.partitions=2000` y AQE desactivado (E7, E22). Cada `MERGE` escribe ~2.000 ficheros (`numTargetFilesAdded` 1.979–2.000) aunque solo cambian ~9.800 filas, y nada los compacta. Con deletion vectors activos, las actualizaciones y borrados no reescriben ficheros: marcan DV sobre los existentes. El resultado son 19.433 ficheros de 4,3 KB, 13.120 con DV y un 42,9 % de filas borradas (E15–E17). Cada commit reescribe además miles de acciones: el JSON pasa de 1,51 a 9,41 MB. El procedimiento de salud devuelve la anomalía 2, y 4,3 KB de media está muy por debajo de los 32 MB de `performance-patterns.md` § Small File Problem.
- **Impacto:** +20,3 s por ejecución en la celda (R² 0,71), más la lectura repetida en otras dos celdas. La tabla gana ~1.900 ficheros por día. Severidad Alta: es el mayor contribuyente medido, con anomalía confirmada por el procedimiento y por el Advisor.

### H2 · Carga completa del histórico en `silver.sales` y `gold.fact_sales`

- **Qué ocurre:** la celda 6 de `nb_02` lee todo `sales_raw`, deduplica por `sale_id` sobre todo el histórico, hace los joins y sobrescribe `silver.sales` (E7). Las filas crecen 1 M por día (1 → 10 M; 84 → 757 MB, E15). El shuffle write del notebook sube de 677 a 6.147 MB (+522,8 MB por ejecución, R² 0,99) y el stage más pesado supera 1 GB desde la ejecución 5 (E10). La celda pasa de 64 a 173 s (R² 0,99, E11). `fact_sales` también se sobrescribe entera (61 → 549 MB), y el tiempo de ejecutor de `nb_03` crece de 797 a 2.680 s·tarea (R² 0,98). Su reloj crece menos porque tiene 48 cores casi ociosos (ver `2026-10-31/01-gold-spark-sobredimensionado.md`).
- **Por qué:** la deduplicación recoge "correcciones tardías" (comentario del código, E7), pero bronze solo hace `append` y `sale_id` es un `uuid()` nuevo por fila. La deduplicación nunca encuentra duplicados: 10 M filas antes y después (E15). Es trabajo creciente que no cambia el resultado.
- **Impacto:** es la única componente con crecimiento perfectamente lineal. Extrapolando la recta de E10 (no es una medición), en 30 días de negocio el shuffle rondaría los 16 GB por ejecución. Severidad Alta: supera 1 GB por stage (MEDIUM) en 6 de 10 ejecuciones y no tiene tope.

### H3 · Skew sin mitigar en el join por tienda y en la UDF

- **Qué ocurre:** en la ejecución 11, el Advisor marca skew en los jobs 62–64. En el stage 127 una tarea lee 652 MB frente a una media de 0,58 MB; los cuantiles dan 1 ms de mediana y 5.451 ms de máximo (E12, E13). En el stage 140 (tras la UDF), 6,1 s de mediana y 23,8 s de máximo (3,9×). La ejecución 1 ya mostraba el patrón (E12).
- **Por qué:** el 60 % de las ventas son de `store_id = 1` (E7). Con `autoBroadcastJoinThreshold=-1` y AQE y skewJoin desactivados (E7, E22), el join con `stores` (50 filas) es un sort-merge y una partición carga con la tienda 1. `classify_note` es una UDF de Python con 100 `re.sub` para los comentarios de las 22–23 h, que tras `repartitionByRange(64, "sale_ts")` caen en pocas particiones.
- **Impacto:** hoy suman unos 30 s de reloj (E10), pero las tareas dominantes crecen con el histórico (H2). Severidad Alta por el umbral (> 3× = HIGH, `diagnostic-workflow.md`); el coste actual es menor que el de H1 y H2.

### H4 · La deriva de esquema rompe el pipeline cada 6 ejecuciones y deja días sin ventas

- **Qué ocurre:** `Ingest bronze` falló con `DELTA_FAILED_TO_MERGE_FIELDS` sobre `amount` en `run_seq` 6 (E6) y otra vez en `run_seq` 12, la ejecución programada del 2026-11-01 05:00 UTC (E29). Es un error de código de usuario (`failureType` UserError, traceback en `Cell In[26]`; `pipeline-diagnosis.md` Step P4c). Tras el fallo del `run_seq` 6, el 2026-09-06 no tiene ventas en `sales_raw`, pero sus 13.958 cambios de clientes sí se aplicaron (E21, E15). La ejecución 12 ya dejó fuera el 2026-09-12 y, al fallar en la primera actividad, ni silver, ni gold ni el refresco se ejecutaron (E29).
- **Por qué:** `schema_drift_every = 6` convierte `amount` en texto cuando `run_seq % 6 == 0` (E7). La fila de control se escribe al principio, no al terminar, así que cada ejecución fallida consume un `run_seq` y un día de negocio.
- **Impacto:** fallo determinista y pérdida de datos de negocio. Con la programación diaria, volverá a ocurrir en `run_seq` 18, y los días fallidos no se recuperan solos. Severidad Alta. No es un problema de rendimiento, pero altera la serie: las duraciones de las ejecuciones 6 y 12 (62 y ~79 s) no son comparables.

### H5 · Ficheros pequeños y commits sin checkpoint en bronze y en los agregados

- **Qué ocurre:** `sales_raw` gana 400 ficheros de ~240 KB por ejecución (4.000 en v9, anomalía 3, E18) y `nb_02` los lee todos. `inventory_events` recibe 30 commits por ejecución con 1 fichero de 200 filas cada uno y acumula 301 versiones sin checkpoint (E14). El tramo de 30 commits pasa de 101 a 147 s y la celda de inventario de `nb_01` de 104 a 150 s (E11, E15). `inventory_levels` escribe 2.000 ficheros (1.999 con menos de 100 filas) para 49.337 filas (E20), y `daily_store_sales` 185 ficheros para 500 filas (E15).
- **Por qué:** `nb_01` hace `repartition(400)` con optimize write desactivado y un `write` por tienda. La tabla se creó con `delta.checkpointInterval=1000` (E7, E15), así que no habrá checkpoint hasta la versión 1.000 (~33 ejecuciones) y cada append reconstruye el estado leyendo todos los JSON. `inventory_levels` hereda las 2.000 particiones de shuffle de silver, y `daily_store_sales` las 200 por defecto con AQE desactivado (E7).
- **Impacto:** `Ingest bronze` no tiene tendencia de reloj (+2,9 s por ejecución, R² 0,16), pero su tiempo de ejecutor crece +25,5 s·tarea por ejecución (R² 0,82, E10). La lectura de los 4.000 ficheros de `sales_raw` forma parte del coste de H2. Severidad Media: anomalía 3 en tres tablas (`lakehouse-health.md`) con efecto medido todavía moderado.

### H6 · Refrescos fallidos de `sm_sales` que el pipeline no detecta

- **Qué ocurre:** dos refrescos lanzados por `nb_04` fallaron con "The 'category' column does not exist in the rowset." (E24), y las actividades `Refresh semantic model` de las ejecuciones 5 y 9 terminaron `Succeeded` (E5).
- **Por qué:** `nb_04` captura cualquier excepción y no espera al resultado, que es asíncrono (E7). `nb_03` alterna el esquema de `dim_product` cada 4 ejecuciones (E7, E25). Los dos fallos llegaron en la ejecución siguiente a cada renombrado, no en la misma. La relación exacta con el momento del fallo no está verificada (retraso de metadatos del endpoint SQL o modo de almacenamiento del modelo, no analizado).
- **Impacto:** el modelo puede quedarse con datos antiguos sin alerta. Severidad Media; efecto nulo en la duración del pipeline. Para el modelo ver `2026-10-31/01-sm-sales-refresh-alineacion-pipeline.md`.

### H7 · `Silver to gold`: sin tendencia, variación por cola del pool (Baja)

Jobs activos de 46–80 s dentro de sesiones de 290–686 s (E11). La sesión espera 61–287 s en cola (`queuedDuration`, E8), dentro de lo esperado para un pool propio grande (3–6 min en frío, `session-health.md` § Expected Startup Times). Explica los picos de las ejecuciones 8 (287 s) y 10 (215 s), no una tendencia. La ejecución 10 tiene además 474 s de `runningDuration` frente a ~250 s en el resto, sin más jobs: no verificado.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Compactar `customers` y recuperar AQE en `env_silver` y `nb_02` | H1, H3, H5 | Alto | Bajo | Medio | Sí |
| R2 | Evitar la deriva de `amount`, escribir la fila de control al final y recargar 2026-09-06 y 2026-09-12 | H4 | Alto | Bajo | Bajo | Sí |
| R3 | Carga incremental de `silver.sales` y `gold.fact_sales` | H2 | Alto | Medio | Medio | Sí |
| R4 | Broadcast de `stores` y UDF nativa | H3 | Medio | Bajo | Bajo | Sí |
| R5 | Escrituras de bronze: sin `repartition(400)`, un solo append de inventario, `checkpointInterval` por defecto | H5 | Medio | Bajo | Bajo | Sí |
| R6 | `nb_04` debe fallar si el refresco falla; fijar el esquema de `dim_product` | H6 | Medio | Bajo | Bajo | Sí |
| R7 | `env_gold` al Starter Pool, o aplicar el redimensionado del informe `2026-10-31/01` | H7 | Bajo | Bajo | Bajo | Sí |

### R1 · Compactar `customers` y recuperar AQE en silver

- **Cambio propuesto:**

  ```python
  # Una vez, fuera de la ventana del pipeline (Spark, no el endpoint SQL):
  spark.sql("REORG TABLE lh_silver.customers APPLY (PURGE)")
  spark.sql("OPTIMIZE lh_silver.customers")
  # env_silver: eliminar de sparkProperties adaptive.enabled=false, adaptive.skewJoin.enabled=false,
  #   autoBroadcastJoinThreshold=-1 y shuffle.partitions=2000
  # nb_02, primera celda: borrar las cuatro spark.conf.set equivalentes
  # Opcional para el MERGE:
  spark.conf.set("spark.databricks.delta.optimizeWrite.enabled", "true")
  ```

- **Impacto esperado:** compactar reduce el coste por fichero de las lecturas de `customers` (stages 19 y 123, E13). La tabla pesa 85,7 MB en total (E15). Con AQE activado, cada `MERGE` escribe pocos ficheros. Se espera recuperar la mayor parte de los +296 s de la celda 4 y parte de los +40 s de `nb_03`. Es una estimación por proporción, no una medición. Ver `2026-10-31/04-config-spark-capas-medallion.md` y `2026-10-31/05-mantenimiento-delta-bronze-silver-gold.md`.
- **Cómo validarlo:** repetir E15 y E17 (ficheros vivos, DV, anomalía) y E9–E11 en las 2 ejecuciones siguientes: tiempo de la celda 4, `executionTimeMs` y `numTargetFilesAdded` por versión (de ~2.000 a decenas).
- **Reversión:** volver a poner las cuatro propiedades y republicar. La compactación no cambia datos; se puede volver atrás con time travel dentro de la retención.
- **Requiere confirmación:** Sí (`REORG`/`OPTIMIZE`, publicación del environment y edición del notebook son escrituras).

### R2 · Evitar la deriva de `amount` antes de `run_seq` 18

- **Cambio propuesto:**

  ```python
  # nb_01: normalizar el tipo antes de escribir (o schema_drift_every = 0 desde el pipeline)
  sales = sales.withColumn("amount", F.regexp_replace(F.col("amount").cast("string"), r"\s*EUR$", "").cast("double"))
  # y escribir la fila de ctl_pipeline_runs al final, tras el último append correcto
  ```

  Recargar los días de negocio 2026-09-06 y 2026-09-12.
- **Impacto esperado:** elimina el fallo determinista (E6, E29) y la pérdida de días. Con la fila de control al final, un fallo se reintenta con el mismo `run_seq`.
- **Cómo validarlo:** la ejecución con `run_seq % 6 == 0` termina `Completed` (repetir E4 y E5), y E21 devuelve 1.000.000 de filas para los `run_seq` 6 y 12.
- **Reversión:** restaurar la versión anterior del notebook.
- **Requiere confirmación:** Sí (edición y recarga de datos). Cómo tratar la conversión de `amount` es una decisión de negocio.

### R3 · Carga incremental de `silver.sales` y `gold.fact_sales`

- **Cambio propuesto:**

  ```python
  last = spark.sql("SELECT COALESCE(MAX(run_seq), 0) AS s FROM lh_silver.sales").first()["s"]
  new_sales = spark.read.table("lh_bronze.sales_raw").where(F.col("run_seq") > last)
  # ...mismo enriquecimiento sobre new_sales (conservar run_seq en silver.sales)...
  (DeltaTable.forName(spark, "sales").alias("t")
     .merge(new_enriched.alias("s"), "t.sale_id = s.sale_id")
     .whenMatchedUpdateAll().whenNotMatchedInsertAll().execute())
  # nb_03: fact_sales con replaceWhere por sale_date de los días cargados, o MERGE equivalente
  ```

- **Impacto esperado:** el shuffle de la celda 6 vuelve a ~670 MB por ejecución (el de la ejecución 1, E10) en lugar de crecer +523 MB cada día. Es la única corrección que elimina la componente lineal de R² 0,99.
- **Cómo validarlo:** E10 y E11 constantes durante 5 ejecuciones; las filas de `silver.sales` igualan las de `sales_raw` (E15).
- **Reversión:** restaurar el notebook y regenerar `silver.sales` con la carga completa actual.
- **Requiere confirmación:** Sí (cambia la lógica de carga; las correcciones tardías las debe definir el responsable del dato).

### R4 · Broadcast de `stores` y UDF nativa

- **Cambio propuesto:** con AQE activo (R1), añadir `F.broadcast(stores_df)` en el join. Sustituir `classify_note` por expresiones nativas (`F.when`, `F.regexp_replace`) o una pandas UDF, aplicadas antes de `repartitionByRange`.
- **Impacto esperado:** desaparecen la partición de 652 MB del stage 127 y la cola de 23,8 s del stage 140 (E13).
- **Cómo validarlo:** E12 sin "Data skew" y E13 con máximo/mediana < 3×.
- **Reversión:** restaurar el notebook.
- **Requiere confirmación:** Sí (edición).

### R5 · Escrituras de bronze

- **Cambio propuesto:** en `nb_01`, quitar `repartition(WRITE_PARTITIONS)` y activar optimize write. Construir las 30 tiendas en un solo DataFrame (`unionByName`) con un único `append`. Volver a `delta.checkpointInterval` por defecto (`ALTER TABLE lh_bronze.inventory_events UNSET TBLPROPERTIES ('delta.checkpointInterval')`). Compactar una vez `sales_raw` e `inventory_events`.
- **Impacto esperado:** `sales_raw` deja de ganar 400 ficheros por ejecución e `inventory_events` pasa de 30 commits a 1 por ejecución, con checkpoint cada 10. Desaparece el crecimiento de 104 → 150 s de la celda de inventario (E11).
- **Cómo validarlo:** E14 y E15 (commits y ficheros por versión), E18–E20 sin anomalía 3, y la celda 10 de `nb_01`.
- **Reversión:** restaurar el notebook y la propiedad de tabla.
- **Requiere confirmación:** Sí (edición, `ALTER TABLE`, `OPTIMIZE`).

### R6 · Hacer visible el fallo del refresco

- **Cambio propuesto:** en `nb_04`, relanzar la excepción y esperar al estado final consultando el historial del refresco, fallando si termina `Failed`. En `nb_03`, aplicar el renombrado de `product_category` de una vez y actualizar el modelo a la vez, en lugar de alternarlo cada 4 ejecuciones.
- **Impacto esperado:** un refresco fallido marca la actividad como fallida (hoy hay 2 silenciosos, E24).
- **Cómo validarlo:** E24 sin fallos en las 5 ejecuciones siguientes o, si alguno falla, actividad `Failed` en E5.
- **Reversión:** restaurar los notebooks.
- **Requiere confirmación:** Sí (edición; el cambio de esquema afecta al modelo).

### R7 · Pool de gold

- **Cambio propuesto:** asociar `env_gold` al Starter Pool (las otras capas arrancan en 3–13 s, E5), o aplicar la recomendación de `2026-10-31/01-gold-spark-sobredimensionado.md`.
- **Impacto esperado:** elimina 61–287 s de cola por ejecución (E8) y casi toda la variación de `Silver to gold`.
- **Cómo validarlo:** `queuedDuration` de la sesión de `nb_03` (E8) y arranque de la actividad (E5).
- **Reversión:** volver a asociar `pool_gold_xl`.
- **Requiere confirmación:** Sí (cambio y publicación del environment).

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Crece el número de jobs de Spark | E9 | Estable: Ingest 218–229, Bronze→silver 62–79, Silver→gold 52–55 (≤ 0,6 jobs por ejecución). Crece el volumen por job |
| D2 | `Ingest bronze` es el que crece | E5, E10 | Spark 142–230 s sin tendencia (R² 0,16); shuffle constante en 116 MB. El salto de la ejecución 11 (301 s) son 60 s de cola del integration runtime, no de Spark |
| D3 | Spill o presión de GC | E10 | 0 bytes de spill en 41 sesiones; GC ≤ 0,95 % (umbrales > 0 y > 20 %) |
| D4 | Presión de capacidad o colas en el Starter Pool | E5, E8, E27 | Arranque 3–7 s en 28 de las 30 actividades del Starter Pool con arranque medido; las excepciones son 13 s (Bronze→silver, ejecución 10) y 68 s (Ingest, ejecución 11, de ellos 60 s de cola del IR). `pl_store_snapshot` no se solapó con ninguna ejecución |
| D5 | `Refresh semantic model` crece | E5, E9 | Sin tendencia (R² 0,02); las 3 sesiones lentas (116–141 s) no registran ningún job de Spark |
| D6 | Las tablas sobrescritas acumulan ficheros | E15 | `silver.sales` y `fact_sales` se mantienen en 64 ficheros porque cada `CREATE OR REPLACE` retira los anteriores. Su coste es el volumen (H2) |

## Siguientes pasos

- [ ] Aplicar R2 y recargar 2026-09-06 y 2026-09-12 — responsable: ingeniería de datos / propietario de `nb_01` · relacionado con: R2
- [ ] Aplicar R1 en una ventana sin ejecuciones — responsable: ingeniería de datos o `FabricAdmin` para el environment · relacionado con: R1
- [ ] Rediseñar la carga de `silver.sales` y `fact_sales` como incremental — responsable: ingeniería de datos y responsable del dato · relacionado con: R3, R4
- [ ] Corregir las escrituras de bronze y la detección de fallos del refresco — responsable: ingeniería de datos · relacionado con: R5, R6
- [ ] Repetir el análisis tras 5 ejecuciones con R1–R3 aplicadas — responsable: FabricPerfAnalyst · relacionado con: R1, R3

## Notas

### Limitaciones

- No hay datos caducados: las 12 ejecuciones son todo el historial del pipeline (la primera fila de `ctl_pipeline_runs` es de 2026-10-30 17:12). `queryActivityRuns`, sesiones, jobs, stages, Advisor y `taskSummary` respondieron para las 11 primeras (las más antiguas, de hace ~22 h). Para la ejecución 12 solo consulté el detalle de actividades (E29), no sus jobs ni stages.
- Las 10 ejecuciones correctas cubren 10 días de negocio (2026-09-01 → 09-11, sin el 06) pero se lanzaron en ~12 h reales: 9 manuales seguidas y 1 programada. Las tendencias se expresan por ejecución, no por día real.
- Los tiempos por celda (E11) son el intervalo entre el primer y el último job de cada sentencia; no incluyen el tiempo de driver sin jobs, así que no suman la duración de Spark.
- En bronze y silver, `startDateTime` de la sesión es anterior al `runStartTime` de la actividad, así que no lo usé para medir el arranque de esas capas. En gold usé `queuedDuration` (E8).
- H6: la relación entre el momento del fallo y el renombrado no está verificada.
- El agente no pudo escribir este informe (la herramienta Write rechazó la escritura de un subagente); se guardó desde la sesión principal con su contenido, sin cambios salvo quitar de "Datos no obtenidos" la fila que lo mencionaba.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| `DESCRIBE DETAIL` / `DESCRIBE HISTORY` vía Livy | No ejecutados: `_delta_log` completo, checkpoint y procedimiento de salud ya dan esas cifras | Ninguno sobre H1 y H5 |
| Causa de los 474 s de `runningDuration` de `Silver to gold` en la ejecución 10 | No se consultó resource usage de esa sesión | H7 con confianza Media |
| Contenido de los jobs `FAILED` de `Bronze to silver` (ejecuciones 2, 3, 4 y 8) | No se descargaron logs del driver | Hay que confirmar que son reintentos internos del `MERGE` antes de descartarlos |
| Coste en CU o moneda | Fuera del alcance; no se llamó a la API de precios | Impactos expresados en segundos |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Retención de `queryActivityRuns` | `automated-diagnostic-workflow.md` y `pipeline-diagnosis.md` P4c: ~1 h; `pipeline-diagnosis.md` P2: "longest retention" (contradicción interna) | Learn no la documenta (E28). Observado: datos de hace ~22 h disponibles | Se usó lo observado |
| Retención de las API de monitorización de Spark | "Minutes–hours" | Learn solo indica 30 días para el Monitoring Hub (E28). Observado: jobs, stages, Advisor y `taskSummary` a ~22 h | Ídem |
| Regla de regresión | `job-diagnostics.md`: última frente a mediana de las 5 anteriores > 2× | Learn propone > 50 % sobre la media de 4 semanas | El usuario pidió tendencia, no umbral. Se informan pendiente y R²; como dato, 1,18× no marcaría regresión |
| `CheckpointVersion` del procedimiento de salud | `lakehouse-health.md` no define el campo | En `customers` devuelve vacío aunque existe `00000000000000000010.checkpoint.parquet`. En `inventory_events` devuelve 297 sin ningún checkpoint en el log, y la snapshot (298) va 2 versiones por detrás del log (300) (E14, E17, E19) | Para checkpoints y versiones se usó el `_delta_log` de OneLake |

## Anexo

### Consultas completas

E21:

```sql
SELECT TOP 20 c.run_seq, c.business_date, c.started_at, s.sales_rows, cc.cust_rows
FROM dbo.ctl_pipeline_runs c
LEFT JOIN (SELECT run_seq, COUNT_BIG(*) AS sales_rows FROM dbo.sales_raw GROUP BY run_seq) s ON s.run_seq = c.run_seq
LEFT JOIN (SELECT run_seq, COUNT_BIG(*) AS cust_rows FROM dbo.customer_changes GROUP BY run_seq) cc ON cc.run_seq = c.run_seq
ORDER BY c.run_seq;
```

E5, cuerpo de `queryactivityruns`: `{"filters":[],"orderBy":[{"orderBy":"ActivityRunStart","order":"ASC"}],"lastUpdatedAfter":"2026-10-30T00:00:00Z","lastUpdatedBefore":"2026-10-31T23:59:59Z"}`.

Tendencias: mínimos cuadrados de cada métrica frente al número de ejecución, solo sobre las 10 ejecuciones correctas (cálculo local sobre E4, E5, E9–E11).

### Configuración efectiva (E22)

- `env_bronze` (Starter Pool, ejecutores 1–4): `autoCompact=false`, `optimizeWrite=false`, `spark.fabric.resourceProfile=readHeavyForPBI`, `spark.sql.parquet.vorder.default=true`.
- `env_silver` (Starter Pool, 1–4): `spark.sql.adaptive.enabled=false`, `adaptive.skewJoin.enabled=false`, `autoBroadcastJoinThreshold=-1`, `shuffle.partitions=2000`.
- `env_gold` (`pool_gold_xl`, 16 cores, asignación dinámica desactivada): `optimizeWrite=false`, `resourceProfile=writeHeavy`, `vorder.default=false`.
- Propiedades de tabla (E15, v0): `inventory_events` `delta.checkpointInterval=1000`; `customers` `delta.enableDeletionVectors=true`.
