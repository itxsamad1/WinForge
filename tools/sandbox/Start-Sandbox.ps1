<#
.SYNOPSIS
    Launches WinForge inside Windows Sandbox for safe testing.
.DESCRIPTION
    Generates a .wsb configuration pointing at wherever this project lives and
    hands it to Windows Sandbox. The project is mapped read-only, so the test
    run physically cannot modify the host copy.

    Windows Sandbox is disposable: closing its window destroys the entire
    machine, including anything the test installed.
#>
[CmdletBinding()]
param(
    [int]$MemoryMB = 8192
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))

$sandboxExe = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'
if (-not (Test-Path $sandboxExe)) {
    Write-Host ''
    Write-Host '  Windows Sandbox is not enabled on this machine.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  It needs Windows 10/11 Pro, Enterprise or Education. To turn it on,' -ForegroundColor Yellow
    Write-Host '  run this in an ADMIN PowerShell and reboot:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '    Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All' -ForegroundColor White
    Write-Host ''
    exit 1
}

$stateDir = Join-Path $root 'state'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$configPath = Join-Path $stateDir 'WinForge-Sandbox.wsb'

# The bootstrap runs from the read-only mapped copy and immediately clones the
# project somewhere writable inside the sandbox.
$configuration = @"
<Configuration>
  <VGpu>Disable</VGpu>
  <Networking>Enable</Networking>
  <MemoryInMB>$MemoryMB</MemoryInMB>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$root</HostFolder>
      <SandboxFolder>C:\WinForgeSource</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File C:\WinForgeSource\tools\sandbox\Sandbox-Bootstrap.ps1</Command>
  </LogonCommand>
</Configuration>
"@

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($configPath, $configuration, $utf8)

Write-Host ''
Write-Host '  Starting Windows Sandbox' -ForegroundColor Cyan
Write-Host "  Project mapped read-only from $root" -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Inside the sandbox it will:' -ForegroundColor White
Write-Host '    1. install winget (a clean Windows does not have it)'
Write-Host '    2. run the full test suite, including a real package install'
Write-Host '    3. open WinForge so you can click around'
Write-Host ''
Write-Host '  First boot takes a minute or two. Close the sandbox window to' -ForegroundColor DarkGray
Write-Host '  destroy everything it did.' -ForegroundColor DarkGray
Write-Host ''

Start-Process -FilePath $sandboxExe -ArgumentList "`"$configPath`""
