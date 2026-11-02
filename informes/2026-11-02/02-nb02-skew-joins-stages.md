# nb_02_bronze_to_silver: skew, stages y estrategia de join

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-02 |
| **Áreas** | Spark runs → Delta tables |
| **Ámbito** | workspace `FabricPerfLab` · `nb_02_bronze_to_silver` dentro de `pl_daily_sales` |
| **Ventana analizada** | 2026-10-30 17:15 → 2026-11-02 05:17 UTC (5 sesiones Spark del notebook; detalle de stages y planes solo de la del 2-nov) |
| **Agente / host** | GitHub Copilot CLI · skills: fabric-perf-analysis, spark-cli, sqldw-cli |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** ¿Hay data skew o time skew en `Bronze to silver`? ¿Qué stages pesan más y qué estrategia usa cada join?
- **Conclusión:** sí hay ambos. Data skew en el join por `store_id` (la tienda 1 concentra el 60 % de las filas) y time skew en la UDF Python de `note_class`. Los dos joins son `SortMergeJoin LeftOuter` con shuffle, sin broadcast. **Esto corrige parcialmente `01-pl-daily-sales-crecimiento.md`:** el paso que más crece no es la reconstrucción de `sales`, sino el `MERGE` de `customers`.
- **Impacto:** en el notebook, el `MERGE` de `customers` pasa de 108 s a 421 s entre el 30-oct y el 2-nov (+313 s) y la reconstrucción de `sales` de 64 s a 184 s (+120 s). Las dos explican casi todo el crecimiento del notebook (280 s → 735 s).
- **Primera acción:** R1, compactar y purgar `lh_silver.customers` (21 104 archivos pequeños y 15 557 bitmaps de borrado). Requiere confirmación porque es una escritura.

## Alcance

**Pregunta original:** "Dices que el paso de Bronze to silver es el que más crece y que además hay joins con shuffle. ¿Hay data skew o time skew? ¿Qué stages pesan más y qué estrategia usa cada join?"

Parte de `01-pl-daily-sales-crecimiento.md` (H1, H2, D2). Aquí los E#, H#, R# y D# vuelven a empezar en 1.

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Stages, task quantiles y plan SQL de la sesión del 2-nov; tiempo por statement en 5 ejecuciones; distribución de claves en bronze | `Silver to gold` y `Ingest bronze`; capacidad; el modelo semántico |

**Hipótesis de partida:** H-a skew de claves en el join; H-b skew de tiempo por la UDF; H-c lo que crece es `customers`, no `sales`.

**Recorrido:** Spark runs (stages, tasks, plan) → Delta tables (health de `customers`, distribución de claves de `sales_raw`).

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Runtime de Spark | 1.3 | E1 |
| Driver / executor | 8 cores, 56 GB cada uno; `numExecutors` = 1 | E1 |
| Config en `nb_02` | `shuffle.partitions=2000`, `adaptive.enabled=false`, `adaptive.skewJoin.enabled=false`, `autoBroadcastJoinThreshold=-1` | Código del notebook en el repo; el plan de E5 lo confirma (sin broadcast ni AQE) |

### Items analizados

| Item | Tipo | ID |
|------|------|----|
| nb_02_bronze_to_silver | Notebook | 4205418f-cee2-4a3d-9390-328618160264 |
| Sesión del 2-nov | Livy / app | 633b770e-ec93-445b-bd77-acfe7f12f6df · application_1793595802092_0001 |
| lh_silver | Lakehouse (SQL endpoint bd96d99c-58c8-4904-89ba-eda833882013) | b01f7911-28fd-4dc2-ac51-1d19ed841238 |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Statement 4 (`MERGE` customers), 30-oct 17:15 → 2-nov | 108 → 295 → 355 → 404 → 421 s | | E3 |
| Statement 6 (reconstrucción de `sales`), mismas ejecuciones | 64 → 111 → 169 → 173 → 184 s | | E3 |
| Statements 5 y 7 (referencias, inventario) | 17–37 s, sin tendencia | | E3 |
| Tiempo de pared de los stages 20 / 30 / 132 | 161 s / 97 s / 80 s (608, 608 y 660 tasks) | | E2 |
| Stage 20: tarea p50 / p95 / máx | 3,5 s / 5,2 s / 14,6 s, con 0,1 MB de entrada por tarea | Max/mediana > 3× = skew (`performance-patterns.md` § Detection Thresholds) | E4 |
| Stage 135 / 141 / 147: máx. lectura de shuffle | 752 MB en una tarea; p95 de 0 a 22 MB | idem | E4, E5 |
| Stage 147: tarea p50 / máx | 2 ms / 13,8 s | Max/mediana > 3× | E4 |
| Stage 148: tarea p50 / p95 / máx | 6,6 s / 21,9 s / 26,2 s; lectura de shuffle p50 21 MB, máx 26 MB | Max/mediana 3,9× | E4 |
| `customers`: archivos / bitmaps de borrado / filas borradas | 21 104 / 15 557 / 149 279 de 314 588 filas físicas | Anomalía tipo 2 (muchas filas borradas) | E6 |
| `customers`: tamaño medio de archivo | ~4,4 KiB (92 935 775 B / 21 104) | | E6 |
| Filas de `sales_raw` con `store_id = 1` | 6 599 879 de 11 000 000 (60 %); la siguiente tienda tiene 90 370 | | E7 |
| Filas de `sales_raw` con hora ≥ 22 y `notes` no nulo | 275 717 (2,5 %); 7 698 979 con `notes` nulo | | E8 |
| Spill en disco | 0 en los 10 stages con quantiles | > 0 = MEDIUM (`performance-patterns.md`) | E4 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces/{ws}/notebooks/{nb}/livySessions/{livy}` y las de las otras 4 ejecuciones | Datos de la sesión (runtime, cores, memoria) y `sparkApplicationId` |
| E2 | REST | `GET …/applications/{app}/jobs`, `/stages`, `/advice` (sesión del 2-nov) | 87 jobs, 187 stages. Advisor: 4 avisos de archivos pequeños (`customers`, `sales_raw`, `inventory_events`) y 3 de data skew (jobs 66, 67, 68; stages 135, 141, 147; máx. 717 MB frente a medias de 0,64–26 MB). Tiempo de pared de stages calculado con `firstTaskLaunchedTime` y `completionTime` |
| E3 | REST | Jobs de las 5 sesiones, agrupados por `jobGroup` (statement del notebook) | Tiempos por statement (ver métricas) |
| E4 | REST | `GET …/stages/{id}/0/taskSummary?quantiles=0.25,0.5,0.75,0.95,1.0` para los stages 20, 30, 35, 111, 132, 134, 135, 141, 147, 148 | Cuantiles de tiempo y de lectura de shuffle por tarea |
| E5 | REST | `GET …/applications/{app}/sql`, `?offset=20…120`; ejecución 86 (jobs 66–68) | Plan: `SortMergeJoin LeftOuter` con `Exchange` y `Sort` en ambos lados, en los dos joins; `BatchEvalPython` tras el segundo |
| E6 | SQL | `EXEC sys.sp_get_table_health_metrics @tableName='dbo.customers'` en lh_silver; `SELECT COUNT(*), MAX(source_run_seq)` | Ver métricas; 165 309 filas lógicas, `source_run_seq` máx. 13 |
| E7 | SQL | `SELECT TOP 4 store_id, COUNT(*) … GROUP BY store_id` en lh_bronze; ídem con `customer_id` | `store_id = 1` con 6,6 M filas; `customer_id` máx. 50 filas por cliente |
| E8 | SQL | `SELECT CASE … COUNT(*) FROM dbo.sales_raw GROUP BY …` | `null` 7 698 979; `evening` 275 717; `standard` 3 025 304 |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | El `MERGE` y la lectura de `customers` son el paso que más crece y el de mayor peso | Alta | Alta | E3, E2, E4, E6 |
| H2 | Data skew en el join por `store_id` | Media | Alta | E2, E4, E7 |
| H3 | Time skew en la escritura de `sales` por la UDF de `note_class` | Media | Media | E4, E8 |
| H4 | Los dos joins son `SortMergeJoin` con shuffle, sin broadcast | Media | Alta | E5 |

### H1 · `customers` crece en archivos y borrados

- **Qué ocurre:** el statement 4 pasa de 108 s a 421 s (63 % del tiempo del notebook el 2-nov). Los stages 20 (`first`, que lee `MAX(source_run_seq)`), 30 y 132 recorren 608–660 tasks de ~0,1 MB de entrada, con tareas homogéneas (p50 3,5 s, p95 5,2 s en el stage 20): no hay skew, el coste viene de abrir muchos archivos pequeños.
- **Por qué:** `customers` tiene 21 104 archivos de ~4,4 KiB, 15 557 bitmaps de borrado y 149 279 filas borradas de 314 588 (E6). Cada `MERGE` aplica unas 14 000 filas pendientes y añade archivos y vectores de borrado sin compactar. El Advisor pide `OPTIMIZE` sobre `customers` en tres ejecuciones SQL (E2). Que el crecimiento sea por acumulación entre ejecuciones se infiere de los tiempos de E3 y del estado actual de E6; no tengo `DESCRIBE HISTORY` para medir los archivos de cada día.
- **Impacto:** +313 s en el notebook entre el 30-oct y el 2-nov. Esto corrige a H1 y D2 de `01-pl-daily-sales-crecimiento.md`, que descartaba `customers` solo por el volumen de filas.

### H2 · Data skew por `store_id`

- **Qué ocurre:** tres stages (135, 141, 147, jobs 66-68) tienen una tarea que lee 752 MB mientras la mayoría lee menos de 1 MB, y el Advisor lo marca como skew (E2, E4). En el stage 147 una tarea tarda 13,8 s frente a 2 ms de mediana.
- **Por qué:** `store_id = 1` tiene 6,6 M de 11 M filas (60 %), mientras `customer_id` está repartido (máx. 50 filas por cliente) (E7). Con AQE y `skewJoin` desactivados, el hash de `store_id = 1` va a una única partición. Que el stage 147 corresponda al join por `store_id` es una inferencia: el volumen coincide, pero no hay mapa explícito stage → operador.
- **Impacto:** el job de los joins (jobs 66-68) dura unos 152 s (E5, ejecución 86), y cada vez más porque la tienda 1 sigue acumulando el 60 % de las filas nuevas (suposición: se mantiene el reparto actual).

### H3 · Time skew por la UDF

- **Qué ocurre:** en el stage 148 (64 tareas, tras `repartitionByRange(64, "sale_ts")`) la lectura de shuffle es uniforme (21–26 MB) pero el tiempo no: p50 6,6 s, p95 21,9 s, máx. 26,2 s (3,9×).
- **Por qué:** la UDF solo ejecuta el bucle de 100 `re.sub` para filas con `notes` y hora ≥ 22 (275 717 filas, 2,5 %; E8). Por el particionado por rango de `sale_ts`, esas filas caen en pocas particiones. Es skew de CPU y no de datos. Por eso es una inferencia: no medí qué tareas contienen esas horas.
- **Impacto:** el stage 148 tarda 26 s de pared, el de mayor tiempo del statement 6 tras los joins (E2).

### H4 · Estrategia de los joins

- **Qué ocurre:** `sales_raw` ⟕ `customers` (por `customer_id`) y el resultado ⟕ `stores` (por `store_id`) son ambos `SortMergeJoin LeftOuter`, con `Exchange` y `Sort` en los dos lados (E5). `stores` también hace shuffle.
- **Por qué:** `autoBroadcastJoinThreshold=-1` impide el `BroadcastHashJoin` aunque `stores` sea pequeña, y `adaptive.enabled=false` impide la conversión dinámica y el tratamiento de skew. Además `shuffle.partitions=2000` fragmenta un shuffle de ~1,3 GB en tareas de ~1 MB (stage 134: p50 de lectura 1,0 MB, 2000 tareas).
- **Impacto:** sin broadcast, `store_id` se redistribuye entera por hash, y eso es lo que provoca H2.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Compactar y purgar `lh_silver.customers` y evitar el escaneo del `MAX` | H1 | Alto | Bajo | Bajo | Sí |
| R2 | Hacer broadcast de `stores` y activar AQE | H2, H4 | Alto | Bajo | Bajo | Sí |
| R3 | Sustituir la UDF y cambiar el particionado | H3 | Medio | Medio | Medio | Sí |

### R1 · Mantenimiento de `customers`

- **Cambio propuesto:**

  ```sql
  REORG TABLE lh_silver.customers APPLY (PURGE);
  OPTIMIZE lh_silver.customers;
  ```

  Y en `nb_02`, guardar la última `run_seq` aplicada en una tabla de control en lugar de `SELECT MAX(source_run_seq)` sobre `customers`. Programar `OPTIMIZE` periódico o activar optimize write en la escritura.
- **Impacto esperado:** el stage 20 y el merge dejan de abrir 21 104 archivos; el `MERGE` volvería hacia los ~108 s de la primera ejecución. Es una estimación, no una medida.
- **Cómo validarlo:** repetir `sys.sp_get_table_health_metrics` (archivos y filas borradas) y el tiempo del statement 4 con la agrupación de E3.
- **Reversión:** `OPTIMIZE` y `REORG` no cambian los datos lógicos; el estado anterior se puede recuperar con `RESTORE` mientras no se haya hecho `VACUUM`.
- **Requiere confirmación:** Sí, es una escritura sobre una tabla.

### R2 · Broadcast de `stores` y AQE

- **Cambio propuesto:**

  ```python
  from pyspark.sql.functions import broadcast
  spark.conf.set("spark.sql.adaptive.enabled", "true")
  spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")
  # quitar autoBroadcastJoinThreshold=-1 y bajar shuffle.partitions (p. ej. 200)
  .join(broadcast(spark.read.table("stores").select(...)), "store_id", "left")
  ```

- **Impacto esperado:** el join por `store_id` deja de ser un shuffle, y con él el 752 MB en una tarea; AQE puede además fusionar particiones pequeñas. Estimación.
- **Cómo validarlo:** tras la próxima ejecución, ver que el plan no tenga `SortMergeJoin` para `stores` y que el Advisor no devuelva skew en esos jobs.
- **Reversión:** restaurar las tres líneas de `spark.conf.set` actuales.
- **Requiere confirmación:** Sí, modifica un notebook.

### R3 · UDF y particionado

- **Cambio propuesto:** reescribir `classify_note` con expresiones nativas (`when`, `regexp_replace`, `length`) o aplicar la UDF solo a `hour >= 22 AND notes IS NOT NULL`; cambiar `repartitionByRange(64, "sale_ts")` por un `repartition(64)` aleatorio si no se necesita el orden por fecha.
- **Impacto esperado:** repartir el trabajo de CPU entre las 64 tareas; no medido.
- **Cómo validarlo:** p95/mediana de tiempo de tarea del stage de escritura (< 3×, `performance-patterns.md`).
- **Reversión:** volver al código anterior.
- **Requiere confirmación:** Sí, modifica un notebook y puede cambiar el resultado de `note_class`.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Skew por `customer_id` | E7 | Máx. 50 filas por cliente |
| D2 | Spill por memoria insuficiente | E4 | `diskBytesSpilled` = 0 en los 10 stages con quantiles |
| D3 | Skew en los stages 20, 30 y 132 | E4 | Tareas homogéneas (p50 3,5 s, p95 5,2 s en el stage 20); el coste es de archivos pequeños |

## Siguientes pasos

- [ ] Aprobar y aplicar R1 y R2 — responsable: dueño del pipeline · relacionado con: R1, R2
- [ ] Ejecutar `DESCRIBE HISTORY lh_silver.customers` (Livy, lectura) para medir los archivos añadidos por día — responsable: analista · relacionado con: H1
- [ ] Repetir el análisis tras aplicar R1–R3

## Notas

### Limitaciones

- Spill y quantiles solo se consultaron para 10 stages; hay 187. Los 177 restantes no se revisaron.
- Los planes y stages detallados son de la sesión del 2-nov. De las otras cuatro solo se compararon tiempos por statement.
- La asignación stage → join (H2) y la distribución de las horas por partición (H3) son inferencias.
- Los tiempos por statement se calculan con el primer y último job de cada `jobGroup`, así que incluyen esperas entre jobs.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| `DESCRIBE HISTORY` / `DESCRIBE DETAIL` de `customers` | No se ejecutó Livy; no era imprescindible | El crecimiento diario de archivos de `customers` es inferido (H1) |
| Skew de `Silver to gold` | Fuera de alcance | Pendiente |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Retención de detalle Spark | `SKILL.md` y `automated-diagnostic-workflow.md`: stages y plan duran minutos a horas | La sesión del 2-nov (05:03 UTC) respondió 13 h después y las de 30-oct también devolvieron jobs | Se usó lo que devolvió la API; la retención real es mayor que la documentada |
