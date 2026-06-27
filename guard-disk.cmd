@echo off
rem ============================================================
rem guard-disk.cmd - FAIL-CLOSED disk guard for the autounattend wipe.
rem ============================================================
rem The target machine has a SINGLE fixed disk. autounattend.xml wipes DiskID=0, which is NOT
rem deterministic when more than one disk is present - it may wipe the wrong one. This guard runs
rem in the windowsPE pass BEFORE DiskConfiguration and proceeds ONLY when it can confirm EXACTLY
rem one disk. On any other outcome (0 disks parsed, >1 disk, or diskpart failure) it shuts the
rem machine down (wpeutil shutdown) before anything is wiped - failing CLOSED, not open.
rem
rem On the "exactly 1" success path it writes a marker (%TEMP%\guard_ok.flag). A second
rem RunSynchronous command in autounattend.xml shuts down if the marker is absent - so even if
rem this .cmd is missing from the media (never called), the install still fails closed.
rem
rem Uses diskpart because the default Setup boot.wim has no PowerShell/WMIC (verified). Disk-row
rem counting covers the common WinPE languages (EN/pt/es/it/fr/de); autounattend forces pt-BR WinPE.
rem
rem >>> TEST in a VM with 2 disks before relying on it: the RunSynchronous-vs-wipe ordering is not
rem     contractually guaranteed by Microsoft. To disable, remove the two guard RunSynchronous
rem     commands from autounattend.xml (see README "Disk guard").
rem ============================================================
setlocal enableextensions
set "TMP_LD=%TEMP%\guard_ld.txt"
set "TMP_OUT=%TEMP%\guard_out.txt"
set "FLAG=%TEMP%\guard_ok.flag"

rem Clear any stale marker from a previous attempt.
del /q "%FLAG%" 2>nul

echo list disk> "%TMP_LD%"
diskpart /s "%TMP_LD%" > "%TMP_OUT%" 2>&1
if errorlevel 1 (
    echo guard-disk: diskpart failed - aborting for safety.
    wpeutil shutdown
    exit /b 1
)

rem Count disk rows: localized disk word + a digit. The "Disk ###" / "Disco ###" headers do not
rem match (### is not a digit), so only real disk lines are counted.
set "COUNT=0"
for /f %%C in ('findstr /i /r /c:"Disk [0-9]" /c:"Disco [0-9]" /c:"Disque [0-9]" /c:"Datentr.ger [0-9]" "%TMP_OUT%" ^| find /c /v ""') do set "COUNT=%%C"

rem FAIL-CLOSED: proceed only when exactly 1 fixed disk is detected.
rem   0  = could not verify (diskpart/locale parse failure) -> abort
rem   >1 = multi-disk, DiskID=0 is ambiguous                -> abort
if not "%COUNT%"=="1" (
    echo.
    echo ====================================================
    echo  ABORTING: detected %COUNT% disk^(s^); expected exactly 1.
    echo  0 = could not verify  ^|  ^>1 = multi-disk.
    echo  Refusing to wipe to avoid hitting the wrong disk. Shutting down...
    echo ====================================================
    wpeutil shutdown
    exit /b 1
)

rem Exactly one disk: record the marker and let the install proceed.
echo ok> "%FLAG%"
echo guard-disk: exactly 1 disk detected - OK, continuing the installation.
exit /b 0
