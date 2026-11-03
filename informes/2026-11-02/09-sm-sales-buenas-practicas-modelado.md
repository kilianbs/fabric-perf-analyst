# Revisión de buenas prácticas de modelado de sm_sales: dim_date sin marcar y medidas que no la usan

Seguimiento de [07-sm-sales-avg-ticket-lento.md](07-sm-sales-avg-ticket-lento.md) y [08-sm-sales-resto-pagina.md](08-sm-sales-resto-pagina.md). No se repiten sus hallazgos; aquí se amplían al modelo completo. Solo diagnóstico: no se cambió nada.

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-02 |
| **Áreas** | Semantic models |
| **Ámbito** | workspace `FabricPerfLab` · modelo semántico `sm_sales` |
| **Ventana analizada** | 2026-11-02 20:36 → 20:40 UTC (lectura de metadatos en vivo) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, semantic-model-authoring |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** ¿cumple `sm_sales` las buenas prácticas de modelado?, y qué medidas usan `fact_sales[...]` como eje o filtro de fecha en lugar de `dim_date`.
- **Conclusión:** el esquema es una estrella razonable (1 hecho, 4 dimensiones), pero incumple prácticas clave: `dim_date` no está marcada como tabla de fechas ni se usa en ninguna medida; 2 de 5 relaciones (40 %) son bidireccional o muchos-a-muchos (el límite de la guía es 30 %); 34 691 `customer_id` huérfanos; y las 10 medidas no tienen descripción, y 8 de 10 no tienen formato.
- **Impacto:** cifras duplicadas por promoción (08), medidas lentas (07, 08), y un modelo difícil de usar (columnas técnicas visibles con suma implícita, mes sin ordenar).
- **Primera acción:** R1, marcar `dim_date` como tabla de fechas (`dataCategory = Time`), completarla y llevar a ella el eje de fecha; luego R2 y R3 para las medidas y las relaciones.

## Alcance

**Pregunta original:** varias medidas filtran sobre `fact_sales` en lugar de usar una tabla de fechas; ¿cumple el modelo las buenas prácticas? Revisar esquema estrella, tabla de fechas, columnas de fecha / year_month en la tabla de hechos, relaciones, bidireccionales y M:N, claves huérfanas, columnas ocultas o innecesarias, tipos de dato, medidas implícitas y formato; listar las medidas que usan `fact_sales[...]` como eje de fecha o filtro en vez de `dim_date`.

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Metadatos del modelo: tablas, columnas, relaciones, medidas, estadísticas de columnas | Cambios en el modelo; rendimiento ya cubierto en 07 y 08; uso real de las columnas en informes (no se leyó la definición del informe) |

**Hipótesis de partida:** H-a) `dim_date` no está marcada ni usada; H-b) hay columnas de fecha / mes en el hecho que duplican a `dim_date`; H-c) relaciones y columnas incumplen las guías.

**Recorrido:** Semantic models únicamente. Las claves huérfanas apuntan a Gold (ver Siguientes pasos), sin cambiar de área.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Modo de almacenamiento del modelo | Import en las 6 tablas | 07 (E3) |
| Permisos con los que se ejecutó | Metadatos y DAX por XMLA vía powerbi-modeling-mcp | E1-E6 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| sm_sales | SemanticModel | Consumo | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Relaciones bidireccionales + M:N | 2 de 5 (40 %) | < 30 %, `modeling-guidelines.md` § Relationships | E2 |
| Tablas con `DataCategory = Time` | 0 | Debe ser "Time", § Date/Calendar Table | E4 |
| Hierarchies / roles / calculation groups | 0 / 0 / 0 | § Hierarchies; § Date/Calendar Table | E4 |
| `customer_id` de hechos sin dimensión | 34 691 de 200 000 distintos (1,9 M filas, 17,3 %, de 08) | Integridad referencial | E5 |
| Cardinalidad `fact_sales[sale_ts]` | 950 391 | "Split combined DateTime", § Table Columns | E3 |
| Cardinalidad `fact_sales[sale_id]` | 11 000 000, texto GUID de 36 caracteres | § Table Columns (alta cardinalidad) | E3 |
| Medidas con formato / con descripción | 2 de 10 / 0 de 10 | "Every visible measure must have a formatString", § Format String Reference; descripciones, § Descriptions & Documentation | E6 |
| Columnas calculadas | 2 (`line_margin`, `year_month`) | Revisar si > 5, § Performance Guidelines | E1 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | DAX | `INFO.VIEW.COLUMNS()` | 44 filas (incluye 6 `RowNumber` de sistema). Tipos, ocultas, SummarizeBy, orden y expresiones de las calculadas |
| E2 | DAX | `INFO.VIEW.RELATIONSHIPS()` | Las 5 relaciones de 07 (E3): 4 desde `fact_sales` y `promotions`↔`dim_product` *<->*; `fact_sales`→`dim_customer` bidireccional; `RelyOnReferentialIntegrity` falso en todas |
| E3 | DAX | `COLUMNSTATISTICS()` filtrado por las 6 tablas | Mínimos, máximos y cardinalidad (ver tabla de métricas y hallazgos) |
| E4 | DAX | `COUNTROWS` de `INFO.HIERARCHIES()`, `INFO.ROLES()`, `INFO.CALCULATIONGROUPS()` y tablas con `DataCategory="Time"` | Todas devuelven blanco (cero) |
| E5 | DAX | `DISTINCT(fact_sales[customer_id])` contra `LOOKUPVALUE` en `dim_customer` | 34 691 ids huérfanos; 0 filas con `customer_id` nulo; 200 000 distintos en el hecho frente a 165 309 en la dimensión |
| E6 | DAX | `INFO.VIEW.MEASURES()` y `measure_operations List` | Formato solo en `Total Sales` ("#,##0.00") y `Total Quantity` ("#,##0"); sin descripción ni carpeta en las 10 |
| E7 | Metadatos | Definiciones de medida de 07 (E2) | Base de la lista de "Medidas que usan `fact_sales` como eje o filtro" |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | `dim_date` no está marcada como tabla de fechas y está incompleta | Alta | Alta | E1, E3, E4 |
| H2 | Medidas e informes usan `fact_sales` como eje o filtro de fecha | Alta | Alta | E1, E7 |
| H3 | Bidireccionales y M:N por encima del límite (40 %) | Media | Alta | E2 |
| H4 | Claves huérfanas de cliente y sin integridad referencial declarada | Media | Alta | E2, E5 |
| H5 | Columnas técnicas visibles con suma implícita; columnas innecesarias o de alta cardinalidad | Media | Alta | E1, E3 |
| H6 | Medidas sin formato ni descripción; `Margin %` con `IFERROR` | Baja | Alta | E6, E7 |
| H7 | Tipos de dato y claves de texto | Baja | Media | E1, E3 |

### H1 · `dim_date`

- **Qué ocurre:** ninguna tabla tiene `DataCategory = Time` (E4); `dim_date` figura como "Regular" (07, E3). No tiene `isKey`. Contiene solo `date`, `year`, `month`, `month_name` y `weekday` (E1): faltan Quarter, Day y Week, y no tiene `year_month`. `month_name` y `weekday` no tienen `SortByColumn` (E1), así que ordenarán alfabéticamente (April, August...); `year` y `month` tienen `SummarizeBy = Sum` (E1), cuando deberían ser `None`. No hay jerarquías (E4). El rango 2026-01-01 a 2027-12-31 tiene 730 días contiguos (E3), y las 11 fechas de hechos están dentro (08, E9).
- **Por qué importa:** `modeling-guidelines.md` § Date/Calendar Table exige marcarla como "Time", atributos comunes y orden; sin ello, la inteligencia de tiempo no está garantizada.
- **Impacto:** informes con meses desordenados y sumas absurdas si alguien arrastra `year`; riesgo de resultados erróneos en `[Sales LY]`.

### H2 · Medidas y visuales que usan `fact_sales` como eje o filtro de fecha

| Elemento | Qué usa de `fact_sales` | Debería usar |
|----------|-------------------------|--------------|
| `[Sales Running Total]` | `FILTER(ALL(fact_sales), fact_sales[sale_ts] <= MAX(fact_sales[sale_ts]))` | `dim_date[date]` (candidato en 08, R1, 4 053 ms a 60 ms) |
| `[Sales LY]` | `SAMEPERIODLASTYEAR(fact_sales[sale_date])` | `SAMEPERIODLASTYEAR(dim_date[date])` con `dim_date` marcada |
| Q2 (visual) | Eje `fact_sales[year_month]` (columna calculada de texto) | Columna de mes en `dim_date` |
| Q3 (visual) | Eje `fact_sales[sale_date]` | `dim_date[date]` |

Otras medidas filtran el hecho aunque no por fecha: `[Enterprise Sales]` (`FILTER(fact_sales, RELATED(dim_customer[segment]) = "Enterprise")`, mejor `CALCULATE([Total Sales], dim_customer[segment] = "Enterprise")`) y `[Avg Ticket]` (07). Las columnas `fact_sales[sale_date]`, `sale_ts` y `year_month` están visibles y duplican a `dim_date`. `year_month` es una columna calculada con `FORMAT(sale_date, "yyyy-MM")` (E1), con 1 valor distinto en los datos actuales (E3).

### H3 · Relaciones

De 5 relaciones (E2), `fact_sales`→`dim_customer` es bidireccional y `promotions`↔`dim_product` es muchos-a-muchos y bidireccional: 2 de 5 (40 %), por encima del 30 % de § Relationships. `fact_sales` y `promotions` se relacionan por `product_code` de texto. Esta tabla `promotions` actúa como segunda tabla con grano distinto (2 052 filas, 1 026 productos, 2 promociones: E3, 08 E10); causa la duplicación de ventas de 08 (H3). Las relaciones no declaran integridad referencial (`RelyOnReferentialIntegrity` falso, E2); ver H4.

### H4 · Claves huérfanas

200 000 `customer_id` distintos en el hecho y 165 309 en la dimensión (E3): 34 691 ids huérfanos (E5), sin nulos. Lo ya medido en 08: 17,3 % de las filas caen en el miembro en blanco con 568,5 M de ventas. Las demás claves cuadran: `store_id` 50 = 50, `product_code` 5 000 = 5 000, 11 fechas contenidas en `dim_date` (E3).

### H5 · Columnas

- **Claves y técnicas visibles:** `store_id`, `customer_id`, `product_code`, `sale_date`, `sale_id` en el hecho, y las claves de dimensión, están visibles (`IsHidden` falso, E1). `store_id` y `customer_id` (en hecho y dimensión) tienen `SummarizeBy = Sum`.
- **Medidas implícitas posibles:** `amount`, `quantity`, `unit_price`, `unit_cost`, `discount`, `line_margin`, `dim_product[list_price]` y `unit_cost` están visibles con `Sum` (E1), aunque ya existen medidas explícitas (`Total Sales`, `Total Quantity`, `Margin`). Un usuario puede arrastrar la columna y obtener una suma implícita sin formato.
- **Alta cardinalidad / innecesarias:** `sale_id` (11 M GUID de texto, 36 caracteres, E3) ninguna medida lo usa (E7); `sale_ts` (950 391 valores, datetime) solo la usa `[Sales Running Total]`; guía: "Split combined DateTime" y "Keep columns not referenced waste memory". `unit_cost` está duplicada en hecho y producto; `note_class`, `payment_method`, `channel`, `unit_price`, `discount` no se usan en ninguna medida (uso en visuales no verificado). `dim_customer[email]` es dato personal visible y no se usa.
- **Calculadas:** `line_margin` y `year_month` son columnas calculadas (2, bajo el umbral de revisión de 5); ambas son candidatas a moverse al origen (Gold).

### H6 · Medidas

Las 10 medidas están en `fact_sales`, sin descripción ni carpeta; solo `Total Sales` y `Total Quantity` tienen formato (E6). `[Margin %]` sin formato mostraría 0,3811 en lugar de porcentaje. `[Margin %]` usa `IFERROR` en lugar de `DIVIDE`, que enmascara errores. `[Margin]` y `[Total Sales]` son simples. No hay duplicados ni medidas que sean solo una referencia a otra.

### H7 · Tipos de dato

Los importes aparecen como "Number" (E1), que en este modelo apunta a coma flotante (no confirmado como Double/Decimal): el running total del 08 mostró diferencias del orden de 1e-4 frente al candidato; la guía pide `Decimal` para dinero. Las claves `product_code` son texto (E1, E3) en lugar de enteros. `sale_ts` y `sale_date` se presentan como "Date".

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Completar y marcar `dim_date` como tabla de fechas | H1 | Alto | Bajo | Bajo | Sí |
| R2 | Llevar medidas y visuales a `dim_date`; reescribir `Sales Running Total`, `Sales LY`, `Enterprise Sales` | H2 | Alto | Medio | Bajo | Sí |
| R3 | Rediseñar `promotions` y poner `fact_sales`→`dim_customer` en unidireccional | H3 | Alto | Medio | Medio | Sí |
| R4 | Tratar los clientes huérfanos en Gold y declarar integridad | H4 | Medio | Medio | Medio | Sí |
| R5 | Ocultar claves y columnas agregadas, `SummarizeBy = None`, quitar columnas no usadas | H5 | Medio | Bajo | Bajo | Sí |
| R6 | Formato, descripciones, carpetas; `DIVIDE` en `Margin %` | H6 | Bajo | Bajo | Bajo | Sí |
| R7 | Revisar tipos (Decimal para importes, claves enteras) en el origen | H7 | Bajo | Alto | Medio | Sí |

### R1 · `dim_date`

- **Cambio propuesto:** `dataCategory = Time` sobre `dim_date`, `date` como columna clave de fecha; añadir Quarter, Day, Week y `year_month` (texto o entero) en la tabla; `SortByColumn` para `month_name` (por `month`) y `weekday`; `SummarizeBy = None` en `year` y `month`; jerarquía Año > Mes > Día.
- **Impacto esperado:** `[Sales LY]` y la inteligencia de tiempo quedan soportadas; meses ordenados.
- **Cómo validarlo:** `INFO.VIEW.TABLES()` debe mostrar `DataCategory = Time`; un visual por mes muestra enero a diciembre en orden.
- **Reversión:** quitar la marca y las columnas añadidas.
- **Requiere confirmación:** Sí, cambio del modelo (Tier C).

### R2 · Medidas sobre `dim_date`

```dax
Sales Running Total =
CALCULATE([Total Sales], REMOVEFILTERS(fact_sales[sale_date]), dim_date[date] <= MAX(dim_date[date]))

Sales LY = CALCULATE([Total Sales], SAMEPERIODLASTYEAR(dim_date[date]))

Enterprise Sales = CALCULATE([Total Sales], dim_customer[segment] = "Enterprise")
```

Mover los ejes de los visuales (Q2, Q3) a `dim_date`. La primera es el candidato probado en 08 (cambiando el `MAX` por `dim_date[date]` hay que revisarlo en un visual con eje de `dim_date`: no se probó esa variante); las otras dos no se probaron.
- **Cómo validarlo:** repetir los benchmarks de 08 (ClearCache, warm-up, 2 ejecuciones) y comparar valores.
- **Reversión:** restaurar las expresiones previas.
- **Requiere confirmación:** Sí.

### R3 a R7

- **R3:** quitar la relación M:N bidireccional `promotions`↔`dim_product` (tabla puente con regla de reparto, 08 R3) y poner `CrossFilteringBehavior = OneDirection` en `fact_sales`→`dim_customer` tras comprobar con negocio si algún visual depende del filtro inverso. Objetivo: 0 relaciones bidireccionales y 0 M:N. Medir el efecto en `[Top 100 Customers Sales]` (08).
- **R4:** en Gold, mapear los 34 691 ids sin dimensión a un miembro "Desconocido" (o completar `dim_customer`); después, activar `RelyOnReferentialIntegrity` solo si la integridad es total. Validar con E5 (debe dar 0).
- **R5:** ocultar FKs y columnas numéricas con medida (`amount`, `quantity`, `line_margin`, etc.); `SummarizeBy = None` en ids y `year`/`month`; eliminar `sale_id`, `sale_ts` (tras R2), `year_month` del hecho, `email`, `note_class`, `unit_price`, `discount` si ningún informe los usa (verificar antes con el lineage de informes). Validar: tamaño del modelo antes/después (no medido aquí).
- **R6:** formato `0.0%` para `Margin %`, descripciones y `displayFolder` en las 10 medidas; `Margin % = DIVIDE([Margin], [Total Sales])`.
- **R7:** `Decimal` para importes y claves enteras en Gold; solo con ventana de cambio.

Todas requieren confirmación: son cambios del modelo o del origen.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Tablas automáticas de fecha (`LocalDateTable_*`) hinchan el modelo | E1 | No hay tablas ocultas de fecha en el inventario de columnas ni de tablas (solo 6 tablas). No se pudo verificar la opción del modelo en sí |
| D2 | Hay un esquema copo de nieve o dimensiones enlazadas entre sí | E2 | Todas las relaciones salen de `fact_sales` salvo `promotions`↔`dim_product` (tratada en H3) |
| D3 | Hay claves huérfanas en tienda, producto o fecha | E3 | Cardinalidades de claves coinciden y las 11 fechas existen en `dim_date` |
| D4 | RLS, calculation groups o jerarquías mal configurados | E4 | No existen (0 de cada) |

## Siguientes pasos

- [ ] Aplicar R1 y R2 — responsable: propietario del modelo · relacionado con: R1, R2
- [ ] Decidir regla de promociones y revisar el uso de la bidireccional de cliente — responsable: negocio / modelador · relacionado con: R3
- [ ] Corregir clientes huérfanos en Gold — responsable: ingeniería de datos · relacionado con: R4
- [ ] Revisar el lineage de informes antes de ocultar o eliminar columnas — responsable: propietario del informe · relacionado con: R5
- [ ] Repetir el análisis tras aplicar R1-R4 para validar el impacto

## Notas

### Limitaciones

- Solo metadatos y estadísticas del modelo: no se revisó qué columnas usan los informes, así que R5 queda condicionada a ese lineage.
- Tamaños en memoria (MB) no obtenidos; el impacto de R5 es cualitativo.
- Los tipos de dato se leen como "Number"/"Date" desde `INFO.VIEW.COLUMNS`, sin distinguir Double de Decimal ni Date de DateTime (H7, confianza Media).

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Tamaño de columnas y tablas (`INFO.STORAGE*`, DMV) | No consultado | H5 sin cifras de memoria |
| Opción "Auto date/time" del modelo | No expuesta por las consultas usadas | D1 solo por ausencia de tablas ocultas |
| Definición TMDL completa | Ver 07 | Se usó `INFO.VIEW.*` |
| Uso de columnas en informes | Definición del informe no leída | R5 condicionada |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Ninguna detectada | | | |

Criterio de severidad: mapeo crítico a Alta, recomendado a Media, opcional a Baja de `SKILL.md` § Workflow: Analyze Best Practices (semantic-model-authoring), justificado con el impacto medido en 07 y 08. Los umbrales numéricos citados proceden de `modeling-guidelines.md`.

## Anexo

### Consultas completas

```dax
-- E1
EVALUATE SELECTCOLUMNS(INFO.VIEW.COLUMNS(), "t",[Table],"c",[Name],"dt",[DataType],"h",[IsHidden],"k",[IsKey],"sum",[SummarizeBy],"sort",[SortByColumn],"type",[Type],"expr",[Expression])
-- E5
EVALUATE ROW("orphan_ids", COUNTROWS(FILTER(DISTINCT(fact_sales[customer_id]), ISBLANK(LOOKUPVALUE(dim_customer[customer_id], dim_customer[customer_id], fact_sales[customer_id])))))
```
