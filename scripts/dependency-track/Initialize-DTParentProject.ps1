#Requires -Version 7.0

<#
.SYNOPSIS
Ensures a Dependency-Track parent project exists, creating it via BOM upload if missing.

.DESCRIPTION
DT's BOM upload endpoint returns 404 when a referenced parent project doesn't exist, so any
workflow that uses parent linkage must guarantee the parent is in place first. This script
performs that bootstrap:

  1. GET /api/v1/project/lookup?name=&version=
  2. If 200, returns immediately.
  3. If 404, POSTs the supplied BOM to /api/v1/bom with autoCreate=true and no parent
     reference. DT creates the project as a root project. Subsequent BOM uploads can then
     reference it as parent.

The plain project create endpoint (PUT /api/v1/project) requires the higher-privilege
PORTFOLIO_MANAGEMENT permission. The BOM-upload bootstrap path only needs
PROJECT_CREATION_UPLOAD, which a typical CI key already carries.

.PARAMETER ServerUrl
Base URL including scheme.

.PARAMETER ApiKey
DT API key with PROJECT_CREATION_UPLOAD.

.PARAMETER ProjectName
Parent project name to ensure.

.PARAMETER ProjectVersion
Parent project version to ensure.

.PARAMETER BomPath
Path to a CycloneDX BOM file used to bootstrap the parent if missing. Required because the
DT BOM endpoint requires a BOM payload even when only creating the project.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ServerUrl,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ApiKey,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ProjectName,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ProjectVersion,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$BomPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $BomPath)) {
    throw "BomPath '$BomPath' not found"
}

$invokeRest = Join-Path -Path $PSScriptRoot -ChildPath 'private/Invoke-DTRestMethod.ps1'

$lookup = & $invokeRest `
    -ServerUrl $ServerUrl `
    -ApiKey $ApiKey `
    -Method Get `
    -Path '/api/v1/project/lookup' `
    -Query @{ name = $ProjectName; version = $ProjectVersion } `
    -ExpectStatus 200, 404

if ($lookup.StatusCode -eq 200) {
    Write-Information "Parent $ProjectName@$ProjectVersion already exists" -InformationAction Continue
    return
}

Write-Information "Bootstrapping parent $ProjectName@$ProjectVersion via BOM upload" -InformationAction Continue

$send = Join-Path -Path $PSScriptRoot -ChildPath 'Send-DTBom.ps1'
& $send `
    -ServerUrl $ServerUrl `
    -ApiKey $ApiKey `
    -ProjectName $ProjectName `
    -ProjectVersion $ProjectVersion `
    -BomPath $BomPath `
    -AutoCreate
