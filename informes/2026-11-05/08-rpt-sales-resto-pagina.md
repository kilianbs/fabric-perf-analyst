# Resto de la página "Sales overview" de rpt_sales: qué tocar y qué no

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-05 |
| **Áreas** | Semantic models |
| **Ámbito** | workspace `FabricPerfLab` · informe `rpt_sales`, página "Sales overview" (4 visuales distintos de la tarjeta) · modelo `sm_sales` |
| **Ventana analizada** | 2026-11-05 09:55 → 10:01 UTC (benchmark en vivo) |
| **Agente / host** | Claude Code · skills: semantic-model-authoring, fabric-perf-analysis |
| **Modo** | Lectura + diagnóstico activo (ClearCache) |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** medir cada visual restante de la página y cada medida que usa, en frío y en caliente, y decir qué hay que tocar y qué no.
- **Conclusión:** además de `Avg Ticket` (ver `07-rpt-sales-avg-ticket-lento.md`), hay dos medidas lentas: `Sales Running Total` (línea, 5,7-6,0 s en frío) y `Top 100 Customers Sales` (barras, 3,6-4,0 s en frío). La matriz y la tabla son rápidas (≤ 0,17 s) y no hay que tocarlas.
- **Impacto:** suma de las consultas de los 5 visuales en frío ≈ 22 s (12,4 + 0,15 + 5,8 + 3,8 + 0,17), dominada por las tres medidas problemáticas. Con los candidatos probados (equivalentes en valor) quedaría ≈ 3,2 s.
- **Primera acción:** R1, reescribir `Sales Running Total` filtrando por `sale_date` (5,7 s a 0,07 s). Requiere confirmación; no se aplicó.

## Alcance

**Pregunta original:** "revisa el resto de la página del informe: mide cada visual (consulta DAX completa reconstruida desde visual.json) y cada medida que usa, en frío y en caliente, con varias repeticiones y SIN lanzar Execute en paralelo con ClearCache u otro Execute. Indica además qué visuales y medidas NO hace falta tocar (con la evidencia medida) y cuáles sí, con recomendación."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Matriz "Sales by store and month", línea "Daily trend", barras "Top 100 customers sales by city", tabla "Category performance with promotions"; medidas Enterprise Sales, Sales Running Total, Top 100 Customers Sales, Sales LY (más Total Sales y Margin % ya medidas en el informe 07) | Tarjeta y `Avg Ticket`: ya analizados en `07-rpt-sales-avg-ticket-lento.md`, no se repiten |

**Hipótesis de partida:** H-a) `Sales Running Total` (`FILTER(ALL(fact_sales), ...)` sobre 13 M de filas); H-b) `Top 100 Customers Sales` (`RANKX` dentro de `SUMX`); H-c) `Enterprise Sales` (`FILTER(fact_sales, RELATED(...))`); H-d) `Sales LY` con relación M2M bidireccional.

**Recorrido:** Semantic models únicamente. Las definiciones de los visuales salen de la lectura `getDefinition` del informe 07 (E2 de ese informe, reutilizada sin volver a descargar; no hay `filterConfig`). Medidas leídas de nuevo con `measure_operations Get`.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Modo de almacenamiento del modelo | Import | informe 07 (E4) |
| Tamaño | `fact_sales` 13.000.000 filas; `dim_customer` 161.879; `dim_store` 50 tiendas; `dim_product` 5.000; `promotions` 2.052; `fact_sales` tiene 13 fechas distintas y 1 `year_month` | E1 |
| Relaciones | 5; `fact_sales`→`dim_customer` y `promotions`→`dim_product` (muchos a muchos) en dirección BothDirections | E2 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| rpt_sales | Report | Consumo | 9bf2e777-02aa-4082-9a1f-02b96987de3c |
| sm_sales | SemanticModel | Modelo Import | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |

## Evidencia

### Métricas clave

Tiempos `executionTimeMs` en ms. Frío = ejecución inmediatamente posterior a `ClearCache`; caliente = repetición sin limpiar. Todas las llamadas se hicieron en serie (ver Limitaciones para una excepción menor).

| Visual (consulta reconstruida) | Medidas | Frío (ms) | Caliente (ms) | Veredicto | Evidencia |
|--------------------------------|---------|-----------|---------------|-----------|-----------|
| Matriz: `store_name` × `year_month` (50 filas) | Total Sales, Enterprise Sales, Margin % | 154 / 157 | 53 / 52 | No tocar | E3 |
| Línea: `sale_date` (13 filas) | Total Sales, Sales Running Total | 5653 / 5998 | 5712 / 5481 | Tocar | E4 |
| Barras: `city` (5 filas) | Top 100 Customers Sales | 4030 / 3611 | 3214 / 2775 | Tocar (mejora moderada) | E5 |
| Tabla: `category` × `promo_name` (16 filas) | Total Sales, Sales LY | 163 / 167 | 157 | No tocar | E6 |

| Medida (al grano del visual) | Frío (ms) | Caliente (ms) | Veredicto | Evidencia |
|------------------------------|-----------|---------------|-----------|-----------|
| Enterprise Sales (grano matriz) | 109 / 110 | 50 | No tocar en rendimiento | E3 |
| Sales Running Total (grano `sale_date`) | 5786 | 5438 | Tocar | E4 |
| Top 100 Customers Sales (grano `city`) | 4030 / 3611 | 3214 / 2775 | Tocar | E5 |
| Sales LY (grano categoría × promo) | 113 | 102 | No tocar en rendimiento | E6 |
| Total Sales y Margin % (informe 07) | 103-167 y 67-73 | 350 y 50 | No tocar | informe 07 E9, E10 |

Candidatos probados en `DEFINE` (valores equivalentes, ver E7-E9):

| Candidato | Frío (ms) | Caliente (ms) | Mejora (frío, baseline más rápido válido) | Evidencia |
|-----------|-----------|---------------|--------------------------------------------|-----------|
| Running Total con `sale_ts` y `REMOVEFILTERS` | 5745 | n/d | Sin mejora (dentro del ruido 5438-5998) | E7 |
| Running Total con `sale_date` (R1) | 71 / 60 | 55 | (5653 - 60) / 5653 = 99 % | E8 |
| Top 100 con `TOPN` (R2) | 2260 / 2148 | 1805 | (3611 - 2148) / 3611 = 41 % | E9 |

Las mejoras superan la banda de ruido de cada baseline (`dax-perf-decision-guide.md` § Phase 2, Step 3), salvo el primer candidato de Running Total.

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | DAX | `EVALUATE ROW("stores",COUNTROWS(dim_store),"months",COUNTROWS(DISTINCT(fact_sales[year_month])),"dates",COUNTROWS(DISTINCT(fact_sales[sale_date])),...)` | 50 tiendas, 1 mes, 13 fechas, 5 ciudades, 5.000 productos, 2.052 promociones; 485 ms |
| E2 | MCP | `measure_operations Get` (4 medidas) y `relationship_operations List` | `Enterprise Sales` = `CALCULATE([Total Sales], FILTER(fact_sales, RELATED(dim_customer[segment]) = "Enterprise"))`; `Sales Running Total` = `CALCULATE([Total Sales], FILTER(ALL(fact_sales), fact_sales[sale_ts] <= MAX(fact_sales[sale_ts])))`; `Top 100 Customers Sales` = `SUMX(VALUES(dim_customer[customer_id]), IF(RANKX(ALL(dim_customer[customer_id]), CALCULATE(SUM(fact_sales[amount]))) <= 100, CALCULATE(SUM(fact_sales[amount]))))`; `Sales LY` = `CALCULATE([Total Sales], SAMEPERIODLASTYEAR(fact_sales[sale_date]))`. 5 relaciones (ver Contexto) |
| E3 | DAX | Matriz: `EVALUATE SUMMARIZECOLUMNS(dim_store[store_name], fact_sales[year_month], "Total Sales",[Total Sales],"Enterprise Sales",[Enterprise Sales],"Margin %",[Margin %])`; 2 frío + 2 caliente; y solo `Enterprise Sales`: 2 frío + 1 caliente | Ver tablas. 50 filas, un único `year_month` (2026-09). Valores de ejemplo: Flagship Madrid 2.326.155.901,9 frente a ~31,6 M por tienda |
| E4 | DAX | Línea: `SUMMARIZECOLUMNS(fact_sales[sale_date], "Total Sales",[Total Sales],"Sales Running Total",[Sales Running Total])`; 2 frío + 2 caliente; solo Running Total: 1 frío + 1 caliente | Ver tablas; 13 filas |
| E5 | DAX | Barras: `SUMMARIZECOLUMNS(dim_store[city], "Top 100 Customers Sales",[Top 100 Customers Sales])`; 2 frío + 2 caliente | Ver tablas; 5 filas (Sevilla 505,5 M; Valencia 91,3 M; Madrid 61,1 M; Bilbao 42,8 M; Barcelona 42,5 M) |
| E6 | DAX | Tabla: `SUMMARIZECOLUMNS(dim_product[category], promotions[promo_name], "Total Sales",[Total Sales],"Sales LY",[Sales LY])`; 2 frío + 1 caliente; solo Sales LY: 1 frío + 1 caliente; recuento | 16 filas (8 categorías); `Sales LY` devuelve blanco en todas; recuento 159 ms |
| E7 | DAX | `DEFINE MEASURE ... RT Cand = VAR m = MAX(fact_sales[sale_ts]) RETURN CALCULATE([Total Sales], REMOVEFILTERS(fact_sales), fact_sales[sale_ts] <= m)`; equivalencia y tiempo | Diferencia 0 en las 13 fechas; tiempo en frío 5745 ms |
| E8 | DAX | `DEFINE MEASURE ... RT Cand2 = VAR m = MAX(fact_sales[sale_date]) RETURN CALCULATE([Total Sales], REMOVEFILTERS(fact_sales), fact_sales[sale_date] <= m)`; equivalencia y tiempo | Diferencia ≤ 2,2e-4 sobre valores de hasta 3,9e9 (ruido de coma flotante) en las 13 fechas; 71 / 60 ms en frío, 55 ms en caliente |
| E9 | DAX | `DEFINE MEASURE ... T100 Cand = SUMX(TOPN(100, VALUES(dim_customer[customer_id]), [Total Sales]), [Total Sales])`; equivalencia y tiempo | Diferencia 0 en las 5 ciudades; 2260 / 2148 ms en frío, 1805 ms en caliente |
| E10 | ClearCache | XMLA ClearCache sobre `sm_sales`, una antes de cada ejecución en frío | `Cache cleared successfully` en todas, entre ~09:55 y 10:00 UTC |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | `Sales Running Total` tarda 5,7-6,0 s por filtrar 13 M de filas con `FILTER(ALL(fact_sales), sale_ts <= MAX(sale_ts))` | Alta | Alta | E2, E4, E7, E8 |
| H2 | `Top 100 Customers Sales` tarda 2,8-4,0 s por `RANKX` dentro de `SUMX` sobre 161.879 clientes | Media | Alta | E2, E5, E9 |
| H3 | Matriz y tabla son rápidas; `Enterprise Sales` (patrón `FILTER(fact_sales)`) no es problema con este volumen | Baja | Alta | E3, E6 |
| H4 | Observaciones de modelo sin impacto medido: `Sales LY` en blanco, `promotions` muchos a muchos bidireccional, `dim_customer` bidireccional | Baja | Media | E2, E6 |

### H1 · Sales Running Total

- **Qué ocurre:** el visual de línea tarda 5,7-6,0 s en frío y 5,5-5,7 s en caliente. La medida sola tarda 5,8 s en frío y 5,4 s en caliente; `Total Sales` aporta una fracción despreciable (E4).
- **Por qué:** `FILTER(ALL(fact_sales), ...)` materializa la tabla de hechos entera (patrón de `DAX001`, `FILTER(Table, ...)` como argumento de filtro, y filtro con comparación contra `MAX` sobre una columna de alta cardinalidad) y se evalúa una vez por fecha (13). Probar solo `REMOVEFILTERS` con la misma columna `sale_ts` no mejora (5745 ms, E7), así que el coste está en comparar sobre la columna `sale_ts` de alta cardinalidad. Cambiar la comparación a `sale_date` (13 valores) baja el coste a 60-71 ms con el mismo resultado (E8). La atribución al predicado y a la cardinalidad de `sale_ts` es una inferencia: no se midió traza SE/FE ni la cardinalidad de `sale_ts`.
- **Impacto:** sobre 13 fechas el visual espera ~6 s; sobre más fechas el coste crece de forma lineal (una reevaluación por punto de la serie).

### H2 · Top 100 Customers Sales

- **Qué ocurre:** 3,6-4,0 s en frío y 2,8-3,2 s en caliente para 5 ciudades.
- **Por qué:** `RANKX(ALL(customer_id), CALCULATE(SUM(amount)))` dentro de un `SUMX` por cliente recalcula la clasificación para cada uno de los 161.879 clientes (patrón `DAX008`, transición de contexto en iterador). `TOPN` da el mismo resultado (diferencia 0 en las 5 ciudades, E9) en 2,1-2,3 s en frío (-41 %). La mejora es parcial: sigue siendo una consulta de 2 s porque hay que evaluar las ventas de los 162 k clientes por ciudad.
- **Impacto:** el visual de barras es el segundo más lento de la página. Severidad Media: es < 5 s, mejora moderada (sin umbral numérico en la skill; criterio `SKILL.md` § Workflow: Analyze Best Practices, recomendado → Media).

### H3 · Lo que no hay que tocar

- Matriz (E3): 154-157 ms en frío y 52-53 ms en caliente. `Enterprise Sales` aislada: 109-110 / 50 ms. Aunque usa `FILTER(fact_sales, RELATED(...))` (patrón desaconsejado, `DAX001`), con este volumen no se nota; si `fact_sales` crece mucho o la matriz se amplía, reevaluar.
- Tabla (E6): 163-167 ms en frío, 157 ms en caliente, 16 filas. `Sales LY` aislada: 102-113 ms.
- `Total Sales` y `Margin %`: ver informe 07 (≤ 350 ms).

### H4 · Observaciones de modelo (sin impacto medido)

- `Sales LY` devuelve blanco en las 16 filas (E6): hay solo 13 fechas de septiembre de 2026 (E1), así que no existe el año anterior. No es un defecto de rendimiento; comprobar si es esperado cuando haya histórico.
- En la tabla, `Total Sales` es idéntico para las dos promociones dentro de cada categoría (por ejemplo, Electronics 99.403.763,55 en "Black Friday" y en "Back to school", E6): la relación `promotions`→`dim_product` es muchos a muchos bidireccional (E2), y los importes se repiten por promoción, por lo que sumar la columna cuenta cada venta varias veces. Revisar si el negocio lo espera.
- `fact_sales`→`dim_customer` es BothDirections (E2), práctica desaconsejada en `modeling-guidelines.md` § Relationships; sin impacto medido en esta página.
- `Margin %` con `IFERROR` (informe 07, H2).

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Reescribir `Sales Running Total` con comparación por `sale_date` | H1 | Alto | Bajo | Bajo | Sí |
| R2 | Reescribir `Top 100 Customers Sales` con `TOPN` | H2 | Medio | Bajo | Bajo | Sí |
| R3 | No tocar matriz, tabla, `Enterprise Sales`, `Sales LY`, `Total Sales`, `Margin %` por rendimiento | H3 | n/a | n/a | n/a | No |
| R4 | Revisar con el negocio la relación M2M de `promotions`, las relaciones bidireccionales y el blanco de `Sales LY` | H4 | Bajo | Medio | Medio | Sí |

### R1 · Sales Running Total

- **Cambio propuesto:**

  ```dax
  Sales Running Total =
  VAR m = MAX ( fact_sales[sale_date] )
  RETURN
      CALCULATE ( [Total Sales], REMOVEFILTERS ( fact_sales ), fact_sales[sale_date] <= m )
  ```

  Equivale a la medida actual solo mientras el visual agrupe por día (`sale_date`); en un grano horario la medida actual acumula por `sale_ts` y esta no. Con más fechas, lo recomendable a largo plazo es usar `dim_date` (existe en el modelo, relacionada con `fact_sales[sale_date]`, E2) en el eje.
- **Impacto esperado:** de ~5,7 s a ~0,07 s (medido, E8).
- **Cómo validarlo:** repetir E4 (1 calentamiento + 2 corridas con ClearCache) y comprobar que los 13 valores coinciden.
- **Reversión:** restaurar la expresión anterior.
- **Requiere confirmación:** Sí: cambio de medida en el modelo (Tier C).

### R2 · Top 100 Customers Sales

- **Cambio propuesto:**

  ```dax
  Top 100 Customers Sales =
  SUMX ( TOPN ( 100, VALUES ( dim_customer[customer_id] ), [Total Sales] ), [Total Sales] )
  ```

  Con empates en el puesto 100, `TOPN` incluye todos los empatados igual que `RANKX` con la ordenación por defecto; en los datos actuales el resultado es idéntico (E9).
- **Impacto esperado:** ~3,6 s a ~2,1 s en frío (-41 %, E9). Para ir más allá habría que cambiar el modelo (por ejemplo una tabla de agregados por cliente y ciudad), con aprobación y copia del modelo.
- **Cómo validarlo:** repetir E5 y comparar los 5 valores.
- **Reversión:** restaurar la expresión anterior.
- **Requiere confirmación:** Sí: cambio de medida.

### R4 · Revisión de modelo

- Revisar si `promotions` debe filtrar ventas (y si el multiplicador por promoción es correcto) y si `dim_customer` necesita BothDirections. Es una decisión de negocio y de modelo; no se midió impacto de rendimiento.
- **Requiere confirmación:** Sí.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | `Enterprise Sales` (FILTER sobre `fact_sales` con RELATED) es lenta | E3 | 109-110 ms en frío y 50 ms en caliente |
| D2 | `Sales LY` (SAMEPERIODLASTYEAR) o la relación M2M ralentizan la tabla | E6 | 102-167 ms; el visual completo tarda 157-167 ms |
| D3 | La matriz es lenta por su número de celdas | E3 | 50 filas, 52-157 ms |
| D4 | `REMOVEFILTERS` en vez de `FILTER(ALL(...))` es suficiente para el Running Total | E7 | 5745 ms, sin mejora respecto a 5438-5998 ms |

## Siguientes pasos

- [ ] Aprobar y aplicar R1 y R2 en `sm_sales` — responsable: propietario del modelo · relacionado con: R1, R2 (más R1 del informe 07)
- [ ] Repetir los benchmarks de los visuales tras aplicar los cambios — responsable: analista · relacionado con: R1, R2
- [ ] Decidir sobre R4 con el negocio — responsable: propietario del modelo · relacionado con: R4
- [ ] Repetir el análisis tras aplicar R# para validar el impacto

## Notas

### Limitaciones

- **Consultas reconstruidas:** se reconstruyeron desde `visual.json` (sin filtros de informe, página ni visual, porque no hay `filterConfig`); no incluyen los `TOPN` de reducción de datos, la ordenación ni los subtotales que añade Power BI (`semantic-models.md` § Known traps).
- **Sin traza FE/SE:** solo se midió `executionTimeMs`; las atribuciones a patrones de FE o a la cardinalidad de `sale_ts` son inferencias contrastadas con candidatos medidos.
- **Protocolo:** ejecuciones en serie, una llamada cada vez. Única salvedad: una consulta de metadatos de relaciones (`relationship_operations List`) se envió junto a la última ejecución de la tabla (167 ms); no es una consulta DAX ni limpieza de caché, y su resultado es consistente con las otras corridas (163 / 157 ms).
- **Repeticiones:** 2 corridas en frío y 1-2 en caliente por visual (3 tiempos como mínimo en las medidas lentas); cumple la regla de 2 corridas medidas con dispersión < 20 % (`dax-perf-decision-guide.md` § Phase 1, Step 3), salvo la tabla (frío 163/167, caliente 157, y matriz 154/157) que están dentro del ruido.
- **Efecto sobre otros usuarios:** cada `ClearCache` actúa sobre toda la base de datos y afecta a todos los usuarios de `sm_sales` (`semantic-models.md` § Known traps); en modo Import "frío" significa caché del Storage Engine vacía, no carga desde disco.
- **Datos limitados:** el modelo solo tiene 13 fechas (septiembre de 2026). El coste de H1 y H2 crecerá con el histórico; no se extrapola.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Traza SE/FE y número de consultas SE | No capturada | Mecanismo inferido por contraste con candidatos |
| Cardinalidad de `fact_sales[sale_ts]` | No consultada | La explicación de H1 por cardinalidad es inferencia (el contraste con `sale_date` es medido) |
| Tiempos reales de render en Power BI (Performance Analyzer) | No disponible | Se midió la DAX equivalente |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Mecanismo de ClearCache | La skill no nombra el mecanismo | XMLA ClearCache actúa sobre toda la base de datos | Ejecutado como Tier B y registrado en E10 |

## Anexo

### Consultas completas

```dax
-- Matriz (E3)
EVALUATE
SUMMARIZECOLUMNS (
    dim_store[store_name], fact_sales[year_month],
    "Total Sales", [Total Sales], "Enterprise Sales", [Enterprise Sales], "Margin %", [Margin %]
)

-- Línea (E4)
EVALUATE
SUMMARIZECOLUMNS ( fact_sales[sale_date], "Total Sales", [Total Sales], "Sales Running Total", [Sales Running Total] )

-- Barras (E5)
EVALUATE
SUMMARIZECOLUMNS ( dim_store[city], "Top 100 Customers Sales", [Top 100 Customers Sales] )

-- Tabla (E6)
EVALUATE
SUMMARIZECOLUMNS (
    dim_product[category], promotions[promo_name],
    "Total Sales", [Total Sales], "Sales LY", [Sales LY]
)
```
