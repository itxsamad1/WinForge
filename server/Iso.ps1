<#
    OS ISO catalog + unelevated download jobs.

    Linux ISOs use allowlisted HTTPS URLs from catalog/isos.json.
    Windows entries are "portal" only — Microsoft does not expose stable
    direct ISO URLs, so we open their official download page instead.
#>

$script:IsoCatalog = @()
$script:IsoStamp = $null
$script:IsoContext = $null

function Get-IsoCatalogPath {
    param([hashtable]$Context)
    return (Join-Path $Context.CatalogDir 'isos.json')
}

function Get-IsoStamp {
    param([hashtable]$Context)
    $path = Get-IsoCatalogPath -Context $Context
    if (-not (Test-Path -LiteralPath $path)) { return '0' }
    return [string](Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks
}

function Initialize-IsoCatalog {
    param([Parameter(Mandatory = $true)] [hashtable]$Context)
    $script:IsoContext = $Context
    $path = Get-IsoCatalogPath -Context $Context
    $doc = Read-JsonFile -Path $path
    if ($null -eq $doc) {
        $script:IsoCatalog = @()
        $script:IsoStamp = Get-IsoStamp -Context $Context
        Write-Host '  ISO catalog: (missing or empty)' -ForegroundColor DarkGray
        return
    }
    $script:IsoCatalog = @(ConvertTo-Array (Get-Prop $doc 'oses'))
    $script:IsoStamp = Get-IsoStamp -Context $Context
    Write-Host "  ISO catalog: $($script:IsoCatalog.Count) operating systems" -ForegroundColor DarkGray
}

function Ensure-IsoCatalogFresh {
    param([Parameter(Mandatory = $true)] [hashtable]$Context)
    $stamp = Get-IsoStamp -Context $Context
    if ($null -ne $script:IsoStamp -and $script:IsoStamp -eq $stamp) { return }
    Initialize-IsoCatalog -Context $Context
}

function Get-IsoCatalog {
    if ($null -ne $script:IsoContext) { Ensure-IsoCatalogFresh -Context $script:IsoContext }
    return $script:IsoCatalog
}

function Get-IsoEntry {
    param([Parameter(Mandatory = $true)] [string]$Key)
    foreach ($os in (Get-IsoCatalog)) {
        if ((Get-Prop $os 'key') -eq $Key) { return $os }
    }
    return $null
}

function Get-DefaultIsoDownloadDir {
    $downloads = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
    return (Join-Path $downloads 'WinForge-ISOs')
}

function Resolve-IsoVariant {
    <#
        Allowlist resolve: only returns a URL that already exists in isos.json.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Key,
        [Parameter(Mandatory = $true)] [string]$Edition,
        [Parameter(Mandatory = $true)] [string]$Arch
    )

    $os = Get-IsoEntry -Key $Key
    if ($null -eq $os) { return $null }

    $source = Get-Prop $os 'source' 'direct'
    if ($source -eq 'portal') {
        $url = Get-Prop $os 'url'
        if ([string]::IsNullOrWhiteSpace($url) -or $url -notmatch '^https://') { return $null }
        return [pscustomobject]@{
            key      = $Key
            name     = Get-Prop $os 'name' $Key
            source   = 'portal'
            url      = $url
            file     = $null
            edition  = $Edition
            arch     = $Arch
        }
    }

    $editionObj = $null
    foreach ($ed in (ConvertTo-Array (Get-Prop $os 'editions'))) {
        if ((Get-Prop $ed 'id') -eq $Edition) { $editionObj = $ed; break }
    }
    if ($null -eq $editionObj) { return $null }

    $archMap = Get-Prop $editionObj 'architectures'
    if ($null -eq $archMap) { return $null }
    $variant = Get-Prop $archMap $Arch
    if ($null -eq $variant) { return $null }

    $url = Get-Prop $variant 'url'
    $file = Get-Prop $variant 'file'
    if ([string]::IsNullOrWhiteSpace($url) -or $url -notmatch '^https://') { return $null }
    if ([string]::IsNullOrWhiteSpace($file)) { $file = [IO.Path]::GetFileName(($url -split '\?')[0]) }
    if ($file -notmatch '\.iso$') { return $null }

    return [pscustomobject]@{
        key     = $Key
        name    = "$(Get-Prop $os 'name') ($(Get-Prop $editionObj 'name'), $Arch)"
        source  = 'direct'
        url     = $url
        file    = $file
        edition = $Edition
        arch    = $Arch
    }
}

function Test-SafeIsoDestDir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch { return $false }
    # Block obvious traversal into system roots; Downloads / user profile is fine.
    if ($full -match '(?i)^[A-Z]:\\(Windows|Program Files|Program Files \(x86\)|ProgramData)(\\|$)') { return $false }
    if ($full.Length -lt 4) { return $false }
    return $true
}

function Test-IsoProcessAlive {
    param($PidValue)
    if ($null -eq $PidValue) { return $false }
    try {
        $proc = Get-Process -Id ([int]$PidValue) -ErrorAction Stop
        return ($null -ne $proc -and -not $proc.HasExited)
    } catch {
        return $false
    }
}

function Find-ActiveIsoJob {
    <#
        Returns an in-flight ISO job for the same OS key / file so a page reload
        or second click reattaches instead of starting a conflicting download.
    #>
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Context,
        [Parameter(Mandatory = $true)] [string]$Key,
        [string]$File,
        [string]$DestDir
    )

    $jobsRoot = Join-Path $Context.StateDir 'iso-jobs'
    if (-not (Test-Path -LiteralPath $jobsRoot)) { return $null }

    $dirs = Get-ChildItem -LiteralPath $jobsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    foreach ($dir in $dirs) {
        if ($dir.Name -notmatch '^[a-f0-9]{12}$') { continue }
        $plan = Read-JsonFile -Path (Join-Path $dir.FullName 'plan.json')
        $status = Read-JsonFile -Path (Join-Path $dir.FullName 'status.json')
        if ($null -eq $plan) { continue }

        $planKey = Get-Prop $plan 'key'
        $planFile = Get-Prop $plan 'file'
        if ($planKey -ne $Key) { continue }
        if (-not [string]::IsNullOrWhiteSpace($File) -and $planFile -ne $File) { continue }
        if (-not [string]::IsNullOrWhiteSpace($DestDir)) {
            $planDest = Get-Prop $plan 'destDir'
            if (-not [string]::IsNullOrWhiteSpace($planDest) -and
                ([IO.Path]::GetFullPath($planDest) -ne [IO.Path]::GetFullPath($DestDir))) {
                continue
            }
        }

        $state = if ($null -ne $status) { Get-Prop $status 'state' } else { 'unknown' }
        $pidValue = if ($null -ne $status) { Get-Prop $status 'pid' } else { $null }
        $alive = Test-IsoProcessAlive -PidValue $pidValue
        $partialPath = $null
        if (-not [string]::IsNullOrWhiteSpace($DestDir) -and -not [string]::IsNullOrWhiteSpace($planFile)) {
            $partialPath = Join-Path $DestDir ($planFile + '.partial')
        } elseif ($null -ne $status) {
            $destPath = Get-Prop $status 'destPath'
            if (-not [string]::IsNullOrWhiteSpace($destPath)) { $partialPath = "$destPath.partial" }
        }
        $partialBusy = $false
        if (-not [string]::IsNullOrWhiteSpace($partialPath) -and (Test-Path -LiteralPath $partialPath)) {
            try {
                $fs = [System.IO.File]::Open($partialPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                $fs.Dispose()
            } catch {
                $partialBusy = $true
            }
        }

        if (-not $alive -and -not $partialBusy) { continue }

        # Heal a failed/stale status while the downloader is still alive.
        if ($null -ne $status -and $alive -and $state -ne 'running') {
            $status.state = 'running'
            if ([string]::IsNullOrWhiteSpace((Get-Prop $status 'message'))) {
                $status.message = 'Downloading'
            }
            try { Write-JsonFile -Path (Join-Path $dir.FullName 'status.json') -Value $status } catch { }
        }

        return [pscustomobject]@{
            jobId   = $dir.Name
            destDir = Get-Prop $plan 'destDir'
            name    = Get-Prop $plan 'name' (Get-Prop $status 'name' 'ISO')
            file    = $planFile
            key     = $planKey
            reattached = $true
        }
    }
    return $null
}

function Start-IsoDownloadJob {
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Context,
        [Parameter(Mandatory = $true)] $Variant,
        [Parameter(Mandatory = $true)] [string]$DestDir
    )

    $existing = Find-ActiveIsoJob -Context $Context -Key $Variant.key -File $Variant.file -DestDir $DestDir
    if ($null -ne $existing) {
        return $existing
    }

    $jobsRoot = Join-Path $Context.StateDir 'iso-jobs'
    if (-not (Test-Path -LiteralPath $jobsRoot)) {
        New-Item -ItemType Directory -Path $jobsRoot -Force | Out-Null
    }

    $jobId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $jobDir = Join-Path $jobsRoot $jobId
    New-Item -ItemType Directory -Path $jobDir -Force | Out-Null

    $startedAt = (Get-Date).ToString('o')
    $plan = [pscustomobject]@{
        jobId   = $jobId
        key     = $Variant.key
        name    = $Variant.name
        source  = $Variant.source
        url     = $Variant.url
        file    = $Variant.file
        edition = $Variant.edition
        arch    = $Variant.arch
        destDir = $DestDir
    }
    Write-JsonFile -Path (Join-Path $jobDir 'plan.json') -Value $plan

    Write-JsonFile -Path (Join-Path $jobDir 'status.json') -Value ([pscustomobject]@{
        jobId      = $jobId
        key        = $Variant.key
        state      = 'queued'
        name       = $Variant.name
        percent    = 0
        message    = 'Starting'
        speed      = $null
        destPath   = $null
        error      = $null
        startedAt  = $startedAt
        finishedAt = $null
    })

    $runner = Join-Path $Context.Root 'server\Download-Iso.ps1'
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', "`"$runner`"",
        '-JobDir', "`"$jobDir`""
    )
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru -WindowStyle Hidden
    Write-JsonFile -Path (Join-Path $jobDir 'status.json') -Value ([pscustomobject]@{
        jobId      = $jobId
        key        = $Variant.key
        state      = 'running'
        name       = $Variant.name
        percent    = 0
        message    = 'Downloading'
        speed      = $null
        destPath   = (Join-Path $DestDir $Variant.file)
        error      = $null
        pid        = $proc.Id
        startedAt  = $startedAt
        finishedAt = $null
    })

    return [pscustomobject]@{
        jobId   = $jobId
        destDir = $DestDir
        name    = $Variant.name
        file    = $Variant.file
        key     = $Variant.key
        reattached = $false
    }
}

function Get-IsoJobState {
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Context,
        [Parameter(Mandatory = $true)] [string]$JobId
    )
    if ($JobId -notmatch '^[a-f0-9]{12}$') { return $null }
    $jobDir = Join-Path $Context.StateDir "iso-jobs\$JobId"
    $path = Join-Path $jobDir 'status.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $status = Read-JsonFile -Path $path
    if ($null -eq $status) { return $null }

    $pidValue = Get-Prop $status 'pid'
    if ($null -ne $pidValue -and (Test-IsoProcessAlive -PidValue $pidValue)) {
        $state = Get-Prop $status 'state'
        if ($state -notin @('running', 'queued', 'finished')) {
            $status.state = 'running'
            if ([string]::IsNullOrWhiteSpace((Get-Prop $status 'message'))) {
                $status.message = 'Downloading'
            }
        }
    }
    return $status
}
