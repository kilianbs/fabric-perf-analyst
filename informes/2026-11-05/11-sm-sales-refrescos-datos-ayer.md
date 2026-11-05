# sm_sales: por qué los usuarios ven datos de ayer o errores (refrescos del modelo)

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-05 |
| **Áreas** | Semantic models (refresco) → Spark runs / pipeline (orquestación) → Delta tables (esquema por versión) |
| **Ámbito** | workspace `FabricPerfLab` · modelo `sm_sales` · pipeline `pl_daily_sales` · notebooks `nb_03_silver_to_gold` y `nb_04_refresh_model` · tablas de `lh_gold` |
| **Ventana analizada** | 2026-10-30 17:00 → 2026-11-05 10:45 UTC (todo el historial disponible) |
| **Agente / host** | Claude Code · skills: semantic-model-authoring, spark-cli, sqldw-cli, fabric-perf-analysis |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Alta (causa del error) / Media (mecanismo de desfase y ausencia de refresco del 5-nov) |

## Resumen

- **Pregunta:** si el modelo se refresca bien, por qué los usuarios ven datos de ayer y por qué a veces hay error.
- **Conclusión:** no se refresca bien. 4 de 20 refrescos del historial fallaron con `The 'category' column does not exist in the rowset`. Causa medida: `nb_03` renombra `dim_product.category` a `product_category` cada vez que `run_seq` es múltiplo de 4 (parámetro `product_schema_v2_every = 4`, con `overwriteSchema`), pero el modelo sigue esperando `category`. Los renombrados caen en las versiones Delta v3, v6 y v13 de `dim_product`.
- **Impacto:** el último refresco con datos nuevos es el del 2026-11-04 05:31 UTC, y ese ya cargó la versión anterior de gold (13 M filas, hasta el 15-sep). El lakehouse tiene 15 M filas hasta el 17-sep. Además, el pipeline marca "Succeeded" aunque el modelo no se refresque: `nb_04` solo pide el refresco, no espera, no comprueba el resultado y se traga las excepciones.
- **Primera acción:** R1, dejar de renombrar columnas del contrato (o versionarlo con una vista estable), y R2, hacer que `nb_04` espere y falle si el refresco no termina en `Completed`. Requieren confirmación; no se aplicaron.

## Alcance

**Pregunta original:** "los usuarios dicen que a veces ven los datos de ayer o el informe da error. ¿Se refresca bien el modelo? ... (1) historial completo de refrescos ... traza esa causa; (2) cruza ... con las ejecuciones de pl_daily_sales ...; (3) cruza con el esquema de las tablas de gold en cada versión Delta ...; (4) revisa en el código cómo lanza y vigila el refresco el pipeline ... Explica por qué los usuarios ven datos de ayer ... y por qué dan error. Distingue evidencia medida de inferencia."

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| 20 refrescos del modelo, 14 ejecuciones del pipeline, esquema y commits Delta de las 6 tablas de gold, código de `nb_03`, `nb_04` y definición del pipeline | Causa del fallo de ingesta `DELTA_FAILED_TO_MERGE_FIELDS ... 'amount'` (solo se registra como segunda causa de desfase); telemetría de errores de usuario del informe (no accesible, ver Notas) |

**Hipótesis de partida:** H-a) un cambio de esquema en `dim_product` rompe la consulta del modelo; H-b) el refresco se lanza antes de que gold esté listo o sin esperar; H-c) fallos del pipeline dejan gold sin cambios.

**Recorrido:** Semantic models (historial de refresco, error `category`) → Delta tables (esquema por versión en `_delta_log`, que ubica el renombrado) → Spark runs/orquestación (`nb_03`, `nb_04`, pipeline) → de vuelta al modelo para explicar el desfase medido de 13 M frente a 15 M filas.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad | FTL64 (trial), West Europe, activa | E11 |
| Modo de almacenamiento del modelo | Import, tablas leídas del SQL endpoint de `lh_gold` | informe 09 (E1) |
| Calendario de refresco del modelo | 05:30 y 06:30 hora de Romance (UTC+1 en noviembre) = 04:30 y 05:30 UTC, todos los días; `notifyOption = NoNotification` | E2 |
| Calendario del pipeline | 06:00 hora de Romance = 05:00 UTC, diario | E5 |
| Permisos con los que se ejecutó | Lectura del historial de refresco, de las definiciones de pipeline y notebooks, `queryactivityruns` y OneLake `_delta_log` correctas; lectura de `demo-setup/` denegada por permisos de la sesión | E1-E9, Notas |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| sm_sales | SemanticModel | Consumo | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |
| pl_daily_sales | DataPipeline | Orquestación | bd706b1d-499f-4a0d-bb22-222312944ca1 |
| nb_03_silver_to_gold | Notebook | Gold | c7cca4b7-3722-4bec-9946-504520f6be21 |
| nb_04_refresh_model | Notebook | Refresco del modelo | 3a609552-4721-406a-8e9c-f801c0a43b59 |
| lh_gold, lh_bronze | Lakehouse | Gold / control | 3aee923d-121b-415b-872c-4d5bb70664c0, 53249a1b-e8a9-4270-9cb4-0f2ce3b10feb |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Refrescos del historial | 20 (16 completados, 4 fallidos); 12 programados, 8 pedidos desde el pipeline (`ViaEnhancedApi`) | `semantic-model-rest-api.md` § Refresh History Response Properties | E1 |
| Error de los 4 fallos | El mismo: `The 'category' column does not exist in the rowset` (2026-10-30 19:50, 2026-11-04 05:30, 2026-11-05 04:30 y 05:30 UTC) | `semantic-models.md` § Known traps ("Column does not exist in the rowset") | E1 |
| Versiones de `dim_product` con `product_category` | v3 (10-30 18:22), v6 (10-30 19:29), v13 (11-04 05:24); el resto con `category` | ídem | E9 |
| Ejecuciones del pipeline | 14 completadas y 2 fallidas en ingesta (2026-10-30 18:43 y 2026-11-01 05:00) | n/a | E3 |
| Datos del modelo frente al lakehouse | 13 M filas, hasta 2026-09-15, 161.879 clientes, frente a 15 M, hasta 2026-09-17, 158.950 clientes | n/a | E10, E12 |
| Último refresco con datos nuevos | 2026-11-04 05:27:44 → 05:31:08 UTC (cargó gold v12, no v13) | n/a | E1, E9, E10 |
| Duración de los refrescos programados | 2-11 min en completados; 5 min en los fallidos del 4 y 5-nov | n/a | E1 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1.0/myorg/groups/{ws}/datasets/{id}/refreshes` (Power BI) | 20 entradas desde 2026-10-30 19:30 UTC; ver línea de tiempo |
| E2 | REST | `GET /v1.0/myorg/groups/{ws}/datasets/{id}/refreshSchedule` | Diario, `times` 05:30 y 06:30 (Romance Standard Time), `NoNotification` |
| E3 | REST | `GET /v1/workspaces/{ws}/items/{pipeline}/jobs/instances` | 16 ejecuciones desde 2026-10-30 17:11; programadas 05:00 UTC; estados y duraciones en la línea de tiempo |
| E4 | REST | `POST /v1/workspaces/{ws}/datapipelines/pipelineruns/{jobId}/queryactivityruns` (lectura), ejecuciones del 4 y 5-nov | 5-nov: `Silver to gold` 05:19:27-05:28:10 UTC, `Refresh semantic model` 05:28:13-05:30:37, todas `Succeeded`. 4-nov: `Silver to gold` 05:18:31-05:25:12, `Refresh semantic model` 05:25:14-05:27:52, todas `Succeeded` |
| E5 | REST | `POST .../items/{pipeline}/getDefinition` (lectura) | 4 actividades `TridentNotebook` en serie con `Succeeded` entre ellas; `Refresh semantic model` ejecuta `nb_04`, `retry: 0`, `timeout 0.00:30:00`; sin actividad de espera ni de sincronización del SQL endpoint |
| E6 | REST | `POST .../items/{nb_04}/getDefinition` (lectura) | `fabric.refresh_dataset(dataset=semantic_model, refresh_type="full")` dentro de `try/except Exception` que solo imprime `WARNING: could not request the refresh...`; no usa `get_refresh_execution_details` |
| E7 | REST | `POST .../items/{nb_03}/getDefinition` (lectura) | `product_schema_v2_every = 4`; `if product_schema_v2_every > 0 and run_seq % 4 == 0: dim_product = dim_product.withColumnRenamed("category", "product_category")`; todas las tablas con `mode("overwrite")` y `overwriteSchema=true` |
| E8 | SQL | `SELECT TOP 50 * FROM dbo.ctl_pipeline_runs ORDER BY run_seq DESC` (`lh_bronze`) | 17 filas: `run_seq` 1-17, `business_date` 2026-09-01 → 09-17, `started_at` de 2026-10-30 17:12 a 2026-11-05 05:01 |
| E9 | OneLake | Lectura de los `_delta_log/*.json` de `fact_sales`, `dim_customer`, `dim_product`, `dim_store`, `promotions`, `dim_date` (`metaData.schemaString` por versión) | `dim_product`: 15 versiones; esquema con `product_category` solo en v3, v6 y v13. `fact_sales`, `dim_customer`, `dim_store`: 15 versiones, esquema sin cambios desde v0. `promotions` y `dim_date`: 1 versión |
| E10 | DAX | `COUNTROWS(fact_sales)`, fechas máx., `COUNTROWS(dim_customer)` en el modelo | 13.000.000, 2026-09-15, 161.879 (informes 07 y 09) |
| E11 | REST | `GET /v1/capacities` | `FTL64`, West Europe, `Active` |
| E12 | SQL | Recuentos en `lh_gold` (SQL endpoint) | `fact_sales` 15.000.000 filas, `sale_date` hasta 2026-09-17; `dim_customer` 158.950 (informe 09, E9) |
| E13 | Docs | Microsoft Learn: sincronización de metadatos del SQL analytics endpoint; `sempy.fabric.refresh_dataset` | Retardo normal < 1 min, puede crecer a minutos; existe la actividad "Refresh SQL analytics endpoint" y la API de refresco de metadatos. `refresh_dataset` es el envoltorio del refresco asíncrono y devuelve el id de petición |

### Línea de tiempo cruzada (UTC)

| Fecha | Pipeline `pl_daily_sales` | `dim_product` en gold | Refrescos del modelo |
|-------|---------------------------|-----------------------|----------------------|
| 2026-10-30 | 8 ejecuciones manuales (17:11-20:18); la de 18:43-18:44 falla en ingesta | v3 18:22 `product_category`; v4 18:40 `category`; v6 19:29 `product_category`; v7 19:49 `category`; v8 20:17 `category` | VEA 19:30:22-19:32:04 **Completado**; VEA 19:50:58-19:51:14 **Fallido** (`category`); VEA 20:18:11-20:20:24 Completado |
| 2026-10-31 | 05:00-05:26 (run 11) | v9 05:22:59 `category` | Prog. 04:30-04:38; VEA 05:25:56-05:28:49; Prog. 05:30-05:38; todos Completados |
| 2026-11-01 | 05:00:02-05:01:21 **Fallido** en `Ingest bronze` (`DELTA_FAILED_TO_MERGE_FIELDS ... 'amount'`); run 12 anotado en `ctl_pipeline_runs`, sin gold | sin versión nueva | Prog. 04:30 y 05:30 Completados sobre gold sin cambios |
| 2026-11-02 | 05:00-05:25 (run 13) | v10 05:23:38 | Prog. 04:30; VEA 05:24:52-05:27:54; Prog. 05:30; Completados |
| 2026-11-03 | 05:00-05:26 (run 14); manual 08:05-08:31 (run 15) | v11 05:23:03; v12 08:28:02 | Prog. 04:30 y 05:30; VEA 05:25:52-05:28:50 y 08:30:42-08:33:52; Completados |
| 2026-11-04 | 05:00-05:27:54 (run 16) | v13 **05:24:23 `product_category`** | Prog. 04:30-04:41 Completado; VEA 05:27:44-05:31:08 **Completado (con datos de v12)**; Prog. 05:30:02-05:35:29 **Fallido** |
| 2026-11-05 | 05:00-05:30:40 (run 17) | v14 05:27:30 `category` | Prog. 04:30:01-04:32:14 **Fallido**; Prog. 05:30:02-05:35:07 **Fallido**; **sin entrada VEA** pese a que `Refresh semantic model` terminó `Succeeded` 05:30:37 |

VEA = `ViaEnhancedApi` (refresco pedido por `nb_04`). Corresponde a los `run_seq` 4, 8, 12 y 16 el renombrado a `product_category`; el run 12 no llegó a gold porque la ingesta falló (E3, E7, E8, E9).

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | El error `category` lo causa `nb_03`, que renombra la columna cada 4.ª ejecución | Alta | Alta | E1, E7, E8, E9 |
| H2 | El fallo del refresco depende del instante en que el SQL endpoint refleja el esquema nuevo, y dura días | Alta | Media | E1, E9, E13 |
| H3 | El modelo está dos ejecuciones por detrás (13 M frente a 15 M filas) | Alta | Alta | E1, E9, E10, E12 |
| H4 | `nb_04` no espera, no comprueba y traga errores; el pipeline termina `Succeeded` aunque el modelo no se refresque | Alta | Alta | E4, E5, E6 |
| H5 | Los calendarios del modelo (04:30 y 05:30 UTC) no están alineados con el pipeline (05:00-05:30 UTC) | Media | Alta | E2, E3, E4 |
| H6 | La ingesta falla por deriva de tipo de `amount` (runs 6 y 12) y deja gold sin cambios | Media | Media | E3 |
| H7 | No se han encontrado evidencias de errores de visuales; los fallos de refresco no deberían romper los informes | Baja | Baja | E1 |

### H1 · Origen del error `category` (medido)

- **Qué ocurre:** los 4 refrescos fallidos devuelven el mismo `The 'category' column does not exist in the rowset`. La partición de `dim_product` lee `Sql.Database(<SQL endpoint de lh_gold>)` y el modelo mapea `category` (informe 09, E1; informe 10).
- **Por qué:** `nb_03` define `product_schema_v2_every = 4` y, si `run_seq % 4 == 0`, aplica `withColumnRenamed("category", "product_category")` y escribe con `overwrite` + `overwriteSchema`. Los commits Delta de `dim_product` lo confirman: `product_category` aparece en v3 (run 4), v6 (run 8) y v13 (run 16); en las demás versiones es `category`. Ninguna otra tabla de gold cambia de esquema (`fact_sales`, `dim_customer`, `dim_store`: sin cambios desde v0) (E7, E9).
- **Impacto:** cada 4 ejecuciones, el contrato `category` desaparece del endpoint y el refresco deja de funcionar hasta que se vuelve a escribir la columna con su nombre.

### H2 · Por qué falla en esos momentos y no en otros (parte inferencia)

- **Medido:** tras el renombrado de v13 (2026-11-04 05:24:23) el refresco pedido a las 05:27:44 terminó `Completed`, el programado de las 05:30:02 falló, y los dos del 5-nov (04:30 y 05:30) también. Tras la vuelta a `category` en v14 (11-05 05:27:30) el refresco de las 05:30:02, 2 min 32 s después, aún falló. El 10-30: v6 (renombrado, 19:29:07) → refresco de las 19:30:22 Completado; v7 (vuelta a `category`, 19:49:50) → refresco de las 19:50:58 **Fallido** (E1, E9).
- **Inferencia (Confianza Media):** el SQL analytics endpoint tarda en reflejar los cambios de Delta. Con esa hipótesis se explica todo el patrón: el refresco justo después de un cambio todavía ve el esquema anterior (sin fallo), y el siguiente ya ve el esquema nuevo (fallo), también cuando el esquema vuelve a ser el correcto, porque el endpoint aún expone el anterior. Learn indica un retardo normal inferior a 1 minuto, con aumentos a minutos según factores como el número de ficheros pequeños (E13); aquí haría falta un retardo de al menos 1-3 min. No se midió la hora de sincronización del endpoint (la DMV `sys.dm_db_external_tables_log_status` es de la nueva sincronización, preview, y no se consultó).
- **Impacto:** el fallo no es instantáneo ni se corrige solo al restaurar `category`: dura desde el primer refresco posterior al renombrado hasta el primero posterior a que el endpoint refleje la vuelta. En este caso, 4 refrescos fallidos en 24 h.

### H3 · Por qué los usuarios ven datos de ayer (parte medida, parte inferencia)

- **Medido:** el modelo tiene 13.000.000 filas hasta 2026-09-15 y 161.879 clientes; gold (v14) tiene 15.000.000 filas hasta 2026-09-17 y 158.950 clientes. Las cifras del modelo coinciden con las de gold v12 (13.000.000 filas de `fact_sales` y 161.879 en `dim_customer`, informe 09, E10). Es decir, el modelo contiene la carga del 3-nov 08:26 (run 15) y no las del 4 y 5-nov (E9, E10, E12).
- **Por qué (medido):** un refresco fallido no cambia los datos del modelo (Import, modo transaccional por defecto de `refresh_dataset`, E13), así que sigue la última instantánea buena. Esa instantánea es la del refresco del 4-nov 05:27-05:31, que además cargó v12 aunque gold ya tenía v13 desde las 05:22:52 (inferencia: el endpoint aún servía v12, mismo retardo que en H2). Después, 3 refrescos seguidos fallaron.
- **Otras causas de datos del día anterior:** (a) el refresco programado de las 04:30 UTC se ejecuta 30 min antes de que arranque el pipeline (05:00 UTC), de modo que siempre carga la carga anterior (E2, E3); (b) el 1-nov el pipeline falló en la ingesta (`DELTA_FAILED_TO_MERGE_FIELDS ... 'amount'`), no se reconstruyó gold y los refrescos programados cargaron los mismos datos (E3, E9).
- **Impacto:** esta mañana, los usuarios ven datos hasta el 15-sep cuando el negocio espera hasta el 17-sep.

### H4 · Cómo lanza y vigila el pipeline el refresco (medido)

- **Tipo de actividad:** `TridentNotebook` ejecutando `nb_04` después de `Silver to gold` con condición `Succeeded` (orden correcto respecto a la carga de gold). Una única actividad termina en 2-3 min (incluye el arranque de la sesión) (E4, E5).
- **Asíncrono y sin espera:** `fabric.refresh_dataset(...)` hace una petición de refresco mejorado y devuelve el id; el notebook no consulta el estado (`get_refresh_execution_details`) ni espera. La actividad termina cuando el notebook devuelve, no cuando el refresco acaba (E6, E13).
- **Sin comprobación de resultado:** el `except Exception` solo imprime `WARNING` y deja que el notebook acabe bien, de modo que un fallo al pedir el refresco no hace fallar la actividad ni el pipeline. Ningún refresco fallido de E1 se refleja en el estado del pipeline: las 4 ejecuciones afectadas (10-30 19:30, 11-04, 11-05) terminaron `Completed` (E3, E4, E6).
- **Reintentos:** `retry: 0` en las cuatro actividades y `retry_count = 0` por defecto en `refresh_dataset`; no hay reintento ni espera entre gold y refresco (E5, E13).
- **Medido, 5-nov:** `Refresh semantic model` acabó `Succeeded` a las 05:30:37 y el historial no tiene ninguna entrada `ViaEnhancedApi` de ese día. **Inferencia:** el notebook habría pedido el refresco hacia las 05:30:30 (el 4-nov lo pidió 8 s antes de acabar la actividad), cuando el programado de las 05:30:02 ya estaba en curso, y la petición habría sido rechazada y quedado en el `WARNING` sin error. No se obtuvo la salida del notebook para confirmarlo (ver Notas).
- **Sincronización de gold:** no hay paso que fuerce o espere la sincronización del SQL endpoint entre `Silver to gold` y el refresco (E5, E13).

### H5 y H6

- **H5:** 3 disparadores para un solo refresco útil: programados a las 04:30 UTC (antes del pipeline) y 05:30 UTC (en el cierre del pipeline, 05:25-05:31), más la petición de `nb_04`. El de las 05:30 arranca 2-5 min después del final del pipeline de los días 31-oct a 4-nov y a las 05:30:02 del 5-nov, 38 s antes de que acabe el pipeline (E1-E3). `notifyOption = NoNotification`: los 4 fallos no avisan a nadie (E2).
- **H6:** `Ingest bronze` falló el 10-30 18:43 (run 6) y el 11-01 05:00 (run 12) con `DELTA_FAILED_TO_MERGE_FIELDS ... 'amount'` (E3). Son runs múltiplos de 6; la causa no se investigó (fuera del alcance), pero las dos veces gold no se reconstruyó. Confianza Media: solo se tiene el mensaje del pipeline.

### H7 · Errores de los usuarios

No se ha encontrado evidencia de errores de visuales ni de consultas fallidas. Lo que sí se midió es: 4 refrescos fallidos (que en Import no afectan a los datos servidos), y 2 días de datos antiguos. Candidatos no verificados (Confianza Baja): usuarios que abren el informe mientras el refresco programado (8-11 min) y el del pipeline compiten por la capacidad FTL64; usuarios que perciben como "error" que los totales no cuadren con los esperados; la lectura de las 3 medidas afectadas por claves huérfanas (informe 09, H1). No se pudo comprobar ninguna.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Quitar el renombrado de `category` en `nb_03` (o versionar el contrato con una vista estable) | H1, H2 | Alto | Bajo | Bajo | Sí |
| R2 | Hacer que `nb_04` espere y falle si el refresco no acaba en `Completed` | H4 | Alto | Bajo | Bajo | Sí |
| R3 | Sincronizar el SQL endpoint antes del refresco | H2, H3 | Alto | Bajo | Bajo | Sí |
| R4 | Alinear los calendarios: un solo refresco, tras el pipeline | H5 | Medio | Bajo | Bajo | Sí |
| R5 | Activar avisos de fallo del refresco y del pipeline | H4, H5 | Medio | Bajo | Bajo | Sí |
| R6 | Investigar la deriva de `amount` en ingesta | H6 | Medio | Medio | Bajo | Sí |

### R1 · Contrato estable de `dim_product`

- **Cambio propuesto:** en `nb_03`, fijar `product_schema_v2_every = 0` (no renombrar). Si el catálogo v2 es obligatorio, publicar el nombre nuevo en otra columna o vista (`product_category`) y mantener `category` hasta migrar el modelo, o cambiar el modelo y `nb_03` a la vez (renombrar la columna en la consulta del modelo) en el mismo despliegue.
- **Impacto esperado:** desaparece el patrón de fallos cada 4 ejecuciones.
- **Cómo validarlo:** comprobar con E9 que no hay más versiones con `product_category`, y que los refrescos de las 4 ejecuciones siguientes (runs 20, 24...) terminan `Completed`.
- **Reversión:** volver al valor 4.
- **Requiere confirmación:** Sí: edita un notebook de producción (Tier C).

### R2 · `nb_04` con espera y verificación

- **Cambio propuesto:** tras `refresh_dataset`, sondear `fabric.get_refresh_execution_details(dataset, request_id)` hasta un estado final, lanzar excepción si no es `Completed`, quitar el `try/except` que oculta el error y poner `retry` en la actividad. Alternativa: usar la actividad nativa de refresco de modelo semántico del pipeline, que espera al resultado.
- **Impacto esperado:** un refresco fallido hace fallar `Refresh semantic model` y el pipeline, con visibilidad inmediata.
- **Cómo validarlo:** forzar una ejecución con el esquema roto en un entorno de prueba y comprobar que el pipeline acaba `Failed`.
- **Reversión:** restaurar el notebook.
- **Requiere confirmación:** Sí.

### R3 a R6

- **R3:** añadir al pipeline, entre `Silver to gold` y el refresco, la actividad "Refresh SQL analytics endpoint" (Learn, E13) o llamar a la API de refresco de metadatos. Impacto: el refresco ve gold completo. Validación: el refresco posterior a cada carga trae la última `business_date` (hoy 2026-09-17). Confirmación: Sí.
- **R4:** eliminar los refrescos programados de las 04:30 y 05:30 UTC (o, como red de seguridad, mover uno a las 06:30 UTC, una vez acabe el pipeline) y dejar el pedido por el pipeline como único refresco; así no se solapan y no se cargan datos antiguos a las 04:30. Validación: sin entradas `Scheduled` solapadas con `ViaEnhancedApi` en E1. Confirmación: Sí.
- **R5:** `notifyOption` del refresco a `MailOnFailure` y alerta de fallo del pipeline. Validación: un fallo provoca un aviso. Confirmación: Sí.
- **R6:** revisar el esquema de `amount` entre la fuente de ingesta y `silver.sales` en las ejecuciones 6 y 12 (`DESCRIBE HISTORY` y esquema por versión en bronze/silver). Confirmación: Sí si requiere cambios.
- **Reversión de R3-R6:** restaurar la configuración anterior.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | El refresco se pide antes de que termine gold | E4 | `Refresh semantic model` empieza después de `Silver to gold` (05:28:13 frente a 05:28:10 el 5-nov; 05:25:14 frente a 05:25:12 el 4-nov) |
| D2 | Cambian otras tablas de gold de esquema (renombrados o tipos) | E9 | `fact_sales`, `dim_customer` y `dim_store` mantienen el mismo esquema en las 15 versiones; `promotions` y `dim_date` tienen una sola versión |
| D3 | El error viene de una columna que se eliminó de `dim_product` | E9 | `category` no se elimina: se renombra de forma temporal y vuelve |
| D4 | El pipeline falla cuando falla el refresco | E3, E4, E6 | Ninguna ejecución fallida del refresco hizo fallar el pipeline |

## Siguientes pasos

- [ ] Aplicar R1 y R2 en `nb_03` y `nb_04` — responsable: ingeniería de datos · relacionado con: R1, R2
- [ ] Añadir el paso de sincronización del endpoint y alinear calendarios (R3, R4) — responsable: ingeniería de datos / propietario del modelo · relacionado con: R3, R4
- [ ] Revisar con el propietario del modelo si hay avisos de fallo activos (R5) — relacionado con: R5
- [ ] Obtener la salida del notebook `nb_04` del 5-nov desde la vista de monitorización para confirmar la petición rechazada — responsable: analista · relacionado con: H4
- [ ] Repetir el análisis tras aplicar R# para validar el impacto

## Notas

### Limitaciones

- **Evidencia medida:** historial de refresco, calendarios, ejecuciones del pipeline, esquema y commits Delta por versión, código de los notebooks y del pipeline, recuentos del modelo y del lakehouse.
- **Inferencia:** el retardo del SQL endpoint como causa del momento exacto de los fallos y de la carga de v12 el 4-nov (H2, H3); la petición rechazada del 5-nov (H4); los candidatos de H7.
- El historial de refresco empieza el 2026-10-30 19:30 UTC; los 6 primeros runs manuales (17:11-19:06) no aparecen (la API lista 20 entradas).
- El horario de los commits Delta se toma del `timestamp` de `commitInfo`; el de los refrescos, de la API de Power BI; ambos en UTC.
- La zona horaria "Romance Standard Time" se tradujo a UTC+1 (horario de invierno desde el 25-oct), coherente con las horas medidas (pipeline arrancando a las 05:00 UTC).

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| `demo-setup/` del repositorio | Permiso denegado en la sesión | Se leyeron las definiciones reales de los items del workspace (más fiables que los ficheros del repositorio) |
| Salida del notebook `nb_04` en cada ejecución | La API consultada no expone la salida de las celdas | No se confirma el `WARNING` del 5-nov |
| Hora de sincronización del SQL endpoint | La DMV de sincronización nueva (preview) no se consultó y el endpoint puede estar en el modo antiguo | Retardo inferido, no medido |
| Errores de usuario en el informe | No hay telemetría de errores de visuales al alcance | H7 sin confirmar |
| Causa de la deriva de `amount` en ingesta | Fuera del alcance | H6 con Confianza Media |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| "Column does not exist in the rowset" | `semantic-models.md` apunta a comparar el esquema por versión Delta y el código del escritor | Learn añade que el SQL endpoint puede tardar en reflejar cambios de esquema y ofrece la actividad y la API de refresco de metadatos | Se aplicó el método de la skill y se añadió la sincronización del endpoint como causa del momento de los fallos (inferencia) |

## Anexo

### Configuración efectiva

```python
# nb_03 (fragmento relevante, E7)
product_schema_v2_every = 4
if product_schema_v2_every > 0 and run_seq % product_schema_v2_every == 0:
    dim_product = dim_product.withColumnRenamed("category", "product_category")
dim_product.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable("dim_product")

# nb_04 (E6)
try:
    request_id = fabric.refresh_dataset(dataset=semantic_model, refresh_type="full")
    print(f"Refresh of {semantic_model} requested: {request_id}")
except Exception as exc:
    print(f"WARNING: could not request the refresh of {semantic_model}: {exc}")
```
