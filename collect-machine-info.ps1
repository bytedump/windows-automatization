<#
.SYNOPSIS
    Shows a small GUI with the machine data the technician needs to fill in the
    intranet asset portal (RAM, storage, MAC, IP, serial number, AnyDesk ID).

.DESCRIPTION
    Standalone helper, not part of the setup.ps1 -> phase-b.ps1 provisioning flow.
    Run it any time on an already-installed Windows machine. Every field is
    collected independently (a failed lookup shows "N/A" instead of aborting the
    whole script), same best-effort spirit as the rest of this repo.

    The window has no close (X) button on purpose: the technician is meant to
    copy every field into the intranet portal before dismissing it. The only way
    out is the "Close" button, which asks for confirmation first.

.EXAMPLE
    .\collect-machine-info.ps1
    # Opens the info window. Click "Copy" next to a field to copy just that value,
    # or "Copy All" to copy every field as one "Label: value" block.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Data collection -------------------------------------------------------
# Each lookup is wrapped on its own so one missing WMI class/adapter/tool can't
# blank out the rest of the window.

function Get-InfoValue {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$FallbackValue = 'N/A'
    )
    try {
        $result = & $ScriptBlock
        if ($null -eq $result -or $result -eq '') { return $FallbackValue }
        return $result
    } catch {
        return $FallbackValue
    }
}

function Get-CimList {
    # A plain array return gets enumerated and unwrapped to a scalar by PowerShell
    # whenever the caller's CIM query matches exactly one item (e.g. one RAM stick,
    # one NIC) - the classic single-element-array gotcha. The leading comma forces
    # the array itself to be returned as one object instead.
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)
    try {
        return , @(& $ScriptBlock)
    } catch {
        return , @()
    }
}

function Get-AnyDeskId {
    # AnyDesk has no CIM/registry property for its own ID; --get-id is the
    # documented way to read it from the client itself.
    $exeCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'AnyDesk\AnyDesk.exe')
        (Join-Path $env:ProgramFiles 'AnyDesk\AnyDesk.exe')
    )
    # PSObject.Properties (not direct dot-access) because Set-StrictMode throws on a
    # missing property, and plenty of Uninstall subkeys have no DisplayName at all.
    $uninstallHit = Get-ItemProperty -Path @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    ) -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like 'AnyDesk*' -and
            $_.PSObject.Properties['InstallLocation'] -and $_.InstallLocation
        } |
        Select-Object -First 1
    if ($uninstallHit) {
        # Some installers write InstallLocation with the quotes baked into the string
        # itself (e.g. `"C:\Program Files (x86)\AnyDesk"`) - Join-Path chokes on that.
        $installLocation = $uninstallHit.InstallLocation.Trim('"')
        $exeCandidates += (Join-Path $installLocation 'AnyDesk.exe')
    }

    $exe = $exeCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $exe) { return 'Not installed' }

    $id = (& $exe --get-id 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($id)) { return 'Not installed' }
    return $id.Trim()
}

function Get-MachineInfoFields {
    $cs  = Get-InfoValue { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
    $bios = Get-InfoValue { Get-CimInstance Win32_BIOS -ErrorAction Stop }
    $mem   = Get-CimList { Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop }
    # Fixed disks only: Win32_DiskDrive also lists the USB stick this tool runs
    # from, and the portal wants just the internal drive(s). Same filter as
    # guard-disk.cmd uses in WinPE.
    $disks = Get-CimList { Get-CimInstance Win32_DiskDrive -Filter "MediaType='Fixed hard disk media'" -ErrorAction Stop }
    $nics  = Get-CimList { Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' -ErrorAction Stop }

    # Bare numbers only: the intranet portal fields take "16" / "256", not "16 GB".
    $ramText = 'N/A'
    if ($mem.Count -gt 0) {
        $ramText = [string][math]::Round((($mem | Measure-Object -Property Capacity -Sum).Sum) / 1GB)
    }

    $storageText = 'N/A'
    if ($disks.Count -gt 0) {
        # Vendors label disks in decimal GB (256 GB = 256e9 bytes); the binary 1GB
        # constant would show a "256 GB" SSD as 238, so divide by 1e9 instead.
        $storageText = ($disks | ForEach-Object { [string][math]::Round($_.Size / 1e9) }) -join ' | '
    }

    $macText = 'N/A'
    $ipText  = 'N/A'
    if ($nics.Count -gt 0) {
        $macText = ($nics | ForEach-Object { $_.MACAddress }) -join ' | '
        $ipText  = ($nics | ForEach-Object {
            if ($_.IPAddress) { $_.IPAddress[0] } else { 'N/A' }
        }) -join ' | '
    }

    [ordered]@{
        'Hostname'             = Get-InfoValue { $cs.Name }
        'Manufacturer / Model' = Get-InfoValue { "$($cs.Manufacturer) $($cs.Model)".Trim() }
        'Serial Number'        = Get-InfoValue { $bios.SerialNumber }
        'RAM'                  = $ramText
        'Storage'              = $storageText
        'MAC Address'          = $macText
        'IP Address'           = $ipText
        'AnyDesk ID'           = Get-InfoValue { Get-AnyDeskId }
    }
}

# --- GUI ---------------------------------------------------------------
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    Write-Error "Failed to load GUI assemblies: $($_.Exception.Message)"
    exit 1
}

# The whole GUI build + message loop runs inside one try/catch: any unexpected error
# (a WinForms quirk, a locked resource) shows the technician a MessageBox instead of the
# window just vanishing/crashing silently. collect-machine-info.bat's errorlevel check
# is the second line of defense if even this can't run (e.g. GUI assemblies unavailable).
try {

$fields = Get-MachineInfoFields

$form = New-Object System.Windows.Forms.Form
$form.Text          = 'Machine Info - copy into the intranet asset portal'
$form.Size          = New-Object System.Drawing.Size(620, (110 + $fields.Count * 40))
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox  = $false
$form.MinimizeBox  = $false
$form.ControlBox   = $false   # no X: the "Close" button (with confirmation) is the only exit
$form.TopMost      = $true

$y = 15
foreach ($key in $fields.Keys) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text     = $key
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(15, ($y + 4))
    $form.Controls.Add($label)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Text     = [string]$fields[$key]
    $box.ReadOnly = $true
    $box.Size     = New-Object System.Drawing.Size(340, 25)
    $box.Location = New-Object System.Drawing.Point(160, $y)
    $form.Controls.Add($box)

    $copyBtn = New-Object System.Windows.Forms.Button
    $copyBtn.Text     = 'Copy'
    $copyBtn.Size     = New-Object System.Drawing.Size(60, 25)
    $copyBtn.Location = New-Object System.Drawing.Point(510, $y)
    $copyBtn.Add_Click({
        try {
            [System.Windows.Forms.Clipboard]::SetText($box.Text)
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Couldn't copy to clipboard: $($_.Exception.Message)`nTry again in a moment.", 'Copy failed') | Out-Null
        }
    }.GetNewClosure())
    $form.Controls.Add($copyBtn)

    $y += 40
}

$copyAllBtn = New-Object System.Windows.Forms.Button
$copyAllBtn.Text     = 'Copy All'
$copyAllBtn.Size     = New-Object System.Drawing.Size(100, 32)
$copyAllBtn.Location = New-Object System.Drawing.Point(15, $y)
$copyAllBtn.Add_Click({
    try {
        $block = ($fields.Keys | ForEach-Object { "${_}: $($fields[$_])" }) -join "`r`n"
        [System.Windows.Forms.Clipboard]::SetText($block)
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Couldn't copy to clipboard: $($_.Exception.Message)`nTry again in a moment.", 'Copy failed') | Out-Null
    }
}.GetNewClosure())
$form.Controls.Add($copyAllBtn)

$closeBtn = New-Object System.Windows.Forms.Button
$closeBtn.Text     = 'Close'
$closeBtn.Size     = New-Object System.Drawing.Size(100, 32)
$closeBtn.Location = New-Object System.Drawing.Point(475, $y)
$closeBtn.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        'Did you copy everything you need into the intranet portal?',
        'Confirm close',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) { $form.Close() }
}.GetNewClosure())
$form.Controls.Add($closeBtn)

[void]$form.ShowDialog()

} catch {
    [System.Windows.Forms.MessageBox]::Show(
        "collect-machine-info.ps1 hit an unexpected error and is closing:`n$($_.Exception.Message)",
        'Unexpected error'
    ) | Out-Null
    exit 1
}
