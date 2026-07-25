<#
    Installs Google's Gemini CLI via npm.
    Not published to winget, so this is the documented install path.
#>
param($Context, $Options)

Update-PathFromRegistry

$npm = Get-Command 'npm' -ErrorAction SilentlyContinue
if ($null -eq $npm) {
    throw 'npm was not found. Install Node.js (or nvm) first, open a new terminal, then retry.'
}

Write-Output 'Installing @google/gemini-cli globally...'
& npm install -g @google/gemini-cli 2>&1 | ForEach-Object { Write-Output $_ }

if ($LASTEXITCODE -ne 0) {
    throw "npm install failed with exit code $LASTEXITCODE"
}

Update-PathFromRegistry
$gemini = Get-Command 'gemini' -ErrorAction SilentlyContinue
if ($null -ne $gemini) {
    Write-Output "Gemini CLI ready: $($gemini.Source)"
} else {
    Write-Output 'Installed. Open a new terminal and run "gemini" if the command is not visible yet.'
}
