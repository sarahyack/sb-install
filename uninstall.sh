#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "[ERR] Do not run this script as root. Run it as your normal user; it will use sudo when needed."
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"

show_intro() {
  cat <<'TXT'

Secure Boot Helper - Uninstall

This script removes hooks/scripts and related additions created by install.sh.
It will ask before each major step.

TXT
}

rm_file() {
  local path="$1"
  if sudo test -e "$path"; then
    sudo rm -f "$path"
    say "Removed: $path"
  else
    say "Missing: $path"
  fi
}

rm_dir() {
  local path="$1"
  if sudo test -d "$path"; then
    sudo rm -rf "$path"
    say "Removed dir: $path"
  else
    say "Missing dir: $path"
  fi
}

maybe_rmdir() {
  local path="$1"
  if sudo rmdir "$path" 2>/dev/null; then
    say "Removed empty dir: $path"
  fi
}

read_meta_field() {
  local meta="$1" key="$2"
  sudo awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$meta" 2>/dev/null
}

pick_backup_from_meta() {
  local target="$1" backup_dir="$2"
  local base meta
  base="$(basename -- "$target")"
  local -a metas=()
  shopt -s nullglob
  for meta in "$backup_dir/${base}.sb-install."*.bak.meta; do
    sudo test -f "$meta" || continue
    if [[ "$(read_meta_field "$meta" created_by)" == "sb-install" ]] \
      && [[ "$(read_meta_field "$meta" source_path)" == "$target" ]]; then
      metas+=("$meta")
    fi
  done
  shopt -u nullglob

  if (( ${#metas[@]} == 0 )); then
    return 1
  fi

  if (( ${#metas[@]} == 1 )); then
    printf '%s\n' "${metas[0]%.meta}"
    return 0
  fi

  warn "Multiple sb-install backups found for $target."
  warn "These may not reflect pre-install state if the script ran multiple times."
  local i
  for i in "${!metas[@]}"; do
    local b="${metas[$i]%.meta}"
    local t r
    t="$(read_meta_field "${metas[$i]}" backup_time)"
    r="$(read_meta_field "${metas[$i]}" run_id)"
    printf '  %s) %s (time: %s, run: %s)\n' "$((i+1))" "$b" "${t:-unknown}" "${r:-unknown}"
  done
  read -r -p "Pick a backup to restore (number), or 0 to skip restore: " choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#metas[@]} )); then
    printf '%s\n' "${metas[$((choice-1))]%.meta}"
    return 0
  fi
  return 2
}

restore_or_remove() {
  local target="$1"
  local backup_dir="$2"
  local base bak chosen
  base="$(basename -- "$target")"
  bak="$backup_dir/${base}.bak"

  if chosen="$(pick_backup_from_meta "$target" "$backup_dir")"; then
    sudo cp -f "$chosen" "$target"
    say "Restored: $target (from $chosen)"
    return 0
  fi

  if sudo test -f "$bak"; then
    warn "Found untagged backup: $bak"
    if confirm "Restore this untagged backup? (not verified as sb-install)" 1; then
      sudo cp -f "$bak" "$target"
      say "Restored: $target (from $bak)"
      return 0
    fi
  fi

  rm_file "$target"
}

uninstall_hooks_and_scripts() {
  say "Stopping any legacy watcher units (if present)"
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl disable --now grub-standalone-watch.path >/dev/null 2>&1 || true
    sudo systemctl disable --now grub-standalone-watch.service >/dev/null 2>&1 || true
    sudo systemctl reset-failed grub-standalone-watch.service grub-standalone-watch.path >/dev/null 2>&1 || true
  fi

  rm_file /etc/systemd/system/grub-standalone-watch.service
  rm_file /etc/systemd/system/grub-standalone-watch.path
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  rm_file /etc/pacman.d/hooks/95-kernel-sbsign.hook
  rm_file /etc/pacman.d/hooks/99-grub-standalone.hook

  rm_file /usr/local/sbin/kernel-sbsign-all.sh
  rm_file /usr/local/sbin/grub-standalone-rebuild.sh
  rm_file /usr/local/sbin/grub-standalone-watch.sh
  rm_file /usr/local/sbin/secureboot-refresh
}

uninstall_secureboot_config_and_state() {
  rm_file /etc/secureboot/grub-standalone.conf
  rm_dir /var/lib/secureboot/grub-standalone
  rm_dir /var/lib/secureboot/kernel-sbsign
  maybe_rmdir /var/lib/secureboot
}

uninstall_mok_keys() {
  local mok_key="${1:-/etc/secureboot/mok/MOK.key}"
  local mok_crt="${2:-/etc/secureboot/mok/MOK.crt}"
  local mok_cer="${3:-/etc/secureboot/mok/MOK.cer}"

  rm_file "$mok_key"
  rm_file "$mok_crt"
  rm_file "$mok_cer"

  local mok_dir
  mok_dir="$(dirname -- "$mok_key")"
  maybe_rmdir "$mok_dir"
  maybe_rmdir /etc/secureboot
}

uninstall_esp_shim_and_mok() {
  local esp="$1"
  local boot_dir="$esp/EFI/BOOT"

  if ! sudo test -d "$boot_dir"; then
    warn "ESP BOOT dir not found: $boot_dir"
    return 0
  fi

  restore_or_remove "$boot_dir/BOOTX64.EFI" "$boot_dir/backup"
  restore_or_remove "$boot_dir/mmx64.efi" "$boot_dir/backup"

  rm_file "$esp/MOK.cer"
  rm_file "$boot_dir/MOK.cer"
}

uninstall_esp_grub_standalone() {
  local esp="$1"
  local grub_id="$2"
  local vendor_dir="$esp/EFI/$grub_id"
  local boot_dir="$esp/EFI/BOOT"

  restore_or_remove "$vendor_dir/grubx64.efi" "$vendor_dir/backup"
  restore_or_remove "$boot_dir/grubx64.efi" "$boot_dir/backup"
}

remove_shim_boot_entries() {
  local -a nums=()
  mapfile -t nums < <(bootnums_for_label_and_loader "Shim" "bootx64.efi" || true)

  if (( ${#nums[@]} == 0 )); then
    say "No Shim boot entries found."
    return 0
  fi

  say "Removing Shim boot entries:"
  printf '  - Boot%s\n' "${nums[@]}"
  local num
  for num in "${nums[@]}"; do
    sudo efibootmgr -b "$num" -B || true
  done
}

main() {
  show_intro
  need_cmd bash
  sudo_once

  local conf="/etc/secureboot/grub-standalone.conf"
  local esp="" grub_id="" mok_key="" mok_crt="" mok_cer=""
  if sudo test -r "$conf"; then
    esp="$(conf_get_var_as_root "$conf" ESP_MOUNT || true)"
    grub_id="$(conf_get_var_as_root "$conf" GRUB_ID || true)"
    mok_key="$(conf_get_var_as_root "$conf" MOK_KEY || true)"
    mok_crt="$(conf_get_var_as_root "$conf" MOK_CRT || true)"
    mok_cer="$(conf_get_var_as_root "$conf" MOK_CER || true)"
  fi
  grub_id="${grub_id:-GRUB}"
  mok_key="${mok_key:-/etc/secureboot/mok/MOK.key}"
  mok_crt="${mok_crt:-/etc/secureboot/mok/MOK.crt}"
  mok_cer="${mok_cer:-/etc/secureboot/mok/MOK.cer}"

  if confirm "Remove pacman hooks and installed scripts?" 0; then
    uninstall_hooks_and_scripts
  fi

  if confirm "Remove /etc/secureboot/grub-standalone.conf and /var/lib/secureboot state dirs?" 0; then
    uninstall_secureboot_config_and_state
  fi

  if confirm "Remove MOK keys under /etc/secureboot (or configured path)?" 1; then
    uninstall_mok_keys "$mok_key" "$mok_crt" "$mok_cer"
  fi

  if confirm "Remove Shim + MokManager files and MOK.cer from the ESP?" 1; then
    local esp
    esp="$(get_esp_or_ask)"
    uninstall_esp_shim_and_mok "$esp"
  fi

  if confirm "Remove standalone GRUB EFI binaries from the ESP (vendor + fallback)?" 1; then
    [[ -n "$esp" ]] || esp="$(get_esp_or_ask)"
    uninstall_esp_grub_standalone "$esp" "$grub_id"
  fi

  if confirm "Remove NVRAM boot entries labeled 'Shim' that point to BOOTX64.EFI?" 1; then
    remove_shim_boot_entries
  fi
}

main "$@"
