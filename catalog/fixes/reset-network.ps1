Write-Host 'Resetting network stack...'
ipconfig /flushdns | Out-Null
netsh winsock reset | Out-Null
netsh int ip reset | Out-Null
Write-Host 'Done. Reboot recommended.' -ForegroundColor Yellow
