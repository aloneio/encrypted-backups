#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_ID="${BACKUP_HOST:-$(hostname -s)}"
ENV_DIR="${BACKUP_ENV_DIR:-/etc/encrypted-git-backup}"
TEMP_DIR=""
STAGED_DEST=""

source "$REPO_DIR/scripts/lib/common.sh"
source "$REPO_DIR/scripts/lib/git-remotes.sh"
source "$REPO_DIR/scripts/lib/install-common.sh"

cleanup_secrets() {
  if [[ -n "$STAGED_DEST" ]]; then
    run_privileged rm -f -- "$STAGED_DEST" >/dev/null 2>&1 || true
  fi
  [[ -z "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
}

handle_secrets_signal() {
  local status="$1"
  cleanup_secrets
  trap - EXIT INT TERM HUP
  exit "$status"
}

trap cleanup_secrets EXIT
trap 'handle_secrets_signal 130' INT
trap 'handle_secrets_signal 143' TERM
trap 'handle_secrets_signal 129' HUP

[[ $# -eq 0 ]] || fail "configure-secrets.sh does not accept arguments"
readonly REPO_DIR HOST_ID ENV_DIR
load_host_install_config
validate_absolute_install_path BACKUP_ENV_DIR "$ENV_DIR"
validate_remote_configuration

HTTP_REMOTES=()
for remote in "${PUSH_REMOTES[@]}"; do
  if [[ "${REMOTE_TRANSPORTS[$remote]}" == http ]]; then
    HTTP_REMOTES+=("$remote")
  fi
done

if [[ ${#HTTP_REMOTES[@]} -eq 0 ]]; then
  printf 'No HTTP(S) remotes configured for host %s; no token file written.\n' "$HOST_ID"
  exit 0
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/local-backup-push-kit-secrets.XXXXXX")"
TOKEN_FILE="$TEMP_DIR/$HOST_ID.env"
umask 077
: >"$TOKEN_FILE"

for remote in "${HTTP_REMOTES[@]}"; do
  printf 'Token for HTTP remote %s: ' "$remote" >&2
  token=""
  if ! IFS= read -r -s token; then
    printf '\n' >&2
    fail "token entry ended before remote '$remote' was configured"
  fi
  printf '\n' >&2
  [[ -n "$token" ]] || fail "token for HTTP remote '$remote' must not be empty"
  validate_no_control_characters "token for HTTP remote '$remote'" "$token"
  token_key="$(remote_env_key "$remote")"
  printf 'BACKUP_TOKEN_%s=%s\n' "$token_key" "$(environment_file_quote "$token")" >>"$TOKEN_FILE"
  unset token
done

need_cmd install
need_cmd mv
if [[ "$EUID" -ne 0 ]]; then need_cmd sudo; fi

DESTINATION="$ENV_DIR/$HOST_ID.env"
STAGED_DEST="$ENV_DIR/.$HOST_ID.env.tmp.$$"
run_privileged install -d -m 0750 -- "$ENV_DIR"
run_privileged install -m 0600 -- "$TOKEN_FILE" "$STAGED_DEST"
run_privileged mv -f -- "$STAGED_DEST" "$DESTINATION"
STAGED_DEST=""
run_privileged chmod 0600 -- "$DESTINATION"

printf 'Configured %s HTTP(S) remote token(s) for host %s in %s.\n' "${#HTTP_REMOTES[@]}" "$HOST_ID" "$DESTINATION"
