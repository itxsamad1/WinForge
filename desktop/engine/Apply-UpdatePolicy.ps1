[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Policy,
    [Parameter(Mandatory = $true)] [string]$Root
)

$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'server\Common.ps1')

$path = Join-Path $Root 'catalog\updates.json'
$doc = Read-JsonFile -Path $path
$entry = $null
foreach ($p in (ConvertTo-Array (Get-Prop $doc 'policies'))) {
    if ((Get-Prop $p 'key') -eq $Policy) { $entry = $p; break }
}

if ($null -eq $entry) { throw "Unknown policy: $Policy" }

$scriptRel = Get-Prop $entry 'script'
$scriptPath = Join-Path $Root ('catalog\' + ($scriptRel -replace '/', '\'))
& $scriptPath

Write-Host "Update policy '$Policy' applied." -ForegroundColor Green
