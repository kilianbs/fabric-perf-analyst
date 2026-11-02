# Dimensionamiento del pool de gold para `nb_03_silver_to_gold`

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-02 |
| **Áreas** | Spark resources → Spark runs |
| **Ámbito** | workspace `FabricPerfLab` · `pool_gold_xl`, `env_gold`, `nb_03_silver_to_gold` (sesión del 2-nov 05:18 UTC) |
| **Ventana analizada** | 2026-11-02 05:18:59 → 05:24:02 UTC |
| **Agente / host** | GitHub Copilot CLI · skills: fabric-perf-analysis, spark-cli, e2e-fabric-cost-estimation |
| **Modo** | Solo lectura |
| **Severidad global** | Media |
| **Confianza global** | Media |

## Resumen

- **Pregunta:** ¿Está bien dimensionado el clúster de gold para lo que hace `nb_03`?
- **Conclusión:** no, es excesivo. `pool_gold_xl` (nodos Large, 3 executors de 16 cores y 112 g fijos) procesa 1,3 GB de entrada y escribe 0,6 GB, y usa el 27 % de los cores asignados. Además, el arranque de este pool aporta 102 s de espera que las sesiones de los pools por defecto no tienen.
- **Impacto:** la sesión de `nb_03` ocupa unos 64 vCores durante 303 s, más CU que la de `nb_02` con ~2 nodos Medium durante 700 s, y solo 1 stage de 135 usa los 48 cores.
- **Primera acción:** R1, compactar `lh_silver.customers` (propuesta de `02-nb02-skew-joins-stages.md`), porque el único stage que justifica el paralelismo lee 660 archivos pequeños de esa tabla. Después, R2: pasar gold a un pool de nodos Medium con asignación dinámica. Ambas requieren confirmación.

## Alcance

**Pregunta original:** "Gold usa otro pool. ¿Ese clúster está bien dimensionado para lo que hace `nb_03_silver_to_gold`?"

Parte de `03-config-spark-por-capa.md` (H3). Aquí los E#, H#, R# y D# vuelven a empezar en 1.

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Configuración del pool y del environment, uso de cores, volumen de datos, stages y tiempos de la sesión del 2-nov | Otras ejecuciones de `nb_03` (solo se analizó esta sesión); precios en moneda; el modelo semántico |

**Hipótesis de partida:** H-a el pool es mayor de lo que necesita la carga; H-b el tiempo de la sesión se va en arrancar el pool, no en computar.

**Recorrido:** Spark resources (pool y `resourceUsage`) → Spark runs (jobs y stages de la sesión, para saber qué los usa) → Delta tables (la lectura de `customers`, que el análisis 02 ya había diagnosticado).

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Pool `pool_gold_xl` | nodos MemoryOptimized Large, autoscale 1–4 nodos, asignación dinámica 1–3 executors | E1 |
| `env_gold` | driver 16 cores / 112 g, 3 executors de 16 cores / 112 g, asignación dinámica desactivada | E1, `03-config-spark-por-capa.md` |
| Starter Pool (para comparar) | MemoryOptimized Medium, autoscale 1–10 nodos, hasta 9 executors | E1 |
| Sesión de `nb_03` | cola de 102 s, ejecución de 303 s | E2 |
| Sesiones de `nb_01` y `nb_02` | cola de 0 s | E2 |

### Items analizados

| Item | Tipo | ID |
|------|------|----|
| nb_03_silver_to_gold | Notebook | c7cca4b7-3722-4bec-9946-504520f6be21 |
| pool_gold_xl | Spark pool de workspace | 38ed5dc4-712e-4b6e-accf-d703ad0463c0 |
| Sesión del 2-nov | Livy / app | 0c97c780-b3bd-4c32-8d78-72ea80f755a2 · application_1793596735962_0001 |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| `coreEfficiency` | 0,273 | < 30 % = HIGH (`performance-patterns.md` § Detection Thresholds) | E3 |
| Tiempo ocioso / duración del recurso | 313 745 ms / 405 078 ms (77 %) | > 40 % = MEDIUM | E3 |
| Cores asignados | 0 → 16 → 32 → 48; 48 en la mayor parte de la sesión | | E3 |
| Muestras con ≥ 32 cores en ejecución | 70 de 193 (36 %); con algún core en ejecución, 95 (49 %) | | E3 |
| Entrada / salida / shuffle / spill | 1,31 GB / 0,61 GB / 0,14 GB / 0 | spill > 0 = MEDIUM | E4 |
| CPU total de los executors | 421 s en 2 898 s de tiempo de ejecución de tareas | | E4 |
| Stages: total / con ≤ 4 tareas / con ≥ 48 tareas | 135 / 48 / 49 | | E4 |
| Stage 52 | 660 tareas, 72 MB de entrada, 2 235 s de ejecución, 48,5 s de pared (el resto: ≤ 8,2 s cada uno) | | E4 |
| Suma de tiempos de pared de los stages | 98 s en 303 s de ejecución | | E4 |
| Tiempo por statement del notebook | 21 s, 20 s, 76 s y 9 s (126 s) | | E4 |
| Cola de la sesión | 102 s (frente a 0 s en bronze y silver) | | E2 |
| Pico de memoria de ejecución en un stage | ≈ 25,9 GB (suma de las tareas) | Memoria disponible: 3 × 112 GB | E4 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces/{ws}/spark/pools` | Configuración de `pool_gold_xl` y del Starter Pool |
| E2 | REST | `GET …/notebooks/{nb}/livySessions/{id}` (nb_01, nb_02, nb_03) | `queuedDuration` y `runningDuration` |
| E3 | REST | `GET …/applications/{app}/resourceUsage` (sesión de nb_03) | `coreEfficiency`, `idleTime`, cores asignados y en ejecución por muestra |
| E4 | REST | `GET …/applications/{app}/jobs`, `/stages`, `/advice` | 70 jobs, 135 stages; volumen, tiempos y un aviso del Advisor de archivos pequeños |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | El clúster de gold es mucho mayor que la carga | Media | Media | E1, E3, E4 |
| H2 | Lo que usa el paralelismo es la lectura de `customers`, no el cálculo de gold | Media | Alta | E4 |
| H3 | El pool propio añade 102 s de cola por sesión | Media | Media | E2 |

### H1 · Clúster sobredimensionado

- **Qué ocurre:** gold reserva 3 executors de 16 cores y 112 g, fijos, más un driver de 16 cores. Procesa 1,3 GB de entrada y escribe 0,6 GB, sin spill. Los cores asignados trabajan menos de la mitad del tiempo, y la CPU consumida (421 s) equivale a 1,4 cores de media durante los 303 s de la sesión.
- **Por qué:** `env_gold` desactiva la asignación dinámica, así que los 48 cores quedan reservados desde que arranca el primer job. El notebook solo lee tablas de silver y las reescribe con `overwrite`, con un único `groupBy`. Un stage usa el paralelismo (H2) y 48 de los 135 stages tienen 4 tareas o menos.
- **Impacto:** unos 64 vCores durante la sesión (driver + 3 executors; suposición: cada uno ocupa un nodo Large, 16 vCores = 8 CU según `e2e-fabric-cost-estimation/SKILL.md` § Spark CU Mapping), es decir ≈ 32 CU × 303 s ≈ 9 700 CU-s como cota superior. La sesión de `nb_02` (2 nodos de 8 cores, 700 s) ronda los 5 600 CU-s con la misma regla, aunque procesa más datos. No hay medida directa de CU facturados.

### H2 · Qué justifica el paralelismo

- **Qué ocurre:** el stage 52 tiene 660 tareas con solo 72 MB de entrada y tarda 48,5 s de pared; el siguiente stage más largo dura 8,2 s. Las tareas duran unos 3,4 s cada una.
- **Por qué:** lee `lh_silver.customers`, que tiene 21 104 archivos de unos 4,4 KiB (`02-nb02-skew-joins-stages.md`, E6). El coste es abrir archivos, no procesar datos, y con 48 cores se reparte en unas 14 oleadas. Que sea el statement que copia `customers` en `dim_customer` se infiere por la lectura y el volumen, no por un mapa explícito de stage a operador.
- **Impacto:** compactar `customers` reduce el trabajo y el paralelismo que gold necesita; resolverlo con más cores no corrige la causa.

### H3 · Cola de la sesión

- **Qué ocurre:** `nb_03` esperó 102 s antes de ejecutar, frente a 0 s en `nb_01` y `nb_02`, que usan el Starter Pool.
- **Por qué:** el pool propio no tiene nodos precalentados, y la sesión pide 4 nodos Large. Es una inferencia: no se midió un arranque con otra configuración.
- **Impacto:** 102 s de los 432 s que dura la actividad `Silver to gold` (24 %), sin trabajo útil.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Compactar `lh_silver.customers` (R1 del análisis 02) | H2 | Alto | Bajo | Bajo | Sí |
| R2 | Pasar gold al Starter Pool con asignación dinámica | H1, H3 | Medio | Bajo | Medio | Sí |

### R1 · Compactar `customers`

- **Cambio propuesto:** `REORG TABLE lh_silver.customers APPLY (PURGE); OPTIMIZE lh_silver.customers;` como en `02-nb02-skew-joins-stages.md`.
- **Impacto esperado:** el stage 52 pasaría de 660 tareas a una fracción; no medido.
- **Cómo validarlo:** repetir el stage de la lectura de `customers` en `nb_03` y su tiempo de pared (48,5 s).
- **Reversión:** no cambia los datos lógicos; `RESTORE` mientras no se haya hecho `VACUUM`.
- **Requiere confirmación:** Sí, es una escritura.

### R2 · Pool de gold

- **Cambio propuesto:** en `env_gold`, usar el Starter Pool (nodos Medium de 8 cores y 64 g) con asignación dinámica, por ejemplo 1–2 executors, en lugar de `pool_gold_xl` con 3 executors fijos:

  ```yaml
  instance_pool_id: null
  driver_cores: 8
  driver_memory: 56g
  executor_cores: 8
  executor_memory: 56g
  dynamic_executor_allocation:
    enabled: true
    min_executors: 1
    max_executors: 2
  ```

  Con la configuración de silver como referencia, que ya procesa más datos en ese tamaño. El pico de memoria de ejecución observado (~25,9 GB sumando tareas) cabe en 56 g; no se midió una ejecución con ese tamaño.
- **Impacto esperado:** menos cores reservados y sin la cola de 102 s; una estimación, no medida.
- **Cómo validarlo:** en la siguiente ejecución de `nb_03`, `queuedDuration`, `coreEfficiency` (> 30 %) y la duración de la actividad frente a 432 s.
- **Reversión:** volver a `instance_pool_id` de `pool_gold_xl` y a 3 executors fijos.
- **Requiere confirmación:** Sí, cambia un environment y el tamaño de la capacidad usada.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Gold necesita memoria alta | E4 | Sin spill y pico de ~25,9 GB frente a 336 GB reservados |
| D2 | La carga de gold es CPU-bound | E4 | 421 s de CPU en 2 898 s de tareas: el tiempo está en abrir archivos y en esperas, no en cómputo |

## Siguientes pasos

- [ ] Aplicar R1 antes de cambiar el pool, para dimensionar con el estado real de `customers` — responsable: dueño del pipeline · relacionado con: R1
- [ ] Probar R2 y repetir este análisis — responsable: dueño del pipeline · relacionado con: R2
- [ ] Revisar la sesión de `Refresh semantic model` (8 cores, `coreEfficiency` 0,0) — responsable: analista · relacionado con: H1

## Notas

### Limitaciones

- Solo se analizó una sesión de `nb_03` (2-nov). No hay línea base de otras ejecuciones ni de otros tamaños.
- Los 126 s de los statements y los 98 s de pared de stages no suman los 303 s de ejecución; el resto (inicio de sesión, esperas del driver) no se desglosó.
- El cálculo de CU supone un nodo por driver y por executor y no incluye la cola; no es un dato facturado. Sin llamada a la API de precios, no hay cifras en moneda.
- No se ejecutó ninguna prueba con otro tamaño de pool: las recomendaciones son estimaciones.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| CU facturados por sesión | Requiere Capacity Metrics, fuera de este análisis | El coste es una cota superior estimada |
| Mapa stage → operador | La API de stages no lo da; no se consultó el plan SQL | H2 es una inferencia por volumen y tamaño |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Uso de la tabla de dimensionamiento de `performance-patterns.md` | Orientativa | — | No se ha usado como límite medido |
