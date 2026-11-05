# Tarjeta "Avg Ticket" de rpt_sales lenta: causa en la medida Avg Ticket

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-05 |
| **Áreas** | Semantic models |
| **Ámbito** | workspace `FabricPerfLab` · informe `rpt_sales` (página "Sales overview", tarjeta `1a5c0e7b3f2d4a6c8e01`) · modelo `sm_sales` |
| **Ventana analizada** | 2026-11-05 09:45 → 2026-11-05 09:53 UTC (benchmark en vivo) |
| **Agente / host** | Claude Code · skills: semantic-model-authoring, powerbi-report-cli, fabric-perf-analysis |
| **Modo** | Lectura + diagnóstico activo (ClearCache) |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** por qué tarda tanto la tarjeta "Avg Ticket" de rpt_sales; medir la consulta completa y cada medida, en frío y en caliente.
- **Conclusión:** la causa es la medida `Avg Ticket` = `AVERAGEX(fact_sales, CALCULATE(SUM(fact_sales[amount])))`: un iterador sobre la tabla de hechos de 13 M de filas con transición de contexto por fila. Las otras tres medidas de la tarjeta cuestan menos de 1,2 s.
- **Impacto:** consulta de la tarjeta 12,4 s en frío (3 de 3 ejecuciones válidas: 12,7 / 12,4 / 12,4) y 5,2-5,6 s en caliente; `Avg Ticket` sola 12,2-13,5 s en frío y 5,9 s en caliente. Candidato `AVERAGE(fact_sales[amount])`: la tarjeta completa baja a 0,31 s en frío y 0,08 s en caliente, con el mismo valor (298,2468).
- **Primera acción:** R1, redefinir `Avg Ticket` como `AVERAGE(fact_sales[amount])` (requiere confirmación; no aplicado).

## Alcance

**Pregunta original:** "La tarjeta de "Avg Ticket" del informe rpt_sales del workspace FabricPerfLab tarda mucho en cargar. Mide la consulta completa de la tarjeta (la DAX que genera el visual) y cada una de sus medidas por separado (en frío con ClearCache y en caliente, varias repeticiones). Identifica qué medida o patrón DAX causa la lentitud."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Tarjeta `cardVisual` con 4 medidas: Total Sales, Margin %, Avg Ticket, Active Customers; medidas individuales y candidato en `DEFINE` | Otros visuales de la página (matriz, línea, barras, tabla): no se preguntaron; se anotan medidas sospechosas en Notas |

**Hipótesis de partida:** H-a) iterador con transición de contexto en `Avg Ticket`; H-b) `Active Customers` (FILTER sobre VALUES de 162 k clientes con CALCULATE); H-c) `Margin %` con `IFERROR`.

**Recorrido:** Semantic models únicamente. El informe se leyó con `getDefinition` para obtener los campos de la tarjeta; no hubo señal de capa de datos, SQL ni capacidad (el modelo es Import, ver Contexto).

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Modo de almacenamiento del modelo | Import (`defaultMode`), `directLakeBehavior` Automatic | E4 |
| Tamaño de `fact_sales` / `dim_customer` | 13.000.000 / 161.879 filas | E5 |
| Permisos con los que se ejecutó | Acceso XMLA y lectura de medidas (Write) funcionaron; `getDefinition` del informe correcto | E1-E4 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| rpt_sales | Report | Consumo | 9bf2e777-02aa-4082-9a1f-02b96987de3c |
| sm_sales | SemanticModel | Modelo Import | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |

## Evidencia

### Métricas clave

Tiempos de `executionTimeMs` devueltos por la herramienta (ms). Frío = tras `ClearCache`; caliente = repetición sin limpiar.

| Consulta | Frío (ms) | Caliente (ms) | Evidencia |
|----------|-----------|---------------|-----------|
| Tarjeta completa (4 medidas) | 12682 / 12355 / 12357 | 5149 / 5237 / 5568 | E6 |
| Avg Ticket | 12178 / 13522 (la corrida de 5862 se descarta, ver Limitaciones) | 5925 / 5916 / 5944 | E7 |
| Active Customers | 399 / 1190 / 547 | 277 | E8 |
| Total Sales | 167 / 103 | 350 | E9 |
| Margin % | 67 / 73 | 50 | E10 |
| Candidato Avg Ticket = AVERAGE(amount), solo medida | 62 | n/d | E11 |
| Tarjeta completa con candidato | 313 | 84 | E11 |

Ahorro con el candidato (tarjeta, frío): (12355 - 313) / 12355 = 97 %; muy por encima de la banda de ruido (12355-12682 ms) (`dax-perf-decision-guide.md` § Phase 2, Step 3).

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces` y `GET /v1/workspaces/{ws}/items?type=Report` / `SemanticModel` | Workspace `FabricPerfLab` 23ca4a73-3312-4242-9714-0289816895aa; rpt_sales y sm_sales localizados |
| E2 | REST | `POST /v1/workspaces/{ws}/reports/{id}/getDefinition?format=PBIR` + `GET /v1/operations/{op}` y `/result` (lectura) | Página "Sales overview", 5 visuales; la tarjeta (`cardVisual`) tiene 4 proyecciones: Total Sales, Margin %, Avg Ticket, Active Customers; sin grupos. No hay `filterConfig` en ninguna parte del informe |
| E3 | MCP | `measure_operations Get` (5 medidas) | `Total Sales` = `SUM(fact_sales[amount])`; `Margin` = `SUM(fact_sales[line_margin])`; `Margin %` = `IFERROR([Margin] / [Total Sales], 0)`; `Avg Ticket` = `AVERAGEX(fact_sales, CALCULATE(SUM(fact_sales[amount])))`; `Active Customers` = `COUNTROWS(FILTER(VALUES(dim_customer[customer_id]), CALCULATE(COUNTROWS(fact_sales)) > 0))`. Sin grupos de cálculo consultados (ver Notas) |
| E4 | MCP | `model_operations Get` | Modo Import, cultura en-US |
| E5 | DAX | `EVALUATE ROW("rows", COUNTROWS(fact_sales), "cust", COUNTROWS(dim_customer))` | 13.000.000 y 161.879; 53 ms |
| E6 | DAX | Consulta de la tarjeta reconstruida: `EVALUATE SUMMARIZECOLUMNS("Total Sales",[Total Sales],"Margin %",[Margin %],"Avg Ticket",[Avg Ticket],"Active Customers",[Active Customers])`; 3 frío + 3 caliente | Ver tabla. Resultado: 3.877.208.385,6 / 0,38116 / 298,2468 / 161.880 |
| E7 | DAX | `EVALUATE SUMMARIZECOLUMNS("Avg Ticket",[Avg Ticket])` | Ver tabla |
| E8 | DAX | Ídem con `[Active Customers]` | Ver tabla |
| E9 | DAX | Ídem con `[Total Sales]` | Ver tabla |
| E10 | DAX | Ídem con `[Margin %]` | Ver tabla |
| E11 | DAX | `DEFINE MEASURE fact_sales[Avg Ticket Cand] = AVERAGE(fact_sales[amount])` + `SUMMARIZECOLUMNS` (solo medida y tarjeta completa) | Ver tabla; valor 298,2467988923077 igual a 298,2467988923078 de la medida original (diferencia de coma flotante ~1e-13) |
| E12 | ClearCache | XMLA ClearCache sobre `sm_sales`, varias limpiezas (una antes de cada corrida en frío) entre 09:48 y 09:53 UTC (la primera hacia las 09:48:05 UTC) | `Cache cleared successfully` en todas |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | `Avg Ticket` (AVERAGEX con CALCULATE sobre `fact_sales`) explica prácticamente todo el tiempo de la tarjeta | Alta | Alta | E3, E5, E6, E7, E11 |
| H2 | `Margin %` usa `IFERROR` en vez de `DIVIDE`; sin impacto medido | Baja | Alta | E3, E10 |

### H1 · Avg Ticket itera 13 M de filas con transición de contexto

- **Qué ocurre:** la tarjeta tarda 12,4 s en frío y 5,2-5,6 s en caliente. `Avg Ticket` sola tarda 12,2-13,5 s en frío y 5,9 s en caliente, es decir, lo mismo que la tarjeta entera. Las otras tres medidas suman menos de ~1,5 s en el peor caso frío (Active Customers 1,19 s, Total Sales 0,17 s, Margin % 0,07 s).
- **Por qué:** `AVERAGEX(fact_sales, CALCULATE(SUM(...)))` itera las 13.000.000 filas de la tabla de hechos y ejecuta una transición de contexto por fila, trabajo del Formula Engine monohilo; el patrón corresponde a `DAX008` (context transition in iterator) del catálogo (`dax-perf-decision-guide.md` § Section 3 router, `dax-perf-patterns.md` DAX008/DAX015). El tiempo no baja a nivel Import con la caché caliente (5,9 s), lo que indica coste de Formula Engine y no de lectura de columnas. El hecho de que el candidato (`AVERAGE`, nativo del Storage Engine) devuelva el mismo resultado en 62 ms lo confirma. No se capturó traza SE/FE (ver Notas), así que la atribución FE se infiere de este contraste.
- **Impacto:** cada carga de la tarjeta (y de la página, que la contiene) espera >12 s en frío. Se aplica a todo usuario que abra el informe tras un refresco o expulsión de caché. Severidad Alta: la carga de un visual de primera línea supera con creces 10 s; no hay umbral numérico en la skill, se justifica con el impacto medido (`SKILL.md` § Workflow: Analyze Best Practices: crítico → Alta).

### H2 · IFERROR en Margin % (Baja)

`Margin %` usa `IFERROR([Margin]/[Total Sales],0)` (E3). Mide 50-73 ms (E10), sin impacto; buena práctica es `DIVIDE` (`modeling-guidelines.md`, véase Notas; `IFERROR` puede ocultar errores y evita la optimización del SE). Se menciona por el trap "Best-practice scope".

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Redefinir `Avg Ticket` como `AVERAGE(fact_sales[amount])` | H1 | Alto | Bajo | Bajo | Sí |
| R2 | Cambiar `IFERROR(...,0)` por `DIVIDE([Margin],[Total Sales],0)` en `Margin %` | H2 | Bajo | Bajo | Bajo | Sí |

### R1 · Redefinir Avg Ticket

- **Cambio propuesto:**

  ```dax
  Avg Ticket = AVERAGE ( fact_sales[amount] )
  ```

  Si "ticket" debe significar el importe medio por pedido o ticket y no por línea, debe definirlo el negocio; esta propuesta conserva la semántica actual (media por fila de `fact_sales`). Con filas duplicadas idénticas la medida original suma importes iguales por fila; con el dato actual el resultado coincide (E11).
- **Impacto esperado:** tarjeta de 12,4 s a 0,31 s en frío y de 5,2 s a 0,08 s en caliente, medido en E11.
- **Cómo validarlo:** repetir E6 y E7 tras el cambio (1 calentamiento + 2 corridas medidas con ClearCache) y comprobar que el valor sigue en 298,2468.
- **Reversión:** restaurar la expresión anterior.
- **Requiere confirmación:** Sí: cambio de definición de medida en el modelo (Tier C para este agente).

### R2 · DIVIDE en Margin %

- **Cambio propuesto:** `Margin % = DIVIDE ( [Margin], [Total Sales], 0 )`
- **Impacto esperado:** ninguno medible en velocidad; mejora de mantenimiento.
- **Cómo validarlo:** comparar el valor de la tarjeta (0,38116) antes y después.
- **Reversión:** restaurar `IFERROR`.
- **Requiere confirmación:** Sí: cambio de medida.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | `Active Customers` (FILTER sobre 162 k clientes con CALCULATE) es el cuello de botella | E8 | 277-1190 ms, ~10 veces menos que Avg Ticket |
| D2 | `Margin %` / `IFERROR` es lento | E10 | 50-73 ms |
| D3 | La lentitud viene de la carga de columnas en frío (caché SE) | E6, E7 | En caliente sigue en 5,2-5,9 s; la mitad del tiempo en frío es adicional, pero el coste dominante persiste con caché caliente |

## Siguientes pasos

- [ ] Aprobar y aplicar R1 en `sm_sales` — responsable: propietario del modelo · relacionado con: R1
- [ ] Repetir el benchmark de la tarjeta tras aplicar R1 — responsable: analista · relacionado con: R1
- [ ] Revisar con el mismo método las medidas del resto de la página (Sales Running Total, Top 100 Customers Sales, Sales LY, Enterprise Sales) — responsable: analista

## Notas

### Limitaciones

- **Consulta reconstruida:** la DAX de la tarjeta se reconstruyó desde `visual.json` (4 medidas, sin agrupación, sin filtros en el informe). Es una aproximación: no incluye lo que añade Power BI al renderizar (`semantic-models.md` § Known traps).
- **Sin traza FE/SE:** se midió `executionTimeMs` de la herramienta Execute; no se capturó traza server timing, por lo que no hay reparto FE/SE ni número de consultas SE medidos. La atribución al Formula Engine es indirecta (Confianza de la atribución del mecanismo: Media; de la medida culpable: Alta).
- **Corridas no válidas:** en dos ocasiones lancé `Execute` y `ClearCache` en paralelo y un `Execute` solapado con otro: se descartan la corrida de Avg Ticket de 5862 ms y la de 13543 ms (esta última claramente afectada por concurrencia). Las corridas de la tarjeta en las que el `ClearCache` posterior iba en el mismo lote (la segunda frío y la última caliente) son válidas porque el borrado se aplicó tras devolver el resultado de la consulta... no verificable al 100 %; los valores son coherentes entre sí (12,36-12,68 s).
- **Frío vs caliente:** el ClearCache solo vacía la caché SE; el modelo Import tiene los datos residentes, por eso el "frío" mide caché SE vacía y no carga desde disco.
- **Efecto sobre otros usuarios:** Los ClearCache afectan a todos los usuarios de `sm_sales` (`semantic-models.md` § Known traps).
- **Active Customers = 161.880** frente a 161.879 filas en `dim_customer`: hay un miembro en blanco (clave huérfana en `fact_sales`). No se investigó (fuera de la pregunta); se anota para una revisión de calidad de datos.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Traza SE/FE y número de consultas SE | No se usó la herramienta de trazas | Mecanismo FE inferido |
| Grupos de cálculo del modelo | No se listaron | No afecta a la conclusión, el contraste con el candidato en el mismo modelo da 62 ms |
| Tiempos reales en el visual (Performance Analyzer) | No disponible desde el agente | Se midió la DAX equivalente |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Mecanismo de ClearCache | La skill no nombra el mecanismo | XMLA ClearCache actúa sobre toda la base de datos | Ejecutado como Tier B y registrado en E12 |

## Anexo

### Consultas completas

```dax
-- E6: tarjeta
EVALUATE
SUMMARIZECOLUMNS (
    "Total Sales", [Total Sales],
    "Margin %", [Margin %],
    "Avg Ticket", [Avg Ticket],
    "Active Customers", [Active Customers]
)

-- E11: candidato
DEFINE MEASURE fact_sales[Avg Ticket Cand] = AVERAGE ( fact_sales[amount] )
EVALUATE
SUMMARIZECOLUMNS (
    "Total Sales", [Total Sales],
    "Margin %", [Margin %],
    "Avg Ticket Cand", [Avg Ticket Cand],
    "Active Customers", [Active Customers]
)
```
