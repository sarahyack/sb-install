#!/usr/bin/env bash

# Classify the complete LC_ALL=C output of mokutil --test-key for this exact
# certificate. mokutil 0.7.2 returns 1 for "is already enrolled"; newer versions
# return 0. Neither status alone establishes membership in the MOK list.
# Callers retain the original status/output for diagnostics and check file access.
mok_enrollment_result() {
  local cert="$1" status="$2" output="$3"
  if [[ -n "$cert" && ( "$status" == 0 || "$status" == 1 ) ]]; then
    if [[ "$output" == "$cert is already enrolled" ]]; then
      printf '%s\n' enrolled
      return 0
    elif [[ "$output" == "$cert is not enrolled" ]]; then
      printf '%s\n' not-enrolled
      return 0
    fi
  fi
  # Additional lines/diagnostics, other certificate names, pending or blocked
  # results, db/keyring membership and unexpected statuses are not confirmation.
  printf '%s\n' inconclusive
}
