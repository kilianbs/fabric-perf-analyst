# Inventario y mantenimiento de las tablas Delta de lh_bronze, lh_silver y lh_gold

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-01 |
| **Áreas** | Delta tables |
| **Ámbito** | workspace `FabricPerfLab` · 18 tablas Delta de `lh_bronze` (6), `lh_silver` (5) y `lh_gold` (7), más `lh_silver.store_snapshot` (no es una tabla Delta válida) |
| **Ventana analizada** | Estado a 2026-11-01 12:30 UTC (la última ejecución del pipeline es del 2026-11-01 05:00 UTC) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli (lakehouse-health) |
| **Modo** | Lectura + diagnóstico activo (Livy) |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** "Al principio salieron ficheros pequeños y un `_delta_log` muy largo en bronze. ¿Qué tablas de los tres lakehouses necesitan mantenimiento?"
- **Premisa: cierta a medias.** Dónde se midió cada cosa:
  - **Ficheros pequeños:** el mayor número está en **silver** (`customers`, 19.433 ficheros de 4,4 KB; `inventory_levels`, 2.000 de 3,4 KB), no en bronze. Bronze tiene `sales_raw` (4.000 de 239 KB) e `inventory_events` (300 de 4,7 KB).
  - **`_delta_log` largo:** en **número de commits** sí es de bronze: `inventory_events` tiene 301 commits JSON sin ningún checkpoint. En **tamaño** el más largo es de silver: `customers` 68,1 MB y `inventory_levels` 14,5 MB; el de `inventory_events` pesa solo 0,3 MB (E1).
- **Conclusión:** 8 de las 18 tablas necesitan algo; 10 no. Ninguna ha recibido nunca `OPTIMIZE` ni `VACUUM` (historial completo de las 18, E3). El orden por impacto en `pl_daily_sales` es `silver.customers`, `bronze.sales_raw`, `silver.inventory_levels`, `bronze.inventory_events`, `gold.dim_customer` y `gold.daily_store_sales`. En casi todas la causa es el patrón de escritura, y `OPTIMIZE` solo trata el síntoma.
- **`VACUUM` no sirve todavía:** hay ~17.900 ficheros huérfanos en `inventory_levels` y 3,5 GB en `silver.sales`, pero tienen 2 días y la retención por defecto es de 7 (inferido: ninguna tabla fija la retención, E2). No liberaría nada hasta el ~2026-11-06.
- **Primera acción (requiere confirmación):** compactar `silver.customers` (R1 del informe 02) y cambiar los patrones de escritura (R1 de este informe).

## Alcance

**Pregunta original:** "Al principio salieron ficheros pequeños y un _delta_log muy largo en bronze. ¿Qué tablas de los tres lakehouses necesitan mantenimiento? Verifica la premisa antes de aceptarla. [...] Dime en qué lakehouse y tabla se midió cada cosa. 1. Inventario de TODAS las tablas Delta de lh_bronze, lh_silver y lh_gold: número de ficheros, tamaño medio, tamaño total, filas, versiones y tamaño o número de ficheros de _delta_log, última OPTIMIZE y VACUUM, y propiedades relevantes. 2. Veredicto por tabla, con el umbral. 3. Distingue lo medido de lo inferido. 4. Solo recomendaciones."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Las 18 tablas Delta de los tres lakehouses: `DESCRIBE DETAIL`, `DESCRIBE HISTORY` por operación, propiedades, listado de OneLake del directorio y de `_delta_log`. | Efecto en la duración de cada celda (informes 01 a 03). `lh_silver.store_snapshot`: pertenece a `pl_store_snapshot`, se anota pero no se analiza. |

**Informes previos:** 01 (ficheros v0 → actual, commits, checkpoints, salud de `customers`, `sales_raw`, `inventory_events`, `inventory_levels`, filas, E14–E20), 02 (escaneo del `MERGE`), `2026-10-31/05-mantenimiento-delta-bronze-silver-gold.md` (mismo tema: no repito sus cifras de salud). Aquí se añade lo que faltaba: tamaño total y del `_delta_log`, ficheros huérfanos, última `OPTIMIZE`/`VACUUM`, propiedades y retención. Las filas y los ficheros por versión se toman del informe 01.

**Hipótesis:** (a) las tablas fragmentadas están en bronze; (b) hay más tablas fragmentadas que las ya medidas; (c) algún mantenimiento (`VACUUM`) ya es aplicable.

**Recorrido:** Delta tables únicamente. Sin pivote.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Sesión Livy | `lh_silver`, pool por defecto, sin `conf`, creada 12:34:35 UTC y borrada 12:38 (estado `killed`). 3 sentencias de lectura | E2, E3 |
| Retención de log y de ficheros | Ninguna tabla define `delta.logRetentionDuration` ni `delta.deletedFileRetentionDuration`; se aplican los valores por defecto de Delta (inferencia) | E2 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| `lh_bronze` / `lh_silver` / `lh_gold` | Lakehouse | Almacenamiento | `53249a1b-…` / `b01f7911-…` / `3aee923d-…` |

## Evidencia

### Inventario de las 18 tablas

Ficheros activos, tamaño total y propiedades: `DESCRIBE DETAIL` (E2). Ficheros físicos y `_delta_log`: listado de OneLake (E1). Filas y versiones: informe 01, a 2026-10-31 (E21 y tabla de tablas). "Huérfanos" = físicos − activos. Ninguna tabla tiene `OPTIMIZE` ni `VACUUM` en el historial (E3).

| Tabla | Ficheros activos | Tamaño medio | Tamaño total | Filas (inf. 01) | Commits JSON | Checkpoint | `_delta_log` | Ficheros físicos (huérfanos) |
|-------|------------------|--------------|--------------|-----------------|--------------|------------|--------------|------------------------------|
| **bronze.ctl_pipeline_runs** | 12 | 2,9 KB | 35 KB | 12 | 13 | 1 | 36 KB | 24 (12) |
| **bronze.customer_changes** | 96 | 76,7 KB | 7,4 MB | 339.884* | 12 | 1 | 121 KB | 96 (0) |
| **bronze.inventory_events** | 300 | 4,7 KB | 1,4 MB | 60.000 | **301** | **0** | 299 KB | 300 (0) |
| bronze.products_raw | 8 | 18 KB | 0,15 MB | 5.000 | 1 | 0 | 6 KB | 8 (0) |
| **bronze.sales_raw** | **4.000** | 239 KB | 957 MB | 10 M | 10 | 0 | 5,3 MB | 4.000 (0) |
| bronze.stores_raw | 8 | 2,4 KB | 19 KB | 50 | 1 | 0 | 5 KB | 8 (0) |
| **silver.customers** | **19.433** | **4,4 KB** | 85,7 MB | 296.452 físicas; 169.227 lógicas | 11 | 1 (v10) | **68,1 MB** | 20.321 (888) |
| **silver.inventory_levels** | **2.000** | 3,4 KB | 6,7 MB | 49.337 | 10 | 0 | **14,5 MB** | 19.889 (**17.889**) |
| silver.products | 8 | 18 KB | 0,15 MB | 5.000 | 10 | 0 | 68 KB | 80 (72) |
| silver.sales | 64 | 11,8 MB | 757 MB | 10 M | 10 | 0 | 1,2 MB | 640 (**576**; 3,5 GB) |
| silver.stores | 8 | 2,3 KB | 18 KB | 50 | 10 | 0 | 55 KB | 80 (72) |
| **gold.daily_store_sales** | 185 | 3,2 KB | 0,6 MB | 500 | 10 | 0 | 976 KB | 1.326 (1.141) |
| **gold.dim_customer** | 608 | 10,2 KB | 6,2 MB | 169.227 | 10 | 0 | 2,8 MB | 3.380 (2.772) |
| gold.dim_date | 1 | 7 KB | 7 KB | 730 | 1 | 0 | 2 KB | 1 (0) |
| gold.dim_product | 8 | 18 KB | 0,15 MB | 5.000 | 10 | 0 | 71 KB | 80 (72) |
| gold.dim_store | 8 | 2,3 KB | 18 KB | 50 | 10 | 0 | 55 KB | 80 (72) |
| gold.fact_sales | 64 | 8,6 MB | 549 MB | 10 M | 10 | 0 | 816 KB | 599 (**535**; 2,6 GB) |
| gold.promotions | 2 | 9 KB | 18 KB | 2.052 | 1 | 0 | 2 KB | 3 (1) |

\* `customer_changes` tenía 88 ficheros en el informe 01 y hoy 96: la ejecución 12 (fallida) llegó a añadir su lote antes de romper en `sales_raw`. Sus filas no se han re-contado.

### Propiedades relevantes y última `OPTIMIZE` / `VACUUM` (E2, E3)

| Tabla(s) | Propiedades de tabla | Operaciones en el historial |
|----------|----------------------|-----------------------------|
| bronze (todas) | `delta.parquet.vorder.enabled=true`; `inventory_events` además `delta.checkpointInterval=1000` | solo `WRITE` y `CREATE`. `inventory_events`: 300 `WRITE`. Ninguna `OPTIMIZE`/`VACUUM` |
| `silver.customers` | `delta.enableDeletionVectors=true` | 10 `MERGE`. Ninguna |
| resto de silver y gold | ninguna propiedad propia (`optimizeWrite`, `autoCompact` y retención no están definidas en la tabla) | `CREATE OR REPLACE TABLE AS SELECT` (10 en las sobrescritas). Ninguna |

`optimizeWrite` y `autoCompact` solo existen como configuración de sesión (informe 04): `env_bronze` los declara en `false`, `nb_01` pone `optimizeWrite=false`, y silver y gold no los fijan.

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | OneLake | Listado de `Tables/` y, por tabla, de `_delta_log` y del directorio (recursivo) en los tres lakehouses | Columnas de `_delta_log`, commits, checkpoints y ficheros físicos de la tabla de inventario. `lh_silver.store_snapshot`: 96 ficheros parquet (930 MB), sin commits JSON y un único fichero de 0 KB en `_delta_log` |
| E2 | Livy | `DESCRIBE DETAIL lh_*.{tabla}` × 18 (`numFiles`, `sizeInBytes`, `properties`) | Ficheros activos, tamaño total, propiedades. `lh_silver.store_snapshot` devuelve `DELTA_PATH_DOES_NOT_EXIST` (no es una tabla Delta) |
| E3 | Livy | `DESCRIBE HISTORY lh_*.{tabla}` con `groupBy("operation").count()` × 18 | Sin `OPTIMIZE` ni `VACUUM` |
| E4 | Livy | Sesión creada y borrada | Creación 12:34:35 UTC, borrado 12:38 UTC (estado `killed`) |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | Premisa parcial: ficheros pequeños sobre todo en silver; log largo en commits en bronze (`inventory_events`) y en bytes en silver (`customers`, `inventory_levels`) | Media | Alta | E1, E2 |
| H2 | `silver.customers` es la tabla que más lo necesita: 19.433 ficheros de 4,4 KB, 42,9 % de filas borradas por deletion vectors, log de 68,1 MB | Alta | Alta | E1, E2, informe 01/02 |
| H3 | Cuatro tablas generan ficheros pequeños por su patrón de escritura, no por falta de mantenimiento: `sales_raw`, `inventory_events`, `inventory_levels`, `dim_customer`/`daily_store_sales` | Alta | Alta | E1, E2, informe 01 |
| H4 | Hay ~6,2 GB de ficheros huérfanos (casi todo en dos tablas), pero `VACUUM` aún no puede retirarlos con la retención por defecto | Media | Media | E1, E2 |
| H5 | Diez tablas no necesitan mantenimiento | Baja | Alta | E1, E2 |
| H6 | `lh_silver.store_snapshot` no se reconoce como tabla Delta | Baja | Media | E1, E2 |

### H1 · Qué se midió y dónde

- **Ficheros pequeños (media < 32 MB, `performance-patterns.md` § Small File Problem):** `silver.customers` 19.433 × 4,4 KB; `silver.inventory_levels` 2.000 × 3,4 KB; `bronze.sales_raw` 4.000 × 239 KB; `bronze.inventory_events` 300 × 4,7 KB; `gold.dim_customer` 608 × 10 KB; `gold.daily_store_sales` 185 × 3,2 KB (E2). `silver.sales` (11,8 MB) y `gold.fact_sales` (8,6 MB) están bajo 32 MB de media pero con solo 64 ficheros.
- **Log largo:** por número de commits, `bronze.inventory_events` (301, ningún checkpoint); por tamaño, `silver.customers` (68,1 MB, un checkpoint de 4 MB en v10) y `silver.inventory_levels` (14,5 MB para 10 commits, sin checkpoint) (E1). La anomalía 3 del procedimiento de salud (informe 01 E17–E20) se midió en bronze y en silver.

### H2 · `silver.customers`

- **Qué ocurre:** 19.433 ficheros, 13.120 con deletion vector, 127.225 de 296.452 filas borradas lógicamente (informe 01). El log pesa 68,1 MB (64,1 de commits + 4,0 del checkpoint) y cada commit añade ~2.000 ficheros (E1; informe 02).
- **Por qué:** cada `MERGE` escribe ~2.000 ficheros con AQE desactivado y 2.000 particiones (informes 02 y 04); no hay `OPTIMIZE` (E3).
- **Impacto:** es el 72 % del tiempo del `MERGE` (informe 02) y el stage más pesado de `nb_03` (informe 05). Severidad Alta: anomalía 2 y ficheros de 4,4 KB (`lakehouse-health.md`).

### H3 · Patrones de escritura

- `bronze.sales_raw`: `repartition(400)` → +400 ficheros por ejecución (informe 01). `bronze.inventory_events`: 30 appends por ejecución. `silver.inventory_levels`: overwrite con 2.000 particiones de shuffle, 1.999 ficheros con menos de 100 filas (informe 01 E20). `gold.dim_customer` y `daily_store_sales`: overwrite con particiones por defecto de 200 (informe 01).
- Una compactación puntual (`OPTIMIZE`) los repara hasta la ejecución siguiente: se vuelven a generar al volver a correr el pipeline. Por eso el cambio de patrón va antes o junto con ella.

### H4 · Huérfanos y `VACUUM`

- **Qué ocurre:** huérfanos (físicos menos activos): `silver.inventory_levels` 17.889 ficheros, `gold.dim_customer` 2.772, `gold.daily_store_sales` 1.141, `silver.sales` 576 ficheros (3,5 GB), `gold.fact_sales` 535 (2,6 GB) y 72 en cada dimensión pequeña (E1).
- **Por qué:** cada `CREATE OR REPLACE` retira los ficheros del `_delta_log` pero no los borra del almacenamiento hasta un `VACUUM`.
- **Impacto:** coste de almacenamiento y de listados, no de lectura (las lecturas usan solo ficheros activos). El efecto sobre la duración de `pl_daily_sales` es nulo o bajo: no medí listados. Hoy, `VACUUM` con 7 días de retención por defecto no elimina nada, porque los ficheros más antiguos son del 2026-10-30. El valor por defecto no está leído de las tablas (inferido); se puede comprobar con `SHOW TBLPROPERTIES`.

### H5 y H6

- Sin mantenimiento: `bronze.ctl_pipeline_runs`, `products_raw`, `stores_raw`, `customer_changes` (96 ficheros de 77 KB, crece +8 por ejecución, seguimiento), `silver.products`, `silver.stores`, `gold.dim_date`, `dim_product`, `dim_store`, `promotions`. Son tablas de 1–96 ficheros y menos de 7,4 MB (E2).
- `lh_silver.store_snapshot`: el directorio tiene 96 parquet (930 MB) pero `_delta_log` está vacío; Spark devuelve `DELTA_PATH_DOES_NOT_EXIST` (E1, E2). Es de otro pipeline (`pl_store_snapshot`, fallido el 10-30 según el informe 01 E27); no he determinado si es un resto de un `CREATE` interrumpido.

## Recomendaciones

Ordenadas por impacto en `pl_daily_sales`. Ninguna se ha ejecutado.

| ID | Tabla | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|-------|---------------|----------|---------|----------|--------|-----------------------|
| R1 | `silver.customers` | `REORG … PURGE` + `OPTIMIZE` y quitar AQE off / 2.000 particiones | H2 | Alto | Bajo | Medio | Sí |
| R2 | `bronze.sales_raw` | Quitar `repartition(400)`, activar optimize write y `OPTIMIZE` una vez | H3 | Alto | Bajo | Bajo | Sí |
| R3 | `silver.inventory_levels` | Escribir con pocas particiones (`coalesce`/AQE) y, después, `VACUUM` | H3, H4 | Medio | Bajo | Bajo | Sí |
| R4 | `bronze.inventory_events` | Un solo append por ejecución, `checkpointInterval` por defecto y `OPTIMIZE` | H3 | Medio | Bajo | Bajo | Sí |
| R5 | `gold.dim_customer`, `gold.daily_store_sales` | Menos particiones al sobrescribir y `OPTIMIZE` | H3 | Bajo | Bajo | Bajo | Sí |
| R6 | `silver.sales`, `gold.fact_sales`, `inventory_levels`, `dim_customer`, `daily_store_sales`, dimensiones | `VACUUM` con la retención por defecto a partir del ~2026-11-06 | H4 | Bajo | Bajo | Medio | Sí |
| R7 | `lh_silver.store_snapshot` | Investigar si es un resto de un `CREATE` interrumpido | H6 | Bajo | Bajo | Bajo | No (lectura) |

### R1 · `silver.customers`

- **Cambio propuesto:** el del informe 02 (R1): `REORG TABLE lh_silver.customers APPLY (PURGE)` y `OPTIMIZE lh_silver.customers`, con AQE activo y sin las 2.000 particiones en `env_silver` y `nb_02`. El checkpoint del log se crea solo cada 10 commits (v20); no hace falta forzarlo.
- **Impacto esperado:** de 19.433 a decenas de ficheros; el escaneo del `MERGE` vuelve cerca de los 17 s (informe 02) y el stage 44 de `nb_03` pasa de 608 tareas a unas pocas (informe 05).
- **Cómo validarlo:** `DESCRIBE DETAIL` (ficheros < 1.000), `DESCRIBE HISTORY` (ahora con `OPTIMIZE`), `scanTimeMs` del siguiente `MERGE`.
- **Reversión:** time travel dentro de la retención.
- **Requiere confirmación:** Sí.

### R2 a R5

- **R2:** en `nb_01`, quitar `repartition(WRITE_PARTITIONS)` y activar optimize write (R5 del informe 01); `OPTIMIZE` una vez de los 4.000 ficheros. Umbral: media 239 KB frente a 32 MB. Validar: ficheros nuevos por ejecución (hoy +400).
- **R3:** `inventory_levels` hereda las 2.000 particiones de shuffle; con AQE (R1) o un `coalesce` se escribirían decenas de ficheros. Validar: `numFiles` y log por commit (hoy 1,4 MB por commit).
- **R4:** construir los 30 almacenes en un solo DataFrame y un único `append` (R5 del informe 01); sin `checkpointInterval=1000` habría checkpoint cada 10 commits. Validar: commits por ejecución (hoy 30).
- **R5:** `dim_customer` y `daily_store_sales` heredan 200 particiones; reducirlas. Impacto bajo: tablas de 6 MB y 0,6 MB.
- **Reversión de R2–R5:** restaurar el notebook y la propiedad; `OPTIMIZE` se revierte con time travel dentro de la retención. **Requieren confirmación: Sí.**

### R6 · `VACUUM`

- **Cambio propuesto:** `VACUUM` con la retención por defecto de 7 días en las tablas con huérfanos, a partir del 2026-11-06 (las más antiguas son del 2026-10-30). No bajar la retención por debajo del valor por defecto sin comprobar que no hay lectores ni time travel en uso.
- **Impacto esperado:** liberar ~6,2 GB (E1). No afecta a la duración del pipeline.
- **Cómo validarlo:** `DESCRIBE HISTORY` con `VACUUM END` y recuento de ficheros físicos (E1).
- **Reversión:** no hay: los ficheros borrados no se recuperan; por eso va después de R1–R5.
- **Requiere confirmación:** Sí.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Las tablas fragmentadas están sobre todo en bronze | E1, E2 | Silver tiene las dos con más ficheros (19.433 y 2.000) y los dos logs más grandes (68,1 y 14,5 MB) |
| D2 | `VACUUM` es aplicable hoy | E1 | Los ficheros huérfanos tienen 2 días; retención por defecto de 7 (inferida) |
| D3 | Alguna tabla ya recibió mantenimiento | E3 | Cero `OPTIMIZE` y cero `VACUUM` en las 18 |
| D4 | `silver.sales` y `gold.fact_sales` necesitan `OPTIMIZE` | E2 | 64 ficheros de 8,6–11,8 MB (media bajo 32 MB, pero cada ejecución los reescribe enteros y su coste es el volumen, informe 01 H2) |

## Siguientes pasos

- [ ] Compactar `silver.customers` y cambiar AQE/particiones (R1) — responsable: ingeniería de datos · relacionado con: R1
- [ ] Cambiar los patrones de escritura de `nb_01`/`nb_02`/`nb_03` (R2–R5) y compactar — responsable: ingeniería de datos · relacionado con: R2–R5
- [ ] Programar `VACUUM` desde el 2026-11-06 (R6) — responsable: ingeniería de datos / `FabricAdmin` · relacionado con: R6
- [ ] Repetir E1–E3 tras aplicar R1–R5 — responsable: FabricPerfAnalyst

## Notas

### Limitaciones

- Filas y versiones por tabla son las del informe 01 (2026-10-31) para las 17 tablas salvo `customer_changes`, que hoy tiene 8 ficheros más; no se re-contaron.
- "Última `OPTIMIZE`/`VACUUM`" = ausencia en `DESCRIBE HISTORY` (E3). `DESCRIBE HISTORY` solo cubre las versiones presentes en el log (todas las del ciclo de vida de estas tablas, creadas el 2026-10-30).
- Los ficheros huérfanos son físicos menos activos; incluyen también ficheros de transacciones escritas y no confirmadas, si las hubiera: no he distinguido.
- El umbral de 32 MB y la anomalía de deletion vectors vienen de `performance-patterns.md` § Small File Problem y `lakehouse-health.md`; en este informe no se volvió a ejecutar `sp_get_table_health_metrics`.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Retención efectiva (`SHOW TBLPROPERTIES`) | No se ejecutó para las 18; las propiedades de `DESCRIBE DETAIL` no incluyen retención | H4 y R6 con retención por defecto inferida |
| Filas actuales de `customer_changes` | No re-contadas | Sin efecto en el veredicto |
| Contenido de `lh_silver.store_snapshot` | No es una tabla Delta válida | H6 con confianza Media |

### Discrepancias entre skills y documentación

Sin discrepancias nuevas respecto a los informes anteriores.

## Anexo

Sentencias Livy (E2, E3), repetidas para las 18 tablas con `lh_bronze.`, `lh_silver.` y `lh_gold.` como prefijo:

```python
spark.sql("DESCRIBE DETAIL lh_silver.customers").selectExpr("'lh_silver.customers' as t","numFiles","sizeInBytes","properties").show(truncate=False)
spark.sql("DESCRIBE HISTORY lh_silver.customers").groupBy("operation").count().show(truncate=False)
```

Listado de OneLake (E1): `GET https://onelake.dfs.fabric.microsoft.com/{ws}?resource=filesystem&recursive=…&directory={lakehouseId}/Tables/{tabla}[/_delta_log]`.
