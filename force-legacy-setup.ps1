#Requires -Version 5.1
<#
.SYNOPSIS
    Forces the LEGACY Windows Setup on a Windows 11 24H2/25H2 install USB, so the
    autounattend.xml windowsPE pass (language/keyboard skip) is honoured.

.DESCRIPTION
    Since 24H2, WinPE launches the new "ConX" setup (SetupPrep.exe via SetupHost.exe),
    which can IGNORE the windowsPE locale settings and stop on the language/region and
    keyboard screens even with a correct answer file. This script edits the media's
    boot.wim so WinPE launches the OLD setup.exe instead, which honours the whole
    windowsPE pass.

    HOW: boot.wim holds two images - index 1 (WinPE) and index 2 (Windows Setup). The
    command WinPE runs at boot is read from the offline registry value
    HKLM\SYSTEM\Setup\CmdLine inside index 2. Setting it to "X:\sources\setup.exe"
    (X: is the WinPE RAM drive at runtime) makes WinPE run the legacy setup.exe; the new
    SetupPrep.exe/SetupHost.exe chain exits and control falls back to setup.exe.

    >>> ONLY needed if a matching-language (pt-BR) ISO alone does NOT remove the two
        screens. Community-reported, MEDIUM confidence - TEST in a VM before production
        (same caution as guard-disk.cmd). See README "Troubleshooting".

.PARAMETER UsbDrive
    USB drive letter (e.g. E or E:) OR a full path to boot.wim. If a drive letter, the
    script targets <drive>\sources\boot.wim.

.PARAMETER MountDir
    Empty scratch folder to mount the image into. Defaults to a temp folder.

.PARAMETER Index
    boot.wim image index to edit. Default 2 ("Windows Setup").

.EXAMPLE
    # Run from an ADMINISTRATOR PowerShell (DISM mount needs elevation):
    powershell -ExecutionPolicy Bypass -File .\force-legacy-setup.ps1 -UsbDrive E
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$UsbDrive,
    [string]$MountDir,
    [int]$Index = 2
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# DISM image mount and offline-registry edits require elevation. Fail early with a clear
# message instead of a confusing DISM access-denied halfway through.
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as Administrator (DISM mount + offline registry edit need elevation).'
}

# Resolve the boot.wim path: accept a full .wim path, or a drive letter (-> \sources\boot.wim).
if ($UsbDrive -match '\.wim$') {
    $bootWim = $UsbDrive
} else {
    $driveLetter = $UsbDrive.TrimEnd(':', '\')
    $bootWim = Join-Path "${driveLetter}:\" 'sources\boot.wim'
}
if (-not (Test-Path $bootWim)) {
    throw "boot.wim not found: $bootWim  (is this the burned Windows install USB?)"
}

if (-not $MountDir) { $MountDir = Join-Path $env:TEMP 'win11_bootwim_mount' }
if (-not (Test-Path $MountDir)) { New-Item -ItemType Directory -Path $MountDir | Out-Null }

# Rufus writes boot.wim read-only; DISM cannot mount it read-write until that is cleared.
$wimItem = Get-Item -LiteralPath $bootWim -Force
if ($wimItem.IsReadOnly) { Set-ItemProperty -LiteralPath $bootWim -Name IsReadOnly -Value $false }

# Back up the USB's ONLY boot.wim before editing it in place (audit A13): DISM commits the image in
# place, so an interrupted Dismount -Save can corrupt the sole boot.wim on the media. Keep a .bak
# (written once, so a re-run never overwrites a good backup with an already-damaged image).
$bootWimBak = "$bootWim.bak"
if (-not (Test-Path -LiteralPath $bootWimBak)) {
    Write-Host "Backing up boot.wim -> $bootWimBak ..." -ForegroundColor Cyan
    Copy-Item -LiteralPath $bootWim -Destination $bootWimBak -Force
}

$hiveKey  = 'HKLM\WIN_OFFLINE_SYSTEM'   # arbitrary temporary mount point for the offline hive
$mounted  = $false
$hiveLoad = $false

try {
    Write-Host "Mounting $bootWim (index $Index) -> $MountDir ..." -ForegroundColor Cyan
    Mount-WindowsImage -ImagePath $bootWim -Index $Index -Path $MountDir | Out-Null
    $mounted = $true

    $offlineSystem = Join-Path $MountDir 'Windows\System32\config\SYSTEM'
    if (-not (Test-Path $offlineSystem)) {
        throw "Offline SYSTEM hive not found at $offlineSystem (wrong index? try -Index 1)."
    }

    # reg.exe is used because there is no simple native cmdlet to edit a loaded offline hive.
    Write-Host 'Loading offline SYSTEM hive and setting Setup\CmdLine = X:\sources\setup.exe ...' -ForegroundColor Cyan
    & reg.exe load $hiveKey $offlineSystem | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load failed (exit $LASTEXITCODE)." }
    $hiveLoad = $true

    & reg.exe add "$hiveKey\Setup" /v CmdLine /t REG_SZ /d 'X:\sources\setup.exe' /f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg add failed (exit $LASTEXITCODE)." }

    # The hive MUST be unloaded before dismounting, or DISM cannot commit (file in use).
    & reg.exe unload $hiveKey | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg unload failed (exit $LASTEXITCODE)." }
    $hiveLoad = $false

    Write-Host 'Committing and unmounting ...' -ForegroundColor Cyan
    Dismount-WindowsImage -Path $MountDir -Save | Out-Null
    $mounted = $false

    Write-Host ''
    Write-Host "OK: legacy setup forced on $bootWim (index $Index)." -ForegroundColor Green
    Write-Host 'TEST the USB in a VM before using it in production.' -ForegroundColor Yellow
}
catch {
    # Best-effort cleanup so a failed run does not leave the hive loaded or the image mounted
    # (an orphaned mount blocks the scratch dir and future mounts until cleaned).
    if ($hiveLoad) { & reg.exe unload $hiveKey 2>$null | Out-Null }
    if ($mounted)  { Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction SilentlyContinue | Out-Null }
    throw
}
