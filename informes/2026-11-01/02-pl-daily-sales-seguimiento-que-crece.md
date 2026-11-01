# Seguimiento de pl_daily_sales: qué crece entre ejecuciones y qué parte del MERGE es la que crece

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-01 |
| **Áreas** | Spark runs → Delta tables (confirmación con Livy) |
| **Ámbito** | workspace `FabricPerfLab` · `pl_daily_sales` y las tablas `lh_silver.customers`, `lh_silver.sales`, `lh_silver.inventory_levels` |
| **Ventana analizada** | 2026-10-30 17:11 → 2026-11-01 05:01 UTC (historial completo del pipeline); Livy a 2026-11-01 11:31–11:33 UTC |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli |
| **Modo** | Lectura + diagnóstico activo (Livy) |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** "¿Qué es lo que crece entre ejecuciones?" de `pl_daily_sales`.
- **Conclusión:** este informe es un seguimiento de `2026-11-01/01-pl-daily-sales-tendencia-crecimiento.md` (informe 01 de hoy). Sus cifras siguen vigentes: no hay ninguna ejecución nueva desde la del 2026-11-01 05:00 UTC (12 instancias, la última `Failed`) y las tablas están sin cambios (E1, E2). Lo que crece, por orden de peso: (1) la fase de **escaneo del objetivo** en el `MERGE` de `customers`, que pasa de 16,6 s a 141,0 s entre la versión 1 y la 10 (+13,1 s por versión, R² 0,93) mientras la fase de reescritura se queda plana (~46 s, R² 0,05) y las filas de origen también (~14.000) (E3); (2) el volumen que se reprocesa en `silver.sales` (10 M filas, 757 MB, reconstruida entera cada día) con su shuffle (+523 MB por ejecución, ver informe 01). El número de jobs de Spark no crece.
- **Impacto:** el escaneo ya es el 72 % del tiempo del `MERGE` (141,0 de 195,9 s; en la versión 1 era el 21 %). Es lo que hace que la celda pase de 108 a 404 s en el informe 01. Los datos que cambian cada día no crecen; crece el número de ficheros que hay que recorrer para encontrarlos.
- **Primera acción:** R1 del informe 01 (compactar `customers` y recuperar AQE), con la medición de este informe como criterio de validación. R2 del informe 01 (deriva de `amount`) sigue pendiente: la ejecución programada de mañana es el `run_seq` 13, no falla, pero los días 2026-09-06 y 2026-09-12 siguen sin ventas.

## Alcance

**Pregunta original:** "El pipeline pl_daily_sales del workspace FabricPerfLab tarda cada día más. Pregunta del usuario: ¿Qué es lo que crece entre ejecuciones?"

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Comprobar si hay ejecuciones nuevas desde el informe 01. Confirmar con Livy el estado actual de `customers`, `sales` e `inventory_levels`. Separar el tiempo del `MERGE` en escaneo y reescritura. | Repetir las series por actividad, notebook, stage y `_delta_log` del informe 01 (no han cambiado). `sm_sales` y capacidad. |

**Informes previos usados:** `2026-11-01/01-pl-daily-sales-tendencia-crecimiento.md` (base de series y tablas). `2026-10-30/01-…` (otro workspace, `DataSaturday`; mismo patrón: `customers` de 2.000 a 5.969 ficheros y `Bronze to silver` +27 s por ejecución). `2026-10-31/05-nb02-skew-shuffle-joins.md` y `2026-10-31/05-mantenimiento-delta-bronze-silver-gold.md` no se releen: el informe 01 ya los cita.

**Hipótesis de partida:** (a) hay ejecuciones nuevas que cambien la tendencia; (b) lo que crece del `MERGE` es el escaneo del objetivo por fragmentación, no el volumen de cambios ni la reescritura; (c) el estado de las tablas coincide con lo que midió el informe 01.

**Recorrido:** Spark runs (lista de ejecuciones, E1) → Delta tables (`DESCRIBE DETAIL` e historial del `MERGE` con Livy, E2–E4). No hubo pivote nuevo.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Workspace | `FabricPerfLab` `23ca4a73-3312-4242-9714-0289816895aa` | informe 01 |
| Sesión Livy | Creada en `lh_silver` (`b01f7911-28fd-4dc2-ac51-1d19ed841238`), pool por defecto, sin `conf`; 4 sentencias de lectura; borrada al terminar (estado `killed`) | E2–E5 |
| Configuración Spark / pools / capacidad | Sin cambios respecto al informe 01 (no re-consultados) | informe 01 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| `pl_daily_sales` | DataPipeline | Orquestación | `bd706b1d-499f-4a0d-bb22-222312944ca1` |
| `lh_silver` | Lakehouse | Silver | `b01f7911-28fd-4dc2-ac51-1d19ed841238` |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Ejecuciones de `pl_daily_sales` | 12 (10 `Completed`, 2 `Failed`); la última, 2026-11-01 05:00:02 UTC, `Failed`, 79 s | — | E1 |
| Duración del pipeline (10 correctas) | 915 → 1.573 s, sin ejecuciones nuevas desde el informe 01 | — | E1 |
| `lh_silver.customers` | 19.433 ficheros, 85.694.861 B (4,4 KB de media), `delta.enableDeletionVectors=true` | Media < 32 MB: `performance-patterns.md` § Small File Problem | E2 |
| `lh_silver.sales` | 64 ficheros, 756.888.497 B, 10.000.000 filas | — | E2, E3 |
| `lh_silver.inventory_levels` | 2.000 ficheros, 6.733.756 B (3,4 KB de media) | Ídem | E2 |
| `MERGE` de `customers`, fase de escaneo (`scanTimeMs`) | 16,6 → 141,0 s (versión 1 → 10); +13,1 s por versión, R² 0,93 | — | E4 |
| `MERGE` de `customers`, fase de reescritura (`rewriteTimeMs`) | 46,7 → 45,5 s; rango 38,7–64,1 s; pendiente −0,6 s, R² 0,05 | — | E4 |
| `MERGE` de `customers`, tiempo total (`executionTimeMs`) | 80,8 → 195,9 s; +12,4 s por versión, R² 0,81 | — | E4 |
| Filas de origen del `MERGE` (`numSourceRows`) | ~13.800–14.100 desde la versión 2 (la 6 con 27.073: absorbe el día sin ventas, ver informe 01 H4) | — | E4 |
| Ficheros escritos por `MERGE` (`numTargetFilesAdded`) | 1.979–2.000 en las 10 versiones | — | E4 |
| Cuota del escaneo en el tiempo total | 21 % (versión 1) → 72 % (versión 10) | — | E4 |

### Tendencia de los componentes del `MERGE` de `customers` (segundos)

| Versión | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
|---------|---|---|---|---|---|---|---|---|---|----|
| Escaneo (`scanTimeMs`) | 16,6 | 37,5 | 48,4 | 64,6 | 88,0 | 108,5 | 83,4 | 126,1 | 119,4 | 141,0 |
| Reescritura (`rewriteTimeMs`) | 46,7 | 49,4 | 42,3 | 58,8 | 64,1 | 46,1 | 38,7 | 41,2 | 49,2 | 45,5 |
| Total (`executionTimeMs`) | 80,8 | 92,8 | 96,3 | 128,3 | 163,6 | 172,4 | 126,9 | 178,0 | 177,9 | 195,9 |
| Filas de origen | 2.000 | 14.015 | 13.935 | 13.994 | 14.038 | 27.073 | 14.114 | 13.779 | 13.872 | 14.089 |
| Ficheros añadidos / quitados | 2.000 / 0 | 1.983 / 0 | 1.989 / 2 | 1.981 / 12 | 1.984 / 25 | 2.000 / 90 | 1.989 / 54 | 1.984 / 71 | 1.979 / 90 | 1.983 / 95 |

La versión 1 es la carga inicial; desde la 2 los cambios diarios son de ~14.000 filas.

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces/{ws}/items/{pl_daily_sales}/jobs/instances` | 12 instancias, sin `continuationToken`; la última, `5d856136` (2026-11-01 05:00:02, Scheduled, `Failed`, 79 s). Ninguna posterior |
| E2 | Livy | Sentencia 1: `DESCRIBE DETAIL` de `customers`, `sales` e `inventory_levels` (`numFiles`, `sizeInBytes`, `properties`) | Cifras de la tabla de métricas |
| E3 | Livy | Sentencia 1: `SELECT COUNT(*) FROM sales`, `SHOW TBLPROPERTIES customers` | 10.000.000 filas; `delta.enableDeletionVectors=true`, `delta.feature.deletionVectors=supported`, `delta.stats.extended.collect/inject=true` |
| E4 | Livy | Sentencias 1 y 2: `DESCRIBE HISTORY customers` con `selectExpr` sobre `operationMetrics` | Tabla de componentes del `MERGE`. Las métricas de la versión 10 coinciden con las del informe 01 (`executionTimeMs` 195.852, `numTargetFilesAdded` 1.983) |
| E5 | REST / Livy | `POST …/lakehouses/{lh_silver}/livyapi/versions/2023-12-01/sessions` (creación, 11:31:45 UTC) y `DELETE …/sessions/{id}` (11:33 UTC) | Sesión `idle` en <2 min; tras el borrado, `GET` devuelve `killed` |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | Lo que crece en el `MERGE` de `customers` es el escaneo del objetivo (+13,1 s por versión, 21 % → 72 % del total); reescritura y filas de origen son constantes | Alta | Alta | E2, E4 |
| H2 | El estado del sistema no ha cambiado desde el informe 01: sin ejecuciones nuevas, tablas idénticas; las conclusiones y recomendaciones de ese informe siguen vigentes | Media | Alta | E1, E2, E4 |

### H1 · El tiempo que crece del `MERGE` es el de buscar en 19.433 ficheros, no el de escribir cambios

- **Qué ocurre:** el `MERGE` de `customers` recibe cada día ~14.000 filas de origen (E4) y escribe siempre 1.979–2.000 ficheros. Con eso, `rewriteTimeMs` se mantiene en 38,7–64,1 s sin tendencia (R² 0,05). En cambio `scanTimeMs` sube de 16,6 a 141,0 s (R² 0,93), (+124,4 s) y `executionTimeMs` crece +115,1 s (80,8 → 195,9 s), es decir, el escaneo explica todo el aumento y algo más, compensado por una reescritura algo menor (E4). El escaneo ya es el 72 % del `MERGE`.
- **Por qué:** la tabla pasa de 2.000 a 19.433 ficheros de 4,4 KB de media, con deletion vectors (E2, informe 01 E15–E17). El `MERGE` tiene que localizar los ficheros que contienen las claves de cambio recorriendo el estado de la tabla y los ficheros candidatos, y ese trabajo crece con el número de ficheros y de deletion vectors, no con el volumen de datos (la tabla pesa 85,7 MB). Esto es una inferencia a partir de que solo crece el escaneo y que la única magnitud que crece en la tabla es el número de ficheros; no medí el plan del `MERGE`.
- **Impacto:** explica la mayor parte de los +296 s de la celda 4 de `nb_02` del informe 01. Severidad Alta: anomalía de ficheros pequeños (media 4,4 KB frente a 32 MB, `performance-patterns.md` § Small File Problem) con efecto directo medido. Confianza Alta en lo medido (qué fase crece); la atribución a la fragmentación es Media-Alta porque coincide con el patrón de `DataSaturday` (`2026-10-30/01`), donde `customers` también crecía en ficheros y en tiempo de `MERGE`.

### H2 · Sin ejecuciones nuevas ni cambios de estado

- **Qué ocurre:** la lista de instancias tiene 12 elementos y la última sigue siendo la del 2026-11-01 05:00 UTC (E1). `customers` tiene 19.433 ficheros, `sales` 64 y 10 M filas, `inventory_levels` 2.000 (E2, E3), las mismas cifras del informe 01. Por tanto la tendencia por actividad (915 → 1.573 s), el shuffle (677 → 6.147 MB) y el resto de series de ese informe no se actualizan.
- **Impacto:** la próxima ejecución programada (2026-11-02 05:00 UTC) será el `run_seq` 13. Con las proyecciones del informe 01 añadiría ~+60 s al pipeline y ~+13 s de escaneo al `MERGE` (extrapolación lineal, no medición).

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Aplicar R1 del informe 01 (`REORG … PURGE` + `OPTIMIZE` de `customers`, AQE activo en silver) y validar con la separación escaneo/reescritura | H1 | Alto | Bajo | Medio | Sí |
| R2 | Mantener las demás recomendaciones del informe 01 (R2 deriva de `amount`, R3 carga incremental de `sales`) en el mismo orden | H2 | Alto | Bajo–Medio | Medio | Sí |

### R1 · Compactar `customers` y validar con `scanTimeMs`

- **Cambio propuesto:** el del informe 01 (R1): `REORG TABLE lh_silver.customers APPLY (PURGE)`, `OPTIMIZE lh_silver.customers`, y eliminar de `env_silver` y de `nb_02` AQE desactivado, `autoBroadcastJoinThreshold=-1` y `shuffle.partitions=2000`.
- **Impacto esperado:** `scanTimeMs` vuelve cerca del nivel de la versión 1 (~17 s) y `numTargetFilesAdded` baja de ~2.000 a decenas. No se espera cambio en `rewriteTimeMs` salvo por el menor número de ficheros escritos. Estimación por proporción, no medición.
- **Cómo validarlo:** tras la compactación y las 2 ejecuciones siguientes, repetir E4 (`DESCRIBE HISTORY customers` con `scanTimeMs`, `rewriteTimeMs`, `numTargetFilesAdded`) y E2 (`numFiles`). Éxito: `scanTimeMs` sin pendiente positiva y < 60 s; `numFiles` < 1.000.
- **Reversión:** la compactación no cambia datos; time travel dentro de la retención. Para el environment, volver a poner las propiedades y republicar.
- **Requiere confirmación:** Sí. Lo aplica una persona o `FabricAdmin` (el agente no ejecuta `OPTIMIZE`, `REORG` ni publica environments).

### R2 · Resto del informe 01

- **Cambio propuesto:** ver R2 y R3 del informe 01 (evitar la deriva de `amount`, escribir la fila de control al final, recargar 2026-09-06 y 2026-09-12; carga incremental de `silver.sales` y `gold.fact_sales`).
- **Impacto esperado:** el que ese informe indica; esta revisión no lo modifica.
- **Cómo validarlo:** igual que en el informe 01.
- **Reversión:** igual que en el informe 01.
- **Requiere confirmación:** Sí.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Crece el volumen diario de cambios que entra al `MERGE` | E4 | `numSourceRows` constante en ~13.800–14.100 desde la versión 2 (el pico de 27.073 de la versión 6 no se repite) |
| D2 | Crece el coste de reescribir ficheros en el `MERGE` | E4 | `rewriteTimeMs` 38,7–64,1 s sin tendencia (R² 0,05); `numTargetFilesAdded` constante en ~2.000 |
| D3 | Hay ejecuciones nuevas que cambian la tendencia del informe 01 | E1 | La lista de instancias no incluye ninguna posterior al 2026-11-01 05:00 UTC |

## Siguientes pasos

- [ ] Aplicar R1 del informe 01 en una ventana sin ejecuciones y repetir E4 — responsable: ingeniería de datos / `FabricAdmin` (environment) · relacionado con: R1
- [ ] Decidir sobre R2 y R3 del informe 01 (deriva de `amount`, carga incremental) — responsable: ingeniería de datos y propietario del dato · relacionado con: R2
- [ ] Repetir el análisis completo tras 5 ejecuciones con R1 aplicada — responsable: FabricPerfAnalyst · relacionado con: R1

## Notas

### Limitaciones

- Este informe no repite las series por actividad, stage y `_delta_log` del informe 01, porque el estado es idéntico (E1, E2). Se citan por referencia.
- H1: el reparto escaneo/reescritura viene de las métricas del `MERGE` (`operationMetrics`); no medí el plan físico (`EXPLAIN`) ni los stages del `MERGE`. La causa (recorrido de ficheros y deletion vectors) es inferencia coherente con el informe 01 (stage 19: 549 tareas de 3,6–9,2 s para ~90 KB).
- La sesión Livy se creó en `lh_silver` y solo vio las tablas de silver con nombre simple; no se consultaron tablas de bronze ni gold por esa vía.
- En la versión 6, `numSourceRows` = 27.073 (el doble). Se atribuye al fallo del `run_seq` 6 del informe 01 (sus cambios de clientes se aplicaron en una ejecución posterior), sin verificarlo con el `_delta_log`.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| `EXPLAIN` del `MERGE` | Es una DML; su plan no se obtiene con las sentencias de lectura permitidas sin ejecutarlo | H1 con confianza Media-Alta en la causa |
| Ejecuciones nuevas | No existen (E1) | Series sin actualizar |

### Discrepancias entre skills y documentación

Sin discrepancias nuevas respecto al informe 01.

## Anexo

### Sentencias Livy ejecutadas (E2–E4)

```python
spark.sql("DESCRIBE DETAIL customers").select("numFiles","sizeInBytes","properties").show(truncate=False)
spark.sql("DESCRIBE DETAIL sales").select("numFiles","sizeInBytes").show(truncate=False)
spark.sql("DESCRIBE DETAIL inventory_levels").select("numFiles","sizeInBytes").show(truncate=False)
spark.sql("DESCRIBE HISTORY customers").select("version","operation","operationMetrics").limit(3).show(truncate=False)
spark.sql("SELECT COUNT(*) AS n FROM sales").show()
spark.sql("SHOW TBLPROPERTIES customers").show(truncate=False)
spark.sql("DESCRIBE HISTORY customers").selectExpr("version","operationMetrics['scanTimeMs'] as scan","operationMetrics['rewriteTimeMs'] as rewrite","operationMetrics['executionTimeMs'] as exec","operationMetrics['numSourceRows'] as src","operationMetrics['numTargetFilesAdded'] as fadd","operationMetrics['numTargetFilesRemoved'] as frem").orderBy("version").show(20,truncate=False)
```

Tendencias: mínimos cuadrados frente al número de versión (1–10) sobre los valores de E4 (cálculo local).
