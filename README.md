# sb-install (Secure Boot Installation Script)

> [!warning]
> This script has not been tested extensively, so unexpected outcomes could theoretically occur.

## Table of Contents

- [What This Is](#what-this-is)
- [Why It Exists](#why-it-exists)
- [How It Works](#how-it-works)
- [Quick Start](#quick-start)
- [Prerequisites and Safety Checklist](#prerequisites-and-safety-checklist)
- [Install Menu Options](#install-menu-options)
- [Prompt Guide](#prompt-guide)
- [What Gets Installed (File Map)](#what-gets-installed-file-map)
- [Backups and Retention](#backups-and-retention)
- [Automatic Updates](#automatic-updates)
- [Health Check and Verification](#health-check-and-verification)
- [Troubleshooting](#troubleshooting)
- [Recovery / Rollback](#recovery--rollback)
- [Uninstall](#uninstall)
- [Security Notes](#security-notes)
- [FAQ](#faq)
- [Repository Layout](#repository-layout)
- [Command Cheatsheet](#command-cheatsheet)

---

## What This Is

A guided Secure Boot helper for Arch-based distros (built for EndeavourOS, should work on other Arch-based systems). Think of it as a careful, menu-driven assistant that walks you through the parts people usually have to stitch together by hand.

It helps you:

- set up a shim + MOK trust chain
- sign kernels and GRUB EFI binaries
- build a signed standalone GRUB EFI with embedded config/theme/splash
- keep shim/MokManager refreshed and EFI binaries re-signed automatically after updates

It includes an install script (`install.sh`) and a dedicated uninstall script (`uninstall.sh`).

## Why It Exists

Secure Boot requires EFI binaries to be signed by trusted keys. On Arch-based systems, GRUB themes, fonts, and kernel updates can silently break boot if you are using Secure Boot without a stable signing workflow.

This project builds a reliable trust chain:

**Firmware → shim (Microsoft-signed) → GRUB (signed by your MOK) → kernel (signed by your MOK)**

…and makes sure it stays healthy over time using pacman hooks and a manual refresh command.

If you have ever wondered why a theme vanished, or why a kernel update suddenly refuses to boot under Secure Boot, this is the automation layer that keeps those problems from resurfacing.

## How It Works

At a high level, the workflow is:

1. Set up shim + MokManager on the ESP and create a boot entry.
2. Create or reuse a Machine Owner Key (MOK).
3. Sign kernels and GRUB using that MOK.
4. Build a **standalone GRUB EFI** (embeds grub.cfg + theme + splash).
5. Install update automation (pacman hooks + manual refresh command).

Why standalone GRUB? It embeds config + assets so GRUB does not depend on disk files at boot time, which is more reliable under Secure Boot.

The scripts are deliberately conservative: they back up before overwriting, confirm major steps, and exit safely if prerequisites are missing.

---

## Quick Start

Ensure Secure Boot is disabled before you begin.

```bash
git clone https://github.com/sarahyack/sb-install
cd sb-install
chmod +x install.sh
./install.sh
```

Recommended first run path:

- Option 7 (full sequence) is the safest guided path.
- Use BootNext when testing shim the first time.
- If anything in a prompt feels unclear, pause and check the [Prompt Guide](#prompt-guide).

After install:

1. Reboot and enable Secure Boot in firmware (if it was off).
2. If MokManager opens, enroll `MOK.cer` from the ESP (`\MOK.cer` or `\EFI\BOOT\MOK.cer`).
3. Reboot again and confirm Secure Boot is working.

> [!note]
> Always read prompts carefully. This script modifies boot-critical files.
> If you want a slower, step-by-step flow, run options 3 → 4 → 6 manually.

---

## Prerequisites and Safety Checklist

- UEFI system with a mounted ESP (VFAT).
- Secure Boot disabled for initial setup (recommended).
- A recovery plan: ability to disable Secure Boot and boot a live USB if needed.
- Sudo access and ability to reboot.
- A bit of uninterrupted time (first run includes at least one reboot).

Helpful commands:

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
findmnt -t vfat
```

---

## Install Menu Options

<details>
<summary>Show all install menu options</summary>

Each option is safe to run individually if you understand the scope. You can rerun options later without redoing the entire flow.

1. **Install packages only**
   - Installs required tools (sbctl/shim/sbsigntools/grub/efibootmgr/openssl).

2. **sbctl flow**
   - Optional: create/enroll sbctl keys and verify/sign files.

3. **Shim + MokManager setup**
   - Installs `shim-signed` if requested, copies or refreshes shim and MokManager on the ESP, and separately offers to create a boot entry.

4. **Create MOK + sign kernel/GRUB**
   - Creates a MOK, signs kernel(s), optionally signs an existing GRUB EFI, and copies `MOK.cer` to the ESP.

5. **Install Post-Update hooks**
   - Installs pacman hooks for shim synchronization, kernel signing, standalone GRUB rebuilds, and the manual refresh command.

6. **Rebuild standalone GRUB + sign + copy fallback**
   - Builds and signs a standalone GRUB EFI with embedded assets.

7. **Full typical sequence**
   - Runs 3 → 4 → 6 in order, then prompts for hooks and optional snapshot support.

8. **Optional: grub-btrfs snapshot support**
   - Installs grub-btrfs and optional snapshot tooling (Snapper/Timeshift).

9. **Health check**
   - Audits installed files and signing status.

</details>

---

## Prompt Guide

<details>
<summary>Common prompts explained</summary>

**ESP mount path**
- Use `/boot/efi` or `/efi`. Pick the VFAT mount containing `EFI/`.
  If you see multiple VFAT mounts, the right one usually contains an `EFI/` directory.

**Disk + partition for efibootmgr**
- Example: `/dev/nvme0n1` + `1`

**BootNext vs BootOrder**
- BootNext is one-time and safest for testing.
- BootOrder is permanent; use after confirming boots are stable.

**MOK key paths**
- Default is `/etc/secureboot/mok`. Don’t overwrite if you already enrolled a key.
  If you do overwrite, you must re-enroll the new `MOK.cer` in MokManager.

**GRUB_ID**
- Controls vendor path: `ESP/EFI/<GRUB_ID>/grubx64.efi`.

**Theme / splash**
- Optional. If omitted, standalone GRUB builds without embedded assets.
  Embedding is recommended if you want consistent visuals under Secure Boot.

</details>

---

## What Gets Installed (File Map)

- Config:
  - `/etc/secureboot/grub-standalone.conf`
- Scripts:
  - `/usr/local/sbin/secureboot-shim-sync`
  - `/usr/local/sbin/grub-standalone-rebuild.sh`
  - `/usr/local/sbin/secureboot-refresh`
  - `/usr/local/sbin/kernel-sbsign-all.sh`
- Hooks:
  - `/etc/pacman.d/hooks/95-kernel-sbsign.hook`
  - `/etc/pacman.d/hooks/98-shim-sync.hook`
  - `/etc/pacman.d/hooks/99-grub-standalone.hook`
- Backups:
  - `/var/lib/secureboot/grub-standalone/backups/`
  - `/var/lib/secureboot/kernel-sbsign/backups/`
  - `ESP/EFI/<GRUB_ID>/backup/` and `ESP/EFI/BOOT/backup/`

---

## Backups and Retention

This project creates **timestamped backups** and metadata so restores can be verified as created by the script.

- Backup filenames include timestamps: `*.sb-install.<UTC timestamp>.bak`
- Metadata files: `*.bak.meta` contain `created_by=sb-install`, source path, and run ID
- A `latest` backup (`.bak`) is also stored for convenience
- Backup retention is controlled by `SB_BACKUP_KEEP` (default `5`)

You can override backup retention like this:

```bash
SB_BACKUP_KEEP=10 ./install.sh
```

Backups are your safety net. If something goes sideways, these are what let you recover quickly.

---

## Automatic Updates

Pacman hooks keep the installed Secure Boot pieces current:

1. **Kernel signing hook**
   - Runs after configured kernel package transactions and signs kernels when needed.

2. **Shim synchronization hook**
   - Runs after `shim-signed` install/upgrade transactions.
   - Compares the installed package files with the ESP copies:
     - `/usr/share/shim-signed/shimx64.efi` → `ESP/EFI/BOOT/BOOTx64.EFI`
     - `/usr/share/shim-signed/mmx64.efi` → `ESP/EFI/BOOT/mmx64.efi`
   - If either ESP copy is stale or missing, it backs up the existing file, copies the installed source, and verifies the final bytes match.
   - It uses file comparison, not version direction, so downgrades are handled the same way as upgrades.

3. **Standalone GRUB rebuild hook**
   - Runs after GRUB, shim-signed, kernel, mkinitcpio, and configured GRUB/theme path changes to rebuild + sign the standalone GRUB.

You can also run a manual refresh any time:

```bash
sudo secureboot-refresh
```

This synchronizes shim/MokManager first, signs kernels if needed, rebuilds/re-signs the standalone GRUB EFI, and runs the existing best-effort verification checks. It does not create NVRAM entries, change `BootOrder`/`BootNext`, regenerate MOK keys, or enroll keys.

The shim synchronization and GRUB rebuild paths are safe to run repeatedly. The shim sync is a no-op when both ESP files already match the installed `shim-signed` package, and the GRUB rebuild uses a lock file to avoid concurrent runs.

If you are curious about what triggers rebuilds, check the hook files.

### Migration note (removing old watcher artifacts)

If you installed an older version that used the continuous watcher, remove it once:

```bash
sudo systemctl disable --now grub-standalone-watch.path grub-standalone-watch.service
sudo rm -f /etc/systemd/system/grub-standalone-watch.path \
  /etc/systemd/system/grub-standalone-watch.service \
  /usr/local/sbin/grub-standalone-watch.sh
sudo systemctl daemon-reload
```

---

## Health Check and Verification

The installer includes a health check (menu option 9). It checks the installed hooks/scripts, ESP mount state, MOK files, GRUB/kernel signatures, and shim/MokManager freshness.

For shim and MokManager it reports the installed source path, the ESP destination path, and `MATCH`, `MISMATCH`, or `MISSING`. A real mismatch is treated as a health-check failure because the boot files on the ESP no longer match the installed `shim-signed` package. The usual remediation is:

```bash
sudo secureboot-refresh
```

You can also manually verify GRUB signatures:

```bash
source /etc/secureboot/grub-standalone.conf
sudo sbverify --list "$ESP_MOUNT/EFI/$GRUB_ID/grubx64.efi"
```

---

## Troubleshooting

<details>
<summary>Common issues and fixes</summary>

**MokManager keeps appearing**
- Enroll the correct `MOK.cer` from the ESP.

**“bad shim lock signature”**
- The binary is not signed by the enrolled MOK. Rebuild + re-sign.

**Health check reports shim or MokManager MISMATCH**
- Run `sudo secureboot-refresh`. It will back up stale ESP copies, refresh them from the installed `shim-signed` package, and verify the final bytes match.

**ESP not mounted**
- Confirm `ESP_MOUNT` and `ESP_DEV` in `/etc/secureboot/grub-standalone.conf`.

</details>

If you are stuck, grab the logs and the health check output first. It is usually enough to spot what went wrong.

---

## Recovery / Rollback

<details>
<summary>Emergency recovery steps</summary>

If Secure Boot fails:

1. Disable Secure Boot in firmware.
2. Boot normally or from live USB.
3. Rebuild standalone GRUB:

```bash
sudo /usr/local/sbin/grub-standalone-rebuild.sh
```

ESP backups exist in:

- `/var/lib/secureboot/grub-standalone/backups/`
- `ESP/EFI/<GRUB_ID>/backup/`
- `ESP/EFI/BOOT/backup/` for fallback GRUB, shim, and MokManager backups

</details>

Take your time here. Recovery is easier when you do one small, verified step at a time.

---

## Uninstall

A dedicated uninstall script is included:

```bash
chmod +x uninstall.sh
./uninstall.sh
```

It will prompt for each major removal step:

- pacman hooks + scripts
- secureboot config/state dirs
- MOK keys
- ESP shim/MOK files
- ESP standalone GRUB binaries
- Shim NVRAM entries

If you are unsure about a step, answer No and move on. You can rerun the uninstall later.

---

## Security Notes

- **Never share private keys** (`MOK.key`).
- It is safe to share `MOK.cer` fingerprints and logs.
- Keep backups; they are your recovery rope.
- Treat the MOK private key like a password: local only, no sync, no paste.

---

## FAQ

<details>
<summary>Answers to common questions</summary>

**Do I need sbctl?**
- No. sbctl is optional. The main workflow uses shim + MOK.

**Does this work with LUKS?**
- Yes, especially because standalone GRUB embeds config/assets.

**Can I change themes later?**
- Yes. Update the theme path, rebuild standalone GRUB, and it will embed the new assets.

</details>

---

## Repository Layout

- `install.sh` - main interactive installer
- `uninstall.sh` - removal script
- `lib/` - helper and health check functions
- `shim/` - shim/MokManager synchronization helper + pacman hook template
- `grub-standalone/` - build scripts + hook templates
- `kernel/` - kernel signing scripts + pacman hook template

---

## Command Cheatsheet

<details>
<summary>Useful commands</summary>

Identify ESP:

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
findmnt -t vfat
```

Rebuild standalone GRUB now:

```bash
sudo /usr/local/sbin/grub-standalone-rebuild.sh
```

Sign kernels now:

```bash
sudo /usr/local/sbin/kernel-sbsign-all.sh
```

Check shim/MokManager ESP freshness:

```bash
sudo /usr/local/sbin/secureboot-shim-sync --check
```

Refresh only shim/MokManager:

```bash
sudo /usr/local/sbin/secureboot-shim-sync
```

Manual refresh now:

```bash
sudo secureboot-refresh
```

</details>
