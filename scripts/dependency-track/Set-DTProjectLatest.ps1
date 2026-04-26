#Requires -Version 7.0

<#
.SYNOPSIS
Marks a Dependency-Track project version as the "latest" for its name.

.DESCRIPTION
DT's isLatest flag is name-scoped: only one project with a given name can hold it. Setting
this flag on a new version automatically clears it on whichever version held it before.
Use this for canonical release projects, not for transient per-commit child projects.

Looks the project up by (name, version), then PATCHes /api/v1/project/{uuid} with
{"isLatest": true}.

.PARAMETER ServerUrl
Base URL including scheme.

.PARAMETER ApiKey
DT API key with permission to update the project (PROJECT_CREATION_UPLOAD or higher).

.PARAMETER ProjectName
Project name to look up.

.PARAMETER ProjectVersion
Project version to look up.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ServerUrl,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ApiKey,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ProjectName,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ProjectVersion
)

$ErrorActionPreference = 'Stop'

$invokeRest = Join-Path -Path $PSScriptRoot -ChildPath 'private/Invoke-DTRestMethod.ps1'

$lookup = & $invokeRest `
    -ServerUrl $ServerUrl `
    -ApiKey $ApiKey `
    -Method Get `
    -Path '/api/v1/project/lookup' `
    -Query @{ name = $ProjectName; version = $ProjectVersion } `
    -ExpectStatus 200, 404

if ($lookup.StatusCode -eq 404 -or -not $lookup.Body.uuid) {
    Write-Warning "Project $ProjectName@$ProjectVersion not found; skipping isLatest update"
    return
}

$uuid = $lookup.Body.uuid

& $invokeRest `
    -ServerUrl $ServerUrl `
    -ApiKey $ApiKey `
    -Method Patch `
    -Path "/api/v1/project/$uuid" `
    -Body @{ isLatest = $true } `
    -ExpectStatus 200, 204 | Out-Null

Write-Information "Marked $ProjectName@$ProjectVersion (uuid $uuid) as latest" -InformationAction Continue
