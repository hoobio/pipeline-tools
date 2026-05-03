#Requires -Version 7.0

<#
.SYNOPSIS
Bootstraps a Backstage-style Dependency-Track project hierarchy
(domain -> system -> component -> channel) idempotently.

.DESCRIPTION
Creates the four grouping projects that sit above per-build SBOM uploads, in order, each
linked to the one above it. Layout:

    <Domain>          @ "domain"        (root)
    <System>          @ "system"        (parent: <Domain>@domain)
    <Component>       @ "component"     (parent: <System>@system)
    <Component>       @ <Channel>       (parent: <Component>@component)

Where <Channel> is a free-form bucket such as "release", "prerelease", or "ci/main".

The DT project create endpoint (PUT /api/v1/project) is used because BOM-upload bootstrap
would attach the supplied BOM to the grouping project, which is misleading for an empty
container. PUT requires PORTFOLIO_MANAGEMENT.

The script is fully idempotent. Each grouping node is created with its target classifier
and collection-logic if absent; if already present, it is patched to match the desired
state on every run. This means running the script after upgrading the desired
classifier/collection-logic will quietly bring the hierarchy in line with the new spec.

.PARAMETER ServerUrl
Base URL including scheme.

.PARAMETER ApiKey
DT API key. Needs PORTFOLIO_MANAGEMENT to create or patch grouping projects;
PROJECT_CREATION_UPLOAD is sufficient on subsequent no-op runs (everything aligned).

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

.PARAMETER Classifier
DT project classifier applied to every grouping node. Defaults to PLATFORM, which
matches the role of these nodes (umbrellas, not real applications).

.PARAMETER DomainCollectionLogic
Collection logic applied to the domain umbrella. Defaults to AGGREGATE_DIRECT_CHILDREN.

.PARAMETER SystemCollectionLogic
Collection logic applied to the system umbrella. Defaults to AGGREGATE_DIRECT_CHILDREN.

.PARAMETER ComponentCollectionLogic
Collection logic applied to the component umbrella. Defaults to
AGGREGATE_LATEST_VERSION_CHILDREN, so the component view rolls up only the latest
version of each channel.

.PARAMETER ChannelCollectionLogic
Collection logic applied to the channel umbrella. Defaults to
AGGREGATE_LATEST_VERSION_CHILDREN, so the channel view rolls up only the latest
per-build SBOM upload (which is what most consumers expect).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ServerUrl,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ApiKey,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$Domain,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$System,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$Component,
    [Parameter(Mandatory = $false)] [string]$Channel,

    [Parameter(Mandatory = $false)]
    [ValidateSet('APPLICATION','FRAMEWORK','LIBRARY','CONTAINER','OPERATING_SYSTEM','DEVICE','FIRMWARE','FILE','PLATFORM','DEVICE_DRIVER','MACHINE_LEARNING_MODEL','DATA','CRYPTOGRAPHIC_ASSET')]
    [string]$Classifier = 'PLATFORM',

    [Parameter(Mandatory = $false)]
    [ValidateSet('NONE','AGGREGATE_DIRECT_CHILDREN','AGGREGATE_DIRECT_CHILDREN_WITH_TAG','AGGREGATE_LATEST_VERSION_CHILDREN')]
    [string]$DomainCollectionLogic = 'AGGREGATE_DIRECT_CHILDREN',

    [Parameter(Mandatory = $false)]
    [ValidateSet('NONE','AGGREGATE_DIRECT_CHILDREN','AGGREGATE_DIRECT_CHILDREN_WITH_TAG','AGGREGATE_LATEST_VERSION_CHILDREN')]
    [string]$SystemCollectionLogic = 'AGGREGATE_DIRECT_CHILDREN',

    [Parameter(Mandatory = $false)]
    [ValidateSet('NONE','AGGREGATE_DIRECT_CHILDREN','AGGREGATE_DIRECT_CHILDREN_WITH_TAG','AGGREGATE_LATEST_VERSION_CHILDREN')]
    [string]$ComponentCollectionLogic = 'AGGREGATE_LATEST_VERSION_CHILDREN',

    [Parameter(Mandatory = $false)]
    [ValidateSet('NONE','AGGREGATE_DIRECT_CHILDREN','AGGREGATE_DIRECT_CHILDREN_WITH_TAG','AGGREGATE_LATEST_VERSION_CHILDREN')]
    [string]$ChannelCollectionLogic = 'AGGREGATE_LATEST_VERSION_CHILDREN'
)

$ErrorActionPreference = 'Stop'

$invokeRest = Join-Path -Path $PSScriptRoot -ChildPath 'private/Invoke-DTRestMethod.ps1'

function Get-DTProject {
    param(
        [string]$ServerUrl,
        [string]$ApiKey,
        [string]$Name,
        [string]$Version
    )

    $lookup = & $invokeRest `
        -ServerUrl $ServerUrl `
        -ApiKey $ApiKey `
        -Method Get `
        -Path '/api/v1/project/lookup' `
        -Query @{ name = $Name; version = $Version } `
        -ExpectStatus 200, 404

    if ($lookup.StatusCode -eq 200 -and $lookup.Body.uuid) {
        return $lookup.Body
    }
    return $null
}

function Update-DTProject {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ServerUrl,
        [string]$ApiKey,
        [string]$Uuid,
        [string]$Name,
        [string]$Version,
        [hashtable]$Patch
    )

    if (-not $Patch -or $Patch.Count -eq 0) { return }

    $summary = ($Patch.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
    if (-not $PSCmdlet.ShouldProcess("$Name@$Version", "Patch fields ($summary)")) {
        return
    }

    $resp = & $invokeRest `
        -ServerUrl $ServerUrl `
        -ApiKey $ApiKey `
        -Method Patch `
        -Path "/api/v1/project/$Uuid" `
        -Body $Patch `
        -ExpectStatus 200, 304, 403

    if ($resp.StatusCode -eq 403) {
        # Drift correction is best-effort. The project already exists, so failing
        # the build because the CI key lacks PORTFOLIO_MANAGEMENT would block
        # consumers from upgrading just to align an umbrella's classifier or
        # collection-logic. Surface the situation as a warning, leave the project
        # on its existing config, and let an operator run once with an admin key
        # when they choose to migrate.
        $msg = "Dependency-Track refused project update with HTTP 403 for $Name@$Version. " +
               "The supplied API key lacks PORTFOLIO_MANAGEMENT, required by PATCH /api/v1/project/{uuid}. " +
               "Leaving $Name@$Version on its existing config. Run the hierarchy bootstrap " +
               "once with an admin key (or grant PORTFOLIO_MANAGEMENT) to align ($summary)."
        Write-Warning $msg
        return
    }

    Write-Information "Updated $Name@$Version ($summary)" -InformationAction Continue
}

function Sync-DTGroupingProject {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ServerUrl,
        [string]$ApiKey,
        [string]$Name,
        [string]$Version,
        [string]$ParentUuid,
        [string]$DesiredClassifier,
        [string]$DesiredCollectionLogic
    )

    $existing = Get-DTProject -ServerUrl $ServerUrl -ApiKey $ApiKey -Name $Name -Version $Version
    if ($existing) {
        $patch = @{}
        if ($existing.classifier -ne $DesiredClassifier) {
            $patch.classifier = $DesiredClassifier
        }
        if ($existing.collectionLogic -ne $DesiredCollectionLogic) {
            $patch.collectionLogic = $DesiredCollectionLogic
        }

        if ($patch.Count -gt 0) {
            Write-Information "Hierarchy node $Name@$Version drift detected; aligning ($($patch.Keys -join ', '))" -InformationAction Continue
            Update-DTProject `
                -ServerUrl $ServerUrl `
                -ApiKey $ApiKey `
                -Uuid $existing.uuid `
                -Name $Name `
                -Version $Version `
                -Patch $patch
        }
        else {
            Write-Information "Hierarchy node $Name@$Version already aligned ($($existing.uuid))" -InformationAction Continue
        }
        return $existing.uuid
    }

    if (-not $PSCmdlet.ShouldProcess("$Name@$Version", 'Create grouping project')) {
        return $null
    }

    $body = [ordered]@{
        name             = $Name
        version          = $Version
        classifier       = $DesiredClassifier
        collectionLogic  = $DesiredCollectionLogic
        description      = "Grouping node ($Version) for $Name"
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
        Write-Information "::error::$msg" -InformationAction Continue
        throw $msg
    }

    if (-not $created.Body.uuid) {
        throw "DT create returned no uuid for $Name@$Version"
    }

    Write-Information "Created hierarchy node $Name@$Version (classifier=$DesiredClassifier, collectionLogic=$DesiredCollectionLogic, $($created.Body.uuid))" -InformationAction Continue
    return $created.Body.uuid
}

$domainUuid = Sync-DTGroupingProject `
    -ServerUrl $ServerUrl -ApiKey $ApiKey `
    -Name $Domain -Version 'domain' -ParentUuid $null `
    -DesiredClassifier $Classifier -DesiredCollectionLogic $DomainCollectionLogic

$systemUuid = Sync-DTGroupingProject `
    -ServerUrl $ServerUrl -ApiKey $ApiKey `
    -Name $System -Version 'system' -ParentUuid $domainUuid `
    -DesiredClassifier $Classifier -DesiredCollectionLogic $SystemCollectionLogic

$componentUuid = Sync-DTGroupingProject `
    -ServerUrl $ServerUrl -ApiKey $ApiKey `
    -Name $Component -Version 'component' -ParentUuid $systemUuid `
    -DesiredClassifier $Classifier -DesiredCollectionLogic $ComponentCollectionLogic

if ($Channel) {
    $null = Sync-DTGroupingProject `
        -ServerUrl $ServerUrl -ApiKey $ApiKey `
        -Name $Component -Version $Channel -ParentUuid $componentUuid `
        -DesiredClassifier $Classifier -DesiredCollectionLogic $ChannelCollectionLogic
}
