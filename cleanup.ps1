#Requires -Version 5.1
<#
.SYNOPSIS
    Cleanup stage of the hands-free Win11 provisioning: machine-level teardown.

.DESCRIPTION
    Runs as a scheduled task under the SYSTEM principal (-AtLogOn). Its job is the
    machine-level teardown a standard user cannot do:

      - Close the AutoLogon brecha: the new user's password was written in plain text
        to HKLM ...\Winlogon (DefaultPassword) so the box could auto-log-on once after
        Phase A's reboot. THIS IS THE SECURITY PAYOFF. It runs FIRST (the secret has no
        reason to outlive this script) and is VERIFIED by read-back - the suppressed
        cmdlet return alone is not treated as proof.
      - Wait for Phase B (the per-user script) to drop its `user-done` flag, then
        unregister both Phase B scheduled tasks and delete C:\ProgramData\CorpSetup.

    Teardown (dropping the SYSTEM task + staging) only happens once the brecha is
    CONFIRMED closed; otherwise the task and staging are left so the next logon retries
    automatically. Everything is idempotent: a re-run after a partial failure converges.

    It deliberately does NOT disable the bootstrap admin account. With no Active
    Directory here, that local admin is the ONLY admin and the team relies on it for
    support; its password was already rotated to the real one by setup.ps1.

    The file helpers (Test-UserDoneFlag, Remove-StagingFolder, Save-PhaseBLogs) are
    dot-source testable via -LoadOnly; the registry/scheduled-task steps need a real
    machine and are validated on a VM.

.PARAMETER LoadOnly
    Define the functions and return before running cleanup. Test seam; never set in
    production.

.PARAMETER StateDir
    The staging folder Phase A created. Default: C:\ProgramData\CorpSetup.

.PARAMETER TimeoutSeconds
    How long to wait for Phase B's user-done flag before finishing anyway. Default: 900.

.PARAMETER PollSeconds
    Flag poll interval while waiting. Default: 5.
#>
[CmdletBinding()]
param(
    [switch]$LoadOnly,
    [string]$StateDir = (Join-Path $env:ProgramData 'CorpSetup'),
    [int]$TimeoutSeconds = 900,
    [int]$PollSeconds = 5
)
Set-StrictMode -Version Latest

# Contract shared with Phase A (3b), which registers these tasks under these exact
# names. Keep in sync. The user task is per-user (signature/wallpaper/printer); the
# system task is this cleanup.
$script:UserTaskName = 'CorpSetup-PhaseB-User'
$script:SystemTaskName = 'CorpSetup-PhaseB-System'

# Log to Windows\Temp, not StateDir - cleanup deletes StateDir, so its own log must
# live somewhere that survives.
$script:CleanupLogFile = $null

# ============================================================
# Logging
# ============================================================
function Write-CleanupLog {
    param(
        [ValidateSet('OK', 'INFO', 'WARN', 'ERROR')][string]$Level,
        [string]$Message
    )
    $line = '{0} {1,-5} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:CleanupLogFile) {
        try { Add-Content -LiteralPath $script:CleanupLogFile -Value $line -Encoding UTF8 } catch { }
    }
}

function Initialize-CleanupLog {
    try {
        $script:CleanupLogFile = Join-Path (Join-Path $env:WINDIR 'Temp') 'corp-cleanup.log'
    } catch {
        $script:CleanupLogFile = $null
    }
}

# ============================================================
# File helpers (unit-tested via -LoadOnly)
# ============================================================

# True when Phase B has dropped its completion flag.
function Test-UserDoneFlag {
    param([Parameter(Mandatory)][string]$StateDir)
    return (Test-Path -LiteralPath (Join-Path $StateDir 'user-done'))
}

# Recursively delete a tree WITHOUT following directory reparse points (junctions / symlinks).
# The staging folder is user-writable (inherited ProgramData ACL), so a standard user can plant a
# directory junction in it; Windows PowerShell 5.1 `Remove-Item -Recurse` traverses INTO junctions
# and would delete the TARGET's contents - a SYSTEM arbitrary-delete (this runs as the SYSTEM task).
# So first unlink every reparse-point directory (the walk skips them, never descends a link), then
# the now link-free tree is safe to remove recursively.
function Remove-TreeNoReparse {
    param([Parameter(Mandatory)][string]$Path)
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Path)
    $reparse = [System.Collections.Generic.List[string]]::new()
    while ($stack.Count) {
        $dir = $stack.Pop()
        foreach ($child in [System.IO.Directory]::GetDirectories($dir)) {
            if ([System.IO.File]::GetAttributes($child) -band [System.IO.FileAttributes]::ReparsePoint) {
                $reparse.Add($child)              # junction/symlink: unlink, never descend into it
            } else {
                $stack.Push($child)
            }
        }
    }
    foreach ($r in $reparse) { [System.IO.Directory]::Delete($r, $false) }   # remove the link only
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}

# Remove the staging folder. Idempotent: a no-op (returns $false) when already gone. Junction-safe
# (see Remove-TreeNoReparse) - the staging tree is user-writable and this deletes it as SYSTEM.
function Remove-StagingFolder {
    param([Parameter(Mandatory)][string]$StateDir)
    if (Test-Path -LiteralPath $StateDir) {
        Remove-TreeNoReparse -Path $StateDir
        return $true
    }
    return $false
}

# Preserve Phase B's per-user log before StateDir is deleted - it is the evidence a
# technician needs when provisioning ran but a step failed. Best-effort. DestRoot is a
# parameter so tests can redirect it away from the real Windows\Temp.
function Save-PhaseBLogs {
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [string]$DestRoot = (Join-Path $env:WINDIR 'Temp')
    )
    $src = Join-Path $StateDir 'logs'
    if (-not (Test-Path -LiteralPath $src)) { return $false }
    try {
        $dest = Join-Path $DestRoot 'corp-phaseb-logs'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        # Copy ONLY the flat *.log files Phase B writes - never -Recurse. The logs folder is
        # user-writable, so a recursive copy as SYSTEM would follow a planted directory junction and
        # read its target; -File excludes any reparse-point directory outright.
        $logs = @(Get-ChildItem -LiteralPath $src -File -Filter '*.log' -ErrorAction SilentlyContinue)
        if (-not $logs) { return $false }
        foreach ($f in $logs) { Copy-Item -LiteralPath $f.FullName -Destination $dest -Force }
        Write-CleanupLog OK "Phase B logs preserved -> $dest"
        return $true
    } catch {
        Write-CleanupLog WARN "Could not preserve Phase B logs: $($_.Exception.Message)"
        return $false
    }
}

# ============================================================
# Markers (persistent technician alerts that survive StateDir deletion)
# ============================================================

# Phase B never signaled completion: the machine is secure but per-user setup may be missing.
function Write-IncompleteMarker {
    param([Parameter(Mandatory)][string]$Reason)
    try {
        $marker = Join-Path (Join-Path $env:WINDIR 'Temp') 'CORP-PHASEB-INCOMPLETE.txt'
        $text = "Phase B did not complete: $Reason`r`n" +
                "The AutoLogon password was cleared, but per-user setup (Outlook signature, " +
                "wallpaper, default printer) may be missing. Finish it manually for this user.`r`n" +
                "Stamp: $(Get-Date -Format o)"
        Set-Content -LiteralPath $marker -Value $text -Encoding UTF8
        Write-CleanupLog WARN "Incomplete marker written: $marker"
    } catch {
        Write-CleanupLog WARN "Could not write incomplete marker: $($_.Exception.Message)"
    }
}

# Worst case: the security payoff could not be verified. Loud and persistent.
function Write-CriticalMarker {
    param([Parameter(Mandatory)][string]$Reason)
    try {
        $marker = Join-Path (Join-Path $env:WINDIR 'Temp') 'CORP-AUTOLOGON-NOT-CLEARED.txt'
        $text = "CRITICAL: $Reason`r`n" +
                "A plaintext logon password may still be in HKLM\...\Winlogon (DefaultPassword). " +
                "Clear it manually NOW and confirm AutoAdminLogon=0.`r`nStamp: $(Get-Date -Format o)"
        Set-Content -LiteralPath $marker -Value $text -Encoding UTF8
        Write-CleanupLog ERROR "Critical marker written: $marker"
    } catch {
        Write-CleanupLog ERROR "Could not write critical marker: $($_.Exception.Message)"
    }
}

# ============================================================
# Side-effecting steps (need a real machine)
# ============================================================

# Poll for Phase B's flag up to the timeout. Returns $true if seen, $false on timeout.
# Uses a monotonic Stopwatch, not Get-Date: a fresh box steps its clock via NTP at first
# logon, which would corrupt a wall-clock deadline.
function Wait-UserDoneFlag {
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [int]$TimeoutSeconds = 900,
        [int]$PollSeconds = 5
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-UserDoneFlag -StateDir $StateDir) { return $true }
        Start-Sleep -Seconds $PollSeconds
    }
    return (Test-UserDoneFlag -StateDir $StateDir)   # final check at the deadline
}

# Zero the AutoLogon entries in HKLM\...\Winlogon AND verify the plaintext password is
# actually gone. Returns $true ONLY when read-back confirms DefaultPassword is absent and
# AutoAdminLogon=0 - a suppressed cmdlet error is not proof. Idempotent.
function Clear-AutoLogon {
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    try {
        Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -Value '0' -ErrorAction SilentlyContinue
        # SilentlyContinue keeps this idempotent (a missing value is a no-op).
        foreach ($name in 'DefaultPassword', 'DefaultUserName', 'DefaultDomainName', 'AutoLogonCount') {
            Remove-ItemProperty -Path $winlogon -Name $name -ErrorAction SilentlyContinue
        }
    } catch {
        Write-CleanupLog ERROR "Clear AutoLogon (write): $($_.Exception.Message)"
    }

    # Trust the registry state, not the (suppressed) cmdlet return.
    $rp = Get-ItemProperty -Path $winlogon -ErrorAction SilentlyContinue
    $pwGone  = -not ($rp -and $rp.PSObject.Properties['DefaultPassword'])
    $autoOff = (-not ($rp -and $rp.PSObject.Properties['AutoAdminLogon'])) -or ($rp.AutoAdminLogon -eq '0')
    if ($pwGone -and $autoOff) {
        Write-CleanupLog OK 'AutoLogon cleared and verified (DefaultPassword gone, AutoAdminLogon=0)'
        return $true
    }
    Write-CleanupLog ERROR 'AutoLogon NOT cleared: DefaultPassword still present or AutoAdminLogon != 0'
    Write-CriticalMarker -Reason 'Clear-AutoLogon read-back failed - plaintext password may persist in HKLM'
    return $false
}

function Unregister-PhaseTasks {
    param([Parameter(Mandatory)][string[]]$TaskNames)
    foreach ($name in $TaskNames) {
        try {
            if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
                Write-CleanupLog OK "Scheduled task unregistered: $name"
            }
        } catch {
            Write-CleanupLog WARN "Unregister task ${name}: $($_.Exception.Message)"
        }
    }
}

# ============================================================
# Orchestration
# ============================================================
function Invoke-Cleanup {
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [int]$TimeoutSeconds = 900,
        [int]$PollSeconds = 5
    )
    Initialize-CleanupLog
    Write-CleanupLog INFO "Cleanup starting (StateDir=$StateDir, timeout=${TimeoutSeconds}s)"

    # Close the brecha FIRST: the plaintext password has no reason to outlive this script,
    # and Phase B never depends on AutoLogon (it only touches the user hive / %APPDATA%).
    # This affects future logons only; the current session keeps running.
    $cleared = Clear-AutoLogon

    # Wait for Phase B to finish (monotonic clock).
    $done = Wait-UserDoneFlag -StateDir $StateDir -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds
    if ($done) {
        Write-CleanupLog OK 'Phase B signaled completion (user-done flag seen)'
    } else {
        Write-CleanupLog WARN "Timeout after ${TimeoutSeconds}s - Phase B did not signal completion."
        Write-IncompleteMarker -Reason "user-done flag absent after ${TimeoutSeconds}s timeout"
        # Stop a possibly-still-running Phase B before tearing its staging down.
        try { Stop-ScheduledTask -TaskName $script:UserTaskName -ErrorAction SilentlyContinue | Out-Null } catch { }
    }

    # Keep the Phase B log (it lives under StateDir, which we may delete below) and drop
    # the per-user task - its work is done or has been stopped.
    Save-PhaseBLogs -StateDir $StateDir | Out-Null
    Unregister-PhaseTasks -TaskNames @($script:UserTaskName)

    if ($cleared) {
        # Brecha confirmed closed: finish teardown. A running task may unregister itself;
        # the script keeps running to completion afterward.
        Unregister-PhaseTasks -TaskNames @($script:SystemTaskName)
        try {
            if (Remove-StagingFolder -StateDir $StateDir) { Write-CleanupLog OK "Staging folder removed: $StateDir" }
            else { Write-CleanupLog INFO "Staging folder already gone: $StateDir" }
        } catch {
            Write-CleanupLog ERROR "Remove staging folder: $($_.Exception.Message)"
        }
        Write-CleanupLog INFO 'Cleanup finished'
    } else {
        # Brecha NOT verified closed: do NOT self-destruct. Leave the SYSTEM task and
        # staging so the next logon retries Clear-AutoLogon (idempotent).
        Write-CleanupLog ERROR 'AutoLogon not verified cleared - leaving SYSTEM task + staging for retry at next logon.'
    }
}

# Test seam: stop here when dot-sourced with -LoadOnly so only the functions load.
if ($LoadOnly) { return }

Invoke-Cleanup -StateDir $StateDir -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds
