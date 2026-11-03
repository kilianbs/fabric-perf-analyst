# Resto de la página de ventas (Q2-Q5) en sm_sales: dos medidas lentas y un modelo que da cifras incorrectas

Seguimiento de [07-sm-sales-avg-ticket-lento.md](07-sm-sales-avg-ticket-lento.md) (tarjeta Avg Ticket, `[Avg Ticket]` ya diagnosticada allí; no se repite).

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-02 |
| **Áreas** | Semantic models |
| **Ámbito** | workspace `FabricPerfLab` · modelo semántico `sm_sales` |
| **Ventana analizada** | 2026-11-02 20:28 → 20:33 UTC (medición puntual en vivo) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, semantic-model-authoring |
| **Modo** | Lectura + diagnóstico activo (ClearCache) |
| **Severidad global** | Alta |
| **Confianza global** | Media |

## Resumen

- **Pregunta:** medir en frío el resto de consultas de la página (Q2-Q5) y diagnosticar `[Enterprise Sales]`, `[Sales Running Total]`, `[Top 100 Customers Sales]`, `[Sales LY]`, `[Total Sales]`, `[Margin %]` y las relaciones bidireccionales / muchos-a-muchos.
- **Conclusión:** hay dos medidas lentas, `[Sales Running Total]` (Q3, 4,05 s) y `[Top 100 Customers Sales]` (Q4, 3,41 s). Q2 y Q5 son rápidas (154 y 166 ms). Además hay un problema de corrección, más grave que la velocidad: Q5 duplica ventas entre promociones y el 17 % de las filas de `fact_sales` no tiene cliente en `dim_customer`.
- **Impacto:** Q3 y Q4 suman ~7,5 s en frío. Q5 devuelve el mismo importe para las dos promociones de cada categoría (suma por promociones 1 347 M frente a 673,5 M reales). `[Top 100 Customers Sales]` incluye el cliente "(Blank)" como el primero de la lista.
- **Primera acción:** R1, reescribir `[Sales Running Total]` con `dim_date`: 4 053 ms a 60 ms, mismos valores.

## Alcance

**Pregunta original:** revisar el resto de la página (Q2-Q5), medir en frío con ClearCache, diagnosticar las medidas implicadas y las relaciones bidireccionales / muchos-a-muchos, y proponer correcciones probadas en `DEFINE` cuando proceda.

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Q2-Q5 tal como las pegó el usuario, medidas implicadas, relaciones del modelo | Trazas SE/FE, refresco, capacidad, `[Avg Ticket]` (informe 07), cambios reales al modelo |

**Hipótesis de partida:** H-a) `Sales Running Total` con `FILTER(ALL(fact_sales))` sobre 11 M de filas; H-b) `Top 100 Customers Sales` con RANKX por cliente; H-c) `Enterprise Sales` con `FILTER`+`RELATED` sobre la tabla de hechos; H-d) relaciones bidireccionales/M:N afectan a Q2, Q4 y Q5.

**Recorrido:** Semantic models únicamente. Los hallazgos de calidad de datos (claves huérfanas) apuntan al origen (Gold) pero no se ha profundizado; ver Siguientes pasos.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Modo de almacenamiento del modelo | Import en las 6 tablas | 07 (E3) |
| Datos en el modelo | 11 días (2026-09-01 a 2026-09-13, 11 fechas distintas); `dim_date` 2026-01-01 a 2027-12-31 | E9 |
| Permisos con los que se ejecutó | Metadatos y DAX por XMLA vía powerbi-modeling-mcp | E1-E10 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| sm_sales | SemanticModel | Consumo | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Q2 en frío (50 filas devueltas) | 154 ms | Protocolo `dax-perf-decision-guide.md` § Phase 1 | E1 |
| Q3 en frío | 4 053 ms | idem | E2 |
| Q4 en frío | 3 405 ms | idem | E3 |
| Q5 en frío (16 filas) | 166 ms | idem | E4 |
| `[Enterprise Sales]` sola en frío | 79 ms | idem | E5 |
| Candidato running total en frío | 60 ms | idem | E7 |
| Candidato Top 100 en frío | 1 931 ms | idem | E8 |
| Filas de `fact_sales` sin cliente en `dim_customer` | 1 906 206 (568,5 M de ventas) | | E6 |
| Suma por promociones de Total Sales | 1 347 060 997 vs 673 530 499 real | | E10 |

### Consultas y llamadas ejecutadas

Cada medición va precedida de un `ClearCache` (modelo completo, afecta a todos los usuarios), todas el 2026-11-02 entre 20:28 y 20:32 UTC. En total 8 clears.

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | DAX | ClearCache + Q2 (con `maxRows` 5) | 154 ms; además `COUNTROWS` del mismo SUMMARIZECOLUMNS = 50 filas (50 tiendas, un solo `year_month` = 2026-09); 170 ms |
| E2 | DAX | ClearCache + Q3 (`maxRows` 3) | 4 053 ms; 11 días |
| E3 | DAX | ClearCache + Q4 | 3 405 ms; 5 ciudades |
| E4 | DAX | ClearCache + Q5 | 166 ms; 16 filas; `[Sales LY]` blanco en todas |
| E5 | DAX | ClearCache + `ROW([Enterprise Sales])` | 79 ms; 908 009 923,40 |
| E6 | DAX | `TOPN(5, SUMMARIZECOLUMNS(dim_customer[customer_id], ...))` | el primero es `customer_id` en blanco: 568 513 099,10 de ventas y 1 906 206 filas; el siguiente real, 29 892,88 y 75 filas |
| E7 | DAX | ClearCache + `DEFINE MEASURE RT Cand = CALCULATE([Total Sales], REMOVEFILTERS(fact_sales[sale_date]), dim_date[date] <= MAX(fact_sales[sale_date]))` + Q3 | 60 ms. Una ejecución previa que calculaba original y candidato a la vez (3 918 ms) dio diferencias ≤1,2e-4 en los 11 días: equivalentes |
| E8 | DAX | ClearCache + `DEFINE MEASURE Top100 Cand = SUMX(TOPN(100, VALUES(dim_customer[customer_id]), [Total Sales]), [Total Sales])` + Q4 | 1 931 ms; mismos 5 importes que el original (E3), p. ej. Sevilla 389 296 355,55 |
| E9 | DAX | rango de fechas y cobertura | 11 fechas de `fact_sales` presentes en `dim_date`; `dim_date` 2026-01-01 a 2027-12-31 |
| E10 | DAX | `COUNTROWS(promotions)`, `DISTINCTCOUNT`, suma por promociones | 2 052 filas, 1 026 productos distintos (2 filas por producto), 2 promos; ventas de productos con promoción 673 530 498,65; ventas totales 3 280 842 012,14; suma por promociones 1 347 060 997,30 |
| E11 | DAX | ventas y tiendas por ciudad | Sevilla 11 tiendas, 2 236 M de 3 281 M (68 %) |

Medidas y relaciones: definiciones y relaciones de 07 (E2, E3).

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | `[Sales Running Total]` es lenta (Q3 4,05 s) por `FILTER(ALL(fact_sales))` sobre 11 M de filas | Alta | Alta | E2, E7 |
| H2 | `[Top 100 Customers Sales]` es lenta (Q4 3,4 s) por RANKX por cliente; además incluye el cliente en blanco | Media | Alta | E3, E6, E8 |
| H3 | Q5: la relación M:N `promotions`↔`dim_product` multiplica las ventas por promoción | Alta | Alta | E4, E10 |
| H4 | 17 % de las filas de `fact_sales` sin cliente en `dim_customer` | Media | Alta | E6 |
| H5 | `[Sales LY]` devuelve blanco: no hay datos del año anterior | Baja | Media | E4, E9 |

### H1 · `[Sales Running Total]`

- **Qué ocurre:** Q3 tarda 4 053 ms en frío para solo 11 filas de resultado.
- **Por qué:** `FILTER(ALL(fact_sales), fact_sales[sale_ts] <= MAX(fact_sales[sale_ts]))` materializa y recorre las 11 M de filas para cada fecha. Filtrar `dim_date` (730 filas) da el mismo resultado a nivel de día (E7: diferencias ≤1,2e-4, ruido de coma flotante) en 60 ms. Cambia la semántica solo si se agrupa por una granularidad menor que el día.
- **Impacto:** ~4 s por carga; crece con el número de fechas del visual (una fila de resultado = un barrido completo de la tabla de hechos).

### H2 · `[Top 100 Customers Sales]`

- **Qué ocurre:** Q4 tarda 3 405 ms con solo 5 filas de resultado.
- **Por qué:** `SUMX(VALUES(customer_id), IF(RANKX(ALL(customer_id), CALCULATE(SUM(amount))) <= 100, ...))` reevalúa el ranking completo (165 k clientes) por cada cliente de cada ciudad. `TOPN(100, VALUES(customer_id), [Total Sales])` da los mismos importes en 1 931 ms (E8): mejora de ~43 %, no una solución completa.
- **Corrección:** el cliente en blanco (568,5 M de ventas, 1,9 M de filas) es el primero del ranking (E6), así que "Top 100" incluye un falso cliente; los 5 importes por ciudad incluyen esa mezcla (Sevilla, 389 M, es incoherente con un cliente real de unos 30 k).
- **Impacto:** 3,4 s por carga y cifras inflada por el cliente en blanco.

### H3 · Q5 multiplica las ventas

- **Qué ocurre:** cada categoría muestra el mismo importe para "Black Friday" y "Back to school" (p. ej. Books 90 708 474,85 en ambas); la suma sobre promociones es 1 347 M frente a 673,5 M reales, es decir ×2 (E10). Además solo se ve el 20,5 % de las ventas (673,5 M de 3 281 M), porque solo 1 026 de 5 000 productos están en promociones.
- **Por qué:** `promotions[product_code]` es "muchos" y se relaciona con `dim_product[product_code]` (M:N, bidireccional); cada producto aparece en las 2 promociones (2 052 filas, 1 026 productos), así que filtrar por promoción no reparte las ventas, las repite.
- **Impacto:** la velocidad es buena (166 ms), pero la cifra por promoción no es interpretable y un total sumado duplica ventas.

### H4 · Clientes huérfanos

1 906 206 filas (17,3 % de las 11 M) tienen `customer_id` sin correspondencia en `dim_customer` y caen en el miembro en blanco con 568,5 M de ventas (E6). Explica el 165 310 de `[Active Customers]` frente a 165 309 filas de la dimensión (07). Esto contamina `[Top 100 Customers Sales]` y cualquier análisis por cliente, y es un problema de calidad en origen.

### H5 · `[Sales LY]`

Blanco en Q5 (E4): los datos solo cubren 11 días de 2026-09 y no hay 2025 en `fact_sales`, aunque `dim_date` sí cubre desde 2026-01-01 (E9). No es un problema de rendimiento (166 ms). Es una limitación de datos, no se pudo validar el valor del candidato.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Reescribir `[Sales Running Total]` con `dim_date` | H1 | Alto | Bajo | Bajo | Sí |
| R2 | Reescribir `[Top 100 Customers Sales]` con TOPN y decidir qué hacer con el cliente en blanco | H2 | Medio | Bajo | Bajo | Sí |
| R3 | Corregir el modelo de promociones (no relacionar M:N con `dim_product`; tabla puente o medida con regla de asignación) | H3 | Alto | Medio | Medio | Sí |
| R4 | Tratar las claves huérfanas de `customer_id` en origen (Gold) | H4 | Medio | Medio | Medio | Sí |
| R5 | `[Sales LY]` sobre `dim_date`, marcada como tabla de fechas, cuando existan datos de 2025 | H5 | Bajo | Bajo | Bajo | Sí |

### R1 · `[Sales Running Total]`

```dax
Sales Running Total =
CALCULATE(
    [Total Sales],
    REMOVEFILTERS(fact_sales[sale_date]),
    dim_date[date] <= MAX(fact_sales[sale_date])
)
```

- **Impacto esperado:** 4 053 ms a 60 ms (E2, E7). Una sola ejecución del candidato; no se repitió con el protocolo completo.
- **Cómo validarlo:** repetir E2/E7 (ClearCache, warm-up, 2 ejecuciones) y comprobar que los valores coinciden con los actuales.
- **Reversión:** restaurar la expresión anterior.
- **Requiere confirmación:** Sí, modifica una medida (Tier C).

### R2 · `[Top 100 Customers Sales]`

```dax
Top 100 Customers Sales =
SUMX(TOPN(100, VALUES(dim_customer[customer_id]), [Total Sales]), [Total Sales])
```

- **Impacto esperado:** 3 405 ms a 1 931 ms (E3, E8), mismos valores. Si el negocio decide excluir el cliente en blanco, añadir `dim_customer[customer_id] <> BLANK()` cambia los importes; hay que acordarlo con negocio. Para ganar más, el origen del coste (la relación bidireccional `fact_sales`→`dim_customer`) no se probó.
- **Cómo validarlo:** repetir E3/E8 en frío.
- **Reversión:** restaurar la expresión anterior.
- **Requiere confirmación:** Sí.

### R3 · Promociones

- **Cambio propuesto:** quitar la relación `promotions`↔`dim_product` M:N bidireccional. Opciones: una tabla puente con `product_code` único y una medida que defina cómo repartir las ventas entre promociones, o aplicar la promoción por fecha/producto si existe. No se probó una medida concreta: depende de la regla de negocio.
- **Cómo validarlo:** la suma de ventas por promoción debe igualar las ventas de los productos con promoción (673,5 M) o la regla acordada.
- **Reversión:** restaurar la relación.
- **Requiere confirmación:** Sí.

### R4 y R5

- R4: auditar en Gold las filas con `customer_id` nulo o sin dimensión (1,9 M, E6) y mapearlas a un miembro "Desconocido".
- R5: tras R4/R3, sustituir `SAMEPERIODLASTYEAR(fact_sales[sale_date])` por `SAMEPERIODLASTYEAR(dim_date[date])` y marcar `dim_date` como tabla de fechas. No probado por falta de datos de 2025.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | `[Enterprise Sales]` con `FILTER`+`RELATED` es lenta | E1, E5 | 79 ms sola y 154 ms en Q2: el motor lo resuelve bien con estos volúmenes |
| D2 | `[Total Sales]` y `[Margin %]` son un problema | E1, E4 | Son agregaciones simples; en 07 las tres medidas sin Avg Ticket tardaron 189 ms |
| D3 | Las relaciones bidireccionales son la causa de la lentitud de Q2/Q5 | E1, E4 | Q2 y Q5 tardan 154 y 166 ms con esas relaciones; su efecto es sobre la corrección de Q5 (H3) |

## Siguientes pasos

- [ ] Aplicar R1 y R2 — responsable: propietario del modelo · relacionado con: R1, R2
- [ ] Decidir la regla de reparto de promociones — responsable: negocio / modelador · relacionado con: R3
- [ ] Auditar `customer_id` huérfanos en Gold — responsable: ingeniería de datos · relacionado con: R4
- [ ] Repetir el análisis tras aplicar R1-R3 para validar el impacto

## Notas

### Limitaciones

- Solo hay 11 días de datos en el modelo (2026-09-01 a 2026-09-13): Q2 devuelve 50 filas (un `year_month`). Los tiempos con un histórico real serán mayores, sobre todo Q3 y Q4. Las medidas con barrido de la tabla de hechos (H1, H2) escalarán peor que las simples.
- Los candidatos R1 y R2 se midieron una vez en frío, sin el protocolo completo de `dax-perf-decision-guide.md` § Phase 2 (2 ejecuciones). La diferencia de R1 (4 053 vs 60 ms) está muy por encima del ruido observado en 07 (<1 %); la de R2 (43 %) es más moderada.
- Cada ejecución mide una sola vez la consulta original (E1-E4).

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Trazas SE/FE | No se capturó traza XMLA | La causa de H1/H2 se atribuye por la forma de la medida y las diferencias de tiempo, no por trazas |
| Efecto de pasar `fact_sales`→`dim_customer` a unidireccional | No probado (CROSSFILTER no ejecutado) | Se desconoce cuánto del coste de Q4 viene de la relación bidireccional |
| Valor de `[Sales LY]` | No hay datos de 2025 | Candidato R5 sin validar |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Ninguna detectada | | | |

## Anexo

### Consultas completas

```dax
-- Q2 (E1), Q3 (E2), Q4 (E3), Q5 (E4): tal como las pegó el usuario.
-- E7
DEFINE MEASURE fact_sales[RT Cand] = CALCULATE([Total Sales], REMOVEFILTERS(fact_sales[sale_date]), dim_date[date] <= MAX(fact_sales[sale_date]))
EVALUATE SUMMARIZECOLUMNS(fact_sales[sale_date], "Total Sales", [Total Sales], "Cand", [RT Cand])
-- E8
DEFINE MEASURE fact_sales[Top100 Cand] = SUMX(TOPN(100, VALUES(dim_customer[customer_id]), [Total Sales]), [Total Sales])
EVALUATE SUMMARIZECOLUMNS(dim_store[city], "Cand", [Top100 Cand])
```
