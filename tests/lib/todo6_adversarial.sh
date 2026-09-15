#!/usr/bin/env bash

scenario_systemd_old_timer_guard() {
  todo6_setup old-timer || return 2
  todo6_write_config backupsvc backupsvc daily origin
  printf 'legacy timer\n' >"$TODO6_SYSTEMD/encrypted-git-backup.timer"
  if todo6_run_installer "$TODO6_FIXTURE/guard.log"; then return 2; fi
  [[ "$(<"$TODO6_SYSTEMD/encrypted-git-backup.timer")" == 'legacy timer' ]] || return 2
  [[ ! -e "$TODO6_SYSTEMD/encrypted-git-backup-testbox.timer" && ! -s "$TODO6_LOG" ]] || return 2
}

scenario_systemd_invalid_fields() {
  local field expected
  for field in user group calendar; do
    todo6_setup "invalid-$field" || return 2
    case "$field" in
      user) todo6_write_config 'bad user' backupsvc daily origin; expected=BACKUP_RUN_USER ;;
      group) todo6_write_config backupsvc 'bad/group' daily origin; expected=BACKUP_RUN_GROUP ;;
      calendar) todo6_write_config backupsvc backupsvc $'daily\nOnBootSec=1' origin; expected=BACKUP_ON_CALENDAR ;;
    esac
    if todo6_run_installer "$TODO6_FIXTURE/invalid.log" BACKUP_INSTALL_DRY_RUN=1; then return 2; fi
    grep -Fq "$expected" "$TODO6_FIXTURE/invalid.log" || return 2
    [[ ! -s "$TODO6_LOG" && -z "$(find "$TODO6_SYSTEMD" -mindepth 1 -print -quit)" ]] || return 2
  done
  todo6_setup invalid-root || return 2
  todo6_write_config root root daily origin
  todo6_remove_runtime_config
  cat >"$TODO6_FIXTURE/bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -un|-gn) printf 'root\n' ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$TODO6_FIXTURE/bin/id"
  if todo6_run_installer "$TODO6_FIXTURE/root.log" BACKUP_INSTALL_DRY_RUN=1 SUDO_USER=; then return 2; fi
  grep -Fq 'root' "$TODO6_FIXTURE/root.log" || return 2
  [[ ! -s "$TODO6_LOG" ]] || return 2
}

scenario_systemd_root_opt_in() {
  todo6_setup root-opt-in || return 2
  todo6_write_config root root daily origin
  if todo6_run_installer "$TODO6_FIXTURE/root.log" BACKUP_INSTALL_DRY_RUN=1; then return 2; fi
  grep -Fq 'trusted repository' "$TODO6_FIXTURE/root.log" || return 2
  [[ ! -s "$TODO6_LOG" && -z "$(find "$TODO6_SYSTEMD" -mindepth 1 -print -quit)" ]] || return 2
}

scenario_systemd_env_validation() {
  local assignment expected
  for assignment in BACKUP_INSTALL_DRY_RUN=2 BACKUP_REPLACE_EXISTING=yes BACKUP_SYSTEMD_DIR=relative; do
    todo6_setup "env-${assignment%%=*}" || return 2
    todo6_write_config backupsvc backupsvc daily origin
    expected="${assignment%%=*}"
    if todo6_run_installer "$TODO6_FIXTURE/env.log" "$assignment"; then return 2; fi
    grep -Fq "$expected" "$TODO6_FIXTURE/env.log" || return 2
    [[ ! -s "$TODO6_LOG" && -z "$(find "$TODO6_SYSTEMD" -mindepth 1 -print -quit)" ]] || return 2
  done
}

scenario_systemd_install_rollback() {
  todo6_setup rollback || return 2
  todo6_write_config backupsvc backupsvc daily origin
  local service="$TODO6_SYSTEMD/encrypted-git-backup-testbox.service"
  local timer="$TODO6_SYSTEMD/encrypted-git-backup-testbox.timer"
  printf 'old service\n' >"$service"
  printf 'old timer\n' >"$timer"
  cat >"$TODO6_FIXTURE/bin/install" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f "${TODO6_INSTALL_COUNT:?}" ]] && count="$(<"$TODO6_INSTALL_COUNT")"
count=$((count + 1)); printf '%s\n' "$count" >"$TODO6_INSTALL_COUNT"
if [[ "$count" -eq 2 ]]; then exit 71; fi
exec /usr/bin/install "$@"
EOF
  chmod +x "$TODO6_FIXTURE/bin/install"
  if todo6_run_installer "$TODO6_FIXTURE/rollback.log" TODO6_INSTALL_COUNT="$TODO6_FIXTURE/install.count"; then return 2; fi
  [[ -f "$TODO6_FIXTURE/install.count" && "$(<"$TODO6_FIXTURE/install.count")" == 2 ]] || return 2
  [[ "$(<"$service")" == 'old service' && "$(<"$timer")" == 'old timer' ]] || return 2
}

scenario_token_entry_interrupt() {
  todo6_setup token-interrupt || return 2
  [[ -x "$TODO6_REPO/scripts/configure-secrets.sh" ]] || return 2
  todo6_write_config backupsvc backupsvc daily http-main
  todo6_init_remotes || return 2
  mkfifo "$TODO6_FIXTURE/input.fifo"
  exec 9<>"$TODO6_FIXTURE/input.fifo"
  env PATH="$TODO6_FIXTURE/bin:$PATH" TODO6_LOG="$TODO6_LOG" \
    BACKUP_HOST="$TODO6_HOST" BACKUP_ENV_DIR="$TODO6_ENV" \
    bash "$TODO6_REPO/scripts/configure-secrets.sh" \
    <"$TODO6_FIXTURE/input.fifo" >"$TODO6_FIXTURE/interrupt.log" 2>&1 &
  local pid=$! attempt prompted=0
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    if grep -Fq 'http-main' "$TODO6_FIXTURE/interrupt.log" 2>/dev/null; then prompted=1; break; fi
    /bin/sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  exec 9>&-
  [[ "$prompted" == 1 ]] || return 2
  [[ ! -e "$TODO6_ENV/$TODO6_HOST.env" ]] || return 2
  [[ -z "$(find "$TODO6_ENV" -mindepth 1 -print -quit)" ]] || return 2
}

scenario_token_entry_collision() {
  todo6_setup token-collision || return 2
  todo6_write_config backupsvc backupsvc daily foo-bar foo_bar
  /usr/bin/git init -q "$TODO6_REPO" || return 2
  /usr/bin/git -C "$TODO6_REPO" remote add foo-bar https://example.invalid/one.git
  /usr/bin/git -C "$TODO6_REPO" remote add foo_bar https://example.invalid/two.git
  if todo6_run_secrets "$TODO6_FIXTURE/collision.log" 'placeholder'; then return 2; fi
  grep -Fq 'token key collision' "$TODO6_FIXTURE/collision.log" || return 2
  if grep -Fq 'Token for HTTP remote' "$TODO6_FIXTURE/collision.log"; then return 2; fi
  [[ -z "$(find "$TODO6_ENV" -mindepth 1 -print -quit)" && ! -s "$TODO6_LOG" ]] || return 2
}

scenario_token_entry_eof() {
  todo6_setup token-eof || return 2
  todo6_write_config backupsvc backupsvc daily http-main
  todo6_init_remotes || return 2
  if run_captured "$TODO6_FIXTURE/eof.log" 10 env \
    PATH="$TODO6_FIXTURE/bin:$PATH" TODO6_LOG="$TODO6_LOG" \
    BACKUP_HOST="$TODO6_HOST" BACKUP_ENV_DIR="$TODO6_ENV" \
    bash "$TODO6_REPO/scripts/configure-secrets.sh" </dev/null; then return 2; fi
  grep -Fq "token entry ended before remote 'http-main'" "$TODO6_FIXTURE/eof.log" || return 2
  [[ -z "$(find "$TODO6_ENV" -mindepth 1 -print -quit)" && ! -s "$TODO6_LOG" ]] || return 2
}

scenario_systemd_install_interrupt() {
  todo6_setup install-interrupt || return 2
  todo6_write_config backupsvc backupsvc daily origin
  local service="$TODO6_SYSTEMD/encrypted-git-backup-testbox.service"
  local timer="$TODO6_SYSTEMD/encrypted-git-backup-testbox.timer"
  printf 'old service\n' >"$service"
  printf 'old timer\n' >"$timer"
  cat >"$TODO6_FIXTURE/bin/install" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f "${TODO6_INSTALL_COUNT:?}" ]] && count="$(<"$TODO6_INSTALL_COUNT")"
count=$((count + 1)); printf '%s\n' "$count" >"$TODO6_INSTALL_COUNT"
if [[ "$count" -eq 2 ]]; then
  : >"${TODO6_INSTALL_MARKER:?}"
  /bin/sleep 60
  exit 72
fi
exec /usr/bin/install "$@"
EOF
  chmod +x "$TODO6_FIXTURE/bin/install"
  setsid env PATH="$TODO6_FIXTURE/bin:$PATH" TODO6_LOG="$TODO6_LOG" \
    TODO6_INSTALL_COUNT="$TODO6_FIXTURE/install.count" \
    TODO6_INSTALL_MARKER="$TODO6_FIXTURE/install.marker" \
    BACKUP_HOST="$TODO6_HOST" BACKUP_SYSTEMD_DIR="$TODO6_SYSTEMD" BACKUP_ENV_DIR="$TODO6_ENV" \
    bash "$TODO6_REPO/scripts/install-systemd-timer.sh" >"$TODO6_FIXTURE/interrupt-install.log" 2>&1 &
  local pid=$! attempt
  ACTIVE_GROUPS+=("$pid")
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -e "$TODO6_FIXTURE/install.marker" ]] && break
    /bin/sleep 0.1
  done
  [[ -e "$TODO6_FIXTURE/install.marker" ]] || return 2
  kill -TERM -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  ACTIVE_GROUPS=()
  [[ "$(<"$service")" == 'old service' && "$(<"$timer")" == 'old timer' ]] || return 2
}

todo6_write_stateful_systemctl() {
  cat >"$TODO6_FIXTURE/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
state_dir="${TODO6_SYSTEMCTL_STATE:?}"
command_name="${1:-}"
shift || true
printf 'systemctl %q' "$command_name" >>"${TODO6_LOG:?}"
printf ' %q' "$@" >>"$TODO6_LOG"
printf '\n' >>"$TODO6_LOG"
state_value() { [[ -f "$state_dir/$1.$2" ]] && cat "$state_dir/$1.$2" || printf '0\n'; }
set_state() { printf '%s\n' "$3" >"$state_dir/$1.$2"; }
case "$command_name" in
  is-enabled) [[ "$(state_value "$1" enabled)" == 1 ]] ;;
  is-active) [[ "$(state_value "$1" active)" == 1 ]] ;;
  enable)
    now=0
    [[ "${1:-}" != --now ]] || { now=1; shift; }
    set_state "$1" enabled 1
    [[ "$now" == 0 ]] || set_state "$1" active 1
    ;;
  disable)
    now=0
    [[ "${1:-}" != --now ]] || { now=1; shift; }
    unit="$1"
    set_state "$unit" enabled 0
    [[ "$now" == 0 ]] || set_state "$unit" active 0
    if [[ "$unit" == encrypted-git-backup.timer && ! -e "${TODO6_SYSTEMCTL_ONCE:?}" ]]; then
      : >"$TODO6_SYSTEMCTL_ONCE"
      case "${TODO6_SYSTEMCTL_MODE:?}" in
        fail) exit 77 ;;
        block) : >"${TODO6_SYSTEMCTL_MARKER:?}"; /bin/sleep 60 ;;
      esac
    fi
    ;;
  start) set_state "$1" active 1 ;;
  stop) set_state "$1" active 0 ;;
  daemon-reload) : ;;
  *) exit 64 ;;
esac
EOF
  chmod +x "$TODO6_FIXTURE/bin/systemctl"
}

todo6_set_timer_state() {
  local unit="$1" enabled="$2" active="$3"
  printf '%s\n' "$enabled" >"$TODO6_FIXTURE/systemctl-state/$unit.enabled"
  printf '%s\n' "$active" >"$TODO6_FIXTURE/systemctl-state/$unit.active"
}

todo6_assert_timer_state() {
  local unit="$1" enabled="$2" active="$3"
  [[ "$(<"$TODO6_FIXTURE/systemctl-state/$unit.enabled")" == "$enabled" ]] || return 1
  [[ "$(<"$TODO6_FIXTURE/systemctl-state/$unit.active")" == "$active" ]] || return 1
}

todo6_runtime_rollback_case() {
  local mode="$1" host_enabled="$2" host_active="$3" legacy_enabled="$4" legacy_active="$5" host_files="$6"
  local host_timer=encrypted-git-backup-testbox.timer legacy_timer=encrypted-git-backup.timer status pid attempt
  todo6_setup "runtime-$mode" || return 2
  todo6_write_config backupsvc backupsvc daily origin
  mkdir -p "$TODO6_FIXTURE/systemctl-state"
  todo6_write_stateful_systemctl
  todo6_set_timer_state "$host_timer" "$host_enabled" "$host_active"
  todo6_set_timer_state "$legacy_timer" "$legacy_enabled" "$legacy_active"
  printf 'legacy service\n' >"$TODO6_SYSTEMD/encrypted-git-backup.service"
  printf 'legacy timer\n' >"$TODO6_SYSTEMD/encrypted-git-backup.timer"
  if [[ "$host_files" == 1 ]]; then
    printf 'old host service\n' >"$TODO6_SYSTEMD/encrypted-git-backup-testbox.service"
    printf 'old host timer\n' >"$TODO6_SYSTEMD/encrypted-git-backup-testbox.timer"
  fi
  if [[ "$mode" == fail ]]; then
    if todo6_run_installer "$TODO6_FIXTURE/runtime-fail.log" \
      TODO6_SYSTEMCTL_STATE="$TODO6_FIXTURE/systemctl-state" TODO6_SYSTEMCTL_MODE=fail \
      TODO6_SYSTEMCTL_ONCE="$TODO6_FIXTURE/systemctl.once" TODO6_SYSTEMCTL_MARKER="$TODO6_FIXTURE/systemctl.marker" \
      BACKUP_REPLACE_EXISTING=1; then return 2; fi
  else
    setsid env PATH="$TODO6_FIXTURE/bin:$PATH" TODO6_LOG="$TODO6_LOG" \
      TODO6_SYSTEMCTL_STATE="$TODO6_FIXTURE/systemctl-state" TODO6_SYSTEMCTL_MODE=block \
      TODO6_SYSTEMCTL_ONCE="$TODO6_FIXTURE/systemctl.once" TODO6_SYSTEMCTL_MARKER="$TODO6_FIXTURE/systemctl.marker" \
      BACKUP_HOST="$TODO6_HOST" BACKUP_SYSTEMD_DIR="$TODO6_SYSTEMD" BACKUP_ENV_DIR="$TODO6_ENV" BACKUP_REPLACE_EXISTING=1 \
      bash "$TODO6_REPO/scripts/install-systemd-timer.sh" >"$TODO6_FIXTURE/runtime-term.log" 2>&1 &
    pid=$!
    ACTIVE_GROUPS+=("$pid")
    for attempt in {1..100}; do [[ -e "$TODO6_FIXTURE/systemctl.marker" ]] && break; /bin/sleep 0.1; done
    [[ -e "$TODO6_FIXTURE/systemctl.marker" ]] || return 2
    terminate_process_group "$pid"
    wait "$pid"; status=$?
    ACTIVE_GROUPS=()
    [[ "$status" -eq 143 ]] || return 2
    process_group_alive "$pid" && return 2
  fi
  if [[ "$host_files" == 1 ]]; then
    [[ "$(<"$TODO6_SYSTEMD/encrypted-git-backup-testbox.service")" == 'old host service' ]] || return 2
    [[ "$(<"$TODO6_SYSTEMD/encrypted-git-backup-testbox.timer")" == 'old host timer' ]] || return 2
  else
    [[ ! -e "$TODO6_SYSTEMD/encrypted-git-backup-testbox.service" && ! -e "$TODO6_SYSTEMD/encrypted-git-backup-testbox.timer" ]] || return 2
  fi
  [[ "$(<"$TODO6_SYSTEMD/encrypted-git-backup.service")" == 'legacy service' ]] || return 2
  [[ "$(<"$TODO6_SYSTEMD/encrypted-git-backup.timer")" == 'legacy timer' ]] || return 2
  grep -Fq 'systemctl daemon-reload' "$TODO6_LOG" || return 2
  if ! todo6_assert_timer_state "$host_timer" "$host_enabled" "$host_active" || \
     ! todo6_assert_timer_state "$legacy_timer" "$legacy_enabled" "$legacy_active"; then
    return 42
  fi
}

scenario_systemd_runtime_state_rollback() {
  local failure_status term_status
  todo6_runtime_rollback_case fail 1 0 0 1 1; failure_status=$?
  todo6_runtime_rollback_case term 0 1 1 0 0; term_status=$?
  if [[ "$failure_status" -eq 42 || "$term_status" -eq 42 ]]; then
    known_failure "systemd rollback loses enabled/active state after failure or TERM"
    return $?
  fi
  [[ "$failure_status" -eq 0 && "$term_status" -eq 0 ]] || return 2
}
