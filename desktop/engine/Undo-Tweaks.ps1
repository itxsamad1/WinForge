[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Keys,
    [Parameter(Mandatory = $true)] [string]$Root
)

$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'server\Common.ps1')

$tweaksPath = Join-Path $Root 'catalog\tweaks.json'
$doc = Read-JsonFile -Path $tweaksPath
$all = @{}
foreach ($t in (ConvertTo-Array (Get-Prop $doc 'tweaks'))) {
    $all[(Get-Prop $t 'key')] = $t
}

foreach ($key in ($Keys -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    if (-not $all.ContainsKey($key)) { continue }
    $scriptRel = Get-Prop $all[$key] 'undoScript'
    if ([string]::IsNullOrWhiteSpace($scriptRel)) { continue }
    $scriptPath = Join-Path $Root ('catalog\' + ($scriptRel -replace '/', '\'))
    if (-not (Test-Path -LiteralPath $scriptPath)) { continue }
    & $scriptPath
}

Write-Host 'Tweaks reverted.' -ForegroundColor Green
