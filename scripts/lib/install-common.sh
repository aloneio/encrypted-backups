#!/usr/bin/env bash

validate_no_control_characters() {
  local label="$1" value="$2"
  [[ "$value" != *[[:cntrl:]]* ]] || fail "$label contains ASCII control characters"
}

validate_absolute_install_path() {
  local label="$1" value="$2"
  validate_no_control_characters "$label" "$value"
  [[ "$value" == /* && "$value" != / && "$value" != */../* && "$value" != */.. && "$value" != */./* && "$value" != */. ]] || \
    fail "$label must be a normalized absolute path"
}

validate_account_name() {
  local label="$1" value="$2"
  validate_no_control_characters "$label" "$value"
  [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ ]] || fail "$label contains unsafe characters: $value"
}

validate_systemd_calendar() {
  local value="$1"
  validate_no_control_characters BACKUP_ON_CALENDAR "$value"
  [[ -n "$value" && "$value" =~ ^[A-Za-z0-9*,:./_+~[:space:]-]+$ ]] || \
    fail "BACKUP_ON_CALENDAR contains unsafe characters"
}

load_host_install_config() {
  local config_file
  validate_host_identifier BACKUP_HOST "$HOST_ID"
  config_file="$REPO_DIR/hosts/$HOST_ID/backup.conf"
  [[ -f "$config_file" && ! -L "$config_file" ]] || fail "missing regular host config: $config_file"
  # shellcheck source=/dev/null
  source "$config_file"
  validate_host_identifier CONFIG_HOST_ID "${CONFIG_HOST_ID:-}"
  [[ "$CONFIG_HOST_ID" == "$HOST_ID" ]] || fail "host mismatch: BACKUP_HOST=$HOST_ID config=${CONFIG_HOST_ID:-unset}"
}

validate_timer_install_config() {
  validate_account_name BACKUP_RUN_USER "${BACKUP_RUN_USER:-}"
  validate_account_name BACKUP_RUN_GROUP "${BACKUP_RUN_GROUP:-}"
  validate_systemd_calendar "${BACKUP_ON_CALENDAR:-}"
  validate_absolute_install_path BACKUP_SYSTEMD_DIR "$SYSTEMD_DIR"
  validate_absolute_install_path BACKUP_ENV_DIR "$ENV_DIR"
  validate_absolute_install_path BACKUP_ROOT_LAUNCHER_DIR "$ROOT_LAUNCHER_DIR"
  if [[ "$BACKUP_RUN_USER" == root ]]; then
    [[ "$BACKUP_RUN_USER_EXPLICIT" == 1 ]] || fail "root runtime requires explicit BACKUP_RUN_USER=root"
    printf 'WARNING: installing backup timer with root runtime privileges\n' >&2
  fi
}

resolve_timer_install_config() {
  BACKUP_RUN_USER_EXPLICIT=0
  if [[ -n "${BACKUP_RUN_USER:-}" ]]; then
    BACKUP_RUN_USER_EXPLICIT=1
  else
    BACKUP_RUN_USER="${SUDO_USER:-$(id -un)}"
  fi
  if [[ -z "${BACKUP_RUN_GROUP:-}" ]]; then
    BACKUP_RUN_GROUP="$(id -gn "$BACKUP_RUN_USER" 2>/dev/null || id -gn)"
  fi
  BACKUP_ON_CALENDAR="${BACKUP_ON_CALENDAR:-daily}"
}

systemd_escape() {
  local value="$1" escaped="" character index
  validate_no_control_characters 'systemd value' "$value"
  for ((index = 0; index < ${#value}; index++)); do
    character="${value:index:1}"
    case "$character" in
      \\) escaped+='\\' ;;
      '"') escaped+='\"' ;;
      '$') escaped+='$$' ;;
      '%') escaped+='%%' ;;
      *) escaped+="$character" ;;
    esac
  done
  printf '%s' "$escaped"
}

systemd_path_escape() {
  local value="$1" escaped="" character index
  validate_no_control_characters 'systemd path' "$value"
  for ((index = 0; index < ${#value}; index++)); do
    character="${value:index:1}"
    case "$character" in
      \\) escaped+='\\' ;;
      '"') escaped+='\"' ;;
      '%') escaped+='%%' ;;
      *) escaped+="$character" ;;
    esac
  done
  printf '%s' "$escaped"
}

environment_file_quote() {
  local value="$1" escaped="" character index
  validate_no_control_characters token "$value"
  for ((index = 0; index < ${#value}; index++)); do
    character="${value:index:1}"
    case "$character" in
      \\) escaped+='\\' ;;
      '"') escaped+='\"' ;;
      *) escaped+="$character" ;;
    esac
  done
  printf '"%s"' "$escaped"
}

run_privileged() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}
