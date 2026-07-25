<#
    Two-tier "is it already installed?" detection.

    Tier 1 is synchronous and runs on every /api/installed call: one snapshot of
    the three uninstall registry hives (~0.12s for ~100 apps) plus PATH and file
    probes. It also catches tools winget did not install, such as Node put there
    by nvm.

    Tier 2 is "winget export", which is authoritative for winget package ids but
    takes ~13 seconds. Blocking the first page load on that is unacceptable, so
    it runs in a detached process and drops its answer into a cache file that
    tier 1 merges in once it lands.
#>

$script:InstalledCacheTtlMinutes = 30
$script:RefreshProcess = $null

function Get-InstalledRegistryNames {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entries = @()
    foreach ($item in (Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue)) {
        $displayName = $item.DisplayName
        if ([string]::IsNullOrWhiteSpace($displayName)) { continue }
        $entries += [pscustomobject]@{
            Name    = $displayName
            Version = $item.DisplayVersion
        }
    }
    return $entries
}

function Get-PathExecutableIndex {
    <#
        Get-Command resolves aliases, functions and modules as well as
        executables, and calling it per app costs well over a second. One pass
        over the PATH directories gives the same answer for a fraction of that.
    #>
    $index = @{}
    $extensions = @('.exe', '.cmd', '.bat', '.com', '.ps1')
    $seenDirectories = @{}

    foreach ($directory in ($env:Path -split ';')) {
        if ([string]::IsNullOrWhiteSpace($directory)) { continue }
        $normalized = $directory.Trim().TrimEnd('\').ToLowerInvariant()
        if ($seenDirectories.ContainsKey($normalized)) { continue }
        $seenDirectories[$normalized] = $true

        try {
            if (-not [System.IO.Directory]::Exists($directory)) { continue }
            foreach ($file in [System.IO.Directory]::GetFiles($directory)) {
                $extension = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
                if ($extensions -notcontains $extension) { continue }
                $index[[System.IO.Path]::GetFileNameWithoutExtension($file).ToLowerInvariant()] = $true
            }
        } catch {
            # Unreadable directory on PATH; skip it.
        }
    }

    return $index
}

function Expand-DetectPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Get-InstalledState {
    <#
        Returns a hashtable of catalog key -> detection result for every app.
    #>
    param([Parameter(Mandatory = $true)] [hashtable]$Context)

    # The server's $env:Path is a snapshot from startup, so anything installed
    # since then would be invisible to the cmd probes below.
    Update-PathFromRegistry

    $registryEntries = Get-InstalledRegistryNames
    $registryNames = @($registryEntries | ForEach-Object { $_.Name })

    $cachePath = Join-Path $Context.StateDir 'installed.json'
    $cache = Read-JsonFile -Path $cachePath
    $wingetIds = @{}
    $cacheAge = $null
    if ($null -ne $cache) {
        foreach ($id in (ConvertTo-Array (Get-Prop $cache 'packageIds'))) {
            $wingetIds[$id.ToLowerInvariant()] = $true
        }
        $stamp = Get-Prop $cache 'generatedAt'
        if (-not [string]::IsNullOrWhiteSpace($stamp)) {
            try { $cacheAge = ((Get-Date) - [datetime]::Parse($stamp)).TotalMinutes } catch { }
        }
    }

    $pathExecutables = Get-PathExecutableIndex

    $result = @{}
    foreach ($app in (Get-CatalogApps)) {
        $key = Get-Prop $app 'key'
        $detect = Get-Prop $app 'detect'
        $installed = $false
        $via = $null
        $version = $null

        $id = Get-Prop $app 'id'
        if (-not [string]::IsNullOrWhiteSpace($id) -and $wingetIds.ContainsKey($id.ToLowerInvariant())) {
            $installed = $true
            $via = 'winget'
        }

        if (-not $installed -and $null -ne $detect) {
            $pattern = Get-Prop $detect 'registry'
            if (-not [string]::IsNullOrWhiteSpace($pattern)) {
                foreach ($entry in $registryEntries) {
                    if ($entry.Name -match $pattern) {
                        $installed = $true
                        $via = 'registry'
                        $version = $entry.Version
                        break
                    }
                }
            }

            if (-not $installed) {
                $command = Get-Prop $detect 'cmd'
                if (-not [string]::IsNullOrWhiteSpace($command) -and
                    $pathExecutables.ContainsKey($command.ToLowerInvariant())) {
                    $installed = $true
                    $via = 'path'
                }
            }

            if (-not $installed) {
                $probePath = Expand-DetectPath (Get-Prop $detect 'path')
                if (-not [string]::IsNullOrWhiteSpace($probePath) -and (Test-Path -LiteralPath $probePath)) {
                    $installed = $true
                    $via = 'file'
                }
            }
        }

        $result[$key] = [pscustomobject]@{
            installed = $installed
            via       = $via
            version   = $version
        }
    }

    return [pscustomobject]@{
        apps           = $result
        wingetCacheAge = $cacheAge
        wingetCached   = ($wingetIds.Count -gt 0)
        registryCount  = $registryNames.Count
    }
}

function Start-InstalledCacheRefresh {
    <#
        Fires "winget export" in a detached process. The 13 second cost happens
        off the request path; the UI picks the answer up on a later poll.
    #>
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Context,
        [switch]$Force
    )

    $cachePath = Join-Path $Context.StateDir 'installed.json'

    if (-not $Force -and (Test-Path -LiteralPath $cachePath)) {
        $cache = Read-JsonFile -Path $cachePath
        $stamp = Get-Prop $cache 'generatedAt'
        if (-not [string]::IsNullOrWhiteSpace($stamp)) {
            try {
                $age = ((Get-Date) - [datetime]::Parse($stamp)).TotalMinutes
                if ($age -lt $script:InstalledCacheTtlMinutes) { return $false }
            } catch { }
        }
    }

    if ($null -ne $script:RefreshProcess -and -not $script:RefreshProcess.HasExited) {
        return $false
    }

    $refreshScript = Join-Path $Context.Root 'server\Refresh-Installed.ps1'
    if (-not (Test-Path -LiteralPath $refreshScript)) { return $false }

    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', "`"$refreshScript`"",
        '-OutputPath', "`"$cachePath`""
    )

    try {
        $script:RefreshProcess = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList $arguments -WindowStyle Hidden -PassThru
        return $true
    } catch {
        return $false
    }
}
