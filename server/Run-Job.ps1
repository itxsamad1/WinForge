<#
.SYNOPSIS
    Executes an install job. Runs elevated, detached from the web server.
.DESCRIPTION
    The server writes plan.json into a job directory and launches this script
    with Start-Process -Verb RunAs, which produces exactly one UAC prompt for
    the whole batch. Every winget child process then inherits admin, so nothing
    prompts again.

    Progress is published by rewriting status.json and appending to per-step log
    files. The server never talks to this process directly, it just reads those
    files, which means the job survives the browser (or the server) going away.
.NOTES
    Runs standalone for debugging:
      powershell -File server\Run-Job.ps1 -JobDir state\jobs\<id>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$JobDir
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'server\Common.ps1')

$planPath = Join-Path $JobDir 'plan.json'
$statusPath = Join-Path $JobDir 'status.json'
$logDir = Join-Path $JobDir 'logs'

if (-not (Test-Path -LiteralPath $planPath)) { throw "No plan.json in $JobDir" }
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$plan = Read-JsonFile -Path $planPath
$steps = ConvertTo-Array (Get-Prop $plan 'steps')
$options = Get-Prop $plan 'options'

$context = @{
    Root     = $root
    StateDir = Join-Path $root 'state'
    Elevated = Test-IsElevated
}

# ---------------------------------------------------------------------------
# Status bookkeeping
# ---------------------------------------------------------------------------

$status = [pscustomobject]@{
    jobId       = Get-Prop $plan 'jobId'
    state       = 'running'
    startedAt   = (Get-Date).ToString('o')
    finishedAt  = $null
    elevated    = $context.Elevated
    rebootNeeded = $false
    steps       = @()
}

$index = 0
foreach ($step in $steps) {
    $status.steps += [pscustomobject]@{
        index    = $index
        key      = Get-Prop $step 'key'
        name     = Get-Prop $step 'name'
        kind     = Get-Prop $step 'kind' 'winget'
        state    = 'pending'
        message  = $null
        exitCode = $null
        phase    = $null
        percent  = $null
        progressDetail = $null
        logFile  = "$index.log"
        startedAt = $null
        finishedAt = $null
    }
    $index++
}

function Save-Status {
    Write-JsonFile -Path $statusPath -Value $status
}

Save-Status

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

$script:CurrentLogPath = $null
$script:CurrentStepEntry = $null
$script:LastProgressSave = [datetime]::MinValue

function Write-StepLog {
    param([string]$Text)
    $clean = Get-CleanConsoleLine -Line $Text

    # Progress frames are noise in the log, but they still feed the UI bar.
    $progress = Get-WingetProgressInfo -Line $clean
    if ($null -ne $progress -and $null -ne $script:CurrentStepEntry) {
        $changed = $false
        if ($null -ne $progress.phase -and $script:CurrentStepEntry.phase -ne $progress.phase) {
            $script:CurrentStepEntry.phase = $progress.phase
            $changed = $true
        }
        if ($null -ne $progress.percent) {
            $previous = 0
            if ($null -ne $script:CurrentStepEntry.percent) { $previous = [int]$script:CurrentStepEntry.percent }
            if ($progress.percent -ge $previous) {
                $script:CurrentStepEntry.percent = $progress.percent
                $changed = $true
            }
        }
        if ($null -ne $progress.detail) {
            $script:CurrentStepEntry.progressDetail = $progress.detail
            $changed = $true
        }
        if ($changed -and ((Get-Date) - $script:LastProgressSave).TotalMilliseconds -ge 400) {
            $script:LastProgressSave = Get-Date
            Save-Status
        }
    }

    if ($null -eq $script:CurrentLogPath) { return }
    if (Test-IsNoiseLine -Line $clean) { return }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $writer = New-Object System.IO.StreamWriter($script:CurrentLogPath, $true, $utf8)
            try { $writer.WriteLine($clean) } finally { $writer.Dispose() }
            return
        } catch {
            # The server may be reading the file; back off briefly.
            Start-Sleep -Milliseconds 30
        }
    }
}

# ---------------------------------------------------------------------------
# winget
# ---------------------------------------------------------------------------

function Get-WingetExitMessage {
    <#
        winget reports its HRESULTs as large negative integers. Surfacing the
        raw number to a user setting up a laptop is useless, so translate the
        ones that actually come up.
    #>
    param([int]$ExitCode)

    switch ($ExitCode) {
        0            { return @{ ok = $true;  reboot = $false; message = 'Installed' } }
        3010         { return @{ ok = $true;  reboot = $true;  message = 'Installed, reboot required' } }
        1641         { return @{ ok = $true;  reboot = $true;  message = 'Installed, the installer requested a restart' } }
        -1978335189  { return @{ ok = $true;  reboot = $false; message = 'Already installed and up to date' } }
        -1978335135  { return @{ ok = $true;  reboot = $false; message = 'Already installed' } }
        -1978335212  { return @{ ok = $false; reboot = $false; message = 'No package matched that id in the winget source' } }
        -1978335215  { return @{ ok = $false; reboot = $false; message = 'No installer available for this machine (architecture or scope mismatch)' } }
        -1978335216  { return @{ ok = $false; reboot = $false; message = 'Installer hash mismatch, the publisher may have republished the package' } }
        -1978334967  { return @{ ok = $false; reboot = $false; message = 'A newer version is already installed' } }
        -1978335231  { return @{ ok = $false; reboot = $false; message = 'Installer failed. See the log above for the vendor error' } }
        -1978335226  { return @{ ok = $false; reboot = $false; message = 'The installer needs administrator rights' } }
        -1978334972  { return @{ ok = $false; reboot = $false; message = 'Another installation is already in progress' } }
        -1978335138  { return @{ ok = $false; reboot = $false; message = 'Download failed. Check the network connection' } }
        # HTTP 403 Forbidden from the vendor CDN (common with EnterpriseDB / PostgreSQL).
        -2145844845  { return @{ ok = $false; reboot = $false; message = 'Download blocked by the publisher (HTTP 403). Try PostgreSQL 17, or install from postgresql.org' } }
        -2146697211  { return @{ ok = $false; reboot = $false; message = 'Download failed (network or TLS error)' } }
    }
    return @{ ok = $false; reboot = $false; message = "winget exited with code $ExitCode" }
}

function Invoke-WingetInstall {
    param($Step)

    $id = Get-Prop $Step 'id'
    $arguments = @(
        'install',
        '--id', $id,
        '--exact',
        '--source', (Get-Prop $Step 'source' 'winget'),
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
        # --nowarn omitted on purpose: it also hides download progress frames.
    )

    $scope = Get-Prop $Step 'scope'
    if (-not [string]::IsNullOrWhiteSpace($scope)) {
        $arguments += @('--scope', $scope)
    }

    $override = Get-Prop $Step 'override'
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $arguments += @('--override', $override)
    }

    Write-StepLog "> winget $($arguments -join ' ')"
    Write-StepLog ''

    # Capture stdout and stderr together and stream each line into the log so
    # the UI shows download progress rather than a frozen spinner.
    & winget @arguments 2>&1 | ForEach-Object { Write-StepLog ([string]$_) }

    return $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Scripted steps
# ---------------------------------------------------------------------------

function Invoke-CatalogScript {
    param(
        [string]$ScriptPath,
        $Options
    )
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Script not found: $ScriptPath"
    }
    & $ScriptPath -Context $context -Options $Options 2>&1 | ForEach-Object { Write-StepLog ([string]$_) }
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

function Invoke-JobSteps {
    $stepIndex = 0
    foreach ($step in $steps) {
        $entry = $status.steps[$stepIndex]
        $script:CurrentLogPath = Join-Path $logDir $entry.logFile
        $script:CurrentStepEntry = $entry

        $entry.state = 'running'
        $entry.phase = 'starting'
        $entry.percent = 0
        $entry.progressDetail = $null
        $entry.startedAt = (Get-Date).ToString('o')
        Save-Status

        # Pick up PATH and env changes made by the previous step. Without this,
        # "corepack enable" straight after installing Node cannot find node.exe.
        Update-PathFromRegistry

        $kind = Get-Prop $step 'kind' 'winget'
        $failed = $false

        try {
            switch ($kind) {
                'winget' {
                    $exitCode = Invoke-WingetInstall -Step $step
                    $entry.exitCode = $exitCode
                    $verdict = Get-WingetExitMessage -ExitCode $exitCode
                    $entry.message = $verdict.message
                    if ($verdict.reboot) { $status.rebootNeeded = $true }
                    if (-not $verdict.ok) { $failed = $true }
                }
                'script' {
                    $command = Get-Prop $step 'command'
                    $scriptPath = Join-Path $root "catalog\scripts\$command.ps1"
                    Invoke-CatalogScript -ScriptPath $scriptPath -Options $options
                    $entry.message = 'Completed'
                    $entry.exitCode = 0
                }
                'manual' {
                    Write-StepLog (Get-Prop $step 'instructions' 'This app must be installed by hand.')
                    $url = Get-Prop $step 'url'
                    if (-not [string]::IsNullOrWhiteSpace($url)) {
                        Write-StepLog ''
                        Write-StepLog "Download page: $url"
                    }
                    $entry.message = 'Needs a manual step'
                    $entry.state = 'manual'
                }
                default {
                    throw "Unsupported step kind '$kind'"
                }
            }
        } catch {
            $failed = $true
            $entry.message = $_.Exception.Message
            Write-StepLog "ERROR: $($_.Exception.Message)"
        }

        if (Get-Prop $step 'reboot' $false) { $status.rebootNeeded = $true }

        # Post-install steps only run when the package itself landed;
        # configuring JAVA_HOME after a failed JDK install would just produce
        # a broken path.
        if (-not $failed -and $entry.state -ne 'manual') {
            foreach ($postStep in (ConvertTo-Array (Get-Prop $step 'postInstall'))) {
                Update-PathFromRegistry
                Write-StepLog ''
                Write-StepLog "--- post-install: $postStep ---"
                try {
                    $postPath = Join-Path $root "catalog\postinstall\$postStep.ps1"
                    Invoke-CatalogScript -ScriptPath $postPath -Options $options
                } catch {
                    # A failed env tweak should not mark a working install as broken.
                    Write-StepLog "WARNING: post-install step '$postStep' failed: $($_.Exception.Message)"
                    if ([string]::IsNullOrWhiteSpace($entry.message)) { $entry.message = 'Installed' }
                    $entry.message = "$($entry.message) (post-install step '$postStep' failed)"
                }
            }
        }

        if ($entry.state -ne 'manual') {
            if ($failed) {
                $entry.state = 'failed'
                $entry.percent = $null
            } else {
                $entry.state = 'done'
                $entry.phase = 'done'
                $entry.percent = 100
            }
        }
        $entry.finishedAt = (Get-Date).ToString('o')
        $script:CurrentStepEntry = $null
        Save-Status

        $stepIndex++
    }
}

try {
    Invoke-JobSteps
} finally {
    # Always publish a terminal state. If this script dies unexpectedly the UI
    # would otherwise poll a job stuck at "running" forever.
    $script:CurrentLogPath = $null
    if ($status.state -eq 'running') { $status.state = 'finished' }
    $status.finishedAt = (Get-Date).ToString('o')
    foreach ($entry in $status.steps) {
        if ($entry.state -eq 'running' -or $entry.state -eq 'pending') {
            $entry.state = 'failed'
            if ([string]::IsNullOrWhiteSpace($entry.message)) {
                $entry.message = 'The installer stopped before this step completed.'
            }
        }
    }
    Save-Status

    # The cached winget package list is stale the moment anything installs.
    Remove-Item -LiteralPath (Join-Path $context.StateDir 'installed.json') -Force -ErrorAction SilentlyContinue
}
