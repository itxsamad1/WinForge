Write-Host 'Repairing winget...'
winget source reset --force 2>&1 | Out-Null
winget source update 2>&1 | Out-Null
Write-Host 'Done.' -ForegroundColor Green
