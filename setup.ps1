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

function Write-Log {
    param([string]$Level, [string]$Msg)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Msg"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $line
    if ($Level -in 'ERROR', 'FATAL') {
        $script:Erros.Add("[$Level] $Msg") | Out-Null
    }

    # --- Tee into the live-progress window (only if the UI exists) ---
    # Single choke point: every phase streams here for free. Headless ($script:UI = $null)
    # makes this a no-op, so -Unattended behaves exactly like before (file + host only).
    if ($script:UI) {
        try {
            $rtb = $script:UI.Log
            $clr = $script:LevelClr[$Level]; if (-not $clr) { $clr = $script:LevelClr.INFO }
            $rtb.SelectionStart  = $rtb.TextLength
            $rtb.SelectionLength  = 0
            $rtb.SelectionColor  = $clr
            $rtb.AppendText($line + "`n")
            $rtb.SelectionColor  = $rtb.ForeColor             # reset so the next line is default
            $rtb.ScrollToCaret()                              # read-only RTB never focuses: needed to autoscroll
            if ($rtb.Lines.Count -gt 5000) {                  # cap growth on long runs
                $rtb.ReadOnly = $false
                $rtb.Select(0, $rtb.GetFirstCharIndexFromLine(1000))
                $rtb.SelectedText = ''
                $rtb.ReadOnly = $true
                $rtb.SelectionStart = $rtb.TextLength
            }
            [System.Windows.Forms.Application]::DoEvents()    # repaint + process window messages
        } catch { }   # the tee must never break logging (runs inside catch/trap blocks)
    }
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
    # If the window is up, let the technician read the fatal line before we exit.
    if ($script:UI) { try { Complete-ProgressUI; Wait-WindowClosed } catch { } }
    exit 1
}

# UI state is initialized BEFORE Add-Type so Write-Log's tee guard (and the trap) are safe
# even if Add-Type itself throws: its catch calls Write-Log, whose `if ($script:UI)` would
# otherwise read an unset variable and blow up under StrictMode. $script:LevelClr needs
# System.Drawing, so it is defined right AFTER the assemblies load (just below).
$script:UI      = $null     # control handles; $null = headless (no window)
$script:Started = $false    # flipped by the Start button click handler

# GUI assemblies are loaded up front so the live-progress window (and the color table
# below) can be built anywhere. Failure here is fatal: nothing downstream works without them.
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    Write-Log 'FATAL' "Failed to load GUI assemblies: $($_.Exception.Message)"
    exit 1
}

# ============================================================
# Live-progress UI - single window: input form on top, streaming log at the bottom
# ============================================================
# Approach: single-threaded, modeless Form + RichTextBox fed by Write-Log, with
# Application.DoEvents() acting as a hand-rolled message pump (no Application.Run, no
# runspaces). The technician fills the form on top; the section below streams every task
# live. $script:UI = $null means headless (no window) and every UI touch becomes a no-op.
# ($script:UI / $script:Started are initialized above, before Add-Type.)

# Color per log level (uses System.Drawing, loaded just above).
$script:LevelClr = @{
    OK    = [System.Drawing.Color]::FromArgb(80, 220, 100)
    WARN  = [System.Drawing.Color]::FromArgb(235, 200, 60)
    ERROR = [System.Drawing.Color]::FromArgb(240, 90, 90)
    FATAL = [System.Drawing.Color]::FromArgb(255, 70, 70)
    INFO  = [System.Drawing.Color]::FromArgb(185, 185, 185)
}

# Status caption + pump (cosmetic; safe when headless).
function Set-Phase([string]$text) {
    if ($script:UI) {
        $script:UI.Status.Text = $text
        [System.Windows.Forms.Application]::DoEvents()
    }
}

# Polls a process to completion while pumping the window (replaces blocking WaitForExit /
# Start-Process -Wait, which would freeze a modeless window). Thread.Sleep (NOT Start-Sleep:
# Start-Sleep inside a DoEvents loop breaks Alt-Tab / taskbar reactivation - PowerShell#19796).
function Wait-ProcPumping($Proc) {
    while (-not $Proc.HasExited) {
        if ($script:UI) { [System.Windows.Forms.Application]::DoEvents() }
        [System.Threading.Thread]::Sleep(200)
    }
}

# End state: stop the marquee, enable Close, then pump until the technician closes the window.
function Complete-ProgressUI {
    if (-not $script:UI) { return }
    $script:UI.Bar.Style    = 'Continuous'
    $script:UI.Bar.Value    = $script:UI.Bar.Maximum
    $script:UI.Close.Enabled = $true
    $script:UI.Status.Text  = 'Done - you may close this window.'
    [System.Windows.Forms.Application]::DoEvents()
}

function Wait-WindowClosed {
    if (-not $script:UI) { return }
    while ($script:UI -and -not $script:UI.Form.IsDisposed) {
        [System.Windows.Forms.Application]::DoEvents()
        [System.Threading.Thread]::Sleep(100)
    }
}

# Builds the single window (form on top + live log at the bottom), wires the dynamic
# combo events and the Start button, shows it modeless and pumps once. Reads $Printers,
# $EmailDomains and $PathSignatures from the enclosing script scope (set before this runs).
# IMPORTANT: this MUST be invoked dot-sourced ('. Show-MainWindow') so the control variables
# land in the script scope and the event handlers can still see them when they fire later.
function Show-MainWindow {
    $f = New-Object System.Windows.Forms.Form
    $f.Text            = 'New Machine Setup'
    $f.Size            = New-Object System.Drawing.Size(580, 880)
    $f.StartPosition   = 'CenterScreen'
    $f.FormBorderStyle = 'Sizable'
    $f.MinimizeBox     = $true
    $f.MaximizeBox     = $true

    # --- bottom: live log panel (added first so Dock=Fill yields the right remaining space) ---
    $logPanel = New-Object System.Windows.Forms.Panel
    $logPanel.Dock   = 'Bottom'
    $logPanel.Height = 300

    $status = New-Object System.Windows.Forms.Label
    $status.Dock      = 'Top'
    $status.Height    = 24
    $status.TextAlign = 'MiddleLeft'
    $status.Padding   = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
    $status.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $status.Text      = 'Fill in the form and click Start.'

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

    $logPanel.Controls.Add($rtb)
    $logPanel.Controls.Add($bar)
    $logPanel.Controls.Add($status)

    # --- top: input form (scrolls if the screen is small) ---
    $inputPanel = New-Object System.Windows.Forms.Panel
    $inputPanel.Dock      = 'Fill'
    $inputPanel.AutoScroll = $true

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

    $y = 12

    Add-Label $inputPanel 'Full name (from the ticket):' 10 $y; $y += 20
    $TxtFullName = New-TextBox 10 $y; $inputPanel.Controls.Add($TxtFullName); $y += 35

    Add-Label $inputPanel 'Username (e.g. joao.silva):' 10 $y; $y += 20
    $TxtUsername = New-TextBox 10 $y; $inputPanel.Controls.Add($TxtUsername); $y += 35

    Add-Label $inputPanel 'Email domain:' 10 $y; $y += 20
    $CmbDomain = New-Combo 10 $y 300
    $EmailDomains | ForEach-Object { $CmbDomain.Items.Add($_) | Out-Null }
    $CmbDomain.SelectedIndex = 0
    $inputPanel.Controls.Add($CmbDomain); $y += 35

    Add-Label $inputPanel 'Network configuration:' 10 $y; $y += 20
    $RadioDhcp            = New-Object System.Windows.Forms.RadioButton
    $RadioDhcp.Text       = 'DHCP (automatic)'
    $RadioDhcp.Location   = New-Object System.Drawing.Point(10, $y)
    $RadioDhcp.AutoSize   = $true
    $RadioDhcp.Checked    = $true
    $RadioStatic          = New-Object System.Windows.Forms.RadioButton
    $RadioStatic.Text     = 'Static IP'
    $RadioStatic.Location = New-Object System.Drawing.Point(190, $y)
    $RadioStatic.AutoSize = $true
    $inputPanel.Controls.Add($RadioDhcp); $inputPanel.Controls.Add($RadioStatic); $y += 30

    $LblIp          = New-Object System.Windows.Forms.Label
    $LblIp.Text     = 'IP (e.g. 10.0.X.X):'
    $LblIp.Location = New-Object System.Drawing.Point(10, $y)
    $LblIp.AutoSize = $true
    $LblIp.Visible  = $false
    $TxtIp          = New-TextBox 140 $y 160
    $TxtIp.Visible  = $false
    $inputPanel.Controls.Add($LblIp); $inputPanel.Controls.Add($TxtIp); $y += 35

    $RadioStatic.Add_CheckedChanged({ $LblIp.Visible = $RadioStatic.Checked; $TxtIp.Visible = $RadioStatic.Checked })
    $RadioDhcp.Add_CheckedChanged({   $LblIp.Visible = $RadioStatic.Checked; $TxtIp.Visible = $RadioStatic.Checked })

    Add-Label $inputPanel 'Main printer:' 10 $y; $y += 20
    $CmbPrinter = New-Combo 10 $y
    $CmbPrinter.Items.Add('(None)') | Out-Null
    foreach ($p in $Printers) { $CmbPrinter.Items.Add("$($p.name) - $($p.model) [$($p.ip)]") | Out-Null }
    $CmbPrinter.SelectedIndex = 0
    $inputPanel.Controls.Add($CmbPrinter); $y += 35

    Add-Label $inputPanel 'Sector (for the signature):' 10 $y; $y += 20
    $CmbSector = New-Combo 10 $y
    $inputPanel.Controls.Add($CmbSector); $y += 35

    Add-Label $inputPanel 'Base signature (.htm):' 10 $y; $y += 20
    $CmbSigTemplate = New-Combo 10 $y
    $CmbSigTemplate.Items.Add('(Automatic - first found)') | Out-Null
    $CmbSigTemplate.SelectedIndex = 0
    $inputPanel.Controls.Add($CmbSigTemplate); $y += 35

    $ChkWebAgent          = New-Object System.Windows.Forms.CheckBox
    $ChkWebAgent.Text     = 'Install WebAgent'
    $ChkWebAgent.Location = New-Object System.Drawing.Point(10, $y)
    $ChkWebAgent.AutoSize = $true
    $inputPanel.Controls.Add($ChkWebAgent); $y += 40

    $BtnStart          = New-Object System.Windows.Forms.Button
    $BtnStart.Text     = 'Start setup'
    $BtnStart.Location = New-Object System.Drawing.Point(10, $y)
    $BtnStart.Size     = New-Object System.Drawing.Size(480, 35)
    $inputPanel.Controls.Add($BtnStart)

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

    # Start: validate, copy values to script scope, lock inputs, flip $Started.
    # The work runs in the main flow (NOT in this handler) so no interactive control is
    # enabled during the run -> no DoEvents re-entrancy. The window is NOT closed.
    $BtnStart.Add_Click({
        if (-not $TxtFullName.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show('Fill in the full name.', 'Setup', 'OK', 'Warning') | Out-Null; return
        }
        if (-not $TxtUsername.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show('Fill in the username.', 'Setup', 'OK', 'Warning') | Out-Null; return
        }
        if ($RadioStatic.Checked -and -not $TxtIp.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show('Fill in the static IP.', 'Setup', 'OK', 'Warning') | Out-Null; return
        }

        $script:FullName    = $TxtFullName.Text.Trim()
        $script:Username    = $TxtUsername.Text.Trim().ToLower()
        $script:EmailDomain = if ($CmbDomain.SelectedItem) { $CmbDomain.SelectedItem.ToString() } else { $EmailDomains[0] }
        $script:Email       = "$($script:Username)@$($script:EmailDomain)"
        $script:UseStatic   = $RadioStatic.Checked
        $script:StaticIp    = if ($RadioStatic.Checked) { $TxtIp.Text.Trim() } else { '' }
        $pidx               = $CmbPrinter.SelectedIndex
        $script:SelectedPrinter = if ($pidx -gt 0) { $Printers[$pidx - 1] } else { $null }
        $script:SectorName  = if ($CmbSector.SelectedItem) { $CmbSector.SelectedItem.ToString() } else { '' }
        $script:SigTemplate = if ($CmbSigTemplate.SelectedItem) { $CmbSigTemplate.SelectedItem.ToString() } else { '(Automatic - first found)' }
        $script:InstallWebAgent = $ChkWebAgent.Checked

        $BtnStart.Enabled = $false
        foreach ($ctl in $script:UI.Inputs) { $ctl.Enabled = $false }
        $script:UI.Status.Text = 'Running setup...'
        $script:Started = $true
    })

    # Initial load: fire the domain event to populate sectors and templates
    $CmbDomain.SelectedIndex = -1
    $CmbDomain.SelectedIndex = 0

    # Closing the window mid-run just drops the UI reference; the run keeps going (log
    # falls back to file + host). We never abort a half-provisioned machine on a window close.
    $f.Add_FormClosed({ $script:UI = $null })

    $f.Controls.Add($inputPanel)
    $f.Controls.Add($logPanel)

    $script:UI = @{
        Form   = $f
        Log    = $rtb
        Bar    = $bar
        Status = $status
        Close  = $BtnStart   # placeholder; replaced just below by a dedicated Close button
        Inputs = @($TxtFullName, $TxtUsername, $CmbDomain, $RadioDhcp, $RadioStatic, $TxtIp,
                   $CmbPrinter, $CmbSector, $CmbSigTemplate, $ChkWebAgent)
    }

    # Dedicated Close button at the bottom of the log panel (disabled until the run finishes).
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Dock    = 'Bottom'
    $btnClose.Height  = 34
    $btnClose.Text    = 'Close'
    $btnClose.Enabled = $false
    $btnClose.Add_Click({ if ($script:UI) { $script:UI.Form.Close() } })
    $logPanel.Controls.Add($btnClose)
    $script:UI.Close = $btnClose

    $f.Show()                                          # modeless: returns immediately
    [System.Windows.Forms.Application]::DoEvents()      # force the first paint
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
    param([string]$Name, [string]$FilePath, [string[]]$ArgumentList = @(), [int[]]$OkCodes = @(0))
    $params = @{ FilePath = $FilePath; PassThru = $true }
    if ($ArgumentList.Count) { $params['ArgumentList'] = $ArgumentList }
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
# PHASE 3 - Collect inputs (single live window) or resolve from -Test* params
# ============================================================
# Interactive: show the single window (form + live log) and wait, via a hand-rolled DoEvents
# pump, until the technician clicks Start. Headless ($Unattended, or no interactive desktop):
# values come from the -Test* params and no window is shown.

$useUI = (-not $Unattended) -and [System.Environment]::UserInteractive

if ($useUI) {
    try {
        # DOT-SOURCED on purpose: '. Show-MainWindow' runs the function body in THIS (script)
        # scope, so the control variables ($CmbDomain, $LblIp, ...) live at script scope. The
        # form's event handlers fire later (after the function returns) on the message pump;
        # if the controls were function-locals they'd be gone by then and every handler would
        # throw "variable ... cannot be retrieved". Dot-sourcing keeps them reachable.
        . Show-MainWindow
        while (-not $script:Started -and $script:UI -and -not $script:UI.Form.IsDisposed) {
            [System.Windows.Forms.Application]::DoEvents()
            [System.Threading.Thread]::Sleep(50)
        }
    } catch {
        Write-Log 'FATAL' "GUI failed: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Fatal GUI error:`n$($_.Exception.Message)",
            'Setup - Fatal Error', 'OK', 'Error') | Out-Null
        exit 1
    }
    if (-not $script:Started) {
        Write-Log 'WARN' "Setup cancelled (window closed before Start)"
        exit 0
    }
    $FullName        = $script:FullName
    $Username        = $script:Username
    $EmailDomain     = $script:EmailDomain
    $Email           = $script:Email
    $UseStatic       = $script:UseStatic
    $StaticIp        = $script:StaticIp
    $SelectedPrinter = $script:SelectedPrinter
    $SectorName      = $script:SectorName
    $SigTemplate     = $script:SigTemplate
    $InstallWebAgent = $script:InstallWebAgent
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
        $confXml = Join-Path $PathOffice 'configuration.xml'
        $oArgs = if (Test-Path $confXml) { @('/configure', $confXml) } else { @() }
        Start-BgInstall 'Office ODT' $officeOdt $oArgs | Out-Null
    } elseif (Test-Path $officeLocal) {
        Start-BgInstall 'Office Click-to-Run' $officeLocal | Out-Null
    } else {
        Write-Log 'WARN' "Office installer not found (share: $PathOffice | USB: $ScriptDir)"
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

# Join: wait for each pool installer to finish and evaluate its exit code.
# Wait-ProcPumping keeps the live window responsive (replaces blocking WaitForExit).
foreach ($bgItem in $BgInstalls) {
    try {
        Wait-ProcPumping $bgItem.Proc
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
            if ($driverObj) {
                $driverName = $driverObj.Name
            } else {
                if ($script:UI) { [System.Windows.Forms.Application]::DoEvents() }
                [System.Threading.Thread]::Sleep(500)
            }
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
                 -ArgumentList '/i', "`"$($waMsi.FullName)`"", '/quiet', '/norestart' -PassThru
            Wait-ProcPumping $p
            Write-ProcResult 'WebAgent (MSI)' $p @(0, 3010)
        } elseif ($waZip) {
            Write-Log 'INFO' "WebAgent ZIP: $($waZip.Name) - extracting..."
            $extractDir = "$env:TEMP\webagent_extract"
            New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
            Expand-Archive -Path $waZip.FullName -DestinationPath $extractDir -Force
            $msiInZip = Get-ChildItem -Path $extractDir -Filter '*.msi' -Recurse | Select-Object -First 1
            if ($msiInZip) {
                $p = Start-Process -FilePath 'msiexec.exe' `
                     -ArgumentList '/i', "`"$($msiInZip.FullName)`"", '/quiet', '/norestart' -PassThru
                Wait-ProcPumping $p
                Write-ProcResult 'WebAgent (ZIP)' $p @(0, 3010)
            } else {
                Write-Log 'WARN' "No MSI found inside the ZIP"
            }
        } elseif ($waExe) {
            Write-Log 'INFO' "WebAgent EXE (legacy): $($waExe.Name)"
            $p = Start-Process -FilePath $waExe.FullName -ArgumentList '/S' -PassThru
            Wait-ProcPumping $p
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

# Show the checklist in the live window (replaces the modal checklist popup), appended
# directly to the RichTextBox so it is NOT duplicated in the log file (Add-Content already
# wrote it once above). Then flip the window to its "done, you may close" state.
if ($script:UI) {
    try {
        $rtb = $script:UI.Log
        $rtb.SelectionStart = $rtb.TextLength
        $rtb.SelectionColor = $script:LevelClr.INFO
        $rtb.AppendText($checklist + "`n")
        $rtb.SelectionColor = $rtb.ForeColor
        $rtb.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    } catch { }
}
Complete-ProgressUI

if ($script:Erros.Count -gt 0) {
    $s = if ($script:Erros.Count -ne 1) { 's' } else { '' }
    $errSummary = "ATTENTION: $($script:Erros.Count) error$s during setup:`n`n" +
                  ($script:Erros -join "`n") +
                  "`n`nFull log: $LogFile"
    Write-Log 'INFO' "Setup completed with $($script:Erros.Count) error$s"
    # Modal error summary forces acknowledgement (interactive only).
    if ($script:UI) {
        [System.Windows.Forms.MessageBox]::Show(
            $errSummary,
            'Setup - Errors Found',
            'OK',
            'Warning'
        ) | Out-Null
    }
    Wait-WindowClosed
    # Signals failure to the caller (run.bat / FirstLogonCommands check %errorlevel%).
    exit 1
} else {
    Write-Log 'OK' "setup.ps1 completed without errors"
    Wait-WindowClosed
    exit 0
}
