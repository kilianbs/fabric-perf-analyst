> Prompt usado para generar `.claude/agents/FabricPerfAnalyst.md`, `.claude/skills/fabric-perf-analysis/`
> y el hook `.claude/hooks/livy_readonly_guard.py`. Requiere `apm install --only apm` previo.

# Tarea: construir el agente FabricPerfAnalyst y su skill de análisis

Construye en este repositorio un agente de Claude Code que diagnostique el rendimiento de Microsoft Fabric (Spark, tablas Delta, SQL endpoint/Warehouse, modelos semánticos y capacidad) y genere un informe Markdown en español con una plantilla fija. Nunca cambia items, datos, definiciones, programaciones ni capacidad. Las ejecuciones de diagnóstico que consumen CU o afectan a otros usuarios (sentencias Livy de solo lectura como `DESCRIBE DETAIL`, limpieza de la caché VertiPaq) las ejecuta él mismo, sin pedir confirmación, dentro de un presupuesto fijo y detrás de un hook que bloquea cualquier escritura por Livy.

El conocimiento técnico ya está en las skills de `microsoft/skills-for-fabric`. Lo que construyes es una capa delgada de navegación encima: método de diagnóstico, mapa de síntomas a áreas, trampas conocidas y formato de salida. **No dupliques umbrales, rutas REST ni procedimientos de las skills: apunta a ellos.**

Todo lo que añadas solo aplica dentro de `FabricPerfAnalyst`. La sesión principal y los demás agentes y skills de `skills-for-fabric` (por ejemplo `FabricDataEngineer`) tienen que seguir funcionando como en el paquete: no cargan la skill nueva, no quedan sujetos al hook y pueden ejecutar notebooks, jobs o sentencias Spark según sus propias skills.

## Antes de escribir nada

1. Comprueba que existen las skills de `microsoft/skills-for-fabric` en `.claude/skills/`. Si faltan, para y dime que las instale con `apm install --only apm` (un `apm install` sin `--only apm` intenta escribir los MCP del paquete en `.mcp.json` y se detiene por el conflicto con `FabricIQ`).
2. Revisa `.mcp.json`: hacen falta `fabric-sqlendpoint` (remoto), `FabricIQ` (remoto, con `headersHelper` que use `az account get-access-token --resource https://api.fabric.microsoft.com`) y `powerbi-modeling-mcp` (local vía `npx`). Si falta alguno, avísame; no lo añadas sin preguntar.
3. Lee los agentes existentes en `.claude/agents/` para seguir su formato de frontmatter. No modifiques los que vienen de fabric-skills (son copias de `agents/*.agent.md` del paquete; APM no despliega agentes de un skill bundle). Verifica en la documentación de Claude Code:
   - que el campo `skills:` del frontmatter de subagentes precarga una skill (y que una skill con `disable-model-invocation: true` no se puede precargar);
   - que el campo `hooks:` del frontmatter de un subagente solo se ejecuta mientras corre ese subagente, a diferencia de los hooks de `.claude/settings.json`, que aplican a toda la sesión y a todos los agentes;
   - en qué condiciones se ejecutan los hooks del frontmatter de un agente de proyecto (diálogo de confianza del workspace).
4. Comprueba cómo trata APM los directorios de `.claude/skills/` que no gestiona (`apm install`, `apm prune` o equivalente). Si existe riesgo de que borre o sobrescriba una skill propia, para y propónme una ubicación alternativa antes de crearla.
5. Lee las referencias de las skills relevantes para cada área (delega en un explorador de solo lectura si superan el presupuesto de contexto). Cada referencia que cites tiene que existir. Las rutas REST que no estén en las skills se verifican en Microsoft Learn.
6. Lee en `spark-cli` cómo se envían sentencias a una sesión Livy (forma del cuerpo, URL con variables, `az rest --body @<fichero>`): el hook tiene que aceptar esa forma tal cual.

## Archivos a crear o modificar

| Archivo | Idioma | Lector |
|---------|--------|--------|
| `.claude/agents/FabricPerfAnalyst.md` | Inglés (como el resto de agentes) | Agente |
| `.claude/skills/fabric-perf-analysis/SKILL.md` | Inglés | Agente |
| `.claude/skills/fabric-perf-analysis/references/*.md` | Inglés | Agente |
| `.claude/skills/fabric-perf-analysis/assets/informe-analisis.md` | Español (literal, ver abajo) | Agente |
| `.claude/hooks/livy_readonly_guard.py` | Inglés (código y mensajes) | Claude Code |
| `CLAUDE.md` | Español neutro | Personas y sesión principal |
| `README.md` (ampliar la sección existente de requisitos) | El idioma actual del README | Personas |

No crees `.claude/settings.json` ni registres el hook en él.

Los informes se generarán en `informes/AAAA-MM-DD/<nn>-<slug>.md`. Esa carpeta no se crea ahora.

## Agente `.claude/agents/FabricPerfAnalyst.md`

Contiene solo el rol, la navegación, los niveles de acción, el flujo, los guardrails y la salida. **No contiene una tabla de casos.**

- **Frontmatter:**
  - `name: FabricPerfAnalyst` y `skills: [fabric-perf-analysis]`.
  - `hooks:` con un `PreToolUse` cuyo `matcher` es `"Bash|PowerShell"` y que ejecuta `python "$CLAUDE_PROJECT_DIR/.claude/hooks/livy_readonly_guard.py"`. Así el hook solo corre dentro de este agente.
  - Una `description` que:
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
  1. **Scope:** resolver workspace, items y ventana temporal (UTC), descubriendo los IDs (listar y filtrar). Si el workspace es desconocido y no se puede descubrir, parar y devolver una sola pregunta.
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
  - Cabecera: host `Claude Code` más las skills usadas, ventana en UTC, modo `Solo lectura` si no se ejecutó ninguna acción B o `Lectura + diagnóstico activo (<Livy, ClearCache>)` nombrando las acciones B ejecutadas, severidad global igual a la del hallazgo más grave.
  - Trazabilidad `E#`, `H#`, `R#`, `D#`: cada hallazgo cita al menos una E#, y cada recomendación cita su H# y explica cómo validarla.
  - Severidad `Alta`, `Media` o `Baja` según los criterios de las referencias de la skill. Confianza `Alta` (medido directamente), `Media` (medición parcial o indirecta) o `Baja` (inferido).
  - Guardar en `informes/AAAA-MM-DD/<nn>-<slug>.md`, una carpeta por día de análisis (creada si falta). `<nn>` = el número de dos cifras más alto ya usado en esa carpeta, sea cual sea el slug, más uno; listar la carpeta justo antes de escribir, no al empezar, porque otros análisis pueden haber guardado informes entretanto. Para citar otro informe, ruta relativa a `informes/` (por ejemplo `2026-10-29/03-nb02-skew-shuffle.md`). Nunca sobrescribir un informe existente: sufijo `-v2` (o el siguiente libre).
  - Respuesta final: la ruta del informe y su sección Resumen.

## Hook `.claude/hooks/livy_readonly_guard.py`

Hook `PreToolUse` en Python con la biblioteca estándar, declarado solo en el frontmatter del agente. Es el límite determinista que respalda la autonomía del nivel B. Es una **lista blanca**, no una lista negra de palabras clave (una lista negra se salta con facilidad). El docstring explica qué hace y que solo corre dentro de `FabricPerfAnalyst`.

- **Entrada y salida:** lee de stdin el JSON de Claude Code (`tool_name`, `tool_input.command`, `cwd`). Código de salida 2 con un mensaje en stderr para bloquear; 0 para permitir. El mensaje de bloqueo indica el motivo y recuerda la forma permitida, que un bloqueo es definitivo y que una lectura bloqueada se simplifica o se anota en Notas › Datos no obtenidos.
- **Qué no toca:** herramientas distintas de `Bash` y `PowerShell`; comandos sin una URL `/sessions/<id>/statements`; `GET` (sondeo y listado) y `DELETE` sobre esa URL, y el `POST` sin cuerpo a `.../statements/<n>/cancel`. Si el JSON de entrada no es válido, bloquea solo cuando el texto contiene "statements".
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
| `spark-runs.md` | Pipeline cada día más lento · Data skew y shuffle · Fallos de Spark y OOM | spark-cli operations (pipeline-diagnosis, job-diagnostics, automated-diagnostic-workflow, diagnostic-workflow, performance-patterns, spark-history-server, jobinsight-api); `common/SPARK-MONITORING-CORE.md`; sqldw-cli consumption | Criterio de regresión frente a ejecuciones anteriores. Cola = inicio de la actividad frente a `runStartTime`. Tendencias desde jobs/instances porque stages/advice y queryactivityruns caducan antes. `/advice` antes que `/stages`; criterio de selección de stages y Tier 2. No decodificar la definición de notebooks salvo petición. Las sesiones HC agregan métricas. Separar fallo de código y de infraestructura. Las sentencias Livy cuestan CU: dentro del presupuesto de nivel B y nunca keep-alives. `copyEventLog` de Job Insight escribe. |
| `spark-resources.md` | Clúster sobredimensionado · Config de Spark por capa · Salud de sesiones Spark y colas | spark-cli operations (diagnostic-workflow, performance-patterns, session-health); spark-cli authoring/resources/data-engineering-patterns (lectura); e2e-medallion-architecture; e2e-fabric-cost-estimation | Umbrales de `coreEfficiency` e `idleTime`. Equivalencia CU/vCores. Cifras en moneda solo con la Retail Prices API en vivo y la región. NEE no fiable con `spark.conf.set` a mitad de sesión. Perfil `readHeavyForPBI`. Sesión sin `appId` tras un tiempo = espera de capacidad. **Contradicciones a documentar:** clave de V-Order (`spark.sql.parquet.vorder.default` frente a `spark.microsoft.delta.parquet.vorder.enabled`) y optimize write en Gold. |
| `delta-tables.md` | Mantenimiento de tablas Delta | sqldw-cli operations: lakehouse-health; spark-cli operations; spark-cli mlv | `itemId` = `sqlEndpointProperties.id`. `sp_get_table_health_metrics` solo devuelve la anomalía más grave y una llamada fallida es "No evaluada". Límite de peticiones. `DESCRIBE DETAIL` solo por Livy (nivel B, consume CU), dentro del presupuesto del agente. MLV: sin OData, `Deduped` no es un fallo, `DeltaTableVersionNotFound` apunta a VACUUM. |
| `semantic-models.md` | Buenas prácticas de modelado · Rendimiento DAX · Refrescos de modelos semánticos | semantic-model-authoring (Analyze Best Practices, Optimize DAX, semantic-model-rest-api, dax-perf-*, direct-lake-guidelines) | Permisos Write frente a Build (`INFO.VIEW.*`). Medidas en bloque `DEFINE`, sin tocar el modelo. Protocolo de medición (caché, calentamiento, repeticiones, dispersión). Routing DAX/DL. El fallback de Direct Lake se verifica en Learn. Ante un error de credenciales en refrescos, parar. POST, DELETE y PATCH son escrituras salvo `getDefinition` y `executeQueries`. La limpieza de caché (XMLA `ClearCache`) actúa sobre toda la base de datos y afecta a todos los usuarios: se ejecuta como nivel B sin pedir confirmación, solo entre ejecuciones del benchmark, registrando cada limpieza con su hora UTC; no va en la lista de escrituras. |
| `capacity.md` | Picos de CU y throttling | sqldw-cli operations: capacity-metrics-correlation; fabriciq | CU alto no es presión por sí solo. `CapacitiesList`. No unir Operation Id con `distributed_statement_id`. Capacity Metrics guarda una ventana limitada. |
| `sql-endpoint.md` | — (sin escenario en `demo-setup/`, sí del agente) | sqldw-cli operations (scenarios, query-reference, resource-consumers, pool-pressure, failure-analysis) | queryinsights requiere Contributor. La presión del pool solo correlaciona. Clustering solo por predicados `WHERE`. No recomendar result-set caching. |

## `CLAUDE.md`

Corto, con reglas del repositorio:
- Propósito del repo (ejemplo replicable) y enlace al README.
- **Análisis de rendimiento:** se delegan en `FabricPerfAnalyst`; la administración (permisos, capacidad, gobierno) corresponde a `FabricAdmin`.
- **Sin cambios en Fabric desde `FabricPerfAnalyst`:** el agente nunca crea, modifica, borra, refresca, programa o mantiene items de un workspace, ni ejecuta notebooks, jobs o pipelines; esos cambios los deja como recomendaciones. La regla no aplica a la sesión principal ni a los demás agentes, que siguen las reglas de sus skills de `skills-for-fabric`.
- **Ejecuciones de diagnóstico:** las de `FabricPerfAnalyst` (una sesión Livy propia con sentencias que no escriben, como `DESCRIBE DETAIL`, y `ClearCache` para medir DAX en frío) no son cambios: el agente las ejecuta sin pedir confirmación aunque consuman CU o afecten a otros usuarios. El hook `.claude/hooks/livy_readonly_guard.py`, declarado en el frontmatter del agente, solo deja pasar sentencias Livy de la lista blanca de lectura mientras corre ese agente.
- **Aislamiento:** lo que añade el repositorio (agente, skill y hook) solo aplica dentro de `FabricPerfAnalyst`. La sesión principal y los demás agentes y skills de `skills-for-fabric` funcionan como en el paquete: no cargan esa skill ni quedan sujetos a ese hook. No registrar el hook en `.claude/settings.json`.
- **Informes:** van en `informes/AAAA-MM-DD/<nn>-<slug>.md` (`<nn>` correlativo dentro de la carpeta); nunca se sobrescriben (sufijo `-v2` o el siguiente libre).
- **Contenido de `skills-for-fabric`:** no editar las skills de `.claude/skills/` que instala `apm install --only apm` ni los agentes copiados del paquete. Las únicas excepciones son `.claude/skills/fabric-perf-analysis/` y `.claude/agents/FabricPerfAnalyst.md`.

## `README.md`

Añade una sección que compare el bundle `skills-for-fabric` con lo que aporta este repositorio (alcance, agentes, routing, escrituras y ejecuciones de diagnóstico, trampas conocidas, evidencia, salida). En la fila de escrituras explica que el agente nunca cambia items, datos ni definiciones (cada cambio es una recomendación "Requiere confirmación"), que ejecuta por su cuenta las dos ejecuciones de diagnóstico (Livy de solo lectura, una sesión por análisis borrada al terminar; `ClearCache`, que afecta a todos los usuarios del modelo) y que el hook, declarado en el frontmatter del agente, solo corre dentro de `FabricPerfAnalyst` y no afecta a la sesión principal ni a los agentes del bundle.

Amplía la sección existente de requisitos (no la reescribas) con lo que hoy no recoge:
- **Python** en la tabla de herramientas: lo usan algunas skills de Fabric y el hook de Livy.
- **Autenticación:** `--allow-no-subscriptions` y audiencias de token.
- **Capacidad:** SKU F o trial, o P1+ para los modelos; XMLA en Read Write; región compatible con FabricIQ.
- **Configuración del tenant y permisos del usuario**, indicando qué área del agente los necesita.
- **Capacity Metrics:** instalarla requiere ser administrador de capacidad y licencia Power BI; conviene un workspace Pro; retención.
- **Limitaciones conocidas:** el MCP local no funciona en macOS (verifícalo); los hooks del frontmatter de un agente de proyecto solo se ejecutan tras aceptar el diálogo de confianza del workspace, y hasta entonces el agente corre sin el hook (verifícalo).
- **Comprobación rápida:** `az account show`, `az rest` a `/v1/workspaces`, `node --version`, `apm install --only apm`, `/mcp`.

Verifica en Microsoft Learn los requisitos de XMLA, FabricIQ y Capacity Metrics antes de escribirlos.

## Verificación

- El frontmatter del agente es YAML válido y declara `skills` y `hooks`.
- No existe `.claude/settings.json` con el hook, y la sesión principal puede ejecutar comandos que contengan una URL de sentencias Livy sin que nada la bloquee.
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
| **Agente / host** | Claude Code \| GitHub Copilot CLI · skills: <skills usadas> |
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
