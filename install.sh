#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "[ERR] Do not run this script as root. Run it as your normal user; it will use sudo when needed."
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOOK_TEMPLATE="$SCRIPT_DIR/mkinitcpio-hook"
ENV_FILE="$SCRIPT_DIR/env.sh"

say() { printf "\n==> %s\n" "$*"; }
warn() { printf "\n[WARN] %s\n" "$*" >&2; }
die() { printf "\n[ERR] %s\n" "$*" >&2; exit 1; }

# Load GRUB_MODULES into this script's environment (temporary)
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] || die "Missing env.sh"; source "$ENV_FILE"

confirm() {
  local prompt="${1:-Proceed?}"
  local default_no="${2:-1}" # 1 = default No, 0 = default Yes
  local yn
  if [[ "$default_no" -eq 1 ]]; then
    read -r -p "$prompt [y/N]: " yn || true
    [[ "${yn:-}" =~ ^[Yy]$ ]]
  else
    read -r -p "$prompt [Y/n]: " yn || true
    [[ -z "${yn:-}" || "${yn}" =~ ^[Yy]$ ]]
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

sudo_once() {
  say "Requesting sudo once (and keeping it alive while the script runs)..."
  sudo -v
  # keepalive
  ( while true; do sudo -n true; sleep 45; done ) >/dev/null 2>&1 &
  SUDO_KEEPALIVE_PID=$!
  trap '[[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "${SUDO_KEEPALIVE_PID}" >/dev/null 2>&1 || true' EXIT
}

yay_install() {
  local pkgs=("$@")
  need_cmd yay
  say "Installing packages (if missing) via yay: ${pkgs[*]}"

  # Interactive by default. If you want fewer yay prompts, see note below.
  yay -S --needed --noconfirm --answerclean None --answerdiff None "${pkgs[@]}"
}

backup_file() {
  local path="$1"
  local backup_dir="$2"
  local base
  base="$(basename -- "$path")"
  if [[ -e "$path" ]]; then
    sudo mkdir -p "$backup_dir"
    sudo cp -a "$path" "$backup_dir/${base}.$(date +%Y%m%d-%H%M%S).bak"
  fi
}

autodetect_esp_mount() {
  local -a mps=()
  mapfile -t mps < <(findmnt -rn -t vfat -o TARGET 2>/dev/null || true)

  if (( ${#mps[@]} == 0 )); then
    return 1
  elif (( ${#mps[@]} == 1 )); then
    printf '%s\n' "${mps[0]}"
    return 0
  else
    echo "Multiple VFAT mounts detected (possible ESPs):"
    local i
    for i in "${!mps[@]}"; do
      echo "  $((i+1))) ${mps[$i]}"
    done
    read -r -p "Pick the ESP mount (number): " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || return 2
    (( choice >= 1 && choice <= ${#mps[@]} )) || return 2
    printf '%s\n' "${mps[$((choice-1))]}"
    return 0
  fi
}

get_esp_or_ask() {
  local esp
  if esp="$(autodetect_esp_mount)"; then
    say "Detected ESP mount: $esp"
    echo "$esp"
    return 0
  fi
  echo "Couldn't auto-detect a mounted ESP."
  echo "Try: lsblk -f  OR  findmnt -t vfat"
  read -r -p "Enter your mounted ESP path (example: /boot/efi or /efi): " esp
  [[ -d "$esp" ]] || return 1
  echo "$esp"
}

esp_device_from_mount() {
  local esp="$1"
  findmnt -rn -o SOURCE --target "$esp"
}

disk_part_from_device() {
  local dev="$1"
  local disk part

  if [[ "$dev" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
    disk="${BASH_REMATCH[1]}"
    part="${BASH_REMATCH[2]}"
  elif [[ "$dev" =~ ^(/dev/mmcblk[0-9]+)p([0-9]+)$ ]]; then
    disk="${BASH_REMATCH[1]}"
    part="${BASH_REMATCH[2]}"
  elif [[ "$dev" =~ ^(/dev/[a-zA-Z]+)[0-9]+$ ]]; then
    disk="${dev%%[0-9]*}"
    part="${dev##*[!0-9]}"
  else
    return 1
  fi

  printf '%s|%s\n' "$disk" "$part"
}

get_disk_part_for_efibootmgr() {
  local esp="$1"
  local dev diskpart

  dev="$(esp_device_from_mount "$esp")" || return 1
  [[ -b "$dev" ]] || return 1

  diskpart="$(disk_part_from_device "$dev")" || return 1
  say "ESP device: $dev -> disk/part: ${diskpart/|/ }"
  printf '%s\n' "$diskpart"
}

detect_shim_paths() {
  local shim mm
  shim="$(yay -Ql shim-signed 2>/dev/null | awk '{print $2}' | grep -E '/shimx64\.efi$' | head -n1 || true)"
  mm="$(yay -Ql shim-signed 2>/dev/null | awk '{print $2}' | grep -E '/mmx64\.efi$' | head -n1 || true)"
  [[ -f "$shim" && -f "$mm" ]] || return 1
  printf '%s|%s\n' "$shim" "$mm"
}

detect_grub_efi_candidates() {
  local esp="$1"
  find "$esp/EFI" -maxdepth 3 -type f -iname 'grubx64.efi' 2>/dev/null | sort -u || true
}

choose_grub_efi() {
  local esp="$1"
  local -a cands=()
  mapfile -t cands < <(detect_grub_efi_candidates "$esp")

  if (( ${#cands[@]} == 0 )); then
    return 1
  elif (( ${#cands[@]} == 1 )); then
    printf '%s\n' "${cands[0]}"
    return 0
  else
    echo "Multiple grubx64.efi candidates found:"
    local i
    for i in "${!cands[@]}"; do
      echo "  $((i+1))) ${cands[$i]}"
    done
    read -r -p "Pick which GRUB EFI to use (number): " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || return 2
    (( choice >= 1 && choice <= ${#cands[@]} )) || return 2
    printf '%s\n' "${cands[$((choice-1))]}"
    return 0
  fi
}

sign_in_place() {
  local key="$1" cert="$2" target="$3"
  [[ -f "$key" ]] || die "Key not found: $key"
  [[ -f "$cert" ]] || die "Cert not found: $cert"
  [[ -f "$target" ]] || die "Target not found: $target"

  local tmp
  tmp="$(mktemp)"
  say "Signing: $target"
  sudo sbsign --key "$key" --cert "$cert" --output "$tmp" "$target"
  sudo cp -a "$target" "$target.presign.$(date +%Y%m%d-%H%M%S).bak"
  sudo mv -f "$tmp" "$target"
}

extract_sbctl_paths() {
  # Attempt to extract paths from `sbctl verify` output
  # Common formats include lines containing absolute paths; we grab /something tokens
  sed -nE 's/.*(\/[^[:space:]]+).*/\1/p' | sort -u
}

show_intro() {
  cat <<'TXT'

Secure Boot Helper (sbctl + shim + GRUB shim-lock modules)

This script can:
  A) Run sbctl workflow (create/enroll keys, verify, sign complained files)
  B) Set up shim + MokManager on the ESP and create an NVRAM entry
  C) Create a MOK (RSA 2048) and sign kernel + GRUB EFI binaries using sbsigntools
  D) Install mkinitcpio post hook: /etc/initcpio/post/kernel-sbsign (from template)
  E) Reinstall GRUB with GRUB_MODULES + sbat.csv, then sign + copy to fallback path

It will ask before each big step.

TXT
}

pick_esp() {
  say "ESP (EFI System Partition) mountpoint needed."
  echo "Helpful commands:"
  echo "  lsblk -f"
  echo "  findmnt -t vfat"
  echo
  read -r -p "Enter your mounted ESP path (example: /boot/efi or /efi): " ESP
  [[ -d "$ESP" ]] || die "ESP path does not exist: $ESP"
  echo "$ESP"
}

pick_disk_part() {
  say "efibootmgr needs the disk + partition number for the ESP."
  echo "Helpful commands:"
  echo "  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,PARTUUID"
  echo "  sudo fdisk -l"
  echo
  read -r -p "Enter ESP disk (example: /dev/nvme0n1 or /dev/sda): " ESP_DISK
  read -r -p "Enter ESP partition number (example: 1): " ESP_PART
  [[ -b "$ESP_DISK" ]] || die "Not a block device: $ESP_DISK"
  [[ "$ESP_PART" =~ ^[0-9]+$ ]] || die "Partition must be a number."
  echo "$ESP_DISK|$ESP_PART"
}

mk_mok_keys() {
  local mok_dir="$1"
  say "Creating Machine Owner Key (RSA 2048) in: $mok_dir"
  sudo mkdir -p "$mok_dir"
  sudo chmod 700 "$mok_dir"

  if [[ -f "$mok_dir/MOK.key" || -f "$mok_dir/MOK.crt" || -f "$mok_dir/MOK.cer" ]]; then
    warn "MOK.* already exists in $mok_dir"
    confirm "Overwrite existing MOK.* files?" 1 || { say "Keeping existing keys."; return 0; }
    sudo rm -f "$mok_dir/MOK.key" "$mok_dir/MOK.crt" "$mok_dir/MOK.cer"
  fi

  sudo openssl req \
    -newkey rsa:2048 -nodes \
    -keyout "$mok_dir/MOK.key" \
    -new -x509 -sha256 -days 3650 \
    -subj "/CN=my Machine Owner Key/" \
    -out "$mok_dir/MOK.crt"

  sudo openssl x509 -outform DER -in "$mok_dir/MOK.crt" -out "$mok_dir/MOK.cer"

  sudo chmod 600 "$mok_dir/MOK.key"
  sudo chmod 644 "$mok_dir/MOK.crt" "$mok_dir/MOK.cer"

  say "Created: $mok_dir/MOK.key, MOK.crt, MOK.cer"
}

install_mkinitcpio_hook() {
  [[ -f "$HOOK_TEMPLATE" ]] || die "Missing template: $HOOK_TEMPLATE"

  say "Installing mkinitcpio post hook to /etc/initcpio/post/kernel-sbsign"
  sudo mkdir -p /etc/initcpio/post
  sudo cp -f "$HOOK_TEMPLATE" /etc/initcpio/post/kernel-sbsign
  sudo chmod +x /etc/initcpio/post/kernel-sbsign

  warn "The installed hook still contains placeholder paths (/path/to/MOK.key /path/to/MOK.crt)."
  if confirm "Do you want me to replace those placeholders now?" 0; then
    read -r -p "Enter full path to MOK.key (example: /etc/secureboot/mok/MOK.key): " KEY_PATH
    read -r -p "Enter full path to MOK.crt (example: /etc/secureboot/mok/MOK.crt): " CRT_PATH
    [[ -f "$KEY_PATH" ]] || die "Key not found: $KEY_PATH"
    [[ -f "$CRT_PATH" ]] || die "Cert not found: $CRT_PATH"
    # Escape slashes for sed
    local key_esc crt_esc
    key_esc="$(printf '%s' "$KEY_PATH" | sed 's/[\/&]/\\&/g')"
    crt_esc="$(printf '%s' "$CRT_PATH" | sed 's/[\/&]/\\&/g')"
    sudo sed -i "s#/path/to/MOK\.key#${key_esc}#g; s#/path/to/MOK\.crt#${crt_esc}#g" /etc/initcpio/post/kernel-sbsign
    say "Updated /etc/initcpio/post/kernel-sbsign with your key paths."
  else
    say "Okay. Remember to edit /etc/initcpio/post/kernel-sbsign later."
  fi
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

  # fallback to old defaults if detection failed
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

  if confirm "Create NVRAM boot entry for shim (efibootmgr)?" 1; then
    local ESP_DISK ESP_PART

    if IFS='|' read -r ESP_DISK ESP_PART < <(get_disk_part_for_efibootmgr "$esp"); then
      : # autodetect succeeded
    else
      warn "Couldn't auto-derive disk+part for efibootmgr; falling back to manual input."
      IFS='|' read -r ESP_DISK ESP_PART < <(pick_disk_part)
    fi

    sudo efibootmgr --unicode --disk "$ESP_DISK" --part "$ESP_PART" --create \
      --label "Shim" --loader '\EFI\BOOT\BOOTx64.EFI'
  fi
}

sign_kernel_and_grub_with_mok() {
  local esp="$1"
  say "Sign kernel + GRUB EFI binaries with a Machine Owner Key (MOK)"
  confirm "Install sbsigntools + openssl?" 0 && yay_install sbsigntools openssl

  read -r -p "Where should MOK keys live? (default: /etc/secureboot/mok): " mok_dir
  mok_dir="${mok_dir:-/etc/secureboot/mok}"

  if confirm "Create (or reuse) MOK keys in $mok_dir ?" 0; then
    mk_mok_keys "$mok_dir"
  fi

  local MOK_KEY="$mok_dir/MOK.key"
  local MOK_CRT="$mok_dir/MOK.crt"
  local MOK_CER="$mok_dir/MOK.cer"
  [[ -f "$MOK_KEY" && -f "$MOK_CRT" && -f "$MOK_CER" ]] || die "Missing MOK files in $mok_dir"

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
    grub_efi="$(choose_grub_efi "$esp")" || die "Couldn't find grubx64.efi on ESP."
    say "Selected GRUB EFI: $grub_efi"
    sign_in_place "$MOK_KEY" "$MOK_CRT" "$grub_efi"
  else
    warn "Skipping GRUB signing in this step."
    warn "If you want to sign manually later, run option 4 again or use option 6 (GRUB reinstall + signing)."
  fi

  say "Copy MOK.cer to ESP so MokManager can enroll it from disk"
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

reinstall_grub_with_modules_and_sign() {
  local esp="$1"
  say "Reinstall GRUB with GRUB_MODULES and sbat.csv, then sign + copy to fallback"
  confirm "Install grub + sbsigntools?" 0 && yay_install grub sbsigntools

  [[ -f /usr/share/grub/sbat.csv ]] || warn "Missing /usr/share/grub/sbat.csv (grub package should provide it)."

  read -r -p "GRUB bootloader-id (default: GRUB): " grub_id
  grub_id="${grub_id:-GRUB}"

  local modules_norm="$(printf '%s' "$GRUB_MODULES" | tr '\n\t' '  ' | xargs)"

  warn "About to run grub-install with a large module list (GRUB_MODULES) and sbat.csv."
  if confirm "Run grub-install now?" 1; then
    sudo grub-install --target=x86_64-efi --efi-directory="$esp" --bootloader-id="$grub_id" --modules="$modules_norm" --sbat /usr/share/grub/sbat.csv
    say "grub-install completed."
  fi

  # Ask for MOK location to sign grub
  read -r -p "Enter full path to MOK.key for signing GRUB (or blank to skip signing): " MOK_KEY
  if [[ -n "${MOK_KEY:-}" ]]; then
    read -r -p "Enter full path to MOK.crt for signing GRUB: " MOK_CRT
    [[ -f "$MOK_KEY" ]] || die "Key not found: $MOK_KEY"
    [[ -f "$MOK_CRT" ]] || die "Cert not found: $MOK_CRT"

    local grub_efi
    grub_efi="$(choose_grub_efi "$esp")" || die "Couldn't find grubx64.efi on ESP after grub-install."
    say "Using GRUB EFI: $grub_efi"
    local fallback_dir="$esp/EFI/BOOT"
    local fallback_grub="$fallback_dir/grubx64.efi"

    [[ -f "$grub_efi" ]] || die "Expected GRUB EFI not found: $grub_efi"

    if confirm "Sign $grub_efi in-place with sbsign?" 1; then
      sign_in_place "$MOK_KEY" "$MOK_CRT" "$grub_efi"
    fi

    if confirm "Copy signed GRUB to fallback path ($fallback_grub)?" 0; then
      sudo mkdir -p "$fallback_dir"
      backup_file "$fallback_grub" "$fallback_dir/backup"
      sudo cp -f "$grub_efi" "$fallback_grub"
      say "Copied to fallback: $fallback_grub"
    fi
  else
    warn "Skipping GRUB signing because you didn't provide MOK.key."
  fi
}

final_instructions() {
  cat <<'TXT'

Next manual steps (cannot be scripted safely):

1) Reboot and enable Secure Boot in firmware if needed.

2) If shim does not find the certificate that grubx64.efi is signed with in MokList,
   it will launch MokManager (mmx64.efi).

   In MokManager:
     - "Enroll key from disk"
     - find MOK.cer on the ESP (often at \MOK.cer or \EFI\BOOT\MOK.cer)
     - enroll it to MokList
     - Continue boot

3) Reboot again; Secure Boot should be working.

Tip: If you want GRUB_MODULES available in your current shell, run:
  source ./sb-install/env.sh

TXT
}

main() {
  show_intro

  need_cmd bash
  sudo_once

  # Options
  say "Choose what to run:"
  echo "  1) Install packages only"
  echo "  2) sbctl flow (keys/enroll/verify/sign)"
  echo "  3) Shim + MokManager copy + NVRAM entry"
  echo "  4) Create MOK + sign kernel/GRUB + copy MOK.cer to ESP"
  echo "  5) Install mkinitcpio post hook (/etc/initcpio/post/kernel-sbsign)"
  echo "  6) Reinstall GRUB with GRUB_MODULES + sbat.csv + sign/copy fallback"
  echo "  7) Run a typical full sequence (3 -> 4 -> 5 -> 6), with prompts"
  echo

  read -r -p "Enter selection (1-7): " sel
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
      install_mkinitcpio_hook
      ;;
    6)
      esp="$(get_esp_or_ask)"
      reinstall_grub_with_modules_and_sign "$esp"
      ;;
    7)
      esp="$(get_esp_or_ask)"
      setup_shim_and_mokmanager "$esp"
      sign_kernel_and_grub_with_mok "$esp"
      install_mkinitcpio_hook
      reinstall_grub_with_modules_and_sign "$esp"
      ;;
    *)
      die "Invalid selection."
      ;;
  esac

  final_instructions
}

main "$@"
