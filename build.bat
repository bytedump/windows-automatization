@echo off
chcp 65001 >nul
echo Running the USB config wizard (config.ps1 + autounattend.xml)...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-usb.ps1" -GenerateConfig -OutPath "%~dp0autounattend.xml"
echo.
echo ----------------------------------------------------------
echo Done. Read the messages above (errors stay on screen).
pause
