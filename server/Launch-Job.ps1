<#
.SYNOPSIS
    Starts Run-Job.ps1, elevating if needed, without blocking the web server.
.DESCRIPTION
    The HTTP handler must return immediately. Start-Process -Verb RunAs waits on
    the UAC dialog on the calling thread, which froze the UI on "Waiting for
    administrator approval..." and often hid the prompt behind the browser.

    This launcher is itself started with a normal (non-RunAs) Start-Process, so
    the server stays responsive. The UAC wait, if any, happens only here.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$JobDir
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'server\Common.ps1')

$statusPath = Join-Path $JobDir 'status.json'
$runner = Join-Path $root 'server\Run-Job.ps1'

function Set-JobFailed {
    param([string]$Message)
    $status = Read-JsonFile -Path $statusPath
    if ($null -eq $status) { return }
    $status.state = 'failed'
    $status.finishedAt = (Get-Date).ToString('o')
    $status | Add-Member -NotePropertyName 'launchError' -NotePropertyValue $Message -Force
    foreach ($step in (ConvertTo-Array (Get-Prop $status 'steps'))) {
        if ((Get-Prop $step 'state') -eq 'pending') {
            $step.state = 'failed'
            $step.message = $Message
        }
    }
    Write-JsonFile -Path $statusPath -Value $status
}

$arguments = @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', "`"$runner`"",
    '-JobDir', "`"$JobDir`""
)

try {
    if (Test-IsElevated) {
        # Already admin (user opened WinForge as Administrator). No prompt.
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    } else {
        # Blocks THIS process only until the user accepts or declines UAC.
        # The web server is not waiting on us.
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments `
            -Verb RunAs -WindowStyle Hidden | Out-Null
    }
} catch {
    Set-JobFailed -Message 'Administrator approval was declined or the installer could not start. Click Install again and accept the Windows security prompt (it may appear behind the browser).'
}
