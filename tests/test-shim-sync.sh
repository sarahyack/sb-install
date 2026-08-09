#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/shim/shim-sync.sh"

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

run_sync() {
  local esp="$1"
  local src_dir="$2"
  shift 2
  SB_INSTALL_RUN_ID=test-run \
    SB_BACKUP_KEEP=5 \
    bash "$HELPER" --esp "$esp" \
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

run_case "already synchronized" case_already_synchronized
run_case "outdated ESP" case_outdated_esp
run_case "fresh destination" case_fresh_destination
run_case "missing shim source" case_missing_shim_source
run_case "missing MokManager source" case_missing_mokmanager_source
run_case "both binaries change" case_both_binaries_change
run_case "repeated execution" case_repeated_execution_noop
