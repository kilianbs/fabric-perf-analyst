# Uso de cores y sesiones Spark en pl_daily_sales: pool de gold y aprovechamiento de cada actividad

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-05 |
| **Áreas** | Spark resources → Spark runs |
| **Ámbito** | workspace `FabricPerfLab` · `pl_daily_sales` (`nb_01`, `nb_02`, `nb_03`, `nb_04`), pools `Starter Pool` y `pool_gold_xl` |
| **Ventana analizada** | 2026-10-30 17:11 → 2026-11-05 05:30 UTC (15 ejecuciones completadas, 60 sesiones); detalle de la ejecución del 5 nov 05:00–05:30 |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli |
| **Modo** | Solo lectura |
| **Severidad global** | Media |
| **Confianza global** | Alta (uso de cores y tiempos) / Media (estimaciones de dimensionamiento) |

## Resumen

- **Pregunta:** ¿está bien dimensionado el clúster de gold (`pool_gold_xl`, 3 ejecutores fijos de 16 cores) para `nb_03`? ¿Aprovechan las demás actividades las sesiones que abren, podrían compartir sesión, y el pool o tamaño es excesivo o corto?
- **Conclusión:** el clúster de gold está sobredimensionado para lo que hace. Eficiencia de cores 0,255 y 56 % de la sesión sin trabajo; solo un stage de 880 tareas llena los 48 cores, y el pico de memoria de ejecución es 13 GiB de 67 GiB por ejecutor. Pero el mayor desperdicio de `nb_03` es el arranque: 180 s desde que arranca la actividad hasta el primer job (34 % de su duración), con 61–287 s de cola de Livy por el pool propio. `nb_04` no usa Spark en absoluto (0 tareas) y pasa 144 s abriendo una sesión. `nb_02` es el único que aprovecha el clúster (eficiencia 0,70) y está en su techo de 4 ejecutores. `nb_01` usa ~3 de los 8–16 cores asignados, limitado por el driver.
- **Impacto:** de los 1.839 s de la última ejecución, ~180 s (`nb_03`) y ~144 s (`nb_04`) son arranque y espera, 18 % del pipeline. Compartir sesión (alta concurrencia) hoy no es posible: las cuatro actividades difieren en lakehouse por defecto y en proceso de cómputo.
- **Primera acción:** R1, sustituir `nb_04` por la actividad de refresco de modelo semántico del pipeline (sin Spark), que además espera el resultado. Después R2, redimensionar o unificar el pool de gold. Requieren confirmación.

## Alcance

**Pregunta original:** "(1) Gold usa otro pool (pool_gold_xl, 3 ejecutores fijos de 16 cores). ¿Ese clúster está bien dimensionado para lo que hace nb_03_silver_to_gold? Mide uso de cores/ejecutores (tiempo de ejecutor frente a tiempo de pared por stage, tareas concurrentes frente a cores disponibles, memoria pico por ejecutor, spill, tiempo ocioso entre jobs) y compara con el volumen real que procesa. (2) Revisa si las demás actividades del pipeline (nb_01, nb_02, nb_04 y las que haya) aprovechan las sesiones de Spark que abren: duración de sesión frente a tiempo de ejecutor útil, cores ociosos, arranque/cola, si podrían compartir sesión (high concurrency / session tag) o si el pool/tamaño es excesivo o corto."

**Informes previos:** `2026-11-05/01-pl-daily-sales-tendencia-crecimiento.md` (qué crece), `2026-11-05/02-nb02-skew-stages-joins.md` (skew y joins de `nb_02`) y `2026-11-05/03-config-spark-capas-y-direct-lake.md` (configuración por capa, pool de gold). Aquí se reutilizan sus datos de jobs y stages sin repetirlos.

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Las 4 actividades de `pl_daily_sales` (el pipeline no tiene otras), sus 60 sesiones, `resourceUsage`, ejecutores, stages y jobs, pools y configuración de alta concurrencia del workspace | Coste en CU o en dinero (no se consultó capacidad ni precios); `pl_store_snapshot` y `nb_05` |

**Hipótesis de partida:** H-a, el pool de gold tiene más cores y memoria de los que usa `nb_03` y los mantiene fijos. H-b, parte del tiempo de las actividades es arranque o espera, no cómputo. H-c, las sesiones no se pueden compartir porque difieren lakehouse y cómputo.

**Recorrido:** Spark resources (pools y configuración de gold, informe 03) → Spark runs (`resourceUsage`, ejecutores y stages de las 60 sesiones). Sin pivote adicional; un hallazgo lateral de refrescos del modelo se anota en H6.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad | `FTL64` (trial), West Europe | informe 03, E9 |
| Pool de silver y bronze | `Starter Pool` (Medium, MemoryOptimized, 8 cores por nodo): autoescalado 1–10 nodos, ejecutores dinámicos 1–9. Los environments limitan a 1–4 ejecutores | E5 |
| Pool de gold | `pool_gold_xl` (Large, 16 cores por nodo): autoescalado 1–4 nodos, ejecutores dinámicos 1–3. `env_gold` desactiva la asignación dinámica, y la sesión usa 3 ejecutores fijos | E5, informe 03 |
| Alta concurrencia | Pipeline desactivada (`notebookPipelineRunEnabled=false`); notebooks interactivos activada | E5 |
| Librerías en environments | Ningún environment tiene librerías publicadas | E6 |
| Runtime | 1.3 | informe 03 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| pl_daily_sales | DataPipeline | Orquestación | bd706b1d-499f-4a0d-bb22-222312944ca1 |
| nb_01 / nb_02 / nb_03 / nb_04 | Notebook | Bronze / silver / gold / refresco | 4240632d-… / 4205418f-… / c7cca4b7-… / 3a609552-… |

## Evidencia

### Métricas clave

Umbrales: `coreEfficiency` < 0,3 es HIGH y `idleTime/duration` > 0,4 es MEDIUM (`diagnostic-workflow.md` § Severity Thresholds, `performance-patterns.md` § Detection Thresholds); rangos sanos: eficiencia > 0,5 e idle < 0,3 (`SPARK-MONITORING-CORE.md` § Interpreting Resource Usage). Los valores entre ambos conjuntos son "ni marcados ni sanos" (severidad Baja como máximo, `spark-resources.md` § 5).

**Última ejecución programada (5 nov 05:00): sesión frente a trabajo útil (E2, E3)**

| Actividad | Sesión (s) | Idle (s) · ratio | Eficiencia de cores | Ejecutores · cores | Cores asignados medios / máx | Cores en uso medios / máx | Tiempo de tareas (s) | Valoración |
|-----------|-----------|------------------|---------------------|--------------------|------------------------------|---------------------------|----------------------|------------|
| nb_01 Ingest bronze | 244 | 133 · 0,54 | 0,327 | 3 · 8 | 8,3 / 16 | 2,9 / 8 | 675 | Idle > 0,4 (MEDIUM); eficiencia entre 0,3 y 0,5 (Baja) |
| nb_02 Bronze to silver | 849 | 101 · 0,12 | 0,702 | 5 (4 simultáneos) · 8 | 27,2 / 32 | 18,3 / 32 | 16.313 | Sano |
| nb_03 Silver to gold | 494 | 278 · 0,56 | 0,255 | 3 · 16 | 32,6 / 48 | 9,5 / 48 | 3.831 | Eficiencia < 0,3 (HIGH); idle > 0,4 (MEDIUM) |
| nb_04 Refresh model | 142 | 142 · 1,00 | 0,0 | 1 · 8 | 6,0 / 8 | 0 / 0 | 0 (0 jobs, 0 tareas) | Eficiencia < 0,3 (HIGH); idle > 0,4 |

El "5 ejecutores" de `nb_02` son los que pasaron por la sesión; el máximo asignado a la vez es 32 cores (4 ejecutores), igual que el máximo de `spark.dynamicAllocation.maxExecutors`.

**Tendencia de las ejecuciones completadas (15 ejecuciones, rango y última) (E2)**

| Actividad | Eficiencia | Idle/duración | Cola de Livy (s) |
|-----------|-----------|---------------|------------------|
| nb_01 | 0,195–0,327 (sin tendencia) | 0,50–0,63 | 0 |
| nb_02 | 0,639 → 0,702 (máx 0,783) | 0,12–0,25 | 0 |
| nb_03 | 0,121–0,347 (0,255 la última) | 0,56–0,88 | 61–287 (mediana 76; 62, 98, 71, 137, 66, 61, 287, 76, 215, 76, 102, 79, 81, 68, 61) |
| nb_04 | 0,0 | 1,0 | 0 en 8 ejecuciones (sesión caliente, 23–58 s en total) y 62–81 en 7 (127–159 s en total) |

**Gold (`nb_03`) en detalle: cores, tareas, memoria, spill y ocio (E2–E4)**

| Medida | Valor |
|--------|-------|
| Cores disponibles | 3 ejecutores × 16 = 48 cores (+16 del driver), fijos |
| Tareas concurrentes frente a cores | Máximo 48 en uso, alcanzado durante el stage de 880 tareas. 61 de 97 stages tienen menos de 48 tareas; mediana de tareas por stage: 5; solo 7 stages superan las 200 tareas |
| Tiempo de ejecutor frente a pared por stage | Suma de pared de stages 219 s; suma de ejecutor 3.635 s; eficiencia ponderada 0,347. El stage 48 (lectura de `silver.customers`, 28.149 ficheros) tiene 880 tareas, 178 s de pared y 3.078 s de ejecutor: el 85 % del ejecutor total, con eficiencia 0,36 incluso ahí |
| Distribución de la sesión (494 s) | 10 s sin cores asignados; 199 s con cores asignados y nada en ejecución; 100 s con < 25 % en uso; 12 s con 25–75 %; 99 s con ≥ 75 % |
| Ocio entre jobs | Jobs ocupados 216 s en un tramo de 315 s: 99 s sin ningún job activo (driver, comprobaciones `tableExists`, commits) |
| Arranque | Actividad empieza en +1.166 s; el `queuedDuration` de Livy es 61 s; el primer job de la celda 3 llega en +1.346 s, es decir, 180 s después del inicio de la actividad (34 % de sus 523 s) |
| Memoria pico por ejecutor | Memoria de ejecución en heap 13,0 GiB (máx. 67 GiB utilizables por ejecutor, 19 %); heap JVM máximo 4,8 GiB de 112 g |
| Spill | 0 (disco y memoria) |
| Volumen que procesa | Entrada 1.771 MB, shuffle 176 MB, salida 759 MB, 3.897 tareas, 63 jobs (informe 01) |

**Sesión, arranque y composición del pipeline (última ejecución, s desde el inicio del pipeline) (E1, E2, E4)**

| Actividad | Actividad (inicio–fin) | Sesión Livy: enviada → arrancada | Primer job | Duración |
|-----------|------------------------|-----------------------------------|------------|----------|
| nb_01 | 14–280 | arrancada 260 s antes del inicio del pipeline (cola 0) | – | 266 |
| nb_02 | 282–1.164 | arrancada 219 s antes del inicio (cola 0) | – | 882 |
| nb_03 | 1.166–1.689 | 1.172 → 1.234 (cola 61) | 1.346 | 522 |
| nb_04 | 1.692–1.836 | 1.699 → 1.780 (cola 81) | ningún job | 144 |

Las actividades se encadenan sin huecos (2–3 s entre una y otra): la duración del pipeline es la suma de las cuatro.

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces/{ws}/spark/livySessions` (informe 01, E5) y `queryactivityruns` (informe 01, E4) | Sesiones enviada/arrancada/cola de las 4 actividades |
| E2 | REST | `GET .../notebooks/{nb}/livySessions/{livy}/applications/{app}/resourceUsage` ×60 | Duración, tiempo ocioso, eficiencia y series de cores asignados y en uso; `capacityExceeded=false` en todas |
| E3 | REST | `GET .../applications/{app}/allexecutors` ×60 | Ejecutores, cores, memoria máxima y pico (`peakMemoryMetrics`), GC y tiempo de tareas |
| E4 | REST | `GET .../applications/{app}/jobs` y `/stages` (informe 01, E6) | Pared, ejecutor y número de tareas por stage; spill |
| E5 | REST | `GET /v1/workspaces/{ws}/spark/pools`, `/spark/settings` | Pools y alta concurrencia (ver Entorno) |
| E6 | REST | `GET /v1/workspaces/{ws}/environments/{id}/libraries` ×3 | `EnvironmentLibrariesNotFound` en los tres: sin librerías publicadas |
| E7 | Docs | Microsoft Learn: High concurrency mode in Apache Spark for Fabric; Configure high concurrency mode for Fabric notebooks in pipelines | Condiciones para compartir sesión (ver H5) |
| E8 | REST | `GET https://api.powerbi.com/v1.0/myorg/groups/{ws}/datasets/{sm_sales}/refreshes?$top=40` | Historial de refrescos del modelo (ver H6) |

No se ejecutó ninguna acción Tier B (ni Livy ni `ClearCache`).

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | El clúster de gold usa un 26 % de eficiencia de cores y le sobra cómputo y memoria; la asignación fija lo mantiene todo el tiempo | Media | Alta | E2, E3, E4 |
| H2 | `nb_03` pierde 180 s (34 %) en arranque antes del primer job; la cola de Livy del pool propio es de 61–287 s | Media | Alta (tiempos) / Baja (causa de los ~112 s tras la cola) | E1, E2 |
| H3 | `nb_04` abre una sesión Spark de 142 s sin ejecutar ningún job | Media | Alta | E1, E2, E3 |
| H4 | `nb_01` usa ~3 de los 8–16 cores asignados; está limitado por el driver, no por el clúster | Baja | Media | E2, E3 |
| H5 | `nb_02` es el único que usa el clúster y está en su techo de 4 ejecutores | Baja | Alta | E2, E3 |
| H6 | Las sesiones no pueden compartirse hoy (alta concurrencia) y aprovecharlo exige cambios de código | Informativo | Alta | E5, E7, informe 03 |
| H7 | Observación lateral: el refresco de `sm_sales` falla desde el 4 nov | Media | Alta | E8 |

### H1 · Gold sobredimensionado y fijo

- **Qué ocurre:** `nb_03` tiene 48 cores fijos y solo usa 9,5 de media (0,255 de eficiencia; el umbral HIGH es < 0,3). Pasa 199 s con cores asignados y nada en ejecución y 100 s con menos de un 25 % en uso; llena los 48 cores solo durante el stage de 880 tareas. Memoria de ejecución pico 13,0 GiB de 67 GiB por ejecutor y heap 4,8 GiB; spill 0. El volumen es modesto: 1.771 MB de entrada, 176 MB de shuffle, 3.897 tareas, y el 85 % del tiempo de ejecutor es una sola lectura de `silver.customers` con 28.149 ficheros.
- **Por qué:** 61 de 97 stages tienen menos tareas que cores (mediana 5), con 99 s sin ningún job activo entre ellos; son trabajo del driver y stages cortos que no paralelizan. El único stage grande lo causa la fragmentación de `customers` (informe 01, H2), no el volumen de datos. `env_gold` desactiva la asignación dinámica (informe 03, H3), así que los 3 ejecutores se mantienen todo el tiempo.
- **Dimensionamiento (estimación):** con 3.635 s de ejecutor, 32 cores (el techo de silver, 4×8) darían un mínimo teórico de ~114 s frente a ~76 s con 48 cores, es decir ~38 s más en el caso ideal, y la eficiencia real hoy es 0,35, así que la diferencia efectiva sería menor. Tras compactar `customers`, el stage grande se reduce y la necesidad de cores baja más. No se midió ningún tamaño alternativo; es una estimación basada en E3 y E4.
- **Impacto:** no afecta a la duración (el clúster no limita); sí a CU: 3 ejecutores de 16 cores + driver de 16 cores durante toda la sesión. El coste en CU no se midió. Severidad Media: el umbral de eficiencia da HIGH, pero el efecto en duración es nulo y el consumo no está medido.

### H2 · Arranque de nb_03

- **Qué ocurre:** la actividad empieza a los 1.166 s; la sesión de Livy se envía a los 1.172 s y arranca a los 1.234 s (cola de 61 s); el primer job aparece a los 1.346 s. De los 523 s de actividad, 180 s son anteriores al primer job. En 15 ejecuciones la cola de Livy de gold fue 61–287 s (mediana 76), sin tendencia creciente. En silver y bronze la cola fue 0.
- **Por qué:** el pool `pool_gold_xl` es propio y bajo demanda (`spark.fabric.pools.poolHit=false`, `category=OnDemand`, informe 03), no el Starter Pool precalentado. Los 61–287 s están dentro de lo esperado para un pool propio (2–5 min según `session-health.md` § Expected Startup Times, frente a 10–30 s del Starter Pool). Los ~112 s entre el arranque de la sesión y el primer job no tienen causa identificada: no hay librerías en el environment (E6) y la celda 1 es trivial.
- **Impacto:** 34 % de la duración de `nb_03` y 9,8 % del pipeline. Corrección al informe 01 (D2): allí se midió la cola como actividad menos `runStartTime` (4–27 s); `runStartTime` es el inicio de la ejecución del notebook, no el de la aplicación Spark, y esa fórmula no recoge la cola de Livy ni el tiempo hasta el primer job. D2 sigue siendo válido para la tendencia (no crece), pero el valor absoluto estaba infravalorado.

### H3 · nb_04 no usa Spark

- **Qué ocurre:** `nb_04` pide el refresco con `sempy` y ejecuta 0 jobs y 0 tareas en las 7 ejecuciones en que la sesión tuvo cola; la sesión de 142 s tiene idle 1,0 y eficiencia 0. Su duración depende solo del arranque: 23–58 s con sesión caliente (cola 0) y 127–159 s con cola de 62–81 s. De las 5 ejecuciones programadas, 4 han sido de 144–159 s (solo la del 2 nov fue de 38 s).
- **Por qué:** el notebook hace una única llamada REST al servicio del modelo y no procesa datos; Spark no aporta. Esto resuelve la variación de 38 a 159 s que el informe 01 dejó sin explicar (D4 y Notas): era cola de sesión.
- **Impacto:** 144 s de 1.839 (7,8 %) del pipeline y una sesión Spark completa para una llamada. Además, el notebook solo solicita el refresco y termina (los refrescos "ViaEnhancedApi" empiezan en el momento en que acaba la actividad, E8) y captura las excepciones con un `try/except` que solo imprime un aviso, así que el pipeline no espera ni se entera de que falla.

### H4 · nb_01 limitado por el driver

- **Qué ocurre:** `nb_01` asigna de media 8,3 cores y usa 2,9 (eficiencia 0,327, entre los dos conjuntos de umbrales: no marcado, no sano); 135 s de 244 con cores asignados y nada en ejecución; solo 86 s con ≥ 75 % en uso. Pico de 8 cores en uso de 16 asignados; heap 2,5–4,7 GiB.
- **Por qué:** 221 jobs y 30 `append` secuenciales de inventario en un bucle de Python (informe 01, H6) mantienen al driver como cuello de botella. Un ejecutor de 8 cores bastaría para el trabajo de ejecutor (675 s en 244 s, 2,8 tareas concurrentes de media); el tamaño no limita.
- **Impacto:** bajo; las 3 ejecuciones con 3 ejecutores no aceleran nada. La mejora está en el código (R4 del informe 01).

### H5 · nb_02 sin holgura

- **Qué ocurre:** eficiencia 0,70 (sana, > 0,5), idle 0,12 (sano, < 0,3), 32 cores asignados y 32 en uso durante 562 s de 849 (≥ 75 % de uso). GC total 129 s sobre 16.313 s de tareas (0,8 %); memoria de ejecución pico 8,6 GiB de 33,4 GiB; spill 0.
- **Por qué:** el clúster está en su techo de 4 ejecutores (`maxExecutors=4` del environment), con el Starter Pool permitiendo hasta 9. Pero el trabajo es innecesario en buena parte (9.264 s en relecturas de `customers`, informe 02), así que subir ejecutores acelera algo, aunque no ataca la causa.
- **Impacto:** no hay sobredimensionamiento; se arreglan primero R1 y R2 del informe 02 y se vuelve a medir.

### H6 · Compartir sesión no es posible hoy

- **Qué ocurre:** Learn (E7) exige para compartir sesión en un pipeline: mismo usuario, mismo lakehouse por defecto, misma configuración de cómputo, mismas librerías, y activar la alta concurrencia de pipeline en el workspace (hoy `notebookPipelineRunEnabled=false`) más una etiqueta de sesión en las actividades. Los cuatro notebooks difieren: lakehouse por defecto `lh_bronze`, `lh_silver`, `lh_gold` y ninguno en `nb_04`; environments distintos; `nb_03` en otro pool.
- **Valoración:** la alta concurrencia no acelera un pipeline de actividades secuenciales y dependientes; solo evita arranques. Beneficio máximo: los ~180 s de `nb_03` y los 62–81 s de cola de `nb_04` (en bronze y silver la cola ya es 0). Coste: unificar el lakehouse por defecto obligaría a calificar todas las escrituras (hoy `nb_02` y `nb_03` escriben tablas sin esquema ni lakehouse, que van al lakehouse por defecto de cada notebook), unificar environment y pool, y asumir una misma configuración de AQE y broadcast para todos. Es un cambio de diseño, no un ajuste.
- **Impacto:** informativo. Primero conviene R1 (sacar `nb_04` de Spark) y R2 (pool de gold).

### H7 · Observación lateral: refrescos del modelo

- **Qué ocurre:** los refrescos programados de `sm_sales` del 4 nov 05:30 y del 5 nov 04:30 y 05:30 están en estado Failed con "The 'category' column does not exist in the rowset". No hay refresco "ViaEnhancedApi" del 5 nov, y sí del 31 oct, 2, 3 y 4 nov.
- **Por qué:** coincide con el renombrado `category` → `product_category` de `dim_product` que hace `nb_03` cada 4.ª ejecución (informe 03, H5). No se analizó en profundidad.
- **Impacto:** el modelo se queda sin refrescar y el pipeline marca éxito porque `nb_04` solo solicita el refresco. Se anota para análisis aparte.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Sustituir `nb_04` por la actividad de refresco de modelo semántico del pipeline | H3, H7 | Medio | Bajo | Bajo | Sí |
| R2 | Redimensionar o eliminar el pool propio de gold y reactivar la asignación dinámica | H1, H2 | Medio | Bajo | Bajo | Sí |
| R3 | Esperar a corregir `nb_02` y `customers` antes de tocar el tamaño de silver o bronze | H4, H5 | Bajo | Bajo | Bajo | No |

### R1 · Refresco sin Spark

- **Cambio propuesto:** sustituir la actividad Notebook `nb_04` por la actividad "Semantic model refresh" del pipeline sobre `sm_sales`, con espera del resultado, o, si se mantiene el notebook, quitar el `try/except` que silencia el error y hacer que espere al estado final.
- **Impacto esperado:** quita ~144 s de duración (7,8 % de la ejecución del 5 nov) y una sesión Spark; el pipeline pasa a fallar cuando falla el refresco. Basado en E1, E2 y E8.
- **Cómo validarlo:** duración del pipeline y existencia de cada refresco en el historial del modelo (E8) tras la siguiente ejecución.
- **Reversión:** volver a la actividad Notebook.
- **Requiere confirmación:** Sí, cambia el pipeline.

### R2 · Pool de gold

- **Cambio propuesto:** que `nb_03` use el Starter Pool (como silver) o, si se mantiene un pool propio, un nodo `Medium` con asignación dinámica 1–3, y quitar `dynamicExecutorAllocation.enabled=false` de `env_gold`. Con el Starter Pool desaparecería la cola de 61–287 s; el tiempo hasta el primer job tras el arranque (~112 s) no tiene causa conocida y habría que revisarlo.
- **Impacto esperado:** gold dejaría de mantener 3 ejecutores de 16 cores y de esperar la cola del pool propio. Estimación: hasta ~60–180 s menos por ejecución en el arranque y menos CU; ver el cálculo de H1 para los cores. No medido.
- **Cómo validarlo:** `queuedDuration`, tiempo hasta el primer job y `resourceUsage` (eficiencia y idle) de `nb_03` en las siguientes ejecuciones; la duración de `nb_03` no debe subir.
- **Reversión:** volver a `pool_gold_xl` y a la asignación fija.
- **Requiere confirmación:** Sí, cambia un environment y requiere publicarlo; el tamaño correcto depende de si se adopta Direct Lake (informe 03, R3).

### R3 · Silver y bronze

- **Cambio propuesto:** no cambiar el tamaño de silver ni de bronze hasta aplicar los informes 01 y 02 (R1 y R2 del 02, R1 del 01) y repetir las medidas. Si después `nb_02` sigue en el techo con trabajo útil, valorar más ejecutores (el workspace admite 9).
- **Impacto esperado:** evita pagar más cómputo para un trabajo que hoy es en buena parte relectura.
- **Cómo validarlo:** repetir E2/E3 tras los cambios.
- **Reversión:** no aplica.
- **Requiere confirmación:** No (no es un cambio).

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Spill o presión de memoria en gold | E3, E4 | Spill 0; memoria de ejecución pico 13 GiB de 67 GiB por ejecutor |
| D2 | `nb_02` sobredimensionado | E2, E3 | Eficiencia 0,70, idle 0,12 y 32 cores en uso durante 562 s |
| D3 | La cola de Livy de gold crece con los días | E2 | 61–287 s sin tendencia en 15 ejecuciones |
| D4 | El resultado de `queryActivityRuns` ya medía bien el arranque | E1, E2 | `runStartTime` no incluye la cola de Livy (61 s en `nb_03`, 81 s en `nb_04`) |
| D5 | Las actividades comparten ya sesión | E1, E5 | Cada actividad tiene su propia sesión; alta concurrencia de pipeline desactivada |

## Siguientes pasos

- [ ] Sustituir `nb_04` por la actividad de refresco de modelo (R1) — responsable: ingeniería de datos · relacionado con: R1
- [ ] Decidir pool y tamaño de gold junto con la decisión sobre Direct Lake (R2) — responsable: dueño del modelo / `FabricAdmin` · relacionado con: R2
- [ ] Analizar aparte los refrescos fallidos de `sm_sales` desde el 4 nov — responsable: ingeniería de datos · relacionado con: H7
- [ ] Repetir E2/E3 tras aplicar los cambios de los informes 01 a 04

## Notas

### Limitaciones

- Solo se analizaron las 15 ejecuciones completadas del pipeline que conserva el monitor (desde el 30 oct 17:11); 9 de ellas son manuales encadenadas.
- No se midió coste en CU ni en dinero (no se consultó capacidad ni la API de precios); las afirmaciones sobre CU son cualitativas.
- Los tamaños alternativos de pool son estimaciones a partir del tiempo de tareas, no pruebas.
- El campo `startDateTime` de las sesiones de `nb_01` y `nb_02` es anterior al inicio del pipeline (4 y 5 minutos); no se investigó. Las colas de Livy de bronze y silver son 0.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Causa de los ~112 s entre el arranque de la sesión de gold y su primer job | Las rutas de lectura usadas no exponen la actividad de la sesión durante el arranque (no hay logs de Livy consultados) | H2 con confianza Baja en esa parte |
| CU consumidos por sesión | Fuera del alcance de la petición | No se cuantifica el ahorro de R1 y R2 en CU |
| Jobs ocupados frente a tramo para `nb_01` | Los jobs de calentamiento anteriores al inicio de la actividad falsean el tramo | El ocio de `nb_01` se mide con `resourceUsage` |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Cálculo de la cola de arranque | `spark-runs.md` § 5 la define como inicio de actividad menos `runStartTime` | `runStartTime` es el inicio del notebook; el `queuedDuration` de Livy (61–81 s) y el primer job (180 s) muestran un arranque mayor | Se usan `queuedDuration` de la sesión y el instante del primer job. Registrado también como corrección al informe 01 |
| Arranque esperado de pool propio | `session-health.md` § Expected Startup Times: 2–5 min para pool propio | Learn (E7): con alta concurrencia el arranque puede ser mucho más rápido | Se usó el rango de la skill como referencia |

## Anexo

### Consultas completas

- E2/E3: para cada sesión de las 4 actividades de las 15 ejecuciones completadas, `GET /v1/workspaces/23ca4a73-3312-4242-9714-0289816895aa/notebooks/{nb}/livySessions/{livy}/applications/{app}/resourceUsage` y `/allexecutors`, con cabecera `x-ms-fabric-skill: spark-cli`.
- Métricas derivadas: cores asignados medios y en uso = media ponderada por tiempo de `allocatedCores` y `runningCores`; distribución = segundos con 0 en ejecución, < 25 %, 25–75 % y ≥ 75 % de los asignados; ocio entre jobs = tramo entre el primer envío y la última finalización menos la unión de intervalos de jobs.

### Configuración efectiva

Ver informe 03 (tabla "Configuración Spark por capa"). Pools: `Starter Pool` (Medium, autoescalado 1–10, dinámico 1–9) y `pool_gold_xl` (Large, autoescalado 1–4, dinámico 1–3); `env_gold` fija 3 ejecutores.
