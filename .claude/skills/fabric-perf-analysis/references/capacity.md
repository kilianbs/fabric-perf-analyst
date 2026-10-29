# Area: capacity

## 1. What it covers

Fabric capacity consumption: CU spikes, throttling (delay, rejection), carry-forward debt, and which items, operations or SQL queries drove them.

## 2. Typical questions

- "We had CU spikes and throttling yesterday afternoon. Who caused it?"
- "Is the capacity undersized or is one workload misbehaving?"
- "Interactive reports were slow at 9:00; was the capacity throttling?"
- "Which items consume the most CU this week?"

## 3. Where the knowledge lives

| Reference | Provides |
|-----------|----------|
| `.claude/skills/sqldw-cli/references/operations/capacity-metrics-correlation.md` § Existing Tool and Authentication Boundary | Use only the existing FabricIQ MCP; no new auth, raw REST DAX or extra MCP server. |
| same file § Timeframe and Correlation Limits | Fixed-window tables, overlap with Query Insights history, units, non-UTC timestamps. |
| same file § 1. Discover the Installed Capacity Metrics Model | FabricIQ tool sequence to find and read the installed model. |
| same file § 2. Resolve the Capacity and Rank Costly Items (branches "Timestamped item/hour", "Fixed-window health", "Broader item-total fallback") | Procedure, the metrics that define pressure, `CapacitiesList` usage. |
| same file § 3 to § 5 | Operation-level evidence, resolving the right SQL endpoint, expensive SQL users and queries. |
| same file § 6, § 7, § Response Contract | Custom SQL pool profiling and recommendation rules; output contract. |
| `.claude/skills/fabriciq/SKILL.md` § Available Tools, § Must/Prefer/Avoid, § Error Taxonomy, § DAX Rules | FabricIQ tool limits (artifacts, rows, queries per call), unsupported DAX (INFO, DMV, MDX), errors such as MCP not enabled on the tenant. |
| `apm_modules/microsoft/skills-for-fabric/common/COMMON-CORE.md` § Capacity Management, § Rate Limiting & Throttling | Capacity REST routes (read: list/get) and API throttling rules. |

## 4. Signals to measure

| Signal | How to get it | Threshold / interpretation |
|--------|---------------|----------------------------|
| Average / peak CU %, minimum utilization, variance | Capacity Metrics model via FabricIQ `ExecuteQuery` | `capacity-metrics-correlation.md` § 2 |
| Interactive / background delay and rejection, cumulative carry-forward | Capacity Metrics throttling tables (`Usage Operation (...)`) | `capacity-metrics-correlation.md` § 2 |
| Top items and operations by CU (s) in the window | Capacity Metrics item tables | Ranking only; units are CU seconds |
| SQL users and queries behind a SQL endpoint spike | Query Insights (see `sql-endpoint.md`) | Different unit (CPU ms); correlate by time and item only |

## 5. Known traps

- **High CU is not pressure.** Pressure means delay, rejection, throttling or carry-forward debt, not a high CU % alone (`capacity-metrics-correlation.md` § 2). A capacity at 90 % with no delay is a sizing observation, not a finding of throttling.
- **`CapacitiesList` is an M parameter**, not a table or a tool. Fill it only with IDs returned by the live `Capacities` table; some item tables accept one capacity only, so retry once with a single ID on a data-location error (`capacity-metrics-correlation.md` § 2).
- **No join on Operation Id.** Never join the Capacity Metrics Operation Id with `distributed_statement_id` (`capacity-metrics-correlation.md` § Timeframe and Correlation Limits). `SQLDW-CONSUMPTION-CORE.md` § Query Activity & Capacity Metrics says they correlate; the operations reference wins. Record the conflict in Notes.
- **Different units.** CU seconds (Capacity Metrics) and CPU ms (Query Insights) are not convertible; never express a Query Insights share as a share of capacity CU (`capacity-metrics-correlation.md` § Timeframe and Correlation Limits).
- **Limited window.** The skill states no retention; it only lists fixed-window tables. Learn states 14 days for the app ([What is the Capacity Metrics app](https://learn.microsoft.com/fabric/enterprise/metrics-app#considerations-and-limitations)). If the requested window is older, say the data expired; do not infer it.
- **Timestamps.** Report timestamps may not be UTC (`capacity-metrics-correlation.md` § Timeframe and Correlation Limits). Convert using the app's `UTC_offset` parameter and state the conversion in Notes.
- **Empty drillthrough is not zero.** An empty drillthrough table means "unavailable without report context" (`capacity-metrics-correlation.md` § 3).
- **Model schema varies by app version.** Read the schema with `GetSemanticModelSchema` before writing DAX; do not assume table names (`capacity-metrics-correlation.md` § 1).
- **Supportability.** Learn says the Capacity Metrics semantic model is supported only for the app's own reports. The skill queries it anyway; record this in Notes → Discrepancies.

## 6. Writes (propose only)

Scaling or pausing the capacity, changing surge protection, reassigning workspaces (`assignToCapacity`), creating or resizing custom SQL pools, changing schedules to spread load. These are administration tasks: propose them and point to `FabricAdmin`.

## 7. Cross-area pivots

| Evidence | Go to |
|----------|-------|
| Top consumer is a notebook, Spark job or pipeline | `spark-runs.md` |
| Top consumer is a SQL endpoint or Warehouse | `sql-endpoint.md` |
| Top consumer is a semantic model (queries or refresh) | `semantic-models.md` |
| Spark sessions wait without `appId` while CU is saturated | `spark-resources.md` |
