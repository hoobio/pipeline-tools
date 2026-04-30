#Requires -Version 7.0

<#
.SYNOPSIS
Deletes stale Dependency-Track child projects under a parent, keeping only the most
recently uploaded N.

.DESCRIPTION
For long-lived per-commit project hierarchies (e.g. one child project per push), this
script keeps the parent's child list bounded. It looks up the parent project, lists its
children sorted newest-first by lastBomImport, and deletes everything past Keep.

DELETE in DT is asynchronous (typically returns 202); the response status is treated as
success on any 2xx code.

.PARAMETER ServerUrl
Base URL including scheme.

.PARAMETER ApiKey
DT API key with PORTFOLIO_MANAGEMENT permission. The key needs DELETE rights on
projects; lower-privilege keys (e.g. PROJECT_CREATION_UPLOAD only) hit HTTP 403 and the
script aborts with an actionable error.

.PARAMETER ParentName
Parent project name.

.PARAMETER ParentVersion
Parent project version.

.PARAMETER Keep
Number of most recent children to retain. Default 10. Must be >= 0.

.PARAMETER PageSize
Maximum number of children to consider in a single pass. Default 1000.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ServerUrl,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ApiKey,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ParentName,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ParentVersion,
    [Parameter(Mandatory = $false)] [ValidateRange(0, [int]::MaxValue)] [int]$Keep = 10,
    [Parameter(Mandatory = $false)] [ValidateRange(1, 5000)] [int]$PageSize = 1000
)

$ErrorActionPreference = 'Stop'

$invokeRest = Join-Path -Path $PSScriptRoot -ChildPath 'private/Invoke-DTRestMethod.ps1'

$lookup = & $invokeRest `
    -ServerUrl $ServerUrl `
    -ApiKey $ApiKey `
    -Method Get `
    -Path '/api/v1/project/lookup' `
    -Query @{ name = $ParentName; version = $ParentVersion } `
    -ExpectStatus 200, 404

if ($lookup.StatusCode -eq 404 -or -not $lookup.Body.uuid) {
    Write-Warning "Parent $ParentName@$ParentVersion not found; nothing to prune"
    return
}

$parentUuid = $lookup.Body.uuid

$children = & $invokeRest `
    -ServerUrl $ServerUrl `
    -ApiKey $ApiKey `
    -Method Get `
    -Path "/api/v1/project/$parentUuid/children" `
    -Query @{
        sortName   = 'lastBomImport'
        sortOrder  = 'desc'
        pageNumber = '1'
        pageSize   = [string]$PageSize
    } `
    -ExpectStatus 200

$all = @($children.Body)
if ($all.Count -le $Keep) {
    Write-Information "Nothing to prune (have $($all.Count), keep $Keep)" -InformationAction Continue
    return
}

$stale = $all | Select-Object -Skip $Keep
$deleted = 0
$skipped404 = 0
foreach ($child in $stale) {
    if (-not $child.uuid) { continue }

    # Accept 403 here so we can surface a single, specific error instead of one
    # generic warning per child. 404 is benign (another runner won the race).
    $resp = & $invokeRest `
        -ServerUrl $ServerUrl `
        -ApiKey $ApiKey `
        -Method Delete `
        -Path "/api/v1/project/$($child.uuid)" `
        -ExpectStatus 200, 202, 204, 403, 404

    if ($resp.StatusCode -eq 403) {
        $msg = "Dependency-Track refused project DELETE with HTTP 403. The supplied API key " +
               "lacks the PORTFOLIO_MANAGEMENT permission required to delete projects. " +
               "Grant it under Administration > Access Management > Teams > Permissions, " +
               "or run prune-stale-children with an admin key. Aborting prune to avoid " +
               "spamming the rest of $($stale.Count) children."
        Write-Host "::error::$msg"
        throw $msg
    }

    if ($resp.StatusCode -eq 404) {
        $skipped404++
        continue
    }

    $deleted++
}

$summary = "Pruned $deleted stale child(ren) under $ParentName@$ParentVersion; kept $Keep most recent"
if ($skipped404 -gt 0) { $summary += " ($skipped404 already gone)" }
Write-Information $summary -InformationAction Continue
