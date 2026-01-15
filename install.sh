#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "[ERR] Do not run this script as root. Run it as your normal user; it will use sudo when needed."
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_SIGN_SCRIPT_TEMPLATE="$SCRIPT_DIR/kernel/kernel-sbsign-all.sh"
KERNEL_SIGN_HOOK_TEMPLATE="$SCRIPT_DIR/kernel/kernel-sbsign.hook"
GRUB_HOOK_TEMPLATE="$SCRIPT_DIR/grub-standalone/grub-standalone.hook"
WATCHER_SCRIPT_TEMPLATE="$SCRIPT_DIR/grub-standalone/grub-standalone-watch.sh"
WATCHER_SERVICE_TEMPLATE="$SCRIPT_DIR/grub-standalone/grub-standalone-watch.service"
WATCHER_PATH_TEMPLATE="$SCRIPT_DIR/grub-standalone/grub-standalone-watch.path"
STANDALONE_GRUB_BUILDER="$SCRIPT_DIR/grub-standalone/build-grub-standalone.sh"
ENV_FILE="$SCRIPT_DIR/lib/env.sh"
SB_INSTALL_RUN_ID="${SB_INSTALL_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)-$$}"
export SB_INSTALL_RUN_ID

# Load GRUB_MODULES into this script's environment (temporary)
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] || die "Missing env.sh"; source "$ENV_FILE"

source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/checkhealth.sh"

show_intro() {
  cat <<'TXT'

Secure Boot Helper (sbctl + shim + GRUB shim-lock modules)

This script can:
  A) Run sbctl workflow (create/enroll keys, verify, sign complained files)
  B) Set up shim + MokManager on the ESP and create an NVRAM entry
  C) Create a MOK (RSA 2048) and sign kernel + GRUB EFI binaries using sbsigntools
  D) Install Watcher hooks for future update support
  E) Reinstall GRUB with GRUB_MODULES + sbat.csv, then sign + copy to fallback path
  F) Set Up Full Support for Grub-Btrfs & Snapshots (Snapper or Timeshift)
  G) Run a Health Check for Everything This Script Installs/Signs

It will ask before each big step.

TXT
}

run_sbctl_flow() {
  say "sbctl workflow"
  confirm "Install sbctl (yay)?" 0 && yay_install sbctl

  say "sbctl status:"
  sudo sbctl status || true

  if confirm "Create sbctl keys (sudo sbctl create-keys)?" 1; then
    sudo sbctl create-keys
  fi

  warn "Next step enrolls keys with Firmware and Microsoft keys included: sbctl enroll-keys -m -f"
  if confirm "Enroll keys now (this is a big step)?" 1; then
    sudo sbctl enroll-keys -m -f
  fi

  if confirm "Run sbctl verify to find unsigned files?" 0; then
    say "sbctl verify output (read this and copy the file paths it complains about):"
    echo "------------------------------------------------------------"
    sudo sbctl verify || true
    echo "------------------------------------------------------------"
    echo
    warn "Please manually enter the full paths that sbctl verify says need signing."
    warn "Tip: you can paste multiple paths at once, separated by spaces."

    local -a paths=()
    read -r -p "Enter full paths to sign with sbctl (or leave blank to skip): " -a paths

    if [[ "${#paths[@]}" -gt 0 ]]; then
      echo "You entered:"
      printf '  - %s\n' "${paths[@]}"
      if confirm "Sign these now with: sbctl sign -s <path> ?" 1; then
        for p in "${paths[@]}"; do
          [[ -e "$p" ]] || { warn "Skipping missing: $p"; continue; }
          sudo sbctl sign -s "$p"
        done
      fi
    else
      warn "No paths entered; skipping signing step."
    fi
  fi

  say "sbctl status (post):"
  sudo sbctl status || true
}

setup_shim_and_mokmanager() {
  local esp="$1"

  say "Shim + MokManager setup on ESP: $esp"
  confirm "Install shim-signed + efibootmgr?" 0 && yay_install shim-signed efibootmgr

  sudo mkdir -p "$esp/EFI/BOOT"
  local shim_src mm_src
  IFS='|' read -r shim_src mm_src < <(detect_shim_paths || true)

  shim_src="${shim_src:-/usr/share/shim-signed/shimx64.efi}"
  mm_src="${mm_src:-/usr/share/shim-signed/mmx64.efi}"

  [[ -f "$shim_src" ]] || die "shim not found: $shim_src (is shim-signed installed?)"
  [[ -f "$mm_src" ]] || die "MokManager not found: $mm_src (is shim-signed installed?)"

  if confirm "Copy shim to $esp/EFI/BOOT/BOOTx64.EFI and MokManager to $esp/EFI/BOOT/ ?" 1; then
    backup_file "$esp/EFI/BOOT/BOOTx64.EFI" "$esp/EFI/BOOT/backup"
    backup_file "$esp/EFI/BOOT/mmx64.efi" "$esp/EFI/BOOT/backup"
    sudo cp -f "$shim_src" "$esp/EFI/BOOT/BOOTx64.EFI"
    sudo cp -f "$mm_src" "$esp/EFI/BOOT/mmx64.efi"
    say "Copied shim + MokManager."
  fi

  if confirm "Create NVRAM boot entry for shim (label: Shim)?" 1; then
    local ESP_DISK ESP_PART
    local shim_bootnum=""

    if IFS='|' read -r ESP_DISK ESP_PART < <(get_disk_part_for_efibootmgr "$esp"); then
      :
    else
      warn "Couldn't auto-derive disk+part for efibootmgr; falling back to manual input."
      IFS='|' read -r ESP_DISK ESP_PART < <(pick_disk_part)
    fi

    [[ "$ESP_DISK" == /dev/* ]] || die "Bad ESP_DISK from detection: '$ESP_DISK'"
    [[ "$ESP_PART" =~ ^[0-9]+$ ]] || die "Bad ESP_PART from detection: '$ESP_PART'"

    local -a nums=()
    mapfile -t nums < <(bootnums_for_label_and_loader "Shim" "bootx64.efi" || true)

    if (( ${#nums[@]} > 0 )); then
      local best=""
      best="$(choose_highest_bootnum "${nums[@]}" || true)"
      echo
      echo "Found existing Shim boot entries that already point at BOOTX64.EFI:"
      printf '  - Boot%s\n' "${nums[@]}"
      echo
      if [[ -n "$best" ]] && confirm "Reuse newest-looking one (Boot$best)?" 0; then
        shim_bootnum="$best"
      else
        shim_bootnum="$(choose_bootnum_from_list "${nums[@]}")" || die "No Shim entry selected."
      fi
    else
      # Create entry only if none exists that matches the loader path
      say "No existing matching Shim entry found; creating a new one."
      sudo efibootmgr --unicode --disk "$ESP_DISK" --part "$ESP_PART" --create \
        --label "Shim" --loader '\EFI\BOOT\BOOTX64.EFI'

      # Re-scan after creation
      mapfile -t nums < <(bootnums_for_label_and_loader "Shim" "bootx64.efi" || true)
      (( ${#nums[@]} > 0 )) || die "Created Shim entry, but couldn't detect it via efibootmgr output."

      shim_bootnum="$(choose_highest_bootnum "${nums[@]}")" || shim_bootnum="${nums[0]}"
      say "Using Shim boot entry: Boot${shim_bootnum}"
    fi

    # BootNext (one-time) — default YES
    if confirm "Set Shim as NEXT boot only (BootNext)?" 0; then
      set_bootnext "$shim_bootnum"
    fi

    # Permanent BootOrder — default NO
    if confirm "Move Shim to the FRONT permanently (BootOrder)?" 1; then
      set_bootorder_shim_first "$shim_bootnum"
    fi

    warn "Note: You can always manage boot order later in BIOS/UEFI, or via:"
    echo "  sudo efibootmgr"
    echo "  sudo efibootmgr -n $shim_bootnum           # one-time next boot"
    echo "  sudo efibootmgr -o $shim_bootnum,<rest...> # permanent order"
  fi
}

sign_kernel_and_grub_with_mok() {
  local esp="$1"
  say "Sign kernel + GRUB EFI binaries with a Machine Owner Key (MOK)"
  confirm "Install sbsigntools + openssl?" 0 && yay_install sbsigntools openssl

  read -r -p "Where should MOK keys live? (default: /etc/secureboot/mok): " mok_dir
  mok_dir="${mok_dir:-/etc/secureboot/mok}"

  if confirm "Create (or reuse) MOK keys in $mok_dir ?" 0; then
    mk_mok_keys "$mok_dir" "$esp"
  fi

  local MOK_KEY="$mok_dir/MOK.key"
  local MOK_CRT="$mok_dir/MOK.crt"
  local MOK_CER="$mok_dir/MOK.cer"
  sudo test -f "$MOK_KEY" || die "Missing MOK files in $mok_dir"
  sudo test -f "$MOK_CRT" || die "Missing MOK files in $mok_dir"
  sudo test -f "$MOK_CER" || die "Missing MOK files in $mok_dir"

  say "Kernel signing"
  echo "Common kernel paths:"
  ls -1 /boot/vmlinuz* 2>/dev/null || true
  read -r -p "Enter kernel image path(s) to sign (space-separated, default: /boot/vmlinuz-linux): " -a kernels
  if [[ "${#kernels[@]}" -eq 0 ]]; then kernels=(/boot/vmlinuz-linux); fi

  if confirm "Sign kernel image(s) now?" 1; then
    for k in "${kernels[@]}"; do
      sign_in_place "$MOK_KEY" "$MOK_CRT" "$k"
    done
  fi

  say "GRUB EFI signing"

  say "GRUB candidates on ESP:"
  detect_grub_efi_candidates "$esp" | sed 's/^/  - /' || true
  echo

  if confirm "Auto-select a grubx64.efi from the ESP and sign it now?" 0; then
    local grub_efi
    grub_efi="$(choose_grub_efi "$esp")" || true
    if [[ -z "${grub_efi:-}" ]]; then
      warn "Couldn't auto-find GRUB EFI on $esp."
      read -r -p "Enter full path to the GRUB EFI to sign (or blank to skip): " grub_efi
    fi

    if [[ -n "${grub_efi:-}" ]]; then
      sudo test -f "$grub_efi" || die "GRUB EFI not found: $grub_efi"
      say "Selected GRUB EFI: $grub_efi"
      sign_in_place "$MOK_KEY" "$MOK_CRT" "$grub_efi"
    else
      warn "Skipping GRUB signing."
    fi
  else
    warn "Skipping GRUB signing in this step."
    warn "If you want to sign manually later, run option 4 again or use option 6 (GRUB reinstall + signing)."
  fi

  say "Copy MOK.cer to ESP so MokManager can enroll it from disk"
  show_mok_fingerprint_report "$mok_dir" "$esp"
  if confirm "Copy $MOK_CER onto the ESP root and ESP/EFI/BOOT ?" 0; then
    sudo cp -f "$MOK_CER" "$esp/MOK.cer"
    sudo cp -f "$MOK_CER" "$esp/EFI/BOOT/MOK.cer" || true
    say "Copied MOK.cer to:"
    echo "  - $esp/MOK.cer"
    echo "  - $esp/EFI/BOOT/MOK.cer (if directory exists)"
  fi

  say "MOK key summary:"
  echo "  Key : $MOK_KEY"
  echo "  CRT : $MOK_CRT"
  echo "  CER : $MOK_CER"
}

install_watchers() {
  confirm "Install Watchers for Post-Update Resigning & Rebuilding (kernel + grubcfg)?" 0 \
      || { say "Skipping watcher/hook install."; return 0; }

  [[ -f "$KERNEL_SIGN_SCRIPT_TEMPLATE" ]] || die "Missing template: $KERNEL_SIGN_SCRIPT_TEMPLATE"
  [[ -f "$KERNEL_SIGN_HOOK_TEMPLATE"   ]] || die "Missing template: $KERNEL_SIGN_HOOK_TEMPLATE"
  [[ -f "$STANDALONE_GRUB_BUILDER"     ]] || die "Missing template: $STANDALONE_GRUB_BUILDER"
  [[ -f "$GRUB_HOOK_TEMPLATE"          ]] || die "Missing template: $GRUB_HOOK_TEMPLATE"
  [[ -f "$WATCHER_SCRIPT_TEMPLATE"     ]] || die "Missing template: $WATCHER_SCRIPT_TEMPLATE"
  [[ -f "$WATCHER_SERVICE_TEMPLATE"    ]] || die "Missing template: $WATCHER_SERVICE_TEMPLATE"
  [[ -f "$WATCHER_PATH_TEMPLATE"       ]] || die "Missing template: $WATCHER_PATH_TEMPLATE"

  # Install kernel signing script + pacman hook (PostTransaction)
  say "Installing kernel signing script to /usr/local/sbin/kernel-sbsign-all.sh"
  [[ -f "$KERNEL_SIGN_SCRIPT_TEMPLATE" ]] || die "Missing template: $KERNEL_SIGN_SCRIPT_TEMPLATE"
  sudo install -D -m 0755 "$KERNEL_SIGN_SCRIPT_TEMPLATE" /usr/local/sbin/kernel-sbsign-all.sh

  say "Installing pacman hook for kernel signing to /etc/pacman.d/hooks/95-kernel-sbsign.hook"
  [[ -f "$KERNEL_SIGN_HOOK_TEMPLATE" ]] || die "Missing template: $KERNEL_SIGN_HOOK_TEMPLATE"
  sudo install -D -m 0644 "$KERNEL_SIGN_HOOK_TEMPLATE" /etc/pacman.d/hooks/95-kernel-sbsign.hook

  say "Installing builder to /usr/local/sbin/grub-standalone-rebuild.sh"
  sudo install -D -m 0755 "$STANDALONE_GRUB_BUILDER" /usr/local/sbin/grub-standalone-rebuild.sh

  say "Installing pacman hook to /etc/pacman.d/hooks/99-grub-standalone.hook"
  sudo install -D -m 0644 "$GRUB_HOOK_TEMPLATE" /etc/pacman.d/hooks/99-grub-standalone.hook

  say "Installing watch script + systemd path/service (manual edits trigger rebuilds)"
  sudo install -D -m 0755 "$WATCHER_SCRIPT_TEMPLATE" /usr/local/sbin/grub-standalone-watch.sh
  sudo install -D -m 0644 "$WATCHER_SERVICE_TEMPLATE" /etc/systemd/system/grub-standalone-watch.service
  sudo install -D -m 0644 "$WATCHER_PATH_TEMPLATE" /etc/systemd/system/grub-standalone-watch.path

  sudo systemctl daemon-reload
  sudo systemctl disable --now grub-standalone-watch.service >/dev/null 2>&1 || true
  sudo systemctl enable --now grub-standalone-watch.path
  say "Watcher enabled: grub-standalone-watch.path"

}

install_grub_standalone_maintenance() {
  local esp="$1"

  confirm "Install grub + sbsigntools (standalone build + watcher)?" 0 && yay_install grub sbsigntools

  # Detect ESP device for hook-time mounts
  local esp_dev
  esp_dev="$(esp_device_from_mount "$esp")" || die "Couldn't detect ESP device from mount: $esp"
  if [[ "$esp_dev" == UUID=* ]]; then
    local uuid="${esp_dev#UUID=}"
    esp_dev="$(blkid -U "$uuid" 2>/dev/null || true)"
  fi
  esp_dev="$(readlink -f -- "$esp_dev" 2>/dev/null || printf '%s' "$esp_dev")"
  [[ -b "$esp_dev" ]] || die "ESP device isn't a block device: $esp_dev"

  read -r -p "GRUB ID on ESP (default: GRUB): " grub_id
  grub_id="${grub_id:-GRUB}"

  local mok_key_def="/etc/secureboot/mok/MOK.key"
  local mok_crt_def="/etc/secureboot/mok/MOK.crt"
  local mok_cer_def="/etc/secureboot/mok/MOK.cer"
  read -r -p "MOK.key path (default: $mok_key_def): " mok_key
  mok_key="${mok_key:-$mok_key_def}"
  read -r -p "MOK.crt path (default: $mok_crt_def): " mok_crt
  mok_crt="${mok_crt:-$mok_crt_def}"
  read -r -p "MOK.cer path (default: $mok_cer_def): " mok_cer
  mok_cer="${mok_cer:-$mok_cer_def}"

  sudo test -r "$mok_key" || die "Can't read: $mok_key"
  sudo test -r "$mok_crt" || die "Can't read: $mok_crt"
  sudo test -r "$mok_cer" || die "Can't read: $mok_cer"

  local theme_dir_def="/boot/grub/themes/starfield"
  read -r -p "Theme dir to embed (default: $theme_dir_def): " theme_dir
  theme_dir="${theme_dir:-$theme_dir_def}"
  [[ -d "$theme_dir" ]] || theme_dir=""

  local theme_name_def="starfield"
  read -r -p "Theme Name (default: $theme_name_def): " theme_name
  theme_name="${theme_name:-$theme_name_def}"

  local splash_def="/usr/share/endeavouros/splash.png"
  read -r -p "Background splash PNG to embed (default: $splash_def): " splash_src
  splash_src="${splash_src:-$splash_def}"
  [[ -r "$splash_src" ]] || splash_src=""

  # Build modules string: your env.sh GRUB_MODULES + required theme bits
  local modules_norm extras modules_final
  modules_norm="$(printf '%s' "$GRUB_MODULES" | tr '\n\t' '  ' | xargs)"
  extras="font gfxterm gfxterm_background gfxmenu png gettext all_video efi_gop efi_uga"

  # de-dup
  modules_final="$(
    printf '%s %s\n' "$modules_norm" "$extras" \
      | tr ' ' '\n' \
      | awk 'NF && !seen[$0]++' \
      | paste -sd' ' -
  )"

  local default_watch_dirs="/etc/default /etc/grub.d /boot/grub/themes /usr/share/endeavouros"
  local existing_watch_dirs="$(read_existing_watch_dirs || true)"
  local watch_dirs="${existing_watch_dirs:-$default_watch_dirs}"

  say "Writing config: /etc/secureboot/grub-standalone.conf"
  sudo install -d -m 0755 /etc/secureboot
  sudo tee /etc/secureboot/grub-standalone.conf >/dev/null <<EOF
ESP_MOUNT="$esp"
ESP_DEV="$esp_dev"
GRUB_ID="$grub_id"

MOK_KEY="$mok_key"
MOK_CRT="$mok_crt"
MOK_CER="$mok_cer"

MODULES="$modules_final"

THEME_DIR="$theme_dir"
THEME_NAME="$theme_name"

SPLASH_SRC="$splash_src"
WATCH_DIRS="$watch_dirs"
EOF

  install_watchers

  confirm "Would you like to Install Snapshot Support? [y/n]" 0 && install_grub_btrfs_support

  run_grub_builder
}

# -----------------------------
# Optional: grub-btrfs support
# -----------------------------

install_grub_btrfs_support() {
  say "Optional snapshot boot menu support (grub-btrfs)"

  confirm "Install grub-btrfs?" 0 || { say "Skipping grub-btrfs support."; return 0; }
  yay_install grub-btrfs

  # Ensure grub-btrfs script is executable if present
  if sudo test -f /etc/grub.d/41_snapshots-btrfs; then
    sudo chmod +x /etc/grub.d/41_snapshots-btrfs || true
  fi

  say "Choose snapshot tool:"
  echo "  1) Snapper (recommended)"
  echo "  2) Timeshift (BTRFS mode only)"
  echo "  3) Neither (I’ll install grub-btrfs only)"
  read -r -p "Enter selection (1-3): " tool_sel

  local snapdir=""
  case "$tool_sel" in
    1)
      confirm "Install snapper + btrfs-progs?" 0 && yay_install snapper btrfs-progs
      ensure_snapper_root_config || warn "Snapper config step may have failed; you can create it later."
      snapdir="$(detect_snapper_snapshot_dir)"
      say "Detected Snapper snapshot dir: $snapdir"
      conf_add_watch_dir "/etc/snapper"
      confirm "Install snapper GUI? (btrfs-assistant)" 0 && yay_install btrfs-assistant
      confirm "Install Auto-Snapshot Support For Updates? (snap-pac) [y/n]" 0 && yay_install snap-pac
      ;;
    2)
      confirm "Install timeshift + btrfs-progs?" 0 && yay_install timeshift btrfs-progs
      snapdir="$(detect_timeshift_snapshot_dir)"
      say "Detected/assumed Timeshift snapshot dir: $snapdir"
      warn "Reminder: Timeshift must be configured in BTRFS mode for grub-btrfs menus to work."
      conf_add_watch_dir "/etc/timeshift"
      confirm "Install Auto-Snapshot Support For Updates? (timeshift-autosnap) [y/n]" 0 && yay_install timeshift-autosnap
      ;;
    3)
      warn "No snapshot tool installed (grub-btrfs only)."
      ;;
    *)
      warn "Invalid selection; skipping snapshot tool setup."
      ;;
  esac

  disable_grub_btrfsd

  # Add snapshot dir to your existing watcher (so snapshot creation triggers rebuild)
  if [[ -n "$snapdir" ]]; then
    conf_add_watch_dir "$snapdir"
  fi

  # Restart watcher so it rereads grub-standalone.conf
  sudo systemctl restart grub-standalone-watch.service >/dev/null 2>&1 || true

  run_grub_builder

  say "grub-btrfs support done."
  say "Tip: watch logs with: journalctl -fu grub-standalone-watch.service"
}

run_healthcheck() {
    confirm "Perform Health Check Now? [y/n]" 0

    checkhealth
}

final_instructions() {
  cat <<'TXT'

If running full sequence for the first time, the next manual steps that cannot be scripted safely are:

1) Reboot and enable Secure Boot in firmware if needed.

2) If shim does not find the certificate that grubx64.efi is signed with in MokList,
   it will launch MokManager (mmx64.efi).

   In MokManager:
     - "Enroll key from disk"
     - find MOK.cer on the ESP (often at \MOK.cer or \EFI\BOOT\MOK.cer)
     - enroll it to MokList
     - Continue boot

3) Reboot again; Secure Boot should be working.

TXT
}

main() {
  show_intro

  need_cmd bash
  sudo_once

  local check_already_run=false

  # Options
  say "Choose what to run:"
  echo "  1) Install packages only"
  echo "  2) sbctl flow (keys/enroll/verify/sign)"
  echo "  3) Shim + MokManager copy + NVRAM entry"
  echo "  4) Create MOK + sign kernel/GRUB + copy MOK.cer to ESP"
  echo "  5) Install Post-Update Hooks for Future Update Re-signing & Rebuilding"
  echo "  6) Rebuild GRUB Standalone with GRUB_MODULES + sbat.csv + sign/copy fallback"
  echo "  7) Run a typical full sequence (3 -> 4 -> 5 -> 6), with prompts"
  echo "  8) Optional: grub-btrfs snapshot boot menu support (Snapper/Timeshift)"
  echo "  9) Run a Health Check For This Script To Ensure Everything's Setup Properly"
  echo

  read -r -p "Enter selection (1-9): " sel
  case "$sel" in
    1)
      confirm "Install sbctl, shim-signed, sbsigntools, efibootmgr, grub, openssl?" 0 && \
        yay_install sbctl shim-signed sbsigntools efibootmgr grub openssl
      ;;
    2)
      run_sbctl_flow
      ;;
    3)
      esp="$(get_esp_or_ask)"
      setup_shim_and_mokmanager "$esp"
      ;;
    4)
      esp="$(get_esp_or_ask)"
      sign_kernel_and_grub_with_mok "$esp"
      ;;
    5)
      confirm "WARNING: Only Run This Option After a Full Sequence Has Been Run on Your Machine! Continue (y/n)?" 0 \
          || { say "Canceling Watcher Installation."; return 0; }
      install_watchers
      ;;
    6)
      esp="$(get_esp_or_ask)"
      install_grub_standalone_maintenance "$esp"
      ;;
    7)
      esp="$(get_esp_or_ask)"
      setup_shim_and_mokmanager "$esp"
      sign_kernel_and_grub_with_mok "$esp"
      install_grub_standalone_maintenance "$esp"
      ;;
    8)
      install_grub_btrfs_support
      ;;
    9)
      run_healthcheck
      check_already_run=true
      ;;
    *)
      die "Invalid selection."
      ;;
  esac

  if [[ "${check_already_run}" != true ]]; then
      run_healthcheck
  fi

  final_instructions
}

main "$@"
