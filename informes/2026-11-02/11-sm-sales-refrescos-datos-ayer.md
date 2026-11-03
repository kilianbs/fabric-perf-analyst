# Refrescos de sm_sales: "datos de ayer" por fallo silencioso de la carga y un refresco de las 05:30 UTC que siempre llega antes que los datos

Seguimiento de [07-sm-sales-avg-ticket-lento.md](07-sm-sales-avg-ticket-lento.md), [08-sm-sales-resto-pagina.md](08-sm-sales-resto-pagina.md), [09-sm-sales-buenas-practicas-modelado.md](09-sm-sales-buenas-practicas-modelado.md) y [10-sm-sales-memoria-modelo.md](10-sm-sales-memoria-modelo.md). Solo lectura: sin refrescos manuales, sin Livy y sin ClearCache.

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-02 |
| **Áreas** | Semantic models (refrescos); pivotes a Spark runs (pipeline y notebooks), Delta tables (hora de escritura de Gold) y Capacity |
| **Ámbito** | workspace `FabricPerfLab` · `sm_sales`, `pl_daily_sales`, `nb_01_ingest_bronze`, `nb_03_silver_to_gold`, `nb_04_refresh_model`, tablas de `lh_gold` |
| **Ventana analizada** | 2026-10-30 17:00 → 2026-11-02 20:56 UTC (todo el historial disponible: el modelo se creó el 2026-10-30 17:03 UTC) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, semantic-model-authoring, spark-cli |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Media |

## Resumen

- **Pregunta:** los usuarios ven a veces los datos de ayer o un error; ¿se refresca bien `sm_sales`?
- **Conclusión:** los refrescos del modelo no fallan: los 6 programados terminaron en `Completed`. Los "datos de ayer" vienen de la fuente. El domingo 2026-11-01 la carga `pl_daily_sales` falló (`DELTA_FAILED_TO_MERGE_FIELDS ... 'amount'`), Gold no se actualizó y el refresco de las 05:30 UTC terminó en `Completed` sobre datos de 24 h. Además, el refresco programado de las 04:30 UTC (05:30 locales) corre siempre antes de la carga (05:00 UTC) y refresca datos viejos durante ~10 min.
- **Impacto:** 1 de 3 días programados (33 %) con datos de ayer sin que nada fallara ni avisara; `nb_04_refresh_model` lanza el refresco sin esperarlo y traga las excepciones; el refresco de las 05:30 UTC empieza 3 min 47 s a 5 min después del final de la carga. Los "errores" no se pudieron reproducir ni atribuir con los datos disponibles (ver Limitaciones).
- **Primera acción:** R1, avisar de los fallos del pipeline y hacer que `nb_04` espere y propague el error del refresco.

## Alcance

**Pregunta original:** diagnosticar en solo lectura el historial de refrescos (inicio, fin, duración, estado, errores, tendencia, solapes, refrescos tardíos, schedule), si Gold se actualiza antes del refresco, correlación con capacidad, memoria (806 MiB, doble en memoria al refrescar) y claves huérfanas, y distinguir "datos de ayer" de "error".

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Historial de refrescos, schedule, ejecuciones del pipeline y notebooks, `_delta_log` de Gold, partición del modelo, capacidad (SKU y memoria) | Trazas de consultas de usuarios, horas reales de uso de los informes, CU y throttling (no disponibles, ver Notas), cualquier refresco o cambio |

**Hipótesis de partida:** H-a) refresco fallido o cancelado; H-b) schedule anterior a la carga; H-c) carga fallida deja Gold viejo; H-d) memoria o throttling; H-e) solape de refrescos.

**Recorrido:** Semantic models (E1, E2) → Spark runs (E3-E5: el refresco las 05:30 UTC no explica los datos viejos; falla la carga) → Delta tables (E6: hora de escritura de Gold, que confirma la secuencia) → Capacity (E8: SKU; CU sin datos).

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad (SKU · región) | Trial `FTL64` (equivale a F64) · West Europe, estado Active | E8 |
| Modo de almacenamiento del modelo | Import; origen `Sql.Database(... lh_gold)` por el endpoint SQL, 6 particiones, una por tabla | E7 |
| Schedule del modelo | Diario, 05:30 y 06:30, zona `Romance Standard Time`, activo, sin notificaciones (`NoNotification`) | E2 |
| Schedule del pipeline `pl_daily_sales` | Diario 06:00 locales, zona `Romance Standard Time`, desde 2026-10-31 hasta 2026-11-30 | E3 |
| Zona horaria efectiva | CET (UTC+1) tras el cambio horario del 25-oct: 05:30 locales = 04:30 UTC; 06:30 = 05:30 UTC; 06:00 = 05:00 UTC. Coincide con las horas observadas | E1, E3 |
| Permisos con los que se ejecutó | Lectura de refrescos, schedules, jobs y OneLake; sin acceso a datos de CU | E1-E8 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| sm_sales | SemanticModel | Consumo | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |
| pl_daily_sales | DataPipeline | Orquestación | bd706b1d-499f-4a0d-bb22-222312944ca1 |
| nb_01 / nb_03 / nb_04 | Notebook | Ingesta / Gold / refresco | 4240632d-... / c7cca4b7-... / 3a609552-... |
| lh_gold | Lakehouse | Gold | 3aee923d-121b-415b-872c-4d5bb70664c0 |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Refrescos en el historial | 17 (9 el 30-oct, 8 desde el 31-oct); 15 `Completed`, 2 `Failed`, 0 `Cancelled`, 0 `Disabled` | `semantic-model-rest-api.md` § Refresh History Response Properties | E1 |
| Refrescos programados | 6 de 6 `Completed` | | E1 |
| Duración del refresco programado de las 04:30 UTC | 498, 622, 621 s | | E1 |
| Duración del refresco programado de las 05:30 UTC | 481, 493, 500 s | | E1 |
| Duración del refresco lanzado por `nb_04` | 172, 181 s | | E1 |
| Fin de `pl_daily_sales` frente al refresco de las 05:30 UTC | 05:26:15 (31-oct) y 05:25:02 (2-nov) frente a 05:30:01,8 y 05:30:02,2 | Margen 3 min 47 s y 5 min | E1, E3 |
| Duración de `pl_daily_sales` | 914 → 1 621 s en 9 ejecuciones manuales del 30-oct; 1 572 y 1 499 s en las programadas | | E3 |
| Última escritura de Gold | 2026-10-31 05:21:52 UTC y 2026-11-02 05:22:17 UTC; ninguna el 11-01 | | E6 |
| Memoria por refresco | 806,2 MiB × 2 ≈ 1,6 GiB, frente a 25 GB por modelo en F64/FT1 | Learn: Semantic model SKU limitation | E8, 10 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1.0/myorg/groups/{ws}/datasets/{sm}/refreshes?$top=100` (audiencia Power BI) | 17 entradas, todas las disponibles. Programados (`Scheduled`): 10-31 04:30:03-04:38:21, 05:30:01-05:38:03; 11-01 04:30:01-04:40:24, 05:30:02-05:38:15; 11-02 04:30:01-04:40:23, 05:30:02-05:38:22 (todos `Completed`). Vía API (`ViaEnhancedApi`): 10-31 05:25:56-05:28:48, 11-02 05:24:52-05:27:54 (`Completed`) y 9 del 30-oct (17:26 a 20:18), de los que 2 `Failed` (18:42:16 y 19:50:58): `ModelRefresh_ShortMessage_ProcessingError`, "The 'category' column does not exist in the rowset" |
| E2 | REST | `GET .../datasets/{sm}/refreshSchedule` y `GET .../datasets/{sm}` | Activo, todos los días, 05:30 y 06:30, `Romance Standard Time`, `NoNotification`; `isRefreshable` verdadero; sin réplicas de escalado |
| E3 | REST | `GET /v1/workspaces/{ws}/items/{pl}/jobs/instances` y `.../jobs/Pipeline/schedules` | Programadas: 10-31 05:00:02-05:26:15 `Completed`; **11-01 05:00:02-05:01:21 `Failed`**; 11-02 05:00:02-05:25:02 `Completed`. Fallo: "Operation on target Ingest bronze failed ... `[DELTA_FAILED_TO_MERGE_FIELDS] Failed to merge fields 'amount' and 'amount'`". Mismo error el 10-30 18:43 (manual, rehecho a las 18:44). Schedule 06:00 locales |
| E4 | REST | `GET .../items/{nb}/jobs/instances` (nb_01, nb_03, nb_04) y schedules `RunNotebook` | nb_01 11-01 05:00:30-05:01:12 `Failed` (`System_Cancelled_Session_Statements_Failed`). nb_03 y nb_04 no se ejecutaron el 11-01. 10-31: nb_03 05:17:26-05:23:25, nb_04 05:23:39-05:25:59. 11-02: nb_03 05:17:16-05:24:02, nb_04 05:24:30-05:25:01. Sin schedules propios en los notebooks |
| E5 | REST | `POST .../notebooks/{nb_04}/getDefinition` (lectura) | `fabric.refresh_dataset(dataset=..., refresh_type="full")` dentro de `try/except` que solo imprime "WARNING"; no espera el resultado |
| E6 | OneLake | Lectura de `lh_gold/Tables/*/_delta_log` (fechas de los JSON y esquemas) | `fact_sales` commit 9 el 10-31 05:21:52Z y commit 10 el 11-02 05:22:17Z; dimensiones 05:22:47 a 05:23:39 el 10-31 y 05:23:21 a 05:23:39 el 11-02; `dim_date` y `promotions`: solo commit 0 (10-30 17:25). `dim_product` commits 3 (18:22:28Z) y 6 (19:29:08Z) con la columna `product_category`; commits 4 (18:40:48Z) y 7 (19:49:51Z) vuelven a `category` |
| E7 | DAX | `INFO.PARTITIONS()` | `RefreshedTime` del 11-02: `fact_sales` 05:37:04, dimensiones 05:35:26-05:35:29 (UTC). Origen: endpoint SQL de `lh_gold` |
| E8 | REST | `GET /v1/capacities` y consultas al modelo de Capacity Metrics (`executeQueries`) | Capacidad del workspace: `FTL64`, Active, West Europe. El modelo "Fabric Capacity Metrics" no tiene datos: `Capacities` solo contiene la fila de muestra, `Items` 0 filas, `Capacity States By Day` y `Max Memory By Item` sin fila actual, y su historial de refrescos está vacío |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | El 11-01 la carga falló y el modelo se refrescó "con éxito" sobre datos de 24 h | Alta | Alta | E1, E3, E4, E6 |
| H2 | El refresco de las 04:30 UTC corre siempre antes de la carga: refresca datos viejos | Media | Alta | E1, E2, E3, E6 |
| H3 | `nb_04` lanza el refresco sin esperar ni propagar el error, y el schedule deja un margen de 3,8 a 5 min | Media | Alta | E1, E3, E5 |
| H4 | Los fallos del 30-oct coinciden con cambios de nombre de la columna en Gold (`category` / `product_category`) | Media | Media | E1, E6 |
| H5 | No hay datos de CU ni de consultas fallidas para explicar los "errores" | Media | Alta | E8 |

### H1 · Un día de datos viejos sin refresco fallido

- **Qué ocurre:** el domingo 11-01 `pl_daily_sales` falló a los 79 s en "Ingest bronze" por `DELTA_FAILED_TO_MERGE_FIELDS ... 'amount'` (E3, E4); `nb_03` y `nb_04` no se ejecutaron. Gold no tuvo ninguna escritura entre el 10-31 05:21:52 UTC y el 11-02 05:22:17 UTC (E6). Los dos refrescos programados del 11-01 (04:30 y 05:30 UTC) terminaron `Completed` (E1) y cargaron los datos del 10-31, con una antigüedad de unas 24 h al cierre del refresco (05:38:15 UTC).
- **Por qué:** la dependencia entre carga y modelo no está acoplada: el modelo se refresca por hora (E2), no por el resultado del pipeline, y no hay notificación (`NoNotification`, sin alerta de fallo). Nadie repitió la carga; el 10-30 sí se repitió a mano a los 29 s. El mismo error `amount` ya había aparecido el 10-30 (E3), así que es recurrente (deriva de esquema, área Spark runs/Delta; no se diagnosticó en este informe).
- **Impacto:** de 3 días programados (31-oct, 1-nov, 2-nov), uno con datos de ayer sin fallo visible. Es el escenario "datos de ayer" que describen los usuarios.

### H2 · Refresco de las 04:30 UTC antes de la carga

El refresco de las 05:30 locales (04:30 UTC) empieza 30 min antes del pipeline (05:00 UTC) y dura 498 a 622 s (E1, E2, E3). Siempre lee el Gold del día anterior (última escritura 05:22 UTC del día anterior, E6), consume ese tiempo de cómputo y es el más lento de la serie. El de las 06:30 locales (05:30 UTC) es el que sirve. No genera error, pero cuesta ~10 min de capacidad cada día sin beneficio.

### H3 · Acoplamiento débil entre carga y refresco

- `nb_04` pide un refresco `full` y termina sin esperarlo; si la petición falla, imprime un aviso y el notebook acaba en `Completed` (E5). El pipeline no puede reflejar un fallo del refresco.
- Margen del schedule: el pipeline termina a las 05:26:15 (10-31) y 05:25:02 (11-02) y el refresco de las 05:30 UTC arranca 3 min 47 s y 5 min después (E1, E3). El pipeline pasó de 914 a 1 621 s durante las pruebas del 30-oct (+77 %); aun así, las dos ejecuciones programadas duraron 1 572 y 1 499 s. Si la carga superase ~30 min, el refresco leería Gold a medio escribir (las tablas se escriben en secuencia durante ~1,5 min, E6).
- Cercanía con el refresco de `nb_04`: el 10-31 terminó a las 05:28:48, 73 s antes de que arrancara el programado; el 11-02, 2 min 8 s antes (E1). No se observó solape real; el comportamiento de dos refrescos simultáneos del mismo modelo no se probó.

### H4 · Fallos de refresco del 30-oct

Los dos únicos refrescos fallidos (18:42:16 y 19:50:58, ambos vía API) fallaron por la columna `category` ausente (E1). En Gold, `dim_product` cambió de `category` a `product_category` en los commits 3 y 6 y volvió a `category` en los 4 y 7 (E6). Los refrescos posteriores a los commits con `product_category` (18:23:17 y 19:30:22) terminaron bien y los posteriores a los commits con `category` (18:42:16 y 19:50:58) fallaron: patrón compatible con que el endpoint SQL tarda en sincronizar los metadatos del esquema y el modelo ve el esquema anterior. Es una hipótesis (Media): no se midió el retardo de sincronización. Desde el 10-31 el esquema es estable (commits 8 a 10 sin cambios de metadatos).

### H5 · "Errores": lo que no se puede ver

No hay datos de CU, throttling, memoria ni consultas fallidas: la app Fabric Capacity Metrics instalada en el tenant nunca se ha refrescado (E8), y no hay registro de consultas del modelo (Log Analytics o monitorización del workspace) en lo que pude leer. Por eso no se puede asociar ningún error de usuario a una hora o a un refresco concreto.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Alertas de fallo del pipeline y `nb_04` que espere y propague el error | H1, H3 | Alto | Bajo | Bajo | Sí |
| R2 | Corregir la causa del error `amount` en la ingesta (deriva de esquema) | H1 | Alto | Medio | Medio | Sí |
| R3 | Quitar el refresco programado de las 05:30 locales y reubicar el de las 06:30 con más margen | H2, H3 | Medio | Bajo | Bajo | Sí |
| R4 | Fijar el esquema de `dim_product` en `nb_03` y sincronizar el endpoint SQL antes de refrescar | H4 | Medio | Medio | Bajo | Sí |
| R5 | Habilitar visibilidad de capacidad y de consultas | H5 | Medio | Bajo | Bajo | Sí |

### R1 · Avisar y propagar

- **Cambio propuesto:** (a) notificación de fallo en `pl_daily_sales` (correo, Teams o Activator) y en el refresco del modelo (`notifyOption` distinto de `NoNotification`); (b) en `nb_04`, quitar el `try/except` que solo imprime, esperar a que el refresco termine y lanzar una excepción si falla (comprobar en la documentación de `sempy` el método de espera disponible); (c) un indicador de frescura en el informe (por ejemplo, la fecha de última carga de Gold).
- **Impacto esperado:** un fallo como el del 11-01 se detecta en minutos y no hasta que un usuario lo nota.
- **Cómo validarlo:** forzar un fallo en un entorno de prueba y comprobar la alerta; repetir E1/E3 a diario durante una semana.
- **Reversión:** volver al estado anterior.
- **Requiere confirmación:** Sí, cambios en items y schedules (Tier C).

### R2 a R5

- **R2:** la ingesta falla al fusionar `amount` (tipo distinto entre el destino y la fuente): fijar el esquema o el tipo en la lectura (por ejemplo, forzar `DecimalType`/`DoubleType` explícito) o definir la política de evolución de esquema. Debe revisarse con `nb_01` y el área Spark runs; no se profundizó aquí.
- **R3:** eliminar la hora de las 05:30 locales (04:30 UTC) y mover la de las 06:30 locales (05:30 UTC) a una hora con margen, o encadenarla al final del pipeline; al hacerlo, tener en cuenta que `nb_04` ya refresca al terminar la carga (172-181 s). Medir el margen con E1 y E3 durante una semana.
- **R4:** estabilizar el nombre de columna `category` en `nb_03`; añadir antes de `refresh_dataset` una sincronización de metadatos del endpoint SQL de `lh_gold` (la operación existe como API de Fabric; verificarla antes de adoptarla). Medir con las mismas consultas.
- **R5:** refrescar y configurar la app Fabric Capacity Metrics (así E8 devuelve CU, throttling y memoria por elemento) y habilitar un registro de consultas del modelo (Log Analytics o monitorización del workspace) para atribuir los errores de usuario a una hora.
- **Requiere confirmación (todas):** Sí.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Refrescos programados fallidos, cancelados o desactivados | E1, E2 | 6 de 6 `Completed`; schedule activo; no hay estados `Cancelled` ni `Disabled` |
| D2 | Falta de memoria al refrescar (copia previa al commit) | E8, 10 | 806,2 MiB × 2 ≈ 1,6 GiB, por debajo del 7 % de los 25 GB por modelo de F64/FT1; ningún refresco falló por memoria |
| D3 | Solape entre refrescos programados | E1 | 04:30-04:40 UTC y 05:30-05:38 UTC no coinciden; el refresco vía API termina 73 s y 2 min 8 s antes del programado |
| D4 | Cambio horario (DST) desalineando carga y refresco | E2, E3 | Ambos usan `Romance Standard Time` y las horas observadas son las esperadas para CET; el próximo cambio afectaría a los dos por igual |
| D5 | Claves huérfanas como causa de fallo o de datos viejos | 09, 10 | La integridad referencial (`RIVIOLATION_COUNT` = 1 en `dim_customer`, 10 E5) no hace fallar el refresco; los huérfanos son constantes (17,3 %) y no varían con la hora |
| D6 | Refrescos tardíos respecto al uso de los informes | E1 | Los programados terminan a las 05:38 UTC (06:38 locales); no se conoce la hora de uso real (H5), así que no se puede afirmar nada más |

## Siguientes pasos

- [ ] Aplicar R1 (alertas y `nb_04`) — responsable: propietario de la carga y del modelo · relacionado con: R1
- [ ] Analizar el fallo `DELTA_FAILED_TO_MERGE_FIELDS ... 'amount'` en `nb_01` — responsable: ingeniería de datos · relacionado con: R2
- [ ] Decidir el calendario de refrescos — responsable: propietario del modelo · relacionado con: R3
- [ ] Habilitar la app de capacidad y el registro de consultas, y pedir a los usuarios la hora y el informe de los errores — responsable: administración / propietario del informe · relacionado con: R5
- [ ] Repetir el análisis tras una semana con R1-R3 aplicadas

## Notas

### Limitaciones

- Solo hay 3 días de datos desde la creación del modelo (el 30-oct fue desarrollo con ejecuciones manuales); los patrones (p. ej. el fallo de los domingos) no se pueden generalizar. El 11-01 es domingo, pero el pipeline es diario; no se probó si el error depende del día.
- El historial devuelve 17 entradas con `$top=100`, es decir, todo lo disponible.
- La hora de uso de los informes y los errores concretos de los usuarios no se han podido obtener (H5). Los "errores" quedan sin diagnosticar: lo único medido es que ningún refresco programado falló.
- La hipótesis H4 (retardo de sincronización del endpoint SQL) no se midió.
- `nb_04` mide 172 a 181 s por refresco frente a 481 a 622 s de los programados, aunque ambos son `full`; no encontré la causa en los datos disponibles.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| CU, throttling y memoria por hora | El modelo de Capacity Metrics no tiene datos (nunca se refrescó); FabricIQ no conectó (401) | H5 sin cifras; descarte de memoria solo por límites documentados |
| Consultas fallidas por hora | No hay Log Analytics ni traza | No se pueden asociar errores de usuario a horas |
| Hora de uso de los informes | Sin métricas de uso | D6 no concluyente |
| Retardo de sincronización del endpoint SQL | No consultado | H4 sigue como hipótesis |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Límite de memoria por modelo | `semantic-model-rest-api.md` no lo cubre | Learn: Semantic model SKU limitation (F64: 25 GB; el refresco puede superar el doble del tamaño del modelo) | Aplicada la documentación de Learn |

## Anexo

### Consultas completas

```text
GET https://api.powerbi.com/v1.0/myorg/groups/{ws}/datasets/{sm}/refreshes?$top=100
GET https://api.powerbi.com/v1.0/myorg/groups/{ws}/datasets/{sm}/refreshSchedule
GET https://api.fabric.microsoft.com/v1/workspaces/{ws}/items/{item}/jobs/instances?limit=30
GET https://api.fabric.microsoft.com/v1/workspaces/{ws}/items/{pl}/jobs/Pipeline/schedules
GET https://onelake.dfs.fabric.microsoft.com/{ws}/{lh_gold}/Tables/{tabla}/_delta_log/<n>.json
```

### Configuración efectiva

Cronología UTC de los días programados:

| Día | 04:30 refresco | 05:00 pipeline | Fin de carga | 05:30 refresco | Gold actualizado |
|-----|----------------|----------------|--------------|----------------|------------------|
| 10-31 (sáb) | 04:30-04:38 `Completed` | 05:00-05:26 `Completed` | 05:26:15 | 05:30-05:38 `Completed` | Sí, 05:21-05:23 |
| 11-01 (dom) | 04:30-04:40 `Completed` | 05:00-05:01 `Failed` | no hubo carga | 05:30-05:38 `Completed` (datos del 10-31) | No |
| 11-02 (lun) | 04:30-04:40 `Completed` | 05:00-05:25 `Completed` | 05:25:02 | 05:30-05:38 `Completed` | Sí, 05:22-05:23 |
