#!/usr/bin/env bash

todo3_install_git_wrapper() {
  local bin="$1"
  cat >"$bin/git" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%q ' "$@" >>"${FAKE_GIT_LOG:?}"
printf '\n' >>"$FAKE_GIT_LOG"

repo=""
command_name=""
for ((i = 1; i <= $#; i++)); do
  arg="${!i}"
  if [[ "$arg" == "-C" ]]; then
    j=$((i + 1))
    repo="${!j}"
  fi
  case "$arg" in
    add|fetch|pull|push) command_name="$arg"; break ;;
  esac
done

if [[ "${TODO3_GIT_MODE:-}" == race-* && "$command_name" == "" && " $* " == *' status --porcelain=v1 '* ]]; then
  counter_file="${TODO3_GIT_RACE_COUNTER:?}"
  count=0
  [[ -f "$counter_file" ]] && count="$(/bin/cat "$counter_file")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$counter_file"
  /usr/bin/git "$@"
  status=$?
  if [[ "$count" == "2" ]]; then
    if [[ "$TODO3_GIT_MODE" == "race-tracked" ]]; then
      printf 'external tracked race\n' >>"$repo/RACE.txt"
    else
      printf 'external untracked race\n' >"$repo/RACE.txt"
    fi
    : >"${TODO3_GIT_RACE_MARKER:?}"
  fi
  exit "$status"
fi

if [[ "${TODO3_GIT_MODE:-}" == "stage-partial-fail" && "$command_name" == "add" ]]; then
  after_separator=0
  for arg in "$@"; do
    if [[ "$after_separator" == "1" ]]; then
      /usr/bin/git -C "$repo" add -- "$arg"
      exit 1
    fi
    [[ "$arg" == "--" ]] && after_separator=1
  done
  exit 1
fi

if [[ "${TODO3_GIT_MODE:-}" == "stage-delay" && "$command_name" == "add" ]]; then
  /usr/bin/git "$@"
  : >"${TODO3_GIT_DELAY_MARKER:?}"
  /bin/sleep "${TODO3_GIT_DELAY:?}"
  exit 0
fi

if [[ "${TODO3_GIT_MODE:-}" == "extra-stage" && "$command_name" == "add" ]]; then
  /usr/bin/git "$@"
  printf 'external staged injection\n' >>"$repo/README.md"
  /usr/bin/git -C "$repo" add -- README.md
  exit 0
fi

if [[ "${TODO3_FAKE_NETWORK:-0}" == "1" ]]; then
  case "$command_name" in
    fetch|pull|push) exit 0 ;;
  esac
fi

exec /usr/bin/git "$@"
EOF
  chmod +x "$bin/git"
}

todo3_setup_fixture() {
  local name="$1"
  new_fixture "todo3-$name" || return 2
  TODO3_FIXTURE="$FIXTURE"
  TODO3_REPO="$TODO3_FIXTURE/repo"
  TODO3_DATA="$TODO3_FIXTURE/data"
  TODO3_ORIGIN="$TODO3_FIXTURE/origin.git"
  copy_template "$TODO3_REPO"
  install_common_shims "$TODO3_FIXTURE"
  todo3_install_git_wrapper "$TODO3_FIXTURE/bin"
  mkdir -p "$TODO3_DATA"
  printf 'payload\n' >"$TODO3_DATA/payload.txt"
  write_config "$TODO3_REPO" testbox "$TODO3_DATA" origin
  init_real_repo "$TODO3_REPO" || return 2
  /usr/bin/git init -q --bare "$TODO3_ORIGIN" || return 2
  /usr/bin/git -C "$TODO3_REPO" remote add origin "$TODO3_ORIGIN" || return 2
  /usr/bin/git -C "$TODO3_REPO" push -q origin HEAD:refs/heads/main || return 2
  TODO3_STATE="$TODO3_REPO/.git/local-backup-push-kit/prepared/testbox.state"
}

todo3_run() {
  local push="$1"
  shift
  local -a environment
  mapfile -t environment < <(fixture_env "$TODO3_FIXTURE")
  run_captured "$TODO3_FIXTURE/run.log" 8 env \
    "${environment[@]}" \
    TODO3_GIT_RACE_COUNTER="$TODO3_FIXTURE/git-race.counter" \
    TODO3_GIT_RACE_MARKER="$TODO3_FIXTURE/git-race.marker" \
    BACKUP_HOST=testbox \
    BACKUP_PUSH="$push" \
    "$@" \
    bash "$TODO3_REPO/scripts/backup.sh"
}

todo3_inventory() {
  local destination="$1"
  /usr/bin/python3 - "$TODO3_REPO" "$destination" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
digest = hashlib.sha256()
for path in sorted(root.rglob("*")):
    relative = path.relative_to(root)
    if relative.parts and relative.parts[0] == ".git":
        continue
    if path.is_file():
        digest.update(str(relative).encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
destination.write_text(digest.hexdigest() + "\n", encoding="utf-8")
PY
}

todo3_tree_digest() {
  /usr/bin/python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(root.rglob("*")):
    relative = path.relative_to(root)
    digest.update(str(relative).encode())
    digest.update(b"\0")
    if path.is_file():
        digest.update(path.read_bytes())
    digest.update(b"\0")
print(digest.hexdigest())
PY
}

todo3_snapshot() {
  local prefix="$1"
  todo3_inventory "$prefix.inventory"
  /usr/bin/git -C "$TODO3_REPO" write-tree >"$prefix.tree"
  /usr/bin/git -C "$TODO3_REPO" status --porcelain=v1 --untracked-files=all >"$prefix.status"
  if [[ -e "$TODO3_REPO/backups/testbox/latest.txt" ]]; then
    printf 'present\n' >"$prefix.latest"
    /usr/bin/sha256sum "$TODO3_REPO/backups/testbox/latest.txt" >>"$prefix.latest"
  else
    printf 'absent\n' >"$prefix.latest"
  fi
}

todo3_assert_snapshot_equal() {
  local before="$1" after="$2"
  cmp -s "$before.inventory" "$after.inventory" || { say_error "worktree inventory changed after failed preparation"; return 2; }
  cmp -s "$before.tree" "$after.tree" || { say_error "index tree changed after failed preparation"; return 2; }
  cmp -s "$before.status" "$after.status" || { say_error "Git status changed after failed preparation"; return 2; }
  cmp -s "$before.latest" "$after.latest" || { say_error "latest marker changed after failed preparation"; return 2; }
}

todo3_find_paths() {
  TODO3_ARCHIVE="$(find "$TODO3_REPO/backups/testbox" -maxdepth 1 -type f -name '*.tar.zst.age' -print -quit)"
  TODO3_CHECKSUM="$(find "$TODO3_REPO/backups/testbox" -maxdepth 1 -type f -name '*.sha256' -print -quit)"
  TODO3_MANIFEST="$(find "$TODO3_REPO/manifests/testbox" -maxdepth 1 -type f -name '*.json' -print -quit)"
  [[ -n "$TODO3_ARCHIVE" && -n "$TODO3_CHECKSUM" && -n "$TODO3_MANIFEST" ]] || { say_error "prepared output set is incomplete"; return 2; }
}

todo3_assert_prepared() {
  [[ -f "$TODO3_STATE" ]] || { say_error "prepared state was not persisted"; return 2; }
  [[ -f "$TODO3_REPO/backups/testbox/latest.txt" ]] || { say_error "latest marker was not installed"; return 2; }
  [[ "$(find "$TODO3_REPO/backups/testbox" -maxdepth 1 -type f -name '*.tar.zst.age' | wc -l)" == "1" ]] || return 2
  [[ "$(find "$TODO3_REPO/backups/testbox" -maxdepth 1 -type f -name '*.sha256' | wc -l)" == "1" ]] || return 2
  [[ "$(find "$TODO3_REPO/manifests/testbox" -maxdepth 1 -type f -name '*.json' | wc -l)" == "1" ]] || return 2
  todo3_find_paths
}

scenario_prepare() {
  todo3_setup_fixture prepare || return 2
  todo3_run 0 || return 2
  todo3_assert_prepared
}

scenario_decrypt() {
  todo3_setup_fixture decrypt || return 2
  todo3_run 0 || return 2
  todo3_assert_prepared || return 2
  env PATH="$TODO3_FIXTURE/bin:$PATH" age -d -i "$TODO3_FIXTURE/identity.txt" "$TODO3_ARCHIVE" >"$TODO3_FIXTURE/decrypted.tar.zst" || return 2
  grep -Fq 'fixture sentinel' "$TODO3_FIXTURE/decrypted.tar.zst" || { say_error "decrypted archive lacks producer sentinel"; return 2; }
}

scenario_checksum() {
  todo3_setup_fixture checksum || return 2
  todo3_run 0 || return 2
  todo3_assert_prepared || return 2
  (cd "$TODO3_REPO" && /usr/bin/sha256sum -c "${TODO3_CHECKSUM#"$TODO3_REPO/"}") >/dev/null || return 2
}

scenario_state() {
  todo3_setup_fixture state || return 2
  todo3_run 0 || return 2
  todo3_assert_prepared || return 2
  /usr/bin/python3 - "$TODO3_STATE" "$TODO3_REPO" <<'PY'
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
root = pathlib.Path(sys.argv[2])
assert state["version"] == 2
assert state["canonical_branch_exists"] is True
assert state["host"] == "testbox"
assert state["branch"] == "main"
assert len(state["base_oid"]) == 40
assert state["remotes"] == ["origin"]
assert state["retention_deletions"] == []
assert state["committed_oid"] == ""
assert len(state["paths"]) == 4
assert sorted(state["paths"].values()) == sorted(state["staged_paths"])
assert set(state["hashes"]) == set(state["staged_paths"])
for relative in state["staged_paths"]:
    path = pathlib.PurePosixPath(relative)
    assert not path.is_absolute() and ".." not in path.parts
    assert (root / relative).is_file()
assert state["publication"] == {
    "artifact_id": state["publication"]["artifact_id"],
    "commit_message": f"Add testbox encrypted backup {state['publication']['artifact_id']}",
    "remotes": [{"name": "origin", "status": "pending", "published_oid": "", "error": ""}],
}
PY
}

scenario_schema_scaffold() {
  todo3_setup_fixture schema-scaffold || return 2
  /usr/bin/python3 - "$TODO3_REPO/hosts/testbox/backup.conf" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8").replace('BACKUP_REMOTES=("origin")', 'BACKUP_REMOTES=("origin" "mirror")')
path.write_text(text, encoding="utf-8")
PY
  /usr/bin/git -C "$TODO3_REPO" add -- hosts/testbox/backup.conf
  /usr/bin/git -C "$TODO3_REPO" commit -qm "configure two remotes"
  /usr/bin/git init -q --bare "$TODO3_FIXTURE/mirror.git" || return 2
  /usr/bin/git -C "$TODO3_REPO" remote add mirror "$TODO3_FIXTURE/mirror.git" || return 2
  /usr/bin/git -C "$TODO3_REPO" push -q origin HEAD:refs/heads/main || return 2
  /usr/bin/git -C "$TODO3_REPO" push -q mirror HEAD:refs/heads/main || return 2
  todo3_run 0 || return 2
  /usr/bin/python3 - "$TODO3_STATE" <<'PY'
import json
import pathlib
import sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert state["retention_deletions"] == []
assert state["committed_oid"] == ""
assert state["remotes"] == ["origin", "mirror"]
assert state["publication"]["remotes"] == [
    {"name": "origin", "status": "pending", "published_oid": "", "error": ""},
    {"name": "mirror", "status": "pending", "published_oid": "", "error": ""},
]
PY
}

scenario_exact_staging() {
  todo3_setup_fixture exact-staging || return 2
  todo3_run 0 || return 2
  todo3_assert_prepared || return 2
  /usr/bin/git -C "$TODO3_REPO" diff --cached --name-only | LC_ALL=C sort >"$TODO3_FIXTURE/staged"
  printf '%s\n' \
    "${TODO3_ARCHIVE#"$TODO3_REPO/"}" \
    "${TODO3_CHECKSUM#"$TODO3_REPO/"}" \
    "${TODO3_MANIFEST#"$TODO3_REPO/"}" \
    "backups/testbox/latest.txt" | LC_ALL=C sort >"$TODO3_FIXTURE/expected-staged"
  cmp -s "$TODO3_FIXTURE/expected-staged" "$TODO3_FIXTURE/staged" || { say_error "staged paths are not exactly the four prepared outputs"; return 2; }
  grep -Eq 'add -- backups/testbox/[^ ]+\.tar\.zst\.age backups/testbox/[^ ]+\.sha256 manifests/testbox/[^ ]+\.json backups/testbox/latest\.txt' "$TODO3_FIXTURE/git.log" || { say_error "git add was not one exact four-path invocation"; return 2; }
}

scenario_manifest_memory_todo3() {
  todo3_setup_fixture manifest-memory || return 2
  todo3_run 0 || return 2
  grep -Fq 'timestamp_utc' "$TODO3_FIXTURE/python-code.py" || return 2
  if grep -Eq 'fh\.read\(|read_bytes\(' "$TODO3_FIXTURE/python-code.py"; then
    say_error "manifest hashing reads the whole archive into memory"
    return 2
  fi
}

todo3_failure_scenario() {
  local name="$1"
  shift
  todo3_setup_fixture "$name" || return 2
  todo3_snapshot "$TODO3_FIXTURE/before" || return 2
  if todo3_run 0 "$@"; then
    say_error "$name unexpectedly succeeded"
    return 2
  fi
  todo3_snapshot "$TODO3_FIXTURE/after" || return 2
  todo3_assert_snapshot_equal "$TODO3_FIXTURE/before" "$TODO3_FIXTURE/after" || return 2
  [[ ! -e "$TODO3_STATE" ]] || { say_error "$name left prepared state behind"; return 2; }
}

scenario_fail_tar() { todo3_failure_scenario fail-tar FAKE_TAR_MODE=partial; }
scenario_fail_age() { todo3_failure_scenario fail-age FAKE_AGE_MODE=partial-fail; }
scenario_fail_checksum() { todo3_failure_scenario fail-checksum FAKE_SHA256_FAIL_AT=1; }
scenario_fail_manifest() { todo3_failure_scenario fail-manifest FAKE_MANIFEST_MODE=partial-fail; }
scenario_fail_state() { todo3_failure_scenario fail-state FAKE_STATE_MODE=partial-fail; }
scenario_fail_staging() { todo3_failure_scenario fail-staging TODO3_GIT_MODE=stage-partial-fail; }

scenario_dirty_index_todo3() {
  todo3_setup_fixture dirty-index || return 2
  printf 'changed\n' >>"$TODO3_REPO/README.md"
  /usr/bin/git -C "$TODO3_REPO" add -- README.md
  todo3_snapshot "$TODO3_FIXTURE/before" || return 2
  if todo3_run 0; then return 2; fi
  todo3_snapshot "$TODO3_FIXTURE/after" || return 2
  todo3_assert_snapshot_equal "$TODO3_FIXTURE/before" "$TODO3_FIXTURE/after"
}

todo3_producer_count() {
  grep -Fvc 'age-validate' "$TODO3_FIXTURE/age.log" 2>/dev/null || true
}

scenario_prepared_reuse() {
  todo3_setup_fixture prepared-reuse || return 2
  todo3_run 0 || return 2
  todo3_assert_prepared || return 2
  local before_age_count before_archive_count before_archive_hash before_head before_tar_count
  before_age_count="$(todo3_producer_count)"
  before_archive_count="$(find "$TODO3_REPO/backups/testbox" -maxdepth 1 -type f -name '*.tar.zst.age' | wc -l)"
  before_archive_hash="$(/usr/bin/sha256sum "$TODO3_ARCHIVE")"
  before_head="$(/usr/bin/git -C "$TODO3_REPO" rev-parse HEAD)"
  before_tar_count="$(wc -l <"$TODO3_FIXTURE/tar.log")"
  todo3_run 1 BACKUP_GIT_TOKEN=test-token || return 2
  [[ "$(todo3_producer_count)" == "$before_age_count" ]] || { say_error "prepared publication reran encryption"; return 2; }
  [[ "$(find "$TODO3_REPO/backups/testbox" -maxdepth 1 -type f -name '*.tar.zst.age' | wc -l)" == "$before_archive_count" ]] || { say_error "prepared publication created another archive"; return 2; }
  [[ "$(/usr/bin/sha256sum "$TODO3_ARCHIVE")" == "$before_archive_hash" ]] || { say_error "prepared publication changed the tested archive hash"; return 2; }
  [[ "$(wc -l <"$TODO3_FIXTURE/tar.log")" == "$before_tar_count" ]] || { say_error "prepared publication reran tar"; return 2; }
  [[ "$(/usr/bin/git -C "$TODO3_REPO" rev-parse HEAD)" != "$before_head" ]] || return 2
  [[ ! -e "$TODO3_STATE" ]] || { say_error "successful prepared publication left state behind"; return 2; }
  grep -Eq 'push origin [0-9a-f]+:refs/heads/main' "$TODO3_FIXTURE/git.log" || return 2
}

scenario_direct_publication() {
  todo3_setup_fixture direct-publication || return 2
  local before_head
  before_head="$(/usr/bin/git -C "$TODO3_REPO" rev-parse HEAD)"
  todo3_run 1 BACKUP_GIT_TOKEN=test-token || return 2
  [[ "$(todo3_producer_count)" == "1" ]] || { say_error "direct publication did not produce exactly one archive"; return 2; }
  [[ "$(/usr/bin/git -C "$TODO3_REPO" rev-parse HEAD)" != "$before_head" ]] || return 2
  [[ ! -e "$TODO3_STATE" ]] || { say_error "successful direct publication left prepared state behind"; return 2; }
  grep -Eq 'push origin [0-9a-f]+:refs/heads/main' "$TODO3_FIXTURE/git.log" || return 2
}

scenario_prepared_tampered() {
  todo3_setup_fixture prepared-tampered || return 2
  todo3_run 0 || return 2
  todo3_assert_prepared || return 2
  printf 'tampered\n' >>"$TODO3_ARCHIVE"
  local before_count="$(todo3_producer_count)"
  if todo3_run 1 BACKUP_GIT_TOKEN=test-token; then return 2; fi
  [[ "$(todo3_producer_count)" == "$before_count" && -f "$TODO3_STATE" ]] || return 2
}

scenario_state_malformed() {
  todo3_setup_fixture state-malformed || return 2
  todo3_run 0 || return 2
  todo3_assert_prepared || return 2
  printf '{not-json\n' >"$TODO3_STATE"
  local before_count="$(todo3_producer_count)"
  if todo3_run 1 BACKUP_GIT_TOKEN=test-token; then return 2; fi
  [[ "$(todo3_producer_count)" == "$before_count" ]] || return 2
}

todo3_mutate_state() {
  local mutation="$1" source="$2" destination="$3"
  /usr/bin/python3 - "$mutation" "$source" "$destination" <<'PY'
import json
import pathlib
import sys

mutation, source, destination = sys.argv[1:]
state = json.loads(pathlib.Path(source).read_text(encoding="utf-8"))
if mutation == "version":
    state["version"] = 3
elif mutation == "host":
    state["host"] = "other"
elif mutation == "branch":
    state["branch"] = "other"
elif mutation == "base":
    state["base_oid"] = "0" * 40
elif mutation == "remotes":
    state["remotes"] = ["other"]
elif mutation == "traversal":
    old = state["paths"]["archive"]
    new = "../escape.age"
    state["paths"]["archive"] = new
    state["staged_paths"][0] = new
    state["hashes"][new] = state["hashes"].pop(old)
elif mutation == "duplicate":
    archive = state["paths"]["archive"]
    checksum = state["paths"]["checksum"]
    state["paths"]["checksum"] = archive
    state["staged_paths"][1] = archive
    state["hashes"].pop(checksum)
elif mutation == "staged":
    state["staged_paths"].append("README.md")
elif mutation == "hash":
    state["hashes"][state["paths"]["archive"]] = "0" * 64
elif mutation == "artifact-format":
    state["publication"]["artifact_id"] = "not-an-artifact"
elif mutation == "commit-message":
    state["publication"]["commit_message"] = "arbitrary"
elif mutation == "retention":
    state["retention_deletions"] = ["backups/testbox/old.tar.zst.age"]
elif mutation == "committed":
    state["committed_oid"] = "0" * 40
elif mutation == "publication-status":
    state["publication"]["remotes"][0]["status"] = "published"
elif mutation == "publication-oid":
    state["publication"]["remotes"][0]["published_oid"] = "0" * 40
elif mutation == "publication-error":
    state["publication"]["remotes"][0]["error"] = "forged"
elif mutation == "version-type":
    state["version"] = True
elif mutation == "extra-top":
    state["extra"] = "forged"
elif mutation == "missing-top":
    del state["committed_oid"]
elif mutation == "hash-format":
    state["hashes"][state["paths"]["archive"]] = "not-a-sha256"
elif mutation == "publication-type":
    state["publication"]["remotes"] = "origin"
elif mutation == "latest-evil":
    old = state["paths"]["latest"]
    new = old + ".evil"
    state["paths"]["latest"] = new
    state["staged_paths"][3] = new
    state["hashes"][new] = state["hashes"].pop(old)
elif mutation == "archive-prefix":
    old = state["paths"]["archive"]
    new = old.replace("backups/testbox/", "backups/testbox/prefix-")
    state["paths"]["archive"] = new
    state["staged_paths"][0] = new
    state["hashes"][new] = state["hashes"].pop(old)
elif mutation == "checksum-id":
    old = state["paths"]["checksum"]
    new = "backups/testbox/2000-01-01T00-00-00Z-000000000.sha256"
    state["paths"]["checksum"] = new
    state["staged_paths"][1] = new
    state["hashes"][new] = state["hashes"].pop(old)
elif mutation == "manifest-suffix":
    old = state["paths"]["manifest"]
    new = old + ".evil"
    state["paths"]["manifest"] = new
    state["staged_paths"][2] = new
    state["hashes"][new] = state["hashes"].pop(old)
elif mutation == "control-path":
    old = state["paths"]["archive"]
    new = old + "\nREADME.md"
    state["paths"]["archive"] = new
    state["staged_paths"][0] = new
    state["hashes"][new] = state["hashes"].pop(old)
else:
    raise SystemExit("unknown mutation")
pathlib.Path(destination).write_text(json.dumps(state) + "\n", encoding="utf-8")
PY
}

scenario_state_validation() {
  todo3_setup_fixture state-validation || return 2
  todo3_run 0 || return 2
  todo3_assert_prepared || return 2
  local original="$TODO3_FIXTURE/original.state" mutation before_count before_head
  /bin/cp "$TODO3_STATE" "$original"
  before_count="$(todo3_producer_count)"
  before_head="$(/usr/bin/git -C "$TODO3_REPO" rev-parse HEAD)"
  for mutation in version version-type extra-top missing-top host branch base remotes traversal duplicate staged hash hash-format artifact-format commit-message retention committed publication-status publication-oid publication-error publication-type; do
    todo3_mutate_state "$mutation" "$original" "$TODO3_STATE" || return 2
    if todo3_run 1 BACKUP_GIT_TOKEN=test-token; then
      say_error "prepared state mutation was accepted: $mutation"
      return 2
    fi
    [[ "$(todo3_producer_count)" == "$before_count" ]] || return 2
    [[ "$(/usr/bin/git -C "$TODO3_REPO" rev-parse HEAD)" == "$before_head" ]] || return 2
    [[ -f "$TODO3_STATE" ]] || return 2
  done
}

scenario_exact_path_tricks() {
  local mutation key old_path new_path
  for mutation in latest-evil archive-prefix checksum-id manifest-suffix; do
    todo3_setup_fixture "exact-$mutation" || return 2
    todo3_run 0 || return 2
    todo3_assert_prepared || return 2
    /bin/cp "$TODO3_STATE" "$TODO3_FIXTURE/original.state"
    todo3_mutate_state "$mutation" "$TODO3_FIXTURE/original.state" "$TODO3_STATE" || return 2
    case "$mutation" in
      latest-evil) key=latest ;;
      archive-prefix) key=archive ;;
      checksum-id) key=checksum ;;
      manifest-suffix) key=manifest ;;
    esac
    mapfile -t paths < <(/usr/bin/python3 - "$TODO3_FIXTURE/original.state" "$TODO3_STATE" "$key" <<'PY'
import json
import sys
for name in sys.argv[1:3]:
    with open(name, encoding="utf-8") as handle:
        print(json.load(handle)["paths"][sys.argv[3]])
PY
    )
    old_path="${paths[0]}"
    new_path="${paths[1]}"
    mkdir -p "$(dirname "$TODO3_REPO/$new_path")"
    /bin/cp "$TODO3_REPO/$old_path" "$TODO3_REPO/$new_path"
    /usr/bin/git -C "$TODO3_REPO" restore --staged -- "$old_path"
    rm -f "$TODO3_REPO/$old_path"
    /usr/bin/git -C "$TODO3_REPO" add -- "$new_path"
    if todo3_run 1 BACKUP_GIT_TOKEN=test-token; then
      say_error "exact-path mutation was accepted: $mutation"
      return 2
    fi
  done

  todo3_setup_fixture exact-control-path || return 2
  todo3_run 0 || return 2
  todo3_assert_prepared || return 2
  /bin/cp "$TODO3_STATE" "$TODO3_FIXTURE/original.state"
  todo3_mutate_state control-path "$TODO3_FIXTURE/original.state" "$TODO3_STATE" || return 2
  if todo3_run 1 BACKUP_GIT_TOKEN=test-token; then return 2; fi
}

scenario_extra_stage_injection() {
  todo3_setup_fixture extra-stage || return 2
  local before_tree
  before_tree="$(/usr/bin/git -C "$TODO3_REPO" write-tree)"
  if todo3_run 0 TODO3_GIT_MODE=extra-stage; then return 2; fi
  [[ "$(/usr/bin/git -C "$TODO3_REPO" write-tree)" == "$before_tree" ]] || return 2
  [[ ! -e "$TODO3_STATE" && ! -e "$TODO3_REPO/backups/testbox" && ! -e "$TODO3_REPO/manifests/testbox" ]] || return 2
  [[ "$(/usr/bin/git -C "$TODO3_REPO" status --porcelain=v1)" == ' M README.md' ]] || return 2
  grep -Fq 'external staged injection' "$TODO3_REPO/README.md" || return 2
}

todo3_race_scenario() {
  local mode="$1"
  todo3_setup_fixture "$mode" || return 2
  if [[ "$mode" == "race-tracked" ]]; then
    printf 'baseline\n' >"$TODO3_REPO/RACE.txt"
    /usr/bin/git -C "$TODO3_REPO" add -- RACE.txt
    /usr/bin/git -C "$TODO3_REPO" commit -qm "track race fixture"
  fi
  local before_tree
  before_tree="$(/usr/bin/git -C "$TODO3_REPO" write-tree)"
  if todo3_run 0 "TODO3_GIT_MODE=$mode"; then return 2; fi
  [[ -e "$TODO3_FIXTURE/git-race.marker" ]] || return 2
  [[ "$(/usr/bin/git -C "$TODO3_REPO" write-tree)" == "$before_tree" ]] || return 2
  [[ ! -e "$TODO3_STATE" && ! -e "$TODO3_REPO/backups/testbox" && ! -e "$TODO3_REPO/manifests/testbox" ]] || return 2
  if [[ "$mode" == "race-tracked" ]]; then
    [[ "$(/usr/bin/git -C "$TODO3_REPO" status --porcelain=v1)" == ' M RACE.txt' ]] || return 2
  else
    [[ "$(/usr/bin/git -C "$TODO3_REPO" status --porcelain=v1)" == '?? RACE.txt' ]] || return 2
  fi
  grep -Fq 'external ' "$TODO3_REPO/RACE.txt" || return 2
}

scenario_race_tracked() { todo3_race_scenario race-tracked; }
scenario_race_untracked() { todo3_race_scenario race-untracked; }

scenario_storage_symlinks() {
  local kind external external_before
  for kind in state prepared-dir state-file backups backups-host manifests manifests-host; do
    todo3_setup_fixture "symlink-$kind" || return 2
    external="$TODO3_FIXTURE/external"
    mkdir -p "$external"
    case "$kind" in
      state)
        mkdir -p "$TODO3_REPO/.git"
        ln -s "$external" "$TODO3_REPO/.git/local-backup-push-kit"
        ;;
      prepared-dir)
        mkdir -p "$TODO3_REPO/.git/local-backup-push-kit"
        ln -s "$external" "$TODO3_REPO/.git/local-backup-push-kit/prepared"
        ;;
      state-file)
        mkdir -p "$TODO3_REPO/.git/local-backup-push-kit/prepared"
        : >"$external/state"
        ln -s "$external/state" "$TODO3_REPO/.git/local-backup-push-kit/prepared/testbox.state"
        ;;
      backups)
        ln -s "$external" "$TODO3_REPO/backups"
        /usr/bin/git -C "$TODO3_REPO" add -- backups
        /usr/bin/git -C "$TODO3_REPO" commit -qm "track backups symlink"
        ;;
      backups-host)
        mkdir -p "$TODO3_REPO/backups"
        ln -s "$external" "$TODO3_REPO/backups/testbox"
        /usr/bin/git -C "$TODO3_REPO" add -- backups
        /usr/bin/git -C "$TODO3_REPO" commit -qm "track backup host symlink"
        ;;
      manifests)
        ln -s "$external" "$TODO3_REPO/manifests"
        /usr/bin/git -C "$TODO3_REPO" add -- manifests
        /usr/bin/git -C "$TODO3_REPO" commit -qm "track manifests symlink"
        ;;
      manifests-host)
        mkdir -p "$TODO3_REPO/manifests"
        ln -s "$external" "$TODO3_REPO/manifests/testbox"
        /usr/bin/git -C "$TODO3_REPO" add -- manifests
        /usr/bin/git -C "$TODO3_REPO" commit -qm "track manifest symlink"
        ;;
    esac
    external_before="$(todo3_tree_digest "$external")"
    if todo3_run 0; then
      say_error "storage symlink was accepted: $kind"
      return 2
    fi
    [[ "$(todo3_tree_digest "$external")" == "$external_before" ]] || { say_error "storage symlink wrote outside repository: $kind"; return 2; }
  done
}

scenario_prepared_hardlink() {
  todo3_setup_fixture prepared-hardlink || return 2
  todo3_run 0 || return 2
  todo3_assert_prepared || return 2
  /bin/cp "$TODO3_ARCHIVE" "$TODO3_FIXTURE/hardlink-source"
  rm -f "$TODO3_ARCHIVE"
  ln "$TODO3_FIXTURE/hardlink-source" "$TODO3_ARCHIVE"
  [[ "$(stat -c %h "$TODO3_ARCHIVE")" == "2" ]] || return 2
  if todo3_run 1 BACKUP_GIT_TOKEN=test-token; then return 2; fi
  [[ -f "$TODO3_STATE" ]] || return 2
}

scenario_output_hardlink() {
  todo3_setup_fixture output-hardlink || return 2
  mkdir -p "$TODO3_REPO/backups/testbox"
  printf 'historical latest\n' >"$TODO3_FIXTURE/external-latest"
  ln "$TODO3_FIXTURE/external-latest" "$TODO3_REPO/backups/testbox/latest.txt"
  /usr/bin/git -C "$TODO3_REPO" add -- backups/testbox/latest.txt
  /usr/bin/git -C "$TODO3_REPO" commit -qm "track hardlinked latest fixture"
  local before_hash
  before_hash="$(/usr/bin/sha256sum "$TODO3_FIXTURE/external-latest")"
  if todo3_run 0; then return 2; fi
  [[ "$(/usr/bin/sha256sum "$TODO3_FIXTURE/external-latest")" == "$before_hash" ]] || return 2
  [[ "$(stat -c %h "$TODO3_FIXTURE/external-latest")" == "2" ]] || return 2
  [[ ! -e "$TODO3_STATE" ]] || return 2
}

scenario_historical_rollback() {
  todo3_setup_fixture historical-rollback || return 2
  mkdir -p "$TODO3_REPO/backups/testbox" "$TODO3_REPO/manifests/testbox"
  printf 'historical archive\n' >"$TODO3_REPO/backups/testbox/2025-01-01T00-00-00Z-000000001.tar.zst.age"
  printf 'historical checksum\n' >"$TODO3_REPO/backups/testbox/2025-01-01T00-00-00Z-000000001.sha256"
  printf '{"historical":true}\n' >"$TODO3_REPO/manifests/testbox/2025-01-01T00-00-00Z-000000001.json"
  printf 'backups/testbox/2025-01-01T00-00-00Z-000000001.tar.zst.age\n' >"$TODO3_REPO/backups/testbox/latest.txt"
  chmod 0640 "$TODO3_REPO/backups/testbox/latest.txt"
  /usr/bin/git -C "$TODO3_REPO" add -- backups manifests
  /usr/bin/git -C "$TODO3_REPO" commit -qm "historical fixture"
  local before_inventory="$TODO3_FIXTURE/history-before" after_inventory="$TODO3_FIXTURE/history-after" before_mode
  todo3_inventory "$before_inventory"
  before_mode="$(stat -c %a "$TODO3_REPO/backups/testbox/latest.txt")"
  if todo3_run 0 FAKE_STATE_MODE=partial-fail; then return 2; fi
  todo3_inventory "$after_inventory"
  cmp -s "$before_inventory" "$after_inventory" || return 2
  [[ "$(stat -c %a "$TODO3_REPO/backups/testbox/latest.txt")" == "$before_mode" ]] || return 2
  [[ ! -e "$TODO3_STATE" ]] || return 2
}

scenario_prepared_stale() {
  todo3_setup_fixture prepared-stale || return 2
  todo3_run 0 || return 2
  todo3_assert_prepared || return 2
  /usr/bin/git -C "$TODO3_REPO" reset -q
  printf 'advance\n' >>"$TODO3_REPO/README.md"
  /usr/bin/git -C "$TODO3_REPO" add -- README.md
  /usr/bin/git -C "$TODO3_REPO" commit -qm "advance base"
  if todo3_run 1 BACKUP_GIT_TOKEN=test-token; then return 2; fi
  [[ -f "$TODO3_STATE" ]] || return 2
}

todo3_wait_for_marker() {
  local marker="$1" attempt
  for attempt in $(seq 1 100); do
    [[ -e "$marker" ]] && return 0
    /bin/sleep 0.05
  done
  say_error "phase marker was not reached: $marker"
  return 2
}

todo3_signal_scenario() {
  local name="$1" signal_name="$2" marker_name="$3"
  shift 3
  local pid status marker
  local -a environment
  todo3_setup_fixture "$name" || return 2
  todo3_snapshot "$TODO3_FIXTURE/before" || return 2
  marker="$TODO3_FIXTURE/$marker_name"
  mapfile -t environment < <(fixture_env "$TODO3_FIXTURE")
  /usr/bin/python3 -c 'import os, signal, sys; os.setsid(); signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvpe(sys.argv[1], sys.argv[1:], os.environ)' env \
    "${environment[@]}" \
    TODO3_GIT_DELAY_MARKER="$TODO3_FIXTURE/git-delay.marker" \
    BACKUP_HOST=testbox \
    BACKUP_PUSH=0 \
    "$@" \
    bash "$TODO3_REPO/scripts/backup.sh" >"$TODO3_FIXTURE/signal.log" 2>&1 &
  pid=$!
  ACTIVE_GROUPS+=("$pid")
  if ! todo3_wait_for_marker "$marker"; then
    if [[ -f "$TODO3_FIXTURE/signal.log" ]]; then
      while IFS= read -r line; do
        say_error "$line"
      done <"$TODO3_FIXTURE/signal.log"
    fi
    terminate_process_group "$pid"
    wait "$pid" 2>/dev/null || true
    ACTIVE_GROUPS=()
    return 2
  fi
  kill -"$signal_name" -- "-$pid" 2>/dev/null || true
  wait "$pid"
  status=$?
  ACTIVE_GROUPS=()
  [[ "$status" -ne 0 ]] || { say_error "$name ignored $signal_name"; return 2; }
  todo3_snapshot "$TODO3_FIXTURE/after" || return 2
  todo3_assert_snapshot_equal "$TODO3_FIXTURE/before" "$TODO3_FIXTURE/after" || return 2
  [[ ! -e "$TODO3_STATE" ]] || { say_error "$name left prepared state after interruption"; return 2; }
}

scenario_interrupt_tar_todo3() {
  todo3_signal_scenario interrupt-tar INT tar-delay.marker LOCAL_BACKUP_TEST_TAR_DELAY=60
}

scenario_interrupt_age_todo3() {
  todo3_signal_scenario interrupt-age TERM age-delay.marker FAKE_AGE_DELAY=60
}

scenario_interrupt_checksum_todo3() {
  todo3_signal_scenario interrupt-checksum HUP sha256-delay.marker FAKE_SHA256_DELAY=60
}

scenario_interrupt_manifest_todo3() {
  todo3_signal_scenario interrupt-manifest INT python-delay.marker FAKE_PYTHON_DELAY=60 FAKE_PYTHON_DELAY_MATCH=timestamp_utc
}

scenario_interrupt_install_todo3() {
  todo3_signal_scenario interrupt-install TERM install-delay.marker FAKE_INSTALL_DELAY=60
}

scenario_interrupt_state_todo3() {
  todo3_signal_scenario interrupt-state HUP python-delay.marker FAKE_PYTHON_DELAY=60 FAKE_PYTHON_DELAY_MATCH=publication
}

scenario_interrupt_stage_todo3() {
  todo3_signal_scenario interrupt-stage TERM git-delay.marker TODO3_GIT_MODE=stage-delay TODO3_GIT_DELAY=60
}
