#Requires -Version 5.1
<#
.SYNOPSIS
    Prepares the provisioning USB. Always generates autounattend.xml from
    autounattend.template.xml (bootstrap admin name + password). With -GenerateConfig it
    runs an interactive wizard that ALSO writes config.ps1 and reports on the USB assets,
    so nothing has to be hand-edited in Notepad.

.DESCRIPTION
    The repository ships only the TEMPLATE (with __ADMIN_USER__ / __ADMIN_PW_B64__
    placeholders) and config.example.ps1 — no secret is versioned. This script fills the
    template and writes autounattend.xml to the USB root; both autounattend.xml and
    config.ps1 hold credentials, so both are in .gitignore — NEVER commit them.

    The autounattend password is BOOTSTRAP only: setup.ps1 rotates it on first login to the
    real password ($AdminNewPass in config.ps1). The bootstrap admin NAME is written into
    BOTH autounattend.xml and config.ps1's $AdminAccount from a single prompt, so they can
    never drift.

    -GenerateConfig walks every value that used to be hand-edited in config.ps1 (credentials,
    email domains, static IP, WiFi, wallpaper-by-domain, bookmarks), generates a valid
    config.ps1, then checks that the physical group-B assets exist on the USB (report only).
    Passwords are collected with Read-Host -AsSecureString and never echoed; config.ps1 stores
    them in plaintext (accepted trade-off — the file is gitignored and lives only on the USB).

.EXAMPLE
    .\build-usb.ps1 -GenerateConfig -OutPath E:\autounattend.xml
    # Full wizard: prompts for everything, writes E:\config.ps1 + E:\autounattend.xml, checks assets.

.EXAMPLE
    .\build-usb.ps1
    # Legacy: prompts only for the bootstrap admin name + password, writes .\autounattend.xml.

.EXAMPLE
    .\build-usb.ps1 -AdminUser setupadmin -OutPath E:\autounattend.xml
    # Prompts only for the password (hidden), writes autounattend.xml to the USB root (E:).

.EXAMPLE
    $pw = Read-Host 'Bootstrap password' -AsSecureString
    .\build-usb.ps1 -AdminUser setupadmin -AdminPassword $pw -OutPath E:\autounattend.xml -Force
    # Non-interactive: -AdminPassword takes a [securestring] (never a plaintext string);
    # -Force overwrites an existing autounattend.xml (re-burns the bootstrap password).
#>
[CmdletBinding()]
param(
    [string]$TemplatePath,
    [string]$OutPath,
    [string]$AdminUser,
    [securestring]$AdminPassword,
    [switch]$Force,
    # Run the interactive wizard that also generates config.ps1 + an asset check. Without it,
    # the script keeps its legacy behaviour (autounattend.xml only) so existing callers/tests
    # are unaffected.
    [switch]$GenerateConfig,
    # Also prompt the 7 $Path* overrides. Off by default: an existing config.ps1's paths are
    # preserved as-is, else the config.example.ps1 defaults are used.
    [switch]$Advanced,
    # Where to write config.ps1 (default: next to autounattend.xml on the USB root).
    [string]$ConfigPath,
    # Test seam: dot-source with -LoadOnly to define the pure helpers below WITHOUT running
    # the body (used by tests/unit). Never set in production. Mirrors setup.ps1 -LoadOnly.
    [switch]$LoadOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MinPasswordLength         = 1    # hard floor: only an empty password is rejected (WiFi passes its own WPA2 floor of 8)
$RecommendedPasswordLength = 12   # soft floor: a shorter password prints a warning but is accepted

# ============================================================
# Pure, unit-testable helpers (above the -LoadOnly seam, like setup.ps1). No side effects and
# no Read-Host, so tests dot-source `build-usb.ps1 -LoadOnly` to exercise them in isolation.
# ============================================================

# The verbatim $Path* block emitted into the generated config.ps1. Kept byte-for-byte in sync
# with config.example.ps1. Double-quoted on purpose: $ScriptDir (set by setup.ps1 before it
# dot-sources config.ps1) must EXPAND at load time — so this block never goes through
# Format-PsString (which would single-quote it and break the expansion).
$script:DefaultPathBlock = @'
# --- Paths — everything on the USB ($ScriptDir = USB root, set by setup.ps1) ---
$PathOffice     = "$ScriptDir\Office"               # ODT folder: needs setup.exe + configuration.xml (copy configuration.example.xml); falls back to OfficeSetup.exe at the root
$PathBelarc     = $ScriptDir                        # belarc.exe at the USB root
$PathEpson      = "$ScriptDir\Drivers Epson"        # folder with the extracted Epson INF driver (registered silently via pnputil; no vendor .exe, no GUI)
$PathWebAgent   = "$ScriptDir\WebAgent\windows"     # folder with the WebAgent .msi
$PathSignatures = "$ScriptDir\signatures-2026"      # structure: \{domain}\{sector}\user.htm
$PathVPN        = "$ScriptDir\VPN"                  # OpenVPN: folder with the .msi installer + the .ovpn profile; omit/empty to disable the VPN option in the GUI

# --- Cloud agent (optional vendor toolkit; empty $PathCloudAgent = skip the step) ---
$PathCloudAgent       = "$ScriptDir\CloudAgent"     # toolkit folder on the USB (exes + installer bat)
$CloudAgentInstaller  = 'install.bat'               # installer bat name inside that folder
$CloudAgentInstallDir = 'C:\CloudAgent'             # local retention copy target on the machine
'@

# Encode a string as a single-quoted PowerShell literal. Single-quoted strings do NOT interpret
# $, backtick or " — only the single quote needs doubling — so any value (passwords included)
# round-trips byte-for-byte when the generated config.ps1 is dot-sourced. This one function is
# what makes the whole serializer injection-safe and round-trip-safe.
function Format-PsString {
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

# Convert a SecureString to plaintext for the shortest possible window, scrubbing the unmanaged
# BSTR in finally. Used only when building the base64 / writing config.ps1, never echoed.
function ConvertFrom-SecureStringToPlainText {
    [OutputType([string])]
    param([Parameter(Mandatory)][securestring]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Strict IPv4: exactly 4 octets, each 0-255 (mirrors setup.ps1's validator so the wizard rejects
# the same inputs the GUI would). Empty -> false; callers treat empty as "skip static IP".
function Test-Ipv4 {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) { return $false }
    $o = $Ip.Trim() -split '\.'
    if ($o.Count -ne 4) { return $false }
    foreach ($x in $o) { if ($x -notmatch '^\d{1,3}$' -or [int]$x -gt 255) { return $false } }
    return $true
}

# Image files directly under $Directory that could serve as a wallpaper (leaf names, sorted
# case-insensitively). Non-recursive: wallpapers live at the USB root, alongside config.ps1.
# Pure and read-only (no prompts), so the wizard uses it to offer a pick-list instead of making
# the operator type a filename, and tests dot-source -LoadOnly and point it at a temp folder.
function Get-WallpaperCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Directory)
    if ([string]::IsNullOrEmpty($Directory) -or -not (Test-Path -LiteralPath $Directory)) { return @() }
    $exts = '.jpg', '.jpeg', '.png', '.bmp'
    @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
        Where-Object { $exts -contains $_.Extension.ToLowerInvariant() } |
        ForEach-Object { $_.Name } |
        Sort-Object)
}

# Pure serializer: a value hashtable -> the full config.ps1 text. Every operator string goes
# through Format-PsString; every collection is wrapped in @()/@{} so a single element never
# collapses to a scalar under PS 5.1; the $Path* block is emitted verbatim. The output is
# guaranteed to dot-source back to the same values (see ConfigGen.Tests.ps1 round-trips).
function ConvertTo-ConfigPs1Content {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [string]$PathBlock = $script:DefaultPathBlock
    )

    # Read helpers that INDEX $Values directly by key. They never take an array as an argument:
    # passing an empty @() positionally would unroll to zero args and leave the param $null,
    # which then serialized as @('') instead of @(). Each returns a finished PS literal / string.
    $scalar = {
        param($Key)
        if ($Values.ContainsKey($Key) -and $null -ne $Values[$Key]) { [string]$Values[$Key] } else { '' }
    }
    $strArray = {
        param($Key)
        $items = @()
        if ($Values.ContainsKey($Key) -and $null -ne $Values[$Key]) { $items = @($Values[$Key]) }
        if ($items.Count -eq 0) { return '@()' }
        '@(' + (($items | ForEach-Object { Format-PsString ([string]$_) }) -join ', ') + ')'
    }

    $adminAccount    = Format-PsString (& $scalar 'AdminAccount')
    $adminNewPass    = Format-PsString (& $scalar 'AdminNewPass')
    $userInitialPass = Format-PsString (& $scalar 'UserInitialPass')
    $emailDomains    = & $strArray 'EmailDomains'
    $staticGateway   = Format-PsString (& $scalar 'StaticGateway')
    $prefix          = 24
    if ($Values.ContainsKey('StaticPrefixLength') -and $null -ne $Values['StaticPrefixLength']) { $prefix = [int]$Values['StaticPrefixLength'] }
    $dnsServers      = & $strArray 'DnsServers'
    $wallpaperFile   = Format-PsString (& $scalar 'WallpaperFile')
    $wifiSsid        = Format-PsString (& $scalar 'WifiSSID')
    $wifiPass        = Format-PsString (& $scalar 'WifiPass')

    # $WallpaperByDomain hashtable, keys sorted for deterministic output; '@{ }' when empty.
    $map = @{}
    if ($Values.ContainsKey('WallpaperByDomain') -and $Values['WallpaperByDomain'] -is [hashtable]) { $map = $Values['WallpaperByDomain'] }
    if ($map.Count -eq 0) {
        $wpMap = '@{ }'
    } else {
        $pairs = foreach ($k in ($map.Keys | Sort-Object)) {
            '{0} = {1}' -f (Format-PsString ([string]$k)), (Format-PsString ([string]$map[$k]))
        }
        $wpMap = '@{ ' + ($pairs -join '; ') + ' }'
    }

    # $Bookmarks array-of-hashtables, one entry per line inside @( … ); '@()' when empty.
    $bm = @()
    if ($Values.ContainsKey('Bookmarks') -and $null -ne $Values['Bookmarks']) { $bm = @($Values['Bookmarks']) }
    if ($bm.Count -eq 0) {
        $bookmarks = '@()'
    } else {
        $lines = foreach ($b in $bm) {
            '    @{{ Name = {0}; Url = {1} }}' -f (Format-PsString ([string]$b.Name)), (Format-PsString ([string]$b.Url))
        }
        $bookmarks = "@(`n" + ($lines -join "`n") + "`n)"
    }

    # Assemble by concatenation, NEVER an expandable here-string: the literal "$AdminAccount ="
    # text lives in single-quoted strings so it is emitted, not interpolated (and StrictMode
    # would throw on the undefined vars anyway). Computed values are appended.
    $out = New-Object System.Collections.Generic.List[string]
    $add = { param($Line) $out.Add($Line) }

    & $add '# ============================================================'
    & $add '# config.ps1 — generated by build-usb.ps1 (do NOT hand-edit; re-run the wizard instead)'
    & $add '# gitignored — NEVER commit (holds plaintext credentials, lives only on the USB)'
    & $add '# ============================================================'
    & $add ''
    & $add '# --- Local administration credentials ---'
    & $add ('$AdminAccount    = ' + $adminAccount)
    & $add ('$AdminNewPass    = ' + $adminNewPass)
    & $add ('$UserInitialPass = ' + $userInitialPass)
    & $add ''
    & $add '# --- Email domains (GUI dropdown) ---'
    & $add ('$EmailDomains = ' + $emailDomains)
    & $add ''
    & $add '# --- Static IP (used when the technician picks "Static IP" in the GUI) ---'
    & $add ('$StaticGateway      = ' + $staticGateway)
    & $add ('$StaticPrefixLength = ' + [string]$prefix)
    & $add ('$DnsServers         = ' + $dnsServers)
    & $add ''
    & $add '# --- Wallpaper (filenames at the USB root; per-domain override, else the default) ---'
    & $add ('$WallpaperFile     = ' + $wallpaperFile)
    & $add ('$WallpaperByDomain = ' + $wpMap)
    & $add ''
    & $add '# --- Corporate WiFi ---'
    & $add ('$WifiSSID = ' + $wifiSsid)
    & $add ('$WifiPass = ' + $wifiPass)
    & $add ''
    & $add $PathBlock
    & $add ''
    & $add '# --- Corporate browser bookmarks (Chrome / Edge / Firefox) — one GUI checkbox per entry ---'
    & $add ('$Bookmarks = ' + $bookmarks)
    & $add ''
    & $add '# Bookmarks (by Name) that also get a desktop .url shortcut in Phase B; @() for none.'
    & $add ('$DesktopShortcutBookmarks = ' + (& $strArray 'DesktopShortcutBookmarks'))
    & $add ''

    return ($out -join "`n")
}

# If a config.ps1 already exists, load its current values as wizard defaults. Dot-sources INSIDE
# this function so the config vars land in the function scope and die on return (the wizard scope
# stays clean). $ScriptDir is predefined because the $Path* lines expand it; every var is read via
# Get-Variable -ErrorAction SilentlyContinue so a config that omits optionals is StrictMode-safe.
function Import-ConfigDefault {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ScriptDirValue = 'C:\USB'
    )
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $ScriptDir = $ScriptDirValue   # referenced by the $Path* lines in config.ps1
    try {
        . $Path
    } catch {
        # Deliberately NOT interpolating the exception: a ParseException message embeds the
        # offending source line, which in config.ps1 can be a plaintext credential.
        Write-Warning 'Existing config.ps1 could not be read for defaults - starting blank.'
        return $result
    }
    foreach ($k in @('AdminAccount', 'AdminNewPass', 'UserInitialPass', 'EmailDomains',
                     'StaticGateway', 'StaticPrefixLength', 'DnsServers', 'WallpaperFile',
                     'WallpaperByDomain', 'WifiSSID', 'WifiPass', 'Bookmarks',
                     'PathOffice', 'PathBelarc', 'PathEpson', 'PathWebAgent', 'PathSignatures',
                     'PathVPN', 'PathCloudAgent', 'CloudAgentInstaller', 'CloudAgentInstallDir',
                     'DesktopShortcutBookmarks')) {
        # Read .Value (property access) rather than -ValueOnly (pipeline output): the latter
        # ENUMERATES the value, collapsing a single-element $EmailDomains/$Bookmarks array to a
        # scalar and an empty array to $null. .Value preserves the array shape.
        $var = Get-Variable -Name $k -Scope Local -ErrorAction SilentlyContinue
        if ($null -ne $var) { $result[$k] = $var.Value }
    }
    return $result
}

# Canonical $Path* variable set (name -> default subfolder relative to $ScriptDir; '' = the USB
# root itself). Single source for the Advanced prompts and for the per-var fallback when an
# existing config.ps1 omits one. Order mirrors config.example.ps1.
$script:PathVarSpecs = [ordered]@{
    PathOffice     = 'Office'
    PathBelarc     = ''
    PathEpson      = 'Drivers Epson'
    PathWebAgent   = 'WebAgent\windows'
    PathSignatures = 'signatures-2026'
    PathVPN        = 'VPN'
    PathCloudAgent = 'CloudAgent'
}

# Undo the load-time expansion of a $Path* value read back by Import-ConfigDefault (its dot-source
# expanded "$ScriptDir\..." with -ScriptDirValue baked in). Classifies the value against that same
# root: Root (the root itself), Suffix (below it; Suffix = the relative part), or Literal
# (anywhere else - kept verbatim). Comparisons are case-insensitive because Windows paths are; the
# prefix keeps its trailing '\' so a sibling like C:\USBX never false-matches root C:\USB.
function Split-ScriptDirPath {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$ScriptDirValue
    )
    $root = $ScriptDirValue.TrimEnd('\')   # a drive-root USB arrives as 'E:\'
    if ($Value.TrimEnd('\') -eq $root) { return @{ Kind = 'Root'; Suffix = '' } }
    $prefix = $root + '\'
    if ($Value.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return @{ Kind = 'Suffix'; Suffix = $Value.Substring($prefix.Length) }
    }
    return @{ Kind = 'Literal'; Suffix = $Value }
}

# The $Path* block the wizard emits. When the loaded config.ps1 carried any path / cloud-agent
# value, rebuild the block from those values so a re-run PRESERVES them (the same "Enter keeps the
# value" promise the scalar prompts make); otherwise return $script:DefaultPathBlock verbatim,
# comments included. $ScriptDirValue MUST be the same root that was passed to Import-ConfigDefault
# - Split-ScriptDirPath strips it back off the expanded values. Suffixes/literals are emitted
# single-quoted (Format-PsString), the same injection-safe form the Advanced prompts use.
function ConvertTo-PathBlock {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Defaults,
        [Parameter(Mandatory)][string]$ScriptDirValue
    )
    $known = @($script:PathVarSpecs.Keys) + @('CloudAgentInstaller', 'CloudAgentInstallDir')
    if (@($known | Where-Object { $Defaults.ContainsKey($_) }).Count -eq 0) {
        return $script:DefaultPathBlock
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# --- Paths — everything on the USB ($ScriptDir = USB root, set by setup.ps1) ---')
    $lines.Add('# Preserved from the existing config.ps1 (see config.example.ps1 for the defaults).')
    foreach ($name in $script:PathVarSpecs.Keys) {
        if ($name -eq 'PathCloudAgent') {   # section break, mirrors the default block
            $lines.Add('')
            $lines.Add('# --- Cloud agent (optional vendor toolkit; empty $PathCloudAgent = skip the step) ---')
        }
        if ($Defaults.ContainsKey($name)) {
            $split = Split-ScriptDirPath -Value ([string]$Defaults[$name]) -ScriptDirValue $ScriptDirValue
            switch ($split.Kind) {
                'Root'    { $lines.Add(('${0} = $ScriptDir' -f $name)) }
                'Suffix'  { $lines.Add(('${0} = Join-Path $ScriptDir {1}' -f $name, (Format-PsString $split.Suffix))) }
                'Literal' { $lines.Add(('${0} = {1}' -f $name, (Format-PsString $split.Suffix))) }
            }
        } else {
            # Var absent from the loaded config (partial/legacy file): emit its default.
            $suffix = $script:PathVarSpecs[$name]
            if ([string]::IsNullOrEmpty($suffix)) { $lines.Add(('${0} = $ScriptDir' -f $name)) }
            else { $lines.Add(('${0} = Join-Path $ScriptDir {1}' -f $name, (Format-PsString $suffix))) }
        }
    }
    $installer  = if ($Defaults.ContainsKey('CloudAgentInstaller'))  { [string]$Defaults['CloudAgentInstaller'] }  else { 'install.bat' }
    $installDir = if ($Defaults.ContainsKey('CloudAgentInstallDir')) { [string]$Defaults['CloudAgentInstallDir'] } else { 'C:\CloudAgent' }
    $lines.Add(('$CloudAgentInstaller  = {0}' -f (Format-PsString $installer)))
    $lines.Add(('$CloudAgentInstallDir = {0}' -f (Format-PsString $installDir)))
    return ($lines -join "`n")
}

# Test seam: stop here so -LoadOnly defines only the pure helpers above (tests/unit), never the body.
if ($LoadOnly) { return }

# ============================================================
# Body
# ============================================================

# Resolve the script's own folder. $PSScriptRoot can be EMPTY when referenced inside a
# param() default (it is not always populated at parameter-binding time, e.g. launched via
# `powershell -File`), which made Join-Path fail. Resolve it here in the body with a fallback
# and default the paths from it instead of in the param block.
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $TemplatePath) { $TemplatePath = Join-Path $ScriptDir 'autounattend.template.xml' }
if (-not $OutPath)      { $OutPath      = Join-Path $ScriptDir 'autounattend.xml' }
# Only the wizard needs config.ps1 — and a bare relative -OutPath (legacy usage, resolved
# against the current dir) has no parent: Split-Path returns '' and Join-Path throws. Resolve
# to a full path first (GetUnresolvedProviderPathFromPSPath honors the PS location and does
# not require the file to exist yet).
if ($GenerateConfig -and -not $ConfigPath) {
    $outFull    = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutPath)
    $ConfigPath = Join-Path (Split-Path -Parent $outFull) 'config.ps1'
}

if (-not (Test-Path $TemplatePath)) {
    throw "Template not found: $TemplatePath"
}

# ============================================================
# Interactive wizard (only with -GenerateConfig): collect every hand-edited config value,
# write config.ps1, and set $AdminUser/$AdminPassword/$Force so the autounattend generation
# below reuses them (bootstrap name -> config $AdminAccount, so they can never drift).
# ============================================================
if ($GenerateConfig) {
    # --- UI helpers + prompt primitives (below the seam: they use Read-Host / colored Write-Host,
    # so they never run under -LoadOnly). One consistent look: a colored bar per section, gray help
    # lines, a "   >" input caret, green confirmations, yellow warnings. ---

    # Section bar: black text on a dark-cyan strip, padded so the colour runs across the line.
    $banner = {
        param($Title)
        Write-Host ''
        Write-Host ((' ' + $Title).PadRight(58)) -ForegroundColor Black -BackgroundColor DarkCyan
    }
    # Gray helper/example line under a banner.
    $note = { param($Text) Write-Host ("   {0}" -f $Text) -ForegroundColor DarkGray }
    # Green confirmation of a captured value.
    $ok   = { param($Text) Write-Host ("   -> {0}" -f $Text) -ForegroundColor Green }

    # Prompt for a line with an optional shown default; empty input keeps the default.
    $askText = {
        param($Label, $Default)
        $shown = if ($Default) { " [$Default]" } else { '' }
        Write-Host ("   {0}{1}" -f $Label, $shown) -ForegroundColor Gray
        $ans = (Read-Host '   >').Trim()
        if ($ans) { $ans } else { [string]$Default }
    }
    # Prompt for a secret (never echoed). Blank keeps $ExistingPlain when given; otherwise loops
    # ONLY while below $MinLength (the HARD floor — default 1, so just empty is rejected; WiFi
    # passes 8 for WPA2). A non-empty value under $Recommended (soft floor, default 12) is
    # accepted with a warning, never blocked. Returns plaintext (write-time only).
    $askSecret = {
        param($Label, $ExistingPlain, $MinLength = $MinPasswordLength, $Recommended = $RecommendedPasswordLength)
        $hint = if ($ExistingPlain) { ' [Enter = keep ****]' } else { '' }
        while ($true) {
            Write-Host ("   {0}{1}" -f $Label, $hint) -ForegroundColor Gray
            $sec = Read-Host '   >' -AsSecureString
            if ($sec.Length -eq 0) {
                if ($ExistingPlain) { return $ExistingPlain }
                Write-Host '   Value required.' -ForegroundColor Yellow
                continue
            }
            $plain = ConvertFrom-SecureStringToPlainText $sec
            if ($plain.Length -lt $MinLength) {
                Write-Host "   Too short: minimum $MinLength characters." -ForegroundColor Yellow
                $plain = $null
                continue
            }
            # A new secret is typed once, hidden and never echoed, so a typo would silently
            # provision the whole fleet with an unknown password (audit C3). Require an identical
            # re-type before accepting a newly entered value.
            Write-Host '   Confirm (type it again)' -ForegroundColor Gray
            $sec2   = Read-Host '   >' -AsSecureString
            $plain2 = ConvertFrom-SecureStringToPlainText $sec2
            if ($plain -cne $plain2) {
                Write-Host '   The two entries do not match - try again.' -ForegroundColor Yellow
                $plain = $null; $plain2 = $null
                continue
            }
            $plain2 = $null
            if ($Recommended -and $plain.Length -lt $Recommended) {
                Write-Host "   Warning: $($plain.Length) characters (under the recommended $Recommended). Accepted anyway." -ForegroundColor Yellow
            }
            return $plain
        }
    }
    # Comma-separated list -> trimmed, de-blanked array.
    $askList = {
        param($Label, $Default)
        $shown = if (@($Default).Count) { " [" + (@($Default) -join ', ') + "]" } else { '' }
        Write-Host ("   {0}{1}" -f $Label, $shown) -ForegroundColor Gray
        $ans = (Read-Host '   >').Trim()
        if (-not $ans) { return @($Default | Where-Object { $_ }) }
        @($ans -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    # Pick an image detected on the USB by number, or type any filename, or Enter to keep
    # $Default. Falls back to plain typing (like $askText) when no images were detected, so an
    # empty USB still works. Returns the chosen filename ('' when none).
    $askImage = {
        param($Label, $Default, $Images)
        if (-not @($Images).Count) { return [string](& $askText "$Label (filename at USB root)" $Default) }
        Write-Host ("   {0}" -f $Label) -ForegroundColor Gray
        for ($i = 0; $i -lt @($Images).Count; $i++) {
            $mark = if ($Images[$i] -eq $Default) { '  <- current' } else { '' }
            Write-Host ("     [{0}] {1}{2}" -f ($i + 1), $Images[$i], $mark) -ForegroundColor DarkGray
        }
        $shown = if ($Default) { " [$Default]" } else { '' }
        Write-Host ("   pick a number, type a filename, or Enter{0}" -f $shown) -ForegroundColor DarkGray
        $ans = (Read-Host '   >').Trim()
        if (-not $ans) { return [string]$Default }
        if ($ans -match '^\d+$' -and [int]$ans -ge 1 -and [int]$ans -le @($Images).Count) {
            return [string]$Images[[int]$ans - 1]
        }
        return $ans   # a literal filename (may not exist yet — the asset check below flags it)
    }

    Write-Host ''
    Write-Host '  =====================================================' -ForegroundColor DarkCyan
    Write-Host '   USB CONFIG WIZARD' -ForegroundColor White
    Write-Host '  =====================================================' -ForegroundColor DarkCyan
    & $note 'Press Enter to keep the shown default. Secrets are never shown. Ctrl+C aborts.'

    # Load an existing config.ps1 (if any) for defaults.
    $def = Import-ConfigDefault -Path $ConfigPath -ScriptDirValue $ScriptDir
    $getDef = { param($Key, $Fallback) if ($def.ContainsKey($Key)) { $def[$Key] } else { $Fallback } }

    $cfg = @{}

    & $banner 'Credentials'
    & $note 'The bootstrap admin account, plus the two real passwords setup.ps1 will set.'
    $cfg['AdminAccount']    = & $askText   'Bootstrap admin account name' (& $getDef 'AdminAccount' 'setupadmin')
    $cfg['AdminNewPass']    = & $askSecret 'Real admin password ($AdminNewPass)'        (& $getDef 'AdminNewPass' '')
    $cfg['UserInitialPass'] = & $askSecret 'New user''s initial password ($UserInitialPass)' (& $getDef 'UserInitialPass' '')

    & $banner 'Email domains'
    & $note "The mail domains your company uses - the part after the '@' in an address."
    Write-Host '   Example:  ana@acme.com.br  ->  the domain is  ' -ForegroundColor DarkGray -NoNewline
    Write-Host 'acme.com.br' -ForegroundColor White
    & $note 'Add them one per line; press Enter on an empty line when done.'
    & $note '(You can also paste several at once, separated by commas.)'
    $domainList = New-Object System.Collections.Generic.List[string]
    $existingDomains = @(& $getDef 'EmailDomains' @() | Where-Object { $_ })
    if ($existingDomains.Count) {
        Write-Host ('   Current: ' + ($existingDomains -join ', ')) -ForegroundColor Green
        if ((Read-Host '   Keep these? [Y/n]').Trim() -notmatch '^[nN]') {
            $existingDomains | ForEach-Object { $domainList.Add($_) }
        }
    }
    if ($domainList.Count -eq 0) {
        while ($true) {
            $entry = (Read-Host ("   Domain #{0} (Enter = finish)" -f ($domainList.Count + 1))).Trim()
            if (-not $entry) {
                if ($domainList.Count) { break }
                Write-Host '   You need at least one domain to continue.' -ForegroundColor Yellow
                continue
            }
            foreach ($part in ($entry -split ',')) {
                $p = $part.Trim()
                if ($p -and -not $domainList.Contains($p)) { $domainList.Add($p) }
            }
            Write-Host ('   Domains so far: ' + ($domainList -join ', ')) -ForegroundColor Green
        }
    }
    $domains = @($domainList)
    $cfg['EmailDomains'] = $domains
    & $ok ("{0} domain(s): {1}" -f $domains.Count, ($domains -join ', '))

    & $banner 'Network - static IP (optional)'
    & $note 'Leave the gateway blank to keep DHCP (skips static IP entirely).'
    $gw = & $askText 'Gateway (blank = skip static IP)' (& $getDef 'StaticGateway' '')
    # Re-prompt an invalid gateway instead of silently discarding the whole static-IP block
    # (audit A2). A blank stays a deliberate "skip static IP".
    while ($gw -and -not (Test-Ipv4 $gw)) {
        Write-Host "   '$gw' is not a valid IPv4. Enter a valid gateway, or leave blank to skip static IP." -ForegroundColor Yellow
        $gw = & $askText 'Gateway (blank = skip static IP)' ''
    }
    $cfg['StaticGateway'] = $gw
    if ($gw) {
        # Validate BEFORE the [int] cast: under EAP=Stop a bare [int]'/24' throws and kills the
        # whole wizard, discarding every answer typed so far. Loop until sane, like $askSecret.
        $prefixRaw = [string](& $askText 'Prefix length (e.g. 24)' (& $getDef 'StaticPrefixLength' 24))
        while ($prefixRaw -notmatch '^\d{1,2}$' -or [int]$prefixRaw -lt 1 -or [int]$prefixRaw -gt 32) {
            Write-Host '   Enter a number from 1 to 32 (e.g. 24).' -ForegroundColor Yellow
            $prefixRaw = [string](& $askText 'Prefix length (e.g. 24)' 24)
        }
        $cfg['StaticPrefixLength'] = [int]$prefixRaw
        $dns = & $askList 'DNS servers' (& $getDef 'DnsServers' @('8.8.8.8', '8.8.4.4'))
        $dnsValid = @($dns | Where-Object { Test-Ipv4 $_ })
        # Warn instead of silently dropping every DNS entry (audit A2): an all-invalid list would
        # otherwise write $DnsServers = @() with no hint to the operator.
        if (@($dns).Count -and -not $dnsValid.Count) {
            Write-Host '   None of the DNS entries were valid IPv4 - no DNS will be set for this static IP.' -ForegroundColor Yellow
        }
        $cfg['DnsServers'] = $dnsValid
        & $ok ("static IP via gateway {0}/{1}, DNS {2}" -f $gw, $cfg['StaticPrefixLength'], (@($cfg['DnsServers']) -join ', '))
    } else {
        # Same guard on the carried-over value: an existing hand-edited config could hold anything.
        $prevPrefix = [string](& $getDef 'StaticPrefixLength' 24)
        $cfg['StaticPrefixLength'] = if ($prevPrefix -match '^\d{1,2}$' -and [int]$prevPrefix -ge 1 -and [int]$prevPrefix -le 32) { [int]$prevPrefix } else { 24 }
        $cfg['DnsServers'] = @()
        & $note 'Static IP skipped - the machine will use DHCP.'
    }

    & $banner 'Wallpaper'
    # Auto-detect images sitting at the USB root (next to config.ps1) so the wallpaper never has
    # to be typed by hand. Empty USB -> $askImage falls back to plain typing.
    $usbImages = @(Get-WallpaperCandidate -Directory (Split-Path -Parent $ConfigPath))
    if ($usbImages.Count) {
        & $note ("Detected {0} image(s) on the USB root." -f $usbImages.Count)
    } else {
        & $note 'No images detected on the USB root yet - type a filename (add the file later).'
    }
    # Pre-select the sole image as the default when nothing was configured before.
    $defWall = [string](& $getDef 'WallpaperFile' '')
    if (-not $defWall -and $usbImages.Count -eq 1) { $defWall = $usbImages[0] }
    $cfg['WallpaperFile'] = & $askImage 'Default wallpaper' $defWall $usbImages
    $wpDefault = [hashtable](& $getDef 'WallpaperByDomain' @{})
    $wpMap = @{}
    $hadOverrides = @($wpDefault.Keys).Count -gt 0
    Write-Host ''
    if ($cfg['WallpaperFile']) {
        Write-Host ("   By default every domain uses: {0}" -f $cfg['WallpaperFile']) -ForegroundColor Green
    } else {
        Write-Host '   No default wallpaper chosen.' -ForegroundColor DarkGray
    }
    if ($hadOverrides) {
        Write-Host ('   Current per-domain overrides: ' +
            (@($wpDefault.Keys | ForEach-Object { "$_ -> $($wpDefault[$_])" }) -join ', ')) -ForegroundColor Green
    }
    # Common case: one wallpaper for all - so only walk the per-domain loop on an explicit yes.
    # Existing overrides flip the default to yes, so re-running never silently drops them.
    $wantPer = if ($hadOverrides) {
        (Read-Host '   Give some domains a DIFFERENT wallpaper? [Y/n]').Trim() -notmatch '^[nN]'
    } else {
        (Read-Host '   Give some domains a DIFFERENT wallpaper? [y/N]').Trim() -match '^[yY]'
    }
    if ($wantPer) {
        Write-Host '   For each domain: pick a number, type a filename, or press Enter to keep the default.' -ForegroundColor DarkGray
        foreach ($d in $domains) {
            Write-Host ("   -- {0} --" -f $d) -ForegroundColor Cyan
            $cur = if ($wpDefault.ContainsKey($d)) { [string]$wpDefault[$d] } else { '' }
            $wp = & $askImage '   wallpaper' $cur $usbImages
            if ($wp -and $wp -ne $cfg['WallpaperFile']) { $wpMap[$d] = $wp }
        }
    }
    $cfg['WallpaperByDomain'] = $wpMap

    & $banner 'Corporate WiFi (optional)'
    & $note 'Leave the SSID blank to skip WiFi setup.'
    $ssid = & $askText 'WiFi SSID' (& $getDef 'WifiSSID' '')
    $cfg['WifiSSID'] = $ssid
    if ($ssid) {
        # Hard floor 8, no soft warning (Recommended = 0): WPA2-PSK passphrases are valid from 8
        # chars, and this is an EXTERNAL credential that must match the already-deployed network.
        # A shorter value would produce an invalid netsh profile, so 8 stays a real block here
        # (unlike the admin/user secrets, which only warn). A 12 floor would make a real 8-11
        # char corp passphrase impossible to enter.
        $cfg['WifiPass'] = & $askSecret 'WiFi password' (& $getDef 'WifiPass' '') 8 0
        & $ok ("WiFi '{0}' configured." -f $ssid)
    } else {
        $cfg['WifiPass'] = ''
        & $note 'WiFi skipped.'
    }

    & $banner 'Bookmarks'
    & $note 'Links pinned loose on the browser bookmarks bar. Blank name = finish.'
    $existingBm = @(& $getDef 'Bookmarks' @())
    if ($existingBm.Count) {
        & $note ('Current: ' + (($existingBm | ForEach-Object { $_.Name }) -join ', '))
        $keep = (Read-Host '   Keep the current bookmarks? [Y/n]').Trim()
        if ($keep -notmatch '^[nN]') { $cfg['Bookmarks'] = $existingBm }
    }
    if (-not $cfg.ContainsKey('Bookmarks')) {
        $bmList = @()
        while ($true) {
            Write-Host ("   Bookmark #{0} name (blank to finish)" -f ($bmList.Count + 1)) -ForegroundColor Gray
            $bn = (Read-Host '   >').Trim()
            if (-not $bn) { break }
            Write-Host ("   URL for '{0}'" -f $bn) -ForegroundColor Gray
            $bu = (Read-Host '   >').Trim()
            if (-not $bu) { Write-Host '   URL required - skipped.' -ForegroundColor Yellow; continue }
            $bmList += @{ Name = $bn; Url = $bu }
            & $ok ("added '{0}'" -f $bn)
        }
        $cfg['Bookmarks'] = $bmList
    }

    # Not prompted: carried over from the loaded config so a re-run does not reset it to @()
    # (setup.ps1 matches these names against the ticked bookmarks; a stale name is inert).
    $cfg['DesktopShortcutBookmarks'] = @((& $getDef 'DesktopShortcutBookmarks' $null) | Where-Object { $_ })

    # --- optional $Path* overrides ---
    # Preserve loaded paths on a re-run: ConvertTo-PathBlock rebuilds the block from $def (same
    # $ScriptDir root the loader expanded with); fresh runs get the default block back.
    $pathBlock = ConvertTo-PathBlock -Defaults $def -ScriptDirValue $ScriptDir
    if (-not $Advanced -and $pathBlock -cne $script:DefaultPathBlock) {
        & $note 'Paths kept from the existing config.ps1 (re-run with -Advanced to change them).'
    }
    if ($Advanced) {
        & $banner 'Paths (Advanced)'
        & $note 'Subfolder (relative to the USB root) for each asset group; Enter keeps the default.'
        $pathBlock = & {
            $lines = New-Object System.Collections.Generic.List[string]
            $lines.Add('# --- Paths — everything on the USB ($ScriptDir = USB root, set by setup.ps1) ---')
            # Prompt defaults: the loaded config's suffix when it has one (Enter keeps it), else
            # the canonical default from $script:PathVarSpecs. A Literal (outside the USB root)
            # cannot be expressed as a suffix, so it keeps the canonical default here - the
            # non-Advanced flow is the one that preserves literals verbatim. Emitted as Join-Path
            # with a single-quoted suffix so a typed value can never inject $(...) at dot-source.
            $specs = [ordered]@{}
            foreach ($name in $script:PathVarSpecs.Keys) {
                $seed = $script:PathVarSpecs[$name]
                if ($def.ContainsKey($name)) {
                    $split = Split-ScriptDirPath -Value ([string]$def[$name]) -ScriptDirValue $ScriptDir
                    if ($split.Kind -ne 'Literal') { $seed = $split.Suffix }
                }
                $specs[$name] = $seed
            }
            foreach ($name in $specs.Keys) {
                $suffix = & $askText ("  `$$name suffix") $specs[$name]
                if ([string]::IsNullOrEmpty($suffix)) {
                    $lines.Add(('${0} = $ScriptDir' -f $name))
                } else {
                    $lines.Add(('${0} = Join-Path $ScriptDir {1}' -f $name, (Format-PsString $suffix)))
                }
            }
            # Non-path cloud-agent scalars: keep the generated config complete in Advanced mode too.
            $agentBat = & $askText '  $CloudAgentInstaller (bat name)' (& $getDef 'CloudAgentInstaller' 'install.bat')
            $agentDir = & $askText '  $CloudAgentInstallDir (local copy dir)' (& $getDef 'CloudAgentInstallDir' 'C:\CloudAgent')
            $lines.Add(('$CloudAgentInstaller  = {0}' -f (Format-PsString $agentBat)))
            $lines.Add(('$CloudAgentInstallDir = {0}' -f (Format-PsString $agentDir)))
            $lines -join "`n"
        }
    }

    # --- write config.ps1 (confirm overwrite; Enter = yes) ---
    # Default = overwrite: the wizard just loaded this very file as its defaults, so Enter-kept
    # answers reproduce it - and every other prompt teaches "Enter = keep going". Defaulting to
    # No made the final Enter throw away the whole session (config AND the autounattend
    # regeneration below). An explicit 'n' still aborts.
    if ((Test-Path -LiteralPath $ConfigPath)) {
        $ow = (Read-Host "config.ps1 exists at $ConfigPath — overwrite? [Y/n]").Trim()
        if ($ow -match '^[nN]') { throw "Aborted: config.ps1 left unchanged at $ConfigPath" }
    }
    $configText = ConvertTo-ConfigPs1Content -Values $cfg -PathBlock $pathBlock
    # UTF-8 WITH BOM so PowerShell 5.1 reads non-ASCII correctly when setup.ps1 dot-sources it.
    [System.IO.File]::WriteAllText($ConfigPath, $configText, (New-Object System.Text.UTF8Encoding($true)))
    & $ok ("config.ps1 generated at {0}" -f $ConfigPath)

    # Feed the bootstrap identity into the autounattend generation below (single source of truth).
    $AdminUser = [string]$cfg['AdminAccount']
    & $banner 'Bootstrap admin password'
    & $note 'Temporary password baked into autounattend.xml; setup.ps1 rotates it to $AdminNewPass on first login.'
    $bootPlain = & $askSecret 'Bootstrap admin password' ''
    # Build the SecureString via .NET rather than ConvertTo-SecureString: that cmdlet lives in
    # Microsoft.PowerShell.Security, whose on-demand module load can be blocked by an enforced WDAC
    # policy on a hardened operator/IT workstation ("the module could not be loaded"), which is a
    # realistic environment for the machine that builds the USB. SecureString is in mscorlib and is
    # always available; the plaintext is scrubbed right after the base64 is built below.
    $AdminPassword = New-Object System.Security.SecureString
    foreach ($ch in $bootPlain.ToCharArray()) { $AdminPassword.AppendChar($ch) }
    $AdminPassword.MakeReadOnly()
    $bootPlain = $null
    # The wizard is a deliberate re-burn of the USB, so overwrite autounattend.xml without a second prompt.
    $Force = $true
}

# --- Account name ---
if (-not $AdminUser) {
    $AdminUser = (Read-Host 'Bootstrap admin account name (e.g. setupadmin)').Trim()
}
if (-not $AdminUser) { throw 'Account name cannot be empty.' }
# Validate against Windows local-account rules BEFORE injecting into the XML (audit A1). Without
# this a name like 'TI & Suporte' or 'a<b' produces a malformed autounattend.xml that passes every
# build-side check and only fails at the target machine's Setup. The strict charset also means the
# value can never carry XML-special characters into the .Replace below.
if ($AdminUser -notmatch '^[A-Za-z0-9._-]{1,20}$') {
    throw "Invalid account name '$AdminUser': use 1-20 chars, letters/digits/dot/hyphen/underscore only (Windows local account rules)."
}

# --- Password (kept as SecureString; converted to plaintext only long enough to reject an
# empty value and build the base64, then scrubbed). The -AdminPassword parameter is a
# [securestring] so a plaintext password can never be passed on the command line. ---
if (-not $AdminPassword) {
    $AdminPassword = Read-Host 'Bootstrap admin account password' -AsSecureString
}
if ($AdminPassword.Length -eq 0) { throw 'Password cannot be empty.' }

# Windows expects the value as base64 of UTF-16LE of (password + "Password" suffix),
# for both LocalAccount and AutoLogon. Same value in both places.
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    # Empty was already rejected above; a short-but-non-empty password only warns (it is reused
    # fleet-wide, so length matters), it never blocks the build.
    if ($plain.Length -lt $RecommendedPasswordLength) {
        Write-Warning "Bootstrap admin password is only $($plain.Length) characters; $RecommendedPasswordLength+ recommended (it is reused fleet-wide). Using it anyway."
    }
    $pwB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($plain + 'Password'))
}
finally {
    # Scrub the plaintext from memory now that the base64 is built (defense-in-depth).
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $plain = $null
}

$xml = Get-Content -Path $TemplatePath -Raw -Encoding UTF8
$xml = $xml.Replace('__ADMIN_USER__', $AdminUser).Replace('__ADMIN_PW_B64__', $pwB64)

if ($xml -match '__ADMIN_USER__|__ADMIN_PW_B64__') {
    throw 'An unreplaced placeholder remains in the XML - aborting.'
}
# Defensive re-parse (audit A1): guarantee the generated answer file is still well-formed XML
# before it is written, so a bad substitution can never ship a file that only fails at boot.
try { [void][xml]$xml } catch { throw "Generated autounattend.xml is not well-formed XML: $($_.Exception.Message)" }

# Overwrite guard: autounattend.xml holds a (base64-encoded) bootstrap password. Refuse to
# silently clobber an existing one — re-running could burn a different/stale password without
# the operator noticing. Surface the existing file's age; require -Force to overwrite.
if ((Test-Path $OutPath) -and -not $Force) {
    $existing = Get-Item $OutPath
    throw ("Refusing to overwrite existing autounattend.xml at $OutPath " +
           "(last modified $($existing.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))). " +
           'Pass -Force to overwrite — this re-burns the bootstrap password.')
}

# UTF-8 without BOM (autounattend expects UTF-8).
[System.IO.File]::WriteAllText($OutPath, $xml, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "OK: autounattend.xml generated at $OutPath" -ForegroundColor Green
Write-Host "Bootstrap account: $AdminUser" -ForegroundColor Green
Write-Host ""
Write-Host "REMINDERS:" -ForegroundColor Yellow
Write-Host "  - In config.ps1, `$AdminAccount MUST be '$AdminUser'." -ForegroundColor Yellow
Write-Host "  - The generated autounattend.xml holds the password - NEVER commit it (already in .gitignore)." -ForegroundColor Yellow
Write-Host "  - This is the BOOTSTRAP password; setup.ps1 rotates it to the real one (`$AdminNewPass) on first login." -ForegroundColor Yellow

# ============================================================
# Asset check (only with -GenerateConfig): report which physical group-B files exist on the USB
# root next to config.ps1. Report only — never fails, since assets are added over time.
# ============================================================
if ($GenerateConfig) {
    $usbRoot = Split-Path -Parent $ConfigPath
    & $banner 'Asset check'
    & $note ("Scanning {0}" -f $usbRoot)

    # label -> test scriptblock returning $true when the asset is present.
    $checks = [ordered]@{
        'Default wallpaper'         = { $cfg['WallpaperFile'] -and (Test-Path -LiteralPath (Join-Path $usbRoot $cfg['WallpaperFile'])) }
        'Office ODT (setup.exe)'    = { (Test-Path (Join-Path $usbRoot 'Office\setup.exe')) -or (Test-Path (Join-Path $usbRoot 'OfficeSetup.exe')) }
        'Office configuration.xml'  = { Test-Path (Join-Path $usbRoot 'Office\configuration.xml') }
        'Belarc (belarc.exe)'       = { Test-Path (Join-Path $usbRoot 'belarc.exe') }
        'Epson driver (INF)'        = { (Test-Path (Join-Path $usbRoot 'Drivers Epson')) -and @(Get-ChildItem -LiteralPath (Join-Path $usbRoot 'Drivers Epson') -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count }
        'WebAgent .msi'             = { @(Get-ChildItem -Path (Join-Path $usbRoot 'WebAgent\windows') -Filter *.msi -ErrorAction SilentlyContinue).Count }
        'Signatures tree'           = { Test-Path (Join-Path $usbRoot 'signatures-2026') }
        'Cloud-agent toolkit'       = { Test-Path (Join-Path $usbRoot 'CloudAgent') }
        'VPN .msi'                  = { @(Get-ChildItem -Path (Join-Path $usbRoot 'VPN') -Filter *.msi -ErrorAction SilentlyContinue).Count }
        'VPN .ovpn profile'         = { @(Get-ChildItem -Path (Join-Path $usbRoot 'VPN') -Filter *.ovpn -ErrorAction SilentlyContinue).Count }
        'Ninite (ninite.exe)'       = { Test-Path (Join-Path $usbRoot 'ninite.exe') }
        'printers.json'             = { Test-Path (Join-Path $usbRoot 'printers.json') }
        # Optional: WinPE auto-loads storage drivers (e.g. Intel VMD/IRST) from \$WinPEDriver$\.
        # Only needed when the target BIOS uses RAID On/VMD; see README "Troubleshooting".
        'WinPE storage drivers ($WinPEDriver$, optional)' = { @(Get-ChildItem -Path (Join-Path $usbRoot '$WinPEDriver$') -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count }
    }
    # Per-domain wallpapers actually referenced in the map.
    foreach ($d in @($cfg['WallpaperByDomain'].Keys)) {
        $wpFile = [string]$cfg['WallpaperByDomain'][$d]
        $checks["Wallpaper for $d ($wpFile)"] = [scriptblock]::Create("Test-Path -LiteralPath (Join-Path `$usbRoot '$($wpFile.Replace("'","''"))')")
    }

    foreach ($label in $checks.Keys) {
        $present = $false
        try { $present = [bool](& $checks[$label]) } catch { $present = $false }
        if ($present) {
            Write-Host ("   [OK]      {0}" -f $label) -ForegroundColor Green
        } else {
            Write-Host ("   [MISSING] {0}" -f $label) -ForegroundColor Yellow
        }
    }
    & $note '(Missing items are only a warning - add them to the USB before deploying.)'
}
