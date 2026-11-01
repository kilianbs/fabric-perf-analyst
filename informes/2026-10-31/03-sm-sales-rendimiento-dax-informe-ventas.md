# Rendimiento DAX del informe de ventas (sm_sales)

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-10-31 |
| **Áreas** | Semantic models |
| **Ámbito** | workspace `FabricPerfLab` · modelo semántico `sm_sales` |
| **Ventana analizada** | 2026-10-31 15:52 → 2026-10-31 15:58 UTC |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, semantic-model-authoring (`dax-perf-decision-guide.md`) |
| **Modo** | Lectura + diagnóstico activo (ClearCache) |
| **Severidad global** | Alta |
| **Confianza global** | Media |

## Resumen

- **Pregunta:** qué consultas y medidas de la página de ventas son lentas, si las reescrituras en DEFINE dan el mismo resultado y qué medidas no hay que tocar.
- **Conclusión:** la lentitud viene de solo tres medidas: `Avg Ticket` (~10 s), `Top 100 Customers Sales` (~4 s) y `Sales Running Total` (~3,3 s). El resto responde en menos de 200 ms.
- **Impacto:** Q1 tarda 10,3-12,3 s en frío (todo de `Avg Ticket`), Q3 3,3-3,7 s y Q4 4,0-4,1 s. Q2 y Q5 tardan menos de 270 ms. Con las reescrituras en DEFINE: `Avg Ticket` 10,5 s → 57 ms, `Sales Running Total` 3,3 s → 59-66 ms, `Top 100` 4,0 s → 0,95-1,4 s.
- **Primera acción:** R1, sustituir `Avg Ticket` por `DIVIDE([Total Sales], COUNTROWS(fact_sales))` (resultado idéntico hasta el 12.º decimal).
- **Limitación importante:** no hubo trazas del motor (sin split FE/SE). La causa se atribuye por el patrón DAX y por el efecto de la reescritura, con confianza Media.

## Alcance

**Pregunta original:** "El informe de ventas va lento. Analiza el rendimiento de las medidas de sm_sales con estas consultas de la página. Mide cada consulta y cada medida aislada, con trazas si están disponibles, y para las lentas prueba la reescritura en DEFINE comprobando que da el mismo resultado. Indica también qué medidas no hace falta tocar." (consultas Q1-Q5 de `demo-setup/dax/report-queries.dax`).

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Q1-Q5, las 10 medidas del modelo, reescrituras en `DEFINE MEASURE` (sin guardarlas) | Cambios en el modelo, refrescos, historial de refresco, mejores prácticas de modelado (ver informe `2026-10-31/02-sm-sales-buenas-practicas-modelado.md`) |

**Hipótesis de partida:** H-a medidas con iteradores y transición de contexto sobre la tabla de hechos (`Avg Ticket`, `Active Customers`, `Enterprise Sales`); H-b `FILTER(ALL(fact_sales))` en `Sales Running Total`; H-c `RANKX` dentro de `SUMX` en `Top 100`.

**Recorrido:** solo Semantic models. Ninguna evidencia llevó a pivotar de área.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Modo de almacenamiento | No consultado (no hace falta para este análisis) | n/a |
| Volumen de datos | `fact_sales`: 10 días (2026-09-01 a 2026-09-11, sin el 06), `Total Sales` = 2.982.980.595,69; `dim_customer` 169.227 filas; 200.000 `customer_id` distintos en hechos | E3, E5, E18 |
| Permisos | Acceso de lectura/ejecución DAX por el servidor hospedado `plugin:fabric-skills:powerbi-modeling-mcp` | E1 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| `sm_sales` | Semantic model | Consumo (informe de ventas) | no consultado |

## Evidencia

### Métricas clave

Tiempos de ejecución devueltos por la herramienta (`executionTimeMs`, incluye ida y vuelta al servicio), con `ClearCache` previo salvo indicación. Ver notas de método en Limitaciones.

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Q1 completa (en frío, ejecución de calentamiento) | 12.298 ms | n/a | E4 |
| Q1 completa (2 ejecuciones medidas) | 10.333 / 10.268 ms (dispersión < 1 %) | `dax-perf-decision-guide.md` § Phase 1 Step 3: dispersión < 20 % → valor más rápido | E4 |
| Q2 completa | 265 ms (frío) / 162 / 157 ms | ídem | E10 |
| Q3 completa | 3.687 / 3.257 ms | ídem | E13 |
| Q4 completa | 4.018 / 4.088 ms | ídem | E16 |
| Q5 completa | 171 / 157 ms | ídem | E20 |
| `Total Sales` aislada | 56 / 57 ms | ídem | E5 |
| `Margin %` aislada | 63 / 65 ms | ídem | E6 |
| `Avg Ticket` aislada | 10.485 / 9.876 ms | ídem | E7 |
| `Active Customers` aislada | 182 / 184 ms | ídem | E8 |
| `Enterprise Sales` (vía Q2 y aislada) | 79 / 100 ms | ídem | E11 |
| `Sales Running Total` (Q3 menos `Total Sales`) | ≈3.200-3.600 ms | ídem | E13 |
| `Top 100 Customers Sales` (Q4) | ≈4.000 ms | ídem | E16 |
| `Sales LY` (Q5) | ≤ 171 ms; valor vacío en todas las filas | ídem | E20 |
| `Avg Ticket` reescrita | 57 / 57 ms (−99,4 % frente a 9.876 ms) | mejora > banda de ruido | E9 |
| `Sales Running Total` reescrita | 66 / 59 ms (−98 % frente a 3.257 ms) | ídem | E14 |
| `Top 100` reescrita | 947 / 1.368 ms (−76,4 % con el más rápido frente a 4.018 ms; dispersión 44 %) | ídem | E17 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | MCP | `connection_operations ConnectFabric` (FabricPerfLab / sm_sales) en el servidor hospedado | Conectado. El servidor local `powerbi-modeling-mcp` (con `trace_operations`) devolvió "EULA must be accepted"; no se aceptó (ver Notas) |
| E2 | DAX | `INFO.VIEW.MEASURES()` | 10 medidas, todas en `fact_sales`; expresiones en el Anexo |
| E3 | DAX | Q1 original: tres ejecuciones, `ClearCache` antes de cada una (la primera es el calentamiento en frío) | 12.298 / 10.333 / 10.268 ms; Total Sales 2.982.980.595,69; Margin % 0,3812; Avg Ticket 298,298059569; Active Customers 169.228 |
| E4 | DAX | Resumen de E3 | ver Métricas clave |
| E5 | DAX | `ROW([Total Sales])`, 2 ejecuciones en frío | 56 / 57 ms |
| E6 | DAX | `ROW([Margin %])`, 2 ejecuciones | 63 / 65 ms |
| E7 | DAX | `ROW([Avg Ticket])`, 2 ejecuciones | 10.485 / 9.876 ms |
| E8 | DAX | `ROW([Active Customers])`, 2 ejecuciones | 182 / 184 ms; 169.228 |
| E9 | DAX | `DEFINE MEASURE Avg Ticket = DIVIDE([Total Sales], COUNTROWS(fact_sales))`; equivalencia contra el original en la misma consulta; 2 tiempos | Original 298,298059569 vs candidata 298,29805956900003; 57 / 57 ms |
| E10 | DAX | Q2 completa (50 filas) y dos ejecuciones envueltas en `ROW(COUNTROWS, SUMX)` | 265 ms; 162 / 157 ms; 50 filas; Total Sales 2.982.980.595,69; Enterprise 843.073.452,58 |
| E11 | DAX | `ROW([Enterprise Sales])`, 2 ejecuciones | 79 / 100 ms; 843.073.452,58 |
| E12 | DAX | Q3 envuelta en `ROW` (calentamiento en frío) | 3.687 ms; 10 filas |
| E13 | DAX | Q3 original con `ORDER BY` | 3.257 ms; acumulado final 2.982.980.595,69 |
| E14 | DAX | Candidata `Sales Running Total` = `CALCULATE([Total Sales], FILTER(ALL(fact_sales[sale_date]), fact_sales[sale_date] <= MAX(fact_sales[sale_date])))`: equivalencia y tiempos | Diferencia absoluta máxima por fila 0,000144 (ruido de coma flotante del original, a nivel de céntimo idéntico); 66 / 59 ms |
| E15 | DAX | Q4 original con `ORDER BY` | 4.018 ms; Barcelona 26.537.015,71; Bilbao 26.634.025,65; Madrid 37.978.028,67; Sevilla 314.410.203,10; Valencia 56.778.437,47 |
| E16 | DAX | Q4 original envuelta (total) en frío | 4.088 ms; 462.337.710,60 |
| E17 | DAX | Candidata `Top 100` = `SUMX(TOPN(100, ALL(dim_customer[customer_id]), CALCULATE(SUM(fact_sales[amount]))), CALCULATE(SUM(fact_sales[amount])))`: valores por ciudad y 2 tiempos en frío | Las 5 ciudades idénticas hasta el 14.º decimal; 947 / 1.368 ms; total 462.337.710,60000014 |
| E18 | DAX | Candidatas `Enterprise Sales` (`CALCULATE([Total Sales], dim_customer[segment]="Enterprise")`) y `Active Customers` (`DISTINCTCOUNT(fact_sales[customer_id])`) | Enterprise: 843.073.452,58 (idéntico), 94 ms con la consulta completa. Active Customers: 200.000 frente a 169.228 (distinto) |
| E19 | DAX | Candidata `Active Customers` = `CALCULATE(DISTINCTCOUNT(dim_customer[customer_id]), fact_sales)` | 169.227 frente a 169.228 (distinto en 1); `dim_customer` 169.227 filas |
| E20 | DAX | Q5 envuelta en `ROW`, 2 ejecuciones en frío | 171 / 157 ms; 16 filas; Total Sales 1.224.970.922,10; Sales LY vacío en todas |
| E21 | MCP | `dax_query_operations ClearCache` sobre `sm_sales` (Tier B) | 30 limpiezas, entre 15:52 y 15:58 UTC, una antes de cada ejecución medida; todas con éxito |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | `Avg Ticket` consume ~10 s: es el 100 % del coste de Q1 | Alta | Media | E3, E7, E9 |
| H2 | `Top 100 Customers Sales` tarda ~4 s (Q4) | Media | Media | E15, E16, E17 |
| H3 | `Sales Running Total` tarda ~3,3 s para solo 10 puntos (Q3) | Media | Media | E12, E13, E14 |
| H4 | `Total Sales`, `Margin %`, `Enterprise Sales`, `Active Customers`, `Sales LY` no necesitan cambios | Baja | Alta | E5, E6, E8, E10, E11, E20 |
| H5 | La reescritura de `Active Customers` que sugiere el patrón habitual cambia el resultado | Baja | Alta | E8, E18, E19 |

Criterio de severidad: la skill (`SKILL.md` § Workflow: Analyze Best Practices) solo define critical / recommended / optional sin umbral numérico; mapeo aplicado critical → Alta, recommended → Media, optional → Baja, según impacto medido. Alta: una medida que domina una consulta de la página con > 10 s. Media: 3-5 s. Baja: < 200 ms.

### H1 · `Avg Ticket`

- **Qué ocurre:** aislada tarda 10.485 / 9.876 ms; Q1 (4 medidas) tarda 10.333 / 10.268 ms, con las otras tres sumando ~300 ms.
- **Por qué:** `AVERAGEX(fact_sales, CALCULATE(SUM(fact_sales[amount])))` itera cada fila de hechos y aplica transición de contexto en cada una (E2). Es un patrón de iterador con `CALCULATE` por fila; sin trazas no se midió el reparto FE/SE, por eso la confianza es Media. La causa se sustenta en que la reescritura sin iterador baja a 57 ms (E9).
- **Impacto:** KPI de la primera tarjeta; una sola medida bloquea toda la fila de tarjetas ~10 s.

### H2 · `Top 100 Customers Sales`

- **Qué ocurre:** ~4,0 s (E15, E16). La reescritura con `TOPN` una sola vez baja a 947-1.368 ms con los mismos valores en las 5 ciudades (E17).
- **Por qué:** `RANKX(ALL(customer_id), ...)` se evalúa para cada cliente visible dentro de `SUMX` (E2), trabajo cuadrático en clientes. Atribución por patrón y por el efecto de la reescritura (Confianza Media).
- **Impacto:** Q4 es 4 s en frío; sigue siendo ~1 s tras la reescritura. La dispersión de la candidata (44 %) supera el 20 % de la guía, así que se tomó el valor más rápido y se anota el rango. La mejora (≥ 66 %) supera con holgura el ruido.

### H3 · `Sales Running Total`

- **Qué ocurre:** 3.687 / 3.257 ms para 10 filas; la candidata, 66 / 59 ms (E13, E14).
- **Por qué:** `FILTER(ALL(fact_sales), fact_sales[sale_ts] <= MAX(fact_sales[sale_ts]))` materializa y filtra la tabla de hechos entera (~9 millones de filas según DEMO-SCENARIOS, no medido aquí) en cada punto. La candidata filtra solo la columna `sale_date`.
- **Impacto:** crece con el número de días y de filas.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Reescribir `Avg Ticket` | H1 | Alto | Bajo | Bajo | Sí |
| R2 | Reescribir `Sales Running Total` | H3 | Medio | Bajo | Bajo | Sí |
| R3 | Reescribir `Top 100 Customers Sales` | H2 | Medio | Bajo | Medio | Sí |

### R1 · Avg Ticket

- **Cambio propuesto:**

  ```dax
  Avg Ticket = DIVIDE([Total Sales], COUNTROWS(fact_sales))
  ```

- **Impacto esperado:** de ~10 s a ~57 ms (−99 %), medido en E9.
- **Cómo validarlo:** repetir Q1 en frío con 3 ejecuciones y comparar con 10,3 s; confirmar `Avg Ticket` = 298,298059569 (diferencia de coma flotante en el 12.º decimal).
- **Reversión:** restaurar la expresión original (en el Anexo).
- **Requiere confirmación:** Sí — cambia una medida del modelo; este agente no escribe en el modelo.

### R2 · Sales Running Total

- **Cambio propuesto:**

  ```dax
  Sales Running Total =
  CALCULATE([Total Sales],
      FILTER(ALL(fact_sales[sale_date]), fact_sales[sale_date] <= MAX(fact_sales[sale_date])))
  ```

- **Impacto esperado:** de ~3,3 s a ~60 ms (E14). Cambia el nivel de comparación de `sale_ts` a `sale_date`: es idéntico cuando se agrupa por día (Q3) pero daría otro valor si se agrupara por hora o por marca de tiempo. Una variante con `dim_date[date]` requiere que la relación con `dim_date` esté activa y marcada; no se probó.
- **Cómo validarlo:** repetir Q3 en frío y comparar fila a fila con E13.
- **Reversión:** expresión original en el Anexo.
- **Requiere confirmación:** Sí — escritura en el modelo.

### R3 · Top 100 Customers Sales

- **Cambio propuesto:**

  ```dax
  Top 100 Customers Sales =
  SUMX(TOPN(100, ALL(dim_customer[customer_id]), CALCULATE(SUM(fact_sales[amount]))),
       CALCULATE(SUM(fact_sales[amount])))
  ```

- **Impacto esperado:** de ~4,0 s a ~0,95-1,4 s (E17). Riesgo Medio: `TOPN` devuelve los empates y `RANKX` también, y los valores coincidieron en las 5 ciudades, pero con otros datos o filtros de página (por ejemplo, empates en el corte 100) puede divergir; validar con la página real.
- **Cómo validarlo:** repetir Q4 y comparar los 5 valores por ciudad, y probar con los filtros de la página.
- **Reversión:** expresión original en el Anexo.
- **Requiere confirmación:** Sí — escritura en el modelo.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | `Enterprise Sales` (`FILTER` + `RELATED` sobre hechos) es lenta | E10, E11, E18 | 79-100 ms aislada y Q2 completa en 157-265 ms con 50 filas; el motor lo resuelve bien a este volumen. La reescritura da el mismo valor (843.073.452,58) y es más legible, pero no hay mejora de rendimiento que medir |
| D2 | `Active Customers` (`FILTER` + `CALCULATE` por cliente) es lenta | E8 | 182-184 ms. Las reescrituras probadas (`DISTINCTCOUNT` sobre hechos: 200.000; sobre `dim_customer`: 169.227) no coinciden con 169.228, porque en hechos hay `customer_id` que no existen en `dim_customer` (huérfanos); ver H5 |
| D3 | `Margin %` (`IFERROR`) es lenta | E6 | 63-65 ms; `DIVIDE` sería mejor práctica pero no cambia el rendimiento |
| D4 | `Sales LY` es lenta | E20 | Q5 completa en 157-171 ms. Devuelve vacío en todas las filas porque no hay datos del año anterior en el modelo |
| D5 | Las medidas simples (`Total Sales`) son un problema | E5 | 56-57 ms |

### Medidas que no hace falta tocar

`Total Sales`, `Total Quantity` (suma simple; no se midió aislada, su definición es `SUM`, ver E2), `Margin` (suma simple, no medida aislada), `Margin %`, `Enterprise Sales`, `Active Customers`, `Sales LY`. Evidencia en D1-D5. Q2 y Q5 completas (< 270 ms) tampoco requieren cambios.

## Siguientes pasos

- [ ] Aplicar R1, R2 y R3 en una copia del modelo y repetir Q1, Q3 y Q4 en frío — responsable: autor del modelo · relacionado con: R1, R2, R3
- [ ] Repetir el análisis con trazas (aceptar el EULA del servidor local `powerbi-modeling-mcp`) para obtener el reparto FE/SE — responsable: usuario · relacionado con: H1-H3
- [ ] Repetir el análisis tras aplicar R1-R3 para validar el impacto

## Notas

### Limitaciones

- **Trazas no disponibles.** El servidor local `powerbi-modeling-mcp` (único con `trace_operations`) exige aceptar un EULA (`accept_eula` / `--accept-eula`). Aceptarlo es un consentimiento legal del usuario y no lo da el agente, así que no se aceptó. Se usó el servidor hospedado `plugin:fabric-skills:powerbi-modeling-mcp`, que ejecuta DAX y `ClearCache` pero no trazas ni métricas de ejecución. Por tanto no hay duración FE/SE, número de consultas SE ni caché de SE; las atribuciones de causa son por patrón DAX y por el efecto de la reescritura (Confianza Media).
- **Método de tiempos.** `executionTimeMs` incluye ida y vuelta al servicio. Para Q2, Q3, Q4 y Q5 las repeticiones se envolvieron en `ROW(COUNTROWS, SUMX)` para no devolver todas las filas; el cómputo es el mismo pero no es exactamente la consulta de la página. Cada medida aislada tuvo 2 ejecuciones medidas, con un calentamiento en frío solo en Q1, Q2, Q3 y Q4/Q5 por su primera ejecución (cuya duración se registra, no se descarta). La guía (§ Phase 1 Step 3) pide 1 calentamiento + 2 ejecuciones; para `Sales Running Total` y `Top 100` el calentamiento fue la primera consulta de Q3/Q4.
- **Ventana de datos corta.** El modelo cubre 10 días (E3), así que las medidas rápidas pueden degradarse con más volumen, como indica `DEMO-SCENARIOS.md`.
- Ejecuciones de `ClearCache`: 30, afectan a todos los usuarios del modelo; E21 las registra.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Trazas FE/SE por consulta | EULA del servidor local sin aceptar; el servidor hospedado no expone trazas | Confianza Media en la causa de H1-H3 |
| Tiempo de `Total Quantity` y `Margin` aisladas | Son sumas simples sin iteradores; no se midieron por separado | Se incluyen como "no tocar" por definición (E2) y porque `Margin %` que las usa tarda 63-65 ms (E6) |
| Modo de almacenamiento, tamaño de tablas | No consultado | Sin efecto en las conclusiones |
| Reescritura de `Active Customers` equivalente | Las dos probadas cambian el resultado (E18, E19) | Se deja la medida sin tocar |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Reescritura de `Active Customers` por `DISTINCTCOUNT` | Patrón habitual que sugiere `DEMO-SCENARIOS.md` | No equivalente en este modelo (huérfanos en hechos, E18, E19) | Se prioriza la verificación de equivalencia de la guía (§ Phase 2 Step 2): resultado distinto → no recomendar |

## Anexo

### Consultas completas

Definiciones originales (E2):

```dax
Total Sales = SUM(fact_sales[amount])
Margin = SUM(fact_sales[line_margin])
Margin % = IFERROR([Margin] / [Total Sales], 0)
Enterprise Sales = CALCULATE([Total Sales], FILTER(fact_sales, RELATED(dim_customer[segment]) = "Enterprise"))
Avg Ticket = AVERAGEX(fact_sales, CALCULATE(SUM(fact_sales[amount])))
Sales Running Total = CALCULATE([Total Sales], FILTER(ALL(fact_sales), fact_sales[sale_ts] <= MAX(fact_sales[sale_ts])))
Top 100 Customers Sales = SUMX(VALUES(dim_customer[customer_id]),
    IF(RANKX(ALL(dim_customer[customer_id]), CALCULATE(SUM(fact_sales[amount]))) <= 100, CALCULATE(SUM(fact_sales[amount]))))
Active Customers = COUNTROWS(FILTER(VALUES(dim_customer[customer_id]), CALCULATE(COUNTROWS(fact_sales)) > 0))
Sales LY = CALCULATE([Total Sales], SAMEPERIODLASTYEAR(fact_sales[sale_date]))
Total Quantity = SUM(fact_sales[quantity])
```

### Configuración efectiva

Sin datos relevantes.
