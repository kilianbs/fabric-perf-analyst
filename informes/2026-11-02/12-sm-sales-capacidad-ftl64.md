# Capacidad FTL64 y errores de usuario de sm_sales: sin throttling ni sobreuso en 15 días; el detalle por item no está disponible

Seguimiento de [11-sm-sales-refrescos-datos-ayer.md](11-sm-sales-refrescos-datos-ayer.md) (que dejó sin cifras de CU, throttling y memoria, H5). Relacionado con [07-sm-sales-avg-ticket-lento.md](07-sm-sales-avg-ticket-lento.md) y [10-sm-sales-memoria-modelo.md](10-sm-sales-memoria-modelo.md). Solo lectura: sin refrescos, sin Livy y sin ClearCache.

| Campo | Valor |
|-------|-------|
| **Fecha** | 2026-11-02 |
| **Áreas** | Capacity; pivote a Semantic models (ventanas de refresco) |
| **Ámbito** | capacidad Trial `FTL64` (353a0ed6-2bba-456c-bac7-009fc42e4b94), West Europe · workspace `FabricPerfLab` |
| **Ventana analizada** | 2026-10-29 09:00 → 2026-11-02 22:00 hora local (CET, UTC+1), es decir, hasta 21:00 UTC del 11-02; todo lo que contiene la app (21 541,5 min) |
| **Agente / host** | Claude Code · skills: fabric-perf-analysis, sqldw-cli (Capacity Metrics) |
| **Modo** | Solo lectura |
| **Severidad global** | Baja |
| **Confianza global** | Media |

## Resumen

- **Pregunta:** ¿los errores de usuario de `sm_sales` coinciden con picos de CU, throttling o con las ventanas de refresco (04:30 y 05:30 UTC) y de carga (05:00 UTC)?
- **Conclusión:** no hay throttling ni sobreuso. En 21 541,5 min (≈15 días) la capacidad estuvo 100 % del tiempo sin throttling: 0 min de interactive delay, 0 de rechazo interactivo, 0 de rechazo de background, 0 min "at risk", sobreuso facturado 0 y deuda acumulada 0. El pico de utilización suavizada fue del 27,1 % (sobre 64 CU). Por tanto los errores de usuario no se explican por throttling.
- **Impacto:** la cadena diaria (carga a las 05:00 UTC + refrescos) hace de la hora 06 local la más cargada: 62 925 CU(s) el 11-02 (≈27 % de la capacidad de esa hora), sin throttling. El detalle por item y por operación (sm_sales, pipeline, notebooks) no se pudo obtener.
- **Primera acción:** R1, obtener los errores concretos de los usuarios (hora, informe, mensaje) y habilitar un registro de consultas del modelo; con los datos actuales no se pueden distinguir timeout, refresco en curso u otros errores.

## Alcance

**Pregunta original:** analizar la capacidad FTL64 en las últimas 2 semanas (o lo que haya): CU por item y operación, en especial sm_sales, pl_daily_sales y sus notebooks; picos de utilización, smoothing/overage, throttling, carryforward, correlación por hora con los refrescos de 04:30 y 05:30 UTC y con la carga de las 05:00 UTC; buscar si los errores de usuario pueden coincidir con esas ventanas y distinguir timeout, throttling o refresco en curso.

| Dentro del alcance | Fuera del alcance |
|--------------------|-------------------|
| Resumen de salud de la capacidad, utilización por hora (suavizada) y por tipo de utilización, operaciones por hora (ok, fallo, rechazo) | CU por item y por operación (tablas vacías, ver Notas), consultas y errores concretos de usuarios, timeouts |

**Hipótesis de partida:** H-a) los refrescos y la carga saturan la capacidad y provocan throttling o delay; H-b) los errores de usuario ocurren en esas horas.

**Recorrido:** Capacity (E1 a E4) → ventanas de 11 (refrescos y carga) para correlacionar por hora. No se cambió de área porque no hay señal de throttling.

## Contexto

### Entorno

| Elemento | Valor | Fuente |
|----------|-------|--------|
| Capacidad (SKU · región) | `FTL64` (equivale a F64, 64 CU), West Europe, estado Active, Healthy; 1 cambio de SKU registrado (creación del trial el 2026-10-29) | E1, 11 (E8) |
| Zona horaria de la app | Hora local (CET, UTC+1): la hora "06" es 05:00-05:59 UTC. Se deduce de que la carga del 11-02 (05:00-05:26 UTC) cae en la hora 06 y las pruebas del 30-oct (17:11-20:26 UTC) en las horas 18 a 21 | E3 |
| Límite de memoria por modelo | 25 GB en F64/FT1 (Learn, tabla de límites por SKU) | 11 (D2) |
| Permisos con los que se ejecutó | `executeQueries` sobre el modelo "Fabric Capacity Metrics" (refrescado a las 21:54 UTC del 11-02) | E1 |

### Items analizados

| Item | Tipo | Capa / rol | ID |
|------|------|------------|----|
| Fabric Capacity Metrics | SemanticModel | Origen de las métricas | 3b749d41-702f-49e4-ba5f-cb9c0723a715 |
| FTL64 (Trial) | Capacidad | Aloja FabricPerfLab y otros 7 workspaces | 353a0ed6-2bba-456c-bac7-009fc42e4b94 |

## Evidencia

### Métricas clave

| Métrica | Valor | Referencia / umbral | Evidencia |
|---------|-------|---------------------|-----------|
| Minutos totales / sin throttling | 21 541,5 / 21 541,5 (100 %) | Capacity Metrics: estado Healthy | E1 |
| Interactive delay, rechazo interactivo, rechazo background, at risk, pausas | 0 min cada uno; 0 pausas | | E1 |
| Sobreuso (OverageBillingCUs), deuda acumulada, overage procesado | 0; 0; 0 | | E1, E2 |
| Utilización media / máxima (suavizada) | 7,75 % / 27,1 % | | E1 |
| Utilización background / interactiva | 7,67 % / 0,08 % | | E1 |
| Máximo de interactive delay, rechazo interactivo, rechazo background (% del umbral) | 16,0 % / 14,5 % / 8,2 % | | E1 |
| Hora más cargada de las últimas 24 h (06 local del 11-02) | 62 925 CU(s), 8 460 operaciones, 9 usuarios, 0 fallos; 62 925 / (64 × 3 600) = 27,3 % | | E3 |
| Hora típica de base | ≈ 11 000 CU(s) (≈ 4,8 %) | | E3 |
| Throttling y operaciones rechazadas en las 127 filas hora-tipo | 0 s y 0 | | E3 |
| Operaciones fallidas (total) | 43 operaciones en el conjunto de 127 filas hora-tipo | | E3 |

### Consultas y llamadas ejecutadas

| ID | Tipo | Consulta o llamada | Resultado |
|----|------|--------------------|-----------|
| E1 | DAX | `EVALUATE 'Capacity Health Summary'` y `'Latest Capacity Details Metrics'` (`executeQueries` sobre el modelo de Capacity Metrics) | 1 fila para 353A0ED6...: 21 541,5 min, 100 % sin throttling, 0 en delay/rechazo/at risk/pausas/sobreuso; `MaxUsage` 0,2709; `Status` Healthy; `AvgBaseunits` 64; almacenamiento 64,6 (actual) y 56,7 (medio) |
| E2 | DAX | `EVALUATE 'Usage Summary (Last 7 days)'` y `(Last 24 hours)` | 110 y 25 filas horarias (de 2026-10-29 11:00 a 11-03 00:00 local). CU(s) por hora, `Average CU %`, `Maximum CU %`, delay y rechazos: 0 en todas; deuda acumulada (24 h) 0. Máximo `Maximum CU %`: 27,1 % el 10-31 a las 18 h local; 14,9 % el 11-02 a las 23 h |
| E3 | DAX | `EVALUATE 'Usage Operation (Last 7 days)'` y `(Last 24 hours)` | 127 y 27 filas (hora × tipo de utilización): CU(s), duración, usuarios, operaciones ok/fallidas/rechazadas, throttling. Suma de CU: background 2 101 723, interactiva 20 024 |
| E4 | DAX | `COUNTROWS` de las tablas por item/operación (`Metrics By Item`, `Metrics By Item And Operation`, `Unsmoothed Consumption By Item And Operation And Hour`, `Timepoint*`, `CU Detail`, `Smoothed Operation Metrics*`) y consulta filtrada por capacidad y por fechas | Todas devuelven 0 filas o sin valor (son tablas DirectQuery). `Items` sí tiene 81 filas (solo catálogo, sin CU) |

### Ventanas diarias de la cadena (hora local = UTC + 1; datos de E3)

| Día | Hora 05 local (04:00-04:59 UTC; refresco 04:30 UTC) | Hora 06 local (05:00-05:59 UTC; carga + refresco 05:30 UTC) | Hora 07 local (06:00-06:59 UTC) |
|-----|------------------------|--------------------------|-------------------|
| 10-31 | 16 443 CU(s), 1 099 ops, 1 fallo | 56 787 CU(s), 7 706 ops, 0 fallos | 17 894 CU(s) |
| 11-01 (carga fallida) | 16 671 CU(s), 1 093 ops, 1 fallo | 17 296 CU(s), 2 090 ops, 2 fallos | 17 684 CU(s) |
| 11-02 | 17 133 CU(s), 932 ops, 1 fallo | 62 925 CU(s), 8 460 ops, 0 fallos | 17 828 CU(s) |

## Hallazgos

| ID | Hallazgo | Severidad | Confianza | Evidencia |
|----|----------|-----------|-----------|-----------|
| H1 | No hay throttling, sobreuso ni deuda en toda la historia disponible | Baja | Alta | E1, E2, E3 |
| H2 | La cadena de carga y refresco concentra la hora 06 local, pero al 27 % de la capacidad | Baja | Alta | E3 |
| H3 | El refresco de las 04:30 UTC añade ≈ 6 000 CU(s) cada día | Baja | Media | E3, 11 (H2) |
| H4 | Un fallo diario en la hora 05 local no es atribuible a ningún item | Baja | Baja | E3 |
| H5 | El detalle por item y operación no está disponible | Media | Alta | E4 |

### H1 · Sin throttling

- **Qué ocurre:** 100 % del tiempo sin throttling, con 0 minutos de interactive delay, 0 de rechazo, 0 "at risk", overage 0 y deuda acumulada 0 (E1, E2). La utilización media es del 7,75 % y el máximo del 27,1 % (10-31, 18 h local). Los máximos de delay y rechazo llegaron al 16,0 % y 14,5 % del umbral. La carryforward (deuda) es 0 en las últimas 24 h y no hay sobreuso en ningún momento (E1, E2).
- **Por qué importa:** si los usuarios tuvieron errores, la capacidad no los provocó por throttling ni por rechazo. Los umbrales de severidad usados son los estados del propio informe de Capacity Metrics (Healthy, sin delay ni rechazo); la skill `capacity.md` es la referencia de área.
- **Impacto:** sin riesgo de capacidad actual. Margen: la hora más cargada usa el 27,3 % de 64 CU.

### H2 · Hora 06 local

La carga de las 05:00 UTC junto con los refrescos de nb_04 (05:24 UTC) y de las 05:30 UTC cae en la hora 06 local: 56 787 y 62 925 CU(s) en 10-31 y 11-02, frente a unos 11 000 de base (E3). Eso es ≈ 17,5 CU de media horaria (62 925 / 3 600), el 27,3 % de la capacidad, sin picos que lleguen a throttling ni siquiera en la serie suavizada (máximo 27,1 %, E2). El 11-01, con la carga fallida, la hora 06 solo tuvo 17 296 CU(s) (E3).

### H3 · Refresco de las 04:30 UTC

Las horas 05 local suben a 16 443 a 17 133 CU(s) los tres días (E3), unos 5 500 a 6 300 por encima de la base de ≈ 11 000, compatible con el refresco programado de 498 a 622 s del informe 11 (H2). Es una atribución indirecta: no hay detalle por item (H5), y la hora 07 muestra un exceso similar (17 684 a 17 894) incluso el día sin carga, que no sé atribuir.

### H4 · Fallos recurrentes en la hora 05 local

En las horas 05 local de 10-30, 10-31, 11-01 y 11-02 hay 1 operación fallida por día (E3), en la ventana de 04:00 a 04:59 UTC donde corre el refresco de las 04:30 UTC. Ese refresco terminó `Completed` los tres días (11, E1), así que el fallo no es de `sm_sales` según el historial de refrescos; podría ser de otro item de la capacidad. Sin detalle por item no se puede atribuir.

### H5 · Sin detalle por item

Las tablas por item, operación y timepoint del modelo de Capacity Metrics devuelven 0 filas (E4), aunque el modelo se refrescó a las 21:54 UTC y los resúmenes sí tienen datos. Por eso no se puede dar el CU por item de `sm_sales`, `pl_daily_sales` y sus notebooks, ni las consultas interactivas por item. El total interactivo de 7 días es de solo 20 024 CU(s) (0,08 % de utilización, E1, E3), pequeño frente al background (2 101 723 CU(s)). Para el 11-02 de 20 a 21 h local aparecen 2 371 CU(s) interactivos con 31 operaciones y 1 fallo (E3), que coinciden con mis consultas de diagnóstico de los informes 07 a 10 (una consulta INFO fallida a propósito); no se pudo confirmar el vínculo item a item.

## Recomendaciones

| ID | Recomendación | Resuelve | Impacto | Esfuerzo | Riesgo | Requiere confirmación |
|----|---------------|----------|---------|----------|--------|-----------------------|
| R1 | Recoger los errores de usuario y habilitar el registro de consultas del modelo | H5 | Alto | Bajo | Bajo | Sí |
| R2 | Mantener la capacidad: no hace falta escalar | H1, H2 | Bajo | Bajo | Bajo | No |
| R3 | Aplicar las correcciones de los informes 07, 08 y 11 | H2, H3 | Medio | Medio | Bajo | Sí |

### R1 · Obtener el error real

- **Cambio propuesto:** pedir a los usuarios hora, informe y texto exacto del error (o captura); habilitar registro de consultas del modelo (Log Analytics del workspace o monitorización del workspace) y revisar el workspace de Capacity Metrics para el detalle por item (comprobar su origen de datos, que hoy devuelve vacío). Con esos datos se podrá distinguir timeout (duración de consulta alta), throttling (descartado aquí), refresco en curso (coincidencia con 04:30, 05:24 o 05:30 UTC) u otro error.
- **Impacto esperado:** diagnóstico del error de usuario, que ahora queda sin explicar.
- **Cómo validarlo:** cruzar las horas de los errores con E1 y E3 y con el historial de refrescos (11, E1).
- **Reversión:** desactivar el registro.
- **Requiere confirmación:** Sí, cambia la configuración del workspace.

### R2 y R3

- **R2:** con un 27,3 % de la hora más cargada y 0 min de throttling (E1, E3), no se recomienda escalar. Vigilar la fecha de caducidad del Trial (no verificada aquí).
- **R3:** reducir CU eliminando el refresco de las 04:30 UTC (11, R3) y las medidas costosas (07, 08). Es una mejora de eficiencia, no una causa de errores.

## Descartado

| ID | Hipótesis | Evidencia | Motivo del descarte |
|----|-----------|-----------|---------------------|
| D1 | Throttling (interactive delay o rechazo) como causa de los errores | E1, E2, E3 | 0 min de delay y rechazo, 0 s de throttling, 0 operaciones rechazadas en 15 días |
| D2 | Sobreuso o deuda acumulada (carryforward) | E1, E2 | Overage 0, deuda acumulada 0 |
| D3 | Capacidad pausada o en cambio de estado | E1 | 0 pausas, 0 min pausados |
| D4 | Pico de CU de la carga y los refrescos provocando saturación | E2, E3 | Máximo suavizado 27,1 %; la hora 06 local, 27,3 % de la capacidad |
| D5 | Memoria del refresco (copia previa al commit) | 10, 11 (D2) | 806 MiB × 2 ≈ 1,6 GiB, frente a 25 GB; sin datos de memoria por item en este informe |

## Siguientes pasos

- [ ] Recoger hora, informe y mensaje de los errores de los usuarios — responsable: propietario del informe · relacionado con: R1
- [ ] Habilitar el registro de consultas del modelo y revisar por qué el detalle por item de Capacity Metrics está vacío — responsable: administración · relacionado con: R1
- [ ] Aplicar las correcciones de 07, 08 y 11 — responsable: propietario del modelo · relacionado con: R3
- [ ] Repetir el análisis cuando haya errores con hora conocida

## Notas

### Limitaciones

- La app solo contiene datos desde 2026-10-29 (≈ 15 días); la ventana de "2 semanas" se cubre entera.
- Los datos de uso por hora son de la capacidad completa (8 workspaces, hasta 9 usuarios por hora), no solo de `FabricPerfLab`. La distribución por item no está disponible (H5).
- La serie de CU por hora de `Usage Summary` está suavizada; `Usage Operation` es el consumo por hora y tipo. Los picos de menos de una hora no se ven en estas tablas.
- La hora de la app es local (CET); la conversión a UTC la deduje por correlación con la carga (E3), no por documentación.
- No se mide timeout: ninguna fuente contiene duraciones de consulta de los usuarios. El caso "refresco en curso" tampoco se puede contrastar sin horas de error.
- Las 127 filas de operaciones agregan por hora y tipo; el "43 fallos" incluye todos los items de la capacidad.

### Datos no obtenidos

| Dato | Motivo | Efecto en el análisis |
|------|--------|-----------------------|
| CU por item y operación (`sm_sales`, `pl_daily_sales`, notebooks) | Las tablas DirectQuery por item/timepoint devuelven 0 filas con mis permisos y consultas | H3 y H4 solo por correlación horaria |
| Errores y duraciones de consultas de usuarios | No hay registro de consultas ni horas de uso | No se puede distinguir timeout ni correlacionar errores |
| Fecha de caducidad del Trial | No consultada | R2 sin fecha límite |

### Discrepancias entre skills y documentación

| Tema | Skill | Documentación actual | Criterio aplicado |
|------|-------|----------------------|-------------------|
| Ninguna detectada | | | |

## Anexo

### Consultas completas

```dax
EVALUATE 'Capacity Health Summary'
EVALUATE 'Latest Capacity Details Metrics'
EVALUATE 'Usage Summary (Last 7 days)'
EVALUATE 'Usage Summary (Last 24 hours)'
EVALUATE 'Usage Operation (Last 7 days)'
EVALUATE 'Usage Operation (Last 24 hours)'
```

Todas por `POST .../groups/{ws_metrics}/datasets/{modelo_metrics}/executeQueries` (lectura, audiencia Power BI).
