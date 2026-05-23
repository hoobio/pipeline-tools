#Requires -Version 7.0

<#
.SYNOPSIS
Queries Dependency-Track findings for a project + version, writes a Markdown
summary to GITHUB_STEP_SUMMARY, optionally upserts a PR comment, and fails the
step if findings of `FailOnSeverity` (or worse) are present.

.DESCRIPTION
Intended as a CI gate after upload-sbom-to-dependency-track on a PR. Looks up
the (name, version) project, fetches /api/v1/finding/project/<uuid>, bins the
findings by severity, and produces a Markdown table. Severity ordering:
critical > high > medium > low > info > unassigned.

The PR comment is upserted using a marker so re-runs replace the previous
comment rather than stacking new ones. Pass empty PrNumber/RepoName/GithubToken
to skip the comment (useful for non-PR gates).

The exit-non-zero gate is independent of comment posting; you can gate without
commenting and vice-versa.

.PARAMETER ServerUrl
DT base URL.

.PARAMETER ApiKey
DT API key with VIEW_PORTFOLIO + VIEW_VULNERABILITY.

.PARAMETER ProjectName
DT project name (typically the `component` value passed to upload).

.PARAMETER ProjectVersion
DT project version (the `project-version` value passed to upload).

.PARAMETER FailOnSeverity
Lowest severity that triggers a non-zero exit. One of:
critical, high, medium, low, info, none. 'none' disables the gate.
Default: critical.

.PARAMETER PrNumber
GitHub PR number to comment on. Omit for non-PR contexts.

.PARAMETER RepoName
GitHub repo in <owner>/<repo> form. Required when PrNumber is set.

.PARAMETER GithubToken
GitHub token with pull-requests:write. Required when PrNumber is set.

.PARAMETER CommentMarker
HTML-comment marker used to find the prior bot comment for upsert.
Default: '<!-- dt-pr-gate -->'.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ServerUrl,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ApiKey,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ProjectName,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ProjectVersion,
    [Parameter(Mandatory = $false)] [ValidateSet('critical', 'high', 'medium', 'low', 'info', 'none')] [string]$FailOnSeverity = 'critical',
    [Parameter(Mandatory = $false)] [string]$PrNumber,
    [Parameter(Mandatory = $false)] [string]$RepoName,
    [Parameter(Mandatory = $false)] [string]$GithubToken,
    [Parameter(Mandatory = $false)] [string]$CommentMarker = '<!-- dt-pr-gate -->'
)

$ErrorActionPreference = 'Stop'

$invokeRest = Join-Path -Path $PSScriptRoot -ChildPath 'private/Invoke-DTRestMethod.ps1'

# Look up project UUID.
$lookup = & $invokeRest `
    -ServerUrl $ServerUrl `
    -ApiKey $ApiKey `
    -Method Get `
    -Path '/api/v1/project/lookup' `
    -Query @{ name = $ProjectName; version = $ProjectVersion } `
    -ExpectStatus 200, 404

if ($lookup.StatusCode -eq 404) {
    throw "Dependency-Track has no project '$ProjectName@$ProjectVersion'. Upload the BOM before running the gate."
}
$projectUuid = $lookup.Content.uuid
if (-not $projectUuid) {
    throw "Lookup returned no uuid for '$ProjectName@$ProjectVersion'."
}

# Fetch findings.
$findResp = & $invokeRest `
    -ServerUrl $ServerUrl `
    -ApiKey $ApiKey `
    -Method Get `
    -Path "/api/v1/finding/project/$projectUuid"
$findings = @($findResp.Content)

$severityOrder = @('critical', 'high', 'medium', 'low', 'info', 'unassigned')
$counts = [ordered]@{}
foreach ($s in $severityOrder) { $counts[$s] = 0 }
foreach ($f in $findings) {
    $sev = ($f.vulnerability.severity ?? '').ToString().ToLowerInvariant()
    if (-not $counts.Contains($sev)) { $sev = 'unassigned' }
    $counts[$sev]++
}

# Compose Markdown.
$totalCount = ($counts.Values | Measure-Object -Sum).Sum
$gateRank   = @{ critical = 0; high = 1; medium = 2; low = 3; info = 4; none = 99 }[$FailOnSeverity]
$gateTripped = $false
for ($i = 0; $i -lt $severityOrder.Count; $i++) {
    if ($i -le $gateRank -and $counts[$severityOrder[$i]] -gt 0) { $gateTripped = $true; break }
}

$icon = if ($gateTripped) { ':x:' } elseif ($totalCount -gt 0) { ':warning:' } else { ':white_check_mark:' }
$header = "## $icon Dependency-Track scan ($ProjectName@$ProjectVersion)"

$summaryLines = @($header, '')
if ($totalCount -eq 0) {
    $summaryLines += ':tada: **No findings.**'
}
else {
    $summaryLines += "**$totalCount finding(s):**"
    $sevEmojis = @{
        critical   = ':red_circle:'
        high       = ':orange_circle:'
        medium     = ':yellow_circle:'
        low        = ':white_circle:'
        info       = ':information_source:'
        unassigned = ':grey_question:'
    }
    $countLine = foreach ($s in $severityOrder) {
        if ($counts[$s] -gt 0) { "$($sevEmojis[$s]) **$($counts[$s]) $s**" }
    }
    if ($countLine) { $summaryLines += ($countLine -join '  ·  ') }
    $summaryLines += ''

    # Per-finding table (cap so the comment doesn't blow past GitHub's 65k char limit).
    $rowCap = 50
    $rows = @('| Severity | CVE / GHSA | Component | Title |',
              '|---|---|---|---|')
    $sortedFindings = $findings | Sort-Object `
        @{ Expression = { $gateRank.Keys.IndexOf( ($_.vulnerability.severity ?? '').ToLowerInvariant() ) }; Ascending = $true },
        @{ Expression = { $_.vulnerability.vulnId }; Ascending = $true }
    $rendered = 0
    foreach ($f in $sortedFindings) {
        if ($rendered -ge $rowCap) { break }
        $sev    = ($f.vulnerability.severity ?? 'unknown').ToString().ToLowerInvariant()
        $sevTag = "$($sevEmojis[$sev] ?? '') $sev"
        $vulnId = $f.vulnerability.vulnId ?? 'UNKNOWN'
        $source = $f.vulnerability.source ?? ''
        $comp   = "$($f.component.name)@$($f.component.version)"
        $title  = ($f.vulnerability.title ?? '').Trim() -replace '\s+', ' '
        if ($title.Length -gt 120) { $title = $title.Substring(0, 120) + '…' }
        $rows  += "| $sevTag | ``$vulnId`` ($source) | ``$comp`` | $title |"
        $rendered++
    }
    if ($rendered -lt $sortedFindings.Count) {
        $rows += "| _… $($sortedFindings.Count - $rendered) more truncated_ | | | |"
    }
    $summaryLines += $rows
}

$summaryLines += ''
$summaryLines += "_Gate: fails on **$FailOnSeverity** or worse._"

$summary = ($summaryLines -join "`n")

# Write the step summary so the run page surfaces it.
if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary
}

# Optionally upsert a PR comment.
if ($PrNumber -and $RepoName -and $GithubToken) {
    $body = "$summary`n`n$CommentMarker"
    $headers = @{
        Authorization = "Bearer $GithubToken"
        Accept        = 'application/vnd.github+json'
    }
    $listUri  = "https://api.github.com/repos/$RepoName/issues/$PrNumber/comments?per_page=100"
    $comments = Invoke-RestMethod -Uri $listUri -Headers $headers -Method Get
    $existing = @($comments | Where-Object { $_.body -like "*$CommentMarker*" })[0]
    if ($existing) {
        $patchUri = "https://api.github.com/repos/$RepoName/issues/comments/$($existing.id)"
        Invoke-RestMethod -Uri $patchUri -Headers $headers -Method Patch -Body (@{ body = $body } | ConvertTo-Json -Compress) -ContentType 'application/json' | Out-Null
        Write-Information "Updated existing PR comment $($existing.id)" -InformationAction Continue
    }
    else {
        $postUri = "https://api.github.com/repos/$RepoName/issues/$PrNumber/comments"
        Invoke-RestMethod -Uri $postUri -Headers $headers -Method Post -Body (@{ body = $body } | ConvertTo-Json -Compress) -ContentType 'application/json' | Out-Null
        Write-Information "Posted new PR comment" -InformationAction Continue
    }
}
elseif ($PrNumber -or $RepoName -or $GithubToken) {
    Write-Warning 'PR comment skipped: pr-number, repo, and github-token must all be supplied.'
}

# Emit GitHub outputs.
if ($env:GITHUB_OUTPUT) {
    foreach ($s in $severityOrder) {
        "$($s)-count=$($counts[$s])" | Out-File -Append -LiteralPath $env:GITHUB_OUTPUT
    }
    "total-count=$totalCount"      | Out-File -Append -LiteralPath $env:GITHUB_OUTPUT
    "gate-tripped=$($gateTripped.ToString().ToLowerInvariant())" | Out-File -Append -LiteralPath $env:GITHUB_OUTPUT
}

if ($gateTripped) {
    $msg = "Dependency-Track gate tripped: findings at or above '$FailOnSeverity' present."
    Write-Information "::error::$msg" -InformationAction Continue
    exit 1
}
