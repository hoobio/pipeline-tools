#Requires -Version 7.0

<#
.SYNOPSIS
Stamps the four-part version number into a Package.appxmanifest's Identity element.

.DESCRIPTION
WinUI / UWP packages encode the package version in `Package.appxmanifest`'s
`<Identity Version="X.Y.Z.W"/>` attribute. This script reads a SemVer-ish version
(e.g. "1.2.3"), pads it to a four-part tuple, and rewrites the manifest in place.

.PARAMETER ManifestPath
Path to Package.appxmanifest.

.PARAMETER Version
Version to stamp. Accepts "X.Y.Z" (extended to "X.Y.Z.0") or "X.Y.Z.W".
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ManifestPath,
    [Parameter(Mandatory = $true)] [ValidatePattern('^\d+\.\d+\.\d+(\.\d+)?$')] [string]$Version
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "ManifestPath '$ManifestPath' not found"
}

$resolved = (Resolve-Path -LiteralPath $ManifestPath).Path

# Pad to 4 parts (X.Y.Z -> X.Y.Z.0).
$fourPart = if ($Version -match '^\d+\.\d+\.\d+$') { "$Version.0" } else { $Version }

$content = [System.IO.File]::ReadAllText($resolved)
$pattern = '(?<=<Identity\s[^>]*)Version="[\d.]+"'
$replacement = "Version=`"$fourPart`""
$updated = [regex]::Replace($content, $pattern, $replacement)

if ($updated -eq $content) {
    Write-Warning "No <Identity Version=...> attribute found in '$resolved'; manifest unchanged"
    return
}

[System.IO.File]::WriteAllText($resolved, $updated, [System.Text.UTF8Encoding]::new($false))
Write-Information "Stamped $resolved with version $fourPart" -InformationAction Continue
