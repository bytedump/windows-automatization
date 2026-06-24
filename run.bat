@echo off
chcp 65001 >nul
echo Starting Windows 11 setup...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
if %errorlevel% neq 0 (
    echo.
    echo ERROR: setup.ps1 exited with code %errorlevel%
    pause
)
