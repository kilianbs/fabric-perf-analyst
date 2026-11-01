# Refresco del modelo sm_sales: duración, fallos y alineación con pl_daily_sales

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-10-31 |
| **Áreas** | Modelos semánticos (refresco); pivote breve a Delta tables (esquema de `dim_product`) |
| **Ámbito** | workspace `FabricPerfLab` · `sm_sales`, `pl_daily_sales`, `nb_04_refresh_model`, `lh_gold.dim_product` |
| **Ventana analizada** | 2026-10-30 17:26 → 2026-10-31 05:38 UTC |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, semantic-model-authoring, sqldw-cli |
| **Modo** | Solo lectura |
| **Severidad global** | Alta |
| **Confianza global** | Alta |

## Resumen

- **Pregunta:** ¿`sm_sales` se refresca bien, cuánto tarda cada refresco, por qué falla y está alineado con el pipeline?
- **Conclusión:** No del todo. 2 de 12 refrescos fallaron con `The 'category' column does not exist in the rowset.`; el refresco que lanza `nb_04` no se espera ni se vigila, así que el pipeline termina "Completed" aunque el modelo quede sin actualizar. La programación del modelo (05:30 y 06:30 hora Romance) no está alineada con el pipeline (06:00, fin 06:26).
- **Impacto:** refrescos correctos entre 23 s y 8 min 18 s; los fallidos duran ~15 s y dejan el modelo con datos anteriores sin que nadie lo vea.
- **Primera acción:** R1, hacer que `nb_04` espere y falle si el refresco falla.

## Alcance

**Pregunta original:** ¿El modelo sm_sales se refresca correctamente? Cruza el historial de refrescos (incluidos los fallidos y su mensaje de error), la programación del modelo y las horas de inicio y fin de pl_daily_sales, y revisa cómo lanza y vigila el refresco nb_04. ¿Cuánto tarda cada refresco, por qué falla y está alineado con el pipeline?

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Historial de refrescos (12 entradas), programación, ejecuciones de `pl_daily_sales`, definición de `nb_04` y del pipeline, esquema actual de `dim_product` | Rendimiento DAX, capacidad, detalle de Spark de cada notebook |

**Hipótesis de partida:** H-a el fallo viene de un cambio de esquema en gold; H-b el refresco programado no coincide con el fin del pipeline; H-c `nb_04` no vigila el resultado.

**Recorrido:** Modelos semánticos → el error nombra la columna `category` → Delta tables/gold (esquema de `dim_product` y código de `nb_03`). No se ejecutó ninguna acción de diagnóstico activo (Livy ni ClearCache).

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Modo de almacenamiento del modelo | Import; origen `Sql.Database(... "lh_gold")`, tablas `dbo.*` | E6 |
| Zona horaria de la programación | Romance Standard Time (UTC+1 en esta fecha, confirmado por E1: la programación de 05:30 empezó a las 04:30:03Z) | E2, E1 |
| Permisos | Lectura de refrescos, programación, definiciones y SQL endpoint | E1-E8 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| sm_sales | SemanticModel | Consumo | a2fca5a4-b9e4-4baa-92a9-daa82f80fdd9 |
| pl_daily_sales | DataPipeline | Orquestación | bd706b1d-499f-4a0d-bb22-222312944ca1 |
| nb_04_refresh_model | Notebook | Lanza el refresco | 3a609552-4721-406a-8e9c-f801c0a43b59 |
| lh_gold | Lakehouse | Origen del modelo | 3aee923d-121b-415b-872c-4d5bb70664c0 |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Refrescos en el historial | 12 (10 Completed, 2 Failed) | n/a | E1 |
| Duración refrescos vía API (Completed) | 23,0 s → 2 min 52 s, creciente | `SKILL.md` semantic-model-authoring § Refresh History: comparar duraciones entre ejecuciones | E1 |
| Duración refrescos programados | 8 min 18 s (04:30Z) y 8 min 01 s (05:30Z) | ídem | E1 |
| Duración refrescos fallidos | 15,4 s ambos | ídem | E1 |
| `pl_daily_sales` programado 2026-10-31 | 05:00:02Z → 05:26:15Z (26 min 13 s) | n/a | E3 |
| Hueco fin del pipeline → refresco programado 06:30 | 3 min 45 s | n/a | E1, E3 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST (Power BI) | `GET /v1.0/myorg/groups/{ws}/datasets/{sm}/refreshes?$top=50` | 12 refrescos, tabla abajo |
| E2 | REST (Power BI) | `GET .../datasets/{sm}/refreshSchedule` | enabled, todos los días, `05:30` y `06:30`, Romance Standard Time |
| E3 | REST (Fabric) | `GET /v1/workspaces/{ws}/items/{pl}/jobs/instances` | 5 ejecuciones, todas Completed (tabla abajo) |
| E4 | REST (Fabric) | `POST /v1/workspaces/{ws}/items/{pl}/getDefinition` (lectura) | 4 actividades en cadena; "Refresh semantic model" ejecuta `nb_04`, timeout 30 min, retry 0; schedule diario 06:00 Romance (2026-10-31 → 2026-11-30) |
| E5 | REST (Fabric) | `POST .../notebooks/{nb4}/getDefinition?format=ipynb` (lectura) | `fabric.refresh_dataset(dataset="sm_sales", refresh_type="full")` dentro de `try/except` que solo hace `print("WARNING: ...")` |
| E6 | REST (Fabric) | `POST .../semanticModels/{sm}/getDefinition?format=TMDL` (lectura) | `dim_product` columna `category`, partición `Sql.Database(..., "lh_gold")` `dbo.dim_product` |
| E7 | SQL | `SELECT TOP 20 COLUMN_NAME ... FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='dim_product'` en `lh_gold` | `product_code, product_name, category, list_price, unit_cost` (hoy existe `category`) |
| E8 | Fichero del repositorio | `demo-setup/items/notebooks/nb_03_silver_to_gold.py` líneas 6, 40-41 | `product_schema_v2_every = 4`; si `run_seq % 4 == 0` renombra `category` → `product_category` y sobrescribe `dim_product` con `overwriteSchema` |

Detalle de E1 (UTC, ordenado de más reciente a más antiguo):

| Refresco | Tipo | Estado | Inicio | Fin | Duración |
|----------|------|--------|--------|-----|----------|
| a9374fbd | Scheduled | Completed | 10-31 05:30:01 | 05:38:03 | 8 min 01 s |
| 6dbe2f5d | ViaEnhancedApi | Completed | 10-31 05:25:56 | 05:28:48 | 2 min 52 s |
| d64e2246 | Scheduled | Completed | 10-31 04:30:03 | 04:38:21 | 8 min 18 s |
| 9d7d5b56 | ViaEnhancedApi | Completed | 10-30 20:18:11 | 20:20:24 | 2 min 13 s |
| f46649b1 | ViaEnhancedApi | **Failed** | 10-30 19:50:58 | 19:51:14 | 15 s |
| 0ce8ac01 | ViaEnhancedApi | Completed | 19:30:22 | 19:32:04 | 1 min 42 s |
| 23fae972 | ViaEnhancedApi | Completed | 19:06:43 | 19:08:04 | 1 min 21 s |
| 1966a26f | ViaEnhancedApi | **Failed** | 18:42:16 | 18:42:31 | 15 s |
| 58069d86 | ViaEnhancedApi | Completed | 18:23:17 | 18:24:14 | 57 s |
| 0748da40 | ViaEnhancedApi | Completed | 18:02:53 | 18:03:53 | 1 min 00 s |
| 6d092c06 | ViaEnhancedApi | Completed | 17:46:19 | 17:46:48 | 30 s |
| 47b1ef60 | ViaEnhancedApi | Completed | 17:26:39 | 17:27:02 | 23 s |

Mensaje de error literal de ambos fallos (`ModelRefresh_ShortMessage_ProcessingError`): `The '<oii>category<\/oii>' column does not exist in the rowset.`

Detalle de E3 (UTC): programado 05:00:02 → 05:26:15; manuales 19:51:20 → 20:18:22, 19:30:43 → 19:51:04, 19:07:08 → 19:30:32, 18:44:32 → 19:06:51. Todos Completed.

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | Los refrescos fallan cuando gold publica `dim_product` con `product_category` en lugar de `category` | Alta | Media | E1, E6, E7, E8 |
| H2 | `nb_04` lanza el refresco sin esperarlo y traga los errores: el pipeline sale en verde aunque el modelo falle | Alta | Alta | E3, E4, E5, E1 |
| H3 | La programación del modelo (05:30 / 06:30 Romance) no está alineada con el pipeline (06:00, fin ~06:26) | Media | Alta | E1, E2, E3, E4 |
| H4 | Los refrescos programados tardan ~8 min frente a 2 min 52 s del último vía API, y la duración vía API crece | Baja | Media | E1 |

### H1 · Fallo por cambio de esquema en gold

- **Qué ocurre:** 2 de 12 refrescos (18:42 y 19:50 UTC del 30-10) fallaron en ~15 s con `The 'category' column does not exist in the rowset.` El resto terminó bien.
- **Por qué:** el modelo importa `category` de `lh_gold.dbo.dim_product` (E6). `nb_03` renombra esa columna a `product_category` una de cada 4 ejecuciones (`run_seq % 4 == 0`) y sobrescribe la tabla con `overwriteSchema` (E8). El refresco posterior a esa carga no encuentra la columna. Hoy la tabla vuelve a tener `category` (E7), lo que cuadra con que los refrescos siguientes sean correctos. Correlación temporal: el fallo de 19:50:58 cae dentro de la ejecución 19:30:43 → 19:51:04 (E3). El de 18:42 corresponde a una ejecución anterior a la ventana de E3, no listada. Confianza Media: no se leyó el `run_seq` de esas ejecuciones ni el historial Delta de `dim_product`, y E8 es el código del repositorio, no la versión desplegada de `nb_03`.
- **Impacto:** tras cada fallo el modelo conserva datos del refresco anterior hasta el siguiente correcto; con el patrón actual se repite cada 4 cargas. El próximo fallo es previsible cuando `run_seq` sea múltiplo de 4.

### H2 · `nb_04` no vigila el refresco

- **Qué ocurre:** la actividad "Refresh semantic model" dura segundos: el refresco 6dbe2f5d empezó a las 05:25:56 y el pipeline terminó a las 05:26:15, 19 s después, mientras el refresco siguió hasta las 05:28:48 (E1, E3). Las ejecuciones del pipeline están todas Completed, incluida la del refresco fallido de 19:50 (E3).
- **Por qué:** `nb_04` llama a `fabric.refresh_dataset(...)` sin esperar al estado final, y el `except` solo imprime un `WARNING` (E5). Además el timeout de 30 min y `retry: 0` de la actividad (E4) nunca se aprovechan.
- **Impacto:** un fallo del modelo es invisible para el pipeline y su monitorización; solo se ve entrando al historial del modelo.

### H3 · Programación desalineada

- **Qué ocurre:** con UTC+1 (E1/E2), el pipeline arranca a las 06:00 local (05:00Z) y termina a las 06:26 local (05:26Z) (E3, E4). El modelo se refresca a las 05:30 local (04:30Z), 30 min antes de que empiece la carga, y a las 06:30 local (05:30Z), 3 min 45 s tras el fin del pipeline y 1 min 12 s después de que acabara el refresco de `nb_04` (05:28:48Z).
- **Por qué:** el refresco de 05:30 lee los datos del día anterior; el de 06:30 duplica el que ya lanza `nb_04`. El margen de 3 min 45 s del segundo se quedaría en nada si el pipeline pasa de ~30 min (las manuales duraron 20-27 min, E3).
- **Impacto:** ~8 min de refresco redundante cada uno, dos veces al día (E1), sin aportar datos nuevos; riesgo de solapamiento con el refresco de `nb_04`.

### H4 · Duraciones

- Los refrescos vía API crecen de 23 s (17:26Z) a 2 min 52 s (05:25Z) (E1), coherente con el tamaño creciente de las cargas, pero no se midió el volumen de filas (Confianza Media). Los programados duran ~8 min; no se determinó la causa de la diferencia con los de API (sin traza ni detalle por tabla), queda como no verificada.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Que `nb_04` espere al refresco y falle si no termina en Completed | H2 | Alto | Bajo | Bajo | Sí |
| R2 | Quitar el cambio de nombre de `category` en `nb_03` o actualizar el modelo a la vez | H1 | Alto | Bajo | Medio | Sí |
| R3 | Eliminar los refrescos programados o moverlos tras el pipeline | H3 | Medio | Bajo | Bajo | Sí |

### R1 · Esperar y vigilar el refresco en `nb_04`

- **Cambio propuesto:**

  ```python
  import sempy.fabric as fabric
  request_id = fabric.refresh_dataset(dataset=semantic_model, refresh_type="full", commit_mode="transactional")
  # esperar con fabric.get_refresh_execution_details(semantic_model, request_id) hasta status Completed
  # y lanzar la excepción (sin try/except) si el estado es Failed o se agota el tiempo
  ```

- **Impacto esperado:** el pipeline pasará a Failed cuando el modelo falle. Se basa en E3/E5.
- **Cómo validarlo:** repetir E3 y E1 tras una carga con fallo provocado y comprobar que el pipeline queda Failed.
- **Reversión:** restaurar la versión anterior del notebook.
- **Requiere confirmación:** Sí, modifica un notebook.

### R2 · Coordinar el esquema de `dim_product`

- **Cambio propuesto:** dejar de renombrar `category` en `nb_03` (`product_schema_v2_every = 0`) o publicar a la vez el cambio equivalente en la partición y columna `category` de `sm_sales`.
- **Impacto esperado:** desaparecen los fallos 1 de cada 4 cargas (E8).
- **Cómo validarlo:** repetir E1 durante al menos 8 cargas sin Failed.
- **Reversión:** restaurar el valor anterior del parámetro.
- **Requiere confirmación:** Sí, cambia un notebook o el modelo.

### R3 · Alinear la programación

- **Cambio propuesto:** desactivar la programación de `sm_sales` (el pipeline ya refresca tras gold) o dejar solo una hora posterior al fin del pipeline con margen (por ejemplo 07:00 Romance).
- **Impacto esperado:** se evitan ~16 min diarios de refresco redundante (E1).
- **Cómo validarlo:** repetir E1 y E2 y comprobar que no hay refrescos `Scheduled` previos al pipeline ni solapados.
- **Reversión:** restablecer las horas 05:30 y 06:30.
- **Requiere confirmación:** Sí, cambia la programación.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Error de credenciales o de origen de datos | E1 | El error es de columna inexistente, no de credenciales; los refrescos adyacentes terminan bien |
| D2 | Los fallos vienen de la programación | E1 | Ambos fallos son `ViaEnhancedApi`; los dos programados terminaron bien |

## Siguientes pasos

- [ ] Aplicar R1 y R2 — responsable: ingeniero de datos · relacionado con: R1, R2
- [ ] Decidir la política de refresco programado — responsable: propietario del modelo · relacionado con: R3
- [ ] Repetir el análisis tras aplicar R1-R3 para validar el impacto

## Notas

### Limitaciones

El historial de refrescos devolvió solo 12 entradas (desde 17:26Z del 30-10); no se puede evaluar la tendencia de más días. La lista de ejecuciones del pipeline tiene 5 entradas, por lo que el fallo de 18:42Z no se pudo asociar a una ejecución concreta.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| `run_seq` de cada carga e historial Delta de `dim_product` | Requería Livy (`DESCRIBE HISTORY`); no se ejecutó porque el fallo ya es explicable con el código y el mensaje de error | H1 queda con confianza Media |
| Versión desplegada de `nb_03` | Solo se leyó el fichero del repositorio | Idem |
| Causa de que los refrescos programados tarden más que los de API | Sin traza ni detalle por tabla | H4 sin verificar |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Sin discrepancias detectadas | n/a | n/a | n/a |

## Anexo

### Consultas completas

Ver E1-E8; ninguna es demasiado larga para la tabla.

### Configuración efectiva

Programación del modelo: diaria, 05:30 y 06:30, Romance Standard Time. Programación del pipeline: diaria 06:00 Romance Standard Time, del 2026-10-31 al 2026-11-30.
