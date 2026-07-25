<#
.SYNOPSIS
    End-to-end self test for WinForge.
.DESCRIPTION
    Starts a real server on a spare port, exercises every endpoint and security
    gate, and checks the install pipeline.

    By default it does NOT install anything, so it is safe to run on a working
    machine. Pass -RunInstall to additionally install and then uninstall one
    tiny package (jq, about 1 MB) to prove the whole pipeline end to end.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Smoke-Test.ps1
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Smoke-Test.ps1 -RunInstall
#>
[CmdletBinding()]
param(
    [switch]$RunInstall,
    [int]$Port = 47190
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

$script:Passed = 0
$script:Failed = 0
$script:Failures = @()

function Test-Case {
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [scriptblock]$Body
    )
    try {
        $result = & $Body
        if ($result -is [string] -and $result.Length -gt 0) {
            Write-Host ("  PASS  {0,-52} {1}" -f $Name, $result) -ForegroundColor Green
        } else {
            Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
        }
        $script:Passed++
    } catch {
        Write-Host ("  FAIL  {0,-52} {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
        $script:Failed++
        $script:Failures += "$Name : $($_.Exception.Message)"
    }
}

function Assert-True {
    param($Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Api {
    param(
        [string]$Path,
        [string]$Method = 'GET',
        $Body,
        [hashtable]$Headers
    )
    if ($null -eq $Headers) { $Headers = @{ 'X-WinForge-Token' = $script:Token } }
    $arguments = @{
        Uri         = "http://localhost:$Port$Path"
        Method      = $Method
        Headers     = $Headers
        UseBasicParsing = $true
    }
    if ($null -ne $Body) {
        $arguments.Body = ($Body | ConvertTo-Json -Depth 8)
        $arguments.ContentType = 'application/json'
    }
    return Invoke-RestMethod @arguments
}

function Get-HttpStatus {
    param([string]$Path, [hashtable]$Headers)
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$Port$Path" -Headers $Headers -UseBasicParsing
        return $response.StatusCode
    } catch {
        if ($null -ne $_.Exception.Response) { return $_.Exception.Response.StatusCode.value__ }
        throw
    }
}

Write-Host ''
Write-Host '  WinForge smoke test' -ForegroundColor Cyan
Write-Host ("  install step: {0}" -f $(if ($RunInstall) { 'ENABLED (jq will be installed then removed)' } else { 'skipped, pass -RunInstall to enable' })) -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------------------
Write-Host '  Catalog' -ForegroundColor White
# ---------------------------------------------------------------------------

. (Join-Path $root 'server\Common.ps1')
. (Join-Path $root 'server\Catalog.ps1')

Test-Case 'catalog parses and loads' {
    Initialize-Catalog -Context @{ CatalogDir = (Join-Path $root 'catalog') } | Out-Null
    $apps = Get-CatalogApps
    Assert-True ($apps.Count -gt 50) "expected more than 50 apps, got $($apps.Count)"
    return "$($apps.Count) apps"
}

Test-Case 'every referenced script file exists' {
    $missing = @()
    foreach ($app in (Get-CatalogApps)) {
        foreach ($step in (ConvertTo-Array (Get-Prop $app 'postInstall'))) {
            if (-not (Test-Path (Join-Path $root "catalog\postinstall\$step.ps1"))) { $missing += $step }
        }
        if ((Get-Prop $app 'kind') -eq 'script') {
            $command = Get-Prop $app 'command'
            if (-not (Test-Path (Join-Path $root "catalog\scripts\$command.ps1"))) { $missing += $command }
        }
    }
    Assert-True ($missing.Count -eq 0) "missing: $($missing -join ', ')"
}

Test-Case 'dependency ordering (nvm before node, jdk before android)' {
    $plan = Resolve-InstallPlan -Keys @('android-studio', 'node-lts', 'temurin-21', 'nvm-windows')
    $order = @($plan.steps | ForEach-Object { $_.key })
    Assert-True ([array]::IndexOf($order, 'nvm-windows') -lt [array]::IndexOf($order, 'node-lts')) "nvm must precede node: $($order -join ' -> ')"
    Assert-True ([array]::IndexOf($order, 'temurin-21') -lt [array]::IndexOf($order, 'android-studio')) "jdk must precede android studio: $($order -join ' -> ')"
    return ($order -join ' -> ')
}

Test-Case 'allowlist rejects ids outside the catalog' {
    $plan = Resolve-InstallPlan -Keys @('git', '../../evil', 'Git.Git; rm -rf /', 'nope')
    Assert-True ($plan.steps.Count -eq 1) "expected only git to survive, got $($plan.steps.Count)"
    Assert-True ($plan.steps[0].key -eq 'git') 'wrong app survived'
    Assert-True ($plan.unknown.Count -eq 3) "expected 3 rejects, got $($plan.unknown.Count)"
    return "3 rejected, 1 accepted"
}

Test-Case 'log sanitiser strips ANSI and progress frames' {
    $dirty = "$([char]27)[32mDownloading$([char]27)[0m`r  45%`r  99%`rSuccessfully installed"
    $clean = Get-CleanConsoleLine -Line $dirty
    Assert-True ($clean -eq 'Successfully installed') "got '$clean'"
    Assert-True (Test-IsNoiseLine -Line '  ---  ') 'spinner frame should be noise'
    return "'$clean'"
}

Test-Case 'winget progress maps download bytes into a mid band' {
    $found = Get-WingetProgressInfo -Line 'Found pgAdmin 4 [PostgreSQL.pgAdmin] Version 9.16'
    Assert-True ($found.percent -eq 3) "found percent was $($found.percent)"
    $mid = Get-WingetProgressInfo -Line '179.4 MB / 358.9 MB'
    Assert-True ($mid.phase -eq 'downloading') "phase was $($mid.phase)"
    Assert-True ($mid.percent -ge 30 -and $mid.percent -le 45) "mid download percent was $($mid.percent)"
    $done = Get-WingetProgressInfo -Line 'Successfully verified installer hash'
    Assert-True ($done.percent -eq 72) "verify percent was $($done.percent)"
    return "bands ok ($($mid.percent)%)"
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  Server' -ForegroundColor White
# ---------------------------------------------------------------------------

$serverProcess = $null
try {
    $serverProcess = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$(Join-Path $root 'start.ps1')`"",
        '-Port', $Port, '-NoBrowser'
    )

    # Wait for the listener rather than guessing with a fixed sleep.
    $ready = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 400
        try {
            Invoke-WebRequest -Uri "http://localhost:$Port/" -UseBasicParsing -TimeoutSec 2 | Out-Null
            $ready = $true
            break
        } catch {
            if ($null -ne $_.Exception.Response) { $ready = $true; break }
        }
    }
    if (-not $ready) { throw "Server did not come up on port $Port" }

    # The token is only printed by the server, so read it back from its window
    # title equivalent: re-derive it by asking the server to reject us first.
    # Simpler: the launcher writes it to state for the test to pick up.
    $script:Token = $null
    $tokenFile = Join-Path $root 'state\session.json'
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $session = Read-JsonFile -Path $tokenFile
        if ($null -ne $session) { $script:Token = Get-Prop $session 'token'; break }
        Start-Sleep -Milliseconds 300
    }
    if ([string]::IsNullOrWhiteSpace($script:Token)) { throw 'Could not read the session token from state\session.json' }

    Test-Case 'serves index.html with real content' {
        $response = Invoke-WebRequest -Uri "http://localhost:$Port/" -UseBasicParsing
        Assert-True ($response.StatusCode -eq 200) "status $($response.StatusCode)"
        Assert-True ($response.RawContentLength -gt 500) "body was empty ($($response.RawContentLength) bytes)"
        Assert-True ($response.Content -match 'WinForge') 'HTML did not contain WinForge'
        return "$($response.RawContentLength) bytes"
    }

    Test-Case 'serves app.js and styles.css with real content' {
        $js = Invoke-WebRequest -Uri "http://localhost:$Port/app.js" -UseBasicParsing
        $css = Invoke-WebRequest -Uri "http://localhost:$Port/styles.css" -UseBasicParsing
        Assert-True ($js.RawContentLength -gt 1000) "app.js was empty ($($js.RawContentLength) bytes)"
        Assert-True ($css.RawContentLength -gt 1000) "styles.css was empty ($($css.RawContentLength) bytes)"
        return "js=$($js.RawContentLength) css=$($css.RawContentLength)"
    }

    Test-Case 'api rejects a missing token' {
        $status = Get-HttpStatus -Path '/api/catalog' -Headers @{}
        Assert-True ($status -eq 401) "expected 401, got $status"
    }

    Test-Case 'api rejects a wrong token' {
        $status = Get-HttpStatus -Path '/api/catalog' -Headers @{ 'X-WinForge-Token' = 'not-the-token' }
        Assert-True ($status -eq 401) "expected 401, got $status"
    }

    Test-Case 'api rejects a cross-origin call' {
        $status = Get-HttpStatus -Path '/api/catalog' -Headers @{
            'X-WinForge-Token' = $script:Token
            'Origin'             = 'http://evil.example.com'
        }
        Assert-True ($status -eq 401) "expected 401, got $status"
    }

    Test-Case 'path traversal is blocked' {
        $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $Port)
        try {
            $stream = $client.GetStream()
            $request = "GET /..%2f..%2fstart.ps1 HTTP/1.1`r`nHost: localhost:$Port`r`nConnection: close`r`n`r`n"
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($request)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            $reader = New-Object System.IO.StreamReader($stream)
            $statusLine = $reader.ReadLine()
        } finally { $client.Close() }
        Assert-True ($statusLine -match '40[34]') "got '$statusLine'"
        return $statusLine
    }

    Test-Case 'GET /api/catalog returns the catalog' {
        $catalog = Invoke-Api -Path '/api/catalog'
        Assert-True ($catalog.apps.Count -gt 50) "only $($catalog.apps.Count) apps"
        Assert-True ($catalog.categories.Count -gt 5) 'categories missing'
        Assert-True ($catalog.presets.Count -gt 0) 'presets missing'
        return "$($catalog.apps.Count) apps, $($catalog.presets.Count) presets, winget=$($catalog.wingetFound)"
    }

    Test-Case 'GET /api/installed responds quickly' {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $installed = Invoke-Api -Path '/api/installed'
        $stopwatch.Stop()
        $count = @($installed.apps.PSObject.Properties | Where-Object { $_.Value.installed }).Count
        Assert-True ($stopwatch.ElapsedMilliseconds -lt 3000) "took $($stopwatch.ElapsedMilliseconds)ms, should stay under 3000ms"
        return "$count detected in $($stopwatch.ElapsedMilliseconds)ms"
    }

    Test-Case 'POST /api/install rejects an empty selection' {
        try {
            Invoke-Api -Path '/api/install' -Method POST -Body @{ apps = @() } | Out-Null
            throw 'should have been rejected'
        } catch {
            $status = $_.Exception.Response.StatusCode.value__
            Assert-True ($status -eq 400) "expected 400, got $status"
        }
    }

    Test-Case 'POST /api/install rejects unknown apps' {
        try {
            Invoke-Api -Path '/api/install' -Method POST -Body @{ apps = @('not-a-real-app') } | Out-Null
            throw 'should have been rejected'
        } catch {
            $status = $_.Exception.Response.StatusCode.value__
            Assert-True ($status -eq 400) "expected 400, got $status"
        }
    }

    Test-Case 'unknown job id returns 404' {
        $status = Get-HttpStatus -Path '/api/job/99999999-999999-zzzzzz' -Headers @{ 'X-WinForge-Token' = $script:Token }
        Assert-True ($status -eq 404) "expected 404, got $status"
    }

    # -----------------------------------------------------------------------
    if ($RunInstall) {
        Write-Host ''
        Write-Host '  Install pipeline (real winget install)' -ForegroundColor White

        $jobDirectory = $null

        Test-Case 'runner installs a package and logs cleanly' {
            $plan = Resolve-InstallPlan -Keys @('jq', 'davinci-resolve')
            $jobId = '20990101-000000-aaaaaa'
            $jobDirectory = Join-Path $root "state\jobs\$jobId"
            New-Item -ItemType Directory -Path (Join-Path $jobDirectory 'logs') -Force | Out-Null
            Write-JsonFile -Path (Join-Path $jobDirectory 'plan.json') -Value ([pscustomobject]@{
                jobId = $jobId; options = $null; steps = $plan.steps
            })

            & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $root 'server\Run-Job.ps1') -JobDir $jobDirectory | Out-Null

            $status = Read-JsonFile -Path (Join-Path $jobDirectory 'status.json')
            Assert-True ($status.state -eq 'finished') "job state is '$($status.state)'"
            Assert-True ($status.steps[0].state -eq 'done') "install state is '$($status.steps[0].state)': $($status.steps[0].message)"
            Assert-True ($status.steps[1].state -eq 'manual') "manual step state is '$($status.steps[1].state)'"

            $log = Get-Content (Join-Path $jobDirectory 'logs\0.log') -Raw
            Assert-True ($log -notmatch "\x1b\[") 'ANSI escapes leaked into the log'
            Assert-True ($log -match 'Successfully installed|Already installed') 'no success line in the log'
            return "$($status.steps[0].message)"
        }

        Test-Case 'incremental log polling returns only new lines' {
            $full = Invoke-Api -Path "/api/job/20990101-000000-aaaaaa?tail=0&since=0"
            $total = $full.logs.'0'.total
            Assert-True ($total -gt 0) 'no log lines'
            $partial = Invoke-Api -Path "/api/job/20990101-000000-aaaaaa?tail=0&since=$($total - 2)"
            Assert-True ($partial.logs.'0'.lines.Count -eq 2) "expected 2 new lines, got $($partial.logs.'0'.lines.Count)"
            return "$total lines total, tail returned 2"
        }

        Test-Case 'installed package is detected' {
            $installed = Invoke-Api -Path '/api/installed?refresh=1'
            # The registry tier misses portable packages, so give the winget
            # export tier time to land before deciding.
            for ($attempt = 0; $attempt -lt 12; $attempt++) {
                if ($installed.apps.jq.installed) { break }
                Start-Sleep -Seconds 3
                $installed = Invoke-Api -Path '/api/installed'
            }
            Assert-True ($installed.apps.jq.installed) 'jq was installed but not detected'
            return "detected via $($installed.apps.jq.via)"
        }

        Test-Case 'cleanup: package removed and job state deleted' {
            & winget uninstall --id jqlang.jq -e --disable-interactivity 2>&1 | Out-Null
            Remove-Item -Recurse -Force $jobDirectory -ErrorAction SilentlyContinue
            $remaining = & winget list --id jqlang.jq -e --disable-interactivity 2>&1 | Out-String
            Assert-True ($remaining -notmatch 'jqlang\.jq') 'jq is still installed'
            return 'jq removed'
        }
    }

} finally {
    if ($null -ne $serverProcess) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*start.ps1*-Port $Port*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------

Write-Host ''
Write-Host ("  {0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed) { 'Red' } else { 'Green' })
if ($script:Failed -gt 0) {
    Write-Host ''
    foreach ($failure in $script:Failures) { Write-Host "    - $failure" -ForegroundColor Red }
    Write-Host ''
    exit 1
}
Write-Host ''
exit 0
