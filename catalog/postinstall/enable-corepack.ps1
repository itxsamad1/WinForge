<#
    Turns on corepack so "yarn" and "pnpm" work without a separate global
    install. Ships with Node, just disabled by default.
#>
param($Context, $Options)

Update-PathFromRegistry

$corepack = Get-Command 'corepack' -ErrorAction SilentlyContinue
if ($null -eq $corepack) {
    throw 'corepack was not found. Node may need a new terminal session before its bin directory is visible.'
}

Write-Output 'Enabling corepack (yarn and pnpm shims)...'
& corepack enable 2>&1 | ForEach-Object { Write-Output $_ }

if ($LASTEXITCODE -ne 0) {
    throw "corepack enable exited with code $LASTEXITCODE"
}

$node = & node --version 2>&1
$npm = & npm --version 2>&1
Write-Output "Node $node, npm $npm"
Write-Output 'corepack enabled. "yarn" and "pnpm" are now available.'
