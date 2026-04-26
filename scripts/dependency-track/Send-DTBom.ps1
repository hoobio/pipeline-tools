#Requires -Version 7.0

<#
.SYNOPSIS
Uploads a CycloneDX BOM to a Dependency-Track server. Drop-in replacement for
DependencyTrack/gh-upload-sbom that runs entirely in PowerShell.

.DESCRIPTION
POSTs a multipart/form-data BOM upload to the DT v1 BOM endpoint. Supports auto-create,
parent project linkage (DT 4.8+), and project tags (DT 4.12+). Returns the upload token
emitted by DT for downstream polling, if any.

.PARAMETER ServerUrl
Base URL including scheme, e.g. "https://dt.example.com".

.PARAMETER ApiKey
DT API key. The key must hold PROJECT_CREATION_UPLOAD if -AutoCreate is used and the
project does not yet exist.

.PARAMETER ProjectName
Target project name.

.PARAMETER ProjectVersion
Target project version.

.PARAMETER BomPath
Path to a CycloneDX BOM file (JSON or XML).

.PARAMETER ParentName
Optional parent project name. Requires DT 4.8+.

.PARAMETER ParentVersion
Optional parent project version. Requires DT 4.8+.

.PARAMETER ProjectTags
Comma-separated list of tags applied to the (auto-created) project. DT 4.12+.

.PARAMETER AutoCreate
If set, DT creates the project if it does not exist. Requires PROJECT_CREATION_UPLOAD.

.OUTPUTS
PSCustomObject with the parsed DT response (typically the upload token).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ServerUrl,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ApiKey,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ProjectName,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ProjectVersion,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$BomPath,
    [Parameter(Mandatory = $false)] [string]$ParentName,
    [Parameter(Mandatory = $false)] [string]$ParentVersion,
    [Parameter(Mandatory = $false)] [string]$ProjectTags,
    [Parameter(Mandatory = $false)] [switch]$AutoCreate
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $BomPath)) {
    throw "BomPath '$BomPath' not found"
}

$invokeRest = Join-Path -Path $PSScriptRoot -ChildPath 'private/Invoke-DTRestMethod.ps1'

$form = [ordered]@{
    projectName    = $ProjectName
    projectVersion = $ProjectVersion
    bom            = Get-Item -LiteralPath $BomPath
}

if ($AutoCreate) {
    $form['autoCreate'] = 'true'
}

if ($ParentName -and $ParentVersion) {
    $form['parentName'] = $ParentName
    $form['parentVersion'] = $ParentVersion
}
elseif ($ParentName -or $ParentVersion) {
    throw 'ParentName and ParentVersion must both be supplied or both omitted'
}

if ($ProjectTags) {
    $form['projectTags'] = $ProjectTags
}

Write-Information "Uploading BOM to $ProjectName@$ProjectVersion" -InformationAction Continue

$result = & $invokeRest `
    -ServerUrl $ServerUrl `
    -ApiKey $ApiKey `
    -Method Post `
    -Path '/api/v1/bom' `
    -Form $form `
    -ExpectStatus 200, 201

Write-Information "DT accepted upload (HTTP $($result.StatusCode))" -InformationAction Continue
$result.Body
