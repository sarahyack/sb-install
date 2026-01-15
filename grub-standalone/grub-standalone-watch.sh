#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[grub-standalone-watch] $*"; }
warn(){ echo "[grub-standalone-watch][WARN] $*" >&2; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { warn "Run as root (sudo)"; exit 1; }

CONF="/etc/secureboot/grub-standalone.conf"
[[ -r "$CONF" ]] && . "$CONF" || true

REBUILD="${REBUILD_CMD:-/usr/local/sbin/grub-standalone-rebuild.sh}"

if [[ ! -x "$REBUILD" ]]; then
  warn "Rebuild script not found/executable: $REBUILD"
  exit 0
fi

log "Triggered by systemd path unit; rebuilding..."
if "$REBUILD"; then
  log "Rebuild complete."
else
  warn "Rebuild failed (check logs: journalctl -u grub-standalone-watch.service)."
  exit 1
fi
