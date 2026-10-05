<#
    Creates install jobs and reads back their state.

    A job is a directory under state/jobs/<id> containing plan.json (written by
    the server), status.json and logs/<n>.log (written by the elevated runner).
    Nothing is shared in memory, so the runner and the server stay completely
    decoupled.
#>

function New-InstallJob {
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Context,
        [Parameter(Mandatory = $true)] $Plan,
        $Options
    )

    $jobId = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('n').Substring(0, 6))
    $jobDir = Join-Path $Context.JobsDir $jobId
    New-Item -ItemType Directory -Path (Join-Path $jobDir 'logs') -Force | Out-Null

    $planDocument = [pscustomobject]@{
        jobId     = $jobId
        createdAt = (Get-Date).ToString('o')
        options   = $Options
        steps     = $Plan.steps
    }
    Write-JsonFile -Path (Join-Path $jobDir 'plan.json') -Value $planDocument

    # Seed status.json so the UI has something to render during the seconds
    # between the POST returning and the elevated process starting up.
    $seedSteps = @()
    $index = 0
    foreach ($step in $Plan.steps) {
        $seedSteps += [pscustomobject]@{
            index      = $index
            key        = $step.key
            name       = $step.name
            kind       = $step.kind
            state      = 'pending'
            message    = $null
            exitCode   = $null
            phase      = $null
            percent    = $null
            progressDetail = $null
            logFile    = "$index.log"
            startedAt  = $null
            finishedAt = $null
        }
        $index++
    }

    $needsElevation = -not [bool]$Context.Elevated
    Write-JsonFile -Path (Join-Path $jobDir 'status.json') -Value ([pscustomobject]@{
        jobId        = $jobId
        state        = $(if ($needsElevation) { 'awaiting_elevation' } else { 'starting' })
        startedAt    = $null
        finishedAt   = $null
        elevated     = [bool]$Context.Elevated
        rebootNeeded = $false
        steps        = $seedSteps
    })

    # Launch via a helper that is itself started WITHOUT -Verb RunAs. That keeps
    # this function non-blocking: the HTTP response returns immediately, the UI
    # can poll, and any UAC prompt waits only inside Launch-Job.ps1.
    $launcher = Join-Path $Context.Root 'server\Launch-Job.ps1'
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$launcher`"",
        '-JobDir', "`"$jobDir`""
    )

    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
        return [pscustomobject]@{
            jobId            = $jobId
            started          = $true
            needsElevation   = $needsElevation
            error            = $null
        }
    } catch {
        $failedStatus = Read-JsonFile -Path (Join-Path $jobDir 'status.json')
        if ($null -ne $failedStatus) {
            $failedStatus.state = 'failed'
            $failedStatus.finishedAt = (Get-Date).ToString('o')
            Write-JsonFile -Path (Join-Path $jobDir 'status.json') -Value $failedStatus
        }
        return [pscustomobject]@{
            jobId            = $jobId
            started          = $false
            needsElevation   = $needsElevation
            error            = $_.Exception.Message
        }
    }
}

function Get-JobLogLines {
    param(
        [Parameter(Mandatory = $true)] [string]$JobDir,
        [Parameter(Mandatory = $true)] [int]$StepIndex,
        [int]$Since = 0
    )

    $logPath = Join-Path $JobDir "logs\$StepIndex.log"
    if (-not (Test-Path -LiteralPath $logPath)) {
        return [pscustomobject]@{ from = $Since; total = 0; lines = @() }
    }

    $lines = @()
    try {
        # Shared read: the runner has the file open for append.
        $stream = New-Object System.IO.FileStream($logPath, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            try {
                while (-not $reader.EndOfStream) { $lines += $reader.ReadLine() }
            } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
    } catch {
        return [pscustomobject]@{ from = $Since; total = 0; lines = @() }
    }

    $total = $lines.Count
    if ($Since -lt 0) { $Since = 0 }
    if ($Since -ge $total) {
        return [pscustomobject]@{ from = $total; total = $total; lines = @() }
    }

    return [pscustomobject]@{
        from  = $Since
        total = $total
        lines = @($lines[$Since..($total - 1)])
    }
}

function Test-InstallProcessAlive {
    param($PidValue)
    if ($null -eq $PidValue) { return $false }
    try {
        $proc = Get-Process -Id ([int]$PidValue) -ErrorAction Stop
        return ($null -ne $proc -and -not $proc.HasExited)
    } catch {
        return $false
    }
}

function Test-IsTerminalJobState {
    param([string]$State)
    return $State -in @('finished', 'failed', 'cancelled')
}

function Stop-ProcessTree {
    param([Parameter(Mandatory = $true)] [int]$ProcessId)
    try {
        & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
    } catch {
        try { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Write-CancelledJobStatus {
    param(
        [Parameter(Mandatory = $true)] [string]$JobDir,
        [string]$Message = 'Cancelled by user.'
    )

    $statusPath = Join-Path $JobDir 'status.json'
    $status = Read-JsonFile -Path $statusPath
    if ($null -eq $status) { return $null }

    $state = Get-Prop $status 'state' 'unknown'
    if (Test-IsTerminalJobState -State $state) { return $status }

    $status.state = 'cancelled'
    Set-ObjectProp -Object $status -Name 'finishedAt' -Value ((Get-Date).ToString('o'))
    Set-ObjectProp -Object $status -Name 'cancelMessage' -Value $Message
    foreach ($entry in @(ConvertTo-Array (Get-Prop $status 'steps'))) {
        $stepState = Get-Prop $entry 'state' 'pending'
        if ($stepState -in @('pending', 'running', 'starting')) {
            Set-ObjectProp -Object $entry -Name 'state' -Value 'cancelled'
            if ([string]::IsNullOrWhiteSpace((Get-Prop $entry 'message'))) {
                Set-ObjectProp -Object $entry -Name 'message' -Value $Message
            }
            Set-ObjectProp -Object $entry -Name 'finishedAt' -Value ((Get-Date).ToString('o'))
            Set-ObjectProp -Object $entry -Name 'percent' -Value $null
        }
    }
    Write-JsonFile -Path $statusPath -Value $status
    return $status
}

function Write-StaleJobStatus {
    param(
        [Parameter(Mandatory = $true)] [string]$JobDir,
        [string]$Message = 'Installer process is no longer running.'
    )

    $statusPath = Join-Path $JobDir 'status.json'
    $status = Read-JsonFile -Path $statusPath
    if ($null -eq $status) { return $null }

    $state = Get-Prop $status 'state' 'unknown'
    if (Test-IsTerminalJobState -State $state) { return $status }

    $status.state = 'failed'
    Set-ObjectProp -Object $status -Name 'finishedAt' -Value ((Get-Date).ToString('o'))
    Set-ObjectProp -Object $status -Name 'stale' -Value $true
    Set-ObjectProp -Object $status -Name 'launchError' -Value $Message
    foreach ($entry in @(ConvertTo-Array (Get-Prop $status 'steps'))) {
        $stepState = Get-Prop $entry 'state' 'pending'
        if ($stepState -in @('pending', 'running', 'starting')) {
            Set-ObjectProp -Object $entry -Name 'state' -Value 'failed'
            if ([string]::IsNullOrWhiteSpace((Get-Prop $entry 'message'))) {
                Set-ObjectProp -Object $entry -Name 'message' -Value $Message
            }
            Set-ObjectProp -Object $entry -Name 'finishedAt' -Value ((Get-Date).ToString('o'))
            Set-ObjectProp -Object $entry -Name 'percent' -Value $null
        }
    }
    Write-JsonFile -Path $statusPath -Value $status
    return $status
}

function Request-JobCancel {
    <#
        Soft-cancel: drop a flag the runner checks between steps, then kill the
        process tree so a stuck winget does not keep the UI "installing".
    #>
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Context,
        [Parameter(Mandatory = $true)] [string]$JobId
    )

    if ($JobId -notmatch '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$') {
        return [pscustomobject]@{ ok = $false; error = 'Invalid job id.' }
    }

    $jobDir = Join-Path $Context.JobsDir $JobId
    if (-not (Test-Path -LiteralPath $jobDir -PathType Container)) {
        return [pscustomobject]@{ ok = $false; error = 'Unknown job.' }
    }

    $cancelFlag = Join-Path $jobDir 'cancel.flag'
    Set-Content -LiteralPath $cancelFlag -Value ((Get-Date).ToString('o')) -Encoding ASCII -Force

    $status = Read-JsonFile -Path (Join-Path $jobDir 'status.json')
    if ($null -eq $status) {
        return [pscustomobject]@{ ok = $false; error = 'Missing status.' }
    }

    $state = Get-Prop $status 'state' 'unknown'
    if (Test-IsTerminalJobState -State $state) {
        return [pscustomobject]@{ ok = $true; alreadyDone = $true; state = $state; jobId = $JobId }
    }

    $pidValue = Get-Prop $status 'pid'
    if ($null -ne $pidValue -and (Test-InstallProcessAlive -PidValue $pidValue)) {
        Stop-ProcessTree -ProcessId ([int]$pidValue)
        Start-Sleep -Milliseconds 250
    }

    # Also kill orphaned Launch-Job / powershell children that may still linger
    # before the elevated runner wrote its pid.
    $status = Write-CancelledJobStatus -JobDir $jobDir -Message 'Cancelled by user.'
    return [pscustomobject]@{
        ok     = $true
        jobId  = $JobId
        state  = if ($null -ne $status) { Get-Prop $status 'state' 'cancelled' } else { 'cancelled' }
    }
}

function Request-CancelAllJobs {
    param([Parameter(Mandatory = $true)] [hashtable]$Context)

    $cancelled = @()
    $jobsDir = $Context.JobsDir
    if ([string]::IsNullOrWhiteSpace($jobsDir) -or -not (Test-Path -LiteralPath $jobsDir)) {
        return [pscustomobject]@{ ok = $true; cancelled = @(); count = 0 }
    }

    $dirs = Get-ChildItem -LiteralPath $jobsDir -Directory -ErrorAction SilentlyContinue
    foreach ($dir in $dirs) {
        if ($dir.Name -notmatch '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$') { continue }
        $status = Read-JsonFile -Path (Join-Path $dir.FullName 'status.json')
        if ($null -eq $status) { continue }
        $state = Get-Prop $status 'state' 'unknown'
        if (Test-IsTerminalJobState -State $state) { continue }
        $result = Request-JobCancel -Context $Context -JobId $dir.Name
        if ($result.ok -and -not $result.alreadyDone) {
            $cancelled += $dir.Name
        }
    }

    return [pscustomobject]@{
        ok        = $true
        cancelled = @($cancelled)
        count     = @($cancelled).Count
    }
}

function Reconcile-InstallJob {
    param(
        [Parameter(Mandatory = $true)] [string]$JobDir,
        $Status = $null
    )

    $statusPath = Join-Path $JobDir 'status.json'
    if ($null -eq $Status) {
        $Status = Read-JsonFile -Path $statusPath
    }
    if ($null -eq $Status) { return $null }

    $state = Get-Prop $Status 'state' 'unknown'
    if (Test-IsTerminalJobState -State $state) { return $Status }

    $cancelFlag = Join-Path $JobDir 'cancel.flag'
    if (Test-Path -LiteralPath $cancelFlag) {
        return Write-CancelledJobStatus -JobDir $JobDir -Message 'Cancelled by user.'
    }

    $pidValue = Get-Prop $Status 'pid'
    $alive = Test-InstallProcessAlive -PidValue $pidValue

    if ($alive) { return $Status }

    # No live runner. awaiting_elevation / starting can be briefly pid-less while
    # Launch-Job is still prompting UAC — only mark stale after a grace window,
    # or immediately when a pid was recorded and has since died.
    $statusFile = Get-Item -LiteralPath $statusPath -ErrorAction SilentlyContinue
    $ageMinutes = if ($null -ne $statusFile) {
        ((Get-Date) - $statusFile.LastWriteTime).TotalMinutes
    } else { 999 }

    if ($null -ne $pidValue) {
        return Write-StaleJobStatus -JobDir $JobDir `
            -Message 'Installer process is no longer running.'
    }

    if ($state -in @('awaiting_elevation', 'starting') -and $ageMinutes -lt 3) {
        return $Status
    }

    if ($ageMinutes -ge 2) {
        $msg = if ($state -eq 'awaiting_elevation') {
            'UAC prompt was not accepted, or the installer never started.'
        } else {
            'Installer process is no longer running.'
        }
        return Write-StaleJobStatus -JobDir $JobDir -Message $msg
    }

    return $Status
}

function Reconcile-AllInstallJobs {
    param([Parameter(Mandatory = $true)] [hashtable]$Context)

    $jobsDir = $Context.JobsDir
    if ([string]::IsNullOrWhiteSpace($jobsDir)) {
        $jobsDir = Join-Path $Context.StateDir 'jobs'
    }
    if ([string]::IsNullOrWhiteSpace($jobsDir) -or -not (Test-Path -LiteralPath $jobsDir)) {
        return 0
    }

    $fixed = 0
    $dirs = Get-ChildItem -LiteralPath $jobsDir -Directory -ErrorAction SilentlyContinue
    foreach ($dir in $dirs) {
        if ($dir.Name -notmatch '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$') { continue }
        $before = Read-JsonFile -Path (Join-Path $dir.FullName 'status.json')
        if ($null -eq $before) { continue }
        $beforeState = Get-Prop $before 'state' 'unknown'
        if (Test-IsTerminalJobState -State $beforeState) { continue }
        $after = Reconcile-InstallJob -JobDir $dir.FullName -Status $before
        if ($null -ne $after -and (Get-Prop $after 'state') -ne $beforeState) {
            $fixed++
        }
    }
    return $fixed
}

function Get-JobState {
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Context,
        [Parameter(Mandatory = $true)] [string]$JobId,
        [int[]]$TailSteps = @(),
        [int[]]$SinceOffsets = @()
    )

    # The id goes into a filesystem path, so constrain it to what this server
    # generates rather than trusting the caller.
    if ($JobId -notmatch '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$') { return $null }

    $jobDir = Join-Path $Context.JobsDir $JobId
    if (-not (Test-Path -LiteralPath $jobDir -PathType Container)) { return $null }

    $status = Reconcile-InstallJob -JobDir $jobDir
    if ($null -eq $status) { return $null }

    $logs = @{}
    for ($i = 0; $i -lt $TailSteps.Count; $i++) {
        $stepIndex = $TailSteps[$i]
        $since = 0
        if ($i -lt $SinceOffsets.Count) { $since = $SinceOffsets[$i] }
        $logs["$stepIndex"] = Get-JobLogLines -JobDir $jobDir -StepIndex $stepIndex -Since $since
    }

    return [pscustomobject]@{
        status = $status
        logs   = $logs
    }
}

function Get-ActivitySnapshot {
    <#
        Recent install + ISO jobs for the top-bar Activity panel.
    #>
    param([Parameter(Mandatory = $true)] [hashtable]$Context)

    $installs = @()
    $jobsDir = $Context.JobsDir
    if ([string]::IsNullOrWhiteSpace($jobsDir)) {
        $jobsDir = Join-Path $Context.StateDir 'jobs'
    }
    if (-not [string]::IsNullOrWhiteSpace($jobsDir) -and (Test-Path -LiteralPath $jobsDir)) {
        $dirs = Get-ChildItem -LiteralPath $jobsDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 12
        foreach ($dir in $dirs) {
            if ($dir.Name -notmatch '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$') { continue }
            $status = Reconcile-InstallJob -JobDir $dir.FullName
            if ($null -eq $status) { continue }
            $steps = @(ConvertTo-Array (Get-Prop $status 'steps'))
            $running = $steps | Where-Object { (Get-Prop $_ 'state') -eq 'running' } | Select-Object -First 1
            $done = @($steps | Where-Object { (Get-Prop $_ 'state') -in @('done', 'manual') }).Count
            $failed = @($steps | Where-Object { (Get-Prop $_ 'state') -in @('failed', 'cancelled') }).Count
            $label = if ($null -ne $running) {
                Get-Prop $running 'name' 'Installing'
            } elseif ($steps.Count -gt 0) {
                "Install ($($steps.Count) apps)"
            } else {
                'Install job'
            }
            $pct = $null
            if ($null -ne $running -and $null -ne (Get-Prop $running 'percent')) {
                $pct = [int](Get-Prop $running 'percent')
            } elseif ($steps.Count -gt 0) {
                $pct = [int][math]::Round(100.0 * ($done + $failed) / $steps.Count)
            }
            $jobState = Get-Prop $status 'state' 'unknown'
            $installs += [pscustomobject]@{
                kind      = 'install'
                jobId     = Get-Prop $status 'jobId' $dir.Name
                state     = $jobState
                name      = $label
                detail    = if ($null -ne $running) { Get-Prop $running 'phase' } else { $null }
                percent   = $pct
                message   = if ($null -ne $running) { Get-Prop $running 'message' } else { Get-Prop $status 'cancelMessage' }
                canCancel = -not (Test-IsTerminalJobState -State $jobState)
            }
        }
    }

    $isos = @()
    $isoRoot = Join-Path $Context.StateDir 'iso-jobs'
    if (Test-Path -LiteralPath $isoRoot) {
        $isoDirs = Get-ChildItem -LiteralPath $isoRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 12
        foreach ($dir in $isoDirs) {
            if ($dir.Name -notmatch '^[a-f0-9]{12}$') { continue }
            $status = Read-JsonFile -Path (Join-Path $dir.FullName 'status.json')
            $plan = Read-JsonFile -Path (Join-Path $dir.FullName 'plan.json')
            if ($null -eq $status -and $null -eq $plan) { continue }

            $rawState = if ($null -ne $status) { Get-Prop $status 'state' 'unknown' } else { 'unknown' }
            $pidValue = if ($null -ne $status) { Get-Prop $status 'pid' } else { $null }
            $alive = $false
            if ($null -ne $pidValue) {
                try {
                    $proc = Get-Process -Id ([int]$pidValue) -ErrorAction Stop
                    $alive = ($null -ne $proc -and -not $proc.HasExited)
                } catch { $alive = $false }
            }

            $percent = $null
            if ($null -ne $status -and $null -ne (Get-Prop $status 'percent')) {
                $percent = [int](Get-Prop $status 'percent')
            }

            $destPath = if ($null -ne $status) { Get-Prop $status 'destPath' } else { $null }
            if ([string]::IsNullOrWhiteSpace($destPath) -and $null -ne $plan) {
                $pf = Get-Prop $plan 'file'
                $pd = Get-Prop $plan 'destDir'
                if (-not [string]::IsNullOrWhiteSpace($pf) -and -not [string]::IsNullOrWhiteSpace($pd)) {
                    $destPath = Join-Path $pd $pf
                }
            }

            # Only trust "running" from the status file or a live PID.
            # A locked .partial must NOT flip every failed sibling job to running.
            $state = $rawState
            if ($alive) { $state = 'running' }
            elseif ($rawState -eq 'running') { $state = 'running' }

            $message = if ($null -ne $status) { Get-Prop $status 'message' } else { $null }
            if ($state -eq 'running' -and [string]::IsNullOrWhiteSpace($message)) {
                $message = 'Downloading'
            }

            $isos += [pscustomobject]@{
                kind     = 'iso'
                jobId    = if ($null -ne $status) { Get-Prop $status 'jobId' $dir.Name } else { $dir.Name }
                key      = if ($null -ne $status -and (Get-Prop $status 'key')) { Get-Prop $status 'key' } else { Get-Prop $plan 'key' }
                state    = $state
                name     = if ($null -ne $status) { Get-Prop $status 'name' 'ISO download' } else { Get-Prop $plan 'name' 'ISO download' }
                detail   = if ($null -ne $status) { Get-Prop $status 'speed' } else { $null }
                percent  = $percent
                message  = $message
                destPath = $destPath
                alive    = $alive
            }
        }
    }

    $activeCount = @($installs | Where-Object { -not (Test-IsTerminalJobState -State $_.state) }).Count +
        @($isos | Where-Object { $_.state -in @('queued', 'running') -or $_.alive }).Count

    # Running jobs first so the Activity panel is useful at a glance.
    $isos = @($isos | Sort-Object @{ Expression = { if ($_.state -eq 'running' -or $_.alive) { 0 } else { 1 } } }, @{ Expression = { if ($null -eq $_.percent) { -1 } else { -[int]$_.percent } } })
    $installs = @($installs | Sort-Object @{ Expression = { if (-not (Test-IsTerminalJobState -State $_.state)) { 0 } else { 1 } } })

    return [pscustomobject]@{
        activeCount = $activeCount
        installs    = $installs
        isos        = $isos
    }
}
