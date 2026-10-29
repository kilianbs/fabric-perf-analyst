> Prompt usado para generar `.claude/agents/FabricPerfAnalyst.md` y `.claude/skills/fabric-perf-analysis/`.
> Requiere `apm install` previo.

# Tarea: construir el agente FabricPerfAnalyst y su skill de análisis

Construye en este repositorio un agente de Claude Code de **solo lectura** que diagnostique el rendimiento de Microsoft Fabric (Spark, tablas Delta, SQL endpoint/Warehouse, modelos semánticos y capacidad) y genere un informe Markdown en español con una plantilla fija.

El conocimiento técnico ya está en las skills de `microsoft/skills-for-fabric`. Lo que construyes es una capa delgada de navegación encima: método de diagnóstico, mapa de síntomas a áreas, trampas conocidas y formato de salida. **No dupliques umbrales, rutas REST ni procedimientos de las skills: apunta a ellos.**

## Antes de escribir nada

1. Comprueba que existen las skills de `microsoft/skills-for-fabric` en `.claude/skills/`. Si faltan, para y dime que las instale con `apm install`.
2. Revisa `.mcp.json`: hacen falta `fabric-sqlendpoint` (remoto), `FabricIQ` (remoto, con `headersHelper` que use `az account get-access-token --resource https://api.fabric.microsoft.com`) y `powerbi-modeling-mcp` (local vía `npx`). Si falta alguno, avísame; no lo añadas sin preguntar.
3. Lee los agentes existentes en `.claude/agents/` para seguir su formato de frontmatter. No modifiques los que vienen de fabric-skills. Comprueba en la documentación de Claude Code si el frontmatter de subagentes admite un campo para precargar skills; si lo admite, úsalo para `fabric-perf-analysis`.
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

- **Frontmatter:** `name: FabricPerfAnalyst` y una `description` que:
  - lo presente como analista de rendimiento de solo lectura;
  - enumere las áreas que cubre (ejecuciones Spark, recursos y sesiones Spark, tablas Delta y MLV, SQL endpoint/Warehouse, modelos semánticos, capacidad), con síntomas típicos como disparadores ("cada día más lento", "OOM", "throttling", "DAX lento", "refresco fallido"...);
  - deje claro que hace diagnóstico, no administración, para no solaparse con FabricAdmin.
- **Navegación:** antes de recoger evidencia, el agente lee `fabric-perf-analysis/SKILL.md`, identifica las áreas implicadas a partir de los síntomas de la petición, lee el archivo de cada área y después las referencias de fabric-skills que ese archivo indique. Una petición puede tocar varias áreas: se sigue la evidencia, no un guion. Todo produce un único informe.
- **Workflow:**
  1. **Scope:** resolver workspace, items y ventana temporal. Si el workspace es desconocido y no se puede descubrir, una sola pregunta.
  2. **Orientación:** formular hipótesis iniciales a partir de los síntomas y del mapa de la skill.
  3. **Evidencia:** primero MCP (`fabric-sqlendpoint`, `powerbi-modeling-mcp`, FabricIQ para Capacity Metrics), después `az rest` (audiencia Fabric `https://api.fabric.microsoft.com`, Power BI `https://analysis.windows.net/powerbi/api`). Toda llamada a Fabric lleva `--headers "x-ms-fabric-skill=<skill>"`. Registrar cada consulta y llamada con su resultado. Respetar la retención: si un dato caducó, decirlo, no inferirlo.
  4. **Pivotar:** si la evidencia apunta a otra área (por ejemplo, un pipeline lento cuya causa es la fragmentación de una tabla), cargar esa área y seguir. Anotar en Alcance qué áreas se recorrieron y por qué.
  5. **Contrastar:** sin datos, una hipótesis va a Notas como no verificada; si los datos la refutan, va a Descartado.
  6. **Recomendar**, ordenando por impacto/esfuerzo.
  7. **Escribir el informe.**
- **Guardrails** (se quedan en el agente, que debe ser autocontenido):
  - Solo lectura: nada de `OPTIMIZE`, `VACUUM`, `TableMaintenance`, publicar environments, ejecutar notebooks o MLV, cambiar programaciones, borrar sesiones, `copyEventLog` de Job Insight, cambiar el modelo o las medidas, ni refrescar modelos. Todo eso se propone en Recomendaciones marcado "Requiere confirmación".
  - Los workflows de las skills terminan en hallazgos: anular el "Auto-apply" de Optimize DAX y la fase de corrección de Analyze Best Practices.
  - Piden confirmación crear una sesión Livy o ejecutar statements (consumen CU, incluido `DESCRIBE DETAIL`) y limpiar la caché VertiPaq (afecta a todos los usuarios del modelo).
  - Único `EXEC` SQL permitido: `sys.sp_get_table_health_metrics`. Nunca `ALTER`, `CREATE` ni `DROP`.
  - La falta de permisos o de un MCP se trata como hallazgo de Notas, consultando en la referencia de la skill qué permiso hacía falta.
  - Nunca imprimir tokens, cadenas de conexión ni cabeceras `Authorization`.
  - Cada cifra sale de una consulta o llamada registrada.
  - Cada umbral usado para asignar severidad cita la referencia de la skill de la que sale.
  - Las discrepancias entre skills y documentación se verifican con las herramientas de Microsoft Learn y se anotan en Notas.
  - Consultas acotadas con TOP, ventana temporal y agregados.
- **Output:**
  - Partir de `assets/informe-analisis.md`, mantener secciones y orden, seguir el comentario HTML inicial y después borrar todos los comentarios. Una sección vacía lleva "Sin datos" con el motivo en Notas.
  - Informe en español; código e identificadores tal cual.
  - Cabecera: host `Claude Code` más las skills usadas, ventana en UTC, modo `Solo lectura`, severidad global igual a la del hallazgo más grave.
  - Trazabilidad `E#`, `H#`, `R#`, `D#`: cada hallazgo cita al menos una E#, y cada recomendación cita su H# y explica cómo validarla.
  - Severidad `Alta`, `Media` o `Baja` según los criterios de las referencias de la skill. Confianza `Alta` (medido directamente), `Media` (medición parcial o indirecta) o `Baja` (inferido).
  - Nunca sobrescribir un informe existente: sufijo `-v2`.
  - Respuesta final: la ruta del informe y la sección Resumen.

## Skill `.claude/skills/fabric-perf-analysis/`

Usa el formato de frontmatter y la carga por capas (SKILL.md breve, referencias bajo demanda) de las skills de fabric-skills instaladas.

### `SKILL.md`

- **Frontmatter:** `name` y una `description` orientada a disparadores de síntomas de rendimiento.
- **Método de diagnóstico** (genérico, válido para cualquier petición): síntoma → área → hipótesis → evidencia mínima → contraste → hallazgo. Incluye cómo pivotar entre áreas.
- **Mapa de navegación:** tabla con síntoma o señal observable, área probable, archivo de área y señales que indican que hay que cruzar a otra área. Es una guía, no una lista cerrada: si nada encaja, el agente razona desde el método y lo anota en Alcance.
- **Reglas comunes de evidencia:** cabecera `x-ms-fabric-skill`, preferencia MCP → REST, retención, límites del SQL endpoint MCP (tomados de la skill que los documente, citándola) y que Livy consume CU.
- **Salida:** enlace a `assets/informe-analisis.md`.

### `references/<área>.md`

Un archivo por área técnica. Estructura fija:

1. **Qué cubre** (1-2 líneas).
2. **Preguntas típicas:** ejemplos de peticiones. Incluyen los escenarios de `demo-setup/`, pero el área no se limita a ellos.
3. **Dónde está el conocimiento:** rutas exactas a las referencias de fabric-skills, con qué aporta cada una (umbrales, procedimiento, rutas REST, permisos). Sin copiar los valores.
4. **Señales a medir:** qué métricas o llamadas dan evidencia en esta área, con un puntero a la referencia que define su umbral.
5. **Trampas conocidas:** lo que el agente podría hacer mal aunque lea la skill (ver tabla abajo).
6. **Escritura:** operaciones de esta área que solo se proponen.
7. **Cruces con otras áreas:** cuándo pivotar y a qué archivo.

Áreas propuestas (ajústalas si las skills sugieren otra partición mejor). Los ejemplos de los escenarios son orientativos; la columna de trampas recoge los puntos que hay que verificar contra la skill instalada (si la skill dice otra cosa, manda la skill y se anota la discrepancia):

| Archivo | Escenarios de `demo-setup/` | Skills de partida | Trampas conocidas a verificar |
|---------|-----------------------------|-------------------|-------------------------------|
| `spark-runs.md` | Pipeline cada día más lento · Data skew y shuffle · Fallos de Spark y OOM | spark-cli operations (pipeline-diagnosis, job-diagnostics, automated-diagnostic-workflow, diagnostic-workflow, performance-patterns, spark-history-server, jobinsight-api); `common/SPARK-MONITORING-CORE.md`; sqldw-cli consumption | Criterio de regresión frente a ejecuciones anteriores. Cola = inicio de la actividad frente a `runStartTime`. Tendencias desde jobs/instances porque stages/advice y queryactivityruns caducan antes. `/advice` antes que `/stages`; criterio de selección de stages y Tier 2. No decodificar la definición de notebooks salvo petición. Las sesiones HC agregan métricas. Separar fallo de código y de infraestructura. `copyEventLog` de Job Insight escribe. |
| `spark-resources.md` | Clúster sobredimensionado · Config de Spark por capa · Salud de sesiones Spark y colas | spark-cli operations (diagnostic-workflow, performance-patterns, session-health); spark-cli authoring/resources/data-engineering-patterns (lectura); e2e-medallion-architecture; e2e-fabric-cost-estimation | Umbrales de `coreEfficiency` e `idleTime`. Equivalencia CU/vCores. Cifras en moneda solo con la Retail Prices API en vivo y la región. NEE no fiable con `spark.conf.set` a mitad de sesión. Perfil `readHeavyForPBI`. Sesión sin `appId` tras un tiempo = espera de capacidad. **Contradicciones a documentar:** clave de V-Order (`spark.sql.parquet.vorder.default` frente a `spark.microsoft.delta.parquet.vorder.enabled`) y optimize write en Gold. |
| `delta-tables.md` | Mantenimiento de tablas Delta | sqldw-cli operations: lakehouse-health; spark-cli operations; spark-cli mlv | `itemId` = `sqlEndpointProperties.id`. `sp_get_table_health_metrics` solo devuelve la anomalía más grave y una llamada fallida es "No evaluada". Límite de peticiones. MLV: sin OData, `Deduped` no es un fallo, `DeltaTableVersionNotFound` apunta a VACUUM. |
| `semantic-models.md` | Buenas prácticas de modelado · Rendimiento DAX · Refrescos de modelos semánticos | semantic-model-authoring (Analyze Best Practices, Optimize DAX, semantic-model-rest-api, dax-perf-*, direct-lake-guidelines) | Permisos Write frente a Build (`INFO.VIEW.*`). Medidas en bloque `DEFINE`, sin tocar el modelo. Protocolo de medición (caché, calentamiento, repeticiones, dispersión). Routing DAX/DL. El fallback de Direct Lake se verifica en Learn. Ante un error de credenciales en refrescos, parar. POST, DELETE y PATCH son escrituras. |
| `capacity.md` | Picos de CU y throttling | sqldw-cli operations: capacity-metrics-correlation; fabriciq | CU alto no es presión por sí solo. `CapacitiesList`. No unir Operation Id con `distributed_statement_id`. Capacity Metrics guarda una ventana limitada. |
| `sql-endpoint.md` | — (sin escenario en `demo-setup/`, sí del agente) | sqldw-cli operations (scenarios, query-reference, resource-consumers, pool-pressure, failure-analysis) | queryinsights requiere Contributor. La presión del pool solo correlaciona. Clustering solo por predicados `WHERE`. No recomendar result-set caching. |

## `CLAUDE.md`

Corto, con reglas del repositorio:
- Propósito del repo (ejemplo replicable) y enlace al README.
- Los análisis de rendimiento se delegan en `FabricPerfAnalyst`.
- Repositorio de solo lectura frente a Fabric: ninguna sesión escribe en workspaces sin confirmación explícita.
- Los informes van en `informes/` con el patrón de nombre; nunca se sobrescriben.
- No editar `.claude/skills/` ni `.claude/agents/` instalados por APM (salvo `fabric-perf-analysis` y `FabricPerfAnalyst`).

## `README.md`

Amplía la sección existente de requisitos (no la reescribas) con lo que hoy no recoge:
- **Autenticación:** `--allow-no-subscriptions` y audiencias de token.
- **Capacidad:** SKU F o trial, o P1+ para los modelos; XMLA en Read Write; región compatible con FabricIQ.
- **Configuración del tenant y permisos del usuario**, indicando qué área del agente los necesita.
- **Capacity Metrics:** instalarla requiere ser administrador de capacidad y licencia Power BI; conviene un workspace Pro; retención.
- **Limitación conocida:** el MCP local no funciona en macOS (verifícalo).
- **Comprobación rápida:** `az account show`, `az rest` a `/v1/workspaces`, `node --version`, `apm install`, `/mcp`.

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
| **Modo** | Solo lectura |
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
