@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0JTL-DHL-PrintAgent.ps1"
pause
