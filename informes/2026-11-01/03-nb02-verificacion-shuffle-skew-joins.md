# nb_02: verificación de la premisa "el shuffle es lo que más crece", skew por stage y estrategia de joins

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-01 |
| **Áreas** | Spark runs |
| **Ámbito** | workspace `FabricPerfLab` · `nb_02_bronze_to_silver` (actividad `Bronze to silver` de la ejecución `524c4c37`, la 11ª; sesión `88afdede-f5be-4d97-beb4-53fd5c9445b4`) |
| **Ventana analizada** | 2026-10-31 05:00 UTC (ejecución 11); consulta realizada el 2026-11-01 |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** seguimiento de `02-pl-daily-sales-seguimiento-que-crece.md`. El usuario afirma que el shuffle de `nb_02` es lo que más crece; pide skew por stage, stages más pesados y estrategia de cada join.
- **Conclusión sobre la premisa: es cierta a medias, y las dos afirmaciones de los informes previos son del mismo notebook.** Tanto el escaneo del `MERGE` de `customers` (informe 02) como el shuffle de `silver.sales` (informe 01) están en `nb_02`: el `MERGE` es la sentencia 4 y la reconstrucción de `sales` es la sentencia 6. En bytes, el shuffle sí es lo que más crece: el 99 % del shuffle write de `nb_02` (6.085 de 6.147 MB) es de la sentencia 6, y la 4 solo mueve 55 MB (E3). En tiempo no: la sentencia 4 suma 6.853 s·tarea de ejecutor (60 %) y la 6, 3.898 (34 %) (E3). Y de los +401 s de Spark que crece el notebook, +296 s son de la celda del `MERGE` y +109 s de la de `sales` (informe 01 E11). El shuffle crece mucho en volumen pero pesa menos en reloj que el escaneo de ficheros pequeños.
- **Skew (pregunta 1):** hay **data skew** en una sola exchange, la de `hashpartitioning(store_id, 2000)` del join con `stores`: una tarea lee 683,85 MB y la mediana es 0 (stages 139, 127 y 133). Hay **time skew** (tiempo desigual con bytes iguales) en la UDF de Python (stage 140: 1,5 / 6,3 / 23,9 s con 19,3 / 24,9 MB de lectura mediana / máxima) y moderado en las lecturas de `customers` del `MERGE` (stages 19 y 29: 3,1× y 4,1× con 0,09 MB por tarea). Nada de esto produce spill (0 bytes).
- **Joins (pregunta 3):** los cuatro joins medidos son `SortMergeJoin`; ninguno es broadcast ni shuffled hash. Medido en el plan físico de la Spark UI (E4). AQE no aparece en los planes (`AdaptiveSparkPlan` ausente).
- **Primera acción:** R1 y R4 del informe 01 (AQE y broadcast de `stores`, UDF nativa), junto con R1 del informe 02 (compactar `customers`). Son cambios, requieren confirmación.

## Alcance

**Pregunta original:** "El usuario dice que el shuffle de nb_02 es lo que más crece. Verifica esa premisa antes de aceptarla: tu informe dice que crece el escaneo del MERGE de silver.customers y que el shuffle de silver.sales sube unos 523 MB por ejecución. Indica a qué notebook corresponde cada cosa y si de verdad el shuffle de nb_02 es lo que más crece. 1. En nb_02, ¿hay data skew o time skew? Da la evidencia por stage: min/mediana/máx de duración y de bytes por tarea. 2. ¿Qué stages pesan más (tiempo, shuffle read/write, spill)? Tabla ordenada. 3. ¿Qué estrategia usa cada join? Basa la respuesta en el plan o en la Spark UI/history, y marca como inferencia lo que no puedas medir."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Stages, cuantiles de tareas y plan físico de `nb_02` en la ejecución 11. Reparto de la sesión por sentencia. | Series entre ejecuciones y tablas Delta (informes 01 y 02, no se repiten). Otras ejecuciones: no se re-consultaron los stages de las ejecuciones 1–10. |

**Informes previos reutilizados:** `2026-11-01/01-pl-daily-sales-tendencia-crecimiento.md` (series, tiempos por celda E11, stages 127/140/19 con E13) y `2026-11-01/02-pl-daily-sales-seguimiento-que-crece.md` (escaneo vs reescritura del `MERGE`). Aquí solo se añade lo no medido antes: cuantiles de bytes por tarea en 16 stages, estrategia de cada join y el reparto por sentencia.

**Hipótesis:** (a) el shuffle de bytes crece más que el resto, pero el tiempo está en otro sitio; (b) hay data skew en el join por `store_id`; (c) los joins son sort-merge por tener AQE y broadcast desactivados.

**Recorrido:** Spark runs únicamente (stages, `taskSummary`, plan SQL). Sin pivote.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Sesión analizada | `application_1793422990874_0001`, runtime 1.3, `runningDuration` 670 s | E1 |
| Configuración Spark de `nb_02` | AQE y skewJoin desactivados, `autoBroadcastJoinThreshold=-1`, `shuffle.partitions=2000` | informe 01 (E7, E22) |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| `nb_02_bronze_to_silver` | Notebook | Silver | `4205418f-cee2-4a3d-9390-328618160264` |

## Evidencia

### Métricas clave

Sesión de la ejecución 11: 167 stages (sin los `SKIPPED` en las sumas), 0 bytes de spill (E2). Reparto por sentencia (`jobGroup`) de los stages ejecutados (E3):

| Sentencia | Qué hace | Tiempo de ejecutor (s·tarea) | % | Shuffle write (MB) | Shuffle read (MB) | Spill |
|-----------|----------|------------------------------|---|--------------------|-------------------|-------|
| 4 | `MERGE` de `customers` | 6.853 | 60 % | 55 | 65 | 0 |
| 6 | Reconstrucción de `silver.sales` | 3.898 | 34 % | 6.085 | 8.515 | 0 |
| 7 | `inventory_levels` | 718 | 6 % | 7 | 7 | 0 |
| 5 | `stores` / `products` | 31 | < 1 % | 0,2 | 0,2 | 0 |

Crecimiento entre ejecuciones (informe 01, E10–E11): shuffle write de `nb_02` 677 → 6.147 MB (+522,8 MB por ejecución, R² 0,99); celda 4 108 → 404 s (+20,3 s por ejecución); celda 6 64 → 173 s (+10,9 s por ejecución). Es decir: **en bytes crece la sentencia 6; en segundos de reloj crece más la 4** (+296 s frente a +109 s en la serie de 10 ejecuciones).

### Stages más pesados (ordenados por tiempo de ejecutor; ejecución 11)

| Stage | Sentencia | Tareas | Ejecutor (s·tarea) | Shuffle read (MB) | Shuffle write (MB) | Input (MB) | Spill |
|-------|-----------|--------|--------------------|-------------------|--------------------|------------|-------|
| 19 | 4 · `MAX(source_run_seq)` sobre `customers` | 549 | 2.090 | 0 | 0,03 | 47,7 | 0 |
| 29 | 4 · `MERGE` (lectura de `customers`) | 549 | 1.839 | 0 | 6,9 | 40,0 | 0 |
| 123 | 6 · lectura de `customers` en el join | 608 | 1.810 | 0 | 3,4 | 36,3 | 0 |
| 34 | 4 · `MERGE` | 188 | 670 | 0 | 1,1 | 19,3 | 0 |
| 33 | 4 · `MERGE` | 2.000 | 662 | 2,3 | 0 | 0 | 0 |
| 159 | 7 · escritura de `inventory_levels` | 2.000 | 535 | 3,8 | 0 | 0 | 0 |
| 125 | 6 · join por `customer_id` | 2.000 | 486 | 1.875,8 | 1.215,0 | 0 | 0 |
| 35 | 4 · `MERGE` (escritura) | 2.000 | 458 | 1,1 | 0 | 0,8 | 0 |
| 140 | 6 · UDF y escritura de `sales` | 64 | 432 | 1.244,5 | 0 | 0 | 0 |
| 103 | 6 · `count` sobre `sales_raw` | 130 | 409 | 0 | 449,2 | 399,4 | 0 |
| 122 | 6 · lectura de `sales_raw` (dedup) | 130 | 369 | 0 | 1.292,7 | 722,4 | 0 |

Ordenados por **shuffle write**: stage 124 (1.872,5 MB, 2.000 tareas), 122 (1.292,7), 139 (1.244,5), 125 (1.215,0), 103 (449,2). Por **shuffle read**: 125 (1.875,8), 124 (1.292,7), 140 (1.244,5), 139 (1.215,0), 133 y 127 (1.215,0 cada uno, de la misma exchange). Todos son de la sentencia 6. **Spill: 0 en todos** (E2). Los tres primeros por tiempo (19, 29, 123) no mueven shuffle: son lecturas de `customers` con ficheros pequeños (informe 02, H1).

### Skew por stage (cuantiles de las tareas; ms y MB)

Duración en ms (mín / mediana / p95 / máx) y razón máx/mediana; bytes por tarea (mediana / máx) (E5).

| Stage | Duración mín / med / p95 / máx (ms) | Máx/med | Bytes por tarea (mediana / máx, MB) | Lectura |
|-------|-------------------------------------|---------|-------------------------------------|---------|
| 19 (`MERGE`, MAX) | 986 / 3.572 / 5.325 / 11.028 | 3,1 | input 0,09 / 0,09 | **Time skew**: mismos bytes, 3× de tiempo |
| 29 (`MERGE`) | 1.325 / 3.203 / 4.238 / 13.245 | 4,1 | input 0,09 / 0,11 | **Time skew** |
| 123 (join, `customers`) | 727 / 2.937 / 4.092 / 4.974 | 1,7 | input 0,08 / 0,11 | Sin skew; 2,9 s por tarea para ~90 KB (ficheros pequeños) |
| 34 (`MERGE`) | 1.359 / 3.653 / 4.477 / 4.873 | 1,3 | input 0,11 / 0,20 | Sin skew |
| 122 (`sales_raw`) | 105 / 2.721 / 3.701 / 4.294 | 1,6 | input 4,31 / 7,49 | Sin skew |
| 124 (exchange por `sale_id`) | 65 / 106 / 157 / 341 | 3,2 | read 0,65 / 0,68; write 0,94 / 0,98 | Datos equilibrados |
| 125 (join `customer_id`) | 105 / 255 / 402 / 606 | 2,4 | read 0,94 / 1,25; write 0,61 / 0,84 | Datos equilibrados |
| **139 (exchange por `store_id`)** | 13 / 24 / 58 / 12.849 | **535** | read 0 / **683,85**; write 0 / **746,32** | **Data skew** |
| **127 y 133 (lectura de esa exchange)** | 12 / 23 / 52 / 5.476 (127); 205 / 396 / 550 / 5.150 (133) | 238 y 13 | read 0 / 683,85 (127); 10,89 / 683,85 (133) | **Data skew**: una tarea con 684 MB |
| **140 (UDF + escritura)** | 1.484 / 6.254 / 18.693 / 23.939 | 3,8 | read 19,26 / 24,93 | **Time skew**: bytes similares, 3,8× de tiempo |
| 103 (`count`) | 184 / 3.168 / 3.637 / 4.052 | 1,3 | input 3,10 / 3,10; write 3,48 / 3,49 | Sin skew |
| 104 | 18 / 44 / 73 / 129 | 2,9 | read 0,22 / 0,24 | Sin skew |
| 33, 35, 159 | máx/mediana 3,3 / 7,1 / 2,5 | — | bytes ≈ 0 | Tareas cortas (< 2 s), irrelevante |

Impacto en reloj del data skew: la tarea de 684 MB tarda 12,8 s (stage 139) y 5,5 s (stage 127): unos 18–25 s en total en una ejecución de 668 s (E5; el informe 01 ya lo cuantificaba en ~30 s). El tamaño de esa tarea sí crece con el histórico (el 60 % de las ventas son de `store_id = 1`, informe 01 H3).

### Estrategia de cada join (plan físico de la sentencia 6, ejecución SQL 81, y de la 4, ejecuciones 22, 25, 28 y 29)

| Join | Claves | Tipo | Estrategia | Exchange previo | Origen |
|------|--------|------|------------|-----------------|--------|
| `sales` (tras dedup) ⋈ `customers` | `customer_id` | LeftOuter | **SortMergeJoin** (nodo 20) | `hashpartitioning(customer_id, 2000)` en ambos lados | Plan, E4 |
| resultado ⋈ `stores` (50 filas) | `store_id` | LeftOuter | **SortMergeJoin** (nodo 28) | `hashpartitioning(store_id, 2000)` en ambos lados | Plan, E4 |
| `MERGE` de `customers`: origen ⋈ destino | clave de cliente | Inner y LeftOuter | **SortMergeJoin** (ejecuciones 22: dos; 25 y 28 y 29: uno cada una) | — | Plan, E4 |
| Dedup de `sale_id` | `row_number()` | Window | `Exchange hashpartitioning(sale_id, 2000)` + `Sort` + `Window` con `WindowGroupLimit` | — | Plan, E4 |

Además, el plan acaba con `Exchange rangepartitioning(sale_ts, 64)` (la `repartitionByRange(64)`) y `BatchEvalPython` (UDF `classify_note`). No hay `BroadcastHashJoin` ni `ShuffledHashJoin` en ninguna ejecución de `nb_02` (E4). **Inferencia (no medida):** que `stores` (50 filas, ~0 KB) y `customers` (~169.000 filas) irían a broadcast con `autoBroadcastJoinThreshold` por defecto es una deducción de los tamaños y del `-1` configurado; no se probó con otro valor. La relación entre el stage 139 y el nodo 22 (`hashpartitioning(store_id)`) también es una inferencia: el stage 139 escribe 1.244,5 MB y la exchange 22 mueve las filas de ~16 columnas del join; no hay etiqueta directa stage ↔ nodo en el plan.

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `POST …/datapipelines/pipelineruns/524c4c37-…/queryactivityruns`; `GET …/notebooks/{nb_02}/livySessions/{88afdede-…}` | `Bronze to silver` `Succeeded`, 696 s; `sparkApplicationId` `application_1793422990874_0001`, `runningDuration` 670 s |
| E2 | REST | `GET …/applications/{appId}/stages` | 167 stages; suma sobre los no `SKIPPED`: 11.511 s·tarea, shuffle write 6.147 MB, read 8.588 MB, spill 0 |
| E3 | REST | `GET …/applications/{appId}/jobs` y agregación de E2 por `jobGroup` | Tabla por sentencia |
| E4 | REST | `GET …/applications/{appId}/sql?details=true&planDescription=true&length=400` | 106 ejecuciones SQL; planes físicos de las ejecuciones 22, 25, 28, 29 (sentencia 4) y 81 (sentencia 6) |
| E5 | REST | `GET …/stages/{id}/0/taskSummary?quantiles=0.0,0.5,0.95,1.0` × 16 stages | Tablas de skew |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | La premisa es parcial: el shuffle es lo que más crece en bytes (99 % en la sentencia 6), pero en tiempo manda el `MERGE` de `customers` (60 % del ejecutor, +296 s frente a +109 s). Ambos son de `nb_02` | Alta | Alta | E2, E3, informes 01 y 02 |
| H2 | Data skew en la exchange por `store_id`: una tarea de 684 MB con mediana 0 (stages 139, 127, 133) | Alta | Alta | E4, E5 |
| H3 | Time skew en la UDF (stage 140, 3,8×) y en las lecturas de `customers` del `MERGE` (stages 19 y 29, 3,1× y 4,1×) | Media | Alta | E5 |
| H4 | Todos los joins de `nb_02` son SortMergeJoin con 2.000 particiones de shuffle; ninguno usa broadcast, incluso `stores` con 50 filas | Alta | Alta | E4 |

### H1 · La premisa "el shuffle es lo que más crece" es cierta solo en bytes

- **Qué ocurre:** en la sesión de la ejecución 11, la sentencia 6 concentra 6.085 de los 6.147 MB de shuffle write (99 %), y la 4 solo 55 MB (E3). Pero el tiempo de ejecutor de la 4 (6.853 s·tarea) casi dobla el de la 6 (3.898). Sus stages 19, 29 y 123 (2.090, 1.839, 1.810 s·tarea) no mueven shuffle (E2).
- **Por qué:** el shuffle de `sales` es volumen real (se reprocesa todo el histórico, informe 01 H2). El coste del `MERGE` no es de datos sino de ficheros: 549 tareas de 3,2–3,6 s para ~90 KB cada una (E5, informe 02 H1).
- **Impacto:** si se corrige solo el shuffle (R3 del informe 01), se elimina la componente lineal en bytes pero no la mayor parte del aumento de reloj. Severidad Alta por ser la causa de la mayor parte del aumento (`diagnostic-workflow.md` § Severity Thresholds para el shuffle > 1 GB por stage, ya superado por los stages 124, 125, 140 y 139).

### H2 · Data skew en el join por `store_id`

- **Qué ocurre:** en los stages 127 y 133 una sola tarea lee 683,85 MB; la mediana de lectura es 0 (127) o 10,9 MB (133). En el stage 139 una tarea escribe 746,3 MB (mediana 0) y dura 12,8 s frente a una mediana de 24 ms (E5).
- **Por qué:** la clave `store_id` está concentrada (60 % de las ventas en la tienda 1, informe 01 H3), y con `hashpartitioning(store_id, 2000)` todas las filas de esa tienda caen en una partición. AQE y `skewJoin` desactivados (informe 01 E22) no lo reparten.
- **Impacto:** 18–25 s de reloj hoy (E5). Crece con el histórico porque la tienda 1 acumula el 60 % de 10 M filas. Cumple el umbral de skew > 3× (`diagnostic-workflow.md`), y en este caso la razón máx/mediana es 238–535×.

### H3 · Time skew en UDF y en `customers`

- **Qué ocurre:** el stage 140 tiene tareas de 1,5 s a 23,9 s con ~19–25 MB de lectura (E5). Los stages 19 y 29 van de ~1 s a 11–13 s con 0,09–0,11 MB por tarea.
- **Por qué:** con bytes casi iguales, la diferencia de tiempo no viene del volumen. En el stage 140 la causa probable es la UDF de Python (el informe 01 describe 100 `re.sub` para comentarios de 22–23 h tras `repartitionByRange(sale_ts)`); es inferencia, no se midió el contenido de cada partición. En 19 y 29 es el coste por fichero pequeño y los deletion vectors (informe 02).
- **Impacto:** el stage 140 aporta ~24 s de reloj en el peor caso; 19 y 29, ~11–13 s cada uno. Severidad Media.

### H4 · SortMergeJoin en todos los joins

- **Qué ocurre:** el plan de la sentencia 6 contiene dos `SortMergeJoin LeftOuter` precedidos de `Exchange hashpartitioning(..., 2000)` y `Sort` en ambos lados (E4). El `MERGE` también usa `SortMergeJoin`.
- **Por qué:** `autoBroadcastJoinThreshold=-1` y AQE desactivado fuerzan el shuffle de ambos lados aunque `stores` tenga 50 filas (informe 01 E7, E22).
- **Impacto:** el join con `stores` es el que produce el data skew de H2 y mueve 1.215 MB. Severidad Alta por esa relación.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | `F.broadcast(stores)` y quitar `autoBroadcastJoinThreshold=-1`; AQE con `skewJoin` activo | H2, H4 | Alto | Bajo | Bajo | Sí |
| R2 | Sustituir `classify_note` por expresiones nativas o pandas UDF | H3 | Medio | Bajo | Bajo | Sí |
| R3 | Compactar `customers` (R1 del informe 02) | H1, H3 | Alto | Bajo | Medio | Sí |
| R4 | Carga incremental de `silver.sales` (R3 del informe 01) | H1 | Alto | Medio | Medio | Sí |

### R1 · Broadcast de `stores` y AQE

- **Cambio propuesto:** en `nb_02`, `sales.join(F.broadcast(stores_df), "store_id", "left")` y eliminar `spark.conf.set("spark.sql.adaptive.enabled","false")` y `autoBroadcastJoinThreshold=-1` (y lo mismo en `env_silver`).
- **Impacto esperado:** desaparece la exchange por `store_id` (1.215 MB de shuffle y la tarea de 684 MB). Estimación a partir de los tamaños, no medida.
- **Cómo validarlo:** en la ejecución siguiente, el plan (E4) muestra `BroadcastHashJoin` para `stores`, y los stages que lo sustituyen tienen máx/mediana < 3× (E5).
- **Reversión:** restaurar el notebook y el environment.
- **Requiere confirmación:** Sí (edición y publicación del environment; no los hace el agente).

### R2 · UDF nativa

- **Cambio propuesto:** reescribir `classify_note` con `F.when` y `F.regexp_replace`, o una pandas UDF, antes de `repartitionByRange`.
- **Impacto esperado:** el stage 140 pasa a tareas de duración homogénea (hoy 1,5–23,9 s).
- **Cómo validarlo:** `taskSummary` del stage equivalente con máx/mediana < 3×.
- **Reversión:** restaurar el notebook.
- **Requiere confirmación:** Sí.

### R3 y R4

Ver R1 del informe 02 y R3 del informe 01. R3 ataca el 60 % del tiempo de ejecutor; R4 la componente en bytes. Con la premisa corregida (H1), conviene hacer R3 antes que R4 si solo se puede una.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Hay spill en `nb_02` | E2 | 0 bytes de spill en memoria y disco en todos los stages |
| D2 | Hay data skew en la exchange por `customer_id` o por `sale_id` | E5 | Stages 124 y 125: lectura/escritura por tarea de 0,6–1,3 MB (máx/mediana 1,3–1,5 en bytes), duración 2,4–3,2× |
| D3 | Algún join usa broadcast o shuffled hash | E4 | Solo `SortMergeJoin` en las 5 ejecuciones SQL inspeccionadas |
| D4 | El shuffle es la parte del `nb_02` que más pesa en tiempo | E2, E3 | La sentencia 4 (sin shuffle relevante) suma el 60 % del ejecutor |

## Siguientes pasos

- [ ] Aplicar R1 (broadcast y AQE) y R3 (compactar `customers`) en una ventana sin ejecuciones — responsable: ingeniería de datos / `FabricAdmin` (environment) · relacionado con: R1, R3
- [ ] Reescribir la UDF — responsable: ingeniería de datos · relacionado con: R2
- [ ] Repetir E4 y E5 en las 2 ejecuciones siguientes a los cambios — responsable: FabricPerfAnalyst · relacionado con: R1, R2

## Notas

### Limitaciones

- Solo se analizaron los stages y el plan de la ejecución 11. No se re-consultó la ejecución 1 ni las intermedias; la evolución por ejecución del skew se toma del informe 01 (stage 127: 652 MB en el Advisor).
- Los planes SQL no llevan etiqueta stage ↔ nodo. Asigné los stages a las exchanges por sus tamaños y por el `jobGroup` (sentencia); esa asignación es inferencia (marcada arriba) salvo para el stage 140 y la sentencia, que sí constan.
- El stage 123 está en la sentencia 6 (lectura de `customers` en el join), no en la 4; el informe 01 ya lo describía así.
- Los stages 103 y 104 (`count`) están en la sentencia 6, según su `jobGroup` (E3).
- Los planes SQL listan 106 ejecuciones y se pidieron 400 (`length`); no hay paginación pendiente.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Plan con `BroadcastHashJoin` bajo otra configuración | Requeriría `spark.conf.set` o reejecución (Tier C) | La mejora de R1 es estimación |
| Contenido por partición de la UDF | No hay API de contenido por tarea | Causa del time skew del stage 140 con confianza Media |

### Discrepancias entre skills y documentación

Sin discrepancias nuevas respecto a los informes 01 y 02.

## Anexo

Cuantiles pedidos: `quantiles=0.0,0.5,0.95,1.0` sobre `duration`, `shuffleReadMetrics.readBytes`, `shuffleWriteMetrics.writeBytes` e `inputMetrics.bytesRead` de cada stage (intento 0). Agregación por sentencia: `jobGroup` de cada job de E3 aplicado a los `stageIds`, contando cada stage una vez y excluyendo `SKIPPED`.
