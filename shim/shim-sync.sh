#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="${SB_SHIM_SYNC_LOG_PREFIX:-secureboot-shim-sync}"
CONF="${SB_SHIM_SYNC_CONF:-/etc/secureboot/grub-standalone.conf}"
LOCK_PATH="${SB_SHIM_SYNC_LOCK:-/run/secureboot-shim-sync.lock}"
LOCK_TIMEOUT="${SB_SHIM_SYNC_LOCK_TIMEOUT:-60}"
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
}

acquire_sync_lock() {
  command -v flock >/dev/null 2>&1 || {
    warn "Missing required command for synchronization lock: flock"
    return 1
  }

  local lock_dir
  lock_dir="$(dirname -- "$LOCK_PATH")"
  if ! mkdir -p "$lock_dir"; then
    warn "Could not create lock directory: $lock_dir"
    return 1
  fi

  exec 9>"$LOCK_PATH" || {
    warn "Could not open lock file: $LOCK_PATH"
    return 1
  }

  log "Waiting for synchronization lock: $LOCK_PATH"
  if ! flock -w "$LOCK_TIMEOUT" 9; then
    warn "Timed out after ${LOCK_TIMEOUT}s waiting for synchronization lock: $LOCK_PATH"
    return 1
  fi
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
  local outvar="$3"
  local base
  base="$(basename -- "$path")"

  printf -v "$outvar" '%s' ""

  if [[ ! -e "$path" ]]; then
    return 0
  fi

  local ts backup latest meta latest_tmp latest_meta_tmp
  ts="$(date -u +%Y%m%d-%H%M%S)"
  backup="$backup_dir/${base}.sb-install.${ts}.bak"
  latest="$backup_dir/${base}.bak"
  meta="${backup}.meta"
  latest_tmp="$backup_dir/.${base}.bak.$$"
  latest_meta_tmp="$backup_dir/.${base}.bak.meta.$$"

  cleanup_failed_backup() {
    rm -f "$backup" "$meta" "$latest_tmp" "$latest_meta_tmp" 2>/dev/null || true
  }

  if ! mkdir -p "$backup_dir"; then
    warn "Could not create backup directory: $backup_dir"
    return 1
  fi

  if ! cp -f "$path" "$backup"; then
    warn "Could not create timestamped backup: $backup"
    cleanup_failed_backup
    return 1
  fi
  if [[ ! -f "$backup" ]] || ! cmp -s "$path" "$backup"; then
    warn "Timestamped backup verification failed: $backup"
    cleanup_failed_backup
    return 1
  fi

  if ! {
    cat > "$meta" <<EOF
created_by=sb-install
source_path=$path
backup_time=$ts
run_id=$RUN_ID
EOF
  }; then
    warn "Could not write backup metadata: $meta"
    cleanup_failed_backup
    return 1
  fi
  if [[ ! -f "$meta" ]]; then
    warn "Backup metadata was not created: $meta"
    cleanup_failed_backup
    return 1
  fi

  if ! cp -f "$path" "$latest_tmp"; then
    warn "Could not create latest-backup temporary copy: $latest_tmp"
    cleanup_failed_backup
    return 1
  fi
  if [[ ! -f "$latest_tmp" ]] || ! cmp -s "$path" "$latest_tmp"; then
    warn "Latest-backup temporary copy verification failed: $latest_tmp"
    cleanup_failed_backup
    return 1
  fi

  if ! {
    cat > "$latest_meta_tmp" <<EOF
created_by=sb-install
source_path=$path
backup_time=$ts
run_id=$RUN_ID
EOF
  }; then
    warn "Could not write latest-backup metadata: $latest_meta_tmp"
    cleanup_failed_backup
    return 1
  fi
  if [[ ! -f "$latest_meta_tmp" ]]; then
    warn "Latest-backup metadata was not created: $latest_meta_tmp"
    cleanup_failed_backup
    return 1
  fi

  if ! mv -f "$latest_tmp" "$latest"; then
    warn "Could not install latest-backup copy: $latest"
    cleanup_failed_backup
    return 1
  fi
  if ! mv -f "$latest_meta_tmp" "${latest}.meta"; then
    warn "Could not install latest-backup metadata: ${latest}.meta"
    cleanup_failed_backup
    return 1
  fi

  printf -v "$outvar" '%s' "$backup"
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

prune_completed_backups() {
  local backup_dir="$1"
  shift

  local base
  for base in "$@"; do
    prune_backups "$backup_dir" "$base" "$BACKUP_KEEP"
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
  local -a prune_after_success=()
  local shim_backup="" mm_backup=""

  if (( shim_current == 0 )); then
    backup_esp_file "$shim_dst" "$backup_dir" shim_backup || {
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
    [[ -n "$shim_backup" ]] && prune_after_success+=("$(basename -- "$shim_dst")")
  fi

  if (( mm_current == 0 )); then
    backup_esp_file "$mm_dst" "$backup_dir" mm_backup || {
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
    [[ -n "$mm_backup" ]] && prune_after_success+=("$(basename -- "$mm_dst")")
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

  prune_completed_backups "$backup_dir" "${prune_after_success[@]}"
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
    local detected_shim detected_mm
    IFS='|' read -r detected_shim detected_mm < <(detect_shim_sources)
    shim_src="${shim_src:-$detected_shim}"
    mm_src="${mm_src:-$detected_mm}"
  fi

  if [[ "$mode" == "print-sources" ]]; then
    printf '%s|%s\n' "$shim_src" "$mm_src"
    return 0
  fi

  if [[ "$mode" == "sync" ]]; then
    if ! acquire_sync_lock; then
      return 1
    fi
  fi

  if [[ -z "$esp" ]]; then
    load_esp_from_config || return 1
    esp="$ESP_MOUNT"
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
