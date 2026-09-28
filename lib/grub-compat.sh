#!/usr/bin/env bash
# Shared by the installer and standalone builder. No configuration writes.

grub_platform_dir() {
  local dir="${GRUB_MODULE_DIR:-/usr/lib/grub/x86_64-efi}"
  dir="$(readlink -f -- "$dir")" || return 1
  if [[ "${dir##*/}" != x86_64-efi || ! -r "$dir/moddep.lst" || ! -s "$dir/normal.mod" ]]; then
    echo "Invalid x86_64-efi module directory: $dir" >&2
    return 1
  fi
  printf '%s\n' "$dir"
}

grub_effective_modules() {
  local dir="$1" requested="$2" module
  local -a effective=() missing=() words=()
  # Split whitespace, including multiline MODULES, without pathname expansion.
  read -r -a words <<< "${requested//$'\n'/ }"
  for module in "${words[@]}"; do
    if [[ ! "$module" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
      missing+=("$module (invalid module name)")
    elif [[ -s "$dir/$module.mod" && -r "$dir/$module.mod" ]]; then
      effective+=("$module")
    elif [[ "$module" == efi_uga ]]; then
      echo "[WARN] Legacy optional module efi_uga is absent in $dir; omitting it for this build only." >&2
    else
      missing+=("$module")
    fi
  done
  if (( ${#missing[@]} )); then
    printf 'Missing requested GRUB modules in %s: %s\n' "$dir" "${missing[*]}" >&2
    return 1
  fi
  printf '%s\n' "${effective[*]}"
}

# Validate all rows before emitting a normalized, deduplicated CSV. A stale
# shared global row is valid metadata but is never merged over the platform row.
grub_validate_sbat() {
  local source="$1"
  [[ -r "$source" && -s "$source" ]] || { echo "Missing/empty SBAT: $source" >&2; return 1; }
  LC_ALL=C awk -F, '
    function bad(message) {
      print FILENAME ":" FNR ": " message > "/dev/stderr"
      failed=1
    }
    {
      sub(/\r$/, "")
      if (NF != 6 || $0 ~ /[[:cntrl:]]/ || $0 ~ /"/ ||
          $1 !~ /^[a-zA-Z0-9_.-]+$/ || $2 !~ /^[1-9][0-9]*$/) {
        bad("malformed SBAT row"); next
      }
      for (i=3; i<=6; i++) if ($i !~ /[^[:space:]]/) bad("empty SBAT field")
      if (FNR == 1 && $1 != "sbat") bad("SBAT header must be first")
      if ($1 == "sbat" && ($2 != "1" || $4 != "sbat" || $5 != "1")) bad("invalid SBAT header")
      if ($1 in row) {
        if (row[$1] != $0) bad("conflicting duplicate SBAT component: " $1)
      } else {
        row[$1]=$0; order[++count]=$1
      }
    }
    END {
      if (!("sbat" in row) || !("grub" in row)) bad("SBAT requires header and global grub row")
      if (failed) exit 1
      for (i=1; i<=count; i++) print row[order[i]]
    }
  ' "$source"
}

grub_prepare_sbat() {
  local dir="$1" shared="$2" work="$3" platform="$1/sbat.csv"
  local owner shared_owner platform_owner
  if [[ -e "$platform" || -L "$platform" ]]; then
    echo "[grub-standalone] Platform SBAT source: $platform"
    grub_validate_sbat "$platform" > "$work/platform.csv" || return 1
  else
    echo "[grub-standalone][WARN] No platform SBAT at $platform; validating legacy shared fallback." >&2
  fi
  if [[ -e "$shared" || -L "$shared" ]]; then
    # Do not mix metadata from an unrelated GRUB installation. Arch package
    # ownership ties the shared CSV to the selected modules (also for fallback).
    command -v pacman >/dev/null 2>&1 || { echo "pacman is required to establish SBAT package ownership" >&2; return 1; }
    owner="$(pacman -Qqo "$dir/moddep.lst")" || return 1
    shared_owner="$(pacman -Qqo "$shared")" || return 1
    [[ -n "$owner" && "$owner" == "$shared_owner" ]] || { echo "SBAT and modules belong to different packages" >&2; return 1; }
    if [[ -e "$platform" ]]; then
      platform_owner="$(pacman -Qqo "$platform")" || return 1
      [[ "$platform_owner" == "$owner" ]] || { echo "Platform SBAT and modules belong to different packages" >&2; return 1; }
    fi
    echo "[grub-standalone] Shared SBAT source: $shared (package $owner)"
    grub_validate_sbat "$shared" > "$work/shared.csv" || return 1
  fi
  if [[ -s "$work/platform.csv" ]]; then
    cp "$work/platform.csv" "$work/combined.csv" || return 1
    if [[ -s "$work/shared.csv" ]]; then
      # Preserve distribution GRUB entries verbatim; exclude shared sbat/grub.
      awk -F, '$1 ~ /^grub\./' "$work/shared.csv" >> "$work/combined.csv" || return 1
    fi
  elif [[ -s "$work/shared.csv" ]]; then
    cp "$work/shared.csv" "$work/combined.csv" || return 1
  else
    echo "No usable SBAT metadata for $dir" >&2
    return 1
  fi
  grub_validate_sbat "$work/combined.csv" > "$work/sbat.csv" || return 1
  awk -F, '{printf "[grub-standalone] Selected SBAT %s generation %s\n", $1, $2}' "$work/sbat.csv"
}

grub_verify_sbat() {
  local image="$1" intended="$2" work="$3"
  rm -f "$work/section.raw" || return 1
  # An explicit output path keeps objcopy from rewriting the inspected image.
  objcopy --dump-section ".sbat=$work/section.raw" "$image" "$work/inspection.efi" || return 1
  [[ -s "$work/section.raw" ]] || { echo "Missing/empty .sbat section: $image" >&2; return 1; }
  # PE section alignment may add trailing NULs, but interior NULs hide rows from
  # shim. Reject any nonzero byte after the first NUL before stripping padding.
  od -An -v -tu1 "$work/section.raw" | awk '
    { for (i=1; i<=NF; i++) { if ($i == 0) padding=1; else if (padding) exit 1 } }
  ' || { echo "Invalid NUL padding in .sbat: $image" >&2; return 1; }
  tr -d '\000' < "$work/section.raw" > "$work/section.csv" || return 1
  grub_validate_sbat "$work/section.csv" > "$work/section.valid.csv" || return 1
  LC_ALL=C sort "$intended" > "$work/expected.sorted" || return 1
  LC_ALL=C sort "$work/section.valid.csv" > "$work/actual.sorted" || return 1
  cmp -s "$work/expected.sorted" "$work/actual.sorted" || {
    echo "Embedded .sbat differs from selected metadata: $image" >&2
    diff -u "$work/expected.sorted" "$work/actual.sorted" >&2
    return 1
  }
}
