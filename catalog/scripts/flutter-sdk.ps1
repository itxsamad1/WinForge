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

if (Test-Path -LiteralPath (Join-Path $flutterBin 'flutter.bat')) {
    Write-Output "Flutter is already present at $flutterDir"
} else {
    $git = Get-Command 'git' -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        throw 'Git is required to install Flutter. Select Git in the catalog and run again.'
    }

    if (-not (Test-Path -LiteralPath $installRoot)) {
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    }

    Write-Output "Cloning the Flutter stable channel into $flutterDir (about 1 GB)..."
    # A shallow clone keeps this to a few minutes; Flutter only needs the
    # working tree, not the full history.
    & git clone --depth 1 --branch stable https://github.com/flutter/flutter.git $flutterDir 2>&1 |
        ForEach-Object { Write-Output $_ }

    if ($LASTEXITCODE -ne 0) {
        throw "git clone failed with exit code $LASTEXITCODE"
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
& (Join-Path $flutterBin 'flutter.bat') --version 2>&1 | ForEach-Object { Write-Output $_ }

Write-Output ''
Write-Output 'Next: run "flutter doctor" in a new terminal. It will list any remaining'
Write-Output 'steps, such as accepting the Android SDK licences.'
