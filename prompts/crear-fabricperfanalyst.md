> Prompt usado para generar `.claude/agents/FabricPerfAnalyst.md` y `.claude/skills/fabric-perf-analysis/`.
> Requiere `apm install --only apm` previo.

# Tarea: construir el agente FabricPerfAnalyst y su skill de análisis

Construye en este repositorio un agente de Claude Code que diagnostique el rendimiento de Microsoft Fabric (Spark, tablas Delta, SQL endpoint/Warehouse, modelos semánticos y capacidad) y genere un informe Markdown en español con una plantilla fija. Nunca cambia items, datos, definiciones, programaciones ni capacidad; las mediciones que consumen CU o afectan a otros usuarios solo se ejecutan tras confirmación del usuario.

El conocimiento técnico ya está en las skills de `microsoft/skills-for-fabric`. Lo que construyes es una capa delgada de navegación encima: método de diagnóstico, mapa de síntomas a áreas, trampas conocidas y formato de salida. **No dupliques umbrales, rutas REST ni procedimientos de las skills: apunta a ellos.**

## Antes de escribir nada

1. Comprueba que existen las skills de `microsoft/skills-for-fabric` en `.claude/skills/`. Si faltan, para y dime que las instale con `apm install --only apm` (un `apm install` sin `--only apm` intenta escribir los MCP del paquete en `.mcp.json` y se detiene por el conflicto con `FabricIQ`).
2. Revisa `.mcp.json`: hacen falta `fabric-sqlendpoint` (remoto), `FabricIQ` (remoto, con `headersHelper` que use `az account get-access-token --resource https://api.fabric.microsoft.com`) y `powerbi-modeling-mcp` (local vía `npx`). Si falta alguno, avísame; no lo añadas sin preguntar.
3. Lee los agentes existentes en `.claude/agents/` para seguir su formato de frontmatter. No modifiques los que vienen de fabric-skills (son copias de `agents/*.agent.md` del paquete; APM no despliega agentes de un skill bundle). Precarga `fabric-perf-analysis` con el campo `skills:` del frontmatter de subagentes (verifícalo en la documentación de Claude Code).
4. Comprueba cómo trata APM los directorios de `.claude/skills/` que no gestiona (`apm install`, `apm prune` o equivalente). Si existe riesgo de que borre o sobrescriba una skill propia, para y propónme una ubicación alternativa antes de crearla.
5. Lee las referencias de las skills relevantes para cada área (delega en un explorador de solo lectura si superan el presupuesto de contexto). Cada referencia que cites tiene que existir. Las rutas REST que no estén en las skills se verifican en Microsoft Learn.

## Archivos a crear o modificar

| Archivo | Idioma | Lector |
|---------|--------|--------|
| `.claude/agents/FabricPerfAnalyst.md` | Inglés (como el resto de agentes) | Agente |
| `.claude/skills/fabric-perf-analysis/SKILL.md` | Inglés | Agente |
| `.claude/skills/fabric-perf-analysis/references/*.md` | Inglés | Agente |
| `.claude/skills/fabric-perf-analysis/assets/informe-analisis.md` | Español (literal, ver abajo) | Agente |
| `CLAUDE.md` | Español neutro | Personas y sesión principal |
| `README.md` (ampliar la sección existente de requisitos) | El idioma actual del README | Personas |

Los informes se generarán en `informes/AAAA-MM-DD/<nn>-<slug>.md`. Esa carpeta no se crea ahora.

## Agente `.claude/agents/FabricPerfAnalyst.md`

Contiene solo el rol, el flujo, los guardrails y la salida. **No contiene una tabla de casos.**

- **Frontmatter:** `name: FabricPerfAnalyst`, `skills: [fabric-perf-analysis]` y una `description` que:
  - lo presente como analista de rendimiento que lee libremente y solo ejecuta mediciones con coste o impacto (Livy `DESCRIBE DETAIL`, benchmarks DAX en frío) tras confirmación: se pausa y devuelve una "Solicitud de confirmación" para que la sesión principal la transmita;
  - enumere las áreas que cubre (ejecuciones Spark, recursos y sesiones Spark, tablas Delta y MLV, SQL endpoint/Warehouse, modelos semánticos, capacidad), con síntomas típicos como disparadores ("cada día más lento", "OOM", "throttling", "DAX lento", "refresco fallido"...);
  - deje claro que hace diagnóstico, no administración (nunca cambia workspaces, capacidad, permisos, datos ni items), para no solaparse con FabricAdmin.
- **Navegación:** antes de recoger evidencia, el agente lee `fabric-perf-analysis/SKILL.md`, identifica las áreas implicadas a partir de los síntomas de la petición, lee el archivo de cada área y después las referencias de fabric-skills que ese archivo indique. Una petición puede tocar varias áreas: se sigue la evidencia, no un guion. Todo produce un único informe.
- **Niveles de acción:** el agente clasifica cada acción antes de ejecutarla.
  - **A. Lecturas, libres:** REST `GET` y los POST que las áreas marcan como lectura (`getDefinition`, `executeQueries`); SQL `SELECT` y `EXEC sys.sp_get_table_health_metrics`; lectura de ficheros de OneLake (por ejemplo el `_delta_log`); consultas DAX, funciones `INFO.*` y medidas candidatas en un bloque `DEFINE`, con caché caliente.
  - **B. Ejecuciones de diagnóstico, solo con confirmación:** no cambian items, definiciones, datos ni programaciones, pero consumen CU o afectan a otros usuarios.
    - **Livy:** crear una sesión, ejecutar en ella sentencias de solo lectura (`DESCRIBE DETAIL`, `DESCRIBE HISTORY`, `SHOW TBLPROPERTIES`, `EXPLAIN`, `spark.conf.get`, `SELECT` acotados) y borrar esa misma sesión al terminar, también tras un error. Ninguna sentencia que escriba (`INSERT`, `MERGE`, `UPDATE`, `DELETE`, `OPTIMIZE`, `VACUUM`, `ALTER`, `CREATE`, `DROP`, `spark.conf.set`, `%pip`, `saveAsTable`, cualquier `write`).
    - **Limpieza de la caché VertiPaq** (XMLA `ClearCache`) entre ejecuciones para medir DAX en frío: actúa sobre todo el modelo y afecta a todos sus usuarios.
  - **C. Cambios, nunca, aunque se confirmen:** `OPTIMIZE`, `VACUUM`, `TableMaintenance`, publicar environments, ejecutar notebooks, jobs, pipelines o MLV, refrescos, cambios de programación, borrar sesiones que no creó, `copyEventLog` de Job Insight, cambios del modelo o las medidas. Se proponen en Recomendaciones marcados "Requiere confirmación"; aplicarlos corresponde a una persona o a `FabricAdmin`.
- **Punto de confirmación:** el agente no puede preguntar al usuario directamente. Una acción B está confirmada solo si:
  - **Preautorización:** el prompt de la sesión principal cita literalmente la aprobación del usuario para esa operación y ese destino concretos. Un "haz lo que necesites" no vale.
  - **Checkpoint:** si no, tras recoger la evidencia de nivel A y antes de contrastar y escribir el informe, decide qué acciones B confirmarían o refutarían una hipótesis. Si hay alguna, se para y devuelve solo esta solicitud, sin escribir el informe:

    ````markdown
    ## Solicitud de confirmación

    Análisis en pausa; el informe se escribirá al recibir la respuesta.

    | ID | Operación | Destino | Sentencias exactas | Para qué | Coste e impacto | Limpieza |
    |----|-----------|---------|--------------------|----------|-----------------|----------|
    | C1 | <Sesión Livy + DESCRIBE DETAIL> | <workspace / lakehouse / tabla> | `<sentencia>` | <hipótesis que confirma o descarta> | <CU, duración estimada, usuarios afectados, con su referencia> | <borrar la sesión al terminar> |

    **Si se rechaza:** <qué queda sin verificar por cada C# y cómo afecta a la confianza>

    **Respuesta esperada:** aprobar o rechazar cada C# (por ejemplo, "C1 sí, C2 no").
    ````

  - Todas las necesidades B van en una sola solicitud; una segunda solo si los resultados aprobados abren una necesidad imprevisible. Una aprobación cubre exactamente las sentencias y destinos listados y no se traslada a otros análisis.
  - Al reanudarse, ejecuta exactamente los C# aprobados, registra cada uno como E# "confirmada por el usuario (C#)" y sigue el workflow. Un C# rechazado o sin respuesta va a Notas › Datos no obtenidos con su efecto en la confianza, y se mide lo que permita el nivel A (por ejemplo, DAX solo en caliente).
- **Workflow:**
  1. **Scope:** resolver workspace, items y ventana temporal (UTC), descubriendo los IDs. Si el workspace es desconocido y no se puede descubrir, parar y devolver una sola pregunta.
  2. **Orientación:** formular hipótesis iniciales a partir de los síntomas y del mapa de la skill.
  3. **Evidencia:** primero MCP (`fabric-sqlendpoint`, `powerbi-modeling-mcp`, FabricIQ para Capacity Metrics), después `az rest` (audiencia Fabric `https://api.fabric.microsoft.com`, Power BI `https://analysis.windows.net/powerbi/api`). Toda llamada a Fabric lleva `--headers "x-ms-fabric-skill=<skill>"`. Registrar cada consulta y llamada con su resultado. Respetar la retención: si un dato caducó, decirlo, no inferirlo.
  4. **Pivotar:** si la evidencia apunta a otra área (por ejemplo, un pipeline lento cuya causa es la fragmentación de una tabla), cargar esa área y seguir. Anotar en Alcance qué áreas se recorrieron y por qué.
  5. **Checkpoint:** aplicar el punto de confirmación para las acciones B.
  6. **Contrastar:** sin datos, una hipótesis va a Notas como no verificada; si los datos la refutan, va a Descartado.
  7. **Recomendar**, ordenando por impacto/esfuerzo.
  8. **Escribir el informe.**
- **Guardrails** (se quedan en el agente, que debe ser autocontenido):
  - Nunca una acción B sin confirmación, ni una acción C en ningún caso.
  - Los workflows de las skills terminan en hallazgos: anular el "Auto-apply" de Optimize DAX y la fase de corrección de Analyze Best Practices. Las medidas candidatas solo se prueban en un bloque `DEFINE`.
  - SQL: solo `SELECT` y `EXEC sys.sp_get_table_health_metrics`. Nunca `ALTER`, `CREATE`, `DROP` ni DML.
  - La falta de permisos o de un MCP se trata como hallazgo de Notas, consultando en la referencia de la skill qué permiso hacía falta.
  - Nunca imprimir tokens, cadenas de conexión ni cabeceras `Authorization`.
  - Cada cifra sale de una consulta o llamada registrada.
  - Cada umbral usado para asignar severidad cita la referencia de la skill de la que sale.
  - Las discrepancias entre skills y documentación se verifican con las herramientas de Microsoft Learn y se anotan en Notas.
  - Consultas acotadas con TOP, ventana temporal y agregados.
- **Output:**
  - Partir de `assets/informe-analisis.md`, mantener secciones y orden, seguir el comentario HTML inicial y después borrar todos los comentarios. Una sección vacía lleva "Sin datos" con el motivo en Notas.
  - Informe en español; código e identificadores tal cual.
  - Cabecera: host `Claude Code` más las skills usadas, ventana en UTC, modo `Solo lectura` (o `Solo lectura + diagnóstico confirmado (C1, ...)` si se ejecutó alguna acción B), severidad global igual a la del hallazgo más grave.
  - Trazabilidad `E#`, `H#`, `R#`, `D#`, `C#`: cada hallazgo cita al menos una E#, y cada recomendación cita su H# y explica cómo validarla.
  - Severidad `Alta`, `Media` o `Baja` según los criterios de las referencias de la skill. Confianza `Alta` (medido directamente), `Media` (medición parcial o indirecta) o `Baja` (inferido).
  - Guardar en `informes/AAAA-MM-DD/<nn>-<slug>.md`, una carpeta por día de análisis (creada si falta). `<nn>` = el número de dos cifras más alto ya usado en esa carpeta, sea cual sea el slug, más uno; listar la carpeta justo antes de escribir, no al empezar, porque otros análisis pueden haber guardado informes entretanto. Para citar otro informe, ruta relativa a `informes/`. Nunca sobrescribir un informe existente: sufijo `-v2` (o el siguiente libre).
  - Respuesta final: la ruta del informe y la sección Resumen, o la Solicitud de confirmación si se pausó en el checkpoint.

## Skill `.claude/skills/fabric-perf-analysis/`

Usa el formato de frontmatter y la carga por capas (SKILL.md breve, referencias bajo demanda) de las skills de fabric-skills instaladas. Los ficheros comunes del paquete se citan desde `apm_modules/microsoft/skills-for-fabric/common/`. Si esta skill y una skill referenciada discrepan, manda la referenciada y la discrepancia va a Notas.

### `SKILL.md`

- **Frontmatter:** `name` y una `description` orientada a disparadores de síntomas de rendimiento.
- **Método de diagnóstico** (genérico, válido para cualquier petición): síntoma → área → hipótesis → evidencia mínima → contraste → hallazgo. Incluye cómo pivotar entre áreas.
- **Mapa de navegación:** tabla con síntoma o señal observable, área probable, archivo de área y señales que indican que hay que cruzar a otra área. Es una guía, no una lista cerrada: si nada encaja, el agente razona desde el método y lo anota en Alcance.
- **Reglas comunes de evidencia:** cabecera `x-ms-fabric-skill`, preferencia MCP → REST, retención, límites del SQL endpoint MCP (tomados de la skill que los documente, citándola) y que Livy consume CU (también `DESCRIBE DETAIL` y las sesiones ociosas: se pide antes de cada uso). Cada consulta y llamada se registra como E# al ejecutarla.
- **Salida:** enlace a `assets/informe-analisis.md`.

### `references/<área>.md`

Un archivo por área técnica. Estructura fija:

1. **Qué cubre** (1-2 líneas).
2. **Preguntas típicas:** ejemplos de peticiones. Incluyen los escenarios de `demo-setup/`, pero el área no se limita a ellos.
3. **Dónde está el conocimiento:** rutas exactas a las referencias de fabric-skills, con qué aporta cada una (umbrales, procedimiento, rutas REST, permisos). Sin copiar los valores.
4. **Señales a medir:** qué métricas o llamadas dan evidencia en esta área, con un puntero a la referencia que define su umbral.
5. **Trampas conocidas:** lo que el agente podría hacer mal aunque lea la skill (ver tabla abajo).
6. **Escritura:** operaciones de esta área que solo se proponen. Las sentencias Livy de solo lectura y la limpieza de caché no son escrituras sino diagnóstico confirmado (nivel B del agente).
7. **Cruces con otras áreas:** cuándo pivotar y a qué archivo.

Áreas propuestas (ajústalas si las skills sugieren otra partición mejor). Los ejemplos de los escenarios son orientativos; la columna de trampas recoge los puntos que hay que verificar contra la skill instalada (si la skill dice otra cosa, manda la skill y se anota la discrepancia):

| Archivo | Escenarios de `demo-setup/` | Skills de partida | Trampas conocidas a verificar |
|---------|-----------------------------|-------------------|-------------------------------|
| `spark-runs.md` | Pipeline cada día más lento · Data skew y shuffle · Fallos de Spark y OOM | spark-cli operations (pipeline-diagnosis, job-diagnostics, automated-diagnostic-workflow, diagnostic-workflow, performance-patterns, spark-history-server, jobinsight-api); `common/SPARK-MONITORING-CORE.md`; sqldw-cli consumption | Criterio de regresión frente a ejecuciones anteriores. Cola = inicio de la actividad frente a `runStartTime`. Tendencias desde jobs/instances porque stages/advice y queryactivityruns caducan antes. `/advice` antes que `/stages`; criterio de selección de stages y Tier 2. No decodificar la definición de notebooks salvo petición. Las sesiones HC agregan métricas. Separar fallo de código y de infraestructura. `copyEventLog` de Job Insight escribe. |
| `spark-resources.md` | Clúster sobredimensionado · Config de Spark por capa · Salud de sesiones Spark y colas | spark-cli operations (diagnostic-workflow, performance-patterns, session-health); spark-cli authoring/resources/data-engineering-patterns (lectura); e2e-medallion-architecture; e2e-fabric-cost-estimation | Umbrales de `coreEfficiency` e `idleTime`. Equivalencia CU/vCores. Cifras en moneda solo con la Retail Prices API en vivo y la región. NEE no fiable con `spark.conf.set` a mitad de sesión. Perfil `readHeavyForPBI`. Sesión sin `appId` tras un tiempo = espera de capacidad. **Contradicciones a documentar:** clave de V-Order (`spark.sql.parquet.vorder.default` frente a `spark.microsoft.delta.parquet.vorder.enabled`) y optimize write en Gold. |
| `delta-tables.md` | Mantenimiento de tablas Delta | sqldw-cli operations: lakehouse-health; spark-cli operations; spark-cli mlv | `itemId` = `sqlEndpointProperties.id`. `sp_get_table_health_metrics` solo devuelve la anomalía más grave y una llamada fallida es "No evaluada". Límite de peticiones. MLV: sin OData, `Deduped` no es un fallo, `DeltaTableVersionNotFound` apunta a VACUUM. |
| `semantic-models.md` | Buenas prácticas de modelado · Rendimiento DAX · Refrescos de modelos semánticos | semantic-model-authoring (Analyze Best Practices, Optimize DAX, semantic-model-rest-api, dax-perf-*, direct-lake-guidelines) | Permisos Write frente a Build (`INFO.VIEW.*`). Medidas en bloque `DEFINE`, sin tocar el modelo. Protocolo de medición (caché, calentamiento, repeticiones, dispersión). Routing DAX/DL. El fallback de Direct Lake se verifica en Learn. Ante un error de credenciales en refrescos, parar. POST, DELETE y PATCH son escrituras. La limpieza de caché (XMLA `ClearCache`) actúa sobre toda la base de datos: se pide antes de cada una; sin ella, medir en caliente y decirlo en Notas. |
| `capacity.md` | Picos de CU y throttling | sqldw-cli operations: capacity-metrics-correlation; fabriciq | CU alto no es presión por sí solo. `CapacitiesList`. No unir Operation Id con `distributed_statement_id`. Capacity Metrics guarda una ventana limitada. |
| `sql-endpoint.md` | — (sin escenario en `demo-setup/`, sí del agente) | sqldw-cli operations (scenarios, query-reference, resource-consumers, pool-pressure, failure-analysis) | queryinsights requiere Contributor. La presión del pool solo correlaciona. Clustering solo por predicados `WHERE`. No recomendar result-set caching. |

## `CLAUDE.md`

Corto, con reglas del repositorio:
- Propósito del repo (ejemplo replicable) y enlace al README.
- Los análisis de rendimiento se delegan en `FabricPerfAnalyst`; la administración corresponde a `FabricAdmin`.
- Si `FabricPerfAnalyst` devuelve una `Solicitud de confirmación`, la sesión principal la muestra completa al usuario, sin resumirla ni decidir por él, y reanuda el mismo agente (`SendMessage` con su ID) con la respuesta literal por cada `C#`. Si el usuario ya aprobó una operación concreta al pedir el análisis, se cita literalmente en el prompt.
- Repositorio de solo lectura frente a Fabric: ninguna sesión escribe en workspaces sin confirmación explícita para esa operación concreta.
- Los informes van en `informes/AAAA-MM-DD/<nn>-<slug>.md`; nunca se sobrescriben (sufijo `-v2`).
- No editar las skills de `.claude/skills/` que instala `apm install --only apm` ni los agentes copiados del paquete (salvo `fabric-perf-analysis` y `FabricPerfAnalyst`).

## `README.md`

Añade una sección que compare el bundle `skills-for-fabric` con lo que aporta este repositorio (alcance, agentes, routing, escrituras y confirmaciones, trampas conocidas, evidencia, salida) y amplía la sección existente de requisitos (no la reescribas) con lo que hoy no recoge:
- **Autenticación:** `--allow-no-subscriptions` y audiencias de token.
- **Capacidad:** SKU F o trial, o P1+ para los modelos; XMLA en Read Write; región compatible con FabricIQ.
- **Configuración del tenant y permisos del usuario**, indicando qué área del agente los necesita.
- **Capacity Metrics:** instalarla requiere ser administrador de capacidad y licencia Power BI; conviene un workspace Pro; retención.
- **Limitación conocida:** el MCP local no funciona en macOS (verifícalo).
- **Comprobación rápida:** `az account show`, `az rest` a `/v1/workspaces`, `node --version`, `apm install --only apm`, `/mcp`.

Verifica en Microsoft Learn los requisitos de XMLA, FabricIQ y Capacity Metrics antes de escribirlos.

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
| **Modo** | Solo lectura \| Solo lectura + diagnóstico confirmado (<C#>) |
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
