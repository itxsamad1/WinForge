$path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
Set-ItemProperty -Path $path -Name 'PauseFeatureUpdatesStartTime' -Value ([datetime]::Now.ToString('yyyy-MM-ddTHH:mm:ss')) -Force
Set-ItemProperty -Path $path -Name 'PauseFeatureUpdatesEndTime' -Value ([datetime]::Now.AddDays(35).ToString('yyyy-MM-ddTHH:mm:ss')) -Force
Set-ItemProperty -Path $path -Name 'PauseQualityUpdatesStartTime' -Value ([datetime]::Now.ToString('yyyy-MM-ddTHH:mm:ss')) -Force
Set-ItemProperty -Path $path -Name 'PauseQualityUpdatesEndTime' -Value ([datetime]::Now.AddDays(35).ToString('yyyy-MM-ddTHH:mm:ss')) -Force
