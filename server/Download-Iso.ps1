<#
.SYNOPSIS
    Downloads an allowlisted OS ISO into the destination folder.
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
$plan = Read-JsonFile -Path $planPath
if ($null -eq $plan) { throw "Missing plan.json in $JobDir" }

function Save-IsoStatus {
    param($Value)
    # Progress updates are best-effort; never abort a multi-GB download because
    # status.json was briefly locked by the UI poller.
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            Write-JsonFile -Path $statusPath -Value $Value
            return
        } catch {
            Start-Sleep -Milliseconds (40 + ($attempt * 40))
        }
    }
}

$name = Get-Prop $plan 'name' 'ISO'
$url = Get-Prop $plan 'url'
$file = Get-Prop $plan 'file'
$destDir = Get-Prop $plan 'destDir'
$jobId = Get-Prop $plan 'jobId'
$startedAt = (Get-Date).ToString('o')
$destPath = $null
$partial = $null

$status = [pscustomobject]@{
    jobId      = $jobId
    state      = 'running'
    name       = $name
    percent    = 0
    message    = 'Preparing'
    speed      = $null
    destPath   = $null
    error      = $null
    startedAt  = $startedAt
    finishedAt = $null
}
Save-IsoStatus $status

try {
    if ([string]::IsNullOrWhiteSpace($url) -or $url -notmatch '^https://') {
        throw 'Refusing download: URL is not an allowlisted https link.'
    }
    if ([string]::IsNullOrWhiteSpace($file) -or $file -notmatch '^[A-Za-z0-9][A-Za-z0-9._\- ]*\.iso$') {
        throw 'Refusing download: unsafe file name.'
    }
    if ([string]::IsNullOrWhiteSpace($destDir)) {
        throw 'No destination folder.'
    }

    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $destPath = Join-Path $destDir $file
    $partial = "$destPath.partial"
    $status.destPath = $destPath
    $status.message = "Downloading $file"
    Save-IsoStatus $status

    if (Test-Path -LiteralPath $destPath) {
        $status.state = 'finished'
        $status.percent = 100
        $status.message = 'Already downloaded'
        $status.finishedAt = (Get-Date).ToString('o')
        Save-IsoStatus $status
        return
    }

    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    }

    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.Method = 'GET'
    $request.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) WinForge/1.0'
    $request.AllowAutoRedirect = $true
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 600000

    $response = $request.GetResponse()
    try {
        $total = [int64]$response.ContentLength
        $input = $response.GetResponseStream()
        $output = [System.IO.File]::Create($partial)
        try {
            $buffer = New-Object byte[] (1024 * 256)
            $readTotal = [int64]0
            $lastPct = -1
            $lastSave = [datetime]::MinValue
            $speedMark = Get-Date
            $speedBytes = [int64]0

            while (($n = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $output.Write($buffer, 0, $n)
                $readTotal += $n
                $speedBytes += $n

                $pct = 0
                if ($total -gt 0) {
                    $pct = [int][math]::Min(99, [math]::Floor(100.0 * $readTotal / $total))
                }

                $now = Get-Date
                if ($pct -ge ($lastPct + 1) -or ($now - $lastSave).TotalMilliseconds -ge 800) {
                    $elapsedSec = [math]::Max(0.001, ($now - $speedMark).TotalSeconds)
                    $bytesPerSec = $speedBytes / $elapsedSec
                    $speedMark = $now
                    $speedBytes = [int64]0

                    if ($bytesPerSec -ge 1MB) {
                        $status.speed = ('{0:N1} MB/s' -f ($bytesPerSec / 1MB))
                    } elseif ($bytesPerSec -ge 1KB) {
                        $status.speed = ('{0:N0} KB/s' -f ($bytesPerSec / 1KB))
                    } else {
                        $status.speed = ('{0:N0} B/s' -f $bytesPerSec)
                    }

                    $lastPct = $pct
                    $lastSave = $now
                    $mb = [math]::Round($readTotal / 1MB, 1)
                    if ($total -gt 0) {
                        $totalMb = [math]::Round($total / 1MB, 1)
                        $status.message = "Downloading $mb / $totalMb MB"
                        $status.percent = $pct
                    } else {
                        $status.message = "Downloading $mb MB"
                        $status.percent = [math]::Min(95, [int]($mb / 50))
                    }
                    Save-IsoStatus $status
                }
            }
        } finally {
            $output.Dispose()
            $input.Dispose()
        }
    } finally {
        $response.Dispose()
    }

    $info = Get-Item -LiteralPath $partial -ErrorAction SilentlyContinue
    if ($null -eq $info -or $info.Length -lt 1MB) {
        throw 'Download finished but the file is missing or too small.'
    }

    Move-Item -LiteralPath $partial -Destination $destPath -Force

    $status.state = 'finished'
    $status.percent = 100
    $status.message = 'Download complete'
    $status.speed = $null
    $status.destPath = $destPath
    $status.finishedAt = (Get-Date).ToString('o')
    Save-IsoStatus $status
} catch {
    if ($null -ne $partial -and (Test-Path -LiteralPath $partial)) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    }
    $status.state = 'failed'
    $status.error = $_.Exception.Message
    $status.message = $_.Exception.Message
    $status.speed = $null
    $status.finishedAt = (Get-Date).ToString('o')
    Save-IsoStatus $status
    exit 1
}
