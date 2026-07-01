#Requires -Version 5.1
<#
.SYNOPSIS
    Phase B of the hands-free Win11 provisioning: per-user setup.

.DESCRIPTION
    Phase A (setup.ps1, elevated) does all machine-wide work, then reboots and
    auto-logs-on the new standard user. A scheduled task (-AtLogOn, user context)
    runs THIS script as that user, so it can touch settings that only make sense
    inside the user's own profile / registry hive:

      - Desktop wallpaper (HKCU + a live SystemParametersInfo refresh).
      - Outlook signature, written into the user's real %APPDATA%, and registered
        as the default for New mail and Reply/Forward.
      - Default printer (the printer itself was installed machine-wide in Phase A;
        here we only mark it as this user's default).

    It reads its inputs from C:\ProgramData\CorpSetup\state.json, which Phase A
    writes and which NEVER contains credentials. When done it drops a `user-done`
    flag so the separate SYSTEM cleanup task can finish (clear the AutoLogon
    password, unregister the Phase B tasks, remove the staging folder). Cleanup
    does NOT disable the bootstrap admin - it is the only admin and is kept for
    support.

    The pure helpers (Resolve-SignatureTemplate, Convert-SignatureContent,
    Read-CorpState) have no side effects, so tests dot-source this file with
    -LoadOnly and exercise them without touching the machine.

.PARAMETER LoadOnly
    Define the functions and return before running Phase B. Test seam for
    tests/unit; never set in production.

.PARAMETER StatePath
    Path to the handoff state file written by Phase A.
    Default: C:\ProgramData\CorpSetup\state.json.

.NOTES
    Exit contract mirrors setup.ps1: 0 = ran (individual steps log their own
    failures and do not abort the others). A missing/invalid state file is the
    only fatal condition.
#>
[CmdletBinding()]
param(
    # Test seam: dot-source with -LoadOnly to define the pure functions below
    # WITHOUT running the Phase B body. Used by tests/unit. Never set in production.
    [switch]$LoadOnly,

    [string]$StatePath = (Join-Path $env:ProgramData 'CorpSetup\state.json')
)
Set-StrictMode -Version Latest

# Set once Initialize-PhaseLog runs; defined up front so StrictMode never sees it unset.
$script:PhaseLogFile = $null

# ============================================================
# Logging (own logger - Phase B runs in its own process, no access to setup.ps1)
# ============================================================
function Write-PhaseLog {
    param(
        [ValidateSet('OK', 'INFO', 'WARN', 'ERROR')][string]$Level,
        [string]$Message
    )
    $line = '{0} {1,-5} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:PhaseLogFile) {
        # Logging must never throw - a failed log write should not abort provisioning.
        try { Add-Content -LiteralPath $script:PhaseLogFile -Value $line -Encoding UTF8 } catch { }
    }
}

function Initialize-PhaseLog {
    param([string]$StateDir)
    try {
        $logDir = Join-Path $StateDir 'logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $script:PhaseLogFile = Join-Path $logDir "phase-b-$env:USERNAME.log"
    } catch {
        $script:PhaseLogFile = $null   # console-only if the log dir is not writable
    }
}

# ============================================================
# Pure helpers (no side effects - unit-tested via -LoadOnly)
# ============================================================

# Read and normalize the Phase A handoff file. Returns an object whose expected
# properties always exist (missing optionals become '') so downstream access is
# safe under StrictMode. Throws if the file is missing/invalid or a required
# field (the ones the signature needs) is absent. NEVER expects credentials.
function Read-CorpState {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "State file not found: $Path" }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    try { $obj = $raw | ConvertFrom-Json } catch { throw "state.json is not valid JSON: $($_.Exception.Message)" }
    if ($null -eq $obj) { throw 'state.json is empty' }

    $has = { param($n) ($obj.PSObject.Properties.Name -contains $n) }
    $val = { param($n) if (& $has $n) { $obj.$n } else { '' } }

    $state = [pscustomobject]@{
        Username      = (& $val 'Username')
        FullName      = (& $val 'FullName')
        Email         = (& $val 'Email')
        EmailDomain   = (& $val 'EmailDomain')
        SectorName    = (& $val 'SectorName')
        SigTemplate   = (& $val 'SigTemplate')
        PrinterName   = (& $val 'PrinterName')
        WallpaperPath = (& $val 'WallpaperPath')
    }

    foreach ($req in 'Username', 'FullName', 'Email') {
        if ([string]::IsNullOrWhiteSpace($state.$req)) { throw "state.json missing required field: $req" }
    }
    return $state
}

# Locate the signature template under <root>\<domain>\<sector>. With the sentinel
# '(Automatic - first found)' it picks the first *.htm whose name does not start
# with '.' or '_' (Outlook side-car files); otherwise the named template.
# Returns a FileInfo or $null. Mirrors setup.ps1 PHASE 6 resolution.
function Resolve-SignatureTemplate {
    param(
        [Parameter(Mandatory)][string]$SignaturesRoot,
        [string]$EmailDomain,
        [string]$SectorName,
        [string]$SigTemplate
    )
    $sectorPath = Join-Path (Join-Path $SignaturesRoot $EmailDomain) $SectorName
    if (-not (Test-Path -LiteralPath $sectorPath)) { return $null }

    if ($SigTemplate -eq '(Automatic - first found)') {
        return Get-ChildItem -LiteralPath $sectorPath -Filter '*.htm' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^[._]' } | Select-Object -First 1
    }
    return Get-Item -LiteralPath (Join-Path $sectorPath $SigTemplate) -ErrorAction SilentlyContinue
}

# Rewrite a signature template: detect the old email (first address) and the old
# name (first bold span) and swap them for the new ones. Pure string -> object.
# Ports setup.ps1 PHASE 6, with one fix: the replacement strings are '$'-escaped
# (setup.ps1 does not), so a value containing $ is inserted literally instead of
# being read as a -replace substitution token ($&, $1, ${n}, $$).
function Convert-SignatureContent {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$NewName,
        [Parameter(Mandatory)][string]$NewEmail
    )
    $emailMatch = [regex]::Match($Content, '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}')
    $oldEmail = if ($emailMatch.Success) { $emailMatch.Value } else { '' }

    $nameMatch = [regex]::Match($Content, 'font-weight:\s*bold[^>]*>([^<]+)')
    $oldName = if ($nameMatch.Success) { $nameMatch.Groups[1].Value.Trim() } else { '' }

    # In a -replace replacement, '$$' yields one literal '$', so doubling every '$'
    # ('$' -> '$$') makes the value insert verbatim. Matching stays case-insensitive.
    $new = $Content
    if ($oldEmail) { $new = $new -replace [regex]::Escape($oldEmail), ($NewEmail -replace '\$', '$$$$') }
    if ($oldName) { $new = $new -replace [regex]::Escape($oldName), ($NewName -replace '\$', '$$$$') }

    return [pscustomobject]@{
        Content  = $new
        OldName  = $oldName
        OldEmail = $oldEmail
    }
}

# Repoint references to the template's asset folder (<OldBase>_files) at the user's
# copy (<NewBase>_files). A literal token replace covers every reference form Outlook
# emits (src=, v:imagedata, background, single/double quotes). No-op if names match.
# NewBase is the validated username (no regex metacharacters), so it needs no escaping.
function Update-SignatureAssetRefs {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$OldBase,
        [Parameter(Mandatory)][string]$NewBase
    )
    if ($OldBase -eq $NewBase) { return $Content }
    return $Content -replace [regex]::Escape("${OldBase}_files"), "${NewBase}_files"
}

# ============================================================
# Side-effecting steps (run only in the body; not exercised by -LoadOnly tests -
# they touch HKCU / user profile / printers and need a real user session / VM)
# ============================================================

function Set-UserWallpaper {
    param([string]$ImagePath)

    # Fall back to the machine-wide copy Phase A drops, if state did not carry a path.
    if ([string]::IsNullOrWhiteSpace($ImagePath)) {
        $ImagePath = Join-Path $env:WINDIR 'Web\Wallpaper\Corp\wallpaper.jpg'
    }
    if (-not (Test-Path -LiteralPath $ImagePath)) {
        Write-PhaseLog WARN "Wallpaper image not found: '$ImagePath' - skipped"
        return
    }

    $desk = 'HKCU:\Control Panel\Desktop'
    Set-ItemProperty -Path $desk -Name 'WallPaper' -Value $ImagePath
    Set-ItemProperty -Path $desk -Name 'WallpaperStyle' -Value '10'  # 10 = Fill
    Set-ItemProperty -Path $desk -Name 'TileWallpaper' -Value '0'

    # Live refresh for the current session (HKCU alone updates only the next logon).
    if (-not ('CorpWallpaper' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class CorpWallpaper {
    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
    }
    # 20 = SPI_SETDESKWALLPAPER, 3 = SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
    [CorpWallpaper]::SystemParametersInfo(20, 0, $ImagePath, 3) | Out-Null
    Write-PhaseLog OK "Wallpaper applied: $ImagePath"
}

function Set-DefaultSignature {
    param([Parameter(Mandatory)][string]$SignatureName)

    # Office MailSettings sets the default New / Reply signature. Detect the
    # installed Office version(s) from HKLM; default to 16.0 (2016/2019/2021/365).
    $versions = @(
        Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Office' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^\d+\.\d+$' } |
            Select-Object -ExpandProperty PSChildName
    )
    if (-not $versions) { $versions = @('16.0') }

    foreach ($v in ($versions | Select-Object -Unique)) {
        $key = "HKCU:\Software\Microsoft\Office\$v\Common\MailSettings"
        try {
            if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
            Set-ItemProperty -Path $key -Name 'NewSignature' -Value $SignatureName
            Set-ItemProperty -Path $key -Name 'ReplySignature' -Value $SignatureName
            Write-PhaseLog OK "Default signature set for Office $v (new + reply): $SignatureName"
        } catch {
            Write-PhaseLog WARN "Default signature for Office ${v}: $($_.Exception.Message)"
        }
    }
}

function Install-UserSignature {
    param(
        [Parameter(Mandatory)][pscustomobject]$State,
        [Parameter(Mandatory)][string]$SignaturesRoot
    )
    # Sector sentinel '(...)' or empty means "no signature for this user".
    if ([string]::IsNullOrWhiteSpace($State.SectorName) -or $State.SectorName -match '^\(') {
        Write-PhaseLog INFO 'Signature skipped (no sector)'
        return
    }

    $tpl = Resolve-SignatureTemplate -SignaturesRoot $SignaturesRoot `
        -EmailDomain $State.EmailDomain -SectorName $State.SectorName -SigTemplate $State.SigTemplate
    if (-not $tpl) {
        Write-PhaseLog WARN "No signature template under $SignaturesRoot\$($State.EmailDomain)\$($State.SectorName)"
        return
    }

    $content = [System.IO.File]::ReadAllText($tpl.FullName, [System.Text.Encoding]::UTF8)
    $res = Convert-SignatureContent -Content $content -NewName $State.FullName -NewEmail $State.Email
    $out = $res.Content

    $sigFolder = Join-Path $env:APPDATA 'Microsoft\Signatures'
    New-Item -ItemType Directory -Path $sigFolder -Force | Out-Null
    $sigName = $State.Username

    # Logo/image templates: Outlook stores images in a sibling "<base>_files" folder
    # referenced from the .htm. Copy it to "<Username>_files" and repoint the refs,
    # else the signature renders with broken images. (Phase A must stage the _files
    # folders alongside the .htm templates.)
    $tplBase = [System.IO.Path]::GetFileNameWithoutExtension($tpl.Name)
    $srcAssets = Join-Path $tpl.DirectoryName ('{0}_files' -f $tplBase)
    if (Test-Path -LiteralPath $srcAssets) {
        $destAssets = Join-Path $sigFolder ('{0}_files' -f $sigName)
        if (Test-Path -LiteralPath $destAssets) { Remove-Item -LiteralPath $destAssets -Recurse -Force -ErrorAction SilentlyContinue }
        Copy-Item -LiteralPath $srcAssets -Destination $destAssets -Recurse -Force
        $out = Update-SignatureAssetRefs -Content $out -OldBase $tplBase -NewBase $sigName
        Write-PhaseLog OK "Signature assets copied -> $destAssets"
    }

    [System.IO.File]::WriteAllText((Join-Path $sigFolder "$sigName.htm"), $out, [System.Text.Encoding]::UTF8)

    Write-PhaseLog OK "Signature written: $sigFolder\$sigName.htm"
    Write-PhaseLog INFO "Base: $($tpl.Name) | '$($res.OldName)' -> '$($State.FullName)' | '$($res.OldEmail)' -> '$($State.Email)'"

    Set-DefaultSignature -SignatureName $sigName
}

function Set-UserDefaultPrinter {
    param([string]$PrinterName)

    if ([string]::IsNullOrWhiteSpace($PrinterName)) {
        Write-PhaseLog INFO 'Default printer skipped (none in state)'
        return
    }

    if (-not (Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue)) {
        Write-PhaseLog WARN "Printer '$PrinterName' not found for this user - cannot set default"
        return
    }
    # Match client-side instead of a WQL -Filter: WQL escapes quotes with a backslash
    # (not SQL-style doubling), so a name containing ' or \ would build a malformed
    # query and silently match nothing. Enumerating and comparing in PowerShell is
    # both correct and injection-free.
    $cim = Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $PrinterName } | Select-Object -First 1
    if ($cim) {
        # Only now that we have a printer to set: stop Windows 11 from managing the
        # default (last-used) so our choice sticks. Doing this before the existence
        # check would disable management with no corp default to show for it.
        $winKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows'
        try { Set-ItemProperty -Path $winKey -Name 'LegacyDefaultPrinterMode' -Value 1 -Type DWord } catch { }
        Invoke-CimMethod -InputObject $cim -MethodName SetDefaultPrinter | Out-Null
        Write-PhaseLog OK "Default printer set: $PrinterName"
    } else {
        Write-PhaseLog WARN "Printer '$PrinterName' not enumerable via CIM - default not set"
    }
}

# Import the corp VPN profile for THIS user, if Phase A staged one (it stages the .ovpn only when
# the technician ticked the VPN box). The profile carries an embedded client key, so it lands in
# the user's OWN profile (%USERPROFILE%\OpenVPN\config), not a machine-wide dir. If OpenVPN is
# installed, register its GUI to open at logon and launch it now so the tray icon is ready - the
# profile uses auth-user-pass, so the user still connects manually (types user/password).
function Install-UserVpnProfile {
    param(
        [Parameter(Mandatory)][string]$StagingRoot,
        [string]$ConfigDir = (Join-Path $env:USERPROFILE 'OpenVPN\config'),
        [string]$GuiPath   = (Join-Path $env:ProgramFiles 'OpenVPN\bin\openvpn-gui.exe')
    )
    if (-not (Test-Path -LiteralPath $StagingRoot)) {
        Write-PhaseLog INFO 'VPN skipped (not selected)'
        return
    }
    $ovpn = Get-ChildItem -LiteralPath $StagingRoot -Filter '*.ovpn' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $ovpn) {
        Write-PhaseLog INFO 'VPN skipped (no staged profile)'
        return
    }

    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    Copy-Item -LiteralPath $ovpn.FullName -Destination (Join-Path $ConfigDir $ovpn.Name) -Force
    Write-PhaseLog OK "VPN profile imported: $ConfigDir\$($ovpn.Name)"

    # Open the OpenVPN GUI at logon (and now) - only if OpenVPN actually installed in Phase A.
    if (Test-Path -LiteralPath $GuiPath) {
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        try { Set-ItemProperty -Path $runKey -Name 'OpenVPN-GUI' -Value ('"{0}"' -f $GuiPath) } catch { }
        try {
            Start-Process -FilePath $GuiPath -ErrorAction Stop
            Write-PhaseLog OK 'OpenVPN GUI launched (connect manually with your credentials)'
        } catch { Write-PhaseLog WARN "OpenVPN GUI did not launch: $($_.Exception.Message)" }
    } else {
        Write-PhaseLog WARN "OpenVPN GUI not found ($GuiPath) - profile imported, but the MSI install may have failed"
    }
}

# Signal Phase B completion so the SYSTEM cleanup task can proceed. The flag holds
# no credentials. Cleanup (the separate SYSTEM script) owns unregistering both
# tasks, so this script does not deregister itself.
function Write-UserDoneFlag {
    param([Parameter(Mandatory)][string]$StateDir)
    $flag = Join-Path $StateDir 'user-done'
    Set-Content -LiteralPath $flag -Value "user=$env:USERNAME done=$(Get-Date -Format o)" -Encoding UTF8
    Write-PhaseLog OK "Done flag written: $flag"
}

# ============================================================
# Orchestration
# ============================================================
function Invoke-PhaseB {
    param([Parameter(Mandatory)][string]$StatePath)

    $stateDir = Split-Path -Parent $StatePath
    Initialize-PhaseLog -StateDir $stateDir
    Write-PhaseLog INFO "Phase B starting (user=$env:USERNAME)"

    try {
        $state = Read-CorpState -Path $StatePath
    } catch {
        # No state = nothing to do and no safe defaults; this is the only fatal case.
        Write-PhaseLog ERROR "Cannot read state: $($_.Exception.Message)"
        return
    }

    # Each step is isolated: one failure logs and the rest still run.
    try { Set-UserWallpaper -ImagePath $state.WallpaperPath } catch { Write-PhaseLog ERROR "Wallpaper: $($_.Exception.Message)" }

    $sigRoot = Join-Path $stateDir 'Signatures'
    try { Install-UserSignature -State $state -SignaturesRoot $sigRoot } catch { Write-PhaseLog ERROR "Signature: $($_.Exception.Message)" }

    try { Set-UserDefaultPrinter -PrinterName $state.PrinterName } catch { Write-PhaseLog ERROR "Default printer: $($_.Exception.Message)" }

    try { Install-UserVpnProfile -StagingRoot (Join-Path $stateDir 'VPN') } catch { Write-PhaseLog ERROR "VPN profile: $($_.Exception.Message)" }

    try { Write-UserDoneFlag -StateDir $stateDir } catch { Write-PhaseLog ERROR "Done flag: $($_.Exception.Message)" }

    Write-PhaseLog INFO 'Phase B finished'
}

# Test seam: when dot-sourced with -LoadOnly, stop here so only the functions
# above are defined - the body below never runs.
if ($LoadOnly) { return }

Invoke-PhaseB -StatePath $StatePath
