#Requires -Version 5.1
<#
.SYNOPSIS
  Check deps, build WinForge desktop if needed, and launch WinForge.exe on Windows.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File desktop\build\Run-On-Windows.ps1 -SingleFile
#>
[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$SingleFile
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

if ($env:OS -ne 'Windows_NT') {
    throw "This script must run on a Windows PC (found OS='$env:OS')."
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$desktopRoot = Join-Path $repoRoot 'desktop'
$distExe = Join-Path $desktopRoot 'dist\WinForge.exe'

Write-Host "WinForge desktop launcher" -ForegroundColor Green
Write-Host "Repo: $repoRoot"

Write-Step "Checking winget"
$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Host "winget not found. Install 'App Installer' from the Microsoft Store, then re-run." -ForegroundColor Yellow
} else {
    Write-Host ("winget OK: " + $winget.Source)
}

Write-Step "Checking .NET SDK 8"
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
$hasSdk8 = $false
if ($dotnet) {
    $sdks = & dotnet --list-sdks 2>$null
    if ($sdks -match '^8\.') { $hasSdk8 = $true }
    Write-Host ($sdks -join "`n")
}

if (-not $hasSdk8) {
    Write-Step "Installing .NET 8 SDK via winget"
    if (-not $winget) {
        throw "Need either .NET 8 SDK or winget. Install Visual Studio 2022 (Desktop workload) or .NET 8 SDK, then re-run."
    }
    winget install --id Microsoft.DotNet.SDK.8 -e --accept-source-agreements --accept-package-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        throw ".NET SDK install finished but 'dotnet' is still not on PATH. Open a NEW PowerShell window and re-run."
    }
}

if (-not $SkipBuild -or -not (Test-Path $distExe)) {
    Write-Step "Publishing WinForge.exe"
    $publish = Join-Path $desktopRoot 'build\Publish.ps1'
    if (-not (Test-Path $publish)) { throw "Missing $publish" }
    if ($SingleFile) {
        & $publish -SingleFile
    } else {
        & $publish
    }
    if (-not $?) { throw "Publish.ps1 failed." }
}

if (-not (Test-Path $distExe)) {
    throw "Build finished but $distExe was not found."
}

Write-Step "Launching WinForge"
Write-Host $distExe -ForegroundColor Green
Start-Process -FilePath $distExe
Write-Host "Launched. If UAC appears during Install, accept it." -ForegroundColor Green
