# pl_daily_sales: qué crece entre ejecuciones

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-02 |
| **Áreas** | Spark runs → Delta tables |
| **Ámbito** | workspace `FabricPerfLab` · `pl_daily_sales`, `nb_02_bronze_to_silver`, `lh_bronze.sales_raw`, `lh_silver.sales` |
| **Ventana analizada** | 2026-10-30 17:11 → 2026-11-02 05:25 UTC (13 ejecuciones) |
| **Agente / host** | GitHub Copilot CLI · skills: fabric-perf-analysis, spark-cli, sqldw-cli |
| **Modo** | Solo lectura |
| **Severidad global** | Media |
| **Confianza global** | Media |

## Resumen

- **Pregunta:** ¿Qué crece entre ejecuciones de `pl_daily_sales` y hace que tarde cada día más?
- **Conclusión:** crece `lh_bronze.sales_raw` (+1 000 000 filas por carga, solo anexado). La actividad `Bronze to silver` y, en menor medida, `Silver to gold` reprocesan todo el histórico en cada ejecución.
- **Impacto:** duración total de 915 s a 1 622 s en las ejecuciones manuales; `Bronze to silver` pasa de 280 s a 650 s (735 s en la última programada).
- **Primera acción:** R1, procesar solo las filas nuevas en lugar de reconstruir `sales` completa. Hay que confirmarla porque modifica el notebook.

## Alcance

**Pregunta original:** "El pipeline `pl_daily_sales` del workspace FabricPerfLab tarda cada día más. ¿Qué es lo que crece entre ejecuciones?"

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Duración por ejecución y por actividad; volumen de bronze; layout de `sales_raw` | Métricas de stages/Spark Advisor (no se consultaron); capacidad; modelo semántico |

**Hipótesis de partida:** H-a el volumen de entrada crece y el procesamiento es proporcional al histórico; H-b fragmentación de archivos; H-c otra actividad concreta degrada.

**Recorrido:** Spark runs (tendencia por actividad señala `Bronze to silver`) → Delta tables (volumen y archivos de `sales_raw`).

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Configuración Spark relevante en `nb_02` | `shuffle.partitions=2000`, AQE desactivado, broadcast desactivado | Código del notebook en el repo (`demo-setup/items/notebooks/nb_02_bronze_to_silver.py`), no leído del workspace |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| pl_daily_sales | DataPipeline | Orquestación | bd706b1d-499f-4a0d-bb22-222312944ca1 |
| lh_bronze | Lakehouse | Bronze | 53249a1b-e8a9-4270-9cb4-0f2ce3b10feb |
| lh_silver | Lakehouse | Silver | b01f7911-28fd-4dc2-ac51-1d19ed841238 |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Duración de la ejecución (manuales, 30-oct) | 915 s → 1 622 s | Regresión con línea base (`job-diagnostics.md`) | E1 |
| Duración programadas | 1 573 s (31-oct), 1 500 s (2-nov) | | E1 |
| `Bronze to silver` | 280 s → 650 s (manuales); 701 s / 735 s (programadas) | | E2 |
| `Ingest bronze` | 157–232 s (31-oct: 301 s, 2-nov: 274 s) | Sin tendencia clara | E2 |
| Filas en `sales_raw` | 9 M (30-oct), +1 M (31-oct), +1 M (2-nov) = 11 M | | E3 |
| Archivos de `sales_raw` | 4 400, todos en [256 KiB, 4 MiB) | Anomalía tipo 3: muchos archivos pequeños | E4 |
| Filas en `lh_silver.sales` | 11 000 000 (= bronze completo) | | E5 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | REST | `GET /v1/workspaces/{ws}/items/{pipeline}/jobs/instances` | 13 ejecuciones; 2 fallidas (62 s y 79 s) excluidas de la tendencia |
| E2 | REST | `POST /v1/workspaces/{ws}/datapipelines/pipelineruns/{id}/queryactivityruns` (11 ejecuciones) | Duración por actividad (ver métricas) |
| E3 | SQL | `SELECT CAST(ingested_at AS date), COUNT(*), COUNT(DISTINCT sale_id) FROM dbo.sales_raw GROUP BY ...` en lh_bronze | 30-oct 9 000 000; 31-oct 1 000 000; 2-nov 1 000 000; sin `sale_id` duplicados |
| E4 | SQL | `EXEC sys.sp_get_table_health_metrics @tableName='dbo.sales_raw'` | `PotentialAnomalyType=3`, 4 400 archivos, 1 052 898 766 bytes, 11 M filas |
| E5 | SQL | `SELECT COUNT(*), MIN(sale_ts), MAX(sale_ts) FROM dbo.sales` en lh_silver | 11 000 000 filas |
| E6 | SQL | `SELECT run_seq, COUNT(*) FROM dbo.customer_changes GROUP BY run_seq` | ~14 000 filas por run_seq tras la carga inicial de 200 000 |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | El histórico de `sales_raw` crece 1 M filas por carga y `nb_02` lo reprocesa entero | Media | Media | E1, E2, E3, E5 |
| H2 | `sales_raw` tiene 4 400 archivos pequeños | Baja | Media | E4 |

### H1 · Reprocesado completo de un histórico que solo crece

- **Qué ocurre:** `sales_raw` pasa de 9 M a 11 M filas y la duración de `Bronze to silver` crece en paralelo. `Ingest bronze`, que solo añade el lote del día, se mantiene estable.
- **Por qué:** según el código de `nb_02` (revisado en el repo, no en el workspace), la tabla `sales` se reconstruye entera con `row_number` sobre todo el histórico, dos `count()`, joins con shuffle y una UDF Python por fila, y se escribe con `overwrite`. El coste es proporcional al histórico acumulado. `sales` en silver tiene 11 M filas, igual que bronze (E5). No hay `sale_id` duplicados (E3), así que la deduplicación recorre todo el histórico sin eliminar nada en esas cargas.
- **Impacto:** la ejecución crece unos 4-5 minutos en tres días y seguirá creciendo con cada carga. `Silver to gold` también crece (342 s → 704 s en manuales, 432 s en la última programada) con variabilidad; no se verificó su causa.

### H2 · Archivos pequeños en `sales_raw`

- **Qué ocurre:** 4 400 archivos de entre 256 KiB y 4 MiB (~239 KiB de media) para ~1 GB.
- **Por qué:** cada carga añade archivos sin compactar. Agrava la lectura completa de H1, pero no se midió su peso relativo.
- **Impacto:** aumenta el coste de listar y abrir archivos en cada lectura completa.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Procesar `sales` de forma incremental (solo `ingested_at` nuevo, `MERGE` por `sale_id`) | H1 | Alto | Medio | Medio | Sí |
| R2 | Compactar `lh_bronze.sales_raw` con `OPTIMIZE` y activar optimize write en la ingesta | H2 | Medio | Bajo | Bajo | Sí |

### R1 · Carga incremental de `sales`

- **Cambio propuesto:** leer de `sales_raw` solo `ingested_at > max(ingested_at)` ya aplicado en `sales`, aplicar la UDF y deduplicar solo ese lote, y hacer `MERGE` en `sales`. Eliminar los `count()` de depuración.
- **Impacto esperado:** el tiempo de `Bronze to silver` pasaría a depender del lote diario (1 M filas) y no del histórico; estimación, no medida.
- **Cómo validarlo:** repetir `queryactivityruns` y comparar la duración de `Bronze to silver` con 735 s tras varias cargas.
- **Reversión:** volver a la versión anterior del notebook.
- **Requiere confirmación:** Sí, modifica un notebook y una tabla.

### R2 · Compactación de bronze

- **Cambio propuesto:** `OPTIMIZE lh_bronze.sales_raw` y activar optimize write en `nb_01`.
- **Impacto esperado:** menos archivos por lectura; el efecto en duración no está medido.
- **Cómo validarlo:** repetir `sys.sp_get_table_health_metrics` y comparar los 4 400 archivos.
- **Reversión:** no aplica; `OPTIMIZE` no cambia los datos lógicos.
- **Requiere confirmación:** Sí, es una escritura.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | `Ingest bronze` es el origen de la degradación | E2 | Su duración no muestra tendencia |
| D2 | Crece `customer_changes` | E6 | ~14 000 filas por run_seq tras la carga inicial; el notebook solo aplica los `run_seq` pendientes |

## Siguientes pasos

- [ ] Aprobar y aplicar R1 — responsable: dueño del pipeline · relacionado con: R1
- [ ] Analizar `Silver to gold` (nb_03) con la misma tendencia — responsable: analista · relacionado con: H1
- [ ] Repetir el análisis tras aplicar R1 y R2

## Notas

### Limitaciones

- Las ejecuciones del 30-oct son manuales, en ráfaga; las programadas solo son dos exitosas. La tendencia combina ambos tipos de ejecución.
- La causa de H1 se infirió de la tendencia por actividad, del volumen y del código en el repo; no se consultaron stages ni Spark Advisor, y la versión desplegada en el workspace no se verificó. La confianza es Media.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| Stages, shuffle, spill, skew de `nb_02` | No se consultaron; la retención de los detalles Spark es de minutos a horas | No se cuantifica el coste por fase |
| `DESCRIBE DETAIL` de las tablas silver/gold | No se ejecutó Livy | Sin tamaño por tabla en silver/gold |
| Causa del crecimiento de `Silver to gold` | No analizada | Queda fuera de H1 |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Retención de `queryActivityRuns` | `pipeline-diagnosis.md` P2: "la más larga" | La retención de detalles Spark es menor que la de job instances | Se usó `queryactivityruns` solo para duraciones, y estaba disponible para las 11 ejecuciones consultadas |

## Anexo

### Consultas completas

Todas están resumidas en la tabla de Evidencia.
