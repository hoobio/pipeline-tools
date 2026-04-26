#Requires -Version 7.0

<#
.SYNOPSIS
Generates a CycloneDX SBOM for a .NET solution or project using the dotnet CycloneDX tool.

.DESCRIPTION
Installs (or updates) the global CycloneDX tool to the requested version, runs it against the
target solution/project, and writes the resulting JSON BOM to OutputPath. The emitted spec
version is pinned via -SpecVersion so consumers can guarantee compatibility with their SBOM
tooling.

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

if (-not (Test-Path -LiteralPath $SolutionPath)) {
    throw "SolutionPath '$SolutionPath' not found"
}

Write-Verbose "Installing CycloneDX dotnet tool $ToolVersion"
& dotnet tool update --global CycloneDX --version $ToolVersion 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    & dotnet tool install --global CycloneDX --version $ToolVersion
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install dotnet CycloneDX $ToolVersion (exit $LASTEXITCODE)"
    }
}

$workDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$workFileName = [System.IO.Path]::GetFileName($OutputPath)

try {
    Write-Verbose "Running dotnet CycloneDX against $SolutionPath (spec $SpecVersion)"
    & dotnet CycloneDX $SolutionPath `
        --spec-version $SpecVersion `
        --json `
        --output $workDir `
        --filename $workFileName
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet CycloneDX failed (exit $LASTEXITCODE)"
    }

    $generated = Join-Path -Path $workDir -ChildPath $workFileName
    if (-not (Test-Path -LiteralPath $generated)) {
        throw "CycloneDX did not produce expected output at '$generated'"
    }

    $outDir = Split-Path -Path $OutputPath -Parent
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    Move-Item -Path $generated -Destination $OutputPath -Force
    Write-Information "BOM written to $OutputPath" -InformationAction Continue
}
finally {
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
