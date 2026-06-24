@echo off
chcp 65001 >nul
echo Generating autounattend.xml from the template...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-usb.ps1"
echo.
echo ----------------------------------------------------------
echo Done. Read the messages above (errors stay on screen).
pause
