# Configuración Spark por capa (bronze, silver, gold)

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-02 |
| **Áreas** | Spark resources → Spark runs → Delta tables |
| **Ámbito** | workspace `FabricPerfLab` · `env_bronze`, `env_silver`, `env_gold` y los notebooks `nb_01`, `nb_02`, `nb_03` |
| **Ventana analizada** | Sesiones Spark de la ejecución programada del 2-nov 05:00 UTC de `pl_daily_sales` |
| **Agente / host** | GitHub Copilot CLI · skills: fabric-perf-analysis, spark-cli, e2e-medallion-architecture |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Media |

## Resumen

- **Pregunta:** ¿Es correcta la configuración Spark de las tres capas, con broadcast y AQE desactivados?
- **Conclusión:** no. Silver desactiva AQE, `skewJoin` y el broadcast, y fija 2000 particiones de shuffle, en el environment y en el notebook. Bronze está configurado como capa de lectura, y le faltan las opciones que evitan archivos pequeños. Gold está sobredimensionado y también desactiva AQE.
- **Impacto:** `coreEfficiency` del 27,6 % en bronze y del 27,3 % en gold, ambos por debajo del 30 % (umbral HIGH); 77,5 % en silver. `sales_raw` tiene 4 400 archivos pequeños y el skew de `store_id` de `02-nb02-skew-joins-stages.md` se debe a la configuración de silver.
- **Primera acción:** R1, quitar de `env_silver` y de `nb_02` las cuatro propiedades que desactivan AQE, `skewJoin` y broadcast, y dejar de fijar `shuffle.partitions`. Requiere confirmación porque cambia un environment y un notebook.

## Alcance

**Pregunta original:** "Si está desactivado el broadcast y AQE, creo que la configuración no es correcta. Revísala para las tres capas: bronze, silver y gold"

Parte de `01-pl-daily-sales-crecimiento.md` y `02-nb02-skew-joins-stages.md`. Aquí los E#, H#, R# y D# vuelven a empezar en 1.

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Config publicada de los tres environments, config fijada en los notebooks, tamaño real de las sesiones y eficiencia de cores | Cambiar nada (solo propuestas); `Refresh semantic model` salvo mención; coste en moneda (sin precios en vivo) |

**Hipótesis de partida:** H-a la configuración de silver contradice su propia carga; H-b bronze y gold usan perfiles que no corresponden a su rol; H-c el tamaño de gold no se corresponde con su carga.

**Recorrido:** Spark resources (environments, tamaño, `resourceUsage`) → Spark runs (planes de `02`, que ya mostraban `SortMergeJoin` sin AQE) → Delta tables (archivos pequeños de bronze).

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Runtime | 1.3 en los tres environments | E1 |
| Pool bronze y silver | Starter Pool; 8 cores / 56 g en driver y executor; asignación dinámica 1–4 executors | E1 |
| Pool gold | `pool_gold_xl`; 16 cores / 112 g; asignación dinámica desactivada | E1 |
| Native Execution Engine | desactivado en los tres (definición del environment en el repo) | `demo-setup/items/environments/*.yml` |
| Notebook ↔ environment | Inferido por el tamaño de sesión (8×56 en nb_01 y nb_02, 16×112 en nb_03); no se leyó la definición de los notebooks | E2 |

### Items analizados

| Item | Tipo | Capa | ID |
|------|------|------|----|
| env_bronze | Environment | Bronze | ed7daf54-76f9-4505-8a11-9eed95f8accb |
| env_silver | Environment | Silver | 1cd0a99e-2c23-4c2f-8a9c-7f8a1a336358 |
| env_gold | Environment | Gold | b8c2f706-500a-4507-89fa-f460f81ce7d7 |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| `env_bronze` | profile `readHeavyForPBI`, V-Order `true`, `optimizeWrite=false`, `autoCompact=false` | `e2e-medallion-architecture/SKILL.md` § Environment Optimization: bronze write-heavy, V-Order off, autoCompact on | E1 |
| `env_silver` | AQE `false`, `skewJoin` `false`, `autoBroadcastJoinThreshold=-1`, `shuffle.partitions=2000`; sin perfil, V-Order ni `optimizeWrite` | misma sección: silver con V-Order y adaptive query execution | E1 |
| `env_gold` | profile `writeHeavy`, V-Order `false`, `optimizeWrite=false`; AQE sin fijar en el environment | misma sección: gold read-heavy, V-Order, Optimize Write, AQE | E1 |
| `nb_02` (líneas 14–17) | repite `shuffle.partitions=2000`, AQE `false`, `skewJoin` `false`, broadcast `-1` | | `nb_02_bronze_to_silver.py` |
| `nb_03` (línea 13) | `spark.conf.set("spark.sql.adaptive.enabled", "false")` | | `nb_03_silver_to_gold.py` |
| `nb_01` (línea 26) | `optimizeWrite.enabled=false`; `repartition(400)` y `append` en cada carga | | `nb_01_ingest_bronze.py` |
| `coreEfficiency` bronze / silver / gold | 0,276 / 0,775 / 0,273 | < 30 % = HIGH (`performance-patterns.md` § Detection Thresholds) | E2 |
| Gold: cores asignados | executors 16 cores × 3 y driver de 16 (sesión de `Silver to gold`) | | E2 |
| `sales_raw` | 4 400 archivos, 1 052 898 766 bytes, anomalía tipo 3 | | `01-pl-daily-sales-crecimiento.md`, E4 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces/{ws}/environments/{id}/sparkcompute` (×3) | Valores publicados de la tabla anterior |
| E2 | REST | `queryactivityruns` de la ejecución del 2-nov; `GET …/livySessions/{id}`; `GET …/applications/{app}/resourceUsage` (4 sesiones) | Tamaño de sesión y `coreEfficiency` (0,276; 0,775; 0,273; 0,0 la del refresh del modelo) |
| E3 | Web | Microsoft Learn, *Configure Resource Profile Configurations* | `writeHeavy`: V-Order `false`, `optimizeWrite` `null`; `readHeavyForPBI`: V-Order `true`; los workspaces nuevos usan `writeHeavy` |
| E4 | SQL | health metrics de `sales_raw` (del análisis 01) | 4 400 archivos |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | Silver desactiva AQE, skew join y broadcast y fija 2000 particiones, por duplicado | Alta | Alta | E1, `02-nb02-skew-joins-stages.md` |
| H2 | Bronze usa un perfil de lectura y no compacta al escribir | Media | Alta | E1, E3, E4 |
| H3 | Gold está sobredimensionado y desactiva AQE | Media | Media | E1, E2 |

### H1 · Silver

- **Qué ocurre:** `env_silver` y `nb_02` fijan los mismos cuatro valores (E1 y líneas 14–17 del notebook).
- **Por qué:** AQE y el broadcast están activos por defecto, así que son decisiones explícitas. Para silver, la guía de la skill pide V-Order y adaptive query execution. Con estos valores `stores` (50 filas) se redistribuye por hash, la tienda 1 (60 % de las filas) va a una sola partición y los 1,3 GB de shuffle se reparten en 2000 tareas de ~1 MB. Es la causa de H2 y H4 de `02-nb02-skew-joins-stages.md`.
- **Impacto:** unos 152 s de joins en la ejecución del 2-nov, y creciendo. El notebook repite en tiempo de ejecución lo que ya fija el environment, así que cambiar solo uno de los dos no tendría efecto.

### H2 · Bronze

- **Qué ocurre:** `env_bronze` aplica `readHeavyForPBI` con V-Order activado, y desactiva `optimizeWrite` y `autoCompact`. `nb_01` hace `repartition(400)` y `append` en cada carga.
- **Por qué:** bronze es una capa de ingesta. La skill pide para ella perfil write-heavy, V-Order desactivado y autoCompact activado; este environment hace lo contrario. 400 archivos por carga explican los 4 400 archivos pequeños de `sales_raw`, que el Advisor también señaló.
- **Impacto:** `coreEfficiency` de 27,6 % (HIGH), con un executor de 8 cores y 56 g para la ingesta, y lecturas más lentas en silver por los archivos pequeños. La parte de eficiencia es una inferencia: con un solo executor activo no hay cifras por stage.

### H3 · Gold

- **Qué ocurre:** `pool_gold_xl` con 16 cores / 112 g, asignación dinámica desactivada y 3 executors fijos, `coreEfficiency` de 27,3 % (HIGH). `nb_03` además desactiva AQE en la sesión. El perfil es `writeHeavy`, con V-Order y `optimizeWrite` desactivados.
- **Por qué:** `nb_03` escribe tablas pequeñas con `overwrite` y `coalesce(1)`; la capacidad fija no se aprovecha. La skill pide V-Order y Optimize Write para gold, pero el modelo `sm_sales` es Import (descripción del item, no verificada), así que V-Order no es crítico para su consumo; sí lo sería con Direct Lake o con el SQL endpoint.
- **Impacto:** gold ocupa 64 cores asignados con un 27 % de uso. No cuantifico el coste en CU ni en moneda: no se llamó a la API de precios.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Silver: quitar los cuatro overrides, activar AQE | H1 | Alto | Bajo | Bajo | Sí |
| R2 | Bronze: perfil write-heavy, sin V-Order, con `optimizeWrite`/`autoCompact` | H2 | Medio | Bajo | Bajo | Sí |
| R3 | Gold: dimensionar al uso y activar AQE | H3 | Medio | Bajo | Medio | Sí |

### R1 · Silver

- **Cambio propuesto:** en `env_silver` y en `nb_02`:

  ```yaml
  spark_conf:
    spark.sql.adaptive.enabled: 'true'
    spark.sql.adaptive.skewJoin.enabled: 'true'
    spark.sql.adaptive.coalescePartitions.enabled: 'true'
    spark.sql.parquet.vorder.default: 'true'
    spark.databricks.delta.optimizeWrite.enabled: 'true'
  ```

  Eliminar `autoBroadcastJoinThreshold` y `shuffle.partitions` (con AQE, las 200 por defecto se fusionan solas). Añadir `broadcast()` explícito en el join con `stores`. Publicar el environment y borrar las cuatro líneas de `nb_02`.
- **Impacto esperado:** broadcast de `stores`, tratamiento de la partición de `store_id = 1` y menos tareas de ~1 MB. Es una estimación; no hay medida.
- **Cómo validarlo:** en la siguiente ejecución, el plan de `nb_02` debe mostrar `AdaptiveSparkPlan` y `BroadcastHashJoin` para `stores`, y los jobs de join (152 s) deben bajar.
- **Reversión:** restaurar las cuatro propiedades en el environment y publicarlo.
- **Requiere confirmación:** Sí, publicar un environment y modificar un notebook.

### R2 · Bronze

- **Cambio propuesto:**

  ```yaml
  spark_conf:
    spark.fabric.resourceProfile: writeHeavy
    spark.sql.parquet.vorder.default: 'false'
    spark.databricks.delta.optimizeWrite.enabled: 'true'
    spark.databricks.delta.autoCompact.enabled: 'true'
  ```

  Quitar `spark.conf.set("...optimizeWrite.enabled", "false")` de `nb_01` y sustituir `repartition(400)` por un valor acorde con el volumen diario (~1 GB). Pasar a un executor menor o a una pool pequeña es opcional y no se ha medido.
- **Impacto esperado:** menos archivos nuevos por carga y escrituras más baratas sin V-Order; el efecto en duración no está medido.
- **Cómo validarlo:** `sys.sp_get_table_health_metrics` sobre `sales_raw` (los 4 400 archivos) y `coreEfficiency` de `nb_01`.
- **Reversión:** restaurar el environment anterior.
- **Requiere confirmación:** Sí, publicar un environment y modificar `nb_01`.

### R3 · Gold

- **Cambio propuesto:** quitar `spark.conf.set("spark.sql.adaptive.enabled", "false")` de `nb_03`; usar la pool por defecto, o activar la asignación dinámica con un máximo bajo, en lugar de `pool_gold_xl`; decidir V-Order y `optimizeWrite` según el consumidor (Direct Lake o SQL endpoint → activarlos; Import → mantenerlos desactivados).
- **Impacto esperado:** menos cores asignados con la misma carga; no se midió una configuración alternativa.
- **Cómo validarlo:** `coreEfficiency` de la sesión de `nb_03` (> 30 %) y su duración frente a 432 s.
- **Reversión:** volver a `pool_gold_xl` con las propiedades actuales.
- **Requiere confirmación:** Sí, cambia un environment y el tamaño de la capacidad usada.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Silver está limitado por el tamaño de sus executors | E2 | `coreEfficiency` de 77,5 %; el cuello es el plan, no los recursos |

## Siguientes pasos

- [ ] Aprobar y aplicar R1 y R2 — responsable: dueño del pipeline · relacionado con: R1, R2
- [ ] Confirmar el consumidor de gold (Import frente a Direct Lake) antes de decidir V-Order — responsable: dueño del modelo · relacionado con: R3
- [ ] Repetir el análisis tras aplicar R1–R3

## Notas

### Limitaciones

- La config es la publicada en los environments y la fijada en los notebooks del repo. No ejecuté `spark.conf.get` en Livy, así que no verifiqué el valor efectivo en tiempo de ejecución; el plan de `02` (sin `AdaptiveSparkPlan`) es coherente con AQE desactivado.
- No leí la definición de los notebooks desplegados ni el environment asignado a cada uno: lo inferí por el tamaño de sesión.
- La sesión de `Refresh semantic model` también reservó 8 cores con `coreEfficiency` de 0,0; queda fuera de alcance, pero merece revisión.
- Sin llamada a la API de precios, no hay cifras de coste en moneda.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Valores efectivos de `spark.conf` por sesión | No se ejecutó Livy | H1 se apoya en el environment, el notebook y el plan |
| Modo de almacenamiento de `sm_sales` | Solo la descripción del item | El criterio de V-Order en gold queda condicionado |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Optimize Write en gold | `e2e-medallion-architecture/SKILL.md` lo activa; `data-engineering-patterns.md` lo desactiva | Learn: `readHeavyForPBI` lo activa (E3) | Decidir según el consumidor |
| Clave de V-Order | `e2e-medallion-architecture` usa `spark.sql.parquet.vorder.default`; `data-engineering-patterns.md`, `spark.microsoft.delta.parquet.vorder.enabled` | Learn documenta `spark.sql.parquet.vorder.default` | Se propone la clave de Learn |
| autoCompact en silver | `data-engineering-patterns.md` lo activa en el bloque write-heavy | Sin dato en Learn en esta consulta | Solo se recomienda en bronze |
