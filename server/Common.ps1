<#
    Shared helpers used by both the server process and the elevated runner.
    Windows PowerShell 5.1 compatible.
#>

function New-SessionToken {
    $bytes = New-Object 'byte[]' 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Get-ServerPrefixes {
    <#
        Single source of truth for the listener prefixes. The port probe must
        reserve exactly what the server later registers, otherwise a port that
        http.sys is still holding from a previous run looks free and the server
        fails on startup instead of moving to the next port.
    #>
    param([Parameter(Mandatory = $true)] [int]$Port)
    return @("http://localhost:$Port/", "http://127.0.0.1:$Port/")
}

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-Prop {
    <#
        Safe property read for PSCustomObjects produced by ConvertFrom-Json.
        Returns $Default when the property is missing or null.
    #>
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)] [string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function ConvertTo-Array {
    <#
        ConvertFrom-Json yields a bare value for single-element arrays in some
        paths and $null for absent ones. Normalise everything to an array.
    #>
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { return , @($Value) }
    if ($Value -is [System.Collections.IEnumerable]) { return @($Value) }
    return , @($Value)
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        $Default = $null
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    # Share ReadWrite so runners can rewrite status.json while the HTTP server
    # is mid-poll (File.ReadAllText uses a share that blocks writers).
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        try {
            $stream = New-Object System.IO.FileStream(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite
            )
            try {
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
                try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
            } finally {
                $stream.Dispose()
            }
            if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
            return ($raw | ConvertFrom-Json)
        } catch {
            Start-Sleep -Milliseconds (25 + ($attempt * 25))
        }
    }
    return $Default
}

function Write-JsonFile {
    <#
        Writes atomically: the runner rewrites status.json constantly while the
        server reads it. Retries when the destination is briefly locked.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] $Value,
        [int]$Depth = 12
    )
    $json = $Value | ConvertTo-Json -Depth $Depth
    if ($null -eq $json) { $json = '{}' }
    $temp = "$Path.tmp"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temp, $json, $utf8)

    $copied = $false
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            [System.IO.File]::Copy($temp, $Path, $true)
            $copied = $true
            break
        } catch {
            Start-Sleep -Milliseconds (30 + ($attempt * 30))
        }
    }
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue

    if (-not $copied) {
        $bytes = $utf8.GetBytes($json)
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::ReadWrite
        )
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
}

function Get-CleanConsoleLine {
    <#
        winget emits ANSI colour codes and redraws a progress bar with carriage
        returns. Left alone, a single install fills the log pane with hundreds
        of spinner frames.
    #>
    param([string]$Line)
    if ($null -eq $Line) { return '' }

    # Keep only what follows the last carriage return: that is the final state
    # of a redrawn progress line.
    $lastCr = $Line.LastIndexOf("`r")
    if ($lastCr -ge 0) { $Line = $Line.Substring($lastCr + 1) }

    $Line = $Line -replace "\x1b\[[0-9;?]*[a-zA-Z]", ''
    $Line = $Line -replace "\x1b\][^\x07]*\x07", ''
    # Braille and block glyphs are winget's spinner and progress bar fill.
    $Line = $Line -replace '[\u2800-\u28FF\u2580-\u259F]', ''
    return $Line.TrimEnd()
}

function Convert-SizeToBytes {
    param([double]$Value, [string]$Unit)
    switch ($Unit.ToUpperInvariant()) {
        'B'  { return $Value }
        'KB' { return $Value * 1KB }
        'MB' { return $Value * 1MB }
        'GB' { return $Value * 1GB }
        default { return $Value }
    }
}

function Get-WingetProgressInfo {
    <#
        Pull a percent / phase out of a winget console line. Progress frames are
        often filtered from the visible log, but the UI still wants a bar.

        Winget only emits a few milestone lines reliably (Found → Downloading →
        hash → install → done), so we map those into bands and scale any real
        download bytes into the downloading band (5–68%) instead of jumping
        straight from 2% to 70%.
    #>
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

    $phase = $null
    $percent = $null
    $detail = $null

    if ($Line -match '(?i)^Found .+\[') {
        $phase = 'resolving'; $percent = 3
    }
    elseif ($Line -match '(?i)Downloading\s+https?://') {
        $phase = 'downloading'; $percent = 6
    }
    elseif ($Line -match '(?i)Successfully verified installer hash') {
        $phase = 'verifying'; $percent = 72
    }
    elseif ($Line -match '(?i)Starting package install') {
        $phase = 'installing'; $percent = 78
    }
    elseif ($Line -match '(?i)Successfully installed') {
        $phase = 'done'; $percent = 100
    }
    elseif ($Line -match '(?i)already installed') {
        $phase = 'done'; $percent = 100
    }

    $downloadPct = $null
    if ($Line -match '(\d+(?:\.\d+)?)\s*%') {
        $downloadPct = [math]::Min(100.0, [double]$Matches[1])
        if ($null -eq $phase) { $phase = 'downloading' }
    }

    # winget / progress bars: "12.4 MB / 358.9 MB" (also "of" and thin spaces)
    $sizeLine = $Line -replace '[\u00A0\u202F]', ' '
    if ($sizeLine -match '([\d\.]+)\s*(B|KB|MB|GB)\s*(?:/|of)\s*([\d\.]+)\s*(B|KB|MB|GB)') {
        $current = Convert-SizeToBytes -Value ([double]$Matches[1]) -Unit $Matches[2]
        $total = Convert-SizeToBytes -Value ([double]$Matches[3]) -Unit $Matches[4]
        if ($total -gt 0) {
            $downloadPct = 100.0 * $current / $total
            $detail = "$($Matches[1]) $($Matches[2]) / $($Matches[3]) $($Matches[4])"
            if ($null -eq $phase) { $phase = 'downloading' }
        }
    }

    if ($null -ne $downloadPct) {
        if ($phase -eq 'verifying' -or $phase -eq 'installing' -or $phase -eq 'done') {
            # Keep milestone percents once we leave the download phase.
        } else {
            $phase = 'downloading'
            # Map 0–100% of the file into the 6–68% UI band.
            $percent = [int][math]::Round(6 + (62.0 * [math]::Min(100.0, $downloadPct) / 100.0))
            $percent = [math]::Min(68, [math]::Max(6, $percent))
        }
    }

    if ($null -eq $phase -and $null -eq $percent) { return $null }
    return @{
        phase   = $phase
        percent = $percent
        detail  = $detail
    }
}

function Test-IsNoiseLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $true }
    $trimmed = $Line.Trim()
    if ($trimmed -match '^[\-\\|/]+$') { return $true }
    if ($trimmed -match '^[\s\d\.%KMGB/]+$' -and $trimmed -match '%') { return $true }
    if ($trimmed -match '^[\d\.]+\s*(B|KB|MB|GB)\s*/\s*[\d\.]+\s*(B|KB|MB|GB)') { return $true }
    return $false
}

function Update-PathFromRegistry {
    <#
        A child process inherits the PATH that existed when it started. After
        installing Node, "corepack enable" in the same job would fail without
        this because node.exe is not on the inherited PATH yet.
    #>
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    foreach ($chunk in @($machine, $user)) {
        if ([string]::IsNullOrWhiteSpace($chunk)) { continue }
        foreach ($p in $chunk.Split(';')) {
            if (-not [string]::IsNullOrWhiteSpace($p) -and $parts -notcontains $p) {
                $parts += $p
            }
        }
    }
    $env:Path = [string]::Join(';', $parts)

    foreach ($name in @('JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'NVM_HOME', 'NVM_SYMLINK')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Machine')
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = [Environment]::GetEnvironmentVariable($name, 'User')
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            Set-Item -Path "env:$name" -Value $value -ErrorAction SilentlyContinue
        }
    }
}

function Add-ToSystemPath {
    <#
        Appends a directory to the persisted PATH (machine scope when elevated,
        user scope otherwise) without duplicating an existing entry.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Directory,
        [ValidateSet('Machine', 'User')] [string]$Scope = 'Machine'
    )
    $current = [Environment]::GetEnvironmentVariable('Path', $Scope)
    if ($null -eq $current) { $current = '' }
    $existing = $current.Split(';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($entry in $existing) {
        if ($entry.TrimEnd('\') -ieq $Directory.TrimEnd('\')) {
            return $false
        }
    }
    $updated = (@($existing) + $Directory) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $updated, $Scope)
    return $true
}

function Set-PersistentEnvVar {
    param(
        [Parameter(Mandatory = $true)] [string]$Name,
        [Parameter(Mandatory = $true)] [string]$Value,
        [ValidateSet('Machine', 'User')] [string]$Scope = 'Machine'
    )
    [Environment]::SetEnvironmentVariable($Name, $Value, $Scope)
    Set-Item -Path "env:$Name" -Value $Value -ErrorAction SilentlyContinue
}
