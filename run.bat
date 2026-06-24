@echo off
chcp 65001 >nul
echo Iniciando setup Windows 11...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
if %errorlevel% neq 0 (
    echo.
    echo ERRO: setup.ps1 finalizou com codigo %errorlevel%
    pause
)
