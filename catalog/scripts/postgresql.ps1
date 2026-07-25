<#
    Installs PostgreSQL 18 via the EnterpriseDB Windows installer.

    winget cannot download this package (EDB returns HTTP 403 to WinGet).
    PowerShell can download it, then we drive the installer with an
    InstallBuilder --optionfile so quoting never breaks silent mode.
#>
param($Context, $Options)

Update-PathFromRegistry

$packageId = 'PostgreSQL.PostgreSQL.18'
$major = '18'
$prefix = "C:\Program Files\PostgreSQL\$major"
$binDir = Join-Path $prefix 'bin'
$psql = Join-Path $binDir 'psql.exe'

if ((Get-Command 'psql' -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $psql)) {
    Write-Output "PostgreSQL $major already looks installed."
    if (Test-Path -LiteralPath $binDir) {
        if (Add-ToSystemPath -Directory $binDir -Scope 'Machine') {
            Write-Output "Added $binDir to PATH"
        }
    }
    return
}

Write-Output "Resolving installer URL for $packageId..."
$show = & winget show --id $packageId --exact --source winget --disable-interactivity 2>&1 |
    ForEach-Object { [string]$_ }
$urlLine = $show | Where-Object { $_ -match 'Installer Url:\s+(\S+)' } | Select-Object -First 1
if (-not $urlLine -or $urlLine -notmatch 'Installer Url:\s+(\S+)') {
    throw "Could not read Installer Url from winget show for $packageId"
}
$url = $Matches[1]
Write-Output "Installer: $url"

$workDir = Join-Path $env:TEMP 'WinForge-postgresql'
if (-not (Test-Path -LiteralPath $workDir)) {
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
}
$installer = Join-Path $workDir ([IO.Path]::GetFileName(($url -split '\?')[0]))

if (-not (Test-Path -LiteralPath $installer) -or (Get-Item -LiteralPath $installer).Length -lt 1MB) {
    Write-Output 'Downloading (EnterpriseDB blocks winget; using PowerShell instead)...'
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) WinForge/1.0')
    try {
        $wc.DownloadFile($url, $installer)
    } finally {
        $wc.Dispose()
    }
} else {
    Write-Output 'Using cached installer from a previous attempt.'
}

$file = Get-Item -LiteralPath $installer -ErrorAction SilentlyContinue
if ($null -eq $file -or $file.Length -lt 1MB) {
    throw "Download failed or file too small: $installer"
}
Write-Output ("Installer size: {0:N1} MB" -f ($file.Length / 1MB))

# Must satisfy Windows password complexity (upper + lower + digit + symbol).
$alphabet = [char[]]((48..57) + (65..90) + (97..122))
$superPassword = (-join (1..18 | ForEach-Object { $alphabet | Get-Random })) + '#A1'
Write-Output ''
Write-Output '================================================================'
Write-Output " PostgreSQL superuser password (save this): $superPassword"
Write-Output ' User: postgres   Port: 5432'
Write-Output '================================================================'
Write-Output ''

# Option file avoids Start-Process quoting bugs (comma locales, spaces in paths).
$optFile = Join-Path $workDir 'options.txt'
$debugLog = Join-Path $workDir 'install-debug.log'
$dataDir = Join-Path $env:ProgramData "PostgreSQL\$major\data"
if (-not (Test-Path -LiteralPath (Split-Path $dataDir))) {
    New-Item -ItemType Directory -Path (Split-Path $dataDir) -Force | Out-Null
}

$optLines = @(
    'mode=unattended'
    'unattendedmodeui=none'
    "prefix=$prefix"
    "datadir=$dataDir"
    "superpassword=$superPassword"
    "servicepassword=$superPassword"
    'superaccount=postgres'
    "servicename=postgresql-x64-$major"
    'serverport=5432'
    'install_runtimes=1'
    'create_shortcuts=0'
    'enable_acledit=1'
    'enable-components=server,commandlinetools'
    'disable-components=pgAdmin,stackbuilder'
)
$optLines | Set-Content -LiteralPath $optFile -Encoding ASCII
Write-Output "Wrote option file: $optFile"
Write-Output "Data directory: $dataDir"

# cmd.exe keeps the whole command line intact for InstallBuilder.
$argLine = "--optionfile `"$optFile`" --debuglevel 4 --debugtrace `"$debugLog`""
Write-Output "Running: `"$installer`" $argLine"
$proc = Start-Process -FilePath $installer -ArgumentList $argLine -Wait -PassThru -WindowStyle Hidden
$exitCode = $proc.ExitCode

function Write-InstallerLogs {
    $candidates = @(
        $debugLog
        (Join-Path $env:TEMP 'install-postgresql.log')
        (Join-Path $env:TEMP 'installbuilder_installer.log')
    )
    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $info = Get-Item -LiteralPath $path
        if ($info.Length -le 0) { continue }
        Write-Output ''
        Write-Output "----- $(Split-Path $path -Leaf) -----"
        Get-Content -LiteralPath $path -Tail 80 -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
    }
}

if ($exitCode -ne 0) {
    Write-InstallerLogs
    throw "PostgreSQL installer exited with code $exitCode"
}

if (-not (Test-Path -LiteralPath $psql)) {
    Write-InstallerLogs
    throw "Installer reported success but psql.exe was not found under $binDir"
}

if (Add-ToSystemPath -Directory $binDir -Scope 'Machine') {
    Write-Output "Added $binDir to PATH"
} else {
    Write-Output 'PostgreSQL bin was already on PATH'
}

$svc = Get-Service -Name "postgresql-x64-$major" -ErrorAction SilentlyContinue
if ($null -ne $svc) {
    Write-Output "Service $($svc.Name): $($svc.Status)"
}

Write-Output ''
Write-Output "PostgreSQL $major installed. Open a new terminal, then: psql -U postgres"
Write-Output 'Remember the password printed above — it is not stored by WinForge.'
