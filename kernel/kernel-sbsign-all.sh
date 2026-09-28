#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[kernel-sbsign] $*"; }
warn(){ echo "[kernel-sbsign][WARN] $*" >&2; }

[[ "$(id -u)" -eq 0 ]] || { warn "Run as root"; exit 1; }

CONF="/etc/secureboot/grub-standalone.conf"
[[ -r "$CONF" ]] || { warn "Missing $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

: "${MOK_KEY:?missing MOK_KEY in conf}"
: "${MOK_CRT:?missing MOK_CRT in conf}"

command -v sbsign   >/dev/null 2>&1 || { warn "Missing sbsign (sbsigntools)"; exit 1; }
command -v sbverify >/dev/null 2>&1 || { warn "Missing sbverify (sbsigntools)"; exit 1; }

[[ -s "$MOK_KEY" && -r "$MOK_KEY" && -s "$MOK_CRT" && -r "$MOK_CRT" ]] || { warn "Can't read MOK key/cert"; exit 1; }

BACKUP_DIR="/var/lib/secureboot/kernel-sbsign/backups"
mkdir -p "$BACKUP_DIR"
BACKUP_KEEP="${SB_BACKUP_KEEP:-5}"

backup_kernel() {
  local k="$1"
  local base ts run_id backup meta
  base="$(basename "$k")"
  ts="$(date -u +%Y%m%d-%H%M%S)"
  run_id="${SB_INSTALL_RUN_ID:-${ts}-$$}"
  backup="$BACKUP_DIR/${base}.sb-install.${ts}.bak"
  meta="${backup}.meta"

  cp -f "$k" "$backup"
  cat > "$meta" <<EOF
created_by=sb-install
source_path=$k
backup_time=$ts
run_id=$run_id
EOF
  prune_backups "$base" "$BACKUP_KEEP"
}

prune_backups() {
  local base="$1"
  local keep="${2:-5}"
  local -a files=()
  local f

  [[ "$keep" =~ ^[0-9]+$ ]] || return 0

  shopt -s nullglob
  for f in "$BACKUP_DIR/${base}.sb-install."*.bak; do
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

sign_one() {
  local k="$1"
  [[ -f "$k" && -s "$k" && -r "$k" ]] || { warn "Unusable kernel image: $k"; return 1; }

  # already good? skip.
  if sbverify --cert "$MOK_CRT" "$k" >/dev/null 2>&1; then
    log "OK (already signed): $k"
    return 0
  fi

  log "Signing: $k"
  TMP="$(mktemp "${k}.signed.XXXXXX")"
  local tmp="$TMP"
  sbsign --key "$MOK_KEY" --cert "$MOK_CRT" --output "$tmp" "$k"
  test -s "$tmp" || { rm -f "$tmp"; warn "sbsign produced empty output for $k"; return 1; }

  sbverify --cert "$MOK_CRT" "$tmp" || { warn "Signed kernel verification failed: $k"; return 1; }
  chmod --reference="$k" "$tmp"
  backup_kernel "$k"
  mv -f "$tmp" "$k"
  TMP=""
  log "Signed OK: $k"
}

TMP=""
trap '[[ -z "$TMP" ]] || rm -f -- "$TMP"' EXIT

# Sign all kernel images present in /boot
COUNT=0
for k in /boot/vmlinuz-*; do
  [[ -e "$k" ]] || continue
  sign_one "$k"
  COUNT=$((COUNT+1))
done

if (( COUNT == 0 )); then
  warn "Skipped: no /boot/vmlinuz-* kernel images found"
  exit 1
fi
log "Verified $COUNT kernel image(s)."
