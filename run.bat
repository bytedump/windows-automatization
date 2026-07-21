@echo off
chcp 65001 >nul
echo Starting Windows 11 setup...
rem -EnableHandoff matches the production boot path (autounattend FirstLogonCommands): without it
rem a manual recovery run would finish Phase A but never stage Phase B, arm AutoLogon or reboot
rem (audit C4).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -EnableHandoff
if %errorlevel% neq 0 (
    echo.
    echo ERROR: setup.ps1 exited with code %errorlevel%
    pause
)
