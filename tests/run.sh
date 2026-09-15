#!/usr/bin/env bash
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$TESTS_DIR/lib/harness.sh"

KNOWN_SELECTORS=()

RESOLVED_SELECTORS=(
  schedule-user
  relative-path
  ancestor-path
  symlink-path
  same-second
  multi-host-staged
  broad-staging
  partial-tar
  manifest-memory
  empty-remote
  immutable-mirrors
  ssh-no-token
  retention-empty
  docs-private-key
  provider-hostname-fallback-todo4
  systemd-runtime-state-rollback
  retention-interrupt-postcommit
  f2-retention-durable-tristate
  f2-canonical-publication-shape
  f2-root-launcher-transaction
)

REGISTERED_SELECTORS=()

load_registered_selectors() {
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]+([a-z0-9][a-z0-9-]*)\)$ ]]; then
      REGISTERED_SELECTORS+=("${BASH_REMATCH[1]}")
    fi
  done < <(declare -f run_selector_function)
  [[ ${#REGISTERED_SELECTORS[@]} -gt 0 ]] || {
    printf 'ERROR: no registered selectors found\n' >&2
    return 1
  }
  validate_unique_selectors "${REGISTERED_SELECTORS[@]}"
}

usage() {
  printf 'Usage: bash tests/run.sh [selector ...]\n' >&2
  printf '       bash tests/run.sh --expect-known-failures <known-selector> [...]\n' >&2
}

is_known_selector() {
  local wanted="$1" selector
  for selector in "${KNOWN_SELECTORS[@]}"; do
    [[ "$selector" == "$wanted" ]] && return 0
  done
  return 1
}

is_resolved_selector() {
  local wanted="$1" selector
  for selector in "${RESOLVED_SELECTORS[@]}"; do
    [[ "$selector" == "$wanted" ]] && return 0
  done
  return 1
}

is_selector() {
  local wanted="$1" selector
  for selector in "${REGISTERED_SELECTORS[@]}"; do
    [[ "$selector" == "$wanted" ]] && return 0
  done
  return 1
}

is_exact_f3_run() {
  [[ $# -eq 5 ]] || return 1
  [[ "$1" == e2e-prepare-decrypt-publish &&
     "$2" == e2e-mirror-retry &&
     "$3" == e2e-multi-host-retention &&
     "$4" == e2e-systemd-render &&
     "$5" == e2e-migration-dry-run ]]
}

validate_unique_selectors() {
  local -A seen=()
  local selector
  for selector in "$@"; do
    if [[ -n "${seen[$selector]:-}" ]]; then
      printf 'ERROR: duplicate selector: %s\n' "$selector" >&2
      return 1
    fi
    seen[$selector]=1
  done
}

main() {
  local expect_known=0 selector status failures=0 default_run=0
  local -a selectors=()

  initialize_harness_run || return 2
  load_registered_selectors || return 2
  REGISTERED_SELECTORS+=(root-mode-trust)

  if [[ "${1:-}" == "--expect-known-failures" ]]; then
    expect_known=1
    shift
    if [[ $# -eq 0 ]]; then
      printf 'ERROR: --expect-known-failures requires at least one known selector\n' >&2
      usage
      return 64
    fi
  fi

  if [[ $# -eq 0 ]]; then
    default_run=1
    selectors=("${REGISTERED_SELECTORS[@]}")
    LLM_FIXTURE="${LLM_FIXTURE:-github-gitlab-weekly-nonroot}"
  else
    selectors=("$@")
  fi

  validate_unique_selectors "${selectors[@]}" || return 64

  for selector in "${selectors[@]}"; do
    if ! is_selector "$selector"; then
      printf 'ERROR: unknown selector: %s\n' "$selector" >&2
      usage
      return 64
    fi
    if [[ "$expect_known" -eq 1 ]] && ! is_known_selector "$selector" && ! is_resolved_selector "$selector"; then
      printf 'ERROR: --expect-known-failures only accepts named known-failure selectors: %s\n' "$selector" >&2
      return 64
    fi
  done

  for selector in "${selectors[@]}"; do
    if [[ "$selector" == "root-mode-trust" ]]; then
      bash "$TESTS_DIR/root-mode-trust.sh"
    else
      run_selector_function "$selector"
    fi
    status=$?
    if [[ "${LOCAL_BACKUP_TEST_INVERT_ASSERTION:-0}" == "1" && "$ASSERTION_INVERTED" -eq 0 ]]; then
      ASSERTION_INVERTED=1
      [[ "$status" -ne 0 ]] || status=2
    fi
    if [[ "$expect_known" -eq 1 ]]; then
      if is_resolved_selector "$selector" && [[ "$status" -eq 0 ]]; then
        printf 'PASS %s\n' "$selector"
      elif is_resolved_selector "$selector"; then
        printf 'FAIL %s: resolved regression is still present\n' "$selector" >&2
        failures=$((failures + 1))
      elif [[ "$status" -eq "$KNOWN_FAILURE_STATUS" ]]; then
        printf 'KNOWN_FAIL %s\n' "$selector"
      elif [[ "$status" -eq 0 ]]; then
        printf 'FAIL %s: expected product regression was not observed\n' "$selector" >&2
        failures=$((failures + 1))
      else
        printf 'ERROR %s: harness status %s\n' "$selector" "$status" >&2
        failures=$((failures + 1))
      fi
    else
      if [[ "$status" -eq 0 ]]; then
        printf 'PASS %s\n' "$selector"
      elif [[ "$status" -eq "$KNOWN_FAILURE_STATUS" ]]; then
        printf 'FAIL %s: confirmed product regression\n' "$selector" >&2
        failures=$((failures + 1))
      else
        printf 'ERROR %s: harness status %s\n' "$selector" "$status" >&2
        failures=$((failures + 1))
      fi
    fi
  done

  if [[ "${LOCAL_BACKUP_TEST_FORCE_AFTER_OUTPUT_FAIL:-0}" == "1" ]]; then
    printf 'ERROR: forced failure after success-looking output\n' >&2
    return 1
  fi

  [[ "$failures" -eq 0 ]] || return 1
  if is_exact_f3_run "${selectors[@]}"; then
    printf 'PASS F3\n'
  fi
  if [[ "$default_run" -eq 1 ]]; then
    printf 'ALL TESTS PASSED\n'
  fi
}

main "$@"
