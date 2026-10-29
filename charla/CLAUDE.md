# CLAUDE.md

Repositorio de demostración de la charla sobre diagnóstico de rendimiento en Microsoft Fabric con
Claude Code. Requisitos, instalación y configuración: [README.md](README.md).

## Reglas

- **Análisis de rendimiento:** cualquier petición de diagnóstico de rendimiento de Fabric (Spark,
  tablas Delta, SQL endpoint/Warehouse, modelos semánticos o capacidad) se delega en el agente
  `FabricPerfAnalyst`. La administración (permisos, capacidad, gobierno) corresponde a `FabricAdmin`.
- **Solo lectura frente a Fabric:** ninguna sesión escribe en un workspace (crear, modificar, borrar,
  ejecutar, refrescar, programar o mantener items) sin confirmación explícita del usuario para esa
  operación concreta.
- **Informes:** se guardan en una carpeta por día de análisis, `informes/AAAA-MM-DD/`, con el
  patrón `<nn>-<slug>.md` (`<nn>` correlativo dentro de la carpeta). Un informe
  existente nunca se sobrescribe: la nueva versión lleva el sufijo `-v2` (o el siguiente libre).
- **Contenido instalado por APM:** no editar las skills de `.claude/skills/` ni los agentes de
  `.claude/agents/` que instala `apm install`. Las únicas excepciones son la skill
  `.claude/skills/fabric-perf-analysis/` y el agente `.claude/agents/FabricPerfAnalyst.md`, que son
  propios de este repositorio.
