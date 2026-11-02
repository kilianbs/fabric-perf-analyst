# Tu agente de Fabric: skills para diagnosticar Spark y modelos semánticos en vivo

Diagnosticar un Spark job lento o detectar un problema de rendimiento en un modelo semántico puede
llevar bastante tiempo entre logs, Spark UI y métricas de capacidad. Este repositorio muestra cómo
montar un agente de IA sobre Microsoft Fabric con el bundle oficial de skills de Microsoft
(skills-for-fabric) como conocimiento base y un MCP server de Fabric como capa de conectividad para
acceder a logs y metadatos en tiempo real. Con el stack montado, puedes diagnosticar un job de Spark
con cuellos de botella y analizar un modelo semántico.

Workspace for Microsoft Fabric / Power BI work with Claude Code or GitHub Copilot (VS Code and
Copilot CLI). Skills and agents come from
[`microsoft/skills-for-fabric`](https://github.com/microsoft/skills-for-fabric), installed with
APM (Agent Package Manager). MCP servers are declared in `.mcp.json`, which both hosts read. The
rules for both hosts are in [`AGENTS.md`](AGENTS.md); `CLAUDE.md` only imports it.

## Quick start

1. Clone this repository and check the [requirements](#requirements).
2. Restore the `skills-for-fabric` skills: `apm install --only apm`.
3. Sign in: `az login` (or `az login --allow-no-subscriptions`).
4. Start `claude` in the repository root and check with `/mcp` that `FabricIQ`, `fabric-sqlendpoint`
   and `powerbi-modeling-mcp` are connected. With GitHub Copilot, follow
   [VS Code + GitHub Copilot](#vs-code--github-copilot) instead.
5. Build the lab workspace with planted performance problems:
   `pwsh ./demo-setup/setup.ps1 -CapacityName "<your capacity name>"` ([details](demo-setup/README.md)).
6. Follow one of the conversations, or ask about each scenario, in
   [`demo-setup/DEMO-SCENARIOS.md`](demo-setup/DEMO-SCENARIOS.md). Reports are written to `informes/`,
   one per turn.

## What this repo adds: `FabricPerfAnalyst`

On top of the bundle, this repo adds one agent ([`.claude/agents/FabricPerfAnalyst.md`](.claude/agents/FabricPerfAnalyst.md),
with a GitHub Copilot copy in [`.github/agents/FabricPerfAnalyst.agent.md`](.github/agents/FabricPerfAnalyst.agent.md))
and one skill ([`.claude/skills/fabric-perf-analysis/`](.claude/skills/fabric-perf-analysis/SKILL.md))
for performance diagnosis that never changes items or data. They are a thin layer: they point to the bundle's skills and
do not copy their thresholds, REST routes or procedures.

| Topic | `skills-for-fabric` bundle | Added by this repo |
|-------|----------------------------|--------------------|
| Scope | One skill per workload (`spark-cli`, `sqldw-cli`, `semantic-model-authoring`, ...). Each has its own diagnostic procedure. | One entry point for performance across Spark runs, Spark resources and sessions, Delta tables and MLVs, the SQL endpoint and Warehouse, semantic models, and capacity. |
| Agents | `FabricAdmin`, `FabricDataEngineer`, `FabricAppDev`, ... These manage and build things. | `FabricPerfAnalyst` only diagnoses. Administration stays with `FabricAdmin`. |
| Routing | You need to know which skill and which reference to open. | A map from symptom to area (for example "slower every day", OOM, throttling, slow DAX). The agent switches area when the evidence points elsewhere, for example from a slow pipeline to a fragmented table. |
| Writes | Some workflows apply changes themselves: DAX "Auto-apply", the fix phase of Analyze Best Practices, `copyEventLog`, session cleanup. | Never changes items, data or definitions: every change becomes a recommendation marked "Requiere confirmación". Two diagnostic executions run on their own, without asking: read-only Livy statements such as `DESCRIBE DETAIL` (one session per analysis, deleted at the end; they consume CU) and clearing the VertiPaq cache for cold DAX benchmarks (it affects every user of the model). A hook ([`.claude/hooks/livy_readonly_guard.py`](.claude/hooks/livy_readonly_guard.py)), declared in the agent's frontmatter so it runs only inside `FabricPerfAnalyst` and never affects the main session or the bundle's agents, only lets through Livy statements on a read-only allowlist (`spark.sql` with `DESCRIBE`, `SHOW`, `EXPLAIN`, `SELECT` or `WITH`, submitted with `az rest --body @file`). |
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
| [Claude Code](https://claude.com/claude-code) | Agent host (option 1) | 2.1.312 |
| [VS Code](https://code.visualstudio.com/) + GitHub Copilot, or [Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli) | Agent host (option 2), Copilot harness | Copilot CLI 1.0.96 |
| [APM](https://github.com/microsoft/apm) | Installs the skills from `apm.yml` | 0.35.0 |
| [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) | Gets Entra ID tokens for the FabricIQ MCP | 2.91.0 |
| Node.js + `npx` | Runs `@microsoft/powerbi-modeling-mcp` | Node 24.14.0, npx 11.11.0 |
| Git | Required by APM to resolve GitHub packages | 2.55.0 |
| Python | Used by some Fabric skills and by the Livy guard hook | 3.13.3 |

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
- The Livy guard hook lives in the frontmatter of `.claude/agents/FabricPerfAnalyst.md`. Claude Code
  runs a project agent's frontmatter hooks only after you accept the workspace trust dialog for this
  folder; until then the agent still runs, without the hook. GitHub Copilot behaves the same way with
  `.github/agents/FabricPerfAnalyst.agent.md`: VS Code needs a trusted workspace, and Copilot CLI
  needs the folder in its trusted folders. `COPILOT_ALLOW_ALL=true` is not enough, because it only
  trusts repository hooks, not agent hooks.

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

| Server | Type | Auth in Claude Code | Auth in GitHub Copilot |
|--------|------|---------------------|------------------------|
| `FabricIQ` | HTTP | Bearer token from `az account get-access-token` via `headersHelper` | `Authorization: Bearer ${FABRIC_MCP_TOKEN}` header |
| `fabric-sqlendpoint` | HTTP | `headersHelper` (the entry is skipped today, see [Troubleshooting](#troubleshooting)) | `Authorization: Bearer ${FABRIC_MCP_TOKEN}` header |
| `powerbi-modeling-mcp` | stdio (`npx`) | Local, no OAuth | Local, no OAuth |

Both HTTP servers accept a token for the audience `https://api.fabric.microsoft.com`. Each one has
the static header and the `headersHelper`. Claude Code runs the helper, and its output overrides
the static header with the same name, so `FABRIC_MCP_TOKEN` doesn't affect it. Copilot ignores
`headersHelper` and uses the header with the expanded variable.

### Why `FabricIQ` uses `headersHelper`

FabricIQ authenticates against Microsoft Entra ID, which does not support OAuth dynamic client
registration. Claude Code's built-in OAuth flow fails with
`Incompatible auth server: does not support dynamic client registration`.
The token from `az` avoids that flow:

```bash
az account get-access-token --resource https://api.fabric.microsoft.com
```

If the token expires, run `az login` again, then `/mcp` > reconnect `FabricIQ`.

## VS Code + GitHub Copilot

The repository also works with the GitHub Copilot harness, which VS Code (session target
**Copilot**), the GitHub Copilot app and Copilot CLI share. What it reads:

| Piece | Where Copilot reads it from |
|-------|-----------------------------|
| Rules | `AGENTS.md` (and `CLAUDE.md`, which only imports it) |
| Skills | `.claude/skills/` (Copilot reads it natively; `apm install --only apm` as for Claude). The `--target claude,copilot` from the skills-for-fabric docs also copies them to `.agents/skills/` (git-ignored). It isn't needed: Copilot reads both folders and shows each skill once. |
| Bundle agents | `.claude/agents/` |
| `FabricPerfAnalyst` | `.github/agents/FabricPerfAnalyst.agent.md`, which wins over the `.claude/` copy with the same name |
| MCP servers | `.mcp.json` |

### Livy guard in VS Code

The Copilot copy of `FabricPerfAnalyst` declares the same hook in its frontmatter:
`python .claude/hooks/livy_readonly_guard.py --format copilot`. There is still only one script: in
agent-scoped hooks, paths resolve from the repository root, so the hook doesn't need copying to
`.github/`. Don't put it in `.github/hooks/`, because Copilot treats any `*.json` there as a hook for
the whole repository.

| VS Code session target | What the hook receives | How it blocks | Verified |
|------------------------|------------------------|---------------|----------|
| **Copilot** (same harness as Copilot CLI) | `tool_name` `Bash` (`powershell` and `bash` tools), `write_powershell`, `write_bash` | top-level `permissionDecision: "deny"` | Yes: a VS Code session and `copilot --agent FabricPerfAnalyst` |
| **Local** (legacy) | `tool_name` `run_in_terminal`, `send_to_terminal` | `hookSpecificOutput.permissionDecision: "deny"` | Only with test payloads; needs `chat.useHooks` |

With `--format copilot` the hook prints a single JSON object with both decisions and exits 0, so
the block reason reaches the model in either session target. Without `--format copilot`, or with
Claude's `$CLAUDE_PROJECT_DIR`, the hook fails in Copilot and Copilot denies every shell command for
the agent with "hook errored". Use the **Copilot** session target: in **Local**, VS Code also sees
the `.claude/agents/` copy, whose hook uses `$CLAUDE_PROJECT_DIR`.

### Start

1. `apm install --only apm` and `az login`, as for Claude Code.
2. Close **every** VS Code window. A new `code` reuses the running process and does not inherit
   the variable. Then, from the same terminal:

   ```powershell
   $env:FABRIC_MCP_TOKEN = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
   code .
   ```

   ```bash
   export FABRIC_MCP_TOKEN=$(az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
   code .
   ```

   With Copilot CLI, set the same variable and run `copilot` instead of `code .`.
3. Trust the folder when VS Code or Copilot CLI asks. Without trust, the agent runs without the
   Livy guard.
4. In the Chat view, choose **Copilot** as the session target. Check in **Chat: Open
   Customizations** > **MCP Servers** that `FabricIQ`, `fabric-sqlendpoint` and
   `powerbi-modeling-mcp` are connected; in Copilot CLI, `/mcp`.
5. Ask for the analysis in the chat. The main session delegates it to `FabricPerfAnalyst`, as in
   Claude Code, or you can pick the agent in the agents dropdown (in Copilot CLI,
   `/agent FabricPerfAnalyst` or `copilot --agent FabricPerfAnalyst`).

The token lasts about an hour. When it expires, `FabricIQ` and `fabric-sqlendpoint` return 401:
repeat step 2.

### Limitations

- `FABRIC_MCP_TOKEN` is a bearer token in the environment of VS Code or the CLI and their child
  processes. Don't put it in any file or commit it.
- If the variable is missing, Copilot sends `Bearer ` with no token, the servers return 401, and
  Copilot tries browser OAuth, which fails because Entra has no dynamic client registration. The
  agent records it under Notas as a missing MCP.
- An alternative not tested in this repository: VS Code's built-in Microsoft authentication for
  MCP servers declared in `.vscode/mcp.json`. It would need other server names so they don't clash
  with `.mcp.json`.
- The Claude-only `.claude/settings.local.json` deny rule from
  [DEMO-SCENARIOS.md](demo-setup/DEMO-SCENARIOS.md#before-you-run-the-agent) has no equivalent here:
  move `demo-setup/` out of the repository.

## Useful commands

```bash
claude mcp list          # Connection status of all MCP servers (Claude Code)
copilot mcp list         # MCP servers configured for the Copilot harness
apm --version            # Check the APM version
apm install --only apm   # Restore the skills and apm_modules/ from apm.lock.yaml
az account show          # Confirm which account/tenant you are signed in with
```

Inside Claude Code: `/mcp` (manage servers), `/reload-plugins` (reload plugins and skills).
Inside Copilot CLI: `/mcp`, `/agent`, `/skills`.

## Troubleshooting

- **FabricIQ fails with a dynamic client registration error**: make sure `headersHelper` is set
  in `.mcp.json` and `az login` is valid.
- **Copilot: `FabricIQ` or `fabric-sqlendpoint` asks for browser OAuth or doesn't connect**:
  `FABRIC_MCP_TOKEN` is missing or expired in the VS Code or CLI process. Repeat step 2 of
  [Start](#start).
- **Copilot: every shell command of `FabricPerfAnalyst` is denied with "hook errored"**: the hook
  is running without `--format copilot` or can't find `python`. Check the frontmatter of
  `.github/agents/FabricPerfAnalyst.agent.md`.
- **Copilot: the hook doesn't fire** (a Livy write is not blocked): the folder isn't trusted
  (VS Code: Workspace Trust; Copilot CLI: `trustedFolders`). In Copilot CLI the debug log shows
  `agent hooks deferred until their workspace is trusted`. In the VS Code **Local** session target,
  also check `chat.useHooks`.
- **Duplicate servers**: the `fabric-skills` plugin declares the same three servers. If both the
  plugin and this `.mcp.json` are active you will see duplicates (`plugin:fabric-skills:*` and
  the project ones).
- **`fabric-sqlendpoint` config rejected** with `tools.0: expected object, received string`:
  the `tools` array is not accepted in this format by Claude Code 2.1.312.
