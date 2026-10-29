---
name: fabric-perf-analysis
description: "Read-only diagnosis of Microsoft Fabric performance problems: navigation layer over skills-for-fabric that maps symptoms to areas, lists known traps, and fixes the report format. Use when a Spark notebook, job or pipeline is slow, getting slower every day, skewed, spilling, failing or OOM; sessions are stuck or clusters look oversized; Delta tables or materialized lake views need maintenance or fail to refresh; SQL endpoint or Warehouse queries are slow or failing; DAX is slow, a model breaks best practices, or a refresh fails; or the capacity shows CU spikes or throttling."
---

# Fabric performance analysis

Thin navigation layer. The technical knowledge (thresholds, REST routes, procedures, permissions) lives in the installed `microsoft/skills-for-fabric` skills under `.claude/skills/` and their shared files under `apm_modules/microsoft/skills-for-fabric/common/` (restored by `apm install`). This skill tells you where to look, what usually goes wrong, and how to write the result. It never replaces the referenced skill: when this file and a referenced skill disagree, the referenced skill wins and the discrepancy goes to the report's Notes.

## Diagnostic method

Apply to every request, whatever the area:

1. **Symptom.** Restate the observable problem in measurable terms (what, which item, since when, how much).
2. **Area.** Pick the probable area(s) with the navigation map below. Read each area file, then the skills-for-fabric references it points to.
3. **Hypothesis.** Write down 1-3 candidate causes, each with the signal that would confirm or refute it.
4. **Minimum evidence.** Collect the smallest set of queries and calls that can decide each hypothesis. Bounded queries only (TOP, time window, aggregates).
5. **Contrast.** Confirmed by data → finding. Refuted by data → Descartado (D#). No data obtainable → Notes, "no verificada".
6. **Finding.** State the finding with its evidence IDs, severity (threshold cited from the referenced skill) and confidence.

**Pivoting.** If evidence points outside the current area (the "cross to" column below, or section 7 of each area file), load that area file and continue from step 3 with the new area. Keep one report. Record each pivot and the evidence that triggered it in the report's Alcance → Recorrido.

**No match.** If no row of the map fits, reason from the method, choose the closest skills-for-fabric skill by its description, and say so in Alcance.

## Navigation map

| Symptom or observable signal | Probable area | Area file | Cross to another area when |
|------------------------------|---------------|-----------|----------------------------|
| Notebook, job or pipeline slower every day; one run much slower | Spark runs | [references/spark-runs.md](references/spark-runs.md) | Input tables fragmented → delta-tables; low core efficiency or long start → spark-resources; many items delayed at once → capacity |
| Data skew, big shuffle, spill, a slow stage | Spark runs | [references/spark-runs.md](references/spark-runs.md) | Small files on input → delta-tables |
| Spark failure, OOM, timeout, "failed last night" | Spark runs | [references/spark-runs.md](references/spark-runs.md) | Session never got `appId` → spark-resources / capacity |
| Cluster oversized, idle executors, config per layer, cost of Spark | Spark resources | [references/spark-resources.md](references/spark-resources.md) | Waste concentrated in stages → spark-runs |
| Sessions stuck in Starting, queued, zombies | Spark resources | [references/spark-resources.md](references/spark-resources.md) | No `appId` while CU saturated → capacity |
| Table maintenance, small files, reads slower over time | Delta tables | [references/delta-tables.md](references/delta-tables.md) | Writer config causes layout → spark-resources; Direct Lake consumer → semantic-models |
| MLV refresh failed, skipped or slow | Delta tables (MLV) | [references/delta-tables.md](references/delta-tables.md) | Refresh run itself slow → spark-runs |
| Slow, expensive, failed or canceled T-SQL; regression; pool pressure | SQL endpoint / Warehouse | [references/sql-endpoint.md](references/sql-endpoint.md) | Lakehouse table layout → delta-tables; throttling → capacity |
| Model best practices, slow DAX, slow report page | Semantic models | [references/semantic-models.md](references/semantic-models.md) | Data layout signal in traces → delta-tables; fallback to DirectQuery → sql-endpoint |
| Refresh of a semantic model failed or slow | Semantic models | [references/semantic-models.md](references/semantic-models.md) | Upstream load finishes late → spark-runs |
| CU spikes, throttling, interactive delay, rejection | Capacity | [references/capacity.md](references/capacity.md) | Top consumer is Spark / SQL / model → that area |

The map is a guide, not a closed list.

## Common evidence rules

- **Telemetry header.** Every `api.fabric.microsoft.com` call carries `--headers "x-ms-fabric-skill=<skill>"`, where `<skill>` is the skills-for-fabric skill whose procedure you are following (for example `spark-cli`), including LRO polls and retries. It does not apply to OneLake, SQL/TDS or Kusto (`apm_modules/microsoft/skills-for-fabric/common/COMMON-CLI.md` § Skill Attribution Header).
- **MCP first, then REST.** Prefer `fabric-sqlendpoint` (T-SQL), `powerbi-modeling-mcp` (model metadata, DAX, traces) and FabricIQ (Capacity Metrics). Fall back to `az rest` with the audiences in `COMMON-CORE.md` § Token Audiences / Scopes per Workload: Fabric `https://api.fabric.microsoft.com`, Power BI `https://analysis.windows.net/powerbi/api`. Follow pagination (`COMMON-CORE.md` § Pagination) and back off on 429 (§ Rate Limiting & Throttling).
- **Retention.** Each source keeps data for a limited time (Spark: `spark-cli/references/operations/automated-diagnostic-workflow.md` § Data Retention Summary; Query Insights: `sqldw-cli/references/operations.md` MODE-CRITICAL NOTES block; Capacity Metrics: `capacity.md`). If the requested window is older, say the data expired; never infer it.
- **SQL endpoint MCP limits.** Row cap (a result exactly at the cap is truncated), timeout, request rate, one batch per call, only the last result set: `sqldw-cli/SKILL.md` § Execution surface — `fabric-sqlendpoint-execute_query` and `sqldw-cli/references/consumption.md` § MCP Limits. The tool does not enforce read-only; you do.
- **Livy consumes CU.** Creating a Livy session or running any statement in it (including `DESCRIBE DETAIL`) consumes capacity; idle sessions also consume it (`spark-cli/references/operations/session-health.md` § Idle and Zombie Session Detection). Ask before each one.
- **Record everything.** Each query and call gets an E# with its result, as you run it.

## Output

Write the report from [assets/informe-analisis.md](assets/informe-analisis.md), following the instructions in its leading HTML comment.
