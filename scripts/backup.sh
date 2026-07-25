#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/retention.sh"
source "$SCRIPT_DIR/lib/prepare.sh"
source "$SCRIPT_DIR/lib/publication-schema.sh"
source "$SCRIPT_DIR/lib/git-remotes.sh"

reject_plaintext_in_repo() {
  local bad=0
  while IFS= read -r -d '' f; do
    rel="${f#${REPO_DIR}/}"
    case "$rel" in
      .git/*|*.tar.zst.age|*.sha256|*.json|*.md|*.sh|*.conf|*.txt|.gitignore|*.yml|*.yaml) ;;
      *) printf 'Unexpected file in repo: %s\n' "$rel" >&2; bad=1 ;;
    esac
    case "$rel" in
      *.tar|*.tar.zst|*.zip|*.sql|*.dump|*.bak|*.key|*.pem|*.env|*.sqlite|*.db|age-identity*|id_*|*_rsa|*_ed25519)
        printf 'Forbidden plaintext/secret-like file in repo: %s\n' "$rel" >&2; bad=1 ;;
    esac
  done < <(find "$REPO_DIR" -path "$REPO_DIR/.git" -prune -o -type f -print0)
  [[ "$bad" -eq 0 ]] || fail "repo contains forbidden files"
}

main() {
  preflight_commands
  HOST_ID="${BACKUP_HOST-$(hostname -s)}"
  CONFIG_FILE="${BACKUP_CONFIG:-${REPO_DIR}/hosts/${HOST_ID}/backup.conf}"
  [[ -f "$CONFIG_FILE" ]] || fail "missing config: $CONFIG_FILE"
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  PUSH="${BACKUP_PUSH:-0}"
  if [[ -n "${BACKUP_PUSH+x}" && -z "$BACKUP_PUSH" ]]; then
    PUSH=""
  fi
  RETENTION_COUNT="${BACKUP_RETENTION_COUNT-3}"
  LOCK_TIMEOUT="${BACKUP_LOCK_TIMEOUT-30}"
  PUSH_BRANCH="${BACKUP_BRANCH-main}"

  validate_config
  validate_remote_configuration
  canonicalize_backup_paths
  BACKUP_PATHS=("${CANONICAL_BACKUP_PATHS[@]}")
  initialize_prepared_state
  validate_internal_storage_paths
  acquire_backup_lock
  recover_pending_retention_transaction
  validate_internal_storage_paths

  if [[ -e "$PREPARED_STATE_FILE" ]]; then
    [[ "$PUSH" == "1" ]] || fail "prepared backup already exists for $HOST_ID; publish it with BACKUP_HOST=$HOST_ID scripts/publish-prepared.sh"
    publish_prepared_state_machine
    return 0
  fi

  require_clean_repository
  synchronize_canonical_before_prepare
  require_clean_repository
  reject_plaintext_in_repo
  prepare_backup

  if [[ "$PUSH" == "1" ]]; then
    publish_prepared_state_machine
  fi
}

main "$@"
