[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Key,
    [Parameter(Mandatory = $true)] [string]$Root
)

$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'server\Common.ps1')

$fixesPath = Join-Path $Root 'catalog\fixes.json'
$doc = Read-JsonFile -Path $fixesPath
$fix = $null
foreach ($f in (ConvertTo-Array (Get-Prop $doc 'fixes'))) {
    if ((Get-Prop $f 'key') -eq $Key) { $fix = $f; break }
}

if ($null -eq $fix) { throw "Unknown fix: $Key" }

$panel = Get-Prop $fix 'panel'
if (-not [string]::IsNullOrWhiteSpace($panel)) {
    Start-Process $panel
    return
}

$scriptRel = Get-Prop $fix 'script'
if ([string]::IsNullOrWhiteSpace($scriptRel)) { throw 'Fix has no action defined.' }
$scriptPath = Join-Path $Root ('catalog\' + ($scriptRel -replace '/', '\'))
& $scriptPath
