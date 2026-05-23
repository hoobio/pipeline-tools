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

.PARAMETER OutputHtmlPath
Optional path to write a self-contained HTML findings report to. Empty to
skip. When set, the report is rendered with embedded CSS (no external assets)
so a single file is sufficient for distribution as a workflow artifact.

.PARAMETER ArtifactRunUrl
Optional URL to surface in the PR comment as "Download full report". Usually
the workflow run page that will hold the uploaded HTML artifact.

.PARAMETER AdoCollectionUri
Azure DevOps organisation collection URI (e.g. "https://dev.azure.com/Hoobi/").
Required when AdoProjectId + AdoRepoId + AdoPrId are set for ADO PR commenting.

.PARAMETER AdoProjectId
Azure DevOps project ID or name.

.PARAMETER AdoRepoId
Azure DevOps Git repository ID.

.PARAMETER AdoPrId
Azure DevOps pull request id to comment on.

.PARAMETER AdoAccessToken
Azure DevOps System.AccessToken or PAT with PR-comment write scope.
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
    [Parameter(Mandatory = $false)] [string]$CommentMarker = '<!-- dt-pr-gate -->',
    [Parameter(Mandatory = $false)] [string]$OutputHtmlPath,
    [Parameter(Mandatory = $false)] [string]$ArtifactRunUrl,
    [Parameter(Mandatory = $false)] [string]$AdoCollectionUri,
    [Parameter(Mandatory = $false)] [string]$AdoProjectId,
    [Parameter(Mandatory = $false)] [string]$AdoRepoId,
    [Parameter(Mandatory = $false)] [string]$AdoPrId,
    [Parameter(Mandatory = $false)] [string]$AdoAccessToken
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

if ($ArtifactRunUrl) {
    $summaryLines += ''
    $summaryLines += ":paperclip: **Full HTML report:** see the ``dt-findings`` artifact in [this workflow run]($ArtifactRunUrl)."
}

$summary = ($summaryLines -join "`n")

# ---- HTML report (optional) ----
if ($OutputHtmlPath) {
    $htmlPath = [System.IO.Path]::GetFullPath($OutputHtmlPath)
    $htmlDir  = Split-Path -Path $htmlPath -Parent
    if ($htmlDir -and -not (Test-Path -LiteralPath $htmlDir)) {
        New-Item -Path $htmlDir -ItemType Directory -Force | Out-Null
    }

    # Severity → CSS class.
    function Get-SevClass([string]$s) { switch ($s) {
        'critical' { 'sev-critical' }
        'high'     { 'sev-high' }
        'medium'   { 'sev-medium' }
        'low'      { 'sev-low' }
        'info'     { 'sev-info' }
        default    { 'sev-unassigned' }
    }}
    function Escape-Html([string]$s) {
        if ($null -eq $s) { return '' }
        return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
    }

    $statusClass = if ($gateTripped) { 'status-fail' } elseif ($totalCount -gt 0) { 'status-warn' } else { 'status-pass' }
    $statusLabel = if ($gateTripped) { "GATE TRIPPED ($FailOnSeverity+)" } elseif ($totalCount -gt 0) { 'FINDINGS PRESENT' } else { 'CLEAN' }
    $generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss \U\T\C')

    $countCards = foreach ($s in $severityOrder) {
        if ($counts[$s] -gt 0) {
            $cls = Get-SevClass $s
            "<div class='count-card $cls'><span class='count-num'>$($counts[$s])</span><span class='count-label'>$(Escape-Html $s)</span></div>"
        }
    }

    $tableRows = foreach ($f in $sortedFindings) {
        $sev    = ($f.vulnerability.severity ?? 'unknown').ToString().ToLowerInvariant()
        $sevCls = Get-SevClass $sev
        $vulnId = Escape-Html ($f.vulnerability.vulnId ?? 'UNKNOWN')
        $source = Escape-Html ($f.vulnerability.source ?? '')
        $comp   = Escape-Html "$($f.component.name)@$($f.component.version)"
        $title  = Escape-Html ((($f.vulnerability.title ?? '') -replace '\s+', ' ').Trim())
        $url    = $f.vulnerability.url
        $idCell = if ($url) { "<a href='$(Escape-Html $url)' target='_blank' rel='noreferrer'>$vulnId</a>" } else { $vulnId }
        $cweCell = ''
        if ($f.vulnerability.cweId) { $cweCell = "<span class='cwe'>CWE-$(Escape-Html ([string]$f.vulnerability.cweId))</span>" }
        @"
<tr>
  <td class='sev-cell $sevCls'>$([string]$sev)</td>
  <td><code>$idCell</code> <span class='source'>$source</span> $cweCell</td>
  <td><code>$comp</code></td>
  <td>$title</td>
</tr>
"@
    }

    $tableHtml = if ($totalCount -eq 0) {
        "<div class='empty'>:tada: No findings on this project version.</div>"
    } else {
        @"
<table>
  <thead>
    <tr><th>Severity</th><th>Vulnerability</th><th>Component</th><th>Title</th></tr>
  </thead>
  <tbody>
$($tableRows -join "`n")
  </tbody>
</table>
"@
    }

    $html = @"
<!DOCTYPE html>
<html lang='en'>
<head>
  <meta charset='utf-8'>
  <title>Dependency-Track findings - $(Escape-Html $ProjectName)@$(Escape-Html $ProjectVersion)</title>
  <style>
    :root {
      --bg: #0d1117; --bg-2: #161b22; --bg-3: #21262d;
      --border: #30363d; --text: #c9d1d9; --text-dim: #8b949e; --text-bright: #f0f6fc;
      --critical: #f85149; --high: #f39c12; --medium: #f1c40f; --low: #95e6cb; --info: #73d0ff; --unassigned: #6e7681;
      --pass: #56d364; --fail: #f85149; --warn: #f39c12;
    }
    * { box-sizing: border-box; }
    body { margin: 0; padding: 2rem; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: var(--bg); color: var(--text); line-height: 1.5; }
    header { max-width: 1100px; margin: 0 auto 2rem; }
    h1 { color: var(--text-bright); font-size: 1.75rem; margin: 0 0 0.5rem; font-weight: 600; }
    .meta { color: var(--text-dim); font-size: 0.875rem; }
    .meta code { background: var(--bg-2); padding: 0.125rem 0.375rem; border-radius: 0.25rem; font-family: ui-monospace, 'SFMono-Regular', Menlo, monospace; font-size: 0.85rem; color: var(--text); }
    .status { display: inline-block; padding: 0.25rem 0.625rem; border-radius: 0.25rem; font-size: 0.75rem; font-weight: 600; letter-spacing: 0.05em; text-transform: uppercase; margin-left: 0.5rem; }
    .status-pass { background: rgba(86, 211, 100, 0.15); color: var(--pass); }
    .status-warn { background: rgba(243, 156, 18, 0.15); color: var(--warn); }
    .status-fail { background: rgba(248, 81, 73, 0.15); color: var(--fail); }
    main { max-width: 1100px; margin: 0 auto; }
    .counts { display: flex; gap: 0.75rem; margin-bottom: 1.5rem; flex-wrap: wrap; }
    .count-card { background: var(--bg-2); border: 1px solid var(--border); border-radius: 0.5rem; padding: 0.75rem 1rem; min-width: 100px; }
    .count-num { display: block; font-size: 1.5rem; font-weight: 600; color: var(--text-bright); }
    .count-label { display: block; text-transform: uppercase; letter-spacing: 0.05em; font-size: 0.7rem; color: var(--text-dim); margin-top: 0.125rem; }
    .count-card.sev-critical .count-num   { color: var(--critical); }
    .count-card.sev-high     .count-num   { color: var(--high); }
    .count-card.sev-medium   .count-num   { color: var(--medium); }
    .count-card.sev-low      .count-num   { color: var(--low); }
    .count-card.sev-info     .count-num   { color: var(--info); }
    .count-card.sev-unassigned .count-num { color: var(--unassigned); }
    table { width: 100%; border-collapse: collapse; background: var(--bg-2); border: 1px solid var(--border); border-radius: 0.5rem; overflow: hidden; }
    thead th { text-align: left; padding: 0.75rem 1rem; background: var(--bg-3); color: var(--text-dim); font-size: 0.75rem; letter-spacing: 0.05em; text-transform: uppercase; font-weight: 600; border-bottom: 1px solid var(--border); }
    tbody td { padding: 0.75rem 1rem; border-bottom: 1px solid var(--bg-3); vertical-align: top; font-size: 0.875rem; }
    tbody tr:last-child td { border-bottom: none; }
    tbody tr:hover { background: var(--bg-3); }
    code { font-family: ui-monospace, 'SFMono-Regular', Menlo, monospace; font-size: 0.825rem; background: var(--bg-3); padding: 0.125rem 0.375rem; border-radius: 0.25rem; color: var(--text); }
    a { color: var(--info); text-decoration: none; }
    a:hover { text-decoration: underline; }
    .sev-cell { font-weight: 600; text-transform: uppercase; font-size: 0.75rem; letter-spacing: 0.05em; }
    .sev-cell.sev-critical { color: var(--critical); }
    .sev-cell.sev-high     { color: var(--high); }
    .sev-cell.sev-medium   { color: var(--medium); }
    .sev-cell.sev-low      { color: var(--low); }
    .sev-cell.sev-info     { color: var(--info); }
    .sev-cell.sev-unassigned { color: var(--unassigned); }
    .source { color: var(--text-dim); font-size: 0.75rem; margin-left: 0.375rem; }
    .cwe { color: var(--text-dim); font-size: 0.75rem; margin-left: 0.5rem; }
    .empty { text-align: center; padding: 3rem 1rem; background: var(--bg-2); border: 1px solid var(--border); border-radius: 0.5rem; color: var(--low); font-size: 1.125rem; }
    footer { max-width: 1100px; margin: 2rem auto 0; padding-top: 1rem; border-top: 1px solid var(--border); color: var(--text-dim); font-size: 0.75rem; text-align: center; }
    footer code { background: var(--bg-2); }
  </style>
</head>
<body>
  <header>
    <h1>Dependency-Track findings<span class='status $statusClass'>$statusLabel</span></h1>
    <div class='meta'>Project: <code>$(Escape-Html $ProjectName)@$(Escape-Html $ProjectVersion)</code> &middot; Generated: $generatedAt &middot; Gate threshold: <code>$(Escape-Html $FailOnSeverity)</code></div>
  </header>
  <main>
    <section class='counts'>
$([string]::Join("`n", $countCards))
    </section>
    $tableHtml
  </main>
  <footer>Generated by <code>dt-findings-pr-gate</code> from hoobio/pipeline-tools.</footer>
</body>
</html>
"@

    Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8
    Write-Information "Wrote HTML report to $htmlPath" -InformationAction Continue
}

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
    Write-Warning 'GitHub PR comment skipped: pr-number, repo, and github-token must all be supplied.'
}

# Optional Azure DevOps PR thread upsert. Marker text is embedded so re-runs
# update the same thread rather than stacking new ones.
if ($AdoCollectionUri -and $AdoProjectId -and $AdoRepoId -and $AdoPrId -and $AdoAccessToken) {
    $body = "$summary`n`n$CommentMarker"
    $baseUri = $AdoCollectionUri.TrimEnd('/') + "/$AdoProjectId/_apis/git/repositories/$AdoRepoId/pullRequests/$AdoPrId"
    # ADO accepts either Bearer (PAT or System.AccessToken from oauth) or Basic
    # with empty username + PAT. Bearer works for System.AccessToken; PATs need
    # Basic auth. Try Bearer first; fall back to Basic on 401.
    $headers = @{
        Authorization = "Bearer $AdoAccessToken"
        Accept        = 'application/json'
    }
    try {
        $threadList = Invoke-RestMethod -Uri "$baseUri/threads?api-version=7.1" -Headers $headers -Method Get
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 401) {
            $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoAccessToken"))
            $headers.Authorization = "Basic $b64"
            $threadList = Invoke-RestMethod -Uri "$baseUri/threads?api-version=7.1" -Headers $headers -Method Get
        }
        else { throw }
    }

    $existingThread = @($threadList.value | Where-Object {
        $_.comments -and ($_.comments[0].content -like "*$CommentMarker*")
    })[0]

    if ($existingThread) {
        $commentId = $existingThread.comments[0].id
        $patchUri = "$baseUri/threads/$($existingThread.id)/comments/$commentId" + '?api-version=7.1'
        Invoke-RestMethod -Uri $patchUri -Headers $headers -Method Patch `
            -Body (@{ content = $body; commentType = 1 } | ConvertTo-Json -Compress) `
            -ContentType 'application/json' | Out-Null
        Write-Information "Updated existing ADO PR comment in thread $($existingThread.id)" -InformationAction Continue
    }
    else {
        $postUri = "$baseUri/threads?api-version=7.1"
        $payload = @{
            comments = @(@{ parentCommentId = 0; content = $body; commentType = 1 })
            status   = 1
        } | ConvertTo-Json -Depth 5 -Compress
        Invoke-RestMethod -Uri $postUri -Headers $headers -Method Post -Body $payload -ContentType 'application/json' | Out-Null
        Write-Information 'Posted new ADO PR comment thread' -InformationAction Continue
    }
}
elseif ($AdoCollectionUri -or $AdoProjectId -or $AdoRepoId -or $AdoPrId -or $AdoAccessToken) {
    Write-Warning 'ADO PR comment skipped: ado-collection-uri, ado-project-id, ado-repo-id, ado-pr-id, and ado-access-token must all be supplied.'
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
