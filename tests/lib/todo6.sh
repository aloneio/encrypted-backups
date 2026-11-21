#!/usr/bin/env bash

scenario_todo6_baseline() {
  local installer="$PROJECT_ROOT/scripts/install-systemd-timer.sh"
  [[ -x "$installer" ]] || return 2
  bash -n "$installer" || return 2
  if grep -Eq '(^|[^A-Za-z])(curl|wget)([^A-Za-z]|$)' "$installer"; then return 2; fi
}

todo6_setup() {
  local name="$1" host="${2:-testbox}" repo_name="${3:-repo}"
  new_fixture "todo6-$name" || return 2
  TODO6_FIXTURE="$FIXTURE"
  TODO6_REPO="$TODO6_FIXTURE/$repo_name"
  TODO6_HOST="$host"
  TODO6_SYSTEMD="$TODO6_FIXTURE/systemd"
  TODO6_ENV="$TODO6_FIXTURE/env"
  TODO6_LOG="$TODO6_FIXTURE/actions.log"
  copy_template "$TODO6_REPO"
  mkdir -p "$TODO6_FIXTURE/bin" "$TODO6_SYSTEMD" "$TODO6_ENV"
  cat >"$TODO6_FIXTURE/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo' >>"${TODO6_LOG:?}"
printf ' %q' "$@" >>"$TODO6_LOG"
printf '\n' >>"$TODO6_LOG"
exec "$@"
EOF
  cat >"$TODO6_FIXTURE/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl' >>"${TODO6_LOG:?}"
printf ' %q' "$@" >>"$TODO6_LOG"
printf '\n' >>"$TODO6_LOG"
case "${1:-}" in
  is-enabled|is-active) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$TODO6_FIXTURE/bin/sudo" "$TODO6_FIXTURE/bin/systemctl"
}

todo6_write_config() {
  local user="$1" group="$2" calendar="$3"
  shift 3
  mkdir -p "$TODO6_REPO/hosts/$TODO6_HOST"
  {
    printf 'CONFIG_HOST_ID=%q\n' "$TODO6_HOST"
    printf 'AGE_RECIPIENT=%q\n' "$TEST_AGE_RECIPIENT"
    printf '%s\n' 'BACKUP_BRANCH="main"'
    printf '%s' 'BACKUP_REMOTES=('; printf ' %q' "$@"; printf ' )\n'
    printf '%s\n' 'BACKUP_PATHS=("/etc/hostname")'
    printf 'BACKUP_RUN_USER=%q\n' "$user"
    printf 'BACKUP_RUN_GROUP=%q\n' "$group"
    printf 'BACKUP_ON_CALENDAR=%q\n' "$calendar"
  } >"$TODO6_REPO/hosts/$TODO6_HOST/backup.conf"
}

todo6_remove_runtime_config() {
  python3 - "$TODO6_REPO/hosts/$TODO6_HOST/backup.conf" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
blocked = ("BACKUP_RUN_USER=", "BACKUP_RUN_GROUP=", "BACKUP_ON_CALENDAR=")
path.write_text("\n".join(line for line in lines if not line.startswith(blocked)) + "\n", encoding="utf-8")
PY
}

todo6_run_installer() {
  local output="$1"
  shift
  local -a extra_environment=() arguments=()
  while [[ "${1:-}" == *=* ]]; do
    extra_environment+=("$1")
    shift
  done
  arguments=("$@")
  run_captured "$output" 10 env \
    PATH="$TODO6_FIXTURE/bin:$PATH" \
    TODO6_LOG="$TODO6_LOG" \
    BACKUP_HOST="$TODO6_HOST" \
    BACKUP_SYSTEMD_DIR="$TODO6_SYSTEMD" \
    BACKUP_ENV_DIR="$TODO6_ENV" \
    "${extra_environment[@]}" \
    bash "$TODO6_REPO/scripts/install-systemd-timer.sh" "${arguments[@]}"
}

todo6_assert_render() {
  local output="$1" calendar="$2" unit="encrypted-git-backup-$TODO6_HOST"
  grep -Fq -- "--- $TODO6_SYSTEMD/$unit.service ---" "$output" || return 2
  grep -Fq -- "--- $TODO6_SYSTEMD/$unit.timer ---" "$output" || return 2
  grep -Fq 'User=backupsvc' "$output" || return 2
  grep -Fq 'Group=backupsvc' "$output" || return 2
  grep -Fq "OnCalendar=$calendar" "$output" || return 2
  grep -Fq "EnvironmentFile=-$TODO6_ENV/$TODO6_HOST.env" "$output" || return 2
  grep -Fq 'Environment="BACKUP_PUSH=1"' "$output" || return 2
  [[ ! -s "$TODO6_LOG" && ! -e "$TODO6_SYSTEMD/$unit.service" ]] || return 2
}

scenario_systemd_render() {
  todo6_setup render testbox 'repo $%"slash\path' || return 2
  todo6_write_config backupsvc backupsvc '*-*-* 03:15:00' origin
  todo6_run_installer "$TODO6_FIXTURE/render.log" BACKUP_INSTALL_DRY_RUN=1 || return 2
  todo6_assert_render "$TODO6_FIXTURE/render.log" '*-*-* 03:15:00' || return 2
  grep -Fq '$$' "$TODO6_FIXTURE/render.log" || return 2
  grep -Fq '%%' "$TODO6_FIXTURE/render.log" || return 2
  grep -Fq '\"' "$TODO6_FIXTURE/render.log" || return 2
  grep -Fq '\\' "$TODO6_FIXTURE/render.log" || return 2
}

scenario_systemd_render_daily() {
  todo6_setup daily || return 2
  todo6_write_config backupsvc backupsvc daily origin
  todo6_run_installer "$TODO6_FIXTURE/render.log" BACKUP_INSTALL_DRY_RUN=1 || return 2
  todo6_assert_render "$TODO6_FIXTURE/render.log" daily
}

scenario_systemd_render_weekly() {
  todo6_setup weekly || return 2
  todo6_write_config backupsvc backupsvc weekly origin
  todo6_run_installer "$TODO6_FIXTURE/render.log" BACKUP_INSTALL_DRY_RUN=1 || return 2
  todo6_assert_render "$TODO6_FIXTURE/render.log" weekly
}

scenario_systemd_two_hosts() {
  local first second
  todo6_setup two-hosts host-a || return 2
  todo6_write_config backupsvc backupsvc daily origin
  todo6_run_installer "$TODO6_FIXTURE/host-a.log" BACKUP_INSTALL_DRY_RUN=1 || return 2
  first="$TODO6_FIXTURE/host-a.log"
  TODO6_HOST=host-b
  todo6_write_config backupsvc backupsvc weekly origin
  todo6_run_installer "$TODO6_FIXTURE/host-b.log" BACKUP_INSTALL_DRY_RUN=1 || return 2
  second="$TODO6_FIXTURE/host-b.log"
  grep -Fq 'encrypted-git-backup-host-a.service' "$first" || return 2
  grep -Fq 'encrypted-git-backup-host-b.service' "$second" || return 2
  if grep -Fq 'encrypted-git-backup-host-b' "$first" || grep -Fq 'encrypted-git-backup-host-a' "$second"; then return 2; fi
}

todo6_init_remotes() {
  /usr/bin/git init -q "$TODO6_REPO" || return 2
  /usr/bin/git -C "$TODO6_REPO" remote add http-main https://example.invalid/backup.git
  /usr/bin/git -C "$TODO6_REPO" remote add native-local "$TODO6_FIXTURE/native.git"
}

todo6_run_secrets() {
  local output="$1" input="$2"
  shift 2
  printf '%s\n' "$input" | run_captured "$output" 10 env \
    PATH="$TODO6_FIXTURE/bin:$PATH" TODO6_LOG="$TODO6_LOG" \
    BACKUP_HOST="$TODO6_HOST" BACKUP_ENV_DIR="$TODO6_ENV" \
    "$@" bash "$TODO6_REPO/scripts/configure-secrets.sh"
}

scenario_token_entry() {
  local secret='placeholder token $%# value'
  todo6_setup token-entry || return 2
  todo6_write_config backupsvc backupsvc daily http-main native-local
  todo6_init_remotes || return 2
  todo6_run_secrets "$TODO6_FIXTURE/token.log" "$secret" || return 2
  local env_file="$TODO6_ENV/$TODO6_HOST.env"
  [[ -f "$env_file" && "$(stat -c %a "$env_file")" == 600 ]] || return 2
  grep -Fq 'BACKUP_TOKEN_HTTP_MAIN=' "$env_file" || return 2
  if grep -Fq 'BACKUP_TOKEN_NATIVE_LOCAL=' "$env_file"; then return 2; fi
  if grep -Fq "$secret" "$TODO6_FIXTURE/token.log" || grep -Fq "$secret" "$TODO6_LOG"; then return 2; fi
  grep -Fq 'http-main' "$TODO6_FIXTURE/token.log" || return 2
  if grep -Fq 'native-local' "$TODO6_FIXTURE/token.log"; then return 2; fi
}

scenario_timer_migration() {
  todo6_setup migration || return 2
  todo6_write_config backupsvc backupsvc daily origin
  printf 'legacy service\n' >"$TODO6_SYSTEMD/encrypted-git-backup.service"
  printf 'legacy timer\n' >"$TODO6_SYSTEMD/encrypted-git-backup.timer"
  if todo6_run_installer "$TODO6_FIXTURE/guard.log"; then return 2; fi
  [[ ! -e "$TODO6_SYSTEMD/encrypted-git-backup-testbox.service" ]] || return 2
  todo6_run_installer "$TODO6_FIXTURE/migrate.log" BACKUP_REPLACE_EXISTING=1 || return 2
  [[ -f "$TODO6_SYSTEMD/encrypted-git-backup-testbox.service" && -f "$TODO6_SYSTEMD/encrypted-git-backup-testbox.timer" ]] || return 2
  grep -Fq 'systemctl disable --now encrypted-git-backup.timer' "$TODO6_LOG" || return 2
}

scenario_systemd_parser_verify() {
  command -v systemd-analyze >/dev/null 2>&1 || return 2
  todo6_setup parser-verify testbox 'repo $%"slash\path' || return 2
  todo6_write_config backupsvc backupsvc weekly origin
  todo6_run_installer "$TODO6_FIXTURE/install.log" || return 2
  systemd-analyze verify \
    "$TODO6_SYSTEMD/encrypted-git-backup-testbox.service" \
    "$TODO6_SYSTEMD/encrypted-git-backup-testbox.timer" \
    >"$TODO6_FIXTURE/verify.log" 2>&1 || {
      cat "$TODO6_FIXTURE/verify.log" >&2
      return 2
    }
}

scenario_systemd_identity_defaults() {
  todo6_setup identity-defaults || return 2
  todo6_write_config ignored ignored ignored origin
  todo6_remove_runtime_config
  cat >"$TODO6_FIXTURE/bin/id" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -un) printf 'invoking-user\n' ;;
  -gn) printf 'invoking-group\n' ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$TODO6_FIXTURE/bin/id"
  todo6_run_installer "$TODO6_FIXTURE/defaults.log" BACKUP_INSTALL_DRY_RUN=1 || return 2
  grep -Fq 'User=invoking-user' "$TODO6_FIXTURE/defaults.log" || return 2
  grep -Fq 'Group=invoking-group' "$TODO6_FIXTURE/defaults.log" || return 2
  grep -Fq 'OnCalendar=daily' "$TODO6_FIXTURE/defaults.log" || return 2
  [[ ! -s "$TODO6_LOG" ]] || return 2
  todo6_run_installer "$TODO6_FIXTURE/sudo-user.log" BACKUP_INSTALL_DRY_RUN=1 SUDO_USER=sudo-user || return 2
  grep -Fq 'User=sudo-user' "$TODO6_FIXTURE/sudo-user.log" || return 2
  grep -Fq 'Group=invoking-group' "$TODO6_FIXTURE/sudo-user.log" || return 2
}
