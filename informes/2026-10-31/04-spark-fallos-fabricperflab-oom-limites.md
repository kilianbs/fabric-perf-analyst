# Fallos de Spark en FabricPerfLab: causa raíz, reintentos, coste y datos sin cargar

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-10-31 |
| **Áreas** | Spark runs (con comprobación de Delta tables para el efecto aguas abajo) |
| **Ámbito** | workspace `FabricPerfLab` · pipelines `pl_daily_sales`, `pl_store_snapshot` · notebooks `nb_01`…`nb_05` · lakehouses bronze/silver/gold |
| **Ventana analizada** | 2026-10-30 17:05 → 2026-10-31 15:57 UTC (todas las instancias de job devueltas por la API) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli |
| **Modo** | Lectura + diagnóstico activo (Livy) |
| **Severidad global** | Alta |
| **Confianza global** | Alta (causas) · Baja (coste en CU, estimado) |

## Resumen

- **Pregunta:** qué ejecuciones de Spark han fallado en FabricPerfLab, por qué, si alguna es por memoria, reintentos y coste, y qué datos faltan aguas abajo.
- **Conclusión:** 3 ejecuciones de pipeline fallidas (de 13) y 5 intentos de notebook fallidos: 4 de `nb_05_store_snapshot` (`pl_store_snapshot`) y 1 de `nb_01_ingest_bronze` (`pl_daily_sales`). Solo hay memoria en el caso `pairs` (MemoryError en el driver por un producto cartesiano de pandas, no por memoria mal dimensionada). El caso `nested` es un límite interno de Spark (fila de más de 2 GiB en el ejecutor), no un OOM de heap. El de `nb_01` es un fallo de esquema Delta. Ninguno corresponde a `maxResultSize`, broadcast ni RPC.
- **Impacto:** `pl_store_snapshot` nunca ha tenido una ejecución correcta: `store_snapshot` no es una tabla Delta válida y `store_pairs` no existe. Cada ejecución de `nb_05` se intentó 2 veces y el reintento falló igual (determinista): ≈133 s de sesión Spark desperdiciados (≈1 064 CU·s estimados, no medidos). `pl_daily_sales` se recuperó con una re-ejecución manual.
- **Primera acción:** R1 y R2/R3, reescribir `nb_05` (sin `collect_list` de JSON completo ni `toPandas()` + `merge`) y poner reintentos a 0 en esa actividad.

## Alcance

**Pregunta original:** "¿Qué ejecuciones de Spark han fallado en FabricPerfLab y por qué? ¿Alguna por memoria? Revisa todos los pipelines, cuenta los reintentos y lo que cuestan, distingue el OOM de driver, el de ejecutor y los límites internos de Spark, e indica qué datos faltan aguas abajo por cada fallo."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Los 2 pipelines del workspace, sus 5 notebooks y todas las instancias de job devueltas (10-11 por item); 45 sesiones Livy del workspace | CU medido en Capacity Metrics (FabricIQ no conectó); decodificar definiciones de pipeline o notebook (no pedido) |
| Efecto en tablas bronze/silver/gold | Consumidores de `store_snapshot` fuera de las tablas del workspace (no se inspeccionó `sm_sales`) |

**Hipótesis de partida:** H-a OOM de driver o ejecutor en `nb_05` (fallos repetidos); H-b límite interno de Spark; H-c fallo de código o esquema en `nb_01`.

**Recorrido:** solo Spark runs. Se consultó Delta (historial y estado de tablas) únicamente para medir el efecto aguas abajo. Sin pivote a capacity: `capacityExceeded=false` y todas las sesiones obtuvieron `appId`.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad | id `353a0ed6-2bba-456c-bac7-009fc42e4b94` (SKU y región no consultados) | E1 |
| Runtime de Spark | 1.3 | E9 |
| Sesión de los notebooks | driver 8 cores / 56 GB, 1 ejecutor 8 cores / 56 GB | E9 |
| Configuración (sesión Livy de diagnóstico) | `maxResultSize=4096m`, `autoBroadcastJoinThreshold=26214400`, `broadcastTimeout=300`, `task.maxFailures=4`, `rpc.message.maxSize=128` | E12 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| pl_daily_sales | DataPipeline | nb01→nb02→nb03→nb04 | bd706b1d-499f-4a0d-bb22-222312944ca1 |
| pl_store_snapshot | DataPipeline | nb05 | 7b2521f4-d7ec-4bc4-b9b0-f7159cd20f4d |
| nb_01_ingest_bronze | Notebook | bronze | 4240632d-3ce1-422f-a1b2-ddb55d8736e0 |
| nb_05_store_snapshot | Notebook | silver | 1a79471b-3d90-40b3-a8a2-4cde71470594 |
| nb_02 / nb_03 / nb_04 | Notebook | silver / gold / refresco | 4205418f-cee2-4a3d-9390-328618160264, c7cca4b7-3722-4bec-9946-504520f6be21, 3a609552-4721-406a-8e9c-f801c0a43b59 |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Ejecuciones de pipeline | `pl_daily_sales` 11 (1 fallida); `pl_store_snapshot` 2 (2 fallidas) | — | E2 |
| Intentos de notebook fallidos | 5 (nb01: 1; nb05: 4); el resto Completed | — | E3 |
| Intentos por ejecución de `pl_store_snapshot` | 2 (actividad repetida con distinto `activityRunId`) | — | E5, E6 |
| Duración de actividad `nested` | 98,3 s y 97,2 s | — | E6 |
| Duración de actividad `pairs` | 51,5 s y 51,3 s | — | E5 |
| Espera entre intento 1 y 2 | ≈62 s (20:20:15→20:21:17; 20:24:26→20:25:28) | — | E5, E6 |
| Tamaño solicitado por pandas | 214 TiB, array de 29 420 231 897 168 elementos int64 | — | E5 |
| Límite alcanzado en `nested` | `Cannot grow BufferHolder by size 552 … exceeds size limitation 2147483632` | — | E6 |
| Tarea 1043, etapa 20 | falló 4 veces (`numFailedTasks=4` de 2 009) | `spark.task.maxFailures=4` | E7, E12 |
| Skew de la etapa 20 | máx. 646,46 MB leídos frente a media 1,51 MB | Advisor | E7 |
| coreEfficiency de las 5 sesiones fallidas | 0,135 (nb01); 0,543 y 0,422 (nested); 0,192 y 0,238 (pairs) | — | E8 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces`; `GET /v1/workspaces/{ws}/items` | workspace FabricPerfLab; 2 DataPipeline, 5 Notebook, 3 Lakehouse, 1 SemanticModel |
| E2 | REST | `GET /v1/workspaces/{ws}/items/{pipeline}/jobs/instances` (×2) | `pl_daily_sales`: 10 Completed + 1 Failed (`1c7c087c`, 18:43:02→18:44:04); `pl_store_snapshot`: 2 Failed (`d0adcd1b` 20:18:26→20:22:58; `33278036` 20:23:28→20:26:24) |
| E3 | REST | `GET …/items/{notebook}/jobs/instances` (×5) | fallidos: nb01 `52b192ad`; nb05 `4a6d7480`, `9c280cd4`, `97635219`, `b50c371b`; `failureReason` "System cancelled the Spark session due to statement execution failures" |
| E4 | REST | `POST …/datapipelines/pipelineruns/1c7c087c…/queryactivityruns` | una sola actividad (`Ingest bronze`) Failed, 52,1 s; `AnalysisException [DELTA_FAILED_TO_MERGE_FIELDS] Failed to merge fields 'amount' and 'amount'`; celda 26 línea 30 `saveAsTable("sales_raw")` (append) tras convertir `amount` a texto `"%.2f EUR"` si `run_seq % schema_drift_every == 0`; UserError |
| E5 | REST | `POST …/pipelineruns/33278036…/queryactivityruns` | 2 actividades `Export store snapshot` Failed, `export_format=pairs`; `MemoryError: Unable to allocate 214. TiB`; celda 17 línea 11 `pdf.merge(pdf, on="store_id")` tras `toPandas()` |
| E6 | REST | `POST …/pipelineruns/d0adcd1b…/queryactivityruns` | 2 actividades Failed, `export_format=nested`; `Task 1043 in stage 20.0 failed 4 times … [TASK_WRITE_FAILED] … Tables/store_snapshot`; causa `IllegalArgumentException: Cannot grow BufferHolder by size 552 because the size after growing exceeds size limitation 2147483632`; celda 17 línea 8 |
| E7 | REST | `GET …/livySessions/{livy}/applications/{app}/advice` y `/jobs` (5 sesiones fallidas) | nested: job 12 FAILED, 2 009 tareas, 4 falladas, Advisor `Spark_User_Requirements_IllegalArgumentException` y skew en etapa 20; pairs: todos los jobs SUCCEEDED (job 12 con 9 tareas), sin advice; nb01: 30 jobs SUCCEEDED, sin advice |
| E8 | REST | `GET …/applications/{app}/resourceUsage` (×5) | `capacityExceeded=false` en las cinco; coreEfficiency 0,135 / 0,543 / 0,422 / 0,192 / 0,238; una sesión con `allocatedCores` hasta 24 |
| E9 | REST | `GET …/notebooks/{nb}/livySessions/{livy}`; `GET /workspaces/{ws}/spark/livySessions` | 45 sesiones; 5 Failed con totalDuration 43 s (nb01), 86 y 94 s (nested), 44 y 39 s (pairs); driver 56 GB, ejecutor 56 GB, runtime 1.3, `queuedDuration` 0 |
| E10 | REST | `GET /lakehouses/{id}/tables` (bronze, silver, gold) | silver contiene `store_snapshot` y no `store_pairs`; gold 7 tablas |
| E11 | Livy | creación de la sesión `081f213e…` en lh_silver (pool por defecto, sin conf) y `DELETE` de la misma | creada; estado final `killed` |
| E12 | Livy | `spark.conf.get` de claves de límites | maxResultSize `4096m`; autoBroadcastJoinThreshold `26214400`; broadcastTimeout `300`; task.maxFailures `4`; driver/executor memory `56g`; rpc.message.maxSize `128` |
| E13 | Livy | `SHOW TABLES IN lh_silver`; `SELECT count(*) FROM lh_silver.store_snapshot`; `DESCRIBE HISTORY lh_silver.store_snapshot` | la tabla figura en el catálogo pero `DELTA_TABLE_NOT_FOUND` / "is not a Delta table"; sin historial |
| E14 | Livy | `DESCRIBE HISTORY` de `lh_bronze.sales_raw`, `lh_silver.sales`, `lh_gold.fact_sales`, `lh_gold.daily_store_sales` | sales_raw: v4 18:25:06, **v5 18:45:52** (ninguna versión a las 18:43); silver.sales v9 05:16:06; fact_sales v9 05:21:52; daily_store_sales v9 05:23:12 |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | `nb_05` con `nested` falla por un límite interno de Spark (fila >2 GiB en el ejecutor), no por OOM de heap | Alta | Alta | E6, E7, E9, E12 |
| H2 | `nb_05` con `pairs` falla con MemoryError en el driver por un producto cartesiano de pandas | Alta | Alta | E5, E7, E9 |
| H3 | `pl_store_snapshot` nunca ha cargado datos: `store_snapshot` inválida y `store_pairs` inexistente | Alta | Alta | E10, E13 |
| H4 | Los reintentos de `nb_05` (1 por ejecución, 2 en total) son deterministas y desperdician sesión Spark | Media | Media | E5, E6, E9 |
| H5 | `nb_01` falla por fusión de esquema Delta; sin memoria ni reintento; recuperado por re-ejecución | Media | Alta | E4, E14 |
| H6 | Ningún fallo corresponde a `maxResultSize`, broadcast o RPC | Baja | Alta | D1-D3 |

Severidad asignada por impacto en datos (tabla nunca cargada = Alta; fallo recuperado = Media). Las categorías de fallo siguen `spark-cli/references/operations/job-diagnostics.md` § Failure Classification; esa referencia no define umbrales numéricos de severidad para estos casos.

### H1 · `nested`: límite interno de Spark en el ejecutor

- **Qué ocurre:** la ejecución `d0adcd1b` (2 intentos, 98,3 s y 97,2 s) falla en la etapa 20 al escribir `store_snapshot`. La tarea 1043 se reintentó 4 veces dentro de Spark hasta abortar el job (E6, E7).
- **Por qué:** `IllegalArgumentException: Cannot grow BufferHolder … exceeds size limitation 2147483632` es el tope de 2 GiB del buffer de una fila (`UnsafeRow`). El código agrupa por `store_id` con `collect_list` del JSON de cada venta: el array de la tienda mayor no cabe en una fila. El Advisor muestra 646,46 MB frente a 1,51 MB de media, coherente con una tienda dominante (no verificada). Con 56 GB por ejecutor no falta memoria (E9): **ni OOM de driver ni de ejecutor, es un límite interno**. UserError (E6).
- **Impacto:** `store_snapshot` queda sin datos válidos (H3).

### H2 · `pairs`: MemoryError en el driver

- **Qué ocurre:** ejecución `33278036` (51,5 s y 51,3 s). Todos los jobs de Spark terminan bien, incluido el `toPandas()` (E7); el fallo ocurre en Python, en el driver, al hacer `pdf.merge(pdf, on="store_id")`.
- **Por qué:** el auto-join por `store_id` genera una fila por cada par de ventas de la misma tienda: 29,4 billones de elementos, 214 TiB (E5). Es un error de lógica, no de configuración: un driver de 56 GB no lo resuelve. Es **memoria del driver (proceso Python)**, no heap de JVM; `maxResultSize=4096m` no se alcanzó porque los jobs terminaron (E7, E12).
- **Impacto:** `store_pairs` no se crea.

### H3 · Datos aguas abajo de `pl_store_snapshot`

- **Qué ocurre:** en silver el catálogo lista `store_snapshot`, pero la lectura devuelve `DELTA_TABLE_NOT_FOUND` y `DESCRIBE HISTORY` indica que no es Delta; `store_pairs` no existe (E10, E13).
- **Por qué:** los dos únicos runs fallaron (E2); el `overwrite` abortado dejó una ruta sin `_delta_log` válido.
- **Impacto:** cualquier consumidor de `store_snapshot` o `store_pairs` no tiene datos. No se comprobó si existe alguno (Notas).

### H4 · Reintentos y coste

- **Qué ocurre:** cada ejecución de `pl_store_snapshot` registra 2 actividades con el mismo nombre e `iterationHash` vacío, separadas ≈62 s; `retryAttempt` viene vacío en la API (E5, E6). Se interpreta el segundo intento como reintento de la actividad. `pl_daily_sales` no tuvo reintentos (una sola actividad, E4). Además, dentro de Spark la tarea 1043 se reintentó 4 veces por `spark.task.maxFailures=4` en cada intento `nested`.
- **Coste (estimación, no medida):** sesiones de 16 vCores (driver 8 + ejecutor 8) ÷ 2 = 8 CU mientras corren (1 CU = 2 vCores, `e2e-fabric-cost-estimation` § Spark CU Mapping). Sesiones fallidas (E9): nested 86 s + 94 s; pairs 44 s + 39 s; nb01 43 s; total 306 s ≈ 2 448 CU·s. **Segundos intentos: 94 s + 39 s = 133 s ≈ 1 064 CU·s**, sin retorno, más ≈124 s de espera de pipeline (2 × 62 s). Una sesión llegó a 24 cores asignados (E8), así que la cifra puede ser mayor.
- **Impacto:** poco CU absoluto, pero con retorno cero y repetible en cada ejecución.

### H5 · `nb_01`: esquema Delta

- **Qué ocurre:** run `1c7c087c`, actividad 52,1 s, sesión 43 s, sin reintento (E4, E9). Los 30 jobs de Spark terminaron sin error (E7).
- **Por qué:** el notebook inyecta deriva de esquema (`amount` como `"%.2f EUR"`) cuando `run_seq % schema_drift_every == 0` y hace `append` a `sales_raw`: `DELTA_FAILED_TO_MERGE_FIELDS`. Categoría: código (UserError), no memoria. El append es atómico: no hay versión de `sales_raw` a las 18:43 (E14).
- **Impacto aguas abajo:** `nb_02`, `nb_03` y `nb_04` no se ejecutaron en ese run (la API solo devuelve la actividad fallida, E4). Silver, gold y el refresco del modelo quedaron sin actualizar hasta la re-ejecución manual `5afbd9f3` (18:44:32→19:06:51; `sales_raw` v5 18:45:52), unos 24 min después del fin del run correcto previo (18:42:34, E2). Hoy está al día (v9 del 31-oct 05:16-05:23, E14). Al ser determinista, se repetirá en el siguiente `run_seq` múltiplo de `schema_drift_every`.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Reintentos a 0 en la actividad `Export store snapshot` | H4 | Medio | Bajo | Bajo | Sí |
| R2 | Reescribir la rama `nested` sin superar 2 GiB por fila | H1, H3 | Alto | Medio | Bajo | Sí |
| R3 | Reescribir la rama `pairs` en Spark, sin `toPandas()` | H2, H3 | Alto | Medio | Bajo | Sí |
| R4 | Normalizar `amount` antes del `append` en `nb_01` | H5 | Medio | Bajo | Medio | Sí |
| R5 | Alerta de fallo de pipeline y limpieza de `store_snapshot` | H3, H5 | Medio | Bajo | Bajo | Sí |

### R1 · Reintentos a 0 en `nb_05`

- **Cambio propuesto:** `retry = 0` en la actividad `Export store snapshot` de `pl_store_snapshot` (hoy se observan 2 intentos; la política no se leyó, ver Notas).
- **Impacto esperado:** ahorra ≈133 s de sesión y ≈124 s de espera por cada par de ejecuciones fallidas.
- **Cómo validarlo:** `queryactivityruns` de una ejecución fallida debe mostrar una sola actividad.
- **Reversión:** restaurar el valor previo.
- **Requiere confirmación:** Sí, cambia la definición del pipeline.

### R2 · `nested` por debajo de 2 GiB por fila

- **Cambio propuesto:** no acumular todos los documentos de una tienda en una fila; añadir un cubo para repartirlos (ajustar N tras medir la tienda mayor):

  ```python
  snapshot = (sales
      .withColumn("document", F.to_json(F.struct(*sales.columns)))
      .withColumn("bucket", F.pmod(F.hash("sale_id"), F.lit(64)))
      .groupBy("store_id", "bucket")
      .agg(F.collect_list("document").alias("documents"), F.count("*").alias("sales_count")))
  ```
- **Impacto esperado:** filas por debajo de 2 147 483 632 bytes (E6).
- **Cómo validarlo:** ejecutar `export_format=nested` y comprobar que `store_snapshot` tiene historial Delta.
- **Reversión:** restaurar el notebook.
- **Requiere confirmación:** Sí (modifica un notebook y reejecuta el pipeline).

### R3 · `pairs` en Spark

- **Cambio propuesto:** calcular el número de pares sin materializarlos: `sales.groupBy("store_id").count().withColumn("pairs", F.col("count")*F.col("count"))`. Si se necesitan los pares reales, acotarlos por ventana de fechas.
- **Impacto esperado:** elimina los 214 TiB solicitados (E5); sin `toPandas()` no depende de `maxResultSize`.
- **Cómo validarlo:** `store_pairs` aparece en `lh_silver` y el run termina Completed.
- **Reversión:** restaurar el notebook.
- **Requiere confirmación:** Sí.

### R4 · `nb_01` y esquema

- **Cambio propuesto:** convertir `amount` a su tipo numérico antes del `append`, o desviar el lote con tipo distinto a una tabla de cuarentena en vez de fallar el pipeline.
- **Cómo validarlo:** un run con `run_seq % schema_drift_every == 0` completa sin cambiar el esquema de `sales_raw`.
- **Reversión:** restaurar el notebook.
- **Requiere confirmación:** Sí.

### R5 · Alerta y limpieza

- **Cambio propuesto:** alerta (Activator o notificación del pipeline) ante fallo; eliminar o recrear `lh_silver.store_snapshot` solo tras R2. Este agente no ejecuta `DROP`.
- **Cómo validarlo:** el siguiente fallo genera aviso; la tabla pasa a tener historial.
- **Requiere confirmación:** Sí.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | `spark.driver.maxResultSize` agotado | E7, E12 | En `pairs` los jobs terminan con éxito tras `toPandas()`; ningún error `Total size of serialized results … is bigger than` |
| D2 | `autoBroadcastJoinThreshold` / `broadcastTimeout` | E4-E7, E12 | Sin excepción de broadcast ni timeout en tracebacks ni advice |
| D3 | Límite de mensaje RPC o de shuffle (`FetchFailed`) | E4-E7 | Ningún traceback lo menciona; la única excepción de Spark es `BufferHolder` |
| D4 | OOM de heap del ejecutor en `nested` | E6, E9 | La excepción es `IllegalArgumentException`, no `OutOfMemoryError`; ejecutor de 56 GB |
| D5 | Falta de capacidad o sesión sin arrancar | E8, E9 | `capacityExceeded=false`; todas las sesiones con `appId` y `queuedDuration` 0 |

## Siguientes pasos

- [ ] Aplicar R2 y R3 y volver a ejecutar `pl_store_snapshot` — responsable: ingeniería de datos · relacionado con: R2, R3
- [ ] Poner `retry=0` en la actividad — responsable: ingeniería de datos · relacionado con: R1
- [ ] Decidir el tratamiento de la deriva de esquema — responsable: ingeniería de datos · relacionado con: R4
- [ ] Repetir el análisis tras aplicar R2-R4 para validar el impacto

## Notas

### Limitaciones

- CU real no medido: FabricIQ (Capacity Metrics) no conectó en esta sesión. El coste de H4 es una estimación con duración de sesión y la equivalencia documentada 1 CU = 2 vCores; confianza Baja. Spark Monitoring y `queryActivityRuns` seguían disponibles unas 21 h después de los fallos.
- La sesión Livy de diagnóstico muestra valores por defecto de una sesión nueva; se asume que los notebooks usan los mismos (no se leyó ningún `%%configure`).

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Política de reintento del pipeline | No se decodificó la definición (no solicitado) | "Reintento" inferido de actividades duplicadas; confianza Media |
| CU facturado | FabricIQ no disponible | Coste estimado |
| Consumidores de `store_snapshot` / `store_pairs` | No se inspeccionó `sm_sales` ni otros items | Impacto aguas abajo limitado a las tablas Delta |
| Tamaño de la tienda dominante | No se hizo consulta agrupada (no necesaria para el diagnóstico) | La causa de H1 se infiere del texto del error y del skew del Advisor |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Retención de `queryActivityRuns` | `pipeline-diagnosis.md` P2: "longest retention"; `automated-diagnostic-workflow.md`: ~1 h | Observado: disponible ≈21 h después, igual que Spark Monitoring | Se usó lo medido; no se contrastó con Microsoft Learn |
| Reintentos | `pipeline-diagnosis.md` P3: diagnosticar solo el último intento | La petición pide contar y costear los reintentos | Se diagnosticaron todos los intentos |

## Anexo

### Consultas completas

E12 (Livy, solo lectura): `spark.conf.get('spark.driver.maxResultSize', ...)`, `spark.sql.autoBroadcastJoinThreshold`, `spark.sql.broadcastTimeout`, `spark.task.maxFailures`, `spark.driver.memory`, `spark.executor.memory`, `spark.rpc.message.maxSize`.
E14: `DESCRIBE HISTORY lh_bronze.sales_raw`, `lh_silver.sales`, `lh_gold.fact_sales`, `lh_gold.daily_store_sales`.
