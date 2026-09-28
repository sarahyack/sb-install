#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[grub-standalone] $*"; }
warn(){ echo "[grub-standalone][WARN] $*" >&2; }

die(){ warn "$*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root (sudo)"
export LC_ALL=C
for tool in flock mountpoint mount grub-mkconfig grub-mkstandalone sbsign sbverify objcopy awk od tr sort cmp diff readlink grep; do
  command -v "$tool" >/dev/null 2>&1 || die "Missing required command: $tool"
done
COMPAT="/usr/local/lib/sb-install/grub-compat.sh"
[[ -r "$COMPAT" ]] || die "Missing $COMPAT; reinstall helpers with install.sh option 5"
# shellcheck source=lib/grub-compat.sh
source "$COMPAT"

LOCK="/run/grub-standalone-rebuild.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  warn "Skipped: another standalone GRUB rebuild is running; retry refresh after it finishes."
  exit 75
fi

CONF="/etc/secureboot/grub-standalone.conf"
[[ -r "$CONF" ]] || die "Missing $CONF (not installed)"
# shellcheck source=/dev/null
. "$CONF"

: "${ESP_MOUNT:?missing ESP_MOUNT in conf}"
: "${ESP_DEV:?missing ESP_DEV in conf}"
: "${GRUB_ID:?missing GRUB_ID in conf}"
: "${MOK_KEY:?missing MOK_KEY in conf}"
: "${MOK_CRT:?missing MOK_CRT in conf}"
: "${MODULES:=}"
: "${THEME_DIR:=}"
: "${THEME_NAME:=starfield}"
: "${SPLASH_SRC:=}"
[[ "$GRUB_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid GRUB_ID: $GRUB_ID"
[[ -s "$MOK_KEY" && -r "$MOK_KEY" && -s "$MOK_CRT" && -r "$MOK_CRT" ]] || die "MOK key/cert missing, empty or unreadable: $MOK_KEY / $MOK_CRT"

# Resolve the platform BEFORE either module filtering or SBAT selection.
GRUBDIR="$(grub_platform_dir)" || die "Cannot resolve GRUB platform directory"
log "GRUB module directory: $GRUBDIR"
MODULES="$(grub_effective_modules "$GRUBDIR" "$MODULES")" || die "Module preflight failed"

if ! mountpoint -q "$ESP_MOUNT"; then
  log "ESP not mounted at $ESP_MOUNT; attempting mount $ESP_DEV -> $ESP_MOUNT"
  mkdir -p "$ESP_MOUNT"
  mount "$ESP_DEV" "$ESP_MOUNT" || die "Could not mount ESP"
fi
mountpoint -q "$ESP_MOUNT" && [[ -d "$ESP_MOUNT" && -w "$ESP_MOUNT" ]] || die "ESP is not mounted/writable: $ESP_MOUNT"

WORK_BASE="/var/lib/secureboot/grub-standalone"
mkdir -p "$WORK_BASE"
WORK="$(mktemp -d "$WORK_BASE/.work.XXXXXX")"
declare -a destinations=() stages=() touched=()
DEPLOYING=0
cleanup() {
  local rc=$? i failed=0
  trap - EXIT
  if (( DEPLOYING )); then
    warn "Deployment failed; restoring previous GRUB files."
    for i in "${!touched[@]}"; do
      if [[ -f "${stages[i]}/old" ]]; then
        mv -f "${stages[i]}/old" "${destinations[i]}" || failed=1
      else
        rm -f "${destinations[i]}" || failed=1
      fi
    done
  fi
  if (( failed )); then
    warn "Rollback incomplete. Recovery files retained in: ${stages[*]} and $WORK_BASE/backups"
    rc=1
  else
    for i in "${stages[@]}"; do rm -rf -- "$i"; done
  fi
  rm -rf -- "$WORK"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

grub_prepare_sbat "$GRUBDIR" /usr/share/grub/sbat.csv "$WORK" || die "SBAT selection failed"
SBAT="$WORK/sbat.csv"

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

UNSIGNED="$WORK/grubx64.efi.unsigned"
SIGNED="$WORK/grubx64.efi"

log "Building standalone GRUB EFI (unsigned)"
args=(--directory "$GRUBDIR"
      --format x86_64-efi
      --output "$UNSIGNED"
      --modules "$MODULES"
      --fonts unicode)

args+=(--sbat "$SBAT")

# Preserve tool diagnostics, including warnings from otherwise successful builds.
BUILD_RC=0
grub-mkstandalone "${args[@]}" "${grafts[@]}" > "$WORK/build.log" 2>&1 || BUILD_RC=$?
cat "$WORK/build.log"
(( BUILD_RC == 0 )) || die "grub-mkstandalone failed (status $BUILD_RC)"
if grep -Eiq 'warning.*sbat|sbat.*warning|sbat.*(mismatch|does not match|do not match|generation)|(mismatch|does not match|do not match).*sbat' "$WORK/build.log"; then
  die "GRUB reported an SBAT warning/mismatch; refusing deployment"
fi
[[ -s "$UNSIGNED" ]] || die "GRUB produced an empty image"
grub_verify_sbat "$UNSIGNED" "$SBAT" "$WORK" || die "Unsigned GRUB SBAT validation failed"

log "Signing standalone GRUB EFI"
sbsign --key "$MOK_KEY" --cert "$MOK_CRT" --output "$SIGNED" "$UNSIGNED"
[[ -s "$SIGNED" ]] || die "sbsign produced an empty image"
sbverify --cert "$MOK_CRT" "$SIGNED" || die "Signed GRUB verification failed"
grub_verify_sbat "$SIGNED" "$SBAT" "$WORK" || die "Signed GRUB SBAT validation failed"

# shim owns BOOTx64.EFI. Only the vendor and fallback grubx64.efi are replaced.
VENDOR="$ESP_MOUNT/EFI/$GRUB_ID/grubx64.efi"
FALL="$ESP_MOUNT/EFI/BOOT/grubx64.efi"
destinations=("$VENDOR")
[[ "$VENDOR" == "$FALL" ]] || destinations+=("$FALL")

log "Backing up and staging verified GRUB binaries"
for i in "${!destinations[@]}"; do
  target="${destinations[i]}"
  [[ ! -L "$target" ]] || die "Refusing symlink destination: $target"
  [[ ! -e "$target" || -f "$target" ]] || die "Not a regular EFI file: $target"
  backup_esp_binary "$target"
  mkdir -p "$(dirname "$target")"
  stages[i]="$(mktemp -d "$(dirname "$target")/.grub-deploy.XXXXXX")"
  if [[ -e "$target" ]]; then
    cp "$target" "${stages[i]}/old"
    cmp -s "$target" "${stages[i]}/old" || die "Rollback copy verification failed: $target"
  fi
  cp "$SIGNED" "${stages[i]}/new"
  cmp -s "$SIGNED" "${stages[i]}/new" || die "Staged copy verification failed: $target"
done

DEPLOYING=1
for i in "${!destinations[@]}"; do
  log "Installing to: ${destinations[i]}"
  touched[i]=1
  mv -f "${stages[i]}/new" "${destinations[i]}"
  cmp -s "$SIGNED" "${destinations[i]}" || die "Installed copy verification failed: ${destinations[i]}"
done
DEPLOYING=0
log "Rebuilt, signed and verified vendor/fallback GRUB copies."
