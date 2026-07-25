<#
    Installs the latest Node LTS through nvm and makes it the active version.
    Without this, nvm is installed but "node" still is not a command.
#>
param($Context, $Options)

Update-PathFromRegistry

$nvm = Get-Command 'nvm' -ErrorAction SilentlyContinue
if ($null -eq $nvm) {
    # nvm's installer writes NVM_HOME but the running process may still not see
    # it on PATH, so fall back to the documented install location.
    $fallback = Join-Path $env:APPDATA 'nvm\nvm.exe'
    if (Test-Path -LiteralPath $fallback) {
        $nvmPath = $fallback
    } else {
        throw 'nvm was not found on PATH. Open a new terminal and run "nvm install lts" manually.'
    }
} else {
    $nvmPath = $nvm.Source
}

Write-Output "Using nvm at $nvmPath"

Write-Output 'Installing the latest Node LTS (this downloads ~30 MB)...'
& $nvmPath install lts 2>&1 | ForEach-Object { Write-Output $_ }

# "nvm use lts" is rejected by some nvm builds, so resolve the concrete version
# from the install list and switch to that.
$listOutput = & $nvmPath list 2>&1 | Out-String
$versions = [regex]::Matches($listOutput, '\d+\.\d+\.\d+') | ForEach-Object { $_.Value }

if ($versions.Count -eq 0) {
    Write-Output 'Could not determine the installed Node version; run "nvm use <version>" yourself.'
    return
}

$newest = $versions |
    Sort-Object -Property { [version]$_ } -Descending |
    Select-Object -First 1

Write-Output "Activating Node $newest"
& $nvmPath use $newest 2>&1 | ForEach-Object { Write-Output $_ }

Update-PathFromRegistry
Write-Output "Node $newest is now the active version."
