#!/usr/bin/env bash

todo4_write_config() {
  local repo="$1" data="$2" branch="$3"
  shift 3
  mkdir -p "$repo/hosts/testbox"
  {
    printf '%s\n' 'CONFIG_HOST_ID="testbox"' "AGE_RECIPIENT=\"$TEST_AGE_RECIPIENT\"" "BACKUP_BRANCH=\"$branch\""
    printf '%s' 'BACKUP_REMOTES=('; printf ' %q' "$@"; printf ' )\n'
    printf 'BACKUP_PATHS=(%q)\n' "$data"
  } >"$repo/hosts/testbox/backup.conf"
}

todo4_setup() {
  local name="$1" branch="${2:-main}" seed="${3:-1}" remotes="${4:-2}"
  new_fixture "todo4-$name" || return 2
  TODO4_FIXTURE="$FIXTURE"
  TODO4_REPO="$TODO4_FIXTURE/repo"
  TODO4_DATA="$TODO4_FIXTURE/data"
  TODO4_CANONICAL="$TODO4_FIXTURE/canonical.git"
  TODO4_MIRROR="$TODO4_FIXTURE/mirror.git"
  copy_template "$TODO4_REPO"
  install_common_shims "$TODO4_FIXTURE"
  rm -f "$TODO4_FIXTURE/bin/git"
  mkdir -p "$TODO4_DATA"
  printf 'payload\n' >"$TODO4_DATA/payload.txt"
  todo4_write_config "$TODO4_REPO" "$TODO4_DATA" "$branch" canonical $([[ "$remotes" == "2" ]] && printf mirror)
  init_real_repo "$TODO4_REPO" || return 2
  if [[ "$branch" != "main" ]]; then
    /usr/bin/git -C "$TODO4_REPO" branch -m "$branch"
  fi
  /usr/bin/git init -q --bare "$TODO4_CANONICAL"
  /usr/bin/git -C "$TODO4_REPO" remote add canonical "$TODO4_CANONICAL"
  if [[ "$remotes" == "2" ]]; then
    /usr/bin/git init -q --bare "$TODO4_MIRROR"
    /usr/bin/git -C "$TODO4_REPO" remote add mirror "$TODO4_MIRROR"
  fi
  if [[ "$seed" == "1" ]]; then
    /usr/bin/git -C "$TODO4_REPO" push -q canonical "HEAD:refs/heads/$branch"
    if [[ "$remotes" == "2" ]]; then /usr/bin/git -C "$TODO4_REPO" push -q mirror "HEAD:refs/heads/$branch"; fi
  fi
  TODO4_STATE="$TODO4_REPO/.git/local-backup-push-kit/prepared/testbox.state"
}

todo4_run_script() {
  local output="$1"
  shift
  local -a environment
  mapfile -t environment < <(fixture_env "$TODO4_FIXTURE")
  run_captured "$output" 12 env "${environment[@]}" BACKUP_HOST=testbox "$@"
}

todo4_prepare() {
  todo4_run_script "$TODO4_FIXTURE/prepare.log" BACKUP_PUSH=0 bash "$TODO4_REPO/scripts/backup.sh"
}

todo4_publish() {
  todo4_run_script "$TODO4_FIXTURE/publish.log" bash "$TODO4_REPO/scripts/publish-prepared.sh"
}

todo4_remote_oid() {
  /usr/bin/git --git-dir="$1" rev-parse "refs/heads/$2" 2>/dev/null
}

todo4_advance_remote() {
  local bare="$1" branch="$2" name="$3" clone
  clone="$TODO4_FIXTURE/$name"
  /usr/bin/git clone -q "$bare" "$clone"
  /usr/bin/git -C "$clone" config user.name fixture
  /usr/bin/git -C "$clone" config user.email fixture@example.invalid
  /usr/bin/git -C "$clone" checkout -q "$branch"
  printf '%s\n' "$name" >>"$clone/README.md"
  /usr/bin/git -C "$clone" add -- README.md
  /usr/bin/git -C "$clone" commit -qm "$name"
  /usr/bin/git -C "$clone" push -q origin "HEAD:refs/heads/$branch"
}

todo4_install_git_wrapper() {
  cat >"$TODO4_FIXTURE/bin/git" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'ASKPASS=%q TOKEN=%q USER=%q ARGS=' "${GIT_ASKPASS-}" "${GIT_ASKPASS_TOKEN-}" "${GIT_ASKPASS_USERNAME-}" >>"${TODO4_GIT_LOG:?}"
printf '%q ' "$@" >>"$TODO4_GIT_LOG"; printf '\n' >>"$TODO4_GIT_LOG"
if [[ "${TODO4_FAIL_REMOTE:-}" != "" && " $* " == *" push ${TODO4_FAIL_REMOTE} "* ]]; then
  marker="${TODO4_FAIL_MARKER:?}"
  if [[ ! -e "$marker" ]]; then : >"$marker"; exit 1; fi
fi
exec /usr/bin/git "$@"
EOF
  chmod +x "$TODO4_FIXTURE/bin/git"
}

scenario_publish() {
  todo4_setup publish main 1 1 || return 2
  todo4_prepare || return 2
  local tar_count age_count
  tar_count="$(wc -l <"$TODO4_FIXTURE/tar.log")"
  age_count="$(grep -Fvc age-validate "$TODO4_FIXTURE/age.log")"
  rm -rf "$TODO4_DATA"
  rm -f "$TODO4_FIXTURE/bin/tar" "$TODO4_FIXTURE/bin/age"
  todo4_publish || return 2
  local head remote
  head="$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)"
  remote="$(todo4_remote_oid "$TODO4_CANONICAL" main)"
  [[ "$head" == "$remote" && ! -e "$TODO4_STATE" ]] || return 2
  [[ "$(wc -l <"$TODO4_FIXTURE/tar.log")" == "$tar_count" && "$(grep -Fvc age-validate "$TODO4_FIXTURE/age.log")" == "$age_count" ]] || return 2
}

scenario_empty_remote_todo4() {
  todo4_setup empty-remote main 0 1 || return 2
  todo4_prepare || return 2
  todo4_publish || return 2
  [[ "$(todo4_remote_oid "$TODO4_CANONICAL" main)" == "$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)" ]] || return 2
}

scenario_custom_branch_todo4() {
  todo4_setup custom-branch release/2026.07 0 1 || return 2
  todo4_prepare || return 2
  todo4_publish || return 2
  [[ "$(todo4_remote_oid "$TODO4_CANONICAL" release/2026.07)" == "$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)" ]] || return 2
}

scenario_retry_state() {
  todo4_setup retry-state main 1 2 || return 2
  todo4_prepare || return 2
  todo4_install_git_wrapper
  local base tar_count first_commit
  base="$(todo4_remote_oid "$TODO4_MIRROR" main)"
  tar_count="$(wc -l <"$TODO4_FIXTURE/tar.log")"
  if todo4_run_script "$TODO4_FIXTURE/first-publish.log" TODO4_GIT_LOG="$TODO4_FIXTURE/git4.log" TODO4_FAIL_REMOTE=mirror TODO4_FAIL_MARKER="$TODO4_FIXTURE/fail-once" bash "$TODO4_REPO/scripts/publish-prepared.sh"; then return 2; fi
  first_commit="$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)"
  [[ "$(todo4_remote_oid "$TODO4_CANONICAL" main)" == "$first_commit" && "$(todo4_remote_oid "$TODO4_MIRROR" main)" == "$base" && -f "$TODO4_STATE" ]] || return 2
  /usr/bin/python3 - "$TODO4_STATE" "$first_commit" <<'PY'
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert state["committed_oid"] == sys.argv[2]
assert state["publication"]["remotes"] == [
    {"name": "canonical", "status": "published", "published_oid": sys.argv[2], "error": ""},
    {"name": "mirror", "status": "failed", "published_oid": "", "error": "push failed"},
]
PY
  todo4_run_script "$TODO4_FIXTURE/retry.log" TODO4_GIT_LOG="$TODO4_FIXTURE/git4.log" TODO4_FAIL_REMOTE=mirror TODO4_FAIL_MARKER="$TODO4_FIXTURE/fail-once" bash "$TODO4_REPO/scripts/publish-prepared.sh" || return 2
  [[ "$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)" == "$first_commit" && "$(todo4_remote_oid "$TODO4_MIRROR" main)" == "$first_commit" && ! -e "$TODO4_STATE" ]] || return 2
  [[ "$(wc -l <"$TODO4_FIXTURE/tar.log")" == "$tar_count" ]] || return 2
}

scenario_legacy_prepared_state_retry() {
  todo4_setup legacy-state-retry main 1 2 || return 2
  todo4_prepare || return 2
  /usr/bin/python3 - "$TODO4_STATE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
state = json.loads(path.read_text(encoding="utf-8"))
state["version"] = 1
state.pop("canonical_branch_exists")
path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  todo4_install_git_wrapper
  if todo4_run_script "$TODO4_FIXTURE/first-publish.log" TODO4_GIT_LOG="$TODO4_FIXTURE/git4.log" TODO4_FAIL_REMOTE=mirror TODO4_FAIL_MARKER="$TODO4_FIXTURE/fail-once" bash "$TODO4_REPO/scripts/publish-prepared.sh"; then return 2; fi
  /usr/bin/python3 - "$TODO4_STATE" <<'PY'
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert state["version"] == 1
assert "canonical_branch_exists" not in state
assert state["publication"]["remotes"][0]["status"] == "published"
assert state["publication"]["remotes"][1]["status"] == "failed"
PY
  todo4_run_script "$TODO4_FIXTURE/retry.log" TODO4_GIT_LOG="$TODO4_FIXTURE/git4.log" TODO4_FAIL_REMOTE=mirror TODO4_FAIL_MARKER="$TODO4_FIXTURE/fail-once" bash "$TODO4_REPO/scripts/publish-prepared.sh" || return 2
  [[ ! -e "$TODO4_STATE" && "$(todo4_remote_oid "$TODO4_CANONICAL" main)" == "$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)" && "$(todo4_remote_oid "$TODO4_MIRROR" main)" == "$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)" ]] || return 2
}

scenario_canonical_moved() {
  todo4_setup canonical-moved main 1 1 || return 2
  todo4_prepare || return 2
  local local_before
  local_before="$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)"
  todo4_advance_remote "$TODO4_CANONICAL" main canonical-advance
  local remote_before="$(todo4_remote_oid "$TODO4_CANONICAL" main)"
  if todo4_publish; then return 2; fi
  [[ "$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)" == "$local_before" && "$(todo4_remote_oid "$TODO4_CANONICAL" main)" == "$remote_before" && -f "$TODO4_STATE" ]] || return 2
}

scenario_canonical_deleted_after_prepare() {
  todo4_setup canonical-deleted main 1 1 || return 2
  todo4_prepare || return 2
  local local_before
  local_before="$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)"
  /usr/bin/git --git-dir="$TODO4_CANONICAL" update-ref -d refs/heads/main || return 2
  if todo4_publish; then return 2; fi
  /usr/bin/git --git-dir="$TODO4_CANONICAL" rev-parse --verify refs/heads/main >/dev/null 2>&1 && return 2
  [[ "$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)" == "$local_before" && -f "$TODO4_STATE" ]] || return 2
  grep -Fq 'canonical moved after preparation' "$TODO4_FIXTURE/publish.log" || return 2
}

scenario_immutable_mirror_divergence() {
  todo4_setup mirror-divergence main 1 2 || return 2
  todo4_prepare || return 2
  local local_before canonical_before
  local_before="$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)"
  canonical_before="$(todo4_remote_oid "$TODO4_CANONICAL" main)"
  todo4_advance_remote "$TODO4_MIRROR" main mirror-advance
  local mirror_before="$(todo4_remote_oid "$TODO4_MIRROR" main)"
  todo4_install_git_wrapper
  if todo4_run_script "$TODO4_FIXTURE/divergence.log" TODO4_GIT_LOG="$TODO4_FIXTURE/git4.log" bash "$TODO4_REPO/scripts/publish-prepared.sh"; then return 2; fi
  local committed
  committed="$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)"
  [[ "$committed" != "$local_before" && "$(todo4_remote_oid "$TODO4_CANONICAL" main)" == "$committed" && "$(todo4_remote_oid "$TODO4_MIRROR" main)" == "$mirror_before" && -f "$TODO4_STATE" ]] || return 2
  [[ "$canonical_before" == "$local_before" ]] || return 2
  if grep -Eq 'ARGS=.* (pull|rebase|merge|amend|reset|force|--force) ' "$TODO4_FIXTURE/git4.log"; then return 2; fi
}

scenario_missing_remote_todo4() {
  todo4_setup missing-remote main 1 1 || return 2
  todo4_write_config "$TODO4_REPO" "$TODO4_DATA" main canonical missing
  /usr/bin/git -C "$TODO4_REPO" add -- hosts/testbox/backup.conf
  /usr/bin/git -C "$TODO4_REPO" commit -qm "configure missing remote"
  if todo4_prepare; then return 2; fi
  [[ ! -e "$TODO4_STATE" && ! -s "$TODO4_FIXTURE/tar.log" ]] || return 2
}

scenario_branch_guards() {
  todo4_setup wrong-branch main 1 1 || return 2
  /usr/bin/git -C "$TODO4_REPO" checkout -qb other
  if todo4_prepare; then return 2; fi
  todo4_setup detached main 1 1 || return 2
  /usr/bin/git -C "$TODO4_REPO" checkout -q --detach
  if todo4_prepare; then return 2; fi
  todo4_setup unborn main 0 1 || return 2
  /usr/bin/git -C "$TODO4_REPO" checkout -q --orphan unborn
  /usr/bin/git -C "$TODO4_REPO" rm -qrf .
  todo4_write_config "$TODO4_REPO" "$TODO4_DATA" unborn canonical
  if todo4_prepare; then return 2; fi
}

scenario_transports() {
  [[ -f "$PROJECT_ROOT/scripts/lib/git-remotes.sh" ]] || return 2
  bash -c 'set -euo pipefail; REPO_DIR="$1"; source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/git-remotes.sh"; [[ "$(classify_remote_url https://example.invalid/a.git)" == http && "$(classify_remote_url ssh://git@example.invalid/a.git)" == native && "$(classify_remote_url git@example.invalid:a.git)" == native && "$(classify_remote_url file:///tmp/a.git)" == native && "$(classify_remote_url /tmp/a.git)" == native && "$(classify_remote_url ../a.git)" == native ]]; declare -A REMOTE_TRANSPORTS=([http]=http) REMOTE_FETCH_URLS=([http]=https://example.invalid/a.git); git() { if [[ "$1" == -C ]]; then shift 2; fi; [[ "$1" == fetch && "${GIT_ASKPASS-}" == "$REPO_DIR/scripts/git-askpass.sh" && "${GIT_ASKPASS_TOKEN-}" == token-http ]]; }; BACKUP_TOKEN_HTTP=token-http git_for_remote http fetch http refspec' _ "$PROJECT_ROOT" || return 2

  todo4_setup transports main 1 1 || return 2
  todo4_prepare || return 2
  todo4_install_git_wrapper
  todo4_run_script "$TODO4_FIXTURE/native-publish.log" TODO4_GIT_LOG="$TODO4_FIXTURE/git4.log" env -u GITHUB_TOKEN -u GITLAB_TOKEN -u BACKUP_GIT_TOKEN GIT_ASKPASS=poison GIT_ASKPASS_TOKEN=poison GIT_ASKPASS_USERNAME=poison bash "$TODO4_REPO/scripts/publish-prepared.sh" || return 2
  [[ "$(todo4_remote_oid "$TODO4_CANONICAL" main)" == "$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)" ]] || return 2
  if grep -E 'ARGS=.* (ls-remote|fetch|push) ' "$TODO4_FIXTURE/git4.log" | grep -Evq "ASKPASS='' TOKEN='' USER=''"; then return 2; fi
}

scenario_post_commit_immutability() {
  scenario_retry_state || return 2
  if grep -Eq ' (pull|rebase|merge|amend|reset|force|--force)' "$TODO4_FIXTURE/git4.log"; then return 2; fi
}

scenario_commit_state_recovery() {
  todo4_setup commit-state-recovery main 1 1 || return 2
  todo4_prepare || return 2
  local message committed
  message="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["publication"]["commit_message"])' "$TODO4_STATE")"
  /usr/bin/git -C "$TODO4_REPO" commit -qm "$message" || return 2
  committed="$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)"
  todo4_publish || return 2
  [[ "$(todo4_remote_oid "$TODO4_CANONICAL" main)" == "$committed" && ! -e "$TODO4_STATE" ]] || return 2
}

scenario_remote_status_recovery() {
  todo4_setup remote-status-recovery main 1 2 || return 2
  todo4_prepare || return 2
  local message committed
  message="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["publication"]["commit_message"])' "$TODO4_STATE")"
  /usr/bin/git -C "$TODO4_REPO" commit -qm "$message" || return 2
  committed="$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)"
  /usr/bin/python3 - "$TODO4_STATE" "$committed" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
state = json.loads(path.read_text(encoding="utf-8"))
state["committed_oid"] = sys.argv[2]
path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  /usr/bin/git -C "$TODO4_REPO" push -q canonical "$committed:refs/heads/main" || return 2
  todo4_install_git_wrapper
  todo4_run_script "$TODO4_FIXTURE/status-recovery.log" TODO4_GIT_LOG="$TODO4_FIXTURE/git4.log" bash "$TODO4_REPO/scripts/publish-prepared.sh" || return 2
  [[ "$(todo4_remote_oid "$TODO4_CANONICAL" main)" == "$committed" && "$(todo4_remote_oid "$TODO4_MIRROR" main)" == "$committed" && ! -e "$TODO4_STATE" ]] || return 2
  if grep -Eq 'ARGS=.* push canonical ' "$TODO4_FIXTURE/git4.log"; then return 2; fi
}

scenario_canonical_preprepare_sync() {
  local publisher
  todo4_setup canonical-preprepare-sync main 1 1 || return 2
  publisher="$TODO4_FIXTURE/publisher"
  /usr/bin/git clone -q --branch main "$TODO4_CANONICAL" "$publisher" || return 2
  /usr/bin/git -C "$publisher" remote rename origin canonical
  todo4_run_script "$TODO4_FIXTURE/canonical-publish.log" BACKUP_PUSH=1 BACKUP_CONFIG="$publisher/hosts/testbox/backup.conf" bash "$publisher/scripts/backup.sh" || return 2
  local canonical_oid
  canonical_oid="$(todo4_remote_oid "$TODO4_CANONICAL" main)"
  todo4_prepare || return 2
  [[ "$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)" == "$canonical_oid" ]] || return 2
  /usr/bin/python3 - "$TODO4_STATE" "$canonical_oid" <<'PY'
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert state["base_oid"] == sys.argv[2]
assert state["committed_oid"] == ""
PY
}

scenario_remote_validation_todo4() {
  todo4_setup duplicate-remote main 1 1 || return 2
  todo4_write_config "$TODO4_REPO" "$TODO4_DATA" main canonical canonical
  /usr/bin/git -C "$TODO4_REPO" add -- hosts/testbox/backup.conf
  /usr/bin/git -C "$TODO4_REPO" commit -qm "configure duplicate remote"
  if todo4_prepare; then return 2; fi
  grep -Fq 'duplicate remote: canonical' "$TODO4_FIXTURE/prepare.log" || return 2
  [[ ! -e "$TODO4_STATE" && ! -s "$TODO4_FIXTURE/tar.log" ]] || return 2

  todo4_setup unsupported-remote main 1 1 || return 2
  /usr/bin/git -C "$TODO4_REPO" remote set-url canonical ftp://example.invalid/repo.git
  if todo4_prepare; then return 2; fi
  grep -Fq 'unsupported remote transport' "$TODO4_FIXTURE/prepare.log" || return 2
  [[ ! -e "$TODO4_STATE" && ! -s "$TODO4_FIXTURE/tar.log" ]] || return 2
}
