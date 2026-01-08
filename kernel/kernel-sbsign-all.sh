
#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[kernel-sbsign] $*"; }
warn(){ echo "[kernel-sbsign][WARN] $*" >&2; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { warn "Run as root"; exit 1; }

CONF="/etc/secureboot/grub-standalone.conf"
[[ -r "$CONF" ]] || { warn "Missing $CONF; skipping"; exit 0; }
# shellcheck disable=SC1090
. "$CONF"

: "${MOK_KEY:=/etc/secureboot/mok/MOK.key}"
: "${MOK_CRT:=/etc/secureboot/mok/MOK.crt}"

command -v sbsign   >/dev/null 2>&1 || { warn "Missing sbsign (sbsigntools); skipping"; exit 0; }
command -v sbverify >/dev/null 2>&1 || { warn "Missing sbverify (sbsigntools); skipping"; exit 0; }

[[ -r "$MOK_KEY" && -r "$MOK_CRT" ]] || { warn "Can't read MOK key/cert; skipping"; exit 0; }

BACKUP_DIR="/var/lib/secureboot/kernel-sbsign/backups"
mkdir -p "$BACKUP_DIR"

sign_one() {
  local k="$1"
  [[ -f "$k" ]] || return 0

  # already good? skip.
  if sbverify --cert "$MOK_CRT" --verify "$k" >/dev/null 2>&1; then
    log "OK (already signed): $k"
    return 0
  fi

  log "Signing: $k"
  cp -f "$k" "$BACKUP_DIR/$(basename "$k").$(date +%Y%m%d-%H%M%S).bak"

  local tmp="${k}.signed.$$"
  sbsign --key "$MOK_KEY" --cert "$MOK_CRT" --output "$tmp" "$k"
  test -s "$tmp" || { rm -f "$tmp"; warn "sbsign produced empty output for $k"; return 1; }

  mv -f "$tmp" "$k"

  sbverify --cert "$MOK_CRT" --verify "$k" >/dev/null
  log "Signed OK: $k"
}

# Sign all kernel images present in /boot
for k in /boot/vmlinuz-*; do
  [[ -e "$k" ]] || continue
  sign_one "$k"
done

log "Done."
