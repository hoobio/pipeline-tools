#Requires -Version 7.0

<#
.SYNOPSIS
Imports a PFX signing certificate and signs every MSIX under a directory with signtool.

.DESCRIPTION
Two-step signing flow used in CI:
  1. Decode the base64-encoded PFX from a secret, write it to a temp file, and
     `Import-PfxCertificate` into the user's certificate store.
  2. Locate the newest x64 `signtool.exe` shipped with the Windows SDK, then sign every
     `.msix` under the supplied directory by certificate thumbprint.

The script removes the temp PFX file after import. It does NOT remove the certificate
from the store; runners are ephemeral so this isn't a leak risk in CI.

.PARAMETER PfxBase64
Base64-encoded PFX certificate (typically a workflow secret).

.PARAMETER PfxPassword
Password for the PFX.

.PARAMETER Thumbprint
SHA1 thumbprint of the certificate to sign with.

.PARAMETER PackagesPath
Directory containing one or more .msix files. Subdirectories are searched.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$PfxBase64,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$PfxPassword,
    [Parameter(Mandatory = $true)] [ValidatePattern('^[0-9A-Fa-f]{40}$')] [string]$Thumbprint,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$PackagesPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $PackagesPath)) {
    throw "PackagesPath '$PackagesPath' not found"
}

$pfxPath = Join-Path -Path $env:RUNNER_TEMP -ChildPath ([guid]::NewGuid().ToString('N') + '.pfx')
try {
    [System.IO.File]::WriteAllBytes($pfxPath, [Convert]::FromBase64String($PfxBase64))
    $secure = ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force
    Import-PfxCertificate -FilePath $pfxPath -CertStoreLocation Cert:\CurrentUser\My -Password $secure | Out-Null
}
finally {
    if (Test-Path -LiteralPath $pfxPath) {
        Remove-Item -LiteralPath $pfxPath -Force -ErrorAction SilentlyContinue
    }
}

$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
    Sort-Object { [version]($_.FullName -replace '.*\\(\d+\.\d+\.\d+\.\d+)\\.*', '$1') } -Descending |
    Select-Object -First 1 -ExpandProperty FullName

if (-not $signtool) {
    throw "Could not locate signtool.exe under the Windows SDK"
}
Write-Information "Using signtool: $signtool" -InformationAction Continue

$packages = Get-ChildItem -Path $PackagesPath -Recurse -Filter *.msix -ErrorAction SilentlyContinue
if (-not $packages) {
    throw "No .msix files found under '$PackagesPath'"
}

foreach ($pkg in $packages) {
    Write-Information "Signing $($pkg.FullName)" -InformationAction Continue
    & $signtool sign /fd SHA256 /sha1 $Thumbprint /td SHA256 $pkg.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "signtool failed for $($pkg.FullName) (exit $LASTEXITCODE)"
    }
}

Write-Information "Signed $($packages.Count) package(s)" -InformationAction Continue
