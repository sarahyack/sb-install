#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[secureboot-refresh] $*"; }
warn(){ echo "[secureboot-refresh][WARN] $*" >&2; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { warn "Run as root (use sudo)."; exit 1; }

CONF="/etc/secureboot/grub-standalone.conf"
if [[ ! -r "$CONF" ]]; then
  warn "Missing $CONF — run the install/maintenance step first."
  exit 1
fi

# shellcheck disable=SC1090
source "$CONF"

# Optional: if your conf doesn't store MOK_CER, derive it from MOK_CRT
if [[ -z "${MOK_CER:-}" && -n "${MOK_CRT:-}" ]]; then
  MOK_CER="${MOK_CRT%.*}.cer"
fi

KERNEL_SIGNER="/usr/local/sbin/kernel-sbsign-all.sh"
SHIM_SYNCER="/usr/local/sbin/secureboot-shim-sync"
GRUB_REBUILDER="/usr/local/sbin/grub-standalone-rebuild.sh"
REFRESH_RC=0

if [[ -x "$SHIM_SYNCER" ]]; then
  log "Synchronizing shim and MokManager on the ESP..."
  if ! "$SHIM_SYNCER"; then
    warn "Shim/MokManager synchronization failed."
    REFRESH_RC=1
  fi
else
  warn "Shim sync helper missing: $SHIM_SYNCER"
  REFRESH_RC=1
fi

if [[ -x "$KERNEL_SIGNER" ]]; then
  log "Signing kernels (if needed)..."
  "$KERNEL_SIGNER" || true
else
  warn "Kernel signer missing: $KERNEL_SIGNER"
fi

if [[ -x "$GRUB_REBUILDER" ]]; then
  log "Rebuilding + signing standalone GRUB..."
  "$GRUB_REBUILDER" || true
else
  warn "GRUB rebuilder missing: $GRUB_REBUILDER"
fi

# Quick verification (best-effort)
if command -v sbverify >/dev/null 2>&1 && [[ -n "${MOK_CRT:-}" ]] && [[ -r "${MOK_CRT:-}" ]]; then
  log "Verifying kernels against MOK cert..."
  for k in /boot/vmlinuz-*; do
    [[ -e "$k" ]] || continue
    if sbverify --cert "$MOK_CRT" --verify "$k" >/dev/null 2>&1; then
      log "OK: $k"
    else
      warn "NOT OK (not signed by MOK cert): $k"
    fi
  done

  if [[ -n "${ESP_MOUNT:-}" && -n "${GRUB_ID:-}" ]]; then
    for efi in "$ESP_MOUNT/EFI/$GRUB_ID/grubx64.efi" "$ESP_MOUNT/EFI/BOOT/grubx64.efi"; do
      [[ -f "$efi" ]] || continue
      if sbverify --cert "$MOK_CRT" --verify "$efi" >/dev/null 2>&1; then
        log "OK: $efi"
      else
        warn "NOT OK (not signed by MOK cert): $efi"
      fi
    done
  fi
fi

# Optional MOK enrollment check (best-effort)
if command -v mokutil >/dev/null 2>&1 && [[ -r "${MOK_CER:-}" ]]; then
  log "MOK test-key (best-effort): $MOK_CER"
  mokutil --test-key "$MOK_CER" >/dev/null 2>&1 \
    && log "MOK appears enrolled" \
    || warn "MOK test-key failed"
fi

if [[ "$REFRESH_RC" -eq 0 ]]; then
  log "Done."
else
  warn "Done with failures."
fi
exit "$REFRESH_RC"
