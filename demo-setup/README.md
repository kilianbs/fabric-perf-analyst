# demo-setup: FabricPerfLab workspace

Scripts that build a Fabric workspace to analyze with the `FabricPerfAnalyst` agent: a medallion
lakehouse with Spark pipelines, Delta tables and an Import semantic model. Each item carries known
performance problems, and the script runs the pipelines several times so there is history to
analyze. The demo conversations and what each scenario expects to find are in [DEMO-SCENARIOS.md](DEMO-SCENARIOS.md) (keep it
away from the agent while it analyzes).

## Quick path

```powershell
az login                                   # or: az login --allow-no-subscriptions
pwsh ./demo-setup/setup.ps1 -CapacityName "<your capacity name>"
```

1. **Deploy** (about 5 minutes): creates the workspace and every item.
2. **Manual step**: the script stops and asks you to set the model credentials ([below](#manual-step-model-credentials)).
3. **History** (hours, see [Timing](#timing-and-cost)): runs the daily pipeline once per simulated day, then the failing export twice.
4. **Schedule**: daily pipeline at 06:00 and model refresh at 05:30 and 06:30.

The History phase takes hours: run it before you start analyzing. The schedules then add real daily runs on top.

### Or ask the agent to do it

Open Claude Code, or a GitHub Copilot chat in VS Code, at the repository root and say, for example:

> Ejecuta `demo-setup/setup.ps1 -CapacityName "<capacidad>" -Phase Deploy -NonInteractive`. Confirmo
> que puede crear el workspace FabricPerfLab y sus artefactos. Cuando termine, dime qué paso manual
> me queda y después lanza `-Phase History -NonInteractive` en segundo plano.

The repository's [AGENTS.md](../AGENTS.md) forbids writes to Fabric without explicit confirmation,
so the prompt must confirm the operation. `-NonInteractive` skips the "press Enter" pause; do the
[manual step](#manual-step-model-credentials) before the History phase starts, or the model
refreshes in the history fail with a credentials error.

## What gets created

| Item | Name | Role in the scenarios |
|------|------|-------------------|
| Workspace | `FabricPerfLab` | Container, on your capacity |
| Lakehouse | `lh_bronze`, `lh_silver`, `lh_gold` | Medallion layers (no schemas, tables under `dbo`) |
| Spark pool | `pool_gold_xl` | Custom pool used by the gold environment |
| Environment | `env_bronze`, `env_silver`, `env_gold` | Spark settings per layer |
| Notebook | `nb_01_ingest_bronze` | Generates one business day of synthetic data |
| Notebook | `nb_02_bronze_to_silver` | Deduplication, joins, customer MERGE |
| Notebook | `nb_03_silver_to_gold` | Star schema for the model |
| Notebook | `nb_04_refresh_model` | Requests the model refresh |
| Notebook | `nb_05_store_snapshot` | Per-store export (fails on purpose) |
| Pipeline | `pl_daily_sales` | nb_01 → nb_02 → nb_03 → nb_04 |
| Pipeline | `pl_store_snapshot` | nb_05 with parameter `export_format` |
| Semantic model | `sm_sales` | Import model over the `lh_gold` SQL endpoint |

Local files: [`items/`](items/) holds every definition (readable Python, JSON, YAML and TMDL), and
[`dax/report-queries.dax`](dax/report-queries.dax) holds the queries of a typical report page. The
script writes item IDs and a run log to `demo-setup/.state/` (git-ignored).

## Prerequisites

Everything in the root [README.md](../README.md#requirements), plus:

| Requirement | Why |
|-------------|-----|
| PowerShell 7.2+ (`pwsh`) | The scripts use PowerShell 7 syntax. Windows PowerShell 5.1 does not work. |
| Fabric capacity, **trial F64 recommended** | Spark sessions, a Large-node pool and an Import model of several million rows. On a small capacity use `-GoldPoolNodeSize Medium -GoldPoolMaxNodes 3`. |
| Permission to create workspaces and assign them to the capacity | Tenant setting for workspace creation, and Contributor (or admin) on the capacity. |
| Workspace setting *Customize compute configurations for items* enabled | Needed for the custom pool and environments. It is on by default. |
| Capacity setting **XMLA endpoint: Read Write** | Only for the semantic model scenarios (see the root README). |

## Manual step: model credentials

`sm_sales` is an Import model, so Power BI needs credentials for the `lh_gold` SQL endpoint, and
the API cannot set an OAuth2 sign-in for you. Once, after Deploy:

1. Open the URL the script prints (`app.powerbi.com/groups/<ws>/settings/datasets/<model>`).
2. **Data source credentials** → **Edit credentials** → Authentication method **OAuth2** → **Sign in**.

Then run `-Phase Schedule` again if it warned that the refresh schedule was not enabled.

## Phases and parameters

Each phase can run alone with `-Phase Deploy|History|Schedule`. Deploy is idempotent: it matches
items by name and updates their definitions, so it is safe to re-run after editing `items/`.

| Parameter | Default | Effect |
|-----------|---------|--------|
| `-WorkspaceName` | `FabricPerfLab` | Workspace to create or reuse |
| `-CapacityName` / `-CapacityId` | none | Needed only when the workspace does not exist yet |
| `-SimulatedDays` | `10` | Pipeline runs in the History phase (one business day each) |
| `-RowsPerDay` | `1000000` | Sales rows generated per run |
| `-GoldPoolNodeSize` / `-GoldPoolMaxNodes` | `Large` / `4` | Size of `pool_gold_xl` (gold uses max nodes − 1 fixed executors) |
| `-PipelineTime` | `06:00` | Daily schedule of `pl_daily_sales` |
| `-ModelRefreshTimes` | `05:30`, `06:30` | Model refresh schedule (Power BI only accepts :00 and :30) |
| `-TimeZoneId` | `Romance Standard Time` | Windows time zone ID for both schedules |
| `-ScheduleDays` | `30` | When the pipeline schedule ends |
| `-SkipSnapshotFailures` | off | Skips the two failing `pl_store_snapshot` runs |
| `-NonInteractive` | off | No pauses; for the agent or CI |

Re-running History adds more days: the day counter lives in `lh_bronze.ctl_pipeline_runs`.

## Timing and cost

Not measured yet: the durations below are estimates, check them on your capacity.

| Phase | Estimate | Note |
|-------|----------|------|
| Deploy | 5–10 min | Waits for the SQL endpoint and the environment publishes |
| History | several hours for 10 days | Each run is slower than the previous one (that is the demo) |
| Schedule | under 1 min | Then one pipeline run and two model refreshes per day |

The History phase consumes Spark CU for its whole duration, and the schedules keep consuming
every day. When you are done, stop them (next section).

## Check before analyzing

- [ ] `demo-setup/.state/FabricPerfLab-history.csv` lists the runs; run 6 shows `Failed`.
- [ ] `pl_store_snapshot` shows two failed runs in the Monitor hub.
- [ ] `sm_sales` refresh history shows successes and failures (runs 4 and 8).
- [ ] `FabricIQ`, `fabric-sqlendpoint` and `powerbi-modeling-mcp` are connected: `/mcp` in Claude Code; in VS Code with GitHub Copilot, **Chat: Open Customizations** > **MCP Servers** (or `copilot mcp list` and `/mcp` in Copilot CLI), with `FABRIC_MCP_TOKEN` set ([README](../README.md#vs-code--github-copilot)).
- [ ] The agent cannot read `demo-setup/` (see [DEMO-SCENARIOS.md](DEMO-SCENARIOS.md#before-you-run-the-agent)).

## Stop or remove

```powershell
pwsh ./demo-setup/teardown.ps1 -DisableSchedules   # keep everything, stop daily runs
pwsh ./demo-setup/teardown.ps1                     # delete the workspace (asks you to type its name)
```

## Troubleshooting

| Symptom | Likely cause and fix |
|---------|----------------------|
| `Not signed in` / HTTP 401 | Run `az login` again; with no Azure subscription, `az login --allow-no-subscriptions`. |
| `Capacity '...' not found` | The name must match the capacity display name exactly, or pass `-CapacityId`. The capacity must be active. |
| Pool creation fails with a node size error | The capacity is too small for Large nodes: `-GoldPoolNodeSize Medium -GoldPoolMaxNodes 3`. |
| Environment publish fails | Open the environment in the portal: the error is shown there. With `instance_pool_id: null`, bronze and silver use the starter pool. |
| Every model refresh fails with a credentials error | The manual step was skipped. |
| `nb_05` "nested" export succeeds | Not enough data in the hot store yet; run more History days or raise `-RowsPerDay`. |
