# Tarjeta "Avg Ticket" lenta en sm_sales: AVERAGEX con transición de contexto sobre 11 M de filas

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-02 |
| **Áreas** | Semantic models |
| **Ámbito** | workspace `FabricPerfLab` · modelo semántico `sm_sales` |
| **Ventana analizada** | 2026-11-02 20:24 → 20:27 UTC (medición puntual en vivo) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, semantic-model-authoring |
| **Modo** | Lectura + diagnóstico activo (ClearCache) |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** por qué tarda tanto la consulta de la tarjeta (Total Sales, Margin %, Avg Ticket, Active Customers).
- **Conclusión:** la causa es solo la medida `[Avg Ticket]` = `AVERAGEX(fact_sales, CALCULATE(SUM(fact_sales[amount])))`: itera 11 M de filas con transición de contexto por fila. Las otras tres medidas juntas tardan 189 ms.
- **Impacto:** consulta completa 10,4 s en frío (10,37 s y 10,43 s); `[Avg Ticket]` sola 10,23 s (~98 % del total).
- **Primera acción:** R1, reescribir como `AVERAGE(fact_sales[amount])`. Candidato probado en `DEFINE`: mismo valor (298,25836474) en 61 ms.

## Alcance

**Pregunta original:** "La tarjeta de Avg Ticket del informe de ventas tarda mucho en cargar" (consulta DAX con Total Sales, Margin %, Avg Ticket, Active Customers); workspace y modelo no indicados.

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Modelo `sm_sales`: medidas de la tarjeta, relaciones, modo de almacenamiento, cold vs warm | Trazas SE/FE por XMLA (no capturadas), refresco del modelo, capacidad, medidas ajenas a la tarjeta (solo se leyó su definición) |

**Hipótesis de partida:** H-a) una medida con iterador sobre la tabla de hechos; H-b) relaciones bidireccionales/muchos-a-muchos; H-c) fallback de Direct Lake.

**Recorrido:** Semantic models únicamente. No hubo señal que llevara a otra área (modelo Import, sin fallback).

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Modo de almacenamiento del modelo | Import en las 6 tablas | E3 |
| Permisos con los que se ejecutó | Lectura de metadatos y DAX por XMLA vía powerbi-modeling-mcp | E1-E9 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| sm_sales | SemanticModel | Consumo | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |
| FabricPerfLab | Workspace | | 23ca4a73-3312-4242-9714-0289816895aa |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Consulta completa, warm-up en frío | 10 366 ms | Protocolo `dax-perf-decision-guide.md` § Phase 1 Step 3 | E5 |
| Consulta completa, medida 1 (caché limpia) | 10 426 ms | idem | E6 |
| `[Avg Ticket]` sola (caché limpia) | 10 230 ms | | E7 |
| Total Sales + Margin % + Active Customers (caché limpia) | 189 ms | | E8 |
| Candidato `AVERAGE(fact_sales[amount])` | 61 ms | | E9 |
| Filas fact_sales | 11 000 000 | | E4 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces` y `GET /v1/workspaces/{ws}/items` | `sm_sales` único modelo, en FabricPerfLab |
| E2 | DAX | `INFO.VIEW.MEASURES()` | Definiciones de las 10 medidas (ver H1) |
| E3 | DAX | `INFO.VIEW.TABLES()`, `INFO.VIEW.RELATIONSHIPS()` | 6 tablas Import; `fact_sales→dim_customer` bidireccional (*<->1); `promotions<->dim_product` muchos-a-muchos bidireccional; resto unidireccional |
| E4 | DAX | `COUNTROWS` por tabla | fact_sales 11 000 000; dim_customer 165 309; dim_product 5 000; dim_store 50; dim_date 730; promotions 2 052 |
| E5 | DAX | ClearCache (20:25 UTC) + consulta de la tarjeta (warm-up) | 10 366 ms |
| E6 | DAX | ClearCache + consulta de la tarjeta | 10 426 ms (dispersión <1 %) |
| E7 | DAX | ClearCache + `ROW("Avg Ticket",[Avg Ticket])` | 10 230 ms |
| E8 | DAX | ClearCache + las otras 3 medidas | 189 ms |
| E9 | DAX | `DEFINE MEASURE ... AVERAGE(fact_sales[amount])` | 298,25836474 en 61 ms (valor idéntico a E7: 298,2583647400001) |
| E10 | DAX | `COUNTROWS(SUMMARIZE(fact_sales, sale_ts, customer_id, product_code, store_id, amount))` | 11 000 000 = filas totales: sin duplicados, equivalencia semántica |

Cinco ClearCache en total (E5 a E8, más el previo a E5), todos el 2026-11-02 entre 20:25 y 20:27 UTC; afectan a todos los usuarios del modelo.

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | `[Avg Ticket]` causa ~98 % de la latencia de la tarjeta | Alta | Alta | E2, E5-E9 |
| H2 | Relaciones bidireccionales y muchos-a-muchos: riesgo latente, no causa aquí | Baja | Media | E3, E8 |
| H3 | Otras medidas del modelo con el mismo patrón costoso (no medidas) | Media | Baja | E2 |

### H1 · `[Avg Ticket]` itera 11 M de filas con transición de contexto

- **Qué ocurre:** la consulta de la tarjeta tarda ~10,4 s; sin `[Avg Ticket]` tarda 189 ms.
- **Por qué:** `AVERAGEX(fact_sales, CALCULATE(SUM(fact_sales[amount])))` ejecuta una transición de contexto por cada una de las 11 M filas; el `CALCULATE` es innecesario porque `amount` ya es una columna de la fila. Como no hay filas duplicadas (E10), el resultado es idéntico a `AVERAGE(fact_sales[amount])` (E9). El tiempo es igual en frío y tras limpiar caché (E5-E7), por lo que no es un problema de carga de columnas.
- **Impacto:** ~10 s por cada carga de la tarjeta/página que la incluya, y carga de CPU en la capacidad por cada usuario. Umbral: no se aplica uno numérico de la skill; severidad Alta por el peso medido (98 %) según el mapeo crítico→Alta de `SKILL.md` § Workflow: Analyze Best Practices.

### H2 · Relaciones bidireccionales

`fact_sales↔dim_customer` y `promotions↔dim_product` son bidireccionales (E3), y la segunda es muchos-a-muchos. No explican esta lentitud (las otras tres medidas, incluida `Active Customers` que recorre dim_customer, tardan 189 ms), pero ensanchan el filtrado cruzado en cualquier visual. Severidad Baja según `modeling-guidelines.md` § Relationships (criterio: recomendado/opcional, sin impacto medido).

### H3 · Otras medidas con patrones caros (solo lectura de definición)

`Enterprise Sales` (FILTER sobre toda `fact_sales` con RELATED), `Sales Running Total` (`FILTER(ALL(fact_sales), ...)`), `Top 100 Customers Sales` (RANKX por cliente) siguen patrones caros sobre 11 M de filas. No están en esta tarjeta y no se midieron (Confianza Baja).

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Reescribir `[Avg Ticket]` con `AVERAGE` | H1 | Alto | Bajo | Bajo | Sí |
| R2 | Revisar medidas de H3 con el mismo protocolo | H3 | Medio | Medio | Bajo | Sí |
| R3 | Pasar relaciones bidireccionales a unidireccionales si no son necesarias | H2 | Bajo | Medio | Medio | Sí |

### R1 · Reescribir `[Avg Ticket]`

- **Cambio propuesto:**

  ```dax
  Avg Ticket = AVERAGE(fact_sales[amount])
  ```

- **Impacto esperado:** de ~10,2 s a ~0,06 s (E9; el valor candidato se midió una vez, sin repetir según el protocolo completo).
- **Cómo validarlo:** repetir E5-E6 tras el cambio (ClearCache, warm-up, 2 ejecuciones) y comprobar que el valor sigue en 298,2584 y la duración baja al orden de cientos de ms.
- **Reversión:** restaurar la expresión anterior.
- **Requiere confirmación:** Sí, modifica una medida del modelo (Tier C); lo aplica un humano o FabricAdmin.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Fallback de Direct Lake a DirectQuery | E3 | El modelo es Import en todas las tablas |
| D2 | Relaciones bidireccionales como causa principal | E3, E8 | Las otras medidas, que usan esas relaciones, tardan 189 ms |
| D3 | Caché fría / carga de columnas | E5-E7 | Los tiempos son los mismos con warm-up y con caché limpia |

## Siguientes pasos

- [ ] Aplicar R1 en el modelo — responsable: propietario del modelo · relacionado con: R1
- [ ] Repetir el análisis tras aplicar R1 para validar el impacto
- [ ] Medir las medidas de H3 si aparecen en otros visuales — responsable: analista · relacionado con: R2

## Notas

### Limitaciones

- El candidato de E9 se ejecutó una sola vez, no con el protocolo completo de `dax-perf-decision-guide.md` § Phase 2 (2 ejecuciones con caché limpia); aun así la diferencia (61 ms vs 10 230 ms) está muy por encima de cualquier ruido de banda observado (<1 %).
- Server rejection of FabricIQ MCP (401) no afectó: se usó powerbi-modeling-mcp.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Trazas SE/FE (número de consultas SE, duración) | No se capturó traza XMLA | La atribución a FE por iteración/transición de contexto se infiere de la forma de la medida y los tiempos; Confianza Alta por la medición directa del efecto |
| Definición TMDL completa (`getDefinition`) | LRO sin cuerpo vía `az rest` en esta sesión | Se usó `INFO.VIEW.*` en su lugar |
| Medidas de H3 | Fuera de la tarjeta | Sin cifras |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Ninguna detectada | | | |

## Anexo

### Consultas completas

```dax
-- E5/E6
EVALUATE ROW("Total Sales",[Total Sales],"Margin %",[Margin %],"Avg Ticket",[Avg Ticket],"Active Customers",[Active Customers])
-- E9
DEFINE MEASURE fact_sales[Avg Ticket Cand] = AVERAGE(fact_sales[amount])
EVALUATE ROW("Cand",[Avg Ticket Cand])
```

### Configuración efectiva

Valor de la tarjeta: Total Sales 3 280 842 012,14; Margin % 0,3811; Avg Ticket 298,2584; Active Customers 165 310 (dim_customer tiene 165 309 filas: hay un cliente en fact_sales sin correspondencia en la dimensión, fila en blanco; calidad de datos, no rendimiento).
