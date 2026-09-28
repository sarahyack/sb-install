#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[secureboot-refresh] $*"; }
warn(){ echo "[secureboot-refresh][WARN] $*" >&2; }
die(){ warn "$*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root (use sudo)."
export LC_ALL=C
CONF="/etc/secureboot/grub-standalone.conf"
[[ -r "$CONF" ]] || die "Missing $CONF — run the install/maintenance step first."
# shellcheck source=/dev/null
source "$CONF"
: "${ESP_MOUNT:?missing ESP_MOUNT in conf}"
: "${ESP_DEV:?missing ESP_DEV in conf}"
: "${GRUB_ID:?missing GRUB_ID in conf}"
: "${MOK_KEY:?missing MOK_KEY in conf}"
: "${MOK_CRT:?missing MOK_CRT in conf}"
MOK_CER="${MOK_CER:-${MOK_CRT%.*}.cer}"
for file in "$MOK_KEY" "$MOK_CRT" "$MOK_CER"; do
  [[ -r "$file" && -s "$file" ]] || die "Missing/empty/unreadable key or certificate: $file"
done
for tool in sbverify mountpoint mount cmp grep; do
  command -v "$tool" >/dev/null 2>&1 || die "Missing required command: $tool"
done
if ! mountpoint -q "$ESP_MOUNT"; then
  mkdir -p "$ESP_MOUNT"
  mount "$ESP_DEV" "$ESP_MOUNT" || die "Could not mount ESP: $ESP_MOUNT"
fi
mountpoint -q "$ESP_MOUNT" && [[ -d "$ESP_MOUNT" && -w "$ESP_MOUNT" ]] || die "ESP is not mounted/writable: $ESP_MOUNT"

KERNEL_SIGNER="/usr/local/sbin/kernel-sbsign-all.sh"
SHIM_SYNCER="/usr/local/sbin/secureboot-shim-sync"
GRUB_REBUILDER="/usr/local/sbin/grub-standalone-rebuild.sh"
REFRESH_RC=0
for helper in "$SHIM_SYNCER" "$KERNEL_SIGNER" "$GRUB_REBUILDER"; do
  if [[ ! -x "$helper" ]]; then
    warn "Missing required helper: $helper (reinstall with install.sh option 5)"
    REFRESH_RC=1
    continue
  fi
  log "Running $helper"
  if "$helper"; then
    log "Completed: $helper"
  else
    rc=$?
    warn "Failed or skipped: $helper (status $rc)"
    REFRESH_RC=1
  fi
done

log "Verifying installed kernels and GRUB against MOK cert..."
COUNT=0
for k in /boot/vmlinuz-*; do
  [[ -e "$k" ]] || continue
  COUNT=$((COUNT+1))
  if sbverify --cert "$MOK_CRT" "$k"; then
    log "OK: $k"
  else
    warn "Kernel verification failed: $k"
    REFRESH_RC=1
  fi
done
if (( COUNT == 0 )); then
  warn "No /boot/vmlinuz-* kernel images found to verify"
  REFRESH_RC=1
fi
VENDOR="$ESP_MOUNT/EFI/$GRUB_ID/grubx64.efi"
FALLBACK="$ESP_MOUNT/EFI/BOOT/grubx64.efi"
for efi in "$VENDOR" "$FALLBACK"; do
  if [[ ! -s "$efi" ]]; then
    warn "Missing/empty GRUB image: $efi"
    REFRESH_RC=1
  elif sbverify --cert "$MOK_CRT" "$efi"; then
    log "OK: $efi"
  else
    warn "GRUB verification failed: $efi"
    REFRESH_RC=1
  fi
done
if ! cmp -s "$VENDOR" "$FALLBACK"; then
  warn "Vendor and fallback GRUB copies differ"
  REFRESH_RC=1
fi

if command -v mokutil >/dev/null 2>&1; then
  MOK_RC=0
  MOK_OUT="$(mokutil --test-key "$MOK_CER" 2>&1)" || MOK_RC=$?
  log "mokutil --test-key (status $MOK_RC): $MOK_OUT"
  if grep -qiE 'not enrolled|no.*match|not found' <<< "$MOK_OUT"; then
    warn "MOK is not enrolled"
    REFRESH_RC=1
  elif (( MOK_RC == 0 )) && grep -qiE 'already enrolled|is enrolled' <<< "$MOK_OUT"; then
    log "MOK is enrolled"
  else
    warn "MOK enrollment check is inconclusive (status $MOK_RC)"
    REFRESH_RC=1
  fi
else
  warn "MOK enrollment check unavailable: mokutil is missing"
  REFRESH_RC=1
fi

if (( REFRESH_RC == 0 )); then
  log "Refresh and verification completed successfully."
else
  warn "Refresh incomplete: one or more operations failed, were skipped, or could not be verified."
fi
exit "$REFRESH_RC"
