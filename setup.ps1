#Requires -Version 5.1
param(
    [switch]$Unattended,
    [string]$TestFullName  = 'Test User',
    [string]$TestUsername  = 'test.user',
    [string]$TestDomain    = '',
    [string]$TestSector    = '',
    [switch]$TestStaticIp,
    [string]$TestIpAddress = '',
    [switch]$TestWebAgent
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# setup.ps1 - Windows 11 Setup
# Run automatically by autounattend.xml on the first login
# Requires: config.ps1 at the USB root (gitignored, never commit)
# ============================================================

$LogFile      = "$env:USERPROFILE\Desktop\win11_setup_log.txt"
$ScriptDir    = $PSScriptRoot
$script:Erros = [System.Collections.Generic.List[string]]::new()

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
        $script:Erros.Add("[$Level] $Msg") | Out-Null
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

# --- Input-form helpers (used by the PHASE 3 ShowDialog form, at script scope) ---
function Add-Label([System.Windows.Forms.Control]$c, [string]$text, [int]$x, [int]$y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text     = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.AutoSize = $true
    $c.Controls.Add($l)
}
function New-TextBox([int]$x, [int]$y, [int]$w = 480) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.Size     = New-Object System.Drawing.Size($w, 23)
    return $t
}
function New-Combo([int]$x, [int]$y, [int]$w = 480) {
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.Location      = New-Object System.Drawing.Point($x, $y)
    $cb.Size          = New-Object System.Drawing.Size($w, 23)
    $cb.DropDownStyle = 'DropDownList'
    return $cb
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

# ============================================================
# PHASE 2 - WiFi, share and initial data
# ============================================================

# WiFi
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
    Set-Content -Path $wifiXmlPath -Value $wifiXml -Encoding UTF8
    netsh wlan add profile filename="$wifiXmlPath" 2>&1 | Out-Null
    # add profile writes the profile synchronously; connect can be issued directly.
    netsh wlan connect name="$WifiSSID" 2>&1 | Out-Null
    Write-Log 'OK' "WiFi $WifiSSID configured"
} catch {
    Write-Log 'WARN' "WiFi: $($_.Exception.Message)"
} } else { Write-Log 'WARN' "WiFi skipped (WifiSSID empty)" }

# Map the share
if ($SharePath) { try {
    New-SmbMapping -RemotePath $SharePath -UserName $ShareUser -Password $SharePass -Persistent $false -ErrorAction Stop | Out-Null
    Write-Log 'OK' "Share mapped: $SharePath"
} catch {
    Write-Log 'WARN' "Share: $($_.Exception.Message)"
} } else { Write-Log 'WARN' "Share skipped (SharePath empty)" }

# Load printers.json from the USB
$Printers = @()
$PrintersJson = Join-Path $ScriptDir 'printers.json'
if (Test-Path $PrintersJson) {
    try {
        $Printers = @(Get-Content $PrintersJson -Raw -Encoding UTF8 | ConvertFrom-Json)
        Write-Log 'OK' "$($Printers.Count) printers loaded"
    } catch {
        Write-Log 'ERROR' "printers.json: $($_.Exception.Message)"
    }
} else {
    Write-Log 'WARN' "printers.json not found on the USB"
}

# ============================================================
# Pre-GUI - kick off Ninite early (overlaps with the technician filling the form)
# ============================================================
# Ninite is the longest installer (downloads several apps from the internet). Launched HERE,
# it downloads while the technician fills the form (dead time). Internet comes from the WiFi
# (PHASE 2, DHCP, already up); it does not depend on Ethernet, which is configured in PHASE 4.
# The pool infra (Start-BgInstall/$BgInstalls) is defined here and reused in PHASE 5; the join
# of all of them is in PHASE 7. MSI mutex: Ninite and WebAgent never overlap (WebAgent only runs
# in PHASE 7, after the pool).
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
# PHASE 3 - Collect inputs (modal input form) or resolve from -Test* params
# ============================================================
# Interactive: a MODAL input form (ShowDialog = real message loop, rock-solid - no DoEvents).
# It only collects values, then closes. The live progress window is launched afterwards in a
# separate runspace (see Start-ProgressWindow). Headless ($Unattended / no desktop): values
# come from -Test* params and no window is shown.

$useUI = (-not $Unattended) -and [System.Environment]::UserInteractive

if ($useUI) {
try {

$Form = New-Object System.Windows.Forms.Form
$Form.Text            = 'New Machine Setup'
$Form.Size            = New-Object System.Drawing.Size(520, 640)
$Form.StartPosition   = 'CenterScreen'
$Form.FormBorderStyle = 'FixedDialog'
$Form.MaximizeBox     = $false

$y = 12

Add-Label $Form 'Full name (from the ticket):' 10 $y; $y += 20
$TxtFullName = New-TextBox 10 $y; $Form.Controls.Add($TxtFullName); $y += 35

Add-Label $Form 'Username (e.g. joao.silva):' 10 $y; $y += 20
$TxtUsername = New-TextBox 10 $y; $Form.Controls.Add($TxtUsername); $y += 35

Add-Label $Form 'Email domain:' 10 $y; $y += 20
$CmbDomain = New-Combo 10 $y 300
$EmailDomains | ForEach-Object { $CmbDomain.Items.Add($_) | Out-Null }
$CmbDomain.SelectedIndex = 0
$Form.Controls.Add($CmbDomain); $y += 35

Add-Label $Form 'Network configuration:' 10 $y; $y += 20
$RadioDhcp            = New-Object System.Windows.Forms.RadioButton
$RadioDhcp.Text       = 'DHCP (automatic)'
$RadioDhcp.Location   = New-Object System.Drawing.Point(10, $y)
$RadioDhcp.AutoSize   = $true
$RadioDhcp.Checked    = $true
$RadioStatic          = New-Object System.Windows.Forms.RadioButton
$RadioStatic.Text     = 'Static IP'
$RadioStatic.Location = New-Object System.Drawing.Point(190, $y)
$RadioStatic.AutoSize = $true
$Form.Controls.Add($RadioDhcp); $Form.Controls.Add($RadioStatic); $y += 30

$LblIp          = New-Object System.Windows.Forms.Label
$LblIp.Text     = 'IP (e.g. 10.0.X.X):'
$LblIp.Location = New-Object System.Drawing.Point(10, $y)
$LblIp.AutoSize = $true
$LblIp.Visible  = $false
$TxtIp          = New-TextBox 140 $y 160
$TxtIp.Visible  = $false
$Form.Controls.Add($LblIp); $Form.Controls.Add($TxtIp); $y += 35

$RadioStatic.Add_CheckedChanged({ $LblIp.Visible = $RadioStatic.Checked; $TxtIp.Visible = $RadioStatic.Checked })
$RadioDhcp.Add_CheckedChanged({   $LblIp.Visible = $RadioStatic.Checked; $TxtIp.Visible = $RadioStatic.Checked })

Add-Label $Form 'Main printer:' 10 $y; $y += 20
$CmbPrinter = New-Combo 10 $y
$CmbPrinter.Items.Add('(None)') | Out-Null
foreach ($p in $Printers) { $CmbPrinter.Items.Add("$($p.name) - $($p.model) [$($p.ip)]") | Out-Null }
$CmbPrinter.SelectedIndex = 0
$Form.Controls.Add($CmbPrinter); $y += 35

Add-Label $Form 'Sector (for the signature):' 10 $y; $y += 20
$CmbSector = New-Combo 10 $y
$Form.Controls.Add($CmbSector); $y += 35

Add-Label $Form 'Base signature (.htm):' 10 $y; $y += 20
$CmbSigTemplate = New-Combo 10 $y
$CmbSigTemplate.Items.Add('(Automatic - first found)') | Out-Null
$CmbSigTemplate.SelectedIndex = 0
$Form.Controls.Add($CmbSigTemplate); $y += 35

$ChkWebAgent          = New-Object System.Windows.Forms.CheckBox
$ChkWebAgent.Text     = 'Install WebAgent'
$ChkWebAgent.Location = New-Object System.Drawing.Point(10, $y)
$ChkWebAgent.AutoSize = $true
$Form.Controls.Add($ChkWebAgent); $y += 40

$BtnOk          = New-Object System.Windows.Forms.Button
$BtnOk.Text     = 'Start setup'
$BtnOk.Location = New-Object System.Drawing.Point(10, $y)
$BtnOk.Size     = New-Object System.Drawing.Size(480, 35)
$BtnOk.Add_Click({
    if (-not $TxtFullName.Text.Trim()) {
        [System.Windows.Forms.MessageBox]::Show('Fill in the full name.', 'Setup', 'OK', 'Warning') | Out-Null; return
    }
    if (-not $TxtUsername.Text.Trim()) {
        [System.Windows.Forms.MessageBox]::Show('Fill in the username.', 'Setup', 'OK', 'Warning') | Out-Null; return
    }
    if ($RadioStatic.Checked -and -not $TxtIp.Text.Trim()) {
        [System.Windows.Forms.MessageBox]::Show('Fill in the static IP.', 'Setup', 'OK', 'Warning') | Out-Null; return
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

$Form.ShowDialog() | Out-Null

if ($Form.Tag -ne 'OK') {
    Write-Log 'WARN' "Setup cancelled (input form closed)"
    exit 0
}

$FullName        = $TxtFullName.Text.Trim()
$Username        = $TxtUsername.Text.Trim().ToLower()
$EmailDomain     = if ($CmbDomain.SelectedItem) { $CmbDomain.SelectedItem.ToString() } else { $EmailDomains[0] }
$Email           = "$Username@$EmailDomain"
$UseStatic       = $RadioStatic.Checked
$StaticIp        = if ($UseStatic) { $TxtIp.Text.Trim() } else { '' }
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
# PHASE 4 - Rename PC + create user + network + wallpaper
# ============================================================
Set-Phase 'Phase 4 - rename PC, create user, network, wallpaper'

# Rename the PC to the BIOS serial
try {
    $sn = (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber
    if ($sn -and $sn.Trim().Length -gt 0 -and $sn -notmatch 'O\.E\.M\.|Default|System Serial|To Be Filled') {
        $newName = $sn.Trim() -replace '[^A-Za-z0-9-]', ''
        if ($newName.Length -gt 15) { $newName = $newName.Substring(0, 15) }
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

# Wallpaper (only if config.ps1 set WallpaperFile - avoids Join-Path with $null under StrictMode)
$WallpaperSrc = if ($WallpaperFile) { Join-Path $ScriptDir $WallpaperFile } else { $null }
if ($WallpaperSrc -and (Test-Path $WallpaperSrc)) {
    try {
        $WallpaperDest = "$env:WINDIR\Web\Wallpaper\Corp"
        New-Item -ItemType Directory -Path $WallpaperDest -Force | Out-Null
        Copy-Item $WallpaperSrc "$WallpaperDest\wallpaper.jpg" -Force
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class CorpWallpaper {
    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
        [CorpWallpaper]::SystemParametersInfo(20, 0, "$WallpaperDest\wallpaper.jpg", 3) | Out-Null
        Write-Log 'OK' "Wallpaper applied"
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
    $belarc = Get-ChildItem -Path $PathBelarc -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($belarc) { Start-BgInstall 'Belarc' $belarc.FullName @('/S') | Out-Null }
    else { Write-Log 'WARN' "Belarc installer not found in $PathBelarc" }
} catch { Write-Log 'ERROR' "Belarc: $($_.Exception.Message)" }

# Epson driver (pool) + TCP/IP port. The printer is added in PHASE 7, after the driver
# registers (the join guarantees the installer exited). The port does not depend on the
# driver, so it is created here.
$script:PrinterPort = $null
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

# ============================================================
# PHASE 6 - Outlook signature
# ============================================================
Set-Phase 'Phase 6 - Outlook signature'

if ($SectorName -and $SectorName -notmatch '^\(') {
    try {
        $sectorPath = Join-Path (Join-Path $PathSignatures $EmailDomain) $SectorName

        if ($SigTemplate -eq '(Automatic - first found)') {
            $srcFile = Get-ChildItem -Path $sectorPath -Filter '*.htm' -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -notmatch '^[._]' } | Select-Object -First 1
        } else {
            $srcFile = Get-Item -Path (Join-Path $sectorPath $SigTemplate) -ErrorAction SilentlyContinue
        }

        if ($srcFile) {
            $content = [System.IO.File]::ReadAllText($srcFile.FullName, [System.Text.Encoding]::UTF8)

            # Detect the old email
            $emailMatch = [regex]::Match($content, '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}')
            $oldEmail   = if ($emailMatch.Success) { $emailMatch.Value } else { '' }

            # Detect the old name in the bold span
            $nameMatch  = [regex]::Match($content, 'font-weight:\s*bold[^>]*>([^<]+)')
            $oldName    = if ($nameMatch.Success) { $nameMatch.Groups[1].Value.Trim() } else { '' }

            $newContent = $content
            if ($oldEmail) { $newContent = $newContent -replace [regex]::Escape($oldEmail), $Email }
            if ($oldName)  { $newContent = $newContent -replace [regex]::Escape($oldName),  $FullName }

            $sigFolder = "$env:APPDATA\Microsoft\Signatures"
            New-Item -ItemType Directory -Path $sigFolder -Force | Out-Null
            [System.IO.File]::WriteAllText("$sigFolder\$Username.htm", $newContent, [System.Text.Encoding]::UTF8)

            Write-Log 'OK' "Signature created: $sigFolder\$Username.htm"
            Write-Log 'INFO' "Base: $($srcFile.Name) | '$oldName' -> '$FullName' | '$oldEmail' -> '$Email'"
        } else {
            Write-Log 'WARN' "No .htm found in: $sectorPath"
        }
    } catch { Write-Log 'ERROR' "Signature: $($_.Exception.Message)" }
} else {
    Write-Log 'INFO' "Signature skipped"
}

# ============================================================
# PHASE 7 - Join the installers + dependent steps + checklist
# ============================================================
Set-Phase 'Phase 7 - finishing installers and dependent steps'

# Join: wait for each pool installer to finish and evaluate its exit code. Blocking is fine -
# the progress window lives on its own thread, so it stays responsive while we wait here.
foreach ($bgItem in $BgInstalls) {
    try {
        $bgItem.Proc.WaitForExit()
        Write-ProcResult $bgItem.Name $bgItem.Proc $bgItem.OkCodes
    } catch { Write-Log 'ERROR' "$($bgItem.Name) (join): $($_.Exception.Message)" }
}

# Printer: the Epson driver already finished (join above). Short poll for the driver
# registration (it can lag a few seconds after the installer exits) and add the printer.
if ($SelectedPrinter -and $script:PrinterPort) {
    try {
        $driverName = $null
        for ($d = 0; $d -lt 30 -and -not $driverName; $d++) {
            $driverObj = Get-PrinterDriver -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -match 'Epson' } | Select-Object -First 1
            if ($driverObj) { $driverName = $driverObj.Name } else { Start-Sleep -Milliseconds 500 }
        }
        if ($driverName) {
            Add-Printer -Name $SelectedPrinter.name -DriverName $driverName `
                        -PortName $script:PrinterPort -ErrorAction Stop | Out-Null
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
            $p = Start-Process -FilePath 'msiexec.exe' `
                 -ArgumentList '/i', "`"$($waMsi.FullName)`"", '/quiet', '/norestart' -Wait -PassThru
            Write-ProcResult 'WebAgent (MSI)' $p @(0, 3010)
        } elseif ($waZip) {
            Write-Log 'INFO' "WebAgent ZIP: $($waZip.Name) - extracting..."
            $extractDir = "$env:TEMP\webagent_extract"
            New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
            Expand-Archive -Path $waZip.FullName -DestinationPath $extractDir -Force
            $msiInZip = Get-ChildItem -Path $extractDir -Filter '*.msi' -Recurse | Select-Object -First 1
            if ($msiInZip) {
                $p = Start-Process -FilePath 'msiexec.exe' `
                     -ArgumentList '/i', "`"$($msiInZip.FullName)`"", '/quiet', '/norestart' -Wait -PassThru
                Write-ProcResult 'WebAgent (ZIP)' $p @(0, 3010)
            } else {
                Write-Log 'WARN' "No MSI found inside the ZIP"
            }
        } elseif ($waExe) {
            Write-Log 'INFO' "WebAgent EXE (legacy): $($waExe.Name)"
            $p = Start-Process -FilePath $waExe.FullName -ArgumentList '/S' -Wait -PassThru
            Write-ProcResult 'WebAgent (EXE)' $p
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
[ ] Verify the signature in Outlook
[ ] Test the printer: $(if ($SelectedPrinter) { "$($SelectedPrinter.name) [$($SelectedPrinter.ip)]" } else { 'None' })
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

if ($script:Erros.Count -gt 0) {
    $s = if ($script:Erros.Count -ne 1) { 's' } else { '' }
    Write-Log 'INFO' "Setup completed with $($script:Erros.Count) error$s"
    if ($script:UiState) { $script:UiState.Status = "Done - $($script:Erros.Count) error$s. Review the red lines above, then close." }
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

# Signals failure to the caller (run.bat / FirstLogonCommands check %errorlevel%).
exit $exitCode
