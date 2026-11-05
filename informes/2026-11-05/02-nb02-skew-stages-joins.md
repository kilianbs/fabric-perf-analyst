# nb_02_bronze_to_silver: data skew, time skew, stages, operadores y joins

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-05 |
| **Áreas** | Spark runs |
| **Ámbito** | workspace `FabricPerfLab` · `nb_02_bronze_to_silver`, ejecución programada de `pl_daily_sales` del 2026-11-05 05:04 UTC |
| **Ventana analizada** | 2026-11-05 05:04:47 → 05:18:56 UTC (sesión Livy `ac30d635-858d-4376-b567-a1c24a37baf6`) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli |
| **Modo** | Solo lectura |
| **Severidad global** | Media |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** ¿hay data skew o time skew en `nb_02`? ¿Qué stages pesan más, cuáles se repiten, qué operadores consumen más tiempo y qué estrategia usa cada join?
- **Conclusión:** sí hay skew, pero no es lo que más pesa. Hay (1) data skew por clave en la unión con `stores`: `store_id=1` concentra 9.000.391 de 15.000.000 de filas (60 %) en una sola tarea de 2.000; (2) time skew en el stage de escritura de ventas (64 tareas): la tarea máxima tarda 3,7x la mediana con solo 1,2x más registros, por el UDF de Python; (3) skew por tamaño de fichero al leer `silver.customers` (827–880 tareas, 11,2x en el stage de la lectura inicial); y (4) dos stages con 150x entre tarea máxima y mediana (30 s frente a 0,2 s) con 5–57 registros por tarea, cuya causa no se identificó. Todos los joins del notebook son `SortMergeJoin`; no hay broadcast.
- **Impacto:** el tiempo lo dominan stages sin skew relevante: la lectura repetida de `silver.customers` (28.149 ficheros) suma 9.264 s de ejecutor en 4 stages (62 % de los 15.055 s de `nb_02`), y el escaneo más deduplicado de `bronze.sales_raw` se ejecuta dos veces (1.116 s). El skew de `store_id` aún no hace spill (0 B) pero su tarea ya procesa 2,6 GiB de memoria pico y crece con los datos.
- **Primera acción:** R1, quitar `autoBroadcastJoinThreshold=-1` y AQE desactivado (`stores` son 50 filas, 17,8 KiB) y compactar `silver.customers`; R2 cachear el DataFrame de ventas deduplicado para no calcular el mismo plan dos veces. Requieren confirmación.

## Alcance

**Pregunta original:** "Repregunta sobre tu informe informes/2026-11-05/01-pl-daily-sales-tendencia-crecimiento.md (nb_02_bronze_to_silver). ¿Hay data skew o time skew? Revisa cada stage con shuffle o escritura, incluidos los de pocas tareas: duración y registros de la tarea máxima frente a la mediana. Dime qué stages pesan más, cuáles se repiten en varios jobs, qué operadores del plan consumen más tiempo y qué estrategia usa cada join (broadcast, sort-merge, shuffle hash...)."

**Informe previo:** `2026-11-05/01-pl-daily-sales-tendencia-crecimiento.md`. Sus hallazgos (crecimiento por ficheros pequeños en `silver.customers` y reconstrucción completa de ventas) no se repiten; aquí se matizan en H3 y H5. Las cifras de volumen de la última ejecución (shuffle read 12.063 MB, 28.149 ficheros) coinciden con las de este informe (E4).

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| `nb_02` en su última ejecución (05:04 UTC del 5 nov): 100 stages completados con shuffle o escritura, de 165 (136 completados y 29 omitidos); 107 ejecuciones SQL y sus planes; Spark Advisor | `nb_01`, `nb_03`, `nb_04`. Ejecuciones anteriores de `nb_02`: no se compararon stage a stage, así que no se mide si el skew crece entre ejecuciones (ver Notas) |

**Hipótesis de partida:** H-a, `store_id` está sesgado (la ingesta concentra el 60 % de ventas en la tienda 1 en `nb_01`) y la unión con `stores` lo sufre. H-b, el UDF de Python produce time skew en el stage de escritura. H-c, las uniones usan sort-merge por el umbral de broadcast desactivado en la celda 2.

**Recorrido:** Spark runs únicamente. `/advice` → `taskSummary` de todos los stages con shuffle o escritura (más allá del tope de 20 de `diagnostic-workflow.md` § Stage Detail Selection Logic, porque la petición pedía cada stage) → planes físicos y métricas por operador de `/sql`. No hubo pivote a otra área: los 28.149 ficheros de `silver.customers` ya están en el informe previo.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Runtime de Spark | 2.0 | informe previo, E5 |
| Configuración Spark (declarada en el código de `nb_02`, celda 2) | `spark.sql.shuffle.partitions=2000`, `spark.sql.adaptive.enabled=false`, `spark.sql.adaptive.skewJoin.enabled=false`, `spark.sql.autoBroadcastJoinThreshold=-1` | informe previo, E7 |
| Sesión de alta concurrencia | No (`isHighConcurrency=false`) | informe previo, E4 |
| Permisos | Lectura de Spark Monitoring | E1–E5 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| nb_02_bronze_to_silver | Notebook | Bronze → silver | 4205418f-cee2-4a3d-9390-328618160264 |
| Sesión Livy / aplicación | Sesión Spark del pipeline | – | ac30d635-858d-4376-b567-a1c24a37baf6 / application_1793855021534_0001 |

## Evidencia

### Métricas clave

Umbral de skew usado en todo el informe: `maxExecutorRunTime / median > 3x` = HIGH (`diagnostic-workflow.md` § Severity Thresholds y `performance-patterns.md` § Detection Thresholds). Umbral de shuffle: `shuffleWriteBytes` por stage > 1 GB = MEDIUM. Spill: > 0 = MEDIUM; aquí `diskBytesSpilled` = 0 en todos los stages revisados.

**Stages con skew (tarea máxima frente a mediana), última ejecución (E2, E3)**

| Stage | Job / statement | Tareas | Duración tarea máx / mediana | Registros tarea máx / mediana | Tipo | Severidad (umbral) |
|-------|-----------------|--------|-------------------------------|-------------------------------|------|--------------------|
| 136 (SMJ por `store_id`, escritura) | 65 / 6 (ventas) | 2.000 | 19,0 s / 0,05 s | 9.000.391 / 0 (shuffle read) | **Data skew** por clave | Alta |
| 124 (misma unión, 1.ª ejecución) | 63 / 6 | 2.000 | 7,8 s / 0,04 s | 9.000.391 / 0 | Data skew | Alta |
| 130 (muestreo de `repartitionByRange`) | 64 / 6 | 48 | 8,0 s / 0,54 s (ejecutor 17,3x) | 9.000.391 / 122.483 | Data skew | Alta |
| 137 (escritura final de `sales`, 64 tareas) | 65 / 6 | 64 | 27,8 s / 7,5 s (ejecutor 3,7x) | 289.210 / 239.527 (1,2x) | **Time skew** (el tiempo no sigue a los registros) | Alta |
| 20 (lectura de `customers` para `MAX(source_run_seq)`) | 13 / 4 (customers) | 827 | 43,5 s / 3,6 s (ejecutor 11,2x) | 4.018 / 184 de entrada (21,8x) | Skew por tamaño de fichero (data + time) | Alta |
| 36 (escritura del `MERGE`) | 20 / 4 | 2.000 | 30,2 s / 0,22 s (ejecutor 150x) | 13 / 5 de salida | Time skew sin causa de datos | Alta (ratio), impacto 30 s |
| 157 (escritura de `inventory_levels`) | 76 / 7 (inventario) | 2.000 | 30,3 s / 0,21 s (ejecutor 157x) | 57 / 34 de salida | Time skew sin causa de datos | Alta (ratio), impacto 30 s |
| 33, 40, 27, 31 (stages de 2.000 tareas del `MERGE`) | 19, 21, 17, 19 / 4 | 2.000 | ratios 50x, 20x, 7x, 15x | pocos registros (unidades) | Ratios altos sobre medianas de milisegundos; ejecutor total 20–45 s por stage | Baja (impacto bajo) |
| 121, 30, 35, 122, 119, 101, 120 | 63, 19, 20, 63, 63, 55, 63 | 194–2.000 | ejecutor 1,2x–3,0x | 1,0x–1,6x | Sin skew relevante (la mayor parte del tiempo) | – |

Los datos de las 100 tareas resumidas están en E2. Hay 22 stages con ratio ejecutor > 3x; los de menos de 5 s de ejecutor se descartan por impacto.

**Stages que más pesan (tiempo de ejecutor de la última ejecución, E2)**

| Stage | Job / statement | Tareas | Ejecutor (s) | Qué hace | % del total de `nb_02` (15.055 s) |
|-------|-----------------|--------|--------------|----------|-----------------------------------|
| 20 | 13 / 4 | 827 | 3.269 | `first()` sobre `customers` (28.149 ficheros) | 21,7 % |
| 30 | 19 / 4 | 827 | 2.741 | Búsqueda de ficheros del `MERGE` en `customers` | 18,2 % |
| 121 | 63 / 6 | 880 | 2.500 | Escaneo de `customers` para la unión de ventas (`scan time` 41,4 min en el plan) | 16,6 % |
| 35 | 20 / 4 | 236 | 754 | Reescritura del `MERGE` | 5,0 % |
| 122 | 63 / 6 | 2.000 | 596 | Unión sort-merge con `customers` | 4,0 % |
| 34 | 19 / 4 | 2.000 | 596 | Shuffle del `MERGE` | 4,0 % |
| 137 | 65 / 6 | 64 | 583 | Escritura de `sales` con UDF de Python | 3,9 % |
| 101 | 55 / 6 | 194 | 583 | Escaneo de `sales_raw` + `WindowGroupLimit` (cuenta de deduplicadas) | 3,9 % |
| 119 | 63 / 6 | 194 | 533 | El mismo escaneo + `WindowGroupLimit` (escritura) | 3,5 % |
| 46, 48 | 24, 25 / 4 | 32 | 512, 444 | Escrituras de ficheros del `MERGE` | 3,4 %, 2,9 % |
| 36, 157 | 20, 76 | 2.000 | 482, 480 | Escrituras con 30 s de tarea máxima | 3,2 % cada una |

**Stages que se repiten (E2, E4)**

| Qué se repite | Dónde | Coste |
|---------------|-------|-------|
| Lectura completa de `silver.customers` | Stages 20 (job 13), 30 (job 19), 35 (job 20), 121 (job 63); además 3 avisos de Spark Advisor de "small files" sobre `customers` | 3.269 + 2.741 + 754 + 2.500 = 9.264 s |
| Escaneo y deduplicado (`Window`) de `bronze.sales_raw` (15 M filas, 6.000 ficheros, 1.369 MiB) | Stage 101 (job 55, `count()` de deduplicadas) y stage 119 (job 63, escritura) | 583 + 533 = 1.116 s; 649 MB y 1.862 MB de shuffle write |
| Unión por `store_id` con la tarea de 9 M registros | Stages 124 (job 63), 130 (job 64), 136 (job 65): tres jobs del mismo `saveAsTable` (cálculo de rangos de `repartitionByRange` y escritura) | El skew se paga tres veces (7,8 s + 8,0 s + 19,0 s de tarea máxima) |
| Stages "SKIPPED" | 29 en total, entre ellos 7 en el job 65 y 6 en el job 64 | Reutilizan shuffle files; evitan recalcular 119–122 |

**Operadores del plan que más tiempo consumen (ejecución SQL 81, ventas) (E3)**

| Operador | Métrica del plan | Valor |
|----------|------------------|-------|
| Scan `lh_silver.customers` | `scan time` | 41,4 min total (mediana 2,8 s por tarea) con 28.149 ficheros, 116,7 MiB y 350.980 filas leídas |
| Scan `lh_bronze.sales_raw` | `scan time` | 7,9 min, 6.000 ficheros, 1.369,2 MiB, 15.000.000 filas |
| Sort + SortMergeJoin con `customers` (WholeStageCodegen 4 y 7) | `duration` | 8,4 min y 8,2 min |
| Sort previo a la ventana (WholeStageCodegen 1) | `duration` | 8,4 min |
| BatchEvalPython + escritura (WholeStageCodegen 12) | `duration` | 6,5 min; la tarea máxima 22,5 s |
| Exchange tras la unión con `customers` | `fetch wait time` | 4,5 min en total (2000 tareas) |
| Sort de la unión por `store_id` | `peak memory` | 17,3 GiB en total; **2,6 GiB en una sola tarea** (stage 124, tarea 33770) |
| Exchange de rango tras la última unión | `data size` | 4,0 GiB; **2,4 GiB en una tarea** (stage 136, tarea 35818) |

Las métricas `WholeStageCodegen duration` son inclusivas y no suman con el tiempo de ejecutor del stage (la del nodo 6 indica 2,76 h y no cuadra con los 596 s del stage 122), así que el orden de los stages sale de `executorRunTime` y los operadores se usan para localizar la causa dentro de cada stage.

**Estrategia de cada join (E3)**

| Unión | Ejecución SQL | Estrategia | Claves | Tipo |
|-------|---------------|------------|--------|------|
| ventas ⟕ `customers` | 81 (ventas) | `SortMergeJoin` | `customer_id` | LeftOuter |
| ventas ⟕ `stores` (50 filas, 17,8 KiB) | 81 | `SortMergeJoin` | `store_id` | LeftOuter |
| `MERGE` de customers: fuente ⋈ destino | 23 | `SortMergeJoin` | `customer_id` | Inner |
| `MERGE`: reescritura de ficheros | 23 | `SortMergeJoin` | `filePath` ↔ `path` (deletion vectors) | LeftOuter |
| `MERGE`, variante de fase previa | 26 | `SortMergeJoin` | `customer_id` | LeftOuter |
| Resolución de ficheros del `MERGE` | 29 y 30 | `SortMergeJoin` | `path` | Inner |

En los 107 planes: 7 `SortMergeJoin`, 0 `BroadcastHashJoin`, 0 `ShuffledHashJoin`, 0 `BroadcastNestedLoopJoin`. Las celdas 4 y 6 (referencias e inventario) no tienen joins.

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET .../notebooks/{nb02}/livySessions/{livy}/applications/{app}/jobs` y `/stages` (reutilizados del informe previo, E6) | 81 jobs, 165 stages (136 COMPLETE, 29 SKIPPED); 100 stages COMPLETE con shuffle o escritura |
| E2 | REST | `GET .../stages/{id}/{attempt}/taskSummary?quantiles=0.25,0.5,0.75,0.95,1.0` ×100 | Cuantiles de duración, `executorRunTime`, registros de entrada, shuffle y salida, spill y GC por stage; sin errores |
| E3 | REST | `GET .../applications/{app}/sql?details=true&offset=0&length=1000` | 107 ejecuciones SQL con plan físico y métricas por nodo |
| E4 | REST | `GET .../applications/{app}/advice` | 12 avisos: 4 de time skew (jobs 13, 20, 76; stages 20, 36, 157), 3 de data skew (jobs 63, 64, 65; stages 124, 130, 136) y 6 informativos de compactación (`customers` ×3, `sales_raw` ×2, `inventory_events` ×1) |
| E5 | REST | `GET .../notebooks/.../livySessions` (informe previo, E5) | `isHighConcurrency=false` |

No se ejecutó Livy ni `ClearCache`: los planes y las métricas por tarea salen del Spark History online.

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | Data skew por `store_id` en la unión con `stores`: 9,0 M de 15 M de filas en una tarea | Media | Alta | E2, E3, E4 |
| H2 | Time skew en la escritura de ventas por el UDF de Python | Media | Alta (medición) / Media (causa) | E2, E3 |
| H3 | La lectura de `silver.customers` está sesgada por tamaño de fichero y se repite en 4 stages | Alta | Alta | E1, E2, E3 |
| H4 | Dos stages de 2.000 tareas tienen una tarea de ~30 s con 5–57 registros, sin causa de datos identificada | Baja | Media | E2, E4 |
| H5 | Todos los joins son sort-merge por `autoBroadcastJoinThreshold=-1`; la unión con la tabla de 50 filas hace un shuffle completo de 15 M filas | Media | Alta | E3 |
| H6 | El mismo plan de ventas se evalúa dos veces (escaneo y deduplicado de `sales_raw`) | Media | Alta | E1, E2, E3 |

### H1 · Data skew por store_id

- **Qué ocurre:** en los stages 124, 130 y 136 una tarea lee 9.000.391 registros de shuffle y la mediana de las 2.000 es 0 (solo hay 50 `store_id` distintos, así que como mucho 50 de las 2.000 particiones tienen datos). Esa tarea tarda 19,0 s frente a 0,05 s de mediana en el stage 136, tiene un pico de memoria de 2,6 GiB en el `Sort` (stage 124) y escribe 2,4 GiB en el `Exchange` de rango (stage 136). Spark Advisor lo marca como data skew en los jobs 63, 64 y 65 (lectura máxima 978,61 MB frente a media de 0,86 MB).
- **Por qué:** 9.000.391 son el 60 % de 15.000.000: es la tienda 1 (`nb_01` genera el 60 % de las ventas con `store_id=1`, E7 del informe previo). Con `autoBroadcastJoinThreshold=-1` y AQE desactivado (`skewJoin.enabled=false`) la unión con `stores` hace sort-merge por `store_id` y toda la tienda 1 va a una partición (H5).
- **Impacto:** hoy 19 s en el camino crítico más 7,8 s y 8,0 s en los otros dos jobs. Sin spill (0 B), pero la tarea crece con los datos (60 % de cada carga): riesgo de spill u OOM a futuro. Por eso Media. Umbral: ratio > 3x = HIGH (`diagnostic-workflow.md`); se rebaja porque el impacto absoluto es pequeño frente a H3.

### H2 · Time skew por el UDF de Python

- **Qué ocurre:** el stage 137 (64 tareas, escritura de `sales`) tiene una tarea máxima de 27,8 s frente a una mediana de 7,5 s (3,7x), con registros casi iguales (289.210 frente a 239.527, 1,2x). El p95 es 26,05 s: las últimas tareas de rango tardan lo mismo. Es un stage pequeño de 583 s de ejecutor (3,9 %) que el filtro por número de tareas habría ignorado.
- **Por qué:** el plan contiene `BatchEvalPython` (nodo 31) delante de la escritura, con 15.000.000 de filas de salida. En el código, `classify_note` hace 100 pasadas de regex solo para filas con comentario y hora ≥ 22; `repartitionByRange(64, "sale_ts")` agrupa por hora, así que las tareas de las horas finales (y las que más filas con comentario tienen) son las caras. Relación entre las horas y las tareas lentas no verificada (no se miró `taskList`); la causa se infiere del código y del plan.
- **Impacto:** el stage termina cuando acaba la tarea más lenta (27,8 s); con tareas uniformes serían ~7–12 s. Ganancia de unos 15–20 s por ejecución y creciente con el volumen.

### H3 · Lectura de silver.customers: skew por tamaño de fichero y repetición

- **Qué ocurre:** el stage 20 (827 tareas) lee de 184 registros por tarea (mediana) a 4.018 (máximo): 21,8x en registros y 11,2x en tiempo de ejecutor (43,5 s frente a 3,6 s), la tarea máxima es 12x la mediana. Es el stage más caro de la ejecución (3.269 s). La misma tabla se lee en otros tres stages (30, 35 y 121), con 9.264 s en total (62 % del ejecutor de `nb_02`). El plan de ventas lee 28.149 ficheros y 350.980 filas, de las que el filtro deja 158.950.
- **Por qué:** la tabla tiene 28.149 ficheros de 0,004 MB de media (informe previo, H2) con un reparto muy desigual de filas por fichero; y cada acción (`first()`, `MERGE`, unión de ventas) la vuelve a escanear. El filtro de 350.980 a 158.950 filas parece el filtro de deletion vectors (la tabla tiene `delta.enableDeletionVectors=true`), lo que implicaría 192.030 filas borradas que aún se leen; no verificado, no se inspeccionaron los deletion vectors.
- **Impacto:** es el mayor consumo de `nb_02` y no lo causa un skew de datos sino la fragmentación. Spark Advisor recomienda `OPTIMIZE` sobre `silver.customers` (3 avisos) y `bronze.sales_raw` (2).

### H4 · Tareas de 30 s con casi ningún dato

- **Qué ocurre:** en el stage 36 (job 20, `MERGE`) y el 157 (job 76, inventario) hay una tarea de 30,2 s y 30,3 s frente a medianas de 0,22 s y 0,21 s (150x y 157x), con entre 5 y 57 registros; el resto de percentiles es ~0,3 s. Spark Advisor lo avisa como time skew (stages 36 y 157).
- **Por qué:** no hay relación con datos (13 y 57 registros como máximo) ni con GC (0,04–0,07 s) ni con spill (0). Que dos stages de statements distintos tengan casi exactamente 30 s sugiere una espera fija (por ejemplo del commit o de la limpieza de la escritura de 2.000 particiones), pero no hay evidencia para afirmarlo.
- **Impacto:** unos 30 s de tiempo de pared por stage (~60 s en `nb_02`) sobre 882 s. Un efecto similar se ve en el stage 20 (43,5 s máx).

### H5 · Joins: todo sort-merge

- **Qué ocurre:** los 7 joins de los 107 planes son `SortMergeJoin`, incluidos `ventas ⟕ stores` (50 filas, 17,8 KiB) y las uniones del `MERGE`. La unión con `stores` hace un shuffle completo (3,3 GiB de `Exchange`) de las 15 M filas, solo para añadir `store_name` y `city`.
- **Por qué:** la celda 2 de `nb_02` fija `autoBroadcastJoinThreshold=-1`, que desactiva el broadcast; y AQE está desactivado (`adaptive.enabled=false`), así que Spark no puede cambiar de estrategia en ejecución ni dividir la partición sesgada de H1.
- **Impacto:** crea H1 y obliga a ordenar 15 M filas dos veces (sort de 125,5 GiB de pico acumulado en el lado de `customers`). Un broadcast de `stores` elimina el shuffle y el skew de `store_id` por completo.
- **Dato anómalo no resuelto:** una de las dos `SortMergeJoin` del plan de ventas reporta 45.000.000 filas de salida mientras que la otra y el `BatchEvalPython` reportan 15.000.000. No pude asignar cuál es cada nodo en la lista de métricas, así que no se concluye nada; conviene comprobar duplicados de `customer_id` en `silver.customers` (R4).

### H6 · Plan de ventas evaluado dos veces

- **Qué ocurre:** el escaneo de `bronze.sales_raw` con el `WindowGroupLimit` de deduplicación se ejecuta en el stage 101 (job 55) y otra vez en el 119 (job 63): 583 + 533 = 1.116 s de ejecutor y 2,5 GB de shuffle write entre ambos. Además, los jobs 64 y 65 (que repiten H1) son del mismo `saveAsTable`.
- **Por qué:** la celda 5 llama a `sales.count()` sobre un DataFrame sin cachear antes de escribirlo; cada acción recalcula el plan completo. Los stages "SKIPPED" (29) solo reutilizan shuffle dentro de la misma consulta SQL.
- **Impacto:** 7,4 % del ejecutor de `nb_02`, crece con `sales_raw`. Los `print` de recuentos no aportan al resultado.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Quitar `autoBroadcastJoinThreshold=-1` y reactivar AQE (con skew join) en `nb_02`; hacer broadcast explícito de `stores` | H1, H5 | Medio | Bajo | Bajo | Sí |
| R2 | Compactar `silver.customers` y evitar relecturas (cachear lo leído una vez) | H3 | Alto | Bajo | Bajo | Sí |
| R3 | Eliminar los `count()` de la celda 5 o cachear el DataFrame deduplicado | H6 | Medio | Bajo | Bajo | Sí |
| R4 | Sustituir el UDF de Python por funciones nativas y comprobar duplicados de `customer_id` | H2, H5 | Medio | Medio | Medio | Sí |

### R1 · Broadcast de stores y AQE

- **Cambio propuesto:** en la celda 2 de `nb_02`, quitar `spark.sql.adaptive.enabled=false`, `spark.sql.adaptive.skewJoin.enabled=false` y `spark.sql.autoBroadcastJoinThreshold=-1`, y en la celda 5:

  ```python
  from pyspark.sql.functions import broadcast
  .join(broadcast(spark.read.table("stores").select("store_id", "store_name", "city")), "store_id", "left")
  ```
- **Impacto esperado:** desaparece el shuffle de las 15 M filas por `store_id` y la tarea de 9 M registros (stages 124/130/136: 7,8 + 8,0 + 19,0 s de tarea máxima). Estimación basada en E2/E3, no medida.
- **Cómo validarlo:** repetir `taskSummary` y el plan: debe aparecer `BroadcastHashJoin` para `stores` y no deben quedar stages con 9 M registros en una tarea.
- **Reversión:** volver a poner las tres líneas de configuración y quitar `broadcast()`.
- **Requiere confirmación:** Sí, modifica un notebook y cambia la configuración que el informe previo (R1) también propone retirar.

### R2 · Compactar customers y no releer

- **Cambio propuesto:** `OPTIMIZE lh_silver.customers` (y `lh_bronze.sales_raw`, `lh_bronze.inventory_events`, como indica Spark Advisor). En la celda 3, evitar el `first()` sobre `customers` calculando `last_applied` del propio `MERGE` o de `ctl_pipeline_runs`.
- **Impacto esperado:** los 4 stages de lectura (9.264 s) dependen del número de ficheros y de su desigual reparto de filas; con pocos ficheros el skew por tamaño de fichero del stage 20 desaparece. Estimación; coincide con la de R1 del informe previo.
- **Cómo validarlo:** repetir E2: el stage 20 debería pasar de 827 tareas con 21,8x en registros a unas pocas tareas equilibradas.
- **Reversión:** `RESTORE` de la tabla a la versión anterior.
- **Requiere confirmación:** Sí (escribe en tablas y consume CU).

### R3 · No calcular dos veces el plan de ventas

- **Cambio propuesto:** quitar los `count()` de la celda 5 o hacer `sales.cache()` (o escribir y contar después sobre la tabla escrita).
- **Impacto esperado:** evita el stage 101 (583 s de ejecutor). Estimación.
- **Cómo validarlo:** el job 55 debe desaparecer y `bronze.sales_raw` debe escanearse una vez por ejecución.
- **Reversión:** versión anterior del notebook.
- **Requiere confirmación:** Sí, cambio de notebook (alternativa: cache consume memoria del cluster).

### R4 · UDF y duplicados

- **Cambio propuesto:** reescribir `classify_note` con expresiones nativas (si la lógica de las 100 pasadas de reversión por bloques de 4 caracteres hex es necesaria, valorar con el dueño del dato si lo es) y comprobar `SELECT customer_id, COUNT(*) FROM lh_silver.customers GROUP BY customer_id HAVING COUNT(*) > 1`.
- **Impacto esperado:** la tarea más larga del stage 137 pasa de 27,8 s a cerca de la mediana (~7,5 s) si el UDF es la causa. Estimación.
- **Cómo validarlo:** `taskSummary` del stage de escritura (ratio ejecutor < 3x) y desaparición de `BatchEvalPython` del plan.
- **Reversión:** versión anterior del notebook.
- **Requiere confirmación:** Sí, cambia el resultado de `note_class` si la lógica nativa difiere.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Spill a disco por el skew | E2 | `diskBytesSpilled` = 0 y `memoryBytesSpilled` = 0 en todos los stages revisados |
| D2 | GC como causa de las tareas lentas | E2 | `jvmGcTime` máximo 0,29 s en el stage 20 y ≤ 0,07 s en los demás skewed |
| D3 | Skew en el reparto de `customer_id` en la unión de ventas | E2, E3 | Stage 122 (2.000 tareas): ejecutor 3,0x, registros 10.681 frente a 7.567 (1,4x) |
| D4 | Hay broadcast o shuffle hash en algún join | E3 | 7 `SortMergeJoin`, ninguna otra estrategia |

## Siguientes pasos

- [ ] Aplicar R1 y R2 (configuración de `nb_02` y compactación) — responsable: ingeniería de datos / `FabricAdmin` · relacionado con: R1, R2
- [ ] Decidir sobre el UDF `classify_note` y comprobar duplicados en `customers` — responsable: dueño del dato · relacionado con: R4
- [ ] Repetir `taskSummary` y los planes tras aplicar R1–R3 en la siguiente ejecución del pipeline

## Notas

### Limitaciones

- Solo se analizó la última ejecución de `nb_02`. No se comparó el skew de `store_id` ni el de `customers` con ejecuciones anteriores, por lo que no se mide cuánto crece; sí se ve que depende de datos acumulados (60 % de una tienda y ficheros pequeños).
- Se revisaron 100 stages, por encima del tope de 20 de `diagnostic-workflow.md`, por la petición explícita de revisar cada stage con shuffle o escritura; los 36 stages restantes no tenían shuffle ni escritura.
- Se dio prioridad a los stages COMPLETE; los 29 SKIPPED no ejecutan tareas.
- La asignación de las métricas `SortMergeJoin` (15 M frente a 45 M filas de salida) a cada nodo no es fiable (ver H5).

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Lista de tareas (`taskList`) del stage 137 y de los stages 36/157 | No se consultó; con `taskSummary` bastaba para cuantificar el skew | La relación entre tareas lentas y horas finales (H2) y la causa de los 30 s (H4) no están verificadas |
| Deletion vectors de `silver.customers` | No se inspeccionó `DESCRIBE DETAIL` ni el log de DV | La explicación 350.980 → 158.950 filas (H3) es una hipótesis |
| Configuración efectiva (`spark.conf.get`) | No se abrió sesión Livy | Se toma la configuración declarada en el código (informe previo) y es consistente con los planes (SMJ para 50 filas) |
| Skew en ejecuciones anteriores | Fuera de lo pedido | No se mide la evolución del skew |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Paginación de `/sql` | `SPARK-MONITORING-CORE.md` § SQL list no describe parámetros | La ruta devuelve 20 elementos por defecto; `offset` y `length` amplían la lista (107 ejecuciones con `length=1000`) | Se usó `offset=0&length=1000`. Sin él habrían quedado fuera los planes de las celdas 5 a 7. No contrastado con Microsoft Learn |
| Ruta de `taskSummary` | `diagnostic-workflow.md` línea 135 la cita, pero `SPARK-MONITORING-CORE.md` solo documenta `/stages/{id}` | `GET .../stages/{id}/{attempt}/taskSummary?quantiles=...` respondió con cuantiles | Se usó la ruta del skill; no contrastado con Microsoft Learn |

## Anexo

### Consultas completas

- E1/E2: base `GET /v1/workspaces/23ca4a73-3312-4242-9714-0289816895aa/notebooks/4205418f-cee2-4a3d-9390-328618160264/livySessions/ac30d635-858d-4376-b567-a1c24a37baf6/applications/application_1793855021534_0001`, con `/jobs`, `/stages`, `/stages/{id}/0/taskSummary?quantiles=0.25,0.5,0.75,0.95,1.0`, `/sql?details=true&offset=0&length=1000` y `/advice`. Todas con cabecera `x-ms-fabric-skill: spark-cli`.
- Selección de stages para `taskSummary`: los COMPLETE con `shuffleReadBytes`, `shuffleWriteBytes` u `outputBytes` mayores que 0 (100 de 165).

### Configuración efectiva

Sin datos medidos; ver Entorno. Planes: las 7 uniones y su estrategia están en E3 (ejecuciones SQL 23, 26, 29, 30 y 81).
