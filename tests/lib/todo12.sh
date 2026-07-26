#!/usr/bin/env bash

compaction_make_set() {
  local repo="$1" host="$2" artifact="$3" payload="${4:-payload}" archive digest
  mkdir -p "$repo/backups/$host" "$repo/manifests/$host"
  archive="backups/$host/$artifact.tar.zst.age"
  printf '%s\n' "$payload" >"$repo/$archive"
  digest="$(sha256sum "$repo/$archive" | cut -d ' ' -f 1)"
  printf '%s  %s\n' "$digest" "$archive" >"$repo/backups/$host/$artifact.sha256"
  printf '{"host_id":"%s","timestamp_utc":"%s","encrypted_archive":"%s","encrypted_archive_sha256":"%s","included_paths":["/fixture/%s"]}\n' \
    "$host" "$artifact" "$archive" "$digest" "$host" >"$repo/manifests/$host/$artifact.json"
  printf '%s\n' "$archive" >"$repo/backups/$host/latest.txt"
}

compaction_commit() {
  local repo="$1" message="$2"
  /usr/bin/git -C "$repo" add -- backups manifests
  /usr/bin/git -C "$repo" commit -qm "$message"
}

compaction_setup() {
  local name="$1" branch="${2:-main}"
  new_fixture "compaction-$name" || return 2
  COMPACTION_FIXTURE="$FIXTURE"
  COMPACTION_REPO="$COMPACTION_FIXTURE/repo"
  COMPACTION_REMOTE="$COMPACTION_FIXTURE/remote.git"
  copy_template "$COMPACTION_REPO"
  init_real_repo "$COMPACTION_REPO" || return 2
  if [[ "$branch" != main ]]; then /usr/bin/git -C "$COMPACTION_REPO" branch -m "$branch"; fi
  /usr/bin/git init -q --bare "$COMPACTION_REMOTE" || return 2
  /usr/bin/git -C "$COMPACTION_REPO" remote add origin "$COMPACTION_REMOTE" || return 2
  /usr/bin/git -C "$COMPACTION_REPO" push -q origin "HEAD:refs/heads/$branch" || return 2
}

compaction_run() {
  local output="$1"
  run_captured "$output" 30 env BACKUP_COMPACTION_CI=1 BACKUP_COMPACTION_REMOTE=origin BACKUP_COMPACTION_BRANCH=main BACKUP_COMPACTION_KEEP=2 \
    bash "$COMPACTION_REPO/scripts/compact-remote-history.sh"
}

compaction_remote_head() {
  /usr/bin/git --git-dir="$COMPACTION_REMOTE" rev-parse refs/heads/main
}

compaction_assert_two_sets() {
  local head="$1" host="$2"
  [[ "$(/usr/bin/git --git-dir="$COMPACTION_REMOTE" ls-tree -r --name-only "$head" -- "backups/$host" | grep -Ec '\.tar\.zst\.age$')" == 2 ]] || return 2
  [[ "$(/usr/bin/git --git-dir="$COMPACTION_REMOTE" ls-tree -r --name-only "$head" -- "manifests/$host" | grep -Ec '\.json$')" == 2 ]] || return 2
}

scenario_remote_compaction_rewrites_to_two_sets() {
  local artifact head old_head
  compaction_setup retains-two || return 2
  for artifact in 2026-01-01T00-00-00Z 2026-01-02T00-00-00Z 2026-01-03T00-00-00Z 2026-01-04T00-00-00Z; do
    compaction_make_set "$COMPACTION_REPO" host-a "$artifact" "host-a-$artifact"
    compaction_commit "$COMPACTION_REPO" "fixture $artifact" || return 2
  done
  for artifact in 2026-01-01T12-00-00Z 2026-01-02T12-00-00Z 2026-01-03T12-00-00Z; do
    compaction_make_set "$COMPACTION_REPO" host-b "$artifact" "host-b-$artifact"
    compaction_commit "$COMPACTION_REPO" "fixture host-b $artifact" || return 2
  done
  /usr/bin/git -C "$COMPACTION_REPO" push -q origin HEAD:refs/heads/main || return 2
  old_head="$(compaction_remote_head)" || return 2
  compaction_run "$COMPACTION_FIXTURE/compact.log" || return 2
  head="$(compaction_remote_head)" || return 2
  [[ "$head" != "$old_head" ]] || return 2
  [[ -z "$(/usr/bin/git --git-dir="$COMPACTION_REMOTE" rev-list --parents -n 1 "$head" | awk 'NF > 1 {print}')" ]] || return 2
  compaction_assert_two_sets "$head" host-a || return 2
  compaction_assert_two_sets "$head" host-b || return 2
  /usr/bin/git --git-dir="$COMPACTION_REMOTE" ls-tree -r --name-only "$head" | grep -Fqx 'backups/host-a/2026-01-04T00-00-00Z.tar.zst.age' || return 2
  /usr/bin/git --git-dir="$COMPACTION_REMOTE" ls-tree -r --name-only "$head" | grep -Fqx 'backups/host-b/2026-01-03T12-00-00Z.tar.zst.age' || return 2
  ! /usr/bin/git --git-dir="$COMPACTION_REMOTE" ls-tree -r --name-only "$head" | grep -Fq '2026-01-01T00-00-00Z' || return 2
  grep -Fq 'COMPACTION_PUBLISHED branch=main' "$COMPACTION_FIXTURE/compact.log" || return 2
}

scenario_remote_compaction_all_branches() {
  local artifact main_head branch_head
  compaction_setup all-branches || return 2
  for artifact in 2026-01-01T00-00-00Z 2026-01-02T00-00-00Z 2026-01-03T00-00-00Z; do
    compaction_make_set "$COMPACTION_REPO" host-a "$artifact"
    compaction_commit "$COMPACTION_REPO" "main fixture $artifact" || return 2
  done
  /usr/bin/git -C "$COMPACTION_REPO" branch backup/host-b
  /usr/bin/git -C "$COMPACTION_REPO" push -q origin HEAD:refs/heads/main backup/host-b:refs/heads/backup/host-b || return 2
  /usr/bin/git -C "$COMPACTION_REPO" checkout -q backup/host-b
  for artifact in 2026-02-01T00-00-00Z 2026-02-02T00-00-00Z 2026-02-03T00-00-00Z; do
    compaction_make_set "$COMPACTION_REPO" host-b "$artifact"
    compaction_commit "$COMPACTION_REPO" "branch fixture $artifact" || return 2
  done
  /usr/bin/git -C "$COMPACTION_REPO" push -q origin HEAD:refs/heads/backup/host-b || return 2
  run_captured "$COMPACTION_FIXTURE/all.log" 30 env BACKUP_COMPACTION_CI=1 BACKUP_COMPACTION_REMOTE=origin BACKUP_COMPACTION_ALL_BRANCHES=1 BACKUP_COMPACTION_KEEP=2 \
    bash "$COMPACTION_REPO/scripts/compact-remote-history.sh" || return 2
  main_head="$(/usr/bin/git --git-dir="$COMPACTION_REMOTE" rev-parse refs/heads/main)" || return 2
  branch_head="$(/usr/bin/git --git-dir="$COMPACTION_REMOTE" rev-parse refs/heads/backup/host-b)" || return 2
  [[ -z "$(/usr/bin/git --git-dir="$COMPACTION_REMOTE" rev-list --parents -n 1 "$main_head" | awk 'NF > 1 {print}')" ]] || return 2
  [[ -z "$(/usr/bin/git --git-dir="$COMPACTION_REMOTE" rev-list --parents -n 1 "$branch_head" | awk 'NF > 1 {print}')" ]] || return 2
  compaction_assert_two_sets "$main_head" host-a || return 2
  compaction_assert_two_sets "$branch_head" host-a || return 2
  compaction_assert_two_sets "$branch_head" host-b || return 2
  grep -Fq 'COMPACTION_PUBLISHED branch=main' "$COMPACTION_FIXTURE/all.log" || return 2
  grep -Fq 'COMPACTION_PUBLISHED branch=backup/host-b' "$COMPACTION_FIXTURE/all.log" || return 2
}

scenario_remote_compaction_requires_ci_marker() {
  local artifact before after
  compaction_setup ci-marker || return 2
  for artifact in 2026-01-01T00-00-00Z 2026-01-02T00-00-00Z 2026-01-03T00-00-00Z; do
    compaction_make_set "$COMPACTION_REPO" host-a "$artifact"
    compaction_commit "$COMPACTION_REPO" "fixture $artifact" || return 2
  done
  /usr/bin/git -C "$COMPACTION_REPO" push -q origin HEAD:refs/heads/main || return 2
  before="$(compaction_remote_head)" || return 2
  if run_captured "$COMPACTION_FIXTURE/no-ci.log" 20 env BACKUP_COMPACTION_REMOTE=origin BACKUP_COMPACTION_BRANCH=main BACKUP_COMPACTION_KEEP=2 \
    bash "$COMPACTION_REPO/scripts/compact-remote-history.sh"; then return 2; fi
  after="$(compaction_remote_head)" || return 2
  [[ "$before" == "$after" ]] || return 2
  grep -Fq 'refusing to run outside an explicitly marked CI job' "$COMPACTION_FIXTURE/no-ci.log" || return 2
}

scenario_remote_compaction_noop_at_two_sets() {
  local artifact before after
  compaction_setup noop || return 2
  for artifact in 2026-01-01T00-00-00Z 2026-01-02T00-00-00Z; do
    compaction_make_set "$COMPACTION_REPO" host-a "$artifact"
    compaction_commit "$COMPACTION_REPO" "fixture $artifact" || return 2
  done
  /usr/bin/git -C "$COMPACTION_REPO" push -q origin HEAD:refs/heads/main || return 2
  before="$(compaction_remote_head)" || return 2
  compaction_run "$COMPACTION_FIXTURE/noop-first.log" || return 2
  after="$(compaction_remote_head)" || return 2
  [[ "$before" != "$after" ]] || return 2
  compaction_run "$COMPACTION_FIXTURE/noop-second.log" || return 2
  [[ "$after" == "$(compaction_remote_head)" ]] || return 2
  grep -Fq 'COMPACTION_NOOP branch=main' "$COMPACTION_FIXTURE/noop-second.log" || return 2
}

scenario_remote_compaction_rejects_malformed_set() {
  compaction_setup malformed || return 2
  compaction_make_set "$COMPACTION_REPO" host-a 2026-01-01T00-00-00Z || return 2
  rm -f "$COMPACTION_REPO/manifests/host-a/2026-01-01T00-00-00Z.json"
  compaction_commit "$COMPACTION_REPO" 'malformed fixture' || return 2
  /usr/bin/git -C "$COMPACTION_REPO" push -q origin HEAD:refs/heads/main || return 2
  if compaction_run "$COMPACTION_FIXTURE/malformed.log"; then return 2; fi
  grep -Fq 'malformed or incomplete backup data' "$COMPACTION_FIXTURE/malformed.log" || return 2
}

scenario_compaction_snapshot_fast_forward() {
  local artifact compacted clone output state
  compaction_setup client-recovery || return 2
  mkdir -p "$COMPACTION_REPO/hosts/testbox" "$COMPACTION_FIXTURE/data"
  printf 'payload\n' >"$COMPACTION_FIXTURE/data/payload"
  cat >"$COMPACTION_REPO/hosts/testbox/backup.conf" <<EOF
CONFIG_HOST_ID="testbox"
AGE_RECIPIENT="$TEST_AGE_RECIPIENT"
BACKUP_BRANCH="main"
BACKUP_REMOTES=("origin")
BACKUP_PATHS=("$COMPACTION_FIXTURE/data")
EOF
  /usr/bin/git -C "$COMPACTION_REPO" add -- hosts/testbox/backup.conf
  /usr/bin/git -C "$COMPACTION_REPO" commit -qm 'fixture host config'
  /usr/bin/git -C "$COMPACTION_REPO" push -q origin HEAD:refs/heads/main
  clone="$COMPACTION_FIXTURE/client"
  /usr/bin/git clone -q --branch main "$COMPACTION_REMOTE" "$clone" || return 2
  /usr/bin/git -C "$clone" config user.name fixture
  /usr/bin/git -C "$clone" config user.email fixture@example.invalid
  for artifact in 2026-01-01T00-00-00Z 2026-01-02T00-00-00Z 2026-01-03T00-00-00Z; do
    compaction_make_set "$COMPACTION_REPO" testbox "$artifact"
    compaction_commit "$COMPACTION_REPO" "fixture $artifact" || return 2
  done
  /usr/bin/git -C "$COMPACTION_REPO" push -q origin HEAD:refs/heads/main || return 2
  compaction_run "$COMPACTION_FIXTURE/compact.log" || return 2
  compacted="$(compaction_remote_head)" || return 2
  output="$COMPACTION_FIXTURE/client.log"
  run_captured "$output" 20 env BACKUP_HOST=testbox BACKUP_PUSH=0 PATH="$COMPACTION_FIXTURE/bin:$PATH" FAKE_TAR_LOG="$COMPACTION_FIXTURE/tar.log" FAKE_AGE_LOG="$COMPACTION_FIXTURE/age.log" FAKE_GIT_LOG="$COMPACTION_FIXTURE/git.log" FAKE_GIT_INDEX="$COMPACTION_FIXTURE/git-index" FAKE_PYTHON_CODE="$COMPACTION_FIXTURE/python-code.py" FAKE_NETWORK_MARKER="$COMPACTION_FIXTURE/network.log" FAKE_AGE_VALID_RECIPIENT="$TEST_AGE_RECIPIENT" FAKE_SHA256_COUNTER="$COMPACTION_FIXTURE/sha256-counter" FAKE_TAR_DELAY_MARKER="$COMPACTION_FIXTURE/tar-delay.marker" FAKE_AGE_DELAY_MARKER="$COMPACTION_FIXTURE/age-delay.marker" FAKE_SHA256_DELAY_MARKER="$COMPACTION_FIXTURE/sha256-delay.marker" FAKE_PYTHON_DELAY_MARKER="$COMPACTION_FIXTURE/python-delay.marker" FAKE_INSTALL_MARKER="$COMPACTION_FIXTURE/install-delay.marker" bash "$clone/scripts/backup.sh" || return 2
  state="$clone/.git/local-backup-push-kit/prepared/testbox.state"
  [[ -f "$state" && "$(/usr/bin/git -C "$clone" rev-parse HEAD)" == "$compacted" ]] || return 2
  run_captured "$COMPACTION_FIXTURE/client-publish.log" 20 env BACKUP_HOST=testbox PATH="$COMPACTION_FIXTURE/bin:$PATH" FAKE_TAR_LOG="$COMPACTION_FIXTURE/tar.log" FAKE_AGE_LOG="$COMPACTION_FIXTURE/age.log" FAKE_GIT_LOG="$COMPACTION_FIXTURE/git.log" FAKE_GIT_INDEX="$COMPACTION_FIXTURE/git-index" FAKE_PYTHON_CODE="$COMPACTION_FIXTURE/python-code.py" FAKE_NETWORK_MARKER="$COMPACTION_FIXTURE/network.log" FAKE_AGE_VALID_RECIPIENT="$TEST_AGE_RECIPIENT" FAKE_SHA256_COUNTER="$COMPACTION_FIXTURE/sha256-counter" FAKE_TAR_DELAY_MARKER="$COMPACTION_FIXTURE/tar-delay.marker" FAKE_AGE_DELAY_MARKER="$COMPACTION_FIXTURE/age-delay.marker" FAKE_SHA256_DELAY_MARKER="$COMPACTION_FIXTURE/sha256-delay.marker" FAKE_PYTHON_DELAY_MARKER="$COMPACTION_FIXTURE/python-delay.marker" FAKE_INSTALL_MARKER="$COMPACTION_FIXTURE/install-delay.marker" bash "$clone/scripts/publish-prepared.sh" || return 2
  [[ ! -e "$state" && "$(compaction_remote_head)" == "$(/usr/bin/git -C "$clone" rev-parse HEAD)" ]] || return 2
}
