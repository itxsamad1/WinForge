<#
    Applies the global Git identity and a few defaults that avoid the usual
    first-day-on-Windows papercuts. Everything here is optional: with no
    identity supplied the script only sets the safe defaults.
#>
param($Context, $Options)

Update-PathFromRegistry

$git = Get-Command 'git' -ErrorAction SilentlyContinue
if ($null -eq $git) {
    throw 'git was not found on PATH.'
}

$name = Get-Prop $Options 'gitName'
$email = Get-Prop $Options 'gitEmail'

if (-not [string]::IsNullOrWhiteSpace($name)) {
    & git config --global user.name $name
    Write-Output "Set user.name to $name"
} else {
    Write-Output 'No name supplied, leaving user.name unset.'
}

if (-not [string]::IsNullOrWhiteSpace($email)) {
    & git config --global user.email $email
    Write-Output "Set user.email to $email"
} else {
    Write-Output 'No email supplied, leaving user.email unset.'
}

& git config --global init.defaultBranch main
Write-Output 'Set init.defaultBranch to main'

# input = commit LF, check out as-is. Avoids the CRLF churn that "true" causes
# in repos shared with macOS and Linux machines.
& git config --global core.autocrlf input
Write-Output 'Set core.autocrlf to input'

& git config --global core.longpaths true
Write-Output 'Enabled long path support'

& git config --global pull.rebase false
Write-Output 'Set pull.rebase to false'

$version = & git --version 2>&1
Write-Output $version
