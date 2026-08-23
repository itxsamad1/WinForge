[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$JobDir,
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

. (Join-Path $Root 'server\Common.ps1')

$statusPath = Join-Path $JobDir 'status.json'
$runner = Join-Path $Root 'server\Run-Job.ps1'

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
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    } else {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments `
            -Verb RunAs -WindowStyle Hidden | Out-Null
    }
} catch {
    Set-JobFailed -Message 'Administrator approval was declined. Click Install again and accept the UAC prompt (it may appear behind this window).'
}
