# Area: SQL endpoint and Warehouse

## 1. What it covers

T-SQL workload on Fabric Warehouses, Lakehouse SQL analytics endpoints and mirrored databases: slow, frequent, expensive, failed or canceled queries, regressions against a baseline, and custom SQL pool pressure.

## 2. Typical questions

- "Which queries consume the most on the warehouse this week?"
- "This query got slower since Monday."
- "Why are queries failing or being canceled?"
- "Are our custom SQL pools under pressure?"
- "Should we cluster this warehouse table?"

## 3. Where the knowledge lives

Base path: `.claude/skills/sqldw-cli/`.

| Reference | Provides |
|-----------|----------|
| `SKILL.md` § Mode selection, § Mode boundary rule, § Execution surface — `fabric-sqlendpoint-execute_query`, § Rules | Mode choice (operations for diagnosis), read-only rule, MCP limits. |
| `references/operations.md` MODE-CRITICAL NOTES block, § Prerequisites, § Fabric DW Constraints, § Gotchas, Rules, Troubleshooting | Permissions, retention, unsupported features, banned statements. |
| `references/operations/scenarios.md` | Procedures for composite questions (failures, consumers, regressions, clustering, pools) and the response contract. |
| `references/operations/query-reference.md` | Query Insights templates and their thresholds (§ Top Resource Consumers, § Compare Recent vs Baseline, § Long-Running Query Analysis, § Cluster Key Recommendations). |
| `references/operations/resource-consumers.md` | Concentration rule, baseline comparison, cache interpretation. |
| `references/operations/pool-pressure.md` | Building pressure intervals and correlating requests. |
| `references/operations/failure-analysis.md` | Failure and cancellation summary, error-code categories, interpretation rules. |
| `references/consumption.md` § MCP Limits | Row limit, timeout, request rate of the MCP tool. |
| `apm_modules/microsoft/skills-for-fabric/common/SQLDW-CONSUMPTION-CORE.md` § Monitoring and Diagnostics, § Item-Type Capability Matrix | Query Insights views, DMV visibility, what each item type supports. |

## 4. Signals to measure

| Signal | How to get it | Threshold / interpretation |
|--------|---------------|----------------------------|
| Top consumers by CPU, elapsed, data scanned | `queryinsights.exec_requests_history` templates | `references/operations/query-reference.md` § Top Resource Consumers; `resource-consumers.md` § Measure concentration |
| Regression vs baseline | Template § Compare Recent vs Baseline | Regression threshold in that section |
| Cache state of a query (remote vs memory/disk) | Columns in `exec_requests_history` | `resource-consumers.md` § Cache interpretation |
| Failures and cancellations by error code | `failure-analysis.md` queries + `sys.messages` | `failure-analysis.md` § Interpretation rules |
| Pool pressure intervals | `queryinsights.sql_pool_insights` | `pool-pressure.md` § Interpretation |

## 5. Known traps

- **Contributor required.** `queryinsights` needs Contributor or higher (`references/operations.md` § Prerequisites). With Viewer the MCP connects but these views fail: record it in Notes as missing permission, citing that section.
- **Retention.** Query Insights keeps 30 days and lags up to about 15 minutes (`references/operations.md` MODE-CRITICAL NOTES block; `SQLDW-CONSUMPTION-CORE.md` § Query Insights — Historical Analytics). Never suggest "enabling" Query Insights.
- **The MCP tool is not read-only by itself.** DML works through `execute_query`; read-only is a skill rule (`SKILL.md` § Rules). Only `SELECT` and the single allowed `EXEC sys.sp_get_table_health_metrics`.
- **MCP limits.** Row cap (a result of exactly the cap means truncated), timeout, request rate, one batch per call, only the last result set (`SKILL.md` § Execution surface; `references/consumption.md` § MCP Limits). Always use `TOP`, a time window and aggregates.
- **Exclude your own queries.** Filter out the agent's monitoring queries (label and `queryinsights` text) as `resource-consumers.md` § Measure concentration shows, or they skew the ranking.
- **Pool pressure only correlates.** Overlap of a request with a pressure interval is correlation, not cause; it only counts when time and pool name both match (`pool-pressure.md` § Interpretation; `failure-analysis.md` § Interpretation rules).
- **Clustering.** Recommend cluster keys only from columns used in `WHERE` predicates, within the column-count and cardinality limits of `references/operations.md` § Recommend Cluster Keys, and only on Warehouses: Lakehouse and mirrored endpoints do not support it (`SQLDW-CONSUMPTION-CORE.md` § Item-Type Capability Matrix). Verification queries disagree between files; use the one in `references/operations.md`.
- **No result-set caching.** Never recommend it (`references/operations.md` MODE-CRITICAL NOTES block). `SQLDW-CONSUMPTION-CORE.md` § Result Set Caching (Preview) presents it as available: record the conflict in Notes.
- **Cross-database queries** are logged in the Query Insights of the item you connected to (`SQLDW-CONSUMPTION-CORE.md` § Monitoring and Diagnostics). Connect to the right item before concluding "no activity".
- **Units.** Query Insights CPU ms are not capacity CU (`capacity-metrics-correlation.md` § Timeframe and Correlation Limits).

## 6. Writes (propose only)

`ALTER`, `CREATE`, `DROP`; statistics creation or update; clustering via CTAS + rename (hand off to authoring); custom SQL pool configuration; `KILL`; `refreshMetadata` on the SQL endpoint; any `ALTER DATABASE` setting.

## 7. Cross-area pivots

| Evidence | Go to |
|----------|-------|
| Lakehouse endpoint slow on specific tables, many files, stale metadata | `delta-tables.md` |
| SQL load coincides with capacity throttling | `capacity.md` |
| Queries come from a Direct Lake on SQL model falling back to DirectQuery | `semantic-models.md` |
| Queries come from a pipeline or notebook step | `spark-runs.md` |
