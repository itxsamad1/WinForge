[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Root,
    [Parameter(Mandatory = $true)] [string]$OutPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'server\Common.ps1')
. (Join-Path $Root 'server\Catalog.ps1')
. (Join-Path $Root 'server\Detect.ps1')

$context = @{
    Root       = $Root
    CatalogDir = Join-Path $Root 'catalog'
    StateDir   = Join-Path $env:LOCALAPPDATA 'WinForge\state'
}

Initialize-Catalog -Context $context
$state = Get-InstalledState -Context $context

$result = @{}
foreach ($app in (Get-CatalogApps)) {
    $key = Get-Prop $app 'key'
    if ([string]::IsNullOrWhiteSpace($key)) { continue }
    $entry = $state[$key]
    if ($null -ne $entry -and [bool](Get-Prop $entry 'installed')) {
        $result[$key] = $true
    }
}

$dir = Split-Path -Parent $OutPath
if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

Write-JsonFile -Path $OutPath -Value $result
