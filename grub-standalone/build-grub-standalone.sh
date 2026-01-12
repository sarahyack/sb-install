#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[grub-standalone] $*"; }
warn(){ echo "[grub-standalone][WARN] $*" >&2; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { warn "Run as root (sudo)"; exit 1; }

LOCK="/run/grub-standalone-rebuild.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  warn "Another standalone GRUB rebuild is already running; exiting."
  exit 0
fi

CONF="/etc/secureboot/grub-standalone.conf"
[[ -r "$CONF" ]] || { warn "Missing $CONF (not installed). Skipping."; exit 0; }
# shellcheck source=/dev/null
. "$CONF"

: "${ESP_MOUNT:?missing ESP_MOUNT in conf}"
: "${ESP_DEV:?missing ESP_DEV in conf}"
: "${GRUB_ID:=GRUB}"
: "${MOK_KEY:=/etc/secureboot/mok/MOK.key}"
: "${MOK_CRT:=/etc/secureboot/mok/MOK.crt}"
: "${MODULES:=}"
: "${THEME_DIR:=}"
: "${THEME_NAME:=starfield}"
: "${SPLASH_SRC:=}"

# best-effort mount
if ! mountpoint -q "$ESP_MOUNT"; then
  log "ESP not mounted at $ESP_MOUNT; attempting mount $ESP_DEV -> $ESP_MOUNT"
  mkdir -p "$ESP_MOUNT" || true
  if ! mount "$ESP_DEV" "$ESP_MOUNT" 2>/dev/null; then
    warn "Could not mount ESP. Skipping rebuild."
    exit 0
  fi
fi

# sanity
if [[ ! -r "$MOK_KEY" || ! -r "$MOK_CRT" ]]; then
  warn "MOK key/cert not readable: $MOK_KEY / $MOK_CRT. Skipping."
  exit 0
fi
command -v grub-mkconfig >/dev/null 2>&1 || { warn "Missing grub-mkconfig"; exit 0; }
command -v grub-mkstandalone >/dev/null 2>&1 || { warn "Missing grub-mkstandalone"; exit 0; }
command -v sbsign >/dev/null 2>&1 || { warn "Missing sbsign (sbsigntools)"; exit 0; }

SBAT="/usr/share/grub/sbat.csv"
if [[ ! -r "$SBAT" ]]; then
  warn "Missing $SBAT; continuing anyway (some setups require it)."
  SBAT=""
fi

WORK_BASE="/var/lib/secureboot/grub-standalone"
mkdir -p "$WORK_BASE"
WORK="$(mktemp -d "$WORK_BASE/.work.XXXXXX")"
cleanup(){ rm -rf "$WORK" || true; }
trap cleanup EXIT

backup_to_dir() {
  local src="$1" bdir="$2"
  [[ -e "$src" ]] || return 0
  local base ts run_id backup latest meta
  base="$(basename "$src")"
  ts="$(date -u +%Y%m%d-%H%M%S)"
  run_id="${SB_INSTALL_RUN_ID:-${ts}-$$}"
  backup="$bdir/${base}.sb-install.${ts}.bak"
  latest="$bdir/${base}.bak"
  meta="${backup}.meta"
  mkdir -p "$bdir"
  cp -f "$src" "$backup"
  cp -f "$src" "$latest"
  cat > "$meta" <<EOF
created_by=sb-install
source_path=$src
backup_time=$ts
run_id=$run_id
EOF
  cat > "${latest}.meta" <<EOF
created_by=sb-install
source_path=$src
backup_time=$ts
run_id=$run_id
EOF
  prune_backups "$bdir" "$base" "${SB_BACKUP_KEEP:-5}"
}

prune_backups() {
  local backup_dir="$1"
  local base="$2"
  local keep="${3:-5}"
  local -a files=()
  local f

  [[ "$keep" =~ ^[0-9]+$ ]] || return 0

  shopt -s nullglob
  for f in "$backup_dir/${base}.sb-install."*.bak; do
    files+=("$f")
  done
  shopt -u nullglob

  (( ${#files[@]} <= keep )) && return 0

  local -a sorted=()
  mapfile -t sorted < <(printf '%s\n' "${files[@]}" | sort)
  local remove_count=$(( ${#sorted[@]} - keep ))
  local i
  for ((i=0; i<remove_count; i++)); do
    rm -f "${sorted[$i]}" "${sorted[$i]}.meta"
  done
}

backup_esp_binary() {
  local target="$1"
  # root-side backups (keeps lots)
  backup_to_dir "$target" "$WORK_BASE/backups"

  # esp-side backups (keep minimal, but useful from live ISO)
  local esp_bdir
  esp_bdir="$(dirname "$target")/backup"
  backup_to_dir "$target" "$esp_bdir"
}

RAW="$WORK/grub.cfg.raw"
PATCHED="$WORK/grub.cfg.patched"

log "Generating grub.cfg -> $RAW"
grub-mkconfig -o "$RAW" >/dev/null

cp -f "$RAW" "$PATCHED"

# ---- PATCHES (make the embedded assets actually be used) ----
# 1) Font: replace any unicode.pf2 file path with built-in "unicode"
#    (so "loadfont $font" becomes "loadfont unicode")
sed -Ei 's|font="[^"]*unicode\.pf2"|font=unicode|g' "$PATCHED"

# 2) Theme path: force it into embedded /boot/grub/themes/<name>/theme.txt if we have a theme dir
if [[ -n "$THEME_DIR" && -d "$THEME_DIR" ]]; then
    sed -Ei "s|set theme=\"[^\"]*\"|set theme=\"(memdisk)/boot/grub/themes/${THEME_NAME}/theme.txt\"|g" "$PATCHED"
fi

# 3) Background image: if you provide SPLASH_SRC, force background_image to embedded /boot/grub/splash.png
if [[ -n "$SPLASH_SRC" && -r "$SPLASH_SRC" ]]; then
  # replaces any background_image ... "something.png" with our embedded splash
  sed -Ei 's|^([[:space:]]*background_image[[:space:]].*)\"[^\"]+\"|\1"(memdisk)/boot/grub/splash.png"|g' "$PATCHED"
fi

# 4) Ensure prefix points to memdisk so /boot/grub/... resolves to embedded files early
PRE="$WORK/preamble.cfg"
cat > "$PRE" <<'EOF'
# Embedded standalone preamble
# Force embedded assets first. grub.cfg can still change prefix later if it wants.
set prefix=(memdisk)/boot/grub
export prefix
EOF

FINAL_CFG="$WORK/grub.cfg"
cat "$PRE" "$PATCHED" > "$FINAL_CFG"

# ---- GRAFT POINTS: embed config + assets into the EFI ----
declare -a grafts
grafts+=("boot/grub/grub.cfg=$FINAL_CFG")

# embed splash
if [[ -n "$SPLASH_SRC" && -r "$SPLASH_SRC" ]]; then
  grafts+=("boot/grub/splash.png=$SPLASH_SRC")
fi

# embed theme directory contents
if [[ -n "$THEME_DIR" && -d "$THEME_DIR" ]]; then
  while IFS= read -r -d '' f; do
    rel="${f#"$THEME_DIR"/}"
    grafts+=("boot/grub/themes/$THEME_NAME/$rel=$f")
  done < <(find "$THEME_DIR" -type f -print0)
fi

# directory for GRUB platform modules
GRUBDIR="$(grub-install --print-directory 2>/dev/null || true)"
if [[ -z "$GRUBDIR" ]]; then
  GRUBDIR="/usr/lib/grub/x86_64-efi"
fi

UNSIGNED="$WORK/grubx64.efi.unsigned"
SIGNED="$WORK/grubx64.efi"

log "Building standalone GRUB EFI (unsigned)"
args=(--directory "$GRUBDIR"
      --format x86_64-efi
      --output "$UNSIGNED"
      --modules "$MODULES"
      --fonts unicode)

if [[ -n "$SBAT" ]]; then
  args+=(--sbat "$SBAT")
fi

# NOTE: graft syntax is accepted as positional args (see manpage “Graft point syntax”)
grub-mkstandalone "${args[@]}" "${grafts[@]}"

log "Signing standalone GRUB EFI"
sbsign --key "$MOK_KEY" --cert "$MOK_CRT" --output "$SIGNED" "$UNSIGNED"

# install to ESP vendor path + fallback path
VENDOR="$ESP_MOUNT/EFI/$GRUB_ID/grubx64.efi"
FALLDIR="$ESP_MOUNT/EFI/BOOT"
FALL="$FALLDIR/grubx64.efi"

log "Backing up existing ESP binaries (if present)"
backup_esp_binary "$VENDOR"
backup_esp_binary "$FALL"

log "Installing to: $VENDOR"
mkdir -p "$(dirname "$VENDOR")"
cp -f "$SIGNED" "$VENDOR"

log "Installing fallback to: $FALL"
mkdir -p "$FALLDIR"
cp -f "$SIGNED" "$FALL"

log "Done."
exit 0
