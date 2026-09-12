#!/usr/bin/env bash

scenario_verifier_baseline_todo4() {
  todo4_setup verifier-baseline main 1 1 || return 2
  todo4_prepare || return 2
  local base
  base="$(todo4_remote_oid "$TODO4_CANONICAL" main)"
  todo4_publish || return 2
  [[ "$(todo4_remote_oid "$TODO4_CANONICAL" main)" == "$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)" ]] || return 2
  [[ "$(todo4_remote_oid "$TODO4_CANONICAL" main)" != "$base" && ! -e "$TODO4_STATE" ]] || return 2
}

scenario_canonical_only_precommit_todo4() {
  todo4_setup verifier-ordering main 1 2 || return 2
  todo4_prepare || return 2
  todo4_install_git_wrapper
  todo4_run_script "$TODO4_FIXTURE/order.log" TODO4_GIT_LOG="$TODO4_FIXTURE/git4.log" bash "$TODO4_REPO/scripts/publish-prepared.sh" || return 2
  /usr/bin/python3 - "$TODO4_FIXTURE/git4.log" <<'PY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()

def first(fragment):
    return next((index for index, line in enumerate(lines) if fragment in line), None)

commit = first(" commit ")
canonical_push = first(" push canonical ")
mirror_ops = [
    index
    for index, line in enumerate(lines)
    if any(fragment in line for fragment in (" ls-remote --exit-code mirror ", " fetch --no-tags mirror ", " push mirror "))
]
assert commit is not None and canonical_push is not None and mirror_ops
assert commit < canonical_push < min(mirror_ops)
PY
}

todo4_make_partial_publication() {
  todo4_setup "$1" main 1 2 || return 2
  todo4_prepare || return 2
  todo4_install_git_wrapper
  if todo4_run_script "$TODO4_FIXTURE/partial.log" TODO4_GIT_LOG="$TODO4_FIXTURE/git4.log" TODO4_FAIL_REMOTE=mirror TODO4_FAIL_MARKER="$TODO4_FIXTURE/fail-once" bash "$TODO4_REPO/scripts/publish-prepared.sh"; then
    return 2
  fi
  TODO4_PARTIAL_OID="$(/usr/bin/git -C "$TODO4_REPO" rev-parse HEAD)"
  TODO4_MIRROR_BEFORE="$(todo4_remote_oid "$TODO4_MIRROR" main)"
}

scenario_retry_branch_guard_todo4() {
  todo4_setup verifier-precommit-wrong-branch main 1 1 || return 2
  todo4_prepare || return 2
  local canonical_before
  canonical_before="$(todo4_remote_oid "$TODO4_CANONICAL" main)"
  /usr/bin/git -C "$TODO4_REPO" checkout -qb other
  if todo4_publish; then return 2; fi
  [[ "$(todo4_remote_oid "$TODO4_CANONICAL" main)" == "$canonical_before" && -f "$TODO4_STATE" ]] || return 2

  todo4_make_partial_publication verifier-retry-wrong-branch || return 2
  /usr/bin/git -C "$TODO4_REPO" checkout -qb other
  if todo4_run_script "$TODO4_FIXTURE/retry-wrong.log" TODO4_GIT_LOG="$TODO4_FIXTURE/git4.log" TODO4_FAIL_REMOTE=mirror TODO4_FAIL_MARKER="$TODO4_FIXTURE/fail-once" bash "$TODO4_REPO/scripts/publish-prepared.sh"; then return 2; fi
  [[ "$(todo4_remote_oid "$TODO4_MIRROR" main)" == "$TODO4_MIRROR_BEFORE" && -f "$TODO4_STATE" ]] || return 2

  todo4_make_partial_publication verifier-retry-detached || return 2
  /usr/bin/git -C "$TODO4_REPO" checkout -q --detach "$TODO4_PARTIAL_OID"
  if todo4_run_script "$TODO4_FIXTURE/retry-detached.log" TODO4_GIT_LOG="$TODO4_FIXTURE/git4.log" TODO4_FAIL_REMOTE=mirror TODO4_FAIL_MARKER="$TODO4_FIXTURE/fail-once" bash "$TODO4_REPO/scripts/publish-prepared.sh"; then return 2; fi
  [[ "$(todo4_remote_oid "$TODO4_MIRROR" main)" == "$TODO4_MIRROR_BEFORE" && -f "$TODO4_STATE" ]] || return 2
}

todo4_collision_case() {
  local name="$1" first="$2" second="$3"
  todo4_setup "$name" main 1 2 || return 2
  /usr/bin/git -C "$TODO4_REPO" remote rename canonical "$first"
  /usr/bin/git -C "$TODO4_REPO" remote rename mirror "$second"
  todo4_write_config "$TODO4_REPO" "$TODO4_DATA" main "$first" "$second"
  /usr/bin/git -C "$TODO4_REPO" add -- hosts/testbox/backup.conf
  /usr/bin/git -C "$TODO4_REPO" commit -qm "configure token collision"
  if todo4_run_script "$TODO4_FIXTURE/collision.log" BACKUP_TOKEN_FOO_BAR=verifier-secret BACKUP_PUSH=0 bash "$TODO4_REPO/scripts/backup.sh"; then return 2; fi
  grep -Fq 'token key collision' "$TODO4_FIXTURE/collision.log" || return 2
  if grep -Fq 'verifier-secret' "$TODO4_FIXTURE/collision.log"; then return 2; fi
  [[ ! -e "$TODO4_STATE" && ! -s "$TODO4_FIXTURE/tar.log" ]] || return 2
}

scenario_token_key_collisions_todo4() {
  todo4_collision_case verifier-collision-dash-dot foo-bar foo.bar || return 2
  todo4_collision_case verifier-collision-case foo FOO || return 2
}

scenario_push_provider_credentials_todo4() {
  new_fixture todo4-verifier-provider || return 2
  local fixture="$FIXTURE"
  mkdir -p "$fixture/bin"
  cat >"$fixture/bin/git" <<'EOF'
#!/usr/bin/env bash
printf 'TOKEN=%s USER=%s ARGS=' "${GIT_ASKPASS_TOKEN-}" "${GIT_ASKPASS_USERNAME-}" >>"${TODO4_PROVIDER_LOG:?}"
printf '%q ' "$@" >>"$TODO4_PROVIDER_LOG"
printf '\n' >>"$TODO4_PROVIDER_LOG"
EOF
  chmod +x "$fixture/bin/git"
  PATH="$fixture/bin:$PATH" TODO4_PROVIDER_LOG="$fixture/provider.log" \
    GITHUB_TOKEN=github-fallback GITLAB_TOKEN=gitlab-fallback BACKUP_GIT_TOKEN=generic-fallback \
    bash -c 'set -euo pipefail; REPO_DIR="$1"; source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/git-remotes.sh"; declare -A REMOTE_TRANSPORTS=([split]=http) REMOTE_FETCH_URLS=([split]=https://github.com/example/repo.git) REMOTE_PUSH_URLS=([split]=https://gitlab.com/example/repo.git); git_for_remote split push split oid:refs/heads/main; BACKUP_TOKEN_SPLIT=explicit-token git_for_remote split push split oid:refs/heads/main' _ "$PROJECT_ROOT" || return 2
  /usr/bin/python3 - "$fixture/provider.log" <<'PY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
assert len(lines) == 2
assert "TOKEN=gitlab-fallback USER=oauth2" in lines[0]
assert "TOKEN=explicit-token USER=oauth2" in lines[1]
assert "github-fallback" not in lines[0]
PY
}

scenario_provider_hostname_fallback_todo4() {
  new_fixture todo4-provider-hostname || return 2
  local fixture="$FIXTURE" status
  mkdir -p "$fixture/bin"
  cat >"$fixture/bin/git" <<'EOF'
#!/usr/bin/env bash
printf 'TOKEN=%s USER=%s ARGS=' "${GIT_ASKPASS_TOKEN-}" "${GIT_ASKPASS_USERNAME-}" >>"${TODO4_PROVIDER_LOG:?}"
printf '%q ' "$@" >>"$TODO4_PROVIDER_LOG"
printf '\n' >>"$TODO4_PROVIDER_LOG"
EOF
  chmod +x "$fixture/bin/git"
  PATH="$fixture/bin:$PATH" TODO4_PROVIDER_LOG="$fixture/provider.log" \
    GITHUB_TOKEN=github-sentinel GITLAB_TOKEN=gitlab-sentinel BACKUP_GIT_TOKEN=generic-sentinel \
    bash -c '
      set -euo pipefail
      REPO_DIR="$1"
      source "$1/scripts/lib/common.sh"
      source "$1/scripts/lib/git-remotes.sh"
      declare -A REMOTE_TRANSPORTS=() REMOTE_FETCH_URLS=() REMOTE_PUSH_URLS=()
      run_case() {
        local remote="$1" fetch="$2" push="$3"
        REMOTE_TRANSPORTS["$remote"]=http
        REMOTE_FETCH_URLS["$remote"]="$fetch"
        REMOTE_PUSH_URLS["$remote"]="$push"
        git_for_remote "$remote" push "$remote" oid:refs/heads/main
      }
      run_case github-exact https://example.invalid/fetch.git https://github.com/org/repo.git
      run_case github-case-port https://example.invalid/fetch.git https://GITHUB.COM:443/org/repo.git
      run_case gitlab-exact https://example.invalid/fetch.git https://gitlab.com/org/repo.git
      run_case github-lookalike https://example.invalid/fetch.git https://github.com.evil.invalid/repo.git
      run_case gitlab-lookalike https://example.invalid/fetch.git https://notgitlab.com/repo.git
      run_case github-path https://example.invalid/fetch.git https://example.invalid/github/repo.git
      run_case gitlab-path https://example.invalid/fetch.git https://example.invalid/gitlab/repo.git
      run_case push-selected https://github.com/org/fetch.git https://gitlab.com/org/push.git
      BACKUP_TOKEN_OVERRIDE_REMOTE=override-sentinel run_case override-remote https://example.invalid/fetch.git https://github.com/org/override.git
    ' _ "$PROJECT_ROOT" || return 2
  /usr/bin/python3 - "$fixture/provider.log" <<'PY'
import pathlib
import shlex
import sys

expected = {
    "github-exact": ("github-sentinel", "x-access-token"),
    "github-case-port": ("github-sentinel", "x-access-token"),
    "gitlab-exact": ("gitlab-sentinel", "oauth2"),
    "github-lookalike": ("generic-sentinel", "x-access-token"),
    "gitlab-lookalike": ("generic-sentinel", "x-access-token"),
    "github-path": ("generic-sentinel", "x-access-token"),
    "gitlab-path": ("generic-sentinel", "x-access-token"),
    "push-selected": ("gitlab-sentinel", "oauth2"),
    "override-remote": ("override-sentinel", "x-access-token"),
}
actual = {}
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    prefix, args = line.split(" ARGS=", 1)
    fields = dict(item.split("=", 1) for item in prefix.split())
    words = shlex.split(args)
    remote = words[words.index("push") + 1]
    actual[remote] = (fields["TOKEN"], fields["USER"])
if set(actual) != set(expected):
    raise SystemExit(2)
if actual == expected:
    raise SystemExit(0)
provider_values = {"github-sentinel", "gitlab-sentinel"}
known = (
    actual["github-case-port"] != expected["github-case-port"]
    or any(actual[name][0] in provider_values for name in ("github-lookalike", "gitlab-lookalike", "github-path", "gitlab-path"))
)
raise SystemExit(42 if known else 2)
PY
  status=$?
  if [[ "$status" -eq 42 ]]; then
    known_failure "provider fallback trusts URL substrings instead of exact selected hostname"
    return $?
  fi
  [[ "$status" -eq 0 ]] || return 2
}

todo4_control_url_case() {
  local name="$1" kind="$2" url="$3"
  todo4_setup "$name" main 1 1 || return 2
  if [[ "$kind" == push ]]; then
    /usr/bin/git -C "$TODO4_REPO" config --replace-all remote.canonical.url https://github.com/example/repo.git
    /usr/bin/git -C "$TODO4_REPO" config --replace-all remote.canonical.pushurl "$url"
  else
    /usr/bin/git -C "$TODO4_REPO" config --replace-all remote.canonical.url "$url"
  fi
  if todo4_run_script "$TODO4_FIXTURE/control.log" GITHUB_TOKEN=verifier-http-token GITLAB_TOKEN=verifier-gitlab-token BACKUP_PUSH=0 bash "$TODO4_REPO/scripts/backup.sh"; then return 2; fi
  grep -Fq 'remote URL contains ASCII control characters' "$TODO4_FIXTURE/control.log" || return 2
  if grep -Eq 'verifier-http-token|verifier-gitlab-token' "$TODO4_FIXTURE/control.log"; then return 2; fi
  [[ ! -e "$TODO4_STATE" && ! -s "$TODO4_FIXTURE/tar.log" ]] || return 2
}

scenario_control_url_validation_todo4() {
  todo4_control_url_case verifier-http-cr fetch $'https://example.invalid/repo.git\rshadow' || return 2
  todo4_control_url_case verifier-http-tab-push push $'https://gitlab.com/example/repo.git\tshadow' || return 2
  todo4_control_url_case verifier-file-cr fetch $'file:///tmp/repo.git\rshadow' || return 2
  todo4_control_url_case verifier-absolute-tab fetch $'/tmp/repo.git\tshadow' || return 2
  todo4_control_url_case verifier-relative-soh fetch $'../repo.git\001shadow' || return 2
  todo4_control_url_case verifier-plain-del fetch $'repo.git\177shadow' || return 2
}

scenario_hung_git_publication_todo4() {
  todo4_setup verifier-hung-git main 1 1 || return 2
  todo4_prepare || return 2
  local canonical_before output status
  canonical_before="$(todo4_remote_oid "$TODO4_CANONICAL" main)"
  cat >"$TODO4_FIXTURE/bin/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *' ls-remote '*|*' fetch '*|*' push '*) /bin/sleep 60 ;;
esac
exec /usr/bin/git "$@"
EOF
  chmod +x "$TODO4_FIXTURE/bin/git"
  output="$TODO4_FIXTURE/hung.log"
  local -a environment
  mapfile -t environment < <(fixture_env "$TODO4_FIXTURE")
  run_captured "$output" 2 env "${environment[@]}" BACKUP_HOST=testbox bash "$TODO4_REPO/scripts/publish-prepared.sh"
  status=$?
  [[ "$status" -eq 124 && -f "$TODO4_STATE" && "$(todo4_remote_oid "$TODO4_CANONICAL" main)" == "$canonical_before" ]] || return 2
  if compgen -G "$TODO4_REPO/.git/local-backup-push-kit/prepared/.testbox.publish.*" >/dev/null; then return 2; fi
}
