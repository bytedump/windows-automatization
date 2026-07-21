#Requires -Version 5.1
param(
    # Mode forwarded to bootstrap.ps1's auto-run (LogonCommand). Default = interactive GUI.
    # -Headless: automated setup assertion (no GUI). -PhaseB: two-phase handoff smoke (stage ->
    # Phase B -> cleanup) with its own PASS/FAIL, which also covers the bookmark seeding + wallpaper.
    [switch]$Headless,
    [switch]$PhaseB
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# prep.ps1 — Prepares and opens Windows Sandbox for testing
# Run on Windows (native PowerShell, NOT WSL)
# ============================================================
# Usage: powershell.exe -ExecutionPolicy Bypass -File prep.ps1

$repoRoot   = Split-Path $PSScriptRoot -Parent
$stagingDir = "C:\SandboxTest"
$scriptsOut = "$stagingDir\scripts"
$testsOut   = "$stagingDir\tests"

Write-Host ""
Write-Host "  ======================================" -ForegroundColor Cyan
Write-Host "   PREPARING THE TEST SANDBOX" -ForegroundColor Cyan
Write-Host "  ======================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Source repo : $repoRoot" -ForegroundColor Yellow
Write-Host "  Staging     : $stagingDir" -ForegroundColor Yellow
Write-Host ""

# --- Clean up and recreate the staging dir ---
Write-Host "  [1/4] Creating the staging directory..." -ForegroundColor White
if (Test-Path $stagingDir) {
    Remove-Item $stagingDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $scriptsOut | Out-Null
New-Item -ItemType Directory -Force -Path $testsOut  | Out-Null

# --- Copy the repo scripts (excluding what must not reach the simulated USB) ---
Write-Host "  [2/4] Copying the repo scripts..." -ForegroundColor White
$excludeDirs = @('tests', '.git', 'CloudAgent', 'signatures-2026')
$excludeFiles = @('config.ps1', 'printers.json')   # config.ps1: real credentials. printers.json: internal production IPs — usb-sim ships the test fixture

Get-ChildItem -Path $repoRoot | Where-Object {
    $_.Name -notin $excludeDirs -and $_.Name -notin $excludeFiles
} | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $scriptsOut -Recurse -Force
    Write-Host "        copied: $($_.Name)" -ForegroundColor DarkGray
}

# --- Copy the test fixtures ---
Write-Host "  [3/4] Copying the test fixtures..." -ForegroundColor White
Copy-Item -Path "$PSScriptRoot\*" -Destination $testsOut -Recurse -Force
Write-Host "        copied: tests/" -ForegroundColor DarkGray

# --- Generate sandbox.wsb with the correct absolute paths ---
Write-Host "  [4/4] Generating sandbox.wsb..." -ForegroundColor White
# Forward the selected mode to bootstrap's auto-run at login (default = interactive GUI).
$bootArgs = if ($PhaseB) { ' -PhaseB' } elseif ($Headless) { ' -Headless' } else { '' }
$wsbContent = @"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$scriptsOut</HostFolder>
      <SandboxFolder>C:\Scripts</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$testsOut</HostFolder>
      <SandboxFolder>C:\Tests</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>cmd.exe /c "ping -n 20 127.0.0.1 >nul &amp;&amp; start &quot;Bootstrap&quot; powershell.exe -NoExit -ExecutionPolicy Bypass -File C:\Tests\bootstrap.ps1$bootArgs"</Command>
  </LogonCommand>
</Configuration>
"@

$wsbPath = "$stagingDir\sandbox.wsb"
Set-Content -Path $wsbPath -Value $wsbContent -Encoding UTF8
Write-Host "        generated: $wsbPath" -ForegroundColor DarkGray

Write-Host ""
Write-Host "  Done! Opening Windows Sandbox..." -ForegroundColor Green
Write-Host "  bootstrap.ps1 will run automatically on login." -ForegroundColor Green
if ($PhaseB) {
    Write-Host "  Mode: -PhaseB (two-phase handoff smoke). It asserts staging + Phase B (bookmarks" -ForegroundColor Green
    Write-Host "  seeded loose on the bar in Chrome/Edge, wallpaper override) + cleanup, then prints" -ForegroundColor Green
    Write-Host "  PHASE B SMOKE: PASSED/FAILED." -ForegroundColor Green
} elseif ($Headless) {
    Write-Host "  Mode: -Headless (automated setup assertion, no GUI). Prints RESULT: PASSED/FAILED." -ForegroundColor Green
} else {
    Write-Host "  Mode: interactive GUI (production-like): fill the form and click Start; at the end" -ForegroundColor Green
    Write-Host "  it prints RESULT: PASSED/FAILED. (-Headless or -PhaseB run automated assertions.)" -ForegroundColor Green
}
Write-Host ""
Write-Host "  Test log: C:\Users\WDAGUtilityAccount\Desktop\win11_setup_log.txt" -ForegroundColor Yellow
Write-Host ""

Start-Process $wsbPath
