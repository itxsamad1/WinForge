<#
    Installs the Flutter SDK.

    Google does not publish Flutter to winget, so this follows the documented
    manual route: clone the stable channel and put its bin directory on PATH.
#>
param($Context, $Options)

Update-PathFromRegistry

$installRoot = 'C:\src'
$flutterDir = Join-Path $installRoot 'flutter'
$flutterBin = Join-Path $flutterDir 'bin'
$flutterBat = Join-Path $flutterBin 'flutter.bat'

function Write-NativeLine {
    param($Item)
    # Native stderr becomes ErrorRecord under 2>&1; stringify so
    # $ErrorActionPreference Stop does not abort the install.
    Write-Output ([string]$Item)
}

function Invoke-Native {
    param([scriptblock]$Command)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command 2>&1 | ForEach-Object { Write-NativeLine $_ }
        return [int]$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
}

if (Test-Path -LiteralPath $flutterBat) {
    Write-Output "Flutter is already present at $flutterDir"
} else {
    $git = Get-Command 'git' -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        throw 'Git is required to install Flutter. Select Git in the catalog and run again.'
    }

    if (-not (Test-Path -LiteralPath $installRoot)) {
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    }

    # A previous failed run often leaves an incomplete tree that blocks clone.
    if (Test-Path -LiteralPath $flutterDir) {
        Write-Output "Removing incomplete Flutter folder at $flutterDir..."
        Remove-Item -LiteralPath $flutterDir -Recurse -Force -ErrorAction Stop
    }

    Write-Output "Cloning the Flutter stable channel into $flutterDir (about 1 GB)..."
    # A shallow clone keeps this to a few minutes; Flutter only needs the
    # working tree, not the full history.
    $cloneExit = Invoke-Native {
        git clone --depth 1 --branch stable https://github.com/flutter/flutter.git $flutterDir
    }

    if ($cloneExit -ne 0) {
        throw "git clone failed with exit code $cloneExit. Check network access to github.com, then retry."
    }
    if (-not (Test-Path -LiteralPath $flutterBat)) {
        throw "git clone finished but $flutterBat is missing. Delete $flutterDir and retry."
    }
}

if (Add-ToSystemPath -Directory $flutterBin -Scope 'User') {
    Write-Output "Added $flutterBin to PATH"
} else {
    Write-Output 'Flutter bin directory was already on PATH'
}

$env:Path = "$flutterBin;$env:Path"

# The first invocation downloads the bundled Dart SDK, so do it here rather
# than leaving a multi-minute stall for the user's first command.
Write-Output 'Running flutter --version to download the Dart SDK...'
$null = Invoke-Native { & $flutterBat --version }

Write-Output ''
Write-Output 'Next: run "flutter doctor" in a new terminal. It will list any remaining'
Write-Output 'steps, such as accepting the Android SDK licences.'
