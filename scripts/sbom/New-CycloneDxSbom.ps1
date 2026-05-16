#Requires -Version 7.0

<#
.SYNOPSIS
Backward-compat wrapper: generate a CycloneDX BOM for a .NET solution or project.

.DESCRIPTION
Soft-deprecated in v2. Delegates to Build-CycloneDxSbom.ps1 with -AppLanguage dotnet
so existing v1 callers keep working without modification. New scripts should call
Build-CycloneDxSbom.ps1 directly because it supports container scans, other
language ecosystems, and merging multiple BOMs.

This wrapper will be removed in a future major release. The set of parameters here
is exactly the v1 surface so v1 -> v2 upgrades that only pin the tag don't fail.

.PARAMETER SolutionPath
Path to the .sln, .slnx, or .csproj to scan.

.PARAMETER OutputPath
Destination path for the generated BOM JSON file.

.PARAMETER SpecVersion
CycloneDX specification version emitted in the BOM (e.g. 1.5, 1.6).

.PARAMETER ToolVersion
Version of the dotnet CycloneDX tool to install. Pin this so CI is reproducible.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SolutionPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^\d+\.\d+$')]
    [string]$SpecVersion = '1.6',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ToolVersion = '6.1.1'
)

$ErrorActionPreference = 'Stop'

Write-Warning "New-CycloneDxSbom.ps1 is soft-deprecated; prefer Build-CycloneDxSbom.ps1 -AppLanguage dotnet. This wrapper will be removed in a future major release."

$builder = Join-Path -Path $PSScriptRoot -ChildPath 'Build-CycloneDxSbom.ps1'

& $builder `
    -AppLanguage dotnet `
    -AppManifestPath $SolutionPath `
    -OutputPath $OutputPath `
    -DotnetSpecVersion $SpecVersion `
    -DotnetToolVersion $ToolVersion
