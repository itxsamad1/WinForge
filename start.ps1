<#
.SYNOPSIS
    WinForge launcher. Picks a free port, mints a session token, starts the
    local web server and opens the browser.
.NOTES
    Targets Windows PowerShell 5.1 (the version guaranteed on a fresh Windows
    install). Avoid PS7-only syntax anywhere in this project.
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$NoBrowser
)

# StrictMode is deliberately off: catalog entries are PSCustomObjects from
# ConvertFrom-Json with many optional fields, and strict mode turns every
# absent field into a terminating error.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path

. (Join-Path $root 'server\Common.ps1')
. (Join-Path $root 'server\Catalog.ps1')
. (Join-Path $root 'server\Iso.ps1')
. (Join-Path $root 'server\Detect.ps1')
. (Join-Path $root 'server\Jobs.ps1')
. (Join-Path $root 'server\Api.ps1')
. (Join-Path $root 'server\Server.ps1')

function Get-FreePort {
    param([int[]]$Candidates)
    foreach ($candidate in $Candidates) {
        $listener = New-Object System.Net.HttpListener
        foreach ($prefix in (Get-ServerPrefixes -Port $candidate)) {
            $listener.Prefixes.Add($prefix)
        }
        try {
            $listener.Start()
            $listener.Stop()
            return $candidate
        } catch {
            # Port busy or reserved; try the next one.
        } finally {
            $listener.Close()
        }
    }
    throw "Could not find a free port in the range $($Candidates[0])-$($Candidates[-1])."
}

if ($Port -eq 0) {
    $Port = Get-FreePort -Candidates (47113..47143)
}

$token = New-SessionToken
$stateDir = Join-Path $root 'state'
if (-not (Test-Path $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

$script:WinForge = @{
    Root       = $root
    WebRoot    = Join-Path $root 'web'
    CatalogDir = Join-Path $root 'catalog'
    StateDir   = $stateDir
    JobsDir    = Join-Path $stateDir 'jobs'
    Token      = $token
    Port       = $Port
    Elevated   = Test-IsElevated
}

$url = "http://localhost:$Port/?token=$token"

# Publish the session so tools\Smoke-Test.ps1 can drive the API. The token
# guards against other web pages reaching this server, not against code already
# running as this user, so a file next to the app is no weaker than the URL that
# is about to be handed to the browser.
$sessionPath = Join-Path $stateDir 'session.json'
Write-JsonFile -Path $sessionPath -Value ([pscustomobject]@{
    token     = $token
    port      = $Port
    pid       = $PID
    startedAt = (Get-Date).ToString('o')
})

Write-Host ''
Write-Host '  WinForge' -ForegroundColor Cyan
Write-Host '  One-click Windows dev setup' -ForegroundColor DarkGray
Write-Host ''
Write-Host "  URL   $url" -ForegroundColor Green
if ($script:WinForge.Elevated) {
    Write-Host '  Mode  Administrator (no UAC prompts during install)' -ForegroundColor DarkGray
} else {
    Write-Host '  Mode  Normal user (one UAC prompt per install batch)' -ForegroundColor DarkGray
}
Write-Host '  Stop  Ctrl+C in this window' -ForegroundColor DarkGray
Write-Host ''

if (-not (Get-Command 'winget' -ErrorAction SilentlyContinue)) {
    Write-Host '  Warning: winget was not found on PATH. Install "App Installer"' -ForegroundColor Yellow
    Write-Host '  from the Microsoft Store, then restart WinForge.' -ForegroundColor Yellow
    Write-Host ''
}

if (-not $NoBrowser) {
    Start-Process $url | Out-Null
}

try {
    Start-WinForgeServer -Context $script:WinForge
} finally {
    Remove-Item -LiteralPath $sessionPath -Force -ErrorAction SilentlyContinue
}
