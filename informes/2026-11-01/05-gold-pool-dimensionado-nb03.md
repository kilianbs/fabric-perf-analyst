# ¿Está bien dimensionado el clúster de gold para nb_03_silver_to_gold?

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-01 |
| **Áreas** | Spark resources → Spark runs (stages de la sesión) |
| **Ámbito** | workspace `FabricPerfLab` · `pool_gold_xl`, `env_gold`, `nb_03_silver_to_gold` (10 sesiones, ejecuciones 1–5 y 7–11 de `pl_daily_sales`) |
| **Ventana analizada** | 2026-10-30 17:21 → 2026-10-31 05:23 UTC |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli |
| **Modo** | Solo lectura |
| **Severidad global** | Media |
| **Confianza global** | Alta (medido); Media en las estimaciones de tamaño |

## Resumen

- **Pregunta:** "Gold usa otro pool. ¿Ese clúster está bien dimensionado para lo que hace nb_03_silver_to_gold?"
- **Veredicto: sobredimensionado en reserva y en memoria, no en pico, y el pico que existe es en gran parte artificial.** El pool es Large (16 cores por nodo), con 1 driver y 3 ejecutores fijos de 16 cores y 112 g: 48 cores de ejecutor, sin asignación dinámica (E1, E2). En la ejecución 11 solo hubo jobs de Spark activos 81 s de una sesión de 282 s (29 %). Los 48 cores se llenan en un único stage (608 tareas, 44 s, concurrencia media 46) que lee `silver.customers`, fragmentada en 19.433 ficheros. Fuera de ese stage hay poco trabajo: la mediana es de 10 tareas por stage (E3).
- **Lo que crece en nb_03:** el tiempo de ejecutor pasa de 797 a 2.680 s·tarea (+205 s por ejecución, R² 0,99). El stage de `customers` pasa de 204 a 2.030 s·tarea (26 % → 76 %); el resto se queda en 556–679 s·tarea sin tendencia (E3). Es fragmentación (informe 02), no volumen de gold.
- **Arranque y cola:** el pool personalizado no está precalentado (`poolHit=false`, categoría `OnDemand`). Cola 61–287 s, y el último ejecutor tarda 105–332 s en estar disponible. En la ejecución 10 (la más lenta, 474 s de sesión) el ejecutor 3 llegó a los 332 s y el primer job empezó a los 333 s (E3).
- **Spill 0; GC 41 s de 2.680 (1,5 %); memoria pico de heap de ejecutor 4,7 GB frente a 112 g reservados** (E3, E4).
- **Recomendación (requiere confirmación):** primero compactar `silver.customers` (R1 del informe 02). Después, nodos Medium (8 cores/56 g) con asignación dinámica 1–5 ejecutores, en Starter Pool. Mantiene el pico de 48 cores y no reserva lo que no se usa. Detalle y validación en R1.

## Alcance

**Pregunta original:** "Gold usa otro pool. ¿Ese clúster está bien dimensionado para lo que hace nb_03_silver_to_gold? 1. Qué es hoy el pool de gold: tamaño de nodo, nodos mín/máx, autoscale y asignación dinámica, y cómo se compara con el Starter Pool. 2. Lo que usa nb_03: ejecutores concurrentes y cores o memoria aprovechados frente a los reservados, paralelismo de las tareas (tareas por stage frente a cores), tiempo de cola y arranque, spill, GC y volumen de datos. Contrasta con la serie de ejecuciones. 3. Veredicto razonado, distinguiendo medido de inferido. 4. Recomendación de tamaño y cómo validarla."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Pool, entorno, ejecutores, stages, jobs, memoria y `resourceUsage` de las 10 sesiones de `nb_03`. | Coste en moneda (no se llamó a la API de precios). Capacidad. Causas de la fragmentación (informe 02). |

**Informes previos reutilizados:** `2026-10-31/01-gold-spark-sobredimensionado.md` (eficiencia 0,207, ocio 82,7 %, pico 48 cores, R1 Medium 1–5; dejó abierta la causa del ocio: R2), `2026-11-01/01` (duraciones y cola de gold, E8), `2026-11-01/04` (entorno efectivo de gold: 3 ejecutores fijos, `OnDemand`). Aquí no se repiten esas cifras; se añade el desglose por stage y por tramo de la sesión, que responde a su R2.

**Hipótesis:** (a) el pico de 48 cores se necesita de forma sostenida; (b) el tiempo de la sesión se va en espera y en tramos sin tareas; (c) la memoria reservada es excesiva; (d) el volumen de datos de gold explica el crecimiento.

**Recorrido:** Spark resources (pool y entorno) → Spark runs (stages y jobs de las 10 sesiones, para localizar dónde se usan los cores). Pivote a Delta tables por referencia: la fragmentación de `silver.customers` está en el informe 02.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad | `FTL64` (Trial), West Europe | informe 01 E2 |
| Pool de gold | `pool_gold_xl`: MemoryOptimized, nodo **Large**, autoscale 1–4 nodos, asignación dinámica del pool 1–3 ejecutores | E1 |
| Entorno de gold | `env_gold`: driver 16 cores, ejecutor 16 cores, **asignación dinámica desactivada**; sesión con `executor.instances=3`, `driver.memory` 112g, `executor.memory` 112g | E2; informe 04 E1 |
| Starter Pool (bronze y silver) | MemoryOptimized, nodo **Medium**, autoscale 1–10 nodos, asignación dinámica 1–9 ejecutores; los entornos de bronze y silver lo limitan a 1–4 ejecutores de 8 cores/56 g | E1; informe 04 E4 |
| Runtime | 1.3 | informe 04 E4 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| `pool_gold_xl` | Pool de workspace | Gold | `38ed5dc4-712e-4b6e-accf-d703ad0463c0` |
| `env_gold` | Environment | Gold | `b8c2f706-500a-4507-89fa-f460f81ce7d7` |
| `nb_03_silver_to_gold` | Notebook | Gold | `c7cca4b7-3722-4bec-9946-504520f6be21` |

## Evidencia

### Pool de gold frente a Starter Pool

| Propiedad | `pool_gold_xl` (gold) | Starter Pool (bronze, silver) | Fuente |
|-----------|-----------------------|-------------------------------|--------|
| Tamaño de nodo | Large (16 vCores) | Medium (8 vCores) | E1 |
| Nodos mín/máx | 1 / 4 (autoscale) | 1 / 10 (autoscale) | E1 |
| Asignación dinámica del pool | 1–3 ejecutores | 1–9 ejecutores | E1 |
| Asignación dinámica que usa la sesión | **No** (la desactiva `env_gold`); 3 ejecutores | Sí, 1–4 (la fija el entorno) | E2; informe 04 E4 |
| Cores por ejecutor / memoria | 16 / 112 g (+ driver 16 / 112 g) | 8 / 56 g (+ driver 8 / 56 g) | E2; informe 04 E1 |
| Cores de ejecutor reservados | 48 | 8–32 (según la sesión) | E2; `2026-10-31/01` |
| Precalentado | No: `poolHit=false`, `OnDemand` | Sí (arranque de actividad 3–13 s, informe 01 E5) | informe 04 E1 |

### Uso real de nb_03, serie de las 10 sesiones

Cores de ejecutor reservados = 48. "Activo" = unión de los intervalos de los jobs. Eficiencia sobre activo = `s·tarea de ejecutor / (48 × tiempo activo)`; sobre sesión = `/ (48 × duración)` (E3).

| Ejecución | Cola (s) | Sesión (s) | Último ejecutor listo (s) | Primer job (s) | Tiempo activo (s) | Ejecutor (s·tarea) | Eficiencia activo | Eficiencia sesión | Máx. tareas/stage | Stage más pesado: tareas · s·tarea |
|-----------|----------|------------|---------------------------|----------------|-------------------|--------------------|-------------------|-------------------|-------------------|------------------------------------|
| 1 | 62 | 255 | 169 | 76 | 50 | 797 | 0,34 | 0,07 | 200 | 63 · 204 |
| 2 | 98 | 233 | 150 | 77 | 51 | 1.037 | 0,42 | 0,09 | 200 | 125 · 481 |
| 3 | 71 | 224 | 137 | 49 | 52 | 1.313 | 0,53 | 0,12 | 200 | 187 · 664 |
| 4 | 137 | 284 | 193 | 91 | 63 | 1.432 | 0,48 | 0,11 | 249 | 249 · 818 |
| 5 | 66 | 242 | 149 | 49 | 63 | 1.758 | 0,58 | 0,15 | 310 | 310 · 1.116 |
| 7 | 61 | 283 | 182 | 84 | 70 | 1.869 | 0,55 | 0,14 | 369 | 369 · 1.268 |
| 8 | 287 | 212 | 105 | 41 | 66 | 2.008 | 0,63 | 0,20 | 430 | 430 · 1.354 |
| 9 | 76 | 262 | 153 | 51 | 80 | 2.362 | 0,62 | 0,19 | 490 | 490 · 1.683 |
| 10 | 215 | 474 | 332 | 333 | 82 | 2.446 | 0,62 | 0,11 | 549 | 549 · 1.821 |
| 11 | 76 | 282 | 148 | 149 | 81 | 2.680 | 0,69 | 0,20 | 608 | 608 · 2.030 |

Tendencias (E3): tiempo activo +4,0 s por ejecución (R² 0,93); ejecutor +205 s·tarea por ejecución (R² 0,99); stage más pesado +198 s·tarea por ejecución (R² 0,99); duración de sesión +11,8 s (R² 0,23); cola +8,6 s (R² 0,11), sin tendencia. Excluido el stage pesado, el ejecutor queda en 556–679 s·tarea sin tendencia.

### Desglose de la ejecución 11 (E3, E4)

| Tramo | Duración | Observación |
|-------|----------|-------------|
| Cola antes del inicio de sesión | 76 s | `queuedDuration` |
| Sesión hasta tener los 3 ejecutores | 148 s | Ejecutor 1 a los 31 s; ejecutores 2 y 3 a los 144 y 148 s |
| Primer job | 149 s | Prácticamente a la vez que el último ejecutor |
| De primer a último job | 121 s | De ellos, 81 s con jobs activos y 40 s entre jobs (driver) |
| Tramo final tras el último job | 12 s | 270 → 282 s |

Reservados: 48 cores × 282 s = 13.536 core·s. Usados: 2.680 s·tarea. 19,8 % de la sesión, 69 % del tiempo activo. Paralelismo: 89 stages ejecutados, mediana 10 tareas por stage, 50 stages con ≤ 16 tareas, 58 con ≤ 48, 31 con > 48. Concurrencia media ponderada por tiempo de stage: 32,1 cores. El stage 44 (`spark.read.table("lh_silver.customers")… saveAsTable("dim_customer")`) usa 608 tareas durante 44 s con 2.030 s·tarea (concurrencia 46,2), 69 MB de entrada. El segundo stage más pesado (escritura de `fact_sales`, 64 tareas, 5,4 s) usa 227 s·tarea.

Datos y recursos de la sesión 11: entrada 1.246 MB, salida 556 MB, shuffle write 125 MB; spill 0; GC 41 s de 2.680 (1,5 %). Los ejecutores tienen 68,6 GB de memoria máxima de almacenamiento/ejecución visible y el pico de heap de JVM es de 4,7 GB (ejecutores 1 y 2) y 3,0 GB (ejecutor 3). `resourceUsage`: eficiencia 0,29, ocio 277 s de 357 s (E5).

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces/{ws}/spark/pools` | `pool_gold_xl` Large 1–4 nodos, dinámica 1–3; Starter Pool Medium 1–10 nodos, dinámica 1–9 |
| E2 | REST | `GET …/environments/{env_gold}/sparkcompute` | 16/16 cores, dinámica desactivada (informe 04 E4 la había leído; aquí contrasta con E3) |
| E3 | REST | `GET …/notebooks/{nb_03}/livySessions` y, por sesión, `…/applications/{appId}/allexecutors`, `/jobs`, `/stages` × 10 | Tablas de la serie y del desglose |
| E4 | REST | `allexecutors` de la sesión de la ejecución 11 | Ejecutores 1–3 de 16 cores; `addTime`; `peakMemoryMetrics` |
| E5 | REST | `GET …/applications/{appId}/resourceUsage` de la sesión de la ejecución 11 | `coreEfficiency` 0,290; `idleTime` 277.307 ms de 357.501 ms |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | Gold reserva 48 cores y 112 g por ejecutor para 29 % de tiempo con jobs; la memoria usada es un 4 % de la reservada | Media | Alta | E2–E5 |
| H2 | El único momento en que se llenan los 48 cores es la lectura fragmentada de `silver.customers`, y esa carga crece +198 s·tarea por ejecución | Alta | Alta | E3 |
| H3 | El arranque del pool no precalentado (cola + espera de ejecutores) pesa más que el trabajo de Spark | Media | Alta | E3 |
| H4 | La ejecución 10 lenta (474 s) se debe a la espera de ejecutores (332 s), no a más trabajo | Media | Alta | E3 |
| H5 | Veredicto de dimensionado: sobredimensionado en reserva y memoria; el pico no es una necesidad real | Media | Media | H1–H4 |

### H1 · Reserva frente a uso

- **Qué ocurre:** 48 cores de ejecutor fijos durante 282 s, de los que solo hay jobs activos 81 s (E3). Eficiencia de sesión 0,07–0,20 y 0,34–0,69 sobre el tiempo activo (E3). Pico de heap 4,7 GB por ejecutor frente a 112 g configurados; spill 0; GC 1,5 % (E3, E4).
- **Por qué:** `env_gold` desactiva la asignación dinámica y el pool es Large. Con nodos Large y 3 ejecutores fijos, todo el clúster queda reservado desde el arranque hasta el fin de la sesión (E2).
- **Impacto:** `coreEfficiency` 0,29 en la ejecución 11 y 0,207 de media según `2026-10-31/01` (umbral HIGH < 0,3 en `diagnostic-workflow.md` § Severity Thresholds). Aquí la bajo a Media porque el uso en el tiempo activo es alto (69 %) y no encuentro más coste que la reserva; sin precios en vivo no se calcula dinero.

### H2 · El pico de 48 cores es de una sola lectura fragmentada

- **Qué ocurre:** el stage 44 de la ejecución 11 ocupa el 76 % del tiempo de ejecutor y 44 de los 81 s activos (E3). Sus tareas crecen 63 → 608 y sus segundos de ejecutor 204 → 2.030, con 69 MB de entrada. Las tareas de ese stage coinciden con las de la serie del número de splits de lectura de `silver.customers`; que sea exactamente la lectura de `silver.customers` consta en la descripción del job (E3), y que el número de tareas siga a la fragmentación (informe 02: 19.433 ficheros) es una inferencia.
- **Por qué:** muchos ficheros diminutos generan muchas tareas cortas que sí paralelizan en 48 cores, aunque el volumen de datos es pequeño. El resto del notebook no pasa de 556–679 s·tarea (E3).
- **Impacto:** sin la fragmentación, `nb_03` necesitaría una fracción de esos cores. Con 600 s·tarea de trabajo "base" y concurrencia de 8–32, 24 cores bastan sobradamente (estimación, no medida). Severidad Alta para el crecimiento de la carga (hecho medido), Media para el tamaño del clúster.

### H3 · Arranque y cola

- **Qué ocurre:** `poolHit=false` y categoría `OnDemand` en gold (informe 04 E1); cola de 61–287 s (E3) y último ejecutor listo a los 105–332 s. La suma de cola y espera de ejecutores es de 224 s en la ejecución 11 (76 + 148) frente a 81 s de jobs activos.
- **Por qué:** el pool es personalizado, sin precalentar: hay que aprovisionar nodos Large. En el Starter Pool, bronze y silver arrancan la actividad en 3–13 s (informe 01 E5). Que el motivo sea el pool no precalentado es una inferencia a partir del `poolHit=false` y de esa comparación.
- **Impacto:** cola sin tendencia (R² 0,11), pero con picos que dominan la duración de `Silver to gold` (informe 01 H7).

### H4 · La ejecución 10 tarda más por la espera de ejecutores

- **Qué ocurre:** ejecución 10: sesión de 474 s, último ejecutor a los 332 s, primer job a los 333 s, tiempo activo de 82 s (E3). Las demás sesiones tienen el último ejecutor a los 105–193 s.
- **Por qué:** la API no da la causa (aprovisionamiento de nodos lento o capacidad). Sin evidencia de `capacityExceeded` en esa sesión (no consultado).
- **Impacto:** cierra el punto abierto del informe 01 H7 ("474 s de `runningDuration`, no verificado"): son ~330 s de espera de ejecutores, no más cómputo.

### H5 · Veredicto

- **Sobredimensionado en reserva y en memoria; ajustado solo en el único stage que se debe a la fragmentación.** Medido: 19,8 % de uso de la sesión, 29 % de tiempo con jobs, 4,7 GB de pico de heap frente a 112 g, spill 0, GC 1,5 %. Inferido: que el trabajo no fragmentado necesite pocos cores (concurrencia media 32 con la fragmentación; sin ella no medida).
- No es infradimensionado: no hay spill, GC alto ni sesiones fallidas (10 de 10 `Succeeded`, `2026-10-31/01` D2).

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Compactar `silver.customers` y, después, pasar gold a nodos Medium con asignación dinámica 1–5 | H1–H4 | Alto | Bajo | Medio | Sí |
| R2 | Si tras R1 el pico baja, reducir `maxExecutors` a 3 | H1, H5 | Medio | Bajo | Bajo | Sí |

### R1 · Compactar y redimensionar

- **Cambio propuesto:**
  1. Compactar `lh_silver.customers` (R1 del informe 02) antes del cambio de pool: así el stage 44 deja de necesitar cientos de tareas.
  2. En `env_gold`, usar el Starter Pool (precalentado) o un pool propio Medium con:

     ```json
     {
       "instancePool": { "name": "Starter Pool", "type": "Workspace" },
       "driverCores": 8, "driverMemory": "56g",
       "executorCores": 8, "executorMemory": "56g",
       "dynamicExecutorAllocation": { "enabled": true, "minExecutors": 1, "maxExecutors": 5 }
     }
     ```

     Pico = 5 × 8 = 40 cores de ejecutor (48 con el driver), como los 48 de hoy; memoria 56 g frente a 4,7 GB de pico medido. Es el mismo perfil que propuso `2026-10-31/01`.
- **Impacto esperado:** mismas fases activas con el mismo pico, cores liberados en los 200 s de espera y tramos entre jobs, y arranque en segundos si se usa el Starter Pool (bronze y silver arrancan en 3–13 s). Estimación; no se promete un ahorro en CU porque depende de la rampa de ejecutores.
- **Cómo validarlo:** tras 5 ejecuciones, repetir E3 para las nuevas sesiones: eficiencia de sesión > 0,5 (hoy 0,07–0,20, `SPARK-MONITORING-CORE.md` § Interpreting Resource Usage), cola y espera de ejecutores < 30 s (hoy 61–287 y 105–332 s), tiempo activo ≤ 82 s y stage de `customers` con decenas de tareas (hoy 608). Riesgo: la rampa de la asignación dinámica puede alargar la primera fase; en ese caso subir `minExecutors` a 2.
- **Reversión:** volver a publicar `env_gold` con `pool_gold_xl`, 16 cores y asignación dinámica desactivada.
- **Requiere confirmación:** Sí (publicar un environment y compactar una tabla son cambios que no hace el agente).

### R2 · Ajuste fino

- **Cambio propuesto:** si tras R1 la concurrencia máxima medida es < 24, bajar `maxExecutors` a 3 (como silver).
- **Cómo validarlo:** concurrencia máxima y duración de sesión (E3) sin empeorar respecto a la ejecución con 1–5.
- **Reversión:** volver a 1–5.
- **Requiere confirmación:** Sí.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Gold está infradimensionado | E3 | Spill 0 en las 10 sesiones; GC 1,5 %; memoria usada 4 % |
| D2 | El volumen de datos de gold explica el crecimiento de nb_03 | E3 | Sin el stage de `customers` el ejecutor es 556–679 s·tarea sin tendencia; la entrada crece 132 → 1.246 MB pero el stage pesado lee 69 MB |
| D3 | La cola crece con las ejecuciones | E3 | +8,6 s por ejecución, R² 0,11 |
| D4 | Gold necesita 48 cores sostenidos | E3 | Concurrencia media ponderada 32; 69 % de uso solo en el 29 % del tiempo |

## Siguientes pasos

- [ ] Aplicar R1 del informe 02 (compactar `customers`) — responsable: ingeniería de datos · relacionado con: R1
- [ ] Aprobar y publicar el cambio de pool en `env_gold` — responsable: `FabricAdmin` / dueño del workspace · relacionado con: R1
- [ ] Repetir E3 tras 5 ejecuciones — responsable: FabricPerfAnalyst · relacionado con: R1, R2

## Notas

### Limitaciones

- Concurrencia por stage = s·tarea de ejecutor / duración del stage (primer lanzamiento a finalización); es una media, no una medida instantánea. El tiempo activo es la unión de los intervalos de los jobs.
- Las 10 sesiones cubren ~12 h reales y 10 días de negocio; no distingo la variación por hora de la de volumen.
- No consulté `capacityExceeded` por sesión ni el uso de capacidad: la espera de ejecutores de la ejecución 10 queda sin causa.
- Coste en CU o moneda no calculado. El mapeo vCores ↔ CU no se usa aquí.
- El número de tareas del stage pesado sigue al número de ficheros; la identificación del stage con la lectura de `silver.customers` es medida (descripción del job), la relación causal con la fragmentación es inferencia apoyada en el informe 02.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Causa de la espera de ejecutores de 332 s (ejecución 10) | La API no la expone | H4 describe el síntoma |
| Rendimiento de `nb_03` sobre Medium con asignación dinámica | Requiere cambiar el entorno (Tier C) | Tamaño de R1 como estimación |

### Discrepancias entre skills y documentación

Sin discrepancias nuevas. Los umbrales de eficiencia (flag < 0,3, sano > 0,5) son los de `2026-10-31/01`.

## Anexo

Cálculos (E3): `Tiempo activo` = unión de `[submissionTime, completionTime]` de los jobs; `Último ejecutor listo` = `addTime` máximo de los ejecutores menos `startDateTime` de la sesión; `Primer job` = `submissionTime` mínimo menos `startDateTime`; s·tarea = suma de `executorRunTime` de los stages no `SKIPPED`. Tendencias por mínimos cuadrados sobre las 10 sesiones.
