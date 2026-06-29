@echo off
rem ============================================================
rem guard-disk.cmd - FAIL-CLOSED disk guard for the autounattend wipe.
rem ============================================================
rem autounattend.xml wipes DiskID=0, which is NOT deterministic when more than one FIXED disk is
rem present - it may wipe the wrong one. This guard runs in the windowsPE pass BEFORE
rem DiskConfiguration and proceeds ONLY when it confirms EXACTLY one FIXED disk. On any other
rem outcome (0 parsed, >1, or a tooling failure) it shuts the machine down (wpeutil shutdown)
rem before anything is wiped - failing CLOSED, not open.
rem
rem Counts FIXED disks only (MediaType='Fixed hard disk media'), so the boot USB stick - which
rem enumerates as a REMOVABLE disk - is excluded and does not trip the "exactly 1" check. Optical
rem (DVD) media is never a Win32_DiskDrive, so DVD/PXE boot is fine too.
rem
rem Tooling: WMIC is the source of truth (locale-independent, and it carries the MediaType filter).
rem The Win11 25H2 Setup boot.wim ships WMIC but NOT findstr and NOT PowerShell (verified in a VM -
rem an earlier findstr-based version always counted 0 and aborted every install). If WMIC is ever
rem absent, the fallback counts ALL disks via diskpart + find (no findstr): it cannot tell fixed
rem from removable, so a USB-boot there counts 2 and fails CLOSED - safe by design.
rem
rem On the "exactly 1" success path it writes %TEMP%\guard_ok.flag. A second RunSynchronous command
rem in autounattend.xml shuts down if that marker is absent - so even if this .cmd is missing from
rem the media (never called), the install still fails closed.
rem
rem >>> TEST in a VM (1 disk = proceeds; 2 disks = aborts) before relying on it: the
rem     RunSynchronous-vs-wipe ordering is not contractually guaranteed by Microsoft. To disable,
rem     remove the two guard RunSynchronous commands from autounattend.xml (see README "Disk guard").
rem ============================================================
setlocal enableextensions enabledelayedexpansion
set "FLAG=%TEMP%\guard_ok.flag"
del /q "%FLAG%" 2>nul

set "COUNT=0"
if exist "%SystemRoot%\System32\wbem\wmic.exe" (
    rem Primary: count FIXED disks only (excludes the removable boot USB and optical media).
    for /f "usebackq" %%C in (`wmic diskdrive where "MediaType='Fixed hard disk media'" get index /value 2^>nul ^| find /c "Index="`) do set "COUNT=%%C"
) else (
    rem Fallback: no WMIC - count ALL disks via diskpart + find (boot.wim has no findstr). Sums the
    rem localized "disk" word across common WinPE languages (EN/pt/es/it/fr/de) and subtracts the 1
    rem header row that also carries it. Cannot exclude removable media, so USB-boot here counts 2
    rem and fails closed. autounattend forces pt-BR WinPE.
    echo list disk> "%TEMP%\guard_ld.txt"
    diskpart /s "%TEMP%\guard_ld.txt" > "%TEMP%\guard_out.txt" 2>&1
    if errorlevel 1 (
        echo guard-disk: diskpart failed - aborting for safety.
        wpeutil shutdown
        exit /b 1
    )
    set "T=0"
    for /f %%C in ('type "%TEMP%\guard_out.txt" ^| find /i /c "Disco "') do set /a T+=%%C
    for /f %%C in ('type "%TEMP%\guard_out.txt" ^| find /i /c "Disk "') do set /a T+=%%C
    for /f %%C in ('type "%TEMP%\guard_out.txt" ^| find /i /c "Disque "') do set /a T+=%%C
    for /f %%C in ('type "%TEMP%\guard_out.txt" ^| find /i /c "Datentr"') do set /a T+=%%C
    if !T! geq 1 ( set /a COUNT=T-1 ) else ( set "COUNT=0" )
)

rem FAIL-CLOSED: proceed only when exactly 1 fixed disk is detected.
rem   0  = could not verify (tooling/locale parse failure) -> abort
rem   >1 = multi-disk, DiskID=0 is ambiguous                -> abort
if not "!COUNT!"=="1" (
    echo.
    echo ====================================================
    echo  ABORTING: detected !COUNT! fixed disk^(s^); expected exactly 1.
    echo  0 = could not verify  ^|  ^>1 = multi-disk.
    echo  Refusing to wipe to avoid hitting the wrong disk. Shutting down...
    echo ====================================================
    wpeutil shutdown
    exit /b 1
)

rem Exactly one fixed disk: record the marker and let the install proceed.
echo ok> "%FLAG%"
echo guard-disk: exactly 1 fixed disk detected - OK, continuing the installation.
exit /b 0
