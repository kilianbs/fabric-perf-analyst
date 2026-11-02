# Fallos de `pl_daily_sales`: ejecuciones fallidas y motivo

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-02 |
| **Áreas** | Spark runs (fallos), con comprobación aguas abajo en Delta tables y semantic models |
| **Ámbito** | workspace `FabricPerfLab` · `pl_daily_sales`, `nb_01_ingest_bronze`, `lh_bronze`, `sm_sales` |
| **Ventana analizada** | 2026-10-30 17:11 → 2026-11-02 05:38 UTC (todo el historial disponible del pipeline: 13 ejecuciones) |
| **Agente / host** | GitHub Copilot (VS Code) · skills: spark-cli, sqldw-cli, fabric-perf-analysis |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Alta (fallo de ingesta); Media (refrescos del modelo) |

## Resumen

- **Pregunta:** qué ejecuciones de `pl_daily_sales` han fallado y por qué.
- **Conclusión:** fallaron 2 de 13 (15 %), las dos en la actividad `Ingest bronze`, con `[DELTA_FAILED_TO_MERGE_FIELDS] Failed to merge fields 'amount' and 'amount'`. `nb_01` convierte `amount` a texto (`"70.18 EUR"`) cuando `run_seq` es múltiplo de 6, y el `append` a una columna numérica falla.
- **Impacto:** cada fallo deja un día de negocio sin cargar y no se recupera solo: faltan 2026-09-06 y 2026-09-12 en `sales_raw` (11 de 13 días) y, por tanto, aguas abajo. Además hay 2 refrescos de `sm_sales` fallidos con el pipeline en verde.
- **Primera acción:** R1, validar el esquema de `amount` en `nb_01` y no consumir `run_seq` antes de que la carga termine; R2, recargar los 2 días perdidos. Ambas requieren confirmación.

## Alcance

**Pregunta original:** «También he visto que el pipeline a veces falla, ¿puedes revisar las ejecuciones fallidas y el motivo?»

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| 13 ejecuciones de `pl_daily_sales`; error y actividad de las fallidas; datos que faltan en bronze; refrescos de `sm_sales` | Logs de Spark de las sesiones fallidas (no consultados: el mensaje de error ya identifica la causa); `pl_store_snapshot`; alertas o reintentos configurados |

**Hipótesis de partida:** fallo de datos (esquema) en la ingesta, o fallo de recursos (OOM, cola de capacidad).

**Recorrido:** Spark runs → Delta tables (qué falta en `sales_raw`) → semantic models (refrescos, por sospechar fallos silenciosos).

## Contexto

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| `pl_daily_sales` | Pipeline | Orquestación | `bd706b1d-499f-4a0d-bb22-222312944ca1` |
| `nb_01_ingest_bronze` | Notebook | Ingesta | `4240632d-3ce1-422f-a1b2-ddb55d8736e0` |
| `lh_bronze` | Lakehouse | Bronze | `53249a1b-e8a9-4270-9cb4-0f2ce3b10feb` |
| `sm_sales` | Semantic model | Consumo | `a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9` |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Ejecuciones / fallidas | 13 / 2 (15 %) | n/a | E1 |
| Fallidas: `run_seq` | 6 y 12 | múltiplos de `schema_drift_every = 6` | E1, E3, E4 |
| Duración de las fallidas | 82 s y 79 s (actividad: 52 s y 70 s) | vs. 915–1 622 s de las correctas | E1, E2 |
| `isRetriable` | `false` | n/a | E1 |
| Días en `sales_raw` | 11 de 13 | faltan `run_seq` 6 y 12 | E5 |
| Refrescos de `sm_sales` fallidos | 2 de 17 listados | n/a | E6 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces/{ws}/items/{pipelineId}/jobs/instances` | 13 instancias, 11 `Completed`. Fallidas: `1c7c087c-541a-45bb-984c-b935c5fb4a94` (Manual, 2026-10-30 18:43:02 → 18:44:04) y `5d856136-ff80-4711-9fe4-f8abbd4ceec4` (Scheduled, 2026-11-01 05:00:02 → 05:01:21). Ambas `errorCode 2451`, mismo mensaje |
| E2 | REST | `POST /v1/workspaces/{ws}/datapipelines/pipelineruns/{runId}/queryactivityruns` para cada fallida | Una sola actividad, `Ingest bronze` (TridentNotebook), `Failed`; 52,1 s y 70,1 s. No aparecen actividades posteriores |
| E3 | SQL | `SELECT TOP 30 * FROM dbo.ctl_pipeline_runs ORDER BY 1 DESC` en `lh_bronze` | 13 filas (`run_seq` 1–13, `business_date` 2026-09-01 a 2026-09-13); `run_seq` 6 con `started_at` 2026-10-30 18:43:40 y 12 con 2026-11-01 05:00:54 |
| E4 | Código | `demo-setup/items/notebooks/nb_01_ingest_bronze.py` líneas 9, 43–50, 122–126 | `schema_drift_every = 6`; la fila de control se escribe antes de cargar; si `run_seq % 6 == 0`, `amount` pasa a `format_string("%.2f EUR")`; luego `append` a `sales_raw` |
| E5 | SQL | `SELECT run_seq, business_date, COUNT_BIG(*) ... FROM dbo.sales_raw GROUP BY ...` | 11 grupos de 1 000 000 filas; no hay `run_seq` 6 ni 12 (faltan 2026-09-06 y 2026-09-12) |
| E6 | REST | `GET https://api.powerbi.com/v1.0/myorg/groups/{ws}/datasets/{id}/refreshes?$top=20` | 17 refrescos; 2 `Failed` (`ViaEnhancedApi`): 2026-10-30 18:42:16 y 19:50:58, ambos `The 'category' column does not exist in the rowset` |
| E7 | Código | `nb_03_silver_to_gold.py` líneas 6 y 40–41 | Si `run_seq % 4 == 0`, renombra `category` a `product_category` en `dim_product` |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | `Ingest bronze` falla cada 6.ª ejecución por cambio de tipo de `amount` (double → texto) | Alta | Alta | E1, E2, E4 |
| H2 | Cada fallo pierde un día de datos y no se recupera | Alta | Alta | E3, E5 |
| H3 | Dos refrescos de `sm_sales` fallaron sin que el pipeline lo reflejara | Media | Media | E6, E7 |

### H1 · El esquema de `amount` cambia cada 6 ejecuciones

- **Qué ocurre:** las dos ejecuciones fallidas (la manual del 30-oct y la programada del 1-nov) terminan en `Ingest bronze` con `[DELTA_FAILED_TO_MERGE_FIELDS] Failed to merge fields 'amount' and 'amount'`, `isRetriable: false`.
- **Por qué:** en `nb_01`, cuando `run_seq` es múltiplo de 6 el importe se escribe como texto con sufijo `EUR`; `sales_raw` tiene `amount` numérico y Delta rechaza el `append` (E4). Coinciden los `run_seq` fallidos 6 y 12 (E3). No es un fallo de recursos: las fallidas duran 52 y 70 s y el error es de análisis, no de memoria ni de cola.
- **Impacto:** el siguiente fallo previsible es `run_seq` 18, que correspondería a la ejecución programada del 2026-11-07 (inferencia: una ejecución diaria desde `run_seq` 13 el 2-nov).

### H2 · El día fallido queda perdido

- **Qué ocurre:** `sales_raw` tiene 11 días de 1 M filas; faltan `business_date` 2026-09-06 y 2026-09-12 (E5). La ejecución siguiente a cada fallo sigue con el `run_seq` siguiente (7 y 13), no reintenta el día fallido (E3).
- **Por qué:** `nb_01` inserta la fila en `ctl_pipeline_runs` y toma `run_seq` antes de cargar `sales_raw` (E4), de modo que el fallo consume el número. Las 11 M filas de `silver.sales` y `gold.fact_sales` (informe 05, E13 y E20) coinciden con los 11 días.
- **Impacto:** cifras de ventas incompletas en bronze, silver, gold y en el modelo, sin ningún marcador en el pipeline de que falta un día.

### H3 · Refrescos fallidos que el pipeline no muestra

- **Qué ocurre:** `sm_sales` registra 2 refrescos fallidos el 30-oct (18:42:16 y 19:50:58) con `The 'category' column does not exist in the rowset`, mientras que las ejecuciones del pipeline de esas horas terminaron `Completed` (E1, E6).
- **Por qué:** `nb_03` renombra `category` a `product_category` cada 4 ejecuciones (E7) y el modelo sigue esperando `category`. Los refrescos son de tipo `ViaEnhancedApi`, es decir, los lanza la actividad `Refresh semantic model` / `nb_04`; no he leído `nb_04` para confirmar si espera el resultado. No he podido casar de forma exacta qué `run_seq` produjo cada renombrado con la hora de cada fallo (la correlación horaria con las ejecuciones 5 y 9 no coincide con `run_seq % 4`), por eso la confianza es Media.
- **Impacto:** el modelo puede quedar con los datos del refresco anterior. Los refrescos programados posteriores (31-oct a 2-nov) terminaron `Completed`.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Normalizar el tipo de `amount` en `nb_01` antes del `append` y no consumir `run_seq` hasta que la carga termine | H1, H2 | Alto | Bajo | Bajo | Sí |
| R2 | Recargar los días 2026-09-06 y 2026-09-12 | H2 | Alto | Medio | Medio | Sí |
| R3 | Hacer que la actividad de refresco falle el pipeline y alinear el nombre de `category`/`product_category` entre `nb_03` y el modelo | H3 | Medio | Medio | Bajo | Sí |
| R4 | Añadir una alerta (Activator o correo en la actividad) sobre `pl_daily_sales` fallido | H1–H3 | Medio | Bajo | Bajo | Sí |

### R1 · Validar el esquema y retrasar el consumo de `run_seq`

- **Cambio propuesto:**

  ```python
  # Convertir el texto de la fuente v2 a numérico antes de escribir
  sales = sales.withColumn(
      "amount",
      F.regexp_replace(F.col("amount").cast("string"), r"\s*EUR$", "").cast("double"),
  )
  ```

  Y mover el `INSERT` en `ctl_pipeline_runs` (líneas 43–50) a después del `append` correcto, o guardar un estado `Failed`/`Completed`.
- **Impacto esperado:** desaparecen los fallos con ese mensaje y el día fallido ya no consume número. Estimación a partir del código; no probada.
- **Cómo validarlo:** ejecuciones con `run_seq` 18 y 24 en `Completed`, y `SELECT COUNT(DISTINCT business_date) FROM sales_raw` igual al número de ejecuciones correctas.
- **Reversión:** restaurar la versión anterior del notebook.
- **Requiere confirmación:** Sí — cambia un notebook de producción. Convertir un importe de texto con formato es una decisión de negocio (¿la fuente v2 es el nuevo formato definitivo?).

### R2 · Recargar los 2 días perdidos

- **Cambio propuesto:** ejecutar `nb_01` para `business_date` 2026-09-06 y 2026-09-12 (con R1 ya aplicado), y repetir silver y gold. `silver.sales` se reconstruye entera en cada ejecución (informe 01), así que bastará una ejecución completa posterior.
- **Impacto esperado:** `sales_raw` pasa de 11 a 13 M filas; silver y gold lo reflejan en la siguiente ejecución. Añadir 2 M filas aumenta el volumen de lo que ya crece (informes 01 y 02).
- **Cómo validarlo:** `SELECT business_date, COUNT_BIG(*) FROM sales_raw GROUP BY business_date` con 13 días.
- **Reversión:** borrar esas filas por `business_date` (escritura, requiere confirmación).
- **Requiere confirmación:** Sí — ejecuta notebooks y escribe datos.

### R3 y R4 · Que los fallos se vean

- **Cambio propuesto:** que `nb_04` espere el estado del refresco y falle si es `Failed`; mantener `category` en la capa de consumo (o actualizar el modelo a `product_category`); notificar fallos del pipeline.
- **Impacto esperado:** un fallo de refresco o de ingesta deja de pasar desapercibido. No cuantificable.
- **Cómo validarlo:** forzar un fallo en un entorno de prueba y comprobar que el pipeline queda `Failed` y llega la alerta.
- **Reversión:** deshacer el cambio.
- **Requiere confirmación:** Sí — cambia notebooks y configuración de alertas.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Fallo por OOM, timeout o falta de capacidad | E1, E2 | El error es `AnalysisException` de Delta; las fallidas duran 52 y 70 s |
| D2 | Fallo intermitente al azar | E1, E3 | Los dos fallos son `run_seq` 6 y 12, múltiplos de 6 |
| D3 | Los días perdidos se recuperan en la ejecución siguiente | E3, E5 | La siguiente ejecución carga `run_seq` 7 y 13; el hueco sigue |

## Siguientes pasos

- [ ] Decidir el formato definitivo de `amount` con el propietario de la fuente — responsable: negocio/datos · relacionado con: R1
- [ ] Aplicar R1 antes del 2026-11-07 (próxima ejecución con `run_seq` 18) — responsable: ingeniería de datos · relacionado con: R1
- [ ] Recargar los días perdidos — responsable: ingeniería de datos · relacionado con: R2
- [ ] Leer `nb_04` y confirmar si espera el refresco — responsable: analista · relacionado con: R3
- [ ] Repetir el análisis tras aplicar R1 y R2

## Notas

### Limitaciones

- Solo hay 13 ejecuciones disponibles (desde el 30-oct); no se puede saber si hubo fallos anteriores.
- No leí el log de Spark de las sesiones fallidas; el diagnóstico se apoya en el mensaje de error del pipeline y en el código del notebook.
- La numeración `run_seq` ↔ día se infiere de `ctl_pipeline_runs`; la fecha prevista del próximo fallo supone una ejecución programada diaria.
- El código de `nb_01` y `nb_03` es el del repositorio (`demo-setup`); asumo que coincide con el desplegado, porque el error medido encaja con él.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Contenido de `nb_04` y de la actividad de refresco | No leído | H3 con confianza Media |
| Alertas o reintentos configurados | No consultados | No sé si alguien se enteró de los fallos |
| `business_date` en `lh_gold.fact_sales` | La columna no existe con ese nombre (error de la consulta) | El hueco en gold se deduce del recuento de filas (11 M), no de las fechas |

### Discrepancias entre skills y documentación

Sin discrepancias nuevas.
