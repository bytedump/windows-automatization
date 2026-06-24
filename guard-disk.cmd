@echo off
rem ============================================================
rem guard-disk.cmd - Abort the installation if more than 1 fixed disk exists.
rem ============================================================
rem The target machine has a SINGLE disk. If there is more than one, the
rem autounattend.xml DiskID=0 is not deterministic and may wipe the wrong disk.
rem This guard counts the disks and, if > 1, SHUTS DOWN the machine before the wipe.
rem
rem Runs in Windows PE (windowsPE pass). Uses diskpart because, in the default
rem Setup boot.wim, PowerShell and WMIC are NOT available (verified).
rem wpeutil shutdown ends the WinPE session cleanly (installs nothing).
rem
rem >>> NOT enabled by default. See README ("Disk guard") for the wiring in
rem     autounattend.xml. BEFORE relying on it, TEST in a VM with 2 disks:
rem       - the media drive letter in WinPE is not fixed (where this .cmd is called);
rem       - parsing depends on the WinPE language (pt-BR "Disco" / EN "Disk");
rem       - the RunSynchronous vs wipe ordering is not guaranteed by Microsoft.
rem ============================================================
setlocal
set "TMP_LD=%TEMP%\guard_ld.txt"
set "TMP_OUT=%TEMP%\guard_out.txt"

echo list disk> "%TMP_LD%"
diskpart /s "%TMP_LD%" > "%TMP_OUT%"

rem Count lines that are a disk: "Disco N" (pt-BR) or "Disk N" (EN).
set "COUNT=0"
for /f %%C in ('findstr /i /r /c:"Disco [0-9][0-9]*" /c:"Disk [0-9][0-9]*" "%TMP_OUT%" ^| find /c /v ""') do set "COUNT=%%C"

if %COUNT% GTR 1 (
    echo.
    echo ====================================================
    echo  ABORTING: %COUNT% fixed disks found. Expected: 1.
    echo  Risk of wiping the wrong disk. Shutting the machine down...
    echo ====================================================
    wpeutil shutdown
    exit /b 1
)

echo guard-disk: %COUNT% disk(s) detected - OK, continuing the installation.
exit /b 0
