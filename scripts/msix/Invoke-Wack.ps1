#Requires -Version 7.0

<#
.SYNOPSIS
Runs the Windows App Certification Kit against an MSIX package, parses the report,
applies an exclusion list, and emits a structured summary.

.DESCRIPTION
Locates `appcert.exe` under the Windows SDK, runs it against the supplied MSIX in
`-apptype windowspackagedapp` mode, and writes the report XML to ReportPath. After
the run, it parses the report, separates real failures from excluded failures, and:

  - Optionally fails the script with non-zero exit if any non-excluded failures
    remain (controlled by FailOnRealFailure).
  - Always writes a Markdown summary of the run to SummaryPath if provided. The
    summary is formatted for direct paste into a PR comment or
    `$GITHUB_STEP_SUMMARY`.

The exclusions JSON is an array of objects with `test` and `reason` fields:

    [ { "test": "Banned File Analyzer", "reason": "false positive on third-party DLL" } ]

.PARAMETER MsixPath
Directory or file path to scan for an .msix to test. If a directory is supplied,
the first .msix found recursively is used.

.PARAMETER ReportPath
Output path for the appcert XML report.

.PARAMETER ExclusionsPath
Optional path to a JSON exclusions list. Missing file is treated as no exclusions.

.PARAMETER SummaryPath
Optional path to write a Markdown summary to. Useful for $GITHUB_STEP_SUMMARY.

.PARAMETER FailOnRealFailure
If set, exits with code 1 when at least one non-excluded test fails.

.PARAMETER Platform
Optional label used in the Markdown summary header (e.g. `x64` / `ARM64`).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$MsixPath,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ReportPath,
    [Parameter(Mandatory = $false)] [string]$ExclusionsPath,
    [Parameter(Mandatory = $false)] [string]$SummaryPath,
    [Parameter(Mandatory = $false)] [switch]$FailOnRealFailure,
    [Parameter(Mandatory = $false)] [string]$Platform
)

$ErrorActionPreference = 'Stop'

# Locate appcert.exe in the Windows SDK.
$appCert = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\App Certification Kit' `
    -Filter appcert.exe -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName

if (-not $appCert) {
    Write-Warning "appcert.exe not found under the Windows App Certification Kit; skipping WACK"
    if ($SummaryPath) {
        $platformLabel = if ($Platform) { " ($Platform)" } else { '' }
        @"
## :warning: WACK Results$platformLabel

WACK report was not generated - the `appcert.exe` tool was not available on this runner.
"@ | Out-File -LiteralPath $SummaryPath -Encoding utf8
    }
    return
}

# Resolve the .msix to test.
if (Test-Path -LiteralPath $MsixPath -PathType Leaf) {
    $msix = (Resolve-Path -LiteralPath $MsixPath).Path
} else {
    $msix = Get-ChildItem -LiteralPath $MsixPath -Recurse -Filter *.msix -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $msix) {
    throw "No .msix file found at or under '$MsixPath'"
}

$absReport = if ([System.IO.Path]::IsPathRooted($ReportPath)) {
    $ReportPath
} else {
    Join-Path -Path (Get-Location) -ChildPath $ReportPath
}
New-Item -ItemType Directory -Path (Split-Path $absReport -Parent) -Force | Out-Null

Write-Information "Running WACK on $msix" -InformationAction Continue
# appcert returns non-zero on test failures; we apply exclusions ourselves so suppress
# native error propagation here.
$PSNativeCommandErrorActionPreference = $false
& $appCert test -apptype windowspackagedapp -appxpackagepath $msix -reportoutputpath $absReport
$appCertExit = $LASTEXITCODE
Write-Information "appcert exited with code $appCertExit" -InformationAction Continue

if (-not (Test-Path -LiteralPath $absReport)) {
    throw "appcert did not produce a report at '$absReport'"
}

# Load exclusions.
$exclusionMap = @{}
if ($ExclusionsPath -and (Test-Path -LiteralPath $ExclusionsPath)) {
    (Get-Content -LiteralPath $ExclusionsPath | ConvertFrom-Json) | ForEach-Object {
        $exclusionMap[$_.test] = $_.reason
    }
}

# Parse report.
[xml]$report = Get-Content -LiteralPath $absReport
$tests = $report.SelectNodes("//TEST")
$passed       = @($tests | Where-Object { $_.SelectSingleNode("RESULT").InnerText.Trim() -eq 'PASS' })
$failed       = @($tests | Where-Object { $_.SelectSingleNode("RESULT").InnerText.Trim() -eq 'FAIL' })
$skipped      = @($tests | Where-Object { $_.SelectSingleNode("RESULT").InnerText.Trim() -eq 'NOT_APPLICABLE' })
$excluded     = @($failed | Where-Object { $exclusionMap.ContainsKey($_.GetAttribute("NAME")) })
$realFailures = @($failed | Where-Object { -not $exclusionMap.ContainsKey($_.GetAttribute("NAME")) })

Write-Information "WACK summary: $($passed.Count) pass, $($realFailures.Count) fail, $($excluded.Count) excluded, $($skipped.Count) N/A" -InformationAction Continue

# Write Markdown summary if requested.
if ($SummaryPath) {
    $platformLabel = if ($Platform) { " ($Platform)" } else { '' }
    $icon = if ($realFailures.Count -eq 0) { ':white_check_mark:' } else { ':x:' }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("## $icon WACK Results$platformLabel")
    [void]$sb.AppendLine()
    [void]$sb.Append(":green_circle: **$($passed.Count) passed** ")
    if ($realFailures.Count -gt 0) { [void]$sb.Append(":red_circle: **$($realFailures.Count) failed** ") }
    if ($excluded.Count -gt 0)     { [void]$sb.Append(":warning: **$($excluded.Count) excluded** ") }
    if ($skipped.Count -gt 0)      { [void]$sb.Append(":white_circle: **$($skipped.Count) N/A** ") }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine()

    if ($realFailures.Count -gt 0) {
        [void]$sb.AppendLine("### Failed Tests")
        [void]$sb.AppendLine("| Test | Message |")
        [void]$sb.AppendLine("|---|---|")
        foreach ($t in $realFailures) {
            $name = $t.GetAttribute("NAME")
            $msgs = @($t.SelectNodes("MESSAGES/MESSAGE")) | ForEach-Object { $_.GetAttribute("TEXT") }
            $detail = ($msgs -join '; ') -replace '[\r\n]+', ' '
            if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) + '...' }
            if (-not $detail) { $detail = $t.GetAttribute("DESCRIPTION") }
            [void]$sb.AppendLine("| ``$name`` | $detail |")
        }
        [void]$sb.AppendLine()
    }

    if ($excluded.Count -gt 0) {
        [void]$sb.AppendLine("### Excluded Tests")
        [void]$sb.AppendLine("| Test | Reason |")
        [void]$sb.AppendLine("|---|---|")
        foreach ($t in $excluded) {
            $name = $t.GetAttribute("NAME")
            $reason = $exclusionMap[$name]
            [void]$sb.AppendLine("| ``$name`` | $reason |")
        }
        [void]$sb.AppendLine()
    }

    [void]$sb.AppendLine("<details><summary>All tests</summary>")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("| Test | Result |")
    [void]$sb.AppendLine("|---|---|")
    foreach ($t in ($tests | Sort-Object { $_.SelectSingleNode("RESULT").InnerText.Trim() })) {
        $name   = $t.GetAttribute('NAME')
        $result = $t.SelectSingleNode("RESULT").InnerText.Trim()
        $r = if ($result -eq 'PASS') { ':green_circle: Pass' }
             elseif ($result -eq 'FAIL' -and $exclusionMap.ContainsKey($name)) { ':warning: Excluded' }
             elseif ($result -eq 'FAIL') { ':red_circle: Fail' }
             else { ':white_circle: N/A' }
        [void]$sb.AppendLine("| ``$name`` | $r |")
    }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("</details>")

    New-Item -ItemType Directory -Path (Split-Path $SummaryPath -Parent) -Force -ErrorAction SilentlyContinue | Out-Null
    $sb.ToString() | Out-File -LiteralPath $SummaryPath -Encoding utf8
}

if ($FailOnRealFailure -and $realFailures.Count -gt 0) {
    $names = ($realFailures | ForEach-Object { $_.GetAttribute('NAME') }) -join ', '
    Write-Error "$($realFailures.Count) non-excluded WACK test(s) failed: $names"
    exit 1
}
