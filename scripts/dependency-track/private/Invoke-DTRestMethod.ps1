#Requires -Version 7.0

<#
.SYNOPSIS
Internal: invokes a Dependency-Track REST API call with consistent auth, error handling,
and JSON parsing. Not exposed as a public action.

.PARAMETER ServerUrl
Base URL including scheme, e.g. "https://dt.example.com".

.PARAMETER ApiKey
DT API key. Sent as the X-Api-Key header.

.PARAMETER Method
HTTP method.

.PARAMETER Path
Path component starting with "/api/v1/...". Combined with ServerUrl.

.PARAMETER Query
Hashtable of query string parameters. Values are URL-encoded.

.PARAMETER Body
Request body. Hashtables are JSON-serialised; strings are sent verbatim.

.PARAMETER Form
Multipart form fields. Hashtable; values prefixed with "@" are read from disk.

.PARAMETER ExpectStatus
Acceptable HTTP status codes. Anything else throws.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ServerUrl,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$ApiKey,
    [Parameter(Mandatory = $true)] [ValidateSet('Get', 'Post', 'Put', 'Patch', 'Delete')] [string]$Method,
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$Path,
    [Parameter(Mandatory = $false)] [hashtable]$Query,
    [Parameter(Mandatory = $false)] $Body,
    [Parameter(Mandatory = $false)] [hashtable]$Form,
    [Parameter(Mandatory = $false)] [int[]]$ExpectStatus = @(200, 201, 202, 204)
)

$ErrorActionPreference = 'Stop'

$uri = $ServerUrl.TrimEnd('/') + $Path
if ($Query -and $Query.Count -gt 0) {
    $pairs = foreach ($key in $Query.Keys) {
        $encodedKey = [System.Uri]::EscapeDataString([string]$key)
        $encodedValue = [System.Uri]::EscapeDataString([string]$Query[$key])
        "$encodedKey=$encodedValue"
    }
    $uri = $uri + '?' + ($pairs -join '&')
}

$headers = @{
    'X-Api-Key' = $ApiKey
    'Accept'    = 'application/json'
}

$irmArgs = @{
    Uri                  = $uri
    Method               = $Method
    Headers              = $headers
    SkipHttpErrorCheck   = $true
    StatusCodeVariable   = 'statusCode'
    ResponseHeadersVariable = 'responseHeaders'
}

if ($Form) {
    $irmArgs['Form'] = $Form
}
elseif ($null -ne $Body) {
    if ($Body -is [string]) {
        $irmArgs['Body'] = $Body
        $irmArgs['ContentType'] = 'application/json'
    }
    else {
        $irmArgs['Body'] = $Body | ConvertTo-Json -Depth 10 -Compress
        $irmArgs['ContentType'] = 'application/json'
    }
}

$response = Invoke-RestMethod @irmArgs

if ($ExpectStatus -notcontains $statusCode) {
    $msg = "DT $Method $Path failed with HTTP $statusCode"
    if ($null -ne $response) {
        try {
            $msg += ": $($response | ConvertTo-Json -Depth 5 -Compress)"
        }
        catch {
            Write-Verbose "Could not serialise DT error response body: $($_.Exception.Message)"
        }
    }
    throw $msg
}

[pscustomobject]@{
    StatusCode = $statusCode
    Body       = $response
    Headers    = $responseHeaders
}
