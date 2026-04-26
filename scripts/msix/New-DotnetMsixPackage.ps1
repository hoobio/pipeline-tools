#Requires -Version 7.0

<#
.SYNOPSIS
Restores, builds, and produces an MSIX package for a .NET WinUI 3 application.

.DESCRIPTION
Wraps `dotnet restore` + `dotnet publish` with the AppxPackage MSBuild flags so the
output directory contains a single `.msix` per platform. Designed for projects that
already declare `<EnableMsixTooling>true</EnableMsixTooling>` and have a
`Package.appxmanifest`.

.PARAMETER ProjectPath
Path to the .csproj that owns the MSIX manifest.

.PARAMETER Platform
Build platform (typically `x64` or `ARM64`).

.PARAMETER Configuration
MSBuild configuration. Defaults to `Release`.

.PARAMETER OutputDir
Destination for the AppxPackage output. Created if it doesn't exist.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ProjectPath,
    [Parameter(Mandatory = $true)] [ValidateSet('x64', 'ARM64', 'x86')] [string]$Platform,
    [Parameter(Mandatory = $false)] [ValidateNotNullOrEmpty()] [string]$Configuration = 'Release',
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$OutputDir
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ProjectPath)) {
    throw "ProjectPath '$ProjectPath' not found"
}

$absOutput = if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir
} else {
    Join-Path -Path (Get-Location) -ChildPath $OutputDir
}
New-Item -ItemType Directory -Path $absOutput -Force | Out-Null

Write-Information "Restoring $ProjectPath ($Platform)" -InformationAction Continue
& dotnet restore $ProjectPath -p:Platform=$Platform
if ($LASTEXITCODE -ne 0) { throw "dotnet restore failed (exit $LASTEXITCODE)" }

Write-Information "Building $ProjectPath ($Platform/$Configuration)" -InformationAction Continue
& dotnet build $ProjectPath -c $Configuration -p:Platform=$Platform --no-restore
if ($LASTEXITCODE -ne 0) { throw "dotnet build failed (exit $LASTEXITCODE)" }

Write-Information "Publishing MSIX for $ProjectPath ($Platform/$Configuration) to $absOutput" -InformationAction Continue
# WindowsPackageType=MSIX overrides projects that ship unpackaged by default
# (e.g. WinUI apps that set WindowsPackageType=None for local dev). Projects already
# defaulting to MSIX are unaffected. WindowsAppSDKSelfContained=false keeps the MSIX
# size bounded by relying on the Windows App SDK runtime install.
& dotnet publish $ProjectPath `
    -c $Configuration `
    -p:Platform=$Platform `
    -p:WindowsPackageType=MSIX `
    -p:WindowsAppSDKSelfContained=false `
    -p:AppxPackageDir="$absOutput\" `
    -p:GenerateAppxPackageOnBuild=true `
    -p:AppxBundle=Never
if ($LASTEXITCODE -ne 0) { throw "dotnet publish (MSIX) failed (exit $LASTEXITCODE)" }

$produced = Get-ChildItem -Path $absOutput -Recurse -Filter *.msix -ErrorAction SilentlyContinue
if (-not $produced) {
    throw "No .msix file produced under '$absOutput' after publish"
}

Write-Information "Produced $($produced.Count) MSIX file(s):" -InformationAction Continue
foreach ($pkg in $produced) {
    Write-Information "  $($pkg.FullName)" -InformationAction Continue
}
