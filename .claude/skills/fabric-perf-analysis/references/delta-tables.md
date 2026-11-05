# Area: Delta tables and materialized lake views

## 1. What it covers

Physical health of Lakehouse Delta tables (small files, fragmentation, deletion vectors, stale checkpoints, maintenance history) and the refresh behavior of materialized lake views (MLV).

## 2. Typical questions

- "Do our Delta tables need maintenance?"
- "Reads on this table get slower every week."
- "The MLV refresh failed / was skipped."
- "Is fragmentation the reason the pipeline or the report is slow?"

## 3. Where the knowledge lives

| Reference | Provides |
|-----------|----------|
| `.claude/skills/sqldw-cli/references/operations/lakehouse-health.md` § Applicability, § Inventory, § Health procedure, § Interpretation, § Response contract | Health procedure with `sys.sp_get_table_health_metrics`, anomaly codes, required permission, how to read and report results. |
| `.claude/skills/sqldw-cli/references/operations.md` § Prerequisites, § Connection | `VIEW DEFINITION` requirement; connecting with the SQL endpoint id. |
| `.claude/skills/sqldw-cli/references/consumption.md` § MCP Limits | Request rate and row limits of the SQL endpoint MCP. |
| `.claude/skills/spark-cli/references/operations/performance-patterns.md` § Detection Thresholds, § Anti-Patterns | Small-file and layout signals from the Spark side. |
| `.claude/skills/spark-cli/references/operations/automated-diagnostic-workflow.md` Step 1 | Reading Lakehouse job history, including `TableMaintenance` runs. |
| `.claude/skills/spark-cli/references/mlv.md` § 6. Run History diagnostic workflow, § Trigger On-Demand Refresh (POST /instances), § MLV Execution Definitions, § Common Errors & Fixes, § Tips for Users | MLV REST routes, statuses, job types, permissions, errors, paging without OData. |
| `.claude/skills/spark-cli/references/operations.md` § Must/Prefer/Avoid | MLV failure-classification table. |
| `.claude/skills/spark-cli/references/authoring/resources/materialized-lake-view-patterns.md` § Refresh and orchestration guidance | Refresh semantics (read-only use). |

Table maintenance REST is not in the skills; Learn: [Manage a lakehouse with the REST API § Run table maintenance](https://learn.microsoft.com/fabric/data-engineering/lakehouse-api#run-table-maintenance-on-a-delta-table).

## 4. Signals to measure

| Signal | How to get it | Threshold / interpretation |
|--------|---------------|----------------------------|
| Table anomaly code and description | `EXEC sys.sp_get_table_health_metrics` per table via `fabric-sqlendpoint` | `lakehouse-health.md` § Interpretation |
| File count, size, growth | Health procedure output; `DESCRIBE DETAIL` only through Livy (Tier B, consumes CU) | `performance-patterns.md` § Detection Thresholds |
| Last maintenance run and status | Lakehouse job instances (`TableMaintenance`) | Learn statuses; `Deduped` = skipped because one was running |
| MLV run history, status per lineage, error code | MLV job instances | `spark-cli/references/mlv.md` § 6. Run History diagnostic workflow; MLV failure table in `spark-cli/references/operations.md` § Must/Prefer/Avoid |

## 5. Known traps

- **`itemId` is the SQL endpoint id.** The health procedure runs on the SQL analytics endpoint: use `sqlEndpointProperties.id` of the lakehouse, never the lakehouse id (`sqldw-cli/references/operations.md` § MCP Tool Signature, § Connection).
- **One anomaly per table.** The procedure returns only the most severe anomaly; absence of other codes is not proof of health. Output rows do not name the table: attach the input table name to each row, and keep the live description text (`lakehouse-health.md` § Interpretation).
- **Failed call = "No evaluada".** A failed or truncated call is "not evaluated", never healthy (`lakehouse-health.md` § Interpretation). Report it in Notes.
- **Request limit.** Run the procedure once per fully qualified table and respect the MCP request rate (`sqldw-cli/references/consumption.md` § MCP Limits; `sqldw-cli/references/operations/scenarios.md` § 4. Analyze Lakehouse tables needing attention). For many tables, sample the largest or the ones read by the slow workload and say so in Alcance.
- **Snapshot is not the Delta version.** The snapshot and checkpoint columns of the health procedure describe what the SQL endpoint has read, not the table's Delta version; use `DESCRIBE HISTORY` for versions and changes.
- **Non-default properties are findings.** A table property away from the default (a high `delta.checkpointInterval`, disabled optimize write, a custom retention) is a finding unless the writer's code or a comment justifies it; never discard it as "by design" without that evidence.
- **V-Order verdict per table.** Give each table a V-Order verdict from its readers: Direct Lake consumers need it; Import models and write-heavy layers do not (`spark-resources.md`, `readHeavyForPBI` trap).
- **Lakehouse only.** Health checks apply to Lakehouse SQL endpoints, not Warehouses (`lakehouse-health.md` § Applicability).
- **`DESCRIBE DETAIL` costs CU.** It needs a Livy session and statement; run it within the Tier B budget (agent § Action tiers: one session per analysis, deleted at the end).
- **MLV: no OData.** The MLV APIs do not support OData filters; filter and sort client-side and follow `continuationToken` (`spark-cli/references/mlv.md` § Tips for Users).
- **MLV: `Deduped` is not a failure.** It means another refresh was already running (`spark-cli/references/mlv.md` § 6. Run History diagnostic workflow, § Trigger On-Demand Refresh (POST /instances); Learn uses the same status for table maintenance). The UI "Skipped" shows as Cancelled in the API (same section).
- **MLV job type mismatch.** History shows `MaterializedLakeViews` while the trigger uses `refreshMaterializedLakeViews`; filter on both (`spark-cli/references/mlv.md` § 2. Use REST APIs exactly as documented, § Trigger On-Demand Refresh (POST /instances)).
- **`DeltaTableVersionNotFound` points to VACUUM.** A source version was vacuumed below retention (MLV failure table in `spark-cli/references/operations.md` § Must/Prefer/Avoid). Pivot: check maintenance history and retention; propose, do not change.
- **MLV permissions.** All MLV scheduling operations, including status and cancel, need workspace Contributor or Admin (`mlv.md` § Must). With Viewer, record it in Notes.

## 6. Writes (propose only)

`OPTIMIZE` (with or without V-Order / Z-Order), `VACUUM`, `REORG ... APPLY (PURGE)`, `TableMaintenance` jobs (Learn route above), `ALTER TABLE ... SET TBLPROPERTIES` (retention, CDF, optimize write), clustering, MLV refresh / cancel / schedule / execution-definition changes, `CREATE OR REPLACE` of an MLV, `refreshMetadata` on the SQL endpoint.

## 7. Cross-area pivots

| Evidence | Go to |
|----------|-------|
| Fragmentation explains a slower notebook or pipeline | `spark-runs.md` |
| Writer config (V-Order, optimize write, profile) causes the layout | `spark-resources.md` |
| Direct Lake model reads these tables (guardrails, row groups) | `semantic-models.md` |
| SQL endpoint queries slow on these tables | `sql-endpoint.md` |
