#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_ID="${BACKUP_HOST:-$(hostname -s)}"
SYSTEMD_DIR="${BACKUP_SYSTEMD_DIR:-/etc/systemd/system}"
ENV_DIR="${BACKUP_ENV_DIR:-/etc/encrypted-git-backup}"
ROOT_LAUNCHER_DIR="${BACKUP_ROOT_LAUNCHER_DIR:-/usr/local/libexec/local-backup-push-kit}"
DRY_RUN="${BACKUP_INSTALL_DRY_RUN:-0}"
REPLACE_EXISTING="${BACKUP_REPLACE_EXISTING:-0}"
TEMP_DIR=""
TRANSACTION_ACTIVE=0
ROLLBACK_RUNNING=0
ROLLBACK_FAILED=0
HOST_TIMER_MUTATION_ATTEMPTED=0
LEGACY_TIMER_MUTATION_ATTEMPTED=0
LEGACY_TIMER_STATE_TRACKED=0
HOST_TIMER_WAS_ENABLED=0
HOST_TIMER_WAS_ACTIVE=0
LEGACY_TIMER_WAS_ENABLED=0
LEGACY_TIMER_WAS_ACTIVE=0

source "$REPO_DIR/scripts/lib/common.sh"
source "$REPO_DIR/scripts/lib/install-common.sh"

usage() {
  printf 'Usage: BACKUP_HOST=<host> %s [--dry-run] [--migrate-legacy]\n' "${0##*/}" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --migrate-legacy) REPLACE_EXISTING=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; fail "unknown argument: $1" ;;
  esac
  shift
done

[[ "$DRY_RUN" == 0 || "$DRY_RUN" == 1 ]] || fail "BACKUP_INSTALL_DRY_RUN must be exactly 0 or 1"
[[ "$REPLACE_EXISTING" == 0 || "$REPLACE_EXISTING" == 1 ]] || fail "BACKUP_REPLACE_EXISTING must be exactly 0 or 1"
readonly REPO_DIR HOST_ID SYSTEMD_DIR ENV_DIR ROOT_LAUNCHER_DIR DRY_RUN REPLACE_EXISTING

cleanup_installer() {
  [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
}

rollback_active_install() {
  [[ "$TRANSACTION_ACTIVE" == 1 ]] || return 0
  [[ "$ROLLBACK_RUNNING" == 0 ]] || return 0
  ROLLBACK_RUNNING=1
  if [[ "$HOST_TIMER_MUTATION_ATTEMPTED" == 1 ]]; then
    if ! run_privileged systemctl disable --now "$UNIT_NAME.timer" >/dev/null 2>&1; then
      printf 'ERROR: installer rollback could not stop the new host timer\n' >&2
      ROLLBACK_FAILED=1
    fi
  fi
  restore_unit_files || ROLLBACK_FAILED=1
  if ! run_privileged systemctl daemon-reload >/dev/null 2>&1; then
    printf 'ERROR: installer rollback could not reload systemd units\n' >&2
    ROLLBACK_FAILED=1
  fi
  if [[ "$HOST_TIMER_MUTATION_ATTEMPTED" == 1 ]]; then
    restore_timer_runtime_state "$UNIT_NAME.timer" "$HOST_TIMER_WAS_ENABLED" "$HOST_TIMER_WAS_ACTIVE" || ROLLBACK_FAILED=1
  fi
  if [[ "$LEGACY_TIMER_STATE_TRACKED" == 1 && "$LEGACY_TIMER_MUTATION_ATTEMPTED" == 1 ]]; then
    restore_timer_runtime_state encrypted-git-backup.timer "$LEGACY_TIMER_WAS_ENABLED" "$LEGACY_TIMER_WAS_ACTIVE" || ROLLBACK_FAILED=1
  fi
  TRANSACTION_ACTIVE=0
  ROLLBACK_RUNNING=0
  [[ "$ROLLBACK_FAILED" == 0 ]]
}

handle_installer_exit() {
  local status="$1"
  trap - EXIT
  trap '' INT TERM HUP
  if [[ "$TRANSACTION_ACTIVE" == 1 ]]; then rollback_active_install || true; fi
  cleanup_installer
  if [[ "$status" -eq 0 && "$ROLLBACK_FAILED" == 1 ]]; then status=1; fi
  exit "$status"
}

handle_installer_signal() {
  local status="$1"
  trap - EXIT
  trap '' INT TERM HUP
  rollback_active_install || true
  cleanup_installer
  exit "$status"
}

trap 'handle_installer_exit $?' EXIT
trap 'handle_installer_signal 130' INT
trap 'handle_installer_signal 143' TERM
trap 'handle_installer_signal 129' HUP

load_host_install_config
resolve_timer_install_config
validate_timer_install_config

validate_root_launcher_directory_component() {
  local path="$1" mode uid
  [[ ! -L "$path" ]] || fail "unsafe root launcher directory path: symlink component: $path"
  [[ -d "$path" ]] || fail "unsafe root launcher directory path: expected directory: $path"
  uid="$(stat -c %u -- "$path")" || fail "unsafe root launcher directory path: cannot inspect $path"
  mode="$(stat -c %f -- "$path")" || fail "unsafe root launcher directory path: cannot inspect $path"
  [[ "$uid" == 0 && $((0x$mode & 0022)) -eq 0 ]] || \
    fail "unsafe root launcher directory path: ownership or permissions: $path"
}

validate_root_launcher_directory_path() {
  local component current="" missing_ok=0
  local -a components=()
  IFS='/' read -r -a components <<<"${ROOT_LAUNCHER_DIR#/}"
  validate_root_launcher_directory_component /
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="$current/$component"
    if [[ -e "$current" || -L "$current" ]]; then
      validate_root_launcher_directory_component "$current"
    elif [[ "$current" == "$ROOT_LAUNCHER_DIR" ]]; then
      missing_ok=1
    else
      fail "unsafe root launcher directory path: missing parent directory: $current"
    fi
  done
  [[ "$missing_ok" == 0 || -n "${current:-}" ]] || fail "unsafe root launcher directory path: $ROOT_LAUNCHER_DIR"
}

if [[ "$BACKUP_RUN_USER" == root ]]; then
  bash "$REPO_DIR/scripts/root-launcher.sh" --verify-paths "$REPO_DIR" "$HOST_ID" || \
    fail 'root runtime requires a trusted repository, launcher, configuration, and token environment'
  run_privileged bash "$REPO_DIR/scripts/root-launcher.sh" --verify "$REPO_DIR" "$HOST_ID" "$ENV_DIR/$HOST_ID.env" || \
    fail 'root runtime requires a trusted repository, launcher, configuration, and token environment'
  validate_root_launcher_directory_path
fi

UNIT_NAME="encrypted-git-backup-$HOST_ID"
SERVICE_DEST="$SYSTEMD_DIR/$UNIT_NAME.service"
TIMER_DEST="$SYSTEMD_DIR/$UNIT_NAME.timer"
LAUNCHER_DEST="$ROOT_LAUNCHER_DIR/backup-launcher"
LEGACY_SERVICE="$SYSTEMD_DIR/encrypted-git-backup.service"
LEGACY_TIMER="$SYSTEMD_DIR/encrypted-git-backup.timer"

legacy_units_present() {
  [[ -e "$LEGACY_SERVICE" || -e "$LEGACY_TIMER" ]] && return 0
  [[ "$DRY_RUN" == 1 ]] && return 1
  systemctl is-enabled encrypted-git-backup.timer >/dev/null 2>&1 || \
    systemctl is-active encrypted-git-backup.timer >/dev/null 2>&1
}

if legacy_units_present && [[ "$REPLACE_EXISTING" != 1 ]]; then
  fail "legacy encrypted-git-backup units detected; set BACKUP_REPLACE_EXISTING=1 after review"
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/local-backup-push-kit-systemd.XXXXXX")"
SERVICE_TEMP="$TEMP_DIR/$UNIT_NAME.service"
TIMER_TEMP="$TEMP_DIR/$UNIT_NAME.timer"
LAUNCHER_TEMP="$TEMP_DIR/backup-launcher"
/bin/cp -- "$REPO_DIR/scripts/root-launcher.sh" "$LAUNCHER_TEMP"

escaped_repo="$(systemd_path_escape "$REPO_DIR")"
escaped_repo_argument="$(systemd_escape "$REPO_DIR")"
escaped_host="$(systemd_escape "$HOST_ID")"
escaped_env_file="$(systemd_path_escape "$ENV_DIR/$HOST_ID.env")"
escaped_env_argument="$(systemd_escape "$ENV_DIR/$HOST_ID.env")"
escaped_exec="$(systemd_escape "$REPO_DIR/scripts/backup.sh")"
escaped_launcher="$(systemd_escape "$LAUNCHER_DEST")"

cat >"$SERVICE_TEMP" <<EOF
[Unit]
Description=Create encrypted Git backup for $HOST_ID
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=$BACKUP_RUN_USER
Group=$BACKUP_RUN_GROUP
WorkingDirectory=$escaped_repo
$(if [[ "$BACKUP_RUN_USER" == root ]]; then
    printf 'ExecStart=%s "%s" "%s" "%s"' "$escaped_launcher" "$escaped_repo_argument" "$escaped_host" "$escaped_env_argument"
  else
    printf 'Environment="BACKUP_HOST=%s"\nEnvironment="BACKUP_PUSH=1"\nEnvironmentFile=-%s\nExecStart=/bin/bash "%s"' \
      "$escaped_host" "$escaped_env_file" "$escaped_exec"
  fi)
Nice=10
IOSchedulingClass=best-effort
EOF

cat >"$TIMER_TEMP" <<EOF
[Unit]
Description=Run encrypted Git backup for $HOST_ID

[Timer]
OnCalendar=$BACKUP_ON_CALENDAR
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF

if [[ "$DRY_RUN" == 1 ]]; then
  if [[ "$BACKUP_RUN_USER" == root ]]; then
    printf '%s\n' "--- $LAUNCHER_DEST ---"
    cat "$LAUNCHER_TEMP"
  fi
  printf '%s\n' "--- $SERVICE_DEST ---"
  cat "$SERVICE_TEMP"
  printf '%s\n' "--- $TIMER_DEST ---"
  cat "$TIMER_TEMP"
  exit 0
fi

need_cmd install
need_cmd systemctl
if [[ "$EUID" -ne 0 ]]; then need_cmd sudo; fi

SERVICE_EXISTED=0
TIMER_EXISTED=0
LAUNCHER_EXISTED=0
if [[ -e "$SERVICE_DEST" ]]; then
  cp -a -- "$SERVICE_DEST" "$TEMP_DIR/original.service"
  SERVICE_EXISTED=1
fi
if [[ -e "$TIMER_DEST" ]]; then
  cp -a -- "$TIMER_DEST" "$TEMP_DIR/original.timer"
  TIMER_EXISTED=1
fi
if [[ "$BACKUP_RUN_USER" == root && -e "$LAUNCHER_DEST" ]]; then
  cp -a -- "$LAUNCHER_DEST" "$TEMP_DIR/original.launcher"
  LAUNCHER_EXISTED=1
fi

restore_unit_files() {
  local failed=0
  if [[ "$SERVICE_EXISTED" == 1 ]]; then
    if ! run_privileged rm -f -- "$SERVICE_DEST" || ! run_privileged cp -a -- "$TEMP_DIR/original.service" "$SERVICE_DEST"; then
      printf 'ERROR: installer rollback could not restore %s\n' "$SERVICE_DEST" >&2
      failed=1
    fi
  else
    if ! run_privileged rm -f -- "$SERVICE_DEST"; then
      printf 'ERROR: installer rollback could not remove %s\n' "$SERVICE_DEST" >&2
      failed=1
    fi
  fi
  if [[ "$TIMER_EXISTED" == 1 ]]; then
    if ! run_privileged rm -f -- "$TIMER_DEST" || ! run_privileged cp -a -- "$TEMP_DIR/original.timer" "$TIMER_DEST"; then
      printf 'ERROR: installer rollback could not restore %s\n' "$TIMER_DEST" >&2
      failed=1
    fi
  else
    if ! run_privileged rm -f -- "$TIMER_DEST"; then
      printf 'ERROR: installer rollback could not remove %s\n' "$TIMER_DEST" >&2
      failed=1
    fi
  fi
  if [[ "$BACKUP_RUN_USER" == root ]]; then
    if [[ "$LAUNCHER_EXISTED" == 1 ]]; then
      if ! run_privileged rm -f -- "$LAUNCHER_DEST" || ! run_privileged cp -a -- "$TEMP_DIR/original.launcher" "$LAUNCHER_DEST"; then
        printf 'ERROR: installer rollback could not restore %s\n' "$LAUNCHER_DEST" >&2
        failed=1
      fi
    else
      if ! run_privileged rm -f -- "$LAUNCHER_DEST"; then
        printf 'ERROR: installer rollback could not remove %s\n' "$LAUNCHER_DEST" >&2
        failed=1
      fi
    fi
  fi
  [[ "$failed" == 0 ]]
}

timer_is_enabled() {
  run_privileged systemctl is-enabled "$1" >/dev/null 2>&1
}

timer_is_active() {
  run_privileged systemctl is-active "$1" >/dev/null 2>&1
}

capture_timer_runtime_states() {
  if timer_is_enabled "$UNIT_NAME.timer"; then HOST_TIMER_WAS_ENABLED=1; fi
  if timer_is_active "$UNIT_NAME.timer"; then HOST_TIMER_WAS_ACTIVE=1; fi
  if legacy_units_present; then
    LEGACY_TIMER_STATE_TRACKED=1
    if timer_is_enabled encrypted-git-backup.timer; then LEGACY_TIMER_WAS_ENABLED=1; fi
    if timer_is_active encrypted-git-backup.timer; then LEGACY_TIMER_WAS_ACTIVE=1; fi
  fi
}

restore_timer_runtime_state() {
  local timer="$1" enabled="$2" active="$3"
  local failed=0
  if [[ "$enabled" == 1 ]]; then
    run_privileged systemctl enable "$timer" >/dev/null 2>&1 || failed=1
  else
    run_privileged systemctl disable "$timer" >/dev/null 2>&1 || failed=1
  fi
  if [[ "$active" == 1 ]]; then
    run_privileged systemctl start "$timer" >/dev/null 2>&1 || failed=1
  else
    run_privileged systemctl stop "$timer" >/dev/null 2>&1 || failed=1
  fi
  if [[ "$failed" != 0 ]]; then
    printf 'ERROR: installer rollback could not restore runtime state for %s\n' "$timer" >&2
    return 1
  fi
}

install_unit_files() {
  run_privileged mkdir -p -- "$SYSTEMD_DIR" || return 1
  if [[ "$BACKUP_RUN_USER" == root ]]; then
    run_privileged install -d -o root -g root -m 0755 -- "$ROOT_LAUNCHER_DIR" || return 1
    validate_root_launcher_directory_path || return 1
    run_privileged install -m 0755 -- "$LAUNCHER_TEMP" "$LAUNCHER_DEST" || return 1
  fi
  run_privileged install -m 0644 -- "$SERVICE_TEMP" "$SERVICE_DEST" || return 1
  run_privileged install -m 0644 -- "$TIMER_TEMP" "$TIMER_DEST" || return 1
}

capture_timer_runtime_states
TRANSACTION_ACTIVE=1
if ! install_unit_files; then
  fail "cannot install per-host systemd unit files"
fi

if ! run_privileged systemctl daemon-reload; then
  fail "cannot activate per-host systemd timer"
fi
HOST_TIMER_MUTATION_ATTEMPTED=1
if ! run_privileged systemctl enable --now "$UNIT_NAME.timer"; then
  fail "cannot activate per-host systemd timer"
fi

if [[ "$REPLACE_EXISTING" == 1 ]] && legacy_units_present; then
  LEGACY_TIMER_MUTATION_ATTEMPTED=1
  if ! run_privileged systemctl disable --now encrypted-git-backup.timer; then
    fail "cannot disable legacy systemd timer"
  fi
fi

TRANSACTION_ACTIVE=0
printf 'Installed %s.timer; token environment: %s/%s.env\n' "$UNIT_NAME" "$ENV_DIR" "$HOST_ID"
