#Requires -Version 7.0

<#
.SYNOPSIS
Removes the dotnet NuGet sources registered by Set-AdoNuGetSource.ps1.

.DESCRIPTION
Removes SourceName, then SourceName-2, SourceName-3, and so on until a name is not found.

.PARAMETER SourceName
Name given to Set-AdoNuGetSource.ps1.

.PARAMETER ConfigFile
NuGet.Config to update. Defaults to the user-level config.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$SourceName,
    [Parameter()] [ValidateNotNullOrEmpty()] [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'

$configArgs = if ($ConfigFile) { @('--configfile', $ConfigFile) } else { @() }

$index = 1
while ($true) {
    $name = if ($index -eq 1) { $SourceName } else { "$SourceName-$index" }
    & dotnet nuget remove source $name @configArgs *> $null
    $removed = $LASTEXITCODE -eq 0
    $global:LASTEXITCODE = 0
    if (-not $removed) { break }
    Write-Information "Removed NuGet source '$name'" -InformationAction Continue
    $index++
}
