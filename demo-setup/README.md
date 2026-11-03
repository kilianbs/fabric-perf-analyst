# demo-setup: workspace FabricPerfLab

Scripts que crean un workspace de Fabric para analizarlo con el agente `FabricPerfAnalyst`: un lakehouse
medallion con pipelines de Spark, tablas Delta y un modelo semántico Import. Cada item lleva problemas
de rendimiento conocidos, y el script ejecuta los pipelines varias veces para que haya historial que
analizar. Las conversaciones de la demo y lo que debería encontrarse en cada escenario están en
[DEMO-SCENARIOS.md](DEMO-SCENARIOS.md) (mantenlo fuera del alcance del agente mientras analiza).

## Camino rápido

```powershell
az login                                   # o bien: az login --allow-no-subscriptions
pwsh ./demo-setup/setup.ps1 -CapacityName "<nombre de tu capacidad>"
```

1. **Deploy** (unos 5 minutos): crea el workspace y todos los items.
2. **Paso manual**: el script se detiene y te pide que configures las credenciales del modelo ([más abajo](#paso-manual-credenciales-del-modelo)).
3. **History** (horas, ver [Tiempos y coste](#tiempos-y-coste)): ejecuta el pipeline diario una vez por día simulado y después la exportación que falla, dos veces.
4. **Schedule**: pipeline diario a las 06:00 y refresco del modelo a las 05:30 y 06:30.

La fase History tarda horas: lánzala antes de empezar a analizar. Después, las programaciones añaden
ejecuciones diarias reales.

### O pídeselo al agente

Abre Claude Code, o un chat de GitHub Copilot en VS Code, en la raíz del repositorio y di, por ejemplo:

> Ejecuta `demo-setup/setup.ps1 -CapacityName "<capacidad>" -Phase Deploy -NonInteractive`. Confirmo
> que puede crear el workspace FabricPerfLab y sus artefactos. Cuando termine, dime qué paso manual
> me queda y después lanza `-Phase History -NonInteractive` en segundo plano.

El [AGENTS.md](../AGENTS.md) del repositorio prohíbe escribir en Fabric sin confirmación explícita,
así que el prompt debe confirmar la operación. `-NonInteractive` omite la pausa de "pulsa Enter"; haz el
[paso manual](#paso-manual-credenciales-del-modelo) antes de que empiece la fase History, o los
refrescos del modelo del historial fallarán con un error de credenciales.

## Qué se crea

| Item | Nombre | Papel en los escenarios |
|------|--------|-------------------------|
| Workspace | `FabricPerfLab` | Contenedor, en tu capacidad |
| Lakehouse | `lh_bronze`, `lh_silver`, `lh_gold` | Capas medallion (sin esquemas, tablas en `dbo`) |
| Spark pool | `pool_gold_xl` | Pool personalizado que usa el environment de gold |
| Environment | `env_bronze`, `env_silver`, `env_gold` | Configuración de Spark por capa |
| Notebook | `nb_01_ingest_bronze` | Genera un día de negocio de datos sintéticos |
| Notebook | `nb_02_bronze_to_silver` | Deduplicación, joins, MERGE de clientes |
| Notebook | `nb_03_silver_to_gold` | Esquema en estrella para el modelo |
| Notebook | `nb_04_refresh_model` | Solicita el refresco del modelo |
| Notebook | `nb_05_store_snapshot` | Exportación por tienda (falla a propósito) |
| Pipeline | `pl_daily_sales` | nb_01 → nb_02 → nb_03 → nb_04 |
| Pipeline | `pl_store_snapshot` | nb_05 con el parámetro `export_format` |
| Modelo semántico | `sm_sales` | Modelo Import sobre el SQL endpoint de `lh_gold` |
| Informe | `rpt_sales` | Página "Sales overview" sobre `sm_sales`; el agente lee sus visuales para construir las consultas DAX |

Ficheros locales: [`items/`](items/) contiene todas las definiciones (Python, JSON, YAML, TMDL legibles y el
informe PBIR), y [`dax/report-queries.dax`](dax/report-queries.dax) contiene las consultas de la página de
`rpt_sales`, una por visual. El script escribe los IDs de los items y un log de ejecuciones en
`demo-setup/.state/` (en el `.gitignore`).

## Requisitos previos

Todo lo del [README.md](../README.md#requisitos) raíz, y además:

| Requisito | Por qué |
|-----------|---------|
| PowerShell 7.2+ (`pwsh`) | Los scripts usan sintaxis de PowerShell 7. Windows PowerShell 5.1 no sirve. |
| Capacidad de Fabric, **se recomienda trial F64** | Sesiones de Spark, un pool de nodos Large y un modelo Import de varios millones de filas. En una capacidad pequeña usa `-GoldPoolNodeSize Medium -GoldPoolMaxNodes 3`. |
| Permiso para crear workspaces y asignarlos a la capacidad | Ajuste del tenant para crear workspaces, y Contributor (o administrador) en la capacidad. |
| Ajuste del workspace *Customize compute configurations for items* activado | Necesario para el pool personalizado y los environments. Viene activado por defecto. |
| Ajuste de la capacidad **XMLA endpoint: Read Write** | Solo para los escenarios del modelo semántico (ver el README raíz). |

## Paso manual: credenciales del modelo

`sm_sales` es un modelo Import, así que Power BI necesita credenciales para el SQL endpoint de `lh_gold`,
y la API no puede configurar por ti un inicio de sesión OAuth2. Una sola vez, después de Deploy:

1. Abre la URL que imprime el script (`app.powerbi.com/groups/<ws>/settings/datasets/<model>`).
2. **Data source credentials** → **Edit credentials** → método de autenticación **OAuth2** → **Sign in**.

Después vuelve a ejecutar `-Phase Schedule` si avisó de que no se activó la programación de refresco.

## Fases y parámetros

Cada fase se puede ejecutar sola con `-Phase Deploy|History|Schedule`. Deploy es idempotente: localiza
los items por nombre y actualiza sus definiciones, así que se puede repetir sin riesgo después de editar
`items/`. `-Phase Report` despliega solo `rpt_sales` sobre un workspace ya desplegado (encuentra
`sm_sales` por nombre), sin volver a enviar la definición del modelo.

| Parámetro | Valor por defecto | Efecto |
|-----------|-------------------|--------|
| `-WorkspaceName` | `FabricPerfLab` | Workspace que se crea o se reutiliza |
| `-CapacityName` / `-CapacityId` | ninguno | Solo hace falta cuando el workspace aún no existe |
| `-SimulatedDays` | `10` | Ejecuciones del pipeline en la fase History (un día de negocio cada una) |
| `-RowsPerDay` | `1000000` | Filas de ventas generadas por ejecución |
| `-GoldPoolNodeSize` / `-GoldPoolMaxNodes` | `Large` / `4` | Tamaño de `pool_gold_xl` (gold usa máx. nodos − 1 ejecutores fijos) |
| `-PipelineTime` | `06:00` | Programación diaria de `pl_daily_sales` |
| `-ModelRefreshTimes` | `05:30`, `06:30` | Programación de refresco del modelo (Power BI solo acepta :00 y :30) |
| `-TimeZoneId` | `Romance Standard Time` | ID de zona horaria de Windows para ambas programaciones |
| `-ScheduleDays` | `30` | Cuándo termina la programación del pipeline |
| `-SkipSnapshotFailures` | desactivado | Omite las dos ejecuciones fallidas de `pl_store_snapshot` |
| `-NonInteractive` | desactivado | Sin pausas; para el agente o CI |

Repetir History añade más días: el contador de días vive en `lh_bronze.ctl_pipeline_runs`.

## Tiempos y coste

Aún sin medir: las duraciones siguientes son estimaciones, compruébalas en tu capacidad.

| Fase | Estimación | Nota |
|------|------------|------|
| Deploy | 5–10 min | Espera al SQL endpoint y a la publicación de los environments |
| History | varias horas para 10 días | Cada ejecución es más lenta que la anterior (esa es la demo) |
| Schedule | menos de 1 min | Después, una ejecución del pipeline y dos refrescos del modelo al día |

La fase History consume CU de Spark durante toda su duración, y las programaciones siguen consumiendo
cada día. Cuando termines, detenlas (siguiente sección).

## Comprobación antes de analizar

- [ ] `demo-setup/.state/FabricPerfLab-history.csv` lista las ejecuciones; la ejecución 6 aparece como `Failed`.
- [ ] `pl_store_snapshot` muestra dos ejecuciones fallidas en el Monitor hub.
- [ ] El historial de refrescos de `sm_sales` muestra éxitos y fallos (ejecuciones 4 y 8).
- [ ] `FabricIQ`, `fabric-sqlendpoint` y `powerbi-modeling-mcp` están conectados: `/mcp` en Claude Code; en VS Code con GitHub Copilot, **Chat: Open Customizations** > **MCP Servers** (o `copilot mcp list` y `/mcp` en Copilot CLI), con `FABRIC_MCP_TOKEN` definido ([README](../README.md#vs-code--github-copilot)).
- [ ] El agente no puede leer `demo-setup/` (ver [DEMO-SCENARIOS.md](DEMO-SCENARIOS.md#antes-de-ejecutar-el-agente)).

## Detener o eliminar

```powershell
pwsh ./demo-setup/teardown.ps1 -DisableSchedules   # lo conserva todo y detiene las ejecuciones diarias
pwsh ./demo-setup/teardown.ps1                     # borra el workspace (pide que escribas su nombre)
```

## Solución de problemas

| Síntoma | Causa probable y solución |
|---------|---------------------------|
| `Not signed in` / HTTP 401 | Vuelve a ejecutar `az login`; sin suscripción de Azure, `az login --allow-no-subscriptions`. |
| `Capacity '...' not found` | El nombre debe coincidir exactamente con el nombre visible de la capacidad, o pasa `-CapacityId`. La capacidad debe estar activa. |
| La creación del pool falla con un error de tamaño de nodo | La capacidad es demasiado pequeña para nodos Large: `-GoldPoolNodeSize Medium -GoldPoolMaxNodes 3`. |
| Falla la publicación de un environment | Abre el environment en el portal: ahí se muestra el error. Con `instance_pool_id: null`, bronze y silver usan el starter pool. |
| Todos los refrescos del modelo fallan con un error de credenciales | Se omitió el paso manual. |
| La exportación "nested" de `nb_05` termina bien | Aún no hay datos suficientes en la tienda caliente; ejecuta más días de History o sube `-RowsPerDay`. |
