@echo off
REM ============================================================
REM  run-sandbox.bat - one-click Windows Sandbox test launcher
REM ============================================================
REM  Path-agnostic: works no matter WHERE this repo lives
REM  (a WSL share \\wsl.localhost\<distro>\... or a normal
REM  Windows folder like C:\projects\...). %~dp0 = this file's
REM  own folder, so prep.ps1 is always found next to it.
REM
REM  Self-elevating: prep.ps1 needs admin (it creates
REM  C:\SandboxTest). If you are not admin yet, it re-launches
REM  itself with a UAC prompt.
REM
REM  Usage: just double-click this file. That's it.
REM ============================================================

setlocal

REM --- are we admin? ('net session' only works elevated) ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights ^(UAC prompt^)...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo  Running the Sandbox prep from:
echo    %~dp0
echo.

REM -File takes the ABSOLUTE path, so the working directory does
REM not matter (UAC may reset it to C:\Windows\System32).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0prep.ps1"

echo.
echo  Done. The Sandbox window should be open and running the test.
pause
