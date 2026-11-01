# Configuración de Spark por capa medallion (bronze, silver, gold) y compatibilidad de gold con Direct Lake

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-10-31 |
| **Áreas** | Spark resources → Delta tables → Semantic models (solo lectura del modo de almacenamiento) |
| **Ámbito** | workspace `FabricPerfLab` · `env_bronze`, `env_silver`, `env_gold`, `nb_01_ingest_bronze`, `nb_02_bronze_to_silver`, `nb_03_silver_to_gold`, tablas de `lh_bronze`, `lh_silver`, `lh_gold`, `sm_sales` |
| **Ventana analizada** | 2026-10-30 17:20 → 2026-10-31 05:23 UTC (histórico de ejecuciones); configuración efectiva medida en las últimas sesiones, 2026-10-31 04:59 → 05:23 UTC |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, spark-cli, semantic-model-authoring |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** ¿Es correcta la configuración de Spark de cada capa medallion (declarada en el environment, sobrescrita con `spark.conf.set` y efectiva) frente a lo que necesita la carga, y está gold preparada para que `sm_sales` pase a Direct Lake?
- **Conclusión:** No es correcta en ninguna de las tres capas. Bronze está configurada como lectura para Power BI (V-Order activado, perfil `readHeavyForPBI`) cuando es una capa de escritura, y el notebook solo desactiva optimize write, sin compactación (4.000 archivos de ~239 KB en `sales_raw`). Silver desactiva AQE, skew join y broadcast y fija 2.000 particiones de shuffle, en el environment y otra vez en el notebook, lo que deja tablas con miles de archivos diminutos (`inventory_levels` 2.000 archivos, `customers` 6.313). Gold usa `writeHeavy` con V-Order desactivado y AQE desactivado, sobre un clúster fijo de 48 cores con eficiencia de cores 0,29. Gold hoy no cumple los requisitos de Direct Lake: 0 de 64 archivos de `fact_sales` con V-Order y ~156.000 filas por row group frente a 1–16 millones recomendadas.
- **Impacto:** Sin fallos de ejecución ni spill. Efectos medidos: 4.000 + 2.000 + 6.313 + 608 archivos pequeños en tablas que leen otras capas y el endpoint SQL, `idleTime/duration` de 0,50 (bronze) y 0,78 (gold), y un riesgo de rendimiento degradado, no de caída, si `sm_sales` pasa a Direct Lake sin corregir gold (las barreras de capacidad F64 no se superan).
- **Primera acción:** R1 (quitar de `env_silver` y de `nb_02` las cuatro sobrescrituras para recuperar AQE, skew join y broadcast). Esperado: desaparece la causa de los archivos diminutos y baja el shuffle. Requiere confirmación.

## Alcance

**Pregunta original:** "¿La configuración de Spark de cada capa de la arquitectura medallion es correcta? Para bronze, silver y gold, haz una tabla con lo declarado en el environment, lo que sobrescribe el notebook con spark.conf.set y lo efectivo, frente a lo que necesita la capa según su carga. Gold la consume sm_sales; ten en cuenta que podría pasar a Direct Lake."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Los tres environments (compute publicado y propiedades Spark), las tres notebooks de capa (`spark.conf.set` y environment asociado), la última sesión de cada notebook (SparkConf al arrancar, resource usage, stages, planes SQL, executors), el layout físico de las 20 tablas Delta de las tres lakehouses y el modo de almacenamiento de `sm_sales` | Skew y tiempos por tarea de `nb_02` (corresponde a `spark-runs.md`); cambio concreto de tamaño de pool de gold (ya tratado en `2026-10-31/01-gold-spark-sobredimensionado.md`); migración del modelo a Direct Lake (autoría); coste en moneda (no se consultó la API de precios); `nb_04` y `nb_05` |

**Hipótesis de partida:** H-a las sobrescrituras de los notebooks repiten o contradicen al environment y la sesión usa los valores del notebook; H-b alguna sobrescritura intenta cambiar una configuración fija al arrancar la sesión y se ignora; H-c las capas están configuradas al revés de lo que pide su carga (bronze lectura, gold escritura); H-d gold no cumple los requisitos de layout de Direct Lake.

**Recorrido:** Spark resources (environments, sesiones, SparkConf efectivo) → Delta tables, porque la configuración efectiva solo se demuestra por su huella en los archivos escritos (`_delta_log` y footers Parquet) → Semantic models, solo para leer el modo de almacenamiento de `sm_sales` y contrastar con los requisitos de Direct Lake.

**Ejecuciones de diagnóstico (Tier B) no realizadas:** no se creó sesión Livy. Una sesión Livy por defecto no puede adjuntar el environment de cada capa ni sus pools, así que `spark.conf.get` devolvería la configuración del workspace y no la de las capas; la configuración efectiva real se leyó de las sesiones ya ejecutadas (E8) y `DESCRIBE DETAIL` / `SHOW TBLPROPERTIES` no aportaban nada que no diera ya el `_delta_log` (E13). Ningún resultado de Livy podía cambiar una conclusión.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad (SKU · región) | Trial FTL64 · West Europe (equivalente a F64/FT1 en la tabla de barreras de Direct Lake) | E3, E17 |
| Runtime de Spark | Environments en 1.3; el workspace tiene por defecto 2.0 | E5, E4 |
| Environment / pool | bronze y silver: Starter Pool, nodo 8 cores / 56 g, asignación dinámica 1–4 executors. gold: `pool_gold_xl`, 16 cores / 112 g, asignación dinámica desactivada, 3 executors fijos | E5, E8 |
| Modo de almacenamiento del modelo | `sm_sales`: Import en las 6 tablas, origen `Sql.Database` sobre el endpoint SQL de `lh_gold` | E15 |
| Permisos con los que se ejecutó | Usuario con acceso de lectura a items, `getDefinition`, Spark monitoring y OneLake del workspace | E1–E15 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| env_bronze | Environment | bronze | ed7daf54-76f9-4505-8a11-9eed95f8accb |
| env_silver | Environment | silver | 1cd0a99e-2c23-4c2f-8a9c-7f8a1a336358 |
| env_gold | Environment | gold | b8c2f706-500a-4507-89fa-f460f81ce7d7 |
| nb_01_ingest_bronze | Notebook | bronze | 4240632d-3ce1-422f-a1b2-ddb55d8736e0 |
| nb_02_bronze_to_silver | Notebook | silver | 4205418f-cee2-4a3d-9390-328618160264 |
| nb_03_silver_to_gold | Notebook | gold | c7cca4b7-3722-4bec-9946-504520f6be21 |
| lh_bronze / lh_silver / lh_gold | Lakehouse | capas | 53249a1b-e8a9-4270-9cb4-0f2ce3b10feb / b01f7911-28fd-4dc2-ac51-1d19ed841238 / 3aee923d-121b-415b-872c-4d5bb70664c0 |
| sm_sales | SemanticModel | consumidor de gold | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |

## Evidencia

### Tabla por capa: declarado, sobrescrito, efectivo y necesidad

"Efectivo" es lo observado: SparkConf al arrancar la sesión (E8) más la huella de lo escrito (E10, E11, E13, E14). El notebook se ejecuta después de arrancar, así que sus `spark.conf.set` no aparecen en el SparkConf inicial y se demuestran por sus efectos.

| Capa | Declarado en el environment | Sobrescrito con `spark.conf.set` en el notebook | Efectivo (con evidencia) | Necesidad de la capa según su carga | Veredicto |
|------|-----------------------------|--------------------------------------------------|--------------------------|--------------------------------------|-----------|
| **Bronze** (`nb_01`: ingesta append de 1 M filas/día, `repartition(400)`, ~96 MB escritos por ejecución) | Perfil `readHeavyForPBI`; `spark.sql.parquet.vorder.default=true`; `optimizeWrite.enabled=false`; `autoCompact.enabled=false`. Compute: Starter Pool, 8 cores / 56 g, dinámica 1–4 (E5) | `spark.databricks.delta.optimizeWrite.enabled=false` (repite lo del environment) (E6) | Perfil `readHeavyForPBI` al arrancar; V-Order **activo** (4.000 de 4.000 archivos con etiqueta V-Order, propiedad de tabla `delta.parquet.vorder.enabled=true`); optimize write **desactivado** al escribir (400 archivos de ~239 KB por ejecución; en el SparkConf inicial figuraba `true` por el perfil, y el notebook lo desactiva); auto compact sin establecer; AQE activo (21 de 50 planes con `AdaptiveSparkPlan`) (E8, E11, E13, E14) | Perfil `writeHeavy`, V-Order desactivado (nadie lee bronze con Power BI), compactación automática para no acumular archivos; compute pequeño (heap pico 4,1 GB, 4 de los 8 cores medios sin uso) | **Incorrecta.** Perfil y V-Order al revés de la carga, sin compactación. El `spark.conf.set` del notebook solo tapa uno de los efectos del perfil |
| **Silver** (`nb_02`: dedup por ventana sobre 10 M filas de bronze, MERGE de clientes, join con 50 tiendas, reescritura completa) | AQE `false`; skew join `false`; `autoBroadcastJoinThreshold=-1`; `shuffle.partitions=2000`. Sin perfil propio. Compute: Starter Pool 8 cores / 56 g, dinámica 1–4 (E5) | Las cuatro anteriores otra vez, con el mismo valor (E6) | Perfil `writeHeavy` (por defecto del workspace) con V-Order desactivado (0 de 64 archivos de `silver.sales`); AQE **desactivado** (0 planes de sentencias de usuario con `AdaptiveSparkPlan`); 19 stages de 2.000 tareas; 4 `SortMergeJoin` y ningún broadcast en la muestra; shuffle de hasta 1.872 MB por stage; sin spill (E8, E10, E11, E13) | AQE y skew join activos (60 % de las ventas son de `store_id = 1`, E6), umbral de broadcast por defecto (25 MB, `stores` tiene 50 filas), particiones de shuffle ajustadas al volumen (~1.872 MB / ~200 MB por partición ≈ 10, cálculo propio con la regla de E19); V-Order desactivado salvo que Direct Lake lea silver | **Incorrecta.** Compute y perfil bien; las cuatro sobrescrituras son perjudiciales y están duplicadas |
| **Gold** (`nb_03`: sobrescritura completa del esquema estrella y de `daily_store_sales`; 10 M filas, 549 MB; lo consume `sm_sales` en Import vía endpoint SQL) | Perfil `writeHeavy`; `vorder.default=false`; `optimizeWrite.enabled=false`. Compute: `pool_gold_xl`, 16 cores / 112 g, dinámica **desactivada**, 3 executors fijos = 48 cores (E5) | `spark.sql.adaptive.enabled=false` (E6) | `writeHeavy`; V-Order **desactivado** (0 de 64 archivos de `fact_sales`); optimize write sin establecer; AQE **desactivado** (0 de 50 planes con `AdaptiveSparkPlan`); 48 cores fijos con `coreEfficiency` 0,29 e idle 77,6 %, heap pico 4,7 GB de 72 GB; layout: `dim_customer` 608 archivos de ~10 KB, `daily_store_sales` 185 de ~3 KB (E8, E9, E11, E12, E13) | Con `sm_sales` en Import: V-Order desactivado es válido, pero AQE y optimize write activos (evitar archivos diminutos al endpoint SQL) y compute pequeño. Con Direct Lake: V-Order activado (o `readHeavyForPBI`), optimize write activo, row groups de 1–16 M filas, pocos archivos grandes, AQE activo | **Incorrecta para ambos modos.** Sobredimensionada y con AQE apagado; **no apta para Direct Lake** hasta corregir V-Order y layout |

### Qué se puede cambiar con `spark.conf.set` y qué es fijo al arrancar la sesión

Clasificación según Learn (E19, E16) y comprobación en los notebooks (E6). Ninguna de las sobrescrituras de los notebooks toca una configuración fija: todas son de runtime y tienen efecto demostrado.

| Configuración | ¿`spark.conf.set` en runtime? | Dónde se fija | Uso en este workspace |
|---------------|-------------------------------|---------------|------------------------|
| `spark.sql.adaptive.enabled`, `spark.sql.adaptive.skewJoin.enabled`, `spark.sql.autoBroadcastJoinThreshold`, `spark.sql.shuffle.partitions` | Sí: Learn indica que solo `spark.sql.*` se puede cambiar en runtime | environment o notebook | `nb_02` (cuatro) y `nb_03` (AQE) las cambian y se observan los efectos: stages de 2.000 tareas y ausencia de `AdaptiveSparkPlan` (E10, E11) |
| `spark.sql.parquet.vorder.default` | Sí (sesión; Learn la documenta como clave de sesión) | perfil, environment o notebook | Fijada por el perfil/environment; ningún notebook la toca |
| `spark.databricks.delta.optimizeWrite.enabled`, `autoCompact.enabled` | Sí (configuración Delta de sesión) | perfil, environment o notebook | `nb_01` la desactiva en runtime y el efecto es visible (400 archivos de 239 KB por ejecución, E10, E13) |
| `spark.fabric.resourceProfile` | Sí: Learn documenta `spark.conf.set("spark.fabric.resourceProfile", ...)` y que el runtime tiene precedencia sobre el environment | environment o notebook | Solo en environments |
| `spark.executor.*`, `spark.driver.*` (cores, memoria), `spark.executor.instances` | **No**: se leen al lanzar sesión o executors y `spark.conf.set` no los cambia | `%%configure` en la primera celda o environment | Solo en environments (gold 16 cores / 112 g) |
| `spark.dynamicAllocation.*`, pool, tamaño de nodo, versión de runtime | **No** (Learn no cita `dynamicAllocation` en la lista literal; se trata como fijo al arrancar por ser configuración de compute del environment, confianza Media) | environment / pool | Gold: dinámica desactivada y 3 executors fijos en el environment |
| `spark.native.enabled` (motor nativo) | No es fiable a mitad de sesión (`spark-resources.md` § Known traps) | environment o primera celda | `false` en las tres capas |

### Compatibilidad de gold con Direct Lake (hoy `sm_sales` está en Import)

Requisitos de Learn (E16–E18, E20) frente a lo medido en `lh_gold` (E13, E14, E15). Barreras para la capacidad actual: Trial FTL64, tratada como F64/FT1 (5.000 archivos, 5.000 row groups, 1.500 M filas por tabla).

| Criterio | Requisito | Medido | Veredicto |
|----------|-----------|--------|-----------|
| V-Order | Activado en tablas Spark leídas por Direct Lake, o perfil `readHeavyForPBI` | 0 de 64 archivos de `fact_sales` y 0 de todos los archivos de gold con etiqueta V-Order; sin propiedad `delta.parquet.vorder.enabled`; perfil `writeHeavy` | No cumple |
| Tamaño de row group | 1–16 M filas por row group; los significativamente por debajo de 1 M causan problemas | `fact_sales`: 1 row group por archivo, 64 en total, media 156.250 filas (muestra de tres archivos: 187.484–200.637). `dim_customer`: 608 archivos con 1.845–1.935 filas cada uno | No cumple |
| Número de archivos y row groups | Por debajo de la barrera de la SKU y pocos archivos | `fact_sales` 64, `dim_customer` 608, `daily_store_sales` 185, resto ≤ 8; barrera F64: 5.000 | Cumple la barrera, no el criterio de pocos archivos grandes |
| Filas por tabla | ≤ 1.500 M (F64) | `fact_sales` 10 M | Cumple |
| Optimize write / compactación | Evitar archivos pequeños (Learn: layout de Spark + V-Order) | Sin optimize write ni auto compaction; AQE desactivado en `nb_03` | No cumple |
| Patrón de actualización | Preferir escrituras que añaden, para framing incremental | `mode("overwrite")` + `overwriteSchema=true` de todas las tablas en cada ejecución: Direct Lake recargaría las columnas de cada tabla completa tras cada ejecución | No ideal |
| Estabilidad de esquema | El modelo enlaza columnas por nombre | `nb_03` renombra `dim_product.category` a `product_category` cuando `run_seq % 4 == 0` (E6): rompería el framing y las consultas del modelo en esas ejecuciones | Riesgo |
| Tipos de columna | Sin tipos complejos, binary ni GUID | Todas las columnas de las 6 tablas del modelo son string, integer, double, date o timestamp (E13) | Cumple |
| Modo de acceso | Direct Lake sobre OneLake no cae a DirectQuery y un exceso de barreras hace fallar el refresco; sobre SQL endpoint puede caer a DirectQuery | `sm_sales` consume el endpoint SQL en Import | Decisión pendiente del modelo (fuera de alcance) |

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| `coreEfficiency` bronze / silver / gold | 0,31 / 0,77 / 0,29 | < 0,3 Alta (`diagnostic-workflow.md` § Severity Thresholds); saludable > 0,5 (`SPARK-MONITORING-CORE.md` § Interpreting Resource Usage) | E9 |
| `idleTime / duration` bronze / silver / gold | 0,50 / 0,12 / 0,78 | > 0,4 Media (`diagnostic-workflow.md`); saludable < 0,3 | E9 |
| Duración de la sesión bronze / silver / gold | 228 s / 668 s / 358 s | Informativo | E9 |
| Cores asignados / cores en uso máximo / cores en uso medio | bronze 16 / 16 / 4,0; silver 32 / 32 / 19,0; gold 48 / 48 / 18,8 | Informativo | E9 |
| Spill de disco, tareas fallidas | 0 en las tres sesiones | `diskBytesSpilled > 0` Media | E10 |
| Shuffle máximo por stage | bronze 116 MB; silver 1.872 MB; gold 116 MB | > 1 GB Media (`diagnostic-workflow.md`): solo silver lo supera | E10 |
| Archivos de `bronze.sales_raw` | 4.000 archivos, 957 MB, media 239 KB, 10 M filas, todos con V-Order | Layout de archivos pequeños (`lakehouse-health.md` anomalía 3, `delta-tables.md`) | E13 |
| Archivos de `silver.customers` / `silver.inventory_levels` | 6.313 (media 4,2 KB) / 2.000 (media 3,4 KB, 49.337 filas) | Igual | E13 |
| `silver.sales` / `gold.fact_sales` | 64 archivos, media 11,8 MB / 8,6 MB; 10 M filas | Informativo | E13 |
| `gold.dim_customer` / `gold.daily_store_sales` | 608 archivos de ~10 KB / 185 archivos de ~3 KB | Igual | E13 |
| Heap JVM pico por executor, gold / bronze | 4,7 GB (memoria máxima 72 GB) / 4,1 GB (35,9 GB) | Informativo | E12 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces` | Workspace `FabricPerfLab` (23ca4a73-…) en capacidad 353a0ed6-… |
| E2 | REST | `GET /v1/workspaces/{ws}/items` | 3 environments, 3 lakehouses (+3 endpoints SQL), 5 notebooks, 2 pipelines, `sm_sales` |
| E3 | REST | `GET /v1/capacities` | Capacidad 353a0ed6-…: Trial FTL64, West Europe. Existe también una F2 Spain Central en el tenant, no asignada a este workspace |
| E4 | REST | `GET /v1/workspaces/{ws}/spark/settings` | Runtime por defecto 2.0; pool por defecto Starter Pool (máx. 10 nodos); personalización de compute habilitada |
| E5 | REST | `GET /v1/workspaces/{ws}/environments/{id}/sparkcompute?beta=false` y `GET .../environments/{id}` (×3) | Las tres publicadas con estado `Success` (2026-10-30 17:02–17:03 UTC). Valores declarados en la tabla por capa. Runtime 1.3 en las tres |
| E6 | REST | `POST /v1/workspaces/{ws}/notebooks/{id}/getDefinition?format=ipynb` (LRO, ×3, lectura) | `nb_01`: `WRITE_PARTITIONS=400`, `optimizeWrite=false`. `nb_02`: `shuffle.partitions=2000`, AQE `false`, skew join `false`, broadcast `-1`. `nb_03`: AQE `false`, `overwrite` + `overwriteSchema`, renombrado de `category` cada 4 ejecuciones. Environment adjunto a cada notebook = su `env_*`. 60 % de las ventas generadas con `store_id = 1` |
| E7 | REST | `GET /v1/workspaces/{ws}/notebooks/{id}/livySessions` (×3) y `GET .../items/{nb_03}/jobs/instances` | Últimas sesiones: `nb_01` f2d0ff70-… (04:59–05:05), `nb_02` 88afdede-… (05:03–05:16), `nb_03` ca299bfc-… (05:18–05:23), todas `Succeeded`, runtime 1.3. 10–11 sesiones por notebook |
| E8 | REST | `GET .../livySessions/{livyId}/applications/{appId}/environment` (×3) | SparkConf al arrancar. bronze: `resourceProfile=readHeavyForPBI`, `vorder.default=true`, `optimizeWrite.enabled=true`, `autoBroadcastJoinThreshold=26214400`, AQE/`shuffle.partitions` sin establecer. silver y gold: `writeHeavy`, `vorder.default=false`, `optimizeWrite` sin establecer, broadcast 26214400. gold: `dynamicAllocation.enabled=false`, min=max=3 executors, 16 cores / 112 g. bronze y silver: 8 cores / 56 g, dinámica 1–4 |
| E9 | REST | `GET .../applications/{appId}/resourceUsage` (×3) | Ver métricas clave |
| E10 | REST | `GET .../applications/{appId}/stages?status=complete` (×3) | bronze: etapa de escritura de 400 tareas y 95,7 MB de salida; 223 stages. silver: 19 stages de 2.000 tareas, 137 stages. gold: 89 stages, máximo 608 tareas. Sin spill |
| E11 | REST | `GET .../applications/{appId}/sql?details=false&length=50` (×3) | `AdaptiveSparkPlan`: bronze 21 de 50; silver 2 de 50 (ids 5 y 6, operaciones internas de Delta previas a las sentencias del notebook; 0 en las de usuario) y 4 `SortMergeJoin`; gold 0 de 50 y 1 `BroadcastHashJoin` |
| E12 | REST | `GET .../applications/{appId}/allexecutors` (×3) | Executors 8 cores / 35,9 GB (bronze, silver) y 16 cores / 72 GB (gold); heap pico en la sección de métricas clave |
| E13 | OneLake | `GET https://onelake.dfs.fabric.microsoft.com/{ws}?resource=filesystem&directory={lh}/Tables/{t}/_delta_log` y lectura de los JSON de 20 tablas | Archivos activos, tamaños, filas (`stats.numRecords`), etiqueta `VORDER` por archivo, propiedades de tabla y esquema. Valores en métricas clave y tablas por capa |
| E14 | OneLake | Lectura por rango de los footers Parquet de 3 archivos de `bronze.sales_raw`, `silver.sales`, `gold.fact_sales`, `gold.dim_customer` | 1 row group por archivo en todos; filas por row group: bronze 2.500, silver 141.864–166.250, gold `fact_sales` 187.484–200.637, `dim_customer` 1.845–1.935. Metadatos `com.microsoft.parquet.vorder.*` solo en bronze |
| E15 | REST | `POST /v1/workspaces/{ws}/semanticModels/{id}/getDefinition?format=TMDL` (LRO, lectura) | Las 6 tablas con `mode: import` y origen `Sql.Database(... "lh_gold")`. Sin Direct Lake |
| E16 | Docs | Learn: *Configure resource profile configurations* | Valores de cada perfil; `writeHeavy` desactiva V-Order; el perfil se puede fijar en el environment o en runtime y el runtime prevalece |
| E17 | Docs | Learn: *Direct Lake overview* | Barreras por SKU (F64/FT1: 5.000 archivos, 5.000 row groups, 1.500 M filas); comportamiento de Direct Lake sobre OneLake y sobre SQL |
| E18 | Docs | Learn: *Cross-workload table maintenance and optimization* | Spark → Direct Lake: V-Order o `readHeavyForPBI`; bronze prioriza escritura y auto compaction; silver V-Order solo si Direct Lake es consumidor principal; gold es la capa para Direct Lake; en runtime 1.3 el tamaño adaptativo de archivo y deletion vectors son opt-in |
| E19 | Docs | Learn: *Troubleshoot Spark memory and performance issues* | Solo `spark.sql.*` se puede cambiar en runtime; `spark.executor.*`, `spark.driver.*` se leen al lanzar sesión o executors; regla de 128–256 MB por partición de shuffle |
| E20 | Docs | Learn: *Understand Direct Lake query performance* | Row groups de 1–16 M filas; muchos row groups pequeños generan segmentos pequeños y más transcodificación; preferir actualizaciones que añaden |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | Silver: AQE, skew join y broadcast desactivados y 2.000 particiones de shuffle, en el environment y repetidos en el notebook; producen tablas con miles de archivos diminutos | Media | Alta | E5, E6, E8, E10, E11, E13 |
| H2 | Gold no está preparada para Direct Lake: sin V-Order, ~156.000 filas por row group, dimensiones con cientos de archivos, esquema inestable y sobrescritura completa | Media | Alta | E13, E14, E15, E17–E20 |
| H3 | Gold: AQE desactivado y sin optimize write generan archivos diminutos que ya lee hoy el endpoint SQL (importación del modelo) | Media | Alta | E6, E11, E13 |
| H4 | Gold: clúster fijo de 48 cores con `coreEfficiency` 0,29 e idle 0,78 | Alta | Alta | E5, E8, E9, E12 |
| H5 | Bronze configurada como lectura para Power BI (perfil `readHeavyForPBI`, V-Order activo) y sin compactación: 4.000 archivos de 239 KB | Media | Alta | E5, E8, E9, E13, E14 |
| H6 | El environment declarado no coincide con lo observado al arrancar y los notebooks repiten valores que enmascaran la diferencia | Baja | Media | E5, E6, E8 |

### H1 · Silver con la configuración de shuffle invertida

- **Qué ocurre:** `env_silver` declara `spark.sql.adaptive.enabled=false`, `skewJoin.enabled=false`, `autoBroadcastJoinThreshold=-1` y `shuffle.partitions=2000`, y `nb_02` repite las cuatro con el mismo valor (E5, E6). En la sesión de `nb_02` hay 19 stages de 2.000 tareas, ninguna de las sentencias de usuario usa `AdaptiveSparkPlan`, hay 4 `SortMergeJoin` y ningún broadcast en la muestra, y el shuffle llega a 1.872 MB por stage (E10, E11). Un join contra `stores` (50 filas) debería ser broadcast, y el 60 % de las ventas es de una sola tienda (E6).
- **Por qué:** las cuatro claves son configuración de runtime, así que el notebook las aplica y el efecto se ve (E19). Los 2.000 fragmentos acaban en disco: `silver.inventory_levels` tiene 49.337 filas repartidas en 2.000 archivos de ~3,4 KB y `silver.customers` 6.313 archivos de ~4,2 KB (E13). Con la regla de Learn de 128–256 MB por partición (E19) el shuffle de 1.872 MB necesitaría del orden de 10 particiones.
- **Impacto:** tablas silver que leen `nb_03` y el endpoint SQL con 8.000+ archivos diminutos. No hay spill ni fallos, y `coreEfficiency` es 0,77 (saludable, E9). Severidad Media: ninguno de los umbrales de recursos de la skill se supera salvo el shuffle por stage de 1.872 MB (> 1 GB Media, `diagnostic-workflow.md` § Severity Thresholds); el efecto sobre el layout se rige por `delta-tables.md` (archivos pequeños), que no fija un umbral numérico.

### H2 · Gold no cumple los requisitos de Direct Lake

- **Qué ocurre:** `sm_sales` está en Import sobre el endpoint SQL (E15), así que hoy no hay problema de Direct Lake; si pasa a Direct Lake las tablas de gold no cumplen: 0 archivos V-Order, 64 row groups de ~156.000 filas en `fact_sales` (Learn: 1–16 M), 608 row groups de ~1.900 filas en `dim_customer`, 185 de ~3 KB en `daily_store_sales` (E13, E14, E20).
- **Por qué:** `env_gold` fija `writeHeavy` y `vorder.default=false`; no hay optimize write ni compactación; el número de archivos lo decide la partición de la lectura silver (E5, E13). Learn indica V-Order o `readHeavyForPBI` para Spark → Direct Lake (E18).
- **Impacto:** no se superan las barreras de F64 (64 archivos frente a 5.000; 10 M filas frente a 1.500 M), de modo que ni habría fallo de refresco ni caída a DirectQuery por barreras; el coste sería más segmentos y mayor tiempo de transcodificación y carga en frío. Cada ejecución sobrescribe todo con `overwriteSchema`, así que no hay framing incremental, y el renombrado periódico de `category` rompería el modelo en esas ejecuciones (E6). Severidad Media: condicionada a que se migre el modelo.

### H3 · Archivos diminutos en gold que ya paga el endpoint SQL

- **Qué ocurre:** `nb_03` desactiva AQE y no hay optimize write: las 200 particiones de shuffle por defecto se escriben tal cual (stages de 200 tareas, 0 planes adaptativos) y `dim_customer` queda con 608 archivos de ~10 KB y `daily_store_sales` con 185 de ~3 KB (E10, E11, E13).
- **Por qué:** `nb_03` ejecuta `spark.conf.set("spark.sql.adaptive.enabled", "false")` (E6) y el environment desactiva optimize write (E5). Learn indica que AQE está activo por defecto en los runtimes de Fabric (E19).
- **Impacto:** el refresco Import de `sm_sales` lee estas tablas por el endpoint SQL; archivos de ~3–10 KB degradan el escaneo (`lakehouse-health.md` anomalía 3). Es el mismo defecto que afecta a Direct Lake (H2), pero ya es visible hoy.

### H4 · Gold con clúster fijo y ocioso

- **Qué ocurre:** 3 executors de 16 cores / 112 g fijos (48 cores) frente a un trabajo de 10 M filas, 1,2 GB leídos y 556 MB escritos (E10). Eficiencia de cores 0,29, idle 77,6 %, 18,8 cores en uso de media y 4,7 GB de heap pico por executor sobre 72 GB (E9, E12).
- **Por qué:** `dynamic_executor_allocation.enabled=false` con min=max=3 y pool `pool_gold_xl` en `env_gold` (E5). Es configuración fija al arrancar: solo se cambia en el environment o el pool (E19).
- **Impacto:** `coreEfficiency` 0,29 < 0,3 (Alta, `diagnostic-workflow.md` § Severity Thresholds) e idle > 0,4 (Media). El dimensionamiento concreto está en `2026-10-31/01-gold-spark-sobredimensionado.md`; este informe solo lo conecta con la configuración por capa.

### H5 · Bronze con la configuración de otra capa

- **Qué ocurre:** `env_bronze` declara `readHeavyForPBI` con `vorder.default=true` (E5) y los 4.000 archivos de `sales_raw` están escritos con V-Order, media 239 KB, 400 por ejecución (E13, E14). El notebook desactiva optimize write, pero el SparkConf al arrancar mostraba `optimizeWrite=true` por el perfil (E8). La sesión tuvo idle 0,50 (E9).
- **Por qué:** la carga es una ingesta append que nadie consume desde Power BI; Learn pide priorizar la escritura en bronze y mantener las tablas con auto compaction, y reservar V-Order para Direct Lake (E18). `repartition(400)` fija el número de archivos; el notebook no compacta.
- **Impacto:** coste de escritura adicional de V-Order sin lector que lo aproveche (no medido), 4.000 archivos que `nb_02` relee completos en cada ejecución (la sesión de `nb_02` leyó 1.595 MB en total, E10) y idle 0,50 > 0,4 (Media). `coreEfficiency` 0,31 está en el hueco entre el umbral de alerta (0,3) y el saludable (0,5): no marcado, no saludable (`spark-resources.md` § Known traps).

### H6 · Environment, SparkConf inicial y notebooks no cuadran del todo

- **Qué ocurre:** `env_bronze` declara `optimizeWrite=false` pero el SparkConf de la sesión muestra `true`; `env_silver` declara cuatro claves `spark.sql.*` que no aparecen en el SparkConf inicial (AQE y `shuffle.partitions` sin establecer, broadcast en el valor por defecto 26214400); `env_gold` declara `optimizeWrite=false` que tampoco aparece (E5, E8). Además, los tres environments están en runtime 1.3 y el workspace usa 2.0 por defecto (E4, E5).
- **Por qué:** no se pudo determinar si las propiedades `spark.sql.*` del environment se aplican como configuración de sesión tras el arranque o si el perfil prevalece sobre lo declarado (el SparkConf inicial solo refleja lo que existe al arrancar). Como `nb_01` y `nb_02` repiten los mismos valores, el valor efectivo en esas notebooks es el del notebook.
- **Impacto:** Baja: el efecto final es conocido por su huella, pero el environment por sí solo no es una fuente fiable del valor efectivo. En runtime 1.3 el tamaño adaptativo de archivo y los deletion vectors son opt-in (E18).

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Silver: quitar las cuatro sobrescrituras del environment y del notebook; activar compactación automática; compactar `customers` e `inventory_levels` una vez | H1 | Alto | Bajo | Bajo | Sí |
| R2 | Gold: corregir la escritura (AQE activo, optimize write y V-Order según el modo de `sm_sales`) y reescribir las tablas con `OPTIMIZE ... VORDER` antes de migrar a Direct Lake | H2, H3 | Alto | Medio | Medio | Sí |
| R3 | Bronze: pasar a `writeHeavy`, V-Order desactivado y auto compaction; quitar la sobrescritura del notebook; compactar `sales_raw` una vez | H5 | Medio | Bajo | Bajo | Sí |
| R4 | Gold: aplicar el redimensionamiento propuesto en el informe 01 (nodo menor, asignación dinámica) | H4 | Alto | Bajo | Bajo | Sí |
| R5 | Fuente única de configuración y estabilidad del esquema de gold: configurar en el environment, no en el notebook, fijar el esquema de `dim_product` y valorar runtime 2.0 | H6, H2 | Medio | Medio | Medio | Sí |

### R1 · Silver: recuperar los valores adaptativos y compactar

- **Cambio propuesto:**

  ```yaml
  # env_silver: eliminar estas cuatro propiedades Spark (dejar el valor por defecto de Fabric)
  #   spark.sql.adaptive.enabled: 'false'
  #   spark.sql.adaptive.skewJoin.enabled: 'false'
  #   spark.sql.autoBroadcastJoinThreshold: '-1'
  #   spark.sql.shuffle.partitions: '2000'
  # añadir:
  spark.sql.adaptive.enabled: 'true'
  spark.sql.adaptive.skewJoin.enabled: 'true'
  spark.databricks.delta.autoCompact.enabled: 'true'
  ```

  ```python
  # nb_02_bronze_to_silver, celda 1: eliminar las cuatro líneas spark.conf.set
  # (la configuración vive solo en el environment)
  ```

  ```sql
  -- Una vez, tras publicar el environment:
  OPTIMIZE lh_silver.customers;
  OPTIMIZE lh_silver.inventory_levels;
  ```

- **Impacto esperado:** el shuffle de 1.872 MB pasaría a pocas decenas de particiones (AQE las agrupa), el join con `stores` a broadcast y desaparecen las cifras de 2.000 y 6.313 archivos diminutos en las dos tablas. La magnitud exacta no está medida.
- **Cómo validarlo:** tras la siguiente ejecución, volver a leer `/environment`, `/stages` (nº de tareas por stage) y `/sql` (`AdaptiveSparkPlan`, `BroadcastHashJoin`) de la sesión de `nb_02` y el `_delta_log` de `silver.inventory_levels` (E8, E10, E11, E13); esperar menos de ~50 archivos en `inventory_levels` y planes adaptativos en las sentencias de usuario.
- **Reversión:** volver a publicar el environment anterior y restaurar las líneas del notebook; el `OPTIMIZE` no se revierte pero no cambia datos.
- **Requiere confirmación:** Sí — publicar un environment, editar un notebook y ejecutar `OPTIMIZE` son cambios que este agente no aplica.

### R2 · Gold: escritura y layout compatibles con Direct Lake

- **Cambio propuesto:** decidir primero el modo de `sm_sales`. Si migra a Direct Lake (recomendado por Learn, E18, para gold):

  ```yaml
  # env_gold
  spark.fabric.resourceProfile: readHeavyForPBI   # V-Order true, optimizeWrite true, binSize 1g (E16)
  spark.sql.parquet.vorder.default: 'true'
  spark.databricks.delta.optimizeWrite.enabled: 'true'
  ```

  ```python
  # nb_03_silver_to_gold, celda 2: eliminar spark.conf.set("spark.sql.adaptive.enabled", "false")
  ```

  ```sql
  -- Una vez, tras la primera ejecución con la nueva configuración:
  OPTIMIZE lh_gold.fact_sales VORDER;
  OPTIMIZE lh_gold.dim_customer VORDER;
  OPTIMIZE lh_gold.daily_store_sales VORDER;
  -- y el resto de tablas del modelo (dim_product, dim_store, dim_date, promotions)
  ```

  Si `sm_sales` se queda en Import, mantener V-Order desactivado (Learn: no activarlo solo para el endpoint SQL, E18), pero sí optimize write y AQE para eliminar los archivos diminutos (H3).

- **Impacto esperado:** `fact_sales` pasa de 64 row groups de ~156.000 filas a pocos row groups dentro del rango 1–16 M filas, y `dim_customer` y `daily_store_sales` de cientos de archivos a unos pocos. La mejora de latencia de Direct Lake no está medida.
- **Cómo validarlo:** releer el `_delta_log` y los footers Parquet de `lh_gold` (E13, E14): archivos con etiqueta V-Order = total, filas por row group ≥ 1 M en `fact_sales`, archivos por tabla pequeños. Ya con el modelo en Direct Lake, probar cache frío y caliente con DAX y comprobar que no hay caída a DirectQuery.
- **Reversión:** volver a publicar el environment anterior. Los archivos reescritos por `OPTIMIZE` no se deshacen, pero la tabla sigue siendo válida.
- **Requiere confirmación:** Sí — `OPTIMIZE`, publicación de environment y edición de notebook; el `OPTIMIZE ... VORDER` reescribe las tablas y consume CU.

### R3 · Bronze: configurar para escribir

- **Cambio propuesto:**

  ```yaml
  # env_bronze
  spark.fabric.resourceProfile: writeHeavy
  spark.sql.parquet.vorder.default: 'false'        # o eliminar la propiedad
  spark.databricks.delta.autoCompact.enabled: 'true'
  # eliminar: spark.databricks.delta.optimizeWrite.enabled: 'false'
  ```

  ```python
  # nb_01_ingest_bronze, celda 2: eliminar spark.conf.set("spark.databricks.delta.optimizeWrite.enabled", "false")
  # valorar sustituir sales.repartition(WRITE_PARTITIONS) por la agrupación de optimize write / auto compaction
  ```

  ```sql
  OPTIMIZE lh_bronze.sales_raw;   -- una vez, sin VORDER
  ```

- **Impacto esperado:** menos archivos acumulados por ejecución y lectura de `nb_02` sobre `sales_raw` con menos archivos; se elimina el coste de V-Order en una capa sin consumidores Power BI (no medido).
- **Cómo validarlo:** releer `_delta_log` de `sales_raw` (archivos y tamaño medio, E13) y `/environment` de la sesión de `nb_01` (E8) tras la siguiente ejecución.
- **Reversión:** volver a publicar el environment anterior.
- **Requiere confirmación:** Sí — environment, notebook y `OPTIMIZE`.

### R4 · Gold: dimensionar el clúster

- **Cambio propuesto:** aplicar lo propuesto en `2026-10-31/01-gold-spark-sobredimensionado.md` (nodo y número de executors menores, asignación dinámica). Es configuración fija al arrancar: solo se cambia en el environment o en el pool, no con `spark.conf.set` (E19).
- **Impacto esperado:** `coreEfficiency` por encima de 0,5 y `idleTime/duration` por debajo de 0,3 (rangos saludables de `SPARK-MONITORING-CORE.md` § Interpreting Resource Usage); el ahorro en CU no está medido.
- **Cómo validarlo:** repetir `/resourceUsage` de la sesión de `nb_03` (E9) y comparar con 0,29 y 0,78.
- **Reversión:** volver a publicar el environment anterior y el pool anterior.
- **Requiere confirmación:** Sí — cambia pool y environment, que afectan a las sesiones siguientes.

### R5 · Fuente única de configuración y estabilidad del esquema de gold

- **Cambio propuesto:** mantener un único lugar por clave (el environment para perfil, V-Order, AQE y compact; el notebook solo para excepciones de una celda); no renombrar columnas en gold (`category` ↔ `product_category`): resolver las versiones del catálogo con un alias en el modelo o una vista; valorar pasar los environments a runtime 2.0, donde Learn indica que el tamaño adaptativo de archivo y los deletion vectors son por defecto (E18).
- **Impacto esperado:** valores efectivos legibles desde el environment y un modelo que no se rompe en las ejecuciones donde cambia el esquema.
- **Cómo validarlo:** comparar `/environment` de cada sesión con lo declarado y comprobar que el esquema de `lh_gold.dim_product` no cambia entre ejecuciones (`_delta_log`).
- **Reversión:** restaurar los environments y el notebook anteriores.
- **Requiere confirmación:** Sí — editar notebooks y publicar environments; un cambio de runtime puede alterar el comportamiento de todos los notebooks.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Algún notebook intenta cambiar con `spark.conf.set` una configuración fija al arrancar y se ignora | E6, E10, E11, E19 | Las cinco claves sobrescritas (optimizeWrite, AQE, skew join, broadcast, shuffle partitions) son de runtime y su efecto es observable (400 archivos de 239 KB, stages de 2.000 tareas, ausencia de plan adaptativo). Ningún notebook toca `spark.executor.*`, `spark.driver.*` ni `dynamicAllocation` |
| D2 | Gold ya supera las barreras de Direct Lake de la capacidad actual | E3, E13, E17 | `fact_sales` 64 archivos / 64 row groups / 10 M filas y `dim_customer` 608 archivos frente a 5.000 / 5.000 / 1.500 M de F64/FT1. No hay riesgo de fallo de refresco ni de DirectQuery por barreras hoy |
| D3 | Silver sufre presión de memoria o de recursos por la configuración | E9, E10 | `coreEfficiency` 0,77 e idle 0,12 (saludables), sin spill ni tareas fallidas. El problema de silver es de layout, no de recursos |
| D4 | Gold usa tipos de columna que Direct Lake no admite | E13 | Todas las columnas de las seis tablas del modelo son string, integer, double, date o timestamp |

## Siguientes pasos

- [ ] Decidir si `sm_sales` migra a Direct Lake y sobre qué modo (OneLake sin caída a DirectQuery o endpoint SQL) — responsable: propietario del modelo · relacionado con: R2
- [ ] Publicar los cambios de configuración de silver, bronze y gold y ejecutar los `OPTIMIZE` — responsable: FabricAdmin / ingeniero de datos · relacionado con: R1, R2, R3
- [ ] Reducir el compute de gold según el informe 01 — responsable: FabricAdmin · relacionado con: R4
- [ ] Fijar el esquema de `dim_product` en gold — responsable: ingeniero de datos · relacionado con: R5
- [ ] Repetir el análisis tras aplicar R1–R4 para validar el impacto

## Notas

### Limitaciones

- No se creó sesión Livy (ver Alcance): no hay `spark.conf.get` dentro de sesión; la configuración efectiva sale de sesiones de ejecuciones reales.
- El SparkConf inicial no incluye los `spark.conf.set` ejecutados después; su efecto se demostró solo por la huella (tareas, planes, archivos). Los planes SQL son una muestra de 50 ejecuciones por sesión.
- No se midió skew ni el coste temporal de V-Order; no se consultó la API de precios, por lo que no hay cifras en moneda.
- La capacidad es una Trial FTL64; se trató como F64/FT1 a efectos de barreras de Direct Lake (confianza Media en esa equivalencia, no verificada con Learn para FTL64).

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Origen exacto (environment o runtime) de los valores `spark.sql.*` de silver | El endpoint `/environment` solo devuelve el SparkConf al arrancar | Baja el grado de detalle de H6; no cambia la conclusión porque el notebook repite los valores |
| Duración y coste de V-Order y de optimize write en bronze | No se ejecutaron pruebas A/B (serían escrituras) | Los impactos de R1–R3 son cualitativos |
| Skew real de `nb_02` | Fuera del alcance (`spark-runs.md`) | El valor de skew join queda justificado por el código del generador (60 % de las ventas en una tienda), no por medida |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Clave de V-Order | `e2e-medallion-architecture/SKILL.md` usa `spark.sql.parquet.vorder.default`; `data-engineering-patterns.md` usa `spark.microsoft.delta.parquet.vorder.enabled` | Learn y el SparkConf observado (E8) usan `spark.sql.parquet.vorder.default` | Se recomienda y se ha medido con `spark.sql.parquet.vorder.default` |
| Optimize write en gold | `e2e-medallion-architecture/SKILL.md` lo activa en gold; `data-engineering-patterns.md` lo desactiva | `readHeavyForPBI` lo activa con `binSize` 1g (E16) | Se decide por el consumidor: Direct Lake → activado; Import → activado solo para evitar archivos diminutos |
| V-Order y optimize write "por defecto" | — | La página de comparación Synapse–Fabric dice que ambos están habilitados por defecto en Fabric; la de perfiles dice que los workspaces nuevos usan `writeHeavy` con V-Order desactivado, y la sesión observada (silver, gold) lo confirma (`vorder.default=false`) | Prevalece lo observado y la página de perfiles |
| Dónde se aplica `dynamicAllocation.*` | — | Learn lista `spark.executor.*`, `spark.driver.*`, `spark.network.*` y `spark.yarn.*` como fijas al arrancar; no nombra `dynamicAllocation` | Se trata como configuración de compute del environment (fija al arrancar), confianza Media |
| Valores de `repartition` frente a compactación | — | Learn: auto compaction como estrategia por defecto en tablas escritas por Spark (E18) | Se recomienda auto compaction en bronze y silver |

## Anexo

### Consultas completas

- E13: para cada tabla se listó `…/Tables/{t}/_delta_log`, se aplicaron en orden las acciones `add`, `remove` y `metaData` de los JSON y se agregaron archivos activos, tamaños, `stats.numRecords`, etiqueta `VORDER` y propiedades.
- E14: lectura por rango (`Range: bytes=…`) de los footers Parquet de tres archivos activos por tabla, con `pyarrow` para leer `num_row_groups`, filas por row group y metadatos `com.microsoft.parquet.vorder.*`.

### Configuración efectiva

| Clave | bronze (`nb_01`) | silver (`nb_02`) | gold (`nb_03`) |
|-------|------------------|------------------|----------------|
| `spark.fabric.resourceProfile` | readHeavyForPBI | writeHeavy | writeHeavy |
| `spark.sql.parquet.vorder.default` | true | false | false |
| `spark.databricks.delta.optimizeWrite.enabled` (al arrancar → tras notebook) | true → false | sin establecer | sin establecer |
| `spark.databricks.delta.autoCompact.enabled` | sin establecer | sin establecer | sin establecer |
| AQE (al arrancar → tras notebook) | activo | activo → desactivado | activo → desactivado |
| `spark.sql.autoBroadcastJoinThreshold` | 26214400 | 26214400 → -1 | 26214400 |
| `spark.sql.shuffle.partitions` | sin establecer | sin establecer → 2000 | sin establecer |
| `spark.dynamicAllocation.enabled` / min–max | true / 1–4 | true / 1–4 | false / 3–3 |
| `spark.executor.cores` / `memory` | 8 / 56g | 8 / 56g | 16 / 112g |
| `spark.native.enabled` | false | false | false |
| Runtime | 1.3 | 1.3 | 1.3 |
