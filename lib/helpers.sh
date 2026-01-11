#!/usr/bin/env bash
# helpers.sh - Helpers For Sb-Install

# -------------------------
# Basic I/O Helpers
# -------------------------

say() { printf "\n==> %s\n" "$*"; }
warn() { printf "\n[WARN] %s\n" "$*" >&2; }
die() { printf "\n[ERR] %s\n" "$*" >&2; exit 1; }

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

sed_escape() {
  # escape for sed replacement (delimiter '|')
  printf '%s' "$1" | sed -e 's/[\\/&|]/\\&/g'
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

read_existing_watch_dirs() {
  local conf="/etc/secureboot/grub-standalone.conf"
  sudo test -r "$conf" || return 1
  sudo awk -F= '
    $1=="WATCH_DIRS" {
      v=$2
      sub(/^"/,"",v); sub(/"$/,"",v)
      print v
      exit
    }
  ' "$conf"
}

# -------------------------
# Admin Helpers
# -------------------------

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
    sudo cp -f "$path" "$backup_dir/${base}.bak"
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

  # Temp file on SAME filesystem as target (ESP-safe)
  sudo mkdir -p "$dir/backups"
  tmp="$(sudo mktemp --tmpdir="$dir/backups" ".${base}.sbsign.${ts}.XXXXXX")" \
    || die "mktemp failed in $dir/backups"
  bak="${dir}/backups/${base}.presign.bak"

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

# -------------------------
# ESP & Disk/Part Helpers
# -------------------------

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

# -------------------------
# MOK Helpers
# -------------------------

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

# -------------------------
# Shim & Boot Helpers
# -------------------------

detect_shim_paths() {
  local shim mm
  need_cmd yay
  shim="$(yay -Ql shim-signed 2>/dev/null | awk '{print $2}' | grep -E '/shimx64\.efi$' | head -n1 || true)"
  mm="$(yay -Ql shim-signed 2>/dev/null | awk '{print $2}' | grep -E '/mmx64\.efi$' | head -n1 || true)"
  [[ -f "$shim" && -f "$mm" ]] || return 1
  printf '%s|%s\n' "$shim" "$mm"
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
  # Match BOTH a label and a token that appears in the verbose line.
  # Use a token like: "bootx64.efi" (no backslashes).
  local label="$1"
  local token="$2"

  local lbl_lc tok_lc
  lbl_lc="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
  tok_lc="$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')"

  sudo efibootmgr -v 2>/dev/null | awk -v lbl="$lbl_lc" -v tok="$tok_lc" '
    $1 ~ /^Boot[0-9A-Fa-f]{4}\*?$/ {
      line=tolower($0)
      if (index(line, lbl) && index(line, tok)) {
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

# -------------------------
# Grub/Grub EFI Helpers
# -------------------------

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

patch_grub_font_for_secureboot() {
  local f="/etc/default/grub"
  say "Patching $f to avoid disk-loaded fonts under Secure Boot (use built-in font behavior)"

  sudo test -f "$f" || die "Missing: $f"
  backup_file "$f" "/etc/default/grub.backup"

  # If GRUB_FONT exists, force it empty. If it doesn't exist, add an empty one.
  if sudo grep -Eq '^\s*GRUB_FONT=' "$f"; then
    sudo sed -i -E 's|^\s*GRUB_FONT=.*$|GRUB_FONT=|g' "$f"
  else
    echo "GRUB_FONT=" | sudo tee -a "$f" >/dev/null
  fi

  # Rebuild grub.cfg (Arch/EndeavourOS standard path)
  need_cmd grub-mkconfig
  sudo grub-mkconfig -o /boot/grub/grub.cfg
  say "Regenerated: /boot/grub/grub.cfg"
}

# -------------------------
# Snapshot & Grub-Btrfs Helpers
# -------------------------

conf_get_var_as_root() {
  # Usage: conf_get_var_as_root /path/to/conf VAR
  local conf="$1" var="$2"
  sudo bash -c "set -a; source '$conf' 2>/dev/null || true; printf '%s' \"\${$var:-}\""
}

conf_set_line_kv() {
  # Replace or append: KEY="VALUE"
  # Usage: conf_set_line_kv /path/to/conf KEY VALUE
  local conf="$1" key="$2" val="$3"
  local esc
  esc="$(sed_escape "$val")"

  if sudo grep -qE "^${key}=" "$conf"; then
    sudo sed -i -E "s|^${key}=.*$|${key}=\"${esc}\"|g" "$conf"
  else
    printf '%s\n' "${key}=\"${val}\"" | sudo tee -a "$conf" >/dev/null
  fi
}

conf_add_watch_dir() {
  # Adds a directory to WATCH_DIRS if not already present.
  # Keeps existing WATCH_DIRS if user customized it.
  local dir="$1"
  local conf="/etc/secureboot/grub-standalone.conf"
  [[ -n "$dir" ]] || return 0
  sudo test -f "$conf" || die "Missing $conf. Run the standalone install step first."

  local cur
  cur="$(conf_get_var_as_root "$conf" WATCH_DIRS)"
  if [[ -z "$cur" ]]; then
    # Use your script defaults, plus the new dir.
    cur="/etc/default /etc/grub.d /boot/grub/themes /usr/share/endeavouros"
  fi

  if [[ " $cur " == *" $dir "* ]]; then
    say "WATCH_DIRS already contains: $dir"
    return 0
  fi

  local new="${cur} ${dir}"
  conf_set_line_kv "$conf" WATCH_DIRS "$new"
  say "Added to WATCH_DIRS: $dir"
}

detect_timeshift_snapshot_dir() {
  # Best-effort detection:
  # - First try snapshot_location from /etc/timeshift/timeshift.json
  # - Then common defaults for Timeshift BTRFS mode
  local loc=""

  if sudo test -r /etc/timeshift/timeshift.json; then
    loc="$(sudo sed -nE 's/.*"snapshot_location"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' /etc/timeshift/timeshift.json | head -n1)"
  fi

  # If the config value exists and is a directory, use it
  if [[ -n "$loc" ]] && sudo test -d "$loc"; then
    printf '%s\n' "$loc"
    return 0
  fi

  # Common stable path for Timeshift BTRFS snapshots
  if sudo test -d /timeshift-btrfs/snapshots; then
    printf '%s\n' "/timeshift-btrfs/snapshots"
    return 0
  fi

  # Some systems show a stable mount created for Timeshift operations (less reliable)
  if sudo test -d /run/timeshift/backup/timeshift-btrfs/snapshots; then
    printf '%s\n' "/run/timeshift/backup/timeshift-btrfs/snapshots"
    return 0
  fi

  # If nothing exists yet, return the “expected” default (so we can watch it once it appears).
  # This keeps the setup simple, but you should tell users to configure Timeshift in BTRFS mode first.
  printf '%s\n' "/timeshift-btrfs/snapshots"
  return 0
}

ensure_snapper_root_config() {
  command -v snapper >/dev/null 2>&1 || return 1

  if sudo snapper list-configs 2>/dev/null | awk 'NR>2 {print $1}' | grep -qx root; then
    say "Snapper config 'root' already exists."
  else
    say "Creating Snapper config 'root' for /"
    sudo snapper -c root create-config /
  fi

  # Timers are optional, but are usually what people want.
  sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer >/dev/null 2>&1 || true
}

detect_snapper_snapshot_dir() {
  # Snapper snapshots live at: <SUBVOLUME>/.snapshots
  local cfg="/etc/snapper/configs/root"
  local sub="/"

  if sudo test -r "$cfg"; then
    sub="$(sudo awk -F= '/^SUBVOLUME=/{print $2; exit}' "$cfg")"
  fi

  # Trim whitespace, strip quotes
  sub="$(printf '%s' "$sub" | tr -d '"' | xargs)"
  [[ -n "$sub" ]] || sub="/"

  # Ensure it starts with exactly one leading slash
  if [[ "$sub" != /* ]]; then
    sub="/$sub"
  fi

  # Remove trailing slash unless it is the root
  if [[ "$sub" != "/" ]]; then
    sub="${sub%/}"
  fi

  local path
  if [[ "$sub" == "/" ]]; then
    path="/.snapshots"
  else
    path="${sub}/.snapshots"
  fi

  # Collapse any accidental double slashes
  path="$(printf '%s' "$path" | sed -E 's#/{2,}#/#g')"
  printf '%s\n' "$path"
}

disable_grub_btrfsd() {
  # grub-btrfs usually ships a daemon/path unit to regenerate /boot/grub/grub.cfg.
  # We do NOT want that, because we embed grub.cfg into the signed standalone EFI.
  for u in grub-btrfsd.service grub-btrfsd.path grub-btrfs.path grub-btrfs.service; do
    sudo systemctl disable --now "$u" >/dev/null 2>&1 || true
  done
}



