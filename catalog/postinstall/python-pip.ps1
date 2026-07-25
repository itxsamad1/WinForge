<#
    Upgrades pip and confirms the py launcher works.
#>
param($Context, $Options)

Update-PathFromRegistry

$python = $null
foreach ($candidate in @('py', 'python')) {
    $command = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($null -ne $command) { $python = $command.Source; break }
}

if ($null -eq $python) {
    throw 'Python was not found on PATH. Open a new terminal and try "python --version".'
}

Write-Output "Using $python"
& $python --version 2>&1 | ForEach-Object { Write-Output $_ }

Write-Output 'Upgrading pip...'
& $python -m pip install --upgrade pip 2>&1 | ForEach-Object { Write-Output $_ }

if ($LASTEXITCODE -ne 0) {
    Write-Output "pip upgrade exited with code $LASTEXITCODE (not fatal)."
}

# The user Scripts directory holds console entry points from "pip install --user"
# and is frequently missing from PATH after a fresh Python install.
$userBase = (& $python -c "import site,sys; sys.stdout.write(site.USER_BASE)" 2>$null)
if (-not [string]::IsNullOrWhiteSpace($userBase)) {
    $scriptsDir = Join-Path $userBase 'Scripts'
    if (Test-Path -LiteralPath $scriptsDir) {
        if (Add-ToSystemPath -Directory $scriptsDir -Scope 'User') {
            Write-Output "Added $scriptsDir to PATH"
        }
    }
}

Write-Output 'Python is ready.'
