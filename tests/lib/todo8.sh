#!/usr/bin/env bash

todo8_write_config() {
  local repo="$1" data="$2"
  mkdir -p "$repo/hosts/testbox"
  cat >"$repo/hosts/testbox/backup.conf" <<EOF
CONFIG_HOST_ID="testbox"
AGE_RECIPIENT="$TEST_AGE_RECIPIENT"
BACKUP_BRANCH="main"
BACKUP_REMOTES=("canonical" "mirror")
BACKUP_PATHS=("$data")
EOF
}

todo8_setup() {
  local name="$1"
  new_fixture "todo8-$name" || return 2
  TODO8_FIXTURE="$FIXTURE"
  TODO8_REPO="$TODO8_FIXTURE/repo"
  TODO8_DATA="$TODO8_FIXTURE/data"
  TODO8_CANONICAL="$TODO8_FIXTURE/canonical.git"
  TODO8_MIRROR="$TODO8_FIXTURE/mirror.git"
  TODO8_SYSTEMD_DIR="$TODO8_FIXTURE/systemd"
  TODO8_STATE="$TODO8_REPO/.git/local-backup-push-kit/prepared/testbox.state"
  mkdir -p "$TODO8_DATA" "$TODO8_SYSTEMD_DIR"
  printf 'payload\n' >"$TODO8_DATA/payload.txt"
  copy_template "$TODO8_REPO"
  todo8_write_config "$TODO8_REPO" "$TODO8_DATA"
  init_real_repo "$TODO8_REPO" || return 2
  /usr/bin/git init -q --bare "$TODO8_CANONICAL" || return 2
  /usr/bin/git init -q --bare "$TODO8_MIRROR" || return 2
  /usr/bin/git -C "$TODO8_REPO" remote add canonical "$TODO8_CANONICAL" || return 2
  /usr/bin/git -C "$TODO8_REPO" remote add mirror "$TODO8_MIRROR" || return 2
  /usr/bin/git -C "$TODO8_REPO" push -q canonical HEAD:refs/heads/main || return 2
  /usr/bin/git -C "$TODO8_REPO" push -q mirror HEAD:refs/heads/main || return 2
}

todo8_write_legacy_set() {
  local artifact_id="$1" archive relative digest
  relative="backups/testbox/${artifact_id}.tar.zst.age"
  archive="$TODO8_REPO/$relative"
  mkdir -p "$TODO8_REPO/backups/testbox" "$TODO8_REPO/manifests/testbox"
  printf 'encrypted legacy %s\n' "$artifact_id" >"$archive"
  digest="$(/usr/bin/sha256sum "$archive" | cut -d ' ' -f 1)"
  printf '%s  %s\n' "$digest" "$relative" >"$TODO8_REPO/backups/testbox/${artifact_id}.sha256"
  printf '{"host_id":"testbox","timestamp_utc":"%s","encrypted_archive":"%s","encrypted_archive_sha256":"%s","included_paths":["%s"]}\n' \
    "$artifact_id" "$relative" "$digest" "$TODO8_DATA" >"$TODO8_REPO/manifests/testbox/${artifact_id}.json"
  printf '%s\n' "$relative" >"$TODO8_REPO/backups/testbox/latest.txt"
}

todo8_stage_legacy_set() {
  local artifact_id="$1"
  /usr/bin/git -C "$TODO8_REPO" add -- \
    "backups/testbox/${artifact_id}.tar.zst.age" \
    "backups/testbox/${artifact_id}.sha256" \
    "manifests/testbox/${artifact_id}.json" \
    backups/testbox/latest.txt
}

todo8_run() {
  local output="$1"
  shift
  run_captured "$output" 12 env \
    BACKUP_HOST=testbox \
    MIGRATION_SYSTEMD_DIR="$TODO8_SYSTEMD_DIR" \
    "$@"
}

todo8_snapshot() {
  local prefix="$1"
  /usr/bin/python3 - "$TODO8_REPO" "$prefix.files" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(root.rglob("*")):
    relative = path.relative_to(root)
    if relative.parts and relative.parts[0] == ".git":
        continue
    digest.update(str(relative).encode())
    digest.update(b"\0")
    if path.is_symlink():
        digest.update(b"link\0" + str(path.readlink()).encode())
    elif path.is_file():
        digest.update(b"file\0" + path.read_bytes())
    elif path.is_dir():
        digest.update(b"dir\0")
    digest.update(b"\0")
pathlib.Path(sys.argv[2]).write_text(digest.hexdigest() + "\n", encoding="utf-8")
PY
  /usr/bin/git -C "$TODO8_REPO" write-tree >"$prefix.index"
  /usr/bin/git -C "$TODO8_REPO" rev-parse HEAD >"$prefix.head"
  /usr/bin/git -C "$TODO8_REPO" for-each-ref --format='%(refname) %(objectname)' | LC_ALL=C sort >"$prefix.refs"
  if [[ -f "$TODO8_STATE" ]]; then
    /usr/bin/sha256sum "$TODO8_STATE" >"$prefix.state"
  else
    printf 'absent\n' >"$prefix.state"
  fi
}

todo8_assert_snapshot() {
  local before="$1" after="$2" suffix
  for suffix in files index head refs state; do
    cmp -s "$before.$suffix" "$after.$suffix" || return 2
  done
}

todo8_expect_report_issue() {
  local diagnostic="$1" output="$TODO8_FIXTURE/report.log"
  todo8_snapshot "$TODO8_FIXTURE/before"
  if todo8_run "$output" bash "$TODO8_REPO/scripts/migrate-legacy.sh"; then return 2; fi
  todo8_snapshot "$TODO8_FIXTURE/after"
  todo8_assert_snapshot "$TODO8_FIXTURE/before" "$TODO8_FIXTURE/after" || return 2
  grep -Fq "$diagnostic" "$output" || return 2
  grep -Fq 'RECOVERY:' "$output" || return 2
}

scenario_migration_report() {
  local before_hash after_hash
  todo8_setup report || return 2
  [[ ! -e "$TODO8_REPO/.git/local-backup-push-kit" ]] || return 2
  todo8_snapshot "$TODO8_FIXTURE/before"
  todo8_run "$TODO8_FIXTURE/report.log" bash "$TODO8_REPO/scripts/migrate-legacy.sh" || return 2
  todo8_snapshot "$TODO8_FIXTURE/after"
  todo8_assert_snapshot "$TODO8_FIXTURE/before" "$TODO8_FIXTURE/after" || return 2
  [[ ! -e "$TODO8_REPO/.git/local-backup-push-kit" ]] || return 2
  grep -Fq 'MIGRATION_STATUS=clean' "$TODO8_FIXTURE/report.log" || return 2
  before_hash="$(sha256sum "$TODO8_FIXTURE/before.files" "$TODO8_FIXTURE/before.index" "$TODO8_FIXTURE/before.head" "$TODO8_FIXTURE/before.refs" "$TODO8_FIXTURE/before.state" | cut -d ' ' -f 1 | sha256sum | cut -d ' ' -f 1)"
  after_hash="$(sha256sum "$TODO8_FIXTURE/after.files" "$TODO8_FIXTURE/after.index" "$TODO8_FIXTURE/after.head" "$TODO8_FIXTURE/after.refs" "$TODO8_FIXTURE/after.state" | cut -d ' ' -f 1 | sha256sum | cut -d ' ' -f 1)"
  printf 'REPORT_LOCK_FREE before=%s after=%s internal_path=absent\n' "$before_hash" "$after_hash"
}

scenario_migration_old_staged() {
  local artifact_id=2026-01-02T03-04-05Z
  todo8_setup old-staged || return 2
  todo8_write_legacy_set "$artifact_id"
  todo8_stage_legacy_set "$artifact_id"
  todo8_expect_report_issue 'legacy staged backup set' || return 2
  grep -Fq 'scripts/migrate-legacy.sh --adopt-staged' "$TODO8_FIXTURE/report.log" || return 2
}

scenario_migration_adopt_complete() {
  local artifact_id=2026-01-02T03-04-05Z archive checksum archive_hash checksum_hash
  todo8_setup adopt || return 2
  todo8_write_legacy_set "$artifact_id"
  todo8_stage_legacy_set "$artifact_id"
  archive="$TODO8_REPO/backups/testbox/${artifact_id}.tar.zst.age"
  checksum="$TODO8_REPO/backups/testbox/${artifact_id}.sha256"
  archive_hash="$(/usr/bin/sha256sum "$archive" | cut -d ' ' -f 1)"
  checksum_hash="$(/usr/bin/sha256sum "$checksum" | cut -d ' ' -f 1)"
  todo8_run "$TODO8_FIXTURE/adopt.log" bash "$TODO8_REPO/scripts/migrate-legacy.sh" --adopt-staged || return 2
  [[ -f "$TODO8_STATE" ]] || return 2
  /usr/bin/python3 - "$TODO8_STATE" "$artifact_id" "$archive_hash" "$checksum_hash" <<'PY' || return 2
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
artifact, archive_hash, checksum_hash = sys.argv[2:]
archive = f"backups/testbox/{artifact}.tar.zst.age"
checksum = f"backups/testbox/{artifact}.sha256"
assert state["version"] == 2
assert state["canonical_branch_exists"] is True
assert state["branch"] == "main"
assert state["remotes"] == ["canonical", "mirror"]
assert state["publication"]["artifact_id"] == artifact
assert state["hashes"][archive] == archive_hash
assert state["hashes"][checksum] == checksum_hash
assert state["retention_deletions"] == []
PY
  /usr/bin/sha256sum "$TODO8_STATE" >"$TODO8_FIXTURE/state-before-retry"
  if todo8_run "$TODO8_FIXTURE/retry-adopt.log" bash "$TODO8_REPO/scripts/migrate-legacy.sh" --adopt-staged; then return 2; fi
  /usr/bin/sha256sum "$TODO8_STATE" >"$TODO8_FIXTURE/state-after-retry"
  cmp -s "$TODO8_FIXTURE/state-before-retry" "$TODO8_FIXTURE/state-after-retry" || return 2
  grep -Fq 'prepared state already exists' "$TODO8_FIXTURE/retry-adopt.log" || return 2
  ! grep -Fq 'MIGRATION_STATUS=adopted' "$TODO8_FIXTURE/retry-adopt.log" || return 2
  todo8_run "$TODO8_FIXTURE/publish.log" bash "$TODO8_REPO/scripts/publish-prepared.sh" || return 2
  [[ ! -e "$TODO8_STATE" ]] || return 2
  [[ "$(/usr/bin/git --git-dir="$TODO8_CANONICAL" rev-parse refs/heads/main)" == "$(/usr/bin/git -C "$TODO8_REPO" rev-parse HEAD)" ]] || return 2
  [[ "$(/usr/bin/git --git-dir="$TODO8_MIRROR" rev-parse refs/heads/main)" == "$(/usr/bin/git -C "$TODO8_REPO" rev-parse HEAD)" ]] || return 2
}

scenario_migration_old_names() {
  todo8_setup old-names || return 2
  todo8_write_legacy_set 2026-01-02T03-04-05Z
  todo8_expect_report_issue 'legacy timestamp backup set' || return 2
  grep -Fq '2026-01-02T03-04-05Z' "$TODO8_FIXTURE/report.log" || return 2
}

scenario_migration_timer() {
  todo8_setup timer || return 2
  printf '[Service]\n' >"$TODO8_SYSTEMD_DIR/encrypted-github-backup.service"
  printf '[Timer]\n' >"$TODO8_SYSTEMD_DIR/encrypted-github-backup.timer"
  todo8_expect_report_issue 'legacy root timer unit' || return 2
  grep -Fq -- '--migrate-legacy' "$TODO8_FIXTURE/report.log" || return 2
}

scenario_migration_ci() {
  todo8_setup ci || return 2
  mkdir -p "$TODO8_REPO/.github/workflows"
  printf 'permissions:\n  contents: write\n' >"$TODO8_REPO/.github/workflows/retention.yml"
  todo8_expect_report_issue 'copied legacy retention CI' || return 2
  grep -Fq 'remove the copied legacy CI file manually' "$TODO8_FIXTURE/report.log" || return 2
}
