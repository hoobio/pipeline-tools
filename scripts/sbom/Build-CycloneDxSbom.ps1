#Requires -Version 7.0

<#
.SYNOPSIS
Generate a CycloneDX BOM for a container image, an application lockfile, or both,
optionally merging them into a single BOM for upload to Dependency-Track.

.DESCRIPTION
Single source of truth for CycloneDX BOM generation in this repository. The ADO
templates and GitHub composite actions are thin wrappers over this script.

Invocation modes:

    -Image only                  Container scan via Syft (OS + filesystem
                                 packages). Sufficient on its own for vulnerability
                                 management but typically lacks accurate license
                                 and direct-vs-transitive metadata for application
                                 dependencies.

    -AppLanguage only            Application-level scan via the language-native
                                 CycloneDX tool. Accurate metadata but no OS
                                 coverage.

    -Image and -AppLanguage      Both scans run, then merged via cyclonedx-cli.
                                 The container BOM is fed in first and the
                                 application BOM second so that when DT dedupes
                                 components by purl on ingest, the lockfile-sourced
                                 metadata wins for any package that appears in
                                 both. Result: OS + filesystem packages from Syft,
                                 plus accurate license / direct-transitive
                                 attribution from the language tool.

All scanners run inside pinned Docker images so the agent only needs Docker
itself. The .NET tool is the exception: it runs against the locally-installed
dotnet SDK because Dockerised .NET scans need NuGet feed configuration mounted
in, which is brittle. Consumers running .NET scans must ensure `dotnet` is on
PATH (UseDotNet@2 / actions/setup-dotnet).

.PARAMETER Image
Container image reference to scan with Syft, e.g. registry.example.com/app:sha.
Optional. When omitted, no container scan is performed.

.PARAMETER SyftVersion
Pinned anchore/syft image tag. Defaults to a known-good version.

.PARAMETER AppLanguage
Application-level scanner to run. One of: none, python, node, dotnet.
Default 'none'. When set to anything other than 'none', -AppManifestPath is
required.

.PARAMETER AppManifestPath
Path the application scanner reads from. Semantics differ by language:

    python   Directory containing pyproject.toml + a recognised lockfile
             (uv.lock, poetry.lock, Pipfile.lock, or requirements.txt).
    node     Directory containing package.json + lockfile. When the
             lockfile is bun.lock (text) or bun.lockb (binary), the directory
             is scanned via Syft so the lockfile is read accurately. Otherwise
             cyclonedx-npm reads package-lock.json / yarn.lock / pnpm-lock.
    dotnet   Path to a .sln, .slnx, or .csproj file.

.PARAMETER PythonImage
Docker image used to run cyclonedx-py.

.PARAMETER CycloneDxPyVersion
Pinned cyclonedx-bom (the PyPI package providing cyclonedx-py) version.

.PARAMETER NodeImage
Docker image used to run cyclonedx-npm.

.PARAMETER CycloneDxNpmVersion
Pinned @cyclonedx/cyclonedx-npm version.

.PARAMETER DotnetSpecVersion
CycloneDX spec version emitted by the .NET tool.

.PARAMETER DotnetToolVersion
Pinned dotnet CycloneDX tool version.

.PARAMETER CycloneDxCliImage
Docker image used to run cyclonedx-cli merge when both scans run.

.PARAMETER OutputPath
Destination path for the final BOM file (JSON).

.EXAMPLE
# Container scan only
./Build-CycloneDxSbom.ps1 `
    -Image registry.example.com/myapp:abc123 `
    -OutputPath ./sbom.cdx.json

.EXAMPLE
# Container + Python merge
./Build-CycloneDxSbom.ps1 `
    -Image registry.example.com/myapp:abc123 `
    -AppLanguage python `
    -AppManifestPath . `
    -OutputPath ./sbom.cdx.json

.EXAMPLE
# .NET application only (no container)
./Build-CycloneDxSbom.ps1 `
    -AppLanguage dotnet `
    -AppManifestPath ./src/MySolution.slnx `
    -OutputPath ./sbom.cdx.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Image,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$SyftVersion = 'v1.44.0',

    [Parameter(Mandatory = $false)]
    [ValidateSet('none', 'python', 'node', 'dotnet')]
    [string]$AppLanguage = 'none',

    [Parameter(Mandatory = $false)]
    [string]$AppManifestPath,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$PythonImage = 'python:3.13-slim',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$CycloneDxPyVersion = '7.3.0',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$NodeImage = 'node:22-alpine',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$CycloneDxNpmVersion = '4.2.1',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^\d+\.\d+$')]
    [string]$DotnetSpecVersion = '1.6',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$DotnetToolVersion = '6.2.0',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$CycloneDxCliImage = 'cyclonedx/cyclonedx-cli:0.32.0',

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

function Assert-DockerAvailable {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'docker is not on PATH. Build-CycloneDxSbom.ps1 requires Docker for container, Python, and Node scans, and for cyclonedx-cli merge.'
    }
}

function Invoke-SyftScan {
    param(
        [Parameter(Mandatory)] [string]$Image,
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter(Mandatory)] [string]$SyftVersion
    )
    Assert-DockerAvailable

    $absOutput = [System.IO.Path]::GetFullPath($OutputPath)
    $outDir    = Split-Path -Path $absOutput -Parent
    $outFile   = Split-Path -Path $absOutput -Leaf

    Write-Information "Generating container BOM for $Image via anchore/syft:$SyftVersion" -InformationAction Continue

    & docker run --rm `
        -v '/var/run/docker.sock:/var/run/docker.sock' `
        -v "${outDir}:/out" `
        -w /out `
        "anchore/syft:$SyftVersion" `
        $Image `
        -o "cyclonedx-json=$outFile"

    if ($LASTEXITCODE -ne 0) {
        throw "Syft scan failed for image '$Image' (exit $LASTEXITCODE)"
    }
    if (-not (Test-Path -LiteralPath $absOutput)) {
        throw "Syft did not produce expected output at '$absOutput'"
    }
}

function Invoke-SyftDirScan {
    param(
        [Parameter(Mandatory)] [string]$DirPath,
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter(Mandatory)] [string]$SyftVersion
    )
    Assert-DockerAvailable

    $absDir    = (Resolve-Path -LiteralPath $DirPath).Path
    $absOutput = [System.IO.Path]::GetFullPath($OutputPath)
    $outDir    = Split-Path -Path $absOutput -Parent
    $outFile   = Split-Path -Path $absOutput -Leaf

    Write-Information "Generating directory BOM for $absDir via anchore/syft:$SyftVersion" -InformationAction Continue

    & docker run --rm `
        -v "${absDir}:/work:ro" `
        -v "${outDir}:/out" `
        "anchore/syft:$SyftVersion" `
        'dir:/work' `
        -o "cyclonedx-json=/out/$outFile"

    if ($LASTEXITCODE -ne 0) {
        throw "Syft directory scan failed for '$absDir' (exit $LASTEXITCODE)"
    }
    if (-not (Test-Path -LiteralPath $absOutput)) {
        throw "Syft did not produce expected output at '$absOutput'"
    }
}

function Invoke-PythonScan {
    param(
        [Parameter(Mandatory)] [string]$ManifestPath,
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter(Mandatory)] [string]$PythonImage,
        [Parameter(Mandatory)] [string]$CycloneDxPyVersion
    )
    Assert-DockerAvailable

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Container)) {
        throw "Python -AppManifestPath must be a directory containing pyproject.toml plus a lockfile: '$ManifestPath'"
    }

    $absManifest = (Resolve-Path -LiteralPath $ManifestPath).Path
    $absOutput   = [System.IO.Path]::GetFullPath($OutputPath)
    $outDir      = Split-Path -Path $absOutput -Parent
    $outFile     = Split-Path -Path $absOutput -Leaf

    Write-Information "Generating Python BOM from $absManifest via $PythonImage" -InformationAction Continue

    # Lockfile preference: uv > poetry > pipenv > requirements.txt. The first three
    # are lockfile-driven so produce accurate transitive metadata. requirements.txt
    # is the fallback - some entries may lack hashes or pin sources.
    $shellScript = @"
set -eu
cd /work
pip install --no-cache-dir --quiet 'cyclonedx-bom==$CycloneDxPyVersion'
if [ -f uv.lock ]; then
  pip install --no-cache-dir --quiet uv
  uv export --format requirements-txt --no-hashes --no-emit-project --quiet > /tmp/req.txt
  cyclonedx-py requirements /tmp/req.txt --output-format JSON --output-file "/out/$outFile"
elif [ -f poetry.lock ]; then
  cyclonedx-py poetry --output-format JSON --output-file "/out/$outFile"
elif [ -f Pipfile.lock ]; then
  cyclonedx-py pipenv --output-format JSON --output-file "/out/$outFile"
elif [ -f requirements.txt ]; then
  cyclonedx-py requirements requirements.txt --output-format JSON --output-file "/out/$outFile"
else
  echo "no supported Python lockfile in /work (looked for uv.lock, poetry.lock, Pipfile.lock, requirements.txt)" >&2
  exit 1
fi
"@

    & docker run --rm `
        -v "${absManifest}:/work:ro" `
        -v "${outDir}:/out" `
        "$PythonImage" `
        sh -c $shellScript

    if ($LASTEXITCODE -ne 0) {
        throw "cyclonedx-py scan failed (exit $LASTEXITCODE)"
    }
    if (-not (Test-Path -LiteralPath $absOutput)) {
        throw "cyclonedx-py did not produce expected output at '$absOutput'"
    }
}

function Invoke-NodeScan {
    param(
        [Parameter(Mandatory)] [string]$ManifestPath,
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter(Mandatory)] [string]$NodeImage,
        [Parameter(Mandatory)] [string]$CycloneDxNpmVersion,
        [Parameter(Mandatory)] [string]$SyftVersion
    )
    Assert-DockerAvailable

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Container)) {
        throw "Node -AppManifestPath must be a directory containing package.json + lockfile: '$ManifestPath'"
    }

    $absManifest = (Resolve-Path -LiteralPath $ManifestPath).Path

    # cyclonedx-npm doesn't understand bun's lockfile (neither the binary
    # bun.lockb nor the JSON bun.lock format introduced in bun 1.2). Syft
    # does, so route bun projects through a directory scan when detected.
    $hasBunLockfile = (Test-Path -LiteralPath (Join-Path $absManifest 'bun.lock')) -or
                      (Test-Path -LiteralPath (Join-Path $absManifest 'bun.lockb'))
    if ($hasBunLockfile) {
        Write-Information "Detected bun lockfile in $absManifest; scanning via anchore/syft:$SyftVersion" -InformationAction Continue
        Invoke-SyftDirScan -DirPath $absManifest -OutputPath $OutputPath -SyftVersion $SyftVersion
        return
    }

    $absOutput   = [System.IO.Path]::GetFullPath($OutputPath)
    $outDir      = Split-Path -Path $absOutput -Parent
    $outFile     = Split-Path -Path $absOutput -Leaf

    Write-Information "Generating Node BOM from $absManifest via $NodeImage" -InformationAction Continue

    $shellScript = @"
set -eu
cd /work
if [ ! -f package.json ]; then
  echo "package.json not found in /work" >&2
  exit 1
fi
npx -y -p "@cyclonedx/cyclonedx-npm@$CycloneDxNpmVersion" cyclonedx-npm \
  --package-lock-only \
  --output-format JSON \
  --output-file "/out/$outFile"
"@

    & docker run --rm `
        -v "${absManifest}:/work:ro" `
        -v "${outDir}:/out" `
        "$NodeImage" `
        sh -c $shellScript

    if ($LASTEXITCODE -ne 0) {
        throw "cyclonedx-npm scan failed (exit $LASTEXITCODE)"
    }
    if (-not (Test-Path -LiteralPath $absOutput)) {
        throw "cyclonedx-npm did not produce expected output at '$absOutput'"
    }
}

function Invoke-DotnetScan {
    param(
        [Parameter(Mandatory)] [string]$ManifestPath,
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter(Mandatory)] [string]$SpecVersion,
        [Parameter(Mandatory)] [string]$ToolVersion
    )
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw ".NET -AppManifestPath '$ManifestPath' not found"
    }
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw "dotnet CLI not on PATH. Install the .NET SDK before invoking (UseDotNet@2 on ADO, actions/setup-dotnet on GitHub). Unlike the other scanners, the .NET path runs locally rather than in Docker because NuGet feed configuration is awkward to mount into a container."
    }

    Write-Information "Installing dotnet CycloneDX tool $ToolVersion" -InformationAction Continue
    & dotnet tool update --global CycloneDX --version $ToolVersion 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & dotnet tool install --global CycloneDX --version $ToolVersion
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install dotnet CycloneDX $ToolVersion (exit $LASTEXITCODE)"
        }
    }

    $absOutput = [System.IO.Path]::GetFullPath($OutputPath)
    $workDir   = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $workFile = Split-Path -Path $absOutput -Leaf

    try {
        Write-Information "Generating .NET BOM from $ManifestPath (spec $SpecVersion)" -InformationAction Continue
        & dotnet CycloneDX $ManifestPath `
            --spec-version $SpecVersion `
            --json `
            --output $workDir `
            --filename $workFile
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet CycloneDX failed (exit $LASTEXITCODE)"
        }

        $generated = Join-Path -Path $workDir -ChildPath $workFile
        if (-not (Test-Path -LiteralPath $generated)) {
            throw "dotnet CycloneDX did not produce expected output at '$generated'"
        }
        Move-Item -Path $generated -Destination $absOutput -Force
    }
    finally {
        if (Test-Path -LiteralPath $workDir) {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-CycloneDxMerge {
    param(
        [Parameter(Mandatory)] [string[]]$Inputs,
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter(Mandatory)] [string]$CliImage
    )
    Assert-DockerAvailable

    Write-Information "Merging $($Inputs.Count) BOMs via $CliImage" -InformationAction Continue

    $stagingDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

    try {
        $containerInputs = @()
        $i = 0
        foreach ($inputPath in $Inputs) {
            $i++
            $name = "bom-$i.cdx.json"
            Copy-Item -Path $inputPath -Destination (Join-Path $stagingDir $name) -Force
            $containerInputs += "/in/$name"
        }

        $absOutput = [System.IO.Path]::GetFullPath($OutputPath)
        $outDir    = Split-Path -Path $absOutput -Parent
        $outFile   = Split-Path -Path $absOutput -Leaf

        $dockerArgs = @(
            'run', '--rm',
            '-v', "${stagingDir}:/in:ro",
            '-v', "${outDir}:/out",
            $CliImage,
            'merge', '--input-files'
        ) + $containerInputs + @(
            '--output-file', "/out/$outFile"
        )

        & docker @dockerArgs

        if ($LASTEXITCODE -ne 0) {
            throw "cyclonedx-cli merge failed (exit $LASTEXITCODE)"
        }
        if (-not (Test-Path -LiteralPath $absOutput)) {
            throw "cyclonedx-cli merge did not produce expected output at '$absOutput'"
        }
    }
    finally {
        if (Test-Path -LiteralPath $stagingDir) {
            Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ----- main -----

if (-not $Image -and $AppLanguage -eq 'none') {
    throw 'Specify at least one of -Image (container scan) or -AppLanguage (application scan). Both can be specified together; their BOMs are merged.'
}

if ($AppLanguage -ne 'none' -and -not $AppManifestPath) {
    throw "-AppManifestPath is required when -AppLanguage is '$AppLanguage'."
}

$outDir = Split-Path -Path $OutputPath -Parent
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

$workDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

try {
    $containerBomPath = $null
    $appBomPath       = $null

    if ($Image) {
        $containerBomPath = Join-Path -Path $workDir -ChildPath 'container.cdx.json'
        Invoke-SyftScan -Image $Image -OutputPath $containerBomPath -SyftVersion $SyftVersion
    }

    if ($AppLanguage -ne 'none') {
        $appBomPath = Join-Path -Path $workDir -ChildPath 'app.cdx.json'
        switch ($AppLanguage) {
            'python' {
                Invoke-PythonScan -ManifestPath $AppManifestPath -OutputPath $appBomPath `
                    -PythonImage $PythonImage -CycloneDxPyVersion $CycloneDxPyVersion
            }
            'node' {
                Invoke-NodeScan -ManifestPath $AppManifestPath -OutputPath $appBomPath `
                    -NodeImage $NodeImage -CycloneDxNpmVersion $CycloneDxNpmVersion `
                    -SyftVersion $SyftVersion
            }
            'dotnet' {
                Invoke-DotnetScan -ManifestPath $AppManifestPath -OutputPath $appBomPath `
                    -SpecVersion $DotnetSpecVersion -ToolVersion $DotnetToolVersion
            }
        }
    }

    # Final output selection. Container first in the merge so the application BOM's
    # metadata wins on DT-side dedupe (last-write-wins by purl).
    if ($containerBomPath -and $appBomPath) {
        Invoke-CycloneDxMerge -Inputs @($containerBomPath, $appBomPath) `
            -OutputPath $OutputPath -CliImage $CycloneDxCliImage
    }
    elseif ($containerBomPath) {
        Copy-Item -Path $containerBomPath -Destination $OutputPath -Force
    }
    elseif ($appBomPath) {
        Copy-Item -Path $appBomPath -Destination $OutputPath -Force
    }

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw "Final BOM was not produced at '$OutputPath'."
    }
    Write-Information "BOM written to $OutputPath" -InformationAction Continue
}
finally {
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
