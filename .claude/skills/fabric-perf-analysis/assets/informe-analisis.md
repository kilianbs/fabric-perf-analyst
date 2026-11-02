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
