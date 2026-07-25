#!/usr/bin/env bash

remote_env_key() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_'
}

validate_remote_url() {
  local LC_ALL=C url="$1"
  [[ -n "$url" ]] || fail "remote URL must not be empty"
  [[ "$url" != *[[:cntrl:]]* ]] || fail "remote URL contains ASCII control characters"
}

classify_remote_url() {
  local url="$1" authority
  validate_remote_url "$url"
  case "$url" in
    http://*|https://*)
      authority="${url#*://}"
      authority="${authority%%/*}"
      [[ "$authority" != *@* ]] || fail "HTTP remote URL must not contain embedded userinfo"
      printf '%s\n' http
      ;;
    ssh://*|file://*|/*|./*|../*) printf '%s\n' native ;;
    *://*) fail "unsupported remote transport" ;;
    *:*)
      [[ "$url" =~ ^[^/:[:space:]]+@?[^/:[:space:]]+:.+$ ]] || fail "unsupported ambiguous remote transport"
      printf '%s\n' native
      ;;
    *)
      printf '%s\n' native
      ;;
  esac
}

http_provider_for_url() {
  local url="$1" authority hostname
  authority="${url#*://}"
  authority="${authority%%/*}"
  if [[ "$authority" == \[* ]]; then
    printf '%s\n' generic
    return 0
  fi
  hostname="${authority%%:*}"
  hostname="${hostname,,}"
  case "$hostname" in
    github.com) printf '%s\n' github ;;
    gitlab.com) printf '%s\n' gitlab ;;
    *) printf '%s\n' generic ;;
  esac
}

validate_remote_configuration() {
  local remote fetch_url push_url transport token_key
  local -A seen=() seen_token_keys=()
  local -a fetch_urls=() push_urls=()
  [[ "$(declare -p BACKUP_REMOTES 2>/dev/null)" == declare\ -a\ * ]] || fail "BACKUP_REMOTES must be a nonempty indexed array"
  [[ ${#BACKUP_REMOTES[@]} -gt 0 ]] || fail "BACKUP_REMOTES must be a nonempty indexed array"
  PUSH_REMOTES=("${BACKUP_REMOTES[@]}")
  declare -gA REMOTE_FETCH_URLS=()
  declare -gA REMOTE_PUSH_URLS=()
  declare -gA REMOTE_TRANSPORTS=()
  for remote in "${PUSH_REMOTES[@]}"; do
    validate_safe_identifier BACKUP_REMOTE "$remote"
    [[ -z "${seen[$remote]:-}" ]] || fail "BACKUP_REMOTES contains duplicate remote: $remote"
    seen["$remote"]=1
    token_key="$(remote_env_key "$remote")"
    [[ -z "${seen_token_keys[$token_key]:-}" ]] || fail "BACKUP_REMOTES token key collision"
    seen_token_keys["$token_key"]="$remote"
    mapfile -t fetch_urls < <(GIT_MASTER=1 git -C "$REPO_DIR" remote get-url --all "$remote" 2>/dev/null)
    mapfile -t push_urls < <(GIT_MASTER=1 git -C "$REPO_DIR" remote get-url --push --all "$remote" 2>/dev/null)
    [[ ${#fetch_urls[@]} -eq 1 && ${#push_urls[@]} -eq 1 ]] || fail "remote '$remote' must exist with exactly one fetch URL and one push URL"
    fetch_url="${fetch_urls[0]}"
    push_url="${push_urls[0]}"
    transport="$(classify_remote_url "$fetch_url")"
    [[ "$(classify_remote_url "$push_url")" == "$transport" ]] || fail "remote '$remote' fetch/push transports must match"
    REMOTE_FETCH_URLS["$remote"]="$fetch_url"
    REMOTE_PUSH_URLS["$remote"]="$push_url"
    REMOTE_TRANSPORTS["$remote"]="$transport"
  done
  CANONICAL_REMOTE="${PUSH_REMOTES[0]}"
}

http_token_for_remote() {
  local remote="$1" url="$2" key variable token provider
  key="$(remote_env_key "$remote")"
  variable="BACKUP_TOKEN_${key}"
  token="${!variable:-}"
  provider="$(http_provider_for_url "$url")"
  if [[ -z "$token" ]]; then
    case "$provider" in
      github) token="${GITHUB_TOKEN:-}" ;;
      gitlab) token="${GITLAB_TOKEN:-}" ;;
      *) token="${BACKUP_GIT_TOKEN:-}" ;;
    esac
  fi
  [[ -n "$token" ]] || fail "missing token for HTTP remote '$remote'"
  HTTP_REMOTE_TOKEN="$token"
  HTTP_REMOTE_USER="${BACKUP_GIT_USER:-}"
  if [[ -z "$HTTP_REMOTE_USER" ]]; then
    case "$provider" in
      gitlab) HTTP_REMOTE_USER=oauth2 ;;
      *) HTTP_REMOTE_USER=x-access-token ;;
    esac
  fi
}

git_for_remote() {
  local remote="$1" operation url
  shift
  operation="${1:-}"
  if [[ "${REMOTE_TRANSPORTS[$remote]}" == http ]]; then
    if [[ "$operation" == push ]]; then
      url="${REMOTE_PUSH_URLS[$remote]}"
    else
      url="${REMOTE_FETCH_URLS[$remote]}"
    fi
    http_token_for_remote "$remote" "$url"
    GIT_TERMINAL_PROMPT=0 \
      GIT_ASKPASS="$REPO_DIR/scripts/git-askpass.sh" \
      GIT_ASKPASS_USERNAME="$HTTP_REMOTE_USER" \
      GIT_ASKPASS_TOKEN="$HTTP_REMOTE_TOKEN" \
      GIT_MASTER=1 git -C "$REPO_DIR" "$@"
  else
    GIT_TERMINAL_PROMPT=0 GIT_MASTER=1 \
      env -u GIT_ASKPASS -u GIT_ASKPASS_USERNAME -u GIT_ASKPASS_TOKEN \
      git -C "$REPO_DIR" "$@"
  fi
}

git_without_credentials() {
  env -i \
    PATH="$PATH" \
    GIT_ALLOW_PROTOCOL=file:http:https:ssh \
    GIT_CONFIG=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_TERMINAL_PROMPT=0 \
    GIT_SSH_COMMAND='ssh -F /dev/null -oBatchMode=yes -oPasswordAuthentication=no -oKbdInteractiveAuthentication=no -oPubkeyAuthentication=no -oHostbasedAuthentication=no -oIdentityAgent=none -oIdentityFile=none -oPreferredAuthentications=none' \
    git -C "$REPO_DIR" \
      -c credential.helper= -c http.extraHeader= -c http.proxy= \
      "$@"
}

query_remote_branch() {
  local remote="$1" branch="$2" without_credentials="${3:-0}" output status oid ref
  if [[ "$without_credentials" == "1" ]]; then
    if output="$(git_without_credentials ls-remote --upload-pack=/usr/bin/git-upload-pack --exit-code "${REMOTE_FETCH_URLS[$remote]}" "refs/heads/$branch" 2>/dev/null)"; then
      status=0
    else
      status=$?
    fi
  else
    if output="$(git_for_remote "$remote" ls-remote --exit-code "$remote" "refs/heads/$branch" 2>/dev/null)"; then
      status=0
    else
      status=$?
    fi
  fi
  if [[ "$status" -eq 2 ]]; then
    REMOTE_BRANCH_EXISTS=0
    REMOTE_BRANCH_OID=""
    return 0
  fi
  [[ "$status" -eq 0 ]] || fail "cannot query branch '$branch' on remote '$remote'"
  read -r oid ref <<<"$output"
  [[ "$ref" == "refs/heads/$branch" && "$oid" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ && "$output" != *$'\n'* ]] || fail "remote '$remote' returned an invalid branch OID"
  REMOTE_BRANCH_EXISTS=1
  REMOTE_BRANCH_OID="$oid"
}

fetch_remote_branch() {
  local remote="$1" branch="$2" without_credentials="${3:-0}" destination
  destination="refs/local-backup-push-kit/$remote/$branch"
  if [[ "$without_credentials" == "1" ]]; then
    git_without_credentials fetch --upload-pack=/usr/bin/git-upload-pack --no-tags "${REMOTE_FETCH_URLS[$remote]}" "+refs/heads/$branch:$destination" >/dev/null 2>&1 || fail "cannot fetch branch '$branch' from remote '$remote'"
  else
    git_for_remote "$remote" fetch --no-tags "$remote" "+refs/heads/$branch:$destination" >/dev/null 2>&1 || fail "cannot fetch branch '$branch' from remote '$remote'"
  fi
  FETCHED_REMOTE_OID="$(publication_git rev-parse "$destination")"
}

require_local_publication_branch() {
  local branch head
  head="$(publication_git rev-parse --verify HEAD 2>/dev/null)" || fail "local repository has no template commit; create one on BACKUP_BRANCH first"
  branch="$(publication_git symbolic-ref --quiet --short HEAD 2>/dev/null)" || fail "detached HEAD is not allowed for backup publication"
  [[ "$branch" == "$PUSH_BRANCH" ]] || fail "checked-out branch '$branch' does not match BACKUP_BRANCH '$PUSH_BRANCH'"
  LOCAL_HEAD_OID="$head"
}

synchronize_canonical_before_prepare() {
  local canonical_oid
  require_local_publication_branch
  require_clean_repository
  CANONICAL_BRANCH_EXISTS=""
  query_remote_branch "$CANONICAL_REMOTE" "$PUSH_BRANCH"
  if [[ "$REMOTE_BRANCH_EXISTS" == "0" ]]; then
    CANONICAL_BASE_OID=""
    CANONICAL_BRANCH_EXISTS=0
    return 0
  fi
  CANONICAL_BRANCH_EXISTS=1
  fetch_remote_branch "$CANONICAL_REMOTE" "$PUSH_BRANCH"
  canonical_oid="$FETCHED_REMOTE_OID"
  if [[ "$LOCAL_HEAD_OID" == "$canonical_oid" ]]; then
    CANONICAL_BASE_OID="$canonical_oid"
    return 0
  fi
  if publication_git merge-base --is-ancestor "$LOCAL_HEAD_OID" "$canonical_oid"; then
    validate_publication_commit_range "$LOCAL_HEAD_OID" "$canonical_oid" || fail "canonical commit is not publication-shaped; local branch was not moved"
    publication_git merge --ff-only "$canonical_oid" >/dev/null || fail "cannot fast-forward local BACKUP_BRANCH to canonical"
  elif publication_git merge-base --is-ancestor "$canonical_oid" "$LOCAL_HEAD_OID"; then
    fail "local BACKUP_BRANCH is ahead of canonical; publish or reconcile it before backup"
  else
    fail "local BACKUP_BRANCH diverges from canonical; reconcile it before backup"
  fi
  LOCAL_HEAD_OID="$(publication_git rev-parse HEAD)"
  [[ "$LOCAL_HEAD_OID" == "$canonical_oid" ]] || fail "local HEAD does not equal fetched canonical OID"
  CANONICAL_BASE_OID="$canonical_oid"
}

preflight_canonical_before_commit() {
  local base_oid="$1" expected_exists="$2" oid
  [[ "$expected_exists" == 0 || "$expected_exists" == 1 || "$expected_exists" == legacy ]] || fail "invalid prepared canonical branch state"
  query_remote_branch "$CANONICAL_REMOTE" "$PUSH_BRANCH"
  oid="$REMOTE_BRANCH_OID"
  case "$expected_exists" in
    0)
      [[ "$REMOTE_BRANCH_EXISTS" == 0 ]] || fail "canonical moved after preparation; reprepare required"
      return 0
      ;;
    1)
      [[ "$REMOTE_BRANCH_EXISTS" == 1 && "$oid" == "$base_oid" ]] || fail "canonical moved after preparation; reprepare required"
      ;;
    legacy)
      [[ "$REMOTE_BRANCH_EXISTS" == 1 && "$oid" == "$base_oid" ]] || fail "legacy prepared state cannot prove canonical continuity; reprepare required"
      ;;
  esac
  fetch_remote_branch "$CANONICAL_REMOTE" "$PUSH_BRANCH"
  [[ "$FETCHED_REMOTE_OID" == "$oid" ]] || fail "remote '$CANONICAL_REMOTE' moved during preflight"
}

preflight_remote_after_commit() {
  local remote="$1" base_oid="$2" committed_oid="$3" oid
  query_remote_branch "$remote" "$PUSH_BRANCH"
  oid="$REMOTE_BRANCH_OID"
  [[ -z "$oid" || "$oid" == "$base_oid" || "$oid" == "$committed_oid" ]] || fail "remote divergence: remote=$remote remote_oid=$oid"
  if [[ "$REMOTE_BRANCH_EXISTS" == "1" ]]; then
    fetch_remote_branch "$remote" "$PUSH_BRANCH"
    [[ "$FETCHED_REMOTE_OID" == "$oid" ]] || fail "remote '$remote' moved during preflight"
  fi
  CURRENT_REMOTE_OID="$oid"
}

push_commit_to_remote() {
  local remote="$1" oid="$2"
  git_for_remote "$remote" push "$remote" "$oid:refs/heads/$PUSH_BRANCH"
}

publish_prepared_state_machine() {
  local remote oid all_published
  activate_publication_traps
  require_local_publication_branch
  load_publication_state

  if [[ -z "$PREPARED_COMMITTED_OID" ]]; then
    preflight_canonical_before_commit "$PREPARED_BASE_OID" "$PREPARED_CANONICAL_BRANCH_EXISTS"
    require_exact_prepared_index
    require_no_unrelated_worktree_changes
    require_safe_prepared_files
    begin_retention_transaction
    require_exact_prepared_index
    require_no_unrelated_worktree_changes
    validate_staged_files
    if ! GIT_AUTHOR_NAME="${BACKUP_GIT_AUTHOR_NAME:-backup-bot}" \
      GIT_AUTHOR_EMAIL="${BACKUP_GIT_AUTHOR_EMAIL:-backup-bot@example.invalid}" \
      GIT_COMMITTER_NAME="${BACKUP_GIT_COMMITTER_NAME:-backup-bot}" \
      GIT_COMMITTER_EMAIL="${BACKUP_GIT_COMMITTER_EMAIL:-backup-bot@example.invalid}" \
      GIT_MASTER=1 git -C "$REPO_DIR" commit -m "$PREPARED_COMMIT_MESSAGE" -- "${PREPARED_COMMIT_PATHS[@]}"; then
      settle_retention_transaction "$PREPARED_BASE_OID"
      fail "cannot create prepared publication commit"
    fi
    finish_retention_transaction
    PREPARED_COMMITTED_OID="$(GIT_MASTER=1 git -C "$REPO_DIR" rev-parse HEAD)"
    validate_committed_publication "$PREPARED_COMMITTED_OID"
    write_publication_state_update commit "$PREPARED_COMMITTED_OID"
  fi

  for remote in "${PUSH_REMOTES[@]}"; do
    preflight_remote_after_commit "$remote" "$PREPARED_BASE_OID" "$PREPARED_COMMITTED_OID"
    oid="$CURRENT_REMOTE_OID"
    if [[ "$oid" == "$PREPARED_COMMITTED_OID" ]]; then
      if [[ "${PREPARED_REMOTE_STATUS[$remote]}" != published ]]; then
        write_publication_state_update remote "$remote" published "$PREPARED_COMMITTED_OID" ""
        PREPARED_REMOTE_STATUS["$remote"]=published
      fi
      continue
    fi
    [[ "${PREPARED_REMOTE_STATUS[$remote]}" != published ]] || fail "published remote '$remote' no longer points to committed OID"
    if ! push_commit_to_remote "$remote" "$PREPARED_COMMITTED_OID" >/dev/null 2>&1; then
      write_publication_state_update remote "$remote" failed "" "push failed"
      fail "push failed for remote '$remote'"
    fi
    query_remote_branch "$remote" "$PUSH_BRANCH"
    [[ "$REMOTE_BRANCH_OID" == "$PREPARED_COMMITTED_OID" ]] || {
      write_publication_state_update remote "$remote" failed "" "push verification failed"
      fail "push verification failed for remote '$remote'"
    }
    write_publication_state_update remote "$remote" published "$PREPARED_COMMITTED_OID" ""
    PREPARED_REMOTE_STATUS["$remote"]=published
  done

  all_published=1
  load_publication_state
  for remote in "${PUSH_REMOTES[@]}"; do
    [[ "${PREPARED_REMOTE_STATUS[$remote]}" == published && "${PREPARED_REMOTE_OID[$remote]}" == "$PREPARED_COMMITTED_OID" ]] || all_published=0
  done
  [[ "$all_published" == "1" ]] || fail "publication remains incomplete"
  clear_prepared_state
  finish_publication
}
