#Requires -Version 5.1
param(
    [switch]$Unattended,
    [string]$TestFullName  = 'Test User',
    [string]$TestUsername  = 'test.user',
    [string]$TestDomain    = '',
    [string]$TestSector    = '',
    [switch]$TestStaticIp,
    [string]$TestIpAddress = '',
    [switch]$TestWebAgent,
    # Two-phase handoff (PHASE 8). OFF by default so the harness (interactive sandbox + -Headless)
    # and any single-phase run behave as before - they never stage, arm AutoLogon, or reboot.
    # Production turns it on via autounattend (task 3e). -EnableHandoff: stage Phase B + register the
    # tasks + arm AutoLogon + reboot. -NoReboot (with -EnableHandoff): stage + arm but skip the
    # Restart-Computer (throwaway-VM inspection only - leaves the plaintext password in HKLM).
    [switch]$EnableHandoff,
    [switch]$NoReboot,
    # Test seam: dot-source with -LoadOnly to define the pure validator functions below
    # WITHOUT running the provisioning body (used by tests/unit). Never set in production.
    [switch]$LoadOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# Input normalizers / validators (pure functions, no UI/theme dependency).
# Declared at the top so BOTH the interactive form AND the headless -Test*
# path call the SAME validators - automation cannot drive the script into a
# broken state. StrictMode-safe (only [regex], System.Text, System.Globalization).
# ============================================================

# Strip accents: FormD decomposes 'o-acute' -> 'o' + combining mark, drop every
# NonSpacingMark, recompose. 'c-cedilla' -> 'c'. Handles a-tilde, e-circ, etc.
function Remove-Diacritics {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $d  = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $d.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
}

# Display name (signature + New-LocalUser -FullName): letters/space/hyphen/apostrophe
# only, Title Case, with Portuguese particles lowercased ('Joao Da Silva' -> 'Joao da Silva').
function Format-FullName {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $c = [regex]::Replace($Text, "[^\p{L}\s\-']", '')
    $c = [regex]::Replace($c, '\s+', ' ').Trim()
    if ($c -eq '') { return '' }
    $c = (Get-Culture).TextInfo.ToTitleCase($c.ToLower())
    foreach ($p in 'Da','De','Do','Das','Dos','E') {
        $c = [regex]::Replace($c, "\b$p\b", $p.ToLower())
    }
    return $c
}

# Login / email prefix: lowercase name.surname. Case-sensitive match so an
# upstream bug leaving an uppercase char fails loudly instead of slipping through.
function Test-Username {
    param([string]$Username)
    return ($Username -cmatch '^[a-z]+\.[a-z]+$')
}

# Strict IPv4: exactly 4 octets, each 0-255. Do NOT rely on TryParse alone -
# it accepts '10.5' (2-part) and hex forms that New-NetIPAddress would choke on.
function Test-Ipv4 {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $false }
    $o = $Ip.Trim() -split '\.'
    if ($o.Count -ne 4) { return $false }
    foreach ($x in $o) { if ($x -notmatch '^\d{1,3}$' -or [int]$x -gt 255) { return $false } }
    return $true
}

# Derive the Windows login / e-mail prefix from first + last name: firstname.surname,
# accent-stripped, lowercase, letters only. 'Joao Pedro' + 'da Silva' -> 'joao.silva'.
# Returns '' until both names have a usable token (the form keeps the field empty meanwhile).
function Format-Username {
    param([string]$First, [string]$Last)
    $ft = @(((Remove-Diacritics $First) -replace '[^A-Za-z ]', '') -split '\s+' | Where-Object { $_ })
    $lt = @(((Remove-Diacritics $Last)  -replace '[^A-Za-z ]', '') -split '\s+' | Where-Object { $_ })
    if ($ft.Count -eq 0 -or $lt.Count -eq 0) { return '' }
    return ($ft[0] + '.' + $lt[-1]).ToLower()
}

# Build the Phase A -> Phase B handoff state object (serialized to state.json in PHASE 8). Pure:
# string-in / object-out, references no config/form vars, so tests dot-source this file with
# -LoadOnly and round-trip it against phase-b.ps1's Read-CorpState. Takes NO credential - state.json
# never carries one, and the field set here IS the contract phase-b reads. The 3 required fields are
# Mandatory (a blank one can't even be built); Read-CorpState re-checks them on read (defense in depth).
function New-CorpStateObject {
    param(
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$FullName,
        [Parameter(Mandatory)][string]$Email,
        [string]$EmailDomain   = '',
        [string]$SectorName    = '',
        [string]$SigTemplate   = '',
        [string]$PrinterName   = '',
        [string]$WallpaperPath = ''
    )
    return [pscustomobject]@{
        Username      = $Username
        FullName      = $FullName
        Email         = $Email
        EmailDomain   = $EmailDomain
        SectorName    = $SectorName
        SigTemplate   = $SigTemplate
        PrinterName   = $PrinterName
        WallpaperPath = $WallpaperPath
    }
}

# Test seam: when dot-sourced with -LoadOnly (tests/unit), stop here so only the pure
# validator functions above are defined - the provisioning body below never runs.
if ($LoadOnly) { return }

# ============================================================
# setup.ps1 - Windows 11 Setup
# Run automatically by autounattend.xml on the first login
# Requires: config.ps1 at the USB root (gitignored, never commit)
# ============================================================

$LogFile      = "$env:USERPROFILE\Desktop\win11_setup_log.txt"
$ScriptDir    = $PSScriptRoot
$script:Errors = [System.Collections.Generic.List[string]]::new()

# Absolute path of the wallpaper PHASE 4 copies into %WINDIR% (empty until/unless that runs).
# Handed to Phase B via state.json. Declared up front so StrictMode never sees it unset.
$script:WallpaperStaged = ''

# Live-progress UI state. The input form is modal (ShowDialog) on the main thread; the
# work (PHASE 4-7) runs here on the main thread, while a SEPARATE STA runspace shows a
# progress window with a real message loop (Application.Run) and a Timer that drains the
# log queue. So heavy work never blocks the window -> no "not responding". All three are
# $null when headless (-Unattended) -> every UI touch no-ops and behavior matches the original.
$script:LogQueue = $null   # ConcurrentQueue[object] of {Level, Line}; $null = headless
$script:UiState  = $null   # synchronized hashtable: { Done, Status }
$script:ProgUI   = $null   # @{ PS; Handle; Runspace } for the progress runspace

function Write-Log {
    param([string]$Level, [string]$Msg)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Msg"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $line
    if ($Level -in 'ERROR', 'FATAL') {
        $script:Errors.Add("[$Level] $Msg") | Out-Null
    }
    # Tee to the progress window: enqueue (thread-safe). The runspace Timer drains it.
    if ($script:LogQueue) {
        try { $script:LogQueue.Enqueue([pscustomobject]@{ Level = $Level; Line = $line }) } catch { }
    }
}

# Updates the progress-window status caption (drained by the Timer). No-op when headless.
function Set-Phase([string]$text) {
    if ($script:UiState) { $script:UiState.Status = $text }
}

# Evaluates an installer exit code and logs OK/ERROR (instead of assuming OK).
# 3010 (reboot required) counts as success for MSI.
function Write-ProcResult {
    param([string]$Name, $Proc, [int[]]$OkCodes = @(0))
    if ($null -eq $Proc) { Write-Log 'ERROR' "${Name}: process did not start"; return }
    if ($OkCodes -contains $Proc.ExitCode) {
        Write-Log 'OK' "$Name exit $($Proc.ExitCode)"
    } else {
        Write-Log 'ERROR' "$Name failed (exit $($Proc.ExitCode))"
    }
}

# Runs an installer and waits up to $TimeoutSec, killing it on timeout. A hung silent installer
# (e.g. msiexec /quiet blocked on a dialog) would otherwise block the whole provision forever.
# Returns the finished process (for Write-ProcResult) or $null if it had to be killed.
function Invoke-InstallerWithTimeout {
    param([string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSec = 1800)
    $params = @{ FilePath = $FilePath; PassThru = $true }
    if ($ArgumentList.Count) { $params['ArgumentList'] = $ArgumentList }
    $proc = Start-Process @params
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        Write-Log 'ERROR' "$FilePath timed out after ${TimeoutSec}s - killed"
        return $null
    }
    return $proc
}

# Global trap = last-resort net for a terminating error NOT handled by try/catch.
# Aborts with exit 1 (instead of 'continue') so we don't proceed over inconsistent state
# and so the caller (run.bat checks %errorlevel%) is told it failed.
trap {
    $msg = "Unhandled fatal error at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    Write-Log 'FATAL' $msg
    # If the progress window is up, let the technician read the fatal line before we exit.
    if ($script:ProgUI) {
        try {
            $script:UiState.Status = 'FATAL error - review the log above, then close.'
            $script:UiState.Done   = $true
            $script:ProgUI.PS.EndInvoke($script:ProgUI.Handle)
        } catch { }
    }
    exit 1
}

# GUI assemblies for the input form (ShowDialog) on the main thread. Failure is fatal.
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    Write-Log 'FATAL' "Failed to load GUI assemblies: $($_.Exception.Message)"
    exit 1
}

# --- Input-form helpers (used by the PHASE 3 ShowDialog form, at script scope).
# The redesigned grouped/themed form uses width-only textbox/combo (the position is set by
# Add-Field), New-Group for titled GroupBoxes, and Add-Field to stack a muted label + control.
# These reference the theme vars ($Clr*/$Font*) and $Form defined in the form block below; they
# are only ever called from there, after those vars are assigned (if/try do not open a scope). ---
function New-TextBox([int]$w = 496) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Size        = New-Object System.Drawing.Size($w, 25)
    $t.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $t.BackColor   = $ClrCard
    return $t
}
# Flat read-only dropdown (width only; position set by Add-Field or caller).
function New-Combo([int]$w = 496) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Size          = New-Object System.Drawing.Size($w, 25)
    $c.DropDownStyle = 'DropDownList'
    $c.FlatStyle     = [System.Windows.Forms.FlatStyle]::Flat
    $c.BackColor     = $ClrCard
    return $c
}
# A titled GroupBox added to the form; returns it for child placement.
function New-Group([string]$title, [int]$x, [int]$y, [int]$w, [int]$h) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text      = $title
    $g.Font      = $FontGroup
    $g.ForeColor = $ClrText
    $g.Location  = New-Object System.Drawing.Point($x, $y)
    $g.Size      = New-Object System.Drawing.Size($w, $h)
    $Form.Controls.Add($g)
    return $g
}
# Stack a muted label (with optional red required '*') above a control inside
# $parent at relative (px,py). Returns the next free py.
function Add-Field($parent, [string]$labelText, $control, [int]$px, [int]$py, [bool]$required = $false) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $labelText; $l.AutoSize = $true; $l.ForeColor = $ClrMuted; $l.Font = $FontBase
    $l.Location = New-Object System.Drawing.Point($px, $py)
    $parent.Controls.Add($l)
    if ($required) {
        $star = New-Object System.Windows.Forms.Label
        $star.Text = ' *'; $star.AutoSize = $true; $star.ForeColor = $ClrReq; $star.Font = $FontBase
        $star.Location = New-Object System.Drawing.Point(($px + $l.PreferredWidth - 4), $py)
        $parent.Controls.Add($star)
    }
    $control.Location = New-Object System.Drawing.Point($px, ($py + 20))
    $parent.Controls.Add($control)
    return ($py + 20 + $control.Height + 12)
}

# Launches the progress window in its own STA runspace. The window runs a real message loop
# (Application.Run) so it stays responsive while the main thread does heavy work; a Timer
# drains $script:LogQueue into the colored RichTextBox and reflects $script:UiState. Returns
# the runspace handles so the caller can mark Done and wait for the user to close the window.
function Start-ProgressWindow {
    $script:LogQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $script:UiState  = [hashtable]::Synchronized(@{ Done = $false; Status = 'Starting setup...' })

    $uiScript = {
        param($Queue, $State)
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $clr = @{
            OK    = [System.Drawing.Color]::FromArgb(80, 220, 100)
            WARN  = [System.Drawing.Color]::FromArgb(235, 200, 60)
            ERROR = [System.Drawing.Color]::FromArgb(240, 90, 90)
            FATAL = [System.Drawing.Color]::FromArgb(255, 70, 70)
            INFO  = [System.Drawing.Color]::FromArgb(190, 190, 190)
        }

        $form = New-Object System.Windows.Forms.Form
        $form.Text          = 'Setup - Progress'
        $form.Size          = New-Object System.Drawing.Size(780, 560)
        $form.StartPosition = 'CenterScreen'

        $status = New-Object System.Windows.Forms.Label
        $status.Dock      = 'Top'
        $status.Height    = 24
        $status.TextAlign = 'MiddleLeft'
        $status.Padding   = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
        $status.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $status.Text      = $State.Status

        $bar = New-Object System.Windows.Forms.ProgressBar
        $bar.Dock                  = 'Top'
        $bar.Height                = 16
        $bar.Style                 = 'Marquee'
        $bar.MarqueeAnimationSpeed = 30

        $rtb = New-Object System.Windows.Forms.RichTextBox
        $rtb.Dock       = 'Fill'
        $rtb.ReadOnly   = $true
        $rtb.BackColor  = [System.Drawing.Color]::FromArgb(20, 20, 24)
        $rtb.ForeColor  = [System.Drawing.Color]::FromArgb(200, 200, 200)
        $rtb.Font       = New-Object System.Drawing.Font('Consolas', 9)
        $rtb.WordWrap   = $false
        $rtb.ScrollBars = 'Both'
        $rtb.DetectUrls = $false

        $btn = New-Object System.Windows.Forms.Button
        $btn.Dock    = 'Bottom'
        $btn.Height  = 34
        $btn.Text    = 'Close'
        $btn.Enabled = $false
        $btn.Add_Click({ $form.Close() })

        # Dock order: Fill control added first, edges after -> log fills, status/bar on top, Close at bottom.
        $form.Controls.Add($rtb)
        $form.Controls.Add($bar)
        $form.Controls.Add($status)
        $form.Controls.Add($btn)

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 200
        $timer.Add_Tick({
            $item = $null
            while ($Queue.TryDequeue([ref]$item)) {
                $c = $clr[$item.Level]; if (-not $c) { $c = $clr['INFO'] }
                $rtb.SelectionStart  = $rtb.TextLength
                $rtb.SelectionLength = 0
                $rtb.SelectionColor  = $c
                $rtb.AppendText($item.Line + "`n")
                $rtb.SelectionColor  = $rtb.ForeColor
                $rtb.ScrollToCaret()
            }
            $status.Text = $State.Status
            if ($State.Done) {
                $bar.Style   = 'Continuous'
                $bar.Value   = $bar.Maximum
                $btn.Enabled = $true
            }
        })
        $timer.Start()

        [System.Windows.Forms.Application]::Run($form)   # real message loop: stays responsive
        $timer.Stop()
    }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'                # required for WinForms
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($uiScript).AddArgument($script:LogQueue).AddArgument($script:UiState)
    $handle = $ps.BeginInvoke()

    $script:ProgUI = [pscustomobject]@{ PS = $ps; Handle = $handle; Runspace = $rs }
}

# ============================================================
# PHASE 1 - Load config.ps1 from the USB
# ============================================================

$ConfigFile = Join-Path $ScriptDir 'config.ps1'
if (-not (Test-Path $ConfigFile)) {
    [System.Windows.Forms.MessageBox]::Show(
        "config.ps1 not found at: $ScriptDir`nPut config.ps1 at the USB root and run again.",
        'Setup - Error', 'OK', 'Error') | Out-Null
    exit 1
}
try {
    . $ConfigFile
    Write-Log 'OK' "config.ps1 loaded from: $ConfigFile"
} catch {
    Write-Log 'FATAL' "Failed to execute config.ps1: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show(
        "Error loading config.ps1:`n$($_.Exception.Message)",
        'Setup - Fatal Error', 'OK', 'Error') | Out-Null
    exit 1
}

# Validate the required config variables BEFORE using them (under StrictMode, indexing a
# missing variable becomes a generic FATAL - here we give an actionable message and abort early).
$RequiredConfig = @('AdminAccount', 'AdminNewPass', 'UserInitialPass', 'EmailDomains', 'PathSignatures')
$missing = $RequiredConfig | Where-Object {
    $v = Get-Variable $_ -ErrorAction SilentlyContinue
    (-not $v) -or ($null -eq $v.Value) -or (($v.Value -is [string]) -and ($v.Value.Trim() -eq ''))
}
if ($missing) {
    $msg = "config.ps1 does not define: " + ($missing -join ', ')
    Write-Log 'FATAL' $msg
    [System.Windows.Forms.MessageBox]::Show($msg, 'Setup - incomplete config.ps1', 'OK', 'Error') | Out-Null
    exit 1
}

# ============================================================
# Context guard (production path only) - run BEFORE any mutation.
# ============================================================
# This script is about to rotate $AdminAccount's password and (in the two-phase flow) disable
# that account and write machine handoff state. It MUST be running elevated AND as the bootstrap
# admin account that autounattend created + AutoLogon'd; doing this from the wrong identity would
# corrupt the wrong account and write to the wrong profile. Abort here, before the first change.
# Exit 2 = fatal precondition (autounattend FirstLogonCommands propagates it - see exit contract:
# 0 = success, 1 = errors tracked, 2 = fatal guard/config). Skipped under -Unattended, which is
# the test/headless seam (the harness runs as the sandbox guest, not as $AdminAccount).
if (-not $Unattended) {
    try {
        $currentId  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $isElevated = ([System.Security.Principal.WindowsPrincipal]$currentId).IsInRole(
            [System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        $isElevated = $false
    }
    if (-not $isElevated) {
        $msg = 'setup.ps1 must run elevated (as Administrator). Aborting before any change.'
        Write-Log 'FATAL' $msg
        [System.Windows.Forms.MessageBox]::Show($msg, 'Setup - not elevated', 'OK', 'Error') | Out-Null
        exit 2
    }
    if ($env:USERNAME -ine $AdminAccount) {
        $msg = "setup.ps1 must run as the bootstrap admin '$AdminAccount', " +
               "but the current user is '$env:USERNAME'. Aborting before any change."
        Write-Log 'FATAL' $msg
        [System.Windows.Forms.MessageBox]::Show($msg, 'Setup - wrong account', 'OK', 'Error') | Out-Null
        exit 2
    }
    Write-Log 'OK' "Context guard passed: elevated, running as $env:USERNAME"
}

# OPTIONAL config: if config.ps1 omits it, create it as $null so StrictMode does not blow up
# later (e.g. `if ($WifiSSID)` indexes the missing variable and is FATAL under StrictMode).
# All of these are used under a guard (`if ($Var)`) or validated at the point of use.
$OptionalConfig = @('WifiSSID', 'WifiPass', 'SharePath', 'ShareUser', 'SharePass',
                    'WallpaperFile', 'StaticPrefixLength', 'StaticGateway', 'DnsServers')
foreach ($o in $OptionalConfig) {
    if (-not (Get-Variable -Name $o -ErrorAction SilentlyContinue)) {
        New-Variable -Name $o -Value $null
    }
}

# ============================================================
# Pre-form data load (reads only - NO machine mutation here)
# ============================================================
# OEM activation, admin-password rotation, WiFi, share mapping and the Ninite launch used to run
# HERE, before the form. They mutate the machine, so they moved into PHASE A (below), which only
# runs after the operator confirms - a Cancel must change nothing. The one thing still needed
# before the form is the read-only data the form renders (printers).

# Load printers.json from the USB
$Printers = @()
$PrintersJson = Join-Path $ScriptDir 'printers.json'
if (Test-Path $PrintersJson) {
    try {
        $raw = @(Get-Content $PrintersJson -Raw -Encoding UTF8 | ConvertFrom-Json)
        # Keep only well-formed entries: the GUI and Add-Printer use name/model/ip, and under
        # StrictMode touching a missing property is a hard error - so drop incomplete records.
        $Printers = @($raw | Where-Object {
            $n = $_.PSObject.Properties.Name
            ($n -contains 'name'  -and $_.name)  -and
            ($n -contains 'model' -and $_.model) -and
            ($n -contains 'ip'    -and $_.ip)
        })
        $dropped = $raw.Count - $Printers.Count
        if ($dropped -gt 0) { Write-Log 'WARN' "$dropped printer entry(ies) ignored (missing name/model/ip)" }
        Write-Log 'OK' "$($Printers.Count) printers loaded"
    } catch {
        Write-Log 'ERROR' "printers.json: $($_.Exception.Message)"
    }
} else {
    Write-Log 'WARN' "printers.json not found on the USB"
}

# ============================================================
# PHASE 3 - Collect inputs (modal input form) or resolve from -Test* params
# ============================================================
# Interactive: a MODAL input form (ShowDialog = real message loop, rock-solid - no DoEvents).
# It only collects values, then closes. The live progress window is launched afterwards in a
# separate runspace (see Start-ProgressWindow). Headless ($Unattended / no desktop): values
# come from -Test* params and no window is shown.

$useUI = (-not $Unattended) -and [System.Environment]::UserInteractive

# No desktop but -Unattended not set: the form silently never shows and -Test* params drive the
# run. Surface it so a technician who expected the GUI isn't confused by a "headless" provision.
if (-not $useUI -and -not $Unattended) {
    Write-Log 'WARN' 'No interactive desktop (UserInteractive=False) and -Unattended not set; running headless with -Test* parameters.'
}

if ($useUI) {
try {

# --- palette and fonts ---
$ClrBg      = [System.Drawing.Color]::FromArgb(245, 246, 248)
$ClrCard    = [System.Drawing.Color]::White
$ClrText    = [System.Drawing.Color]::FromArgb(32, 32, 32)
$ClrMuted   = [System.Drawing.Color]::FromArgb(110, 115, 125)
$ClrAccent  = [System.Drawing.Color]::FromArgb(0, 120, 215)
$ClrAccentD = [System.Drawing.Color]::FromArgb(0, 102, 184)
$ClrReq     = [System.Drawing.Color]::FromArgb(200, 40, 40)
$FontBase   = New-Object System.Drawing.Font('Segoe UI', 9)
$FontH1     = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$FontGroup  = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)

$Form = New-Object System.Windows.Forms.Form
$Form.Text            = 'New Machine Setup'
$Form.StartPosition   = 'CenterScreen'
$Form.FormBorderStyle = 'FixedDialog'
$Form.MaximizeBox     = $false
$Form.MinimizeBox     = $false
$Form.BackColor       = $ClrBg
$Form.ForeColor       = $ClrText
$Form.Font            = $FontBase

$CW  = 544          # client width
$gx  = 16           # group left margin
$gw  = 528          # group width
$Tip = New-Object System.Windows.Forms.ToolTip
# Marks invalid fields with an inline glyph (used by the aggregated submit validator).
# Not parented to the form, so Form.Dispose() won't free it - harmless in this one-shot flow.
$ErrProvider = New-Object System.Windows.Forms.ErrorProvider
$ErrProvider.BlinkStyle = [System.Windows.Forms.ErrorBlinkStyle]::NeverBlink

# --- header band ---
$Header = New-Object System.Windows.Forms.Panel
$Header.Location  = New-Object System.Drawing.Point(0, 0)
$Header.Size      = New-Object System.Drawing.Size($CW, 70)
$Header.BackColor = $ClrCard
$Form.Controls.Add($Header)
$AccentBar = New-Object System.Windows.Forms.Panel
$AccentBar.Location  = New-Object System.Drawing.Point(0, 0)
$AccentBar.Size      = New-Object System.Drawing.Size(6, 70)
$AccentBar.BackColor = $ClrAccent
$Header.Controls.Add($AccentBar)
$LblTitle = New-Object System.Windows.Forms.Label
$LblTitle.Text = 'New Machine Setup'; $LblTitle.Font = $FontH1
$LblTitle.ForeColor = $ClrText; $LblTitle.AutoSize = $true
$LblTitle.Location = New-Object System.Drawing.Point(20, 12)
$Header.Controls.Add($LblTitle)
$LblSub = New-Object System.Windows.Forms.Label
$LblSub.Text = 'Fill in the ticket details to provision the computer.'
$LblSub.Font = $FontBase; $LblSub.ForeColor = $ClrMuted; $LblSub.AutoSize = $true
$LblSub.Location = New-Object System.Drawing.Point(22, 42)
$Header.Controls.Add($LblSub)

$y = 82

# Guards against TextChanged recursion when a handler programmatically sets .Text.
$script:SuppressUser = $false
$script:SuppressIp   = $false
$script:SuppressName = $false
$script:IpPrevLen    = 0

# --- group: User ---
$gUser = New-Group 'User' $gx $y $gw 288
$py = 28
# --- Full name: First | Last side by side, divided by a bar. Tab flows left->right then down.
# Tab order == control add-order (the form sets NO explicit TabIndex anywhere); keep First added
# before Last before Username or the tab flow silently breaks. The read-only field below shows the
# Title-Cased concatenation that is actually used downstream ($TxtFullName).
$nameColW   = 240
$nameRightX = 16 + $nameColW + 16    # left col 16..256, 16px gap, right col 272..512

$lblFirst = New-Object System.Windows.Forms.Label
$lblFirst.Text = 'First name'; $lblFirst.AutoSize = $true; $lblFirst.ForeColor = $ClrMuted; $lblFirst.Font = $FontBase
$lblFirst.Location = New-Object System.Drawing.Point(16, $py)
$gUser.Controls.Add($lblFirst)
$starFirst = New-Object System.Windows.Forms.Label
$starFirst.Text = ' *'; $starFirst.AutoSize = $true; $starFirst.ForeColor = $ClrReq; $starFirst.Font = $FontBase
$starFirst.Location = New-Object System.Drawing.Point((16 + $lblFirst.PreferredWidth - 4), $py)
$gUser.Controls.Add($starFirst)
$TxtFirstName = New-TextBox $nameColW
$TxtFirstName.Location = New-Object System.Drawing.Point(16, ($py + 20))
$Tip.SetToolTip($TxtFirstName, 'First name as written on the ticket.')
$gUser.Controls.Add($TxtFirstName)

# vertical divider bar, centered in the gap between the two columns
$NameBar = New-Object System.Windows.Forms.Panel
$NameBar.Size = New-Object System.Drawing.Size(2, 25)
$NameBar.Location = New-Object System.Drawing.Point((16 + $nameColW + 7), ($py + 20))
$NameBar.BackColor = $ClrMuted
$gUser.Controls.Add($NameBar)

$lblLast = New-Object System.Windows.Forms.Label
$lblLast.Text = 'Last name'; $lblLast.AutoSize = $true; $lblLast.ForeColor = $ClrMuted; $lblLast.Font = $FontBase
$lblLast.Location = New-Object System.Drawing.Point($nameRightX, $py)
$gUser.Controls.Add($lblLast)
$starLast = New-Object System.Windows.Forms.Label
$starLast.Text = ' *'; $starLast.AutoSize = $true; $starLast.ForeColor = $ClrReq; $starLast.Font = $FontBase
$starLast.Location = New-Object System.Drawing.Point(($nameRightX + $lblLast.PreferredWidth - 4), $py)
$gUser.Controls.Add($starLast)
$TxtLastName = New-TextBox $nameColW
$TxtLastName.Location = New-Object System.Drawing.Point($nameRightX, ($py + 20))
$Tip.SetToolTip($TxtLastName, 'Last name (surname) as written on the ticket.')
$gUser.Controls.Add($TxtLastName)
$py = $py + 20 + 25 + 12

# Read-only output: the two names concatenated and Title-Cased (the display name actually used).
$lblFull = New-Object System.Windows.Forms.Label
$lblFull.Text = 'Full name (auto)'; $lblFull.AutoSize = $true; $lblFull.ForeColor = $ClrMuted; $lblFull.Font = $FontBase
$lblFull.Location = New-Object System.Drawing.Point(16, $py)
$gUser.Controls.Add($lblFull)
$TxtFullName = New-TextBox
$TxtFullName.ReadOnly  = $true
$TxtFullName.TabStop   = $false
$TxtFullName.BackColor = $ClrBg
$TxtFullName.Location  = New-Object System.Drawing.Point(16, ($py + 20))
$gUser.Controls.Add($TxtFullName)
$py = $py + 20 + 25 + 12

# Live: sanitize each field (letters/space/hyphen/apostrophe), then refresh the concatenation.
# Inputs keep raw casing; the read-only output above is the source of truth (Title Case). The
# concat is always "First Last" (never flipped). Shared SuppressName guard is safe: each handler
# only sets its OWN box, and $TxtFullName has no TextChanged so the concat write cannot recurse.
# Username is auto-derived from First+Last (firstname.surname) so the technician never types it;
# it stays editable - once they type in the Username box (KeyDown below), auto-fill backs off.
$script:UserEditedUsername = $false
$TxtFirstName.Add_TextChanged({
    if ($script:SuppressName) { return }
    $raw   = $TxtFirstName.Text
    $clean = [regex]::Replace($raw, "[^\p{L}\s\-']", '')
    if ($clean -ne $raw) {
        $caret = $TxtFirstName.SelectionStart - ($raw.Length - $clean.Length)
        $script:SuppressName = $true
        $TxtFirstName.Text = $clean
        $script:SuppressName = $false
        $TxtFirstName.SelectionStart = [Math]::Min([Math]::Max($caret, 0), $clean.Length)
    }
    $TxtFullName.Text = Format-FullName ("{0} {1}" -f $TxtFirstName.Text, $TxtLastName.Text)
    if (-not $script:UserEditedUsername) { $TxtUsername.Text = Format-Username $TxtFirstName.Text $TxtLastName.Text }
})
$TxtLastName.Add_TextChanged({
    if ($script:SuppressName) { return }
    $raw   = $TxtLastName.Text
    $clean = [regex]::Replace($raw, "[^\p{L}\s\-']", '')
    if ($clean -ne $raw) {
        $caret = $TxtLastName.SelectionStart - ($raw.Length - $clean.Length)
        $script:SuppressName = $true
        $TxtLastName.Text = $clean
        $script:SuppressName = $false
        $TxtLastName.SelectionStart = [Math]::Min([Math]::Max($caret, 0), $clean.Length)
    }
    $TxtFullName.Text = Format-FullName ("{0} {1}" -f $TxtFirstName.Text, $TxtLastName.Text)
    if (-not $script:UserEditedUsername) { $TxtUsername.Text = Format-Username $TxtFirstName.Text $TxtLastName.Text }
})
$TxtUsername = New-TextBox
$Tip.SetToolTip($TxtUsername, 'Auto-filled from First + Last (e.g. joao.silva). Edit only if you need a different login.')
$py = Add-Field $gUser 'Username (auto from name)' $TxtUsername 16 $py $true
# A real keystroke here means the technician is overriding the auto-derived value: stop syncing
# it from the name fields. KeyDown fires only on physical input, not on our programmatic .Text
# assignment, so the auto-fill itself never trips this.
$TxtUsername.Add_KeyDown({ $script:UserEditedUsername = $true })
# Live cleanup: strip accents (o-acute -> o, c-cedilla -> c) BEFORE filtering so the letter
# survives, force lowercase, keep only [a-z.], collapse repeated dots. Caret-preserving.
# Registered BEFORE the email-preview handler (below) so the preview sees the cleaned text.
# Full name.surname shape is enforced at submit time (Test-Username in the OK handler).
$TxtUsername.Add_TextChanged({
    if ($script:SuppressUser) { return }
    $raw   = $TxtUsername.Text
    $clean = Remove-Diacritics $raw
    $clean = [regex]::Replace($clean.ToLower(), '[^a-z.]', '')
    $clean = [regex]::Replace($clean, '\.{2,}', '.')
    if ($clean -ne $raw) {
        $caret = $TxtUsername.SelectionStart - ($raw.Length - $clean.Length)
        $script:SuppressUser = $true
        $TxtUsername.Text = $clean
        $script:SuppressUser = $false
        $TxtUsername.SelectionStart = [Math]::Min([Math]::Max($caret, 0), $clean.Length)
    }
})
$CmbDomain = New-Combo 250
$EmailDomains | ForEach-Object { $CmbDomain.Items.Add($_) | Out-Null }
$CmbDomain.SelectedIndex = 0
$py = Add-Field $gUser 'Email domain' $CmbDomain 16 $py
$LblEmail = New-Object System.Windows.Forms.Label
$LblEmail.AutoSize = $true; $LblEmail.ForeColor = $ClrAccent; $LblEmail.Font = $FontGroup
$LblEmail.Location = New-Object System.Drawing.Point(16, $py); $LblEmail.Text = 'Email: ---'
$gUser.Controls.Add($LblEmail)
$y += 288 + 12

# --- group: Network ---
$gNet = New-Group 'Network' $gx $y $gw 92
$RadioDhcp            = New-Object System.Windows.Forms.RadioButton
$RadioDhcp.Text       = 'DHCP (automatic)'
$RadioDhcp.AutoSize   = $true
$RadioDhcp.Checked    = $true
$RadioDhcp.Location   = New-Object System.Drawing.Point(16, 28)
$RadioStatic          = New-Object System.Windows.Forms.RadioButton
$RadioStatic.Text     = 'Static IP'
$RadioStatic.AutoSize = $true
$RadioStatic.Location = New-Object System.Drawing.Point(200, 28)
$gNet.Controls.AddRange(@($RadioDhcp, $RadioStatic))
$LblNetHint = New-Object System.Windows.Forms.Label
$LblNetHint.Text = 'The IP address will be obtained automatically from the network.'
$LblNetHint.AutoSize = $true; $LblNetHint.ForeColor = $ClrMuted; $LblNetHint.Font = $FontBase
$LblNetHint.Location = New-Object System.Drawing.Point(16, 60)
$gNet.Controls.Add($LblNetHint)
$LblIp      = New-Object System.Windows.Forms.Label
$LblIp.Text = 'IP (e.g. 10.0.X.X)'
$LblIp.AutoSize = $true; $LblIp.ForeColor = $ClrMuted; $LblIp.Font = $FontBase
$LblIp.Location = New-Object System.Drawing.Point(16, 60)
$LblIp.Visible  = $false
$TxtIp          = New-TextBox 180
$TxtIp.Location = New-Object System.Drawing.Point(150, 57)
$TxtIp.Visible  = $false
$gNet.Controls.AddRange(@($LblIp, $TxtIp))

$RadioStatic.Add_CheckedChanged({
    $LblIp.Visible = $RadioStatic.Checked; $TxtIp.Visible = $RadioStatic.Checked
    $LblNetHint.Visible = -not $RadioStatic.Checked })
$RadioDhcp.Add_CheckedChanged({
    $LblIp.Visible = $RadioStatic.Checked; $TxtIp.Visible = $RadioStatic.Checked
    $LblNetHint.Visible = -not $RadioStatic.Checked })

# IP input mask. KeyPress blocks non-digit/non-dot while typing; KeyDown makes Enter jump to
# the next octet; TextChanged normalizes (also catches paste). The auto-dot fires only while
# TYPING (not when deleting), so backspace can fix mistakes. SuppressIp guards recursion.
$TxtIp.Add_KeyPress({ param($s, $e)
    if ([char]::IsControl($e.KeyChar)) { return }   # let backspace/delete through
    if ($e.KeyChar -ne '.' -and -not [char]::IsDigit($e.KeyChar)) { $e.Handled = $true }
})
# Enter = commit the current octet and jump to the next one (inserts the dot). SuppressKeyPress
# stops the bell; there is no AcceptButton, so nothing gets submitted.
$TxtIp.Add_KeyDown({ param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $e.SuppressKeyPress = $true; $e.Handled = $true
        $t = $TxtIp.Text
        if ($t -and -not $t.EndsWith('.') -and (($t -split '\.').Count -lt 4)) {
            $script:SuppressIp = $true
            $TxtIp.Text = "$t."
            $script:SuppressIp = $false
            $TxtIp.SelectionStart = $TxtIp.Text.Length
            $script:IpPrevLen = $TxtIp.Text.Length
        }
    }
})
$TxtIp.Add_TextChanged({
    if ($script:SuppressIp) { return }
    $raw   = $TxtIp.Text
    $caret = $TxtIp.SelectionStart
    $grew  = $raw.Length -gt $script:IpPrevLen   # typing grows; deleting shrinks -> no re-pad
    $s = [regex]::Replace($raw, '[^\d.]', '')
    $s = [regex]::Replace($s, '\.{2,}', '.')
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($p in ($s -split '\.')) {
        if ($out.Count -ge 4) { break }
        $oct = if ($p.Length -gt 3) { $p.Substring(0, 3) } else { $p }
        if ($oct -ne '' -and [int]$oct -gt 255) { $oct = '255' }
        $out.Add($oct)
    }
    $r = ($out -join '.')
    if ($grew -and $out.Count -lt 4 -and $out.Count -gt 0 -and $out[$out.Count - 1].Length -eq 3 -and -not $raw.EndsWith('.')) {
        $r += '.'
    }
    if ($r -ne $raw) {
        $delta = $r.Length - $raw.Length
        $script:SuppressIp = $true
        $TxtIp.Text = $r
        $script:SuppressIp = $false
        $TxtIp.SelectionStart = [Math]::Min([Math]::Max($caret + $delta, 0), $r.Length)
    }
    $script:IpPrevLen = $TxtIp.Text.Length
})
$y += 92 + 12

# --- group: Peripherals and applications ---
$gPer = New-Group 'Peripherals and applications' $gx $y $gw 118
$py = 28
$CmbPrinter = New-Combo
# DropDownList (New-Combo default), same UX as the signature combos below: click the bar or
# the arrow to open, type the first letter to jump, or scroll. Index 0 = (None).
$CmbPrinter.Items.Add('(None)') | Out-Null
foreach ($p in $Printers) { $CmbPrinter.Items.Add("$($p.name) - $($p.model) [$($p.ip)]") | Out-Null }
$CmbPrinter.SelectedIndex = 0
$py = Add-Field $gPer 'Main printer' $CmbPrinter 16 $py
$ChkWebAgent          = New-Object System.Windows.Forms.CheckBox
$ChkWebAgent.Text     = 'Will this PC use TOTVS? (downloads + installs WebAgent)'
$ChkWebAgent.AutoSize = $true
$ChkWebAgent.Location = New-Object System.Drawing.Point(16, $py)
$Tip.SetToolTip($ChkWebAgent, 'Downloads and installs the WebAgent required to access TOTVS on this machine.')
$gPer.Controls.Add($ChkWebAgent)
$y += 118 + 12

# --- group: Email signature ---
$gSig = New-Group 'Email signature' $gx $y $gw 140
$py = 28
$CmbSector = New-Combo
$py = Add-Field $gSig 'Sector' $CmbSector 16 $py
$CmbSigTemplate = New-Combo
$CmbSigTemplate.Items.Add('(Automatic - first found)') | Out-Null
$CmbSigTemplate.SelectedIndex = 0
$py = Add-Field $gSig 'Template (.htm)' $CmbSigTemplate 16 $py
$y += 140 + 16

# --- footer buttons ---
$BtnCancel = New-Object System.Windows.Forms.Button
$BtnCancel.Text = 'Cancel'
$BtnCancel.Size = New-Object System.Drawing.Size(120, 38)
$BtnCancel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnCancel.BackColor = $ClrCard; $BtnCancel.ForeColor = $ClrText
$BtnCancel.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 205, 212)
$BtnCancel.Location = New-Object System.Drawing.Point(16, $y)
$BtnCancel.Cursor = [System.Windows.Forms.Cursors]::Hand
$BtnCancel.Add_Click({ $Form.Close() })
$Form.Controls.Add($BtnCancel)

$BtnOk          = New-Object System.Windows.Forms.Button
$BtnOk.Text     = 'Start setup'
$BtnOk.Size     = New-Object System.Drawing.Size(264, 38)
$BtnOk.Font     = $FontGroup
$BtnOk.Location = New-Object System.Drawing.Point(($gx + $gw - 264), $y)
$BtnOk.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$BtnOk.BackColor = $ClrAccent
$BtnOk.ForeColor = [System.Drawing.Color]::White
$BtnOk.FlatAppearance.BorderSize          = 0
$BtnOk.FlatAppearance.MouseOverBackColor  = $ClrAccentD
$BtnOk.FlatAppearance.MouseDownBackColor  = [System.Drawing.Color]::FromArgb(0, 90, 158)
$BtnOk.Cursor    = [System.Windows.Forms.Cursors]::Hand
$y += 38 + 16
$BtnOk.Add_Click({
    # Aggregate ALL field errors into one message + per-field glyphs, instead of return-on-first.
    $errs = [System.Collections.Generic.List[string]]::new()
    $ErrProvider.Clear()
    if ((Format-FullName $TxtFullName.Text) -eq '') {
        $errs.Add('Full name: fill in first and last name - letters only (hyphens and apostrophes OK, no digits). Example: Joao Silva.')
        $ErrProvider.SetError($TxtFirstName, 'Fill first/last name - letters only.')
    }
    $un = (Remove-Diacritics $TxtUsername.Text).Trim().ToLower()
    if (-not (Test-Username $un)) {
        $errs.Add('Username must be firstname.surname - all lowercase, with a single dot between the two names, no numbers or spaces (example: joao.silva). It becomes the Windows login and the e-mail address, so it has to be exact.')
        $ErrProvider.SetError($TxtUsername, 'Use firstname.surname (lowercase, one dot). Ex: joao.silva')
    }
    if ($RadioStatic.Checked -and -not (Test-Ipv4 $TxtIp.Text)) {
        $errs.Add('Static IP: four numbers from 0 to 255 separated by dots. Example: 10.0.1.50.')
        $ErrProvider.SetError($TxtIp, 'Four numbers 0-255 with dots. Ex: 10.0.1.50')
    }
    if ($errs.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Some fields need fixing before we can start:`n`n - " + ($errs -join "`n - "),
            'Setup - check the form', 'OK', 'Warning') | Out-Null
        return
    }
    $Form.Tag = 'OK'
    $Form.Close()
})
$Form.Controls.Add($BtnOk)

# Event: domain changes -> reload sectors
$CmbDomain.Add_SelectedIndexChanged({
    if ($CmbDomain.SelectedIndex -lt 0) { return }
    $d  = $CmbDomain.SelectedItem.ToString()
    $dp = Join-Path $PathSignatures $d
    $CmbSector.Items.Clear()
    if (Test-Path $dp) {
        $dirs = @(Get-ChildItem -Path $dp -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        if ($dirs.Count -gt 0) { $dirs | ForEach-Object { $CmbSector.Items.Add($_) | Out-Null } }
        else { $CmbSector.Items.Add('(No sectors)') | Out-Null }
    } else {
        $CmbSector.Items.Add('(Folder not found)') | Out-Null
    }
    if ($CmbSector.Items.Count -gt 0) { $CmbSector.SelectedIndex = 0 }
})

# Event: sector changes -> reload available .htm files
$CmbSector.Add_SelectedIndexChanged({
    if ($CmbSector.SelectedIndex -lt 0 -or -not $CmbDomain.SelectedItem) { return }
    $d = $CmbDomain.SelectedItem.ToString()
    $s = $CmbSector.SelectedItem.ToString()
    $CmbSigTemplate.Items.Clear()
    $CmbSigTemplate.Items.Add('(Automatic - first found)') | Out-Null
    if ($s -notmatch '^\(') {
        $sp = Join-Path (Join-Path $PathSignatures $d) $s
        if (Test-Path $sp) {
            Get-ChildItem -Path $sp -Filter '*.htm' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^[._]' } |
                ForEach-Object { $CmbSigTemplate.Items.Add($_.Name) | Out-Null }
        }
    }
    $CmbSigTemplate.SelectedIndex = 0
})

# Initial load: fire the domain event to populate sectors and templates
$CmbDomain.SelectedIndex = -1
$CmbDomain.SelectedIndex = 0

# Real-time email preview (username@domain). Registered after the initial load so it does not
# fire during population; called once explicitly to set the starting text.
$UpdateEmail = {
    $u = $TxtUsername.Text.Trim().ToLower()
    $d = if ($CmbDomain.SelectedItem) { $CmbDomain.SelectedItem.ToString() } else { '' }
    $LblEmail.Text = if ($u) { "Email: $u@$d" } else { 'Email: ---' }
}
$TxtUsername.Add_TextChanged($UpdateEmail)
$CmbDomain.Add_SelectedIndexChanged($UpdateEmail)
& $UpdateEmail

# Size the window height to the assembled content (grouped layout builds $y as it goes)
$Form.ClientSize = New-Object System.Drawing.Size($CW, $y)

$Form.ShowDialog() | Out-Null

if ($Form.Tag -ne 'OK') {
    Write-Log 'WARN' "Setup cancelled (input form closed)"
    exit 0
}

$FullName        = Format-FullName $TxtFullName.Text
$Username        = (Remove-Diacritics $TxtUsername.Text).Trim().ToLower()
$EmailDomain     = if ($CmbDomain.SelectedItem) { $CmbDomain.SelectedItem.ToString() } else { $EmailDomains[0] }
$Email           = "$Username@$EmailDomain"
$UseStatic       = $RadioStatic.Checked
$StaticIp        = if ($UseStatic) { $TxtIp.Text.Trim() } else { '' }
# DropDownList: index 0 = (None); items 1..N map to $Printers[0..N-1].
$PrinterIdx      = $CmbPrinter.SelectedIndex
$SelectedPrinter = if ($PrinterIdx -gt 0) { $Printers[$PrinterIdx - 1] } else { $null }
$SectorName      = if ($CmbSector.SelectedItem) { $CmbSector.SelectedItem.ToString() } else { '' }
$SigTemplate     = if ($CmbSigTemplate.SelectedItem) { $CmbSigTemplate.SelectedItem.ToString() } else { '(Automatic - first found)' }
$InstallWebAgent = $ChkWebAgent.Checked

} catch {
    Write-Log 'FATAL' "Input GUI failed: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show(
        "Fatal GUI error:`n$($_.Exception.Message)",
        'Setup - Fatal Error', 'OK', 'Error') | Out-Null
    exit 1
}

} else {
    $EmailDomain     = if ($TestDomain) { $TestDomain } else { $EmailDomains[0] }
    $FullName        = $TestFullName
    $Username        = $TestUsername.ToLower()
    $Email           = "$Username@$EmailDomain"
    $UseStatic       = $TestStaticIp.IsPresent
    $StaticIp        = if ($UseStatic) { $TestIpAddress } else { '' }
    $SelectedPrinter = if ($Printers.Count -gt 0) { $Printers[0] } else { $null }

    $sigDomainPath = Join-Path $PathSignatures $EmailDomain
    $SectorName    = if ($TestSector) {
        $TestSector
    } elseif (Test-Path $sigDomainPath) {
        (Get-ChildItem $sigDomainPath -Directory -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty Name)
    } else { '' }

    $SigTemplate     = '(Automatic - first found)'
    $InstallWebAgent = $TestWebAgent.IsPresent
}

# Final defensive validation - the single point both paths (GUI + headless -Test*) converge on.
# The headless path builds these straight from parameters with no GUI validation, so re-check
# here: a malformed -TestUsername aborts with a clear FATAL before any New-LocalUser.
$FullName = Format-FullName $FullName
$Username = (Remove-Diacritics $Username).Trim().ToLower()
$Email    = "$Username@$EmailDomain"
$capErrs  = [System.Collections.Generic.List[string]]::new()
if (-not $FullName)                              { $capErrs.Add("Full name has no usable letters: '$FullName'") }
if (-not (Test-Username $Username))              { $capErrs.Add("Username not name.surname: '$Username'") }
if ($UseStatic -and -not (Test-Ipv4 $StaticIp))  { $capErrs.Add("Static IP invalid: '$StaticIp'") }
if ($capErrs.Count -gt 0) {
    $m = "Input validation failed:`n - " + ($capErrs -join "`n - ")
    Write-Log 'FATAL' $m
    if ($useUI) { [System.Windows.Forms.MessageBox]::Show($m, 'Setup - invalid input', 'OK', 'Error') | Out-Null }
    exit 1
}

# Launch the live progress window now (interactive only). From here, every Write-Log streams
# into it. The work below runs on THIS thread; the window has its own thread + message loop.
# The window is COSMETIC: if it fails to launch (e.g. STA thread error), degrade to file+host
# logging - never abort a machine provision over a progress window. Resetting the three UI
# vars to $null makes the rest of the run behave exactly like the headless path.
if ($useUI) {
    try {
        Start-ProgressWindow
    } catch {
        Write-Log 'WARN' "Progress window failed to launch (continuing without it): $($_.Exception.Message)"
        $script:LogQueue = $null
        $script:UiState  = $null
        $script:ProgUI   = $null
    }
}

Write-Log 'INFO' "Mode: $(if ($useUI) { 'interactive' } else { 'unattended' })"
Write-Log 'INFO' "Name=$FullName | User=$Username | Email=$Email"
Write-Log 'INFO' "Network=$(if ($UseStatic) { "Static $StaticIp" } else { 'DHCP' })"
Write-Log 'INFO' "Printer=$(if ($SelectedPrinter) { $SelectedPrinter.name } else { 'None' })"
Write-Log 'INFO' "Sector=$SectorName | Template=$SigTemplate | WebAgent=$InstallWebAgent"

# ============================================================
# PHASE A - machine-scope provisioning (FIRST point that mutates the machine)
# ============================================================
# Everything above only READ config/printers and collected inputs; a Cancel on the form exited 0
# having changed nothing. From here down the machine is mutated, so these steps run ONLY after the
# operator confirmed (form OK) or in headless mode - never on Cancel. This kills the old
# "cancel after mutations -> exit 0 on a half-changed machine" bug.
Set-Phase 'Phase A - activation, admin password, network base, installers'

# Activate Windows with the OEM key from the UEFI firmware (Dell OA3)
try {
    $oemKey = (Get-CimInstance SoftwareLicensingService -ErrorAction Stop).OA3xOriginalProductKey
    if ($oemKey -and $oemKey.Trim().Length -gt 0) {
        cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /ipk $oemKey 2>&1 | Out-Null
        # /ipk via cscript is synchronous (cscript waits for the script); /ato can follow directly.
        cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /ato 2>&1 | Out-Null
        Write-Log 'OK' "OEM firmware key applied and activation requested"
    } else {
        Write-Log 'WARN' "No OEM key found in the UEFI firmware"
    }
} catch {
    # Activation is best-effort and never blocks provisioning (the machine works
    # unactivated). A sandbox/VM has no firmware OEM key, so this WARNs rather than ERRORs
    # to avoid failing the whole run on a non-critical step. Verify activation in the checklist.
    Write-Log 'WARN' "OEM activation skipped/failed: $($_.Exception.Message)"
}

# Rotate the admin account bootstrap password ($AdminAccount, created by autounattend)
# to the real password from config.ps1
try {
    $adminPass = ConvertTo-SecureString $AdminNewPass -AsPlainText -Force
    Set-LocalUser -Name $AdminAccount -Password $adminPass -ErrorAction Stop
    Write-Log 'OK' "$AdminAccount password updated (bootstrap removed)"
    # The bootstrap password now lives only in autounattend.xml on the USB (base64-encoded, not
    # encrypted) and in Windows' own copy at Panther\unattend.xml. It has been rotated, so both are
    # dead weight + a credential on disk: scrub them. (config.ps1 stays - run.bat may re-run setup.)
    foreach ($u in @((Join-Path $ScriptDir 'autounattend.xml'), "$env:WINDIR\Panther\unattend.xml")) {
        if (Test-Path $u) {
            try { Remove-Item -LiteralPath $u -Force -ErrorAction Stop; Write-Log 'OK' "Removed bootstrap credential file: $u" }
            catch { Write-Log 'WARN' "Could not remove ${u}: $($_.Exception.Message)" }
        }
    }
} catch {
    Write-Log 'ERROR' "Rotate ${AdminAccount} password: $($_.Exception.Message)"
    # Failing here leaves the machine on the BOOTSTRAP password (the autounattend one). Treat it
    # as serious: a blocking alert in interactive mode + the error is already in the final summary (exit 1).
    if (-not $Unattended) {
        [System.Windows.Forms.MessageBox]::Show(
            "FAILED TO ROTATE THE $AdminAccount PASSWORD.`n`nThe machine is on the BOOTSTRAP password. " +
            "Change it manually BEFORE handing it over (e.g. net user $AdminAccount *).`n`nError: $($_.Exception.Message)",
            'Setup - SECURITY RISK', 'OK', 'Error') | Out-Null
    }
}

# WiFi (brings up internet for the Ninite download below)
if ($WifiSSID) { try {
    $escapedSSID = [System.Security.SecurityElement]::Escape($WifiSSID)
    $escapedPass = [System.Security.SecurityElement]::Escape($WifiPass)
    $wifiXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$escapedSSID</name>
  <SSIDConfig><SSID><name>$escapedSSID</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>auto</connectionMode>
  <MSM><security>
    <authEncryption>
      <authentication>WPA2PSK</authentication>
      <encryption>AES</encryption>
      <useOneX>false</useOneX>
    </authEncryption>
    <sharedKey>
      <keyType>passPhrase</keyType>
      <protected>false</protected>
      <keyMaterial>$escapedPass</keyMaterial>
    </sharedKey>
  </security></MSM>
</WLANProfile>
"@
    $wifiXmlPath = "$env:TEMP\corp_wifi_profile.xml"
    try {
        Set-Content -Path $wifiXmlPath -Value $wifiXml -Encoding UTF8
        netsh wlan add profile filename="$wifiXmlPath" 2>&1 | Out-Null
        # add profile writes the profile synchronously; connect can be issued directly.
        netsh wlan connect name="$WifiSSID" 2>&1 | Out-Null
        Write-Log 'OK' "WiFi $WifiSSID configured"
    } finally {
        # The temp profile holds the WPA2 PSK in plaintext; delete it as soon as netsh imported
        # it (previously it was left behind, readable, in %TEMP%).
        Remove-Item -Path $wifiXmlPath -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-Log 'WARN' "WiFi: $($_.Exception.Message)"
} } else { Write-Log 'WARN' "WiFi skipped (WifiSSID empty)" }

# Background-installer pool. Defined before first use; Ninite starts here (the longest installer)
# and downloads while PHASE 4-6 run; the rest of the pool joins in PHASE 7. MSI mutex: Ninite and
# WebAgent never overlap (WebAgent only runs in PHASE 7, after the pool). NOTE: Ninite used to be
# launched pre-form to overlap form entry; it moved here so nothing mutates before the operator
# confirms. Stage 2 will re-introduce safe overlap.
$BgInstalls = [System.Collections.Generic.List[object]]::new()
function Start-BgInstall {
    param([string]$Name, [string]$FilePath, [string[]]$ArgumentList = @(), [int[]]$OkCodes = @(0), [string]$WorkingDirectory)
    $params = @{ FilePath = $FilePath; PassThru = $true }
    if ($ArgumentList.Count) { $params['ArgumentList'] = $ArgumentList }
    # ODT (and any installer that resolves source files relative to CWD) needs a deterministic
    # working dir; without it Start-Process inherits whatever launched setup.ps1 (system32).
    if ($WorkingDirectory) { $params['WorkingDirectory'] = $WorkingDirectory }
    $proc = Start-Process @params
    $BgInstalls.Add([pscustomobject]@{ Name = $Name; Proc = $proc; OkCodes = $OkCodes })
    Write-Log 'INFO' "$Name started in the background (PID $($proc.Id))"
    return $proc
}

$NinitePath = Join-Path $ScriptDir 'ninite.exe'
if (Test-Path $NinitePath) {
    try { Start-BgInstall 'Ninite' $NinitePath | Out-Null }
    catch { Write-Log 'ERROR' "Ninite: $($_.Exception.Message)" }
} else {
    Write-Log 'WARN' "ninite.exe not found on the USB"
}

# ============================================================
# PHASE 4 - Rename PC + create user + network + wallpaper
# ============================================================
Set-Phase 'Phase 4 - rename PC, create user, network, wallpaper'

# Rename the PC to the BIOS serial
try {
    $sn = (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber
    if ($sn -and $sn.Trim().Length -gt 0 -and $sn -notmatch 'O\.E\.M\.|Default|System Serial|To Be Filled') {
        $newName = $sn.Trim() -replace '[^A-Za-z0-9-]', ''
        if ($newName.Length -gt 15) {
            Write-Log 'WARN' "Serial '$newName' exceeds the 15-char NetBIOS limit; truncated to '$($newName.Substring(0, 15))'"
            $newName = $newName.Substring(0, 15)
        }
        if ($env:COMPUTERNAME -eq $newName) {
            Write-Log 'OK' "PC already named $newName"
        } else {
            Rename-Computer -NewName $newName -Force -ErrorAction Stop
            Write-Log 'OK' "PC renamed to: $newName (effective after the next reboot)"
        }
    } else {
        Write-Log 'WARN' "Invalid or generic serial: '$sn' - rename manually"
    }
} catch {
    Write-Log 'ERROR' "Rename PC: $($_.Exception.Message)"
}

# Local user
try {
    # Defense in depth at the use site: never create an account with an invalid name
    # (spaces/digits/uppercase would produce a broken or wrong Windows account).
    if ($Username -match '[^a-z.]') { throw "Refusing to create user with invalid name: '$Username'" }
    $SecPass = ConvertTo-SecureString $UserInitialPass -AsPlainText -Force
    if (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue) {
        Write-Log 'OK' "User already exists: $Username"
    } else {
        New-LocalUser -Name $Username -Password $SecPass -FullName $FullName `
                      -Description 'Created by setup.ps1' -PasswordNeverExpires:$true -ErrorAction Stop | Out-Null
        Write-Log 'OK' "User created: $Username"
    }

    # 'Users' group by SID (S-1-5-32-545) - independent of locale (pt-BR 'Usuarios' vs en 'Users')
    try {
        $usersGroup = (Get-LocalGroup -SID 'S-1-5-32-545' -ErrorAction Stop).Name
        $isMember = @(Get-LocalGroupMember -Group $usersGroup -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like "*\$Username" -or $_.Name -eq $Username }).Count -gt 0
        if ($isMember) {
            Write-Log 'OK' "User $Username already in the $usersGroup group"
        } else {
            Add-LocalGroupMember -Group $usersGroup -Member $Username -ErrorAction Stop
            Write-Log 'OK' "User $Username added to the $usersGroup group"
        }
    } catch {
        Write-Log 'ERROR' "Add to the users group: $($_.Exception.Message)"
    }
} catch {
    Write-Log 'ERROR' "Create user: $($_.Exception.Message)"
}

# Network
try {
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } |
               Select-Object -First 1
    if ($adapter) {
        if ($UseStatic -and $StaticIp) {
            $missNet = @('StaticPrefixLength', 'StaticGateway', 'DnsServers') |
                       Where-Object { -not (Get-Variable $_ -ValueOnly -ErrorAction SilentlyContinue) }
            if ($missNet) { throw "config.ps1 does not define for static IP: $($missNet -join ', ')" }
            # Drop any IP already on the adapter (previous run / manual config) so New-NetIPAddress
            # does not fail with "object already exists".
            Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Remove-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $StaticIp `
                             -PrefixLength $StaticPrefixLength -DefaultGateway $StaticGateway -ErrorAction Stop | Out-Null
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex `
                                       -ServerAddresses $DnsServers -ErrorAction Stop | Out-Null
            Write-Log 'OK' "Static IP: $StaticIp /$StaticPrefixLength GW $StaticGateway"
        } else {
            Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Remove-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Enabled -ErrorAction SilentlyContinue | Out-Null
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
            Write-Log 'OK' "DHCP configured"
        }
    }
} catch {
    Write-Log 'ERROR' "Network: $($_.Exception.Message)"
}

# Wallpaper: COPY the image into %WINDIR% so Phase B (per-user, post-reboot) can apply it from a
# machine-wide path. Applying it live HERE is pointless - this runs as the bootstrap admin, not the
# new user - so the HKCU apply + SystemParametersInfo refresh moved to phase-b.ps1. (Only if
# config.ps1 set WallpaperFile - avoids Join-Path with $null under StrictMode.)
$WallpaperSrc = if ($WallpaperFile) { Join-Path $ScriptDir $WallpaperFile } else { $null }
if ($WallpaperSrc -and (Test-Path $WallpaperSrc)) {
    try {
        $WallpaperDest = "$env:WINDIR\Web\Wallpaper\Corp"
        New-Item -ItemType Directory -Path $WallpaperDest -Force | Out-Null
        Copy-Item $WallpaperSrc "$WallpaperDest\wallpaper.jpg" -Force
        $script:WallpaperStaged = "$WallpaperDest\wallpaper.jpg"
        Write-Log 'OK' "Wallpaper staged: $script:WallpaperStaged"
    } catch {
        Write-Log 'ERROR' "Wallpaper: $($_.Exception.Message)"
    }
}

# ============================================================
# PHASE 5 - Install programs (the rest of the pool, in parallel)
# ============================================================
# Ninite was already launched in the pre-GUI step (downloading during form entry). Here go the
# rest via Start-BgInstall (no -Wait): Office (Click-to-Run, separate engine), Belarc and Epson
# (EXE /S). The join is in PHASE 7; the signature (PHASE 6) runs overlapped. WebAgent (MSI) only
# in PHASE 7, after the pool (mutex _MSIExecute / error 1618).
Set-Phase 'Phase 5 - installing programs (parallel)'

# Office (pool) - Click-to-Run is a separate engine from msiexec, runs in parallel
try {
    $officeOdt   = Join-Path $PathOffice 'setup.exe'
    $officeLocal = Join-Path $ScriptDir 'OfficeSetup.exe'
    if (Test-Path $officeOdt) {
        # ODT setup.exe needs an action verb; with no args it is a SILENT no-op (installs nothing,
        # exits 0 -> would log as OK and fool us). configuration.xml is mandatory: it tells ODT what
        # to install. Working dir = the Office folder so /configure finds the pre-downloaded
        # \Office\Data next to setup.exe (no SourcePath in the XML -> portable across drive letters).
        $confXml = Join-Path $PathOffice 'configuration.xml'
        if (Test-Path $confXml) {
            Start-BgInstall 'Office ODT' $officeOdt @('/configure', $confXml) -WorkingDirectory $PathOffice | Out-Null
        } else {
            Write-Log 'ERROR' "Office ODT setup.exe found but configuration.xml missing in $PathOffice (copy configuration.example.xml) - skipped"
        }
    } elseif (Test-Path $officeLocal) {
        Start-BgInstall 'Office Click-to-Run' $officeLocal | Out-Null
    } else {
        Write-Log 'WARN' "Office installer not found (ODT: $officeOdt | USB: $officeLocal)"
    }
} catch { Write-Log 'ERROR' "Office: $($_.Exception.Message)" }

# Belarc (pool) - EXE /S
try {
    # Match by name (belarc*.exe), NOT the first *.exe: the USB root also holds the Windows
    # installer's setup.exe, and a broad *.exe filter would launch the Win11 setup (modal,
    # freezes Phase A) instead of Belarc. See config: $PathBelarc = USB root.
    $belarc = Get-ChildItem -Path $PathBelarc -Filter 'belarc*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($belarc) { Start-BgInstall 'Belarc' $belarc.FullName @('/S') | Out-Null }
    else { Write-Log 'WARN' "Belarc installer not found in $PathBelarc" }
} catch { Write-Log 'ERROR' "Belarc: $($_.Exception.Message)" }

# Epson driver (pool) + TCP/IP port. The printer is added in PHASE 7, after the driver
# registers (the join guarantees the installer exited). The port does not depend on the
# driver, so it is created here.
$script:PrinterPort = $null
$script:PrinterInstalled = $false
if ($SelectedPrinter) {
    try {
        $epson = Get-ChildItem -Path $PathEpson -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($epson) { Start-BgInstall 'Epson driver' $epson.FullName @('/S') | Out-Null }
        else { Write-Log 'WARN' "Epson installer not found in $PathEpson" }
        $script:PrinterPort = "IP_$($SelectedPrinter.ip)"
        Add-PrinterPort -Name $script:PrinterPort -PrinterHostAddress $SelectedPrinter.ip -ErrorAction SilentlyContinue
    } catch { Write-Log 'ERROR' "Printer (prep): $($_.Exception.Message)" }
}

# WebAgent runs in PHASE 7 - it is msiexec, waits for the pool (Ninite) so they don't collide on the mutex.

# (PHASE 6 - Outlook signature - moved to Phase B (phase-b.ps1). It must land in the NEW user's own
# %APPDATA%\Microsoft\Signatures after the reboot+AutoLogon, not the bootstrap admin's profile, so it
# can no longer run here. Phase A only STAGES the template tree under C:\ProgramData\CorpSetup in
# PHASE 8; phase-b.ps1 reads it and writes the signature as the user.)

# ============================================================
# PHASE 7 - Join the installers + dependent steps + checklist
# ============================================================
Set-Phase 'Phase 7 - finishing installers and dependent steps'

# Join: wait for each pool installer to finish and evaluate its exit code. Blocking is fine -
# the progress window lives on its own thread, so it stays responsive while we wait here.
foreach ($bgItem in $BgInstalls) {
    try {
        if ($bgItem.Proc) {
            $bgItem.Proc.WaitForExit()
            Write-ProcResult $bgItem.Name $bgItem.Proc $bgItem.OkCodes
        } else {
            Write-Log 'ERROR' "$($bgItem.Name): process did not start (skipped join)"
        }
    } catch { Write-Log 'ERROR' "$($bgItem.Name) (join): $($_.Exception.Message)" }
}

# Printer: the Epson driver already finished (join above). Short poll for the driver
# registration (it can lag a few seconds after the installer exits) and add the printer.
if ($SelectedPrinter -and $script:PrinterPort) {
    try {
        $driverName = $null
        for ($d = 0; $d -lt 60 -and -not $driverName; $d++) {
            $driverObj = Get-PrinterDriver -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -match 'Epson' } | Select-Object -First 1
            if ($driverObj) { $driverName = $driverObj.Name } else { Start-Sleep -Milliseconds 500 }
        }
        if ($driverName) {
            Add-Printer -Name $SelectedPrinter.name -DriverName $driverName `
                        -PortName $script:PrinterPort -ErrorAction Stop | Out-Null
            $script:PrinterInstalled = $true
            Write-Log 'OK' "Printer: $($SelectedPrinter.name) [$($SelectedPrinter.ip)]"
        } else {
            Write-Log 'WARN' "Epson driver not located - add the printer manually"
        }
    } catch { Write-Log 'ERROR' "Printer: $($_.Exception.Message)" }
}

# WebAgent (msiexec) - the pool/Ninite finished now, so the Installer mutex is free.
# Tries MSI > ZIP (extracts MSI) > legacy EXE.
if ($InstallWebAgent) {
    try {
        $waMsi = Get-ChildItem -Path $PathWebAgent -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
        $waZip = Get-ChildItem -Path $PathWebAgent -Filter '*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
        $waExe = Get-ChildItem -Path $PathWebAgent -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($waMsi) {
            Write-Log 'INFO' "WebAgent MSI: $($waMsi.Name)"
            $p = Invoke-InstallerWithTimeout 'msiexec.exe' @('/i', "`"$($waMsi.FullName)`"", '/quiet', '/norestart')
            if ($p) { Write-ProcResult 'WebAgent (MSI)' $p @(0, 3010) }
        } elseif ($waZip) {
            Write-Log 'INFO' "WebAgent ZIP: $($waZip.Name) - extracting..."
            $extractDir = "$env:TEMP\webagent_extract"
            New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
            Expand-Archive -Path $waZip.FullName -DestinationPath $extractDir -Force
            $msiInZip = Get-ChildItem -Path $extractDir -Filter '*.msi' -Recurse | Select-Object -First 1
            if ($msiInZip) {
                $p = Invoke-InstallerWithTimeout 'msiexec.exe' @('/i', "`"$($msiInZip.FullName)`"", '/quiet', '/norestart')
                if ($p) { Write-ProcResult 'WebAgent (ZIP)' $p @(0, 3010) }
            } else {
                Write-Log 'WARN' "No MSI found inside the ZIP"
            }
        } elseif ($waExe) {
            Write-Log 'INFO' "WebAgent EXE (legacy): $($waExe.Name)"
            $p = Invoke-InstallerWithTimeout $waExe.FullName @('/S')
            if ($p) { Write-ProcResult 'WebAgent (EXE)' $p }
        } else {
            Write-Log 'WARN' "WebAgent installer not found in $PathWebAgent"
        }
    } catch { Write-Log 'ERROR' "WebAgent: $($_.Exception.Message)" }
}

$checklist = @"

========================================
  POST-SETUP MANUAL CHECKLIST
========================================
User     : $Username ($FullName)
Email    : $Email
Date     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
PC name  : $env:COMPUTERNAME

PENDING:
[ ] REBOOT to apply the new PC name
[ ] Confirm Windows activation (slmgr /xpr) - OEM activation is best-effort
[ ] Register the machine on the intranet
[ ] Office 365 login: $Email
[ ] Verify the Outlook signature (Phase B applies it on the user's first logon)
[ ] Test the printer: $(if ($SelectedPrinter) { if ($script:PrinterInstalled) { "$($SelectedPrinter.name) [$($SelectedPrinter.ip)]" } else { "$($SelectedPrinter.name) [$($SelectedPrinter.ip)] - INSTALL FAILED, add it manually" } } else { 'None' })
[ ] TOTVS (if requested in the ticket)
[ ] Hand over credentials: login=$Username / password=(see config.ps1 - do not record in the log)
========================================
Log: $LogFile
"@

Add-Content -Path $LogFile -Value $checklist -Encoding UTF8 -ErrorAction SilentlyContinue

# Show the checklist in the progress window (enqueue each line; the file already has it once).
if ($script:LogQueue) {
    foreach ($cl in ($checklist -split "`n")) {
        $script:LogQueue.Enqueue([pscustomobject]@{ Level = 'INFO'; Line = $cl })
    }
}

# ============================================================
# PHASE 8 - Phase B handoff: STAGING (PREP) - only under -EnableHandoff
# ============================================================
# Stage everything Phase B + cleanup need into C:\ProgramData\CorpSetup and register the two
# -AtLogOn tasks. This does NOT arm AutoLogon or reboot - that is the COMMIT block at the very end,
# after the technician has reviewed the log and closed the progress window. Runs here (before the
# exit-code tally) so its log lines stream into the window and any failure counts toward $exitCode.
# The folder keeps the INHERITED ProgramData ACL on purpose: the standard user must READ
# state.json/Signatures and WRITE its logs + user-done here, and that default ACL already stops the
# user from overwriting the admin-owned cleanup.ps1 (which SYSTEM runs) - the only thing worth
# guarding. state.json never holds a credential.
if ($EnableHandoff) {
    Set-Phase 'Phase 8 - Phase B handoff (staging + tasks)'
    $StateDir = Join-Path $env:ProgramData 'CorpSetup'
    try {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

        # state.json - NO credential (the AutoLogon password goes to HKLM in COMMIT, never to disk here).
        $printerName = if ($SelectedPrinter) { $SelectedPrinter.name } else { '' }
        $state = New-CorpStateObject -Username $Username -FullName $FullName -Email $Email `
                    -EmailDomain $EmailDomain -SectorName $SectorName -SigTemplate $SigTemplate `
                    -PrinterName $printerName -WallpaperPath $script:WallpaperStaged
        $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $StateDir 'state.json') -Encoding UTF8 -Force
        Write-Log 'OK' 'state.json written (no credentials)'

        # Stage the Phase B + cleanup scripts off the USB (it may be pulled before the user logs on).
        foreach ($s in 'phase-b.ps1', 'cleanup.ps1') {
            $src = Join-Path $ScriptDir $s
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $StateDir $s) -Force
                Write-Log 'OK' "Staged: $s"
            } else {
                Write-Log 'ERROR' "Handoff: $s not found at $ScriptDir - cannot stage (Phase B will not run)"
            }
        }

        # Stage the selected sector's signature subtree (recursive: *.htm + the <template>_files logo
        # folders). phase-b resolves Signatures\<domain>\<sector>\..., so preserve that two-level depth.
        # Skip when there is no real sector (mirrors phase-b's own '(...)'/empty skip). Isolated in its
        # OWN try/catch: the signature is the SOFT part (phase-b WARN-skips a missing template), so a
        # copy failure (locked asset, MAX_PATH on 5.1) must NOT abort the essential task registration
        # below and brick the whole machine->user handoff.
        if ($SectorName -and $SectorName -notmatch '^\(') {
            try {
                $sigSrc = Join-Path (Join-Path $PathSignatures $EmailDomain) $SectorName
                if (Test-Path -LiteralPath $sigSrc) {
                    # Copy the sector's CONTENTS into the dest sector folder (not the folder itself), so
                    # a re-run (run.bat) overwrites in place instead of nesting <sector>\<sector>.
                    $sigDest = Join-Path $StateDir (Join-Path 'Signatures' (Join-Path $EmailDomain $SectorName))
                    New-Item -ItemType Directory -Path $sigDest -Force | Out-Null
                    Copy-Item -Path (Join-Path $sigSrc '*') -Destination $sigDest -Recurse -Force
                    Write-Log 'OK' "Signature sector staged: $EmailDomain\$SectorName"
                } else {
                    Write-Log 'WARN' "Signature source not found (Phase B will skip signature): $sigSrc"
                }
            } catch {
                Write-Log 'ERROR' "Signature staging (non-fatal, Phase B will skip): $($_.Exception.Message)"
            }
        }

        # Register the two -AtLogOn tasks (idempotent via -Force). Names are the exact contract
        # cleanup.ps1 hardcodes. The user task runs as the new user (resolved by SID - immune to the
        # pending PC rename) in its interactive session; the SYSTEM task runs cleanup at highest priv.
        $userSid = (Get-LocalUser -Name $Username -ErrorAction Stop).SID.Value
        $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

        $uAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
                    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $StateDir 'phase-b.ps1'))
        $uTrig   = New-ScheduledTaskTrigger -AtLogOn -User $Username
        $uTrig.Delay = 'PT30S'   # let the profile / print spooler settle before SetDefaultPrinter
        $uPrin   = New-ScheduledTaskPrincipal -UserId $userSid -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName 'CorpSetup-PhaseB-User' -Action $uAction -Trigger $uTrig `
            -Principal $uPrin -Settings $set -Force | Out-Null
        Write-Log 'OK' 'Task registered: CorpSetup-PhaseB-User'

        $sAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
                    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $StateDir 'cleanup.ps1'))
        $sTrig   = New-ScheduledTaskTrigger -AtLogOn -User $Username
        $sPrin   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName 'CorpSetup-PhaseB-System' -Action $sAction -Trigger $sTrig `
            -Principal $sPrin -Settings $set -Force | Out-Null
        Write-Log 'OK' 'Task registered: CorpSetup-PhaseB-System'

        Write-Log 'INFO' 'Phase B staged. Closing this window will REBOOT the PC to run Phase B.'
    } catch {
        Write-Log 'ERROR' "Handoff staging: $($_.Exception.Message)"
    }
}

if ($script:Errors.Count -gt 0) {
    $s = if ($script:Errors.Count -ne 1) { 's' } else { '' }
    Write-Log 'INFO' "Setup completed with $($script:Errors.Count) error$s"
    if ($script:UiState) { $script:UiState.Status = "Done - $($script:Errors.Count) error$s. Review the red lines above, then close." }
    $exitCode = 1
} else {
    Write-Log 'OK' "setup.ps1 completed without errors"
    if ($script:UiState) { $script:UiState.Status = 'Done - no errors. You may close this window.' }
    $exitCode = 0
}

# Hand the progress window to the technician: mark Done (the Timer enables Close and fills the
# bar), then block until they close it (Application.Run returns) so we don't kill the window on
# exit. If the window was closed early, EndInvoke returns at once and the work still completed.
if ($script:ProgUI) {
    $script:UiState.Done = $true
    try { $script:ProgUI.PS.EndInvoke($script:ProgUI.Handle) } catch { }
    try { $script:ProgUI.PS.Dispose() } catch { }
    try { $script:ProgUI.Runspace.Dispose() } catch { }
}

# ============================================================
# PHASE 8 - Phase B handoff: COMMIT (arm AutoLogon + reboot) - only under -EnableHandoff
# ============================================================
# Runs AFTER the progress window closed (interactive: technician reviewed the log and clicked Close;
# headless production: no window, falls straight through). Arm the one-shot AutoLogon and reboot into
# Phase B. Guarded by HARD preconditions so a half-provisioned box is never armed/rebooted - but NOT
# by $script:Errors: a failed install must not block Phase B (signature/wallpaper/default-printer are
# independent of it).
if ($EnableHandoff) {
    $StateDir = Join-Path $env:ProgramData 'CorpSetup'
    $ready =
        [bool](Get-LocalUser -Name $Username -ErrorAction SilentlyContinue) -and
        (Test-Path -LiteralPath (Join-Path $StateDir 'state.json')) -and
        (Test-Path -LiteralPath (Join-Path $StateDir 'phase-b.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $StateDir 'cleanup.ps1')) -and
        [bool](Get-ScheduledTask -TaskName 'CorpSetup-PhaseB-User'   -ErrorAction SilentlyContinue) -and
        [bool](Get-ScheduledTask -TaskName 'CorpSetup-PhaseB-System' -ErrorAction SilentlyContinue)
    if ($ready) {
        try {
            # 🔓 Declared brecha (accepted in the plan): Winlogon AutoLogon stores the password in
            # PLAINTEXT in HKLM - there is no DPAPI option. One boot only: AutoLogonCount=1 makes
            # Windows consume + clear it even if cleanup never runs, and cleanup.ps1 (SYSTEM) zeroes
            # AND verifies it at the end of Phase B. DefaultDomainName='.' = the local machine,
            # name-independent (the BIOS-serial rename only takes effect on the reboot below).
            $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon'    -Value '1'
            Set-ItemProperty -Path $winlogon -Name 'DefaultUserName'   -Value $Username
            Set-ItemProperty -Path $winlogon -Name 'DefaultDomainName' -Value '.'
            Set-ItemProperty -Path $winlogon -Name 'DefaultPassword'   -Value $UserInitialPass
            Set-ItemProperty -Path $winlogon -Name 'AutoLogonCount'    -Value 1 -Type DWord
            Write-Log 'OK' 'AutoLogon armed for Phase B (one-shot).'
            if (-not $NoReboot) {
                Write-Log 'INFO' 'Rebooting into Phase B...'
                Restart-Computer -Force
            }
        } catch {
            Write-Log 'ERROR' "Arm AutoLogon / reboot: $($_.Exception.Message)"
            $exitCode = 1
        }
    } else {
        Write-Log 'ERROR' 'Handoff preconditions not met - NOT arming AutoLogon / NOT rebooting. Finish Phase B manually.'
        $exitCode = 1
    }
}

# Signals failure to the caller (run.bat / FirstLogonCommands check %errorlevel%).
exit $exitCode
