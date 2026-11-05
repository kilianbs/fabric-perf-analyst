# Area: Spark runs

## 1. What it covers

Individual and recurring executions of notebooks, Spark Job Definitions and the Spark activities of pipelines: duration regressions, data skew and shuffle, spill, failures and OOM.

## 2. Typical questions

- "The nightly pipeline gets slower every day."
- "This notebook has data skew / huge shuffles."
- "The job failed with OOM / Spark failed last night."
- "Which stage is the bottleneck of this run?"
- "Did it fail because of our code or because of the platform?"

## 3. Where the knowledge lives

Base path: `.claude/skills/spark-cli/references/`.

| Reference | Provides |
|-----------|----------|
| `operations.md` § Must/Prefer/Avoid, § Automated Diagnostic Workflow | Rules (baseline before regression, advice first), entry points and item-type API paths, inline thresholds summary. |
| `operations/automated-diagnostic-workflow.md` Steps 1-7, § Data Retention Summary | Full procedure from resolving the item to the report; retention of each data source. |
| `operations/pipeline-diagnosis.md` Steps P1-P6 | Pipeline run → activity runs → Spark sessions; `queryActivityRuns` fields, HC sessions, code vs infra classification. |
| `operations/job-diagnostics.md` § Failure Classification, § Job Instance History ("Detect Regressions"), § Failure Triage Workflow | Failure taxonomy (OOM, timeouts...), regression rule, log routes. |
| `operations/diagnostic-workflow.md` § Diagnostic Tiers, § Severity Thresholds, § Stage Detail Selection Logic | Tier 1 online vs Tier 2 offline, severity thresholds, which stages to fetch. |
| `operations/performance-patterns.md` § Detection Thresholds, § Anti-Patterns, § Stage and Task Analysis | Skew, spill, shuffle and small-file detection thresholds and anti-patterns. |
| `operations/spark-history-server.md` | Tier 2 local Spark History Server (only after the user approves the event-log copy). |
| `operations/jobinsight-api.md` § LogUtils.copyEventLog, § Requirements | The event-log copy write and its permissions. |
| `apm_modules/microsoft/skills-for-fabric/common/SPARK-MONITORING-CORE.md` | Monitoring REST routes (sessions, advice, jobs, stages, logs, resource usage), § Permissions, § Interpreting Resource Usage. |
| `.claude/skills/sqldw-cli/references/consumption.md` | Only when a Spark result is checked through the SQL endpoint. |

## 4. Signals to measure

| Signal | How to get it | Threshold / interpretation |
|--------|---------------|----------------------------|
| Duration of last run vs previous successful runs | Job instances of the item | `job-diagnostics.md` § Job Instance History |
| Spark Advisor findings | Advice route in `SPARK-MONITORING-CORE.md` | Severity as returned; map with `diagnostic-workflow.md` § Severity Thresholds |
| Stage duration, shuffle read/write, spill, task-time quantiles (skew) | Jobs/stages routes, `taskSummary` | `performance-patterns.md` § Detection Thresholds |
| Failure reason, error class, traceback cell | Job instance `failureReason`, driver logs, activity output | `job-diagnostics.md` § Failure Classification |
| Queue / start delay | Livy session of the activity (`sessionId` from `queryActivityRuns`): `queuedDuration`, plus the submission time of its first job (`/jobs`) against `activityRunStart` | See trap "Queue time"; field meanings in `pipeline-diagnosis.md` Steps P2-P4 |

## 5. Known traps

- **Regression needs a baseline.** Compare the last successful run against previous successful runs as `job-diagnostics.md` § Detect Regressions defines (count of runs and ratio), and check data volume and config drift before blaming code. One slow run is not a trend.
- **Queue time.** The skill defines the fields but no formula. `runStartTime` ("actual Spark execution start", `pipeline-diagnosis.md` Step P4) is when the notebook run starts, not the Spark application, so activity start minus `runStartTime` misses the Livy queue and the time to the first job. Report the start delay as the session's `queuedDuration` (Livy session of the activity) and the time from `activityRunStart` to the first job's submission; both grow on custom pools (minutes) and are near zero on a warm starter pool. Never use the activity duration as Spark duration.
- **Runtime and config of the activity's own session.** Read runtime version, pool and startup properties from the Livy session of the activity being analyzed (its `sessionId`), not from the first session in the workspace list, which can be a diagnostic or interactive session with workspace defaults.
- **Trends from jobs/instances.** Stages, advice and logs live minutes to hours and `queryActivityRuns` about one hour; job instances live days (`automated-diagnostic-workflow.md` § Data Retention Summary). Build trends from job instances; for older runs say the detail expired. `pipeline-diagnosis.md` Step P2 claims `queryActivityRuns` has the longest retention: contradicts the retention table, record it in Notes.
- **Advice before stages.** Call `/advice` first; then fetch stages per `diagnostic-workflow.md` § Stage Detail Selection Logic (Advisor-named stages first, then slowest/shuffle/spill tops, capped). Do not dump all stages.
- **Tier 2 is a write.** The offline path needs `copyEventLog`, which writes to OneLake (overwrite by default) and needs Contributor on the target (`jobinsight-api.md` § Requirements). Propose it; never run it. Escalation triggers are in `diagnostic-workflow.md` § Diagnostic Tiers.
- **Do not decode definitions.** Do not decode notebook or pipeline definitions unless the user asks (`operations.md` § Must/Prefer/Avoid; `pipeline-diagnosis.md` Step P2). A request that asks how an item reads or writes, its configuration or the root cause of its failure counts as asking: read the definition with `getDefinition` (a read) and say so in Alcance.
- **Time skew hides in small stages.** Fetch `taskSummary` also for stages with few tasks and long wall time (range-partitioned writes, for example), not only the large shuffles. Time skew = similar records per task with very different durations; check the plan for Python UDF operators (`BatchEvalPython`) in those stages.
- **Repeated stages mean recomputation.** The same input scanned in several jobs of one statement points to actions on uncached DataFrames; report it as a finding.
- **Trend, not snapshot.** For "slower every day", give shuffle read/write, jobs and files per run across the runs still retained, not only the last session.
- **Failures across the workspace.** For "it fails sometimes", inventory the failures of every pipeline in the workspace, even when one pipeline is named; analyze the named one in depth and list the rest.
- **High-concurrency sessions aggregate.** When `highConcurrencyModeStatus` shows an HC session, its metrics mix several notebooks; filter by the activity time window (`pipeline-diagnosis.md` Step P3) and lower confidence.
- **Code vs infrastructure.** All Spark jobs succeeded plus a `Cell In[N]` traceback means user code; `failureType` UserError/SystemError helps (`pipeline-diagnosis.md` Steps P4b, P6). Report the category explicitly.
- **Error-source order differs between files.** `operations.md` and `automated-diagnostic-workflow.md` Step 3 treat a non-empty job instance `failureReason` as sufficient; `pipeline-diagnosis.md` reads it last. Use `failureReason` first, then Advisor, then logs, and say which source the finding came from.
- **Empty resource usage is not healthy.** `capacityExceeded=true` in resource usage means the data is empty (`SPARK-MONITORING-CORE.md` § Resource Usage API).
- **Livy statements cost CU.** Operations files include Livy statement POSTs and keep-alives; they consume CU, so keep them within the Tier B budget and never send keep-alives (see SKILL.md § Common evidence rules).

## 6. Writes (propose only)

Re-running notebooks, jobs or pipelines; `spark.conf.set` fixes; `OPTIMIZE`, `ALTER TABLE ... SET TBLPROPERTIES`, rewriting tables; `%pip install`; `copyEventLog`; schedule changes. Read-only Livy statements are a diagnostic execution, not a write (agent § Action tiers, Tier B: run without asking, consumes CU).

## 7. Cross-area pivots

| Evidence | Go to |
|----------|-------|
| Slow scan or many small files on the input/output tables, `DESCRIBE DETAIL` growth | `delta-tables.md` |
| Low core efficiency, high idle time, long start without `appId`, oversized pool | `spark-resources.md` |
| Starts delayed across many items at the same time | `capacity.md` |
| Run is an MLV refresh | `delta-tables.md` (MLV section) |
| Downstream model refresh late or slow | `semantic-models.md` |
