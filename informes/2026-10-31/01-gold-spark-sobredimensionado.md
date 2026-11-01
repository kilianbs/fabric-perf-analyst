# Dimensionado del clúster Spark de la capa gold (env_gold / pool_gold_xl)

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-10-31 |
| **Áreas** | Spark resources |
| **Ámbito** | workspace `FabricPerfLab` · env_gold, env_silver, env_bronze, pool_gold_xl, nb_03_silver_to_gold (contraste: nb_01, nb_02) |
| **Ventana analizada** | 2026-10-30 17:21 → 2026-10-31 05:23 UTC (últimas 10 sesiones de cada notebook) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** ¿Está sobredimensionado el clúster Spark de gold (env_gold, pool_gold_xl) frente al uso real de nb_03_silver_to_gold, y qué tamaño corresponde?
- **Conclusión:** Sí, en su configuración, no en su pico. Gold fija 48 cores durante toda la sesión (nodos Large de 16 cores, sin asignación dinámica) y las 10 últimas sesiones usan de media un 20,7 % de ellos, con un 82,7 % de tiempo ocioso. Cuando hay trabajo sí llena los 48 cores: el problema es que los retiene mientras no hay tareas. Además, el pool se llama `_xl` pero sus nodos son `Large`.
- **Impacto:** `coreEfficiency` medio 0,207 (umbral HIGH < 0,3) y `idleTime/duration` medio 0,827 (umbral MEDIUM > 40 %), con 10 de 10 sesiones fuera de umbral. Silver, en cambio, tiene eficiencia 0,702.
- **Primera acción:** R1, mover gold a nodos Medium (8 cores) con asignación dinámica 1–5 ejecutores. Mantiene el pico de 48 cores, de modo que no debería alargar las fases activas, y libera cores en los periodos ociosos.

## Alcance

**Pregunta original:** En el workspace FabricPerfLab, ¿está sobredimensionado el clúster de Spark que usa la capa gold (environment env_gold, pool pool_gold_xl)? Compara el tamaño de nodo, la asignación dinámica y los ejecutores configurados con el uso real de cores de las últimas sesiones de nb_03_silver_to_gold. Contrástalo con env_bronze y env_silver (sus pools y configuración) y propón el tamaño adecuado para la capa gold.

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Pools del workspace, sparkcompute de los 3 environments, 10 últimas sesiones Livy de nb_03 y, como contraste, de nb_01 y nb_02 | Causa del tiempo ocioso dentro del notebook (no se ejecutó Livy ni se analizaron stages); coste en moneda (no se consultó la API de precios); capacidad (Trial FTL64) |

**Hipótesis de partida:** H1 los nodos Large con asignación dinámica desactivada retienen cores sin uso; H2 gold necesita realmente los 48 cores (el pico los justifica); H3 el arranque en pool personalizado penaliza la sesión.

**Recorrido:** solo Spark resources. No hubo evidencia que justificara pivotar a spark-runs ni a capacity: no hay fallos y ninguna sesión quedó sin `appId`.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad (SKU · región) | FTL64 (Trial) · West Europe, activa | E4 |
| Runtime de Spark | Los 3 environments en 1.3; ajuste por defecto del workspace 2.0 | E3, E5 |
| Environment / pool | gold → `pool_gold_xl`; bronze y silver → Starter Pool | E5 |
| Configuración Spark relevante | Ver Anexo | E2, E5 |
| Permisos con los que se ejecutó | Sesión `az` del usuario; todas las llamadas devolvieron datos | E1–E7 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| env_bronze | Environment | bronze | ed7daf54-76f9-4505-8a11-9eed95f8accb |
| env_silver | Environment | silver | 1cd0a99e-2c23-4c2f-8a9c-7f8a1a336358 |
| env_gold | Environment | gold | b8c2f706-500a-4507-89fa-f460f81ce7d7 |
| pool_gold_xl | Pool de workspace | gold | 38ed5dc4-712e-4b6e-accf-d703ad0463c0 |
| nb_03_silver_to_gold | Notebook | gold | c7cca4b7-3722-4bec-9946-504520f6be21 |
| nb_01_ingest_bronze / nb_02_bronze_to_silver | Notebook | contraste | 4240632d-3ce1-422f-a1b2-ddb55d8736e0 / 4205418f-cee2-4a3d-9390-328618160264 |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Nodo de pool_gold_xl | MemoryOptimized **Large** (16 vCores = 8 CU), autoscale 1–4 nodos | `e2e-fabric-cost-estimation/SKILL.md` § Spark CU Mapping | E2 |
| Gold: asignación dinámica / ejecutores | **Desactivada**; executor 16 cores / 112g, driver 16 cores / 112g | `performance-patterns.md` § Capacity and Resource Diagnostics | E5 |
| Gold: cores asignados en sesión | 48 en el máximo de las 10 sesiones (24 CU) | — | E6 |
| Gold: `coreEfficiency` | media 0,207 (mín 0,121 · máx 0,290); 10/10 < 0,3 | HIGH < 0,3 (`diagnostic-workflow.md` § Severity Thresholds); sano > 0,5 (`SPARK-MONITORING-CORE.md` § Interpreting Resource Usage) | E6 |
| Gold: `idleTime/duration` | media 0,827 (mín 0,767 · máx 0,882) | MEDIUM > 40 % (mismo § Severity Thresholds); sano < 0,3 | E6 |
| Gold: cores en uso | media 13,6 de 48; mediana 0; entre 16 % y 39 % de los puntos con más de 16 cores; pico 48 | — | E6, E7 |
| Gold: duración media de sesión | 390 s; cola/arranque medio 115 s (61–287 s) | — | E6, E8 |
| Silver (Starter Pool) | nodos Medium (8 cores), dinámica 1–4, executor 8 cores/56g; eficiencia media 0,702, ocio 0,170; máximo asignado 24–32 | Sano > 0,5 y < 0,3 | E5, E6 |
| Bronze (Starter Pool) | misma configuración que silver; eficiencia media 0,264, ocio 0,612; máximo asignado 8–16 | Entre flag (0,3) y sano (0,5): Baja como mucho | E5, E6 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces` y `GET /v1/workspaces/{ws}/items` | Workspace FabricPerfLab `23ca4a73-…`; 3 lakehouses, 3 environments, 5 notebooks |
| E2 | REST | `GET /v1/workspaces/{ws}/spark/pools` | Starter Pool (Medium, 1–10 nodos, dinámica 1–9). pool_gold_xl (Large, 1–4 nodos, dinámica 1–3) |
| E3 | REST | `GET /v1/workspaces/{ws}/spark/settings` | Pool por defecto Starter Pool; `sessionTimeoutInMinutes` 20; runtime 2.0 |
| E4 | REST | `GET /v1/capacities` | FTL64, West Europe, Active |
| E5 | REST | `GET /v1/workspaces/{ws}/environments/{id}/sparkcompute` ×3 | Ver Anexo |
| E6 | REST | `GET .../notebooks/{nb}/livySessions` y `.../applications/{appId}/resourceUsage`, 10 sesiones por notebook (nb_03, nb_01, nb_02) | nb_03: eficiencia 0,207, ocio 0,827, asignado 48. nb_01: 0,264, 0,612, 8–16. nb_02: 0,702, 0,170, 24–32 |
| E7 | REST | Misma ruta `resourceUsage` de nb_03, distribución de `runningCores` | Mediana 0, p95 48, máximo 48 en las 10 sesiones; más de 16 cores entre 16 % y 39 % de los puntos |
| E8 | REST | `GET .../notebooks/{nb_03}/livySessions` (`queuedDuration`) | 76, 215, 76, 287, 61, 66, 137, 71, 98, 62 s (media 115 s) |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | Gold reserva hasta 48 cores sin asignación dinámica y los usa de media un 20,7 % | Alta | Alta | E5, E6, E7 |
| H2 | Gold no está sobredimensionado en pico: cuando trabaja usa los 48 cores | Baja | Alta | E7 |
| H3 | El nombre `pool_gold_xl` no corresponde al tamaño (es Large) | Baja | Alta | E2 |
| H4 | La cola/arranque de gold es de 115 s de media en pool personalizado | Baja | Baja | E8 |

### H1 · Cores reservados e inactivos en gold

- **Qué ocurre:** `dynamicExecutorAllocation.enabled=false` con ejecutores y driver de 16 cores (E5). Las 10 sesiones llegan a 48 cores asignados. La eficiencia es 0,121–0,290 y el ocio 77–88 % (E6). La mediana de cores en uso es 0 (E7).
- **Por qué:** la asignación estática con nodos Large deja los cores reservados durante las fases sin tareas. Silver, con dinámica 1–4 y nodos Medium, alcanza 0,702 de eficiencia, lo que apunta a la configuración como diferencia, aunque las cargas no son idénticas. La causa del ocio dentro del notebook (fases en el driver, lecturas, esperas) no se midió.
- **Impacto:** unos 390 s de sesión con hasta 24 CU reservados y un 20,7 % usado. No se calcula coste en moneda por no haber consultado precios en vivo.

### H2 y H3

El pico de 48 cores y los tramos con más de 16 cores impiden recortar el máximo sin más: un clúster fijo más pequeño alargaría las fases activas. Es una oportunidad de elasticidad, no de recorte del pico. El nombre del pool puede inducir a error al dimensionar (E2).

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Gold en nodos Medium con asignación dinámica 1–5 ejecutores | H1, H3 | Alto | Bajo | Bajo | Sí |
| R2 | Analizar por qué el notebook pasa 83 % ocioso (driver, I/O, esperas) | H1 | Medio | Medio | Bajo | No |
| R3 | Valorar Starter Pool para acortar el arranque | H4 | Bajo | Bajo | Bajo | Sí |

### R1 · Tamaño propuesto para gold

- **Cambio propuesto:** en env_gold, sustituir `pool_gold_xl` por Starter Pool (nodos Medium, como silver) o por un pool propio Medium, y activar la asignación dinámica:

  ```json
  {
    "instancePool": { "name": "Starter Pool", "type": "Workspace" },
    "driverCores": 8, "driverMemory": "56g",
    "executorCores": 8, "executorMemory": "56g",
    "dynamicExecutorAllocation": { "enabled": true, "minExecutors": 1, "maxExecutors": 5 }
  }
  ```

  Pico = 8 driver + 5 × 8 = 48 cores (igual al pico observado); mínimo = 16 cores. Si tras medir sobran cores, bajar `maxExecutors` a 3–4 (como silver).
- **Impacto esperado:** mismos 48 cores en las fases activas y cores liberados en las ociosas. No se promete cifra de ahorro: depende de cuánto ocio ocurra con ejecutores reservados, algo que R2 aclara. Hay que validar con un piloto. Un driver de 8 cores/56g podría quedarse corto si nb_03 hace trabajo pesado en el driver; no se midió.
- **Cómo validarlo:** repetir E6 y E7 tras 5–10 ejecuciones: `coreEfficiency` > 0,5, `idleTime/duration` < 0,3 y duración de sesión similar a los 390 s actuales.
- **Reversión:** volver a publicar el environment con el pool y la configuración actuales (Anexo).
- **Requiere confirmación:** Sí, es un cambio y publicación de environment (Tier C); lo aplica una persona o `FabricAdmin`.

### R2 · Origen del ocio

- **Cambio propuesto:** analizar stages y actividad del driver de una sesión de nb_03 (spark-runs), y mapear el ocio a statements con `resourceUsage?jobGroup=`. Solo lectura.
- **Cómo validarlo:** el ocio queda atribuido a statements concretos.
- **Requiere confirmación:** No.

### R3 · Arranque

- Pasar a Starter Pool (parte de R1) podría reducir los 115 s medios de cola/arranque. No se midió el arranque de bronze/silver: es hipótesis sin verificar. Confirmación: Sí, mismo cambio de environment.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Gold necesita 48 cores sostenidos | E6, E7 | Mediana de cores en uso 0; solo entre 16 % y 39 % del tiempo con más de 16 cores |
| D2 | Sesiones fallidas o con reintentos explican el ocio | E6, E8 | 10/10 sesiones `Succeeded` |

## Siguientes pasos

- [ ] Aprobar y aplicar R1 en env_gold (publicar environment) — responsable: dueño del workspace / FabricAdmin · relacionado con: R1
- [ ] Analizar el ocio de nb_03 por stage/statement — responsable: analista · relacionado con: R2
- [ ] Repetir el análisis tras aplicar R1 para validar el impacto

## Notas

### Limitaciones

- No se ejecutó Livy: la configuración y el uso de cores se obtuvieron por REST, sin necesidad de sesión. No se midió `spark.conf` efectiva de las sesiones.
- Solo 10 sesiones por notebook (ventana de unas 12 h); no refleja variaciones de volumen entre días.
- Los 48 cores asignados incluyen el driver (48 = 3 × 16); el desglose no se obtuvo de la API.
- Coste en moneda no calculado (no se llamó a la API de precios en vivo, `e2e-fabric-cost-estimation/SKILL.md` § Capacity SKU Tiers).
- Observación fuera de alcance: gold usa `writeHeavy`, V-Order desactivado y optimize write desactivado. Si gold se consume con Direct Lake, `readHeavyForPBI` sería preferible; no se verificó el consumo. Silver tiene AQE desactivado, `shuffle.partitions=2000` y broadcast desactivado, y bronze usa `readHeavyForPBI`: conviene revisarlos aparte.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Arranque de bronze/silver | No se consultó `queuedDuration` de sus sesiones | R3 queda como hipótesis |
| Causa del ocio de gold | Requiere análisis de stages | H1 mide el síntoma, no la causa |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Umbrales de eficiencia | Flag < 0,3 (`diagnostic-workflow.md`) | Sano > 0,5 (`SPARK-MONITORING-CORE.md`) | Gold (0,207) está bajo el flag. Bronze (0,264) también lo está en media; el criterio aplicado cita ambos umbrales |

## Anexo

### Consultas completas

Rutas REST de E1–E8 en la tabla de Evidencia (todas con cabecera `x-ms-fabric-skill: spark-cli`). `{ws}` = 23ca4a73-3312-4242-9714-0289816895aa.

### Configuración efectiva

| Parámetro | env_bronze | env_silver | env_gold |
|-----------|-----------|-----------|----------|
| Pool | Starter Pool (Medium) | Starter Pool (Medium) | pool_gold_xl (Large) |
| Driver | 8 cores / 56g | 8 cores / 56g | 16 cores / 112g |
| Executor | 8 cores / 56g | 8 cores / 56g | 16 cores / 112g |
| Asignación dinámica | 1–4 | 1–4 | Desactivada |
| Runtime | 1.3 | 1.3 | 1.3 |
| Otras propiedades | resourceProfile readHeavyForPBI, vorder true, autoCompact y optimizeWrite false | AQE y skewJoin false, autoBroadcast -1, shuffle.partitions 2000 | resourceProfile writeHeavy, vorder false, optimizeWrite false |

Pool `pool_gold_xl`: MemoryOptimized, Large, autoscale 1–4 nodos, dinámica 1–3 ejecutores (E2).
