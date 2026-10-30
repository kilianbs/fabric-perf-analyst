# Tu agente de Fabric: skills para diagnosticar Spark y modelos semánticos en vivo

Diagnosticar un Spark job lento o detectar un problema de rendimiento en un modelo semántico puede
llevar bastante tiempo entre logs, Spark UI y métricas de capacidad. Este repositorio muestra cómo
montar un agente de IA sobre Microsoft Fabric con el bundle oficial de skills de Microsoft
(skills-for-fabric) como conocimiento base y un MCP server de Fabric como capa de conectividad para
acceder a logs y metadatos en tiempo real. Con el stack montado, puedes diagnosticar un job de Spark
con cuellos de botella y analizar un modelo semántico.

Claude Code workspace for Microsoft Fabric / Power BI work. Skills and agents come from
[`microsoft/skills-for-fabric`](https://github.com/microsoft/skills-for-fabric), installed with
APM (Agent Package Manager). MCP servers are declared in `.mcp.json`.

## Quick start

1. Clone this repository and check the [requirements](#requirements).
2. Restore the `skills-for-fabric` skills: `apm install --only apm`.
3. Sign in: `az login` (or `az login --allow-no-subscriptions`).
4. Start `claude` in the repository root and check with `/mcp` that `FabricIQ`, `fabric-sqlendpoint`
   and `powerbi-modeling-mcp` are connected.
5. Build the lab workspace with planted performance problems:
   `pwsh ./demo-setup/setup.ps1 -CapacityName "<your capacity name>"` ([details](demo-setup/README.md)).
6. Ask the agent about each scenario in [`demo-setup/DEMO-SCENARIOS.md`](demo-setup/DEMO-SCENARIOS.md).
   Reports are written to `informes/`.

## What this repo adds: `FabricPerfAnalyst`

On top of the bundle, this repo adds one agent ([`.claude/agents/FabricPerfAnalyst.md`](.claude/agents/FabricPerfAnalyst.md))
and one skill ([`.claude/skills/fabric-perf-analysis/`](.claude/skills/fabric-perf-analysis/SKILL.md))
for read-only performance diagnosis. They are a thin layer: they point to the bundle's skills and
do not copy their thresholds, REST routes or procedures.

| Topic | `skills-for-fabric` bundle | Added by this repo |
|-------|----------------------------|--------------------|
| Scope | One skill per workload (`spark-cli`, `sqldw-cli`, `semantic-model-authoring`, ...). Each has its own diagnostic procedure. | One entry point for performance across Spark runs, Spark resources and sessions, Delta tables and MLVs, the SQL endpoint and Warehouse, semantic models, and capacity. |
| Agents | `FabricAdmin`, `FabricDataEngineer`, `FabricAppDev`, ... These manage and build things. | `FabricPerfAnalyst` only diagnoses. Administration stays with `FabricAdmin`. |
| Routing | You need to know which skill and which reference to open. | A map from symptom to area (for example "slower every day", OOM, throttling, slow DAX). The agent switches area when the evidence points elsewhere, for example from a slow pipeline to a fragmented table. |
| Writes | Some workflows apply changes themselves: DAX "Auto-apply", the fix phase of Analyze Best Practices, `copyEventLog`, session cleanup. | Never changes items, data or definitions: every change becomes a recommendation marked "Requiere confirmación". Two diagnostic executions run only after the user confirms them: read-only Livy statements such as `DESCRIBE DETAIL` (they consume CU) and clearing the VertiPaq cache for cold DAX benchmarks (it affects every user of the model). The agent pauses with a "Solicitud de confirmación", the main session relays it, and resumes the same agent with the answer. |
| Known traps | Spread across the references. Some contradict each other: the V-Order key, optimize write in Gold, two sets of Spark thresholds, the Operation Id join, result-set caching. | Each area file lists the traps checked against the installed skill text, and which rule wins. Gaps the skills don't cover (Direct Lake fallback, cache-clear impact, Capacity Metrics retention) are checked in Microsoft Learn. |
| Evidence | Each skill has its own reporting rules. | Common rules: every figure comes from a logged query or call, every threshold cites the reference it comes from, and data past its retention is reported as missing, not guessed. |
| Output | A free-form answer in chat. | A Spanish report from a fixed template ([`assets/informe-analisis.md`](.claude/skills/fabric-perf-analysis/assets/informe-analisis.md)). Every finding, recommendation and ruled-out hypothesis links to its evidence. Reports are saved in `informes/<date>/`, one folder per analysis day, and never overwritten. |

Because the skill only points to the bundle, updates from `apm install` reach the agent
automatically. When the bundle and this skill disagree, the bundle wins, and the report notes the
discrepancy.

The prompt used to generate the agent and the skill is in
[`prompts/crear-fabricperfanalyst.md`](prompts/crear-fabricperfanalyst.md).

## Requirements

| Tool | Purpose | Version used |
|------|---------|--------------|
| [Claude Code](https://claude.com/claude-code) | Agent host | 2.1.312 |
| [APM](https://github.com/microsoft/apm) | Installs the skills from `apm.yml` | 0.35.0 |
| [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) | Gets Entra ID tokens for the FabricIQ MCP | 2.91.0 |
| Node.js + `npx` | Runs `@microsoft/powerbi-modeling-mcp` | Node 24.14.0, npx 11.11.0 |
| Git | Required by APM to resolve GitHub packages | 2.55.0 |
| Python | Used by some Fabric skills | 3.13.3 |

You also need a Microsoft Entra account with access to a Fabric workspace.

### Authentication

- Sign in with `az login`. If the account's tenant has no Azure subscription (common for
  Fabric-only tenants), use `az login --allow-no-subscriptions`.
- Tokens are requested per audience; a wrong audience returns 401:

  | Target | Audience |
  |--------|----------|
  | Fabric REST API and FabricIQ MCP | `https://api.fabric.microsoft.com` |
  | Power BI REST API and XMLA | `https://analysis.windows.net/powerbi/api` |
  | SQL endpoint / Warehouse (TDS) | `https://database.windows.net` (handled by the `fabric-sqlendpoint` MCP) |

### Capacity

- The workspace must be on a Fabric capacity (F SKU or Fabric trial). Semantic model analysis
  through XMLA needs an F SKU or Power BI Premium P1 or higher; Pro and PPU workspaces are not enough.
- The capacity's **XMLA Endpoint** setting must be **Read Write** (Admin portal > Capacity settings >
  Power BI workloads). Only a capacity admin can change it, and it applies to every workspace on
  the capacity.
- FabricIQ needs a tenant whose home region supports all Fabric workloads.

### Tenant settings and user permissions

What each area of the `FabricPerfAnalyst` agent needs. A missing permission does not stop the
analysis: the agent reports it in the Notes section of the report.

| Area | Requirement |
|------|-------------|
| Spark runs and Spark resources | Read access to the notebook, Spark Job Definition, pipeline or lakehouse (workspace Viewer or higher) |
| Delta tables | `VIEW DEFINITION` on the lakehouse SQL endpoint (table health); workspace Contributor or higher for materialized lake view run history |
| SQL endpoint / Warehouse | Workspace Contributor or higher to read `queryinsights` |
| Semantic models | Build permission on the model for `INFO.VIEW.*` and DAX queries; Write permission for full metadata through `powerbi-modeling-mcp`. Tenant settings: *Allow XMLA endpoints and Analyze in Excel with on-premises semantic models* and *Export data* |
| Capacity | Access to the workspace where the Capacity Metrics app is installed; FabricIQ consent for `Item.Read.All` and `Item.Execute.All` (users can consent unless the tenant admin restricts it) |

### Capacity Metrics app

- Installing it requires being a **capacity admin** and having a Power BI license (Pro, PPU or a
  Power BI individual trial).
- Install it in a workspace with a Pro license, so the app itself is not throttled when the
  capacity is overloaded.
- The app keeps about 14 days of history. Older spikes cannot be analyzed.

### Known limitation

- The local `powerbi-modeling-mcp` server does not support macOS. On a Mac, use the hosted Power BI
  Authoring MCP server instead.

### Quick check

```bash
az account show                                                   # Signed-in account and tenant
az rest --method get --resource https://api.fabric.microsoft.com \
  --url https://api.fabric.microsoft.com/v1/workspaces             # Fabric API reachable, token valid
node --version                                                    # Node.js for npx
apm install --only apm                                            # skills-for-fabric skills restored
```

Then, inside Claude Code, run `/mcp` and check that `FabricIQ`, `fabric-sqlendpoint` and
`powerbi-modeling-mcp` are connected.

## Setup

```bash
# 1. Install the skills-for-fabric skills pinned in apm.yml / apm.lock.yaml
apm install --only apm

# 2. Sign in to Azure (used by the FabricIQ MCP token helper)
az login

# 3. Start Claude Code in this folder and approve the project MCP servers
claude
```

`apm install --only apm` deploys the `skills-for-fabric` skills to `.claude/skills/` at the commit
pinned in `apm.lock.yaml`. Those skills and `apm_modules/` are git-ignored; the only versioned skill
is `fabric-perf-analysis`.

- **Why `--only apm`:** `.mcp.json` is versioned with the `headersHelper` that `FabricIQ` needs (see
  [below](#why-fabriciq-uses-headershelper)). A plain `apm install` also tries to write the
  package's MCP servers into `.mcp.json`, stops on the `FabricIQ` conflict and leaves the install
  incomplete.
- **Agents:** the `skills-for-fabric` package is a skill bundle, so APM does not deploy its agents.
  `FabricAdmin`, `FabricAppDev`, `FabricDataEngineer`, `FabricIQ` and `FabricMigrationEngineer` in
  `.claude/agents/` are unmodified copies of its `agents/*.agent.md` (MIT license), versioned here.
  `FabricPerfAnalyst` is this repository's own agent.

## MCP servers (`.mcp.json`)

| Server | Type | Auth |
|--------|------|------|
| `FabricIQ` | HTTP | Bearer token from `az account get-access-token` via `headersHelper` |
| `fabric-sqlendpoint` | HTTP | OAuth via `/mcp` |
| `powerbi-modeling-mcp` | stdio (`npx`) | Local, no OAuth |

### Why `FabricIQ` uses `headersHelper`

FabricIQ authenticates against Microsoft Entra ID, which does not support OAuth dynamic client
registration. Claude Code's built-in OAuth flow fails with
`Incompatible auth server: does not support dynamic client registration`.
The token from `az` avoids that flow:

```bash
az account get-access-token --resource https://api.fabric.microsoft.com
```

If the token expires, run `az login` again, then `/mcp` > reconnect `FabricIQ`.

## Useful commands

```bash
claude mcp list          # Connection status of all MCP servers
apm --version            # Check the APM version
apm install --only apm   # Restore the skills and apm_modules/ from apm.lock.yaml
az account show          # Confirm which account/tenant you are signed in with
```

Inside Claude Code: `/mcp` (manage servers), `/reload-plugins` (reload plugins and skills).

## Troubleshooting

- **FabricIQ fails with a dynamic client registration error**: make sure `headersHelper` is set
  in `.mcp.json` and `az login` is valid.
- **Duplicate servers**: the `fabric-skills` plugin declares the same three servers. If both the
  plugin and this `.mcp.json` are active you will see duplicates (`plugin:fabric-skills:*` and
  the project ones).
- **`fabric-sqlendpoint` config rejected** with `tools.0: expected object, received string`:
  the `tools` array is not accepted in this format by Claude Code 2.1.312.
