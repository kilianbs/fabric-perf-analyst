# sm_sales: revisión de buenas prácticas de modelado e integridad de claves

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-05 |
| **Áreas** | Semantic models → Delta tables (traza del origen de las claves huérfanas) |
| **Ámbito** | workspace `FabricPerfLab` · modelo `sm_sales` · lakehouses `lh_gold` y `lh_silver` (solo lectura) |
| **Ventana analizada** | 2026-11-05 10:05 → 10:31 UTC (estado actual); historial Delta desde 2026-10-30 |
| **Agente / host** | Claude Code · skills: semantic-model-authoring, spark-cli, sqldw-cli, fabric-perf-analysis |
| **Modo** | Lectura + diagnóstico activo (Livy, ClearCache) |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** si `sm_sales` cumple las buenas prácticas de modelado (tipos, columnas calculadas, ubicación de medidas, patrones DAX, tabla de fechas, relaciones) y, si hay problemas de integridad, de dónde vienen.
- **Conclusión:** no las cumple. El problema más grave es de datos, no de modelado: 38.121 `customer_id` de `fact_sales` no existen en `dim_customer` (19,05 % de las ventas, 738,7 M de 3.877,2 M). Los borra el `MERGE` de `lh_silver.customers` (`op = 'D'` hace `delete`) y `gold.dim_customer` se reconstruye cada día desde ahí, mientras `fact_sales` conserva el historial. Efectos medidos: `Active Customers` da 161.880 frente a 200.000 clientes reales, y `Top 100 Customers Sales` es en realidad el miembro en blanco más 99 clientes (503 M de 505 M en Sevilla).
- **Además:** `dim_date` existe pero no está marcada como tabla de fechas ni se usa en medidas ni visuales; 2 de 5 relaciones (40 %) son bidireccionales o muchos-a-muchos (umbral < 30 %); los importes son `Double`; y el refresco programado falla desde 2026-11-04 05:30 UTC (`The 'category' column does not exist in the rowset`), así que el modelo lleva dos días desfasado respecto al lakehouse.
- **Primera acción:** R1, dejar de borrar clientes en el `MERGE` (borrado lógico) para que `fact_sales` no pierda su dimensión. Requiere confirmación; no se aplicó.

## Alcance

**Pregunta original:** "varias medidas filtran sobre fact_sales en lugar de una tabla de fechas. ¿Cumple el modelo las buenas prácticas de modelado? Revisa: (1) tipos de datos de columnas, también de las claves de relación en ambos lados; (2) columnas calculadas; (3) en qué tabla viven las medidas; (4) patrones DAX de TODAS las medidas aunque sean rápidas; (5) tabla de fechas; (6) relaciones. Si ves problemas de integridad, rastrea su origen en el lakehouse con lecturas."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Las 6 tablas, 44 columnas, 10 medidas y 5 relaciones de `sm_sales`; integridad de claves; origen en `lh_gold` y `lh_silver` (`customers`, `dim_customer`, `fact_sales`) | Causa del fallo de refresco (solo se registra, ver H2 y Notas); tamaño en memoria por columna (no obtenido); roles RLS (el modelo tiene 0) |

**Hipótesis de partida:** H-a) medidas y visuales filtran por columnas de `fact_sales` en vez de por `dim_date`; H-b) la diferencia 161.880 vs 161.879 es una clave huérfana (miembro en blanco) con origen en el lakehouse; H-c) tipos `Double` y columnas calculadas pesadas sobre la fact de 13 M de filas.

**Recorrido:** Semantic models (metadatos, DAX, relaciones) → los 38.121 huérfanos apuntan al lakehouse → Delta tables (`DESCRIBE HISTORY` de `dim_customer`, `fact_sales` y `lh_silver.customers`) → vuelta al modelo para medir el efecto en las medidas.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Modo de almacenamiento | Import (6 particiones M contra el SQL endpoint de `lh_gold`) | E1, E2 |
| Tamaño del modelo | 13.000.000 filas en `fact_sales`; 6 tablas, 44 columnas, 10 medidas, 5 relaciones, 0 roles, 0 perspectivas | E1, E3 |
| Estado de los datos | Modelo: 13 M filas, 13 fechas (hasta 2026-09-15), 161.879 clientes. Lakehouse: 15 M filas, 15 fechas (hasta 2026-09-17), 158.950 clientes | E3, E9 |
| Permisos con los que se ejecutó | Lectura de metadatos por MCP y `INFO.VIEW.*` correctas; `INFO.VIEW.PARTITIONS`, `INFO.VIEW.CALCULATIONGROUPS` y `INFO.STORAGETABLECOLUMNS` no disponibles (ver Notas) | E2 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| sm_sales | SemanticModel | Consumo | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |
| lh_gold | Lakehouse | Gold (origen del modelo) | 3aee923d-121b-415b-872c-4d5bb70664c0 |
| lh_silver | Lakehouse | Silver (`customers`) | b01f7911-28fd-4dc2-ac51-1d19ed841238 |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Clientes de `fact_sales` sin `dim_customer` (modelo) | 38.121 ids · 2.476.869 filas (19,05 % de 13 M) | `modeling-guidelines.md` § Maintenance (corregir violaciones de integridad referencial) | E5 |
| Ventas de esos huérfanos | 738.675.648,76 de 3.877.208.385,60 (19,05 %) | ídem | E6 |
| Clientes en `fact_sales` frente a `Active Customers` | 200.000 frente a 161.880 | ídem | E6 |
| Top 100 con y sin miembro en blanco (Sevilla) | 505.463.216,70 frente a 2.318.421,94 | ídem | E7 |
| Huérfanos en el lakehouse actual | 41.050 ids · 3.077.675 filas de 15 M; `dim_customer` 158.950 (de 200.000 en v0) | ídem | E9, E10 |
| Relaciones bidireccionales o M2M | 2 de 5 (40 %) | < 30 % (`modeling-guidelines.md` § Relationships) | E4 |
| Columnas calculadas | 2 (`line_margin`, `year_month`) sobre 13 M de filas | revisar si > 5 (`modeling-guidelines.md` § Performance Guidelines); pasar al origen | E2 |
| Columnas `Double` | 8 (fact: `unit_price`, `unit_cost`, `discount`, `amount`, `line_margin`; `dim_product`: `list_price`, `unit_cost`) | "Avoid `Double`" (`modeling-guidelines.md` § Table Columns) | E2, E8 |
| Refresco programado | Fallido en 3 de los 3 últimos programados (2026-11-04 05:30, 2026-11-05 04:30 y 05:30 UTC) | `SKILL.md` § TROUBLESHOOTING | E11 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | MCP | `INFO.VIEW.TABLES()`; `partition_operations List/Get`; `model_operations Get/GetStats` | 6 tablas, todas `Import`, `DataCategory = Regular` (incluida `dim_date`); particiones M `Sql.Database(<endpoint de lh_gold>, "lh_gold")` por tabla; 0 roles; sin tablas `LocalDateTable_*` |
| E2 | DAX | `INFO.VIEW.COLUMNS()` (44 filas) | Tipos, `SummarizeBy`, columnas ocultas y expresiones calculadas. Ninguna columna oculta salvo `RowNumber`; claves con `SummarizeBy = Sum` (`customer_id`, `store_id`); sin `SortByColumn`; `line_margin = fact_sales[amount] - fact_sales[quantity] * fact_sales[unit_cost]` y `year_month = FORMAT(fact_sales[sale_date], "yyyy-MM")` |
| E3 | DAX | `ROW(COUNTROWS...)` de integridad y rango (modelo) | `dim_customer` 161.879 filas únicas; `dim_product` 5.000; `dim_store` 50; `dim_date` 730 (2026-01-01 → 2027-12-31, contiguas); `fact_sales` fechas 2026-09-01 → 09-15; `sale_ts` 1.123.190 distintos, `sale_id` 13.000.000 distintos; huérfanos de producto, tienda y fecha: 0; `promotions` 2.052 filas con 1.026 códigos |
| E4 | DAX | `INFO.VIEW.RELATIONSHIPS()` | 5 relaciones: `fact_sales`→`dim_customer` Many/One **BothDirections**; `fact_sales`→`dim_product`, `dim_store`, `dim_date` Many/One OneDirection; `promotions`→`dim_product` **Many/Many BothDirections**; todas activas |
| E5 | DAX | `COUNTROWS(FILTER(fact_sales, ISBLANK(RELATED(dim_customer[customer_id]))))`, `EXCEPT(DISTINCT(fact_sales[customer_id]), DISTINCT(dim_customer[customer_id]))` | 2.476.869 filas huérfanas; 38.121 ids distintos; 0 `customer_id` nulos en la fact |
| E6 | DAX | `DISTINCTCOUNT(fact_sales[customer_id])`, `[Active Customers]`, ventas con miembro en blanco, `[Enterprise Sales]` | 200.000 frente a 161.880; ventas huérfanas 738.675.648,76; `Enterprise Sales` 1.048.992.245,13 |
| E7 | DAX | `Top 100` original frente a `TOPN(100, FILTER(VALUES(customer_id), NOT ISBLANK(...)), [Total Sales])` por ciudad | Sevilla 505,5 M frente a 2,3 M (miembro en blanco: 503,2 M); Valencia 91,3 M frente a 0,71 M (en blanco: 90,6 M); Madrid 61,1 M frente a 0,56 M (60,5 M); Bilbao 42,8 M frente a 0,46 M (42,4 M); Barcelona 42,5 M frente a 0,46 M (42,0 M) |
| E8 | SQL | `INFORMATION_SCHEMA.COLUMNS` de `lh_gold` | Importes `float` en origen; `product_code` `varchar`; `customer_id`/`store_id` `int`; `sale_date`/`dim_date.date` `date`; `sale_ts` `datetime2` |
| E9 | SQL | Integridad en `lh_gold`: `fact_sales` frente a `dim_customer` | `fact_sales` 15.000.000 filas (2026-09-01 → 09-17, 15 fechas); `dim_customer` 158.950 filas únicas (ids 1..200.000); 3.077.675 filas y 41.050 ids huérfanos; 0 nulos; `updated_at` máx 2026-11-05 05:01 |
| E10 | Livy | Sesión creada en `lh_gold` (10:20:59 UTC, eliminada a las 10:26 UTC, pool por defecto, sin `conf`); `DESCRIBE HISTORY dim_customer`, `fact_sales`, `lh_silver.customers`; `DESCRIBE DETAIL` | `dim_customer`: 15 versiones, todas `CREATE OR REPLACE TABLE AS SELECT`; filas 200.000 (v0) → 195.833 → 191.995 → 188.377 → 184.971 → 178.994 → 176.230 → 173.785 → 171.419 → 169.227 → 165.309 → 163.525 → 161.879 (v12, 2026-11-03 08:27) → 160.334 → 158.950 (v14, 2026-11-05 05:27). `lh_silver.customers`: 16 versiones, `MERGE` con `matchedPredicates` `op = 'D'` → `delete` y `op = 'U'` → `update`/`insert`; `numTargetRowsDeleted` por carga 4.167, 4.014, 4.019, 3.973, 7.429, 3.795, 3.614, 3.620, 3.623, 6.892, 3.477, 3.402, 3.391, 3.364. `fact_sales`: 12.000.000 → 15.000.000 filas, solo crece |
| E11 | REST | `GET /v1.0/myorg/groups/{ws}/datasets/{id}/refreshes?$top=8` (Power BI) | Fallidos (programado) 2026-11-04 05:30, 2026-11-05 04:30 y 05:30 UTC con `The 'category' column does not exist in the rowset`; último completado 2026-11-04 05:31 UTC (API mejorada); anteriores completados |
| E12 | DAX | Candidatos en `DEFINE` (ver Anexo) y ClearCache entre ejecuciones en frío | Resultados en la tabla de patrones DAX |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | 38.121 clientes de `fact_sales` no existen en `dim_customer`; el origen es el borrado en el `MERGE` de silver y la reconstrucción diaria de la dimensión; falsea 3 medidas | Alta | Alta | E5, E6, E7, E9, E10 |
| H2 | El refresco programado falla desde 2026-11-04 05:30 UTC y el modelo está desfasado | Alta | Media | E11, E3, E9 |
| H3 | La tabla de fechas existe pero no está marcada ni se usa: medidas y visuales filtran sobre columnas de `fact_sales` | Media | Alta | E1, E2, E4, E12 |
| H4 | 40 % de relaciones bidireccionales o M2M; `promotions` duplica ventas entre promociones y no usa sus fechas | Media | Alta | E3, E4 |
| H5 | Tipos: importes en `Double`, claves de producto en texto, `sale_id` y `sale_ts` de alta cardinalidad, claves visibles y sumables | Media | Alta | E2, E3, E8, Notas |
| H6 | Dos columnas calculadas sobre la fact de 13 M de filas que deberían venir del origen o de `dim_date` | Media | Alta | E2 |
| H7 | Higiene de medidas y de nombres: sin `formatString` en 8 de 10, sin descripciones, `IFERROR`, nombres técnicos | Baja | Alta | E1, E12 |

### H1 · Claves huérfanas en fact_sales: origen y efecto

- **Qué ocurre:** en el modelo, 2.476.869 filas (19,05 %) y 738,7 M de ventas pertenecen a 38.121 clientes que no están en `dim_customer`; Power BI los agrupa en un único miembro en blanco. De ahí `Active Customers` = 161.880 (161.879 + el blanco) cuando `fact_sales` tiene 200.000 clientes distintos. En el lakehouse de hoy son 41.050 ids y 3.077.675 filas de 15 M (E5, E6, E9).
- **Por qué:** `lh_silver.customers` recibe un CDC con `op` (`D` borra, `U` actualiza o inserta) y su `MERGE` hace `delete` físico en cada carga (de 3.364 a 7.429 filas por carga, E10). `gold.dim_customer` se vuelve a crear entero (`CREATE OR REPLACE TABLE AS SELECT`) desde silver y por eso baja de 200.000 a 158.950 filas, mientras que `gold.fact_sales` se reescribe solo hacia arriba (12 M → 15 M) y conserva a los clientes borrados. Los ids borrados son los que faltan del rango 1..200.000 (200.000 - 158.950 = 41.050, igual que los huérfanos de E9). El modelo (161.879 clientes) coincide con la versión 12 de la dimensión, no con la actual (E10, E11).
- **Impacto:** (a) `Active Customers` subestima en 38.120 clientes (19 %); (b) `Top 100 Customers Sales` no es el top 100 de clientes: contiene el miembro en blanco, que aporta 503,2 M de 505,5 M en Sevilla (99,5 %) y entre el 98,9 % y el 99,2 % en las demás ciudades, de modo que los otros 99 clientes suman 0,5-2,3 M; (c) `Enterprise Sales` no cuenta las ventas de los clientes borrados porque no tienen segmento; (d) cada gráfico por segmento o cliente mostraría un grupo en blanco con el 19 % de las ventas. Severidad Alta: afecta a la corrección de cifras visibles (`modeling-guidelines.md` § Maintenance exige corregir las violaciones de integridad referencial; sin umbral numérico en la skill, se justifica por el 19 % medido).

### H2 · Refresco fallido y modelo desfasado

- **Qué ocurre:** los tres últimos refrescos programados fallan con `The 'category' column does not exist in the rowset`; el último completado es del 2026-11-04 05:31 UTC. El modelo tiene 13 M filas y datos hasta 2026-09-15 cuando el lakehouse tiene 15 M y hasta 2026-09-17 (E3, E9, E11).
- **Por qué:** no trazado. `category` es una columna de `dim_product`, que hoy sí existe en `lh_gold` (E8). La skill indica comparar el esquema de la tabla por versión Delta y el código del escritor antes de sospechar de la sincronización del SQL endpoint (`semantic-models.md` § Known traps). No se hizo (ver Notas). Además, hay una incoherencia no explicada: el refresco completado del 2026-11-04 05:31 debería haber cargado la v13 de `fact_sales` (14 M) y el modelo tiene 13 M.
- **Impacto:** las cifras de esta página y de los informes 07 y 08 corresponden a datos de hace dos días. Confianza Media por no haberse trazado la causa.

### H3 · Tabla de fechas

- **Qué hay:** `dim_date` (730 días contiguos de 2026-01-01 a 2027-12-31, columnas `date`, `year`, `month`, `month_name`, `weekday`) relacionada Many→One con `fact_sales[sale_date]`. Falta: marcarla como tabla de fechas (`DataCategory` es `Regular`, `date` sin `IsKey`), trimestre/día y `year_month`, ordenar `month_name` y `weekday` (sin `SortByColumn`), y `year`/`month` siguen sumables (`modeling-guidelines.md` § Date/Calendar Table).
- **Qué se usa:** ninguna medida ni visual referencia `dim_date`. `Sales LY` aplica `SAMEPERIODLASTYEAR(fact_sales[sale_date])`, `Sales Running Total` hace `FILTER(ALL(fact_sales), fact_sales[sale_ts] <= MAX(fact_sales[sale_ts]))`, y la matriz y la línea agrupan por `fact_sales[year_month]` y `fact_sales[sale_date]` (informe 08).
- **Medido:** el acumulado reescrito sobre `dim_date` (con la fecha de `dim_date` en el eje) da los mismos 13 valores (diferencia ≤ 2,2e-4 sobre importes de 3,9e9) y tarda 63 y 73 ms en frío, frente a 5,4-6,0 s de la medida actual sobre `fact_sales` (informe 08) (E12). Hay que añadir `IF(NOT ISBLANK([Total Sales]), ...)` para que el eje no se extienda hasta 2027.
- **Severidad Media:** impacto de rendimiento medido (99 %), sin umbral numérico en la skill (`SKILL.md` § Workflow: Analyze Best Practices, recomendado → Media). `Sales LY` no se puede validar con datos: no hay año anterior y devuelve blanco en todas las filas (informe 08).

### H4 · Relaciones

- 2 de 5 relaciones (40 %) son bidireccionales o muchos-a-muchos; el umbral de la skill es < 30 % (`modeling-guidelines.md` § Relationships). `fact_sales`→`dim_customer` es BothDirections sin que ninguna medida lo necesite (todas filtran de dimensión a hecho): ninguna medida depende del filtro inverso.
- `promotions`→`dim_product` es M2M bidireccional por `product_code`. `promotions` tiene 2.052 filas para 1.026 códigos (2 promociones por producto); `dim_product` es único por `product_code` (5.000 distintos). Por eso en la tabla de la página `Total Sales` es igual para las dos promociones de una categoría (informe 08): cada venta cuenta una vez por promoción, sin tener en cuenta `promo_start` ni `promo_end`, que no participan en ninguna relación ni medida.
- No hay relaciones inactivas ni tablas desconectadas; los huérfanos de producto, tienda y fecha son 0 (E3).

### H5 · Tipos de datos

| Columna | Tipo en el modelo (origen) | Valoración |
|---------|----------------------------|------------|
| `fact_sales`: `unit_price`, `unit_cost`, `discount`, `amount`; `line_margin` (calculada); `dim_product`: `list_price`, `unit_cost` | `Double` (`float`) | Evitar `Double`: usar `Decimal` (`modeling-guidelines.md` § Table Columns). Efecto observado: la misma `Avg Ticket` devolvió 298,2467988923078, 298,24679889230737 y 298,24679889230765 en distintas ejecuciones (informe 07), y el acumulado de un día 596096242,0900016, 596096242,0899997 y 596096242,0899968 (informe 08): la suma de flotantes no es determinista |
| Claves enteras: `customer_id`, `store_id` (fact y dimensión) | `Int64` en ambos lados | Correcto. Pero visibles y con `SummarizeBy = Sum` en las 4 columnas; deberían estar ocultas y en `None` |
| `product_code` (fact, `dim_product`, `promotions`) | Texto en los tres | Mismo tipo en ambos lados (correcto), pero se prefiere clave entera (`modeling-guidelines.md` § Relationships); 5.000 productos |
| `sale_date` (fact) ↔ `date` (`dim_date`) | Fecha en ambos | Correcto |
| `sale_id` | Texto, 13.000.000 distintos | Columna de máxima cardinalidad que ninguna medida ni visual usa: candidata a eliminar |
| `sale_ts` | Fecha y hora, 1.123.190 distintos | Cardinalidad alta; solo la usa `Sales Running Total`. Dividir en fecha y hora o eliminar (`modeling-guidelines.md` § Table Columns) |
| `quantity`, `year`, `month` | Entero con `SummarizeBy = Sum` | `year` y `month` deberían ser `None` |

### H6 · Columnas calculadas

Hay 2, por debajo del umbral de revisión de 5 (`modeling-guidelines.md` § Performance Guidelines), pero ambas se evalúan sobre 13 M de filas en cada refresco: `line_margin` (`amount - quantity * unit_cost`, base de la medida `Margin`) y `year_month` (`FORMAT(sale_date, "yyyy-MM")`, texto). La guía pide pasar al origen lo que se pueda: `line_margin` como columna de `gold.fact_sales` (tipo decimal) y `year_month` como atributo de `dim_date`, de modo que la matriz agrupe por `dim_date`. No son agregaciones ni filtros de contexto, así que como medida no es lo que corresponde.

### H7 · Medidas: ubicación, formato y nombres

Las 10 medidas viven en `fact_sales`. La skill pide distribuir las medidas entre tablas relevantes y evitar una tabla única de medidas (`modeling-guidelines.md` § Measures & DAX), así que, según la skill, esto no es un incumplimiento (ver Notas por la discrepancia con la práctica habitual de una tabla de medidas dedicada). Sí faltan `formatString` (solo `Total Sales` y `Total Quantity` lo tienen), `description` y `displayFolder`; las columnas base de las medidas no están ocultas ni `discourageImplicitMeasures` está activo (E1, E2); los nombres de objeto usan `snake_case` y prefijos técnicos (`fact_`, `dim_`) en contra de `modeling-guidelines.md` § Naming Conventions.

### Patrones DAX de todas las medidas (catálogo de `dax-perf-patterns.md`)

| Medida | Expresión (resumen) | Patrón / valoración | Medido |
|--------|---------------------|---------------------|--------|
| Total Sales | `SUM(fact_sales[amount])` | Correcta | 103-167 ms (informe 07) |
| Total Quantity | `SUM(fact_sales[quantity])` | Correcta | no medida por separado |
| Margin | `SUM(fact_sales[line_margin])` | Correcta; depende de la columna calculada (H6) | n/d |
| Margin % | `IFERROR([Margin] / [Total Sales], 0)` | Usar `DIVIDE` (`dax-guidelines.md`: preferir `DIVIDE`, evitar `IFERROR`) | 67-73 ms (informe 07) |
| Enterprise Sales | `CALCULATE([Total Sales], FILTER(fact_sales, RELATED(dim_customer[segment]) = "Enterprise"))` | DAX001: `FILTER(Tabla)` como filtro. Candidato `CALCULATE([Total Sales], dim_customer[segment] = "Enterprise")`: mismo valor (1.048.992.245,13), 93 ms en frío frente a 109-110 ms: sin ganancia a este volumen. Excluye a los clientes borrados (H1) | E12 |
| Avg Ticket | `AVERAGEX(fact_sales, CALCULATE(SUM(amount)))` | DAX008 / DAX015; candidato `AVERAGE(amount)` (informe 07) | 12,4 s en frío |
| Sales Running Total | `CALCULATE([Total Sales], FILTER(ALL(fact_sales), sale_ts <= MAX(sale_ts)))` | DAX001 sobre toda la fact; preferir `REMOVEFILTERS` y `dim_date` (H3) | 5,4-6,0 s frente a 63-73 ms con el candidato |
| Top 100 Customers Sales | `SUMX(VALUES(customer_id), IF(RANKX(ALL(customer_id), CALCULATE(SUM(amount))) <= 100, CALCULATE(SUM(amount))))` | DAX008 (transición de contexto en iterador); candidato `TOPN` (informe 08). Incluye el miembro en blanco (H1) | 3,6-4,0 s en frío |
| Active Customers | `COUNTROWS(FILTER(VALUES(customer_id), CALCULATE(COUNTROWS(fact_sales)) > 0))` | DAX008 / DAX015; el valor es incorrecto por H1; con la integridad arreglada bastaría `DISTINCTCOUNT(fact_sales[customer_id])` (DAX011/DAX014) | 277-1.190 ms |
| Sales LY | `CALCULATE([Total Sales], SAMEPERIODLASTYEAR(fact_sales[sale_date]))` | Debe usar la columna de `dim_date` marcada como tabla de fechas (H3) | 102-113 ms; blanco por falta de datos |

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Borrado lógico de clientes en el `MERGE` de `lh_silver.customers` y mantenerlos en `gold.dim_customer` | H1 | Alto | Medio | Medio | Sí |
| R2 | Averiguar y corregir el fallo `category` del refresco y refrescar el modelo | H2 | Alto | Medio | Bajo | Sí |
| R3 | Marcar `dim_date` como tabla de fechas, completarla y usarla en medidas y visuales | H3 | Alto | Medio | Medio | Sí |
| R4 | Relaciones: `dim_customer` a una dirección y rediseñar `promotions` (fechas de vigencia) | H4 | Medio | Medio | Medio | Sí |
| R5 | Tipos: importes a `Decimal` en el origen, claves ocultas y sin suma, quitar `sale_id` y dividir `sale_ts` | H5 | Medio | Medio | Medio | Sí |
| R6 | Mover `line_margin` y `year_month` al origen / `dim_date` | H6 | Bajo | Medio | Bajo | Sí |
| R7 | Higiene de medidas: `DIVIDE`, `formatString`, descripciones, carpetas, nombres, `discourageImplicitMeasures` | H7 | Bajo | Bajo | Bajo | Sí |

### R1 · Dejar de perder la dimensión de clientes

- **Cambio propuesto:** en el `MERGE` de `silver.customers`, convertir la rama de borrado en actualización de una marca y no borrar la fila. Ejemplo ilustrativo (a adaptar al código real de `nb_02`, que este informe no ha leído línea a línea):

  ```sql
  WHEN MATCHED AND s.op = 'D' THEN UPDATE SET t.is_deleted = true, t.updated_at = s.updated_at
  WHEN MATCHED AND s.op = 'U' THEN UPDATE SET *   -- con is_deleted = false
  WHEN NOT MATCHED AND s.op = 'U' THEN INSERT *    -- con is_deleted = false
  ```

  En `gold.dim_customer` conservar las filas (con el indicador) y, para los 41.050 ids ya perdidos, recuperarlos desde bronze o añadir una fila "Desconocido" para que `fact_sales` siempre encuentre su clave (comprobar primero con negocio si el borrado debe ser real por motivos legales, p. ej. protección de datos).
- **Impacto esperado:** huérfanos 41.050 → 0; `Active Customers` pasa de 161.880 a 200.000 y el Top 100 deja de contener el miembro en blanco.
- **Cómo validarlo:** repetir E5 y E9 (huérfanos = 0) y E6/E7 tras el refresco.
- **Reversión:** volver al `MERGE` anterior.
- **Requiere confirmación:** Sí: cambio de código y de datos en bronze-silver-gold; lo aplica un humano o `FabricDataEngineer`.

### R2 · Refresco

- **Cambio propuesto:** comparar el esquema de `gold.dim_product` por versión Delta (`DESCRIBE HISTORY` y esquema por versión) y el escritor (`nb_03`) con las columnas que espera el modelo; el síntoma intermitente suele seguir a un esquema que cambia entre ejecuciones (`semantic-models.md` § Known traps). Después, refrescar.
- **Impacto esperado:** modelo al día (15 M filas).
- **Cómo validarlo:** `GET .../refreshes` con estado `Completed` y `COUNTROWS(fact_sales)` = 15.000.000 (o el valor vigente).
- **Reversión:** n/a.
- **Requiere confirmación:** Sí: el refresco es un cambio (Tier C).

### R3 · Tabla de fechas

- **Cambio propuesto:** `dim_date`: `dataCategory = Time`, `date` como clave (`isKey`), añadir trimestre, día y `year_month`, `sortByColumn` para `month_name` y `weekday`, `year`/`month` sin suma. Medidas:

  ```dax
  Sales Running Total =
  IF ( NOT ISBLANK ( [Total Sales] ),
      VAR m = MAX ( dim_date[date] )
      RETURN CALCULATE ( [Total Sales], REMOVEFILTERS ( dim_date ), dim_date[date] <= m ) )

  Sales LY = CALCULATE ( [Total Sales], SAMEPERIODLASTYEAR ( dim_date[date] ) )
  ```

  y cambiar los ejes de matriz y línea a `dim_date`.
- **Impacto esperado:** el acumulado pasa de ~5,7 s a ~0,07 s (medido, E12); `Sales LY` queda sobre una tabla de fechas válida (no verificable hasta que haya datos del año anterior).
- **Cómo validarlo:** repetir el benchmark de la línea (informe 08, E4) y comparar los valores.
- **Reversión:** restaurar las medidas y el eje anteriores.
- **Requiere confirmación:** Sí: cambia el modelo, el informe y la fuente de `dim_date`.

### R4, R5, R6, R7

- **R4:** `fact_sales`→`dim_customer` a `OneDirection`; para `promotions`, resolver con negocio qué significa "venta de una promoción" (producto y fecha entre `promo_start` y `promo_end`) y modelarlo para que no duplique ventas ni sea M2M bidireccional.
- **R5:** en `lh_gold` convertir los importes a `decimal(18,4)` (el modelo mapea a `Decimal`), ocultar claves y columnas base, `SummarizeBy = None`, activar `discourageImplicitMeasures`, eliminar `sale_id` si no se usa y separar fecha y hora de `sale_ts`.
- **R6:** `line_margin` como columna de `gold.fact_sales` (decimal) y `year_month` en `dim_date`.
- **R7:** `Margin % = DIVIDE([Margin], [Total Sales], 0)`; `formatString` en las 8 medidas sin él; descripciones y `displayFolder`; nombres legibles (`Sales`, `Customers`...).
- **Impacto esperado, validación y reversión (R4-R7):** mejora de exactitud y de memoria; validar repitiendo E2, E4 y los benchmarks de los informes 07 y 08; revertir restaurando el esquema/definición previos. **Requiere confirmación:** Sí en los cuatro (cambios de modelo o de datos).

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Claves duplicadas en `dim_customer` o `dim_product` | E3, E9 | 161.879 y 158.950 filas únicas en `dim_customer`; 5.000 productos únicos |
| D2 | Huérfanos de producto, tienda o fecha | E3 | 0 filas en cada caso |
| D3 | Tipos distintos en las claves de relación | E2, E8 | Mismo tipo en ambos lados de las 5 relaciones |
| D4 | La diferencia 161.880 / 161.879 es un duplicado | E3, E6 | Es el miembro en blanco por 38.121 ids sin dimensión |
| D5 | Tablas de fecha automáticas ocultas (`LocalDateTable_*`) | E1 | No hay: solo 6 tablas |
| D6 | Hay huecos en `dim_date` | E3 | 730 fechas distintas contiguas, 2026-01-01 → 2027-12-31 |

## Siguientes pasos

- [ ] Decidir con negocio si los clientes borrados deben conservarse (R1) — responsable: propietario de datos · relacionado con: R1
- [ ] Aplicar R1 en `nb_02`/`nb_03` — responsable: ingeniería de datos · relacionado con: R1
- [ ] Trazar el fallo de `category` y refrescar — responsable: propietario del modelo · relacionado con: R2
- [ ] Aprobar R3 y los cambios de modelo R4-R7 — responsable: propietario del modelo · relacionado con: R3-R7
- [ ] Repetir el análisis tras aplicar R# para validar el impacto

## Notas

### Limitaciones

- Las cifras del modelo corresponden a los datos cargados antes del último refresco fallido (13 M filas); las del lakehouse a hoy (15 M). No son comparables fila a fila (H2).
- No se capturó traza FE/SE; los tiempos son `executionTimeMs` de la herramienta (informe 08, Limitaciones).
- Los candidatos de este informe se probaron en `DEFINE`; el tiempo del acumulado sobre `dim_date` con la medida original (56 s en la consulta de comparación, que evalúa ambas) no está aislado y no se usa como cifra.
- Livy: una sola sesión en `lh_gold` (creada 10:20:59 UTC, eliminada 10:26 UTC); las lecturas de `lh_silver` se hicieron desde la misma sesión con `lh_silver.customers`. Una consulta SQL combinada sobre `lh_silver.sales` agotó el tiempo (miles de ficheros pequeños, ver informe 05) y se sustituyó por consultas más simples.
- Los ClearCache (5 en este informe) afectan a todos los usuarios de `sm_sales`.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Tamaño en memoria por columna | `INFO.STORAGETABLECOLUMNS` no utilizable con los permisos/versión disponibles | La valoración de `sale_id` y `sale_ts` se basa en cardinalidad medida, no en MB |
| Causa del error `category` | No se revisó el historial de `gold.dim_product` ni el código del escritor | H2 con confianza Media |
| Código exacto del `MERGE` de `nb_02` | No se leyó la definición del notebook; solo su efecto en `DESCRIBE HISTORY` | El ejemplo de R1 es ilustrativo |
| Grupos de cálculo, jerarquías, perspectivas | `INFO.VIEW.CALCULATIONGROUPS` no existe; las tablas no muestran precedencia de grupo | No se detectan; no afecta a las conclusiones |
| Uso de columnas en otros informes | Solo existe `rpt_sales` además del informe de métricas de uso | Las columnas "sin uso" son sin uso en medidas y en `rpt_sales` |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Tabla de medidas dedicada | `modeling-guidelines.md`: distribuir las medidas y evitar una tabla única de medidas | La práctica habitual en Power BI suele recomendar una tabla de medidas; no se contrastó en Learn | Se aplica la skill: no es un incumplimiento que las 10 medidas estén en `fact_sales` |
| Etiquetas de severidad | La skill no define crítico/recomendado/opcional | n/a | Se mapea según `semantic-models.md` § Known traps y se justifica con el impacto medido |

## Anexo

### Consultas completas

```dax
-- E5: huérfanos
EVALUATE ROW(
  "orphan_rows", COUNTROWS(FILTER(fact_sales, ISBLANK(RELATED(dim_customer[customer_id])))),
  "orphan_ids", COUNTROWS(EXCEPT(DISTINCT(fact_sales[customer_id]), DISTINCT(dim_customer[customer_id]))))

-- E7: Top 100 sin el miembro en blanco
DEFINE MEASURE fact_sales[T100 noblank] =
  SUMX(TOPN(100, FILTER(VALUES(dim_customer[customer_id]), NOT ISBLANK(dim_customer[customer_id])), [Total Sales]), [Total Sales])
EVALUATE SUMMARIZECOLUMNS(dim_store[city], "orig", [Top 100 Customers Sales], "noblank", [T100 noblank])

-- E12: acumulado sobre dim_date
DEFINE MEASURE fact_sales[RT Date] =
  IF(NOT ISBLANK([Total Sales]), VAR m = MAX(dim_date[date])
     RETURN CALCULATE([Total Sales], REMOVEFILTERS(dim_date), dim_date[date] <= m))
EVALUATE SUMMARIZECOLUMNS(dim_date[date], "Total Sales", [Total Sales], "RT", [RT Date])
```

```sql
-- E9 (lh_gold, SQL endpoint)
SELECT COUNT(*) FROM dbo.fact_sales f
WHERE NOT EXISTS (SELECT 1 FROM dbo.dim_customer c WHERE c.customer_id = f.customer_id);
```
