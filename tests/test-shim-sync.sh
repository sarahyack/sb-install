#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/shim/shim-sync.sh"
REAL_CP="$(command -v cp)"
REAL_MV="$(command -v mv)"

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

assert_file_equals() {
  local expected="$1"
  local actual="$2"
  cmp -s "$expected" "$actual" || fail "files differ: $expected != $actual"
}

assert_text_equals() {
  local expected="$1"
  local actual_file="$2"
  local actual
  actual="$(cat "$actual_file")"
  [[ "$actual" == "$expected" ]] || fail "unexpected content in $actual_file: $actual"
}

count_backups() {
  local backup_dir="$1"
  local base="$2"
  if [[ ! -d "$backup_dir" ]]; then
    echo 0
    return 0
  fi
  find "$backup_dir" -type f -name "${base}.sb-install.*.bak" | wc -l | tr -d ' '
}

assert_no_backup() {
  local backup_dir="$1"
  local base="$2"
  [[ "$(count_backups "$backup_dir" "$base")" == "0" ]] || fail "unexpected backup for $base"
}

assert_one_backup_with_meta() {
  local backup_dir="$1"
  local base="$2"
  local target="$3"
  local expected_content="$4"
  local count backup

  count="$(count_backups "$backup_dir" "$base")"
  [[ "$count" == "1" ]] || fail "expected one backup for $base, got $count"

  backup="$(find "$backup_dir" -type f -name "${base}.sb-install.*.bak" -print -quit)"
  [[ -f "$backup.meta" ]] || fail "missing metadata for $backup"
  assert_text_equals "$expected_content" "$backup"
  grep -qx 'created_by=sb-install' "$backup.meta" || fail "missing created_by metadata"
  grep -Fqx "source_path=$target" "$backup.meta" || fail "missing source_path metadata"
  grep -qx 'run_id=test-run' "$backup.meta" || fail "missing run_id metadata"
  grep -Eq '^backup_time=[0-9]{8}-[0-9]{6}$' "$backup.meta" || fail "missing backup_time metadata"
}

write_sources() {
  local src_dir="$1"
  local shim_text="$2"
  local mm_text="$3"
  mkdir -p "$src_dir"
  printf '%s' "$shim_text" > "$src_dir/shimx64.efi"
  printf '%s' "$mm_text" > "$src_dir/mmx64.efi"
}

make_fixed_date() {
  local bin_dir="$1"
  local ts="$2"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/date" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$ts"
EOF
  chmod +x "$bin_dir/date"
}

make_backup_copy_failure() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/cp" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *.sb-install.*.bak)
      exit 13
      ;;
  esac
done
exec "$REAL_CP" "\$@"
EOF
  chmod +x "$bin_dir/cp"
}

make_latest_copy_failure() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/cp" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    */backup/.BOOTx64.EFI.bak.*)
      exit 14
      ;;
  esac
done
exec "$REAL_CP" "\$@"
EOF
  chmod +x "$bin_dir/cp"
}

make_mokmanager_install_failure() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/mv" <<EOF
#!/usr/bin/env bash
src="\${@: -2:1}"
dst="\${@: -1}"
if [[ "\$src" == */.sb-install-shim-sync.*/mmx64.efi && "\$dst" == */EFI/BOOT/mmx64.efi ]]; then
  exit 23
fi
exec "$REAL_MV" "\$@"
EOF
  chmod +x "$bin_dir/mv"
}

make_unmounted_esp_commands() {
  local bin_dir="$1"
  local log_path="$2"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/mountpoint" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "$bin_dir/mount" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\${1:-}" "\${2:-}" > "$log_path"
exit 0
EOF
  chmod +x "$bin_dir/mountpoint" "$bin_dir/mount"
}

run_sync() {
  local esp="$1"
  local src_dir="$2"
  local backup_keep="${SB_BACKUP_KEEP:-5}"
  local lock_path="${SB_SHIM_SYNC_LOCK:-$esp/.shim-sync.lock}"
  local lock_timeout="${SB_SHIM_SYNC_LOCK_TIMEOUT:-60}"
  shift 2
  SB_INSTALL_RUN_ID=test-run \
    SB_BACKUP_KEEP="$backup_keep" \
    SB_SHIM_SYNC_LOCK="$lock_path" \
    SB_SHIM_SYNC_LOCK_TIMEOUT="$lock_timeout" \
    bash "$HELPER" --esp "$esp" \
      --shim-src "$src_dir/shimx64.efi" \
      --mm-src "$src_dir/mmx64.efi" "$@"
}

run_check() {
  local esp="$1"
  local src_dir="$2"
  shift 2
  bash "$HELPER" --check --esp "$esp" \
    --shim-src "$src_dir/shimx64.efi" \
    --mm-src "$src_dir/mmx64.efi" "$@"
}

run_sync_from_config() {
  local conf="$1"
  local src_dir="$2"
  local lock_path="${SB_SHIM_SYNC_LOCK:-$(dirname -- "$conf")/.shim-sync.lock}"
  local lock_timeout="${SB_SHIM_SYNC_LOCK_TIMEOUT:-60}"
  shift 2
  SB_INSTALL_RUN_ID=test-run \
    SB_BACKUP_KEEP="${SB_BACKUP_KEEP:-5}" \
    SB_SHIM_SYNC_CONF="$conf" \
    SB_SHIM_SYNC_LOCK="$lock_path" \
    SB_SHIM_SYNC_LOCK_TIMEOUT="$lock_timeout" \
    bash "$HELPER" \
      --shim-src "$src_dir/shimx64.efi" \
      --mm-src "$src_dir/mmx64.efi" "$@"
}

run_case() {
  local name="$1"
  shift
  local tmp
  tmp="$(mktemp -d)"
  (
    trap 'rm -rf "$tmp"' EXIT
    "$@" "$tmp"
  )
  echo "[OK] $name"
}

case_already_synchronized() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"
  local out="$tmp/out"

  write_sources "$src" "shim-current" "mm-current"
  mkdir -p "$boot"
  cp "$src/shimx64.efi" "$boot/BOOTx64.EFI"
  cp "$src/mmx64.efi" "$boot/mmx64.efi"

  run_sync "$esp" "$src" >"$out"
  assert_file_equals "$src/shimx64.efi" "$boot/BOOTx64.EFI"
  assert_file_equals "$src/mmx64.efi" "$boot/mmx64.efi"
  assert_no_backup "$boot/backup" "BOOTx64.EFI"
  assert_no_backup "$boot/backup" "mmx64.efi"
  grep -q 'already current' "$out" || fail "no already-current log"
}

case_outdated_esp() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"

  write_sources "$src" "shim-new" "mm-current"
  mkdir -p "$boot"
  printf '%s' "shim-old" > "$boot/BOOTx64.EFI"
  cp "$src/mmx64.efi" "$boot/mmx64.efi"

  run_sync "$esp" "$src" >/dev/null
  assert_file_equals "$src/shimx64.efi" "$boot/BOOTx64.EFI"
  assert_file_equals "$src/mmx64.efi" "$boot/mmx64.efi"
  assert_one_backup_with_meta "$boot/backup" "BOOTx64.EFI" "$boot/BOOTx64.EFI" "shim-old"
  assert_no_backup "$boot/backup" "mmx64.efi"
}

case_fresh_destination() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"

  write_sources "$src" "shim-new" "mm-new"
  run_sync "$esp" "$src" >/dev/null
  assert_file_equals "$src/shimx64.efi" "$boot/BOOTx64.EFI"
  assert_file_equals "$src/mmx64.efi" "$boot/mmx64.efi"
  assert_no_backup "$boot/backup" "BOOTx64.EFI"
  assert_no_backup "$boot/backup" "mmx64.efi"
}

case_missing_shim_source() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"

  write_sources "$src" "shim-new" "mm-new"
  rm -f "$src/shimx64.efi"
  mkdir -p "$boot"
  printf '%s' "shim-old" > "$boot/BOOTx64.EFI"
  printf '%s' "mm-old" > "$boot/mmx64.efi"

  if run_sync "$esp" "$src" >/dev/null 2>&1; then
    fail "sync succeeded with missing shim source"
  fi
  assert_text_equals "shim-old" "$boot/BOOTx64.EFI"
  assert_text_equals "mm-old" "$boot/mmx64.efi"
  assert_no_backup "$boot/backup" "BOOTx64.EFI"
  assert_no_backup "$boot/backup" "mmx64.efi"
}

case_missing_mokmanager_source() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"

  write_sources "$src" "shim-new" "mm-new"
  rm -f "$src/mmx64.efi"
  mkdir -p "$boot"
  printf '%s' "shim-old" > "$boot/BOOTx64.EFI"
  printf '%s' "mm-old" > "$boot/mmx64.efi"

  if run_sync "$esp" "$src" >/dev/null 2>&1; then
    fail "sync succeeded with missing MokManager source"
  fi
  assert_text_equals "shim-old" "$boot/BOOTx64.EFI"
  assert_text_equals "mm-old" "$boot/mmx64.efi"
  assert_no_backup "$boot/backup" "BOOTx64.EFI"
  assert_no_backup "$boot/backup" "mmx64.efi"
}

case_both_binaries_change() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"

  write_sources "$src" "shim-new" "mm-new"
  mkdir -p "$boot"
  printf '%s' "shim-old" > "$boot/BOOTx64.EFI"
  printf '%s' "mm-old" > "$boot/mmx64.efi"

  run_sync "$esp" "$src" >/dev/null
  assert_file_equals "$src/shimx64.efi" "$boot/BOOTx64.EFI"
  assert_file_equals "$src/mmx64.efi" "$boot/mmx64.efi"
  assert_one_backup_with_meta "$boot/backup" "BOOTx64.EFI" "$boot/BOOTx64.EFI" "shim-old"
  assert_one_backup_with_meta "$boot/backup" "mmx64.efi" "$boot/mmx64.efi" "mm-old"
}

case_repeated_execution_noop() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"
  local before_shim before_mm after_shim after_mm
  local out="$tmp/out"

  write_sources "$src" "shim-new" "mm-new"
  mkdir -p "$boot"
  printf '%s' "shim-old" > "$boot/BOOTx64.EFI"
  printf '%s' "mm-old" > "$boot/mmx64.efi"

  run_sync "$esp" "$src" >/dev/null
  before_shim="$(count_backups "$boot/backup" "BOOTx64.EFI")"
  before_mm="$(count_backups "$boot/backup" "mmx64.efi")"
  run_sync "$esp" "$src" >"$out"
  after_shim="$(count_backups "$boot/backup" "BOOTx64.EFI")"
  after_mm="$(count_backups "$boot/backup" "mmx64.efi")"

  [[ "$before_shim" == "$after_shim" ]] || fail "repeated run created shim backup"
  [[ "$before_mm" == "$after_mm" ]] || fail "repeated run created MokManager backup"
  grep -q 'already current' "$out" || fail "no repeated already-current log"
}

case_backup_dir_creation_failure() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"

  write_sources "$src" "shim-new" "mm-new"
  mkdir -p "$boot"
  printf '%s' "shim-old" > "$boot/BOOTx64.EFI"
  printf '%s' "mm-old" > "$boot/mmx64.efi"
  printf '%s' "not-a-directory" > "$boot/backup"

  if run_sync "$esp" "$src" >/dev/null 2>&1; then
    fail "sync succeeded when backup directory creation failed"
  fi
  assert_text_equals "shim-old" "$boot/BOOTx64.EFI"
  assert_text_equals "mm-old" "$boot/mmx64.efi"
}

case_backup_copy_failure() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"
  local fakebin="$tmp/fakebin"

  write_sources "$src" "shim-new" "mm-new"
  mkdir -p "$boot"
  printf '%s' "shim-old" > "$boot/BOOTx64.EFI"
  printf '%s' "mm-old" > "$boot/mmx64.efi"
  make_backup_copy_failure "$fakebin"

  if PATH="$fakebin:$PATH" run_sync "$esp" "$src" >/dev/null 2>&1; then
    fail "sync succeeded when timestamped backup copy failed"
  fi
  assert_text_equals "shim-old" "$boot/BOOTx64.EFI"
  assert_text_equals "mm-old" "$boot/mmx64.efi"
  assert_no_backup "$boot/backup" "BOOTx64.EFI"
}

case_latest_backup_copy_failure() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"
  local fakebin="$tmp/fakebin"

  write_sources "$src" "shim-new" "mm-new"
  mkdir -p "$boot"
  printf '%s' "shim-old" > "$boot/BOOTx64.EFI"
  printf '%s' "mm-old" > "$boot/mmx64.efi"
  make_latest_copy_failure "$fakebin"

  if PATH="$fakebin:$PATH" run_sync "$esp" "$src" >/dev/null 2>&1; then
    fail "sync succeeded when latest-backup copy failed"
  fi
  assert_text_equals "shim-old" "$boot/BOOTx64.EFI"
  assert_text_equals "mm-old" "$boot/mmx64.efi"
  assert_no_backup "$boot/backup" "BOOTx64.EFI"
}

case_metadata_write_failure() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"
  local fakebin="$tmp/fakebin"
  local ts="20260101-000000"

  write_sources "$src" "shim-new" "mm-new"
  mkdir -p "$boot/backup/BOOTx64.EFI.sb-install.${ts}.bak.meta"
  printf '%s' "shim-old" > "$boot/BOOTx64.EFI"
  printf '%s' "mm-old" > "$boot/mmx64.efi"
  make_fixed_date "$fakebin" "$ts"

  if PATH="$fakebin:$PATH" run_sync "$esp" "$src" >/dev/null 2>&1; then
    fail "sync succeeded when metadata write failed"
  fi
  assert_text_equals "shim-old" "$boot/BOOTx64.EFI"
  assert_text_equals "mm-old" "$boot/mmx64.efi"
  assert_no_backup "$boot/backup" "BOOTx64.EFI"
}

case_keep_zero_does_not_break_rollback() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"
  local fakebin="$tmp/fakebin"

  write_sources "$src" "shim-new" "mm-new"
  mkdir -p "$boot"
  printf '%s' "shim-old" > "$boot/BOOTx64.EFI"
  printf '%s' "mm-old" > "$boot/mmx64.efi"
  make_mokmanager_install_failure "$fakebin"

  if SB_BACKUP_KEEP=0 PATH="$fakebin:$PATH" run_sync "$esp" "$src" >/dev/null 2>&1; then
    fail "sync succeeded when MokManager install was forced to fail"
  fi
  assert_text_equals "shim-old" "$boot/BOOTx64.EFI"
  assert_text_equals "mm-old" "$boot/mmx64.efi"
}

case_failure_after_first_destination_changes() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"
  local fakebin="$tmp/fakebin"

  write_sources "$src" "shim-new" "mm-new"
  mkdir -p "$boot"
  printf '%s' "shim-old" > "$boot/BOOTx64.EFI"
  printf '%s' "mm-old" > "$boot/mmx64.efi"
  make_mokmanager_install_failure "$fakebin"

  if PATH="$fakebin:$PATH" run_sync "$esp" "$src" >/dev/null 2>&1; then
    fail "sync succeeded when MokManager install was forced to fail"
  fi
  assert_text_equals "shim-old" "$boot/BOOTx64.EFI"
  assert_text_equals "mm-old" "$boot/mmx64.efi"
}

case_config_load_and_mount_uses_esp_dev() {
  local tmp="$1"
  local esp="$tmp/config-esp"
  local src="$tmp/src"
  local fakebin="$tmp/fakebin"
  local mount_log="$tmp/mount.log"
  local conf="$tmp/grub-standalone.conf"
  local boot="$esp/EFI/BOOT"

  write_sources "$src" "shim-new" "mm-new"
  cat > "$conf" <<EOF
ESP_MOUNT="$esp"
ESP_DEV="/dev/mock-esp"
EOF
  make_unmounted_esp_commands "$fakebin" "$mount_log"

  PATH="$fakebin:$PATH" run_sync_from_config "$conf" "$src" >/dev/null
  assert_text_equals "/dev/mock-esp|$esp" "$mount_log"
  assert_file_equals "$src/shimx64.efi" "$boot/BOOTx64.EFI"
  assert_file_equals "$src/mmx64.efi" "$boot/mmx64.efi"
}

case_check_mode_reports_without_modifying() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"

  write_sources "$src" "shim-current" "mm-current"
  mkdir -p "$boot"
  cp "$src/shimx64.efi" "$boot/BOOTx64.EFI"
  cp "$src/mmx64.efi" "$boot/mmx64.efi"

  run_check "$esp" "$src" >/dev/null
  assert_file_equals "$src/shimx64.efi" "$boot/BOOTx64.EFI"
  assert_file_equals "$src/mmx64.efi" "$boot/mmx64.efi"
  assert_no_backup "$boot/backup" "BOOTx64.EFI"
  assert_no_backup "$boot/backup" "mmx64.efi"

  printf '%s' "mm-stale" > "$boot/mmx64.efi"
  if run_check "$esp" "$src" >/dev/null 2>&1; then
    fail "--check succeeded with mismatched MokManager"
  fi
  assert_text_equals "mm-stale" "$boot/mmx64.efi"
  assert_no_backup "$boot/backup" "BOOTx64.EFI"
  assert_no_backup "$boot/backup" "mmx64.efi"
}

case_lock_waits_then_syncs_current_files() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"
  local lock="$tmp/shim-sync.lock"
  local ready="$tmp/holder-ready"
  local out="$tmp/out"
  local holder_pid

  write_sources "$src" "shim-new" "mm-new"
  mkdir -p "$boot"
  printf '%s' "shim-old" > "$boot/BOOTx64.EFI"
  printf '%s' "mm-old" > "$boot/mmx64.efi"

  (
    exec 8>"$lock"
    flock 8
    : > "$ready"
    sleep 1
  ) &
  holder_pid=$!
  for _ in {1..50}; do
    [[ -e "$ready" ]] && break
    sleep 0.05
  done
  [[ -e "$ready" ]] || fail "lock holder did not start"

  SB_SHIM_SYNC_LOCK="$lock" SB_SHIM_SYNC_LOCK_TIMEOUT=5 run_sync "$esp" "$src" >"$out"
  wait "$holder_pid"

  assert_file_equals "$src/shimx64.efi" "$boot/BOOTx64.EFI"
  assert_file_equals "$src/mmx64.efi" "$boot/mmx64.efi"
  grep -q 'Waiting for synchronization lock' "$out" || fail "lock wait was not logged"
  grep -q 'Verified shim and MokManager' "$out" || fail "sync did not report verification after waiting"
}

case_lock_timeout_fails_without_modifying() {
  local tmp="$1"
  local esp="$tmp/esp"
  local src="$tmp/src"
  local boot="$esp/EFI/BOOT"
  local lock="$tmp/shim-sync.lock"
  local ready="$tmp/holder-ready"
  local out="$tmp/out"
  local holder_pid

  write_sources "$src" "shim-new" "mm-new"
  mkdir -p "$boot"
  printf '%s' "shim-old" > "$boot/BOOTx64.EFI"
  printf '%s' "mm-old" > "$boot/mmx64.efi"

  (
    exec 8>"$lock"
    flock 8
    : > "$ready"
    sleep 2
  ) &
  holder_pid=$!
  for _ in {1..50}; do
    [[ -e "$ready" ]] && break
    sleep 0.05
  done
  [[ -e "$ready" ]] || fail "lock holder did not start"

  if SB_SHIM_SYNC_LOCK="$lock" SB_SHIM_SYNC_LOCK_TIMEOUT=1 run_sync "$esp" "$src" >"$out" 2>&1; then
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    fail "sync succeeded despite lock timeout"
  fi
  wait "$holder_pid"

  assert_text_equals "shim-old" "$boot/BOOTx64.EFI"
  assert_text_equals "mm-old" "$boot/mmx64.efi"
  grep -q 'Timed out' "$out" || fail "lock timeout was not reported"
  if grep -Eq 'Verified shim and MokManager|already current' "$out"; then
    fail "timeout output falsely reported success"
  fi
}

case_print_sources_preserves_explicit_shim() {
  local tmp="$1"
  local custom="$tmp/custom-shim.efi"
  local out shim mm

  out="$(bash "$HELPER" --print-sources --shim-src "$custom")"
  IFS='|' read -r shim mm <<< "$out"
  [[ "$shim" == "$custom" ]] || fail "explicit shim source was not preserved"
  [[ -n "$mm" ]] || fail "missing detected MokManager source"
}

case_print_sources_preserves_explicit_mokmanager() {
  local tmp="$1"
  local custom="$tmp/custom-mm.efi"
  local out shim mm

  out="$(bash "$HELPER" --print-sources --mm-src "$custom")"
  IFS='|' read -r shim mm <<< "$out"
  [[ -n "$shim" ]] || fail "missing detected shim source"
  [[ "$mm" == "$custom" ]] || fail "explicit MokManager source was not preserved"
}

run_case "already synchronized" case_already_synchronized
run_case "outdated ESP" case_outdated_esp
run_case "fresh destination" case_fresh_destination
run_case "missing shim source" case_missing_shim_source
run_case "missing MokManager source" case_missing_mokmanager_source
run_case "both binaries change" case_both_binaries_change
run_case "repeated execution" case_repeated_execution_noop
run_case "backup directory creation failure" case_backup_dir_creation_failure
run_case "backup copy failure" case_backup_copy_failure
run_case "latest backup copy failure" case_latest_backup_copy_failure
run_case "metadata write failure" case_metadata_write_failure
run_case "SB_BACKUP_KEEP=0 rollback" case_keep_zero_does_not_break_rollback
run_case "rollback after first destination changes" case_failure_after_first_destination_changes
run_case "config ESP_DEV mount" case_config_load_and_mount_uses_esp_dev
run_case "check mode does not modify" case_check_mode_reports_without_modifying
run_case "lock waits then syncs" case_lock_waits_then_syncs_current_files
run_case "lock timeout fails safely" case_lock_timeout_fails_without_modifying
run_case "print-sources preserves shim override" case_print_sources_preserves_explicit_shim
run_case "print-sources preserves MokManager override" case_print_sources_preserves_explicit_mokmanager
