#Requires -Version 7.0

<#
.SYNOPSIS
Polls Dependency-Track until the BOM upload identified by the given token finishes
processing, or the timeout expires.

.DESCRIPTION
DT processes BOM uploads asynchronously. The upload endpoint returns a token; this
script polls GET /api/v1/bom/token/{token} every PollIntervalSeconds until the
response reports `processing: false`. Throws if the timeout elapses.

.PARAMETER ServerUrl
Base URL including scheme.

.PARAMETER ApiKey
DT API key.

.PARAMETER Token
Upload token returned by DT's BOM upload endpoint.

.PARAMETER TimeoutSeconds
Maximum seconds to wait. Default 600 (10 min).

.PARAMETER PollIntervalSeconds
Seconds between polls. Default 5.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ServerUrl,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ApiKey,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$Token,
    [Parameter(Mandatory = $false)] [ValidateRange(10, 7200)] [int]$TimeoutSeconds = 600,
    [Parameter(Mandatory = $false)] [ValidateRange(1, 60)] [int]$PollIntervalSeconds = 5
)

$ErrorActionPreference = 'Stop'

$invokeRest = Join-Path -Path $PSScriptRoot -ChildPath 'private/Invoke-DTRestMethod.ps1'

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$attempt = 0

while ($true) {
    $attempt++

    $response = & $invokeRest `
        -ServerUrl $ServerUrl `
        -ApiKey $ApiKey `
        -Method Get `
        -Path "/api/v1/bom/token/$Token" `
        -ExpectStatus 200

    if (-not $response.Body.processing) {
        Write-Information "DT processing complete after $attempt poll(s)" -InformationAction Continue
        return
    }

    if ((Get-Date) -ge $deadline) {
        throw "Timed out waiting $TimeoutSeconds s for DT to finish processing token $Token"
    }

    Write-Information "DT still processing (attempt $attempt); sleeping $PollIntervalSeconds s" -InformationAction Continue
    Start-Sleep -Seconds $PollIntervalSeconds
}
