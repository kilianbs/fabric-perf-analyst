# Tu agente de Fabric: skills para diagnosticar Spark y modelos semánticos en vivo

Un agente de IA para diagnosticar el rendimiento de Microsoft Fabric (Spark, tablas Delta, SQL
endpoint/Warehouse, modelos semánticos y capacidad) desde Claude Code o GitHub Copilot (VS Code y
Copilot CLI). Usa el bundle oficial
[`microsoft/skills-for-fabric`](https://github.com/microsoft/skills-for-fabric), instalado con APM,
como conocimiento base y los MCP servers de Fabric de `.mcp.json` para acceder a datos en vivo. Las
reglas para los dos hosts están en [`AGENTS.md`](AGENTS.md).

## Qué añade este repositorio

- **Agente `FabricPerfAnalyst`** ([Claude](.claude/agents/FabricPerfAnalyst.md),
  [Copilot](.github/agents/FabricPerfAnalyst.agent.md)): un único punto de entrada para el
  rendimiento. Solo diagnostica; la administración sigue en `FabricAdmin`.
- **Skill [`fabric-perf-analysis`](.claude/skills/fabric-perf-analysis/SKILL.md)**: mapa de síntoma
  a área y trampas conocidas de las skills del bundle. Apunta al bundle sin copiarlo; si no
  coinciden, prevalece el bundle.
- **Sin cambios en Fabric**: cada cambio queda como recomendación. Solo lanza por su cuenta
  ejecuciones de diagnóstico (sentencias Livy de solo lectura y vaciado de caché VertiPaq para medir
  DAX en frío). El hook [`livy_readonly_guard.py`](.claude/hooks/livy_readonly_guard.py), declarado
  solo en el agente, bloquea cualquier sentencia Livy fuera de una lista blanca de lectura.
- **Informes en español** con una [plantilla fija](.claude/skills/fabric-perf-analysis/assets/informe-analisis.md),
  en `informes/AAAA-MM-DD/`. Cada cifra enlaza con la consulta de la que sale.

El prompt con el que se generaron está en [`prompts/crear-fabricperfanalyst.md`](prompts/crear-fabricperfanalyst.md).

## Requisitos

| Herramienta | Versión usada |
|-------------|---------------|
| [Claude Code](https://claude.com/claude-code) o [VS Code](https://code.visualstudio.com/) + GitHub Copilot / [Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli) | 2.1.312 / Copilot CLI 1.0.96 |
| [APM](https://github.com/microsoft/apm) | 0.35.0 |
| [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) | 2.91.0 |
| Node.js + `npx` (para `powerbi-modeling-mcp`) | Node 24.14.0 |
| Git, Python (hook y algunas skills) | 2.55.0, 3.13.3 |

En Fabric:

- Una cuenta de Entra con acceso a un workspace en una capacidad F (o trial). Para analizar modelos
  por XMLA, SKU F o P1+, con **XMLA Endpoint** en **Read Write** en la capacidad.
- Permisos por área (si falta alguno, el agente lo anota en el informe y sigue):

  | Área | Permiso |
  |------|---------|
  | Spark | Viewer del workspace |
  | Tablas Delta | `VIEW DEFINITION` en el SQL endpoint; Contributor para el historial de MLV |
  | SQL endpoint / Warehouse | Contributor (para `queryinsights`) |
  | Modelos semánticos | Build (Write para metadatos completos); ajustes de tenant *Allow XMLA endpoints* y *Export data* |
  | Capacidad | Acceso a la app Capacity Metrics (la instala un admin de la capacidad; guarda ~14 días) |

## Instalación

```bash
# 1. Skills de skills-for-fabric (para Claude y Copilot, según los targets de apm.yml)
apm install --only apm

# 2. Agentes del bundle: APM no los despliega, hay que copiarlos (Claude y Copilot)
for f in apm_modules/microsoft/skills-for-fabric/agents/*.agent.md; do
  cp "$f" ".claude/agents/$(basename "$f" .agent.md).md"
  cp "$f" .github/agents/
done

# 3. Inicio de sesión (si el tenant no tiene suscripción: --allow-no-subscriptions)
az login
```

En PowerShell, el paso 2 es:

```powershell
Get-ChildItem apm_modules/microsoft/skills-for-fabric/agents/*.agent.md | ForEach-Object {
  Copy-Item $_ ".claude/agents/$($_.Name -replace '\.agent\.md$', '.md')"
  Copy-Item $_ .github/agents/
}
```

- Usa `--only apm`: un `apm install` sin más intenta reescribir los MCP servers de `.mcp.json`, choca
  con la configuración de `FabricIQ` y deja la instalación a medias.
- Las skills instaladas y `apm_modules/` están en el `.gitignore`; la única skill versionada es
  `fabric-perf-analysis`.

Después, arranca el host:

- **Claude Code**: `claude` en la raíz, acepta la confianza de la carpeta y comprueba con `/mcp` que
  `FabricIQ`, `fabric-sqlendpoint` y `powerbi-modeling-mcp` están conectados.
- **GitHub Copilot**: ver [VS Code + GitHub Copilot](#vs-code--github-copilot).

Para probarlo, crea el workspace de laboratorio
(`pwsh ./demo-setup/setup.ps1 -CapacityName "<capacidad>"`, [detalles](demo-setup/README.md)) y sigue
los escenarios de [`DEMO-SCENARIOS.md`](demo-setup/DEMO-SCENARIOS.md).

## MCP servers

| Servidor | Tipo | Claude Code | GitHub Copilot |
|----------|------|-------------|----------------|
| `FabricIQ` | HTTP | `headersHelper` con `az account get-access-token` | `Authorization: Bearer ${FABRIC_MCP_TOKEN}` |
| `fabric-sqlendpoint` | HTTP | `headersHelper` | `Authorization: Bearer ${FABRIC_MCP_TOKEN}` |
| `powerbi-modeling-mcp` | stdio (`npx`) | Local | Local |

Entra ID no admite el registro dinámico de clientes de OAuth, así que el token se obtiene de `az`
(audiencia `https://api.fabric.microsoft.com`). Si caduca: `az login` y reconecta en `/mcp`.

## VS Code + GitHub Copilot

Copilot lee `AGENTS.md`, las skills instaladas, los agentes de `.github/agents/` y `.mcp.json`. Su
copia de `FabricPerfAnalyst` es `.github/agents/FabricPerfAnalyst.agent.md`, cuyo hook lleva
`--format copilot`.

1. Haz la [instalación](#instalación).
2. Cierra **todas** las ventanas de VS Code y, desde el mismo terminal:

   ```powershell
   $env:FABRIC_MCP_TOKEN = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
   code .   # o: copilot
   ```

   El token dura ~1 hora; cuando los servidores HTTP devuelvan 401, repite este paso. No lo guardes
   en ningún fichero.
3. Da confianza a la carpeta; sin ella el agente funciona pero sin la guarda de Livy.
4. En Chat, elige el session target **Copilot** (en **Local** el hook falla) y comprueba los MCP en
   **Chat: Open Customizations** > **MCP Servers** (`/mcp` en Copilot CLI).
5. Pide el análisis, o elige `FabricPerfAnalyst` en el desplegable (`/agent FabricPerfAnalyst` en la CLI).

## Solución de problemas

- **FabricIQ: error de registro dinámico de clientes**: falta el `headersHelper` en `.mcp.json` o ha
  caducado `az login`.
- **Copilot pide OAuth por navegador o recibe 401**: `FABRIC_MCP_TOKEN` falta o ha caducado.
- **Copilot deniega todos los comandos con "hook errored"**: el hook corre sin `--format copilot`, en
  el session target **Local**, o no encuentra `python`.
- **El hook no se dispara**: la carpeta no es de confianza (Workspace Trust en VS Code,
  `trustedFolders` en Copilot CLI, diálogo de confianza en Claude Code).
- **Servidores duplicados**: el plugin `fabric-skills` declara los mismos tres; desactívalo o ignora
  los `plugin:fabric-skills:*`.
- **macOS**: `powerbi-modeling-mcp` local no funciona; usa el MCP alojado de Power BI Authoring.
