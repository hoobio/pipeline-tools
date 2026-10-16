#Requires -Version 7.2

<#
.SYNOPSIS
Runs release-please (github-release, then release-pr) with a GitHub App token.

.DESCRIPTION
Mints a GitHub App JWT (RS256) with .NET only, exchanges it for an installation token scoped
to the target repository, registers the token as a secret with the running CI system, then
runs `release-please github-release` followed by `release-please release-pr` through npx at
a pinned version. Each command is retried once after 15 seconds on a non-zero exit.

The release-please CLI reads its token only from `--token`, not from an environment variable.

.PARAMETER AppId
GitHub App ID (digits).

.PARAMETER AppPrivateKey
GitHub App private key, PEM text, as a SecureString.

.PARAMETER Repository
Target repository as owner/name.

.PARAMETER ReleasePleaseVersion
Exact release-please npm version, for example 1.2.3.

.PARAMETER ConfigFile
Path to release-please-config.json in the repository.

.PARAMETER ManifestFile
Path to .release-please-manifest.json in the repository.

.PARAMETER TargetBranch
Branch to tag releases on and open release PRs against.

.PARAMETER ApiUrl
GitHub API base URL.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidatePattern('^\d+$')] [string]$AppId,
    [Parameter(Mandatory = $true)] [ValidateNotNull()] [securestring]$AppPrivateKey,
    [Parameter(Mandatory = $true)] [ValidatePattern('^[\w.-]+/[\w.-]+$')] [string]$Repository,
    [Parameter(Mandatory = $true)] [ValidatePattern('^\d+\.\d+\.\d+$')] [string]$ReleasePleaseVersion,
    [ValidateNotNullOrEmpty()] [string]$ConfigFile = 'release-please-config.json',
    [ValidateNotNullOrEmpty()] [string]$ManifestFile = '.release-please-manifest.json',
    [ValidateNotNullOrEmpty()] [string]$TargetBranch = 'main',
    [ValidateNotNullOrEmpty()] [string]$ApiUrl = 'https://api.github.com'
)

$ErrorActionPreference = 'Stop'

function ConvertTo-Base64Url {
    param([Parameter(Mandatory = $true)] [byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-GitHubAppJwt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$AppId,
        [Parameter(Mandatory = $true)] [securestring]$PrivateKey
    )

    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem([System.Net.NetworkCredential]::new('', $PrivateKey).Password)

        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $header = @{ alg = 'RS256'; typ = 'JWT' } | ConvertTo-Json -Compress
        $payload = @{ iat = $now - 60; exp = $now + 540; iss = $AppId } | ConvertTo-Json -Compress
        $unsigned = '{0}.{1}' -f (ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($header))),
            (ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($payload)))

        $signature = $rsa.SignData(
            [Text.Encoding]::UTF8.GetBytes($unsigned),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

        '{0}.{1}' -f $unsigned, (ConvertTo-Base64Url $signature)
    }
    finally {
        $rsa.Dispose()
    }
}

function Invoke-ReleasePleaseCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [string]$Version,
        [Parameter(Mandatory = $true)] [string]$Token,
        [Parameter(Mandatory = $true)] [string]$Repository,
        [Parameter(Mandatory = $true)] [string]$ConfigFile,
        [Parameter(Mandatory = $true)] [string]$ManifestFile,
        [Parameter(Mandatory = $true)] [string]$TargetBranch
    )

    foreach ($attempt in 1, 2) {
        & npx --yes "release-please@$Version" $Name `
            --token $Token `
            --repo-url $Repository `
            --config-file $ConfigFile `
            --manifest-file $ManifestFile `
            --target-branch $TargetBranch
        if ($LASTEXITCODE -eq 0) { return }
        if ($attempt -eq 1) {
            Write-Warning "release-please $Name exited with code $LASTEXITCODE; retrying in 15 seconds"
            Start-Sleep -Seconds 15
        }
        else {
            throw "release-please $Name failed twice; last exit code $LASTEXITCODE"
        }
    }
}

$repoName = $Repository.Split('/')[1]

try {
    $jwt = Get-GitHubAppJwt -AppId $AppId -PrivateKey $AppPrivateKey
}
catch {
    throw "Could not sign the GitHub App JWT; check the private key is PEM text: $($_.Exception.Message)"
}

$appHeaders = @{
    Authorization          = "Bearer $jwt"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

try {
    $installation = Invoke-RestMethod -Method Get -Uri "$ApiUrl/repos/$Repository/installation" `
        -Headers $appHeaders -ErrorAction Stop
}
catch {
    throw "Could not find the GitHub App installation for ${Repository}: $($_.Exception.Message)"
}

try {
    $tokenResponse = Invoke-RestMethod -Method Post -Uri "$ApiUrl/app/installations/$($installation.id)/access_tokens" `
        -Headers $appHeaders -ContentType 'application/json' `
        -Body (@{ repositories = @($repoName) } | ConvertTo-Json -Compress) -ErrorAction Stop
}
catch {
    throw "Could not create an installation token for ${Repository}: $($_.Exception.Message)"
}

$token = $tokenResponse.token
if ($env:TF_BUILD) { Write-Output "##vso[task.setsecret]$token" }
if ($env:GITHUB_ACTIONS) { Write-Output "::add-mask::$token" }

foreach ($command in 'github-release', 'release-pr') {
    Invoke-ReleasePleaseCommand -Name $command -Version $ReleasePleaseVersion -Token $token `
        -Repository $Repository -ConfigFile $ConfigFile -ManifestFile $ManifestFile -TargetBranch $TargetBranch
}
