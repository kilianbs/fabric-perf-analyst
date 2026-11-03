# Tu agente de Fabric: skills para diagnosticar Spark y modelos semánticos en vivo

Diagnosticar un Spark job lento o detectar un problema de rendimiento en un modelo semántico puede
llevar bastante tiempo entre logs, Spark UI y métricas de capacidad. Este repositorio muestra cómo
montar un agente de IA sobre Microsoft Fabric con el bundle oficial de skills de Microsoft
(skills-for-fabric) como conocimiento base y un MCP server de Fabric como capa de conectividad para
acceder a logs y metadatos en tiempo real. Con el stack montado, puedes diagnosticar un job de Spark
con cuellos de botella y analizar un modelo semántico.

Workspace para trabajar con Microsoft Fabric / Power BI desde Claude Code o GitHub Copilot (VS Code y
Copilot CLI). Las skills y los agentes vienen de
[`microsoft/skills-for-fabric`](https://github.com/microsoft/skills-for-fabric) y se instalan con
APM (Agent Package Manager). Los MCP servers se declaran en `.mcp.json`, que leen los dos hosts. Las
reglas para ambos hosts están en [`AGENTS.md`](AGENTS.md); `CLAUDE.md` solo lo importa.

## Inicio rápido

1. Clona este repositorio y revisa los [requisitos](#requisitos).
2. Restaura las skills de `skills-for-fabric`: `apm install --only apm`.
3. Inicia sesión: `az login` (o `az login --allow-no-subscriptions`).
4. Arranca `claude` en la raíz del repositorio y comprueba con `/mcp` que `FabricIQ`, `fabric-sqlendpoint`
   y `powerbi-modeling-mcp` están conectados. Con GitHub Copilot, sigue en su lugar
   [VS Code + GitHub Copilot](#vs-code--github-copilot).
5. Crea el workspace de laboratorio con problemas de rendimiento sembrados:
   `pwsh ./demo-setup/setup.ps1 -CapacityName "<nombre de tu capacidad>"` ([detalles](demo-setup/README.md)).
6. Sigue una de las conversaciones, o pregunta por cada escenario, de
   [`demo-setup/DEMO-SCENARIOS.md`](demo-setup/DEMO-SCENARIOS.md). Los informes se escriben en `informes/`,
   uno por turno.

## Qué añade este repositorio: `FabricPerfAnalyst`

Sobre el bundle, este repositorio añade un agente ([`.claude/agents/FabricPerfAnalyst.md`](.claude/agents/FabricPerfAnalyst.md),
con una copia para GitHub Copilot en [`.github/agents/FabricPerfAnalyst.agent.md`](.github/agents/FabricPerfAnalyst.agent.md))
y una skill ([`.claude/skills/fabric-perf-analysis/`](.claude/skills/fabric-perf-analysis/SKILL.md))
para diagnosticar el rendimiento sin cambiar nunca items ni datos. Son una capa fina: apuntan a las skills del bundle y
no copian sus umbrales, rutas REST ni procedimientos.

| Tema | Bundle `skills-for-fabric` | Lo que añade este repositorio |
|------|----------------------------|-------------------------------|
| Alcance | Una skill por workload (`spark-cli`, `sqldw-cli`, `semantic-model-authoring`, ...). Cada una tiene su propio procedimiento de diagnóstico. | Un único punto de entrada para el rendimiento de ejecuciones Spark, recursos y sesiones de Spark, tablas Delta y MLV, SQL endpoint y Warehouse, modelos semánticos y capacidad. |
| Agentes | `FabricAdmin`, `FabricDataEngineer`, `FabricAppDev`, ... Gestionan y construyen. | `FabricPerfAnalyst` solo diagnostica. La administración sigue en `FabricAdmin`. |
| Enrutado | Tienes que saber qué skill y qué referencia abrir. | Un mapa de síntoma a área (por ejemplo "cada día más lento", OOM, throttling, DAX lento). El agente cambia de área cuando la evidencia apunta a otro sitio, por ejemplo de un pipeline lento a una tabla fragmentada. |
| Escrituras | Algunos flujos aplican cambios por sí mismos: el "Auto-apply" de DAX, la fase de corrección de Analyze Best Practices, `copyEventLog`, la limpieza de sesiones. | Nunca cambia items, datos ni definiciones: cada cambio se convierte en una recomendación marcada "Requiere confirmación". Dos ejecuciones de diagnóstico se lanzan solas, sin preguntar: sentencias Livy de solo lectura como `DESCRIBE DETAIL` (una sesión por análisis, que se borra al final; consumen CU) y el vaciado de la caché VertiPaq para medir DAX en frío (afecta a todos los usuarios del modelo). Un hook ([`.claude/hooks/livy_readonly_guard.py`](.claude/hooks/livy_readonly_guard.py)), declarado en el frontmatter del agente para que solo corra dentro de `FabricPerfAnalyst` y nunca afecte a la sesión principal ni a los agentes del bundle, solo deja pasar sentencias Livy de una lista blanca de lectura (`spark.sql` con `DESCRIBE`, `SHOW`, `EXPLAIN`, `SELECT` o `WITH`, enviadas con `az rest --body @file`). |
| Trampas conocidas | Repartidas por las referencias. Algunas se contradicen: la clave de V-Order, optimize write en Gold, dos juegos de umbrales de Spark, el join por Operation Id, la caché de result sets. | Cada fichero de área lista las trampas, contrastadas con el texto de la skill instalada, y qué regla prevalece. Los huecos que las skills no cubren (fallback de Direct Lake, impacto del vaciado de caché, retención de Capacity Metrics) se comprueban en Microsoft Learn. |
| Evidencia | Cada skill tiene sus propias reglas para informar. | Reglas comunes: cada cifra sale de una consulta o llamada registrada, cada umbral cita la referencia de la que sale, y los datos fuera de su retención se dan como ausentes, no se suponen. |
| Salida | Una respuesta libre en el chat. | Un informe en español con una plantilla fija ([`assets/informe-analisis.md`](.claude/skills/fabric-perf-analysis/assets/informe-analisis.md)). Cada hallazgo, recomendación e hipótesis descartada enlaza con su evidencia. Los informes se guardan en `informes/<fecha>/`, una carpeta por día de análisis, y nunca se sobrescriben. |

Como la skill solo apunta al bundle, las actualizaciones de `apm install` llegan al agente
automáticamente. Cuando el bundle y esta skill no coinciden, prevalece el bundle y el informe anota
la discrepancia.

El prompt con el que se generaron el agente y la skill está en
[`prompts/crear-fabricperfanalyst.md`](prompts/crear-fabricperfanalyst.md).

## Requisitos

| Herramienta | Para qué | Versión usada |
|-------------|----------|---------------|
| [Claude Code](https://claude.com/claude-code) | Host del agente (opción 1) | 2.1.312 |
| [VS Code](https://code.visualstudio.com/) + GitHub Copilot, o [Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli) | Host del agente (opción 2), harness de Copilot | Copilot CLI 1.0.96 |
| [APM](https://github.com/microsoft/apm) | Instala las skills de `apm.yml` | 0.35.0 |
| [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) | Obtiene los tokens de Entra ID para el MCP de FabricIQ | 2.91.0 |
| Node.js + `npx` | Ejecuta `@microsoft/powerbi-modeling-mcp` | Node 24.14.0, npx 11.11.0 |
| Git | Lo necesita APM para resolver paquetes de GitHub | 2.55.0 |
| Python | Lo usan algunas skills de Fabric y el hook de guarda de Livy | 3.13.3 |

También necesitas una cuenta de Microsoft Entra con acceso a un workspace de Fabric.

### Autenticación

- Inicia sesión con `az login`. Si el tenant de la cuenta no tiene suscripción de Azure (habitual en
  tenants que solo usan Fabric), usa `az login --allow-no-subscriptions`.
- Los tokens se piden por audiencia; una audiencia equivocada devuelve 401:

  | Destino | Audiencia |
  |---------|-----------|
  | API REST de Fabric y MCP de FabricIQ | `https://api.fabric.microsoft.com` |
  | API REST de Power BI y XMLA | `https://analysis.windows.net/powerbi/api` |
  | SQL endpoint / Warehouse (TDS) | `https://database.windows.net` (lo gestiona el MCP `fabric-sqlendpoint`) |

### Capacidad

- El workspace debe estar en una capacidad de Fabric (SKU F o trial de Fabric). El análisis de modelos
  semánticos por XMLA necesita un SKU F o Power BI Premium P1 o superior; los workspaces Pro y PPU no bastan.
- El ajuste **XMLA Endpoint** de la capacidad debe estar en **Read Write** (Admin portal > Capacity settings >
  Power BI workloads). Solo un administrador de la capacidad puede cambiarlo, y se aplica a todos los
  workspaces de esa capacidad.
- FabricIQ necesita un tenant cuya región principal admita todos los workloads de Fabric.

### Ajustes del tenant y permisos del usuario

Lo que necesita cada área del agente `FabricPerfAnalyst`. Un permiso que falte no detiene el
análisis: el agente lo indica en la sección Notas del informe.

| Área | Requisito |
|------|-----------|
| Ejecuciones y recursos de Spark | Lectura sobre el notebook, Spark Job Definition, pipeline o lakehouse (Viewer del workspace o superior) |
| Tablas Delta | `VIEW DEFINITION` sobre el SQL endpoint del lakehouse (salud de las tablas); Contributor del workspace o superior para el historial de ejecuciones de las materialized lake views |
| SQL endpoint / Warehouse | Contributor del workspace o superior para leer `queryinsights` |
| Modelos semánticos | Permiso Build sobre el modelo para `INFO.VIEW.*` y las consultas DAX; permiso Write para los metadatos completos mediante `powerbi-modeling-mcp`. Ajustes del tenant: *Allow XMLA endpoints and Analyze in Excel with on-premises semantic models* y *Export data* |
| Capacidad | Acceso al workspace donde está instalada la app Capacity Metrics; consentimiento de FabricIQ para `Item.Read.All` e `Item.Execute.All` (los usuarios pueden darlo salvo que el administrador del tenant lo restrinja) |

### App Capacity Metrics

- Para instalarla hay que ser **administrador de la capacidad** y tener licencia de Power BI (Pro, PPU o
  un trial individual de Power BI).
- Instálala en un workspace con licencia Pro, para que la propia app no sufra throttling cuando la
  capacidad esté sobrecargada.
- La app guarda unos 14 días de historial. Los picos más antiguos no se pueden analizar.

### Limitaciones conocidas

- El servidor local `powerbi-modeling-mcp` no funciona en macOS. En un Mac, usa en su lugar el MCP server
  alojado de Power BI Authoring.
- El hook de guarda de Livy está en el frontmatter de `.claude/agents/FabricPerfAnalyst.md`. Claude Code
  solo ejecuta los hooks del frontmatter de un agente de proyecto después de aceptar el diálogo de
  confianza del workspace para esta carpeta; hasta entonces el agente funciona, pero sin el hook. GitHub
  Copilot se comporta igual con `.github/agents/FabricPerfAnalyst.agent.md`: VS Code necesita un workspace
  de confianza y Copilot CLI necesita la carpeta entre sus carpetas de confianza. `COPILOT_ALLOW_ALL=true`
  no basta, porque solo da confianza a los hooks del repositorio, no a los de los agentes.

### Comprobación rápida

```bash
az account show                                                   # Cuenta y tenant con los que has iniciado sesión
az rest --method get --resource https://api.fabric.microsoft.com \
  --url https://api.fabric.microsoft.com/v1/workspaces             # API de Fabric accesible, token válido
node --version                                                    # Node.js para npx
apm install --only apm                                            # Skills de skills-for-fabric restauradas
```

Después, dentro de Claude Code, ejecuta `/mcp` y comprueba que `FabricIQ`, `fabric-sqlendpoint` y
`powerbi-modeling-mcp` están conectados.

## Instalación

```bash
# 1. Instala las skills de skills-for-fabric fijadas en apm.yml / apm.lock.yaml
apm install --only apm

# 2. Inicia sesión en Azure (lo usa el helper de token del MCP de FabricIQ)
az login

# 3. Arranca Claude Code en esta carpeta y aprueba los MCP servers del proyecto
claude
```

`apm install --only apm` despliega las skills de `skills-for-fabric` en `.claude/skills/` en el commit
fijado en `apm.lock.yaml`. Esas skills y `apm_modules/` están en el `.gitignore`; la única skill
versionada es `fabric-perf-analysis`.

- **Por qué `--only apm`:** `.mcp.json` está versionado con el `headersHelper` que necesita `FabricIQ` (ver
  [más abajo](#por-qué-fabriciq-usa-headershelper)). Un `apm install` sin más también intenta escribir los
  MCP servers del paquete en `.mcp.json`, se detiene por el conflicto con `FabricIQ` y deja la instalación
  incompleta.
- **Agentes:** el paquete `skills-for-fabric` es un bundle de skills, así que APM no despliega sus agentes.
  `FabricAdmin`, `FabricAppDev`, `FabricDataEngineer`, `FabricIQ` y `FabricMigrationEngineer` en
  `.claude/agents/` son copias sin modificar de sus `agents/*.agent.md` (licencia MIT), versionadas aquí.
  `FabricPerfAnalyst` es el agente propio de este repositorio.

## MCP servers (`.mcp.json`)

| Servidor | Tipo | Autenticación en Claude Code | Autenticación en GitHub Copilot |
|----------|------|------------------------------|---------------------------------|
| `FabricIQ` | HTTP | Bearer token de `az account get-access-token` mediante `headersHelper` | Cabecera `Authorization: Bearer ${FABRIC_MCP_TOKEN}` |
| `fabric-sqlendpoint` | HTTP | `headersHelper` (hoy la entrada se omite, ver [Solución de problemas](#solución-de-problemas)) | Cabecera `Authorization: Bearer ${FABRIC_MCP_TOKEN}` |
| `powerbi-modeling-mcp` | stdio (`npx`) | Local, sin OAuth | Local, sin OAuth |

Los dos servidores HTTP aceptan un token para la audiencia `https://api.fabric.microsoft.com`. Cada uno
tiene la cabecera estática y el `headersHelper`. Claude Code ejecuta el helper, y su salida sustituye
la cabecera estática del mismo nombre, así que `FABRIC_MCP_TOKEN` no le afecta. Copilot ignora
`headersHelper` y usa la cabecera con la variable expandida.

### Por qué `FabricIQ` usa `headersHelper`

FabricIQ se autentica contra Microsoft Entra ID, que no admite el registro dinámico de clientes de
OAuth. El flujo OAuth integrado de Claude Code falla con
`Incompatible auth server: does not support dynamic client registration`.
El token de `az` evita ese flujo:

```bash
az account get-access-token --resource https://api.fabric.microsoft.com
```

Si el token caduca, vuelve a ejecutar `az login` y después `/mcp` > reconectar `FabricIQ`.

## VS Code + GitHub Copilot

El repositorio también funciona con el harness de GitHub Copilot, que comparten VS Code (session target
**Copilot**), la app de GitHub Copilot y Copilot CLI. Lo que lee:

| Pieza | De dónde la lee Copilot |
|-------|-------------------------|
| Reglas | `AGENTS.md` (y `CLAUDE.md`, que solo lo importa) |
| Skills | `.claude/skills/` (Copilot lo lee de forma nativa; `apm install --only apm` igual que para Claude). El `--target claude,copilot` de la documentación de skills-for-fabric también las copia a `.agents/skills/` (en el `.gitignore`). No hace falta: Copilot lee las dos carpetas y muestra cada skill una sola vez. |
| Agentes del bundle | `.claude/agents/` |
| `FabricPerfAnalyst` | `.github/agents/FabricPerfAnalyst.agent.md`, que prevalece sobre la copia de `.claude/` con el mismo nombre |
| MCP servers | `.mcp.json` |

### Guarda de Livy en VS Code

La copia de `FabricPerfAnalyst` para Copilot declara el mismo hook en su frontmatter:
`python .claude/hooks/livy_readonly_guard.py --format copilot`. Sigue habiendo un solo script: en los
hooks con ámbito de agente, las rutas se resuelven desde la raíz del repositorio, así que no hace falta
copiar el hook a `.github/`. No lo pongas en `.github/hooks/`, porque Copilot trata cualquier `*.json` de
esa carpeta como un hook de todo el repositorio.

| Session target de VS Code | Qué recibe el hook | Cómo bloquea | Verificado |
|---------------------------|--------------------|--------------|------------|
| **Copilot** (el mismo harness que Copilot CLI) | `tool_name` `Bash` (herramientas `powershell` y `bash`), `write_powershell`, `write_bash` | `permissionDecision: "deny"` en el nivel superior | Sí: una sesión de VS Code y `copilot --agent FabricPerfAnalyst` |
| **Local** (heredado) | `tool_name` `run_in_terminal`, `send_to_terminal` | `hookSpecificOutput.permissionDecision: "deny"` | Solo con payloads de prueba; necesita `chat.useHooks` |

Con `--format copilot` el hook imprime un único objeto JSON con las dos decisiones y termina con 0, así
que el motivo del bloqueo llega al modelo en cualquiera de los dos session targets. Sin `--format copilot`,
o con el `$CLAUDE_PROJECT_DIR` de Claude, el hook falla en Copilot y Copilot deniega todos los comandos de
shell del agente con "hook errored". Usa el session target **Copilot**: en **Local**, VS Code también ve
la copia de `.claude/agents/`, cuyo hook usa `$CLAUDE_PROJECT_DIR`.

### Arranque

1. `apm install --only apm` y `az login`, igual que para Claude Code.
2. Cierra **todas** las ventanas de VS Code. Un `code` nuevo reutiliza el proceso en marcha y no hereda
   la variable. Después, desde el mismo terminal:

   ```powershell
   $env:FABRIC_MCP_TOKEN = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
   code .
   ```

   ```bash
   export FABRIC_MCP_TOKEN=$(az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
   code .
   ```

   Con Copilot CLI, define la misma variable y ejecuta `copilot` en lugar de `code .`.
3. Da confianza a la carpeta cuando VS Code o Copilot CLI lo pidan. Sin confianza, el agente funciona sin
   la guarda de Livy.
4. En la vista de Chat, elige **Copilot** como session target. Comprueba en **Chat: Open
   Customizations** > **MCP Servers** que `FabricIQ`, `fabric-sqlendpoint` y
   `powerbi-modeling-mcp` están conectados; en Copilot CLI, `/mcp`.
5. Pide el análisis en el chat. La sesión principal lo delega en `FabricPerfAnalyst`, igual que en
   Claude Code, o puedes elegir el agente en el desplegable de agentes (en Copilot CLI,
   `/agent FabricPerfAnalyst` o `copilot --agent FabricPerfAnalyst`).

El token dura aproximadamente una hora. Cuando caduca, `FabricIQ` y `fabric-sqlendpoint` devuelven 401:
repite el paso 2.

### Limitaciones

- `FABRIC_MCP_TOKEN` es un bearer token en el entorno de VS Code o de la CLI y de sus procesos hijos.
  No lo pongas en ningún fichero ni lo subas al repositorio.
- Si falta la variable, Copilot envía `Bearer ` sin token, los servidores devuelven 401 y Copilot
  intenta el OAuth por navegador, que falla porque Entra no tiene registro dinámico de clientes. El
  agente lo anota en Notas como un MCP que falta.
- Una alternativa no probada en este repositorio: la autenticación de Microsoft integrada en VS Code para
  los MCP servers declarados en `.vscode/mcp.json`. Necesitaría otros nombres de servidor para no chocar
  con `.mcp.json`.
- La regla de denegación de `.claude/settings.local.json`, exclusiva de Claude, de
  [DEMO-SCENARIOS.md](demo-setup/DEMO-SCENARIOS.md#antes-de-ejecutar-el-agente) no tiene equivalente aquí:
  saca `demo-setup/` del repositorio.

## Comandos útiles

```bash
claude mcp list          # Estado de conexión de todos los MCP servers (Claude Code)
copilot mcp list         # MCP servers configurados para el harness de Copilot
apm --version            # Comprueba la versión de APM
apm install --only apm   # Restaura las skills y apm_modules/ desde apm.lock.yaml
az account show          # Confirma con qué cuenta/tenant has iniciado sesión
```

Dentro de Claude Code: `/mcp` (gestionar servidores), `/reload-plugins` (recargar plugins y skills).
Dentro de Copilot CLI: `/mcp`, `/agent`, `/skills`.

## Solución de problemas

- **FabricIQ falla con un error de registro dinámico de clientes**: comprueba que `headersHelper` está
  definido en `.mcp.json` y que `az login` sigue siendo válido.
- **Copilot: `FabricIQ` o `fabric-sqlendpoint` piden OAuth por navegador o no conectan**:
  `FABRIC_MCP_TOKEN` falta o ha caducado en el proceso de VS Code o de la CLI. Repite el paso 2 de
  [Arranque](#arranque).
- **Copilot: todos los comandos de shell de `FabricPerfAnalyst` se deniegan con "hook errored"**: el hook
  se está ejecutando sin `--format copilot` o no encuentra `python`. Revisa el frontmatter de
  `.github/agents/FabricPerfAnalyst.agent.md`.
- **Copilot: el hook no se dispara** (no se bloquea una escritura de Livy): la carpeta no es de confianza
  (VS Code: Workspace Trust; Copilot CLI: `trustedFolders`). En Copilot CLI el log de depuración muestra
  `agent hooks deferred until their workspace is trusted`. En el session target **Local** de VS Code,
  revisa también `chat.useHooks`.
- **Servidores duplicados**: el plugin `fabric-skills` declara los mismos tres servidores. Si el plugin y
  este `.mcp.json` están activos a la vez, verás duplicados (`plugin:fabric-skills:*` y los del
  proyecto).
- **Configuración de `fabric-sqlendpoint` rechazada** con `tools.0: expected object, received string`:
  Claude Code 2.1.312 no acepta el array `tools` en este formato.
