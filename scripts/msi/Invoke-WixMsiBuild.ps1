#Requires -Version 7.0

<#
.SYNOPSIS
Builds a Windows Installer (MSI) package from a WiX 5 source file.

.DESCRIPTION
Three-step flow used in CI:
  1. Install the WiX 5 dotnet global tool (idempotent: the tool reports an error if
     already installed and the script falls back to `dotnet tool update --global`).
  2. Run `wix build` against the supplied `.wxs` source, passing `Version`,
     `Platform`, and `PayloadDir` as preprocessor variables for the source to use.
  3. Verify exactly one `.msi` file landed in OutputDir.

The script is intentionally thin. Anything more elaborate (UI extensions, bundles,
custom actions) belongs in the consumer's `.wxs` rather than in this helper.

.PARAMETER WixSourcePath
Path to the WiX `.wxs` source.

.PARAMETER Version
Three- or four-part version string (e.g. `1.2.3` or `1.2.3.0`). Padded to four
parts before being passed to WiX as the `Version` preprocessor variable.

.PARAMETER Platform
Target architecture. WiX accepts lowercase (`x64`, `arm64`); the script normalises
the supplied value.

.PARAMETER PayloadDir
Directory containing the published payload to wrap (the consumer's
`dotnet publish` output). Passed to WiX as the `PayloadDir` preprocessor variable.

.PARAMETER OutputDir
Directory the produced `.msi` lands in. Created if missing. The output filename is
`<wxs-base-name>-<version>-<platform>.msi`.

.PARAMETER WixVersion
WiX 5 dotnet tool version to install. Defaults to the newest 5.x at the time of
authoring; pin via input if you need reproducibility against a specific release.

.PARAMETER Extension
Optional WiX extensions to add before build (e.g. `WixToolset.UI.wixext`).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$WixSourcePath,
    [Parameter(Mandatory = $true)] [ValidatePattern('^\d+\.\d+\.\d+(\.\d+)?$')] [string]$Version,
    [Parameter(Mandatory = $true)] [ValidateSet('x64', 'ARM64', 'x86')] [string]$Platform,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$PayloadDir,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$OutputDir,
    [Parameter(Mandatory = $false)] [ValidatePattern('^5\.\d+\.\d+(-[\w.]+)?$')] [string]$WixVersion = '5.0.2',
    [Parameter(Mandatory = $false)] [string[]]$Extension = @()
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $WixSourcePath)) {
    throw "WixSourcePath '$WixSourcePath' not found"
}
if (-not (Test-Path -LiteralPath $PayloadDir)) {
    throw "PayloadDir '$PayloadDir' not found"
}

$wxs = (Resolve-Path -LiteralPath $WixSourcePath).Path
$payload = (Resolve-Path -LiteralPath $PayloadDir).Path
$absOutput = if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir
} else {
    Join-Path -Path (Get-Location) -ChildPath $OutputDir
}
New-Item -ItemType Directory -Path $absOutput -Force | Out-Null

# Pad to 4 parts (X.Y.Z -> X.Y.Z.0) so the MSI ProductVersion is well-formed.
$fourPart = if ($Version -match '^\d+\.\d+\.\d+$') { "$Version.0" } else { $Version }
$archLower = $Platform.ToLowerInvariant()

Write-Information "Installing WiX $WixVersion (dotnet global tool)" -InformationAction Continue
& dotnet tool install --global wix --version $WixVersion 2>&1 | Tee-Object -Variable installOutput | Out-Host
if ($LASTEXITCODE -ne 0) {
    # `tool install` returns non-zero if the tool is already installed; fall through to update.
    if ($installOutput -match 'already installed') {
        Write-Information "WiX already installed; running tool update to align to $WixVersion" -InformationAction Continue
        & dotnet tool update --global wix --version $WixVersion
        if ($LASTEXITCODE -ne 0) { throw "dotnet tool update wix failed (exit $LASTEXITCODE)" }
    } else {
        throw "dotnet tool install wix failed (exit $LASTEXITCODE)"
    }
}

# Ensure the dotnet tools shim directory is on PATH for the rest of the script.
$toolsDir = Join-Path -Path $env:USERPROFILE -ChildPath '.dotnet\tools'
if ($env:PATH -notlike "*$toolsDir*") {
    $env:PATH = "$toolsDir;$env:PATH"
}

foreach ($ext in $Extension) {
    if ([string]::IsNullOrWhiteSpace($ext)) { continue }
    Write-Information "Adding WiX extension: $ext" -InformationAction Continue
    & wix extension add --global $ext
    if ($LASTEXITCODE -ne 0) { throw "wix extension add '$ext' failed (exit $LASTEXITCODE)" }
}

$baseName = [System.IO.Path]::GetFileNameWithoutExtension($wxs)
$msiName = "$baseName-$Version-$Platform.msi"
$msiPath = Join-Path -Path $absOutput -ChildPath $msiName

$wixArgs = @(
    'build',
    '-arch', $archLower,
    '-d', "Version=$fourPart",
    '-d', "PayloadDir=$payload",
    '-d', "Platform=$Platform",
    '-out', $msiPath,
    $wxs
)
foreach ($ext in $Extension) {
    if ([string]::IsNullOrWhiteSpace($ext)) { continue }
    $wixArgs += @('-ext', $ext)
}

Write-Information "wix $($wixArgs -join ' ')" -InformationAction Continue
& wix @wixArgs
if ($LASTEXITCODE -ne 0) { throw "wix build failed (exit $LASTEXITCODE)" }

if (-not (Test-Path -LiteralPath $msiPath)) {
    throw "wix build reported success but '$msiPath' is missing"
}

Write-Information "Produced MSI: $msiPath" -InformationAction Continue
