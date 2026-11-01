# Por qué silver no hace broadcast ni trata el skew: configuración Spark efectiva de bronze, silver y gold

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-01 |
| **Áreas** | Spark runs → Spark resources (configuración) |
| **Ámbito** | workspace `FabricPerfLab` · `nb_01`, `nb_02`, `nb_03` en la ejecución 11 de `pl_daily_sales` (`524c4c37`); `env_bronze`, `env_silver`, `env_gold` |
| **Ventana analizada** | Ejecución del 2026-10-31 05:00 UTC; consultas del 2026-11-01 |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Alta (valores efectivos medidos); Media en la procedencia de cada valor en silver |

## Resumen

- **Pregunta:** "¿Por qué no hace broadcast ni ajusta el skew? Revisa la configuración efectiva de silver y, ya puestos, la de bronze y gold."
- **Conclusión:** en silver, `nb_02` desactiva a propósito las dos cosas, y el entorno `env_silver` hace lo mismo con los mismos valores. `autoBroadcastJoinThreshold=-1` impide cualquier broadcast, aunque `stores` tenga 50 filas. `spark.sql.adaptive.enabled=false` desactiva AQE, y con él el tratamiento de skew (`skewJoin` depende de AQE) y la fusión de particiones. Está medido en los planes: los 98 planes de silver no tienen `AdaptiveSparkPlan` ni `BroadcastExchange`, y todos reparten en 2.000 particiones (E3). Es el único de los tres que lo hace.
- **Comparación:** bronze trabaja con los valores por defecto de Fabric (AQE activo, 200 particiones, 25 MB de umbral de broadcast; sus planes llevan `AdaptiveSparkPlan`). Gold desactiva AQE en su notebook pero conserva el umbral de 25 MB y 200 particiones, y sí hace `BroadcastHashJoin` (E3). Lo que distingue a silver es el umbral en `-1` junto con AQE desactivado y 2.000 particiones (E1, E2).
- **Precisión sobre los informes previos:** el informe 01 atribuyó esos valores a `env_silver` y a `nb_02`; es correcto, pero no se puede probar cuál de los dos manda, porque ponen lo mismo. Tampoco la API de entorno de la aplicación Spark los muestra (ver H2).
- **Primera acción (requiere confirmación):** quitar de `nb_02` y de `env_silver` las cuatro propiedades (R1 del informe 01), con `F.broadcast(stores)` de respaldo (R1 del informe 03).

## Alcance

**Pregunta original:** "¿Por qué no hace broadcast ni ajusta el skew? Revisa la configuración efectiva de silver y, ya puestos, la de bronze y gold. 1. La causa de que `stores` (50 filas) no se haga broadcast y de que AQE/skewJoin no aparezca en los planes de silver. Distingue lo medido de lo inferido. 2. La configuración Spark efectiva de las tres capas, con spark.sql.adaptive.enabled, spark.sql.adaptive.skewJoin.enabled, spark.sql.adaptive.coalescePartitions.enabled, spark.sql.autoBroadcastJoinThreshold, spark.sql.shuffle.partitions, spark.sql.join.preferSortMergeJoin y el entorno/runtime. Indica de dónde sale cada valor: %%configure del notebook, environment, conf de sesión o por defecto. 3. Si hay diferencias entre capas, una tabla comparativa y cuál explica el comportamiento observado."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Propiedades Spark de las 3 sesiones de la ejecución 11, `sparkcompute` publicado y en staging de los 3 entornos, celdas `spark.conf.set` de los 3 notebooks, planes SQL de las 3 sesiones. | Consecuencias de rendimiento ya medidas (informes 01–03). Sesión de `nb_04`. |

**Informes previos:** 01 (E7 y E22: configuración por capa, recogida de forma resumida), 02 y 03 (planes y skew de silver). Aquí se mide la configuración efectiva en la sesión, no solo la declarada.

**Hipótesis:** (a) el `-1` y AQE desactivado explican la ausencia de broadcast y de tratamiento de skew en silver; (b) bronze y gold no comparten esa configuración; (c) la API de la aplicación Spark muestra todo lo que se aplicó.

**Recorrido:** Spark runs (planes SQL de las tres sesiones) → Spark resources (propiedades de aplicación, entornos, ajustes del workspace). Sin pivote adicional.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Runtime | 1.3 en los 3 entornos publicados (`runtimeVersion`). El ajuste del workspace dice `2.0` como versión por defecto, pero ningún notebook usa el entorno por defecto | E4, E5 |
| Pools | bronze y silver: Starter Pool (driver y ejecutor 8 cores, 56 g, dinámica 1–4). gold: `pool_gold_xl` (16 cores, 112 g, 3 ejecutores fijos) | E1, E4 |
| Entornos | Los tres notebooks están enlazados a su entorno en el metadato del `.ipynb`: `nb_01` → `env_bronze`, `nb_02` → `env_silver`, `nb_03` → `env_gold`. Los tres con publicación `Success` y staging igual a publicado | E4, E6 |
| Notebooks sin `%%configure` | Ninguno tiene celda `%%configure`; solo `spark.conf.set` | E6 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| `nb_01_ingest_bronze` / `env_bronze` | Notebook / Environment | Bronze | `4240632d-…` / `ed7daf54-76f9-4505-8a11-9eed95f8accb` |
| `nb_02_bronze_to_silver` / `env_silver` | Notebook / Environment | Silver | `4205418f-…` / `1cd0a99e-2c23-4c2f-8a9c-7f8a1a336358` |
| `nb_03_silver_to_gold` / `env_gold` | Notebook / Environment | Gold | `c7cca4b7-…` / `b8c2f706-500a-4507-89fa-f460f81ce7d7` |

## Evidencia

### Configuración efectiva por capa

Procedencia: **E** = propiedad de `sparkcompute` del entorno (publicado y en staging, E4); **N** = `spark.conf.set` en una celda del notebook (E6); **D** = valor por defecto de la plataforma, medido en las propiedades de la aplicación o en el plan (E1–E3); **P** = lo aporta el perfil de recursos (`spark.fabric.resourceProfile`, `Learn`, E7).

| Propiedad | Bronze (`nb_01`) | Silver (`nb_02`) | Gold (`nb_03`) |
|-----------|------------------|------------------|----------------|
| Runtime / pool | 1.3 · Starter Pool | 1.3 · Starter Pool | 1.3 · `pool_gold_xl` |
| `spark.sql.adaptive.enabled` | activo (los planes llevan `AdaptiveSparkPlan`): **D** | **false**: **E** + **N** (celda 1) | **false**: **N** (celda 2). `env_gold` no lo fija |
| `spark.sql.adaptive.skewJoin.enabled` | sin fijar (D: depende de AQE activo) | **false**: **E** + **N** | sin fijar: moot con AQE desactivado |
| `spark.sql.adaptive.coalescePartitions.enabled` | sin fijar (D) | sin fijar: moot con AQE desactivado | sin fijar: moot con AQE desactivado |
| `spark.sql.autoBroadcastJoinThreshold` | 26.214.400 B (25 MB): **D** | **-1**: **E** + **N** | 26.214.400 B (25 MB): **D** |
| `spark.sql.shuffle.partitions` | 200 (medido en los planes): **D** | **2000**: **E** + **N** | 200 (medido en los planes): **D** |
| `spark.sql.join.preferSortMergeJoin` | sin fijar (valor por defecto de Spark: `true`; inferido) | ídem | ídem |
| Perfil de recursos | `readHeavyForPBI`: **E** | `writeHeavy`: **D** | `writeHeavy`: **E** |
| V-Order por defecto | true: **E**/**P** | false: **D**/**P** | false: **E** |
| `optimizeWrite` (inicio de sesión) | true, `binSize` 1g: **P** (anula el `false` de `env_bronze`); `nb_01` lo pone a `false` en la celda 2: **N** | sin fijar (perfil `writeHeavy`, `binSize` 128) | sin fijar (el `false` de `env_gold` no aparece en E1) |
| Dynamic allocation | sí, 1–4 ejecutores | sí, 1–4 | **no**, 3 ejecutores fijos |

### Lo que muestran los planes (E3)

| Capa | Planes con `AdaptiveSparkPlan` | Particiones de las exchanges | Joins | `BroadcastExchange` |
|------|--------------------------------|------------------------------|-------|---------------------|
| Bronze | 75 de 186 (los demás son ejecuciones de Delta/sistema sin plan adaptativo) | 200 | sin joins | 0 |
| Silver | 0 en las sentencias 4–7 (98 planes) | 2.000 (y 64 por `repartitionByRange`) | solo `SortMergeJoin` | 0 |
| Gold | 0 | 200 | `BroadcastHashJoin` en la sentencia 5 | 1 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET …/notebooks/{nb}/livySessions/{livyId}/applications/{appId}/environment` × 3 (sesiones de `Ingest bronze`, `Bronze to silver`, `Silver to gold`) | Propiedades de aplicación. Ninguna sesión lista `spark.sql.adaptive.enabled`, `skewJoin`, `coalescePartitions`, `shuffle.partitions` ni `preferSortMergeJoin`. `autoBroadcastJoinThreshold` aparece en las tres con 26214400. Solo gold lleva `spark.fabric.environmentDetails` |
| E2 | Cálculo | Diferencias entre las propiedades de E1 | `resourceProfile`, V-Order, `optimizeWrite`, tamaños de driver y ejecutor y asignación dinámica |
| E3 | REST | `GET …/applications/{appId}/sql?details=true&planDescription=true&length=400` × 3 | Tabla de planes. Silver: informe 03 E4 completado con las 98 ejecuciones de las sentencias 4–7 |
| E4 | REST | `GET …/environments/{id}` y `…/sparkcompute` y `…/staging/sparkcompute` × 3 | `env_bronze`: autoCompact y optimizeWrite `false`, `readHeavyForPBI`, V-Order `true`. `env_silver`: AQE `false`, `skewJoin` `false`, umbral `-1`, particiones `2000`. `env_gold`: optimizeWrite `false`, `writeHeavy`, V-Order `false`. Publicación `Success` |
| E5 | REST | `GET …/spark/settings` | Runtime por defecto del workspace `2.0`; Starter Pool por defecto; alta concurrencia en pipelines desactivada |
| E6 | REST | `POST …/notebooks/{id}/getDefinition?format=ipynb` × 3 (LRO) | Entorno enlazado en el metadato; `nb_01` celda 2 `optimizeWrite=false`; `nb_02` celda 1 las cuatro `spark.conf.set`; `nb_03` celda 2 AQE `false`; ningún `%%configure` |
| E7 | Learn | `microsoft_docs_search` sobre perfiles de recursos | `readHeavyForPBI`: V-Order on, `optimizeWrite` on, `binSize` 1g. `writeHeavy`: V-Order off. La configuración de runtime tiene prioridad sobre la del entorno |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | Silver no hace broadcast ni tratamiento de skew porque tiene el umbral en `-1` y AQE desactivado, fijados a la vez en `env_silver` y en `nb_02` | Alta | Alta | E3, E4, E6 |
| H2 | La API de propiedades de la aplicación no refleja las propiedades de los entornos: no se puede probar con ella qué fuente aplicó cada valor | Media | Alta | E1, E4 |
| H3 | Gold también desactiva AQE (en el notebook), pero no pierde el broadcast; bronze y gold no explican el comportamiento de silver | Media | Alta | E1, E3, E6 |
| H4 | Los valores de silver no son un efecto colateral de un perfil: son decisiones explícitas y repetidas en dos sitios | Media | Alta | E4, E6 |

### H1 · El umbral en -1 y AQE desactivado explican las dos observaciones

- **Qué ocurre:** los planes de silver no contienen `AdaptiveSparkPlan` ni `BroadcastExchange` y reparten en 2.000 particiones (E3). Las propiedades están declaradas en `env_silver` (publicado y staging) y se vuelven a poner en la celda 1 de `nb_02` (E4, E6). Medido: AQE ausente en 0 de 98 planes, 2.000 particiones, `SortMergeJoin` en todos los joins (informe 03 E4).
- **Por qué (causa de lo medido):** con `autoBroadcastJoinThreshold=-1` Spark no puede elegir `BroadcastHashJoin` en ningún join sin pista explícita, ni siquiera para `stores` (50 filas). Con `spark.sql.adaptive.enabled=false` no hay `AdaptiveSparkPlan`, así que ni la optimización de skew join ni la fusión de particiones pequeñas pueden actuar; `skewJoin` solo opera dentro de AQE, por eso su propio valor `false` es redundante (documentación de Spark, no verificada aquí). Las 2.000 particiones fijas sin fusión explican los 2.000 ficheros por `MERGE` del informe 02. Que el `-1` y el estado de AQE sean la causa directa es **medido** (propiedad + plan); que `skewJoin` solo opera con AQE y que la ausencia de pista impide el broadcast es **conocimiento del motor, no medido aquí**.
- **Impacto:** el join con `stores` produce el data skew de 684 MB y 1.215 MB de shuffle (informe 03 H2, H4). Severidad Alta por esa relación.

### H2 · La API de la aplicación no lista las propiedades de los entornos

- **Qué ocurre:** E1 no incluye `spark.sql.adaptive.enabled`, `shuffle.partitions` ni `skewJoin` en la sesión de silver, aunque los planes muestran sus efectos (AQE ausente, 2.000 particiones). E1 tampoco lista `optimizeWrite=false` de `env_gold` ni `spark.fabric.environmentDetails` en bronze y silver, aunque el notebook declara su entorno (E6) y el perfil de `env_bronze` y su V-Order sí se aplicaron.
- **Por qué:** esa API devuelve propiedades de arranque de la aplicación. Los valores puestos en `spark.conf.set` durante la sesión (los de las celdas de `nb_02`) no son propiedades de arranque, y las del entorno no aparecen todas. Es una inferencia: no probé una sesión con y otra sin entorno.
- **Impacto:** para silver no puedo atribuir cada valor a una sola fuente. Lo medido es el valor efectivo (planes) y las dos fuentes declaradas con el mismo valor. Para quitarlo hay que cambiar las dos (R1).

### H3 · Gold y bronze no explican el comportamiento de silver

- **Qué ocurre:** gold pone `adaptive.enabled=false` en la celda 2 de `nb_03`, sin tocar el umbral, y su plan tiene un `BroadcastHashJoin` con `BroadcastExchange` (E3, E6). Bronze no tiene joins y sus planes llevan AQE (E3).
- **Por qué:** el umbral por defecto (25 MB) deja pasar al broadcast de dimensiones pequeñas, aun sin AQE. Silver añade el `-1`.
- **Impacto:** la diferencia que importa entre capas es el umbral y las 2.000 particiones, no el estado de AQE por sí solo. Gold tiene además 3 ejecutores de 16 cores sin asignación dinámica (informe `2026-10-31/01-gold-spark-sobredimensionado.md`).

### H4 · Una nota sobre precedencia entre perfil, entorno y notebook

- **Qué ocurre:** en bronze, `env_bronze` pone `optimizeWrite=false` y a la vez `readHeavyForPBI`, que activa `optimizeWrite` con `binSize` 1g. La sesión arranca con `optimizeWrite=true` (E1), y `nb_01` lo pone a `false` en la celda 2 (E6).
- **Por qué:** la documentación indica que la configuración de runtime tiene prioridad sobre la del entorno (E7); el perfil prevalece sobre la propiedad explícita del entorno en el arranque, según lo observado. No encontré documentación que fije el orden perfil frente a propiedad explícita; es una observación, no una regla confirmada.
- **Impacto:** no afecta al problema planteado, pero muestra que el valor de arranque no siempre coincide con el entorno declarado.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Quitar de `env_silver` y de `nb_02` las cuatro propiedades (AQE, `skewJoin`, umbral `-1`, 2.000 particiones) | H1, H2 | Alto | Bajo | Medio | Sí |
| R2 | Mantener `F.broadcast(stores)` como respaldo explícito | H1 | Medio | Bajo | Bajo | Sí |
| R3 | Decidir y documentar una sola fuente de configuración por capa | H2, H4 | Bajo | Bajo | Bajo | Sí |

### R1 · Quitar las cuatro propiedades en los dos sitios

- **Cambio propuesto:** en `env_silver`, borrar `spark.sql.adaptive.enabled`, `spark.sql.adaptive.skewJoin.enabled`, `spark.sql.autoBroadcastJoinThreshold` y `spark.sql.shuffle.partitions` de las propiedades Spark y publicar. En `nb_02`, borrar las cuatro `spark.conf.set` de la celda 1. Es la misma acción que R1 del informe 01.
- **Impacto esperado:** los planes recuperan `AdaptiveSparkPlan` y 200 particiones (o las que AQE decida); `stores` pasa a broadcast (25 MB) y desaparece la exchange por `store_id`. Estimación, no medida.
- **Cómo validarlo:** en la ejecución siguiente, repetir E3: planes de la sentencia 6 con `AdaptiveSparkPlan` y `BroadcastHashJoin` para `stores`; repetir el `taskSummary` de los stages equivalentes (informe 03 E5) con máx/mediana < 3×.
- **Reversión:** volver a poner las cuatro propiedades y republicar el entorno y el notebook.
- **Requiere confirmación:** Sí (publicar un entorno y editar un notebook son cambios; los hace una persona o `FabricAdmin`).

### R2 y R3

R2: `F.broadcast(stores_df)` (informe 03 R1) para no depender del umbral. R3: elegir entorno o celda, no ambos, y anotar el motivo; lo contrario deja valores contradictorios (H2, H4). Validar con una ejecución tras el cambio y repitiendo E1/E3. Reversión: restaurar el estado anterior. Requieren confirmación.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | El broadcast falla por un umbral mal calculado o el tamaño de `stores` | E3, E4 | El umbral no se calcula: está fijado en `-1`. En gold, con 25 MB, el broadcast funciona |
| D2 | AQE desactivado es lo que ocurre en todas las capas | E3 | Bronze tiene AQE activo (planes con `AdaptiveSparkPlan`) |
| D3 | El runtime por defecto del workspace (2.0) afecta a estas ejecuciones | E4, E5 | Los 3 entornos publicados usan 1.3 y los notebooks los referencian |

## Siguientes pasos

- [ ] Aplicar R1 en una ventana sin ejecuciones y repetir E3 — responsable: ingeniería de datos / `FabricAdmin` (entorno) · relacionado con: R1
- [ ] Acordar una sola fuente de configuración por capa — responsable: ingeniería de datos · relacionado con: R3

## Notas

### Limitaciones

- Los valores "sin fijar" de `coalescePartitions`, `skewJoin` (bronze, gold) y `preferSortMergeJoin` no aparecen en ninguna fuente consultada. Su valor por defecto es el del motor Spark, no lo he leído con `spark.conf.get`. No abrí una sesión Livy para ello: el efecto sí está medido en los planes.
- No puedo separar cuánto del `-1` y de AQE desactivado viene del entorno y cuánto del notebook en silver, porque la API de la aplicación no lista las propiedades del entorno y ambas fuentes ponen el mismo valor (H2).
- El análisis es de la ejecución 11 con el estado actual de entornos y notebooks; no comparé con ejecuciones anteriores.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| `spark.conf.get` de las propiedades sin fijar | Requiere una sesión Livy con el entorno de cada notebook; una sesión de Livy en el lakehouse no usa esos entornos | Valores por defecto de AQE/coalesce/`preferSortMergeJoin` inferidos del comportamiento de Spark y de los planes de bronze |
| Orden de precedencia perfil frente a propiedad del entorno | Learn solo documenta runtime > entorno | H4 como observación |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Fuente de verdad de la configuración efectiva | `SPARK-MONITORING-CORE.md` presenta la ruta `environment` de la aplicación como lectura de configuración | La ruta no incluye las propiedades del entorno ni los `spark.conf.set` de sesión (E1 frente a los planes) | Se usó el plan SQL como prueba del valor efectivo y `sparkcompute` como declaración |

## Anexo

Propiedades de aplicación comparadas (E1): se descartaron las que cambian por sesión (identificadores, hosts, URL, tokens). Diferencias relevantes entre capas: `spark.fabric.resourceProfile` (`readHeavyForPBI` / `writeHeavy` / `writeHeavy`), `spark.sql.parquet.vorder.default` (true / false / false), `spark.databricks.delta.optimizeWrite.enabled` (true con `binSize` 1g / sin fijar / sin fijar), `spark.dynamicAllocation.enabled` (true / true / false), `spark.executor.instances` (1 / 1 / 3), `spark.executor.cores` (8 / 8 / 16), `spark.executor.memory` (56g / 56g / 112g).

Tabla de planes (E3): para cada ejecución SQL se contó `AdaptiveSparkPlan`, las cifras de `hashpartitioning`/`rangepartitioning`, los operadores de join y `BroadcastExchange`, agrupadas por el número de sentencia del `jobGroup`.
