#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/retention.sh"
source "$SCRIPT_DIR/lib/prepare.sh"
source "$SCRIPT_DIR/lib/publication-schema.sh"
source "$SCRIPT_DIR/lib/git-remotes.sh"

main() {
  preflight_publication_commands
  HOST_ID="${BACKUP_HOST-$(hostname -s)}"
  CONFIG_FILE="${BACKUP_CONFIG:-${REPO_DIR}/hosts/${HOST_ID}/backup.conf}"
  [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || fail "missing or unsafe config: $CONFIG_FILE"
  source "$CONFIG_FILE"
  PUSH_BRANCH="${BACKUP_BRANCH-main}"
  RETENTION_COUNT="${BACKUP_RETENTION_COUNT-3}"
  LOCK_TIMEOUT="${BACKUP_LOCK_TIMEOUT-30}"
  validate_host_identifier BACKUP_HOST "$HOST_ID"
  validate_host_identifier CONFIG_HOST_ID "${CONFIG_HOST_ID:-}"
  [[ "$HOST_ID" == "$CONFIG_HOST_ID" ]] || fail "host mismatch"
  validate_branch_name "$PUSH_BRANCH"
  validate_retention_count "$RETENTION_COUNT"
  validate_lock_timeout "$LOCK_TIMEOUT"
  initialize_prepared_state
  validate_internal_storage_paths
  validate_remote_configuration
  acquire_backup_lock
  recover_pending_retention_transaction
  validate_internal_storage_paths
  [[ -f "$PREPARED_STATE_FILE" ]] || fail "no prepared backup state exists for $HOST_ID"
  publish_prepared_state_machine
}

main "$@"
