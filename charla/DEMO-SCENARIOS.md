# Demo scenarios: what is planted and what the agent should find

Speaker notes for each live demo: the problem built into the workspace, where it lives, a prompt
to give the agent (in Spanish, as in the talk) and the findings to expect. Run numbers assume the
default `-SimulatedDays 10`; use `-SimulatedDays 15` or more if demo 1 needs a clearer trend (each
run takes 15-20 minutes).

The prompts ask for the evidence that exposes each problem without naming the cause. Spark run
details (stages, tasks) are kept for a few hours only, so run the Spark demos soon after the
History phase.

## Before the talk

The planted problems are not commented in the item code, so the agent has to find them from
evidence. This file and `demo-setup/` would give them away. During the talk, either move
`demo-setup/` out of the repository or deny the agent access to it in `.claude/settings.local.json`:

```json
{ "permissions": { "deny": ["Read(demo-setup/**)", "Grep(demo-setup/**)", "Glob(demo-setup/**)"] } }
```

## Summary

| # | Demo | Main item | Area file of the agent |
|---|------|-----------|------------------------|
| 1 | Pipeline slower every day | `pl_daily_sales` | spark-runs |
| 2 | Oversized Spark cluster | `env_gold`, `pool_gold_xl` | spark-resources |
| 3 | Data skew, time skew, heavy shuffle | `nb_02_bronze_to_silver` | spark-runs |
| 4 | Spark config per medallion layer | `env_bronze`, `env_silver`, `env_gold` | spark-resources |
| 5 | Spark failures and OOM | `pl_daily_sales` run 6, `pl_store_snapshot` | spark-runs |
| 6 | Delta tables that need maintenance | `lh_bronze`, `lh_silver`, `lh_gold` | delta-tables |
| 7 | Model best practices | `sm_sales` | semantic-models |
| 8 | DAX performance | `sm_sales` measures, `dax/report-queries.dax` | semantic-models |
| 9 | Model refreshes | `sm_sales` refresh history | semantic-models |

---

## 1. Pipeline slower every day

> El pipeline `pl_daily_sales` del workspace DataSaturday tarda cada día más (cada ejecución simula
> un día de negocio). No me vale un umbral de regresión: quiero la tendencia de cada actividad y de
> cada notebook entre ejecuciones, incluido el shuffle y el número de jobs de Spark. Revisa cómo lee
> y escribe cada notebook (carga completa o incremental) y cómo evolucionan las tablas que toca
> (ficheros, commits y checkpoints del `_delta_log`). ¿Qué crece y por qué?

| Planted cause | Where | Evidence the agent can use |
|---------------|-------|----------------------------|
| Silver rebuilds the whole bronze history every run (`sales_raw` read in full, deduplicated and overwritten) | `nb_02` | Duration of the "Bronze to silver" activity grows with each run while "Ingest bronze" stays flat |
| 400 small files appended to `sales_raw` per run, never compacted | `nb_01` (`WRITE_PARTITIONS`, optimize write turned off in the notebook because the `readHeavyForPBI` profile of `env_bronze` would turn it on) | File count and average file size of `sales_raw` |
| 30 tiny commits per run to `inventory_events` with `delta.checkpointInterval = 1000` | `nb_01` | Long `_delta_log` with no checkpoint; slower reads of the table in `nb_02` |
| `count()` called twice on uncached DataFrames, so the dedup window runs again before the write | `nb_02` | Repeated jobs over the same input in the Spark application |
| Gold overwrites `fact_sales` in full and the model does a full refresh | `nb_03`, `nb_04` | Gold activity and refresh duration grow with total rows |

Expected recommendation: incremental load (MERGE of the new business day), compaction, restore the
checkpoint interval, cache or remove the extra actions.

With few runs the total duration grows slowly and stays well below the usual 2x regression
threshold; the shuffle of `nb_02` (it grew from about 450 MB to 3.7 GB in 9 runs) and the file
counts show the trend more clearly than the durations.

## 2. Oversized Spark cluster

> ¿Está sobredimensionado el clúster de Spark que usa la capa gold (`env_gold`, pool
> `pool_gold_xl`)? Compara el tamaño de nodo, la asignación dinámica y los ejecutores con el uso
> real de cores de las últimas sesiones de `nb_03_silver_to_gold`, contrástalo con `env_bronze` y
> `env_silver`, y propón el tamaño adecuado.

- `env_gold` runs on `pool_gold_xl` (Large nodes by default) with **dynamic allocation off** and a
  fixed number of executors (max nodes − 1), each with 16 cores and 112 GB.
- `nb_03` reads a few million rows and then writes several small tables one after another, so most
  executor cores sit idle.
- Expected: low core efficiency / idle executor time; recommend the starter pool or Medium nodes
  with dynamic allocation. Contrast with `env_bronze` and `env_silver`, which use the starter pool.
- Bonus the agent may find: `nb_04` opens a Spark session only to call the refresh API, so its cores
  sit idle; the native semantic model refresh activity would avoid it.

## 3. Data skew, time skew and heavy shuffle

> ¿Hay data skew o time skew en `nb_02_bronze_to_silver`? ¿Qué stages tienen el shuffle más pesado?
> Para cada join indica la estrategia del plan (broadcast o sort-merge) y compárala con la
> configuración Spark efectiva de la sesión. Por stage: registros y bytes de la tarea máxima frente
> a la mediana, spill, número de tareas y stages que se repiten en varios jobs.

| Case | Planted in `nb_02` | What the Spark metrics show |
|------|--------------------|-----------------------------|
| **Data skew** | 60% of sales belong to `store_id = 1` ("Flagship Madrid"). The join with `stores` is a sort-merge join because broadcast is disabled and AQE (with skew join) is off in `env_silver` and again in the notebook. | One task in the join stage reads far more records and bytes than the median |
| **Time skew without data skew** | `repartitionByRange(64, "sale_ts")` puts the evening sales together; the `classify_note` Python UDF only does heavy work for hours ≥ 22. | Tasks with similar record counts but very different durations |
| **Heavy shuffle** | Dedup window `partitionBy("sale_id")` over the full history, and the join with `customers` (200k rows) without broadcast. | Large shuffle write/read in those stages, growing every run |
| **Spill** | The skewed join partition holds about 60% of the rows in one task. | Memory and disk spill on that task, if the partition outgrows the execution memory (depends on volume) |
| **Too many small tasks** | `spark.sql.shuffle.partitions = 2000` (environment and notebook) for a join on 50 store keys. | Thousands of near-empty tasks; scheduler overhead |
| **Recomputation** | Two `count()` actions before the write, no cache. | The same stages appear in several jobs |
| **Python UDF overhead** | `classify_note` is a row-at-a-time Python UDF. | `BatchEvalPython` in the plan; time in Python workers |

Other cases worth mentioning in the talk, not planted: exploding joins (duplicate keys on both
sides), `collect()` of large results to the driver, skew in `groupBy` aggregations, broadcast of a
table that is too large, and partition pruning lost by a function on the partition column.

## 4. Spark configuration per medallion layer

> ¿La configuración de Spark de cada capa de la arquitectura medallion es correcta? Para bronze,
> silver y gold, haz una tabla con lo declarado en el environment, lo que sobrescribe el notebook con
> `spark.conf.set` y lo efectivo, frente a lo que necesita la capa según su carga. Gold la consume
> `sm_sales`; ten en cuenta que podría pasar a Direct Lake.

| Layer | Planted (environment + notebook) | Expected for that layer |
|-------|----------------------------------|-------------------------|
| Bronze (write-heavy) | `resourceProfile = readHeavyForPBI`, V-Order **on**, optimize write off, auto compact off; the notebook turns optimize write off again | `writeHeavy`, V-Order off, optimize write / auto compact on |
| Silver (balanced) | AQE off, skew join off, broadcast disabled (`-1`), 2000 shuffle partitions; the notebook sets all four again | AQE and skew join on, broadcast threshold by default, partitions sized to the data |
| Gold (read-heavy for Power BI) | `resourceProfile = writeHeavy`, V-Order **off**, optimize write off; the notebook turns AQE off | `readHeavyForPBI` or V-Order + optimize write on, AQE on. Also valid: V-Order off while `sm_sales` stays in Import mode, on as soon as it moves to Direct Lake (Learn advises V-Order only for Direct Lake consumers) |
| All | Native execution engine off | Consider enabling it |

The agent should flag the notebook-level `spark.conf.set` overrides (they win over the
environment) and the V-Order key discrepancy listed in the `fabric-perf-analysis` traps. A
resource profile also sets properties (`readHeavyForPBI` turns optimize write on), so the agent
should compare declared and effective values rather than trust the environment alone.

## 5. Spark failures and OOM

> ¿Qué ejecuciones de Spark han fallado en DataSaturday y por qué? ¿Alguna por memoria? Revisa
> todos los pipelines, cuenta los reintentos y lo que cuestan, distingue el OOM de driver, el de
> ejecutor y los límites internos de Spark, e indica qué datos faltan aguas abajo por cada fallo.

| Failure | When | Cause |
|---------|------|-------|
| `pl_daily_sales` fails in "Ingest bronze" | Run 6 (every `schema_drift_every` = 6 runs) | The source sends `amount` as text; the Delta append fails with a schema mismatch (double vs string). That business day is missing downstream. |
| `pl_store_snapshot`, `export_format = nested` | History phase, after the daily runs | `collect_list` of JSON documents per store: the hot store builds one huge row, so the executor runs out of memory or exceeds Spark's 2 GB row limit. The activity retries once, so the cost is paid twice. |
| `pl_store_snapshot`, `export_format = pairs` | History phase, after the daily runs | `toPandas()` of the sales table, then a pandas self-merge on `store_id`: driver `MemoryError`. |

The "nested" failure depends on data volume (the hot store needs a few million rows, which the
defaults reach after about 8 days). If it succeeded, see the README troubleshooting table.

## 6. Delta tables that need maintenance

> ¿Qué tablas Delta de `lh_bronze`, `lh_silver` y `lh_gold` necesitan mantenimiento y qué operación
> propones? Dame un veredicto por tabla, también para las que no necesitan nada: ficheros pequeños,
> checkpoints, deletion vectors, ficheros sin referenciar con su retención y V-Order según quién lee
> cada capa.

| Table | Problem | Expected proposal |
|-------|---------|-------------------|
| `lh_bronze.sales_raw` | About 400 small files per run, never optimized | `OPTIMIZE` (decide on V-Order for bronze) |
| `lh_bronze.inventory_events` | 30 commits per run, no checkpoint (`checkpointInterval = 1000`), tiny files | Restore the checkpoint interval, `OPTIMIZE` |
| `lh_silver.customers` | Deletion vectors with daily updates and GDPR deletes: soft-deleted rows build up | `OPTIMIZE` / `REORG TABLE ... APPLY (PURGE)`, then `VACUUM` |
| `lh_silver.sales`, `lh_gold.fact_sales` | Overwritten in full every run, old files never vacuumed | `VACUUM` with a retention that respects time travel needs |
| `lh_gold.*` | Written with V-Order off, read by the semantic model | `OPTIMIZE ... VORDER` |
| `lh_gold.dim_date` | Healthy control table, written once | No action: checks that the agent does not over-recommend |
| `lh_gold.daily_store_sales` | Not planted on purpose: many tiny files per run from the gold write | Fix the write (fewer partitions) or `OPTIMIZE`; a valid extra finding |

`VACUUM` cannot free anything until the files are older than the 7-day default retention, so on a
fresh setup the expected answer is to schedule it, not to run it now.

## 7. Semantic model best practices

> Revisa si el modelo semántico `sm_sales` cumple las buenas prácticas de modelado. Usa la
> definición completa del modelo y no solo INFO.VIEW: tipos de datos exactos (también los de las
> claves de relación), cardinalidad comprobada con los datos, columnas calculadas en tablas de
> hechos, anotaciones del modelo, tabla de fechas y en qué tabla viven las medidas. Si ves problemas
> de integridad, rastrea su origen en el lakehouse.

- Bidirectional relationship `fact_sales` ↔ `dim_customer`.
- Many-to-many, bidirectional relationship `promotions` ↔ `dim_product` although `product_code` is
  unique in `dim_product`.
- Relationship on a text key (`product_code`).
- High-cardinality columns loaded but not needed for analysis: `sale_id` (GUID), `sale_ts`
  (datetime to the second), `email`.
- Calculated columns in the fact table (`line_margin`, `year_month`) instead of computing them upstream.
- `double` for money columns instead of fixed decimal.
- Key columns visible and summarized with `sum` (`store_id`, `customer_id`).
- `dim_date` exists but is not marked as a date table; time intelligence uses `fact_sales[sale_date]`.
- Auto date/time annotation enabled; implicit measures not discouraged.
- Measures without format strings or descriptions, and all of them in the fact table.
- `IFERROR` instead of `DIVIDE`; `FILTER` over the whole fact table inside `CALCULATE`.
- Side effect, not planted on purpose: the GDPR deletes in `silver.customers` leave sales whose
  `customer_id` no longer exists in `dim_customer` (about 14% of `fact_sales`), so customer totals
  fall into blank. A valid finding if the agent traces it back to the deletes.

## 8. DAX performance

> El informe de ventas va lento. Analiza el rendimiento de las medidas de `sm_sales` con estas
> consultas de la página. Mide cada consulta y cada medida aislada, con trazas si están
> disponibles, y para las lentas prueba la reescritura en `DEFINE` comprobando que da el mismo
> resultado. Indica también qué medidas no hace falta tocar.

Give the agent the queries in [`dax/report-queries.dax`](dax/report-queries.dax) (paste them; they
live in the hidden folder). Traces need the local `powerbi-modeling-mcp` server with its EULA
accepted; accept it before the talk, or the agent can only time queries without the FE/SE split.

| Measure | Why it is slow | Better pattern |
|---------|----------------|----------------|
| `Avg Ticket` | `AVERAGEX` over every fact row with `CALCULATE` inside: context transition per row on a table without a key | `DIVIDE([Total Sales], COUNTROWS(fact_sales))` |
| `Sales Running Total` | `FILTER(ALL(fact_sales))` on the datetime column, evaluated for every point | Filter `dim_date[date]` instead of the fact table |
| `Top 100 Customers Sales` | `RANKX` inside `SUMX` over 200k customers: quadratic work | `TOPN` once, then `SUMX` over that table |
| `Enterprise Sales` | `FILTER(fact_sales, RELATED(...))` iterates the fact table | `CALCULATE([Total Sales], dim_customer[segment] = "Enterprise")` |
| `Active Customers` | `FILTER` + `CALCULATE` per customer | `DISTINCTCOUNT(fact_sales[customer_id])` |
| `Margin %` | `IFERROR` | `DIVIDE` |
| `Total Sales`, `Total Quantity` | Simple sums | Control measures: no change expected |

With 10 simulated days (about 9 M rows) `Avg Ticket`, `Sales Running Total` and `Top 100 Customers
Sales` take seconds, while `Enterprise Sales` and `Active Customers` stay below 150 ms: the engine
handles those patterns well at this volume. If the agent measures them and leaves them alone, that
is the right answer and a good point for the talk (it does not over-recommend); the better pattern
still applies for readability and larger volumes.

## 9. Semantic model refreshes

> ¿El modelo `sm_sales` se refresca correctamente? Cruza el historial de refrescos (incluidos los
> fallidos y su mensaje de error), la programación del modelo y las horas de inicio y fin de
> `pl_daily_sales`, y revisa cómo lanza y vigila el refresco `nb_04`. ¿Cuánto tarda cada refresco,
> por qué falla y está alineado con el pipeline?

| Planted | Where | Expected finding |
|---------|-------|------------------|
| On runs 4 and 8 the gold layer renames `dim_product.category` to `product_category`; the next run restores it | `nb_03` (`product_schema_v2_every = 4`) | Intermittent refresh failures: column `category` not found |
| The refresh is requested and not awaited, and errors are only printed | `nb_04` | The pipeline is green while the refresh fails: nobody is alerted |
| Scheduled refresh at 05:30, before the 06:00 pipeline | Refresh schedule | That refresh loads the previous day's data |
| Scheduled refresh at 06:30, while the pipeline is still running, plus the refresh `nb_04` requests at the end | Refresh schedule, `nb_04` | Overlapping or redundant refreshes; data loaded mid-pipeline |
| Full refresh of a fact table that grows every day | Model, `nb_03` | Refresh duration grows with the pipeline |
| No SQL endpoint metadata sync after gold writes | `nb_04` | Possible: the refresh reads the SQL endpoint before it sees the new Delta version |

The schedule rows only show up after the Schedule phase has run for at least one real day.
