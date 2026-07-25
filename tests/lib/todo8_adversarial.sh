#!/usr/bin/env bash

scenario_migration_diverged() {
  local base tree divergent
  todo8_setup diverged || return 2
  base="$(/usr/bin/git -C "$TODO8_REPO" rev-parse HEAD)"
  tree="$(/usr/bin/git -C "$TODO8_REPO" rev-parse HEAD^{tree})"
  divergent="$(printf 'mirror divergence\n' | \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    /usr/bin/git --git-dir="$TODO8_MIRROR" commit-tree "$tree" -p "$base")" || return 2
  /usr/bin/git --git-dir="$TODO8_MIRROR" update-ref refs/heads/main "$divergent" || return 2
  todo8_expect_report_issue 'divergent mirror OID' || return 2
  grep -Fq 'reconcile the mirror manually' "$TODO8_FIXTURE/report.log" || return 2
}

todo8_incomplete_case() {
  local mutation="$1" artifact_id=2026-01-02T03-04-05Z path
  todo8_setup "incomplete-$mutation" || return 2
  todo8_write_legacy_set "$artifact_id"
  case "$mutation" in
    missing-manifest)
      rm -f -- "$TODO8_REPO/manifests/testbox/${artifact_id}.json"
      /usr/bin/git -C "$TODO8_REPO" add -- \
        "backups/testbox/${artifact_id}.tar.zst.age" \
        "backups/testbox/${artifact_id}.sha256" backups/testbox/latest.txt
      ;;
    wrong-checksum)
      printf '%064d  backups/testbox/%s.tar.zst.age\n' 0 "$artifact_id" >"$TODO8_REPO/backups/testbox/${artifact_id}.sha256"
      todo8_stage_legacy_set "$artifact_id"
      ;;
    wrong-manifest)
      /usr/bin/python3 - "$TODO8_REPO/manifests/testbox/${artifact_id}.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["encrypted_archive_sha256"] = "0" * 64
path.write_text(json.dumps(data) + "\n")
PY
      todo8_stage_legacy_set "$artifact_id"
      ;;
    wrong-latest)
      printf 'backups/testbox/other.tar.zst.age\n' >"$TODO8_REPO/backups/testbox/latest.txt"
      todo8_stage_legacy_set "$artifact_id"
      ;;
    unrelated-stage)
      todo8_stage_legacy_set "$artifact_id"
      printf 'changed\n' >>"$TODO8_REPO/README.md"
      /usr/bin/git -C "$TODO8_REPO" add README.md
      ;;
    multiple-sets)
      todo8_write_legacy_set 2026-01-02T03-04-06Z
      /usr/bin/git -C "$TODO8_REPO" add backups/testbox manifests/testbox
      ;;
    existing-state)
      todo8_stage_legacy_set "$artifact_id"
      mkdir -p "$(dirname "$TODO8_STATE")"
      printf '{}\n' >"$TODO8_STATE"
      ;;
    symlink)
      path="$TODO8_REPO/backups/testbox/${artifact_id}.tar.zst.age"
      rm -f -- "$path"
      ln -s "$TODO8_DATA/payload.txt" "$path"
      todo8_stage_legacy_set "$artifact_id"
      ;;
    hardlink)
      path="$TODO8_REPO/backups/testbox/${artifact_id}.tar.zst.age"
      ln "$path" "$TODO8_FIXTURE/archive-hardlink"
      todo8_stage_legacy_set "$artifact_id"
      ;;
    branch-mismatch)
      todo8_stage_legacy_set "$artifact_id"
      python3 - "$TODO8_REPO/hosts/testbox/backup.conf" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace('BACKUP_BRANCH="main"', 'BACKUP_BRANCH="other"'))
PY
      ;;
    local-ahead)
      printf 'local unpublished change\n' >>"$TODO8_REPO/README.md"
      /usr/bin/git -C "$TODO8_REPO" add README.md
      /usr/bin/git -C "$TODO8_REPO" commit -qm 'local unpublished commit'
      todo8_stage_legacy_set "$artifact_id"
      ;;
    canonical-ahead)
      local base tree advanced
      base="$(/usr/bin/git -C "$TODO8_REPO" rev-parse HEAD)"
      tree="$(/usr/bin/git -C "$TODO8_REPO" rev-parse HEAD^{tree})"
      advanced="$(printf 'canonical advanced\n' | \
        GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
        GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
        /usr/bin/git --git-dir="$TODO8_CANONICAL" commit-tree "$tree" -p "$base")" || return 2
      /usr/bin/git --git-dir="$TODO8_CANONICAL" update-ref refs/heads/main "$advanced" || return 2
      todo8_stage_legacy_set "$artifact_id"
      ;;
    state-dir-symlink)
      todo8_stage_legacy_set "$artifact_id"
      mkdir -p "$TODO8_REPO/.git/local-backup-push-kit" "$TODO8_FIXTURE/external-state"
      ln -s "$TODO8_FIXTURE/external-state" "$TODO8_REPO/.git/local-backup-push-kit/prepared"
      ;;
    *) return 2 ;;
  esac
  todo8_snapshot "$TODO8_FIXTURE/before"
  if todo8_run "$TODO8_FIXTURE/adopt.log" bash "$TODO8_REPO/scripts/migrate-legacy.sh" --adopt-staged; then return 2; fi
  todo8_snapshot "$TODO8_FIXTURE/after"
  todo8_assert_snapshot "$TODO8_FIXTURE/before" "$TODO8_FIXTURE/after" || return 2
  grep -Fq 'RECOVERY:' "$TODO8_FIXTURE/adopt.log" || return 2
  ! grep -Fq 'MIGRATION_STATUS=adopted' "$TODO8_FIXTURE/adopt.log" || return 2
  [[ ! -e "$TODO8_FIXTURE/external-state/testbox.state" ]] || return 2
}

todo8_url_redaction_case() {
  local marker="$TODO8_FIXTURE/network.marker" secret='todo8-url-secret'
  todo8_setup url-redaction || return 2
  /usr/bin/git -C "$TODO8_REPO" remote set-url canonical "https://user:${secret}@example.invalid/repo.git"
  mkdir -p "$TODO8_FIXTURE/bin"
  cat >"$TODO8_FIXTURE/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *' ls-remote '* ]]; then : >"${TODO8_NETWORK_MARKER:?}"; fi
exec /usr/bin/git "$@"
EOF
  chmod +x "$TODO8_FIXTURE/bin/git"
  todo8_snapshot "$TODO8_FIXTURE/before"
  if todo8_run "$TODO8_FIXTURE/url.log" \
    PATH="$TODO8_FIXTURE/bin:$PATH" TODO8_NETWORK_MARKER="$marker" \
    bash "$TODO8_REPO/scripts/migrate-legacy.sh"; then return 2; fi
  todo8_snapshot "$TODO8_FIXTURE/after"
  todo8_assert_snapshot "$TODO8_FIXTURE/before" "$TODO8_FIXTURE/after" || return 2
  grep -Fq 'embedded userinfo' "$TODO8_FIXTURE/url.log" || return 2
  ! grep -Fq "$secret" "$TODO8_FIXTURE/url.log" || return 2
  [[ ! -e "$marker" ]] || return 2
}

todo8_interruption_case() {
  local artifact_id=2026-01-02T03-04-05Z status
  local -a environment=()
  todo8_setup interruption || return 2
  todo8_write_legacy_set "$artifact_id"
  todo8_stage_legacy_set "$artifact_id"
  mkdir -p "$TODO8_FIXTURE/bin"
  cat >"$TODO8_FIXTURE/bin/mv" <<'EOF'
#!/usr/bin/env bash
last="${!#}"
if [[ "$last" == *.state ]]; then
  : >"${TODO8_MV_MARKER:?}"
  /bin/sleep 60
fi
exec /bin/mv "$@"
EOF
  chmod +x "$TODO8_FIXTURE/bin/mv"
  todo8_snapshot "$TODO8_FIXTURE/before"
  mapfile -t environment < <(fixture_env "$TODO8_FIXTURE")
  run_captured "$TODO8_FIXTURE/interrupted.log" 1 env \
    "${environment[@]}" PATH="$TODO8_FIXTURE/bin:$PATH" \
    TODO8_MV_MARKER="$TODO8_FIXTURE/mv.marker" BACKUP_HOST=testbox \
    MIGRATION_SYSTEMD_DIR="$TODO8_SYSTEMD_DIR" \
    bash "$TODO8_REPO/scripts/migrate-legacy.sh" --adopt-staged
  status=$?
  [[ "$status" -ne 0 && -f "$TODO8_FIXTURE/mv.marker" ]] || return 2
  todo8_snapshot "$TODO8_FIXTURE/after"
  todo8_assert_snapshot "$TODO8_FIXTURE/before" "$TODO8_FIXTURE/after" || return 2
  [[ ! -e "$TODO8_STATE" ]] || return 2
  [[ -z "$(compgen -G "$TODO8_REPO/.git/local-backup-push-kit/prepared/.testbox.migration.*" || true)" ]] || return 2
}

scenario_migration_incomplete() {
  local mutation
  for mutation in missing-manifest wrong-checksum wrong-manifest wrong-latest unrelated-stage multiple-sets existing-state symlink hardlink branch-mismatch local-ahead canonical-ahead state-dir-symlink; do
    todo8_incomplete_case "$mutation" || return 2
  done
  todo8_url_redaction_case || return 2
  todo8_interruption_case || return 2
}

scenario_migration_old_timer() {
  local artifact_id=2026-01-02T03-04-05Z
  scenario_migration_timer || return 2
  todo8_setup timer-adopt || return 2
  todo8_write_legacy_set "$artifact_id"
  todo8_stage_legacy_set "$artifact_id"
  printf '[Timer]\n' >"$TODO8_SYSTEMD_DIR/encrypted-github-backup.timer"
  todo8_snapshot "$TODO8_FIXTURE/before"
  if todo8_run "$TODO8_FIXTURE/adopt.log" bash "$TODO8_REPO/scripts/migrate-legacy.sh" --adopt-staged; then return 2; fi
  todo8_snapshot "$TODO8_FIXTURE/after"
  todo8_assert_snapshot "$TODO8_FIXTURE/before" "$TODO8_FIXTURE/after" || return 2
  grep -Fq 'legacy root timer units prevent safe adoption' "$TODO8_FIXTURE/adopt.log" || return 2
}

scenario_migration_old_ci() {
  local artifact_id=2026-01-02T03-04-05Z
  scenario_migration_ci || return 2
  todo8_setup ci-adopt || return 2
  todo8_write_legacy_set "$artifact_id"
  todo8_stage_legacy_set "$artifact_id"
  mkdir -p "$TODO8_REPO/.github/workflows"
  printf 'permissions:\n  contents: write\n' >"$TODO8_REPO/.github/workflows/retention.yml"
  todo8_snapshot "$TODO8_FIXTURE/before"
  if todo8_run "$TODO8_FIXTURE/adopt.log" bash "$TODO8_REPO/scripts/migrate-legacy.sh" --adopt-staged; then return 2; fi
  todo8_snapshot "$TODO8_FIXTURE/after"
  todo8_assert_snapshot "$TODO8_FIXTURE/before" "$TODO8_FIXTURE/after" || return 2
  grep -Fq 'copied retention CI prevents safe adoption' "$TODO8_FIXTURE/adopt.log" || return 2
}

todo8_wait_for_path() {
  local path="$1" attempt
  for attempt in {1..100}; do
    [[ -e "$path" ]] && return 0
    /bin/sleep 0.05
  done
  return 1
}

todo8_start_adopter() {
  local output="$1" block_mv="$2"
  setsid env \
    PATH="$TODO8_FIXTURE/bin:$PATH" \
    BACKUP_HOST=testbox \
    BACKUP_LOCK_TIMEOUT="${TODO8_LOCK_TIMEOUT:-5}" \
    MIGRATION_SYSTEMD_DIR="$TODO8_SYSTEMD_DIR" \
    TODO8_BLOCK_STATE_MV="$block_mv" \
    TODO8_MV_MARKER="$TODO8_FIXTURE/mv.marker" \
    TODO8_MV_RELEASE="$TODO8_FIXTURE/mv.release" \
    bash "$TODO8_REPO/scripts/migrate-legacy.sh" --adopt-staged >"$output" 2>&1 &
  STARTED_GROUP_PID=$!
  ACTIVE_GROUPS+=("$STARTED_GROUP_PID")
}

todo8_install_blocking_mv() {
  mkdir -p "$TODO8_FIXTURE/bin"
  cat >"$TODO8_FIXTURE/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -u
last="${!#}"
if [[ "$last" == *.state && "${TODO8_BLOCK_STATE_MV:-0}" == 1 ]]; then
  : >"${TODO8_MV_MARKER:?}"
  while [[ ! -e "${TODO8_MV_RELEASE:?}" ]]; do /bin/sleep 0.05; done
fi
exec /bin/mv "$@"
EOF
  chmod +x "$TODO8_FIXTURE/bin/mv"
}

todo8_concurrent_pair() {
  local first_status second_status adopted_count state_count state_hash lock_available=0
  todo8_start_adopter "$TODO8_FIXTURE/first.log" 1
  local first_pid="$STARTED_GROUP_PID"
  todo8_wait_for_path "$TODO8_FIXTURE/mv.marker" || return 2
  todo8_start_adopter "$TODO8_FIXTURE/second.log" 0
  local second_pid="$STARTED_GROUP_PID"
  /bin/sleep 0.5
  : >"$TODO8_FIXTURE/mv.release"
  wait "$first_pid"; first_status=$?
  wait "$second_pid"; second_status=$?
  ACTIVE_GROUPS=()
  adopted_count="$(grep -Fh 'MIGRATION_STATUS=adopted' "$TODO8_FIXTURE/first.log" "$TODO8_FIXTURE/second.log" | wc -l)"
  state_count="$(find "$TODO8_REPO/.git/local-backup-push-kit/prepared" -maxdepth 1 -type f -name 'testbox.state' 2>/dev/null | wc -l)"
  state_hash="$(sha256sum "$TODO8_REPO/.git/local-backup-push-kit/prepared/testbox.state" | cut -d ' ' -f 1)"
  if flock -n "$TODO8_REPO/.git/local-backup-push-kit/lock" -c true; then lock_available=1; fi
  printf 'CONCURRENT_ADOPTION statuses=%s,%s success_messages=%s state_files=%s state_sha256=%s lock_available=%s\n' \
    "$first_status" "$second_status" "$adopted_count" "$state_count" "$state_hash" "$lock_available" >"$TODO8_FIXTURE/concurrent.result"
  if [[ "$first_status" -ne 0 || "$second_status" -eq 0 || "$adopted_count" -ne 1 || "$state_count" -ne 1 || "$lock_available" -ne 1 ]]; then
    say_error "$(<"$TODO8_FIXTURE/concurrent.result")"
    return 2
  fi
  grep -Fq 'prepared state already exists' "$TODO8_FIXTURE/second.log" || return 2
  printf '%s\n' "$(<"$TODO8_FIXTURE/concurrent.result")"
}

scenario_migration_concurrent_adopt() {
  local artifact_id=2026-01-02T03-04-05Z holder_status retry_status timeout_diagnostic
  todo8_setup concurrent-adopt || return 2
  todo8_write_legacy_set "$artifact_id"
  todo8_stage_legacy_set "$artifact_id"
  todo8_install_blocking_mv
  todo8_concurrent_pair || return 2

  rm -rf -- "$TODO8_REPO/.git/local-backup-push-kit"
  rm -f -- "$TODO8_FIXTURE/mv.marker" "$TODO8_FIXTURE/mv.release"
  todo8_start_adopter "$TODO8_FIXTURE/holder.log" 1
  local holder_pid="$STARTED_GROUP_PID"
  todo8_wait_for_path "$TODO8_FIXTURE/mv.marker" || return 2
  TODO8_LOCK_TIMEOUT=0
  todo8_start_adopter "$TODO8_FIXTURE/timeout.log" 0
  local timeout_pid="$STARTED_GROUP_PID"
  wait "$timeout_pid"; retry_status=$?
  [[ "$retry_status" -ne 0 ]] || return 2
  grep -Fq 'backup lock unavailable after 0s' "$TODO8_FIXTURE/timeout.log" || return 2
  timeout_diagnostic="$(grep -Fm1 'backup lock unavailable after 0s' "$TODO8_FIXTURE/timeout.log")"
  kill -TERM -- "-$holder_pid" 2>/dev/null || true
  wait "$holder_pid"; holder_status=$?
  ACTIVE_GROUPS=()
  [[ "$holder_status" -ne 0 ]] || return 2
  [[ ! -e "$TODO8_REPO/.git/local-backup-push-kit/prepared/testbox.state" ]] || return 2
  [[ -z "$(compgen -G "$TODO8_REPO/.git/local-backup-push-kit/prepared/.testbox.migration.*" || true)" ]] || return 2
  flock -n "$TODO8_REPO/.git/local-backup-push-kit/lock" -c true || return 2
  rm -f -- "$TODO8_FIXTURE/mv.marker" "$TODO8_FIXTURE/mv.release"
  unset TODO8_LOCK_TIMEOUT
  todo8_start_adopter "$TODO8_FIXTURE/retry.log" 0
  local retry_pid="$STARTED_GROUP_PID"
  wait "$retry_pid"; retry_status=$?
  ACTIVE_GROUPS=()
  [[ "$retry_status" -eq 0 ]] || return 2
  grep -Fq 'MIGRATION_STATUS=adopted' "$TODO8_FIXTURE/retry.log" || return 2
  printf 'LOCK_TIMEOUT_INTERRUPT timeout_status=nonzero diagnostic=%q holder_status=nonzero retry_status=0 temp_state=absent\n' "$timeout_diagnostic"
}
