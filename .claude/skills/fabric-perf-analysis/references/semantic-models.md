# Area: semantic models

## 1. What it covers

Power BI semantic models in Fabric workspaces: modeling best practices, DAX query performance, Direct Lake behavior, and refresh failures or slow refreshes.

## 2. Typical questions

- "Review this model against best practices."
- "This DAX measure / report page is slow."
- "The page X of report Y is slow" (no DAX given: rebuild the visual queries from the report, see § 4).
- "The refresh of the model failed / takes longer every day."
- "Is the Direct Lake model falling back to DirectQuery?"
- "Why does the report get slower after each load of the Gold layer?"

## 3. Where the knowledge lives

Base path: `.claude/skills/semantic-model-authoring/`.

| Reference | Provides |
|-----------|----------|
| `SKILL.md` § Workflow: Analyze Best Practices | Procedure. Steps 1-4 are diagnosis; step 4 "Present findings" groups them as critical / recommended / optional. Steps 5-6 are the fix phase. |
| `SKILL.md` § Workflow: Optimize DAX Performance | Entry point; delegates to the decision guide. |
| `SKILL.md` § Workflow: Discover Semantic Model Metadata | Discovery order and the Write vs Build permission split. |
| `SKILL.md` § Workflow: Refresh Semantic Model, § TROUBLESHOOTING | Refresh procedure, stop rules for credential errors, meaning of 401/403. |
| `references/dax-perf-decision-guide.md` § Tiers and Autonomy, § Phase 1: Establish Baseline, § Phase 2: Optimization Iterations | Optimization tiers, measurement protocol (warm-up, measured runs, dispersion rule, noise band), semantic-equivalence check. |
| `references/dax-perf-decision-guide.md` § Trace Capture Methods, § Section 2: Reading and Diagnosing Traces | Trace sources and the trace metrics table with its interpretation. |
| `references/dax-perf-decision-guide.md` § DAX vs. Data Layout: Reading the Signal, § Sections 4–6 — Escalation Triggers | Routing: when the problem is DAX, query structure, model, or Direct Lake data layout. |
| `references/dax-perf-patterns.md` § Section 3 to § Section 6 | Pattern catalog (DAX0xx, Tier 2/3, Direct Lake DL0xx). |
| `references/metadata-discovery.md` § Scope Estimation Queries, § Complete INFO Function Catalog, § Troubleshooting | Read-only `INFO.*` / `INFO.VIEW.*` queries and which need elevated permissions. |
| `references/modeling-guidelines.md` | Rules the best-practice review checks, including its numeric review thresholds (§ Table Columns, § Relationships, § Performance Guidelines). |
| `references/semantic-model-rest-api.md` § Authentication & API Audiences, § Refresh Operations (Power BI Datasets API), § Refresh History Response Properties, § Execute DAX Queries (Power BI Datasets API), § Properties Retrieval | REST routes, audiences, executeQueries limits, refresh history fields. |
| `references/connection-binding.md` § Troubleshooting | Bind succeeds but refresh fails. |
| `.claude/skills/powerbi-report-cli/references/management-part-02.md` § Get Report Definition (header `x-ms-fabric-skill=powerbi-report-cli`) | Report definition download: `POST /v1/workspaces/{ws}/reports/{id}/getDefinition?format=PBIR`, LRO, required permissions. |
| `.claude/skills/powerbi-report-cli/references/authoring-part-02.md` § PBIR File Layout; `authoring/expressions.md` | Where pages and visuals live in the definition and how a field is encoded in `visual.json` (`Column`, `Measure`, `Aggregation`, `HierarchyLevel`). |

## 4. Signals to measure

| Signal | How to get it | Threshold / interpretation |
|--------|---------------|----------------------------|
| Model inventory and size (tables, columns, measures, relationships, storage mode) | `INFO.VIEW.*` via `dax_query_operations`; MCP List/Get if the user has Write | `modeling-guidelines.md` thresholds |
| Query duration, SE/FE split, SE query count, cache hits | Trace on the workspace XMLA endpoint (powerbi-modeling-mcp trace) | `dax-perf-decision-guide.md` § Section 2 |
| Queries of a report page (when the user names a report or page instead of giving DAX) | List the workspace items of type `Report`, read the definition (`getDefinition?format=PBIR`), decode the parts of the page (`page.json`, `visuals/*/visual.json`). Per visual, one query: grouping columns from `visual.query.queryState` (`Rows`, `Columns`, `Category`, `Series`, grouping fields in `Values`) and its measures (`Measure` fields, `Aggregation` as `SUM`/`AVERAGE`/... of the column) in `SUMMARIZECOLUMNS`; a card with no grouping is `ROW`. Add the report, page and visual filters (`filterConfig`) as filter arguments. Record each rebuilt query as an E# with the visual it comes from | Then measure each one with the protocol below; the slowest visuals are the first candidates |
| Baseline vs candidate timing | DAX query with measures inlined in `DEFINE`, protocol of § Phase 1 | Dispersion and noise-band rules in § Phase 1 / § Phase 2 |
| Refresh history (status, duration trend, error code) | Refresh history route in `semantic-model-rest-api.md` (Power BI audience) | Compare durations across runs; error codes per § TROUBLESHOOTING |
| Storage mode and Direct Lake flavour | Model properties / partitions | Direct Lake on SQL can fall back; Direct Lake on OneLake cannot (Learn, see traps) |

## 5. Known traps

- **Write vs Build.** MCP List/Get needs Write on the model; with Build only, use `INFO.VIEW.*` through `dax_query_operations` (`SKILL.md` § Workflow: Discover Semantic Model Metadata). Many other `INFO.*` functions need elevated permissions (`metadata-discovery.md` § Troubleshooting). A permission error is a Notes finding, not a reason to stop the whole analysis. Run the function before declaring it unavailable, and record the exact error: `INFO.STORAGETABLES`, `INFO.STORAGETABLECOLUMNS` and `INFO.STORAGETABLECOLUMNSEGMENTS` can answer with the same permissions as `INFO.VIEW.*` and are the source for per-table and per-column memory (they have no cardinality column: measure it with `DISTINCTCOUNT`).
- **Measures are tested, not changed.** Candidate measures go in the query's `DEFINE MEASURE` block; never create or edit measures in the model (`dax-perf-decision-guide.md` § Phase 1, Step 1; `dax-guidelines.md` § DEFINE Block).
- **Measurement protocol is mandatory.** Warm-up, repeated runs, dispersion rule and noise band come from `dax-perf-decision-guide.md` § Phase 1, Step 3 and § Phase 2. Do not report a single run as a speed-up.
- **Benchmark calls run in series.** Send each DAX `Execute` and each `ClearCache` as its own call and wait for its result before the next one: never in the same parallel batch, and never two `Execute` at once. A clear that overlaps a query, or two overlapping queries, invalidates those runs; if it happens, discard them, repeat them and say so in Notas › Limitaciones.
- **Cache clear affects every user.** The protocol clears the cache between runs, but the skill names no mechanism and no side effect. XMLA `ClearCache` acts on the whole database ([Learn: Clear Analysis Services caches](https://learn.microsoft.com/analysis-services/instances/clear-the-analysis-services-caches)), so it affects every user of the model. Run it as Tier B without asking, only between benchmark runs, and record each clear with its UTC time.
- **Routing DAX vs data layout.** Follow `dax-perf-decision-guide.md` § DAX vs. Data Layout and § Escalation Triggers. Direct Lake guidance for performance is in `dax-perf-patterns.md` § Section 6, not in `direct-lake-guidelines.md` (authoring only).
- **Direct Lake fallback is not in the skill.** Verify in Learn ([How Direct Lake works § DirectQuery fallback](https://learn.microsoft.com/fabric/fundamentals/direct-lake-how-it-works#directquery-fallback)): only Direct Lake on SQL falls back (controlled by `DirectLakeBehavior`); Direct Lake on OneLake does not, and a guardrail breach makes refresh fail instead. Record it in Notes as a skill/doc gap.
- **Auto-apply is overridden.** Tier 1 "Auto-apply" in `dax-perf-decision-guide.md` § Tiers and Autonomy and the banner in `dax-perf-patterns.md` § Section 3 do not apply to this agent: the workflow ends at the Phase 2 comparison. Analyze Best Practices ends at step 4 "Present findings"; steps 5-6 are never run.
- **Severity labels are not criteria.** The skill groups findings as critical / recommended / optional without defining them. Map critical → Alta, recommended → Media, optional → Baja, cite `SKILL.md` § Workflow: Analyze Best Practices, and justify each mapping with measured impact.
- **Credential errors stop the refresh line of analysis.** On a credential error in refresh history, stop that line and report it (`SKILL.md` § Workflow: Refresh Semantic Model). Do not retry, rebind or edit data sources.
- **Rebuilt visual queries are approximations.** A query rebuilt from `visual.json` has the visual's fields, measures and filters, but not what Power BI adds when it renders (data-reduction `TOPN`/windows, sort, subtotals, visual calculations, cross-filters from other visuals). State it in Notas › Limitaciones. If the user supplies a query captured with Performance Analyzer, measure that one instead. Reading the definition needs write permission on the report (`management-part-02.md` § Get Report Definition); without it, ask for the queries and record the gap in Notas.
- **Some POSTs are reads.** `getDefinition` and `executeQueries` are POST but read-only (`semantic-model-rest-api.md` § TMDL Definition CRUD, § Execute DAX Queries). Everything else that is POST, PUT, PATCH or DELETE in that file is a write.
- **"Column does not exist in the rowset".** Compare the source table's columns in each Delta version (`DESCRIBE HISTORY`, schema per version) and the writer's code with the columns the model expects, before suspecting SQL endpoint metadata sync. An intermittent error usually follows a schema that changes between runs.
- **Refreshes requested from code.** When a notebook or pipeline activity requests the refresh, read that code: whether it waits for the result and whether a failure fails the activity.
- **Orphan keys and blank members.** Trace them to the lakehouse: `DESCRIBE HISTORY` of the dimension's source (DELETE, MERGE with deletes, deletion vectors) and of the writer of the dimension.
- **Best-practice scope.** Report which table holds the measures, the calculated columns of fact tables, the data type of relationship keys and discouraged DAX patterns (`IFERROR` instead of `DIVIDE`, `FILTER` over the fact table) even when the measure is fast.
- **Broken anchors.** Some in-file anchors in the skill point to non-existent numbered headings; cite headings by text.

## 6. Writes (propose only)

Model, measure, relationship, partition or column changes; Tier 1-4 optimizations; best-practice fixes; refresh trigger, cancel or schedule change; `Default.UpdateParameters`; permission grants; `bindConnection`; `updateDefinition`; deploy. Cache clear is not in this list: it is a Tier B diagnostic execution, run without asking (see traps).

## 7. Cross-area pivots

| Evidence | Go to |
|----------|-------|
| Direct Lake: many small files / row groups, trace signal points to data layout | `delta-tables.md` |
| Refresh slow because upstream Gold notebook or pipeline finishes late | `spark-runs.md` |
| Direct Lake on SQL falling back, DirectQuery queries slow on the endpoint | `sql-endpoint.md` |
| Queries or refreshes throttled, interactive delays across many items | `capacity.md` |
| V-Order / resource profile of the writer of the Gold tables | `spark-resources.md` |
