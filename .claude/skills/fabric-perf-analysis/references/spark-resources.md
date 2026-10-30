# Area: Spark resources and sessions

## 1. What it covers

How Spark compute is sized and configured (pools, environments, executors, resource profiles, per-layer configuration) and the health of Livy sessions (starting, idle, zombie, waiting for capacity), including their cost.

## 2. Typical questions

- "Is our cluster oversized for these jobs?"
- "Which Spark config should each medallion layer use?"
- "Sessions stay in Starting / queue forever."
- "How much does this Spark workload cost per month?"
- "Are there idle sessions burning capacity?"

## 3. Where the knowledge lives

| Reference | Provides |
|-----------|----------|
| `.claude/skills/spark-cli/references/operations/diagnostic-workflow.md` § Severity Thresholds | Flag thresholds for core efficiency and idle time. |
| `.claude/skills/spark-cli/references/operations/performance-patterns.md` § Detection Thresholds, § Capacity and Resource Diagnostics | Same flag thresholds, throttling detection, approximate capacity sizing table. |
| `.claude/skills/spark-cli/references/operations/session-health.md` | Livy states, expected startup times, stuck-starting diagnosis, idle/zombie detection. |
| `apm_modules/microsoft/skills-for-fabric/common/SPARK-MONITORING-CORE.md` § Resource Usage API, § Interpreting Resource Usage | Resource usage route and healthy ranges. |
| `.claude/skills/spark-cli/references/authoring/resources/data-engineering-patterns.md` § Spark Session Configurations for Performance, § Runtime 2.0 Performance Features | Per-layer configs and NEE caveats (read-only use). |
| `.claude/skills/e2e-medallion-architecture/SKILL.md` § Environment Optimization, § Gold Layer — Aggregation Patterns | Per-layer configuration for medallion designs. |
| `.claude/skills/e2e-fabric-cost-estimation/SKILL.md` § Capacity Unit Reference ("Spark CU Mapping"), § Capacity SKU Tiers — Live Pricing Lookup, § Must / Prefer / Avoid | CU ↔ vCore equivalence, live pricing rules. |
| `.claude/skills/e2e-fabric-cost-estimation/resources/pricing-api-reference.md` § 1, § 3 | Retail Prices API and capacity/region discovery routes. |

## 4. Signals to measure

| Signal | How to get it | Threshold / interpretation |
|--------|---------------|----------------------------|
| `coreEfficiency`, `idleTime / duration` | Resource usage route | Flags in `diagnostic-workflow.md` § Severity Thresholds; healthy ranges in `SPARK-MONITORING-CORE.md` § Interpreting Resource Usage |
| Executor count vs allocated, dynamic allocation | Resource usage, environment / pool settings | `performance-patterns.md` § Capacity and Resource Diagnostics |
| Session state, time in `starting`, `appId` presence | Livy session list / get | `session-health.md` § Expected Startup Times, § Starting Stuck Diagnosis |
| Idle and zombie sessions | Livy sessions with last activity | `session-health.md` § Idle and Zombie Session Detection |
| Effective Spark config (resource profile, V-Order, optimize write, NEE) | Environment definition (read), run logs | Learn resource-profile tables (see traps) |
| Cost of the workload | CU-seconds × live price for the region | `e2e-fabric-cost-estimation/SKILL.md` § Must / Prefer / Avoid |

## 5. Known traps

- **Two threshold sets.** Flags (`diagnostic-workflow.md` § Severity Thresholds) and healthy ranges (`SPARK-MONITORING-CORE.md` § Interpreting Resource Usage) leave a gap between them. Values in the gap are "not flagged, not healthy": severity Baja at most, citing both references.
- **CU ↔ vCores.** Use only the equivalence in `e2e-fabric-cost-estimation/SKILL.md` § Spark CU Mapping. Cross-platform mappings in `pricing-api-reference.md` are heuristics.
- **Money only from live prices.** Any currency figure needs the Retail Prices API called live for the capacity's region (`e2e-fabric-cost-estimation/SKILL.md` § Capacity SKU Tiers — Live Pricing Lookup); region comes from `/v1/capacities`. Without that call, report CU only.
- **NEE and mid-session config.** The Native Execution Engine is not reliable when enabled with `spark.conf.set` mid-session (`data-engineering-patterns.md` § Runtime 2.0 Performance Features); recommend environment-level or first-cell configuration.
- **`readHeavyForPBI`.** Not described in spark-cli or medallion; only referenced in `semantic-model-authoring/references/dax-perf-patterns.md` § Section 6. Use Learn ([Resource profiles overview](https://learn.microsoft.com/fabric/data-engineering/resource-profiles-overview)): new workspaces default to `writeHeavy` (V-Order off); `readHeavyForPBI` enables V-Order and optimize write for Direct Lake consumers.
- **No `appId` = waiting for capacity.** A session that stays without `appId` beyond the expected startup time is waiting for capacity, not broken (`session-health.md` § Starting Stuck Diagnosis). Pivot to `capacity.md`.
- **Idle sessions consume CU** (`session-health.md` § Idle and Zombie Session Detection). Report them; deleting them is a write.
- **Contradiction: V-Order key.** `e2e-medallion-architecture/SKILL.md` uses `spark.sql.parquet.vorder.default`; `data-engineering-patterns.md` uses `spark.microsoft.delta.parquet.vorder.enabled`. Learn documents `spark.sql.parquet.vorder.default` (session), `delta.parquet.vorder.enabled` (table property) and `parquet.vorder.enabled` (writer option) ([Delta optimization and V-Order](https://learn.microsoft.com/fabric/data-engineering/delta-optimization-and-v-order)). Recommend the Learn key and record the discrepancy in Notes.
- **Contradiction: optimize write in Gold.** `e2e-medallion-architecture/SKILL.md` turns it on for Gold; `data-engineering-patterns.md` § Spark Session Configurations for Performance turns it off. Learn's `readHeavyForPBI` profile enables it ([Resource profile configurations](https://learn.microsoft.com/fabric/data-engineering/configure-resource-profile-configurations)). Decide from the Gold consumers (Direct Lake → on) and record the discrepancy.
- **The sizing table is approximate.** The SKU-to-concurrent-session table in `performance-patterns.md` § Capacity Sizing Guide is indicative; never quote it as a measured limit.

## 6. Writes (propose only)

Changing or publishing environments; pool size, node size, autoscale or dynamic allocation; resource profile; `spark.conf.set`; deleting Livy sessions the agent did not create; keep-alive statements. Creating one Livy session, running read-only statements in it and deleting it afterwards is a confirmed diagnostic, not a write (agent § Action tiers, Tier B: ask first, consumes CU).

## 7. Cross-area pivots

| Evidence | Go to |
|----------|-------|
| Inefficiency concentrated in a few stages (skew, spill) | `spark-runs.md` |
| Sessions wait without `appId`, throttling at capacity level | `capacity.md` |
| Gold tables consumed by Direct Lake, V-Order or file layout in question | `delta-tables.md`, `semantic-models.md` |
