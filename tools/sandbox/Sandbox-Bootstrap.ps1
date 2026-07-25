<#
.SYNOPSIS
    Prepares Windows Sandbox and runs the WinForge test suite inside it.
.DESCRIPTION
    Windows Sandbox boots a clean, disposable Windows with no winget, which is
    exactly the "fresh install" situation WinForge is built for. This script:

      1. copies the read-only mapped project to a writable location,
      2. installs App Installer (winget) and its dependencies,
      3. runs the full smoke test including a real package install,
      4. leaves WinForge running so the UI can be tried by hand.

    Everything here happens inside the sandbox. Closing the sandbox window
    destroys the whole machine, so nothing can reach the host.
#>
[CmdletBinding()]
param(
    [string]$Source = 'C:\WinForgeSource',
    [string]$Target = 'C:\WinForge'
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

$host.UI.RawUI.WindowTitle = 'WinForge sandbox test'

Write-Host ''
Write-Host '  WinForge - sandbox test run' -ForegroundColor White
Write-Host '  This is a disposable VM. Nothing here touches the host machine.' -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
Write-Step 'Copying the project to a writable location'
# ---------------------------------------------------------------------------

if (-not (Test-Path $Source)) {
    Write-Host "  Mapped folder $Source not found. Was the sandbox started from tools\sandbox\Test-In-Sandbox.cmd?" -ForegroundColor Red
    Read-Host '  Press Enter to close'
    exit 1
}

if (Test-Path $Target) { Remove-Item -Recurse -Force $Target -ErrorAction SilentlyContinue }
Copy-Item -Path $Source -Destination $Target -Recurse -Force
# state/ is host runtime leftovers; the sandbox needs its own.
Remove-Item -Recurse -Force (Join-Path $Target 'state') -ErrorAction SilentlyContinue
Write-Host "  Copied to $Target"

# ---------------------------------------------------------------------------
Write-Step 'Installing winget (App Installer)'
# ---------------------------------------------------------------------------

if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host '  winget is already present.'
} else {
    $downloads = 'C:\wingetsetup'
    New-Item -ItemType Directory -Path $downloads -Force | Out-Null

    # App Installer needs both of these before it will register.
    $packages = @(
        @{ Name = 'VCLibs';  Url = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'; File = 'VCLibs.appx' },
        @{ Name = 'UI.Xaml'; Url = 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx'; File = 'UIXaml.appx' },
        @{ Name = 'winget';  Url = 'https://aka.ms/getwinget'; File = 'winget.msixbundle' }
    )

    foreach ($package in $packages) {
        $path = Join-Path $downloads $package.File
        Write-Host "  Downloading $($package.Name)..."
        try {
            Invoke-WebRequest -Uri $package.Url -OutFile $path -UseBasicParsing
        } catch {
            Write-Host "  Download failed for $($package.Name): $($_.Exception.Message)" -ForegroundColor Red
            continue
        }
        Write-Host "  Installing $($package.Name)..."
        try {
            Add-AppxPackage -Path $path -ErrorAction Stop
        } catch {
            # The bundle often reports a benign "already installed" style error
            # for the dependencies; only the final winget check matters.
            Write-Host "  ($($package.Name): $($_.Exception.Message))" -ForegroundColor DarkYellow
        }
    }

    # PATH does not pick up the new WindowsApps alias until it is re-read.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')

    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        if (Get-Command winget -ErrorAction SilentlyContinue) { break }
        Start-Sleep -Seconds 2
    }
}

$winget = Get-Command winget -ErrorAction SilentlyContinue
if ($null -eq $winget) {
    Write-Host ''
    Write-Host '  winget could not be installed in this sandbox.' -ForegroundColor Red
    Write-Host '  The UI will still load, but no package can be installed.' -ForegroundColor Red
} else {
    Write-Host "  winget ready: $(& winget --version)" -ForegroundColor Green
    & winget source update --disable-interactivity 2>&1 | Out-Null
}

# ---------------------------------------------------------------------------
Write-Step 'Running the full test suite (with a real package install)'
# ---------------------------------------------------------------------------

Push-Location $Target
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Target 'tools\Smoke-Test.ps1') -RunInstall
    $testExitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

Write-Host ''
if ($testExitCode -eq 0) {
    Write-Host '  ALL TESTS PASSED' -ForegroundColor Green
} else {
    Write-Host '  SOME TESTS FAILED - scroll up for the details' -ForegroundColor Red
}

# ---------------------------------------------------------------------------
Write-Step 'Starting WinForge so you can try the interface'
# ---------------------------------------------------------------------------

Write-Host '  A browser will open. Pick some apps and press Install to watch it work.'
Write-Host '  Close the sandbox window when you are done; everything disappears with it.'
Write-Host ''

Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', "`"$(Join-Path $Target 'start.ps1')`""
) -WorkingDirectory $Target
