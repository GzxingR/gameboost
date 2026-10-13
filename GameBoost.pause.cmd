@echo off
chcp 65001 >nul
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pause-non-system-processes.ps1" %*
if "%~1"=="" pause
endlocal
