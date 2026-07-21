@echo off
chcp 65001 >nul
echo Collecting machine info...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect-machine-info.ps1"
if %errorlevel% neq 0 (
    echo.
    echo ERROR: collect-machine-info.ps1 exited with code %errorlevel%
    pause
)
