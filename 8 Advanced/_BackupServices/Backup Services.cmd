@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Backup Services.ps1" %*
pause