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
# Stop on non-terminating errors too: each Phase B step runs inside its own try/catch, and without
# this a non-terminating cmdlet failure (e.g. SetDefaultPrinter, the wallpaper Set-ItemProperty)
# slips past the catch and the step still logs OK. Matches setup.ps1.
$ErrorActionPreference = 'Stop'

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
        # Optional array (not scalar): normalize to @() so Set-ChromiumBookmarks can bind it. Must
        # be an ARRAY SUBEXPRESSION: an if-statement as the value collects through the pipeline,
        # so its @() collapsed to $null (and a JSON null to @($null)) - Set-ChromiumBookmarks's
        # [object[]] then failed to bind on every zero-bookmark provision. Where-Object also
        # drops the JSON-null element itself.
        Bookmarks     = @(if (& $has 'Bookmarks') { @($obj.Bookmarks) | Where-Object { $_ } })
        # Same array normalization: bookmark NAMES that get a desktop .url shortcut.
        DesktopShortcutNames = @(if (& $has 'DesktopShortcutNames') { @($obj.DesktopShortcutNames) | Where-Object { $_ } })
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

# Build a Chrome/Edge profile "Bookmarks" file (the per-user JSON both browsers read on launch) with
# the corp links LOOSE on the bar: entries go under roots.bookmark_bar.children (NOT 'other', which
# would hide them). PURE: string-in / string-out, so tests exercise the shape without touching a
# profile. No "checksum" key - on a fresh profile Chromium recomputes it on first load (the writer
# only seeds when no Bookmarks file exists yet, so there is no stored checksum to mismatch). The
# children array is built by hand (per-item ConvertTo-Json -Compress + join) to dodge PS 5.1's
# single-element array collapse, same trick as ConvertTo-BrowserBookmarkPolicy. date_added is
# Chromium's epoch (microseconds since 1601-01-01 UTC); ids are unique ints (roots 1/2/3, links 4+).
function ConvertTo-ChromiumBookmarkFile {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Bookmarks)

    $ts  = [string][long]([DateTime]::UtcNow.ToFileTimeUtc() / 10)
    $id  = 3
    $items = foreach ($b in $Bookmarks) {
        $id++
        [pscustomobject][ordered]@{
            date_added = $ts
            guid       = [guid]::NewGuid().ToString()
            id         = [string]$id
            name       = [string]$b.Name
            type       = 'url'
            url        = [string]$b.Url
        } | ConvertTo-Json -Compress
    }
    $childrenJson = '[' + ($items -join ',') + ']'

    return @"
{
   "roots": {
      "bookmark_bar": {
         "children": $childrenJson,
         "date_added": "$ts",
         "date_modified": "0",
         "guid": "00000000-0000-4000-8000-000000000001",
         "id": "1",
         "name": "Bookmarks bar",
         "type": "folder"
      },
      "other": {
         "children": [],
         "date_added": "0",
         "date_modified": "0",
         "guid": "00000000-0000-4000-8000-000000000002",
         "id": "2",
         "name": "Other bookmarks",
         "type": "folder"
      },
      "synced": {
         "children": [],
         "date_added": "0",
         "date_modified": "0",
         "guid": "00000000-0000-4000-8000-000000000003",
         "id": "3",
         "name": "Mobile bookmarks",
         "type": "folder"
      }
   },
   "version": 1
}
"@
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
        $setupKey = "HKCU:\Software\Microsoft\Office\$v\Outlook\Setup"
        try {
            if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
            # Write as REG_EXPAND_SZ, not REG_SZ: Microsoft 365 (build 2023+) ignores the
            # plain REG_SZ default-signature values. -Force recreates the value with the
            # correct kind even if a prior run left a stale REG_SZ behind.
            New-ItemProperty -Path $key -Name 'NewSignature'   -Value $SignatureName -PropertyType ExpandString -Force | Out-Null
            New-ItemProperty -Path $key -Name 'ReplySignature' -Value $SignatureName -PropertyType ExpandString -Force | Out-Null
            # Roaming signatures are auto-on for M365 mailboxes and override the local default
            # set above, so without this the write has no visible effect. Disable it per-user
            # (create the Outlook\Setup key if this fresh profile does not have it yet).
            if (-not (Test-Path -LiteralPath $setupKey)) { New-Item -Path $setupKey -Force | Out-Null }
            New-ItemProperty -Path $setupKey -Name 'DisableRoamingSignatures' -Value 1 -PropertyType DWord -Force | Out-Null
            Write-PhaseLog OK "Default signature set for Office $v (new + reply, roaming off): $SignatureName"
        } catch {
            Write-PhaseLog WARN "Default signature for Office ${v}: $($_.Exception.Message)"
        }
    }
}

function ConvertFrom-SignatureHtml {
    # Reduce a signature .htm to readable plain text for the .txt/.rtf companions. Best-effort:
    # drop script/style blocks (so CSS never leaks into the text), turn block-level closes into
    # newlines, strip the remaining tags, decode the few entities a signature realistically holds.
    param([Parameter(Mandatory)][string]$Html)
    $t = $Html
    $t = [regex]::Replace($t, '(?is)<(script|style)\b[^>]*>.*?</\1>', '')
    $t = [regex]::Replace($t, '(?i)<br\s*/?>', "`n")
    $t = [regex]::Replace($t, '(?i)</(p|div|tr|li|h[1-6])\s*>', "`n")
    $t = [regex]::Replace($t, '(?s)<[^>]+>', '')
    $t = $t -replace '&nbsp;', ' ' -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' `
            -replace '&quot;', '"' -replace '&#39;', "'" -replace '&apos;', "'"
    $lines  = @($t -split "`n" | ForEach-Object { ($_ -replace '[ \t]+', ' ').Trim() })
    $joined = [regex]::Replace(($lines -join "`r`n"), '(?:\r?\n){3,}', "`r`n`r`n")
    return $joined.Trim()
}

function ConvertTo-SignatureRtf {
    # Wrap plain text in a minimal RTF document. Escapes \ { } and emits non-ASCII as \uN? so the
    # file stays pure ASCII and portable. A faithful HTML->RTF conversion is intentionally out of scope.
    param([Parameter(Mandatory)][string]$Text)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if     ($ch -eq '\')   { [void]$sb.Append('\\') }
        elseif ($ch -eq '{')   { [void]$sb.Append('\{') }
        elseif ($ch -eq '}')   { [void]$sb.Append('\}') }
        elseif ($ch -eq "`n")  { [void]$sb.Append('\par ') }
        elseif ($ch -eq "`r")  { }
        elseif ($code -gt 127) { [void]$sb.Append('\u' + $code + '?') }
        else                   { [void]$sb.Append($ch) }
    }
    return '{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0 Calibri;}}\f0\fs22 ' + $sb.ToString() + '}'
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

    # Outlook stores a signature as three files: .htm (HTML mail), .rtf (RTF mail) and .txt
    # (plain-text mail). Writing only the .htm leaves plain-text and RTF replies with no
    # signature, so derive both from the rendered HTML (the .htm stays the source of truth).
    $plainSig = ConvertFrom-SignatureHtml -Html $out
    [System.IO.File]::WriteAllText((Join-Path $sigFolder "$sigName.txt"), $plainSig, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $sigFolder "$sigName.rtf"), (ConvertTo-SignatureRtf -Text $plainSig), [System.Text.Encoding]::ASCII)

    Write-PhaseLog OK "Signature written: $sigFolder\$sigName (.htm/.rtf/.txt)"
    Write-PhaseLog INFO "Base: $($tpl.Name) | '$($res.OldName)' -> '$($State.FullName)' | '$($res.OldEmail)' -> '$($State.Email)'"

    Set-DefaultSignature -SignatureName $sigName
}

function Set-UserDefaultPrinter {
    param([string]$PrinterName)

    if ([string]::IsNullOrWhiteSpace($PrinterName)) {
        Write-PhaseLog INFO 'Default printer skipped (none in state)'
        return
    }

    # No Get-Printer -Name pre-check: -Name treats [ and ] as a wildcard class, so a bracketed
    # queue ("HP [Recepcao]") would never match even when present, skipping the default silently.
    # The CIM enumeration below is the single source of truth for existence (exact -eq match).
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
        # Capture the return: SetDefaultPrinter reports failure via ReturnValue, not an exception,
        # so piping to Out-Null would log "set" even when the spooler refused it (bad spooler state
        # or no interactive desktop) - a silent lie (audit: default printer can log OK while failing).
        $r = Invoke-CimMethod -InputObject $cim -MethodName SetDefaultPrinter
        if ($r.ReturnValue -eq 0) {
            Write-PhaseLog OK "Default printer set: $PrinterName"
        } else {
            Write-PhaseLog WARN "SetDefaultPrinter failed for '$PrinterName' (ReturnValue=$($r.ReturnValue))"
        }
    } else {
        Write-PhaseLog WARN "Printer '$PrinterName' not found - cannot set default"
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

# Seed the corp links into THIS user's Chrome + Edge profile so they sit loose on the bookmarks bar
# (the managed-policy path buried them in a folder). Runs as the standard user, so $env:LOCALAPPDATA
# points at that user's profile. -LocalAppData is injectable for tests. GUARD: skip a browser whose
# Bookmarks file already exists - never clobber real bookmarks, and avoid the checksum-mismatch
# discard on an already-launched profile (we write no checksum, valid only for a fresh file). On a
# fresh install the profile dir may not exist yet, so create it; the file is inert until the browser
# reads it on next launch. Best-effort per browser.
function Set-ChromiumBookmarks {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Bookmarks,
        [string]$LocalAppData = $env:LOCALAPPDATA
    )
    # Filter to real entries: a state.json round-trip can leave a null/blank element (e.g. a serialized
    # empty selection), which would otherwise seed a nameless bookmark.
    $valid = @($Bookmarks | Where-Object { $_ -and $_.Name -and $_.Url })
    if ($valid.Count -eq 0) {
        Write-PhaseLog INFO 'Bookmarks skipped (none selected)'
        return
    }

    $json = ConvertTo-ChromiumBookmarkFile -Bookmarks $valid
    $targets = @(
        @{ Name = 'Chrome'; Dir = (Join-Path $LocalAppData 'Google\Chrome\User Data\Default') },
        @{ Name = 'Edge';   Dir = (Join-Path $LocalAppData 'Microsoft\Edge\User Data\Default') }
    )
    foreach ($t in $targets) {
        try {
            $file = Join-Path $t.Dir 'Bookmarks'
            if (Test-Path -LiteralPath $file) {
                Write-PhaseLog INFO "$($t.Name) bookmarks already exist - skipped (won't clobber)"
                continue
            }
            New-Item -ItemType Directory -Path $t.Dir -Force | Out-Null
            # UTF-8 WITHOUT BOM - Chromium's JSON parser rejects a leading BOM.
            [System.IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding($false)))
            Write-PhaseLog OK "$($t.Name) bookmarks seeded (loose on bar): $file"
        } catch {
            Write-PhaseLog WARN "$($t.Name) bookmarks: $($_.Exception.Message)"
        }
    }
}

# Desktop shortcuts for daily-use web apps, mirroring the manual Chrome "Create shortcut" step
# techs used to perform (menu > Cast, save and share > Create shortcut). Piggybacks on the same
# per-link selection as the bookmarks (no extra checkbox): a shortcut is created for each ticked
# bookmark whose Name is listed in $DesktopShortcutBookmarks (config.ps1), carried here via
# state.json ($state.DesktopShortcutNames). A .url file needs no COM and opens in the default
# browser; the config may store the host bare (e.g. '10.0.0.127'), so prefix http:// when no
# scheme is present - .url targets must be absolute.
# GUARD: never overwrite an existing shortcut. -DesktopPath is injectable for tests.
function Set-BookmarkDesktopShortcut {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Bookmarks,
        [AllowEmptyCollection()][string[]]$Names = @(),
        [string]$DesktopPath = [Environment]::GetFolderPath('Desktop')
    )
    if (@($Names).Count -eq 0) {
        Write-PhaseLog INFO 'Desktop shortcuts skipped (no bookmark names configured)'
        return
    }
    $wanted = @($Bookmarks | Where-Object { $_ -and $_.Name -and ($Names -contains $_.Name) -and $_.Url })
    if ($wanted.Count -eq 0) {
        Write-PhaseLog INFO 'Desktop shortcuts skipped (no configured bookmark was selected)'
        return
    }

    foreach ($b in $wanted) {
        $url = [string]$b.Url
        if ($url -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $url = "http://$url" }

        $file = Join-Path $DesktopPath "$($b.Name).url"
        if (Test-Path -LiteralPath $file) {
            Write-PhaseLog INFO "Desktop shortcut already exists - skipped (won't clobber): $file"
            continue
        }
        Set-Content -LiteralPath $file -Value "[InternetShortcut]`r`nURL=$url" -Encoding ASCII
        Write-PhaseLog OK "Desktop shortcut created: $file -> $url"
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
    # Bookmarks first: the sooner we seed, the smaller the window for Edge startup-boost / Chrome
    # background mode to pre-create the profile Bookmarks file (which the skip-if-exists guard honors).
    try { Set-ChromiumBookmarks -Bookmarks $state.Bookmarks } catch { Write-PhaseLog ERROR "Bookmarks: $($_.Exception.Message)" }

    try { Set-BookmarkDesktopShortcut -Bookmarks $state.Bookmarks -Names $state.DesktopShortcutNames } catch { Write-PhaseLog ERROR "Desktop shortcut: $($_.Exception.Message)" }

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
