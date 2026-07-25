#!/usr/bin/env bash

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
RUN_PREFIX="/tmp/opencode/local-backup-push-kit-run-"
RUN_ROOT=""
FIXTURE_PREFIX=""
KNOWN_FAILURE_STATUS=42
ACTIVE_FIXTURES=()
ACTIVE_GROUPS=()
ACTIVE_WATCHDOGS=()
ASSERTION_INVERTED=0
FIXTURE=""
REPO=""
DATA=""
TEST_AGE_RECIPIENT=""

say_error() {
  printf 'HARNESS_ERROR: %s\n' "$*" >&2
}

cleanup_harness() {
  local pid path
  for pid in "${ACTIVE_WATCHDOGS[@]:-}"; do
    [[ -n "$pid" ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_WATCHDOGS[@]:-}"; do
    [[ -n "$pid" ]] || continue
    wait "$pid" 2>/dev/null || true
  done
  ACTIVE_WATCHDOGS=()
  for pid in "${ACTIVE_GROUPS[@]:-}"; do
    [[ -n "$pid" ]] || continue
    terminate_process_group "$pid"
    wait "$pid" 2>/dev/null || true
  done
  ACTIVE_GROUPS=()
  for path in "${ACTIVE_FIXTURES[@]:-}"; do
    [[ -n "$path" ]] || continue
    rm -rf -- "$path"
  done
}

cleanup_stale_fixtures() {
  local path owner_pid owner_start
  for path in "${RUN_PREFIX}"*; do
    [[ -d "$path" && ! -L "$path" ]] || continue
    [[ -f "$path/owner" ]] || continue
    read -r owner_pid owner_start <"$path/owner" || continue
    [[ "$owner_pid" =~ ^[0-9]+$ && "$owner_start" =~ ^[0-9]+$ ]] || continue
    if ! process_identity_alive "$owner_pid" "$owner_start"; then
      rm -rf -- "$path"
    fi
  done
}

process_start_ticks() {
  local pid="$1" stat rest
  local -a fields=()
  [[ -r "/proc/$pid/stat" ]] || return 1
  stat="$(<"/proc/$pid/stat")" || return 1
  rest="${stat##*) }"
  read -r -a fields <<<"$rest"
  [[ ${#fields[@]} -gt 19 ]] || return 1
  printf '%s\n' "${fields[19]}"
}

process_identity_alive() {
  local pid="$1" expected_start="$2" actual_start
  actual_start="$(process_start_ticks "$pid" 2>/dev/null)" || return 1
  [[ "$actual_start" == "$expected_start" ]]
}

initialize_harness_run() {
  local owner_start
  command -v setsid >/dev/null 2>&1 || {
    say_error "missing required command: setsid"
    return 1
  }
  cleanup_stale_fixtures
  RUN_ROOT="$(mktemp -d "${RUN_PREFIX}XXXXXX")" || return 1
  owner_start="$(process_start_ticks "$$")" || {
    rm -rf -- "$RUN_ROOT"
    RUN_ROOT=""
    return 1
  }
  printf '%s %s\n' "$$" "$owner_start" >"$RUN_ROOT/owner"
  if [[ -n "${LOCAL_BACKUP_TEST_RUN_ROOT_FILE:-}" ]]; then
    printf '%s\n' "$RUN_ROOT" >"$LOCAL_BACKUP_TEST_RUN_ROOT_FILE"
  fi
  FIXTURE_PREFIX="$RUN_ROOT/fixture-"
  ACTIVE_FIXTURES+=("$RUN_ROOT")
  TEST_AGE_RECIPIENT="$(test_public_age_recipient)" || return 1
}

test_public_age_recipient() {
  python3 - <<'PY'
alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
hrp = "age"
values = []
acc = 0
bits = 0
for byte in bytes(range(1, 33)):
    acc = (acc << 8) | byte
    bits += 8
    while bits >= 5:
        bits -= 5
        values.append((acc >> bits) & 31)
if bits:
    values.append((acc << (5 - bits)) & 31)
expanded = [ord(char) >> 5 for char in hrp] + [0] + [ord(char) & 31 for char in hrp]
polymod = 1
for value in expanded + values + [0] * 6:
    top = polymod >> 25
    polymod = ((polymod & 0x1ffffff) << 5) ^ value
    for index, generator in enumerate((0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)):
        if (top >> index) & 1:
            polymod ^= generator
checksum = polymod ^ 1
check_values = [(checksum >> (5 * (5 - index))) & 31 for index in range(6)]
print(hrp + "1" + "".join(alphabet[value] for value in values + check_values))
PY
}

process_group_alive() {
  kill -0 -- "-$1" 2>/dev/null
}

terminate_process_group() {
  local pgid="$1" attempt
  process_group_alive "$pgid" || return 0
  kill -TERM -- "-$pgid" 2>/dev/null || true
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    process_group_alive "$pgid" || return 0
    /bin/sleep 0.1
  done
  kill -KILL -- "-$pgid" 2>/dev/null || true
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    process_group_alive "$pgid" || return 0
    /bin/sleep 0.1
  done
  return 0
}

handle_signal() {
  local status="$1"
  cleanup_harness
  trap - EXIT INT TERM HUP
  exit "$status"
}

trap cleanup_harness EXIT
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM HUP

new_fixture() {
  local selector="$1"
  FIXTURE="$(mktemp -d "${FIXTURE_PREFIX}${selector}.XXXXXX")" || return 1
  ACTIVE_FIXTURES+=("$FIXTURE")
}

copy_template() {
  local destination="$1"
  mkdir -p "$destination"
  cp -a \
    "$PROJECT_ROOT/scripts" \
    "$PROJECT_ROOT/hosts" \
    "$PROJECT_ROOT/docs" \
    "$PROJECT_ROOT/tests" \
    "$destination/"
  cp -a \
    "$PROJECT_ROOT/README.md" \
    "$PROJECT_ROOT/.gitignore" \
    "$destination/"
  [[ ! -d "$PROJECT_ROOT/.github" ]] || cp -a "$PROJECT_ROOT/.github" "$destination/"
  [[ ! -f "$PROJECT_ROOT/.gitlab-ci.yml" ]] || cp -a "$PROJECT_ROOT/.gitlab-ci.yml" "$destination/"
}

write_config() {
  local repo="$1" host="$2" path="$3" remote="${4:-origin}"
  mkdir -p "$repo/hosts/$host"
  cat >"$repo/hosts/$host/backup.conf" <<EOF
CONFIG_HOST_ID="$host"
AGE_RECIPIENT="$TEST_AGE_RECIPIENT"
BACKUP_BRANCH="main"
BACKUP_REMOTES=("$remote")
BACKUP_PATHS=("$path")
EOF
}

write_two_path_config() {
  local repo="$1" host="$2" first="$3" second="$4"
  mkdir -p "$repo/hosts/$host"
  cat >"$repo/hosts/$host/backup.conf" <<EOF
CONFIG_HOST_ID="$host"
AGE_RECIPIENT="$TEST_AGE_RECIPIENT"
BACKUP_BRANCH="main"
BACKUP_REMOTES=("origin")
BACKUP_PATHS=("$first" "$second")
EOF
}

write_full_config() {
  local repo="$1" file_host="$2" config_host="$3" recipient="$4" branch="$5" first_path="$6"
  shift 6
  mkdir -p "$repo/hosts/$file_host"
  {
    printf 'CONFIG_HOST_ID=%q\n' "$config_host"
    printf 'AGE_RECIPIENT=%q\n' "$recipient"
    printf 'BACKUP_BRANCH=%q\n' "$branch"
    printf '%s\n' 'BACKUP_REMOTES=("origin")' 'BACKUP_PATHS=('
    printf '  %q\n' "$first_path" "$@"
    printf '%s\n' ')'
  } >"$repo/hosts/$file_host/backup.conf"
}

install_common_shims() {
  local fixture="$1" bin
  bin="$fixture/bin"
  mkdir -p "$bin"

  cat >"$bin/tar" <<'EOF'
#!/usr/bin/env bash
set -u
output=""
previous=""
for arg in "$@"; do
  if [[ "$previous" == "-f" || "$previous" == "-cpf" || "$previous" == "-cf" ]]; then
    output="$arg"
  fi
  case "$arg" in
    -f|-cpf|-cf) previous="$arg" ;;
    *) previous="" ;;
  esac
done
if [[ -z "$output" ]]; then
  for ((i=1; i<=$#; i++)); do
    arg="${!i}"
    if [[ "$arg" == -cpf* && "$arg" != "-cpf" ]]; then output="${arg#-cpf}"; fi
  done
fi
printf '%s\n' "$*" >>"${FAKE_TAR_LOG:?}"
if [[ "${LOCAL_BACKUP_TEST_TAR_HANG:-0}" == "1" ]]; then
  /bin/sleep 60
fi
if [[ -n "${LOCAL_BACKUP_TEST_TAR_DELAY:-}" ]]; then
  : >"${FAKE_TAR_DELAY_MARKER:?}"
  /bin/sleep "$LOCAL_BACKUP_TEST_TAR_DELAY"
fi
mkdir -p "$(dirname "$output")"
printf 'fixture archive\nfixture sentinel\n' >"$output"
if [[ "${FAKE_TAR_MODE:-ok}" == "partial" ]]; then
  case " $* " in
    *' --ignore-failed-read '*) exit 0 ;;
  esac
  exit 1
fi
EOF

  cat >"$bin/age" <<'EOF'
#!/usr/bin/env bash
set -u
output=""
input=""
recipient=""
decrypt=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) decrypt=1; shift ;;
    -i) shift 2 ;;
    -r) recipient="$2"; shift 2 ;;
    -o) output="$2"; shift 2 ;;
    *) input="$1"; shift ;;
  esac
done
if [[ "$decrypt" == "1" ]]; then
  if [[ -n "$output" ]]; then /bin/cp "$input" "$output"; else /bin/cat "$input"; fi
  exit 0
fi
[[ "$recipient" == "${FAKE_AGE_VALID_RECIPIENT:?}" ]] || exit 65
printf '%s -> %s\n' "$input" "$output" >>"${FAKE_AGE_LOG:?}"
mkdir -p "$(dirname "$output")"
/bin/cp "$input" "$output"
if [[ "${FAKE_AGE_MODE:-}" == "partial-fail" && "$input" != /tmp/local-backup-push-kit-age-validate.* ]]; then exit 1; fi
if [[ -n "${FAKE_AGE_DELAY:-}" && "$input" != /tmp/local-backup-push-kit-age-validate.* ]]; then
  : >"${FAKE_AGE_DELAY_MARKER:?}"
  /bin/sleep "$FAKE_AGE_DELAY"
fi
EOF

  cat >"$bin/zstd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$bin/python3" <<'EOF'
#!/usr/bin/env bash
set -u
code_file="${FAKE_PYTHON_CODE:?}"
invocation_file="${code_file}.${BASHPID}"
/bin/cat >"$invocation_file"
{
  printf '%s\n' '--- invocation ---'
  /bin/cat "$invocation_file"
} >>"$code_file"
if [[ "${FAKE_MANIFEST_MODE:-}" == "partial-fail" ]] && grep -Fq 'timestamp_utc' "$invocation_file"; then
  printf '{"partial":' >"${2:?}"
  rm -f "$invocation_file"
  exit 1
fi
if [[ "${FAKE_STATE_MODE:-}" == "partial-fail" ]] && grep -Fq 'publication' "$invocation_file"; then
  printf '{"partial":' >"${2:?}"
  rm -f "$invocation_file"
  exit 1
fi
if [[ -n "${FAKE_PYTHON_DELAY:-}" ]]; then
  if [[ -z "${FAKE_PYTHON_DELAY_MATCH:-}" ]] || grep -Fq "$FAKE_PYTHON_DELAY_MATCH" "$invocation_file"; then
    : >"${FAKE_PYTHON_DELAY_MARKER:?}"
    /bin/sleep "$FAKE_PYTHON_DELAY"
  fi
fi
/usr/bin/python3 "$@" <"$invocation_file"
status=$?
rm -f "$invocation_file"
exit "$status"
EOF

  cat >"$bin/install" <<'EOF'
#!/usr/bin/env bash
set -u
/usr/bin/install "$@"
if [[ -n "${FAKE_INSTALL_DELAY:-}" ]]; then
  : >"${FAKE_INSTALL_MARKER:?}"
  /bin/sleep "$FAKE_INSTALL_DELAY"
fi
EOF

  cat >"$bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -u
counter_file="${FAKE_SHA256_COUNTER:?}"
count=0
[[ -f "$counter_file" ]] && count="$(/bin/cat "$counter_file")"
count=$((count + 1))
printf '%s\n' "$count" >"$counter_file"
/usr/bin/sha256sum "$@"
status=$?
if [[ -n "${FAKE_SHA256_DELAY:-}" ]]; then
  : >"${FAKE_SHA256_DELAY_MARKER:?}"
  /bin/sleep "$FAKE_SHA256_DELAY"
fi
if [[ "${FAKE_SHA256_FAIL_AT:-0}" == "$count" ]]; then exit 1; fi
exit "$status"
EOF

  cat >"$bin/git" <<'EOF'
#!/usr/bin/env bash
set -u
fixture_dir="$(cd "$(dirname "$0")/.." && pwd)"
: "${FAKE_GIT_LOG:=$fixture_dir/git.log}"
: "${FAKE_GIT_INDEX:=$fixture_dir/git-index}"
: "${FAKE_NETWORK_MARKER:=$fixture_dir/network.log}"
printf '%s\n' "$*" >>"${FAKE_GIT_LOG:?}"
args=("$@")
while [[ ${#args[@]} -gt 0 ]]; do
  case "${args[0]}" in
    --no-replace-objects) args=("${args[@]:1}") ;;
    -c|-C) args=("${args[@]:2}") ;;
    *) break ;;
  esac
done
command="${args[0]:-}"
case "$command" in
  add)
    : >"${FAKE_GIT_INDEX:?}"
    after_separator=0
    for arg in "${args[@]:1}"; do
      if [[ "$after_separator" == "1" ]]; then printf '%s\n' "$arg" >>"$FAKE_GIT_INDEX"; fi
      [[ "$arg" == "--" ]] && after_separator=1
    done
    exit 0
    ;;
  read-tree|commit)
    : >"${FAKE_GIT_INDEX:?}"
    exit 0
    ;;
  check-ref-format)
    exec /usr/bin/git check-ref-format "${args[@]:1}"
    ;;
  rev-parse)
    printf '%s\n' '1111111111111111111111111111111111111111'
    exit 0
    ;;
  write-tree)
    printf '%s\n' '2222222222222222222222222222222222222222'
    exit 0
    ;;
  symbolic-ref)
    printf '%s\n' "${FAKE_GIT_BRANCH:-main}"
    exit 0
    ;;
  status|ls-files)
    exit 0
    ;;
  ls-remote)
    if [[ "${LOCAL_BACKUP_TEST_FORBID_NETWORK:-0}" == "1" && "${FAKE_GIT_MODE:-}" == "network-guard" ]]; then
      printf 'intercepted %s\n' "${args[*]}" >>"${FAKE_NETWORK_MARKER:?}"
      exit 97
    fi
    exit 2
    ;;
  remote)
    if [[ "${args[1]:-}" == "get-url" ]]; then
      case "${args[2]:-}" in
        ssh) printf '%s\n' 'git@example.invalid:owner/repo.git' ;;
        https) printf '%s\n' 'https://example.invalid/owner/repo.git' ;;
        mirror) printf '%s\n' 'https://mirror.invalid/owner/repo.git' ;;
        canonical) printf '%s\n' 'https://canonical.invalid/owner/repo.git' ;;
        *) printf '%s\n' "${FAKE_GIT_ORIGIN_URL:-/tmp/local-backup-push-kit-fake-origin.git}" ;;
      esac
      exit 0
    fi
    ;;
  diff)
    if [[ " ${args[*]} " == *' --cached --name-only '* ]]; then
      if [[ -n "${FAKE_GIT_STAGED:-}" ]]; then
        printf '%s' "$FAKE_GIT_STAGED"
      elif [[ " ${args[*]} " == *' -z '* ]]; then
        while IFS= read -r path; do printf '%s\0' "$path"; done <"${FAKE_GIT_INDEX:?}"
      else
        /bin/cat "${FAKE_GIT_INDEX:?}"
      fi
      exit 0
    fi
    ;;
  pull|push)
    if [[ "${LOCAL_BACKUP_TEST_FORBID_NETWORK:-0}" == "1" && "${FAKE_GIT_MODE:-}" == "network-guard" ]]; then
      printf 'Everything up-to-date\n'
      printf 'intercepted %s\n' "${args[*]}" >>"${FAKE_NETWORK_MARKER:?}"
      exit 97
    fi
    if [[ "${FAKE_GIT_MODE:-}" == "immutable" && "$command" == "push" && " ${args[*]} " == *' mirror '* ]]; then
      count_file="${FAKE_GIT_COUNTER:?}"
      count=0
      [[ -f "$count_file" ]] && count="$(/bin/cat "$count_file")"
      count=$((count + 1))
      printf '%s\n' "$count" >"$count_file"
      [[ "$count" -eq 1 ]] && exit 1
    fi
    exit 0
    ;;
esac
exit 0
EOF

  cat >"$bin/sleep" <<'EOF'
#!/usr/bin/env bash
if [[ "${LOCAL_BACKUP_TEST_REAL_SLEEP:-0}" == "1" ]]; then exec /bin/sleep "$@"; fi
exit 0
EOF

  cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl attempted\n' >>"${FAKE_NETWORK_MARKER:?}"
exit 98
EOF

  cat >"$bin/wget" <<'EOF'
#!/usr/bin/env bash
printf 'wget attempted\n' >>"${FAKE_NETWORK_MARKER:?}"
exit 98
EOF

  chmod +x "$bin"/*
}

install_fixed_date_shim() {
  local fixture="$1"
  cat >"$fixture/bin/date" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  '-u +%Y-%m-%dT%H-%M-%SZ') printf '%s\n' '2026-01-02T03-04-05Z' ;;
  '-u +%Y-%m-%dT%H-%M-%SZ-%N') printf '%s\n' '2026-01-02T03-04-05Z-000000001' ;;
  '-u +%N') printf '%s\n' '000000001' ;;
  '-u +%Y-%m-%dT%H:%M:%SZ') printf '%s\n' '2026-01-02T03:04:05Z' ;;
  *) /bin/date "$@" ;;
esac
EOF
  chmod +x "$fixture/bin/date"
}

install_systemd_shims() {
  local fixture="$1"
  cat >"$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${FAKE_SUDO_LOG:?}"
if [[ "${1:-}" == "tee" ]]; then
  target="${2:?}"
  case "$target" in
    *.service) /bin/cat >"${FAKE_SYSTEMD_DIR:?}/unit.service" ;;
    *.timer) /bin/cat >"${FAKE_SYSTEMD_DIR:?}/unit.timer" ;;
    *) exit 2 ;;
  esac
  exit 0
fi
if [[ "${1:-}" == "systemctl" ]]; then shift; exec systemctl "$@"; fi
exit 2
EOF
  cat >"$fixture/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_SYSTEMCTL_LOG:?}"
exit 0
EOF
  chmod +x "$fixture/bin/sudo" "$fixture/bin/systemctl"
}

fixture_env() {
  local fixture="$1"
  printf '%s\n' \
    "PATH=$fixture/bin:$PATH" \
    "FAKE_TAR_LOG=$fixture/tar.log" \
    "FAKE_AGE_LOG=$fixture/age.log" \
    "FAKE_GIT_LOG=$fixture/git.log" \
    "FAKE_GIT_INDEX=$fixture/git-index" \
    "FAKE_PYTHON_CODE=$fixture/python-code.py" \
    "FAKE_NETWORK_MARKER=$fixture/network.log" \
    "FAKE_AGE_VALID_RECIPIENT=$TEST_AGE_RECIPIENT" \
    "FAKE_SHA256_COUNTER=$fixture/sha256-counter" \
    "FAKE_TAR_DELAY_MARKER=$fixture/tar-delay.marker" \
    "FAKE_AGE_DELAY_MARKER=$fixture/age-delay.marker" \
    "FAKE_SHA256_DELAY_MARKER=$fixture/sha256-delay.marker" \
    "FAKE_PYTHON_DELAY_MARKER=$fixture/python-delay.marker" \
    "FAKE_INSTALL_MARKER=$fixture/install-delay.marker"
}

run_captured() {
  local output="$1" timeout_seconds="$2" pid watchdog status marker
  shift 2
  : >"$output"
  marker="$RUN_ROOT/timeout-${BASHPID}-${RANDOM}"
  setsid "$@" >"$output" 2>&1 &
  pid=$!
  ACTIVE_GROUPS+=("$pid")
  (
    /bin/sleep "$timeout_seconds"
    if process_group_alive "$pid"; then
      : >"$marker"
      terminate_process_group "$pid"
    fi
  ) &
  watchdog=$!
  ACTIVE_WATCHDOGS+=("$watchdog")
  wait "$pid"
  status=$?
  if [[ -f "$marker" ]]; then
    wait "$watchdog" 2>/dev/null || true
    status=124
  else
    kill -TERM "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    if process_group_alive "$pid"; then
      terminate_process_group "$pid"
    fi
  fi
  rm -f -- "$marker"
  ACTIVE_GROUPS=()
  ACTIVE_WATCHDOGS=()
  return "$status"
}

assert_condition() {
  local condition="$1" message="$2" result=1
  if eval "$condition"; then result=0; fi
  if [[ "${LOCAL_BACKUP_TEST_INVERT_ASSERTION:-0}" == "1" && "$ASSERTION_INVERTED" -eq 0 ]]; then
    ASSERTION_INVERTED=1
    if [[ "$result" -eq 0 ]]; then result=1; else result=0; fi
  fi
  if [[ "$result" -ne 0 ]]; then
    say_error "$message"
    return 1
  fi
  return 0
}

known_failure() {
  printf 'observed defect: %s\n' "$*" >&2
  return "$KNOWN_FAILURE_STATUS"
}

setup_fake_backup_fixture() {
  local selector="$1" host="${2:-host-a}"
  new_fixture "$selector" || return 1
  REPO="$FIXTURE/repo"
  DATA="$FIXTURE/data"
  copy_template "$REPO"
  install_common_shims "$FIXTURE"
  mkdir -p "$REPO/.git"
  mkdir -p "$DATA"
  printf 'sentinel\n' >"$DATA/sentinel.txt"
  write_config "$REPO" "$host" "$DATA"
}

run_fake_backup() {
  local fixture="$1" repo="$2" host="$3" output="$4" push="${5:-0}"
  local -a environment
  mapfile -t environment < <(fixture_env "$fixture")
  run_captured "$output" 8 env \
    "${environment[@]}" \
    BACKUP_HOST="$host" BACKUP_PUSH="$push" \
    bash "$repo/scripts/backup.sh"
}

init_real_repo() {
  local repo="$1"
  /usr/bin/git -C "$repo" init -q
  /usr/bin/git -C "$repo" config user.name fixture
  /usr/bin/git -C "$repo" config user.email fixture@example.invalid
  /usr/bin/git -C "$repo" add .
  /usr/bin/git -C "$repo" commit -qm baseline
  /usr/bin/git -C "$repo" branch -M main
}

scenario_baseline() {
  local fixture repo data output status
  output="$RUN_ROOT/baseline-source-only.log"
  run_captured "$output" 8 bash "$PROJECT_ROOT/scripts/check-source-only.sh"
  status=$?
  assert_condition '[[ "$status" -eq 0 ]]' "source-only characterization failed" || return 2
  setup_fake_backup_fixture baseline || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  if [[ -n "${LOCAL_BACKUP_TEST_HOLD_SECONDS:-}" ]]; then
    /bin/sleep "$LOCAL_BACKUP_TEST_HOLD_SECONDS"
  fi
  output="$fixture/output.log"
  run_fake_backup "$fixture" "$repo" host-a "$output" 0
  status=$?
  assert_condition '[[ "$status" -eq 0 ]]' "BACKUP_PUSH=0 baseline did not succeed" || return 2
  assert_condition '[[ -s "$repo/backups/host-a/latest.txt" ]]' "baseline latest pointer missing" || return 2
  assert_condition '[[ -n "$(compgen -G "$repo/backups/host-a/*.tar.zst.age")" ]]' "baseline encrypted archive missing" || return 2
  assert_condition '[[ -n "$(compgen -G "$repo/manifests/host-a/*.json")" ]]' "baseline manifest missing" || return 2
  assert_condition '! grep -Fq " commit " "$fixture/git.log" && ! grep -Fq " push " "$fixture/git.log"' "BACKUP_PUSH=0 committed or pushed" || return 2
  return 0
}

scenario_retention_empty() {
  local fixture script output status
  new_fixture retention-empty || return 2
  fixture="$FIXTURE"
  mkdir -p "$fixture/backups/host-a" "$fixture/manifests/host-a" "$fixture/bin"
  install_common_shims "$fixture"
  script="$fixture/retention.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    while IFS= read -r line; do
      case "$line" in
        '          set -euo pipefail') ;;
        '          '*) printf '%s\n' "${line#          }" ;;
      esac
    done < <(tail -n +21 "$PROJECT_ROOT/.github/workflows/retention.yml")
  } >"$script"
  chmod +x "$script"
  output="$fixture/output.log"
  run_captured "$output" 8 env PATH="$fixture/bin:$PATH" FAKE_GIT_LOG="$fixture/git.log" FAKE_TAR_LOG="$fixture/tar.log" FAKE_AGE_LOG="$fixture/age.log" FAKE_PYTHON_CODE="$fixture/code" FAKE_NETWORK_MARKER="$fixture/network" bash -c 'cd "$1" && "$2"' _ "$fixture" "$script"
  status=$?
  if [[ "$status" -ne 0 ]]; then known_failure "empty retention host aborts on unmatched ls glob"; return $?; fi
  return 0
}

scenario_partial_tar() {
  local fixture repo data output status
  setup_fake_backup_fixture partial-tar || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  output="$fixture/output.log"
  FAKE_TAR_MODE=partial run_fake_backup "$fixture" "$repo" host-a "$output" 0
  status=$?
  if [[ "$status" -eq 0 && -n "$(compgen -G "$repo/backups/host-a/*.tar.zst.age")" ]]; then
    known_failure "--ignore-failed-read accepts a partial tar result"
    return $?
  fi
  return 0
}

scenario_path_case() {
  local selector="$1" path_kind="$2" fixture repo data output status path
  setup_fake_backup_fixture "$selector" || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  mkdir -p "$fixture/work"
  case "$path_kind" in
    relative)
      mkdir -p "$fixture/work/relative-data"
      printf 'sentinel\n' >"$fixture/work/relative-data/file"
      path="relative-data"
      ;;
    ancestor) path="$fixture" ;;
    symlink)
      ln -s "$repo" "$fixture/repo-link"
      path="$fixture/repo-link"
      ;;
    *) return 2 ;;
  esac
  write_config "$repo" host-a "$path"
  output="$fixture/output.log"
  local -a environment
  mapfile -t environment < <(fixture_env "$fixture")
  run_captured "$output" 8 env "${environment[@]}" BACKUP_HOST=host-a BACKUP_PUSH=0 bash -c 'cd "$1" && "$2"' _ "$fixture/work" "$repo/scripts/backup.sh"
  status=$?
  if [[ "$status" -eq 0 ]]; then known_failure "$selector path was accepted"; return $?; fi
  return 0
}

scenario_relative_path() { path_case_rejected relative; }
scenario_ancestor_path() { path_case_rejected repo-ancestor; }
scenario_symlink_path() { path_case_rejected symlink-leaf; }

scenario_same_second() {
  scenario_artifact_id
}

scenario_multi_host_staged() {
  local fixture repo data_a data_b output status staged_before staged_after
  new_fixture multi-host-staged || return 2
  fixture="$FIXTURE"
  repo="$fixture/repo"
  data_a="$fixture/data-a"
  data_b="$fixture/data-b"
  copy_template "$repo"
  install_common_shims "$fixture"
  rm -f "$fixture/bin/git"
  mkdir -p "$data_a" "$data_b"
  printf 'a\n' >"$data_a/a"
  printf 'b\n' >"$data_b/b"
  write_config "$repo" host-a "$data_a"
  write_config "$repo" host-b "$data_b"
  init_real_repo "$repo" || return 2
  /usr/bin/git init -q --bare "$fixture/origin.git" || return 2
  /usr/bin/git -C "$repo" remote add origin "$fixture/origin.git" || return 2
  /usr/bin/git -C "$repo" push -q origin HEAD:refs/heads/main || return 2
  output="$fixture/a.log"
  run_fake_backup "$fixture" "$repo" host-a "$output" 0 || return 2
  staged_before="$(/usr/bin/git -C "$repo" diff --cached --name-only)"
  : >"$fixture/tar.log"
  output="$fixture/b.log"
  run_fake_backup "$fixture" "$repo" host-b "$output" 0
  status=$?
  staged_after="$(/usr/bin/git -C "$repo" diff --cached --name-only)"
  if [[ "$status" -ne 0 && "$staged_before" == "$staged_after" && "$staged_after" == *'backups/host-a/'* && "$staged_after" != *'backups/host-b/'* && ! -s "$fixture/tar.log" && ! -e "$repo/backups/host-b" ]] && grep -Fq 'backup repository must be clean' "$output"; then
    return 0
  fi
  return 2
}

scenario_empty_remote() {
  local fixture repo data bare output status
  new_fixture empty-remote || return 2
  fixture="$FIXTURE"
  repo="$fixture/repo"
  data="$fixture/data"
  bare="$fixture/empty.git"
  copy_template "$repo"
  install_common_shims "$fixture"
  rm -f "$fixture/bin/git"
  mkdir -p "$data"
  printf 'sentinel\n' >"$data/file"
  write_config "$repo" host-a "$data" origin
  init_real_repo "$repo" || return 2
  /usr/bin/git init -q --bare "$bare" || return 2
  /usr/bin/git -C "$repo" remote add origin "$bare"
  output="$fixture/output.log"
  local -a environment
  mapfile -t environment < <(fixture_env "$fixture")
  run_captured "$output" 8 env "${environment[@]}" BACKUP_GIT_TOKEN=placeholder BACKUP_HOST=host-a BACKUP_PUSH=1 bash "$repo/scripts/backup.sh"
  status=$?
  if [[ "$status" -ne 0 && ! -e "$repo/backups/host-a" ]]; then known_failure "unconditional pull rejects an empty canonical branch"; return $?; fi
  return 0
}

scenario_immutable_mirrors() {
  local fixture repo data output status
  setup_fake_backup_fixture immutable-mirrors || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  write_config "$repo" host-a "$data" canonical
  perl -0pi -e 's/BACKUP_REMOTES=\("canonical"\)/BACKUP_REMOTES=("canonical" "mirror")/' "$repo/hosts/host-a/backup.conf"
  output="$fixture/output.log"
  local -a environment
  mapfile -t environment < <(fixture_env "$fixture")
  run_captured "$output" 8 env "${environment[@]}" FAKE_GIT_MODE=immutable FAKE_GIT_COUNTER="$fixture/counter" BACKUP_GIT_TOKEN=placeholder BACKUP_HOST=host-a BACKUP_PUSH=1 bash "$repo/scripts/backup.sh"
  status=$?
  if grep -Fq 'pull --rebase --autostash mirror main' "$fixture/git.log"; then known_failure "mirror retry rebases local HEAD after canonical publication"; return $?; fi
  [[ "$status" -eq 0 ]] || return 2
  return 0
}

scenario_ssh_no_token() {
  local fixture repo data output status
  setup_fake_backup_fixture ssh-no-token || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  write_config "$repo" host-a "$data" ssh
  output="$fixture/output.log"
  local -a environment
  mapfile -t environment < <(fixture_env "$fixture")
  run_captured "$output" 8 env -u GITHUB_TOKEN -u GITLAB_TOKEN -u BACKUP_GIT_TOKEN "${environment[@]}" BACKUP_HOST=host-a BACKUP_PUSH=1 bash "$repo/scripts/backup.sh"
  status=$?
  if [[ "$status" -ne 0 ]] && grep -Fq "missing token for remote 'ssh'" "$output"; then known_failure "SSH transport incorrectly requires an HTTPS token"; return $?; fi
  return 0
}

scenario_broad_staging() {
  local fixture repo data output status staged
  new_fixture broad-staging || return 2
  fixture="$FIXTURE"
  repo="$fixture/repo"
  data="$fixture/data"
  copy_template "$repo"
  install_common_shims "$fixture"
  rm -f "$fixture/bin/git"
  mkdir -p "$data"
  printf 'sentinel\n' >"$data/file"
  write_config "$repo" host-a "$data"
  init_real_repo "$repo" || return 2
  /usr/bin/git init -q --bare "$fixture/origin.git" || return 2
  /usr/bin/git -C "$repo" remote add origin "$fixture/origin.git" || return 2
  /usr/bin/git -C "$repo" push -q origin HEAD:refs/heads/main || return 2
  printf '\nunrelated dirty edit\n' >>"$repo/docs/llm-setup-guide.zh.md"
  output="$fixture/output.log"
  run_fake_backup "$fixture" "$repo" host-a "$output" 0
  status=$?
  staged="$(/usr/bin/git -C "$repo" diff --cached --name-only)"
  if [[ "$status" -ne 0 && "$staged" != *'docs/llm-setup-guide.zh.md'* && ! -s "$fixture/tar.log" && ! -e "$repo/backups" && ! -e "$repo/manifests" ]] && grep -Fq 'backup repository must be clean' "$output"; then
    return 0
  fi
  return 2
}

scenario_schedule_user() {
  local fixture repo output status
  new_fixture schedule-user || return 2
  fixture="$FIXTURE"
  repo="$fixture/repo"
  copy_template "$repo"
  mkdir -p "$repo/hosts/host-a"
  cat >"$repo/hosts/host-a/backup.conf" <<EOF
CONFIG_HOST_ID="host-a"
BACKUP_RUN_USER="backup-user"
BACKUP_RUN_GROUP="backup-group"
BACKUP_ON_CALENDAR="weekly"
EOF
  output="$fixture/output.log"
  run_captured "$output" 8 env BACKUP_HOST=host-a BACKUP_SYSTEMD_DIR="$fixture/systemd" BACKUP_ENV_DIR="$fixture/env" BACKUP_INSTALL_DRY_RUN=1 bash "$repo/scripts/install-systemd-timer.sh"
  status=$?
  [[ "$status" -eq 0 ]] || return 2
  grep -Fq 'encrypted-git-backup-host-a.service' "$output" || return 2
  grep -Fq 'User=backup-user' "$output" || return 2
  grep -Fq 'Group=backup-group' "$output" || return 2
  grep -Fq 'OnCalendar=weekly' "$output" || return 2
}

scenario_manifest_memory() {
  local fixture repo data output status
  setup_fake_backup_fixture manifest-memory || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  output="$fixture/output.log"
  run_fake_backup "$fixture" "$repo" host-a "$output" 0
  status=$?
  if [[ "$status" -eq 0 ]] && grep -Fq 'fh.read()' "$fixture/python-code.py"; then known_failure "manifest reads the whole encrypted archive into memory"; return $?; fi
  return 0
}

scenario_docs_private_key() {
  if grep -Fq 'age-keygen -o' "$PROJECT_ROOT/README.md" && \
     grep -Fq 'age-keygen -o /tmp/local-backup-age-identity.txt' "$PROJECT_ROOT/docs/llm-setup-guide.zh.md" && \
     grep -Fq '公钥和私钥完整打印' "$PROJECT_ROOT/docs/llm-setup-guide.zh.md"; then
    known_failure "documentation positively instructs private-key generation and output"
    return $?
  fi
  return 0
}

scenario_network_guard() {
  local fixture repo data output status
  setup_fake_backup_fixture network-guard || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  write_config "$repo" host-a "$data" https
  output="$fixture/output.log"
  local -a environment
  mapfile -t environment < <(fixture_env "$fixture")
  run_captured "$output" 5 env "${environment[@]}" LOCAL_BACKUP_TEST_FORBID_NETWORK=1 FAKE_GIT_MODE=network-guard BACKUP_GIT_TOKEN=placeholder BACKUP_HOST=host-a BACKUP_PUSH=1 bash "$repo/scripts/backup.sh"
  status=$?
  if [[ "$status" -eq 124 && "${LOCAL_BACKUP_TEST_GIT_HANG:-0}" == "1" ]]; then return 0; fi
  assert_condition '[[ "$status" -ne 0 ]]' "network guard expected a nonzero product status, got $status" || return 2
  assert_condition 'grep -Fq "intercepted ls-remote" "$fixture/network.log"' "network guard did not record Git interception" || return 2
  assert_condition '! grep -Fq "curl attempted" "$fixture/network.log" && ! grep -Fq "wget attempted" "$fixture/network.log"' "a real HTTP helper was invoked" || return 2
  return 0
}

fixture_tar_pids() {
  local root="$1" pattern
  pattern="${root}/fixture-.*/bin/tar"
  pgrep -f "$pattern" 2>/dev/null || true
}

kill_fixture_tar_processes() {
  local root="$1" pid child
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if [[ -r "/proc/$pid/task/$pid/children" ]]; then
      for child in $(<"/proc/$pid/task/$pid/children"); do
        kill -KILL "$child" 2>/dev/null || true
      done
    fi
    kill -KILL "$pid" 2>/dev/null || true
  done < <(fixture_tar_pids "$root")
}

scenario_harness_process_tree() {
  local output root_file nested_root status leaked
  output="$RUN_ROOT/process-tree-self-test.log"
  root_file="$RUN_ROOT/process-tree-root"
  env LOCAL_BACKUP_TEST_TAR_HANG=1 LOCAL_BACKUP_TEST_REAL_SLEEP=1 LOCAL_BACKUP_TEST_RUN_ROOT_FILE="$root_file" bash "$TESTS_DIR/run.sh" baseline >"$output" 2>&1
  status=$?
  nested_root="$(<"$root_file")"
  leaked="$(fixture_tar_pids "$nested_root")"
  rm -f -- "$output"
  if [[ -n "$leaked" ]]; then
    kill_fixture_tar_processes "$nested_root"
    say_error "fixture-owned descendants survived timeout: $leaked"
    return 2
  fi
  [[ "$status" -ne 0 ]] || return 2
  return 0
}

scenario_harness_concurrency() {
  local first_output second_output root_file first_pid first_root first_fixture first_status second_status
  first_output="$RUN_ROOT/concurrency-a.log"
  second_output="$RUN_ROOT/concurrency-b.log"
  root_file="$RUN_ROOT/concurrency-root"
  env LOCAL_BACKUP_TEST_HOLD_SECONDS=2 LOCAL_BACKUP_TEST_RUN_ROOT_FILE="$root_file" bash "$TESTS_DIR/run.sh" baseline >"$first_output" 2>&1 &
  first_pid=$!
  first_root=""
  first_fixture=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [[ -s "$root_file" ]]; then
      first_root="$(<"$root_file")"
      first_fixture="$(compgen -G "$first_root/fixture-baseline.*" || true)"
    fi
    [[ -n "$first_fixture" ]] && break
    /bin/sleep 0.2
  done
  if [[ -z "$first_fixture" ]]; then
    kill -TERM "$first_pid" 2>/dev/null || true
    wait "$first_pid" 2>/dev/null || true
    rm -f -- "$first_output" "$second_output"
    return 2
  fi
  bash "$TESTS_DIR/run.sh" baseline >"$second_output" 2>&1
  second_status=$?
  wait "$first_pid"
  first_status=$?
  rm -f -- "$first_output" "$second_output"
  if [[ "$first_status" -ne 0 || "$second_status" -ne 0 ]]; then
    say_error "concurrent baselines were not isolated: first=$first_status second=$second_status"
    return 2
  fi
  return 0
}

scenario_harness_stale_owner() {
  local stale active start
  stale="$(mktemp -d "${RUN_PREFIX}stale.XXXXXX")" || return 2
  active="$(mktemp -d "${RUN_PREFIX}active.XXXXXX")" || {
    rm -rf -- "$stale"
    return 2
  }
  printf '%s %s\n' '999999999' '1' >"$stale/owner"
  start="$(process_start_ticks "$$")" || {
    rm -rf -- "$stale" "$active"
    return 2
  }
  printf '%s %s\n' "$$" "$start" >"$active/owner"
  printf 'stale\n' >"$stale/sentinel"
  printf 'active\n' >"$active/sentinel"
  cleanup_stale_fixtures
  if [[ -e "$stale" || ! -f "$active/sentinel" ]]; then
    rm -rf -- "$stale" "$active"
    return 2
  fi
  rm -rf -- "$active"
  return 0
}

run_fixture_backup_env() {
  local fixture="$1" repo="$2" host="$3" output="$4" push="$5"
  shift 5
  local -a environment
  mapfile -t environment < <(fixture_env "$fixture")
  run_captured "$output" 12 env \
    "${environment[@]}" \
    BACKUP_HOST="$host" BACKUP_PUSH="$push" "$@" \
    bash "$repo/scripts/backup.sh"
}

path_case_rejected() {
  local kind="$1" fixture repo data work path output status
  setup_fake_backup_fixture "path-$kind" || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  work="$fixture/work"
  mkdir -p "$work"
  case "$kind" in
    relative)
      mkdir -p "$work/relative-data"
      printf 'relative\n' >"$work/relative-data/file"
      path="relative-data"
      write_config "$repo" host-a "$path"
      ;;
    missing)
      path="$fixture/missing"
      write_config "$repo" host-a "$path"
      ;;
    duplicate)
      write_two_path_config "$repo" host-a "$data" "$data"
      ;;
    symlink-alias)
      ln -s "$data" "$fixture/data-alias"
      write_two_path_config "$repo" host-a "$data" "$fixture/data-alias"
      ;;
    repo) write_config "$repo" host-a "$repo" ;;
    repo-child) write_config "$repo" host-a "$repo/docs" ;;
    repo-ancestor) write_config "$repo" host-a "$fixture" ;;
    root-ancestor) write_config "$repo" host-a / ;;
    symlink-leaf)
      ln -s "$data" "$fixture/data-link"
      write_config "$repo" host-a "$fixture/data-link"
      ;;
    symlinked-ancestor)
      ln -s "$repo" "$fixture/repo-alias"
      write_config "$repo" host-a "$fixture/repo-alias/docs"
      ;;
    *) return 2 ;;
  esac
  output="$fixture/output.log"
  local -a environment
  mapfile -t environment < <(fixture_env "$fixture")
  run_captured "$output" 8 env "${environment[@]}" BACKUP_HOST=host-a BACKUP_PUSH=0 bash -c 'cd "$1" && "$2"' _ "$work" "$repo/scripts/backup.sh"
  status=$?
  if [[ "$status" -eq 0 || -s "$fixture/tar.log" || -e "$repo/backups" || -e "$repo/manifests" ]] || grep -Fq ' add ' "$fixture/git.log" 2>/dev/null; then
    say_error "path case was not rejected before mutation: $kind status=$status"
    return 2
  fi
  return 0
}

scenario_path_validation() {
  local fixture repo data output status kind
  setup_fake_backup_fixture path-valid || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  output="$fixture/output.log"
  run_fake_backup "$fixture" "$repo" host-a "$output" 0
  status=$?
  [[ "$status" -eq 0 && -s "$fixture/tar.log" ]] || return 2
  for kind in relative missing duplicate symlink-alias repo repo-child repo-ancestor root-ancestor symlink-leaf symlinked-ancestor; do
    path_case_rejected "$kind" || return 2
  done
  return 0
}

invalid_config_rejected() {
  local name="$1" host="$2" config_host="$3" recipient="$4" branch="$5" push="$6" retention="$7" lock_timeout="$8"
  local fixture repo data output status
  setup_fake_backup_fixture "config-$name" || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  write_full_config "$repo" host-a "$config_host" "$recipient" "$branch" "$data"
  output="$fixture/output.log"
  run_fixture_backup_env "$fixture" "$repo" "$host" "$output" "$push" \
    BACKUP_CONFIG="$repo/hosts/host-a/backup.conf" \
    BACKUP_RETENTION_COUNT="$retention" \
    BACKUP_LOCK_TIMEOUT="$lock_timeout"
  status=$?
  if [[ "$status" -eq 0 || -s "$fixture/tar.log" || -e "$repo/backups" || -e "$repo/manifests" ]] || grep -Fq ' add ' "$fixture/git.log" 2>/dev/null; then
    say_error "invalid config was not rejected before mutation: $name status=$status"
    return 2
  fi
  if [[ "$name" == recipient* && -n "$recipient" ]] && grep -Fq -- "$recipient" "$output"; then
    say_error "recipient validation leaked the supplied value"
    return 2
  fi
  return 0
}

dirty_repo_rejected() {
  local fixture repo data output status before after
  new_fixture config-dirty || return 2
  fixture="$FIXTURE" repo="$fixture/repo" data="$fixture/data"
  copy_template "$repo"
  install_common_shims "$fixture"
  rm -f "$fixture/bin/git"
  mkdir -p "$data"
  printf 'data\n' >"$data/file"
  write_config "$repo" host-a "$data"
  init_real_repo "$repo" || return 2
  printf 'dirty\n' >>"$repo/docs/llm-setup-guide.zh.md"
  before="$(/usr/bin/git -C "$repo" status --porcelain=v1 --untracked-files=all)"
  output="$fixture/output.log"
  run_fake_backup "$fixture" "$repo" host-a "$output" 0
  status=$?
  after="$(/usr/bin/git -C "$repo" status --porcelain=v1 --untracked-files=all)"
  if [[ "$status" -eq 0 || "$before" != "$after" || -s "$fixture/tar.log" || -e "$repo/backups" || -e "$repo/manifests" ]]; then
    say_error "dirty repository was not rejected without mutation"
    return 2
  fi
  return 0
}

missing_dependency_rejected() {
  local fixture repo data output status command_name source
  setup_fake_backup_fixture config-missing-command || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  mkdir -p "$fixture/preflight-bin"
  for command_name in age chmod cut date find flock git hostname install mkdir mktemp mv python3 rm rmdir seq sha256sum sleep stat tar tr zstd; do
    if [[ -x "$fixture/bin/$command_name" ]]; then
      source="$fixture/bin/$command_name"
    else
      source="$(command -v "$command_name")" || return 2
    fi
    ln -s "$source" "$fixture/preflight-bin/$command_name"
  done
  output="$fixture/output.log"
  run_captured "$output" 8 env \
    PATH="$fixture/preflight-bin" \
    FAKE_TAR_LOG="$fixture/tar.log" \
    FAKE_AGE_LOG="$fixture/age.log" \
    FAKE_GIT_LOG="$fixture/git.log" \
    FAKE_PYTHON_CODE="$fixture/python-code.py" \
    FAKE_NETWORK_MARKER="$fixture/network.log" \
    BACKUP_HOST=host-a BACKUP_PUSH=0 \
    /bin/bash "$repo/scripts/backup.sh"
  status=$?
  if [[ "$status" -eq 0 || -s "$fixture/tar.log" || -e "$repo/backups" || -e "$repo/manifests" ]] || ! grep -Fq 'missing required command: realpath' "$output"; then
    say_error "missing runtime dependency was not rejected before mutation"
    return 2
  fi
  return 0
}

scalar_paths_rejected() {
  local fixture repo data output status
  setup_fake_backup_fixture config-scalar-paths || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  cat >"$repo/hosts/host-a/backup.conf" <<EOF
CONFIG_HOST_ID="host-a"
AGE_RECIPIENT="$TEST_AGE_RECIPIENT"
BACKUP_BRANCH="main"
BACKUP_PATHS="$data"
EOF
  output="$fixture/output.log"
  run_fake_backup "$fixture" "$repo" host-a "$output" 0
  status=$?
  if [[ "$status" -eq 0 || -s "$fixture/tar.log" || -e "$repo/backups" || -e "$repo/manifests" ]] || ! grep -Fq 'BACKUP_PATHS must be an indexed array' "$output"; then
    return 2
  fi
  return 0
}

valid_config_accepted() {
  local name="$1" branch="$2" retention="$3" lock_timeout="$4"
  local fixture repo data output status
  setup_fake_backup_fixture "config-$name" || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  write_full_config "$repo" host-a host-a "$TEST_AGE_RECIPIENT" "$branch" "$data"
  output="$fixture/output.log"
  run_fixture_backup_env "$fixture" "$repo" host-a "$output" 0 \
    FAKE_GIT_BRANCH="$branch" \
    BACKUP_RETENTION_COUNT="$retention" \
    BACKUP_LOCK_TIMEOUT="$lock_timeout"
  status=$?
  if [[ "$status" -ne 0 || ! -s "$fixture/tar.log" || ! -e "$repo/backups/host-a/latest.txt" ]]; then
    say_error "valid config was rejected: $name status=$status"
    return 2
  fi
  return 0
}

scenario_config_age_recipient() {
  invalid_config_rejected recipient-short host-a host-a age1x main 0 3 30
}

scenario_config_branch_ref() {
  invalid_config_rejected branch-lock-component host-a host-a "$TEST_AGE_RECIPIENT" 'a.lock/b' 0 3 30
}

scenario_config_retention_bound() {
  invalid_config_rejected retention-overflow host-a host-a "$TEST_AGE_RECIPIENT" main 0 999999999999999999999999999999999999 30
}

scenario_config_timeout_canonical() {
  invalid_config_rejected lock-leading-zero host-a host-a "$TEST_AGE_RECIPIENT" main 0 3 0030
}

scenario_config_symlink_rejected() {
  local fixture repo data output status outside marker
  setup_fake_backup_fixture config-symlink || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  outside="$fixture/outside.conf"
  marker="$fixture/config-sourced"
  cat >"$outside" <<EOF
: > "$marker"
CONFIG_HOST_ID="host-a"
AGE_RECIPIENT="$TEST_AGE_RECIPIENT"
BACKUP_BRANCH="main"
BACKUP_PATHS=("$data")
BACKUP_REMOTES=(origin)
EOF
  rm -f -- "$repo/hosts/host-a/backup.conf"
  ln -s "$outside" "$repo/hosts/host-a/backup.conf" || return 2
  output="$fixture/output.log"
  run_fake_backup "$fixture" "$repo" host-a "$output" 0
  status=$?
  if [[ "$status" -eq 0 || -e "$marker" || -s "$fixture/tar.log" || -e "$repo/backups" || -e "$repo/manifests" ]] || grep -Fq ' add ' "$fixture/git.log" 2>/dev/null; then
    say_error "symlinked config was not rejected before sourcing or mutation"
    return 2
  fi
  grep -Fq 'missing or unsafe config' "$output" || return 2
}

scenario_config_validation() {
  local valid="$TEST_AGE_RECIPIENT"
  invalid_config_rejected push host-a host-a "$valid" main 2 3 30 || return 2
  invalid_config_rejected push-empty host-a host-a "$valid" main '' 3 30 || return 2
  invalid_config_rejected retention-zero host-a host-a "$valid" main 0 0 30 || return 2
  invalid_config_rejected retention-leading-zero host-a host-a "$valid" main 0 03 30 || return 2
  invalid_config_rejected retention-sign host-a host-a "$valid" main 0 +3 30 || return 2
  invalid_config_rejected retention-space host-a host-a "$valid" main 0 ' 3' 30 || return 2
  invalid_config_rejected retention-text host-a host-a "$valid" main 0 invalid 30 || return 2
  invalid_config_rejected retention-empty host-a host-a "$valid" main 0 '' 30 || return 2
  invalid_config_rejected retention-overflow host-a host-a "$valid" main 0 999999999999999999999999999999999999 30 || return 2
  invalid_config_rejected lock-negative host-a host-a "$valid" main 0 3 -1 || return 2
  invalid_config_rejected lock-sign host-a host-a "$valid" main 0 3 +30 || return 2
  invalid_config_rejected lock-space host-a host-a "$valid" main 0 3 ' 30' || return 2
  invalid_config_rejected lock-leading-zero host-a host-a "$valid" main 0 3 0030 || return 2
  invalid_config_rejected lock-double-zero host-a host-a "$valid" main 0 3 00 || return 2
  invalid_config_rejected lock-text host-a host-a "$valid" main 0 3 invalid || return 2
  invalid_config_rejected lock-empty host-a host-a "$valid" main 0 3 '' || return 2
  invalid_config_rejected lock-unbounded host-a host-a "$valid" main 0 3 3601 || return 2
  invalid_config_rejected lock-overflow host-a host-a "$valid" main 0 3 999999999999999999 || return 2
  invalid_config_rejected host 'bad host' 'bad host' "$valid" main 0 3 30 || return 2
  invalid_config_rejected host-trailing-dash 'bad-' 'bad-' "$valid" main 0 3 30 || return 2
  invalid_config_rejected host-trailing-underscore 'bad_' 'bad_' "$valid" main 0 3 30 || return 2
  invalid_config_rejected host-trailing-dot 'bad.' 'bad.' "$valid" main 0 3 30 || return 2
  invalid_config_rejected host-empty '' '' "$valid" main 0 3 30 || return 2
  invalid_config_rejected branch-space host-a host-a "$valid" 'bad branch' 0 3 30 || return 2
  invalid_config_rejected branch-double-dot host-a host-a "$valid" 'a..b' 0 3 30 || return 2
  invalid_config_rejected branch-double-slash host-a host-a "$valid" 'a//b' 0 3 30 || return 2
  invalid_config_rejected branch-trailing-slash host-a host-a "$valid" 'a/' 0 3 30 || return 2
  invalid_config_rejected branch-trailing-dot host-a host-a "$valid" 'main.' 0 3 30 || return 2
  invalid_config_rejected branch-leading-dot host-a host-a "$valid" '.hidden' 0 3 30 || return 2
  invalid_config_rejected branch-leading-dash host-a host-a "$valid" '-option' 0 3 30 || return 2
  invalid_config_rejected branch-at-brace host-a host-a "$valid" 'a@{b' 0 3 30 || return 2
  invalid_config_rejected branch-lock-component host-a host-a "$valid" 'a.lock/b' 0 3 30 || return 2
  invalid_config_rejected branch-newline host-a host-a "$valid" $'bad\nbranch' 0 3 30 || return 2
  invalid_config_rejected branch-control host-a host-a "$valid" $'bad\001branch' 0 3 30 || return 2
  invalid_config_rejected branch-empty host-a host-a "$valid" '' 0 3 30 || return 2
  invalid_config_rejected recipient host-a host-a not-an-age-recipient main 0 3 30 || return 2
  invalid_config_rejected recipient-short host-a host-a age1x main 0 3 30 || return 2
  invalid_config_rejected recipient-empty host-a host-a '' main 0 3 30 || return 2
  scalar_paths_rejected || return 2
  scenario_config_symlink_rejected || return 2
  dirty_repo_rejected || return 2
  missing_dependency_rejected || return 2
  valid_config_accepted valid-minimum main 1 0 || return 2
  valid_config_accepted valid-normal release/2026.07 1000000 30 || return 2
  valid_config_accepted valid-timeout-max main 3 3600 || return 2
  return 0
}

scenario_artifact_id() {
  local fixture repo data output first_status second_status count old
  setup_fake_backup_fixture artifact-id || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  install_fixed_date_shim "$fixture"
  mkdir -p "$repo/backups/host-a" "$repo/manifests/host-a"
  old="$repo/backups/host-a/2025-01-01T00-00-00Z.tar.zst.age"
  printf 'old\n' >"$old"
  output="$fixture/first.log"
  run_fake_backup "$fixture" "$repo" host-a "$output" 0
  first_status=$?
  rm -f "$repo/.git/local-backup-push-kit/prepared/host-a.state"
  output="$fixture/second.log"
  run_fake_backup "$fixture" "$repo" host-a "$output" 0
  second_status=$?
  count="$(compgen -G "$repo/backups/host-a/2026-01-02T03-04-05Z-*.tar.zst.age" | wc -l)"
  if [[ "$first_status" -ne 0 || "$second_status" -ne 0 || "$count" -ne 2 || ! -f "$old" ]]; then
    say_error "artifact IDs collided or old filename compatibility was lost"
    return 2
  fi
  while IFS= read -r path; do
    [[ "${path##*/}" =~ ^2026-01-02T03-04-05Z-[0-9]{9}\.tar\.zst\.age$ ]] || return 2
  done < <(compgen -G "$repo/backups/host-a/2026-01-02T03-04-05Z-*.tar.zst.age")
  return 0
}

scenario_locking_timeout() {
  local fixture repo data output status before_tree after_tree before_status after_status lock_fd
  new_fixture locking-timeout || return 2
  fixture="$FIXTURE" repo="$fixture/repo" data="$fixture/data"
  copy_template "$repo"
  install_common_shims "$fixture"
  rm -f "$fixture/bin/git"
  mkdir -p "$data"
  printf 'data\n' >"$data/file"
  write_config "$repo" host-a "$data"
  init_real_repo "$repo" || return 2
  /usr/bin/git init -q --bare "$fixture/origin.git" || return 2
  /usr/bin/git -C "$repo" remote add origin "$fixture/origin.git" || return 2
  /usr/bin/git -C "$repo" push -q origin HEAD:refs/heads/main || return 2
  mkdir -p "$repo/.git/local-backup-push-kit"
  exec {lock_fd}>"$repo/.git/local-backup-push-kit/lock"
  flock -n "$lock_fd" || return 2
  before_tree="$(/usr/bin/git -C "$repo" write-tree)"
  before_status="$(/usr/bin/git -C "$repo" status --porcelain=v1 --untracked-files=all)"
  output="$fixture/output.log"
  run_fixture_backup_env "$fixture" "$repo" host-a "$output" 0 BACKUP_LOCK_TIMEOUT=0
  status=$?
  after_tree="$(/usr/bin/git -C "$repo" write-tree)"
  after_status="$(/usr/bin/git -C "$repo" status --porcelain=v1 --untracked-files=all)"
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  if [[ "$status" -eq 0 || "$before_tree" != "$after_tree" || "$before_status" != "$after_status" || -s "$fixture/tar.log" || -e "$repo/backups" || -e "$repo/manifests" ]] || ! grep -Fq 'backup lock' "$output"; then
    say_error "lock loser mutated state or lacked backup lock diagnostic"
    return 2
  fi
  return 0
}

start_grouped_fixture_backup() {
  local fixture="$1" repo="$2" output="$3" delay="$4"
  local -a environment
  mapfile -t environment < <(fixture_env "$fixture")
  setsid env "${environment[@]}" LOCAL_BACKUP_TEST_REAL_SLEEP=1 LOCAL_BACKUP_TEST_TAR_DELAY="$delay" BACKUP_LOCK_TIMEOUT=5 BACKUP_HOST=host-a BACKUP_PUSH=0 bash "$repo/scripts/backup.sh" >"$output" 2>&1 &
  STARTED_GROUP_PID=$!
  ACTIVE_GROUPS+=("$STARTED_GROUP_PID")
}

wait_for_lock_held() {
  local lock_file="$1" attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [[ -e "$lock_file" ]] && ! flock -n "$lock_file" -c true 2>/dev/null; then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

scenario_locking() {
  local fixture repo data lock_file first_pid second_pid interrupted_pid first_status second_status interrupted_status final_status count
  setup_fake_backup_fixture locking || return 2
  fixture="$FIXTURE" repo="$REPO" data="$DATA"
  install_fixed_date_shim "$fixture"
  mkdir -p "$repo/.git/local-backup-push-kit"
  lock_file="$repo/.git/local-backup-push-kit/lock"
  : >"$lock_file"
  start_grouped_fixture_backup "$fixture" "$repo" "$fixture/first.log" 2
  first_pid="$STARTED_GROUP_PID"
  wait_for_lock_held "$lock_file" || return 2
  start_grouped_fixture_backup "$fixture" "$repo" "$fixture/second.log" 0
  second_pid="$STARTED_GROUP_PID"
  wait "$first_pid"; first_status=$?
  wait "$second_pid"; second_status=$?
  ACTIVE_GROUPS=()
  count="$(compgen -G "$repo/backups/host-a/2026-01-02T03-04-05Z-*.tar.zst.age" | wc -l)"
  if [[ "$first_status" -ne 0 || "$second_status" -eq 0 || "$count" -ne 1 ]] || ! grep -Fq 'prepared backup already exists' "$fixture/second.log"; then
    say_error "concurrent runs were not serialized behind one pending prepared state"
    return 2
  fi
  rm -f "$repo/.git/local-backup-push-kit/prepared/host-a.state"

  start_grouped_fixture_backup "$fixture" "$repo" "$fixture/interrupted.log" 60
  interrupted_pid="$STARTED_GROUP_PID"
  wait_for_lock_held "$lock_file" || return 2
  kill -TERM -- "-$interrupted_pid" 2>/dev/null || true
  wait "$interrupted_pid"
  interrupted_status=$?
  ACTIVE_GROUPS=()
  run_fixture_backup_env "$fixture" "$repo" host-a "$fixture/final.log" 0 BACKUP_LOCK_TIMEOUT=1
  final_status=$?
  if [[ "$interrupted_status" -eq 0 || "$final_status" -ne 0 ]]; then
    say_error "interrupted lock holder did not release lock"
    return 2
  fi
  return 0
}

source "$TESTS_DIR/lib/todo3.sh"
source "$TESTS_DIR/lib/todo4.sh"
source "$TESTS_DIR/lib/todo4_verifier_regressions.sh"
source "$TESTS_DIR/lib/todo5.sh"
source "$TESTS_DIR/lib/todo5_adversarial.sh"
source "$TESTS_DIR/lib/todo6.sh"
source "$TESTS_DIR/lib/todo6_adversarial.sh"
source "$TESTS_DIR/lib/todo7.sh"
source "$TESTS_DIR/lib/todo7_adversarial.sh"
source "$TESTS_DIR/lib/todo8.sh"
source "$TESTS_DIR/lib/todo8_adversarial.sh"
source "$TESTS_DIR/lib/todo9.sh"
source "$TESTS_DIR/lib/todo10.sh"
source "$TESTS_DIR/lib/todo11.sh"
source "$TESTS_DIR/lib/f2_blockers.sh"

todo3_install_git_wrapper() {
  local bin="$1"
  cat >"$bin/git" <<'EOF'
#!/usr/bin/env bash
set -u
fixture_dir="$(cd "$(dirname "$0")/.." && pwd)"
: "${FAKE_GIT_LOG:=$fixture_dir/git.log}"
printf '%q ' "$@" >>"${FAKE_GIT_LOG:?}"
printf '\n' >>"$FAKE_GIT_LOG"

repo=""
command_name=""
for ((i = 1; i <= $#; i++)); do
  arg="${!i}"
  if [[ "$arg" == "-C" ]]; then
    j=$((i + 1))
    repo="${!j}"
  fi
  case "$arg" in
    add|fetch|pull|push) command_name="$arg"; break ;;
  esac
done

if [[ "${TODO3_GIT_MODE:-}" == race-* && "$command_name" == "" && " $* " == *' status --porcelain=v1 '* ]]; then
  counter_file="${TODO3_GIT_RACE_COUNTER:?}"
  count=0
  [[ -f "$counter_file" ]] && count="$(/bin/cat "$counter_file")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$counter_file"
  /usr/bin/git "$@"
  status=$?
  if [[ "$count" == "2" ]]; then
    if [[ "$TODO3_GIT_MODE" == "race-tracked" ]]; then
      printf 'external tracked race\n' >>"$repo/RACE.txt"
    else
      printf 'external untracked race\n' >"$repo/RACE.txt"
    fi
    : >"${TODO3_GIT_RACE_MARKER:?}"
  fi
  exit "$status"
fi

if [[ "${TODO3_GIT_MODE:-}" == "stage-partial-fail" && "$command_name" == "add" ]]; then
  after_separator=0
  for arg in "$@"; do
    if [[ "$after_separator" == "1" ]]; then
      /usr/bin/git -C "$repo" add -- "$arg"
      exit 1
    fi
    [[ "$arg" == "--" ]] && after_separator=1
  done
  exit 1
fi

if [[ "${TODO3_GIT_MODE:-}" == "stage-delay" && "$command_name" == "add" ]]; then
  /usr/bin/git "$@"
  : >"${TODO3_GIT_DELAY_MARKER:?}"
  /bin/sleep "${TODO3_GIT_DELAY:?}"
  exit 0
fi

if [[ "${TODO3_GIT_MODE:-}" == "extra-stage" && "$command_name" == "add" ]]; then
  /usr/bin/git "$@"
  printf 'external staged injection\n' >>"$repo/README.md"
  /usr/bin/git -C "$repo" add -- README.md
  exit 0
fi

if [[ "${TODO3_FAKE_NETWORK:-0}" == "1" ]]; then
  case "$command_name" in
    fetch|pull|push) exit 0 ;;
  esac
fi

exec /usr/bin/git "$@"
EOF
  chmod +x "$bin/git"
}

run_selector_function() {
  case "$1" in
    baseline) scenario_baseline ;;
    retention-empty) scenario_retention_empty ;;
    partial-tar) scenario_partial_tar ;;
    relative-path) scenario_relative_path ;;
    ancestor-path) scenario_ancestor_path ;;
    symlink-path) scenario_symlink_path ;;
    same-second) scenario_same_second ;;
    multi-host-staged) scenario_multi_host_staged ;;
    empty-remote) scenario_empty_remote_todo4 ;;
    immutable-mirrors) scenario_post_commit_immutability ;;
    ssh-no-token) scenario_transports ;;
    broad-staging) scenario_broad_staging ;;
    schedule-user) scenario_schedule_user ;;
    manifest-memory) scenario_manifest_memory ;;
    docs-private-key) scenario_docs_private_key ;;
    todo7-baseline) scenario_todo7_baseline ;;
    source-only) scenario_source_only ;;
    ci-absence) scenario_ci_absence ;;
    docs-key-policy) scenario_docs_key_policy ;;
    migration-report) scenario_migration_report ;;
    migration-adopt-complete) scenario_migration_adopt_complete ;;
    migration-old-names) scenario_migration_old_names ;;
    migration-old-staged) scenario_migration_old_staged ;;
    migration-diverged) scenario_migration_diverged ;;
    migration-timer) scenario_migration_timer ;;
    migration-ci) scenario_migration_ci ;;
    migration-incomplete) scenario_migration_incomplete ;;
    migration-old-timer) scenario_migration_old_timer ;;
    migration-old-ci) scenario_migration_old_ci ;;
    migration-concurrent-adopt) scenario_migration_concurrent_adopt ;;
    readme-contract) scenario_readme_contract ;;
    readme-novice-flow) scenario_readme_novice_flow ;;
    readme-local-remotes) scenario_readme_local_remotes ;;
    readme-no-private-key) scenario_readme_no_private_key ;;
    readme-private-backup-repo) scenario_readme_private_backup_repo ;;
    readme-public-curl-gate) scenario_readme_public_curl_gate ;;
    prepared-state-diagnostic) scenario_prepared_state_diagnostic ;;
    llm-guide-contract) scenario_llm_guide_contract ;;
    llm-interview-sequence) scenario_llm_interview_sequence ;;
    llm-final-summary) scenario_llm_final_summary ;;
    llm-public-backup-narrative) scenario_llm_public_backup_narrative ;;
    llm-missing-public-key) scenario_llm_missing_public_key ;;
    llm-private-raw-url) scenario_llm_private_raw_url ;;
    llm-root-paths) scenario_llm_root_paths ;;
    llm-dirty-repo) scenario_llm_dirty_repo ;;
    llm-old-staged) scenario_llm_old_staged ;;
    source-only-generated) scenario_source_only_generated ;;
    source-only-extra-host) scenario_source_only_extra_host ;;
    source-only-keygen) scenario_source_only_keygen ;;
    source-only-blank-url) scenario_source_only_blank_url ;;
    source-only-broad-add) scenario_source_only_broad_add ;;
    source-only-missing-helper) scenario_source_only_missing_helper ;;
    source-only-symlink) scenario_source_only_symlink ;;
    source-only-tricky-names) scenario_source_only_tricky_names ;;
    network-guard) scenario_network_guard ;;
    harness-process-tree) scenario_harness_process_tree ;;
    harness-concurrency) scenario_harness_concurrency ;;
    harness-stale-owner) scenario_harness_stale_owner ;;
    path-validation) scenario_path_validation ;;
    config-validation) scenario_config_validation ;;
    config-age-recipient) scenario_config_age_recipient ;;
    config-branch-ref) scenario_config_branch_ref ;;
    config-retention-bound) scenario_config_retention_bound ;;
    config-timeout-canonical) scenario_config_timeout_canonical ;;
    artifact-id) scenario_artifact_id ;;
    locking-timeout) scenario_locking_timeout ;;
    locking) scenario_locking ;;
    prepare) scenario_prepare ;;
    decrypt) scenario_decrypt ;;
    checksum) scenario_checksum ;;
    state) scenario_state ;;
    schema-scaffold) scenario_schema_scaffold ;;
    exact-path-tricks) scenario_exact_path_tricks ;;
    prepared-reuse) scenario_prepared_reuse ;;
    direct-publication) scenario_direct_publication ;;
    exact-staging) scenario_exact_staging ;;
    manifest-memory-todo3) scenario_manifest_memory_todo3 ;;
    fail-tar) scenario_fail_tar ;;
    tar-failure) scenario_fail_tar ;;
    fail-age) scenario_fail_age ;;
    fail-checksum) scenario_fail_checksum ;;
    fail-manifest) scenario_fail_manifest ;;
    fail-state) scenario_fail_state ;;
    fail-staging) scenario_fail_staging ;;
    extra-stage-injection) scenario_extra_stage_injection ;;
    race-tracked) scenario_race_tracked ;;
    race-untracked) scenario_race_untracked ;;
    storage-symlinks) scenario_storage_symlinks ;;
    prepared-hardlink) scenario_prepared_hardlink ;;
    output-hardlink) scenario_output_hardlink ;;
    historical-rollback) scenario_historical_rollback ;;
    dirty-index) scenario_dirty_index_todo3 ;;
    prepared-stale) scenario_prepared_stale ;;
    prepared-tampered) scenario_prepared_tampered ;;
    state-malformed) scenario_state_malformed ;;
    state-validation) scenario_state_validation ;;
    interrupt-tar-todo3) scenario_interrupt_tar_todo3 ;;
    interrupt-age-todo3) scenario_interrupt_age_todo3 ;;
    interrupt-checksum-todo3) scenario_interrupt_checksum_todo3 ;;
    interrupt-manifest-todo3) scenario_interrupt_manifest_todo3 ;;
    interrupt-install-todo3) scenario_interrupt_install_todo3 ;;
    interrupt-state-todo3) scenario_interrupt_state_todo3 ;;
    interrupt-stage-todo3) scenario_interrupt_stage_todo3 ;;
    publish) scenario_publish ;;
    transports) scenario_transports ;;
    custom-branch) scenario_custom_branch_todo4 ;;
    retry-state) scenario_retry_state ;;
    legacy-state-retry) scenario_legacy_prepared_state_retry ;;
    canonical-moved) scenario_canonical_moved ;;
    canonical-deleted) scenario_canonical_deleted_after_prepare ;;
    immutable-mirror-divergence) scenario_immutable_mirror_divergence ;;
    missing-remote) scenario_missing_remote_todo4 ;;
    branch-guards) scenario_branch_guards ;;
    post-commit-immutability) scenario_post_commit_immutability ;;
    commit-state-recovery) scenario_commit_state_recovery ;;
    remote-status-recovery) scenario_remote_status_recovery ;;
    canonical-preprepare-sync) scenario_canonical_preprepare_sync ;;
    private-http-canonical-preprepare) scenario_private_http_canonical_preprepare ;;
    remote-validation-todo4) scenario_remote_validation_todo4 ;;
    verifier-baseline-todo4) scenario_verifier_baseline_todo4 ;;
    canonical-only-precommit-todo4) scenario_canonical_only_precommit_todo4 ;;
    retry-branch-guard-todo4) scenario_retry_branch_guard_todo4 ;;
    token-key-collisions-todo4) scenario_token_key_collisions_todo4 ;;
    push-provider-credentials-todo4) scenario_push_provider_credentials_todo4 ;;
    provider-hostname-fallback-todo4) scenario_provider_hostname_fallback_todo4 ;;
    control-url-validation-todo4) scenario_control_url_validation_todo4 ;;
    hung-git-publication-todo4) scenario_hung_git_publication_todo4 ;;
    retention) scenario_retention ;;
    retention-failure) scenario_retention_failure ;;
    multi-host) scenario_retention_multi_host ;;
    retention-old-new) scenario_retention_old_new ;;
    retention-multi-host) scenario_retention_multi_host ;;
    latest-repair) scenario_latest_repair ;;
    retention-orphan) scenario_retention_orphan ;;
    retention-commit-failure) scenario_retention_commit_failure ;;
    retention-prepare-failure) scenario_retention_prepare_failure ;;
    retention-precommit-failure) scenario_retention_precommit_failure ;;
    retention-state-tamper) scenario_retention_state_tamper ;;
    retention-count-one) scenario_retention_count_one ;;
    retention-parent-recovery) scenario_retention_parent_recovery ;;
    retention-unproven-advanced-recovery) scenario_retention_unproven_advanced_recovery ;;
    retention-replace-ref-recovery) scenario_retention_replace_ref_recovery ;;
    retention-deleted-path-read-failure) scenario_retention_deleted_path_read_failure ;;
    retention-journal-cross-binding) scenario_retention_journal_cross_binding ;;
    retention-head-read-failures) scenario_retention_head_read_failures ;;
    retention-retry-state) scenario_retention_retry_state ;;
    retention-interrupt-precommit) scenario_retention_interrupt_precommit ;;
    retention-interrupt-postcommit) scenario_retention_interrupt_postcommit ;;
    todo6-baseline) scenario_todo6_baseline ;;
    systemd-render) scenario_systemd_render ;;
    systemd-render-daily) scenario_systemd_render_daily ;;
    systemd-render-weekly) scenario_systemd_render_weekly ;;
    systemd-two-hosts) scenario_systemd_two_hosts ;;
    token-entry) scenario_token_entry ;;
    timer-migration) scenario_timer_migration ;;
    systemd-old-timer-guard) scenario_systemd_old_timer_guard ;;
    systemd-invalid-fields) scenario_systemd_invalid_fields ;;
    systemd-install-rollback) scenario_systemd_install_rollback ;;
    token-entry-interrupt) scenario_token_entry_interrupt ;;
    token-entry-collision) scenario_token_entry_collision ;;
    systemd-install-interrupt) scenario_systemd_install_interrupt ;;
    systemd-runtime-state-rollback) scenario_systemd_runtime_state_rollback ;;
    systemd-root-opt-in) scenario_systemd_root_opt_in ;;
    systemd-parser-verify) scenario_systemd_parser_verify ;;
    systemd-identity-defaults) scenario_systemd_identity_defaults ;;
    systemd-env-validation) scenario_systemd_env_validation ;;
    token-entry-eof) scenario_token_entry_eof ;;
    e2e-prepare-decrypt-publish) scenario_e2e_prepare_decrypt_publish ;;
    e2e-mirror-retry) scenario_e2e_mirror_retry ;;
    e2e-multi-host-retention) scenario_e2e_multi_host_retention ;;
    e2e-systemd-render) scenario_e2e_systemd_render ;;
    e2e-migration-dry-run) scenario_e2e_migration_dry_run ;;
    f2-retention-durable-tristate) scenario_f2_retention_durable_tristate ;;
    f2-canonical-publication-shape) scenario_f2_canonical_publication_shape ;;
    f2-root-launcher-transaction) scenario_f2_root_launcher_transaction ;;
    *) return 64 ;;
  esac
}
