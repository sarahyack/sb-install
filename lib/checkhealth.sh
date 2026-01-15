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
    findmnt mount awk sed grep
    systemctl journalctl
  )
  for c in "${cmds[@]}"; do
    if have_cmd "$c"; then
      h_ok "cmd: $c"
    else
      # some are truly required for correct operation
      case "$c" in
        grub-mkstandalone|grub-mkconfig|sbsign|sbverify)
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
    "/etc/systemd/system/grub-standalone-watch.path"
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
      h_warn "WATCH_DIRS is empty (update grub-standalone-watch.path if you rely on custom watch dirs)"
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

  # --- 6) Watcher path + service status ---
  local path_en path_act svc_state svc_result
  path_en="$(systemctl is-enabled grub-standalone-watch.path 2>/dev/null || true)"
  path_act="$(systemctl is-active  grub-standalone-watch.path 2>/dev/null || true)"

  if [[ "$path_en" == "enabled" ]]; then
    h_ok "watcher path enabled (systemd): $path_en"
  else
    h_fail "watcher path not enabled (systemd): $path_en"
  fi

  if [[ "$path_act" == "active" ]]; then
    h_ok "watcher path active: $path_act"
  else
    h_fail "watcher path not active: $path_act (check logs below)"
  fi

  svc_state="$(systemctl is-active grub-standalone-watch.service 2>/dev/null || true)"
  svc_result="$(systemctl show -p Result --value grub-standalone-watch.service 2>/dev/null || true)"
  h_info "watcher service state: $svc_state (last result: ${svc_result:-unknown})"

  if [[ "$path_act" != "active" ]]; then
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
  # Use MOK_CER (DER) and run mokutil with sudo.
  if have_cmd mokutil && [[ -n "$MOK_CER" ]]; then
    h_info "Secure Boot state (mokutil):"
    sudo mokutil --sb-state 2>/dev/null | sed 's/^/    /' || true
  
    if sudo test -r "$MOK_CER"; then
      local out rc
      out="$(sudo mokutil --test-key "$MOK_CER" 2>&1 || true)"
      rc=$?
  
      # Some mokutil versions return non-zero even when enrolled.
      if [[ "$rc" -eq 0 ]] || echo "$out" | grep -qiE 'already enrolled|is enrolled|enrolled'; then
        h_ok "MOK appears enrolled (mokutil --test-key): $MOK_CER"
        h_info "mokutil output: $out"
      elif echo "$out" | grep -qiE 'not enrolled|no.*match|not found'; then
        h_fail "MOK NOT enrolled (mokutil --test-key): $MOK_CER"
        h_info "mokutil output: $out"
        h_info "Fix: copy MOK.cer to ESP, reboot into MokManager, enroll it."
      else
        h_warn "mokutil --test-key returned an unexpected result (rc=$rc): $MOK_CER"
        h_info "mokutil output: $out"
        h_info "If Secure Boot boots fine + EFI verifies against MOK cert, this is likely a mokutil quirk."
      fi
    else
      h_fail "Can't read MOK_CER for mokutil test: $MOK_CER"
    fi
  else
    h_warn "mokutil not available or MOK_CER missing; skipping enrollment test (install mokutil and set MOK_CER)"
  fi

  # --- Optional: Snapshot support checks (grub-btrfs + snapper/timeshift) ---
  h_section "Snapshot Support (optional)"

  local SNAP_OK=""
  read -r -p "Check snapshot support (grub-btrfs + Snapper/Timeshift)? [y/N]: " SNAP_OK || true
  if [[ "${SNAP_OK:-}" =~ ^[Yy]$ ]]; then

    # 1) grub-btrfs presence
    if have_pkg grub-btrfs; then
      h_ok "pkg: grub-btrfs"
    else
      h_warn "pkg missing: grub-btrfs (snapshot menu won't exist without it)"
    fi

    # 2) grub-btrfs grub.d script
    local snap_grubd="/etc/grub.d/41_snapshots-btrfs"
    if sudo test -e "$snap_grubd"; then
      h_ok "exists: $snap_grubd"
      if sudo test -x "$snap_grubd"; then
        h_ok "executable: $snap_grubd"
      else
        h_warn "not executable: $snap_grubd (try: sudo chmod +x $snap_grubd)"
      fi
    else
      h_warn "missing: $snap_grubd (grub-btrfs may not be installed or script name differs)"
    fi

    # 3) Ensure our pipeline CAN incorporate /etc/grub.d
    # (This is mostly a sanity hint, not a hard rule.)
    if have_cmd grub-mkconfig; then
      h_ok "cmd: grub-mkconfig (snapshot menu generation requires grub-mkconfig)"
    else
      h_fail "Missing grub-mkconfig (required if you expect snapshot menu generation)"
    fi

    # 4) Snapshot tool presence (snapper vs timeshift)
    local have_snapper=0 have_timeshift=0
    have_pkg snapper && have_snapper=1
    have_pkg timeshift && have_timeshift=1

    if (( have_snapper == 1 )); then h_ok "pkg: snapper"; fi
    if (( have_timeshift == 1 )); then h_ok "pkg: timeshift"; fi
    if (( have_snapper == 0 && have_timeshift == 0 )); then
      h_warn "No snapshot tool detected (snapper/timeshift). grub-btrfs may show nothing."
    fi

    # 5) Detect snapshot directory (best-effort) and confirm WATCH_DIRS includes it
    local snapdir=""

    if (( have_snapper == 1 )); then
      snapdir="$(detect_snapper_snapshot_dir 2>/dev/null || true)"
      if [[ -n "$snapdir" ]]; then
        if sudo test -d "$snapdir"; then
          h_ok "Snapper snapshot dir exists: $snapdir"
        else
          h_warn "Snapper snapshot dir not present yet: $snapdir (normal if no snapshots/config yet)"
        fi
      else
        h_warn "Could not detect Snapper snapshot dir"
      fi
    fi

    if [[ -z "$snapdir" && $have_timeshift -eq 1 ]]; then
      snapdir="$(detect_timeshift_snapshot_dir 2>/dev/null || true)"
      if [[ -n "$snapdir" ]]; then
        if sudo test -d "$snapdir"; then
          h_ok "Timeshift snapshot dir exists: $snapdir"
        else
          h_warn "Timeshift snapshot dir not present yet: $snapdir (normal if not configured / no snapshots)"
        fi
      else
        h_warn "Could not detect Timeshift snapshot dir"
      fi
    fi

    if [[ -n "${WATCH_DIRS:-}" && -n "${snapdir:-}" ]]; then
      if [[ "$snapdir" == "/.snapshots" ]]; then
        h_info "Skipping WATCH_DIRS check for /.snapshots (explicitly excluded)"
      else
        # Normalize just for comparison safety
        local wd_norm
        wd_norm="$(printf '%s' "$WATCH_DIRS" | tr '\n\t' ' ' | xargs)"
        if str_in_list "$wd_norm" "$snapdir"; then
          h_ok "WATCH_DIRS includes snapshot dir: $snapdir"
        else
          h_warn "WATCH_DIRS does NOT include snapshot dir: $snapdir (new snapshots won't trigger rebuild)"
          h_info "Fix: run snapshot install option again or add it via conf_add_watch_dir"
        fi
      fi
    fi

    # 6) Bonus: If any snapshots exist, hint that rebuild should generate menu
    # (Soft check: we don't parse your embedded grub.cfg here.)
    if sudo test -x /usr/local/sbin/grub-standalone-rebuild.sh; then
      h_info "Tip: after creating a snapshot, run:"
      h_info "  sudo /usr/local/sbin/grub-standalone-rebuild.sh"
      h_info "Then reboot and check for the snapshot submenu."
    fi

  else
    h_info "Snapshot checks skipped."
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
