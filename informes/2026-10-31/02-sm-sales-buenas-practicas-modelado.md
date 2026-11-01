# Revisión de buenas prácticas del modelo semántico sm_sales

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-10-31 |
| **Áreas** | Modelos semánticos → Delta tables / SQL endpoint (rastreo de integridad en lakehouse) |
| **Ámbito** | workspace `FabricPerfLab` · modelo `sm_sales`, `lh_gold`, `lh_silver`, `lh_bronze`, notebook `nb_02_bronze_to_silver` |
| **Ventana analizada** | Estado a 2026-10-31 (instantánea; sin ventana temporal de telemetría) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, semantic-model-authoring, sqldw-cli, spark-cli |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** si `sm_sales` cumple las buenas prácticas de modelado y, ante problemas de integridad, cuál es su origen en el lakehouse.
- **Conclusión:** el modelo incumple varias reglas, y la más grave es de datos. 1.537.039 filas de `fact_sales` (15,4 %) apuntan a 30.773 `customer_id` que no existen en `dim_customer`. Los borra `nb_02_bronze_to_silver` al aplicar los `op='D'` del CRM sobre la dimensión, mientras las ventas de esos clientes se conservan.
- **Impacto:** 458,5 M de 2.983,0 M en ventas (15,4 %) caen en un cliente en blanco en el modelo. Además, el modelo no tiene tabla de fechas marcada, usa `double` en importes, deja visibles las claves y tiene dos relaciones bidireccionales, una de ellas muchos a muchos sin necesidad.
- **Primera acción:** R1, decidir con negocio cómo conservar los clientes borrados (soft delete o fila "Cliente desconocido") para que la dimensión cubra todas las claves de hechos.

## Alcance

**Pregunta original:** "Revisa si el modelo semántico sm_sales cumple las buenas prácticas de modelado. Usa la definición completa del modelo y no solo INFO.VIEW: tipos de datos exactos (también los de las claves de relación), cardinalidad comprobada con los datos, columnas calculadas en tablas de hechos, anotaciones del modelo, tabla de fechas y en qué tabla viven las medidas. Si ves problemas de integridad, rastrea su origen en el lakehouse."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Definición TMDL completa, anotaciones, relaciones, tipos, medidas, tabla de fechas; cardinalidad contra `lh_gold`; rastreo bronze → silver → gold | Rendimiento DAX cronometrado (no pedido; sin benchmarks ni ClearCache), historial de refresh, RLS (sin roles en la definición) |

**Hipótesis de partida:** H-a, las claves de relación tienen tipos coherentes pero la cardinalidad real no cumple lo declarado. H-b, el modelo infringe `modeling-guidelines.md` en columnas, fechas y medidas. H-c, las claves huérfanas nacen aguas arriba, en la carga.

**Recorrido:** Semantic models (TMDL completo + INFO) → la comprobación de cardinalidad mostró huérfanos en `customer_id` → SQL endpoint de `lh_gold`, `lh_silver`, `lh_bronze` (Delta tables) → los 30.773 ids coinciden con borrados del CRM → definición del notebook `nb_02_bronze_to_silver`.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Modo de almacenamiento del modelo | Import, particiones M con `Sql.Database(... "lh_gold")` (no Direct Lake) | E1 |
| Nivel de compatibilidad | 1604 | E1 |
| Permisos con los que se ejecutó | Lectura de definición (`getDefinition`), conexión XMLA con `INFO.*` y DAX, SELECT en SQL endpoints | E1, E4 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| sm_sales | SemanticModel | Consumo | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |
| lh_gold | Lakehouse / SQLEndpoint | Gold (origen del modelo) | 3aee923d-121b-415b-872c-4d5bb70664c0 / da36bf45-abe8-4f5d-a5d7-a06e7be62f2e |
| lh_silver | Lakehouse / SQLEndpoint | Silver | b01f7911-28fd-4dc2-ac51-1d19ed841238 (endpoint) |
| lh_bronze | Lakehouse / SQLEndpoint | Bronze | 53249a1b-e8a9-4270-9cb4-0f2ce3b10feb (endpoint) |
| nb_02_bronze_to_silver | Notebook | Transformación | 4205418f-cee2-4a3d-9390-328618160264 |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Filas de hechos sin cliente en `dim_customer` | 1.537.039 de 10.000.000 (15,4 %) | Integridad referencial esperada 0 | E5, E8 |
| `customer_id` huérfanos | 30.773 (hechos: 200.000 distintos; dimensión: 169.227) | — | E5, E6 |
| Ventas sin cliente | 458.540.792 de 2.982.980.596 (15,4 %) | — | E8 |
| Clientes cuyo último cambio en bronze es `D` | 30.773 | Coincide con los huérfanos | E7 |
| Relaciones bidireccionales o M:M | 2 de 5 (40 %) | < 30 % (`modeling-guidelines.md` § Relationships) | E1 |
| Columnas calculadas en `fact_sales` | 2 (`line_margin`, `year_month`) | > 5 se revisa (§ Performance Guidelines) | E1 |
| Columnas `double` | 8 (6 en `fact_sales`, 2 en `dim_product`) | Evitar `Double` (§ Table Columns) | E1, E2 |
| Medidas fuera de una tabla de medidas | 10 de 10 dentro de `fact_sales` | — | E1 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `POST /v1/workspaces/{ws}/semanticModels/{sm}/getDefinition?format=TMDL` (POST de lectura; LRO y `GET /v1/operations/{id}/result`) | 6 tablas, 5 relaciones, 10 medidas, anotación `__PBI_TimeIntelligenceEnabled=1`; sin `dataCategory`, `isKey`, `sortByColumn`, `isHidden` ni descripciones |
| E2 | SQL | `INFORMATION_SCHEMA.COLUMNS` en `lh_gold` | Tipos origen: ids `int`, `product_code varchar(8000)`, importes `float`, fechas `date`/`datetime2` |
| E3 | SQL | `COUNT`, `COUNT DISTINCT` de las claves de cada tabla de `lh_gold` | `dim_customer` 169.227/169.227; `dim_product` 5.000/5.000; `dim_store` 50/50; `dim_date` 730/730; `promotions` 2.052 filas/1.026 productos; `fact_sales` 10.000.000 |
| E4 | MCP/DAX | `ConnectFabric` + `INFO.ANNOTATIONS()`, `INFO.TABLES()` | 3 anotaciones (`__PBI_TimeIntelligenceEnabled`=1, `__PBI_ServiceStoredInTmdl`, `__LastRPTime`); 6 tablas, ninguna con `DataCategory`; no existen tablas `LocalDateTable_*` |
| E5 | SQL | Anti-join de `fact_sales` contra cada dimensión en `lh_gold` | Huérfanos: cliente 1.537.039; producto 0; tienda 0; fecha 0 |
| E6 | SQL | Huérfanos: `COUNT DISTINCT`, rango de fechas | 30.773 ids; todo en `sale_date` 2026-09-01 a 2026-09-11 (~154k filas/día); `dim_date` 2026-01-01 a 2027-12-31 (730 días contiguos) |
| E7 | SQL | `lh_bronze.customer_changes`: operaciones y último `op` por cliente | 200.000 ids; `U` 298.128 filas, `D` 41.756 filas (38.054 ids); 30.773 ids con último cambio `D`; silver `customers` 169.227 filas y `source_run_seq` 1-11 |
| E8 | DAX | `EVALUATE ROW(... [Total Sales], CALCULATE(..., ISBLANK(dim_customer[customer_id])) ...)` | 1.537.039 filas con cliente en blanco; ventas 2.982.980.595,69 frente a 2.524.439.803,37 con cliente |
| E9 | REST | `POST .../notebooks/{nb}/getDefinition?format=ipynb` (lectura) | Celda de clientes: `MERGE ... whenMatchedDelete(condition="s.op = 'D'")`; celda de ventas: `left join` a `customers` y reconstrucción completa de `sales` |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | 15,4 % de las filas de hechos y de las ventas no tiene cliente en la dimensión (integridad referencial rota) | Alta | Alta | E5, E6, E8 |
| H2 | Origen de H1: `nb_02` borra de `dim_customer` los clientes con `op='D'` y las ventas se conservan | Alta | Alta | E7, E9 |
| H3 | Sin tabla de fechas válida: `dim_date` no está marcada (`dataCategory` Time), le falta trimestre y orden de nombres, y `Sales LY` usa `fact_sales[sale_date]` | Media | Alta | E1, E4 |
| H4 | Tipos de datos: `double` en importes y precios; claves de texto (`product_code`); `sale_id` y `sale_ts` de cardinalidad casi única | Media | Alta | E1, E2, E3 |
| H5 | Relaciones: `fact_sales`–`dim_customer` bidireccional y `promotions`–`dim_product` M:M bidireccional sin necesidad (la dimensión es única) | Media | Alta | E1, E3 |
| H6 | Columnas calculadas en la tabla de hechos (`line_margin`, `year_month`) sobre 10 M de filas | Media | Alta | E1 |
| H7 | Las 10 medidas viven en `fact_sales`; solo 2 tienen `formatString`; claves visibles con `summarizeBy: sum` | Baja | Alta | E1 |
| H8 | Anotaciones y metadatos del modelo escasos (sin descripciones; `__PBI_TimeIntelligenceEnabled=1` sin tablas auto-fecha) | Baja | Alta | E1, E4 |

### H1 · Claves de cliente huérfanas en los hechos

- **Qué ocurre:** 1.537.039 filas de `fact_sales` (15,4 %) referencian 30.773 `customer_id` ausentes de `dim_customer`. En el modelo aparecen bajo "(en blanco)": 458,5 M de ventas. Producto, tienda y fecha tienen 0 huérfanos (E5, E8).
- **Por qué:** las 5 relaciones son many-to-one válidas en el modelo, pero Import no impone integridad referencial. Las ventas afectadas son las de 2026-09-01 a 2026-09-11 de esos clientes (E6).
- **Impacto:** análisis por segmento o cliente sin esas ventas (por ejemplo `Enterprise Sales`, `Top 100 Customers Sales`, `Active Customers`) y totales que no cuadran con la suma por segmento.

### H2 · Origen en el lakehouse

- **Qué ocurre:** `lh_bronze.customer_changes` trae 200.000 ids, 30.773 de ellos con último cambio `D`. `lh_silver.customers` tiene 169.227 filas, es decir 200.000 − 30.773 (E7).
- **Por qué:** `nb_02_bronze_to_silver` aplica `whenMatchedDelete(condition="s.op = 'D'")` sobre `customers` y después reconstruye `sales` con `left join` a `customers` sin quitar las ventas de esos clientes. Gold hereda el hueco (E9). La coincidencia exacta 30.773 = 30.773 confirma la causa.
- **Impacto:** el borrado físico elimina el cliente pero no su historia. Cada nueva baja del CRM aumentará los huérfanos.

### H3 · Tabla de fechas

- **Qué ocurre:** `dim_date` tiene 730 días contiguos (2026-01-01 a 2027-12-31), cubre todas las fechas de hechos y se relaciona con `fact_sales[sale_date]` (E3, E5, E6). No tiene `dataCategory: Time`, ni columna marcada como clave, ni `sortByColumn` en `month_name`/`weekday`, ni trimestre, y `year`/`month` se agregan con `sum` (E1).
- **Por qué:** incumple `modeling-guidelines.md` § Date/Calendar Table. `Sales LY` usa `SAMEPERIODLASTYEAR(fact_sales[sale_date])` en lugar de `dim_date[date]`, así que no aprovecha la tabla de fechas.
- **Impacto:** meses ordenados alfabéticamente en visuales y time intelligence frágil. Con solo 10 días de ventas en 2026 la medida `Sales LY` devuelve blanco.

### H4 · Tipos de datos

- **Qué ocurre:** `unit_price`, `unit_cost`, `discount`, `amount`, `line_margin`, `list_price` y `unit_cost` (dim_product) son `double` (origen `float`). Tipos de claves: `customer_id`, `store_id` int64↔int; `sale_date` date↔dateTime, que coincide en ambos lados; `product_code` string↔varchar (E1, E2). `fact_sales` tiene `sale_id` con 10 M valores distintos y `sale_ts` datetime.
- **Por qué:** `modeling-guidelines.md` § Table Columns manda evitar `Double` y preferir claves `Int64`. Las claves coinciden en tipo, así que no hay error de relación. La clave de texto sí es la menos eficiente y todas las columnas de texto son `varchar(8000)` en origen.
- **Impacto:** riesgo de redondeo en importes y diccionarios grandes (`sale_id` no lo usa ninguna medida ni relación).

### H5 · Relaciones y cardinalidad

- **Qué ocurre:** `fact_sales→dim_customer` es `bothDirections`. `promotions→dim_product` es `bothDirections` y `toCardinality: many` (M:M), aunque `dim_product.product_code` es único (5.000/5.000) y `promotions` repite 2 filas por producto (2.052/1.026) (E1, E3).
- **Por qué:** 2 de 5 relaciones (40 %) superan el 30 % que `modeling-guidelines.md` § Relationships fija como límite para bidireccionales y M:M. La relación correcta es muchos a uno, `promotions`→`dim_product`, de filtro único.
- **Impacto:** `promotions` filtra producto y producto filtra hechos, con riesgo de ambigüedad y de consultas más costosas.

### H6 · Columnas calculadas en la tabla de hechos

- **Qué ocurre:** `line_margin = amount − quantity × unit_cost` (double) y `year_month = FORMAT(sale_date,"yyyy-MM")` (string) se materializan en cada refresh sobre 10 M de filas (E1).
- **Por qué:** 2 columnas no superan el umbral de 5, pero la guía recomienda medidas o empujarlas al origen. `year_month` pertenece a `dim_date`. `line_margin` puede ser `SUMX` o columna en gold.
- **Impacto:** memoria y tiempo de refresh. `Margin` y `Margin %` dependen de `line_margin`.

### H7 y H8 · Medidas, visibilidad y anotaciones (Baja)

- Las 10 medidas están en `fact_sales`; ninguna tabla de medidas dedicada. Solo `Total Sales` y `Total Quantity` tienen `formatString`. Ninguna columna tiene `isHidden`, y `customer_id`, `store_id`, `quantity`, `year`, `month` tienen `summarizeBy: sum`. `Margin %` usa `IFERROR` en lugar de `DIVIDE` (E1).
- Anotaciones: solo 3 y ninguna es de documentación (E4). `__PBI_TimeIntelligenceEnabled=1` activa fecha automática, aunque no existen tablas `LocalDateTable_*`. No hay descripciones de tabla ni de medida.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Conservar los clientes borrados (soft delete `is_deleted`) o añadir un miembro "Cliente desconocido" en `dim_customer` | H1, H2 | Alto | Medio | Medio | Sí |
| R2 | Añadir prueba de integridad hechos→dimensión en `nb_02`/`nb_03` que falle o alerte con huérfanos | H1, H2 | Alto | Bajo | Bajo | Sí |
| R3 | Marcar `dim_date` como tabla de fechas, añadir trimestre y ordenación, y usar `dim_date[date]` en `Sales LY` | H3 | Medio | Bajo | Bajo | Sí |
| R4 | Corregir relaciones: `promotions`→`dim_product` many-to-one de filtro único; `dim_customer` en una dirección | H5 | Medio | Bajo | Medio | Sí |
| R5 | Cambiar importes a `decimal` en gold/modelo; valorar clave entera para producto; quitar `sale_id` del modelo | H4 | Medio | Medio | Medio | Sí |
| R6 | Sustituir `line_margin` por medida o mover a gold; mover `year_month` a `dim_date` | H6 | Medio | Bajo | Bajo | Sí |
| R7 | Crear tabla de medidas, formatos y descripciones; ocultar claves y poner `summarizeBy: none`; `DIVIDE` en `Margin %` | H7, H8 | Bajo | Bajo | Bajo | Sí |

### R1 · Conservar los clientes borrados

- **Cambio propuesto:** en `nb_02` cambiar `whenMatchedDelete(condition="s.op = 'D'")` por `whenMatchedUpdate(condition="s.op = 'D'", set={"is_deleted": "true", ...})` y propagar `is_deleted` a gold. Si negocio exige borrado físico por privacidad, anonimizar nombre y correo y conservar el `customer_id`. Alternativa: fila `-1 / Cliente desconocido` y `COALESCE(customer_id, -1)` en los hechos.
- **Impacto esperado:** 0 huérfanos; 458,5 M de ventas vuelven a tener segmento (E5, E8).
- **Cómo validarlo:** repetir el anti-join de E5 (esperado 0) y `CALCULATE(COUNTROWS(fact_sales), ISBLANK(dim_customer[customer_id]))` de E8.
- **Reversión:** restaurar la versión previa del notebook y de la tabla Delta (time travel).
- **Requiere confirmación:** Sí, cambia notebook y datos, y el borrado puede responder a un requisito legal de privacidad.

### R2 a R7

- **R2:** añadir en `nb_03` un `SELECT COUNT(*) ... WHERE NOT EXISTS` por cada clave y fallar si es > 0. Validar provocando un `D` de prueba en un entorno no productivo.
- **R3:** en el modelo, `dataCategory: Time` y marcar `dim_date[date]` como clave; columna `quarter` en gold; `sortByColumn` de `month_name` por `month` y de `weekday` por su número; `Sales LY = CALCULATE([Total Sales], SAMEPERIODLASTYEAR(dim_date[date]))`. Validar con una consulta por mes y trimestre comparando el orden.
- **R4:** TMDL `relationship promotions_dim_product` sin `toCardinality`, `crossFilteringBehavior: oneDirection`; y quitar `bothDirections` en `fact_sales_dim_customer`. Validar con `INFO.RELATIONSHIPS()` y comprobando que los totales de `Total Sales` no cambian.
- **R5 a R7:** cambios de tipo y de metadatos con refresh posterior. Validar con `INFO.VIEW.COLUMNS()` y comparando `Total Sales` antes y después. Reversión: el TMDL actual (E1) sirve de copia.
- **Requiere confirmación:** Sí en todas, porque modifican modelo o lakehouse.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Claves de relación con tipos distintos entre hechos y dimensión | E1, E2 | `customer_id` y `store_id` int64, `product_code` string, `sale_date` dateTime en ambos lados |
| D2 | Duplicados en el lado "uno" de las dimensiones (cardinalidad real ≠ declarada) | E3 | `dim_customer`, `dim_product`, `dim_store` y `dim_date` tienen claves únicas |
| D3 | Huérfanos en producto, tienda o fecha | E5, E6 | 0 filas; `dim_date` cubre todas las fechas de hechos |
| D4 | Hueco de fechas en `dim_date` | E6 | 730 días contiguos |
| D5 | Tablas auto-fecha (`LocalDateTable_*`) inflando el modelo | E4 | Solo existen las 6 tablas de usuario |

## Siguientes pasos

- [ ] Decidir con negocio la política de borrado de clientes (soft delete o miembro desconocido) — responsable: propietario de datos / ingeniería de datos · relacionado con: R1
- [ ] Añadir la validación de integridad en el pipeline — responsable: ingeniería de datos · relacionado con: R2
- [ ] Corregir fecha, relaciones y tipos en el modelo — responsable: autor del modelo · relacionado con: R3, R4, R5, R6, R7
- [ ] Repetir el análisis tras aplicar R1 y R4 para validar el impacto

## Notas

### Limitaciones

- Revisión de estado puntual: no se comparó con versiones anteriores del modelo ni se midió DAX. No se ejecutó Livy ni ClearCache.
- Los roles RLS no aparecen en la definición TMDL, por lo que no se evaluaron.
- Una consulta pesada contra `lh_silver.sales` (anti-join de 10 M de filas) agotó el tiempo de espera del SQL endpoint y no se repitió. No cambia la conclusión: la causa se probó con bronze y con el recuento de `customers`.
- Umbrales de severidad: `modeling-guidelines.md` § Table Columns, § Relationships, § Date/Calendar Table, § Performance Guidelines. La asignación crítico → Alta, recomendado → Media, opcional → Baja sigue `SKILL.md` § Workflow: Analyze Best Practices de semantic-model-authoring. H1/H2 son Alta por impacto medido (15,4 % de las ventas).

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Recuento de huérfanos en `lh_silver.sales` | Tiempo de espera del endpoint en la consulta | Ninguno: el origen se determinó con bronze y `customers` |
| Uso de columnas por informes | Fuera del alcance (sin informes enlazados) | No se pudo confirmar qué columnas ocultar o eliminar con certeza |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Ninguna detectada | — | — | — |

## Anexo

### Consultas completas

- **E5:** `SELECT 'orph_customer', COUNT(*) FROM dbo.fact_sales f WHERE f.customer_id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.dim_customer d WHERE d.customer_id = f.customer_id)` y análogas para `product_code`, `store_id` y `sale_date`/`date`.
- **E7:** `SELECT COUNT(DISTINCT customer_id) FROM (SELECT customer_id, op, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY run_seq DESC, ingested_at DESC) rn FROM dbo.customer_changes) x WHERE rn = 1 AND op IN ('D','DELETE','d','delete')` → 30.773.

### Configuración efectiva

Relaciones (E1): `fact_sales.customer_id→dim_customer.customer_id` (bothDirections); `product_code→dim_product` (oneDirection); `store_id→dim_store`; `sale_date→dim_date.date`; `promotions.product_code→dim_product.product_code` (bothDirections, `toCardinality: many`).
