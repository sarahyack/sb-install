#!/usr/bin/env bash
# Checkhealth Function For Sb-Install

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

checkhealth() {
  say "Health Check: Secure Boot + Standalone GRUB + Watchers"

  local FAIL=0 WARN=0
  h_ok()   { echo "  ✅ $*"; }
  h_warn() { echo "  ⚠️  $*"; WARN=$((WARN+1)); }
  h_fail() { echo "  ❌ $*"; FAIL=$((FAIL+1)); }
  h_info() { echo "  • $*"; }

  have_cmd() { command -v "$1" >/dev/null 2>&1; }

  # --- 1) Core files ---
  local CONF="/etc/secureboot/grub-standalone.conf"
  if sudo test -r "$CONF"; then
    h_ok "Config readable: $CONF"
  else
    h_fail "Missing/unreadable: $CONF (run the standalone maintenance install step first)"
  fi

  # --- 2) Dependencies (soft fail where reasonable) ---
  local -a cmds=(
    grub-mkstandalone grub-mkconfig
    sbsign sbverify
    inotifywait
    findmnt mount awk sed grep
    systemctl journalctl
  )
  for c in "${cmds[@]}"; do
    if have_cmd "$c"; then
      h_ok "cmd: $c"
    else
      # some are truly required for correct operation
      case "$c" in
        grub-mkstandalone|grub-mkconfig|sbsign|sbverify|inotifywait)
          h_fail "Missing required command: $c"
          ;;
        *)
          h_warn "Missing command: $c"
          ;;
      esac
    fi
  done

  # --- 3) Installed hooks + scripts ---
  local -a must_files=(
    "/etc/pacman.d/hooks/95-kernel-sbsign.hook"
    "/etc/pacman.d/hooks/99-grub-standalone.hook"
    "/usr/local/sbin/kernel-sbsign-all.sh"
    "/usr/local/sbin/grub-standalone-rebuild.sh"
    "/usr/local/sbin/grub-standalone-watch.sh"
    "/etc/systemd/system/grub-standalone-watch.service"
  )

  for f in "${must_files[@]}"; do
    if sudo test -e "$f"; then
      h_ok "exists: $f"
    else
      h_fail "missing: $f"
    fi
  done

  # Validate hook Exec lines (helps catch “installed but pointing wrong”)
  if sudo test -r /etc/pacman.d/hooks/95-kernel-sbsign.hook; then
    if sudo grep -qE '^Exec\s*=\s*/usr/local/sbin/kernel-sbsign-all\.sh\s*$' /etc/pacman.d/hooks/95-kernel-sbsign.hook; then
      h_ok "kernel hook Exec looks correct"
    else
      h_fail "kernel hook Exec is not /usr/local/sbin/kernel-sbsign-all.sh"
    fi
  fi
  if sudo test -r /etc/pacman.d/hooks/99-grub-standalone.hook; then
    if sudo grep -qE '^Exec\s*=\s*/usr/local/sbin/grub-standalone-rebuild\.sh\s*$' /etc/pacman.d/hooks/99-grub-standalone.hook; then
      h_ok "grub hook Exec looks correct"
    else
      h_fail "grub hook Exec is not /usr/local/sbin/grub-standalone-rebuild.sh"
    fi
  fi

  # --- 4) Read config vars (only if config exists) ---
  local ESP_MOUNT="" GRUB_ID="" MOK_KEY="" MOK_CRT="" WATCH_DIRS=""
  if sudo test -r "$CONF"; then
    ESP_MOUNT="$(conf_get_var_as_root "$CONF" ESP_MOUNT)"
    GRUB_ID="$(conf_get_var_as_root "$CONF" GRUB_ID)"
    MOK_KEY="$(conf_get_var_as_root "$CONF" MOK_KEY)"
    MOK_CRT="$(conf_get_var_as_root "$CONF" MOK_CRT)"
    MOK_CER="$(conf_get_var_as_root "$CONF" MOK_CER)"
    WATCH_DIRS="$(conf_get_var_as_root "$CONF" WATCH_DIRS)"

    [[ -n "$ESP_MOUNT" ]] && h_ok "ESP_MOUNT=$ESP_MOUNT" || h_fail "ESP_MOUNT is empty in $CONF"
    [[ -n "$GRUB_ID" ]]   && h_ok "GRUB_ID=$GRUB_ID"     || h_fail "GRUB_ID is empty in $CONF"
    [[ -n "$MOK_KEY" ]]   && h_ok "MOK_KEY=$MOK_KEY"     || h_fail "MOK_KEY is empty in $CONF"
    [[ -n "$MOK_CRT" ]]   && h_ok "MOK_CRT=$MOK_CRT"     || h_fail "MOK_CRT is empty in $CONF"
    [[ -n "$MOK_CER" ]]   && h_ok "MOK_CRT=$MOK_CER"     || h_fail "MOK_CER is empty in $CONF"

    if [[ -n "$WATCH_DIRS" ]]; then
      h_ok "WATCH_DIRS set"
      h_info "WATCH_DIRS=$WATCH_DIRS"
    else
      h_warn "WATCH_DIRS is empty (watcher will have nothing to watch)"
    fi
  fi

  # --- 5) ESP sanity ---
  if [[ -n "$ESP_MOUNT" ]]; then
    if sudo test -d "$ESP_MOUNT"; then
      h_ok "ESP mount path exists: $ESP_MOUNT"
      if findmnt -rn --target "$ESP_MOUNT" >/dev/null 2>&1; then
        h_ok "ESP is mounted (findmnt sees it)"
      else
        h_fail "ESP path exists but does not appear mounted: $ESP_MOUNT"
      fi
    else
      h_fail "ESP mount dir not found: $ESP_MOUNT"
    fi
  fi

  # --- 6) Watcher service status ---
  local en act pid args
  en="$(systemctl is-enabled grub-standalone-watch.service 2>/dev/null || true)"
  act="$(systemctl is-active  grub-standalone-watch.service 2>/dev/null || true)"

  if [[ "$en" == "enabled" ]]; then
    h_ok "watcher enabled (systemd): $en"
  else
    h_fail "watcher not enabled (systemd): $en"
  fi

  if [[ "$act" == "active" ]]; then
    h_ok "watcher active: $act"
  else
    h_fail "watcher not active: $act (check logs below)"
  fi

  pid="$(systemctl show -p MainPID --value grub-standalone-watch.service 2>/dev/null || true)"
  args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  # 1) If MainPID is our watcher script, that's fine (systemd often tracks the shell script, not the inotify child).
  if echo "$args" | grep -qE '(^|[[:space:]])(bash[[:space:]]+)?(/usr/local/sbin/)?grub-standalone-watch\.sh([[:space:]]|$)'; then
    h_ok "watcher MainPID is grub-standalone-watch.sh (normal)"
  # 2) If MainPID itself is inotifywait, also fine.
  elif echo "$args" | grep -q "inotifywait"; then
    h_ok "watcher MainPID appears to be running inotifywait"
  # 3) Otherwise, check whether the service cgroup contains inotifywait.
  elif systemctl status grub-standalone-watch.service --no-pager 2>/dev/null | grep -q "inotifywait"; then
    h_ok "watcher cgroup contains inotifywait"
  else
    h_warn "watcher is active, but couldn't confirm inotifywait (MainPID args: $args)"
  fi

  if [[ "$act" != "active" || -z "$pid" || "$pid" == "0" ]]; then
    h_info "Last watcher logs:"
    journalctl -u grub-standalone-watch.service -n 60 --no-pager 2>/dev/null | sed 's/^/    /'
  fi

  # --- 7) Verify signatures (kernel + GRUB EFI) ---
  if [[ -n "$MOK_CRT" ]]; then
    if sudo test -r "$MOK_CRT"; then
      h_ok "MOK cert readable: $MOK_CRT"
    else
      h_fail "Can't read MOK cert: $MOK_CRT"
    fi
  fi

  if [[ -n "$MOK_CER" ]]; then
    if sudo test -r "$MOK_CER"; then
      h_ok "MOK DER cert readable: $MOK_CER"
    else
      h_fail "Can't read MOK DER cert (for mokutil): $MOK_CER"
    fi
  fi
  # 7a) Kernel(s)
  if [[ -n "$MOK_CRT" ]] && sudo test -r "$MOK_CRT"; then
    local any_kernel=0
    for k in /boot/vmlinuz-*; do
      [[ -e "$k" ]] || continue
      any_kernel=1
      if sudo sbverify --cert "$MOK_CRT" --verify "$k" >/dev/null 2>&1; then
        h_ok "kernel signed OK: $k"
      else
        h_fail "kernel NOT signed by MOK cert: $k (run: sudo /usr/local/sbin/kernel-sbsign-all.sh)"
      fi
    done
    [[ "$any_kernel" -eq 1 ]] || h_warn "No /boot/vmlinuz-* found to verify"
  fi

  # 7b) GRUB EFI(s) (vendor + fallback)
  if [[ -n "$ESP_MOUNT" && -n "$GRUB_ID" && -n "$MOK_CRT" ]] && sudo test -r "$MOK_CRT"; then
    local vendor="$ESP_MOUNT/EFI/$GRUB_ID/grubx64.efi"
    local fallback="$ESP_MOUNT/EFI/BOOT/grubx64.efi"

    for efi in "$vendor" "$fallback"; do
      if sudo test -f "$efi"; then
        h_ok "EFI exists: $efi"

        if sudo sbverify --list "$efi" >/dev/null 2>&1; then
          h_ok "EFI has a parseable signature: $efi"
        else
          h_fail "EFI signature structure invalid (sbverify --list failed): $efi"
        fi

        if sudo sbverify --cert "$MOK_CRT" --verify "$efi" >/dev/null 2>&1; then
          h_ok "EFI verifies against MOK cert: $efi"
        else
          h_fail "EFI does NOT verify against MOK cert: $efi (run: sudo /usr/local/sbin/grub-standalone-rebuild.sh)"
        fi
      else
        h_fail "EFI missing: $efi"
      fi
    done
  fi

  # --- 8) MOK enrollment (best-effort, optional) ---
  # Use MOK_CER (DER) and run mokutil with sudo (reading EFI vars often needs root).
  if have_cmd mokutil && [[ -n "$MOK_CER" ]]; then
    h_info "Secure Boot state (mokutil):"
    sudo mokutil --sb-state 2>/dev/null | sed 's/^/    /' || true

    if sudo test -r "$MOK_CER"; then
      local out=""
      if out="$(sudo mokutil --test-key "$MOK_CER" 2>&1)"; then
        h_ok "MOK appears enrolled (mokutil --test-key): $MOK_CER"
      else
        h_fail "MOK test failed (mokutil --test-key): $MOK_CER"
        h_info "mokutil output: $out"
        h_info "Fix: copy MOK.cer to ESP, reboot into MokManager, enroll it."
      fi
    else
      h_fail "Can't read MOK_CER for mokutil test: $MOK_CER"
    fi
  else
    h_warn "mokutil not available or MOK_CER missing; skipping enrollment test (install mokutil and set MOK_CER)"
  fi

  # --- 9) Summary + exit code ---
  echo
  if [[ "$FAIL" -eq 0 ]]; then
    say "Health Check Result: PASS ✅  (warnings: $WARN)"
    return 0
  else
    say "Health Check Result: FAIL ❌  (failures: $FAIL, warnings: $WARN)"
    h_info "Tip: start with watcher logs:"
    echo "    journalctl -u grub-standalone-watch.service -n 80 --no-pager"
    return 1
  fi
}
