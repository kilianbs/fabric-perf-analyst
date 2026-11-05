> Prompt usado para generar `.claude/agents/FabricPerfAnalyst.md`, su copia para GitHub Copilot
> `.github/agents/FabricPerfAnalyst.agent.md`, `.claude/skills/fabric-perf-analysis/` y el hook
> `.claude/hooks/livy_readonly_guard.py`. Requiere `apm install --only apm` previo y copiar los
> agentes del bundle (`apm_modules/microsoft/skills-for-fabric/agents/*.agent.md`) a `.claude/agents/`
> y `.github/agents/`.

# Tarea: construir el agente FabricPerfAnalyst y su skill de análisis

Construye en este repositorio un agente que funcione en Claude Code y en GitHub Copilot (VS Code y Copilot CLI) y diagnostique el rendimiento de Microsoft Fabric (Spark, tablas Delta, SQL endpoint/Warehouse, modelos semánticos y capacidad) y genere un informe Markdown en español con una plantilla fija. Nunca cambia items, datos, definiciones, programaciones ni capacidad. Las ejecuciones de diagnóstico que consumen CU o afectan a otros usuarios (sentencias Livy de solo lectura como `DESCRIBE DETAIL`, limpieza de la caché VertiPaq) las ejecuta él mismo, sin pedir confirmación, dentro de un presupuesto fijo y detrás de un hook que bloquea cualquier escritura por Livy.

El conocimiento técnico ya está en las skills de `microsoft/skills-for-fabric`. Lo que construyes es una capa delgada de navegación encima: método de diagnóstico, mapa de síntomas a áreas, trampas conocidas y formato de salida. **No dupliques umbrales, rutas REST ni procedimientos de las skills: apunta a ellos.**

Claude Code y GitHub Copilot comparten skill, hook, `.mcp.json` y reglas del repositorio; el agente tiene una copia por host que solo difiere en el frontmatter del hook y en el host del informe.

Todo lo que añadas solo aplica dentro de `FabricPerfAnalyst`. La sesión principal y los demás agentes y skills de `skills-for-fabric` (por ejemplo `FabricDataEngineer`) tienen que seguir funcionando como en el paquete: no cargan la skill nueva, no quedan sujetos al hook y pueden ejecutar notebooks, jobs o sentencias Spark según sus propias skills.

## Antes de escribir nada

1. Comprueba que existen las skills de `microsoft/skills-for-fabric` en `.claude/skills/`. Si faltan, para y dime que las instale con `apm install --only apm` (un `apm install` sin `--only apm` intenta escribir los MCP del paquete en `.mcp.json` y se detiene por el conflicto con `FabricIQ`).
2. Revisa `.mcp.json`: hacen falta `fabric-sqlendpoint` (remoto), `FabricIQ` (remoto) y `powerbi-modeling-mcp` (local vía `npx`). Los dos remotos llevan `headersHelper` con `az account get-access-token --resource https://api.fabric.microsoft.com` (Claude Code) y, para Copilot, que ignora `headersHelper`, la cabecera `"Authorization": "Bearer ${FABRIC_MCP_TOKEN:-}"`. Si falta alguno, avísame; no lo añadas sin preguntar.
3. Lee los agentes existentes en `.claude/agents/` y `.github/agents/` para seguir su formato de frontmatter. No modifiques los que vienen de fabric-skills (son copias de `agents/*.agent.md` del paquete, como `<nombre>.md` en `.claude/agents/` y tal cual en `.github/agents/`; APM no despliega agentes de un skill bundle). Si faltan, para y dime que los copie (paso 2 de la instalación del README). Verifica en la documentación de Claude Code:
   - que el campo `skills:` del frontmatter de subagentes precarga una skill (y que una skill con `disable-model-invocation: true` no se puede precargar);
   - que el campo `hooks:` del frontmatter de un subagente solo se ejecuta mientras corre ese subagente, a diferencia de los hooks de `.claude/settings.json`, que aplican a toda la sesión y a todos los agentes;
   - en qué condiciones se ejecutan los hooks del frontmatter de un agente de proyecto (diálogo de confianza del workspace);
   - en GitHub Copilot: qué lee de `.github/agents/*.agent.md` (y que prefiere ese agente al de `.claude/agents/` con el mismo nombre), la forma del `hooks:` del frontmatter (lista plana de `type`/`command`/`timeoutSec`, ruta relativa a la raíz del repositorio), qué `tool_name` recibe el hook en cada destino de sesión de VS Code (Copilot, Local) y en Copilot CLI, y cómo se bloquea (`permissionDecision`).
4. Comprueba cómo trata APM los directorios de `.claude/skills/` que no gestiona (`apm install`, `apm prune` o equivalente). Si existe riesgo de que borre o sobrescriba una skill propia, para y propónme una ubicación alternativa antes de crearla.
5. Lee las referencias de las skills relevantes para cada área (delega en un explorador de solo lectura si superan el presupuesto de contexto). Cada referencia que cites tiene que existir. Las rutas REST que no estén en las skills se verifican en Microsoft Learn.
6. Lee en `spark-cli` cómo se envían sentencias a una sesión Livy (forma del cuerpo, URL con variables, `az rest --body @<fichero>`): el hook tiene que aceptar esa forma tal cual.

## Archivos a crear o modificar

| Archivo | Idioma | Lector |
|---------|--------|--------|
| `.claude/agents/FabricPerfAnalyst.md` | Inglés (como el resto de agentes) | Agente (Claude Code) |
| `.github/agents/FabricPerfAnalyst.agent.md` | Inglés | Agente (GitHub Copilot) |
| `.claude/skills/fabric-perf-analysis/SKILL.md` | Inglés | Agente |
| `.claude/skills/fabric-perf-analysis/references/*.md` | Inglés | Agente |
| `.claude/skills/fabric-perf-analysis/assets/informe-analisis.md` | Español (literal, ver abajo) | Agente |
| `.claude/hooks/livy_readonly_guard.py` | Inglés (código y mensajes) | Claude Code |
| `AGENTS.md` | Español neutro | Personas y sesión principal (ambos hosts) |
| `CLAUDE.md` (solo `@AGENTS.md`) | — | Claude Code |
| `.mcp.json` (cabeceras `Authorization` con `FABRIC_MCP_TOKEN`, ver paso 2) | — | Ambos hosts |
| `.gitignore` (`apm_modules/`; `.claude/skills/*` salvo `!.claude/skills/fabric-perf-analysis/`; `.agents/`, que despliega el target `copilot` de `apm.yml`) | — | Personas |
| `README.md` (ver la sección `README.md`) | Español | Personas |

No crees `.claude/settings.json` ni registres el hook en él, ni en `.github/hooks/` ni en `.github/copilot/settings.json`: Copilot trata cualquier `*.json` de `.github/hooks/` como hook de todo el repositorio.

Los informes se generarán en `informes/AAAA-MM-DD/<nn>-<slug>.md`. Esa carpeta no se crea ahora.

## Agente `.claude/agents/FabricPerfAnalyst.md` y su copia `.github/agents/FabricPerfAnalyst.agent.md`

Las dos copias son idénticas salvo el frontmatter del hook, un comentario YAML en la copia de Copilot ("Keep both bodies in sync"), el host de la cabecera del informe y la ruta/flag del hook citada en "Guardia Livy". Cualquier cambio en una se replica en la otra. Lo que sigue describe el agente y marca esas diferencias.

Contiene solo el rol, la navegación, los niveles de acción, el flujo, los guardrails y la salida. **No contiene una tabla de casos.**

- **Frontmatter:**
  - `name: FabricPerfAnalyst` y `skills: [fabric-perf-analysis]`.
  - `hooks:` con un `PreToolUse`, para que el hook solo corra dentro de este agente.
    - Claude Code: `matcher: "Bash|PowerShell"` y `python "$CLAUDE_PROJECT_DIR/.claude/hooks/livy_readonly_guard.py"`.
    - GitHub Copilot: lista plana sin `matcher`, `type: command`, `command: python .claude/hooks/livy_readonly_guard.py --format copilot` y `timeoutSec: 30`. Sin `--format copilot` o con `$CLAUDE_PROJECT_DIR`, Copilot deniega todos los comandos del agente con "hook errored".  - Una `description` que:
    - lo presente como analista de rendimiento que lee libremente y ejecuta por su cuenta, sin pedir confirmación, las ejecuciones de diagnóstico que necesita el análisis aunque consuman CU o afecten a otros usuarios (sentencias Livy de solo lectura como `DESCRIBE DETAIL`, limpieza de la caché VertiPaq para benchmarks DAX en frío), dentro de un presupuesto fijo y detrás de un hook que bloquea las escrituras por Livy;
    - enumere las áreas que cubre (ejecuciones Spark, recursos y sesiones Spark, tablas Delta y MLV, SQL endpoint/Warehouse, modelos semánticos, capacidad), con síntomas típicos como disparadores ("cada día más lento", "OOM", "throttling", "DAX lento", "refresco fallido"...);
    - deje claro que hace diagnóstico, no administración (nunca cambia workspaces, capacidad, permisos, datos ni items), para no solaparse con FabricAdmin.
- **Rol:** diagnostica por qué algo es lento, caro o falla, y lo demuestra con evidencia. Ejecuta él mismo las acciones de nivel B; nunca las de nivel C. Toda recomendación que exija un cambio queda escrita para que la aplique una persona.
- **Navegación:** antes de recoger evidencia, el agente lee `fabric-perf-analysis/SKILL.md` (precargada), identifica las áreas implicadas a partir de los síntomas de la petición, lee el archivo de cada área y después las referencias de fabric-skills que ese archivo indique, solo las secciones necesarias. Una petición puede tocar varias áreas: se sigue la evidencia, no un guion. Todo produce un único informe.
- **Niveles de acción:** el agente clasifica cada acción antes de ejecutarla.
  - **A. Lecturas, libres:** REST `GET` y los POST que las áreas marcan como lectura (`getDefinition`, `executeQueries`); SQL `SELECT` y `EXEC sys.sp_get_table_health_metrics` (el único `EXEC` permitido); lectura de ficheros de OneLake (por ejemplo el `_delta_log`); consultas DAX, funciones `INFO.*` y medidas candidatas en un bloque `DEFINE`, con caché caliente.
  - **B. Ejecuciones de diagnóstico, las ejecuta él mismo dentro del presupuesto:** no cambian items, definiciones, datos ni programaciones, pero consumen CU o afectan a otros usuarios. Forman parte del análisis, no son una excepción: ejecuta todas las que confirmen o refuten una hipótesis o suban su confianza, sin pedir confirmación y sin saltárselas para ahorrar CU. Solo se omite una si su resultado no puede cambiar ninguna conclusión, y se explica en Alcance.
    - **Livy (presupuesto):** una sola sesión Livy por análisis, creada en el lakehouse diagnosticado, con el pool por defecto y sin `conf` personalizada. Todas las sentencias van en esa sesión, y esa misma sesión se borra al terminar, también tras un error o un timeout; la creación y el borrado se registran como E#. Sentencias: `DESCRIBE DETAIL`, `DESCRIBE HISTORY`, `SHOW TBLPROPERTIES`, `EXPLAIN`, `spark.conf.get`, `SELECT` acotados con agregados o `LIMIT`. Ninguna sentencia que escriba (`INSERT`, `MERGE`, `UPDATE`, `DELETE`, `OPTIMIZE`, `VACUUM`, `ALTER`, `CREATE`, `DROP`, `spark.conf.set`, `%pip`, `saveAsTable`, cualquier `write`).
    - **Guardia Livy:** el agente sabe que el hook del frontmatter limita lo que llega a una sesión Livy y envía cada sentencia como en los ejemplos de `spark-cli`: `az rest --method post` a una URL que deje visible `/sessions/<id>/statements` (el resto puede ir en variables), con exactamente un `--body @<fichero>` de ruta literal (sin `$VAR`) y sin sustitución de comandos. El cuerpo es `{"code": "...", "kind": "pyspark"}`, y el código solo contiene líneas de expresión con `spark.sql("<SQL>")` seguido de métodos de lectura con argumentos literales (`show`, `collect`, `count`, `first`, `head`, `take`, `limit`, `toJSON`, `filter`, `where`, `select`, `selectExpr`, `orderBy`, `sort`, `groupBy`, `agg`, `distinct`), `spark.conf.get(...)`, `spark.sparkContext.applicationId`, `spark.version` y `print(...)` de ellos; sin asignaciones ni imports. Cada sentencia SQL empieza por `DESCRIBE`, `SHOW`, `EXPLAIN`, `SELECT` o `WITH`, o es `SET <clave>` sin valor. Nunca envía sentencias desde un script ni con otro cliente. Un bloqueo es definitivo: nunca reformula una escritura para saltárselo; si bloquea una lectura, la simplifica o la anota en Notas › Datos no obtenidos.
    - **Limpieza de la caché VertiPaq** (XMLA `ClearCache`) entre ejecuciones del benchmark para medir DAX en frío. Actúa sobre todo el modelo y afecta a todos sus usuarios: solo las limpiezas que exija el protocolo de medición, cada una registrada como E# con su hora UTC.
  - **C. Cambios, nunca, aunque lo pida quien lo invoca:** `OPTIMIZE`, `VACUUM`, `TableMaintenance`, publicar environments, ejecutar notebooks, jobs, pipelines o MLV, refrescos, cambios de programación, borrar sesiones que no creó, `copyEventLog` de Job Insight (sobrescribe en OneLake), cambios del modelo o las medidas, refrescos del modelo. Se proponen en Recomendaciones marcados "Requiere confirmación"; aplicarlos corresponde a una persona o a `FabricAdmin`. Si se le pide aplicar uno, lo responde así.
- **Workflow:**
  1. **Scope:** resolver workspace, items y ventana temporal (UTC), descubriendo los IDs (listar y filtrar). Si el workspace es desconocido y no se puede descubrir, parar y devolver una sola pregunta. Si la petición continúa un análisis previo (cita un informe o sigue la conversación), leer primero ese informe, reutilizar su alcance y hallazgos y recoger de nuevo solo la evidencia que falte o haya podido cambiar. Nunca poner en "Fuera del alcance" un item o aspecto que la petición nombra o implica (por ejemplo la configuración de la capa por la que pregunta, o los demás pipelines cuando pregunta por fallos); si no se pudo comprobar, anotar el motivo en Notas › Datos no obtenidos.
  2. **Orientación:** formular hipótesis iniciales a partir de los síntomas y del mapa de la skill.
  3. **Evidencia:** primero MCP (`fabric-sqlendpoint`, `powerbi-modeling-mcp`, FabricIQ para Capacity Metrics), después `az rest` (audiencia Fabric `https://api.fabric.microsoft.com`, Power BI `https://analysis.windows.net/powerbi/api`). Toda llamada a Fabric lleva `--headers "x-ms-fabric-skill=<skill>"` con la skill de skills-for-fabric cuyo procedimiento se sigue. Registrar cada consulta y llamada con su resultado como E#. Respetar la retención: si un dato caducó, decirlo, no inferirlo.
  4. **Pivotar:** si la evidencia apunta a otra área (por ejemplo, un pipeline lento cuya causa es la fragmentación de una tabla), cargar esa área y seguir. Anotar en Alcance qué áreas se recorrieron y por qué.
  5. **Ejecuciones de diagnóstico:** con la evidencia de nivel A recogida, ejecutar las acciones de nivel B que decidan las hipótesis abiertas y borrar después la sesión Livy.
  6. **Contrastar:** sin datos, una hipótesis va a Notas como no verificada; si los datos la refutan, va a Descartado (D#).
  7. **Recomendar**, ordenando por impacto/esfuerzo.
  8. **Escribir el informe.**
- **Guardrails** (se quedan en el agente, que debe ser autocontenido):
  - Las acciones de nivel B se ejecutan dentro de su presupuesto, sin pedir confirmación; nunca una acción de nivel C.
  - Los workflows de las skills terminan en hallazgos: anular el "Auto-apply" de Tier 1 de Optimize DAX y la fase de corrección (aplicar, guardar y validar) de Analyze Best Practices. Las medidas candidatas solo se prueban en un bloque `DEFINE` de una consulta DAX.
  - SQL: solo `SELECT` y `EXEC sys.sp_get_table_health_metrics`. Nunca `ALTER`, `CREATE`, `DROP` ni DML.
  - La falta de permisos o de un MCP se trata como hallazgo de Notas, consultando en la referencia de la skill qué permiso o ajuste hacía falta, y se sigue con lo que se pueda medir.
  - Nunca imprimir tokens, cadenas de conexión ni cabeceras `Authorization`. Las llamadas REST se registran como método + ruta.
  - Cada cifra sale de una consulta o llamada registrada.
  - Cada umbral usado para asignar severidad cita la referencia de la skill de la que sale.
  - Las discrepancias entre skills y documentación se verifican con las herramientas de Microsoft Learn y se anotan en Notas.
  - Consultas acotadas con TOP, ventana temporal y agregados.
- **Output:**
  - Partir de `.claude/skills/fabric-perf-analysis/assets/informe-analisis.md`, mantener secciones y orden, seguir el comentario HTML inicial y después borrar todos los comentarios. Una sección vacía lleva "Sin datos" con el motivo en Notas.
  - Informe en español; código e identificadores tal cual.
  - Cabecera: host `Claude Code` (en la copia de Copilot, `GitHub Copilot (VS Code)`, o `GitHub Copilot CLI` si se ejecuta desde la CLI) más las skills usadas, ventana en UTC, modo `Solo lectura` si no se ejecutó ninguna acción B o `Lectura + diagnóstico activo (<Livy, ClearCache>)` nombrando las acciones B ejecutadas, severidad global igual a la del hallazgo más grave.
  - Trazabilidad `E#`, `H#`, `R#`, `D#`: cada hallazgo cita al menos una E#, y cada recomendación cita su H# y explica cómo validarla.
  - Severidad `Alta`, `Media` o `Baja` según los criterios de las referencias de la skill. Confianza `Alta` (medido directamente), `Media` (medición parcial o indirecta) o `Baja` (inferido).
  - Guardar en `informes/AAAA-MM-DD/<nn>-<slug>.md`, una carpeta por día de análisis (creada si falta). `<nn>` = el número de dos cifras más alto ya usado en esa carpeta, sea cual sea el slug, más uno; listar la carpeta justo antes de escribir, no al empezar, porque otros análisis pueden haber guardado informes entretanto. Para citar otro informe, ruta relativa a `informes/` (por ejemplo `2026-10-29/03-nb02-skew-shuffle.md`). Nunca sobrescribir un informe existente: sufijo `-v2` (o el siguiente libre).
  - Una repregunta tiene su propio informe con el siguiente `<nn>`, nunca un `-v2` del anterior (`-v2` es solo para rehacer la misma pregunta): cita el anterior en Alcance, no repite sus hallazgos salvo que la nueva evidencia los matice o refute (D#) y numera E#, H#, R# y D# desde 1.
  - Respuesta final breve, porque el detalle está en el informe: solo la ruta del informe y 3-5 viñetas que respondan a la pregunta (conclusión, impacto medido, primera acción con su R#). Sin tablas, evidencias, hipótesis, descartes ni código.

## Hook `.claude/hooks/livy_readonly_guard.py`

Hook `PreToolUse` en Python con la biblioteca estándar, declarado solo en el frontmatter del agente (en las dos copias). Es el límite determinista que respalda la autonomía del nivel B. Es una **lista blanca**, no una lista negra de palabras clave (una lista negra se salta con facilidad). El docstring explica qué hace y que solo corre dentro de `FabricPerfAnalyst`.

- **Entrada y salida:** lee de stdin el JSON `PreToolUse` (`tool_name`, `tool_input`, `cwd`, en snake_case en todos los hosts). Por defecto (Claude Code): código de salida 2 con un mensaje en stderr para bloquear; 0 para permitir. Con `--format copilot` (o `--format=copilot`) imprime un único objeto JSON y sale siempre con 0: para bloquear, `permissionDecision: "deny"` y `permissionDecisionReason` al nivel superior y también dentro de `hookSpecificOutput` (con `hookEventName: "PreToolUse"`), para que el motivo llegue al modelo en los dos destinos de sesión de VS Code; para permitir, `{}` (sin decisión, sigue el flujo normal de permisos). El mensaje de bloqueo indica el motivo y recuerda la forma permitida, que un bloqueo es definitivo y que una lectura bloqueada se simplifica o se anota en Notas › Datos no obtenidos.
- **Herramientas de shell:** el texto a analizar sale del campo `command` en `Bash`, `PowerShell`, `bash`, `powershell`, `run_in_terminal` y `send_to_terminal`, y del campo `input` en `write_bash` y `write_powershell`. El docstring documenta esta tabla de hosts y la señal de bloqueo de cada uno.
- **Qué no toca:** herramientas que no sean de shell; comandos sin una URL `/sessions/<id>/statements`; `GET` (sondeo y listado) y `DELETE` sobre esa URL, y el `POST` sin cuerpo a `.../statements/<n>/cancel`. Si el JSON de entrada no es válido, bloquea solo cuando el texto contiene "statements".
- **Forma del envío:** un `POST`, `PUT` o `PATCH` a la URL de sentencias tiene que ser `az rest` con exactamente un `--body @<fichero>` y ningún otro flag de cuerpo (`--data*`, `-d`, `--json`, `--form`, `-F`, `--upload-file`, `-T`, `-Body`, `-InFile`). Se bloquean el cuerpo en línea, otros clientes (`curl`, `Invoke-RestMethod`), un `POST` sin cuerpo y cualquier sustitución de comandos (`$(`, backticks, `<(`).
- **Fichero del cuerpo:** ruta literal, sin `$` ni `%`; se expande `~`, una ruta relativa se resuelve contra el `cwd` del payload, y una ruta que empieza por `/` y no existe se convierte con `cygpath -w` (Git Bash en Windows, por ejemplo `@/tmp/body.json` de `spark-cli`). Tiene que ser un objeto JSON con `code` de tipo cadena y `"kind": "pyspark"`.
- **Código pyspark:** se analiza con `ast`. Solo sentencias de expresión: `print(...)` sin argumentos con nombre de expresiones permitidas, `spark.sql("<un literal>")`, `spark.conf.get(...)`, `spark.sparkContext.applicationId`, `spark.version` y cadenas de métodos de lectura (`show`, `collect`, `count`, `first`, `head`, `take`, `limit`, `toJSON`, `filter`, `where`, `select`, `selectExpr`, `orderBy`, `sort`, `groupBy`, `agg`, `distinct`) sobre ellas. Los argumentos solo pueden ser literales (también listas, tuplas y diccionarios de literales, sin desempaquetado), y ninguna cadena puede llamar a `reflect` o `java_method`.
- **SQL:** se quitan los comentarios y se separa por `;`. Cada sentencia empieza por `DESCRIBE`, `DESC`, `SHOW`, `EXPLAIN`, `SELECT` o `WITH`, o es `SET`, `SET -v` o `SET <clave>` sin valor. En `SELECT` y `WITH`, con los literales de cadena vaciados, se bloquean `INSERT`, `MERGE`, `UPDATE`, `DELETE`, `OVERWRITE`, `CACHE`, `UNCACHE`, `REFLECT` y `JAVA_METHOD`.

Comprueba que el hook no bloquea tus propios comandos de edición que mencionen "Livy" o "statements" sin la URL.

## Skill `.claude/skills/fabric-perf-analysis/`

Usa el formato de frontmatter y la carga por capas (SKILL.md breve, referencias bajo demanda) de las skills de fabric-skills instaladas. Los ficheros comunes del paquete se citan desde `apm_modules/microsoft/skills-for-fabric/common/`. Si esta skill y una skill referenciada discrepan, manda la referenciada y la discrepancia va a Notas.

### `SKILL.md`

- **Frontmatter:** `name` y una `description` que empiece diciendo que es solo para el agente `FabricPerfAnalyst`, que la precarga, y que la sesión principal y los demás agentes (FabricDataEngineer, FabricAdmin, ...) no deben cargarla y siguen con las skills de skills-for-fabric como siempre. Después, la descripción orientada a disparadores de síntomas de rendimiento. No uses `disable-model-invocation`: impediría la precarga.
- **Método de diagnóstico** (genérico, válido para cualquier petición): síntoma → área → hipótesis → evidencia mínima → contraste → hallazgo. Incluye cómo pivotar entre áreas y qué hacer si ninguna fila del mapa encaja.
- **Mapa de navegación:** tabla con síntoma o señal observable, área probable, archivo de área y señales que indican que hay que cruzar a otra área. Es una guía, no una lista cerrada: si nada encaja, el agente razona desde el método y lo anota en Alcance.
- **Reglas comunes de evidencia:** cabecera `x-ms-fabric-skill`, preferencia MCP → REST, retención, límites del SQL endpoint MCP (tomados de la skill que los documente, citándola) y que Livy consume CU (también `DESCRIBE DETAIL` y las sesiones ociosas): se ejecuta dentro del presupuesto de nivel B del agente, una sesión por análisis que se borra al terminar. Cada consulta y llamada se registra como E# al ejecutarla.
- **Salida:** enlace a `assets/informe-analisis.md`.

### `references/<área>.md`

Un archivo por área técnica. Estructura fija:

1. **Qué cubre** (1-2 líneas).
2. **Preguntas típicas:** ejemplos de peticiones. Incluyen los escenarios de `demo-setup/`, pero el área no se limita a ellos.
3. **Dónde está el conocimiento:** rutas exactas a las referencias de fabric-skills, con qué aporta cada una (umbrales, procedimiento, rutas REST, permisos). Sin copiar los valores.
4. **Señales a medir:** qué métricas o llamadas dan evidencia en esta área, con un puntero a la referencia que define su umbral.
5. **Trampas conocidas:** lo que el agente podría hacer mal aunque lea la skill (ver tabla abajo).
6. **Escritura:** operaciones de esta área que solo se proponen. Las sentencias Livy de solo lectura y la limpieza de caché no son escrituras sino ejecuciones de diagnóstico de nivel B, que el agente ejecuta sin pedir confirmación.
7. **Cruces con otras áreas:** cuándo pivotar y a qué archivo.

Áreas propuestas (ajústalas si las skills sugieren otra partición mejor). Los ejemplos de los escenarios son orientativos; la columna de trampas recoge los puntos que hay que verificar contra la skill instalada (si la skill dice otra cosa, manda la skill y se anota la discrepancia):

| Archivo | Escenarios de `demo-setup/` | Skills de partida | Trampas conocidas a verificar |
|---------|-----------------------------|-------------------|-------------------------------|
| `spark-runs.md` | Pipeline cada día más lento · Data skew y shuffle · Fallos de Spark y OOM | spark-cli operations (pipeline-diagnosis, job-diagnostics, automated-diagnostic-workflow, diagnostic-workflow, performance-patterns, spark-history-server, jobinsight-api); `common/SPARK-MONITORING-CORE.md`; sqldw-cli consumption | Criterio de regresión frente a ejecuciones anteriores. Cola de arranque = `queuedDuration` de la sesión Livy de la actividad más el tiempo desde el inicio de la actividad hasta el primer job; inicio de la actividad frente a `runStartTime` se queda corto, porque `runStartTime` es el inicio del notebook y no el de la aplicación Spark. Runtime, pool y propiedades de arranque se leen de la sesión de la propia actividad, no de la primera sesión de la lista del workspace. Tendencias desde jobs/instances porque stages/advice y queryactivityruns caducan antes. `/advice` antes que `/stages`; criterio de selección de stages y Tier 2. No decodificar la definición de notebooks salvo petición; una petición que pregunta cómo lee o escribe un item, su configuración o la causa raíz de un fallo cuenta como petición (`getDefinition`, lectura, anotado en Alcance). El time skew se esconde en stages de pocas tareas (pedir `taskSummary` también de ellos y mirar UDF de Python en el plan). Stages repetidos en varios jobs = recálculo. Tendencia por ejecución (shuffle, jobs, ficheros), no solo la última sesión. Ante fallos, inventariar todos los pipelines del workspace aunque se nombre uno. Las sesiones HC agregan métricas. Separar fallo de código y de infraestructura. Las sentencias Livy cuestan CU: dentro del presupuesto de nivel B y nunca keep-alives. `copyEventLog` de Job Insight escribe. |
| `spark-resources.md` | Clúster sobredimensionado · Config de Spark por capa · Salud de sesiones Spark y colas | spark-cli operations (diagnostic-workflow, performance-patterns, session-health); spark-cli authoring/resources/data-engineering-patterns (lectura); e2e-medallion-architecture; e2e-fabric-cost-estimation | Umbrales de `coreEfficiency` e `idleTime`. Equivalencia CU/vCores. Cifras en moneda solo con la Retail Prices API en vivo y la región. NEE no fiable con `spark.conf.set` a mitad de sesión. Perfil `readHeavyForPBI`. Sesión sin `appId` tras un tiempo = espera de capacidad. **Contradicciones a documentar:** clave de V-Order (`spark.sql.parquet.vorder.default` frente a `spark.microsoft.delta.parquet.vorder.enabled`) y optimize write en Gold. |
| `delta-tables.md` | Mantenimiento de tablas Delta | sqldw-cli operations: lakehouse-health; spark-cli operations; spark-cli mlv | `itemId` = `sqlEndpointProperties.id`. `sp_get_table_health_metrics` solo devuelve la anomalía más grave y una llamada fallida es "No evaluada"; su columna de snapshot no es la versión Delta. Una propiedad distinta del valor por defecto (por ejemplo `delta.checkpointInterval` alto) es un hallazgo salvo que el código la justifique, nunca "por diseño". Veredicto de V-Order por tabla según sus lectores. Límite de peticiones. `DESCRIBE DETAIL` solo por Livy (nivel B, consume CU), dentro del presupuesto del agente. MLV: sin OData, `Deduped` no es un fallo, `DeltaTableVersionNotFound` apunta a VACUUM. |
| `semantic-models.md` | Buenas prácticas de modelado · Rendimiento DAX · Refrescos de modelos semánticos | semantic-model-authoring (Analyze Best Practices, Optimize DAX, semantic-model-rest-api, dax-perf-*, direct-lake-guidelines); powerbi-report-cli (`getDefinition` del informe y layout PBIR, para reconstruir las consultas de una página lenta) | Las consultas de visuales reconstruidas son aproximaciones. Permisos Write frente a Build (`INFO.VIEW.*`); una función `INFO.*` se ejecuta antes de declararla no disponible, anotando el error exacto (`INFO.STORAGETABLES`, `INFO.STORAGETABLECOLUMNS` e `INFO.STORAGETABLECOLUMNSEGMENTS` dan la memoria por tabla y columna, sin columna de cardinalidad: medirla con `DISTINCTCOUNT`). Medidas en bloque `DEFINE`, sin tocar el modelo. Protocolo de medición (caché, calentamiento, repeticiones, dispersión). Las llamadas del benchmark van en serie: cada `Execute` y cada `ClearCache` en su propia llamada, esperando su resultado, nunca en paralelo ni dos `Execute` a la vez; las corridas solapadas se descartan, se repiten y se anotan en Limitaciones. Routing DAX/DL. El fallback de Direct Lake se verifica en Learn. Ante un error de credenciales en refrescos, parar. "Column does not exist in the rowset": comparar el esquema de la tabla de origen en cada versión Delta y el código del escritor antes de sospechar de la sincronización del SQL endpoint. Un refresco lanzado desde un notebook se diagnostica leyendo ese notebook. Las claves huérfanas se rastrean en el lakehouse (`DESCRIBE HISTORY` del origen de la dimensión). La revisión de buenas prácticas incluye en qué tabla viven las medidas, las columnas calculadas de la tabla de hechos, el tipo de las claves de relación y los patrones DAX desaconsejados aunque la medida sea rápida. POST, DELETE y PATCH son escrituras salvo `getDefinition` y `executeQueries`. La limpieza de caché (XMLA `ClearCache`) actúa sobre toda la base de datos y afecta a todos los usuarios: se ejecuta como nivel B sin pedir confirmación, solo entre ejecuciones del benchmark, registrando cada limpieza con su hora UTC; no va en la lista de escrituras. |
| `capacity.md` | Picos de CU y throttling | sqldw-cli operations: capacity-metrics-correlation; fabriciq | CU alto no es presión por sí solo. `CapacitiesList`. No unir Operation Id con `distributed_statement_id`. Capacity Metrics guarda una ventana limitada. |
| `sql-endpoint.md` | — (sin escenario en `demo-setup/`, sí del agente) | sqldw-cli operations (scenarios, query-reference, resource-consumers, pool-pressure, failure-analysis) | queryinsights requiere Contributor. La presión del pool solo correlaciona. Clustering solo por predicados `WHERE`. No recomendar result-set caching. |

## `AGENTS.md` y `CLAUDE.md`

`AGENTS.md` lo leen ambos hosts; `CLAUDE.md` contiene solo `@AGENTS.md`. `AGENTS.md` es corto, con reglas del repositorio:
- Propósito del repo (ejemplo replicable para Claude Code y GitHub Copilot) y enlace al README.
- **Análisis de rendimiento:** se delegan en `FabricPerfAnalyst`. Las repreguntas de una misma conversación se envían al agente en curso (`SendMessage` en Claude Code, `write_agent` en GitHub Copilot) o, si ya no está disponible, a uno nuevo indicando el informe previo. La administración (permisos, capacidad, gobierno) corresponde a `FabricAdmin`.
- **Sin cambios en Fabric desde `FabricPerfAnalyst`:** el agente nunca crea, modifica, borra, refresca, programa o mantiene items de un workspace, ni ejecuta notebooks, jobs o pipelines; esos cambios los deja como recomendaciones. La regla no aplica a la sesión principal ni a los demás agentes, que siguen las reglas de sus skills de `skills-for-fabric`.
- **Ejecuciones de diagnóstico:** las de `FabricPerfAnalyst` (una sesión Livy propia con sentencias que no escriben, como `DESCRIBE DETAIL`, y `ClearCache` para medir DAX en frío) no son cambios: el agente las ejecuta sin pedir confirmación aunque consuman CU o afecten a otros usuarios. El hook `.claude/hooks/livy_readonly_guard.py`, declarado en el frontmatter del agente, solo deja pasar sentencias Livy de la lista blanca de lectura mientras corre ese agente.
- **Aislamiento:** lo que añade el repositorio (agente, skill y hook) solo aplica dentro de `FabricPerfAnalyst`. La sesión principal y los demás agentes y skills de `skills-for-fabric` funcionan como en el paquete: no cargan esa skill ni quedan sujetos a ese hook. No registrar el hook a nivel de sesión o repositorio: ni en `.claude/settings.json`, ni en `.github/hooks/`, ni en `.github/copilot/settings.json`.
- **Dos copias de `FabricPerfAnalyst`:** `.claude/agents/FabricPerfAnalyst.md` (Claude Code) y `.github/agents/FabricPerfAnalyst.agent.md` (GitHub Copilot, que la prefiere a la de `.claude/`). Solo difieren en el frontmatter del hook (`--format copilot`, ruta relativa) y en el host del informe; cualquier cambio en una se replica en la otra.
- **Informes:** van en `informes/AAAA-MM-DD/<nn>-<slug>.md` (`<nn>` correlativo dentro de la carpeta); cada repregunta lleva el siguiente `<nn>`; nunca se sobrescriben: rehacer la misma pregunta lleva el sufijo `-v2` (o el siguiente libre).
- **Contenido de `skills-for-fabric`:** no editar las skills de `.claude/skills/` que instala `apm install --only apm` ni los agentes copiados del paquete en `.claude/agents/` y `.github/agents/`. Las únicas excepciones son `.claude/skills/fabric-perf-analysis/` y las dos copias del agente `FabricPerfAnalyst`.

## `README.md`

README corto, en español, para quien quiere replicar el ejemplo. Secciones, en este orden:

1. **Título e introducción:** qué hace el agente, con qué hosts funciona (Claude Code, VS Code + GitHub Copilot, Copilot CLI), que usa `microsoft/skills-for-fabric` instalado con APM y los MCP de `.mcp.json`, y enlace a `AGENTS.md`.
2. **Qué añade este repositorio:** cuatro viñetas con enlaces: el agente `FabricPerfAnalyst` (las dos copias; solo diagnostica, la administración sigue en `FabricAdmin`); la skill `fabric-perf-analysis` (mapa de síntoma a área y trampas; apunta al bundle sin copiarlo y, si no coinciden, prevalece el bundle); sin cambios en Fabric (cada cambio es una recomendación; solo lanza ejecuciones de diagnóstico, Livy de solo lectura y vaciado de caché VertiPaq, y el hook, declarado solo en el agente, bloquea cualquier sentencia Livy fuera de la lista blanca); informes en español con la plantilla en `informes/AAAA-MM-DD/`. Termina enlazando este prompt.
3. **Requisitos:** tabla de herramientas con la versión usada (Claude Code o VS Code + GitHub Copilot / Copilot CLI, APM, Azure CLI, Node.js + `npx`, Git y Python, que usan el hook y algunas skills). Después, lo necesario en Fabric: cuenta de Entra con acceso a un workspace en capacidad F o trial; SKU F o P1+ con XMLA en Read Write para los modelos; y una tabla de permisos por área del agente (Spark, tablas Delta, SQL endpoint/Warehouse, modelos semánticos con los ajustes de tenant de XMLA y exportación, capacidad con la app Capacity Metrics, quién la instala y su retención), indicando que si falta alguno el agente lo anota en el informe y sigue.
4. **Instalación:** bloque bash con `apm install --only apm`, la copia de `apm_modules/microsoft/skills-for-fabric/agents/*.agent.md` a `.claude/agents/<nombre>.md` y a `.github/agents/`, y `az login` (con `--allow-no-subscriptions` si el tenant no tiene suscripción); el paso de copia también en PowerShell. Notas: por qué `--only apm` (un `apm install` sin más choca con `FabricIQ` en `.mcp.json`) y que solo se versiona la skill propia. Arranque de cada host (Claude Code: `claude`, confianza de la carpeta, `/mcp`; Copilot: enlace a su sección) y cómo probarlo con `demo-setup/` (`setup.ps1 -CapacityName`, `DEMO-SCENARIOS.md`).
5. **MCP servers:** tabla servidor · tipo · autenticación en Claude Code (`headersHelper`) · en GitHub Copilot (`Authorization: Bearer ${FABRIC_MCP_TOKEN}`), y por qué el token sale de `az` (Entra ID no admite registro dinámico de clientes OAuth; audiencia `https://api.fabric.microsoft.com`).
6. **VS Code + GitHub Copilot:** qué lee Copilot (`AGENTS.md`, skills, `.github/agents/`, `.mcp.json`) y que su copia del agente lleva `--format copilot`. Pasos numerados: instalación; cerrar todas las ventanas de VS Code y, desde el mismo terminal, exportar `FABRIC_MCP_TOKEN` con `az account get-access-token` y abrir `code .` o `copilot` (el token dura ~1 hora y no se guarda en ficheros); dar confianza a la carpeta (sin ella el agente corre sin la guarda de Livy); elegir el session target **Copilot** (en **Local** el hook falla) y comprobar los MCP; pedir el análisis o elegir el agente (`/agent FabricPerfAnalyst` en la CLI).
7. **Solución de problemas:** FabricIQ con error de registro dinámico (falta `headersHelper` o caducó `az login`); OAuth del navegador o 401 en Copilot (`FABRIC_MCP_TOKEN` ausente o caducado); "hook errored" (sin `--format copilot`, session target **Local** o sin `python`); hook que no se dispara (carpeta no confiable en cada host); servidores duplicados por el plugin `fabric-skills`; macOS sin `powerbi-modeling-mcp` local (usar el MCP alojado de Power BI Authoring).

Verifica en Microsoft Learn y en la documentación de cada host los requisitos de XMLA, FabricIQ y Capacity Metrics, la limitación de macOS y el comportamiento del hook sin confianza en la carpeta antes de escribirlos.

## Verificación

- El frontmatter de las dos copias del agente es YAML válido y declara `skills` y `hooks`, y sus cuerpos coinciden salvo el host del informe y la ruta/flag del hook.- Con `--format copilot`, el hook imprime `{}` para un comando permitido y un JSON con `permissionDecision: "deny"` para una escritura, siempre con código 0; sin el flag, bloquea con código 2.
- No existe `.claude/settings.json`, `.github/hooks/` ni `.github/copilot/settings.json` con el hook, y la sesión principal puede ejecutar comandos que contengan una URL de sentencias Livy sin que nada la bloquee.
- Ningún archivo del agente, la skill, `CLAUDE.md` o el README habla de pedir confirmación antes de una acción de nivel B.

## `assets/informe-analisis.md` (copiar literal)

Crea el archivo con exactamente este contenido, sin las líneas de apertura y cierre del bloque de 5 backticks:

`````markdown
# <Título del análisis>

<!--
Instrucciones de uso (borrar todos los comentarios al rellenar):
- Mantener todas las secciones y su orden. Si una sección no tiene contenido, escribir "Sin datos" y explicar el motivo en Notas.
- Identificadores: E# para evidencias, H# para hallazgos, R# para recomendaciones, D# para hipótesis descartadas. Cada hallazgo cita sus E#; cada recomendación cita sus H#.
- Severidad: Alta | Media | Baja, según los criterios de las referencias de la skill, citando la referencia usada.
- Confianza: Alta (medido directamente) | Media (medido de forma parcial o indirecta) | Baja (inferido de datos incompletos).
- Sin tokens, cabeceras Authorization ni cadenas de conexión. Llamadas REST como método + ruta.
- Cifras solo si las devolvió una consulta o llamada registrada en Evidencia.
-->

| Campo | Valor |
|-------|-------|
| **Fecha** | AAAA-MM-DD |
| **Áreas** | <áreas de análisis recorridas, en orden> |
| **Ámbito** | workspace `<WORKSPACE>` · <items analizados> |
| **Ventana analizada** | <AAAA-MM-DD HH:MM> → <AAAA-MM-DD HH:MM> UTC |
| **Agente / host** | Claude Code \| GitHub Copilot (VS Code) \| GitHub Copilot CLI · skills: <skills usadas> |
| **Modo** | Solo lectura \| Lectura + diagnóstico activo (<Livy, ClearCache>) |
| **Severidad global** | Alta \| Media \| Baja |
| **Confianza global** | Alta \| Media \| Baja |

## Resumen

<!-- 3-5 líneas para quien solo lea esto. -->

- **Pregunta:** <qué se preguntó, en una frase>
- **Conclusión:** <causa principal encontrada>
- **Impacto:** <efecto medido: duración, CU, coste, usuarios afectados>
- **Primera acción:** <R# más prioritaria y qué se espera de ella>

## Alcance

**Pregunta original:** <texto literal de la petición>

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| <items, capas, ventana> | <lo que no se analizó y por qué> |

**Hipótesis de partida:** <hipótesis iniciales y de qué síntomas salen>

**Recorrido:** <áreas visitadas y qué evidencia motivó cada cambio de área>

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad (SKU · región) | | |
| Runtime de Spark | | |
| Environment / pool | | |
| Configuración Spark relevante | | |
| Modo de almacenamiento del modelo | | |
| Permisos con los que se ejecutó | | |

<!-- Dejar solo las filas aplicables. -->

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| | | | |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| | | | E1 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces/{ws}/...` | <cifras devueltas> |
| E2 | SQL | `SELECT ...` (completa en el Anexo si es larga) | |
| E3 | DAX | `EVALUATE ...` | |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | | Alta \| Media \| Baja | Alta \| Media \| Baja | E1, E2 |

### H1 · <Título del hallazgo>

- **Qué ocurre:** <descripción con cifras>
- **Por qué:** <causa raíz, citando evidencia>
- **Impacto:** <efecto en duración, coste, usuarios o datos>

<!-- Repetir el bloque para cada hallazgo con severidad Alta o Media. -->

## Recomendaciones

<!-- Ordenadas por impacto/esfuerzo: primero las de alto impacto y bajo esfuerzo. -->

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | | H1 | Alto \| Medio \| Bajo | Alto \| Medio \| Bajo | Alto \| Medio \| Bajo | Sí \| No |

### R1 · <Recomendación>

- **Cambio propuesto:**

  ```python
  # código o configuración concreta
  ```

- **Impacto esperado:** <mejora estimada y en qué se basa>
- **Cómo validarlo:** <métrica, consulta o llamada que se repetirá para medir el antes/después>
- **Reversión:** <cómo deshacer el cambio>
- **Requiere confirmación:** Sí | No — <motivo: escritura, coste, afecta a otros usuarios>

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | | E# | |

## Siguientes pasos

- [ ] <acción> — responsable: <rol> · relacionado con: R#
- [ ] Repetir el análisis tras aplicar R# para validar el impacto

## Notas

### Limitaciones

<!-- Permisos ausentes, retención de datos agotada, MCP no disponible, ventana incompleta. -->

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| | | |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| | | | |

## Anexo

### Consultas completas

<!-- SQL, DAX o cuerpos de llamadas demasiado largos para la tabla de Evidencia, con su E#. -->

### Configuración efectiva

<!-- Volcado de la configuración relevante (environment, %%configure, propiedades del modelo), si aporta. -->
`````
