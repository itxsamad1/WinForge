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

function Start-IsoDownloadJob {
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Context,
        [Parameter(Mandatory = $true)] $Variant,
        [Parameter(Mandatory = $true)] [string]$DestDir
    )

    $jobsRoot = Join-Path $Context.StateDir 'iso-jobs'
    if (-not (Test-Path -LiteralPath $jobsRoot)) {
        New-Item -ItemType Directory -Path $jobsRoot -Force | Out-Null
    }

    $jobId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $jobDir = Join-Path $jobsRoot $jobId
    New-Item -ItemType Directory -Path $jobDir -Force | Out-Null

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

    $status = [pscustomobject]@{
        jobId      = $jobId
        state      = 'queued'
        name       = $Variant.name
        percent    = 0
        message    = 'Starting'
        destPath   = $null
        error      = $null
        startedAt  = (Get-Date).ToString('o')
        finishedAt = $null
    }
    Write-JsonFile -Path (Join-Path $jobDir 'status.json') -Value $status

    $runner = Join-Path $Context.Root 'server\Download-Iso.ps1'
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', "`"$runner`"",
        '-JobDir', "`"$jobDir`""
    )
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden
    Write-JsonFile -Path (Join-Path $jobDir 'status.json') -Value ([pscustomobject]@{
        jobId      = $jobId
        state      = 'running'
        name       = $Variant.name
        percent    = 0
        message    = 'Downloading'
        destPath   = $null
        error      = $null
        pid        = $proc.Id
        startedAt  = $status.startedAt
        finishedAt = $null
    })

    return [pscustomobject]@{
        jobId   = $jobId
        destDir = $DestDir
        name    = $Variant.name
        file    = $Variant.file
    }
}

function Get-IsoJobState {
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Context,
        [Parameter(Mandatory = $true)] [string]$JobId
    )
    if ($JobId -notmatch '^[a-f0-9]{12}$') { return $null }
    $path = Join-Path $Context.StateDir "iso-jobs\$JobId\status.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Read-JsonFile -Path $path
}
