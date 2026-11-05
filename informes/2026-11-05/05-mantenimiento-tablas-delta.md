# Mantenimiento de las tablas Delta de lh_bronze, lh_silver y lh_gold: veredicto por tabla, V-Order y orden de operaciones

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-05 |
| **Áreas** | Delta tables (con lectura de Spark resources y Semantic models para el consumidor de cada capa) |
| **Ámbito** | workspace `FabricPerfLab` · 19 tablas: 6 en `lh_bronze`, 6 en `lh_silver`, 7 en `lh_gold` |
| **Ventana analizada** | Estado del `_delta_log` y de las carpetas de datos leído el 2026-11-05 (versiones 0 a 450, desde el 30 oct 17:12 UTC) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, sqldw-cli, spark-cli |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** ¿qué tablas de los tres lakehouses necesitan mantenimiento (veredicto por tabla, también las sanas), con qué evidencia del `_delta_log`, qué V-Order deberían tener según quién las lee, y qué operación, en qué orden y con qué riesgo?
- **Conclusión:** 7 tablas necesitan mantenimiento, 2 hay que vigilarlas, 9 están sanas y 1 no se puede evaluar. Las urgentes son `silver.customers` (28.149 ficheros de 4 KB, 192.030 filas borradas por deletion vectors, un 55 % de las 350.980 físicas) y `bronze.sales_raw` (6.000 ficheros de 0,23 MB). Hay también 13,05 GiB de ficheros sin referenciar frente a 3,25 GiB activos (4 veces), casi todo en `silver.sales` y `gold.fact_sales`, que se reescriben cada día. `bronze.inventory_events` es la única sin checkpoint (451 JSON, `delta.checkpointInterval=1000`). `silver.store_snapshot` no tiene `_delta_log`.
- **Impacto:** el mantenimiento que más rinde es el de `customers` y `sales_raw`, porque son las lecturas que dominan `nb_02` y `nb_03` (informes 01 y 02). Pero compactar sin cambiar antes los escritores es inútil: `customers` volvería a ~1.900 ficheros por carga y las tablas que se sobrescriben cada noche pierden el `OPTIMIZE` en la siguiente carga.
- **Primera acción:** R1, corregir los escritores (informe 03, R1 y R2) y después ejecutar `OPTIMIZE` sobre `silver.customers`. Todo requiere confirmación; el agente no ejecutó nada.

## Alcance

**Pregunta original:** "antes de compactar silver.customers el usuario quiere analizar todo. ¿Qué tablas de los tres lakehouses (lh_bronze, lh_silver, lh_gold) necesitan mantenimiento? Dame un veredicto por tabla, también de las sanas (sana / vigilar / necesita mantenimiento), con la evidencia medida del _delta_log: nº de ficheros activos, tamaño medio y distribución, commits y ritmo de crecimiento por carga, deletion vectors, ficheros/versiones antiguas retenidas, y estado de los checkpoints del _delta_log (existencia, frecuencia, tamaño, nº de JSON posteriores al último checkpoint, checkpointInterval). Incluye V-Order según quién lee cada capa [...]. Para cada tabla que lo necesite indica qué operación de mantenimiento corresponde (OPTIMIZE, VORDER, VACUUM, optimizeWrite/autoCompact en escritura, checkpoint) y en qué orden, y qué riesgo tiene [...]."

**Informes previos:** `2026-11-05/01-pl-daily-sales-tendencia-crecimiento.md`, `2026-11-05/02-nb02-skew-stages-joins.md`, `2026-11-05/03-config-spark-capas-y-direct-lake.md` y `2026-11-05/04-dimensionamiento-sesiones-spark-pipeline.md`. Se reutilizan sus ritmos de crecimiento y la configuración por capa.

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Las 19 tablas de la carpeta `Tables/` de los tres lakehouses | Historial de `TableMaintenance` y de `OPTIMIZE`/`VACUUM` por Spark: no se consultó `DESCRIBE HISTORY` (sin Livy). Rendimiento DAX y refrescos del modelo |

**Hipótesis de partida:** H-a, el pipeline no ha ejecutado nunca `OPTIMIZE` ni `VACUUM`. H-b, las tablas que se reconstruyen cada noche acumulan versiones. H-c, V-Order no se corresponde con el consumidor de cada capa.

**Recorrido:** Delta tables. Se contrastó cada tabla con `sys.sp_get_table_health_metrics` (SQL endpoint) y con la lectura directa del `_delta_log` y de la carpeta de datos en OneLake. Los consumidores de cada capa se tomaron de los informes 03 y 04.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad | `FTL64` (trial), West Europe | informe 03, E9 |
| Runtime de las sesiones | 1.3 | informe 03 |
| Escritores | `nb_01` (bronze, `append`), `nb_02` (silver: `MERGE` en `customers`, `overwrite` en el resto), `nb_03` (gold: `overwrite` o `CREATE OR REPLACE` diario) | informe 01, E7 |
| Lectores | Bronze: `nb_02` (Spark). Silver: `nb_03` (Spark). Gold: `sm_sales`, un modelo Import que lee el SQL endpoint de `lh_gold` | informes 01 y 03 |
| Versión de protocolo | `silver.customers`: reader 3 / writer 7 (deletion vectors). El resto: reader 1 / writer 2 | E3 |
| Permisos | Lectura de OneLake y `VIEW DEFINITION` en los tres SQL endpoints | E2, E3 |

### Items analizados

| Item | Tipo | ID |
|------|------|----|
| lh_bronze (SQL endpoint) | Lakehouse | 53249a1b-… (03c34de1-…) |
| lh_silver (SQL endpoint) | Lakehouse | b01f7911-… (bd96d99c-…) |
| lh_gold (SQL endpoint) | Lakehouse | 3aee923d-… (da36bf45-…) |

## Evidencia

### Métricas clave

Umbrales: tamaño medio de fichero < 32 MB indica problema de ficheros pequeños (`performance-patterns.md` § Small File Problem); códigos del procedimiento de salud: 0 ninguno, 2 muchas filas borradas, 3 muchos ficheros pequeños, 4 sin checkpoint reciente (`lakehouse-health.md` § Health procedure). `OPTIMIZE` purga automáticamente los deletion vectors de un fichero si más del 5 % de sus filas están referenciadas por ellos, y `VACUUM` conserva 7 días por defecto (Learn, E5).

**Estado actual de cada tabla (E2, E3, E4)**

| Tabla | Ficheros activos · MB | Tamaño medio (p10 / p50 / p90) | Filas por fichero (mín / mediana / máx) | Código del endpoint | Deletion vectors |
|-------|-----------------------|-------------------------------|-----------------------------------------|---------------------|------------------|
| bronze.ctl_pipeline_runs | 17 · 0,05 | 3 KB (todos iguales) | 1 / 1 / 1 | 0 | no |
| bronze.customer_changes | 136 · 8,5 | 0,063 MB (0,036 / 0,037 / 0,038; máx 0,47) | 1.647 / 1.756 / 25.000 | 3 | no |
| bronze.inventory_events | 450 · 2,0 | 4,7 KB | 200 / 200 / 200 | 3 | no |
| bronze.products_raw | 8 · 0,1 | 18 KB | 625 / 625 / 625 | 0 | no |
| bronze.stores_raw | 8 · 0,02 | 2 KB | 6 / 6 / 7 | 0 | no |
| bronze.sales_raw | 6.000 · 1.369,2 | 0,228 MB (0,226 / 0,228 / 0,230) | 2.497 / 2.500 / 2.503 | 3 | no |
| silver.customers | 28.149 · 116,7 | 4,1 KB (p10 4,1 KB; máx 7,1 KB) | 1 / 6 / 140 | 2 | **21.440 ficheros con DV, 192.030 filas borradas de 350.980** (54,7 %) |
| silver.inventory_levels | 2.000 · 6,8 | 3,5 KB | 15 / 34 / 57 | 3 | no |
| silver.products | 8 · 0,1 | 18 KB | 625 | 0 | no |
| silver.stores | 8 · 0,02 | 2 KB | 6 / 6 / 7 | 0 | no |
| silver.sales | 64 · 1.068,2 | 16,7 MB (14,1 / 17,0 / 18,7; máx 20,4) | 173.137 / 239.527 / 289.210 | 3 | no |
| silver.store_snapshot | **sin `_delta_log`** · 192 ficheros parquet en la carpeta, 2,02 GiB | – | – | no evaluable (no existe en el endpoint) | – |
| gold.daily_store_sales | 198 · 0,6 | 3 KB | 1 / 3 / 10 | 0 | no |
| gold.dim_customer | 880 · 6,7 | 8 KB (5 / 6 / 9 KB; máx 31 KB) | 21 / 112 / 1.247 | 3 | no |
| gold.dim_date | 1 · 0,01 | 7 KB | 730 | 0 | no |
| gold.dim_product | 8 · 0,1 | 18 KB | 625 | 0 | no |
| gold.dim_store | 8 · 0,02 | 2 KB | 6 / 6 / 7 | 0 | no |
| gold.promotions | 2 · 0,02 | 9 KB | 1.026 | 0 | no |
| gold.fact_sales | 35 · 751,8 | 21,5 MB (14,2 / 22,7 / 25,4; máx 26,1) | 268.148 / 454.773 / 523.209 | 0 | no |

El procedimiento del endpoint devuelve solo la anomalía más grave y no encontró nada en `daily_store_sales` (198 ficheros de 3 KB para 750 filas), que sigue siendo un diseño pobre: ausencia de código no prueba que esté sana (`delta-tables.md` § Known traps).

**Commits y ritmo de crecimiento (E3; ritmos por carga del informe 01)**

| Tabla | Versiones · operación | Crecimiento por carga | Comentario |
|-------|-----------------------|-----------------------|------------|
| ctl_pipeline_runs | 18 · 17 `WRITE` | +1 fichero, +1 commit | Una fila por carga |
| customer_changes | 17 · `WRITE` | +8 ficheros, +1 commit | |
| inventory_events | 451 · 450 `WRITE` | +30 ficheros y +30 commits (uno por tienda) | Ritmo mayor de commits |
| sales_raw | 15 · `WRITE` | +400 ficheros, +91 MB, +1 commit | `repartition(400)` |
| customers | 16 · 15 `MERGE` | ~+1.900 ficheros netos, +1 commit; el último `MERGE` añadió 1.990 ficheros de datos y 7.249 DV, y retiró 286 ficheros | `shuffle.partitions=2000` |
| inventory_levels, products, stores, sales | 15 · `CREATE OR REPLACE` | 0 ficheros netos (reescritura completa); `sales` +69 MB | Una versión por noche |
| dim_customer | 15 · `CREATE OR REPLACE` | +~55 ficheros | Hereda las particiones de lectura de `customers` |
| daily_store_sales | 15 · `CREATE OR REPLACE` | 44 → 198 ficheros en 14 cargas | |
| fact_sales | 15 · `CREATE OR REPLACE` | +50 MB | |
| dim_date, promotions | 1 | – | Se crean una sola vez |

**Versiones y ficheros antiguos retenidos (E3)**

| Medida | Valor |
|--------|-------|
| Versiones retenidas | Todas desde la v0 (30 oct): 14–17 por tabla, 451 en `inventory_events` |
| Ficheros sin referenciar en las carpetas (sin contar `store_snapshot`) | 40.688 ficheros, 13,05 GiB, frente a 3,25 GiB activos |
| Principales | `silver.sales` 896 ficheros, 7.634 MB (7,1 veces lo activo); `gold.fact_sales` 855 ficheros, 5.550 MB (7,4 veces); `silver.inventory_levels` 27.889 ficheros, 86 MB; `gold.dim_customer` 6.356 ficheros, 77,5 MB; `silver.customers` 2.121 ficheros, 8,3 MB; `gold.daily_store_sales` 2.105 ficheros, 6,4 MB; `ctl_pipeline_runs` 17 ficheros |
| Antigüedad del más viejo | 30 oct 17:12 UTC (5 días 16 horas): con la retención por defecto de 7 días todavía no es elegible ningún fichero; la primera vez que `VACUUM` borraría algo es a partir del 6 nov ~17:12 UTC |
| Historial de mantenimiento | Ningún commit `OPTIMIZE` ni `VACUUM START/END` en ninguna tabla |

**Checkpoints (E3)**

| Tabla | Checkpoint (versión · tamaño) | JSON posteriores al último | Observación |
|-------|-------------------------------|----------------------------|-------------|
| Tablas con 11 o más versiones (13 tablas) | un único checkpoint en v10 | 4 a 7 | Frecuencia por defecto (cada 10 commits); sana |
| silver.customers | v10 · 4,05 MB | 5 | Checkpoint de 4 MB por las decenas de miles de entradas de ficheros |
| bronze.sales_raw / silver.inventory_levels | v10 · 1,16 MB cada una | 4 | Idem, por 6.000 y 2.000 ficheros |
| gold.dim_customer | v10 · 0,28 MB | 4 | |
| **bronze.inventory_events** | **ninguno** | **451** | `delta.checkpointInterval=1000` (única tabla con esa propiedad); cada lectura reproduce 451 JSON |
| Tablas con una versión (`products_raw`, `stores_raw`, `dim_date`, `promotions`) | ninguno | 1 | Normal |

El endpoint informa de `CheckpointVersion` 12 en `customers`, 13 en `products` y `stores` de silver, y 448 en `inventory_events`; en la carpeta `_delta_log` solo hay un checkpoint en v10 (y ninguno en `inventory_events`). La diferencia no se pudo explicar (ver Notas).

**V-Order por tabla y por lector (E3)**

| Capa | Quién la lee | V-Order hoy | V-Order recomendado |
|------|--------------|-------------|---------------------|
| Bronze (6 tablas) | Spark (`nb_02`) | **Sí en las 6**: propiedad `delta.parquet.vorder.enabled=true` y etiqueta `VORDER` en los ficheros | No: capa de escritura, lector Spark (Learn: no activarlo solo por Spark o el endpoint) |
| Silver (5 tablas Delta) | Spark (`nb_03`) | No (sin propiedad ni etiquetas) | No, salvo que Direct Lake la lea de forma principal |
| Gold (7 tablas) | `sm_sales` en Import por el SQL endpoint | No (sin propiedad ni etiquetas) | No mientras el modelo sea Import (Learn: V-Order no por el SQL endpoint); **Sí** en `fact_sales` y las dimensiones si se pasa a Direct Lake (informe 03, H5) |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | SQL | `SELECT ... FROM sys.tables ...` en el endpoint de `lh_gold` | 7 tablas |
| E2 | SQL | `EXEC sys.sp_get_table_health_metrics @table_name = 'dbo.<tabla>'` ×18 (6 bronze, 5 silver, 7 gold) | 17 evaluadas; `silver.store_snapshot` falla con "Cannot find the object" |
| E3 | OneLake | `GET` del listado recursivo de `Tables/<tabla>` y lectura de todos los JSON de `_delta_log` y de `_last_checkpoint`, para las 19 tablas | Ficheros activos (altas menos bajas), tamaños, filas por fichero (`stats`), deletion vectors, etiquetas y propiedades, ficheros sin referenciar, checkpoints |
| E4 | OneLake | Repetición para `silver.customers` aplicando las bajas antes que las altas dentro de cada commit | 28.149 ficheros activos, 21.440 con DV, 192.030 filas borradas; cuadra con E2 |
| E5 | Docs | Microsoft Learn: Cross-workload table maintenance; VACUUM; Deletion vectors; Direct Lake storage | Umbral del 5 % de DV, retención de 7 días, orden OPTIMIZE → VACUUM, efecto en Direct Lake |

No se ejecutó ninguna acción Tier B (ni Livy ni `ClearCache`).

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | `silver.customers`: 28.149 ficheros de 4 KB y 55 % de filas borradas por DV sin purgar | Alta | Alta | E2, E3, E4 |
| H2 | `bronze.sales_raw`, `customer_changes` e `inventory_events` acumulan ficheros pequeños; `inventory_events` además no tiene checkpoint | Alta (`sales_raw`) / Media | Alta | E2, E3 |
| H3 | Las tablas que se reescriben cada noche retienen 13,05 GiB sin referenciar y nunca han tenido `VACUUM` | Media | Alta | E3 |
| H4 | `inventory_levels`, `dim_customer` y `daily_store_sales` se reescriben con cientos o miles de ficheros diminutos por la configuración del escritor | Media | Alta | E2, E3 |
| H5 | V-Order está al revés que el consumidor: lo tiene bronze y no lo tiene gold | Media | Alta | E3 |
| H6 | `silver.store_snapshot` no es una tabla Delta válida: 2,02 GiB de parquet sin `_delta_log` | Media | Media | E2, E3 |

### H1 · silver.customers

- **Qué ocurre:** 28.149 ficheros activos, 116,7 MB, 4,1 KB de media, entre 1 y 140 filas por fichero (mediana 6). 21.440 ficheros llevan deletion vector y marcan 192.030 de las 350.980 filas físicas como borradas (54,7 %; el umbral de purga automática de `OPTIMIZE` es el 5 %). El checkpoint de v10 pesa 4,05 MB. El código del endpoint es 2 (muchas filas borradas).
- **Por qué:** cada `MERGE` escribe unos 2.000 ficheros nuevos (`numTargetFilesAdded` 1.990 en el último) por `shuffle.partitions=2000`, añade DV a otros 7.249 y reescribe 286; nunca se compacta ni se purga. Confirma lo supuesto en el informe 02 (H3): los 350.980 → 158.950 de la lectura eran las filas borradas.
- **Impacto:** es la lectura que domina `nb_02` (9.264 s en 4 stages) y `nb_03` (informes 01 y 02).

### H2 · Bronze

- **Qué ocurre:** `sales_raw` tiene 6.000 ficheros de 0,228 MB (todos entre 0,226 y 0,230), 2.500 filas por fichero y +400 ficheros por carga; `customer_changes` 136 ficheros (+8 por carga); `inventory_events` 450 ficheros de 4,7 KB y 450 commits (+30 por carga) sin ningún checkpoint y 451 JSON. Los tres tienen código 3 en el endpoint.
- **Por qué:** `repartition(400)` con `optimizeWrite` a `false` (`nb_01` celda 7) para `sales_raw`; un `append` por tienda en bucle (celda 8) para `inventory_events`, con `checkpointInterval` a 1000, un valor no justificado por el código ni por un comentario, así que es un hallazgo (`delta-tables.md` § Known traps).
- **Impacto:** `sales_raw` se lee entera cada noche en `nb_02` (stages 101 y 119, 1.116 s). Los 451 JSON de `inventory_events` se reproducen en cada lectura.

### H3 · Ficheros sin referenciar

- **Qué ocurre:** 40.688 ficheros y 13,05 GiB sin referenciar, frente a 3,25 GiB activos. `silver.sales` (7,1 veces lo activo) y `gold.fact_sales` (7,4 veces) son el 96 % del total. Ningún `VACUUM` ni `OPTIMIZE` en el historial.
- **Por qué:** `overwrite` o `CREATE OR REPLACE` diario crea una versión nueva y deja la anterior en disco hasta que `VACUUM` la borre. Se retienen 7 días de versiones por defecto, así que en régimen estable serán ~8 copias de cada tabla reescrita.
- **Impacto:** almacenamiento, no velocidad de lectura (los lectores solo usan los ficheros de la versión actual). Aún no es elegible ningún fichero (ver Evidencia).

### H4 · Escritores de muchas particiones

- **Qué ocurre:** `inventory_levels` se reescribe cada noche con 2.000 ficheros de 3,5 KB (67.790 filas); `dim_customer` con 880 (+55 por carga); `daily_store_sales` con 198 ficheros de 3 KB (750 filas).
- **Por qué:** `inventory_levels` y `daily_store_sales` salen de agregaciones con `shuffle.partitions=2000` (silver) o el valor por defecto con AQE desactivado (gold). `dim_customer` copia las particiones de lectura de `customers` (880 tareas, informe 04). Es la causa de que una compactación puntual se pierda la noche siguiente.
- **Impacto:** metadatos y lectura; `dim_customer` sube hacia el límite de 5.000 ficheros por tabla de Direct Lake (informe 03).

### H5 · V-Order

- **Qué ocurre:** las 6 tablas de bronze tienen V-Order (propiedad y etiqueta), las de silver y gold ninguno. La tabla `gold.fact_sales`, la que consumiría Direct Lake, no lo tiene.
- **Por qué:** `env_bronze` declara el perfil `readHeavyForPBI` (V-Order `true`) y `env_gold` el perfil `writeHeavy` con V-Order `false` (informe 03, H2 y H3); es lo contrario de lo que pide la guía de la skill y Learn. El desajuste de gold no cuesta nada mientras el modelo sea Import.
- **Impacto:** bronze paga un coste de escritura sin beneficio; gold necesitaría V-Order antes de adoptar Direct Lake.

### H6 · silver.store_snapshot

- **Qué ocurre:** la carpeta `Tables/store_snapshot` tiene 192 ficheros parquet, 2,02 GiB (el más antiguo del 30 oct 20:19 UTC) y ningún `_delta_log`. El SQL endpoint no la conoce.
- **Por qué:** no se determinó. Pertenece a `pl_store_snapshot`/`nb_05`, fuera de `pl_daily_sales`; no se leyó su código.
- **Impacto:** `OPTIMIZE` y `VACUUM` no aplican a una carpeta sin log Delta; ocupa más espacio que todas las tablas activas juntas (3,25 GiB).

## Veredicto por tabla

| Tabla | Veredicto | Motivo | Prioridad |
|-------|-----------|--------|-----------|
| bronze.ctl_pipeline_runs | Sana | 17 ficheros de una fila, +1 por carga, checkpoint v10 y 7 JSON; código 0. 17 ficheros sin referenciar sin explicar | – |
| bronze.customer_changes | Necesita mantenimiento | Código 3: 136 ficheros de 0,063 MB, +8 por carga | Baja |
| bronze.inventory_events | Necesita mantenimiento | Código 3: 450 ficheros de 4,7 KB y 450 commits; sin checkpoint, 451 JSON, `checkpointInterval=1000` | Media |
| bronze.products_raw | Sana | 8 ficheros, una sola versión | – |
| bronze.stores_raw | Sana | 8 ficheros, una sola versión | – |
| bronze.sales_raw | Necesita mantenimiento | Código 3: 6.000 ficheros de 0,228 MB, +400 por carga | Alta |
| silver.customers | Necesita mantenimiento | Código 2: 28.149 ficheros de 4 KB, 54,7 % de filas borradas por DV | Urgente |
| silver.inventory_levels | Necesita mantenimiento | Código 3: 2.000 ficheros de 3,5 KB, 27.889 sin referenciar | Media (escritor) |
| silver.products | Sana | 8 ficheros; 112 sin referenciar de 2 KB | – |
| silver.stores | Sana | 8 ficheros; 112 sin referenciar | – |
| silver.sales | Necesita mantenimiento | Código 3: 64 ficheros de 16,7 MB; 7,6 GiB sin referenciar | Media |
| silver.store_snapshot | No evaluable | Sin `_delta_log`, 2,02 GiB de parquet | Revisar |
| gold.daily_store_sales | Vigilar | Código 0, pero 198 ficheros de 3 KB para 750 filas, creciendo | Baja |
| gold.dim_customer | Necesita mantenimiento | Código 3: 880 ficheros de 8 KB, +55 por carga | Media (se corrige al arreglar `customers`) |
| gold.dim_date | Sana | 1 fichero, una versión | – |
| gold.dim_product | Sana | 8 ficheros | – |
| gold.dim_store | Sana | 8 ficheros | – |
| gold.promotions | Sana | 2 ficheros, una versión | – |
| gold.fact_sales | Vigilar | Código 0: 35 ficheros de 21,5 MB; sin V-Order; 5,55 GiB sin referenciar. Pasa a "necesita" si se adopta Direct Lake (filas por fichero < 1 M) | Baja |

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Corregir los escritores antes de compactar | H1, H2, H4, H5 | Alto | Bajo | Bajo | Sí |
| R2 | Compactar `silver.customers` y las tablas bronze con `OPTIMIZE` | H1, H2 | Alto | Bajo | Medio | Sí |
| R3 | Restablecer el checkpoint de `inventory_events` | H2 | Medio | Bajo | Bajo | Sí |
| R4 | `VACUUM` con retención por defecto, a partir del 6 nov | H3 | Medio | Bajo | Medio | Sí |
| R5 | V-Order solo en gold y solo si se adopta Direct Lake | H5 | Medio | Bajo | Medio | Sí |
| R6 | Revisar `silver.store_snapshot` | H6 | Medio | Bajo | Bajo | No |

### Orden de las operaciones

1. **R1, escritores (primero).** `nb_02` y `env_silver`: quitar `shuffle.partitions=2000`, AQE desactivado y broadcast desactivado (informe 03, R1). `nb_01`: un solo `append` de inventario y sin `repartition(400)`, o `optimizeWrite` activado (informe 04 y 01, R4). `nb_03`: AQE activo (informe 03, R2). Activar `autoCompact` en `silver.customers` y en las tablas que reciben `append`. Sin esto, `customers` vuelve a ~1.900 ficheros por carga y las tablas reescritas pierden cualquier `OPTIMIZE` en la carga siguiente.
2. **R2, `OPTIMIZE`, fuera de la ventana de 04:30 a 05:35 UTC:**
   1. `silver.customers`: `OPTIMIZE lh_silver.customers` (compacta 28.149 ficheros y purga los DV, porque el 54,7 % supera el 5 %). Dejaría unos pocos ficheros para ~159.000 filas vivas.
   2. `bronze.sales_raw`: `OPTIMIZE lh_bronze.sales_raw` (6.000 → pocos ficheros de ~128 MB o más).
   3. `bronze.customer_changes` y `bronze.inventory_events`: `OPTIMIZE`.
   4. `gold.dim_customer`: sin `OPTIMIZE`. Se reescribe sola con pocas particiones tras el paso 2.1; comprobar el recuento de ficheros después de la primera carga.
   5. Sin `OPTIMIZE` en `silver.sales`, `gold.fact_sales`, `silver.inventory_levels`, `gold.daily_store_sales`: se sobrescriben cada noche y la compactación se perdería. Su solución es el escritor (paso 1).
3. **R3, checkpoint de `inventory_events`:** `ALTER TABLE lh_bronze.inventory_events SET TBLPROPERTIES ('delta.checkpointInterval' = '10')` (o quitar la propiedad). El checkpoint se escribe en el siguiente commit múltiplo del intervalo.
4. **R4, `VACUUM`, después de `OPTIMIZE` y no antes del 6 nov ~17:12 UTC:** `VACUUM <tabla> DRY RUN` y luego `VACUUM <tabla>` con 168 horas, sobre las tablas de las capas silver y gold que se reescriben y las que se hayan compactado. Libera hasta ~13 GiB. No bajar de 7 días.
5. **R5, V-Order:** solo si `sm_sales` pasa a Direct Lake (informe 03, R3): activarlo en el escritor de `nb_03` (`spark.sql.parquet.vorder.default=true` o perfil `readHeavyForPBI`), no con `OPTIMIZE ... VORDER` aislado, porque las tablas se reescriben cada noche. En bronze, desactivarlo en `env_bronze` en el siguiente cambio; no hay que reescribir lo ya escrito.
6. **R6, `store_snapshot`:** comprobar con su dueño qué escribe en esa carpeta (`nb_05`) y si es una tabla Delta a medio escribir, un resto o un formato Parquet; hasta entonces no ejecutar mantenimiento ahí.

### Riesgos

- **`OPTIMIZE` y `MERGE`:** si `OPTIMIZE` coincide con el `MERGE` de `nb_02` (05:04 a 05:18) hay conflicto de concurrencia y uno de los dos falla. Ejecutarlo fuera de esa ventana.
- **Deletion vectors:** `silver.customers` conserva `delta.enableDeletionVectors=true`; tras compactar, el `MERGE` volverá a crear DV (pocos y sobre ficheros grandes). Con ficheros grandes el coste es menor, pero conviene `autoCompact` o un `OPTIMIZE` periódico para no volver al estado actual.
- **Escritor sin corregir:** compactar antes del paso 1 es trabajo perdido (ver arriba).
- **Retención de `VACUUM`:** Fabric rechaza por defecto retenciones menores de 7 días. No reducirla sin evaluar viaje en el tiempo y lectores concurrentes. No se detectó ningún consumo de versiones antiguas; el modelo es Import. Si se adopta Direct Lake, un modelo enmarcado depende de una versión concreta: no quitarle ficheros antes de reenmarcar.
- **Direct Lake:** `OPTIMIZE` invalida los segmentos en memoria y fuerza a transcodificar en la siguiente consulta; hoy no aplica (modelo Import), pero sí si se adopta, y entonces conviene hacerlo con poca frecuencia y fuera de horario.
- **`VACUUM` y deletion vectors:** `VACUUM` no borra ficheros que un DV todavía referencia; tras `OPTIMIZE` aparecerán más ficheros elegibles.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Alguna tabla ya tuvo `OPTIMIZE` o `VACUUM` | E3 | Ningún commit de ese tipo en las 19 tablas; todas conservan la v0 |
| D2 | Los checkpoints están rotos o atrasados en general | E3 | 13 tablas tienen su checkpoint en v10 con 4 a 7 JSON posteriores; solo `inventory_events` carece de él |
| D3 | Alguna tabla acumula deletion vectors aparte de `customers` | E3 | `dv_files` = 0 en las otras 18 |
| D4 | `silver.sales` o `gold.fact_sales` tienen ficheros diminutos | E2, E3 | 64 y 35 ficheros de 16,7 y 21,5 MB; el problema de esas tablas es el espacio sin referenciar |
| D5 | Hay tablas con ficheros oversized | E3 | Ningún fichero activo supera los 26 MB |

## Siguientes pasos

- [ ] Aplicar los cambios de escritor (R1) — responsable: ingeniería de datos / `FabricAdmin` · relacionado con: R1
- [ ] Programar `OPTIMIZE` fuera de la ventana del pipeline (R2) y el cambio del checkpoint (R3) — responsable: ingeniería de datos · relacionado con: R2, R3
- [ ] Planificar `VACUUM` a partir del 6 nov por la tarde (R4) — responsable: ingeniería de datos · relacionado con: R4
- [ ] Decidir sobre Direct Lake antes de tocar V-Order en gold (R5) — responsable: dueño del modelo · relacionado con: R5
- [ ] Aclarar `silver.store_snapshot` (R6) — responsable: dueño de `pl_store_snapshot` · relacionado con: R6
- [ ] Repetir este inventario tras aplicar R1 a R4 para validar el impacto

## Notas

### Limitaciones

- No se consultó `DESCRIBE HISTORY` ni `DESCRIBE DETAIL` (sin Livy): el historial de operaciones sale de los `commitInfo` del `_delta_log`, que no tienen ningún `OPTIMIZE` ni `VACUUM`.
- Los row groups reales no se leyeron; solo las filas por fichero.
- Los ficheros sin referenciar se calculan comparando la carpeta de datos con los ficheros activos del log; para `ctl_pipeline_runs` (17 ficheros sin referenciar en una tabla de solo `append`) no se encontró explicación.
- Las estimaciones de ficheros tras `OPTIMIZE` dependen del tamaño de destino de la ejecución (en runtime 1.3, el tamaño objetivo adaptativo es opcional) y no se midieron.
- Un primer cálculo de `silver.customers` salió mal (6.709 ficheros) porque aplicaba las altas antes que las bajas dentro de un mismo commit; se corrigió (E4) y cuadra con el endpoint.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Salud de `silver.store_snapshot` | Sin `_delta_log` y sin objeto en el endpoint | Veredicto "no evaluable" |
| Historial de trabajos `TableMaintenance` | No se consultó la lista de trabajos del lakehouse | Se asume que no hubo mantenimiento por el contenido del log |
| Causa de los 17 ficheros sin referenciar de `ctl_pipeline_runs` | Sin `DESCRIBE HISTORY` ni logs de escritura | Sin efecto en el veredicto |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| `CheckpointVersion` del endpoint | `delta-tables.md` § Known traps: describe lo que ha leído el endpoint, no la versión de la tabla | El endpoint informa de checkpoints en las versiones 12, 13 y 448 que no existen como ficheros en `_delta_log` (solo v10) | Se tomó como verdad el listado de `_delta_log`; la diferencia no se resolvió |
| Código del endpoint para tablas diminutas | `lakehouse-health.md`: el código 3 indica "muchos ficheros pequeños" | `daily_store_sales` (198 ficheros de 3 KB) y `silver.sales` (64 de 16,7 MB) no se comportan igual: el primero da código 0, el segundo 3 | El código no se usó como única fuente; se compararon los tamaños medios con el umbral de 32 MB |
| Clave de V-Order | Ver informe 03 | Ver informe 03 | Ver informe 03 |

## Anexo

### Consultas completas

- E2: `EXEC sys.sp_get_table_health_metrics @table_name = 'dbo.<tabla>'`, una vez por tabla y SQL endpoint (bronze 03c34de1-…, silver bd96d99c-…, gold da36bf45-…).
- E3/E4: `GET https://onelake.dfs.fabric.microsoft.com/{ws}?resource=filesystem&recursive=true&directory={lakehouseId}/Tables/{tabla}` con paginación, y lectura de cada `_delta_log/*.json` y de `_last_checkpoint`. Ficheros activos = altas menos bajas aplicadas por commit (bajas primero); sin referenciar = ficheros `.parquet` de la carpeta que no están en el conjunto activo.

### Configuración efectiva

Propiedades de tabla leídas en el `_delta_log`: bronze con `delta.parquet.vorder.enabled=true` y `delta.stats.extended.*`; `inventory_events` además `delta.checkpointInterval=1000`; `silver.customers` con `delta.enableDeletionVectors=true` y protocolo 3/7; el resto solo `delta.stats.extended.collect` e `inject`.
