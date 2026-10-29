# Thin helpers over the Fabric and Power BI REST APIs.
# Tokens come from the Azure CLI (`az login`), so no app registration is needed.

$ErrorActionPreference = 'Stop'

$script:ApiBase = @{
    Fabric  = 'https://api.fabric.microsoft.com/v1'
    PowerBI = 'https://api.powerbi.com/v1.0/myorg'
}
$script:Audience = @{
    Fabric  = 'https://api.fabric.microsoft.com'
    PowerBI = 'https://analysis.windows.net/powerbi/api'
}
$script:TokenCache = @{}

function Get-AccessToken {
    param([ValidateSet('Fabric', 'PowerBI')][string]$Api = 'Fabric')

    $cached = $script:TokenCache[$Api]
    if ($cached -and $cached.ExpiresOn -gt (Get-Date).AddMinutes(5)) { return $cached.Token }

    $raw = az account get-access-token --resource $script:Audience[$Api] --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Could not get a $Api token from the Azure CLI. Run 'az login' first." }
    $token = $raw | ConvertFrom-Json
    $expiresOn = if ($token.expires_on) {
        [DateTimeOffset]::FromUnixTimeSeconds([long]$token.expires_on).LocalDateTime
    } else {
        [datetime]$token.expiresOn
    }
    $script:TokenCache[$Api] = @{ Token = $token.accessToken; ExpiresOn = $expiresOn }
    return $token.accessToken
}

function Get-HeaderValue {
    param($Response, [string]$Name)
    $value = $Response.Headers[$Name]
    if ($value -is [array]) { return $value[0] }
    return $value
}

function Invoke-FabricRequest {
    <#
    .SYNOPSIS
    Calls a Fabric or Power BI REST route. Retries on 429/5xx and waits for long-running
    operations (202 + Location) unless -NoLroWait is set.
    .OUTPUTS
    The parsed JSON body, or the raw response with -Raw.
    #>
    [CmdletBinding()]
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        [object]$Body,
        [ValidateSet('Fabric', 'PowerBI')][string]$Api = 'Fabric',
        [switch]$NoLroWait,
        [switch]$Raw,
        [switch]$AllowFailure,
        [int]$MaxRetries = 6
    )

    $uri = if ($Path -match '^https://') { $Path } else { "$($script:ApiBase[$Api])$Path" }
    $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 50 -Compress } else { $null }

    for ($attempt = 0; ; $attempt++) {
        $request = @{
            Method             = $Method
            Uri                = $uri
            Headers            = @{ Authorization = "Bearer $(Get-AccessToken -Api $Api)" }
            SkipHttpErrorCheck = $true
        }
        if ($json) {
            $request.Body = [Text.Encoding]::UTF8.GetBytes($json)
            $request.ContentType = 'application/json; charset=utf-8'
        }
        $response = Invoke-WebRequest @request
        $status = [int]$response.StatusCode

        $isTransient = $status -eq 429 -or $status -ge 500
        if (-not $isTransient -or $attempt -ge $MaxRetries) { break }
        $retryAfter = Get-HeaderValue $response 'Retry-After'
        $wait = if ($retryAfter) { [int]$retryAfter } else { [Math]::Pow(2, $attempt + 2) }
        Write-Verbose "HTTP $status on $Method $uri, retrying in $wait s"
        Start-Sleep -Seconds $wait
    }

    if ($status -ge 400) {
        if ($AllowFailure) { return $null }
        throw "HTTP $status on $Method $uri`n$($response.Content)"
    }
    if ($Raw) { return $response }

    $location = Get-HeaderValue $response 'Location'
    if ($status -eq 202 -and $location -and -not $NoLroWait) {
        $retryAfter = Get-HeaderValue $response 'Retry-After'
        return Wait-FabricOperation -Location $location -RetryAfter ($retryAfter ? [int]$retryAfter : 5) -Api $Api
    }
    if ([string]::IsNullOrWhiteSpace($response.Content)) { return $null }
    return $response.Content | ConvertFrom-Json -Depth 50
}

function Wait-FabricOperation {
    param(
        [Parameter(Mandatory)][string]$Location,
        [int]$RetryAfter = 5,
        [int]$TimeoutMinutes = 30,
        [string]$Api = 'Fabric'
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds ([Math]::Clamp($RetryAfter, 2, 30))
        $operation = Invoke-FabricRequest -Path $Location -Api $Api -NoLroWait
        switch ($operation.status) {
            'Succeeded' {
                # Create operations expose the new item at /result; other operations have no result.
                return (Invoke-FabricRequest -Path "$Location/result" -Api $Api -NoLroWait -AllowFailure) ?? $operation
            }
            { $_ -in 'Failed', 'Cancelled' } {
                throw "Operation $Location ended as $($operation.status): $($operation.error | ConvertTo-Json -Depth 10 -Compress)"
            }
        }
    }
    throw "Operation $Location did not finish within $TimeoutMinutes minutes."
}

function Get-FabricCollection {
    param([Parameter(Mandatory)][string]$Path, [string]$Api = 'Fabric')

    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Path
    while ($next) {
        $page = Invoke-FabricRequest -Path $next -Api $Api
        foreach ($entry in @($page.value)) { if ($null -ne $entry) { $items.Add($entry) } }
        $next = $page.continuationUri
    }
    return $items
}

function ConvertTo-DefinitionPart {
    param([Parameter(Mandatory)][string]$PartPath, [Parameter(Mandatory)][string]$Content)
    return @{
        path        = $PartPath
        payload     = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Content))
        payloadType = 'InlineBase64'
    }
}

function Get-FabricItem {
    param([string]$WorkspaceId, [string]$DisplayName, [string]$Type)
    return Get-FabricCollection "/workspaces/$WorkspaceId/items?type=$Type" |
        Where-Object displayName -eq $DisplayName |
        Select-Object -First 1
}

function Set-FabricItem {
    <#
    .SYNOPSIS
    Creates an item, or updates its definition when an item with the same name and type exists.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Type,
        [object[]]$Parts,
        [string]$Format,
        [string]$Description = ''
    )

    $definition = $null
    if ($Parts) {
        $definition = @{ parts = $Parts }
        if ($Format) { $definition.format = $Format }
    }

    $existing = Get-FabricItem -WorkspaceId $WorkspaceId -DisplayName $DisplayName -Type $Type
    if ($existing) {
        if ($definition) {
            Invoke-FabricRequest -Method POST -Path "/workspaces/$WorkspaceId/items/$($existing.id)/updateDefinition" `
                -Body @{ definition = $definition } | Out-Null
        }
        Write-Host "  = $Type $DisplayName (updated)"
        return $existing
    }

    $body = @{ displayName = $DisplayName; type = $Type; description = $Description }
    if ($definition) { $body.definition = $definition }
    $created = Invoke-FabricRequest -Method POST -Path "/workspaces/$WorkspaceId/items" -Body $body
    if (-not $created.id) { $created = Get-FabricItem -WorkspaceId $WorkspaceId -DisplayName $DisplayName -Type $Type }
    Write-Host "  + $Type $DisplayName (created)"
    return $created
}

function Start-FabricJob {
    <#
    .SYNOPSIS
    Starts an on-demand job (Pipeline, RunNotebook, ...) and optionally waits for it.
    .OUTPUTS
    The job instance (with -Wait) or its URL.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][string]$JobType,
        [hashtable]$ExecutionData,
        [switch]$Wait,
        [int]$PollSeconds = 30,
        [int]$TimeoutMinutes = 240
    )

    $body = if ($ExecutionData) { @{ executionData = $ExecutionData } } else { $null }
    $response = Invoke-FabricRequest -Method POST -Raw `
        -Path "/workspaces/$WorkspaceId/items/$ItemId/jobs/instances?jobType=$JobType" -Body $body
    $instanceUrl = Get-HeaderValue $response 'Location'
    if (-not $Wait) { return $instanceUrl }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        $instance = Invoke-FabricRequest -Path $instanceUrl -NoLroWait
        if ($instance.status -in 'Completed', 'Failed', 'Cancelled', 'Deduped') { return $instance }
    }
    throw "Job $instanceUrl did not finish within $TimeoutMinutes minutes."
}

function Expand-Template {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][hashtable]$Tokens, [string]$Source = 'template')

    $result = $Text
    foreach ($key in $Tokens.Keys) { $result = $result.Replace("{{$key}}", [string]$Tokens[$key]) }
    $left = [regex]::Matches($result, '\{\{[A-Z0-9_]+\}\}') | ForEach-Object Value | Select-Object -Unique
    if ($left) { throw "Unresolved tokens in ${Source}: $($left -join ', ')" }
    return $result
}

function ConvertTo-FabricNotebookSource {
    <#
    .SYNOPSIS
    Turns a plain Python file with VS Code cell markers into the Fabric notebook source format.
    Markers: "# %%" (code), "# %% [parameters]" (parameters cell), "# %% [markdown]" (markdown).
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][System.Collections.IDictionary]$Dependencies)

    $cells = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($line in Get-Content -LiteralPath $Path -Encoding utf8) {
        if ($line -match '^# %%(?:\s*\[(?<kind>\w+)\])?\s*$') {
            $kind = if ($Matches.kind) { $Matches.kind } else { 'code' }
            $current = @{ Kind = $kind; Lines = [System.Collections.Generic.List[string]]::new() }
            $cells.Add($current)
        } elseif ($current) {
            $current.Lines.Add($line)
        }
    }
    if ($cells.Count -eq 0) { throw "$Path has no '# %%' cell markers." }

    $codeMeta = [ordered]@{ language = 'python'; language_group = 'synapse_pyspark' }
    $out = [System.Collections.Generic.List[string]]::new()
    $addMeta = {
        param($Object)
        $out.Add('# METADATA ********************'); $out.Add('')
        ($Object | ConvertTo-Json -Depth 20) -split "`r?`n" | ForEach-Object { $out.Add("# META $_") }
        $out.Add('')
    }

    $out.Add('# Fabric notebook source'); $out.Add('')
    & $addMeta ([ordered]@{ kernel_info = [ordered]@{ name = 'synapse_pyspark' }; dependencies = $Dependencies })

    foreach ($cell in $cells) {
        $body = ($cell.Lines -join "`n").Trim([char[]]"`r`n")
        switch ($cell.Kind) {
            'markdown'   { $out.Add('# MARKDOWN ********************'); $out.Add(''); $out.Add($body); $out.Add('') }
            'parameters' { $out.Add('# PARAMETERS CELL ********************'); $out.Add(''); $out.Add($body); $out.Add(''); & $addMeta $codeMeta }
            'code'       { $out.Add('# CELL ********************'); $out.Add(''); $out.Add($body); $out.Add(''); & $addMeta $codeMeta }
            default      { throw "Unknown cell kind '$($cell.Kind)' in $Path." }
        }
    }
    return ($out -join "`n")
}

Export-ModuleMember -Function Get-AccessToken, Invoke-FabricRequest, Get-FabricCollection, ConvertTo-DefinitionPart,
    Get-FabricItem, Set-FabricItem, Start-FabricJob, Expand-Template, ConvertTo-FabricNotebookSource
