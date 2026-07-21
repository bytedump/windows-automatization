# 🖥️ Windows 11 — Automated Provisioning

[![CI](https://github.com/bytedump/windows-automatization/actions/workflows/ci.yml/badge.svg)](https://github.com/bytedump/windows-automatization/actions/workflows/ci.yml)
![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?style=flat&logo=powershell&logoColor=white)
![Windows 11](https://img.shields.io/badge/Windows%2011-0078D6?style=flat&logo=windows&logoColor=white)
![autounattend.xml](https://img.shields.io/badge/autounattend.xml-1e2327?style=flat)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)

Hands-free provisioning of Windows 11 machines from a USB drive: an `autounattend.xml`
answer file installs Windows with zero clicks, then a post-install PowerShell script
(`setup.ps1`) configures the machine through a small GUI — user, network, printer, apps
and Outlook signature.

No secrets live in this repository. Credentials and real data stay on the USB drive
(`config.ps1`, the generated `autounattend.xml`, `printers.json`) — all gitignored. The
repo ships **templates**; you fill them in once when you build the master USB.

## 📑 Table of Contents

- [Overview](#-overview)
- [Preparing the master USB](#-preparing-the-master-usb)
- [USB drive layout](#-usb-drive-layout)
- [Security model](#-security-model)
- [1. autounattend.xml](#-1-autounattendxml)
- [2. setup.ps1](#-2-setupps1)
- [3. Full flow](#-3-full-flow)
- [4. How to test](#-4-how-to-test)
- [Troubleshooting](#-troubleshooting)
- [5. Repository files](#-5-repository-files)
- [Roadmap — intranet auto-provisioning](#-roadmap--intranet-auto-provisioning-planned)
- [License](#-license)

## 📋 Overview

- 100% hands-free installation (zero clicks until the desktop)
- Secrets kept **out of the repository** — templates in git, real values on the USB drive
- Post-install script with an interactive GUI: user, network, printer, apps, Outlook signature, optional VPN (OpenVPN), optional corp browser bookmarks
- Programs and signatures shipped on the USB drive — no network share needed for installation
- Installers run **in parallel** to cut wall-clock time

---

## ✅ Production validation & releases

`main` is the **integration** line — every change lands here and CI (lint + Pester on pwsh 7 **and**
Windows PowerShell 5.1 + gitleaks) must pass. But **CI cannot test the boot / power-loss /
answer-file / network behaviour**, so a green `main` is *not* proof the USB is safe to image a real
machine.

Before using the USB in production, cut a **validated release**:

1. **Run the VM validation** against the current `main`: Windows
   Sandbox (`tests/run-sandbox.bat`), a 2-disk VM (the disk guard must abort), a **no-TPM** VM (the
   LabConfig bypass must let Setup proceed), and a forced power-loss per phase (Phase A resume,
   `state.json`, cleanup teardown).
2. **Tag the commit that passed** — e.g. `git tag -a v1.0 -m "validated on VM <date>"` then
   `git push origin v1.0`.
3. **Build the USB from that tag**, not from bleeding `main`: `git checkout v1.0`, then run the
   wizard below.

Rule of thumb: any change to **boot, the answer file, the disk guard, cleanup, or the network** goes
to a **branch first**, is VM-validated, and only then merges to `main` — those are exactly the paths
CI cannot cover.

---

## 🛠️ Preparing the master USB

Done **once** per master USB. Each machine's boot is then hands-free — but note that Phase A
**deletes `autounattend.xml` from the USB** after rotating the bootstrap password (so the embedded
credential is never left behind on the drive). Re-run the wizard to regenerate `autounattend.xml`
before imaging the next machine.

### Burning the boot USB (Rufus)

The USB must first be a **bootable Windows 11 installer**. Burn the ISO with
[Rufus](https://rufus.ie) (GPT / UEFI), then copy the repo payload onto its root. Two
things matter:

> **Use an ISO whose language matches the answer file (pt-BR).** `autounattend.xml` requests
> `UILanguage = pt-BR`; an **English (en-US) ISO does not ship the pt-BR language pack** in
> `boot.wim`, so Setup cannot apply it and **stops on the language/keyboard screen** for a
> manual pick. Download the **Windows 11 Portuguese (Brazil)** multi-edition ISO from Microsoft.

> **Leave every box unchecked in Rufus's "Customize Windows installation experience" /
> "Windows User Experience" dialog.** Ticking any of them makes Rufus write its **own**
> `autounattend.xml` to the USB root, which sits higher in Setup's search order and
> **overrides ours**. Our `autounattend.xml` already handles the TPM/Secure Boot/RAM bypass
> (via `LabConfig`) and the local account, so no Rufus customization is needed.

Copy the repo payload **after** Rufus finishes (the steps below write to the USB root).

1. **Copy the repo files** to the USB root (or a staging folder you copy to the USB).
2. **Run the wizard** — it generates BOTH `config.ps1` and `autounattend.xml` from your
   answers (no hand-editing), then reports which USB assets are still missing. The bootstrap
   admin name you type is written into both files, so `$AdminAccount` can never drift:
   ```powershell
   .\build-usb.ps1 -GenerateConfig -OutPath E:\autounattend.xml   # E: = the USB root
   # prompts for every value; passwords are hidden and never echoed
   ```
   Double-clicking `build-usb.ps1` flashes a window and closes (Windows opens `.ps1` in
   Notepad or runs it and exits before you can read it). Instead **double-click `build.bat`**
   — it runs the script with the execution policy bypassed and stays open. Both files land
   next to it (run it from the USB root and they land there). Re-running loads the existing
   `config.ps1` as defaults (Enter keeps each value; secrets show `****`). Pass `-Advanced` to
   also override the `$Path*` locations. The wizard **auto-detects wallpaper images** at the USB
   root and offers them as a numbered pick-list (a lone image is pre-selected), so filenames are
   not typed by hand — apps, drivers, and signature templates are likewise found by folder scan,
   just drop them in.

   > **Legacy / autounattend-only:** without `-GenerateConfig` the script keeps its old
   > behaviour — it prompts only for the bootstrap admin name + password and writes
   > `autounattend.xml`. You then create `config.ps1` by hand from `config.example.ps1`
   > (`$AdminAccount` **must** match the name you typed).
3. **Create `printers.json`** from `printers.example.json` with your real printers.
4. **Add the binaries / assets** the installers expect (see [USB layout](#-usb-drive-layout)):
   `ninite.exe`, the `Office/` ODT folder (see [Office (ODT)](#office-odt)), `belarc.exe`,
   `Drivers Epson/` (the extracted INF driver), `WebAgent/`, the wallpaper, the `signatures-2026/`
   signature templates, and (optional) the `CloudAgent/` vendor toolkit and the `VPN/` folder
   (OpenVPN `.msi` + the `.ovpn` profile) for the VPN option. The wizard's asset check (step 2)
   lists what is still missing.
5. Plug the USB into the target machine and boot from it — the rest is automatic.

> The bootstrap password you set in step 2 is temporary: `setup.ps1` replaces it on first
> login with `$AdminNewPass` from `config.ps1`. Keep it different from any real password.

---

## 💾 USB drive layout

```
USB Root/
  ├── autounattend.xml          ← GENERATED by build-usb.ps1 (gitignored — has the bootstrap password)
  ├── setup.ps1                 ← Post-installation script (GUI) — Phase A
  ├── phase-b.ps1               ← Phase B (new user session): bookmarks, desktop shortcuts, wallpaper, signature, default printer, VPN profile
  ├── cleanup.ps1               ← Cleanup (SYSTEM): zero AutoLogon, unregister tasks, delete staging
  ├── run.bat                   ← Manual fallback to re-run setup.ps1
  ├── build.bat                 ← Double-click launcher for build-usb.ps1 (ExecutionPolicy Bypass)
  ├── guard-disk.cmd            ← fail-closed disk guard (proceeds only if exactly 1 disk), run from autounattend in WinPE
  ├── config.ps1                ← Credentials and paths (copy from config.example.ps1 — gitignored)
  ├── printers.json             ← Printer list (copy from printers.example.json — gitignored)
  ├── belarc.exe                ← Belarc Advisor installer
  ├── Office/                   ← Office Deployment Tool (ODT) — see "Office (ODT)" below
  │     ├── setup.exe           ←   ODT bootstrapper (download at aka.ms/ODT)
  │     ├── configuration.xml   ←   copy from configuration.example.xml (gitignored)
  │     └── Office/Data/        ←   pre-downloaded bits (setup.exe /download — offline mode)
  ├── ninite.exe                ← Download at ninite.com (not committed)
  ├── wallpaper.jpg             ← Wallpaper (filename set in config.ps1 via $WallpaperFile)
  ├── Drivers Epson/            ← Extracted Epson INF driver (registered silently via pnputil — no vendor .exe)
  ├── WebAgent/windows/         ← WebAgent .msi installer
  ├── CloudAgent/               ← Vendor cloud-agent toolkit (optional): installer bat + its exes
  ├── VPN/                      ← OpenVPN (optional): the .msi installer + the .ovpn profile (gitignored)
  └── signatures-2026/          ← Outlook signature templates (gitignored)
        └── {domain}/
              └── {Sector}/
                    └── user.htm
```

---

## 🔒 Security model

No secret is committed. The repository holds templates; the real values are created on
the USB drive at build time and are all gitignored.

| Item | Where it lives |
|---|---|
| Bootstrap admin password | Only in the **generated** `autounattend.xml` (gitignored), created by `build-usb.ps1`. Replaced on first login by `setup.ps1`, which then **deletes** `autounattend.xml` from the USB and the `Panther\unattend.xml` copy. |
| Phase B handoff AutoLogon | `setup.ps1` writes the new user's password to `HKLM\…\Winlogon` in **plaintext for one boot** to autologon into Phase B. `AutoLogonCount=1` makes Windows consume + clear it even if cleanup never runs; `cleanup.ps1` (SYSTEM) zeroes **and verifies** it at the end of Phase B. `state.json` never holds a credential. |
| Real admin / user passwords | Only in `config.ps1` (gitignored) — `$AdminNewPass`, `$UserInitialPass`. ⚠️ `$AdminNewPass` is typically **reused fleet-wide** (the same local-admin password on every provisioned machine): a leak on one machine affects all of them, and rotating it means updating `config.ps1` and re-running setup everywhere. |
| WiFi credentials | Only in `config.ps1` (gitignored) |
| Printer IPs / sectors | Only in `printers.json` (gitignored) — internal network data |
| Outlook signatures | Only in `signatures-2026/` (gitignored) — employee personal data |
| VPN profile | Only in `VPN/` (gitignored) — the `.ovpn` embeds a client cert + private key. Phase B imports it into the user's `%USERPROFILE%\OpenVPN\config\` (readable only by that user); it uses `auth-user-pass`, so each user still authenticates manually |
| WiFi profile | SSID and password XML-escaped via `SecurityElement.Escape`; the temp profile XML (plaintext PSK) is **deleted** right after `netsh` imports it |
| Setup log | Credentials never written to `win11_setup_log.txt` |

> **Physical security of the USB.** Until `setup.ps1` finishes its first run, the USB carries
> live credentials in cleartext: the real passwords in `config.ps1` and the bootstrap password
> in `autounattend.xml`. The bootstrap password is **base64-encoded, not encrypted** — base64 is
> trivially reversible, so anyone holding the USB can decode it. Treat the prepared USB as a secret:
> keep it in locked storage, never leave it in public machines, and store it on an **encrypted
> volume — use BitLocker To Go** (*This PC → right-click the USB → Turn on BitLocker*) or an
> equivalent such as VeraCrypt. `setup.ps1` scrubs `autounattend.xml` after rotating the password,
> but `config.ps1` stays on the USB by design (so the operator can re-run setup).

### Why a bootstrap password at all

`autounattend.xml` cannot read external files — it is static XML processed by Windows
Setup (WinPE). The admin account must be created with a known password so AutoLogon can
fire and launch `setup.ps1`. That password is **bootstrap only**: `setup.ps1` rotates it
to `$AdminNewPass` from `config.ps1` on first login (and raises a blocking alert if the
rotation fails, so a machine is never silently left on the bootstrap password).

`build-usb.ps1` encodes it the way Windows expects — base64 of UTF-16 of
`password + "Password"` — into the LocalAccount and AutoLogon `<Value>` fields.

### Two-phase handoff (Phase A → reboot → Phase B + cleanup)

Provisioning splits into two phases so the per-user work runs in the **new user's own session**
(no impersonation) while machine setup keeps admin rights:

- **Phase A** — `setup.ps1`, elevated, as the bootstrap admin. Does all machine work (OEM license,
  rotate the bootstrap password, create the standard user, network, installs, machine-wide printer,
  stage the wallpaper). At the end it stages the handoff into `C:\ProgramData\CorpSetup`
  (`state.json` + copies of `phase-b.ps1`/`cleanup.ps1` + the signature subtree), registers two
  scheduled tasks (`CorpSetup-PhaseB-User`, `CorpSetup-PhaseB-System`), **arms a one-shot AutoLogon
  for the new user** and **reboots**.
- **Phase B** — `phase-b.ps1`, as the **new standard user** after the reboot+AutoLogon. Per-user
  only: wallpaper (HKCU), Outlook signature in `%APPDATA%` set as default New+Reply, default
  printer. Drops a `user-done` flag.
- **Cleanup** — `cleanup.ps1`, as **SYSTEM**. Waits for `user-done`, then **zeroes + verifies** the
  plaintext AutoLogon in `HKLM\…\Winlogon`, unregisters both tasks, and deletes the staging folder.
  It does **not** disable the bootstrap admin (no AD ⇒ it is the only local admin, kept for support).

`state.json` carries **no credential**. The only secret in flight is the one-boot plaintext AutoLogon
password (declared trade-off — Winlogon AutoLogon has no DPAPI option), self-clearing via
`AutoLogonCount=1` and zeroed by cleanup. The flow is gated by `-EnableHandoff` (passed from
`autounattend.xml`); the test harness never passes it, so the sandbox never reboots.

---

## 🧩 1. autounattend.xml

### What it does
Windows Setup answer file (generated from `autounattend.template.xml`). Boot from the USB
drive — installation runs without any interaction up to the desktop, then `setup.ps1`
opens automatically via `FirstLogonCommands`.

> **Single-disk assumption.** `DiskConfiguration` wipes `DiskID=0` with `WillWipeDisk=true`.
> Disk 0 is not deterministic across firmware, so wiping it is only safe on machines with a
> **single** fixed disk. The `guard-disk.cmd` wiring (below) is the fail-closed safeguard — it
> aborts the install unless it confirms exactly one disk.

### Settings

| Parameter | Value |
|---|---|
| Edition | Windows 11 Pro |
| Language / UI | pt-BR |
| Keyboard | ABNT2 (`0416:00010416`) |
| Time zone | E. South America Standard Time (Brasília) |
| Local admin account | `$AdminAccount` (bootstrap password — replaced by `setup.ps1`) |
| AutoLogon | Bootstrap admin, one-shot for Phase A (`LogonCount=1`); Phase A then arms a separate one-shot for the new user → Phase B |
| Auto-launch | `FirstLogonCommands` finds the USB (drive with `setup.ps1` **and** `config.ps1`), retries ~60s, opens `setup.ps1` (GUI) with `-EnableHandoff` (two-phase flow) |

> **Region/locale is hardcoded to pt-BR** (language, ABNT2 keyboard, Brasília time zone). The
> tool targets Brazilian deployments; using it elsewhere installs a pt-BR system. To retarget,
> change `InputLocale`/`SystemLocale`/`UILanguage`/`UserLocale` (all three passes) and `TimeZone`
> in `autounattend.template.xml`.

### Skipped screens (OOBE)

| Screen | Mechanism |
|---|---|
| Language / Region / Keyboard | `SetupUILanguage`, `InputLocale` — **only with a matching-language ISO (pt-BR)**; on 24H2/25H2 the new "ConX" setup may still show them. See [Troubleshooting](#-troubleshooting). |
| Product key | Generic Pro key `VK7JG-NPHTM-C97JM-9MPGT-3V66T` (selects edition, does not activate) |
| EULA | `<AcceptEula>true</AcceptEula>` |
| Disk / partition | `DiskConfiguration` with `WillWipeDisk=true` |
| Wi-Fi OOBE | `HideWirelessSetupInOOBE=true` |
| Microsoft account | `HideOnlineAccountScreens=true` |
| Local account OOBE | `HideLocalAccountScreen=true` + `UserAccounts` |
| Privacy | `ProtectYourPC=3` |
| Personalization | `SkipUserOOBE=true` |
| Network | `BypassNRO=1` (valid up to ~24H2; redundant here since the full OOBE is already skipped) |

### Partition scheme (GPT/UEFI)

| # | Type | Size | Format | Label |
|---|---|---|---|---|
| 1 | EFI | 300 MB | FAT32 | System |
| 2 | MSR | 16 MB | — | — |
| 3 | Primary | Remaining | NTFS | Windows (C:) |
| WinRE | Recovery | ~500 MB | NTFS | Created automatically **after** partition 3 |

> Recovery must come **after** the Windows partition — placing it before causes Setup to fail at ~50-60%.

### Compatibility — PCs without TPM 2.0

Automatic bypass via `LabConfig` keys in the `windowsPE` pass. Only these three exist;
`BypassCPUCheck` / `BypassStorageCheck` are no-ops.

| Key | Function |
|---|---|
| `BypassTPMCheck` | Skips TPM 2.0 requirement |
| `BypassSecureBootCheck` | Skips Secure Boot |
| `BypassRAMCheck` | Skips RAM check |

### Disk guard (fail-closed: exactly 1 disk)

`guard-disk.cmd` counts **fixed** disks in WinPE and is **fail-closed**: it lets the install
proceed **only** when it confirms *exactly one* fixed disk. On any other outcome — `0` disks
parsed, more than one disk, or a tooling error — it runs `wpeutil shutdown` **before** anything
is wiped. Counting only `MediaType='Fixed hard disk media'` excludes the boot USB itself (a
*removable* disk) and optical media, so the "exactly 1" check is never tripped by the install
medium.

WMIC is the primary counter (locale-independent, and it carries the fixed-media filter). The
Win11 25H2 Setup boot image ships WMIC but **not** `findstr` and **not** PowerShell — an earlier
`findstr`-based version counted `0` on every machine and aborted every install (caught in VM
testing). If WMIC is ever absent, the fallback counts disks via `diskpart` + `find`, covering
EN/pt/es/it/fr/de WinPE languages.

It is wired into `autounattend.xml` as two `RunSynchronous` commands in the
`Microsoft-Windows-Setup` component, **before** `DiskConfiguration`:

1. **Order 1** — the WinPE drive letter is not fixed, so it scans drives for `guard-disk.cmd`
   and calls it. On the "exactly 1" success path the script writes a marker
   (`%TEMP%\guard_ok.flag`).
2. **Order 2** — `if not exist %TEMP%\guard_ok.flag wpeutil shutdown`. This catches the case
   where `guard-disk.cmd` is **missing from the media** (so Order 1 never ran): no marker → the
   install still fails closed instead of wiping blind.

> ⚠️ The ordering of `RunSynchronous` versus the disk wipe is **not contractually
> guaranteed** by Microsoft (medium confidence). **Test in a VM with two disks before
> relying on it.** To disable the guard, delete both `RunSynchronousCommand` blocks. The
> fully-guaranteed alternative is to move partitioning into a `diskpart` script called from
> `RunSynchronous`.

---

## ⚙️ 2. setup.ps1

### What it does
PowerShell + Windows Forms GUI in a **single window**: the input form on top and a live
progress section at the bottom (status + progress bar + colored streaming log) that shows
each task — rename, user, network, installers, signature — as it runs, with a **Close**
button when finished. Auto-launched by `autounattend.xml` on first login; `run.bat` is the
manual fallback. Supports `-Unattended` (with `-Test*` parameters) for headless testing —
used by the Sandbox harness (no window).

### Error handling
- **Input is validated and normalized before any action.** The form sanitizes as you type
  (full name accepts letters/spaces/hyphen/apostrophe only; the username is auto-derived from
  First + Last as lowercase `name.surname` with accents stripped, and stays editable for overrides;
  the static IP field masks to four `0-255` octets,
  with Enter to jump between octets) and **blocks submit** with one consolidated, plain-language
  message + per-field markers if anything is still invalid. The same validators re-run at the single point where
  the GUI and headless `-Test*` paths converge, so automation can't drive the script into a
  broken state (a malformed `-TestUsername` aborts `FATAL` before any account is created).
- Every phase is wrapped in `try/catch`; failures are logged `ERROR`/`FATAL` and counted.
- Installer exit codes are checked (non-zero is `ERROR`, not silently `OK`; `3010` = reboot-required counts as success).
- The script **exits non-zero** when any error was tracked, so callers (`run.bat`, `FirstLogonCommands`) detect failure.
- The unhandled-error `trap` aborts (`exit 1`) instead of continuing over inconsistent state.
- Missing optional config never crashes under StrictMode — it is defaulted or validated with a clear message.
- Re-running is idempotent: an existing user / already-applied PC name is detected, not re-created.

### Prerequisite
`config.ps1` must be in the root of the same USB drive as `setup.ps1`. The easiest way to
create it is the wizard — `build-usb.ps1 -GenerateConfig` (see **Preparing the master USB**
above) — which writes a valid `config.ps1` from your answers. Otherwise copy `config.example.ps1`
by hand and fill in real values; the variables it must define are below.

### config.ps1 — required variables

```powershell
# Admin account
$AdminAccount    = "setupadmin"                 # bootstrap account name — MUST match build-usb.ps1
$AdminNewPass    = "REAL_ADMIN_PASSWORD"        # replaces the bootstrap password; never commit
$UserInitialPass = "USER_INITIAL_PASSWORD"      # new user initial password

# Email domains (GUI dropdown)
$EmailDomains = @('example.com.br', 'example.org.br')

# WiFi (always DHCP — provides internet during provisioning)
$WifiSSID    = "NETWORK_NAME"
$WifiPass    = "WIFI_PASSWORD"

# Static IP for the Ethernet adapter (only when the technician picks "Static IP")
$StaticGateway      = "GATEWAY_IP"
$StaticPrefixLength = 24
$DnsServers         = @('8.8.8.8', '8.8.4.4')

# Wallpaper (USB drive root). $WallpaperFile is the default; $WallpaperByDomain overrides it per
# selected email domain (unlisted domains fall back to the default).
$WallpaperFile     = 'wallpaper.jpg'
$WallpaperByDomain = @{ }   # e.g. @{ 'branch-b.example.com' = 'wallpaper-alt.jpg' }

# Paths — all on the USB drive ($ScriptDir = USB root)
$PathOffice     = "$ScriptDir\Office"           # ODT; falls back to OfficeSetup.exe if absent
$PathBelarc     = $ScriptDir
$PathEpson      = "$ScriptDir\Drivers Epson"    # extracted Epson INF driver (silent pnputil install)
$PathWebAgent   = "$ScriptDir\WebAgent\windows"
$PathSignatures = "$ScriptDir\signatures-2026"  # structure: \{domain}\{sector}\user.htm
$PathVPN        = "$ScriptDir\VPN"              # OpenVPN: .msi + .ovpn; omit/empty to disable the VPN option

# Cloud agent (optional vendor toolkit; empty $PathCloudAgent = skip the step)
$PathCloudAgent       = "$ScriptDir\CloudAgent" # toolkit folder on the USB (exes + installer bat)
$CloudAgentInstaller  = 'install.bat'           # installer bat name inside that folder
$CloudAgentInstallDir = 'C:\CloudAgent'         # local retention copy target on the machine

# Corp browser bookmarks (Chrome/Edge/Firefox) — one GUI checkbox per entry (Name = its label);
# each ticked link lands LOOSE on the bookmarks bar. Keep internal IPs here on the USB only (public repo).
$Bookmarks = @(
    @{ Name = 'Intranet'; Url = 'https://intranet.example.com/' },
    @{ Name = 'WebApp';   Url = 'https://10.0.0.1:1234/webapp/' }
)

# Bookmarks (by Name) that also get a desktop .url shortcut in Phase B; @() for none.
$DesktopShortcutBookmarks = @()   # e.g. @('WebApp')
```

### Execution phases

```
Pre-GUI — Kick off Ninite in the background (longest installer; downloads over WiFi
          while the technician fills the form). WiFi is up since Phase 2.
    ↓
Phase 1 — Load config.ps1; apply OEM license (slmgr); rotate the bootstrap admin password
    ↓
Phase 2 — WiFi (WPA3-SAE transition-mode profile when the driver supports it, else WPA2-PSK;
          waits for WlanSvc/adapter, verifies association via CIM, retries once in Phase 7),
          load printers.json
    ↓
Phase 3 — GUI (single window): the input form (first + last name -> auto username, email domain,
          network DHCP/Static IP, printer, sector, signature .htm, WebAgent) on top, plus a live
          progress section at the bottom that streams every task below as it runs
    ↓
Phase 4 — Rename PC to BIOS SerialNumber; create local user; configure Ethernet; stage the
          wallpaper for the selected email domain to %WINDIR% (applied per-user in Phase B)
    ↓
Phase 5 — Launch the rest of the installers in parallel (Office + Belarc, background, no -Wait)
    ↓
Phase 7 — Join all installers (wait + check exit codes) → add printer (silent Epson driver via pnputil + RAW TCP/IP port) →
          WebAgent (MSI, after the pool to respect the Windows Installer mutex) → OpenVPN
          (install the .msi if the VPN box was ticked) → corp bookmarks (Firefox
          distribution\policies.json for the ticked links; Chrome/Edge seeded per-user in Phase B) → cloud agent
          (copy the vendor toolkit locally + run its installer bat hands-free) →
          checklist on screen + full log on the Desktop
    ↓
Phase 8 — Handoff (only with -EnableHandoff): stage C:\ProgramData\CorpSetup (state.json +
          phase-b.ps1/cleanup.ps1 + the signature subtree + the VPN profile if selected), register the two scheduled tasks, arm
          the new-user one-shot AutoLogon → reboot into Phase B
    ↓
Phase B — (new user session, after reboot) corp bookmarks seeded loose on the bar (Chrome/Edge
          profile Bookmarks file), desktop .url shortcuts for the configured bookmarks
          ($DesktopShortcutBookmarks), wallpaper (HKCU), Outlook signature in %APPDATA% set as
          default New+Reply, default printer, VPN profile imported into %USERPROFILE%\OpenVPN\config
          (OpenVPN GUI opened) → drop the user-done flag
    ↓
Cleanup — (SYSTEM) wait for user-done → zero + verify the AutoLogon in HKLM → unregister both tasks
          → delete the staging folder
```

(The Phase 6 signature step moved to Phase B; the numbering gap mirrors `setup.ps1`.)

The Windows Installer global mutex (`_MSIExecute`) means two `msiexec` jobs can't run at
once: Ninite (uses msiexec internally) and WebAgent (MSI) never overlap, while Office
(Click-to-Run, a separate engine) and Belarc run truly in parallel.

### User creation

| Account | Type | Purpose |
|---|---|---|
| `$AdminAccount` (e.g. `setupadmin`) | Administrator | Technical setup account |
| New (username) | Standard User | Day-to-day account |

- The display name is entered as separate **First** and **Last** name fields (Tab between them),
  concatenated and Title-Cased into the read-only "Full name" — used as the account display name
  and in the signature.
- The username is **auto-derived** from those fields as lowercase `firstname.surname` (accents
  stripped, letters + a single dot; `João Silva` → `joao.silva`) so the technician doesn't type
  it. It stays editable for overrides (e.g. duplicate names) and is the Windows login **and** the
  email prefix; the same `name.surname` shape is enforced at submit.
- Initial password: `$UserInitialPass`; never expires; never written to the log.

### Network configuration

WiFi is always DHCP (initial internet). The DHCP/Static choice in the GUI applies to the
**Ethernet** adapter only.

**Static IP** — the technician types only the address; the field auto-inserts dots and
clamps each octet to `0-255` as they type, and submit is blocked unless it is a valid IPv4.
Prefix length (`$StaticPrefixLength`), gateway (`$StaticGateway`) and DNS (`$DnsServers`)
come from `config.ps1`.

### Program installation

| Program | Source | Method |
|---|---|---|
| Ninite | USB root (`ninite.exe`) | Background (started pre-GUI) |
| Microsoft Office | `$PathOffice\setup.exe` + `configuration.xml` (ODT); falls back to USB `OfficeSetup.exe` | ODT `/configure`, background |
| Belarc Advisor | USB root (`belarc.exe`) | `/S` silent, background |
| Network printer | `printers.json` (name/model/ip) + `Drivers Epson\*.inf` | **Silent** install: `pnputil /add-driver` registers the extracted INF (no vendor GUI, unlike the old `.exe /S`), then `Add-Printer` creates the queue under the corp name over a RAW 9100 TCP/IP port |
| WebAgent | `WebAgent\windows\` — `.msi` → `.zip` → `.exe` | `msiexec /quiet` or `/S`, after the pool |
| Cloud agent (optional) | `$PathCloudAgent` (`CloudAgent\`) | Copy the folder to `$CloudAgentInstallDir`, then run the vendor `$CloudAgentInstaller` bat hands-free (empty stdin, hidden); the installer creates its logon task + the Defender exclusions it requires; DB registration is best-effort (corporate network only) |
| OpenVPN (optional) | `$PathVPN\*.msi` (VPN box ticked) | `msiexec /quiet` in Phase A; the `.ovpn` profile is imported **per-user** in Phase B (`%USERPROFILE%\OpenVPN\config`) and the OpenVPN GUI is opened. Profile uses `auth-user-pass` → user connects manually |
| Corp bookmarks (optional) | `$Bookmarks` from `config.ps1` (one checkbox per link) | **Loose on the bookmarks bar** (not in a folder). Firefox: `<install>\distribution\policies.json` (`Placement:'toolbar'`) written machine-wide in Phase A, only if installed. Chrome/Edge: the new user's profile `Bookmarks` file seeded in Phase B (`roots.bookmark_bar`), skipped if the file already exists so real bookmarks are never clobbered. For each ticked link listed in `$DesktopShortcutBookmarks`, Phase B also drops a `<Name>.url` shortcut on the user's desktop (mirrors the manual Chrome "Create shortcut" step; `http://` prefixed when the config stores a bare host; never overwrites an existing shortcut) |

#### Office (ODT)

Office installs via the **Office Deployment Tool**. Two files go in `<USB>\Office\`:
`setup.exe` (the ODT bootstrapper — download at <https://aka.ms/ODT>) and `configuration.xml`
(copy from [`configuration.example.xml`](configuration.example.xml) and pick your product/apps).

`setup.ps1` runs `setup.exe /configure configuration.xml` with the working dir set to the
Office folder. `configuration.xml` is **mandatory** — ODT with no action verb installs nothing
(silent no-op); the script logs an ERROR and skips Office if it is missing.

**Offline (recommended)** — pre-download the Office bits onto the USB once, so every machine
installs from the USB with no internet during setup:

```powershell
cd <USB>\Office
.\setup.exe /download configuration.xml   # fills <USB>\Office\Office\Data\... (a few GB)
```

No `SourcePath` is set in the XML, so ODT finds that local `Office\Data` next to `setup.exe`
automatically — keeping it portable across USB drive letters.

**Online** — skip the `/download`; each machine pulls ~2–4 GB from the Microsoft CDN at
install time (internet required).

### Licensing (OEM — Dell)
Reads `OA3xOriginalProductKey` from UEFI firmware (`Get-CimInstance SoftwareLicensingService`),
then `slmgr /ipk` + `/ato`. Logs WARN if no firmware key.

### Computer rename
Reads `Win32_BIOS.SerialNumber`, validates (skips empty / "To Be Filled" / "O.E.M." /
"Default string"), strips invalid chars, truncates to 15 (NetBIOS), `Rename-Computer -Force`
(effective after reboot).

### Outlook signature
Runs in **Phase B** (the new user's own session). `phase-b.ps1` loads a `.htm` from the staged
`Signatures/{domain}/{sector}/`, replaces the old name (bold `<span>`) and email (regex) with the
values from `state.json`, copies the `<template>_files` logo folder alongside and re-points its
`src=`, saves to the user's `%APPDATA%\Microsoft\Signatures\{username}.htm`, and registers it as the
**default New + Reply** signature (HKCU Office MailSettings) — no longer a manual step.

---

## 🔁 3. Full flow

```
1.  Plug the USB drive into the machine
2.  Power on → boot from USB
3.  [AUTO] guard-disk: proceed only if exactly 1 disk (else abort); disk wiped + formatted (EFI + MSR + Windows)
4.  [AUTO] Windows 11 Pro installed → reboot
5.  [AUTO] Locale configured, entire OOBE skipped
6.  [AUTO] AutoLogon as the bootstrap admin (one time)
7.  [AUTO] setup.ps1 opens automatically (FirstLogonCommands) — run.bat is the manual fallback
8.  [AUTO] OEM license applied + bootstrap admin password rotated
9.  [INTERACTIVE] GUI (single window) — technician fills name/domain/network/printer/sector (username auto-derived from the name); the bottom section then streams steps 10-12 live
10. [AUTO] PC renamed, user created, network configured; wallpaper staged to %WINDIR%
11. [AUTO] Ninite + Office + Belarc installed in parallel; Epson driver registered silently (pnputil) + network printer added; WebAgent + OpenVPN + cloud agent after
12. [AUTO] Checklist shown + saved to Desktop; Phase B staged (state.json + 2 tasks + new-user AutoLogon armed)
13. [AUTO] Technician closes the progress window → reboot into Phase B
14. [AUTO] New user autologons → Phase B seeds corp bookmarks loose on the bar (Chrome/Edge) + desktop shortcuts for the configured bookmarks + applies wallpaper (HKCU) + Outlook signature (default New+Reply) + default printer + VPN profile (if selected; OpenVPN GUI opened)
15. ✅ Cleanup (SYSTEM) zeroes + verifies the AutoLogon, removes the two tasks and the staging — machine ready, hand credentials to the user
```

---

## 🧪 4. How to test

Testing happens at two levels. **CI** runs automatically on every push/PR and checks the
things that can be verified without a real machine; the **end-to-end** paths (Sandbox, VM,
hardware) stay manual because they actually install Windows / mutate the system.

### Continuous integration (automated, on every push/PR)

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on GitHub Actions:

| Check | Tool | What it guards |
|---|---|---|
| Lint | PSScriptAnalyzer ([`PSScriptAnalyzerSettings.psd1`](PSScriptAnalyzerSettings.psd1)) | PowerShell bugs / style |
| Unit tests | Pester 5 ([`tests/unit/`](tests/unit)) | the pure validators in `setup.ps1` (IP, username, name normalization) |
| Secret scan | gitleaks ([`.gitleaks.toml`](.gitleaks.toml)) | no real credential ever lands in the repo |
| XML | `[xml]` parse | `autounattend.template.xml` / `configuration.example.xml` are well-formed |

The unit tests dot-source `setup.ps1` with `-LoadOnly`, which defines the validator functions
and returns before the provisioning body — so they run on any machine and touch nothing.

```powershell
# run the unit tests locally (needs Pester 5):
Invoke-Pester -Path .\tests\unit -Output Detailed
```

> CI does **not** install Windows or create users — that needs the manual e2e paths below.

### setup.ps1 — Windows Sandbox (isolated, recommended)

Runs `setup.ps1` in a throwaway VM that resets on close. No risk to the host.

**Prerequisites:** Windows 10/11 Pro/Enterprise with Windows Sandbox enabled
(Control Panel → Programs → Windows Features → Windows Sandbox).

**Steps:**
1. Launch the prep (path-agnostic — works wherever the repo lives, WSL share or a
   normal Windows folder). Either **double-click `tests\run-sandbox.bat`** (it
   self-elevates with a UAC prompt), or from an **Administrator** PowerShell in the
   repo's `tests/` folder run:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\prep.ps1
   ```
   Admin is needed because `prep.ps1` creates `C:\SandboxTest` at the root of `C:`.
2. `prep.ps1` stages the scripts, injects fake credentials (`test-config.ps1`), opens the Sandbox.
3. `bootstrap.ps1` runs automatically on login: pre-creates the admin account, then runs
   `setup.ps1` **interactively** — the production-like single-window GUI. Fill the form with
   the test fixtures (domain `example.com.br`, sector `IT`, printer `Test Printer`) and click
   Start; the bottom section streams every task live.
4. Read the verdict: **`RESULT: PASSED`** (exit 0, zero `ERROR`/`FATAL`) or **`FAILED`**.
   Full log on the Sandbox Desktop.
5. Close the Sandbox → everything is discarded.

**Expected WARNs (not failures):** WiFi (no adapter),
Office/Ninite/Belarc (binaries absent), the printer (no printer reachable in a VM), OEM activation (no firmware key in a VM) —
logged WARN, not `ERROR`.

**Headless assertion:** for an automated, no-GUI run (CI-style), use
`bootstrap.ps1 -Headless` — it runs `setup.ps1 -Unattended` with test data and prints the
verdict without any interaction.

**Test fixtures:**
| File | Purpose |
|---|---|
| `tests/run-sandbox.bat` | One-click launcher — self-elevating, path-agnostic; runs `prep.ps1` |
| `tests/prep.ps1` | Staging + WSB generator — run on Windows before Sandbox |
| `tests/bootstrap.ps1` | Runs automatically inside Sandbox at login |
| `tests/test-config.ps1` | Fake credentials replacing `config.ps1` |
| `tests/usb-sim/` | Minimal printer list + signature template |

### autounattend.xml (VM)
Generate the file first (`build-usb.ps1`), then:
- **Hyper-V:** Generation 2 (UEFI) VM, Windows 11 ISO as DVD, USB with `autounattend.xml` as a second disk.
- **VirtualBox:** new VM with the ISO, `autounattend.xml` on a virtual floppy (`.img`/`.vfd`).
- **Disk guard:** add a second virtual disk to confirm the install aborts (the guard proceeds only with exactly 1 disk).

---

## 🩺 Troubleshooting

### Windows 11 24H2/25H2 — initial language/keyboard screens

**Symptom:** Setup stops on the language/region and keyboard screens (two manual "Next"
clicks) before the install becomes automatic. *(The disk-guard `cmd` console that flashes
in WinPE is **expected** — a `RunSynchronous` command shows a console — not the problem.)*

**Cause:** two independent triggers produce the same symptom:

1. **ISO language ≠ pt-BR** — an en-US ISO has no pt-BR pack in `boot.wim`, so
   `SetupUILanguage` cannot apply. **Fix:** burn a **pt-BR ISO** (see
   [Burning the boot USB](#burning-the-boot-usb-rufus)). This is the usual cause.
2. **24H2/25H2 "ConX" setup** — since 24H2, WinPE launches the new `SetupPrep.exe`
   front-end, which can ignore the `windowsPE` locale settings **even on a matching ISO**.

**Fix for the ConX case — force the legacy setup.** Edit the media's `boot.wim` (index 2 =
"Windows Setup") so WinPE launches the old `setup.exe`, which honours the whole `windowsPE`
pass. Run `force-legacy-setup.ps1` from an **Administrator** PowerShell on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\force-legacy-setup.ps1 -UsbDrive E   # E: = the USB
```

Or by hand (the script just wraps these):

```powershell
DISM /Mount-Wim /WimFile:E:\sources\boot.wim /Index:2 /MountDir:C:\mnt
reg load HKLM\OFFSYS C:\mnt\Windows\System32\config\SYSTEM
reg add HKLM\OFFSYS\Setup /v CmdLine /t REG_SZ /d "X:\sources\setup.exe" /f
reg unload HKLM\OFFSYS
DISM /Unmount-Wim /MountDir:C:\mnt /Commit
```

> ⚠️ Community-reported, **medium confidence — test in a VM first** (same caution as the
> disk guard). `boot.wim` is < 4 GB so it fits the FAT32 USB; the script clears its
> read-only attribute automatically if Rufus set one.

### Setup freezes at "searching for disks" (Intel VMD / RAID On)

**Symptom:** the installer hangs indefinitely (15+ min) on the "searching for disks"
loading screen — no disk-selection UI, no error, no shutdown. *(A shutdown instead of a
hang would be `guard-disk.cmd` failing closed — a different problem.)*

**Cause:** the machine's BIOS storage mode is **RAID On / Intel VMD** (the factory
default on recent Dell machines). WinPE ships no Intel VMD driver, so it cannot
enumerate the NVMe disk — disk discovery spins forever and `DiskConfiguration` never
gets a Disk 0 to act on.

**Fix (pick one):**

1. **Switch the BIOS to AHCI/NVMe** (recommended for fresh provisioning): BIOS →
   *Storage* → *SATA/NVMe Operation* → **AHCI/NVMe**. Safe here because the install
   wipes the disk anyway — the mode switch only breaks an *existing* Windows install,
   which is being replaced.
2. **Keep VMD and stage the driver:** create a folder named **`$WinPEDriver$`** on the
   USB root and drop the extracted Intel Rapid Storage Technology (IRST/VMD) **F6
   driver** into it (the `.inf`/`.sys`/`.cat` files, not the installer `.exe` —
   download from the Dell support page for the exact model, category *Serial
   ATA / Storage*). WinPE loads every `*.inf` found in `<any drive>:\$WinPEDriver$\`
   automatically at boot — no `autounattend.xml` change needed. The `build-usb.ps1`
   asset check reports whether this folder is populated.

### Setup appears frozen at "Installing Windows" (blue progress screen)

**Symptom:** the blue "Installing Windows" progress screen sits at the same percentage
for a very long time and looks frozen.

**Cause (usual):** slow USB media. Applying a ~7 GB `install.wim` from a stick reading
at USB 2.0 speeds (~16 MB/s) takes well over 10 minutes with long stretches of no
visible progress. A dying stick (read stalls/errors) produces a genuine hard freeze.

**What to do:**

1. **Wait ≥ 30 minutes** before declaring it frozen — slow ≠ dead.
2. Plug the stick into a **rear USB port directly on the board** (front-panel headers
   and hubs degrade further).
3. **Health-test the stick** from any Windows PC — a full read flushes out read stalls
   and reports real throughput:

   ```powershell
   Get-FileHash E:\sources\install.wim -Algorithm SHA256   # E: = the USB
   ```

   If this errors out or crawls (single-digit MB/s), re-burn on a faster stick
   (USB 3.0, ≥ 16 GB).

### Windows 11 24H2/25H2 — AutoLogon does not fire (Credential Guard)

**Symptom:** on 24H2/25H2 the machine does **not** log the bootstrap admin in automatically;
you reach the sign-in screen and must log in by hand. The same can happen for the new user's
autologon into Phase B after the reboot.

**Cause (likely):** 24H2/25H2 enable **Credential Guard / VBS by default, which blocks
plaintext-password AutoLogon** stored in `HKLM\…\Winlogon` — exactly the mechanism the
`<AutoLogon>` answer-file element and the Phase B handoff rely on. Observed on a Hyper-V VM;
**verify on real hardware** before treating it as universal (it may be VM-specific).

**Workaround (no change needed — the flow still completes):** log in **once** manually.
`setup.ps1` (Phase A) still launches automatically via `FirstLogonCommands`, and Phase B still
runs via its `-AtLogOn` scheduled task on the manual sign-in — you just lose the fully
hands-free step. Do **not** disable Credential Guard to "fix" this: it weakens the machine's
protection against credential theft (pass-the-hash / LSASS) fleet-wide, and the bootstrap
password is rotated on first login anyway.

---

## 🗂️ 5. Repository files

| File | Description |
|---|---|
| `autounattend.template.xml` | Answer-file template (placeholders for admin user/password) |
| `build-usb.ps1` | USB build wizard: generates `autounattend.xml` always, and with `-GenerateConfig` also writes `config.ps1` interactively + an asset check (one-time, at USB build) |
| `build.bat` | Double-click launcher for `build-usb.ps1` (ExecutionPolicy Bypass; stays open) |
| `force-legacy-setup.ps1` | Forces legacy Setup on the boot USB (24H2/25H2 ConX fix; run as admin, test in VM) |
| `setup.ps1` | Post-installation script with GUI — Phase A |
| `phase-b.ps1` | Phase B: per-user work in the new user's own session (bookmarks, desktop shortcuts, wallpaper, signature, default printer, VPN profile) |
| `cleanup.ps1` | SYSTEM teardown: zeroes + verifies the AutoLogon, unregisters the handoff tasks, deletes staging |
| `collect-machine-info.ps1` | Standalone GUI: shows RAM/storage/MAC/serial/AnyDesk ID for the technician to copy into the asset inventory |
| `collect-machine-info.bat` | Double-click launcher for `collect-machine-info.ps1` (ExecutionPolicy Bypass; pauses on error) |
| `run.bat` | Manual fallback launcher (ExecutionPolicy Bypass) |
| `guard-disk.cmd` | WinPE fail-closed guard: proceeds only if exactly 1 fixed disk (test in VM first) |
| `config.example.ps1` | Configuration template — copy to `config.ps1` on the USB drive |
| `printers.example.json` | Printer-list format reference — copy to `printers.json` |
| `configuration.example.xml` | Office ODT template — copy to `Office\configuration.xml` on the USB drive |
| `tests/` | Test infrastructure: Pester unit tests (`tests/unit/`, run by CI), the Windows Sandbox harness (`prep.ps1`/`bootstrap.ps1`/`run-sandbox.bat`, see `tests/SANDBOX-COMMANDS.txt`) and fake fixtures (`tests/usb-sim/`) |
| `.github/workflows/ci.yml` | CI: PSScriptAnalyzer + Pester (pwsh 7 and Windows PowerShell 5.1) + gitleaks |
| `PSScriptAnalyzerSettings.psd1` | Lint ruleset consumed by CI |
| `.gitleaks.toml` | Secret-scan config (allowlists the `.example`/fixture files) |
| `.gitignore` | Excludes the generated/secret files (below), binaries, signatures, logs |

**Not versioned (generated or live only on the USB drive):**
- `autounattend.xml` — generated by `build-usb.ps1` (has the bootstrap password)
- `config.ps1` — real credentials (copy from `config.example.ps1`)
- `printers.json` — real printer IPs/sectors (copy from `printers.example.json`)
- `ninite.exe` — download pre-configured at ninite.com
- `wallpaper.jpg` — corporate wallpaper
- `signatures-2026/` — Outlook signature `.htm` files (employee personal data)
- `Drivers Epson/`, `WebAgent/`, `CloudAgent/`, `belarc.exe`, `OfficeSetup.exe` — installers

---

## 🚧 Roadmap — intranet auto-provisioning (planned)

Today the technician re-types the same machine/user data into internal IT web portals
**after** `setup.ps1` finishes. The planned next step is to have `setup.ps1` **POST the
data it already collected** to those portals so their forms auto-fill — removing the
double entry and the typos it causes.

Until that lands, [`collect-machine-info.ps1`](#-5-repository-files) is the manual
bridge: it gathers the same device fields (RAM, storage, MAC, serial, AnyDesk ID) into
one copy-paste-ready window, with no dependency on the auto-provisioning work.

Principles for the integration:

- **Best-effort, never blocking.** A portal being down logs a `WARN`; provisioning
  still completes. Same contract as every other phase.
- **No secrets in code.** Portal base URLs and API credentials live in `config.ps1`
  (gitignored); never hardcoded. Prefer HTTPS / internal-only reachability.
- **Idempotent.** Look the record up before creating it, so a re-run does not
  duplicate the user/device.

---

## 📄 License

Released under the [MIT License](LICENSE).
