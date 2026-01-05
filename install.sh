#!/usr/bin/env bash

set -euo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "[ERR] Do not run this script as root. Run it as your normal user; it will use sudo when needed."
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOOK_TEMPLATE="$SCRIPT_DIR/mkinitcpio-hook.sh"
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
    sudo cp -f "$path" "$backup_dir/${base}.$(date +%Y%m%d-%H%M%S).bak"
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
    echo "Multiple VFAT mounts detected (possible ESPs):" >&2
    local i
    for i in "${!mps[@]}"; do
      echo "  $((i+1))) ${mps[$i]}" >&2
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
    [[ -n "$esp" ]] || return 1
    printf "\n==> Detected ESP mount: %s\n" "$esp" >&2
    printf '%s\n' "$esp"
    return 0
  fi

  printf "Couldn't auto-detect a mounted ESP.\n" >&2
  printf "Try: lsblk -f  OR  findmnt -t vfat\n" >&2
  read -r -p "Enter your mounted ESP path (example: /boot/efi or /efi): " esp
  [[ -d "$esp" ]] || return 1
  printf '%s\n' "$esp"
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
  if [[ "$dev" == UUID=* ]]; then
    local uuid="${dev#UUID=}"
    dev="$(blkid -U "$uuid" 2>/dev/null || true)"
  fi
  dev="$(readlink -f -- "$dev" 2>/dev/null || printf '%s' "$dev")"
  [[ -b "$dev" ]] || return 1

  diskpart="$(disk_part_from_device "$dev")" || return 1
  printf "\n==> ESP device: %s -> disk/part: %s\n" "$dev" "${diskpart/|/ }" >&2
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

  # Search the whole ESP for likely GRUB EFI binaries.
  # Prefer exact grubx64.efi/grub.efi, but allow *grub*.efi too.
  sudo find "$esp" -maxdepth 6 -type f \( \
      -iname 'grubx64.efi' -o -iname 'grub.efi' -o -iname '*grub*.efi' \
    \) 2>/dev/null \
    | grep -viE '/(shimx64|mmx64|fbx64|bootx64)\.efi$' \
    | sort -u || true
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
    echo "Multiple grubx64.efi candidates found:" >&2
    local i
    for i in "${!cands[@]}"; do
      echo "  $((i+1))) ${cands[$i]}" >&2
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

  # Existence/readability checks that work with root-only dirs
  sudo test -r "$key"   || die "Can't read key (need sudo?): $key"
  sudo test -r "$cert"  || die "Can't read cert (need sudo?): $cert"
  sudo test -f "$target"|| die "Target not found: $target"

  local dir base ts tmp bak
  dir="$(dirname -- "$target")"
  base="$(basename -- "$target")"
  ts="$(date +%Y%m%d-%H%M%S)"

  # Temp file on SAME filesystem as target (ESP-safe)
  tmp="$(sudo mktemp --tmpdir="$dir" ".${base}.sbsign.${ts}.XXXXXX")" \
    || die "mktemp failed in $dir"
  bak="${dir}/${base}.presign.${ts}.bak"

  say "Signing: $target"
  sudo sbsign --key "$key" --cert "$cert" --output "$tmp" "$target"

  # HARD SAFETY CHECKS so we never clobber target with junk/empty
  sudo test -s "$tmp" || { sudo rm -f "$tmp"; die "sbsign produced empty output for $target"; }

  # sbverify is part of sbsigntools; confirms PE/COFF signature structure
  if ! sudo sbverify --list "$tmp" >/dev/null 2>&1; then
    sudo rm -f "$tmp"
    die "Signed output doesn't look like a PE/COFF EFI binary (sbverify failed): $target"
  fi

  # Backup without -a (VFAT doesn't do ownership properly)
  sudo cp -f "$target" "$bak" || warn "Backup failed: $bak"

  # Atomic-ish replace (rename within same dir/filesystem)
  sudo mv -f "$tmp" "$target"
}

extract_sbctl_paths() {
  # Attempt to extract paths from `sbctl verify` output
  # Common formats include lines containing absolute paths; we grab /something tokens
  sed -nE 's/.*(\/[^[:space:]]+).*/\1/p' | sort -u
}

cert_fpr_sha256() {
  # Prints SHA256 fingerprint with no colons (portable for comparisons)
  # Works for PEM (.crt) and DER (.cer).
  local path="$1"
  local inform="PEM"
  [[ "$path" =~ \.cer$ ]] && inform="DER"
  sudo openssl x509 -inform "$inform" -in "$path" -noout -fingerprint -sha256 2>/dev/null \
    | sed -E 's/^.*=//; s/://g'
}

show_mok_fingerprint_report() {
  # Shows fingerprints for the "base" (mok_dir) and any ESP copies,
  # and prints a recommendation about overwriting.
  local mok_dir="$1"
  local esp="${2:-}"

  local crt="$mok_dir/MOK.crt"
  local cer="$mok_dir/MOK.cer"

  say "MOK fingerprint check (SHA256)"
  if sudo test -f "$crt"; then
    echo "  Base CRT: $crt"
    echo "    -> $(cert_fpr_sha256 "$crt" || echo "unreadable")"
  else
    echo "  Base CRT: (missing) $crt"
  fi

  if sudo test -f "$cer"; then
    echo "  Base CER: $cer"
    echo "    -> $(cert_fpr_sha256 "$cer" || echo "unreadable")"
  else
    echo "  Base CER: (missing) $cer"
  fi

  # Compare base crt vs base cer (they SHOULD match)
  if sudo test -f "$crt" && sudo test -f "$cer"; then
    local f_crt f_cer
    f_crt="$(cert_fpr_sha256 "$crt" || true)"
    f_cer="$(cert_fpr_sha256 "$cer" || true)"
    if [[ -n "$f_crt" && -n "$f_cer" && "$f_crt" == "$f_cer" ]]; then
      echo "  Base CRT vs CER: MATCH ✅"
    else
      echo "  Base CRT vs CER: MISMATCH ❌ (this is a red flag)"
    fi
  fi

  # ESP copies (optional)
  if [[ -n "${esp:-}" && -d "$esp" ]]; then
    local esp_root="$esp/MOK.cer"
    local esp_boot="$esp/EFI/BOOT/MOK.cer"

    if sudo test -f "$esp_root"; then
      echo "  ESP copy : $esp_root"
      echo "    -> $(cert_fpr_sha256 "$esp_root" || echo "unreadable")"
    fi
    if sudo test -f "$esp_boot"; then
      echo "  ESP copy : $esp_boot"
      echo "    -> $(cert_fpr_sha256 "$esp_boot" || echo "unreadable")"
    fi

    # Recommend overwrite behavior if we can compare
    if sudo test -f "$cer" && sudo test -f "$esp_root"; then
      local f_base f_esp
      f_base="$(cert_fpr_sha256 "$cer" || true)"
      f_esp="$(cert_fpr_sha256 "$esp_root" || true)"
      if [[ -n "$f_base" && -n "$f_esp" && "$f_base" == "$f_esp" ]]; then
        echo
        echo "  Recommendation: ESP MOK.cer MATCHES your base MOK.cer ✅"
        echo "  -> Do NOT overwrite keys. Answer NO to overwrite prompts."
      else
        echo
        echo "  Recommendation: ESP MOK.cer DOES NOT match base MOK.cer ❌"
        echo "  -> If you overwrite keys, you MUST copy the NEW MOK.cer to the ESP and enroll THAT one."
      fi
    fi
  fi
}

choose_bootnum_from_list() {
  local -a nums=("$@")
  if (( ${#nums[@]} == 0 )); then
    return 1
  elif (( ${#nums[@]} == 1 )); then
    printf '%s\n' "${nums[0]}"
    return 0
  else
    echo "Multiple matching boot entries found:" >&2
    local i
    for i in "${!nums[@]}"; do
      echo "  $((i+1))) Boot${nums[$i]}" >&2
    done
    read -r -p "Pick which one to use (number): " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || return 2
    (( choice >= 1 && choice <= ${#nums[@]} )) || return 2
    printf '%s\n' "${nums[$((choice-1))]}"
    return 0
  fi
}

bootnums_for_label_and_loader() {
  local label="$1"
  local loader_substr="$2"

  local lbl_lc ldr_lc
  lbl_lc="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
  ldr_lc="$(printf '%s' "$loader_substr" | tr '[:upper:]' '[:lower:]')"

  sudo efibootmgr 2>/dev/null | awk -v lbl="$lbl_lc" -v ldr="$ldr_lc" '
    $1 ~ /^Boot[0-9A-Fa-f]{4}\*?$/ {
      line=tolower($0)
      if (index(line, lbl) && index(line, ldr)) {
        b=$1
        sub(/^Boot/,"",b); sub(/\*$/,"",b)
        print toupper(b)
      }
    }'
}

choose_highest_bootnum() {
  # Picks “newest-ish” by highest Boot#### (efibootmgr allocates increasing numbers)
  local -a nums=("$@")
  ((${#nums[@]}==0)) && return 1
  printf '%s\n' "${nums[@]}" | tr '[:lower:]' '[:upper:]' | sort | tail -n1
}

set_bootnext() {
  local bootnum="$1"
  sudo efibootmgr -n "$bootnum"
  say "BootNext set: next reboot will try Boot$bootnum (one-time)."
}

set_bootorder_shim_first() {
  local bootnum="$1"
  local cur
  cur="$(sudo efibootmgr | awk -F': ' '/^BootOrder:/ {print $2; exit}')"
  [[ -n "$cur" ]] || die "Couldn't read current BootOrder."

  IFS=',' read -r -a arr <<< "$cur"
  local -a new=("$bootnum")
  local x
  for x in "${arr[@]}"; do
    [[ "$x" == "$bootnum" ]] && continue
    new+=("$x")
  done

  sudo efibootmgr -o "$(IFS=,; echo "${new[*]}")"
  say "BootOrder updated: Shim entry Boot$bootnum moved to the front."
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
  printf "\n==> efibootmgr needs the disk + partition number for the ESP. \n" >&2
  printf "Helpful commands:\n" >&2
  printf "  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,PARTUUID\n" >&2
  printf "  sudo fdisk -l\n\n" >&2
  
  read -r -p "Enter ESP disk (example: /dev/nvme0n1 or /dev/sda): " ESP_DISK
  read -r -p "Enter ESP partition number (example: 1): " ESP_PART
  [[ -b "$ESP_DISK" ]] || die "Not a block device: $ESP_DISK"
  [[ "$ESP_PART" =~ ^[0-9]+$ ]] || die "Partition must be a number."
  echo "$ESP_DISK|$ESP_PART"
}

mk_mok_keys() {
  local mok_dir="$1"
  local esp="${2:-}"

  say "Creating Machine Owner Key (RSA 2048) in: $mok_dir"
  sudo mkdir -p "$mok_dir"
  sudo chmod 700 "$mok_dir"

  # If keys exist, show fingerprints BEFORE asking about overwrite
  if [[ -f "$mok_dir/MOK.key" || -f "$mok_dir/MOK.crt" || -f "$mok_dir/MOK.cer" ]]; then
    warn "MOK.* already exists in $mok_dir"
    show_mok_fingerprint_report "$mok_dir" "$esp"
    echo
    echo "If the fingerprints match what you expect/enrolled, you should NOT overwrite."
    echo "Overwriting means you'll need to enroll the NEW MOK.cer in MokManager."
    echo

    # Default should be NO (safer)
    confirm "Overwrite existing MOK.* files in $mok_dir ?" 1 || { say "Keeping existing keys."; return 0; }
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
  show_mok_fingerprint_report "$mok_dir" "$esp"
}

install_mkinitcpio_hook() {
  [[ -f "$HOOK_TEMPLATE" ]] || die "Missing template: $HOOK_TEMPLATE"

  say "Installing mkinitcpio post hook to /etc/initcpio/post/kernel-sbsign"
  sudo mkdir -p /etc/initcpio/post
  sudo cp -f "$HOOK_TEMPLATE" /etc/initcpio/post/kernel-sbsign
  sudo chmod +x /etc/initcpio/post/kernel-sbsign

  warn "The installed hook still contains placeholder paths (/path/to/MOK.key /path/to/MOK.crt)."
  if confirm "Do you want me to replace those placeholders now?" 0; then
    local default_key="/etc/secureboot/mok/MOK.key"
    local default_crt="/etc/secureboot/mok/MOK.crt"
    local KEY_PATH CRT_PATH

    read -r -p "Enter full path to MOK.key (example: /etc/secureboot/mok/MOK.key): " KEY_PATH
    KEY_PATH="${KEY_PATH:-$default_key}"
    read -r -p "Enter full path to MOK.crt (example: /etc/secureboot/mok/MOK.crt): " CRT_PATH
    CRT_PATH="${CRT_PATH:-$default_crt}"

    sudo test -f "$KEY_PATH" || die "Key not found: $KEY_PATH"
    sudo test -f "$CRT_PATH" || die "Cert not found: $CRT_PATH"

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

    # Prefer reusing an existing Shim entry that points at the correct loader
    local loader_path='File(\EFI\BOOT\BOOTX64.EFI)'
    local -a nums=()
    mapfile -t nums < <(bootnums_for_label_and_loader "Shim" "$loader_path" || true)

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
      mapfile -t nums < <(bootnums_for_label_and_loader "Shim" "$loader_path" || true)
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
    grub_efi="$(choose_grub_efi "$esp" 2>/dev/null)" || true
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

reinstall_grub_with_modules_and_sign() {
  local esp="$1"
  say "Reinstall GRUB with GRUB_MODULES and sbat.csv, then sign + copy to fallback"

  confirm "Install grub + sbsigntools?" 0 && yay_install grub sbsigntools

  [[ -f /usr/share/grub/sbat.csv ]] || warn "Missing /usr/share/grub/sbat.csv (grub package should provide it)."

  read -r -p "GRUB bootloader-id (default: GRUB): " grub_id
  grub_id="${grub_id:-GRUB}"

  local modules_norm
  modules_norm="$(printf '%s' "$GRUB_MODULES" | tr '\n\t' '  ' | xargs)"

  warn "About to run grub-install with a large module list (GRUB_MODULES) and sbat.csv."
  if confirm "Run grub-install now?" 1; then
    sudo grub-install \
      --target=x86_64-efi \
      --efi-directory="$esp" \
      --bootloader-id="$grub_id" \
      --modules="$modules_norm" \
      --sbat /usr/share/grub/sbat.csv
    say "grub-install completed."
  fi

  # Paths we care about (vendor + fallback)
  local grub_efi_expected="$esp/EFI/$grub_id/grubx64.efi"
  local fallback_dir="$esp/EFI/BOOT"
  local fallback_grub="$fallback_dir/grubx64.efi"
  local fallback_grub_uc="$fallback_dir/GRUBX64.EFI"

  # Ask for MOK location to sign grub
  read -r -p "Enter full path to MOK.key for signing GRUB (or blank to skip signing): " MOK_KEY
  if [[ -z "${MOK_KEY:-}" ]]; then
    warn "Skipping GRUB signing because you didn't provide MOK.key."
    return 0
  fi

  read -r -p "Enter full path to MOK.crt for signing GRUB: " MOK_CRT
  sudo test -f "$MOK_KEY" || die "Key not found: $MOK_KEY"
  sudo test -f "$MOK_CRT" || die "Cert not found: $MOK_CRT"

  # Prefer the known installed path; only fallback to search if it's missing
  local grub_efi="$grub_efi_expected"
  if ! sudo test -f "$grub_efi"; then
    warn "Expected $grub_efi_expected not found; falling back to searching the ESP."
    grub_efi="$(choose_grub_efi "$esp")" || die "Couldn't find a GRUB EFI binary on ESP."
  fi
  sudo test -f "$grub_efi" || die "GRUB EFI not found: $grub_efi"

  say "Using GRUB EFI: $grub_efi"

  if confirm "Sign this GRUB EFI in-place with sbsign?" 1; then
    sign_in_place "$MOK_KEY" "$MOK_CRT" "$grub_efi"
    say "Signature check (vendor GRUB):"
    sudo sbverify --list "$grub_efi" || warn "sbverify failed on $grub_efi"
  else
    warn "You chose not to sign vendor GRUB. Secure Boot will almost certainly fail unless it's already signed/trusted."
  fi

  # Copy to fallback (this is what shim-in-BOOT usually chains to)
  if confirm "Copy the (signed) GRUB to fallback path ($fallback_grub)?" 0; then
    sudo mkdir -p "$fallback_dir"
    backup_file "$fallback_grub" "$fallback_dir/backup"
    sudo cp -f "$grub_efi" "$fallback_grub"
    say "Copied to fallback: $fallback_grub"

    # Optional: also create uppercase twin (harmless, sometimes reduces confusion)
    if confirm "Also copy to ($fallback_grub_uc) as a duplicate?" 1; then
      backup_file "$fallback_grub_uc" "$fallback_dir/backup"
      sudo cp -f "$grub_efi" "$fallback_grub_uc"
      say "Copied to fallback (uppercase): $fallback_grub_uc"
    fi

    say "Signature check (fallback GRUB):"
    sudo sbverify --list "$fallback_grub" || warn "sbverify failed on $fallback_grub"
  fi

  warn "Reminder: your firmware must boot the Shim entry first (or BootNext=Shim)."
  echo "Check quickly with:"
  echo "  sudo efibootmgr -v"
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
