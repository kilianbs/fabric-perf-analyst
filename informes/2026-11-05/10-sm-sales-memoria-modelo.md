# sm_sales: tamaño en memoria por tabla y columna, y qué se puede quitar o reducir

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-05 |
| **Áreas** | Semantic models |
| **Ámbito** | workspace `FabricPerfLab` · modelo `sm_sales` (Import, 6 tablas, 44 columnas) · uso cruzado con medidas, relaciones y visuales de `rpt_sales` |
| **Ventana analizada** | 2026-11-05 10:32 → 10:40 UTC (estado en memoria del modelo; carga de datos anterior al refresco fallido del 2026-11-04, ver informe 09) |
| **Agente / host** | Claude Code · skills: semantic-model-authoring, fabric-perf-analysis |
| **Modo** | Solo lectura |
| **Severidad global** | Media |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** tamaño en memoria del modelo, por tabla y por columna (diccionario, datos, jerarquías, relaciones, cardinalidad) y qué columnas se pueden quitar o reducir, cruzado con su uso real.
- **Conclusión:** las vistas de metadatos están disponibles y suman 1.033,5 MB (diccionarios 668,7 MB, datos/segmentos 246,9 MB, jerarquías de atributo 117,4 MB, relaciones 0,5 MB). `fact_sales` es el 98,0 % del total y una sola columna, `sale_id` (13 M de valores únicos, sin uso en ninguna medida, relación ni visual), pesa 719,3 MB (69,6 %).
- **Impacto:** quitar las columnas sin uso (`sale_id`, `unit_price`, `discount`, `channel`, `payment_method`, `note_class`, `customer_name`, `email` y alguna más pequeña) libera unos 760,0 MB (73,5 %). Si además se elimina `sale_ts` (82,8 MB) y la columna calculada `line_margin` (56,8 MB) se llegaría a 899,6 MB (87,1 %), dejando unos 133,9 MB.
- **Primera acción:** R1, quitar `sale_id` (o, si hay que conservarlo, ocultarlo con `isAvailableInMdx = false`, que solo libera sus 99,2 MB de jerarquía). Requiere confirmación; no se aplicó.

## Alcance

**Pregunta original:** "dame el tamaño en memoria del modelo, de cada tabla y de cada columna (diccionario, datos/segmentos, jerarquías, relaciones; cardinalidad por columna), y qué columnas se podrían quitar o reducir (columnas sin uso en medidas/visuales/relaciones, alta cardinalidad, columnas calculadas pesadas como line_margin y year_month, Double vs Decimal, IDs/timestamps con precisión innecesaria, etc.). Usa las vistas de metadatos del modelo ... Cruza cada columna candidata con su uso real antes de proponer quitarla, e indica el ahorro estimado. Si alguna DMV no está disponible, dilo y no inventes cifras."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Las 6 tablas y 44 columnas de `sm_sales`, relaciones y jerarquías de atributo; uso en 10 medidas, 5 relaciones y los 5 visuales de `rpt_sales` | Consumidores del modelo fuera de `rpt_sales` (Excel, informes de otros workspaces): no hay forma de listarlos con las herramientas usadas; memoria del proceso del servicio o de caché de consultas |

**Hipótesis de partida:** H-a) pocas columnas de alta cardinalidad de la fact dominan la memoria (IDs y marcas de tiempo); H-b) hay columnas sin uso; H-c) `line_margin` pesa mucho por ser `Double` calculado.

**Recorrido:** Semantic models únicamente. Usos de columnas tomados de las definiciones de medidas y del informe de los informes 07-09 (no se vuelven a descargar).

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Modo de almacenamiento del modelo | Import (6 particiones M) | informe 09 (E1) |
| Filas | `fact_sales` 13.000.000; `dim_customer` 161.879; `dim_product` 5.000; `dim_store` 50; `dim_date` 730; `promotions` 2.052 | E1 |
| Jerarquías de usuario y elementos de cálculo | 0 y 0 | E7 |
| Permisos con los que se ejecutó | Lectura de `INFO.STORAGETABLES`, `INFO.STORAGETABLECOLUMNS` e `INFO.STORAGETABLECOLUMNSEGMENTS` correcta | E1-E3 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| sm_sales | SemanticModel | Consumo | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |
| rpt_sales | Report | Consumo (5 visuales) | 9bf2e777-02aa-4082-9a1f-02b96987de3c |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Memoria total (suma de las vistas) | 1.033,5 MB | Estimación de datos y estructuras; no incluye caché de consultas ni memoria de proceso | E1-E3 |
| Diccionarios / datos / jerarquías de atributo / relaciones | 668,7 MB / 246,9 MB / 117,4 MB / 0,5 MB | `modeling-guidelines.md` § Core Principles: las columnas de alta cardinalidad son las que más memoria consumen | E1-E3 |
| `fact_sales` | 1.012,7 MB (98,0 %) | ídem | E1-E3 |
| `sale_id` | 719,3 MB (69,6 %): diccionario 587,0, datos 33,1, jerarquía 99,2 | ídem | E1-E3 |
| `sale_ts` | 82,8 MB (8,0 %), 1.123.190 valores distintos, 86.400 horas-minutos-segundos distintos y 13 fechas | `modeling-guidelines.md` § Table Columns: dividir fecha y hora | E1-E4 |
| `line_margin` | 56,8 MB (5,5 %), 493.224 distintos (139.862 si se redondea a 2 decimales) | `modeling-guidelines.md` § Calculated Columns | E1-E5 |
| Columnas de `fact_sales` sin uso | `sale_id`, `unit_price`, `discount`, `channel`, `payment_method`, `note_class` = 746,4 MB | `modeling-guidelines.md` § Maintenance, § Table Columns | E6 |
| Columnas `Double` con 2 decimales exactos | `amount`, `unit_price`, `unit_cost`, `discount`, `list_price`, `unit_cost` (dim_product): 0 valores distintos con más de 2 decimales | `modeling-guidelines.md`: evitar `Double` | E5 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | DAX | `EVALUATE INFO.STORAGETABLES()` y filtro por tablas | Filas por tabla (ver Contexto); relaciones: `fact_sales`→`dim_customer` 200.003 filas, →`dim_product` 5.003, →`dim_store` 53, →`dim_date` 16; `RIVIOLATION_COUNT` = 1 en `dim_customer` (el miembro en blanco, informe 09) |
| E2 | DAX | `INFO.STORAGETABLECOLUMNS()` (sin las estructuras de jerarquía) | `DICTIONARY_SIZE`, tipo y codificación por columna (1 = hash, 2 = valor); p. ej. `sale_id` 615.529.750 bytes, `sale_ts` 43.468.384, `line_margin` 20.940.572; `amount` y `unit_price` con codificación por valor (diccionario 144 bytes) |
| E3 | DAX | `GROUPBY(INFO.STORAGETABLECOLUMNSEGMENTS(), [TABLE_ID], [COLUMN_ID], SUM(USED_SIZE))` | Datos por columna (13 segmentos en `fact_sales`); estructuras de jerarquía de atributo (`H$...`, `POS_TO_ID` e `ID_TO_POS`) y de relación (`R$...`) |
| E4 | DAX | `ROUND([sale_ts]*1440,0)`, `INT([sale_ts])` y `[sale_ts]-INT([sale_ts])` sobre valores distintos | `sale_ts`: 13 fechas, 86.400 horas del día, 18.723 minutos distintos |
| E5 | DAX | `DISTINCTCOUNT` de las 36 columnas de datos; recuento de valores con más de 2 decimales; `line_margin` redondeada a 2 decimales | Ver cardinalidades en la tabla; `line_margin`: 359.181 valores sin exactitud a 2 ni a 4 decimales (ruido de coma flotante); redondeada a 2 decimales quedan 139.862 |
| E6 | MCP/DAX | Medidas (`measure_operations`), relaciones (`INFO.VIEW.RELATIONSHIPS()`), campos de los visuales (`visual.json` del informe 07) | Usos por columna en la tabla siguiente |
| E7 | DAX | `COUNTROWS(INFO.HIERARCHIES())`, `COUNTROWS(INFO.CALCULATIONITEMS())` | 0 y 0 |

### Tamaño por tabla

| Tabla | Diccionarios | Datos (segmentos) | Jerarquías de atributo | Total | % del modelo |
|-------|--------------|-------------------|------------------------|-------|--------------|
| fact_sales | 653,6 MB | 245,6 MB | 113,5 MB | 1.012,7 MB (más 0,5 MB de relaciones) | 98,0 % |
| dim_customer | 14,8 MB | 1,2 MB | 3,7 MB | 19,7 MB | 1,9 % |
| dim_product | 0,3 MB | 0,04 MB | 0,1 MB | 0,4 MB | 0,04 % |
| dim_date | 0,06 MB | < 0,01 MB | 0,01 MB | 0,07 MB | 0,01 % |
| promotions | 0,05 MB | < 0,01 MB | 0,01 MB | 0,06 MB | 0,01 % |
| dim_store | 0,04 MB | < 0,01 MB | < 0,01 MB | 0,04 MB | 0,00 % |

Relaciones (estructura de índice): `fact_sales`→`dim_customer` 0,51 MB; `dim_product` 0,01 MB; `dim_store` y `dim_date` < 0,01 MB (total 0,52 MB). La relación `promotions`→`dim_product` (muchos a muchos) no aparece como estructura de índice propia en E3.

### Tamaño y uso por columna (ordenado por tabla)

Cardinalidad = valores distintos (E5). Uso = lo que usan las 10 medidas, las 5 relaciones y los 5 visuales de `rpt_sales` (E6).

| Columna | Cardinalidad | Diccionario | Datos | Jerarquía | Total | Uso |
|---------|-------------:|------------:|------:|----------:|------:|-----|
| fact_sales[sale_id] | 13.000.000 | 587,01 MB | 33,06 MB | 99,18 MB | 719,26 MB | Sin uso |
| fact_sales[sale_ts] | 1.123.190 | 41,45 MB | 32,80 MB | 8,57 MB | 82,82 MB | Solo medida `Sales Running Total` |
| fact_sales[line_margin] | 493.224 | 19,97 MB | 33,06 MB | 3,76 MB | 56,80 MB | `Margin`, `Margin %`; visuales |
| fact_sales[customer_id] | 200.000 | 4,76 MB | 33,06 MB | 1,53 MB | 39,35 MB | Relación; `Top 100` |
| fact_sales[amount] | 93.524 | 0,1 KB | 33,06 MB | 0,36 MB | 33,42 MB | `Total Sales`, `Avg Ticket`, `Top 100` |
| fact_sales[unit_cost] | 4.131 | 0,16 MB | 24,80 MB | 0,03 MB | 24,99 MB | Solo `line_margin` (calculada) |
| fact_sales[product_code] | 5.000 | 0,12 MB | 24,80 MB | 0,04 MB | 24,95 MB | Relación |
| fact_sales[unit_price] | 19.501 | 0,1 KB | 24,80 MB | 0,07 MB | 24,87 MB | Sin uso |
| fact_sales[store_id] | 50 | 1,5 KB | 3,95 MB | 0,4 KB | 3,95 MB | Relación |
| fact_sales[discount] | 31 | 1,5 KB | 1,63 MB | 0,3 KB | 1,63 MB | Sin uso |
| fact_sales[channel] | 4 | 0,02 MB | 0,28 MB | 0,1 KB | 0,30 MB | Sin uso |
| fact_sales[payment_method] | 4 | 0,02 MB | 0,27 MB | 0,1 KB | 0,29 MB | Sin uso |
| fact_sales[quantity] | 5 | 1,3 KB | 0,04 MB | 0,1 KB | 0,04 MB | `Total Quantity`; `line_margin` |
| fact_sales[year_month] | 1 | 0,02 MB | 1,7 KB | 0,1 KB | 0,02 MB | Columna de la matriz |
| fact_sales[note_class] | 3 | 0,02 MB | 2,6 KB | 0,1 KB | 0,02 MB | Sin uso |
| fact_sales[sale_date] | 13 | 1,3 KB | 6,1 KB | 0,1 KB | 7,6 KB | Relación; eje de la línea; `Sales LY` |
| dim_customer[email] | 161.879 | 5,56 MB | 0,41 MB | 1,24 MB | 7,20 MB | Sin uso |
| dim_customer[customer_id] | 161.879 | 4,62 MB | 0,41 MB | 1,24 MB | 6,26 MB | Relación; `Active Customers`; `Top 100` |
| dim_customer[customer_name] | 161.879 | 4,56 MB | 0,41 MB | 1,24 MB | 6,20 MB | Sin uso |
| dim_customer[segment] | 3 | 0,02 MB | 0,1 KB | 0,1 KB | 0,02 MB | `Enterprise Sales` |
| dim_customer[updated_at] | 15 | 1,3 KB | 0,5 KB | 0,2 KB | 2,0 KB | Sin uso |
| dim_product[product_name] | 5.000 | 0,13 MB | 9,9 KB | 0,04 MB | 0,18 MB | Sin uso |
| dim_product[product_code] | 5.000 | 0,12 MB | 9,9 KB | 0,04 MB | 0,17 MB | Relaciones |
| dim_product[list_price] | 4.397 | 0,1 KB | 9,9 KB | 0,02 MB | 0,03 MB | Sin uso |
| dim_product[unit_cost] | 4.131 | 0,1 KB | 9,9 KB | 0,02 MB | 0,03 MB | Sin uso |
| dim_product[category] | 8 | 0,02 MB | 0,1 KB | 0,1 KB | 0,02 MB | Visual de la tabla |
| dim_store[store_name] | 50 | 0,02 MB | 0,2 KB | 0,4 KB | 0,02 MB | Visual de la matriz |
| dim_store[city] | 5 | 0,02 MB | 0,1 KB | 0,1 KB | 0,02 MB | Visual de barras |
| dim_store[store_id] | 50 | 1,5 KB | 0,2 KB | 0,4 KB | 2,1 KB | Relación |
| dim_date[date] | 730 | 0,02 MB | 1,1 KB | 5,8 KB | 0,03 MB | Relación (ni medidas ni visuales) |
| dim_date[month_name] | 12 | 0,02 MB | 0,5 KB | 0,1 KB | 0,02 MB | Sin uso |
| dim_date[weekday] | 7 | 0,02 MB | 0,4 KB | 0,1 KB | 0,02 MB | Sin uso |
| dim_date[month] | 12 | 1,3 KB | 0,5 KB | 0,1 KB | 1,9 KB | Sin uso |
| dim_date[year] | 2 | 1,3 KB | 0,1 KB | 0,1 KB | 1,5 KB | Sin uso |
| promotions[product_code] | 1.026 | 0,03 MB | 3,3 KB | 8,1 KB | 0,04 MB | Relación |
| promotions[promo_name] | 2 | 0,02 MB | 0,1 KB | 0,1 KB | 0,02 MB | Visual de la tabla |
| promotions[promo_start] | 2 | 1,2 KB | 0,1 KB | 0,1 KB | 1,5 KB | Sin uso |
| promotions[promo_end] | 2 | 1,2 KB | 0,1 KB | 0,1 KB | 1,5 KB | Sin uso |

Las columnas `RowNumber` internas de cada tabla (hasta 1,6 KB en `fact_sales`) no se listan. Los tamaños de diccionario de las columnas de texto con pocos valores (alrededor de 17 KB) corresponden a una estructura base, no al contenido.

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | `sale_id` ocupa 719,3 MB (69,6 % del modelo) y no se usa | Media | Alta | E1-E3, E6 |
| H2 | Otras columnas sin uso: 27,1 MB en `fact_sales`, 13,4 MB en `dim_customer`, el resto < 0,3 MB | Media | Alta | E1-E3, E6 |
| H3 | `sale_ts` (82,8 MB) solo la usa un acumulado que se puede mover a `dim_date`; tiene 1,1 M de valores por llevar hora con segundos | Media | Alta | E1-E4, E6 |
| H4 | La columna calculada `line_margin` pesa 56,8 MB y su cardinalidad se infla por ruido de coma flotante | Media | Alta | E1-E3, E5 |
| H5 | `Double` vs `Decimal`: no cambia la memoria (codificación por valor) pero sí la exactitud; los importes tienen 2 decimales exactos | Baja | Alta | E2, E5 |
| H6 | `year_month` y el resto de columnas pequeñas no suponen ahorro de memoria | Baja | Alta | E1-E3 |

### H1 · sale_id

- **Qué ocurre:** 13 M de valores distintos de texto, 587,0 MB de diccionario, 33,1 MB de datos y 99,2 MB de estructuras de jerarquía de atributo (`POS_TO_ID` e `ID_TO_POS`, 52,0 MB cada una).
- **Por qué:** columna de identificador de línea con cardinalidad igual al número de filas: no comprime. No aparece en ninguna medida, relación ni visual de `rpt_sales` (E6) y la guía pide quitar o evitar columnas de alta cardinalidad que no se usan (`modeling-guidelines.md` § Core Principles, § Table Columns).
- **Impacto:** 719,3 MB de 1.033,5 (69,6 %). Severidad Media: la skill no fija un umbral de MB; se justifica por la proporción medida. Si alguien necesita el identificador para detalle (exportación a Excel, drill-through), conservarlo exige decidirlo con los consumidores (ver R1).

### H2 · Columnas sin uso

| Columna | Ahorro (MB) | Nota |
|---------|-------------|------|
| fact_sales[unit_price] | 24,87 | Sin uso |
| fact_sales[discount] | 1,63 | Sin uso |
| fact_sales[channel] y [payment_method] | 0,30 + 0,29 | Sin uso |
| fact_sales[note_class] | 0,02 | Sin uso |
| dim_customer[email] y [customer_name] | 7,20 + 6,20 | Sin uso; además son datos personales |
| dim_customer[updated_at], dim_product[product_name], [list_price], [unit_cost], promotions[promo_start], [promo_end], dim_date[year, month, month_name, weekday] | < 0,25 en total | Sin uso en medidas ni visuales actuales, pero `promo_start/promo_end` y las columnas de `dim_date` son las que se necesitan para corregir `promotions` y la tabla de fechas (informe 09, H3 y H4): no quitar |

Suma de lo que se puede quitar sin dependencias: `unit_price`, `discount`, `channel`, `payment_method`, `note_class` (27,11 MB) más `email` y `customer_name` (13,40 MB) = 40,51 MB, más `sale_id` (719,26 MB), con `product_name`, `list_price`, `unit_cost` y `updated_at` hasta 760,0 MB (73,5 %).

### H3 · sale_ts

- **Qué ocurre:** 1.123.190 valores distintos con hora y segundos (86.400 horas del día distintas, 13 fechas), 41,45 MB de diccionario, 32,80 MB de datos y 8,57 MB de jerarquía.
- **Por qué:** `Sales Running Total` compara `sale_ts` contra `MAX(sale_ts)` sobre toda la fact (informe 08). Con un acumulado sobre `dim_date` (informe 09, R3) la columna no tiene otro uso. La guía pide separar fecha y hora cuando hay precisión innecesaria (`modeling-guidelines.md` § Table Columns).
- **Impacto:** 82,8 MB si se elimina. Si hace falta conservar la hora, separarla en fecha (`sale_date` ya existe) y hora con 86.400 valores únicos reduciría el diccionario del orden de 41,45 MB a unos 3,2 MB (estimación proporcional a la cardinalidad: 38,7 bytes por valor × 86.400); no se estima el cambio en datos ni en jerarquía.

### H4 · line_margin

- **Qué ocurre:** columna calculada `fact_sales[amount] - fact_sales[quantity] * fact_sales[unit_cost]`, de tipo `Double`, con 493.224 valores distintos; 359.181 no son exactos a 2 ni a 4 decimales (ruido de coma flotante). Redondeada a 2 decimales quedarían 139.862 (E5).
- **Por qué:** se materializa para 13 M de filas en cada refresco (`modeling-guidelines.md` § Calculated Columns, § Performance Guidelines).
- **Impacto:** (a) sustituir la columna por una medida `Margin = SUMX(fact_sales, fact_sales[amount] - fact_sales[quantity] * fact_sales[unit_cost])` libera 56,80 MB, pero obliga a conservar `unit_cost` (24,99 MB) y `quantity` en memoria; (b) traerla del origen como `decimal(18,2)` reduce diccionario y jerarquía en proporción a la cardinalidad: estimación de unos 17 MB (19,97 × (1 − 139.862/493.224) + 3,76 × (1 − 139.862/493.224) = 14,3 + 2,7), con los datos sin cambio medible estimado (33,06 MB). Ambas cifras son estimaciones proporcionales, no medidas; el rendimiento de la opción (a) no se midió.

### H5 y H6

- **Decimal:** `amount`, `unit_price`, `unit_cost`, `discount` y las columnas de `dim_product` no tienen valores con más de 2 decimales (E5), así que `Decimal` de 2 decimales no pierde información. `amount` y `unit_price` ya usan codificación por valor (diccionario de 144 bytes), de modo que el cambio de tipo no ahorraría memoria; la ganancia es el resultado determinista de las sumas (informes 07 y 08).
- **`year_month`:** 0,02 MB; moverla a `dim_date` es una mejora de diseño (informe 09, R6), no de memoria. `dim_date`, `promotions`, `dim_store`, `dim_product` suman en conjunto menos de 0,6 MB: no hay ahorro que buscar ahí.
- **Claves:** `product_code` como texto cuesta 24,80 MB de datos en la fact (16 bits por fila). Un entero de 5.000 valores necesitaría unos 13 bits, es decir, alrededor de 20 MB: ahorro estimado de unos 5 MB, no recomendable por sí solo.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Quitar `fact_sales[sale_id]` (o, como mínimo, `isAvailableInMdx = false`) | H1 | Alto (719,3 MB) | Bajo | Medio | Sí |
| R2 | Quitar `unit_price`, `discount`, `channel`, `payment_method`, `note_class`, `customer_name` y `email` | H2 | Medio (40,5 MB) | Bajo | Bajo | Sí |
| R3 | Mover `Sales Running Total` a `dim_date` y quitar `sale_ts` (o dividirla) | H3 | Medio (82,8 MB) | Medio | Medio | Sí |
| R4 | Sustituir `line_margin` por medida o por columna decimal del origen | H4 | Medio (17-56,8 MB) | Medio | Medio | Sí |
| R5 | Importes a `Decimal` en el origen | H5 | Bajo en memoria, alto en exactitud | Medio | Medio | Sí |

### R1 · Quitar sale_id

- **Cambio propuesto:** eliminar la columna del modelo (y de la consulta del origen o de la tabla de `lh_gold` si no la usa nadie más). Si hay que poder consultar una venta concreta, mantener `sale_id` solo en la consulta de detalle, no en el modelo.
- **Impacto esperado:** −719,3 MB (69,6 %) en memoria; el refresco deja de construir un diccionario de 13 M de textos. Alternativa mínima: ocultar la columna y poner `isAvailableInMdx = false` (`modeling-guidelines.md` § Table Columns), que solo libera la jerarquía (99,2 MB).
- **Cómo validarlo:** repetir E1-E3 tras un refresco y comprobar que el total baja de 1.033,5 MB a unos 314 MB y que los 5 visuales dan los mismos valores.
- **Reversión:** volver a añadir la columna y refrescar.
- **Requiere confirmación:** Sí: cambia el modelo y puede romper consumidores externos que no se pueden listar con estas herramientas.

### R2 a R5

- **R2:** ahorro 40,5 MB (suma de H2); validar con E1-E3 y los 5 visuales. Reversión: volver a añadir las columnas. Confirmación: Sí (modelo).
- **R3:** requiere antes aplicar R3 del informe 09 (acumulado sobre `dim_date`, 63-73 ms en frío). Ahorro: 82,8 MB si se elimina; si solo se divide, la parte de diccionario baja a unos 3,2 MB (estimación) y el resto no se estima. Validar con el benchmark de la línea (informe 08, E4). Confirmación: Sí.
- **R4:** opción (a) −56,8 MB con medida `SUMX` (hay que medir su coste en el visual de la matriz y la tarjeta antes de aplicar); opción (b) ≈ −17 MB con la columna del origen. Elegir una tras medir. Confirmación: Sí.
- **R5:** `decimal(18,2)` en `amount`, `unit_price`, `unit_cost`, `discount`, `list_price`, `unit_cost` de `dim_product` y `line_margin`; sin ahorro de memoria esperado; validar que los totales coinciden con 3.877.208.385,60. Confirmación: Sí.
- **Total potencial:** R1 + R2 + (las pequeñas sin uso) = 760,0 MB (73,5 %); con `sale_ts` 842,8 MB (81,5 %); con `line_margin` como medida 899,6 MB (87,1 %), dejando unos 133,9 MB.
- **Aviso de crecimiento:** `fact_sales` crece 1 M de filas por día (13 M → 15 M entre el 3 y el 5 de noviembre, informe 09). La memoria de las columnas de alta cardinalidad crecerá en proporción tras el próximo refresco correcto: unos +15 % por columna de la fact (estimación lineal, no medida).

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Las jerarquías de usuario o los grupos de cálculo ocupan memoria | E7 | No hay ninguno |
| D2 | Las dimensiones pequeñas son relevantes | E1-E3 | `dim_product`, `dim_store`, `dim_date` y `promotions` suman < 0,6 MB |
| D3 | Pasar `Double` a `Decimal` reduce la memoria de `amount` y `unit_price` | E2 | Ya tienen codificación por valor (diccionario 144 bytes); el beneficio es de exactitud |
| D4 | `year_month` es una columna calculada pesada | E3 | 0,02 MB (1 valor distinto) |
| D5 | Hay tablas de fecha automáticas ocultas que consumen memoria | informe 09, E1 | No existen |

## Siguientes pasos

- [ ] Confirmar con los propietarios de `rpt_sales` y de cualquier consumidor externo que nadie usa `sale_id`, `unit_price`, `discount`, `channel`, `payment_method`, `note_class`, `email` ni `customer_name` — responsable: propietario del modelo · relacionado con: R1, R2
- [ ] Decidir R3 y R4 (con el benchmark de la medida `SUMX`) — responsable: propietario del modelo · relacionado con: R3, R4
- [ ] Repetir E1-E3 tras el refresco para validar el ahorro — responsable: analista · relacionado con: R1-R4
- [ ] Repetir el análisis tras aplicar R# para validar el impacto

## Notas

### Limitaciones

- Las cifras son las de la última carga del modelo (13 M filas, hasta el 2026-09-15). Hay refrescos fallidos desde el 2026-11-04 (informe 09, H2); tras un refresco correcto los tamaños serán mayores.
- Las vistas `INFO.STORAGE*` devuelven tamaños de estructuras de datos y de diccionario; no incluyen la caché de consultas ni la memoria del proceso, y la suma de 1.033,5 MB no es la huella total del servicio.
- Los ahorros marcados como estimación (división de `sale_ts`, `line_margin` desde el origen, entero para `product_code`, crecimiento) son proporcionales a la cardinalidad; no se probaron en el modelo.
- Uso real: solo se cruzó con `rpt_sales` y con las definiciones de medidas y relaciones. El único otro informe del workspace, "Report Usage Metrics Report", usa su propio modelo.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Consumidores externos al modelo (Excel, informes de otros workspaces, consultas XMLA) | Las herramientas usadas no listan consumidores del modelo | El riesgo de quitar columnas se acota a `rpt_sales`; confirmación requerida (R1, R2) |
| Memoria real tras aplicar los cambios | Es un cambio (Tier C) | Ahorros estimados con los tamaños actuales por columna |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Vista `INFO.STORAGETABLECOLUMNS` | `metadata-discovery.md` indica que varias `INFO.*` requieren permisos elevados | Las tres vistas `INFO.STORAGE*` respondieron con los permisos de esta sesión; las columnas son `DICTIONARY_SIZE`, `USED_SIZE`, etc., sin una columna de cardinalidad (`COLUMN_CARDINALITY` no existe) | Cardinalidad medida con `DISTINCTCOUNT`; documentado aquí |

## Anexo

### Consultas completas

```dax
-- E1
EVALUATE SELECTCOLUMNS(FILTER(INFO.STORAGETABLES(), LEFT([TABLE_ID],1) <> "H"),
  "T",[DIMENSION_NAME],"ID",[TABLE_ID],"Rows",[ROWS_COUNT],"RIViol",[RIVIOLATION_COUNT])

-- E2
EVALUATE FILTER(SELECTCOLUMNS(INFO.STORAGETABLECOLUMNS(),
  "T",[DIMENSION_NAME],"ID",[TABLE_ID],"Col",[COLUMN_ID],"Type",[COLUMN_TYPE],"Enc",[COLUMN_ENCODING],
  "DT",[DATATYPE],"Dict",[DICTIONARY_SIZE],"Res",[DICTIONARY_ISRESIDENT]),
  [Type] <> "HIERARCHY_POSITION_TO_DATAID" && [Type] <> "HIERARCHY_DATAID_TO_POSITION")

-- E3
EVALUATE GROUPBY(INFO.STORAGETABLECOLUMNSEGMENTS(), [MEASURE_GROUP_NAME], [TABLE_ID], [COLUMN_ID],
  "used", SUMX(CURRENTGROUP(), [USED_SIZE]), "alloc", SUMX(CURRENTGROUP(), [ALLOCATED_SIZE]),
  "segs", COUNTX(CURRENTGROUP(), [SEGMENT_NUMBER]), "recs", SUMX(CURRENTGROUP(), [RECORDS_COUNT]))
```
