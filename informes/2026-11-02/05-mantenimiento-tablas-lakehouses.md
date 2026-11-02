# Mantenimiento de tablas Delta en lh_bronze, lh_silver y lh_gold

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-02 |
| **Áreas** | Delta tables |
| **Ámbito** | workspace `FabricPerfLab` · `lh_bronze`, `lh_silver`, `lh_gold` (18 tablas) |
| **Ventana analizada** | Estado puntual de las tablas, evaluado el 2026-11-02 ~17:55 UTC |
| **Agente / host** | GitHub Copilot (VS Code) · skills: sqldw-cli (lakehouse-health), spark-cli (performance-patterns), fabric-perf-analysis |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Alta (métricas de archivos medidas); Media (causas del layout, inferidas del código) |

## Resumen

- **Pregunta:** qué tablas de los tres lakehouses necesitan mantenimiento antes de compactar `customers`.
- **Conclusión:** de 18 tablas, 9 necesitan mantenimiento (2 con severidad Alta, 3 Media, 4 Baja) y 9 están bien. Las dos de severidad Alta son `lh_silver.customers` (47,5 % de filas borradas, 21 104 archivos) y `lh_bronze.sales_raw` (4 400 archivos de ~239 KB, +400 por ejecución).
- **Impacto:** ninguna tabla tiene `TableMaintenance` en el historial de jobs, y el layout lo genera la forma de escribir de los notebooks. Compactar sin cambiar el escritor deja las tablas que se reescriben cada día (`inventory_levels`, `dim_customer`, `daily_store_sales`) otra vez fragmentadas en la siguiente ejecución.
- **Primera acción:** R1, `REORG ... APPLY (PURGE)` + `OPTIMIZE` en `lh_silver.customers`, más R2 (`OPTIMIZE` de `sales_raw`). Ambas requieren confirmación.

## Alcance

**Pregunta original:** «Me has comentado de compactar customer, antes de hacerlo me gustaría analizar todo. ¿Qué tablas de los tres lakehouses necesitan mantenimiento?»

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Las 18 tablas de los tres lakehouses (inventario completo, sin muestreo); métricas de archivos y filas borradas; historial de jobs de los lakehouses | `DESCRIBE DETAIL` / `DESCRIBE HISTORY` (requieren sesión Livy; no cambiaban la lista de tablas a tratar); propiedades de tabla (`TBLPROPERTIES`); lectura de los `_delta_log`; tablas de otros workspaces |

**Hipótesis de partida:** la fragmentación de `customers` (informes 02 y 04) puede no ser un caso aislado: los mismos escritores (`repartition(400)`, `shuffle.partitions=2000`, optimize write desactivado, `MERGE`) deberían haber dejado otras tablas igual.

**Recorrido:** solo Delta tables. Evidencia de contexto tomada de los informes `2026-11-02/02-nb02-skew-joins-stages.md`, `03-config-spark-por-capa.md` y `04-gold-pool-dimensionamiento.md`.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad | `353a0ed6-2bba-456c-bac7-009fc42e4b94` (West Europe) | informe 01 |
| Acceso | SQL analytics endpoint de cada lakehouse vía `fabric-sqlendpoint`, `sys.sp_get_table_health_metrics` | E1–E21 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| `lh_bronze` | Lakehouse | Bronze | `53249a1b-e8a9-4270-9cb4-0f2ce3b10feb` (endpoint `03c34de1-3d8a-4a26-bd4d-cb5084ae92ce`) |
| `lh_silver` | Lakehouse | Silver | `b01f7911-28fd-4dc2-ac51-1d19ed841238` (endpoint `bd96d99c-58c8-4904-89ba-eda833882013`) |
| `lh_gold` | Lakehouse | Gold | `3aee923d-121b-415b-872c-4d5bb70664c0` (endpoint `da36bf45-abe8-4f5d-a5d7-a06e7be62f2e`) |

## Evidencia

### Métricas clave

Tamaño medio = `FileSizeInBytes / FileCount`. Filas por archivo = `PhysicalRowCount / FileCount`. Umbral: tamaño medio < 32 MB = problema de archivos pequeños; objetivo 128 MB–1 GB (`spark-cli/references/operations/performance-patterns.md` § Small File Problem). Los códigos de anomalía son los de `sqldw-cli/references/operations/lakehouse-health.md` § Health procedure.

| Lakehouse | Tabla | Código | Archivos | Filas | Tamaño total | Tamaño medio | Filas/archivo | Filas borradas | Evidencia |
|-----------|-------|--------|----------|-------|--------------|--------------|---------------|----------------|-----------|
| silver | `customers` | **2** | 21 104 | 314 588 | 88,6 MiB | 4,3 KiB | 14,9 | 149 279 (47,5 %); 15 557 delete bitmaps | E10 |
| bronze | `sales_raw` | **3** | 4 400 | 11 000 000 | 1,0 GiB | 239 KB | 2 500 | 0 | E8 |
| silver | `inventory_levels` | **3** | 2 000 | 53 288 | 6,5 MiB | 3,4 KB | 26,6 | 0 | E11 |
| gold | `dim_customer` | **3** | 660 | 165 309 | 6,0 MiB | 9,6 KB | 250 | 0 | E16 |
| bronze | `inventory_events` | **3** | 330 | 66 000 | 1,5 MiB | 4,7 KB | 200 | 0 | E6 |
| bronze | `customer_changes` | **3** | 104 | 368 264 | 7,3 MiB | 73 KB | 3 541 | 0 | E5 |
| silver | `sales` | **3** | 64 | 11 000 000 | 791 MiB | 12,4 MiB | 171 875 | 0 | E13 |
| gold | `fact_sales` | **3** | 64 | 11 000 000 | 573 MiB | 8,9 MiB | 171 875 | 0 | E20 |
| gold | `daily_store_sales` | 0 | 191 | 550 | 601 KiB | 3,2 KB | 2,9 | 0 | E15 |
| bronze | `ctl_pipeline_runs` | 0 | 13 | 13 | 37 KB | 2,9 KB | 1 | 0 | E4 |
| bronze | `products_raw` | 0 | 8 | 5 000 | 144 KB | 18 KB | 625 | 0 | E7 |
| bronze | `stores_raw` | 0 | 8 | 50 | 18 KB | 2,3 KB | 6 | 0 | E9 |
| silver | `products` | 0 | 8 | 5 000 | 144 KB | 18 KB | 625 | 0 | E12 |
| silver | `stores` | 0 | 8 | 50 | 18 KB | 2,3 KB | 6 | 0 | E14 |
| gold | `dim_date` | 0 | 1 | 730 | 7 KB | 7 KB | 730 | 0 | E17 |
| gold | `dim_product` | 0 | 8 | 5 000 | 144 KB | 18 KB | 625 | 0 | E18 |
| gold | `dim_store` | 0 | 8 | 50 | 18 KB | 2,3 KB | 6 | 0 | E19 |
| gold | `promotions` | 0 | 2 | 2 052 | 18 KB | 8,9 KB | 1 026 | 0 | E21 |

Versiones de checkpoint: `inventory_events` tiene `SnapshotVersion` 328 y `CheckpointVersion` 328, y `fact_sales` 10/10. Ninguna tabla devuelve código 4 (sin checkpoint reciente).

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | SQL | Inventario `sys.tables`/`sys.schemas` en `lh_bronze` | 6 tablas: `ctl_pipeline_runs`, `customer_changes`, `inventory_events`, `products_raw`, `sales_raw`, `stores_raw` |
| E2 | SQL | Inventario en `lh_silver` | 5 tablas: `customers`, `inventory_levels`, `products`, `sales`, `stores` |
| E3 | SQL | Inventario en `lh_gold` | 7 tablas: `daily_store_sales`, `dim_customer`, `dim_date`, `dim_product`, `dim_store`, `fact_sales`, `promotions` |
| E4–E9 | SQL | `EXEC sys.sp_get_table_health_metrics @table_name = 'dbo.<tabla>'` en `lh_bronze`, en el orden de la tabla de métricas | Cifras en Métricas clave; 4 devuelven código 3 y 2 devuelven código 0 |
| E10–E14 | SQL | Mismo procedimiento en `lh_silver` | `customers` código 2, `inventory_levels` y `sales` código 3, `products` y `stores` código 0 |
| E15–E21 | SQL | Mismo procedimiento en `lh_gold` | `dim_customer` y `fact_sales` código 3; el resto código 0 |
| E22 | REST | `GET /v1/workspaces/{ws}/items/{lakehouseId}/jobs/instances` para los tres lakehouses | bronze 0 instancias, gold 0, silver 7, todas `LivySession`; ninguna `TableMaintenance`; sin `continuationToken` |

Las 18 llamadas del procedimiento terminaron sin error. Ninguna quedó «No evaluada».

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | `lh_silver.customers`: 47,5 % de filas borradas y 21 104 archivos de 4,3 KiB | Alta | Alta | E10 |
| H2 | `lh_bronze.sales_raw`: 4 400 archivos de 239 KB, +400 por ejecución, tabla append-only | Alta | Alta | E8 |
| H3 | `lh_silver.inventory_levels`: 2 000 archivos con 26,6 filas cada uno | Media | Alta | E11 |
| H4 | `lh_gold.dim_customer`: 660 archivos de 9,6 KB | Media | Alta | E16 |
| H5 | `lh_bronze.inventory_events`: 330 archivos de 4,7 KB, crece a ritmo de una escritura por ejecución | Media | Media | E6 |
| H6 | `lh_bronze.customer_changes`: 104 archivos de 73 KB | Baja | Alta | E5 |
| H7 | `lh_silver.sales` y `lh_gold.fact_sales`: 64 archivos de 12,4 y 8,9 MiB, por debajo de 32 MB | Baja | Alta | E13, E20 |
| H8 | `lh_gold.daily_store_sales`: 191 archivos para 550 filas, aunque el procedimiento devuelve código 0 | Baja | Media | E15 |
| H9 | Ninguna tabla tiene mantenimiento registrado | Media | Media | E22 |

### H1 · `customers` combina filas borradas y archivos diminutos

- **Qué ocurre:** 149 279 de 314 588 filas físicas están marcadas como borradas (47,5 %). Hay 15 557 delete bitmaps para 21 104 archivos (74 %). 16 678 archivos tienen entre 1 y 10 filas (79 %) y todos pesan entre 1 y 16 KiB.
- **Por qué:** el `MERGE` de `nb_02` (líneas 31–73) reescribe cada día un conjunto de filas pequeño. Con optimize write desactivado y `shuffle.partitions=2000`, cada `MERGE` añade archivos y bitmaps, y nadie los compacta (informes 02 y 03; E22).
- **Impacto:** es la tabla cuyo `MERGE` pasa de 108 s a 421 s entre ejecuciones (informe 02), y la que lee `nb_03`.

### H2 · `sales_raw` crece 400 archivos por ejecución

- **Qué ocurre:** 4 400 archivos para 11 M filas (1,0 GiB), 239 KB de media y 2 500 filas por archivo. Snapshot v10 con 11 M filas: 1 M filas y 400 archivos por ejecución.
- **Por qué:** `nb_01` hace `repartition(400)` y `append` (línea 126) con optimize write desactivado (informes 01 y 03). Al ser append-only, el layout solo se arregla con mantenimiento.
- **Impacto:** `nb_02` lee la tabla completa en cada ejecución (informe 01), así que el coste de abrir archivos crece con ella. Es la única tabla cuyo número de archivos crece de forma lineal con las ejecuciones y que se lee entera cada vez.

### H3 · `inventory_levels` coincide con `shuffle.partitions=2000`

- **Qué ocurre:** 2 000 archivos de 3,4 KB, todos de entre 10 y 100 filas.
- **Por qué (inferido):** el número coincide con `spark.sql.shuffle.partitions=2000` de silver (informe 03). Es una inferencia por coincidencia de cifras; no he leído el código que la escribe ni el historial de la tabla.
- **Impacto:** no medido. Es una tabla pequeña (6,5 MiB) y no aparece en los stages analizados.

### H4 · `dim_customer` hereda las 660 particiones de lectura

- **Qué ocurre:** 660 archivos de 250 filas. El stage 52 de la sesión de gold también tiene 660 tareas (informe 04).
- **Por qué (inferido):** gold lee `customers`, que está fragmentada, con un número de particiones alto y lo escribe sin reducirlo. La coincidencia 660 = 660 no distingue si el stage 52 lee o escribe; ambas lecturas son compatibles. Esto matiza la certeza que di en el informe 04 H2 (ver Notas).
- **Impacto:** como gold sobrescribe la tabla en cada ejecución, compactarla a mano sirve hasta la siguiente ejecución.

### H5 a H8 · Fragmentación moderada o por debajo del umbral

- `inventory_events`: 330 archivos y 328 versiones; 200 filas por archivo. Crece una escritura por ejecución.
- `customer_changes`: 104 archivos de 73 KB y 3 541 filas cada uno; en bucket [16 KiB, 256 KiB) hay 96 y en [256 KiB, 4 MiB) hay 8.
- `silver.sales` y `gold.fact_sales`: 64 archivos de 171 875 filas, entre 4 y 64 MiB. El procedimiento los marca con código 3, y quedan por debajo de los 32 MB de `performance-patterns.md`. Salen de `repartitionByRange(64)` en `nb_02` y se sobrescriben en cada ejecución.
- `daily_store_sales`: 191 archivos de ~3 KB para 550 filas; el procedimiento devuelve 0, pero 2,9 filas por archivo es mala forma. Cálculo propio, no del procedimiento.

### H9 · Sin mantenimiento registrado

- **Qué ocurre:** E22 no devuelve ningún job `TableMaintenance` en ninguno de los tres lakehouses. En silver hay 7 instancias, todas `LivySession`.
- **Por qué:** nadie lo ha programado, o el historial de jobs ya expiró. No se puede distinguir con lo medido.
- **Impacto:** explica por qué `customers` y `sales_raw` han llegado a este estado, pero es indicio, no prueba. `DESCRIBE HISTORY` lo confirmaría.

## Recomendaciones

Ordenadas por impacto/esfuerzo. Ninguna se ha aplicado.

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | `REORG TABLE ... APPLY (PURGE)` y `OPTIMIZE` en `lh_silver.customers` | H1 | Alto | Bajo | Bajo | Sí |
| R2 | `OPTIMIZE` en `lh_bronze.sales_raw` y cambiar `nb_01` para escribir menos archivos | H2 | Alto | Medio | Bajo | Sí |
| R3 | Arreglar el escritor de las tablas que se sobrescriben cada ejecución (`inventory_levels`, `dim_customer`, `daily_store_sales`, `sales`, `fact_sales`) | H3, H4, H7, H8 | Medio | Medio | Bajo | Sí |
| R4 | `OPTIMIZE` periódico en las tablas append-only `inventory_events` y `customer_changes` | H5, H6 | Bajo | Bajo | Bajo | Sí |
| R5 | Programar `TableMaintenance` (`OPTIMIZE`, y `VACUUM` con retención explícita) para `customers`, `sales_raw`, `inventory_events` y `customer_changes` | H9 | Medio | Bajo | Medio | Sí |

### R1 · Purgar y compactar `lh_silver.customers`

- **Cambio propuesto:**

  ```sql
  REORG TABLE lh_silver.dbo.customers APPLY (PURGE);
  OPTIMIZE lh_silver.dbo.customers;
  ```

  Después, evitar que reaparezca: activar optimize write y auto compact en el `MERGE` de `nb_02` (informe 03 R1).
- **Impacto esperado:** de 21 104 a un número de archivos del orden de 1 y sin bitmaps. Se debería notar en el `MERGE` de `customers` (421 s en la última ejecución) y en la lectura de gold. La mejora concreta es una estimación; no la he medido.
- **Cómo validarlo:** repetir `EXEC sys.sp_get_table_health_metrics @table_name = 'dbo.customers'` y comparar `FileCount`, `DeleteBitmapCount` y `DeletedRowCount`. Después comparar la duración de los statements de `nb_02` y del stage de 660 tareas de gold.
- **Reversión:** `OPTIMIZE` y `REORG` no cambian los datos lógicos. Las versiones anteriores se pueden leer con time travel mientras no se ejecute `VACUUM`.
- **Requiere confirmación:** Sí — escritura sobre una tabla de producción que consume CU y reescribe los archivos de la tabla que lee gold.

### R2 · Compactar `lh_bronze.sales_raw` y reducir lo que escribe `nb_01`

- **Cambio propuesto:**

  ```sql
  OPTIMIZE lh_bronze.dbo.sales_raw;
  ```

  En `nb_01`, sustituir `repartition(400)` por un número ajustado al volumen (1 M filas ≈ 90 MB por ejecución, o sea 1 a 2 particiones de 64–128 MB) o activar optimize write en bronze (informe 03 R2).
- **Impacto esperado:** de 4 400 a ~10 archivos de ~100 MB; el crecimiento de 400 archivos por ejecución desaparece. Estimación mía a partir del tamaño total de E8, sin medir.
- **Cómo validarlo:** `sp_get_table_health_metrics` sobre `sales_raw` tras la siguiente ejecución: `FileCount` debe subir muy por debajo de 400.
- **Reversión:** igual que R1.
- **Requiere confirmación:** Sí — escritura y CU sobre ~1 GiB; cambia el notebook de ingesta.

### R3 · Corregir el escritor de las tablas que se reescriben

- **Cambio propuesto:** antes de cada `write` de `inventory_levels`, `dim_customer`, `daily_store_sales`, `silver.sales` y `fact_sales`, usar `coalesce(n)` con `n` que dé archivos de 128 MB o más (1 para las tablas de <10 MiB), o activar optimize write en el escritor. Quitar el `shuffle.partitions=2000` de silver (informe 03 R1) arregla `inventory_levels` si H3 es correcta.
- **Impacto esperado:** una tabla pequeña pasa de cientos o miles de archivos a 1–2. No lo he medido.
- **Cómo validarlo:** health metrics de cada tabla tras la siguiente ejecución completa del pipeline.
- **Reversión:** volver a la configuración anterior del notebook.
- **Requiere confirmación:** Sí — cambia notebooks de producción.

### R4 y R5 · Mantenimiento recurrente de las tablas append-only

- **Cambio propuesto:** ejecutar `OPTIMIZE` periódicamente (semanal es un punto de partida) sobre `inventory_events` y `customer_changes`, y `sales_raw` una vez resuelta R2. Programar `TableMaintenance` (Learn: *Manage a lakehouse with the REST API § Run table maintenance*) con retención de `VACUUM` explícita (no menos de 7 días, que es el valor por defecto de Delta).
- **Impacto esperado:** estabiliza el número de archivos. Bajo en estas tablas por su tamaño.
- **Cómo validarlo:** instancias `TableMaintenance` en E22 con estado `Completed`, y `FileCount` estable semana a semana.
- **Reversión:** eliminar la programación.
- **Requiere confirmación:** Sí — `VACUUM` borra archivos y limita el time travel.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Falta de checkpoint reciente en alguna tabla (código 4) | E4–E21 | Ninguna tabla devuelve código 4; `inventory_events` tiene checkpoint en la versión 328 |
| D2 | Filas borradas en tablas distintas de `customers` | E4–E21 | `DeletedRowCount` es 0 en las otras 17 tablas |
| D3 | Necesitan mantenimiento `products`, `stores`, `*_raw` pequeñas, `dim_date`, `dim_product`, `dim_store`, `promotions`, `ctl_pipeline_runs` | E4, E7, E9, E12, E14, E17–E19, E21 | Código 0 y como máximo 13 archivos; compactarlas no aportaría. `ctl_pipeline_runs` (13 archivos, 13 filas) conviene vigilarla: parece añadir un archivo por ejecución |

## Siguientes pasos

- [ ] Decidir si ejecutar `DESCRIBE HISTORY` en `customers`, `sales_raw` e `inventory_events` (una sesión Livy, Tier B) para confirmar el ritmo de archivos por ejecución y si hubo `OPTIMIZE` o `VACUUM` — responsable: analista · relacionado con: H9
- [ ] Aprobar o rechazar R1 y R2 — responsable: propietario del workspace · relacionado con: R1, R2
- [ ] Decidir R3 junto con la revisión de configuración del informe 03 — responsable: ingeniería de datos · relacionado con: R3
- [ ] Repetir este análisis tras aplicar R1 y R2 para validar el impacto

## Notas

### Limitaciones

- Se midió el estado en un instante. La tendencia por ejecución de `customers` y `sales_raw` (archivos nuevos por día) sale del informe 01 y del código, no de una serie temporal de la tabla.
- El historial de jobs tiene retención limitada; que no haya `TableMaintenance` no prueba que nunca se haya ejecutado.
- El procedimiento devuelve solo la anomalía más grave por tabla. `customers` (código 2) también tiene archivos pequeños, pero eso lo he calculado yo a partir de los percentiles de archivo, no lo devuelve el procedimiento.
- El stage 52 de gold puede estar leyendo `customers` o escribiendo `dim_customer` (H4). La API de stages no da el operador. Dejaría de ser ambiguo comparando su plan en `GET .../sql` con los nodos de `FileScan` y `Write`. No lo hice porque no cambia qué tablas necesitan mantenimiento.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| `DESCRIBE DETAIL`, `DESCRIBE HISTORY`, `SHOW TBLPROPERTIES` | Requieren una sesión Livy (Tier B); no se ejecutó porque la lista de tablas a tratar sale de las métricas de archivos | No sé si hubo `OPTIMIZE` o `VACUUM` antes, ni qué propiedades de tabla (optimize write, retención) tienen; H3 y H9 quedan con confianza menor |
| Lectura de las tablas por consumidores (modelo semántico, SQL endpoint) | Fuera del alcance de esta pregunta | No priorizo por uso de lectura salvo `customers`/`sales_raw` (leídas por `nb_02`/`nb_03`) |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Umbral de archivo pequeño | `performance-patterns.md`: media < 32 MB | `sp_get_table_health_metrics` marca código 3 sin publicar su umbral y devuelve 0 para `daily_store_sales` (191 archivos de 3,2 KB) | Cito ambos; listo `daily_store_sales` como Baja por mi cálculo, no por el procedimiento |
| Certeza de la causa del stage 52 | Informe 04 H2 lo atribuye a la lectura de `customers` | Esta evidencia (660 archivos en `dim_customer`) es compatible con lectura y con escritura | Mantengo la recomendación de compactar `customers`; la confianza del informe 04 H2 baja de «Media» a «Baja» en la causa exacta |
