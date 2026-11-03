<#
.SYNOPSIS
Creates the FabricPerfLab workspace in Microsoft Fabric and generates the run history the
performance scenarios analyze.

.DESCRIPTION
Phases (run all of them, or one at a time with -Phase):
  Deploy   Workspace, lakehouses, Spark pool, environments, notebooks, pipelines, semantic model, report.
  History  Runs pl_daily_sales once per simulated day, then pl_store_snapshot twice.
  Schedule Daily pipeline schedule and semantic model refresh schedule.
  Report   Only the rpt_sales report, on a workspace already deployed (not part of All).

The script is idempotent: existing items are matched by name and their definitions updated.
See README.md for prerequisites, timings and the manual credential step.

.EXAMPLE
./setup.ps1 -CapacityName "My F64 capacity"

.EXAMPLE
./setup.ps1 -Phase History -SimulatedDays 3 -NonInteractive
#>
#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$WorkspaceName = 'FabricPerfLab',
    [string]$CapacityName,
    [string]$CapacityId,
    [ValidateSet('All', 'Deploy', 'History', 'Schedule', 'Report')][string]$Phase = 'All',
    [ValidateRange(1, 60)][int]$SimulatedDays = 10,
    [ValidateRange(10000, 50000000)][int]$RowsPerDay = 1000000,
    [ValidateSet('Small', 'Medium', 'Large', 'XLarge')][string]$GoldPoolNodeSize = 'Large',
    [ValidateRange(2, 20)][int]$GoldPoolMaxNodes = 4,
    [string]$PipelineTime = '06:00',
    [string[]]$ModelRefreshTimes = @('05:30', '06:30'),
    [string]$TimeZoneId = 'Romance Standard Time',
    [ValidateRange(1, 365)][int]$ScheduleDays = 30,
    [switch]$SkipSnapshotFailures,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/FabricApi.psm1') -Force

$ItemsDir = Join-Path $PSScriptRoot 'items'
$StateDir = Join-Path $PSScriptRoot '.state'
$StateFile = Join-Path $StateDir "$WorkspaceName.json"
$HistoryLog = Join-Path $StateDir "$WorkspaceName-history.csv"

$Lakehouses = @('lh_bronze', 'lh_silver', 'lh_gold')
$GoldPoolName = 'pool_gold_xl'
$SemanticModelName = 'sm_sales'
$ReportName = 'rpt_sales'
$NodeSizes = @{
    Small  = @{ Cores = 4; Memory = '28g' }
    Medium = @{ Cores = 8; Memory = '56g' }
    Large  = @{ Cores = 16; Memory = '112g' }
    XLarge = @{ Cores = 32; Memory = '224g' }
}
# Default lakehouse, extra lakehouses and environment per notebook.
$Notebooks = [ordered]@{
    nb_01_ingest_bronze    = @{ Token = 'NB_01_ID'; Lakehouse = 'lh_bronze'; Known = @(); Environment = 'env_bronze' }
    nb_02_bronze_to_silver = @{ Token = 'NB_02_ID'; Lakehouse = 'lh_silver'; Known = @('lh_bronze'); Environment = 'env_silver' }
    nb_03_silver_to_gold   = @{ Token = 'NB_03_ID'; Lakehouse = 'lh_gold'; Known = @('lh_bronze', 'lh_silver'); Environment = 'env_gold' }
    nb_04_refresh_model    = @{ Token = 'NB_04_ID'; Lakehouse = $null; Known = @(); Environment = $null }
    nb_05_store_snapshot   = @{ Token = 'NB_05_ID'; Lakehouse = 'lh_silver'; Known = @(); Environment = 'env_silver' }
}

function Write-Step([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }

function Save-State([hashtable]$State) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $StateFile -Encoding utf8
}

function Read-State {
    if (-not (Test-Path $StateFile)) { throw "No state file at $StateFile. Run the Deploy phase first." }
    return Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable
}

function Assert-Prerequisites {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) not found. See README.md.' }
    $account = az account show --output json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Not signed in. Run 'az login' (or 'az login --allow-no-subscriptions')." }
    $user = ($account | ConvertFrom-Json).user.name
    Write-Host "Signed in as $user"
}

function Resolve-Workspace {
    $workspace = Get-FabricCollection '/workspaces' | Where-Object displayName -eq $WorkspaceName | Select-Object -First 1
    if ($workspace) {
        Write-Host "  = Workspace $WorkspaceName ($($workspace.id))"
        if (-not $workspace.capacityId) { throw "Workspace $WorkspaceName exists but is not assigned to a capacity." }
        return $workspace
    }

    $capacity = $CapacityId
    if (-not $capacity) {
        if (-not $CapacityName) { throw "Workspace $WorkspaceName does not exist. Pass -CapacityName or -CapacityId to create it." }
        $match = Get-FabricCollection '/capacities' | Where-Object displayName -eq $CapacityName | Select-Object -First 1
        if (-not $match) { throw "Capacity '$CapacityName' not found or not visible to you." }
        if ($match.state -ne 'Active') { throw "Capacity '$CapacityName' is $($match.state). Resume it first." }
        $capacity = $match.id
    }
    $workspace = Invoke-FabricRequest -Method POST -Path '/workspaces' -Body @{
        displayName = $WorkspaceName
        description = 'Performance diagnosis lab for Claude Code and skills-for-fabric.'
        capacityId  = $capacity
    }
    Write-Host "  + Workspace $WorkspaceName ($($workspace.id))"
    return $workspace
}

function Resolve-Lakehouse([string]$WorkspaceId, [string]$Name) {
    $lakehouse = Get-FabricItem -WorkspaceId $WorkspaceId -DisplayName $Name -Type 'Lakehouse'
    if (-not $lakehouse) {
        $lakehouse = Invoke-FabricRequest -Method POST -Path "/workspaces/$WorkspaceId/lakehouses" -Body @{ displayName = $Name }
        if (-not $lakehouse.id) { $lakehouse = Get-FabricItem -WorkspaceId $WorkspaceId -DisplayName $Name -Type 'Lakehouse' }
        Write-Host "  + Lakehouse $Name"
    } else {
        Write-Host "  = Lakehouse $Name"
    }
    return $lakehouse
}

function Wait-SqlEndpoint([string]$WorkspaceId, [string]$LakehouseId) {
    for ($i = 0; $i -lt 40; $i++) {
        $details = Invoke-FabricRequest -Path "/workspaces/$WorkspaceId/lakehouses/$LakehouseId"
        $sql = $details.properties.sqlEndpointProperties
        if ($sql -and $sql.provisioningStatus -eq 'Success' -and $sql.connectionString) { return $sql }
        Start-Sleep -Seconds 15
    }
    throw "The SQL endpoint of lakehouse $LakehouseId was not provisioned after 10 minutes."
}

function Resolve-GoldPool([string]$WorkspaceId) {
    $executors = $GoldPoolMaxNodes - 1
    $body = @{
        name                      = $GoldPoolName
        nodeFamily                = 'MemoryOptimized'
        nodeSize                  = $GoldPoolNodeSize
        autoScale                 = @{ enabled = $true; minNodeCount = 1; maxNodeCount = $GoldPoolMaxNodes }
        dynamicExecutorAllocation = @{ enabled = $true; minExecutors = 1; maxExecutors = $executors }
    }
    $pool = Get-FabricCollection "/workspaces/$WorkspaceId/spark/pools" | Where-Object name -eq $GoldPoolName | Select-Object -First 1
    if ($pool) {
        Invoke-FabricRequest -Method PATCH -Path "/workspaces/$WorkspaceId/spark/pools/$($pool.id)" -Body $body | Out-Null
        Write-Host "  = Spark pool $GoldPoolName ($GoldPoolNodeSize x $GoldPoolMaxNodes)"
        return $pool
    }
    $pool = Invoke-FabricRequest -Method POST -Path "/workspaces/$WorkspaceId/spark/pools" -Body $body
    Write-Host "  + Spark pool $GoldPoolName ($GoldPoolNodeSize x $GoldPoolMaxNodes)"
    return $pool
}

function Deploy-Environment([string]$WorkspaceId, [string]$Name, [hashtable]$Tokens) {
    $path = Join-Path $ItemsDir "environments/$Name.yml"
    $yaml = Expand-Template -Text (Get-Content $path -Raw) -Tokens $Tokens -Source $path
    $environment = Set-FabricItem -WorkspaceId $WorkspaceId -DisplayName $Name -Type 'Environment' `
        -Parts @(ConvertTo-DefinitionPart -PartPath 'Setting/Sparkcompute.yml' -Content $yaml)
    # Definition changes are staged; publish makes them effective for new sessions.
    $publish = Invoke-FabricRequest -Method POST -AllowFailure `
        -Path "/workspaces/$WorkspaceId/environments/$($environment.id)/staging/publish?beta=false"
    if ($null -eq $publish) { Write-Warning "Publish of $Name was rejected (nothing pending or a publish in progress). Check it in the portal." }
    return $environment
}

function Deploy-Notebook([string]$WorkspaceId, [string]$Name, [hashtable]$Spec, [hashtable]$Ids) {
    $dependencies = [ordered]@{}
    if ($Spec.Lakehouse) {
        $dependencies.lakehouse = [ordered]@{
            default_lakehouse              = $Ids[$Spec.Lakehouse]
            default_lakehouse_name         = $Spec.Lakehouse
            default_lakehouse_workspace_id = $WorkspaceId
            known_lakehouses               = @(@($Spec.Lakehouse) + $Spec.Known | ForEach-Object { [ordered]@{ id = $Ids[$_] } })
        }
    }
    if ($Spec.Environment) {
        $dependencies.environment = [ordered]@{ environmentId = $Ids[$Spec.Environment]; workspaceId = $WorkspaceId }
    }
    $source = ConvertTo-FabricNotebookSource -Path (Join-Path $ItemsDir "notebooks/$Name.py") -Dependencies $dependencies
    return Set-FabricItem -WorkspaceId $WorkspaceId -DisplayName $Name -Type 'Notebook' -Format 'fabricGitSource' `
        -Parts @(ConvertTo-DefinitionPart -PartPath 'notebook-content.py' -Content $source)
}

function Get-FolderParts([string]$Root, [hashtable]$Tokens) {
    Get-ChildItem -Path $Root -Recurse -File -Force | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
        $content = Expand-Template -Text (Get-Content $_.FullName -Raw) -Tokens $Tokens -Source $relative
        ConvertTo-DefinitionPart -PartPath $relative -Content $content
    }
}

function Deploy-SemanticModel([string]$WorkspaceId, [hashtable]$Tokens) {
    $parts = Get-FolderParts -Root (Join-Path $ItemsDir "semantic-model/$SemanticModelName") -Tokens $Tokens
    return Set-FabricItem -WorkspaceId $WorkspaceId -DisplayName $SemanticModelName -Type 'SemanticModel' -Format 'TMDL' -Parts $parts `
        -Description 'Sales model over lh_gold (Import).'
}

function Deploy-Report([string]$WorkspaceId, [string]$ModelId) {
    $parts = Get-FolderParts -Root (Join-Path $ItemsDir "report/$ReportName.Report") -Tokens @{ SEMANTIC_MODEL_ID = $ModelId }
    return Set-FabricItem -WorkspaceId $WorkspaceId -DisplayName $ReportName -Type 'Report' -Format 'PBIR' -Parts $parts `
        -Description "Sales overview page over $SemanticModelName."
}

function Invoke-ReportPhase {
    Write-Step "Report"
    $ws = (Resolve-Workspace).id
    $model = Get-FabricItem -WorkspaceId $ws -DisplayName $SemanticModelName -Type 'SemanticModel'
    if (-not $model) { throw "$SemanticModelName not found in $WorkspaceName. Run the Deploy phase first." }
    $report = Deploy-Report -WorkspaceId $ws -ModelId $model.id
    if (Test-Path $StateFile) {
        $state = Read-State
        $state.items[$ReportName] = $report.id
        Save-State $state
    }
}

function Deploy-Pipeline([string]$WorkspaceId, [string]$Name, [hashtable]$Tokens) {
    $path = Join-Path $ItemsDir "pipelines/$Name.json"
    $content = Expand-Template -Text (Get-Content $path -Raw) -Tokens $Tokens -Source $path
    return Set-FabricItem -WorkspaceId $WorkspaceId -DisplayName $Name -Type 'DataPipeline' `
        -Parts @(ConvertTo-DefinitionPart -PartPath 'pipeline-content.json' -Content $content)
}

function Invoke-DeployPhase {
    Write-Step "Workspace"
    $workspace = Resolve-Workspace
    $ws = $workspace.id
    $ids = @{ WORKSPACE_ID = $ws }

    Write-Step "Lakehouses"
    foreach ($name in $Lakehouses) { $ids[$name] = (Resolve-Lakehouse -WorkspaceId $ws -Name $name).id }
    $goldSql = Wait-SqlEndpoint -WorkspaceId $ws -LakehouseId $ids['lh_gold']

    Write-Step "Spark pool and environments"
    $pool = Resolve-GoldPool -WorkspaceId $ws
    $size = $NodeSizes[$GoldPoolNodeSize]
    $envTokens = @{
        GOLD_POOL_ID   = $pool.id
        GOLD_CORES     = $size.Cores
        GOLD_MEMORY    = $size.Memory
        GOLD_EXECUTORS = $GoldPoolMaxNodes - 1
    }
    foreach ($name in 'env_bronze', 'env_silver', 'env_gold') {
        $ids[$name] = (Deploy-Environment -WorkspaceId $ws -Name $name -Tokens $envTokens).id
    }

    Write-Step "Semantic model"
    $model = Deploy-SemanticModel -WorkspaceId $ws -Tokens @{ GOLD_SQL_ENDPOINT = $goldSql.connectionString; GOLD_DATABASE = 'lh_gold' }
    $ids[$SemanticModelName] = $model.id

    Write-Step "Report"
    $ids[$ReportName] = (Deploy-Report -WorkspaceId $ws -ModelId $model.id).id

    Write-Step "Notebooks"
    foreach ($name in $Notebooks.Keys) {
        $notebook = Deploy-Notebook -WorkspaceId $ws -Name $name -Spec $Notebooks[$name] -Ids $ids
        $ids[$name] = $notebook.id
        $ids[$Notebooks[$name].Token] = $notebook.id
    }

    Write-Step "Pipelines"
    $pipelineTokens = $ids.Clone()
    $pipelineTokens.ROWS_PER_DAY = $RowsPerDay
    foreach ($name in 'pl_daily_sales', 'pl_store_snapshot') {
        $ids[$name] = (Deploy-Pipeline -WorkspaceId $ws -Name $name -Tokens $pipelineTokens).id
    }

    Save-State @{ workspaceName = $WorkspaceName; workspaceId = $ws; items = $ids; goldSqlEndpoint = $goldSql.connectionString }
    Write-Host "`nState saved to $StateFile"
    Request-ModelCredentials -WorkspaceId $ws -ModelId $model.id
}

function Request-ModelCredentials([string]$WorkspaceId, [string]$ModelId) {
    $url = "https://app.powerbi.com/groups/$WorkspaceId/settings/datasets/$ModelId"
    Write-Host @"

MANUAL STEP (once): the Import model needs credentials for the lh_gold SQL endpoint.
  1. Open $url
  2. Data source credentials > Edit credentials > Authentication method: OAuth2 > Sign in.
Without it, every refresh of $SemanticModelName fails with a credentials error.
"@ -ForegroundColor Yellow
    if (-not $NonInteractive) { Read-Host 'Press Enter when the credentials are set' | Out-Null }
}

function Write-HistoryRow([string]$Pipeline, [string]$Label, $Instance, [datetime]$Started) {
    $row = [pscustomobject]@{
        pipeline = $Pipeline
        label    = $Label
        status   = $Instance.status
        started  = $Started.ToString('s')
        minutes  = [Math]::Round(((Get-Date) - $Started).TotalMinutes, 1)
        reason   = $Instance.failureReason.message
    }
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $row | Export-Csv -Path $HistoryLog -Append -NoTypeInformation -Encoding utf8
    $color = if ($row.status -eq 'Completed') { 'Green' } else { 'Yellow' }
    Write-Host ("  {0,-18} {1,-10} {2,6} min  {3}" -f $Label, $row.status, $row.minutes, $row.reason) -ForegroundColor $color
}

function Invoke-HistoryPhase {
    $state = Read-State
    $ws = $state.workspaceId

    Write-Step "pl_daily_sales x $SimulatedDays (one simulated business day per run)"
    for ($day = 1; $day -le $SimulatedDays; $day++) {
        $started = Get-Date
        $instance = Start-FabricJob -WorkspaceId $ws -ItemId $state.items.pl_daily_sales -JobType 'Pipeline' -Wait `
            -ExecutionData @{ parameters = @{ rows_per_day = $RowsPerDay } }
        Write-HistoryRow -Pipeline 'pl_daily_sales' -Label "run $day/$SimulatedDays" -Instance $instance -Started $started
    }

    if ($SkipSnapshotFailures) { return }
    Write-Step "pl_store_snapshot (export formats 'nested' and 'pairs')"
    foreach ($format in 'nested', 'pairs') {
        $started = Get-Date
        $instance = Start-FabricJob -WorkspaceId $ws -ItemId $state.items.pl_store_snapshot -JobType 'Pipeline' -Wait `
            -ExecutionData @{ parameters = @{ export_format = $format } }
        Write-HistoryRow -Pipeline 'pl_store_snapshot' -Label $format -Instance $instance -Started $started
    }
    Write-Host "`nRun log: $HistoryLog"
}

function Invoke-SchedulePhase {
    $state = Read-State
    $ws = $state.workspaceId
    $start = (Get-Date).Date.AddDays(1)

    Write-Step "Pipeline schedule: pl_daily_sales daily at $PipelineTime ($TimeZoneId), $ScheduleDays days"
    $schedulePath = "/workspaces/$ws/items/$($state.items.pl_daily_sales)/jobs/Pipeline/schedules"
    $existing = Get-FabricCollection $schedulePath
    if ($existing) {
        Write-Host "  = $(@($existing).Count) schedule(s) already present, not adding another"
    } else {
        Invoke-FabricRequest -Method POST -Path $schedulePath -Body @{
            enabled       = $true
            configuration = @{
                type            = 'Daily'
                times           = @($PipelineTime)
                startDateTime   = $start.ToString('yyyy-MM-ddTHH:mm:ss')
                endDateTime     = $start.AddDays($ScheduleDays).ToString('yyyy-MM-ddTHH:mm:ss')
                localTimeZoneId = $TimeZoneId
            }
        } | Out-Null
        Write-Host "  + Daily schedule at $PipelineTime"
    }

    Write-Step "Semantic model refresh schedule: $($ModelRefreshTimes -join ', ')"
    Invoke-FabricRequest -Api PowerBI -Method PATCH -AllowFailure `
        -Path "/groups/$ws/datasets/$($state.items.sm_sales)/refreshSchedule" -Body @{
            value = @{
                enabled         = $true
                days            = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
                times           = $ModelRefreshTimes
                localTimeZoneId = $TimeZoneId
                notifyOption    = 'NoNotification'
            }
        } | Out-Null
    $scheduled = Invoke-FabricRequest -Api PowerBI -AllowFailure -Path "/groups/$ws/datasets/$($state.items.sm_sales)/refreshSchedule"
    if ($scheduled.enabled) {
        Write-Host "  + Refresh at $($scheduled.times -join ', ')"
    } else {
        Write-Warning 'The refresh schedule was not enabled. Set the model credentials (see README.md) and run -Phase Schedule again.'
    }
}

Assert-Prerequisites
if ($Phase -in 'All', 'Deploy') { Invoke-DeployPhase }
if ($Phase -eq 'Report') { Invoke-ReportPhase }
if ($Phase -in 'All', 'History') { Invoke-HistoryPhase }
if ($Phase -in 'All', 'Schedule') { Invoke-SchedulePhase }
Write-Host "`nDone. Next: see DEMO-SCENARIOS.md." -ForegroundColor Green
