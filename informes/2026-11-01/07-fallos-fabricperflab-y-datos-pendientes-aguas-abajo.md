# Fallos en FabricPerfLab y datos pendientes aguas abajo de pl_daily_sales

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-01 |
| **Áreas** | Spark runs (fallos) → Delta tables (frescura) → Semantic models (refrescos) |
| **Ámbito** | workspace `FabricPerfLab` · `pl_daily_sales`, `pl_store_snapshot`, los 5 notebooks, `sm_sales`, tablas de los tres lakehouses |
| **Ventana analizada** | 2026-10-30 17:11 → 2026-11-01 12:49 UTC |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli, semantic-model-authoring |
| **Modo** | Lectura + diagnóstico activo (Livy) |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** "En la tendencia del pipeline había una ejecución rara. ¿Ha fallado algo en FabricPerfLab y qué falta aguas abajo?"
- **Qué ejecución es la rara:** depende del criterio, y las dos que mencionaban los informes anteriores lo son por motivos distintos.
  - **Ejecución 12** (2026-11-01 05:00 UTC, `Failed`): es la anomalía categórica. Repite el fallo de la ejecución 6, determinista cada 6 ejecuciones (`run_seq` 6 y 12).
  - **Ejecución 10** (1.622 s): a nivel de pipeline no es rara (+1,1 σ respecto a la recta de las 10 correctas, residuo +131 s). Lo es en la actividad `Silver to gold`: 704 s, +221 s (+2,0 σ) sobre su recta, la mayor desviación de esa serie. Se explica por 332 s de espera de ejecutores (informe 05, H4).
- **Qué ha fallado (E1–E4):** `pl_daily_sales` 2 ejecuciones (6 y 12), ambas en `Ingest bronze` con `DELTA_FAILED_TO_MERGE_FIELDS` sobre `amount`; `pl_store_snapshot` 2 ejecuciones (4 intentos de `nb_05`), una por `TASK_WRITE_FAILED` (límite de 2 GB de una fila) y otra por `MemoryError` (214 TiB); `sm_sales` 2 refrescos fallidos el 10-30 (columna `category`), ninguno desde entonces. Ningún otro notebook ni job ha fallado.
- **Qué falta aguas abajo (E5):** el 2026-09-06 y el 2026-09-12 no tienen ventas (ni en bronze, ni en silver, ni en gold); `fact_sales` y `daily_store_sales` terminan el 2026-09-11. Los 14.044 cambios de clientes del `run_seq` 12 están en bronze, sin aplicar a `silver.customers` (máximo `source_run_seq` 11). `sm_sales` se refrescó con éxito a las 05:30 UTC de hoy, pero con el gold del 10-31 (sin datos nuevos).
- **Riesgo al reintentar (inferido del código descrito en el informe 01):** un reintento usará `run_seq` 13. No debería duplicar clientes ni ventas, pero el 2026-09-12 seguirá sin cargarse, y tampoco se carga el 09-06.
- **Primera acción:** R1 (arreglar la deriva de `amount` antes de `run_seq` 18 y recargar los dos días), igual que R2 del informe 01; sin tocarlo, el pipeline vuelve a fallar en el 18. Requiere confirmación.

## Alcance

**Pregunta original:** "En la tendencia del pipeline había una ejecución rara. ¿Ha fallado algo en FabricPerfLab y qué falta aguas abajo? 1. Cuál es la ejecución rara de la serie (la 10 o la 12, o ambas), justificándolo con la serie. 2. Qué ha fallado en el workspace: la ejecución 12 (actividad, mensaje, causa raíz medida frente a inferida) y cualquier otro fallo reciente de pipelines, notebooks, refrescos de modelos semánticos o jobs; revisa también `pl_store_snapshot`. 3. Qué falta aguas abajo: tablas de silver y gold sin actualizar o a medias (p. ej. `customer_changes`), modelos o informes que dependen de ellas y su frescura, y riesgo de datos parciales o duplicados al reintentar. 4. Distingue medido de inferido. 5. Solo lectura."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Instancias de job de todos los pipelines y notebooks, actividades fallidas, historial de refrescos de `sm_sales`, frescura de tablas por `run_seq` y fecha. | Rendimiento (informes 01–06). Contenido del modelo `sm_sales` (no se consultó con DAX). |

**Informes previos:** 01 (E6, E29: error de `amount`; E21: días sin ventas; H4; H6; E24; E27), `2026-10-31/01-sm-sales-refresh-alineacion-pipeline.md` (refrescos de `sm_sales`), 05 (H4: la ejecución 10), 06 (`lh_silver.store_snapshot` no es Delta). Aquí se añade lo no medido: el resto de fallos del workspace (causas de `pl_store_snapshot`), la frescura actual por tabla y la serie de residuos.

**Hipótesis:** (a) la ejecución rara es la 12 (fallo determinista); (b) la 10 es un valor atípico de rendimiento y no un fallo; (c) los fallos dejan datos pendientes pero no parciales; (d) no hay más fallos en el workspace.

**Recorrido:** Spark runs (instancias y actividades fallidas) → Delta tables (frescura por `run_seq`) → Semantic models (historial de refrescos). Sin pivotes adicionales.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Items del workspace | 2 pipelines, 5 notebooks, 3 lakehouses con sus endpoints SQL, 3 entornos, 1 modelo (`sm_sales`). **Ningún informe de Power BI** | E1 |
| Modelo `sm_sales` | Modo de almacenamiento `Abf` (import); programado dos veces al día (04:30 y 05:30 UTC) | E4 |
| Programación | `pl_daily_sales` diaria 05:00 UTC (informe 01 E26); `pl_store_snapshot` solo manual | informe 01; E1 |
| Sesión Livy | `lh_silver`, creada 12:43:30 UTC y borrada 12:49 UTC (estado `killed`); una sentencia de lectura | E5, E6 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| `pl_daily_sales` | DataPipeline | Orquestación | `bd706b1d-499f-4a0d-bb22-222312944ca1` |
| `pl_store_snapshot` / `nb_05_store_snapshot` | DataPipeline / Notebook | Snapshot de tiendas | `7b2521f4-d7ec-4bc4-b9b0-f7159cd20f4d` / `1a79471b-3d90-40b3-a8a2-4cde71470594` |
| `sm_sales` | SemanticModel | Consumidor | `a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9` |

## Evidencia

### Qué ejecución es la rara (serie de las 10 ejecuciones correctas)

Duraciones de `pl_daily_sales` en segundos: 915, 1.160, 977, 1.215, 1.118, 1.338, 1.405, 1.221, 1.622, 1.573 (ejecuciones 1–5 y 7–11; informe 01 E4). Recta de mínimos cuadrados: +67,7 s por ejecución; desviación típica de los residuos 118 s. Cálculo local sobre E1.

| Serie | Ejecución más desviada | Residuo | σ |
|-------|------------------------|---------|---|
| Pipeline completo | ejecución 8 (1.221 s, valle) | −203 s | −1,7 |
| Pipeline completo | ejecución 10 (1.622 s) | +131 s | +1,1 |
| Actividad `Silver to gold` | ejecución 10 (704 s) | +221 s | +2,0 |
| Ejecuciones fallidas | 6 (62 s) y 12 (79 s) | no comparables | — |

Ninguna ejecución correcta supera 2 σ en la serie del pipeline. La 10 solo lo hace en `Silver to gold`.

### Fallos de pipelines y notebooks (E2, E3)

| Pipeline / ejecución | Inicio (UTC) | Actividad que falla | Duración | Error | Clasificación |
|----------------------|--------------|---------------------|----------|-------|---------------|
| `pl_daily_sales` 6 (`1c7c087c`) | 2026-10-30 18:43 | `Ingest bronze` | 52 s | `AnalysisException [DELTA_FAILED_TO_MERGE_FIELDS] Failed to merge fields 'amount' and 'amount'` | UserError, código 2451 |
| `pl_daily_sales` 12 (`5d856136`) | 2026-11-01 05:00 | `Ingest bronze` (notebook `fb8f40bd`) | 70 s | Mismo error | UserError, código 2451 |
| `pl_store_snapshot` (`d0adcd1b`) | 2026-10-30 20:18 | `Export store snapshot` (2 intentos: 98,3 s y 97,2 s) | 4,5 min | `Py4JJavaError` en `saveAsTable`: `Task 1043 in stage 20.0 failed 4 times … [TASK_WRITE_FAILED] … Tables/store_snapshot`, causa `IllegalArgumentException: Cannot grow BufferHolder by size 552 because the size after growing exceeds size limitation 2147483632` | UserError |
| `pl_store_snapshot` (`33278036`) | 2026-10-30 20:23 | `Export store snapshot` (2 intentos: 51,5 s y 51,3 s) | 3 min | `MemoryError`: `Unable to allocate 214. TiB for an array with shape (29420231897168,) and data type int64` | UserError |

Notebooks: `nb_01` falló 2 veces (las de las ejecuciones 6 y 12), `nb_05` 4 veces (los 4 intentos de `pl_store_snapshot`); `nb_02`, `nb_03` y `nb_04` no tienen ninguna ejecución fallida (E2). Los fallos de `nb_01` y `nb_05` terminan con "System cancelled the Spark session due to statement execution failures" (E2).

Refrescos de `sm_sales` (E4): 2 `Failed` el 2026-10-30 (18:42 y 19:50 UTC) con "The 'category' column does not exist in the rowset." Desde entonces todos `Completed`: `ViaEnhancedApi` 20:18 UTC y 10-31 05:25, y `Scheduled` 10-31 04:30 y 05:30, 11-01 04:30 y 05:30.

### Frescura actual (2026-11-01 12:43 UTC, E5)

| Tabla | Contenido | Observación |
|-------|-----------|-------------|
| `bronze.ctl_pipeline_runs` | 12 filas: `run_seq` 1–12, `business_date` 2026-09-01 → 09-12; el 12 se escribió a las 05:00:54 UTC | La fila de control se escribe antes del trabajo, también en las ejecuciones fallidas |
| `bronze.sales_raw` | 1.000.000 filas por `run_seq` 1–5 y 7–11 (10 M); **faltan el 6 y el 12** | Ninguna fila parcial |
| `bronze.customer_changes` | 12 `run_seq`: 200.000 (1), ~14.000 (2–12), incluido el 6 (13.958) y el **12 (14.044)** | El lote del 12 sí se escribió |
| `silver.customers` | 169.227 filas lógicas; máximo `source_run_seq` = **11** | El cambio del 12 no se aplicó |
| `silver.sales` | 1.000.000 filas por `run_seq` 1–5 y 7–11 | Sin el 6 ni el 12 |
| `gold.fact_sales` | 10 M filas, 10 M `sale_id` distintos, `sale_date` 2026-09-01 → 09-11 | Sin duplicados |
| `gold.daily_store_sales` | 500 filas, última fecha 2026-09-11 | — |
| `bronze.inventory_events` | 300 ficheros = 10 ejecuciones × 30 (informe 06) | Sin el lote del 12 |
| `sm_sales` | Último refresco correcto: 2026-11-01 05:30:02 → 05:38:15 UTC | Su origen (gold) no cambió desde el 2026-10-31 05:23 UTC (informe 05 E3) |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces/{ws}/items` | 17 items; sin `Report` |
| E2 | REST | `GET …/items/{id}/jobs/instances` para los 2 pipelines y los 5 notebooks | 12 instancias de `pl_daily_sales` (2 `Failed`), 2 de `pl_store_snapshot` (2 `Failed`), `nb_01` 12 (2 `Failed`), `nb_05` 4 (4 `Failed`), `nb_02`/`nb_03`/`nb_04` 10 `Completed` cada una |
| E3 | REST | `POST …/datapipelines/pipelineruns/{runId}/queryactivityruns` de las 4 ejecuciones fallidas | Tabla de errores |
| E4 | REST (Power BI) | `GET /v1.0/myorg/groups/{ws}/datasets/{sm_sales}/refreshes?$top=20`, `…/reports` y `…/datasets/{id}` | 14 refrescos, 2 fallidos; `reports` vacío; `targetStorageMode` `Abf` |
| E5 | Livy | `SELECT` sobre `ctl_pipeline_runs`, recuento por `run_seq` en `sales_raw`, `customer_changes` y `silver.sales`, `MAX(source_run_seq)`/`COUNT(*)` de `customers`, `MIN/MAX(sale_date)`/`COUNT(DISTINCT sale_id)` de `fact_sales`, `MAX(sale_date)` de `daily_store_sales` | Tabla de frescura |
| E6 | REST | Creación y borrado de la sesión Livy | 12:43:30 y 12:49 UTC; `killed` |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | La ejecución 12 es la anomalía; la 10 solo lo es en `Silver to gold` | Media | Alta | E2, serie |
| H2 | `pl_daily_sales` falla de forma determinista cada 6 ejecuciones en `Ingest bronze` por `amount` | Alta | Alta | E2, E3, informe 01 |
| H3 | `pl_store_snapshot` falla por dos causas distintas y dejó 96 ficheros sin confirmar en `lh_silver.store_snapshot` | Media | Media | E3, informe 06 |
| H4 | Faltan las ventas del 2026-09-06 y 09-12 en las tres capas; el lote de clientes del 12 está sin aplicar | Alta | Alta | E5 |
| H5 | `sm_sales` está al día con respecto a gold, y gold está dos días de negocio incompletos; no hay informes que dependan del modelo | Media | Media | E1, E4, E5 |
| H6 | Riesgo al reintentar: sin duplicados esperables, pero sin recuperar los días perdidos | Media | Media | E5, informe 01 |

### H1 · Qué ejecución es la rara

- **Qué ocurre:** el pipeline de la ejecución 10 está +131 s sobre la recta (+1,1 σ), dentro del ruido de la serie; la 8 está −203 s (−1,7 σ). Solo `Silver to gold` marca +2,0 σ en la 10 (704 s). Las ejecuciones 6 y 12 fallan a los 62 y 79 s.
- **Por qué:** la 10 tuvo 332 s de espera de ejecutores en el pool de gold (informe 05, H4), una causa de infraestructura y no de código. La 12 repite el fallo de la 6 por una deriva de esquema intencionada (`schema_drift_every = 6`, informe 01 H4).
- **Impacto:** si "rara" significa "distinta del resto de la serie", es la 12 (y la 6); si significa "más lenta de lo esperado", es la 10 solo en una actividad. Severidad Media porque la 10 no repite y la 12 está en H2.

### H2 · Causa raíz de la ejecución 12

- **Qué ocurre:** `Ingest bronze` falla a los 70 s con `DELTA_FAILED_TO_MERGE_FIELDS` sobre `amount` (E3). No hay reintentos ni otras actividades ejecutadas (E3, informe 01 E29).
- **Medido:** el mensaje y la clase del error (UserError). **Inferido, con apoyo del código del informe 01:** que `amount` se cambia a texto cuando `run_seq % 6 == 0` y el `append` a `sales_raw` no acepta el cambio de tipo; el informe 01 lo leyó del código del notebook (E7 de ese informe), aquí no se vuelve a leer.
- **Impacto:** vuelve a ocurrir en el `run_seq` 18 si no se corrige. Severidad Alta.

### H3 · `pl_store_snapshot`

- **Qué ocurre:** dos ejecuciones manuales, cada una con dos intentos de la misma actividad, todas fallidas (E2, E3). Primera: fallo de escritura en `saveAsTable` por una fila que excede 2 GB (`BufferHolder`). Segunda: `MemoryError` al reservar 214 TiB para un array (29,4 billones de elementos).
- **Por qué:** ambos son errores de datos o de código del notebook (UserError), no de plataforma. La causa de fondo (una columna de tamaño gigantesco, o un cálculo con una dimensión errónea) es una inferencia: no leí el código de `nb_05`.
- **Impacto:** `lh_silver.store_snapshot` quedó con 96 ficheros parquet (930 MB) y sin commit de Delta (informe 06, E1/E2), así que no existe como tabla. Nada de `pl_daily_sales` depende de él (inferido: no aparece en el código de los notebooks descritos en el informe 01). Severidad Media.

### H4 · Datos que faltan

- **Qué ocurre:** `sales_raw` no tiene las ventas de los `run_seq` 6 y 12 y `fact_sales` llega hasta el 2026-09-11 (E5). `customer_changes` sí tiene los lotes del 6 y del 12 (13.958 y 14.044 filas). Los del 6 se aplicaron después (el `MERGE` del 7 usa `run_seq > último aplicado`, informe 01 E21 y E15); el del 12 sigue pendiente porque `silver.customers` solo llega a 11.
- **Por qué:** `nb_01` escribe la fila de control y `customer_changes` antes de `sales_raw`, que es donde falla (informe 01 H4, E7). Delta es atómico: el `append` fallido no dejó filas parciales (E5: ninguna fila de `run_seq` 6 ni 12).
- **Impacto:** dos días de negocio sin ventas en las tres capas. Un lote de clientes (14.044 filas) sin aplicar a `silver.customers`. Los 8 ficheros extra de `customer_changes` (88 → 96, informe 06) coinciden con ese lote (inferido por la fecha y el recuento).

### H5 · Dependientes aguas abajo y frescura

- **Qué ocurre:** el único dependiente es `sm_sales` (modelo import, E4); no hay informes en el workspace (E1). Su refresco programado de las 05:30 UTC de hoy terminó con éxito, 30 minutos después del fallo del pipeline, y leyó el gold de ayer (informe 05 E3: la última escritura de `nb_03` terminó a las 05:23 UTC del 10-31). `nb_04` no llegó a lanzarse hoy (el pipeline falló en la primera actividad).
- **Por qué:** los refrescos programados (04:30 y 05:30) son independientes del pipeline y no saben si gold se actualizó (informe `2026-10-31/01-sm-sales-refresh-alineacion-pipeline.md`).
- **Impacto:** el modelo está "fresco" pero con los datos de gold hasta 2026-09-11, con 2026-09-06 y 2026-09-12 ausentes. Esto último es inferido del origen del modelo: no consulté el modelo con DAX. Severidad Media: nadie lo detecta por el estado de los refrescos.

### H6 · Riesgo al reintentar

- **Qué ocurre:** la fila de control del `run_seq` 12 ya existe (E5).
- **Por qué (inferencia desde el comportamiento del `run_seq` 6, E5 y el informe 01):** un reintento calculará `MAX(run_seq)+1 = 13`, con `business_date` 2026-09-13. `nb_02` aplica los cambios con `run_seq` mayores que el último aplicado, así que cargará el lote del 12 junto con el del 13; el `MERGE` por clave no duplica clientes. `sales_raw` no tiene ninguna fila del 12, así que no habrá ventas duplicadas.
- **Impacto:** no hay riesgo de duplicados por lo observado, pero el 2026-09-12 queda sin cargar igual que el 09-06 (E5). Con la conversión de `amount` pendiente, el `run_seq` 18 volvería a fallar. El comportamiento del reintento no se ha probado (no se ejecuta el pipeline).

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Evitar la deriva de `amount`, escribir la fila de control al final y recargar los días 2026-09-06 y 2026-09-12 | H2, H4, H6 | Alto | Bajo | Bajo | Sí |
| R2 | Antes de reintentar, decidir cómo cargar el lote de clientes del `run_seq` 12 y comprobar que `nb_02` lo recogerá | H4, H6 | Medio | Bajo | Bajo | Sí |
| R3 | Que `nb_04` espere y falle si el refresco falla, y que el modelo se refresque tras el pipeline | H5 | Medio | Bajo | Bajo | Sí |
| R4 | Revisar `nb_05` (tamaño de las filas y dimensiones del array) y limpiar los ficheros huérfanos de `store_snapshot` | H3 | Bajo | Medio | Medio | Sí |

### R1 · Deriva de `amount` y días perdidos

- **Cambio propuesto:** el de R2 del informe 01 (normalizar `amount` antes de escribir o `schema_drift_every = 0`; fila de control al final; recarga de 2026-09-06 y 09-12).
- **Impacto esperado:** el `run_seq` 18 no falla y los dos días vuelven a las tres capas.
- **Cómo validarlo:** E2 sin nuevas instancias `Failed` en `Ingest bronze`; E5 con 1.000.000 filas para los `run_seq` 6 y 12 en `sales_raw` y `fact_sales` hasta la fecha esperada.
- **Reversión:** restaurar el notebook; la recarga se puede deshacer con time travel dentro de la retención.
- **Requiere confirmación:** Sí.

### R2 a R4

- **R2:** comprobar, antes de lanzar nada, que `silver.customers` aplica el lote del 12 (`MAX(source_run_seq)` pasa de 11 a ≥ 12) tras la primera ejecución correcta (E5). Sin reejecución no se puede validar.
- **R3:** relanzar la excepción de `nb_04` y consultar el historial del refresco (R6 del informe 01); alinear la programación (informe `2026-10-31/01`). Validar con E4.
- **R4:** el origen de las filas gigantes de `nb_05` hay que verlo en su código; los 96 ficheros (930 MB) de `store_snapshot` son huérfanos sin commit (informe 06 H6). Validar: `pl_store_snapshot` `Completed` y la tabla visible como Delta.
- **Reversión:** restaurar los notebooks. **Requieren confirmación: Sí.**

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | La ejecución 10 es una anomalía del pipeline | Serie, E2 | +1,1 σ en el pipeline; su desviación está en una sola actividad y es de infraestructura |
| D2 | El lote fallido dejó ventas parciales en bronze | E5 | `sales_raw` no tiene filas del `run_seq` 6 ni 12 |
| D3 | Hay duplicados de ventas en gold | E5 | 10 M `sale_id` distintos en 10 M filas de `fact_sales` |
| D4 | Hay otros fallos recientes en notebooks o refrescos | E2, E4 | `nb_02`/`nb_03`/`nb_04` sin fallos; `sm_sales` sin fallos desde el 2026-10-30 |
| D5 | Hay informes de Power BI que dependan de `sm_sales` en este workspace | E1, E4 | Ningún item `Report` ni informe devuelto por la API |

## Siguientes pasos

- [ ] Aplicar R1 y recargar 2026-09-06 y 2026-09-12 — responsable: ingeniería de datos · relacionado con: R1
- [ ] Decidir cómo recoger el lote de clientes del `run_seq` 12 antes del siguiente reintento — responsable: ingeniería de datos · relacionado con: R2
- [ ] Que `nb_04` falle si el refresco falla — responsable: ingeniería de datos · relacionado con: R3
- [ ] Revisar `nb_05` y limpiar `store_snapshot` — responsable: propietario de `pl_store_snapshot` · relacionado con: R4

## Notas

### Limitaciones

- No leí el código de `nb_05` ni volví a descodificar los notebooks de `pl_daily_sales`: las afirmaciones sobre el orden de escritura y `run_seq % 6 == 0` provienen del informe 01 (inferidas aquí).
- No consulté el contenido de `sm_sales` (DAX): su frescura se deduce de su origen (gold) y de las horas de los refrescos.
- La conclusión "reintentar no duplica" no está probada: no se ha reejecutado nada. Depende de que `nb_02` use `run_seq > último aplicado` y `MERGE` por clave (informe 01).
- Los residuos se calculan sobre 10 puntos; con 118 s de desviación típica, el umbral de 2 σ es orientativo.
- `lh_silver.store_snapshot` (ficheros sin commit) lo describe el informe 06; aquí no se vuelve a listar.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Causa de fondo de los fallos de `nb_05` | No se leyó su código | H3 con confianza Media |
| Contenido y frescura reales de `sm_sales` | No se consultó con DAX | H5 en términos de origen, no de modelo |
| Registro de logs del driver de `nb_01` en la ejecución 12 | No se descargaron | La causa es la del mensaje; sin trazas adicionales |

### Discrepancias entre skills y documentación

Sin discrepancias nuevas respecto a los informes anteriores.

## Anexo

Sentencia Livy (E5), en una sola llamada de lectura:

```python
spark.sql("SELECT * FROM lh_bronze.ctl_pipeline_runs ORDER BY run_seq").show(30,truncate=False)
spark.sql("SELECT run_seq, COUNT(*) AS n FROM lh_bronze.sales_raw GROUP BY run_seq ORDER BY run_seq").show(30)
spark.sql("SELECT run_seq, COUNT(*) AS n FROM lh_bronze.customer_changes GROUP BY run_seq ORDER BY run_seq").show(30)
spark.sql("SELECT run_seq, COUNT(*) AS n FROM lh_silver.sales GROUP BY run_seq ORDER BY run_seq").show(30)
spark.sql("SELECT MAX(source_run_seq) AS max_cust_run, COUNT(*) AS n FROM lh_silver.customers").show()
spark.sql("SELECT MIN(sale_date) AS d0, MAX(sale_date) AS d1, COUNT(*) AS n, COUNT(DISTINCT sale_id) AS dist FROM lh_gold.fact_sales").show()
spark.sql("SELECT MAX(sale_date) AS d1, COUNT(*) AS n FROM lh_gold.daily_store_sales").show()
```

Residuos de la serie (E2 y informe 01 E4): recta de mínimos cuadrados sobre las 10 ejecuciones correctas, tanto para el pipeline como para `Silver to gold`.
