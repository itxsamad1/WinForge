@echo off
setlocal
cd /d "%~dp0..\.."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Sandbox.ps1" %*
if errorlevel 1 pause
endlocal
