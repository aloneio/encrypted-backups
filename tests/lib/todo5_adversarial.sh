#!/usr/bin/env bash

todo5_snapshot_prepared() {
  local prefix="$1"
  todo5_inventory "$prefix.inventory"
  /usr/bin/git -C "$TODO5_REPO" write-tree >"$prefix.index"
  /usr/bin/git -C "$TODO5_REPO" rev-parse HEAD >"$prefix.head"
  /usr/bin/sha256sum "$TODO5_STATE" >"$prefix.state"
}

todo5_assert_prepared_snapshot() {
  local before="$1" after="$2"
  cmp -s "$before.inventory" "$after.inventory" || return 2
  cmp -s "$before.index" "$after.index" || return 2
  cmp -s "$before.head" "$after.head" || return 2
  cmp -s "$before.state" "$after.state" || return 2
}

todo5_journal_publication_tree() {
  local repo="$1" journal="$2" publication_index expected_tree
  local -a values=()
  mapfile -d '' -t values < <(/usr/bin/python3 - "$journal" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(state["index_tree"], end="\0")
for item in state["retention"]:
    for key in ("archive", "checksum", "manifest"):
        print(item[key], end="\0")
PY
  ) || return 2
  [[ ${#values[@]} -gt 1 ]] || return 2
  publication_index="$(mktemp "${journal%/*}/.publication-index.XXXXXX")" || return 2
  GIT_INDEX_FILE="$publication_index" /usr/bin/git -C "$repo" read-tree "${values[0]}" || { rm -f -- "$publication_index"; return 2; }
  GIT_INDEX_FILE="$publication_index" /usr/bin/git -C "$repo" update-index --remove -- "${values[@]:1}" || { rm -f -- "$publication_index"; return 2; }
  expected_tree="$(GIT_INDEX_FILE="$publication_index" /usr/bin/git -C "$repo" write-tree)" || { rm -f -- "$publication_index"; return 2; }
  rm -f -- "$publication_index"
  printf '%s\n' "$expected_tree"
}

scenario_retention_prepare_failure() {
  todo5_setup prepare-failure || return 2
  todo5_seed_mixed_hosts
  todo5_finalize_setup || return 2
  todo5_inventory "$TODO5_FIXTURE/before.inventory"
  /usr/bin/git -C "$TODO5_REPO" write-tree >"$TODO5_FIXTURE/before.index"
  /usr/bin/git -C "$TODO5_REPO" rev-parse HEAD >"$TODO5_FIXTURE/before.head"
  if todo5_run "$TODO5_FIXTURE/fail-prepare.log" FAKE_TAR_MODE=partial BACKUP_PUSH=0 bash "$TODO5_REPO/scripts/backup.sh"; then return 2; fi
  todo5_inventory "$TODO5_FIXTURE/after.inventory"
  /usr/bin/git -C "$TODO5_REPO" write-tree >"$TODO5_FIXTURE/after.index"
  /usr/bin/git -C "$TODO5_REPO" rev-parse HEAD >"$TODO5_FIXTURE/after.head"
  cmp -s "$TODO5_FIXTURE/before.inventory" "$TODO5_FIXTURE/after.inventory" || return 2
  cmp -s "$TODO5_FIXTURE/before.index" "$TODO5_FIXTURE/after.index" || return 2
  cmp -s "$TODO5_FIXTURE/before.head" "$TODO5_FIXTURE/after.head" || return 2
  [[ ! -e "$TODO5_STATE" ]] || return 2
}

todo5_install_precommit_failure_wrapper() {
  cat >"$TODO5_FIXTURE/bin/git" <<'EOF'
#!/usr/bin/env bash
set -u
args=("$@")
if [[ "${args[0]:-}" == -C ]]; then args=("${args[@]:2}"); fi
if [[ "${args[0]:-}" == diff && " ${args[*]} " == *' --cached --name-only -z '* ]]; then
  count=0
  [[ -f "${TODO5_DIFF_COUNTER:?}" ]] && count="$(<"$TODO5_DIFF_COUNTER")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$TODO5_DIFF_COUNTER"
  /usr/bin/git "$@"
  status=$?
  if [[ "$count" -eq 3 ]]; then printf 'README.md\0'; fi
  exit "$status"
fi
exec /usr/bin/git "$@"
EOF
  chmod +x "$TODO5_FIXTURE/bin/git"
}

scenario_retention_precommit_failure() {
  todo5_setup precommit-failure || return 2
  todo5_seed_mixed_hosts
  todo5_finalize_setup || return 2
  todo5_prepare || return 2
  todo5_snapshot_prepared "$TODO5_FIXTURE/before"
  todo5_install_precommit_failure_wrapper
  if todo5_run "$TODO5_FIXTURE/precommit.log" TODO5_DIFF_COUNTER="$TODO5_FIXTURE/diff.counter" bash "$TODO5_REPO/scripts/publish-prepared.sh"; then return 2; fi
  todo5_snapshot_prepared "$TODO5_FIXTURE/after"
  todo5_assert_prepared_snapshot "$TODO5_FIXTURE/before" "$TODO5_FIXTURE/after" || return 2
  [[ -z "$(compgen -G '/tmp/local-backup-push-kit-retention.*' || true)" ]] || return 2
}

todo5_mutate_retention_state() {
  local mutation="$1"
  /usr/bin/python3 - "$TODO5_STATE" "$TODO5_FIXTURE/pristine.state" "$mutation" <<'PY'
import json
import pathlib
import sys

destination = pathlib.Path(sys.argv[1])
state = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
mutation = sys.argv[3]
artifact = state["publication"]["artifact_id"]
first = state["retention_deletions"][:3]
second = state["retention_deletions"][3:6]
if mutation == "cross-host":
    value = "2025-01-01T00-00-00Z"
    state["retention_deletions"] = [
        f"backups/host-b/{value}.tar.zst.age",
        f"backups/host-b/{value}.sha256",
        f"manifests/host-b/{value}.json",
    ]
elif mutation == "traversal":
    state["retention_deletions"] = ["backups/testbox/../escape.tar.zst.age", *first[1:]]
elif mutation == "incomplete":
    state["retention_deletions"] = first[:1]
elif mutation == "current":
    state["retention_deletions"] = [
        f"backups/testbox/{artifact}.tar.zst.age",
        f"backups/testbox/{artifact}.sha256",
        f"manifests/testbox/{artifact}.json",
    ]
elif mutation == "unsorted":
    state["retention_deletions"] = [*second, *first]
elif mutation == "duplicate":
    state["retention_deletions"] = [*first, *first]
else:
    raise SystemExit("unknown mutation")
destination.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

scenario_retention_state_tamper() {
  local mutation
  todo5_setup state-tamper || return 2
  todo5_seed_mixed_hosts
  todo5_finalize_setup || return 2
  todo5_prepare || return 2
  /bin/cp -p -- "$TODO5_STATE" "$TODO5_FIXTURE/pristine.state"
  todo5_inventory "$TODO5_FIXTURE/before.inventory"
  /usr/bin/git -C "$TODO5_REPO" write-tree >"$TODO5_FIXTURE/before.index"
  /usr/bin/git -C "$TODO5_REPO" rev-parse HEAD >"$TODO5_FIXTURE/before.head"
  for mutation in cross-host traversal incomplete current unsorted duplicate; do
    todo5_mutate_retention_state "$mutation"
    if todo5_run "$TODO5_FIXTURE/tamper-$mutation.log" bash "$TODO5_REPO/scripts/publish-prepared.sh"; then return 2; fi
    todo5_inventory "$TODO5_FIXTURE/after.inventory"
    /usr/bin/git -C "$TODO5_REPO" write-tree >"$TODO5_FIXTURE/after.index"
    /usr/bin/git -C "$TODO5_REPO" rev-parse HEAD >"$TODO5_FIXTURE/after.head"
    cmp -s "$TODO5_FIXTURE/before.inventory" "$TODO5_FIXTURE/after.inventory" || return 2
    cmp -s "$TODO5_FIXTURE/before.index" "$TODO5_FIXTURE/after.index" || return 2
    cmp -s "$TODO5_FIXTURE/before.head" "$TODO5_FIXTURE/after.head" || return 2
    /bin/cp -p -- "$TODO5_FIXTURE/pristine.state" "$TODO5_STATE"
  done
}

scenario_retention_count_one() {
  todo5_setup count-one || return 2
  todo5_seed_mixed_hosts
  todo5_finalize_setup || return 2
  todo5_run "$TODO5_FIXTURE/prepare.log" BACKUP_RETENTION_COUNT=1 BACKUP_PUSH=0 bash "$TODO5_REPO/scripts/backup.sh" || return 2
  /usr/bin/python3 - "$TODO5_STATE" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert len(state["retention_deletions"]) == 12
PY
  todo5_run "$TODO5_FIXTURE/publish.log" BACKUP_RETENTION_COUNT=1 bash "$TODO5_REPO/scripts/publish-prepared.sh" || return 2
  [[ "$(find "$TODO5_REPO/backups/testbox" -maxdepth 1 -type f -name '*.tar.zst.age' | wc -l)" == 1 ]] || return 2
  [[ "$(find "$TODO5_REPO/backups/host-b" -maxdepth 1 -type f -name '*.tar.zst.age' | wc -l)" == 2 ]] || return 2
}

todo5_finalize_two_remotes() {
  TODO5_MIRROR="$TODO5_FIXTURE/mirror.git"
  todo4_write_config "$TODO5_REPO" "$TODO5_DATA" main canonical mirror
  init_real_repo "$TODO5_REPO" || return 2
  /usr/bin/git init -q --bare "$TODO5_CANONICAL" || return 2
  /usr/bin/git init -q --bare "$TODO5_MIRROR" || return 2
  /usr/bin/git -C "$TODO5_REPO" remote add canonical "$TODO5_CANONICAL" || return 2
  /usr/bin/git -C "$TODO5_REPO" remote add mirror "$TODO5_MIRROR" || return 2
  /usr/bin/git -C "$TODO5_REPO" push -q canonical HEAD:refs/heads/main || return 2
  /usr/bin/git -C "$TODO5_REPO" push -q mirror HEAD:refs/heads/main || return 2
  TODO5_STATE="$TODO5_REPO/.git/local-backup-push-kit/prepared/testbox.state"
}

scenario_retention_parent_recovery() {
  local base committed parent tar_count relative
  local -a deletions=()
  todo5_setup parent-recovery || return 2
  todo5_seed_mixed_hosts
  todo5_finalize_two_remotes || return 2
  todo5_prepare || return 2
  mapfile -t deletions < <(/usr/bin/python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1], encoding="utf-8"))["retention_deletions"]))' "$TODO5_STATE")
  base="$(/usr/bin/git -C "$TODO5_REPO" rev-parse HEAD)"
  tar_count="$(wc -l <"$TODO5_FIXTURE/tar.log")"
  TODO4_FIXTURE="$TODO5_FIXTURE"
  todo4_install_git_wrapper
  if todo5_run "$TODO5_FIXTURE/first-publish.log" TODO4_GIT_LOG="$TODO5_FIXTURE/git4.log" TODO4_FAIL_REMOTE=mirror TODO4_FAIL_MARKER="$TODO5_FIXTURE/fail-once" bash "$TODO5_REPO/scripts/publish-prepared.sh"; then return 2; fi
  committed="$(/usr/bin/git -C "$TODO5_REPO" rev-parse HEAD)"
  parent="$(/usr/bin/git -C "$TODO5_REPO" rev-parse "$committed^")"
  [[ "$parent" == "$base" ]] || return 2
  [[ "$(todo4_remote_oid "$TODO5_CANONICAL" main)" == "$committed" ]] || return 2
  [[ "$(todo4_remote_oid "$TODO5_MIRROR" main)" == "$base" ]] || return 2
  for relative in "${deletions[@]}"; do
    /usr/bin/git -C "$TODO5_REPO" cat-file -e "$parent:$relative" || return 2
    if /usr/bin/git -C "$TODO5_REPO" cat-file -e "$committed:$relative" 2>/dev/null; then return 2; fi
  done
  /usr/bin/python3 - "$TODO5_STATE" "$committed" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert state["committed_oid"] == sys.argv[2]
assert state["publication"]["remotes"][0]["status"] == "published"
assert state["publication"]["remotes"][1]["status"] == "failed"
PY
  todo5_run "$TODO5_FIXTURE/retry.log" TODO4_GIT_LOG="$TODO5_FIXTURE/git4.log" TODO4_FAIL_REMOTE=mirror TODO4_FAIL_MARKER="$TODO5_FIXTURE/fail-once" bash "$TODO5_REPO/scripts/publish-prepared.sh" || return 2
  [[ "$(/usr/bin/git -C "$TODO5_REPO" rev-parse HEAD)" == "$committed" ]] || return 2
  [[ "$(todo4_remote_oid "$TODO5_MIRROR" main)" == "$committed" ]] || return 2
  [[ ! -e "$TODO5_STATE" && "$(wc -l <"$TODO5_FIXTURE/tar.log")" == "$tar_count" ]] || return 2
}

scenario_retention_unproven_advanced_recovery() {
  local publication_pid status recovery_dir base tree unsafe
  local -a environment=()
  todo5_setup unproven-advanced-recovery || return 2
  todo5_seed_mixed_hosts
  todo5_finalize_setup || return 2
  todo5_prepare || return 2
  todo5_install_hung_commit_wrapper
  mapfile -t environment < <(fixture_env "$TODO5_FIXTURE")
  setsid env "${environment[@]}" \
    TODO5_HANG_MARKER="$TODO5_FIXTURE/hang.marker" \
    BACKUP_HOST=testbox BACKUP_RETENTION_COUNT=3 \
    bash "$TODO5_REPO/scripts/publish-prepared.sh" >"$TODO5_FIXTURE/killed.log" 2>&1 &
  publication_pid=$!
  ACTIVE_GROUPS+=("$publication_pid")
  todo5_wait_for_hang_marker "$TODO5_FIXTURE/hang.marker" || return 2
  kill -KILL -- "-$publication_pid" 2>/dev/null || true
  wait "$publication_pid"; status=$?
  ACTIVE_GROUPS=()
  [[ "$status" -ne 0 ]] || return 2
  recovery_dir="$TODO5_REPO/.git/local-backup-push-kit/recovery/retention/testbox"
  [[ -f "$recovery_dir/journal" ]] || return 2
  rm -f -- "$TODO5_FIXTURE/bin/git"
  base="$(/usr/bin/git -C "$TODO5_REPO" rev-parse HEAD)"
  tree="$(/usr/bin/git -C "$TODO5_REPO" rev-parse 'HEAD^{tree}')"
  unsafe="$(printf 'unsafe recovery child\n' | GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid /usr/bin/git -C "$TODO5_REPO" commit-tree "$tree" -p "$base")" || return 2
  /usr/bin/git -C "$TODO5_REPO" update-ref refs/heads/main "$unsafe" "$base" || return 2
  if todo5_publish; then return 2; fi
  grep -Fq 'retention recovery state is unknown; journal preserved' "$TODO5_FIXTURE/publish.log" || return 2
  [[ -f "$recovery_dir/journal" ]]
}

scenario_retention_replace_ref_recovery() {
  local publication_pid status recovery_dir base expected_tree artifact archive checksum manifest digest actual expected
  local -a environment=()
  todo5_setup replace-ref-recovery || return 2
  todo5_seed_mixed_hosts
  todo5_finalize_setup || return 2
  todo5_prepare || return 2
  todo5_install_hung_commit_wrapper
  mapfile -t environment < <(fixture_env "$TODO5_FIXTURE")
  setsid env "${environment[@]}" \
    TODO5_HANG_MARKER="$TODO5_FIXTURE/hang.marker" \
    BACKUP_HOST=testbox BACKUP_RETENTION_COUNT=3 \
    bash "$TODO5_REPO/scripts/publish-prepared.sh" >"$TODO5_FIXTURE/killed.log" 2>&1 &
  publication_pid=$!
  ACTIVE_GROUPS+=("$publication_pid")
  todo5_wait_for_hang_marker "$TODO5_FIXTURE/hang.marker" || return 2
  kill -KILL -- "-$publication_pid" 2>/dev/null || true
  wait "$publication_pid"; status=$?
  ACTIVE_GROUPS=()
  [[ "$status" -ne 0 ]] || return 2
  recovery_dir="$TODO5_REPO/.git/local-backup-push-kit/recovery/retention/testbox"
  [[ -f "$recovery_dir/journal" ]] || return 2
  rm -f -- "$TODO5_FIXTURE/bin/git"
  base="$(/usr/bin/git -C "$TODO5_REPO" rev-parse HEAD)"
  expected_tree="$(todo5_journal_publication_tree "$TODO5_REPO" "$recovery_dir/journal")" || return 2
  artifact="$(/usr/bin/python3 - "$TODO5_STATE" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["publication"]["artifact_id"])
PY
)" || return 2
  archive="backups/testbox/${artifact}.tar.zst.age"
  checksum="backups/testbox/${artifact}.sha256"
  manifest="manifests/testbox/${artifact}.json"
  printf 'alternate encrypted publication\n' >"$TODO5_REPO/$archive"
  digest="$(sha256sum "$TODO5_REPO/$archive" | cut -d ' ' -f 1)"
  printf '%s  %s\n' "$digest" "$archive" >"$TODO5_REPO/$checksum"
  printf '{"host_id":"testbox","timestamp_utc":"%s","encrypted_archive":"%s","encrypted_archive_sha256":"%s"}\n' \
    "$artifact" "$archive" "$digest" >"$TODO5_REPO/$manifest"
  /usr/bin/git -C "$TODO5_REPO" add -- "$archive" "$checksum" "$manifest"
  actual="$(printf 'Add testbox encrypted backup %s\n' "$artifact" | GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid /usr/bin/git -C "$TODO5_REPO" commit-tree "$(/usr/bin/git -C "$TODO5_REPO" write-tree)" -p "$base")" || return 2
  expected="$(printf 'Add testbox encrypted backup %s\n' "$artifact" | GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid /usr/bin/git -C "$TODO5_REPO" commit-tree "$expected_tree" -p "$base")" || return 2
  /usr/bin/git -C "$TODO5_REPO" checkout "$expected_tree" -- "$archive" "$checksum" "$manifest" backups/testbox/latest.txt || return 2
  /usr/bin/git -C "$TODO5_REPO" update-ref refs/heads/main "$actual" "$base" || return 2
  /usr/bin/git -C "$TODO5_REPO" replace "$actual" "$expected" || return 2
  [[ "$(/usr/bin/git -C "$TODO5_REPO" rev-parse --verify "$actual^{tree}")" == "$expected_tree" ]] || return 2
  [[ "$(/usr/bin/git -C "$TODO5_REPO" --no-replace-objects rev-parse --verify "$actual^{tree}")" != "$expected_tree" ]] || return 2
  REPO_DIR="$TODO5_REPO" bash -c 'source "$0"; publication_commit_shape_valid "$1"' "$TODO5_REPO/scripts/lib/publication-schema.sh" "$actual" || return 2
  if env "${environment[@]}" REPO_DIR="$TODO5_REPO" HOST_ID=testbox PUSH_BRANCH=main PREPARED_STATE_FILE="$TODO5_STATE" bash -c 'source "$1"; source "$2"; source "$3"; source "$4"; recover_pending_retention_transaction' _ \
    "$TODO5_REPO/scripts/lib/common.sh" "$TODO5_REPO/scripts/lib/retention.sh" "$TODO5_REPO/scripts/lib/prepare.sh" "$TODO5_REPO/scripts/lib/publication-schema.sh" >"$TODO5_FIXTURE/recovery.log" 2>&1; then return 2; fi
  grep -Fq 'retention recovery state is unknown; journal preserved' "$TODO5_FIXTURE/recovery.log" || return 2
  [[ -f "$recovery_dir/journal" ]]
}

scenario_retention_deleted_path_read_failure() {
  local publication_pid status recovery_dir base expected_tree artifact expected
  local -a environment=()
  todo5_setup deleted-path-read-failure || return 2
  todo5_seed_mixed_hosts
  todo5_finalize_setup || return 2
  todo5_prepare || return 2
  todo5_install_hung_commit_wrapper
  mapfile -t environment < <(fixture_env "$TODO5_FIXTURE")
  setsid env "${environment[@]}" \
    TODO5_HANG_MARKER="$TODO5_FIXTURE/hang.marker" \
    BACKUP_HOST=testbox BACKUP_RETENTION_COUNT=3 \
    bash "$TODO5_REPO/scripts/publish-prepared.sh" >"$TODO5_FIXTURE/killed.log" 2>&1 &
  publication_pid=$!
  ACTIVE_GROUPS+=("$publication_pid")
  todo5_wait_for_hang_marker "$TODO5_FIXTURE/hang.marker" || return 2
  kill -KILL -- "-$publication_pid" 2>/dev/null || true
  wait "$publication_pid"; status=$?
  ACTIVE_GROUPS=()
  [[ "$status" -ne 0 ]] || return 2
  recovery_dir="$TODO5_REPO/.git/local-backup-push-kit/recovery/retention/testbox"
  [[ -f "$recovery_dir/journal" ]] || return 2
  rm -f -- "$TODO5_FIXTURE/bin/git"
  base="$(/usr/bin/git -C "$TODO5_REPO" rev-parse HEAD)"
  expected_tree="$(todo5_journal_publication_tree "$TODO5_REPO" "$recovery_dir/journal")" || return 2
  artifact="$(/usr/bin/python3 - "$TODO5_STATE" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["publication"]["artifact_id"])
PY
)" || return 2
  expected="$(printf 'Add testbox encrypted backup %s\n' "$artifact" | GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid /usr/bin/git -C "$TODO5_REPO" commit-tree "$expected_tree" -p "$base")" || return 2
  /usr/bin/git -C "$TODO5_REPO" update-ref refs/heads/main "$expected" "$base" || return 2
  cat >"$TODO5_FIXTURE/bin/git" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  [[ "$argument" == ls-tree ]] && exit 75
done
exec /usr/bin/git "$@"
EOF
  chmod +x "$TODO5_FIXTURE/bin/git"
  if env "${environment[@]}" REPO_DIR="$TODO5_REPO" HOST_ID=testbox PUSH_BRANCH=main PREPARED_STATE_FILE="$TODO5_STATE" bash -c 'source "$1"; source "$2"; source "$3"; source "$4"; recover_pending_retention_transaction' _ \
    "$TODO5_REPO/scripts/lib/common.sh" "$TODO5_REPO/scripts/lib/retention.sh" "$TODO5_REPO/scripts/lib/prepare.sh" "$TODO5_REPO/scripts/lib/publication-schema.sh" >"$TODO5_FIXTURE/recovery.log" 2>&1; then return 2; fi
  grep -Fq 'retention recovery cannot verify deleted path; journal preserved' "$TODO5_FIXTURE/recovery.log" || return 2
  [[ -f "$recovery_dir/journal" ]]
}

scenario_retention_head_read_failures() {
  local mode publication_pid status recovery_dir
  local -a environment=()
  for mode in unreadable invalid; do
    todo5_setup "head-read-$mode" || return 2
    todo5_seed_mixed_hosts
    todo5_finalize_setup || return 2
    todo5_prepare || return 2
    todo5_install_hung_commit_wrapper
    mapfile -t environment < <(fixture_env "$TODO5_FIXTURE")
    setsid env "${environment[@]}" \
      TODO5_HANG_MARKER="$TODO5_FIXTURE/hang.marker" \
      BACKUP_HOST=testbox BACKUP_RETENTION_COUNT=3 \
      bash "$TODO5_REPO/scripts/publish-prepared.sh" >"$TODO5_FIXTURE/killed.log" 2>&1 &
    publication_pid=$!
    ACTIVE_GROUPS+=("$publication_pid")
    todo5_wait_for_hang_marker "$TODO5_FIXTURE/hang.marker" || return 2
    kill -KILL -- "-$publication_pid" 2>/dev/null || true
    wait "$publication_pid"; status=$?
    ACTIVE_GROUPS=()
    [[ "$status" -ne 0 ]] || return 2
    recovery_dir="$TODO5_REPO/.git/local-backup-push-kit/recovery/retention/testbox"
    [[ -f "$recovery_dir/journal" ]] || return 2
    cat >"$TODO5_FIXTURE/bin/git" <<EOF
#!/usr/bin/env bash
for argument in "\$@"; do
  [[ "\$argument" == rev-parse ]] || continue
  if [[ "$mode" == unreadable ]]; then exit 75; fi
  printf '%s\\n' not-an-oid
  exit 0
done
exec /usr/bin/git "\$@"
EOF
    chmod +x "$TODO5_FIXTURE/bin/git"
    if env "${environment[@]}" REPO_DIR="$TODO5_REPO" HOST_ID=testbox PUSH_BRANCH=main PREPARED_STATE_FILE="$TODO5_STATE" bash -c 'source "$1"; source "$2"; source "$3"; source "$4"; recover_pending_retention_transaction' _ \
      "$TODO5_REPO/scripts/lib/common.sh" "$TODO5_REPO/scripts/lib/retention.sh" "$TODO5_REPO/scripts/lib/prepare.sh" "$TODO5_REPO/scripts/lib/publication-schema.sh" >"$TODO5_FIXTURE/recovery.log" 2>&1; then return 2; fi
    if [[ "$mode" == unreadable ]]; then
      grep -Fq 'retention recovery cannot read HEAD; journal preserved' "$TODO5_FIXTURE/recovery.log" || return 2
    else
      grep -Fq 'retention recovery state is unknown; journal preserved' "$TODO5_FIXTURE/recovery.log" || return 2
    fi
    [[ -f "$recovery_dir/journal" ]] || return 2
  done
}

scenario_retention_journal_cross_binding() {
  local mutation publication_pid status recovery_dir base_tree
  local -a environment=()
  for mutation in prepared-hash publication retention payload index paired-paths paired-artifact boolean-state legacy-state malformed-state; do
    todo5_setup "journal-cross-$mutation" || return 2
    todo5_seed_mixed_hosts
    todo5_finalize_setup || return 2
    todo5_prepare || return 2
    todo5_install_hung_commit_wrapper
    mapfile -t environment < <(fixture_env "$TODO5_FIXTURE")
    setsid env "${environment[@]}" TODO5_HANG_MARKER="$TODO5_FIXTURE/hang.marker" BACKUP_HOST=testbox BACKUP_RETENTION_COUNT=3 \
      bash "$TODO5_REPO/scripts/publish-prepared.sh" >"$TODO5_FIXTURE/killed.log" 2>&1 &
    publication_pid=$!
    ACTIVE_GROUPS+=("$publication_pid")
    todo5_wait_for_hang_marker "$TODO5_FIXTURE/hang.marker" || return 2
    kill -KILL -- "-$publication_pid" 2>/dev/null || true
    wait "$publication_pid"; status=$?
    ACTIVE_GROUPS=()
    [[ "$status" -ne 0 ]] || return 2
    recovery_dir="$TODO5_REPO/.git/local-backup-push-kit/recovery/retention/testbox"
    [[ -f "$recovery_dir/journal" ]] || return 2
    base_tree="$(/usr/bin/git -C "$TODO5_REPO" rev-parse 'HEAD^{tree}')" || return 2
    /usr/bin/python3 - "$recovery_dir/journal" "$TODO5_STATE" "$mutation" "$base_tree" <<'PY'
import hashlib, json, pathlib, sys
journal_path = pathlib.Path(sys.argv[1])
state_path = pathlib.Path(sys.argv[2])
mutation = sys.argv[3]
base_tree = sys.argv[4]
journal = json.loads(journal_path.read_text(encoding="utf-8"))
state = json.loads(state_path.read_text(encoding="utf-8"))
if mutation == "prepared-hash":
    journal["prepared_hashes"][journal["prepared_paths"][0]] = "0" * 64
elif mutation == "publication":
    artifact = "2026-01-03T00-00-00Z"
    paths = [f"backups/testbox/{artifact}.tar.zst.age", f"backups/testbox/{artifact}.sha256", f"manifests/testbox/{artifact}.json", "backups/testbox/latest.txt"]
    journal["commit_message"] = f"Add testbox encrypted backup {artifact}"
    journal["prepared_paths"] = paths
    journal["prepared_hashes"] = {path: "0" * 64 for path in paths}
elif mutation == "retention":
    ids = ["2026-01-01T00-00-01Z", "2026-01-01T00-00-02Z-000000001"]
    journal["retention"] = [{"archive": f"backups/testbox/{value}.tar.zst.age", "checksum": f"backups/testbox/{value}.sha256", "manifest": f"manifests/testbox/{value}.json"} for value in ids]
    journal["payload"] = [{"path": item[key], "sha256": "0" * 64, "mode": "644"} for item in journal["retention"] for key in ("archive", "checksum", "manifest")]
elif mutation == "payload":
    journal["payload"][0]["sha256"] = "0" * 64
elif mutation == "index":
    journal["index_tree"] = base_tree
elif mutation == "paired-paths":
    state["paths"]["latest"] = "backups/testbox/alternate-latest.txt"
    state_path.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
    journal["prepared_state_sha256"] = hashlib.sha256(state_path.read_bytes()).hexdigest()
elif mutation == "paired-artifact":
    state["publication"]["artifact_id"] = "2026-01-03T00-00-00Z"
    state_path.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
    journal["prepared_state_sha256"] = hashlib.sha256(state_path.read_bytes()).hexdigest()
elif mutation == "boolean-state":
    state["version"] = True
    state_path.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
    journal["prepared_state_sha256"] = hashlib.sha256(state_path.read_bytes()).hexdigest()
elif mutation == "legacy-state":
    state["version"] = 0
    state_path.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
    journal["prepared_state_sha256"] = hashlib.sha256(state_path.read_bytes()).hexdigest()
elif mutation == "malformed-state":
    state_path.write_text("{\n", encoding="utf-8")
    journal["prepared_state_sha256"] = hashlib.sha256(state_path.read_bytes()).hexdigest()
else:
    raise SystemExit(1)
journal_path.write_text(json.dumps(journal, sort_keys=True) + "\n", encoding="utf-8")
PY
    if env "${environment[@]}" REPO_DIR="$TODO5_REPO" HOST_ID=testbox PUSH_BRANCH=main PREPARED_STATE_FILE="$TODO5_STATE" bash -c 'source "$1"; source "$2"; source "$3"; source "$4"; recover_pending_retention_transaction' _ \
      "$TODO5_REPO/scripts/lib/common.sh" "$TODO5_REPO/scripts/lib/retention.sh" "$TODO5_REPO/scripts/lib/prepare.sh" "$TODO5_REPO/scripts/lib/publication-schema.sh" >"$TODO5_FIXTURE/recovery.log" 2>&1; then return 2; fi
    [[ -f "$recovery_dir/journal" ]] || return 2
  done
}

scenario_retention_retry_state() { scenario_retention_parent_recovery; }

todo5_install_hung_commit_wrapper() {
  cat >"$TODO5_FIXTURE/bin/git" <<'EOF'
#!/usr/bin/env bash
set -u
args=("$@")
if [[ "${args[0]:-}" == -C ]]; then args=("${args[@]:2}"); fi
if [[ "${args[0]:-}" == commit ]]; then
  : >"${TODO5_HANG_MARKER:?}"
  /bin/sleep 60
  exit 99
fi
exec /usr/bin/git "$@"
EOF
  chmod +x "$TODO5_FIXTURE/bin/git"
}

todo5_wait_for_hang_marker() {
  local marker="$1" attempt
  for attempt in {1..100}; do
    [[ -f "$marker" ]] && return 0
    /bin/sleep 0.1
  done
  return 1
}

scenario_retention_interrupt_precommit() {
  local round status publication_pid
  local -a environment=()
  todo5_setup interrupt-precommit || return 2
  todo5_seed_mixed_hosts
  todo5_finalize_setup || return 2
  todo5_prepare || return 2
  todo5_snapshot_prepared "$TODO5_FIXTURE/before"
  todo5_install_hung_commit_wrapper
  mapfile -t environment < <(fixture_env "$TODO5_FIXTURE")
  for round in 1 2 3; do
    rm -f -- "$TODO5_FIXTURE/hang.marker"
    setsid env \
      "${environment[@]}" \
      TODO5_HANG_MARKER="$TODO5_FIXTURE/hang.marker" \
      BACKUP_HOST=testbox BACKUP_RETENTION_COUNT=3 \
      bash "$TODO5_REPO/scripts/publish-prepared.sh" >"$TODO5_FIXTURE/interrupt-$round.log" 2>&1 &
    publication_pid=$!
    ACTIVE_GROUPS+=("$publication_pid")
    if ! todo5_wait_for_hang_marker "$TODO5_FIXTURE/hang.marker"; then
      terminate_process_group "$publication_pid"
      wait "$publication_pid" 2>/dev/null || true
      ACTIVE_GROUPS=()
      say_error "retention precommit hang marker did not appear within 10s"
      return 2
    fi
    terminate_process_group "$publication_pid"
    wait "$publication_pid"; status=$?
    ACTIVE_GROUPS=()
    [[ "$status" -ne 0 && -f "$TODO5_FIXTURE/hang.marker" ]] || return 2
    process_group_alive "$publication_pid" && return 2
    todo5_snapshot_prepared "$TODO5_FIXTURE/after-$round"
    todo5_assert_prepared_snapshot "$TODO5_FIXTURE/before" "$TODO5_FIXTURE/after-$round" || return 2
  done
  [[ -z "$(compgen -G '/tmp/local-backup-push-kit-retention.*' || true)" ]] || return 2
}

todo5_install_postcommit_wrapper() {
  cat >"$TODO5_FIXTURE/bin/git" <<'EOF'
#!/usr/bin/env bash
set -u
args=("$@")
if [[ "${args[0]:-}" == -C ]]; then args=("${args[@]:2}"); fi
if [[ "${args[0]:-}" == commit ]]; then
  /usr/bin/git "$@"
  status=$?
  [[ "$status" -eq 0 ]] || exit "$status"
  /usr/bin/git -C "${TODO5_POSTCOMMIT_REPO:?}" rev-parse HEAD >"${TODO5_POSTCOMMIT_MARKER:?}"
  /bin/sleep 60
  exit 99
fi
exec /usr/bin/git "$@"
EOF
  chmod +x "$TODO5_FIXTURE/bin/git"
}

scenario_retention_interrupt_postcommit() {
  local base committed parent status publication_pid tar_count commit_count index_tree head_tree relative
  local -a environment=() deletions=()
  todo5_setup interrupt-postcommit || return 2
  todo5_seed_mixed_hosts
  todo5_finalize_two_remotes || return 2
  todo5_prepare || return 2
  mapfile -t deletions < <(/usr/bin/python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1], encoding="utf-8"))["retention_deletions"]))' "$TODO5_STATE")
  base="$(/usr/bin/git -C "$TODO5_REPO" rev-parse HEAD)"
  tar_count="$(wc -l <"$TODO5_FIXTURE/tar.log")"
  commit_count="$(/usr/bin/git -C "$TODO5_REPO" rev-list --count HEAD)"
  todo5_install_postcommit_wrapper
  mapfile -t environment < <(fixture_env "$TODO5_FIXTURE")
  setsid env "${environment[@]}" \
    TODO5_POSTCOMMIT_REPO="$TODO5_REPO" TODO5_POSTCOMMIT_MARKER="$TODO5_FIXTURE/postcommit.marker" \
    BACKUP_HOST=testbox BACKUP_RETENTION_COUNT=3 \
    bash "$TODO5_REPO/scripts/publish-prepared.sh" >"$TODO5_FIXTURE/postcommit.log" 2>&1 &
  publication_pid=$!
  ACTIVE_GROUPS+=("$publication_pid")
  todo5_wait_for_hang_marker "$TODO5_FIXTURE/postcommit.marker" || return 2
  terminate_process_group "$publication_pid"
  wait "$publication_pid"; status=$?
  ACTIVE_GROUPS=()
  [[ "$status" -eq 143 ]] || return 2
  process_group_alive "$publication_pid" && return 2
  committed="$(<"$TODO5_FIXTURE/postcommit.marker")"
  [[ "$(/usr/bin/git -C "$TODO5_REPO" rev-parse HEAD)" == "$committed" ]] || return 2
  parent="$(/usr/bin/git -C "$TODO5_REPO" rev-parse "$committed^")"
  [[ "$parent" == "$base" && "$(/usr/bin/git -C "$TODO5_REPO" rev-list --count HEAD)" -eq $((commit_count + 1)) ]] || return 2
  [[ "$(todo4_remote_oid "$TODO5_CANONICAL" main)" == "$base" && "$(todo4_remote_oid "$TODO5_MIRROR" main)" == "$base" ]] || return 2
  [[ -f "$TODO5_STATE" ]] || return 2
  index_tree="$(/usr/bin/git -C "$TODO5_REPO" write-tree)"
  head_tree="$(/usr/bin/git -C "$TODO5_REPO" rev-parse 'HEAD^{tree}')"
  if [[ -n "$(/usr/bin/git -C "$TODO5_REPO" status --porcelain=v1 --untracked-files=all)" || "$index_tree" != "$head_tree" ]]; then
    known_failure "post-commit signal restored precommit retention over advanced HEAD"
    return $?
  fi
  for relative in "${deletions[@]}"; do [[ ! -e "$TODO5_REPO/$relative" ]] || return 2; done
  [[ -z "$(compgen -G '/tmp/local-backup-push-kit-retention.*' || true)" ]] || return 2
  if compgen -G "$TODO5_REPO/.git/local-backup-push-kit/prepared/.testbox.publish.*" >/dev/null; then return 2; fi
  todo5_run "$TODO5_FIXTURE/retry-postcommit.log" \
    TODO5_POSTCOMMIT_REPO="$TODO5_REPO" TODO5_POSTCOMMIT_MARKER="$TODO5_FIXTURE/postcommit.marker" \
    bash "$TODO5_REPO/scripts/publish-prepared.sh" || return 2
  [[ "$(/usr/bin/git -C "$TODO5_REPO" rev-parse HEAD)" == "$committed" ]] || return 2
  [[ "$(/usr/bin/git -C "$TODO5_REPO" rev-list --count HEAD)" -eq $((commit_count + 1)) ]] || return 2
  [[ "$(todo4_remote_oid "$TODO5_CANONICAL" main)" == "$committed" && "$(todo4_remote_oid "$TODO5_MIRROR" main)" == "$committed" ]] || return 2
  [[ ! -e "$TODO5_STATE" && "$(wc -l <"$TODO5_FIXTURE/tar.log")" == "$tar_count" ]] || return 2
  [[ -z "$(/usr/bin/git -C "$TODO5_REPO" status --porcelain=v1 --untracked-files=all)" ]] || return 2
  [[ -z "$(compgen -G '/tmp/local-backup-push-kit-retention.*' || true)" ]] || return 2
}
