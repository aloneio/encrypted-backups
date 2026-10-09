#!/usr/bin/env bash

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

safe_relpath() {
  case "$1" in
    backups/${HOST_ID}/*|manifests/${HOST_ID}/*|scripts/*|hosts/*/backup.conf|docs/*|.github/workflows/*|.gitlab-ci.yml|README.md|.gitignore) return 0 ;;
    *) return 1 ;;
  esac
}

validate_staged_files() {
  local bad=0 path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    path="${path#\"}"
    path="${path%\"}"
    if ! safe_relpath "$path"; then
      printf 'Refusing to stage unsafe path: %s\n' "$path" >&2
      bad=1
      continue
    fi
    case "$path" in
      *.tar|*.tar.zst|*.zip|*.sql|*.dump|*.bak|*.key|*.pem|*.env|*.sqlite|*.db|age-identity*|id_*|*_rsa|*_ed25519)
        printf 'Refusing to stage plaintext/secret-like path: %s\n' "$path" >&2
        bad=1 ;;
    esac
  done < <(GIT_MASTER=1 git -C "$REPO_DIR" diff --cached --name-only)
  [[ "$bad" -eq 0 ]] || fail "unsafe staged files detected"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

preflight_commands() {
  local command_name
  for command_name in age chmod cut date find flock git hostname install mkdir mktemp mv python3 realpath rm rmdir seq sha256sum sleep stat tar tr zstd; do
    need_cmd "$command_name"
  done
}

preflight_publication_commands() {
  local command_name
  for command_name in chmod cp cut env flock git hostname mkdir mktemp mv python3 realpath rm sha256sum stat tr; do
    need_cmd "$command_name"
  done
}

validate_safe_identifier() {
  local label="$1" value="$2"
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "$label contains unsafe characters: $value"
}

validate_host_identifier() {
  local label="$1" value="$2"
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] || fail "$label contains unsafe characters: $value"
}

validate_branch_name() {
  local branch="$1"
  [[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail "BACKUP_BRANCH contains unsafe characters: $branch"
  [[ "$branch" != *..* && "$branch" != *//* && "$branch" != */ && "$branch" != *. && "$branch" != .* && "$branch" != */.* && "$branch" != *'@{'* && "$branch" != *.lock ]] || fail "BACKUP_BRANCH is invalid: $branch"
  GIT_MASTER=1 git check-ref-format --branch "$branch" >/dev/null 2>&1 || fail "BACKUP_BRANCH is not a valid Git branch"
}

bash_signed_integer_max() {
  local current=1 next
  while :; do
    next=$((current * 2 + 1))
    (( next > current )) || break
    current="$next"
  done
  printf '%s\n' "$current"
}

decimal_is_at_most() {
  local value="$1" maximum="$2"
  local LC_ALL=C
  if (( ${#value} < ${#maximum} )); then
    return 0
  fi
  (( ${#value} == ${#maximum} )) || return 1
  [[ "$value" == "$maximum" || "$value" < "$maximum" ]]
}

validate_retention_count() {
  local value="$1" maximum
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "BACKUP_RETENTION_COUNT must be a canonical positive decimal integer"
  maximum="$(bash_signed_integer_max)"
  decimal_is_at_most "$value" "$maximum" || fail "BACKUP_RETENTION_COUNT exceeds Bash signed integer maximum $maximum"
}

validate_lock_timeout() {
  local value="$1"
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || fail "BACKUP_LOCK_TIMEOUT must be a canonical integer from 0 to 3600"
  [[ ${#value} -le 4 ]] || fail "BACKUP_LOCK_TIMEOUT must be an integer from 0 to 3600"
  (( 10#$value <= 3600 )) || fail "BACKUP_LOCK_TIMEOUT must be an integer from 0 to 3600"
}

validate_age_recipient() {
  local recipient="$1"
  [[ "$recipient" == age1?* ]] || fail "AGE_RECIPIENT must be a valid age X25519 public recipient"
  if ! (
    local validation_dir
    validation_dir="$(mktemp -d /tmp/local-backup-push-kit-age-validate.XXXXXX)" || exit 1
    trap 'rm -rf -- "$validation_dir"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    : >"$validation_dir/empty"
    age -r "$recipient" -o "$validation_dir/output.age" "$validation_dir/empty" >/dev/null 2>&1
  ); then
    fail "AGE_RECIPIENT must be a valid age X25519 public recipient"
  fi
}

validate_config() {
  [[ "$PUSH" == "0" || "$PUSH" == "1" ]] || fail "BACKUP_PUSH must be exactly 0 or 1"
  validate_retention_count "$RETENTION_COUNT"
  validate_lock_timeout "$LOCK_TIMEOUT"
  validate_host_identifier BACKUP_HOST "$HOST_ID"
  validate_host_identifier CONFIG_HOST_ID "${CONFIG_HOST_ID:-}"
  [[ "$HOST_ID" == "$CONFIG_HOST_ID" ]] || fail "host mismatch: BACKUP_HOST=$HOST_ID config=${CONFIG_HOST_ID:-unset}"
  validate_branch_name "$PUSH_BRANCH"
  validate_age_recipient "${AGE_RECIPIENT:-}"
  [[ "$(declare -p BACKUP_PATHS 2>/dev/null)" == declare\ -a\ * ]] || fail "BACKUP_PATHS must be an indexed array"
  [[ ${#BACKUP_PATHS[@]} -gt 0 ]] || fail "BACKUP_PATHS must not be empty"
}

path_has_symlink_component() {
  local path="$1" component current=""
  local -a components=()
  IFS='/' read -r -a components <<<"${path#/}"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="${current}/$component"
    [[ -L "$current" ]] && return 0
  done
  return 1
}

canonicalize_backup_paths() {
  local repo_canonical path canonical
  local -A seen=()
  CANONICAL_BACKUP_PATHS=()
  repo_canonical="$(realpath -e -- "$REPO_DIR")" || fail "cannot resolve backup repository: $REPO_DIR"
  for path in "${BACKUP_PATHS[@]}"; do
    [[ "$path" == /* ]] || fail "backup path must be absolute: $path"
    path_has_symlink_component "$path" && fail "backup path must not contain symlinks: $path"
    canonical="$(realpath -e -- "$path")" || fail "backup path does not exist: $path"
    [[ -z "${seen[$canonical]:-}" ]] || fail "duplicate backup path: $path resolves to $canonical"
    seen[$canonical]=1
    if [[ "$canonical" == "$repo_canonical" || "$canonical" == "$repo_canonical"/* ]]; then
      fail "backup path points inside backup repo: $path"
    fi
    if [[ "$canonical" == / || "$repo_canonical" == "$canonical"/* ]]; then
      fail "backup path is an ancestor of backup repo: $path"
    fi
    CANONICAL_BACKUP_PATHS+=("$canonical")
  done
}

acquire_backup_lock() {
  local state_dir="$REPO_DIR/.git/local-backup-push-kit"
  [[ -d "$REPO_DIR/.git" ]] || fail "backup repository is not initialized: $REPO_DIR/.git is missing"
  mkdir -p "$state_dir"
  exec {BACKUP_LOCK_FD}>"$state_dir/lock"
  flock -w "$LOCK_TIMEOUT" "$BACKUP_LOCK_FD" || fail "backup lock unavailable after ${LOCK_TIMEOUT}s: $state_dir/lock"
}

require_clean_repository() {
  local status
  status="$(GIT_MASTER=1 git -C "$REPO_DIR" status --porcelain=v1 --untracked-files=all)" || fail "cannot inspect backup repository status"
  [[ -z "$status" ]] || fail "backup repository must be clean before preparation"
}

generate_artifact_id() {
  local prefix candidate nanos
  candidate="$(date -u +%Y-%m-%dT%H-%M-%SZ-%N)"
  [[ "$candidate" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z-[0-9]{9}$ ]] || fail "date did not provide a nanosecond artifact ID"
  prefix="${candidate%-*}"
  nanos="${candidate##*-}"
  while [[ -e "$REPO_DIR/backups/$HOST_ID/${candidate}.tar.zst.age" || -e "$REPO_DIR/backups/$HOST_ID/${candidate}.sha256" || -e "$REPO_DIR/manifests/$HOST_ID/${candidate}.json" ]]; do
    (( 10#$nanos < 999999999 )) || fail "artifact ID space exhausted for $prefix"
    printf -v nanos '%09d' "$((10#$nanos + 1))"
    candidate="${prefix}-${nanos}"
  done
  printf '%s\n' "$candidate"
}
