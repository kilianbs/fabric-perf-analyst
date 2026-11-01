# CLAUDE.md

Repositorio de ejemplo para diagnosticar el rendimiento de Microsoft Fabric con Claude Code.
Requisitos, instalación y configuración: [README.md](README.md).

## Reglas

- **Análisis de rendimiento:** cualquier petición de diagnóstico de rendimiento de Fabric (Spark,
  tablas Delta, SQL endpoint/Warehouse, modelos semánticos o capacidad) se delega en el agente
  `FabricPerfAnalyst`. Las repreguntas de una misma conversación se envían al agente en curso
  (`SendMessage`) o, si ya no está disponible, a uno nuevo indicando el informe previo. La administración (permisos, capacidad, gobierno) corresponde a `FabricAdmin`.
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
  en el paquete: no cargan esa skill ni quedan sujetos a ese hook. No registrar el hook en
  `.claude/settings.json`.
- **Informes:** se guardan en una carpeta por día de análisis, `informes/AAAA-MM-DD/`, con el
  patrón `<nn>-<slug>.md` (`<nn>` correlativo dentro de la carpeta). Un informe
  existente nunca se sobrescribe: la nueva versión lleva el sufijo `-v2` (o el siguiente libre).
- **Contenido de `skills-for-fabric`:** no editar las skills de `.claude/skills/` que instala
  `apm install --only apm` ni los agentes de `.claude/agents/` copiados del paquete. Las únicas
  excepciones son la skill
  `.claude/skills/fabric-perf-analysis/` y el agente `.claude/agents/FabricPerfAnalyst.md`, que son
  propios de este repositorio.
