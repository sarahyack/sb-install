#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="${SB_SHIM_SYNC_LOG_PREFIX:-secureboot-shim-sync}"
CONF="${SB_SHIM_SYNC_CONF:-/etc/secureboot/grub-standalone.conf}"
BACKUP_KEEP="${SB_BACKUP_KEEP:-5}"
RUN_ID="${SB_INSTALL_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)-$$}"

log() { echo "[$LOG_PREFIX] $*"; }
warn() { echo "[$LOG_PREFIX][WARN] $*" >&2; }

usage() {
  cat <<'EOF'
Usage: secureboot-shim-sync [--sync|--check|--print-sources] [--esp PATH]
                            [--shim-src PATH] [--mm-src PATH]

Synchronizes installed shim-signed binaries to the EFI System Partition:
  shimx64.efi -> ESP/EFI/BOOT/BOOTx64.EFI
  mmx64.efi   -> ESP/EFI/BOOT/mmx64.efi

Without --esp, ESP_MOUNT is read from /etc/secureboot/grub-standalone.conf.
EOF
}

first_existing_or_default() {
  local default_path="$1"
  shift

  local p
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    if [[ -f "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done

  printf '%s\n' "$default_path"
}

detect_shim_sources() {
  local shim="${SHIM_SYNC_SHIM_SRC:-}"
  local mm="${SHIM_SYNC_MM_SRC:-}"
  local default_shim="/usr/share/shim-signed/shimx64.efi"
  local default_mm="/usr/share/shim-signed/mmx64.efi"

  if [[ -z "$shim" || -z "$mm" ]]; then
    local -a package_paths=()
    if command -v pacman >/dev/null 2>&1; then
      mapfile -t package_paths < <(pacman -Ql shim-signed 2>/dev/null | awk '{print $2}' || true)
    fi

    local p
    for p in "${package_paths[@]}"; do
      case "$p" in
        */shimx64.efi) [[ -z "$shim" ]] && shim="$p" ;;
        */mmx64.efi) [[ -z "$mm" ]] && mm="$p" ;;
      esac
    done
  fi

  if [[ -z "$shim" || -z "$mm" ]]; then
    local found_shim="" found_mm=""
    if [[ -d /usr/share/shim-signed ]]; then
      found_shim="$(find /usr/share/shim-signed -type f -iname shimx64.efi -print -quit 2>/dev/null || true)"
      found_mm="$(find /usr/share/shim-signed -type f -iname mmx64.efi -print -quit 2>/dev/null || true)"
    fi

    [[ -z "$shim" ]] && shim="$(first_existing_or_default "$default_shim" "$default_shim" "$found_shim")"
    [[ -z "$mm" ]] && mm="$(first_existing_or_default "$default_mm" "$default_mm" "$found_mm")"
  fi

  printf '%s|%s\n' "$shim" "$mm"
}

validate_source() {
  local label="$1"
  local path="$2"

  if [[ ! -f "$path" ]]; then
    warn "MISSING $label source: $path"
    return 1
  fi
  if [[ ! -r "$path" ]]; then
    warn "UNREADABLE $label source: $path"
    return 1
  fi
  if [[ ! -s "$path" ]]; then
    warn "EMPTY $label source: $path"
    return 1
  fi
}

load_esp_from_config() {
  if [[ ! -r "$CONF" ]]; then
    warn "Missing config: $CONF (pass --esp or run the maintenance install step)"
    return 1
  fi

  # shellcheck disable=SC1090
  . "$CONF"
  if [[ -z "${ESP_MOUNT:-}" ]]; then
    warn "ESP_MOUNT is empty in $CONF"
    return 1
  fi
  printf '%s\n' "$ESP_MOUNT"
}

ensure_configured_esp_mounted() {
  local esp="$1"

  if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$esp"; then
    return 0
  fi

  if [[ -n "${ESP_DEV:-}" ]]; then
    log "ESP not mounted at $esp; attempting mount $ESP_DEV -> $esp"
    mkdir -p "$esp"
    if mount "$ESP_DEV" "$esp" 2>/dev/null; then
      return 0
    fi
    warn "Could not mount ESP: $ESP_DEV -> $esp"
    return 1
  fi

  warn "ESP does not appear mounted and ESP_DEV is not configured: $esp"
  return 1
}

status_one() {
  local label="$1"
  local src="$2"
  local dst="$3"

  log "source $label: $src"
  log "ESP $label: $dst"

  if [[ ! -f "$dst" ]]; then
    warn "MISSING: $dst"
    return 1
  fi

  if cmp -s "$src" "$dst"; then
    log "MATCH: $src == $dst"
    return 0
  fi

  warn "MISMATCH: $src != $dst"
  return 1
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

backup_esp_file() {
  local path="$1"
  local backup_dir="$2"
  local base
  base="$(basename -- "$path")"

  if [[ ! -e "$path" ]]; then
    return 0
  fi

  local ts backup latest meta
  ts="$(date -u +%Y%m%d-%H%M%S)"
  backup="$backup_dir/${base}.sb-install.${ts}.bak"
  latest="$backup_dir/${base}.bak"
  meta="${backup}.meta"

  mkdir -p "$backup_dir"
  cp -f "$path" "$backup"
  cp -f "$path" "$latest"
  cat > "$meta" <<EOF
created_by=sb-install
source_path=$path
backup_time=$ts
run_id=$RUN_ID
EOF
  cat > "${latest}.meta" <<EOF
created_by=sb-install
source_path=$path
backup_time=$ts
run_id=$RUN_ID
EOF
  prune_backups "$backup_dir" "$base" "$BACKUP_KEEP"

  printf '%s\n' "$backup"
}

restore_changed_targets() {
  local target backup

  while (( $# > 0 )); do
    target="$1"
    backup="$2"
    shift 2

    if [[ -n "$backup" && -f "$backup" ]]; then
      warn "Restoring $target from $backup"
      cp -f "$backup" "$target" || warn "Restore failed for $target"
    else
      warn "Removing incomplete new file: $target"
      rm -f "$target" || warn "Could not remove incomplete file: $target"
    fi
  done
}

install_prepared_copy() {
  local prepared="$1"
  local target="$2"

  mv -f "$prepared" "$target"
}

sync_shim_to_esp() {
  local esp="$1"
  local shim_src="$2"
  local mm_src="$3"
  local boot_dir="$esp/EFI/BOOT"
  local shim_dst="$boot_dir/BOOTx64.EFI"
  local mm_dst="$boot_dir/mmx64.efi"
  local backup_dir="$boot_dir/backup"

  validate_source "shim" "$shim_src" || return 1
  validate_source "MokManager" "$mm_src" || return 1

  mkdir -p "$boot_dir"

  local shim_current=0 mm_current=0
  [[ -f "$shim_dst" ]] && cmp -s "$shim_src" "$shim_dst" && shim_current=1
  [[ -f "$mm_dst" ]] && cmp -s "$mm_src" "$mm_dst" && mm_current=1

  if (( shim_current == 1 && mm_current == 1 )); then
    log "shim and MokManager are already current on the ESP."
    return 0
  fi

  local tmp_dir tmp_shim tmp_mm
  tmp_dir="$(mktemp -d "$boot_dir/.sb-install-shim-sync.XXXXXX")"
  tmp_shim="$tmp_dir/BOOTx64.EFI"
  tmp_mm="$tmp_dir/mmx64.efi"

  if ! cp -f "$shim_src" "$tmp_shim"; then
    warn "Failed to prepare shim copy"
    rm -rf "$tmp_dir" || true
    return 1
  fi
  if ! cp -f "$mm_src" "$tmp_mm"; then
    warn "Failed to prepare MokManager copy"
    rm -rf "$tmp_dir" || true
    return 1
  fi
  if ! cmp -s "$shim_src" "$tmp_shim"; then
    warn "Prepared shim copy does not match source"
    rm -rf "$tmp_dir" || true
    return 1
  fi
  if ! cmp -s "$mm_src" "$tmp_mm"; then
    warn "Prepared MokManager copy does not match source"
    rm -rf "$tmp_dir" || true
    return 1
  fi

  local -a changed=()
  local shim_backup="" mm_backup=""

  if (( shim_current == 0 )); then
    shim_backup="$(backup_esp_file "$shim_dst" "$backup_dir")" || {
      rm -rf "$tmp_dir" || true
      return 1
    }
    log "Installing shim: $shim_src -> $shim_dst"
    if ! install_prepared_copy "$tmp_shim" "$shim_dst"; then
      warn "Failed to install shim to $shim_dst"
      rm -rf "$tmp_dir" || true
      restore_changed_targets "$shim_dst" "$shim_backup"
      return 1
    fi
    changed+=("$shim_dst" "$shim_backup")
  fi

  if (( mm_current == 0 )); then
    mm_backup="$(backup_esp_file "$mm_dst" "$backup_dir")" || {
      rm -rf "$tmp_dir" || true
      restore_changed_targets "${changed[@]}"
      return 1
    }
    log "Installing MokManager: $mm_src -> $mm_dst"
    if ! install_prepared_copy "$tmp_mm" "$mm_dst"; then
      warn "Failed to install MokManager to $mm_dst"
      rm -rf "$tmp_dir" || true
      restore_changed_targets "$mm_dst" "$mm_backup"
      restore_changed_targets "${changed[@]}"
      return 1
    fi
    changed+=("$mm_dst" "$mm_backup")
  fi

  rm -rf "$tmp_dir" || true

  local failed=0
  if ! cmp -s "$shim_src" "$shim_dst"; then
    warn "Verification failed: $shim_src != $shim_dst"
    failed=1
  fi
  if ! cmp -s "$mm_src" "$mm_dst"; then
    warn "Verification failed: $mm_src != $mm_dst"
    failed=1
  fi

  if (( failed != 0 )); then
    restore_changed_targets "${changed[@]}"
    return 1
  fi

  log "Verified shim and MokManager ESP copies match installed sources."
}

check_shim_esp_status() {
  local esp="$1"
  local shim_src="$2"
  local mm_src="$3"
  local boot_dir="$esp/EFI/BOOT"
  local shim_dst="$boot_dir/BOOTx64.EFI"
  local mm_dst="$boot_dir/mmx64.efi"
  local failed=0

  validate_source "shim" "$shim_src" || failed=1
  validate_source "MokManager" "$mm_src" || failed=1
  if (( failed != 0 )); then
    return 1
  fi

  status_one "shim" "$shim_src" "$shim_dst" || failed=1
  status_one "MokManager" "$mm_src" "$mm_dst" || failed=1

  return "$failed"
}

main() {
  local mode="sync"
  local esp=""
  local esp_explicit=0
  local shim_src="${SHIM_SYNC_SHIM_SRC:-}"
  local mm_src="${SHIM_SYNC_MM_SRC:-}"

  while (( $# > 0 )); do
    case "$1" in
      --sync)
        mode="sync"
        ;;
      --check)
        mode="check"
        ;;
      --print-sources)
        mode="print-sources"
        ;;
      --esp)
        shift
        [[ $# -gt 0 ]] || { warn "--esp requires a path"; return 2; }
        esp="$1"
        esp_explicit=1
        ;;
      --shim-src)
        shift
        [[ $# -gt 0 ]] || { warn "--shim-src requires a path"; return 2; }
        shim_src="$1"
        ;;
      --mm-src)
        shift
        [[ $# -gt 0 ]] || { warn "--mm-src requires a path"; return 2; }
        mm_src="$1"
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        if [[ -z "$esp" ]]; then
          esp="$1"
          esp_explicit=1
        else
          warn "Unexpected argument: $1"
          usage >&2
          return 2
        fi
        ;;
    esac
    shift
  done

  if [[ -z "$shim_src" || -z "$mm_src" ]]; then
    IFS='|' read -r shim_src mm_src < <(detect_shim_sources)
  fi

  if [[ "$mode" == "print-sources" ]]; then
    printf '%s|%s\n' "$shim_src" "$mm_src"
    return 0
  fi

  if [[ -z "$esp" ]]; then
    esp="$(load_esp_from_config)" || return 1
  fi

  if (( esp_explicit == 0 )); then
    ensure_configured_esp_mounted "$esp" || return 1
  fi

  case "$mode" in
    sync)
      sync_shim_to_esp "$esp" "$shim_src" "$mm_src"
      ;;
    check)
      check_shim_esp_status "$esp" "$shim_src" "$mm_src"
      ;;
    *)
      warn "Unknown mode: $mode"
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
