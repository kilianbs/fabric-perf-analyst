# Fallos de pl_daily_sales y pl_store_snapshot: causa, memoria y coste de los reintentos

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-05 |
| **Áreas** | Spark runs (con lectura de modelos semánticos para los refrescos fallidos) |
| **Ámbito** | workspace `FabricPerfLab` · `pl_daily_sales`, `pl_store_snapshot`, `nb_01_ingest_bronze`, `nb_05_store_snapshot`, refrescos de `sm_sales` |
| **Ventana analizada** | 2026-10-30 17:11 → 2026-11-05 05:36 UTC (todo lo retenido: 20 ejecuciones de pipeline, 8 sesiones fallidas) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli, semantic-model-authoring |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Alta (errores, tiempos, core-segundos) / Media (causa de tamaño de fila de `nb_05`) |

## Resumen

- **Pregunta:** por qué falla a veces `pl_daily_sales`, qué pasa con los demás pipelines (¿fallos por memoria?, ¿cuánto cuestan los reintentos?) y si los fallos o las ejecuciones manuales sesgan la tendencia de los informes 01-04.
- **Conclusión:** `pl_daily_sales` tiene 2 ejecuciones fallidas de 17 (30 oct 18:43 manual y 1 nov 05:00 programada), las dos en `nb_01` por `DELTA_FAILED_TO_MERGE_FIELDS` en `amount`. Es determinista: `nb_01` convierte `amount` a texto cuando `run_seq % 6 == 0` (runs 6 y 12); el siguiente será el run 18. Además los refrescos de `sm_sales` fallan 4 veces por la columna `category`, 3 seguidas desde el 4 nov 05:30. `pl_store_snapshot` (`nb_05`) falló en las 3 ejecuciones que existen (todas manuales), con 2 intentos cada una: ninguna terminó nunca. No hay OOM de clúster: los errores son un `MemoryError` de Python de 214 TiB (producto cartesiano en pandas) y un límite de 2 GiB por fila de Spark (`BufferHolder`); subir memoria no los arregla.
- **Impacto:** los 2 fallos de `nb_01` dejan sin cargar las ventas de los días de negocio 2026-09-06 y 2026-09-12 y silver, gold y el refresco sin ejecutar esos días; cuestan ~670 core-segundos de ejecutor. Los reintentos de `pl_store_snapshot` (1 reintento configurado, 3 realizados) suman 2.043 de 4.338 core-s (47 %) y 261 s de 557 s de actividad, sin ningún resultado, porque el error es idéntico. Los fallos son el 1,3 % de los core-s Spark medidos.
- **Primera acción:** R1, corregir el cambio de tipo de `amount` en `nb_01` (o aislar la deriva) antes del run 18 (6 nov 05:00 UTC); R2, quitar el reintento de `pl_store_snapshot` y arreglar `nb_05`. Requieren confirmación.

## Alcance

**Pregunta original:** "El pipeline a veces falla, ¿puedes revisar las ejecuciones fallidas y el motivo? Mira también los demás pipelines del workspace: ¿alguno falla por memoria y cuánto cuestan los reintentos?" (con el detalle del encargo: fecha, actividad, duración hasta el fallo, disparo, mensajes, causa raíz, determinista o intermitente, datos a medias, coste, y sesgo de la tendencia de los informes 01-04).

**Informes previos:** `2026-11-05/01-pl-daily-sales-tendencia-crecimiento.md`, `02-nb02-skew-stages-joins.md`, `03-config-spark-capas-y-direct-lake.md`, `04-dimensionamiento-sesiones-spark-pipeline.md`, `05-mantenimiento-tablas-delta.md`. De ellos se reutilizan el inventario de items, las 2 ejecuciones fallidas de `pl_daily_sales` (01, E3), la observación H7 de refrescos (04) y la deriva `category` (03, H5); aquí se mide lo que faltaba.

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Las 2 ejecuciones fallidas de `pl_daily_sales` y las 3 de `pl_store_snapshot` (los dos únicos pipelines), sus 8 sesiones Spark fallidas, el código de `nb_01` y `nb_05`, la configuración de reintentos, el estado de las tablas de bronze, los refrescos de `sm_sales` y el coste en core-segundos de 68 sesiones | CU de capacidad (no se consultó Capacity Metrics: el coste se da en core-segundos de ejecutor asignados, no en CU); análisis de causa del fallo `category` en el modelo más allá de lo ya dicho en 03 y 04; efecto de los fallos en silver/gold por lectura de tablas (ver Datos no obtenidos) |

**Hipótesis de partida:** H-a, los fallos de `pl_daily_sales` son deterministas por deriva de esquema en bronze. H-b, `pl_store_snapshot` falla por memoria (OOM) y los reintentos solo consumen CU. H-c, las ejecuciones manuales y los fallos desplazan la tendencia calculada por días.

**Recorrido:** Spark runs (job instances, `queryActivityRuns`, sesiones Livy, `resourceUsage`/ejecutores/advice de las 8 sesiones fallidas, código `getDefinition`) → lectura de bronze por el SQL endpoint para saber qué quedó a medias → lectura del historial de refrescos de `sm_sales` (el fallo `category` es parte de la pregunta).

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Disparo | `pl_daily_sales`: diario 06:00 `Romance Standard Time` (05:00 UTC), del 31 oct al 30 nov. `pl_store_snapshot`: sin schedule, solo manual | E10 |
| Reintentos configurados | `pl_store_snapshot` / `Export store snapshot`: `retry=1`, intervalo 60 s, timeout 2 h. `pl_daily_sales`: `retry=0` en las 4 actividades | E3 |
| Parámetros | `pl_store_snapshot.export_format` (por defecto `nested`); `pl_daily_sales.rows_per_day=1000000` | E3 |
| Notebook `nb_05` | Lakehouse por defecto `lh_silver`, lee `sales` | E4 |
| Permisos con los que se ejecutó | Usuario con lectura de workspace, Spark Monitoring, SQL endpoint y Power BI | E1-E11 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| pl_daily_sales | DataPipeline | Orquestación diaria | bd706b1d-499f-4a0d-bb22-222312944ca1 |
| pl_store_snapshot | DataPipeline | Exportación semanal manual a finanzas | 7b2521f4-d7ec-4bc4-b9b0-f7159cd20f4d |
| nb_01_ingest_bronze | Notebook | Ingesta bronze | 4240632d-3ce1-422f-a1b2-ddb55d8736e0 |
| nb_05_store_snapshot | Notebook | `store_snapshot` / `store_pairs` en `lh_silver` | 1a79471b-3d90-40b3-a8a2-4cde71470594 |
| sm_sales | SemanticModel | Modelo de ventas | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |

## Evidencia

### Métricas clave

**Inventario de ejecuciones fallidas (UTC)** (E1, E2, E5)

| Pipeline · ejecución | Disparo | Actividad que falla | Hasta el fallo (pipeline / actividad / sesión Spark) | Intentos | Error de la actividad | Causa raíz |
|----------------------|---------|--------------------|-----------------------------------------------------|----------|----------------------|------------|
| pl_daily_sales · 30 oct 18:43 (`1c7c087c`) | Manual | Ingest bronze | 62 s / 52 s / 43 s | 1 (retry 0) | `2451` UserError: `AnalysisException [DELTA_FAILED_TO_MERGE_FIELDS] Failed to merge fields 'amount' and 'amount'` | Run 6: `amount` llega como texto |
| pl_daily_sales · 1 nov 05:00 (`5d856136`) | Programado | Ingest bronze | 79 s / 70 s / 42 s | 1 | Igual (runId `fb8f40bd-…`) | Run 12: igual |
| pl_store_snapshot · 30 oct 20:18 (`d0adcd1b`) | Manual, `nested` | Export store snapshot | 272 s / 98 s + 97 s / 86 s + 94 s | 2 | `Py4JJavaError` en `saveAsTable`: tarea 1043 de la etapa 20 falló 4 veces, `TASK_WRITE_FAILED` | Fila > 2 GiB (`BufferHolder`) |
| pl_store_snapshot · 30 oct 20:23 (`33278036`) | Manual, `pairs` | Export store snapshot | 176 s / 52 s + 51 s / 44 s + 39 s | 2 | `MemoryError: Unable to allocate 214. TiB for an array with shape (29420231897168,)` | Join cartesiano en pandas |
| pl_store_snapshot · 3 nov 08:05 (`c07fef05`) | Manual, `nested` | Export store snapshot | 332 s / 146 s + 113 s / 110 s + 100 s | 2 | Igual que la primera (etapa 21) | Igual |

Las 3 ejecuciones de `pl_store_snapshot` repiten el mismo error en el intento y en el reintento (mismo número de tarea, mismo mensaje). No existe ninguna ejecución exitosa de `pl_store_snapshot`.

**Resultado por pipeline (E1)**

| Pipeline | Ejecuciones | Fallidas | Programadas | Manuales |
|----------|-------------|----------|-------------|----------|
| pl_daily_sales | 17 | 2 (12 %) | 6 (1 fallida) | 11 (1 fallida) |
| pl_store_snapshot | 3 | 3 (100 %) | 0 | 3 |

**Qué quedó a medias en bronze (E6)**

| run_seq | Fecha de negocio | `ctl_pipeline_runs` | `customer_changes` | `inventory_events` | `sales_raw` |
|---------|------------------|---------------------|--------------------|--------------------|-------------|
| 6 (30 oct) | 2026-09-06 | escrito | 13.958 filas | ausente | sin carga (el `append` abortó) |
| 12 (1 nov) | 2026-09-12 | escrito | 14.044 filas | ausente | sin carga |

`sales_raw` tiene 6.000 ficheros = 15 cargas × 400 (informe 01, E8), así que solo 15 de los 17 runs cargaron ventas. La consulta directa de `sales_raw` por `run_seq` agotó el tiempo del endpoint (E6), por lo que la ausencia de ventas de los runs 6 y 12 es inferida de esa cifra y del abort del `append` (confianza Media). `run_seq` se calcula de `ctl_pipeline_runs` antes de la carga, así que el run siguiente avanza al día de negocio siguiente: **los días 06 y 12 de septiembre no se recargan nunca**.

**Coste en core-segundos de ejecutor asignados (integral de `allocatedCores` de `resourceUsage`) (E7, E8)**

| Conjunto | Sesiones | Core-s | Duración de sesión (s) | Eficiencia de cores |
|----------|----------|--------|------------------------|---------------------|
| nb_01 fallido (2) | 2 | 339 + 331 = 670 | 42,4 + 41,3 | 0,135 / 0,133 |
| nb_01 completado (media de 15) | 15 | 27.724 (media 1.848) | 3.158 (media 211) | 0,195–0,327 (informe 04) |
| nb_05 intento 1 (3) | 3 | 680 + 345 + 1.270 = 2.295 | 85,0 + 43,1 + 109,6 | 0,543 / 0,192 / 0,379 |
| nb_05 reintento (3) | 3 | 952 + 305 + 786 = 2.043 | 92,8 + 38,1 + 98,2 | 0,422 / 0,238 / 0,530 |
| nb_05 total | 6 | 4.338 | 467 | – |
| Sesiones completadas de `nb_01`-`nb_04` | 60 | 369.958 | 19.208 | – |

Los core-s fallidos totales (670 + 4.338 = 5.008) son el 1,3 % de los 374.966 core-s medidos (60 completadas + 8 fallidas). Dentro de `pl_store_snapshot` los reintentos son 2.043 / 4.338 = 47 %; en tiempo de actividad 261 s de 557 s (47 %), más 3 esperas de 60 s del `retryInterval` sin Spark. Un fallo de `nb_01` cuesta 335 core-s de media frente a 1.848 de una ejecución completa (18 %). Estos valores no son CU: faltan driver y overhead de capacidad, y no se consultó Capacity Metrics.

**Memoria de las sesiones fallidas de `nb_05` (E8)**

| Sesión | Ejecutores | Tareas fallidas | Heap JVM pico (GiB) | Memoria máx. (GiB) | GC del ejecutor 1 (s) |
|--------|-----------|-----------------|---------------------|--------------------|-----------------------|
| 3 nov, intento 1 (`62546bdc`) | 3 (8 cores) | 4 (ejecutor 1) | 18,7 | 33,4 | 23,2 |
| 3 nov, reintento (`313757e5`) | 1 | 4 | 17,8 | 33,4 | 19,3 |
| 30 oct `nested` (intento `5af59973` y reintento `35c1aa94`) | 1 y 3 | 4 por sesión | 13,0 / 10,1 | 33,4 | 16,4 / 20,5 |
| 30 oct `pairs` (`2230877b`, `b6b7243c`) | 1 | 0 | 0,9–1,5 | 33,4 | 2,6–4,2 |

Ningún error contiene `OutOfMemoryError`, `ExecutorLostFailure`, "container killed", "Java heap space", "GC overhead" ni código 137 (búsqueda en los 5 mensajes de actividad, los job instances y el detalle de las 8 sesiones). Heap pico ≤ 18,7 GiB de 33,4 GiB y ningún ejecutor perdido.

**Tendencia con y sin sesgo (E1, E9)**

| Ejecución programada | Cargas de ventas acumuladas | Pipeline (s) | `nb_02` (s) |
|----------------------|-----------------------------|--------------|-------------|
| 31 oct | 10 | 1.573 | 701 |
| 2 nov | 11 | 1.500 | 735 |
| 3 nov | 12 | 1.556 | 748 |
| 4 nov | 14 | 1.672 | 792 |
| 5 nov | 15 | 1.839 | 882 |

Entre el 3 y el 4 nov hay 2 cargas (la manual del 3 nov 08:05 es la carga 13). Ajuste lineal sobre estos 5 puntos: pipeline +55,8 s por carga (frente a +51,3 s por día natural), `nb_02` +32,0 s por carga (+33,1 s por día).

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces/{ws}/items/{pl}/jobs/instances` ×2 (`pl_daily_sales`, `pl_store_snapshot`) | 17 y 3 ejecuciones; 2 y 3 fallidas; `invokeType`, inicio, fin y `failureReason` (código 2451) de cada una |
| E2 | REST (lectura) | `POST /v1/workspaces/{ws}/datapipelines/pipelineruns/{id}/queryactivityruns` ×5 (las fallidas) | Actividad, estado, `durationInMs`, error completo, parámetros de entrada, `sessionId`, `executionDuration`, `durationInQueue`; 1 actividad en `pl_daily_sales`, 2 (intento y reintento) en `pl_store_snapshot`; `failureType` UserError |
| E3 | REST (lectura) | `POST .../items/{pl}/getDefinition` ×2 | Políticas de actividad (`retry`, `retryIntervalInSeconds`, `timeout`) y parámetros de pipeline |
| E4 | REST (lectura) | `POST .../notebooks/{nb}/getDefinition?format=ipynb` ×2 (`nb_01`, `nb_05`) | Código: deriva `run_seq % 6` de `nb_01` y ramas `nested`/`pairs` de `nb_05` (ver H1 y H3). Se lee la definición porque la petición pide la causa raíz |
| E5 | REST | `GET /v1/workspaces/{ws}/spark/livySessions` | 79 sesiones: 8 `Failed` (2 de `nb_01`, 6 de `nb_05`), "System cancelled the Spark session due to statement execution failures"; el resto Succeeded |
| E6 | SQL | `SELECT TOP 40 … FROM dbo.ctl_pipeline_runs / customer_changes / inventory_events` en `lh_bronze` (agrupados por `run_seq`); `sales_raw` agrupado por `run_seq` | 17 filas en `ctl`; 17 en `customer_changes`; 15 en `inventory_events` (faltan 6 y 12). La consulta de `sales_raw` agotó el tiempo ("The operation timed out") |
| E7 | REST | `GET .../notebooks/{nb}/livySessions/{id}/applications/{app}/resourceUsage` ×68 | Duración, idle, eficiencia y series de cores asignados; `capacityExceeded=false` en las 8 fallidas |
| E8 | REST | `GET .../applications/{app}/allexecutors`, `/stages`, `/jobs`, `/advice` ×8 (fallidas) | Ejecutores, tareas fallidas, heap pico y GC; advice: `Job N error summary` (4 fallos en el ejecutor 1), `Spark_User_Requirements_IllegalArgumentException`, y un aviso de skew (etapa 21: 863 MB leídos por la tarea mayor frente a 2,01 MB de media) |
| E9 | REST + cálculo | `ctl_pipeline_runs` (E6) y job instances (E1) | Cargas de ventas acumuladas por ejecución y ajustes lineales de la tabla de tendencia |
| E10 | REST | `GET .../items/{pl}/jobs/Pipeline/schedules` ×2 | `pl_daily_sales`: diario 06:00 (Romance Standard Time), activo; `pl_store_snapshot`: lista vacía. (La ruta `/jobs/DefaultJob/schedules` y `/schedules` devolvieron 400/404) |
| E11 | REST | `GET https://api.powerbi.com/v1.0/myorg/groups/{ws}/datasets/{sm}/refreshes?$top=40` | 19 refrescos; 4 Failed con "The 'category' column does not exist in the rowset": 30 oct 19:50 (Enhanced API), 4 nov 05:30, 5 nov 04:30 y 05:30 (programados). Último correcto: 4 nov 05:27 (Enhanced API) |

No se ejecutó ninguna acción Tier B (ni Livy ni `ClearCache`).

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | `nb_01` falla de forma determinista cada 6.º run (runs 6 y 12) por cambio de tipo de `amount`; el próximo es el run 18 | Alta | Alta | E1, E2, E4 |
| H2 | Cada fallo de `nb_01` deja `ctl` y `customer_changes` escritos pero ventas e inventario sin cargar: 2 días de negocio perdidos, silver, gold y refresco sin ejecutar | Alta | Media | E2, E6 |
| H3 | `pl_store_snapshot` nunca ha terminado: dos causas deterministas, ninguna de ellas falta de memoria del clúster | Alta | Alta (error) / Media (tamaño de fila) | E2, E4, E8 |
| H4 | El reintento de `pl_store_snapshot` repite el mismo error y supone el 47 % del coste de la actividad | Media | Alta | E2, E3, E7 |
| H5 | Los refrescos de `sm_sales` fallan por `category`, 3 seguidos desde el 4 nov 05:30; el pipeline sale como "Completed" | Alta | Alta | E11, informes 03 y 04 |
| H6 | Fallos y ejecuciones manuales no cambian la pendiente por carga de los informes 01-04, pero sí la cifra "por día" | Baja | Alta | E1, E6, E9 |

### H1 · Fallo de `nb_01` por `amount` (determinista)

- **Qué ocurre:** `nb_01` falló en 2 de 17 ejecuciones (30 oct 18:43, manual, y 1 nov 05:00, programada) con el mismo error de la actividad: `[DELTA_FAILED_TO_MERGE_FIELDS] Failed to merge fields 'amount' and 'amount'` (`failureType` UserError). Falló a los 52 y 70 s de actividad (43 y 42 s de sesión Spark), sin reintentos porque la política es `retry=0`.
- **Por qué:** el código de la celda 6 (E4) hace `if schema_drift_every > 0 and run_seq % schema_drift_every == 0:` y sustituye `amount` por `format_string("%.2f EUR", ...)`, con `schema_drift_every = 6`. `sales_raw` guarda `amount` numérico, y el `append` con texto no se puede mezclar. `run_seq` vale 6 y 12 en las dos ejecuciones fallidas (E6) y es 6 × n para los fallos siguientes. Con 17 runs hechos, el run 18 (el programado del 6 nov 05:00 UTC si no hay ejecuciones manuales antes) fallará, y también el 24. No es intermitente: depende del contador, no del disparo ni de la carga. Falló por igual manual y programado.
- **Impacto:** el pipeline falla en ~1 de cada 6 ejecuciones y deja de refrescar el modelo ese día. Ver H2.

### H2 · Datos a medias y días sin cargar

- **Qué ocurre:** `ctl_pipeline_runs` registra los runs 6 y 12 con sus fechas de negocio 2026-09-06 y 2026-09-12, y `customer_changes` tiene 13.958 y 14.044 filas de esos runs (E6), pero `inventory_events` no tiene filas para esos runs y `sales_raw` no tiene las ventas (6.000 ficheros = 15 cargas, informe 01).
- **Por qué:** el orden del notebook es `ctl` (celda 3) → `customer_changes` (celda 5) → `sales_raw` (celda 6, falla) → `inventory_events` (celda 7). Un `append` de Delta con esquema incompatible aborta sin escribir ficheros; las celdas anteriores ya se confirmaron. El run siguiente toma `MAX(run_seq)+1`, así que salta a la fecha siguiente.
- **Impacto:** los datos de ventas e inventario de las fechas 2026-09-06 y 2026-09-12 faltan de bronze, silver y gold de forma permanente salvo recarga manual. Además `customer_changes` contiene cambios de runs fallidos que el `MERGE` de `nb_02` puede aplicar en el run siguiente (no verificado, Notas). El día del fallo, `nb_02`, `nb_03` y `nb_04` no se ejecutan: silver y gold quedan con los datos del día anterior y los refrescos programados de 04:30 y 05:30 corren sobre datos viejos. El coste directo del fallo es 335 core-s de media, 18 % de una ejecución completa, y 62–79 s de pipeline frente a ~1.500–1.840 s.

### H3 · `pl_store_snapshot`: ni OOM de clúster ni éxito posible

- **Qué ocurre:** 3 de 3 ejecuciones fallidas, todas manuales (no hay schedule). Hay dos causas distintas según `export_format`:
  1. `nested` (por defecto; 30 oct 20:18 y 3 nov 08:05): `Py4JJavaError` en `saveAsTable`, tarea 1043 falló 4 veces con `IllegalArgumentException: Cannot grow BufferHolder by size 448 because the size after growing exceeds size limitation 2147483632` (la traza pasa por `ObjectAggregationIterator`, es decir, `collect_list`). Es el límite de 2 GiB por fila de Spark, no un OOM.
  2. `pairs` (30 oct 20:23): `MemoryError: Unable to allocate 214. TiB for an array with shape (29420231897168,) and data type int64` en la sesión del driver, tras `toPandas()` y `pdf.merge(pdf, on="store_id")`.
- **Por qué:** (1) el código agrupa por `store_id` y acumula en un solo array todos los documentos JSON de la tienda; `nb_01` asigna el 60 % de las ventas a la tienda 1 (`F.rand < 0.6 → 1`). Con 13 cargas × 1 M filas son ~7,8 M documentos en una fila; la etapa 21 lee 863 MB en la tarea mayor frente a 2,01 MB de media (E8). No se midió el tamaño de ese array: la causa es inferida de la traza y del código (Media). (2) El `merge` por tienda es cuadrático: 29,4 billones de filas × 8 B = 214 TiB. El cálculo cuadra con 9 cargas (0,6² × 9 M² ≈ 29,2 billones) que había el 30 oct 20:23. Ninguna memoria de clúster lo resuelve y crece con el cuadrado de los datos.
- **Memoria:** en las 6 sesiones no hay `OutOfMemoryError`, `ExecutorLostFailure`, contenedor terminado ni "Java heap space"; heap pico 18,7 GiB de 33,4 GiB y 4 tareas fallidas solo en un ejecutor (E8). Respuesta a la pregunta sobre memoria: `pl_store_snapshot` falla por una causa relacionada con memoria (tamaño de fila y matriz cartesiana), pero no es un fallo de dimensionamiento del clúster. `pl_daily_sales` no tiene ningún fallo de memoria.
- **Impacto:** el export semanal para finanzas no se ha generado nunca (0 ejecuciones exitosas), y la tabla `store_snapshot` no se ha escrito (el `saveAsTable` con `overwrite` aborta; no se comprobó su estado).

### H4 · Coste de los reintentos

- **Qué ocurre:** `Export store snapshot` tiene `retry=1` e intervalo de 60 s (E3); cada una de las 3 ejecuciones hizo 2 intentos (E2). Los reintentos consumieron 2.043 core-s y 261 s de actividad de un total de 4.338 core-s y 557 s (47 %) más 3 × 60 s de espera. No hay intento exitoso con el que comparar: los 6 intentos fallan con el mismo error y la misma tarea 1043 (E2, E8). `pl_daily_sales` no tiene reintentos (`retry=0`), así que no hay coste de reintento ahí; sus 2 fallos cuestan 670 core-s sin repetición.
- **Por qué:** el error es de entrada y de código, no transitorio: reintentar con la misma entrada no puede cambiar el resultado. Spark ya reintenta cada tarea 4 veces antes (la etapa tarda en fallar 1,5–2 min).
- **Impacto:** 2.043 core-s (0,5 % de los core-s medidos) y 3 sesiones Spark extra (1–2 min cada una más 60 s de espera); es pequeño en términos absolutos, pero 100 % desperdicio. Severidad Media: bajo en coste, pero con un patrón que se amplifica si el export se programa.

### H5 · Refrescos del modelo fallidos que el pipeline no ve

- **Qué ocurre:** E11 muestra 4 refrescos fallidos con el mismo mensaje: 30 oct 19:50, 4 nov 05:30, 5 nov 04:30 y 05:30; los 3 últimos seguidos. Último correcto: 4 nov 05:27. No hay refresco "ViaEnhancedApi" de `nb_04` el 5 nov. En todas las ejecuciones de `pl_daily_sales` `nb_04` terminó correctamente.
- **Por qué:** coincide con el renombrado de `category` a `product_category` en `dim_product` por `nb_03` (informe 03, H5) y con la captura silenciosa de la excepción en `nb_04` (informe 04, H3). Es determinista mientras la columna y el modelo no coincidan. No se volvió a analizar el modelo.
- **Impacto:** `sm_sales` lleva sin refrescar desde el 4 nov 05:27 y el pipeline no avisa; ver R3 y informe 04 R1.

### H6 · Sesgo de la tendencia

- **Qué ocurre:** 9 de las 15 ejecuciones completadas del 30 oct y 1 del 3 nov son manuales. Se comprobó que cada ejecución completada añade exactamente una carga de ventas (15 cargas en 15 completadas, E6), así que el eje "carga acumulada" de los informes 01-04 (primera a última ejecución completada) no se distorsiona por los fallos ni por lo manual. Lo que sí cambia: las cifras expresadas "por día" mezclan 4 cargas en 3 días (2 → 5 nov, por la manual del 3 nov a las 08:05), y los 2 fallos ocupan un `run_seq` sin carga.
- **Por qué:** el informe 01 resumía "+22,6 % en 3 días" (1.500 → 1.839 s). Por carga son 339 s / 4 cargas = 85 s por carga entre el 2 y el 5 nov, y el ajuste de las 5 ejecuciones programadas da +55,8 s por carga (+51,3 s por día) para el pipeline y +32,0 s por carga para `nb_02`. La conclusión del informe 01 (crece con los datos acumulados, 2 causas) se mantiene; "por día" sobreestima un 33 % el ritmo entre esas fechas. Las sesiones fallidas no entran en el informe 04 (solo 15 completadas), y su eficiencia (0,13) no distorsiona las medias de `nb_01` (0,195–0,327).
- **Impacto:** bajo. Conviene expresar el crecimiento por carga. La manual del 3 nov a las 08:05 coincidió con la ejecución fallida de `pl_store_snapshot` (08:05:30): dos sesiones a la vez, con 17 s de cola de integración; esa ejecución (1.518 s) queda entre sus vecinas, sin efecto visible.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Corregir la deriva de `amount` en `nb_01` (convertir a numérico antes del `append` o aislar el caso) y poner `schema_drift_every = 0` si era una simulación | H1, H2 | Alto | Bajo | Bajo | Sí |
| R2 | Quitar el reintento de `pl_store_snapshot` y reescribir `nb_05` (sin `collect_list` de documentos completos; sin join cartesiano en pandas) | H3, H4 | Medio | Medio | Bajo | Sí |
| R3 | Resolver `category` en `sm_sales` y hacer que el pipeline falle cuando falla el refresco (informe 04 R1) | H5 | Alto | Bajo | Bajo | Sí |
| R4 | Recargar los días 2026-09-06 y 2026-09-12 y hacer que `nb_01` escriba `ctl_pipeline_runs` al final | H2 | Alto | Medio | Medio | Sí |
| R5 | Expresar el crecimiento por carga acumulada en los siguientes informes | H6 | Bajo | Bajo | Bajo | No |

### R1 · Deriva de `amount`

- **Cambio propuesto:**

  ```python
  # nb_01, celda 6: no cambiar el tipo; normalizar antes de escribir
  sales = sales.withColumn("amount", F.col("amount").cast("double"))
  # si la fuente v2 envía texto "123.45 EUR": F.regexp_extract("amount", r"[\d.]+", 0).cast("double")
  ```

- **Impacto esperado:** deja de fallar el run 18 (6 nov 05:00 UTC) y los múltiplos de 6, y se evitan 335 core-s y un día sin cargar por fallo.
- **Cómo validarlo:** la siguiente ejecución con `run_seq` múltiplo de 6 debe completarse (E1) y `inventory_events` y `sales_raw` deben tener ese `run_seq` (E6).
- **Reversión:** volver a la versión anterior del notebook.
- **Requiere confirmación:** Sí, cambia un notebook.

### R2 · `pl_store_snapshot`

- **Cambio propuesto:** en el pipeline, `retry: 0` en `Export store snapshot`. En `nb_05`, para `nested` escribir una fila por documento (sin `collect_list`; `partitionBy`/`repartition("store_id")` y `write` de JSON o Delta) y para `pairs` calcular los pares por tienda con `groupBy("store_id").count()` (n²) o `crossJoin` acotado en Spark, sin `toPandas()`.
- **Impacto esperado:** el export termina y desaparecen 2.043 core-s de reintentos por ejecución fallida (47 % del coste de la actividad). Basado en E2, E3, E7 y E8; el tamaño de la fila no se midió.
- **Cómo validarlo:** una ejecución manual completa de cada `export_format` y comparar con E7.
- **Reversión:** restaurar `retry=1` y la versión anterior de `nb_05`.
- **Requiere confirmación:** Sí, cambia el pipeline y el notebook; ejecutar el pipeline es una acción de otro agente o persona.

### R3 · Refrescos del modelo

- **Cambio propuesto:** ver informe 04, R1 (actividad de refresco de modelo semántico con espera) y corregir `category` / `product_category` en el modelo o evitar el renombrado en `nb_03` (informe 03).
- **Impacto esperado:** el modelo vuelve a refrescarse y los fallos aparecen en el pipeline.
- **Cómo validarlo:** estado `Completed` del siguiente refresco de `sm_sales` (E11) y fallo visible en el pipeline si se reproduce.
- **Reversión:** volver a la actividad Notebook.
- **Requiere confirmación:** Sí.

### R4 · Recarga de los días perdidos

- **Cambio propuesto:** diseño de una recarga de las fechas 2026-09-06 y 2026-09-12 (parámetro de fecha de negocio en `nb_01`) y mover la inserción en `ctl_pipeline_runs` y la carga de `customer_changes` al final, tras confirmar la de ventas.
- **Impacto esperado:** bronze, silver y gold completos; se evitan cambios de clientes aplicados sin ventas.
- **Cómo validarlo:** `ctl_pipeline_runs` y `sales_raw` con las mismas fechas (E6).
- **Reversión:** retirar los datos recargados por `run_seq`.
- **Requiere confirmación:** Sí, escribe datos.

### R5 · Métrica de crecimiento

- **Cambio propuesto:** usar la carga acumulada (`run_seq` sin fallos) como eje en lugar de los días.
- **Cómo validarlo:** ajuste de duración frente a cargas, como en la tabla de tendencia.
- **Requiere confirmación:** No.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | `pl_store_snapshot` falla por OOM o ejecutores perdidos (dimensionamiento) | E2, E8 | Ningún `OutOfMemoryError`, `ExecutorLostFailure` ni contenedor terminado; heap pico 18,7 de 33,4 GiB; los errores son límite de fila de 2 GiB y `MemoryError` de 214 TiB (no alcanzable con ningún tamaño) |
| D2 | `pl_daily_sales` falla por memoria | E1, E2 | Sus únicos 2 fallos son `AnalysisException` de esquema; las 60 sesiones completadas tienen spill 0 (informes 01-04) |
| D3 | Los fallos de `pl_daily_sales` son intermitentes o dependen de que el disparo sea manual o programado | E1, E4, E6 | Ocurren en `run_seq` 6 y 12 (múltiplos de 6) tanto en manual como en programado; el código lo explica |
| D4 | Los reintentos recuperan algún fallo | E2 | 3 de 3 ejecuciones repiten el mismo error en el reintento |
| D5 | Las ejecuciones manuales o fallidas distorsionan la pendiente por carga de los informes 01-04 | E1, E6, E9 | Cada completada = una carga; el ajuste por carga confirma el resultado (H6) |

## Siguientes pasos

- [ ] Corregir `amount` en `nb_01` antes del 6 nov 05:00 UTC — responsable: ingeniería de datos · relacionado con: R1
- [ ] Decidir la recarga de las fechas 2026-09-06 y 2026-09-12 — responsable: ingeniería de datos · relacionado con: R4
- [ ] Corregir `nb_05` y quitar el reintento — responsable: ingeniería de datos · relacionado con: R2
- [ ] Resolver `category` en `sm_sales` — responsable: modelado BI · relacionado con: R3
- [ ] Repetir el análisis tras el run 18 (6 nov) para validar R1

## Notas

### Limitaciones

- El coste se da en core-segundos de ejecutor asignados (integral de `allocatedCores`), no en CU: falta el driver y no se consultó Capacity Metrics (`capacity.md`).
- Las sesiones fallidas siguen retenidas (E5, E7, E8); los datos de detalle de Spark caducan en horas, por lo que las de hoy dejarán de estar disponibles pronto (`automated-diagnostic-workflow.md` § Data Retention Summary).
- Las 20 ejecuciones son todas las que devuelve la API; no se sabe si hubo ejecuciones anteriores al 30 oct.
- El run 18 es una predicción derivada del código: cualquier ejecución manual antes del 6 nov cambia qué ejecución es la 18.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Filas de `sales_raw` por `run_seq` | La consulta agotó el tiempo del SQL endpoint (E6) | La ausencia de ventas de los runs 6 y 12 es inferida de 6.000 ficheros = 15 × 400 (confianza Media) |
| Efecto de `customer_changes` de los runs 6 y 12 en `silver.customers` | No se leyó el código de `nb_02` ni el contenido de silver | No se sabe si el `MERGE` de `nb_02` aplicó esos cambios |
| Estado de `lh_silver.store_snapshot` y `store_pairs` | No se consultó (el informe 05 ya anotó que `store_snapshot` no existe en el SQL endpoint) | Se asume que el export nunca se ha escrito |
| Tamaño real del array por tienda en `nested` | No se midió; el job abortó | La causa de los 2 GiB se infiere de la traza, el código y la distribución 60/40 |
| CU por ejecución | No se consultó Capacity Metrics | Coste expresado en core-s |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Ruta de schedules de pipeline | `jobs/DefaultJob/schedules` devuelve 400 y `/schedules` 404 en este entorno | La ruta que funcionó fue `items/{id}/jobs/Pipeline/schedules` | Se usó la que funcionó (E10); no se contrastó con Learn |
| Lectura de `failureReason` | `pipeline-diagnosis.md` lo lee el último | `spark-runs.md` § 5: usar `failureReason` primero | Se usó `failureReason`, luego `queryActivityRuns` y luego advice/ejecutores |

## Anexo

### Consultas completas

- E6 (bronze, `lh_bronze` SQL endpoint, `workspaceId=23ca4a73-…`, `itemId=53249a1b-…`): `SELECT TOP 40 run_seq, business_date, started_at, rows_requested FROM dbo.ctl_pipeline_runs ORDER BY run_seq`; `SELECT TOP 40 run_seq, COUNT_BIG(*) n FROM dbo.customer_changes GROUP BY run_seq ORDER BY run_seq`; ídem para `dbo.inventory_events`; `SELECT TOP 40 run_seq, business_date, COUNT_BIG(*) n FROM dbo.sales_raw GROUP BY run_seq, business_date ORDER BY run_seq` (agotó el tiempo).
- E2: cuerpo de `queryactivityruns`: `{"filters":[],"orderBy":[{"orderBy":"ActivityRunStart","order":"ASC"}],"lastUpdatedAfter":"2026-10-29T00:00:00Z","lastUpdatedBefore":"2026-11-06T00:00:00Z"}`.

### Configuración efectiva

- `pl_store_snapshot` / `Export store snapshot`: `timeout 0.02:00:00`, `retry 1`, `retryIntervalInSeconds 60`.
- `pl_daily_sales`: las 4 actividades con `retry 0`; `Ingest bronze` timeout 2 h, `Bronze to silver` 4 h, `Silver to gold` 2 h, `Refresh semantic model` 30 min.
- `nb_01`: `schema_drift_every = 6`, `rows_per_day = 1000000`; `nb_05`: `export_format = "nested"` por defecto.
