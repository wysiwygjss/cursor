@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0v3.ps1" -startIndex 7790 -autoSubSize -hoursPerSub 2 -saveIntervalHours 2 %*
pause
