#Requires -Version 7.0

<#
.SYNOPSIS
Bootstraps a Backstage-style Dependency-Track project hierarchy
(domain -> system -> component -> channel) idempotently.

.DESCRIPTION
Creates the four grouping projects that sit above per-build SBOM uploads, in order, each
linked to the one above it. Already-existing projects are left untouched. Layout:

    <Domain>          @ "domain"        (root)
    <System>          @ "system"        (parent: <Domain>@domain)
    <Component>       @ "component"     (parent: <System>@system)
    <Component>       @ <Channel>       (parent: <Component>@component)

Where <Channel> is a free-form bucket such as "release", "prerelease", or "ci/main".

The DT project create endpoint (PUT /api/v1/project) is used because BOM-upload bootstrap
would attach the supplied BOM to the grouping project, which is misleading for an empty
container. PUT requires PORTFOLIO_MANAGEMENT, but only the *first* run from a new
deployment needs that permission; subsequent CI uploads see all four projects already in
place and skip the create path entirely.

.PARAMETER ServerUrl
Base URL including scheme.

.PARAMETER ApiKey
DT API key. Needs PORTFOLIO_MANAGEMENT for the initial create; PROJECT_CREATION_UPLOAD is
sufficient on subsequent runs (no-op path).

.PARAMETER Domain
Top-level grouping (Backstage domain).

.PARAMETER System
Mid-level grouping (Backstage system).

.PARAMETER Component
Component name. Reused as the project name for the component umbrella and the channel
umbrella so they sort together in the DT portfolio view.

.PARAMETER Channel
Optional fourth-level bucket below the component (e.g. "release", "prerelease",
"ci/main"). Skipped when omitted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ServerUrl,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ApiKey,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$Domain,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$System,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$Component,
    [Parameter(Mandatory = $false)] [string]$Channel
)

$ErrorActionPreference = 'Stop'

$invokeRest = Join-Path -Path $PSScriptRoot -ChildPath 'private/Invoke-DTRestMethod.ps1'

function Get-DTProjectUuid {
    param([string]$Name, [string]$Version)

    $lookup = & $invokeRest `
        -ServerUrl $ServerUrl `
        -ApiKey $ApiKey `
        -Method Get `
        -Path '/api/v1/project/lookup' `
        -Query @{ name = $Name; version = $Version } `
        -ExpectStatus 200, 404

    if ($lookup.StatusCode -eq 200 -and $lookup.Body.uuid) {
        return $lookup.Body.uuid
    }
    return $null
}

function New-DTGroupingProject {
    param(
        [string]$Name,
        [string]$Version,
        [string]$ParentUuid
    )

    $existing = Get-DTProjectUuid -Name $Name -Version $Version
    if ($existing) {
        Write-Information "Hierarchy node $Name@$Version already exists ($existing)" -InformationAction Continue
        return $existing
    }

    $body = [ordered]@{
        name           = $Name
        version        = $Version
        classifier     = 'APPLICATION'
        description    = "Grouping node ($Version) for $Name"
    }
    if ($ParentUuid) {
        $body.parent = @{ uuid = $ParentUuid }
    }

    $created = & $invokeRest `
        -ServerUrl $ServerUrl `
        -ApiKey $ApiKey `
        -Method Put `
        -Path '/api/v1/project' `
        -Body $body `
        -ExpectStatus 200, 201, 403

    if ($created.StatusCode -eq 403) {
        $msg = "Dependency-Track refused project create with HTTP 403 for $Name@$Version. " +
               "The supplied API key lacks PORTFOLIO_MANAGEMENT, required by PUT /api/v1/project. " +
               "Bootstrap the hierarchy once with an admin key (the script is idempotent: subsequent " +
               "runs from any key with VIEW_PORTFOLIO will see the projects exist and skip create), " +
               "or grant PORTFOLIO_MANAGEMENT to the API key in use."
        Write-Host "::error::$msg"
        throw $msg
    }

    if (-not $created.Body.uuid) {
        throw "DT create returned no uuid for $Name@$Version"
    }

    Write-Information "Created hierarchy node $Name@$Version ($($created.Body.uuid))" -InformationAction Continue
    return $created.Body.uuid
}

$domainUuid    = New-DTGroupingProject -Name $Domain    -Version 'domain'    -ParentUuid $null
$systemUuid    = New-DTGroupingProject -Name $System    -Version 'system'    -ParentUuid $domainUuid
$componentUuid = New-DTGroupingProject -Name $Component -Version 'component' -ParentUuid $systemUuid

if ($Channel) {
    $null = New-DTGroupingProject -Name $Component -Version $Channel -ParentUuid $componentUuid
}
