#Requires -Version 7.0

<#
.SYNOPSIS
Registers Azure DevOps NuGet feeds as dotnet sources, authenticated with a bearer token.

.DESCRIPTION
Clears the NuGet http cache, then removes and re-adds one source per feed URL with the
username `not-used` and the token as the password. The first feed uses SourceName; later
feeds use SourceName-2, SourceName-3, and so on. Feed URLs outside Azure DevOps hosts are
refused, so the token never goes to another host.

.PARAMETER FeedUrl
One or more NuGet v3 index URLs on pkgs.dev.azure.com or *.pkgs.visualstudio.com.

.PARAMETER SourceName
Name for the first source.

.PARAMETER Token
Azure DevOps access token (OAuth token or PAT).

.PARAMETER ConfigFile
Existing NuGet.Config to update. Defaults to the user-level config.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://(pkgs\.dev\.azure\.com|[A-Za-z0-9-]+\.pkgs\.visualstudio\.com)/')]
    [string[]]$FeedUrl,

    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$SourceName,
    [Parameter(Mandatory = $true)] [ValidateNotNull()] [securestring]$Token,
    [Parameter()] [ValidateNotNullOrEmpty()] [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'

$configArgs = if ($ConfigFile) { @('--configfile', $ConfigFile) } else { @() }
$password = [System.Net.NetworkCredential]::new('', $Token).Password

& dotnet nuget locals http-cache --clear | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "dotnet nuget locals http-cache --clear failed (exit $LASTEXITCODE)"
}

for ($i = 0; $i -lt $FeedUrl.Count; $i++) {
    $name = if ($i -eq 0) { $SourceName } else { "$SourceName-$($i + 1)" }
    Write-Information "Configuring NuGet source '$name'" -InformationAction Continue

    & dotnet nuget remove source $name @configArgs *> $null
    $global:LASTEXITCODE = 0

    & dotnet nuget add source $FeedUrl[$i] --name $name --username 'not-used' --password $password --store-password-in-clear-text @configArgs
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet nuget add source failed for '$name' (exit $LASTEXITCODE)"
    }
}
