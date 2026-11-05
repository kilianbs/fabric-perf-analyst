# AGENTS.md

Repositorio de ejemplo para diagnosticar el rendimiento de Microsoft Fabric con un agente de IA.
Funciona con Claude Code y con GitHub Copilot (VS Code y Copilot CLI). Requisitos, instalación y
configuración: [README.md](README.md). `CLAUDE.md` solo importa este archivo.

## Reglas

- **Análisis de rendimiento:** cualquier petición de diagnóstico de rendimiento de Fabric (Spark,
  tablas Delta, SQL endpoint/Warehouse, modelos semánticos o capacidad) se delega en el agente
  `FabricPerfAnalyst`. Las repreguntas de una misma conversación se envían al agente en curso
  (`SendMessage` en Claude Code, `write_agent` en GitHub Copilot) o, si ya no está disponible, a uno
  nuevo indicando el informe previo. Al usuario solo se le devuelve un resumen breve (la ruta del
  informe y 3-5 viñetas con la respuesta), sin ampliar ni repetir el contenido del informe. La administración (permisos, capacidad, gobierno) corresponde a
  `FabricAdmin`.
- **Sin cambios en Fabric desde `FabricPerfAnalyst`:** el agente nunca crea, modifica, borra,
  refresca, programa o mantiene items de un workspace, ni ejecuta notebooks, jobs o pipelines; esos
  cambios los deja como recomendaciones. Esta regla no aplica a la sesión principal ni a los demás
  agentes, que siguen las reglas de sus skills de `skills-for-fabric`.
- **Ejecuciones de diagnóstico:** las ejecuciones de diagnóstico de `FabricPerfAnalyst` (una sesión
  Livy propia con sentencias que no escriben, como `DESCRIBE DETAIL`, y `ClearCache` para medir DAX
  en frío) no son cambios: el agente las ejecuta sin pedir confirmación aunque consuman CU o afecten
  a otros usuarios. El hook `.claude/hooks/livy_readonly_guard.py`, declarado en el frontmatter del
  agente, solo deja pasar sentencias Livy de una lista blanca de lectura mientras corre ese agente.
- **Aislamiento:** lo que añade este repositorio (el agente `FabricPerfAnalyst`, la skill
  `fabric-perf-analysis` y su hook) solo aplica dentro de `FabricPerfAnalyst`. La sesión principal y
  los demás agentes y skills de `skills-for-fabric` (por ejemplo `FabricDataEngineer`) funcionan como
  en el paquete: no cargan esa skill ni quedan sujetos a ese hook. No registrar el hook a nivel de
  sesión o repositorio: ni en `.claude/settings.json`, ni en `.github/hooks/`, ni en
  `.github/copilot/settings.json`.
- **Dos copias de `FabricPerfAnalyst`:** `.claude/agents/FabricPerfAnalyst.md` (Claude Code) y
  `.github/agents/FabricPerfAnalyst.agent.md` (GitHub Copilot, que la prefiere a la de `.claude/`).
  Solo difieren en el frontmatter del hook (`--format copilot`, ruta relativa) y en el host del
  informe. Cualquier cambio en una se replica en la otra.
- **Informes:** se guardan en una carpeta por día de análisis, `informes/AAAA-MM-DD/`, con el
  patrón `<nn>-<slug>.md` (`<nn>` correlativo dentro de la carpeta). Cada repregunta lleva el
  siguiente `<nn>`. Un informe existente nunca se sobrescribe: rehacer la misma pregunta lleva el
  sufijo `-v2` (o el siguiente libre).
- **Contenido de `skills-for-fabric`:** no editar las skills de `.claude/skills/` que instala
  `apm install --only apm` ni los agentes copiados del paquete en `.claude/agents/` y `.github/agents/`. Las únicas
  excepciones son la skill `.claude/skills/fabric-perf-analysis/` y las dos copias del agente
  `FabricPerfAnalyst`, que son propias de este repositorio.
