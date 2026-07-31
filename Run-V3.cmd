@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0v3.ps1" -startIndex 7790 -saveIntervalHours 6 %*
pause
