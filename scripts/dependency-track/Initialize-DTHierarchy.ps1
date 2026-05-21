#Requires -Version 7.0

<#
.SYNOPSIS
Bootstraps a Backstage-style Dependency-Track project hierarchy
(domain -> system -> component -> channel [-> subChannel]) idempotently.

.DESCRIPTION
Creates the grouping projects that sit above per-build SBOM uploads, in order, each
linked to the one above it. Layout:

    <Domain>          @ "domain"        (root)
    <System>          @ "system"        (parent: <Domain>@domain)
    <Component>       @ "component"     (parent: <System>@system)
    <Component>       @ <Channel>       (parent: <Component>@component)
    <Component>       @ <SubChannel>    (parent: <Component>@<Channel>)   [optional]

Where <Channel> is a free-form bucket and <SubChannel> is an optional fifth level
used to group CI builds from non-default branches under a shared "ci" channel.
Typical layouts:

    release builds   : domain/system/component@component/component@release
    default branch   : domain/system/component@component/component@<default-branch>
    feature branches : domain/system/component@component/component@ci/component@<branch>
    hotfix (gitflow) : domain/system/component@component/component@hotfix/component@<hotfix-id>

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
Fourth-level bucket below the component, e.g. "release", "prerelease", "<default-branch>",
"hotfix", or "ci".

.PARAMETER SubChannel
Optional fifth-level bucket below the channel. Use when the channel groups multiple
buckets that each need their own SBOM history (most commonly: channel="ci" and
SubChannel="<branch-name>"). The composite step that consumes this bootstrap will then
upload the per-build BOM as a child of <Component>@<SubChannel> instead of
<Component>@<Channel>.

.PARAMETER Classifier
DT project classifier applied to every grouping node. Defaults to PLATFORM, which
matches the role of these nodes (umbrellas, not real applications).

.PARAMETER DomainCollectionLogic
Collection logic applied to the domain umbrella. Defaults to AGGREGATE_DIRECT_CHILDREN.

.PARAMETER SystemCollectionLogic
Collection logic applied to the system umbrella. Defaults to AGGREGATE_DIRECT_CHILDREN.

.PARAMETER ComponentCollectionLogic
Collection logic applied to the component umbrella. Defaults to
AGGREGATE_DIRECT_CHILDREN, summing across every channel under the component.
AGGREGATE_LATEST_VERSION_CHILDREN would be ideal in theory (pick the canonical
channel), but DT's isLatest flag is keyed by project name, and our umbrellas share
the project name with their per-build children. Marking a channel umbrella as
isLatest would clash with marking individual builds isLatest at the channel level,
so the latest-version logic collapses to zero at the component view. Summing direct
children avoids that, at the cost of overcounting when the same SHA exists in
multiple channels (rare; bounded).

.PARAMETER ChannelCollectionLogic
Collection logic applied to the channel umbrella. Defaults to
AGGREGATE_LATEST_VERSION_CHILDREN, so the channel view rolls up only the latest
per-build SBOM upload (the one marked isLatest=true at upload time). When SubChannel
is in use, the channel umbrella's direct children are SubChannel nodes (one per
branch), so AGGREGATE_DIRECT_CHILDREN may better suit a "see every branch" view;
leave the default unless you have a reason.

.PARAMETER SubChannelCollectionLogic
Collection logic applied to the sub-channel umbrella. Defaults to
AGGREGATE_LATEST_VERSION_CHILDREN, so the per-branch view rolls up only the latest
per-build SBOM upload.

.NOTES
v1 -> v2 channel migration is always-on (no toggle): when invoked with the v2
sub-channel pattern (Channel='ci' + SubChannel='<X>'), the script looks for a
legacy `<Component>@ci/<X>` umbrella - the shape v1 produced when consumers
passed `channel: ci/<branch>` as a single string. If found, every direct child
of the legacy umbrella is re-parented to the newly-created
`<Component>@<SubChannel>` umbrella and the empty legacy is deleted. Idempotent:
subsequent runs find no legacy and no-op. Bumping to a major version that
includes this script is the opt-in.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ServerUrl,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ApiKey,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$Domain,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$System,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$Component,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$Channel,
    [Parameter(Mandatory = $false)] [string]$SubChannel,

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
    [string]$ComponentCollectionLogic = 'AGGREGATE_DIRECT_CHILDREN',

    [Parameter(Mandatory = $false)]
    [ValidateSet('NONE','AGGREGATE_DIRECT_CHILDREN','AGGREGATE_DIRECT_CHILDREN_WITH_TAG','AGGREGATE_LATEST_VERSION_CHILDREN')]
    [string]$ChannelCollectionLogic = 'AGGREGATE_LATEST_VERSION_CHILDREN',

    [Parameter(Mandatory = $false)]
    [ValidateSet('NONE','AGGREGATE_DIRECT_CHILDREN','AGGREGATE_DIRECT_CHILDREN_WITH_TAG','AGGREGATE_LATEST_VERSION_CHILDREN')]
    [string]$SubChannelCollectionLogic = 'AGGREGATE_LATEST_VERSION_CHILDREN'
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

$channelUuid = Sync-DTGroupingProject `
    -ServerUrl $ServerUrl -ApiKey $ApiKey `
    -Name $Component -Version $Channel -ParentUuid $componentUuid `
    -DesiredClassifier $Classifier -DesiredCollectionLogic $ChannelCollectionLogic

$subChannelUuid = $null
if ($SubChannel) {
    $subChannelUuid = Sync-DTGroupingProject `
        -ServerUrl $ServerUrl -ApiKey $ApiKey `
        -Name $Component -Version $SubChannel -ParentUuid $channelUuid `
        -DesiredClassifier $Classifier -DesiredCollectionLogic $SubChannelCollectionLogic
}

# v1 -> v2 channel migration. In v1, consumers passed `channel: ci/<branch>` as a
# single string, producing `<Component>@ci/<branch>` projects with per-build SHAs
# (or BOMs uploaded directly to the channel itself). In v2 the same data lives
# under `<Component>@ci -> <Component>@<branch> -> children`.
#
# Sweep ALL legacy `<Component>@ci/<X>` projects on every bootstrap (not just the
# one matching the current invocation's SubChannel) so a single run after the
# major-version bump migrates the entire history. Bumping to this major version
# IS the opt-in. Idempotent: subsequent runs find no legacy and no-op.
#
# Two legacy shapes are handled:
#
#   PLATFORM legacy (umbrella with per-SHA APPLICATION children):
#     1. Ensure `<Component>@<X>` sub-channel exists under the new
#        `<Component>@ci` umbrella.
#     2. Re-parent every direct child of `<Component>@ci/<X>` to the new
#        sub-channel.
#     3. Delete the now-empty `<Component>@ci/<X>`.
#
#   APPLICATION legacy (BOM was uploaded directly to `<Component>@ci/<X>`
#   without an intermediate per-SHA project, common when v1's autoCreate
#   bootstrapped at the channel level):
#     1. Ensure `<Component>@<X>` sub-channel exists.
#     2. Re-parent the legacy project itself (carrying its BOM data) under the
#        new sub-channel. Its version stays `ci/<X>` to avoid colliding with
#        any existing project named after the new structure, but it now hangs
#        in the right place.
if ($Channel -eq 'ci') {
    $allComponent = & $invokeRest `
        -ServerUrl $ServerUrl -ApiKey $ApiKey `
        -Method Get `
        -Path "/api/v1/project" `
        -Query @{
            name = $Component
            excludeInactive = 'false'
            pageNumber = '1'
            pageSize = '1000'
        } `
        -ExpectStatus 200

    $legacyList = @($allComponent.Body | Where-Object { $_.version -like 'ci/*' })

    if ($legacyList.Count -gt 0) {
        Write-Information "Migration: found $($legacyList.Count) legacy v1 ci/<...> project(s) for $Component; rewriting under the v2 sub-channel hierarchy" -InformationAction Continue
    }

    foreach ($legacy in $legacyList) {
        $legacyVer = $legacy.version
        $subName = $legacyVer.Substring(3)  # strip "ci/"

        # Get/create the new sub-channel umbrella under <Component>@ci.
        $newSubUuid = Sync-DTGroupingProject `
            -ServerUrl $ServerUrl -ApiKey $ApiKey `
            -Name $Component -Version $subName -ParentUuid $channelUuid `
            -DesiredClassifier $Classifier -DesiredCollectionLogic $SubChannelCollectionLogic

        if ($legacy.classifier -eq 'PLATFORM') {
            # Umbrella: re-parent its per-SHA children, then delete it.
            $children = & $invokeRest `
                -ServerUrl $ServerUrl -ApiKey $ApiKey `
                -Method Get `
                -Path "/api/v1/project/$($legacy.uuid)/children" `
                -Query @{ pageNumber = '1'; pageSize = '1000' } `
                -ExpectStatus 200

            $childList = @($children.Body)
            $moved = 0
            foreach ($child in $childList) {
                if (-not $child.uuid) { continue }

                $resp = & $invokeRest `
                    -ServerUrl $ServerUrl -ApiKey $ApiKey `
                    -Method Patch `
                    -Path "/api/v1/project/$($child.uuid)" `
                    -Body @{ parent = @{ uuid = $newSubUuid } } `
                    -ExpectStatus 200, 304, 403, 404

                if ($resp.StatusCode -eq 403) {
                    throw "Dependency-Track refused PATCH with HTTP 403 while re-parenting $($child.name)@$($child.version) under $Component@$subName. The supplied API key lacks PORTFOLIO_MANAGEMENT (required by PATCH /api/v1/project/{uuid}). Aborting migration before more children are moved."
                }
                if ($resp.StatusCode -in 200, 304) { $moved++ }
            }

            $del = & $invokeRest `
                -ServerUrl $ServerUrl -ApiKey $ApiKey `
                -Method Delete `
                -Path "/api/v1/project/$($legacy.uuid)" `
                -ExpectStatus 200, 202, 204, 403, 404

            if ($del.StatusCode -eq 403) {
                Write-Warning "  Migrated $moved child(ren) from $Component@$legacyVer to $Component@$subName, but DELETE of the legacy umbrella was refused (HTTP 403). It's now empty; delete it manually or re-run with PORTFOLIO_MANAGEMENT."
            }
            else {
                Write-Information "  $Component@$legacyVer (umbrella, $moved children) -> $Component@$subName" -InformationAction Continue
            }
        }
        else {
            # BOM upload itself - re-parent under the new sub-channel umbrella.
            # Keep version as `ci/<X>` to avoid colliding with any existing
            # `<Component>@<X>` project (e.g. the umbrella we just created).
            $resp = & $invokeRest `
                -ServerUrl $ServerUrl -ApiKey $ApiKey `
                -Method Patch `
                -Path "/api/v1/project/$($legacy.uuid)" `
                -Body @{ parent = @{ uuid = $newSubUuid } } `
                -ExpectStatus 200, 304, 403

            if ($resp.StatusCode -eq 403) {
                throw "Dependency-Track refused PATCH with HTTP 403 while re-parenting $Component@$legacyVer under $Component@$subName. The supplied API key lacks PORTFOLIO_MANAGEMENT. Aborting migration."
            }
            Write-Information "  $Component@$legacyVer ($($legacy.classifier), BOM upload) re-parented under $Component@$subName" -InformationAction Continue
        }
    }
}
