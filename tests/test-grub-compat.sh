#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_CP="$(command -v cp)"
REAL_MV="$(command -v mv)"
REAL_OBJCOPY="$(command -v objcopy || true)"
export REAL_CP REAL_MV
fail() { echo "[FAIL] $*" >&2; exit 1; }
assert_has() { grep -Fq -- "$2" "$1" || fail "Expected '$2' in $1: $(cat "$1")"; }
assert_lacks() { if grep -Fq -- "$2" "$1"; then fail "Unexpected '$2' in $1"; fi; }
assert_same() { cmp -s "$1" "$2" || fail "Files differ: $1 $2"; }

fixture() {
  T="$1"
  export TEST_ROOT="$T" TEST_MODE="" MOK_STATUS=0 MOK_TEXT="$T/etc/secureboot/mok/MOK.cer is already enrolled" MOK_STDERR=""
  mkdir -p "$T/repo" "$T/bin" "$T/run" "$T/etc/secureboot/mok" "$T/boot" \
    "$T/usr/lib/grub/x86_64-efi" "$T/usr/share/grub" "$T/usr/local/sbin" "$T/usr/local/lib/sb-install" \
    "$T/esp/EFI/GRUB" "$T/esp/EFI/BOOT"
  cp "$ROOT_DIR/install.sh" "$ROOT_DIR/refresh.sh" "$ROOT_DIR/uninstall.sh" "$T/repo/"
  cp -r "$ROOT_DIR/lib" "$ROOT_DIR/grub-standalone" "$ROOT_DIR/kernel" "$ROOT_DIR/shim" "$T/repo/"
  # Relocate fixed production paths only in disposable test copies. No production
  # test bypasses, privileged operations, real keys, mounts or firmware access.
  while IFS= read -r -d '' file; do
    sed -i \
      -e "s|/etc/secureboot|$T/etc/secureboot|g" \
      -e "s|/etc/pacman.d|$T/etc/pacman.d|g" \
      -e "s|/usr/local|$T/usr/local|g" \
      -e "s|/usr/lib/grub|$T/usr/lib/grub|g" \
      -e "s|/usr/share/grub|$T/usr/share/grub|g" \
      -e "s|/var/lib/secureboot|$T/var/lib/secureboot|g" \
      -e "s|/run/grub|$T/run/grub|g" \
      -e "s|/boot/vmlinuz-|$T/boot/vmlinuz-|g" "$file"
  done < <(find "$T/repo" -name '*.sh' -print0)
  cp "$T/repo/lib/grub-compat.sh" "$T/repo/lib/mok-enrollment.sh" "$T/usr/local/lib/sb-install/"
  cp "$T/repo/grub-standalone/build-grub-standalone.sh" "$T/usr/local/sbin/grub-standalone-rebuild.sh"
  cp "$T/repo/kernel/kernel-sbsign-all.sh" "$T/usr/local/sbin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/usr/local/sbin/secureboot-shim-sync"
  chmod +x "$T/usr/local/sbin/"*
  MOD="$T/usr/lib/grub/x86_64-efi"
  printf 'normal: boot\n' > "$MOD/moddep.lst"
  for module in normal boot linux efi_gop; do printf 'module' > "$MOD/$module.mod"; done
  HEADER='sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md'
  GLOBAL='grub,6,Free Software Foundation,grub,2.16,https://www.gnu.org/software/grub/'
  VENDOR='grub.arch,1,Arch Linux,grub,2:2.16-1,https://archlinux.org/packages/core/x86_64/grub/'
  printf '%s\n' "$HEADER" "$GLOBAL" > "$MOD/sbat.csv"
  printf '%s\n' "$HEADER" 'grub,4,Free Software Foundation,grub,2:2.16-1,https//www.gnu.org/software/grub/' "$VENDOR" > "$T/usr/share/grub/sbat.csv"
  for key in key crt cer; do printf 'test key fixture' > "$T/etc/secureboot/mok/MOK.$key"; done
  cat > "$T/etc/secureboot/grub-standalone.conf" <<CONF
ESP_MOUNT="$T/esp"
ESP_DEV="/dev/mock-esp"
GRUB_ID="GRUB"
MOK_KEY="$T/etc/secureboot/mok/MOK.key"
MOK_CRT="$T/etc/secureboot/mok/MOK.crt"
MOK_CER="$T/etc/secureboot/mok/MOK.cer"
MODULES="normal boot linux efi_gop efi_uga"
THEME_DIR="$T/theme"
THEME_NAME="custom"
SPLASH_SRC="$T/splash.png"
WATCH_DIRS=("/custom/config" "/custom/themes")
CONF
  cp "$T/etc/secureboot/grub-standalone.conf" "$T/original.conf"
  printf 'old vendor' > "$T/esp/EFI/GRUB/grubx64.efi"
  printf 'old fallback' > "$T/esp/EFI/BOOT/grubx64.efi"
  printf 'shim must survive' > "$T/esp/EFI/BOOT/BOOTx64.EFI"
  cp "$T/esp/EFI/GRUB/grubx64.efi" "$T/vendor.before"
  cp "$T/esp/EFI/BOOT/grubx64.efi" "$T/fallback.before"
  cp "$T/esp/EFI/BOOT/BOOTx64.EFI" "$T/shim.before"
  printf 'unsigned kernel' > "$T/boot/vmlinuz-test"
  cp "$T/boot/vmlinuz-test" "$T/kernel.before"
  cat > "$T/bin/mock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
name="${0##*/}"
printf '%s' "$name" >> "$TEST_ROOT/commands"
printf ' <%s>' "$@" >> "$TEST_ROOT/commands"
printf '\n' >> "$TEST_ROOT/commands"
case "$name" in
  id) echo "${TEST_UID:-0}" ;;
  mountpoint) [[ "$TEST_MODE" != mount-fail ]] ;;
  mount) exit 19 ;;
  pacman)
    [[ "$1" == -Qqo ]] || exit 90
    if [[ "$TEST_MODE" == wrong-package && "$2" == */share/grub/* ]]; then echo other-grub; else echo grub; fi
    ;;
  grub-mkconfig) printf 'set timeout=2\n' > "$2" ;;
  grub-mkstandalone)
    [[ "$TEST_MODE" != build-fail ]] || { echo 'build failed diagnostic' >&2; exit 21; }
    sbat='' output=''
    while (( $# )); do
      case "$1" in
        --sbat) sbat="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        --directory) [[ "$2" == "$TEST_ROOT/usr/lib/grub/x86_64-efi" ]] || exit 92; shift 2 ;;
        --modules) printf '%s\n' "$2" > "$TEST_ROOT/effective-modules"; shift 2 ;;
        *) shift ;;
      esac
    done
    "$REAL_CP" "$sbat" "$TEST_ROOT/selected.csv"
    "$REAL_CP" "$sbat" "$output"
    case "$TEST_MODE" in
      build-warning) echo 'warning: supplied SBAT global generation 4 does not match build-time global generation 6' >&2 ;;
      no-sbat) : > "$output" ;;
      empty-sbat) printf 'no section\n' > "$output" ;;
      malformed-image-sbat) printf 'grub,6\n' > "$output" ;;
      wrong-image-sbat) sed -i 's/grub,6,/grub,4,/' "$output" ;;
      lost-vendor) sed -i '/^grub.arch,/d' "$output" ;;
      nul-in-sbat) printf '\0hidden\n' >> "$output" ;;
    esac
    ;;
  objcopy)
    [[ "$1" == --dump-section && "$2" == .sbat=* ]] || exit 93
    [[ "$TEST_MODE" != objcopy-fail ]] || exit 26
    if [[ "$TEST_MODE" == empty-sbat ]]; then : > "${2#*=}"; else "$REAL_CP" "$3" "${2#*=}"; fi
    ;;
  sbsign)
    [[ "$1" == --key && "$3" == --cert && "$5" == --output && "$#" == 7 ]] || exit 94
    [[ "$TEST_MODE" != sign-fail ]] || { echo 'signing failed diagnostic' >&2; exit 22; }
    "$REAL_CP" "$7" "$6"
    if [[ "$TEST_MODE" == empty-signed ]]; then : > "$6"; fi
    if [[ "$TEST_MODE" == signed-sbat-corrupt ]]; then printf 'broken\n' > "$6"; fi
    ;;
  sbverify)
    [[ "$#" == 3 && "$1" == --cert && "$2" == "$TEST_ROOT/etc/secureboot/mok/MOK.crt" ]] || { echo 'Bad sbverify arguments' >&2; exit 95; }
    [[ -s "$3" ]] || exit 96
    [[ "$TEST_MODE" != verify-fail ]] || { echo 'signature invalid diagnostic' >&2; exit 23; }
    # The original fixture kernel needs signing; temporary signed copies pass.
    [[ "$3" != "$TEST_ROOT/boot/vmlinuz-test" || "$TEST_MODE" == refresh-ok ]] || exit 1
    ;;
  cp)
    src="${@: -2:1}" dst="${@: -1}"
    if [[ "$TEST_MODE" == backup-fail && "$dst" == *.bak ]]; then exit 28; fi
    if [[ "$TEST_MODE" == stage-copy-fail && "$dst" == */.grub-deploy.*/new ]]; then exit 29; fi
    "$REAL_CP" "$@"
    if [[ "$TEST_MODE" == stage-corrupt && "$dst" == */.grub-deploy.*/new ]]; then printf 'corrupt' > "$dst"; fi
    ;;
  mv)
    src="${@: -2:1}" dst="${@: -1}"
    if [[ "$TEST_MODE" == install-fail && "$src" == */new && "$dst" == */EFI/BOOT/grubx64.efi ]]; then exit 30; fi
    "$REAL_MV" "$@"
    if [[ "$TEST_MODE" == install-corrupt && "$src" == */new ]]; then printf 'corrupt' > "$dst"; fi
    ;;
  sudo)
    case "${1:-}" in -v) exit 0 ;; -n) shift ;; esac
    exec "$@"
    ;;
  mokutil)
    if [[ "$1" == --sb-state ]]; then echo 'SecureBoot enabled'; exit 0; fi
    [[ "$1" == --test-key && "$2" == "$TEST_ROOT/etc/secureboot/mok/MOK.cer" ]] || exit 97
    [[ "$LC_ALL" == C ]] || { echo "Incorrect query locale" >&2; exit 98; }
    if [[ -n "$MOK_STDERR" ]]; then printf '%s\n' "$MOK_STDERR" >&2; fi
    printf '%s\n' "$MOK_TEXT"
    exit "$MOK_STATUS"
    ;;
  efibootmgr|sbctl|yay) echo 'Unexpected firmware/package operation' >&2; exit 98 ;;
  *) echo "Unknown mock $name" >&2; exit 99 ;;
esac
MOCK
  chmod +x "$T/bin/mock"
  for cmd in id mountpoint mount pacman grub-mkconfig grub-mkstandalone objcopy sbsign sbverify cp mv sudo mokutil efibootmgr sbctl yay; do
    ln -s mock "$T/bin/$cmd"
  done
  export PATH="$T/bin:$PATH"
}

builder() { bash "$T/repo/grub-standalone/build-grub-standalone.sh" > "$T/out" 2>&1; }
unchanged() {
  assert_same "$T/vendor.before" "$T/esp/EFI/GRUB/grubx64.efi"
  assert_same "$T/fallback.before" "$T/esp/EFI/BOOT/grubx64.efi"
  assert_same "$T/shim.before" "$T/esp/EFI/BOOT/BOOTx64.EFI"
  assert_same "$T/original.conf" "$T/etc/secureboot/grub-standalone.conf"
}
expect_builder_failure() {
  if builder; then fail "Builder unexpectedly succeeded ($TEST_MODE): $(cat "$T/out")"; fi
  unchanged
  assert_lacks "$T/out" 'Rebuilt, signed and verified'
}
case_success() {
  builder || fail "Builder failed: $(cat "$T/out")"
  assert_has "$T/selected.csv" "$GLOBAL"
  assert_has "$T/selected.csv" "$VENDOR"
  assert_lacks "$T/selected.csv" 'grub,4,'
  assert_lacks "$T/effective-modules" 'efi_uga'
  assert_has "$T/effective-modules" 'normal boot linux efi_gop'
  assert_has "$T/out" 'Legacy optional module efi_uga'
  assert_has "$T/out" 'Selected SBAT grub generation 6'
  assert_has "$T/out" 'Selected SBAT grub.arch generation 1'
  assert_same "$T/selected.csv" "$T/esp/EFI/GRUB/grubx64.efi"
  assert_same "$T/selected.csv" "$T/esp/EFI/BOOT/grubx64.efi"
  assert_same "$T/shim.before" "$T/esp/EFI/BOOT/BOOTx64.EFI"
  assert_same "$T/original.conf" "$T/etc/secureboot/grub-standalone.conf"
  assert_same "$T/vendor.before" "$T/esp/EFI/GRUB/backup/grubx64.efi.bak"
}
case_available_uga() {
  printf module > "$MOD/efi_uga.mod"
  builder || fail "Builder failed: $(cat "$T/out")"
  assert_has "$T/effective-modules" 'efi_uga'
}
case_missing_modules() {
  printf '\nMODULES="normal efi_uga btrfs cryptodisk custom_module"\n' >> "$T/etc/secureboot/grub-standalone.conf"
  cp "$T/etc/secureboot/grub-standalone.conf" "$T/original.conf"
  expect_builder_failure
  assert_has "$T/out" 'btrfs cryptodisk custom_module'
  assert_lacks "$T/commands" 'grub-mkstandalone'
}
case_metadata() {
  case "$1" in
    missing) rm "$MOD/sbat.csv" "$T/usr/share/grub/sbat.csv" ;;
    empty) : > "$MOD/sbat.csv" ;;
    malformed) printf 'grub,six\n' > "$MOD/sbat.csv" ;;
    bad-shared) printf 'bad csv\n' > "$T/usr/share/grub/sbat.csv" ;;
    global-conflict) printf '%s\n' "${GLOBAL/grub,6/grub,7}" >> "$MOD/sbat.csv" ;;
    vendor-conflict) printf '%s\n' "${VENDOR/grub.arch,1/grub.arch,2}" >> "$MOD/sbat.csv" ;;
    wrong-package) TEST_MODE=wrong-package ;;
    wrong-platform) rm "$MOD/moddep.lst" ;;
  esac
  expect_builder_failure
  assert_lacks "$T/commands" 'grub-mkstandalone'
}
case_fallback() {
  rm "$MOD/sbat.csv"
  builder || fail "Fallback failed: $(cat "$T/out")"
  assert_has "$T/out" 'validating legacy shared fallback'
  assert_has "$T/selected.csv" 'grub,4,'
  assert_has "$T/selected.csv" "$VENDOR"
}
case_failure_mode() {
  TEST_MODE="$1"
  expect_builder_failure
  case "$1" in
    build-fail) assert_has "$T/out" 'build failed diagnostic' ;;
    build-warning) assert_has "$T/out" 'SBAT warning/mismatch; refusing deployment' ;;
    sign-fail) assert_has "$T/out" 'signing failed diagnostic' ;;
    verify-fail) assert_has "$T/out" 'signature invalid diagnostic' ;;
  esac
}
case_lock_busy() {
  exec 8> "$T/run/grub-standalone-rebuild.lock"
  flock 8
  expect_builder_failure
  assert_has "$T/out" 'Skipped: another'
}
case_missing_prerequisite() {
  case "$1" in
    config) rm "$T/etc/secureboot/grub-standalone.conf" ;;
    key) rm "$T/etc/secureboot/mok/MOK.key" ;;
    library) rm "$T/usr/local/lib/sb-install/grub-compat.sh" ;;
  esac
  if builder; then fail 'Missing prerequisite succeeded'; fi
  assert_same "$T/vendor.before" "$T/esp/EFI/GRUB/grubx64.efi"
  assert_same "$T/fallback.before" "$T/esp/EFI/BOOT/grubx64.efi"
}
case_kernel_failure() {
  TEST_MODE="$1"
  if bash "$T/repo/kernel/kernel-sbsign-all.sh" > "$T/out" 2>&1; then fail 'Kernel signing unexpectedly succeeded'; fi
  assert_same "$T/kernel.before" "$T/boot/vmlinuz-test"
}
case_kernel_success() {
  bash "$T/repo/kernel/kernel-sbsign-all.sh" > "$T/out" 2>&1 || fail "Kernel signing failed: $(cat "$T/out")"
  assert_has "$T/out" 'Signed OK:'
  local verify_line move_line
  verify_line="$(grep -n 'sbverify.*vmlinuz-test.signed.' "$T/commands" | cut -d: -f1)"
  move_line="$(grep -n '^mv ' "$T/commands" | cut -d: -f1)"
  [[ "$verify_line" -lt "$move_line" ]] || fail 'Kernel moved before verification'
}
refresh_fixture() {
  TEST_MODE=refresh-ok
  for helper in secureboot-shim-sync kernel-sbsign-all.sh grub-standalone-rebuild.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$T/usr/local/sbin/$helper"
  done
  cp "$T/esp/EFI/GRUB/grubx64.efi" "$T/esp/EFI/BOOT/grubx64.efi"
}
case_refresh() {
  refresh_fixture
  case "$1" in
    success) ;;
    kernel-fail) printf '#!/usr/bin/env bash\nexit 41\n' > "$T/usr/local/sbin/kernel-sbsign-all.sh" ;;
    grub-fail) printf '#!/usr/bin/env bash\nexit 42\n' > "$T/usr/local/sbin/grub-standalone-rebuild.sh" ;;
    grub-skipped) printf '#!/usr/bin/env bash\nexit 75\n' > "$T/usr/local/sbin/grub-standalone-rebuild.sh" ;;
    shim-fail) printf '#!/usr/bin/env bash\nexit 43\n' > "$T/usr/local/sbin/secureboot-shim-sync" ;;
    helper-missing) rm "$T/usr/local/sbin/kernel-sbsign-all.sh" ;;
    verify-fail) TEST_MODE=verify-fail ;;
    image-missing) rm "$T/esp/EFI/BOOT/grubx64.efi" ;;
    mount-fail) TEST_MODE=mount-fail ;;
    key-missing) rm "$T/etc/secureboot/mok/MOK.key" ;;
    config-missing) rm "$T/etc/secureboot/grub-standalone.conf" ;;
    not-enrolled) MOK_TEXT="$T/etc/secureboot/mok/MOK.cer is not enrolled"; MOK_STATUS=1 ;;
    inconclusive) MOK_TEXT='Cannot access EFI variables'; MOK_STATUS=2 ;;
  esac
  if bash "$T/repo/refresh.sh" > "$T/out" 2>&1; then
    [[ "$1" == success ]] || fail "Refresh unexpectedly succeeded: $1"
    assert_has "$T/out" 'Refresh and verification completed successfully'
  else
    [[ "$1" != success ]] || fail "Refresh failed: $(cat "$T/out")"
    assert_lacks "$T/out" 'Refresh and verification completed successfully'
  fi
}
case_mok() {
  # shellcheck source=lib/checkhealth.sh
  source "$T/repo/lib/checkhealth.sh"
  h_ok() { echo "OK $*"; }
  h_fail() { echo "FAIL $*"; }
  h_warn() { echo "WARN $*"; }
  h_info() { echo "INFO $*"; }
  MOK_STATUS="$1" MOK_TEXT="${2//%CERT%/$T/etc/secureboot/mok/MOK.cer}"
  check_mok_enrollment "$T/etc/secureboot/mok/MOK.cer" > "$T/out"
  assert_has "$T/out" "$3"
  assert_has "$T/out" "status $MOK_STATUS"
  if [[ "$3" != 'OK MOK is enrolled' ]]; then assert_lacks "$T/out" 'OK MOK is enrolled'; fi
}
case_mok_callers() {
  local query_status="$1" response="$2" expected="$3" query_cert="$T/etc/secureboot/mok/MOK.cer"
  refresh_fixture
  MOK_STATUS="$query_status" MOK_TEXT="${response//%CERT%/$query_cert}"
  MOK_STDERR="${4:-}"
  # Even a config-selected locale must not affect the enrollment query.
  printf '\nLC_ALL=POSIX\n' >> "$T/etc/secureboot/grub-standalone.conf"
  (
    # shellcheck source=lib/checkhealth.sh
    source "$T/repo/lib/checkhealth.sh"
    h_ok() { echo "OK $*"; }
    h_fail() { echo "FAIL $*"; }
    h_warn() { echo "WARN $*"; }
    h_info() { echo "INFO $*"; }
    check_mok_enrollment "$query_cert"
  ) > "$T/health.out"
  assert_has "$T/health.out" "mokutil --test-key (status $query_status):"
  assert_has "$T/health.out" "$MOK_TEXT"
  if [[ "$expected" == enrolled ]]; then
    assert_has "$T/health.out" "OK MOK is enrolled: $query_cert"
    assert_lacks "$T/health.out" 'WARN'
    assert_lacks "$T/health.out" 'FAIL'
  else
    assert_lacks "$T/health.out" 'OK MOK is enrolled'
    if [[ "$expected" == not-enrolled ]]; then
      assert_has "$T/health.out" 'FAIL MOK NOT enrolled'
    else
      assert_has "$T/health.out" "WARN MOK enrollment check inconclusive (status $query_status)"
    fi
  fi
  if bash "$T/repo/refresh.sh" > "$T/out" 2>&1; then
    [[ "$expected" == enrolled ]] || fail "Refresh accepted '$MOK_TEXT' (status $query_status)"
    assert_has "$T/out" "MOK is enrolled: $query_cert"
    assert_has "$T/out" 'Refresh and verification completed successfully'
  else
    [[ "$expected" != enrolled ]] || fail "Refresh rejected confirmed enrollment: $(cat "$T/out")"
    assert_lacks "$T/out" 'MOK is enrolled:'
    assert_lacks "$T/out" 'Refresh and verification completed successfully'
  fi
  assert_has "$T/out" "mokutil --test-key (status $query_status):"
  assert_has "$T/out" "$MOK_TEXT"
  if [[ -n "$MOK_STDERR" ]]; then
    assert_has "$T/out" "$MOK_STDERR"
    assert_has "$T/health.out" "$MOK_STDERR"
  fi
}
case_mok_missing_file() {
  case "$1" in
    missing) rm "$T/etc/secureboot/mok/MOK.cer" ;;
    empty) : > "$T/etc/secureboot/mok/MOK.cer" ;;
  esac
  refresh_fixture
  if bash "$T/repo/refresh.sh" > "$T/out" 2>&1; then fail 'Refresh accepted absent/empty certificate'; fi
  assert_lacks "$T/commands" 'mokutil'
  (
    # shellcheck source=lib/checkhealth.sh
    source "$T/repo/lib/checkhealth.sh"
    h_fail() { echo "FAIL $*"; }
    check_mok_enrollment "$T/etc/secureboot/mok/MOK.cer"
  ) > "$T/health.out"
  assert_has "$T/health.out" "FAIL Can't read MOK_CER"
  assert_lacks "$T/commands" 'mokutil'
}
case_legacy_mok_other_failure() {
  MOK_STATUS=1
  case_refresh "$1"
  assert_has "$T/out" 'MOK is enrolled:'
}
case_legacy_mok_full_health() {
  MOK_STATUS=1
  case_health_verification success
  assert_has "$T/out" 'MOK is enrolled:'
}
case_missing_enrollment_library() {
  refresh_fixture
  rm "$T/usr/local/lib/sb-install/mok-enrollment.sh"
  if bash "$T/repo/refresh.sh" > "$T/out" 2>&1; then fail 'Refresh accepted missing enrollment library'; fi
  assert_has "$T/out" 'reinstall helpers with install.sh option 5'
}
case_install_helpers() {
  rm -rf "${T:?}/usr/local"
  # Actual menu option 5, decline immediate health check; sudo and destinations
  # are mocked/relocated. It must not ask for config/keys/ESP or first-boot steps.
  printf '5\ny\nn\n' | TEST_UID=1000 bash "$T/repo/install.sh" > "$T/out" 2>&1 || fail "Option 5 failed: $(cat "$T/out")"
  for file in sbin/kernel-sbsign-all.sh sbin/secureboot-shim-sync sbin/grub-standalone-rebuild.sh sbin/secureboot-refresh lib/sb-install/grub-compat.sh lib/sb-install/mok-enrollment.sh; do
    [[ -s "$T/usr/local/$file" ]] || fail "Helper not installed: $file"
  done
  for hook in 95-kernel-sbsign 98-shim-sync 99-grub-standalone; do
    [[ -s "$T/etc/pacman.d/hooks/$hook.hook" ]] || fail "Hook missing: $hook"
  done
  assert_has "$T/out" 'Health check skipped.'
  assert_lacks "$T/out" 'Reboot and enable Secure Boot'
  assert_lacks "$T/commands" 'efibootmgr'
  assert_lacks "$T/commands" 'mokutil'
  if grep -q '^sbsign ' "$T/commands"; then fail "Option 5 signed an image"; fi
  unchanged
  for key in key crt cer; do
    [[ "$(cat "$T/etc/secureboot/mok/MOK.$key")" == 'test key fixture' ]] || fail "Option 5 changed MOK.$key"
  done
  # Installed builder can immediately repair the existing configuration.
  bash "$T/usr/local/sbin/grub-standalone-rebuild.sh" > "$T/out" 2>&1 || fail "Installed builder failed: $(cat "$T/out")"
  # Exercise the installed refresh and its installed enrollment dependency.
  refresh_fixture
  MOK_STATUS=1
  bash "$T/usr/local/sbin/secureboot-refresh" > "$T/out" 2>&1 || fail "Installed refresh failed: $(cat "$T/out")"
  assert_has "$T/out" 'MOK is enrolled:'
}
case_missing_tool() {
  export MISSING_TOOL="$2"
  cat > "$T/hide-tool.sh" <<'HIDE'
command() {
  if [[ "${1:-}" == -v && "${2:-}" == "$MISSING_TOOL" ]]; then return 1; fi
  builtin command "$@"
}
HIDE
  export BASH_ENV="$T/hide-tool.sh"
  case "$1" in
    builder) expect_builder_failure; assert_has "$T/out" "$MISSING_TOOL" ;;
    refresh)
      refresh_fixture
      if bash "$T/repo/refresh.sh" > "$T/out" 2>&1; then fail 'Refresh accepted missing tool'; fi
      assert_has "$T/out" "$MISSING_TOOL"
      ;;
    kernel)
      if bash "$T/repo/kernel/kernel-sbsign-all.sh" > "$T/out" 2>&1; then fail 'Kernel signer accepted missing tool'; fi
      assert_same "$T/kernel.before" "$T/boot/vmlinuz-test"
      ;;
  esac
}
case_health_verification() {
  refresh_fixture
  mkdir -p "$T/etc/pacman.d/hooks"
  cp "$T/repo/refresh.sh" "$T/usr/local/sbin/secureboot-refresh"
  printf 'Exec = %s\n' "$T/usr/local/sbin/kernel-sbsign-all.sh" > "$T/etc/pacman.d/hooks/95-kernel-sbsign.hook"
  printf 'Exec = %s\n' "$T/usr/local/sbin/secureboot-shim-sync" > "$T/etc/pacman.d/hooks/98-shim-sync.hook"
  printf 'Exec = %s\n' "$T/usr/local/sbin/grub-standalone-rebuild.sh" > "$T/etc/pacman.d/hooks/99-grub-standalone.hook"
  # Run the whole health check using only certificate verification; the sbverify
  # mock rejects every other argument form. Decline the optional snapshot check.
  if [[ "$1" == failure ]]; then TEST_MODE=verify-fail; fi
  if printf 'n\n' | bash -c 'source "$TEST_ROOT/repo/lib/checkhealth.sh"; checkhealth' > "$T/out" 2>&1; then
    [[ "$1" == success ]] || fail 'Health check masked signature failure'
    assert_has "$T/out" 'Health Check Result: PASS'
  else
    [[ "$1" == failure ]] || fail "Health check failed: $(cat "$T/out")"
    assert_has "$T/out" 'Health Check Result: FAIL'
  fi
  assert_has "$T/commands" 'sbverify <--cert>'
  assert_lacks "$T/commands" '<--list>'
}
case_mok_unavailable() {
  # shellcheck source=lib/checkhealth.sh
  source "$T/repo/lib/checkhealth.sh"
  h_warn() { echo "WARN $*"; }
  # Invoked indirectly by the sourced enrollment helper.
  # shellcheck disable=SC2329
  command() { if [[ "$1" == -v && "$2" == mokutil ]]; then return 1; fi; builtin command "$@"; }
  check_mok_enrollment "$T/etc/secureboot/mok/MOK.cer" > "$T/out"
  assert_has "$T/out" 'MOK enrollment check unavailable'
}
case_real_objcopy() {
  [[ -n "$REAL_OBJCOPY" ]] || { echo '[SKIP] real objcopy unavailable'; return; }
  # Real PE/COFF section extraction, without booting or needing a GRUB build.
  # shellcheck source=lib/grub-compat.sh
  source "$T/repo/lib/grub-compat.sh"
  mkdir "$T/inspect"
  printf 'fixture' > "$T/payload"
  "$REAL_OBJCOPY" -I binary -O pei-x86-64 -B i386:x86-64 --add-section ".sbat=$MOD/sbat.csv" "$T/payload" "$T/fixture.efi"
  objcopy() { "$REAL_OBJCOPY" "$@"; }
  grub_verify_sbat "$T/fixture.efi" "$MOD/sbat.csv" "$T/inspect" || fail 'Real PE SBAT extraction failed'
}
run_case() {
  local name="$1" tmp
  shift
  tmp="$(mktemp -d)"
  (
    trap 'rm -rf "$tmp"' EXIT
    fixture "$tmp"
    "$@"
  )
  echo "[OK] $name"
}

run_case 'platform generation 6 + shared vendor, configuration preserved' case_success
run_case 'available legacy efi_uga preserved' case_available_uga
run_case 'all missing requested modules reported' case_missing_modules
for mode in missing empty malformed bad-shared global-conflict vendor-conflict wrong-package wrong-platform; do
  run_case "SBAT/platform rejects $mode" case_metadata "$mode"
done
run_case 'validated shared-only legacy layout' case_fallback
for mode in build-fail build-warning no-sbat empty-sbat malformed-image-sbat wrong-image-sbat lost-vendor nul-in-sbat objcopy-fail sign-fail empty-signed signed-sbat-corrupt verify-fail backup-fail stage-copy-fail stage-corrupt install-fail install-corrupt mount-fail; do
  run_case "GRUB preserves live files on $mode" case_failure_mode "$mode"
done
run_case 'busy builder reports skipped and nonzero' case_lock_busy
for prerequisite in config key library; do run_case "missing builder $prerequisite" case_missing_prerequisite "$prerequisite"; done
for mode in sign-fail verify-fail empty-signed; do run_case "kernel preserves original on $mode" case_kernel_failure "$mode"; done
run_case 'kernel verifies temporary signature before replacement' case_kernel_success
for mode in success kernel-fail grub-fail grub-skipped shim-fail helper-missing verify-fail image-missing mount-fail key-missing config-missing not-enrolled inconclusive; do
  run_case "refresh $mode" case_refresh "$mode"
done
run_case 'MOK positive result' case_mok 0 '%CERT% is already enrolled' 'OK MOK is enrolled'
run_case 'MOK negative nonzero status' case_mok 1 '%CERT% is not enrolled' 'FAIL MOK NOT enrolled'
run_case 'MOK negative text even with status zero' case_mok 0 '%CERT% is not enrolled' 'FAIL MOK NOT enrolled'
run_case 'MOK unexpected nonzero status preserved' case_mok 2 'EFI variables unavailable' 'WARN MOK enrollment check inconclusive (status 2)'
run_case 'MOK positive text cannot mask failure' case_mok 2 '%CERT% is already enrolled' 'WARN MOK enrollment check inconclusive (status 2)'
run_case 'helper-only menu option 5 is complete and preserves configuration' case_install_helpers
run_case 'real objcopy extracts PE SBAT' case_real_objcopy

run_case 'builder requires objcopy' case_missing_tool builder objcopy
run_case 'builder requires package ownership tool for shared SBAT' case_missing_tool builder pacman
run_case 'refresh requires sbverify' case_missing_tool refresh sbverify
run_case 'refresh reports unavailable enrollment check' case_missing_tool refresh mokutil
run_case 'kernel signer requires sbsign' case_missing_tool kernel sbsign
run_case 'health check uses valid certificate verification' case_health_verification success
run_case 'health check propagates signature failure' case_health_verification failure
run_case 'health check reports unavailable MOK check' case_mok_unavailable

# mokutil 0.7.2 and newer behavior: the complete message AND status matter.
for status in 0 1; do
  run_case "MOK both callers: exact affirmative, status $status" case_mok_callers "$status" '%CERT% is already enrolled' enrolled
  run_case "MOK both callers: explicit negative, status $status" case_mok_callers "$status" '%CERT% is not enrolled' not-enrolled
  for result in 'is already in the enrollment request' 'is already blocked' 'is already in db' 'is already in the built-in keyring' 'is enrolled' 'is already enrolled (pending)' 'unknown result'; do
    run_case "MOK both callers: $result, status $status" case_mok_callers "$status" "%CERT% $result" inconclusive
  done
  run_case "MOK both callers: empty output, status $status" case_mok_callers "$status" '' inconclusive
  run_case "MOK both callers: wrong certificate, status $status" case_mok_callers "$status" '/another/MOK.cer is already enrolled' inconclusive
  run_case "MOK both callers: contradictory output, status $status" case_mok_callers "$status" $'%CERT% is already enrolled\n%CERT% is not enrolled' inconclusive
  run_case "MOK both callers: extra stderr, status $status" case_mok_callers "$status" '%CERT% is already enrolled' inconclusive 'Failed to read EFI variable MokListRT'
done
for status in 2 127 255; do
  run_case "MOK both callers: affirmative with error status $status" case_mok_callers "$status" '%CERT% is already enrolled' inconclusive
done
for error in 'EFI variables are not supported on this system' 'Failed to read certificate' 'Permission denied' 'Not a valid x509 certificate in DER format'; do
  run_case "MOK both callers: $error" case_mok_callers 255 "$error" inconclusive
done
for state in missing empty; do run_case "MOK certificate $state" case_mok_missing_file "$state"; done
for failure in grub-fail kernel-fail shim-fail verify-fail; do
  run_case "Confirmed legacy MOK cannot mask $failure" case_legacy_mok_other_failure "$failure"
done
run_case 'Full health check accepts status 1 confirmed enrollment' case_legacy_mok_full_health
run_case 'Refresh diagnoses missing installed MOK library' case_missing_enrollment_library
