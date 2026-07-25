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

    $status = Read-JsonFile -Path (Join-Path $jobDir 'status.json')
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
    if (Test-Path -LiteralPath $jobsDir) {
        $dirs = Get-ChildItem -LiteralPath $jobsDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 12
        foreach ($dir in $dirs) {
            if ($dir.Name -notmatch '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$') { continue }
            $status = Read-JsonFile -Path (Join-Path $dir.FullName 'status.json')
            if ($null -eq $status) { continue }
            $steps = @(ConvertTo-Array (Get-Prop $status 'steps'))
            $running = $steps | Where-Object { (Get-Prop $_ 'state') -eq 'running' } | Select-Object -First 1
            $done = @($steps | Where-Object { (Get-Prop $_ 'state') -in @('done', 'manual') }).Count
            $failed = @($steps | Where-Object { (Get-Prop $_ 'state') -eq 'failed' }).Count
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
            $installs += [pscustomobject]@{
                kind    = 'install'
                jobId   = Get-Prop $status 'jobId' $dir.Name
                state   = Get-Prop $status 'state' 'unknown'
                name    = $label
                detail  = if ($null -ne $running) { Get-Prop $running 'phase' } else { $null }
                percent = $pct
                message = if ($null -ne $running) { Get-Prop $running 'message' } else { $null }
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

            $state = if ($null -ne $status) { Get-Prop $status 'state' 'unknown' } else { 'unknown' }
            $pidValue = if ($null -ne $status) { Get-Prop $status 'pid' } else { $null }
            $alive = $false
            if ($null -ne $pidValue) {
                try {
                    $proc = Get-Process -Id ([int]$pidValue) -ErrorAction Stop
                    $alive = ($null -ne $proc -and -not $proc.HasExited)
                } catch { $alive = $false }
            }
            if ($alive -and $state -notin @('running', 'queued')) {
                $state = 'running'
            }

            $isos += [pscustomobject]@{
                kind     = 'iso'
                jobId    = if ($null -ne $status) { Get-Prop $status 'jobId' $dir.Name } else { $dir.Name }
                key      = if ($null -ne $status -and (Get-Prop $status 'key')) { Get-Prop $status 'key' } else { Get-Prop $plan 'key' }
                state    = $state
                name     = if ($null -ne $status) { Get-Prop $status 'name' 'ISO download' } else { Get-Prop $plan 'name' 'ISO download' }
                detail   = if ($null -ne $status) { Get-Prop $status 'speed' } else { $null }
                percent  = if ($null -ne $status) { Get-Prop $status 'percent' } else { $null }
                message  = if ($null -ne $status) { Get-Prop $status 'message' } else { 'Downloading' }
                destPath = if ($null -ne $status) { Get-Prop $status 'destPath' } else { $null }
                alive    = $alive
            }
        }
    }

    $activeCount = @($installs | Where-Object { $_.state -notin @('finished', 'failed') }).Count +
        @($isos | Where-Object { $_.state -in @('queued', 'running') -or $_.alive }).Count

    return [pscustomobject]@{
        activeCount = $activeCount
        installs    = $installs
        isos        = $isos
    }
}
