#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[grub-standalone-watch] $*"; }
warn(){ echo "[grub-standalone-watch][WARN] $*" >&2; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { warn "Run as root (sudo)"; exit 1; }

CONF="/etc/secureboot/grub-standalone.conf"
[[ -r "$CONF" ]] && . "$CONF" || true

REBUILD="${REBUILD_CMD:-/usr/local/sbin/grub-standalone-rebuild.sh}"

# Defaults (override by setting WATCH_DIRS / DEBOUNCE_SECS in grub-standalone.conf)
DEBOUNCE_SECS="${DEBOUNCE_SECS:-2}"
EVENTS="${INOTIFY_EVENTS:-close_write,move,create,delete,attrib}"

# If user did not set WATCH_DIRS, use safe defaults
if [[ -n "${WATCH_DIRS:-}" ]]; then
  # shellcheck disable=SC2206
  WATCH_DIRS_ARR=($WATCH_DIRS)
else
  WATCH_DIRS_ARR=(/etc/default/grub /etc/grub.d /boot/grub/themes /usr/share/endeavouros)
fi

# Only keep paths that exist
WATCH=()
for p in "${WATCH_DIRS_ARR[@]}"; do
  [[ -e "$p" ]] && WATCH+=("$p")
done

if (( ${#WATCH[@]} == 0 )); then
  warn "No watch paths exist; nothing to do."
  exit 0
fi

if ! command -v inotifywait >/dev/null 2>&1; then
  warn "inotifywait not found (install inotify-tools). Exiting."
  exit 0
fi

if [[ ! -x "$REBUILD" ]]; then
  warn "Rebuild script not found/executable: $REBUILD"
  exit 0
fi

log "Watching (debounce ${DEBOUNCE_SECS}s):"
printf '  - %s\n' "${WATCH[@]}"

while true; do
  # Wait for the first event (quiet output)
  inotifywait -q -r -e "$EVENTS" "${WATCH[@]}" >/dev/null 2>&1 || true

  # Drain events until quiet for DEBOUNCE_SECS
  while inotifywait -q -r -e "$EVENTS" --timeout "$DEBOUNCE_SECS" "${WATCH[@]}" >/dev/null 2>&1; do
    :
  done

  log "Changes detected; rebuilding..."
  if "$REBUILD"; then
    log "Rebuild complete."
  else
    warn "Rebuild failed (check logs: journalctl -u grub-standalone-watch.service)."
  fi
done
