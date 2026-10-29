<#
.SYNOPSIS
Stops the FabricPerfLab workspace from consuming capacity, or deletes it.

.DESCRIPTION
-DisableSchedules  Disables the pipeline schedule and the model refresh schedule; items and history stay.
(default)          Deletes the whole workspace after you type its name. Run history is lost.
#>
#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$WorkspaceName = 'FabricPerfLab',
    [switch]$DisableSchedules
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/FabricApi.psm1') -Force

$workspace = Get-FabricCollection '/workspaces' | Where-Object displayName -eq $WorkspaceName | Select-Object -First 1
if (-not $workspace) { Write-Host "Workspace $WorkspaceName not found. Nothing to do."; return }
$ws = $workspace.id

if ($DisableSchedules) {
    $pipeline = Get-FabricItem -WorkspaceId $ws -DisplayName 'pl_daily_sales' -Type 'DataPipeline'
    if ($pipeline) {
        $path = "/workspaces/$ws/items/$($pipeline.id)/jobs/Pipeline/schedules"
        foreach ($schedule in Get-FabricCollection $path) {
            Invoke-FabricRequest -Method PATCH -Path "$path/$($schedule.id)" -Body @{
                enabled = $false; configuration = $schedule.configuration
            } | Out-Null
            Write-Host "  - Pipeline schedule $($schedule.id) disabled"
        }
    }
    $model = Get-FabricItem -WorkspaceId $ws -DisplayName 'sm_sales' -Type 'SemanticModel'
    if ($model) {
        Invoke-FabricRequest -Api PowerBI -Method PATCH -AllowFailure -Path "/groups/$ws/datasets/$($model.id)/refreshSchedule" `
            -Body @{ value = @{ enabled = $false } } | Out-Null
        Write-Host '  - Model refresh schedule disabled'
    }
    return
}

$answer = Read-Host "This deletes workspace '$WorkspaceName' ($ws) and everything in it. Type the workspace name to confirm"
if ($answer -cne $WorkspaceName) { Write-Host 'Cancelled.'; return }
Invoke-FabricRequest -Method DELETE -Path "/workspaces/$ws" | Out-Null
Remove-Item -Path (Join-Path $PSScriptRoot ".state/$WorkspaceName*") -ErrorAction SilentlyContinue
Write-Host "Workspace $WorkspaceName deleted."
