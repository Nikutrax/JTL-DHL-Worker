@echo off
setlocal
if "%~1"=="" (
  echo Bitte CSV-Dateiname aus dem Exportordner als Argument angeben.
  exit /b 2
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0JTL-DHL-Worker.ps1" -ConfigPath "%~dp0config.json" -ValidateOnly -SpecificFile "%~1"
exit /b %ERRORLEVEL%
