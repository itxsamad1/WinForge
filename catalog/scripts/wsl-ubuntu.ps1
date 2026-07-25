<#
    Installs WSL with the default Ubuntu distribution.

    "kind": "script" apps run one of these instead of a winget package, for
    things winget cannot express. Same contract as post-install scripts.
#>
param($Context, $Options)

$wsl = Get-Command 'wsl' -ErrorAction SilentlyContinue
if ($null -eq $wsl) {
    throw 'wsl.exe was not found. This requires Windows 10 build 19041 or newer.'
}

Write-Output 'Installing WSL with Ubuntu. This enables Windows features and may take a few minutes.'

# --no-launch keeps the install non-interactive; without it wsl.exe drops into
# the distro's username prompt and the job would hang forever.
& wsl --install -d Ubuntu --no-launch 2>&1 | ForEach-Object { Write-Output $_ }
$code = $LASTEXITCODE

if ($code -ne 0) {
    # Already-installed is reported as a failure by some builds; treat a
    # present distribution as success.
    $installed = & wsl --list --quiet 2>&1 | Out-String
    if ($installed -match 'Ubuntu') {
        Write-Output 'Ubuntu is already installed.'
    } else {
        throw "wsl --install exited with code $code"
    }
}

Write-Output ''
Write-Output 'Reboot required. After restarting, run "wsl" once to create your Linux user account.'
