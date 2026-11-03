# Tamaño en memoria de sm_sales: 806 MiB, el 66 % en una sola columna (fact_sales[sale_id])

Seguimiento de [09-sm-sales-buenas-practicas-modelado.md](09-sm-sales-buenas-practicas-modelado.md), que dejó sin cifras el tamaño de columnas (H5). Relacionado con [07-sm-sales-avg-ticket-lento.md](07-sm-sales-avg-ticket-lento.md) y [08-sm-sales-resto-pagina.md](08-sm-sales-resto-pagina.md). Solo lectura: no se cambió nada.

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-02 |
| **Áreas** | Semantic models |
| **Ámbito** | workspace `FabricPerfLab` · modelo semántico `sm_sales` |
| **Ventana analizada** | 2026-11-02 20:42 → 20:46 UTC (lectura de metadatos en vivo) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, semantic-model-authoring |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Media |

## Resumen

- **Pregunta:** tamaño en memoria del modelo, por tabla y por columna (diccionario, datos, jerarquías, relaciones), con cardinalidad y % del total, y columnas candidatas a ocultar o quitar.
- **Conclusión:** el modelo ocupa 845 392 359 bytes (806,2 MiB). `fact_sales` es el 97,45 % (785,7 MiB) y una sola columna, `fact_sales[sale_id]` (GUID de texto, 11 M valores únicos), es el 65,47 % (527,9 MiB). Con `sale_ts` y `line_margin` suman el 81,1 %.
- **Impacto:** el 69,2 % (557,6 MiB) está en columnas que ninguna medida usa y que se pueden quitar sin tocar ninguna medida (R1); sumando `sale_ts` tras aplicar el rediseño de fechas (R2) se llega al 78,4 % (632,3 MiB). Efecto esperado en actualización y en memoria; no se midió tiempo de refresco.
- **Primera acción:** R1, quitar `sale_id` del origen del modelo (527,9 MiB, 65,5 %). Ocultarla no libera memoria.

## Alcance

**Pregunta original:** tamaño en memoria del modelo, de cada tabla y de cada columna (diccionario, datos, jerarquías, relaciones), ordenado de mayor a menor, con cardinalidad y % del total; señalar candidatas a ocultar o quitar (`sale_id`, `sale_ts`, `year_month`, etc.), solo como recomendación.

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Tamaños de almacenamiento Import (DMV vía `INFO.STORAGE*`) de las 6 tablas, relaciones y estructuras de jerarquía | Memoria de capacidad en ejecución (consultas, caché), tiempo de refresco, uso de columnas en informes |

**Hipótesis de partida:** H-a) `sale_id` y `sale_ts`, de alta cardinalidad, dominan el tamaño (09, H5); H-b) las estructuras de jerarquía de columnas no usadas añaden memoria.

**Recorrido:** Semantic models únicamente.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Modo de almacenamiento del modelo | Import en las 6 tablas | 07 (E3) |
| Permisos con los que se ejecutó | Lectura por XMLA vía powerbi-modeling-mcp; `INFO.STORAGE*` accesibles | E1-E3 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| sm_sales | SemanticModel | Consumo | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Total del modelo | 845 392 359 bytes (806,2 MiB) | Suma de diccionario + datos + jerarquías + relaciones | E1-E3 |
| Diccionarios | 520 038 631 bytes (496,0 MiB, 61,5 %) | | E1 |
| Datos (segmentos) | 219 149 016 bytes (209,0 MiB, 25,9 %) | | E2 |
| Estructuras de jerarquía | 105 661 288 bytes (100,8 MiB, 12,5 %) | | E2 |
| Relaciones | 543 424 bytes (0,5 MiB, 0,06 %) | | E2 |
| `fact_sales` | 97,45 % del total | | E4 |
| `fact_sales[sale_id]` | 553 497 381 bytes, 65,47 % | Columnas de alta cardinalidad inflan el diccionario, `modeling-guidelines.md` § Table Columns | E4 |

Las cifras en MiB usan 1 MiB = 1 048 576 bytes.

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | DAX | `EVALUATE INFO.STORAGETABLECOLUMNS()` | 120 filas: 44 de datos (`BASIC_DATA`), 38 `HIERARCHY_POSITION_TO_DATAID`, 34 `HIERARCHY_DATAID_TO_POSITION`, 4 `RELATIONSHIP`. Contiene `DICTIONARY_SIZE` por columna (resultado demasiado largo para el visor; se leyó desde el archivo guardado) |
| E2 | DAX | `GROUPBY(INFO.STORAGETABLECOLUMNSEGMENTS(), [TABLE_ID], [COLUMN_ID], SUMX(CURRENTGROUP(), [USED_SIZE]), ...)` | 120 filas con `USED_SIZE` de segmentos de datos, de jerarquías (`H$`) y de relaciones (`R$`). `fact_sales`: 11 segmentos; resto de tablas: 1 segmento |
| E3 | DAX | `COLUMNSTATISTICS()` (de 09, E3) | Cardinalidad por columna |
| E4 | Cálculo | Suma por columna: diccionario (E1) + datos (E2, tabla base) + jerarquía (E2, filas `H$` de la columna: `POS_TO_ID` + `ID_TO_POS`) + índice de relación (E2, `R$`) | Totales de las tablas siguientes |
| E5 | DAX | `EVALUATE INFO.STORAGETABLES()` | 48 filas; `RIVIOLATION_COUNT` = 1 en `dim_customer`, 0 en el resto |

Método de atribución: los tamaños de `H$` y `R$` se asignan a la columna o a la relación que los nombra; los de relación se suman a `fact_sales`. Los valores de las tablas de abajo son sumas de bytes devueltos por E1 y E2; la conversión a MiB y a % la hice yo.

### Tamaño por tabla (de mayor a menor)

| Tabla | Diccionario (B) | Datos (B) | Jerarquías (B) | Relaciones (B) | Total (B) | MiB | % |
|-------|-----------------|-----------|----------------|----------------|-----------|-----|---|
| fact_sales | 503 978 164 | 217 777 192 | 101 563 360 | 543 424 | 823 862 140 | 785,70 | 97,45 % |
| dim_customer | 15 632 098 | 1 323 664 | 3 967 744 | 0 | 20 923 506 | 19,95 | 2,48 % |
| dim_product | 281 082 | 40 808 | 114 360 | 0 | 436 250 | 0,42 | 0,05 % |
| dim_date | 59 986 | 2 768 | 6 352 | 0 | 69 106 | 0,07 | 0,01 % |
| promotions | 49 983 | 3 952 | 8 496 | 0 | 62 431 | 0,06 | 0,01 % |
| dim_store | 37 318 | 632 | 976 | 0 | 38 926 | 0,04 | < 0,01 % |
| **Total** | 520 038 631 | 219 149 016 | 105 661 288 | 543 424 | 845 392 359 | 806,20 | 100 % |

### Tamaño por columna (de mayor a menor, hasta el 0,01 %; el resto está por debajo de 0,1 MiB)

| Columna | Tipo | Cardinalidad | Diccionario (B) | Datos (B) | Jerarquía (B) | Total (B) | MiB | % |
|---------|------|--------------|-----------------|-----------|---------------|-----------|-----|---|
| fact_sales[sale_id] | Texto | 11 000 000 | 436 162 533 | 29 334 800 | 88 000 048 | 553 497 381 | 527,86 | 65,47 % |
| fact_sales[sale_ts] | DateTime | 950 391 | 41 651 484 | 28 991 976 | 7 603 168 | 78 246 628 | 74,62 | 9,26 % |
| fact_sales[line_margin] (calculada) | Double | 479 484 | 20 805 200 | 29 334 800 | 3 835 920 | 53 975 920 | 51,48 | 6,38 % |
| fact_sales[customer_id] | Entero | 200 000 | 4 994 576 | 29 334 800 | 1 600 048 | 35 929 424 | 34,26 | 4,25 % |
| fact_sales[amount] | Double | 92 941 | 144 | 29 334 800 | 371 784 | 29 706 728 | 28,33 | 3,51 % |
| fact_sales[unit_cost] | Double | 4 131 | 165 888 | 22 001 496 | 33 088 | 22 200 472 | 21,17 | 2,63 % |
| fact_sales[product_code] | Texto | 5 000 | 123 795 | 22 001 496 | 40 048 | 22 165 339 | 21,14 | 2,62 % |
| fact_sales[unit_price] | Double | 19 501 | 144 | 22 001 496 | 78 024 | 22 079 664 | 21,06 | 2,61 % |
| dim_customer[email] | Texto | 165 309 | 5 915 071 | 440 960 | 1 322 512 | 7 678 543 | 7,32 | 0,91 % |
| dim_customer[customer_id] | Entero | 165 309 | 4 855 812 | 440 960 | 1 322 512 | 6 619 284 | 6,31 | 0,78 % |
| dim_customer[customer_name] | Texto | 165 309 | 4 842 567 | 440 960 | 1 322 512 | 6 606 039 | 6,30 | 0,78 % |
| fact_sales[store_id] | Entero | 50 | 1 496 | 3 503 456 | 448 | 3 505 400 | 3,34 | 0,41 % |
| fact_sales[discount] | Double | 31 | 1 540 | 1 445 032 | 288 | 1 446 860 | 1,38 | 0,17 % |
| Relación fact_sales→dim_customer | | | | | | 533 344 | 0,51 | 0,06 % |
| fact_sales[payment_method] | Texto | 4 | 17 158 | 228 680 | 80 | 245 918 | 0,23 | 0,03 % |
| fact_sales[channel] | Texto | 4 | 17 156 | 223 968 | 80 | 241 204 | 0,23 | 0,03 % |
| dim_product[product_name] | Texto | 5 000 | 139 609 | 10 136 | 40 048 | 189 793 | 0,18 | 0,02 % |
| dim_product[product_code] | Texto | 5 000 | 123 795 | 10 136 | 40 048 | 173 979 | 0,17 | 0,02 % |
| promotions[product_code] | Texto | 1 026 | 30 151 | 3 416 | 8 256 | 41 823 | 0,04 | < 0,01 % |
| fact_sales[quantity] | Entero | 5 | 1 316 | 30 120 | 80 | 31 516 | 0,03 | < 0,01 % |
| dim_date[date] | Date | 730 | 22 612 | 1 104 | 5 888 | 29 604 | 0,03 | < 0,01 % |
| dim_product[list_price] | Double | 4 397 | 144 | 10 136 | 17 608 | 27 888 | 0,03 | < 0,01 % |
| dim_product[unit_cost] | Double | 4 131 | 144 | 10 136 | 16 544 | 26 824 | 0,03 | < 0,01 % |
| fact_sales[note_class] | Texto | 3 | 17 150 | 2 904 | 64 | 20 118 | 0,02 | < 0,01 % |
| fact_sales[year_month] (calculada) | Texto | 1 | 17 096 | 1 496 | 64 | 18 656 | 0,02 | < 0,01 % |
| Resto (columnas de dimensiones pequeñas, 4 relaciones menores, 6 columnas `RowNumber` de sistema) | | | | | | < 0,02 MiB cada una | | < 0,01 % cada una |

Las columnas con codificación por valor (`amount`, `unit_price`, `list_price`, `dim_product[unit_cost]`) no tienen diccionario (144 bytes).

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | `fact_sales[sale_id]` ocupa 527,9 MiB (65,5 % del modelo) y no la usa ninguna medida | Alta | Alta | E1, E2, E4; 07 (medidas) |
| H2 | `sale_ts` (74,6 MiB) y `line_margin` (51,5 MiB) siguen: 15,6 % del modelo | Media | Alta | E4 |
| H3 | Estructuras de jerarquía: 100,8 MiB (12,5 %), de ellas 83,9 MiB en `sale_id` | Media | Media | E2 |
| H4 | Columnas sin uso en medidas: `unit_price`, `unit_cost` (hecho), `discount`, `note_class`, `email`, `customer_name` | Baja | Media | E4; 07 (medidas) |

### H1 · `sale_id`

- **Qué ocurre:** 11 M de GUID de texto de 36 caracteres: diccionario de 436 162 533 bytes (415,9 MiB), datos 29 334 800 y jerarquía 88 000 048 (83,9 MiB). Total 553 497 381 bytes, 65,47 % del modelo.
- **Por qué:** cardinalidad igual al número de filas (11 000 000, 09 E3): el diccionario no comprime y contiene cada valor. Ninguna de las 10 medidas la referencia (07, E2). Umbral cualitativo de `modeling-guidelines.md` § Table Columns: "Watch for high-cardinality text columns (GUIDs, transaction IDs...)" y "Keep columns that are not referenced... waste memory". No hay umbral numérico en la skill; la severidad Alta la justifica el 65 % medido.
- **Impacto:** memoria, tiempo de refresco y de carga del modelo en la capacidad; no afecta a la latencia de las consultas medidas (07, 08).

### H2 · `sale_ts` y `line_margin`

`sale_ts` (950 391 valores) ocupa 78 246 628 bytes; solo la usa `[Sales Running Total]` y el candidato de 08 (R1) ya no la necesita. `line_margin` es calculada (`amount - quantity * unit_cost`): 53 975 920 bytes, de los que 20 805 200 son diccionario de casi 480 000 valores; sí se usa en `[Margin]`.

### H3 · Jerarquías

105 661 288 bytes de estructuras `H$` (E2); las de `sale_id` (88 000 048) y `sale_ts` (7 603 168) son el 90,5 % de ese total. Existen aunque las columnas estén ocultas; ver "Limitaciones" sobre si esas estructuras se crearon por consultas previas.

### H4 · Otras columnas sin uso en medidas

`unit_price` (21,06 MiB) y `discount` (1,38 MiB) no aparecen en ninguna medida; `unit_cost` del hecho (21,17 MiB) solo la usa la calculada `line_margin`, y `dim_product[unit_cost]` la duplica (09, H5); `dim_customer[email]` (7,32 MiB) y `customer_name` (6,30 MiB) no se usan en medidas. Uso en informes no verificado.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Quitar `sale_id` y otras columnas no usadas | H1, H4 | Alto | Bajo | Bajo | Sí |
| R2 | Quitar `sale_ts` tras reescribir `[Sales Running Total]` (08, R1) | H2 | Medio | Bajo | Bajo | Sí |
| R3 | `isAvailableInMdx = false` en columnas ocultas que se conserven | H3 | Medio | Bajo | Bajo | Sí |
| R4 | Valorar `line_margin` y `unit_cost` en el origen | H2, H4 | Medio | Medio | Medio | Sí |

### R1 · Quitar columnas sin uso

- **Cambio propuesto:** eliminar de la consulta/entidad del modelo (no solo ocultar: ocultar no libera memoria) `fact_sales[sale_id]`, `unit_price`, `discount`, `note_class`, `year_month` (tras llevar el eje de mes a `dim_date`, 09 R1/R2) y `dim_customer[email]`. Suma: 584 741 222 bytes = 557,6 MiB = 69,2 % del modelo. Antes, comprobar con el lineage de los informes que ningún visual, filtro o RLS las usa.
- **Impacto esperado:** de 806,2 MiB a unos 248,6 MiB, cálculo aritmético sobre estos tamaños (no medido tras el cambio).
- **Cómo validarlo:** repetir E1/E2 y comparar el total; verificar que las medidas devuelven los mismos valores.
- **Reversión:** volver a incluir las columnas en el origen y refrescar.
- **Requiere confirmación:** Sí, cambia el modelo (Tier C).

### R2 a R4

- **R2:** `sale_ts` (74,6 MiB, 9,26 %) puede quitarse una vez aplicado el candidato de `[Sales Running Total]` con `dim_date` (08, R1). Con R1 y R2 se llegaría a 662 987 850 bytes = 632,3 MiB = 78,4 %.
- **R3:** para columnas ocultas que se conserven (claves foráneas como `customer_id`), `isAvailableInMdx = false` evita crear la estructura de jerarquía (según `modeling-guidelines.md` § Table Columns); el ahorro máximo es el de las filas `H$` de esas columnas (p. ej. `customer_id`: 1 600 048 bytes). No aplica si la columna se usa en `SortByColumn`, jerarquías o variaciones.
- **R4:** pasar `line_margin` (51,5 MiB) a Gold evita guardar `unit_cost` (21,2 MiB) del hecho; ambas decisiones pertenecen al origen y se evalúan junto con 09 R7. `customer_name` (6,3 MiB) quedaría para el final.
- **Cómo validarlo (todas):** repetir E1/E2.
- **Requiere confirmación:** Sí.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Las relaciones ocupan una parte relevante | E2 | 543 424 bytes en total (0,06 %); la mayor es `fact_sales`→`dim_customer`, 533 344 bytes |
| D2 | Las dimensiones pesan: `dim_customer` | E4 | 19,95 MiB (2,48 %); `dim_product`, `dim_date`, `dim_store` y `promotions` suman menos de 0,7 MiB |
| D3 | `year_month` (calculada) es un problema de memoria | E1, E2 | Ocupa 18 656 bytes; su problema es de diseño (09, H2), no de tamaño |

## Siguientes pasos

- [ ] Comprobar en el lineage de los informes que las columnas de R1 no se usan — responsable: propietario del informe · relacionado con: R1
- [ ] Aplicar R1 y R2 y medir el tamaño y el tiempo de refresco — responsable: propietario del modelo · relacionado con: R1, R2
- [ ] Repetir el análisis tras aplicar R1-R3 para validar el impacto

## Notas

### Limitaciones

- Los tamaños son los del almacenamiento del motor (`INFO.STORAGE*`), no la memoria total del proceso en la capacidad (caché, consultas, estructuras temporales).
- Las estructuras de jerarquía (`H$`) pueden crearse a demanda cuando una consulta agrupa o filtra por la columna; mis consultas de diagnóstico previas (07 a 09) tocaron `sale_ts`, `customer_id` y otras. Por eso H3 y los % que incluyen jerarquías pueden estar algo sobrestimados respecto a un modelo recién cargado. El diccionario y los datos no dependen de ello. Los totales sin jerarquías son 739 731 071 bytes (705,5 MiB).
- Las cifras de cardinalidad proceden de `COLUMNSTATISTICS` (09, E3); los diccionarios de E1 incluyen entradas internas (+3).
- `DICTIONARY_ISRESIDENT` y la temperatura de los diccionarios no se analizaron.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Uso de columnas en informes | Definición del informe no leída | R1 y R2 condicionadas al lineage |
| Tiempo de refresco antes y después | Fuera del alcance | El ahorro en refresco no está cuantificado |
| Tamaño a nivel de segmento/partición | Solo se agregó por columna | No se detalló la distribución en los 11 segmentos de `fact_sales` |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Ninguna detectada | | | |

## Anexo

### Consultas completas

```dax
-- E1
EVALUATE INFO.STORAGETABLECOLUMNS()
-- E2
EVALUATE GROUPBY(INFO.STORAGETABLECOLUMNSEGMENTS(), [TABLE_ID], [COLUMN_ID],
  "used", SUMX(CURRENTGROUP(), [USED_SIZE]), "alloc", SUMX(CURRENTGROUP(), [ALLOCATED_SIZE]),
  "segs", COUNTX(CURRENTGROUP(), [SEGMENT_NUMBER]), "recs", SUMX(CURRENTGROUP(), [RECORDS_COUNT]))
-- E5
EVALUATE INFO.STORAGETABLES()
```
