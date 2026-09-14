#!/usr/bin/env bash

TODO11_READY=0

todo11_write_config() {
  local host="$1" data="$2"
  mkdir -p "$TODO11_REPO/hosts/$host"
  cat >"$TODO11_REPO/hosts/$host/backup.conf" <<EOF
CONFIG_HOST_ID="$host"
AGE_RECIPIENT="$TODO11_RECIPIENT"
BACKUP_BRANCH="main"
BACKUP_REMOTES=("canonical" "mirror-a" "mirror-b")
BACKUP_PATHS=("$data")
BACKUP_RETENTION_COUNT="3"
BACKUP_LOCK_TIMEOUT="5"
BACKUP_RUN_USER="backupsvc"
BACKUP_RUN_GROUP="backupsvc"
BACKUP_ON_CALENDAR="weekly"
EOF
}

todo11_write_set() {
  local host="$1" artifact="$2" relative archive digest
  relative="backups/$host/$artifact.tar.zst.age"
  archive="$TODO11_REPO/$relative"
  mkdir -p "$TODO11_REPO/backups/$host" "$TODO11_REPO/manifests/$host"
  printf 'historical encrypted fixture %s %s\n' "$host" "$artifact" >"$archive"
  digest="$(sha256sum "$archive" | cut -d ' ' -f 1)"
  printf '%s  %s\n' "$digest" "$relative" >"$TODO11_REPO/backups/$host/$artifact.sha256"
  printf '{"host_id":"%s","timestamp_utc":"%s","encrypted_archive":"%s","encrypted_archive_sha256":"%s"}\n' \
    "$host" "$artifact" "$relative" "$digest" >"$TODO11_REPO/manifests/$host/$artifact.json"
}

todo11_remote_oid() {
  git --git-dir="$1" rev-parse refs/heads/main
}

todo11_state_value() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
value = state
for key in sys.argv[2].split("."):
    value = value[key]
print(value)
PY
}

todo11_snapshot() {
  python3 - "$1" "$TODO11_REPO" "$TODO11_CANONICAL" "$TODO11_MIRROR_A" "$TODO11_MIRROR_B" <<'PY'
import hashlib
import os
import pathlib
import stat
import sys

digest = hashlib.sha256()
for root_name in sys.argv[2:]:
    root = pathlib.Path(root_name)
    digest.update(root_name.encode() + b"\0")
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        info = path.lstat()
        digest.update(str(relative).encode() + b"\0" + str(stat.S_IMODE(info.st_mode)).encode() + b"\0")
        if path.is_symlink():
            digest.update(os.readlink(path).encode())
        elif path.is_file():
            digest.update(path.read_bytes())
        digest.update(b"\0")
pathlib.Path(sys.argv[1]).write_text(digest.hexdigest() + "\n", encoding="utf-8")
PY
}

todo11_install_git_fail_once() {
  mkdir -p "$TODO11_FIXTURE/bin"
  cat >"$TODO11_FIXTURE/bin/git" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ -n "${TODO11_GIT_LOG:-}" ]]; then
  printf '%q ' "$@" >>"$TODO11_GIT_LOG"
  printf '\n' >>"$TODO11_GIT_LOG"
fi
if [[ " $* " == *' push mirror-b '* && -n "${TODO11_FAIL_MARKER:-}" && ! -e "$TODO11_FAIL_MARKER" ]]; then
  : >"$TODO11_FAIL_MARKER"
  exit 1
fi
exec /usr/bin/git "$@"
EOF
  chmod +x "$TODO11_FIXTURE/bin/git"
}

todo11_run() {
  local output="$1" host="$2" script="$3"
  shift 3
  run_captured "$output" 30 env \
    PATH="$TODO11_FIXTURE/bin:$PATH" \
    TODO11_GIT_LOG="$TODO11_FIXTURE/git.log" \
    TODO11_FAIL_MARKER="$TODO11_FIXTURE/mirror-b.failed" \
    BACKUP_HOST="$host" "$@" bash "$TODO11_REPO/scripts/$script"
}

todo11_prepare_and_restore() {
  local host=host-a state archive checksum restore_dir staged
  state="$TODO11_REPO/.git/local-backup-push-kit/prepared/$host.state"
  todo11_run "$TODO11_FIXTURE/prepare-a.log" "$host" backup.sh BACKUP_PUSH=0 || return 2
  archive="$(todo11_state_value "$state" paths.archive)"
  checksum="$(todo11_state_value "$state" paths.checksum)"
  staged="$(git -C "$TODO11_REPO" diff --cached --name-only | wc -l)"
  [[ "$staged" -eq 4 && "$(todo11_state_value "$state" committed_oid)" == "" ]] || return 2
  (cd "$TODO11_REPO" && sha256sum -c "$checksum") >/dev/null || return 2
  restore_dir="$TODO11_FIXTURE/restore"
  mkdir -p "$restore_dir"
  age -d -i "$TODO11_IDENTITY" -o "$restore_dir/archive.tar.zst" "$TODO11_REPO/$archive" || return 2
  tar --zstd -xf "$restore_dir/archive.tar.zst" -C "$restore_dir" || return 2
  python3 - "$restore_dir" <<'PY'
import pathlib
import sys
matches = [path for path in pathlib.Path(sys.argv[1]).rglob("sentinel-a.txt") if path.read_text() == "RESTORE_SENTINEL_A\n"]
assert len(matches) == 1
PY
  TODO11_ARCHIVE_REL="$archive"
  TODO11_ARCHIVE_HASH="$(sha256sum "$TODO11_REPO/$archive" | cut -d ' ' -f 1)"
  TODO11_ARCHIVE_COUNT="$(find "$TODO11_REPO/backups/host-a" -maxdepth 1 -type f -name '*.tar.zst.age' | wc -l)"
  TODO11_COMMIT_COUNT="$(git -C "$TODO11_REPO" rev-list --count HEAD)"
}

todo11_publish_retry() {
  local state="$TODO11_REPO/.git/local-backup-push-kit/prepared/host-a.state" base after_failure_count
  base="$(git -C "$TODO11_REPO" rev-parse HEAD)"
  todo11_install_git_fail_once
  if todo11_run "$TODO11_FIXTURE/publish-a-first.log" host-a publish-prepared.sh; then return 2; fi
  TODO11_RETRY_OID="$(todo11_state_value "$state" committed_oid)"
  [[ -n "$TODO11_RETRY_OID" ]] || return 2
  [[ "$(todo11_remote_oid "$TODO11_CANONICAL")" == "$TODO11_RETRY_OID" ]] || return 2
  [[ "$(todo11_remote_oid "$TODO11_MIRROR_A")" == "$TODO11_RETRY_OID" ]] || return 2
  [[ "$(todo11_remote_oid "$TODO11_MIRROR_B")" == "$base" ]] || return 2
  after_failure_count="$(find "$TODO11_REPO/backups/host-a" -maxdepth 1 -type f -name '*.tar.zst.age' | wc -l)"
  [[ "$after_failure_count" -eq 3 ]] || return 2
  [[ "$(git -C "$TODO11_REPO" rev-list --count HEAD)" -eq $((TODO11_COMMIT_COUNT + 1)) ]] || return 2
  [[ "$(sha256sum "$TODO11_REPO/$TODO11_ARCHIVE_REL" | cut -d ' ' -f 1)" == "$TODO11_ARCHIVE_HASH" ]] || return 2
  todo11_run "$TODO11_FIXTURE/publish-a-retry.log" host-a publish-prepared.sh || return 2
  [[ ! -e "$state" ]] || return 2
  [[ "$(git -C "$TODO11_REPO" rev-parse HEAD)" == "$TODO11_RETRY_OID" ]] || return 2
  [[ "$(git -C "$TODO11_REPO" rev-list --count HEAD)" -eq $((TODO11_COMMIT_COUNT + 1)) ]] || return 2
  [[ "$(find "$TODO11_REPO/backups/host-a" -maxdepth 1 -type f -name '*.tar.zst.age' | wc -l)" == "$after_failure_count" ]] || return 2
  [[ "$(sha256sum "$TODO11_REPO/$TODO11_ARCHIVE_REL" | cut -d ' ' -f 1)" == "$TODO11_ARCHIVE_HASH" ]] || return 2
  [[ "$(todo11_remote_oid "$TODO11_MIRROR_B")" == "$TODO11_RETRY_OID" ]] || return 2
}

todo11_publish_host_b() {
  todo11_run "$TODO11_FIXTURE/prepare-b.log" host-b backup.sh BACKUP_PUSH=0 || return 2
  todo11_run "$TODO11_FIXTURE/publish-b.log" host-b publish-prepared.sh || return 2
  TODO11_FINAL_OID="$(git -C "$TODO11_REPO" rev-parse HEAD)"
  [[ "$(todo11_remote_oid "$TODO11_CANONICAL")" == "$TODO11_FINAL_OID" ]] || return 2
  [[ "$(todo11_remote_oid "$TODO11_MIRROR_A")" == "$TODO11_FINAL_OID" ]] || return 2
  [[ "$(todo11_remote_oid "$TODO11_MIRROR_B")" == "$TODO11_FINAL_OID" ]] || return 2
  TODO11_HOST_A_COUNT="$(find "$TODO11_REPO/backups/host-a" -maxdepth 1 -type f -name '*.tar.zst.age' | wc -l)"
  TODO11_HOST_B_COUNT="$(find "$TODO11_REPO/backups/host-b" -maxdepth 1 -type f -name '*.tar.zst.age' | wc -l)"
  [[ "$TODO11_HOST_A_COUNT" -eq 3 && "$TODO11_HOST_B_COUNT" -eq 2 ]] || return 2
}

todo11_render_systemd() {
  todo11_run "$TODO11_FIXTURE/systemd-a.log" host-a install-systemd-timer.sh \
    BACKUP_INSTALL_DRY_RUN=1 BACKUP_SYSTEMD_DIR="$TODO11_FIXTURE/systemd" BACKUP_ENV_DIR="$TODO11_FIXTURE/env" || return 2
  todo11_run "$TODO11_FIXTURE/systemd-b.log" host-b install-systemd-timer.sh \
    BACKUP_INSTALL_DRY_RUN=1 BACKUP_SYSTEMD_DIR="$TODO11_FIXTURE/systemd" BACKUP_ENV_DIR="$TODO11_FIXTURE/env" || return 2
  grep -Fq 'encrypted-git-backup-host-a.service' "$TODO11_FIXTURE/systemd-a.log" || return 2
  grep -Fq 'encrypted-git-backup-host-b.service' "$TODO11_FIXTURE/systemd-b.log" || return 2
  for output in "$TODO11_FIXTURE/systemd-a.log" "$TODO11_FIXTURE/systemd-b.log"; do
    grep -Fq 'User=backupsvc' "$output" || return 2
    grep -Fq 'Group=backupsvc' "$output" || return 2
    grep -Fq 'OnCalendar=weekly' "$output" || return 2
  done
}

todo11_migration_report() {
  local status
  todo11_snapshot "$TODO11_FIXTURE/before.snapshot"
  if todo11_run "$TODO11_FIXTURE/migration.log" host-a migrate-legacy.sh; then
    status=0
  else
    status=$?
  fi
  [[ "$status" -eq 0 || "$status" -eq 3 ]] || return 2
  todo11_snapshot "$TODO11_FIXTURE/after.snapshot"
  cmp -s "$TODO11_FIXTURE/before.snapshot" "$TODO11_FIXTURE/after.snapshot" || return 2
  if [[ "$status" -eq 0 ]]; then
    grep -Fq 'MIGRATION_STATUS=clean' "$TODO11_FIXTURE/migration.log" || return 2
  else
    grep -Fq 'MIGRATION_STATUS=attention-required' "$TODO11_FIXTURE/migration.log" || return 2
    grep -Fq 'RECOVERY:' "$TODO11_FIXTURE/migration.log" || return 2
  fi
  TODO11_MIGRATION_HASH="$(<"$TODO11_FIXTURE/before.snapshot")"
}

todo11_ensure_fixture() {
  [[ "$TODO11_READY" -eq 0 ]] || return 0
  new_fixture todo11-f3 || return 2
  TODO11_FIXTURE="$FIXTURE"
  TODO11_REPO="$TODO11_FIXTURE/repo"
  TODO11_CANONICAL="$TODO11_FIXTURE/canonical.git"
  TODO11_MIRROR_A="$TODO11_FIXTURE/mirror-a.git"
  TODO11_MIRROR_B="$TODO11_FIXTURE/mirror-b.git"
  TODO11_IDENTITY="$TODO11_FIXTURE/age-identity.txt"
  copy_template "$TODO11_REPO"
  age-keygen -o "$TODO11_IDENTITY" >"$TODO11_FIXTURE/age-keygen.log" 2>&1 || return 2
  TODO11_RECIPIENT="$(age-keygen -y "$TODO11_IDENTITY")" || return 2
  mkdir -p "$TODO11_FIXTURE/data/host-a" "$TODO11_FIXTURE/data/host-b"
  printf 'RESTORE_SENTINEL_A\n' >"$TODO11_FIXTURE/data/host-a/sentinel-a.txt"
  printf 'RESTORE_SENTINEL_B\n' >"$TODO11_FIXTURE/data/host-b/sentinel-b.txt"
  todo11_write_config host-a "$TODO11_FIXTURE/data/host-a"
  todo11_write_config host-b "$TODO11_FIXTURE/data/host-b"
  for artifact in 2025-12-28T00-00-00Z 2025-12-29T00-00-00Z-000000001 2025-12-30T00-00-00Z 2025-12-31T00-00-00Z-000000001; do
    todo11_write_set host-a "$artifact"
  done
  todo11_write_set host-b 2025-12-31T12-00-00Z
  printf 'backups/host-a/2025-12-31T00-00-00Z-000000001.tar.zst.age\n' >"$TODO11_REPO/backups/host-a/latest.txt"
  printf 'backups/host-b/2025-12-31T12-00-00Z.tar.zst.age\n' >"$TODO11_REPO/backups/host-b/latest.txt"
  init_real_repo "$TODO11_REPO" || return 2
  for remote in "$TODO11_CANONICAL" "$TODO11_MIRROR_A" "$TODO11_MIRROR_B"; do git init -q --bare "$remote" || return 2; done
  git -C "$TODO11_REPO" remote add canonical "$TODO11_CANONICAL"
  git -C "$TODO11_REPO" remote add mirror-a "$TODO11_MIRROR_A"
  git -C "$TODO11_REPO" remote add mirror-b "$TODO11_MIRROR_B"
  for remote in canonical mirror-a mirror-b; do git -C "$TODO11_REPO" push -q "$remote" HEAD:refs/heads/main || return 2; done
  todo11_prepare_and_restore || return 2
  todo11_publish_retry || return 2
  todo11_publish_host_b || return 2
  todo11_render_systemd || return 2
  todo11_migration_report || return 2
  TODO11_READY=1
  printf 'F3_COMPONENTS crypto=real-age archive=real-tar-zstd git=real-local systemd=render-only migration=real-report mirror-failure=git-wrapper\n'
  printf 'F3_OIDS retry=%s final=%s remotes=3\n' "$TODO11_RETRY_OID" "$TODO11_FINAL_OID"
  printf 'F3_RESTORE sentinel=RESTORE_SENTINEL_A checksum=verified strict_state=verified\n'
  printf 'F3_RETENTION host-a=%s host-b=%s\n' "$TODO11_HOST_A_COUNT" "$TODO11_HOST_B_COUNT"
  printf 'F3_SYSTEMD hosts=2 user=backupsvc group=backupsvc schedule=weekly\n'
  printf 'F3_MIGRATION no_mutation_sha256=%s\n' "$TODO11_MIGRATION_HASH"
}

scenario_e2e_prepare_decrypt_publish() { todo11_ensure_fixture; }
scenario_e2e_mirror_retry() { todo11_ensure_fixture; }
scenario_e2e_multi_host_retention() { todo11_ensure_fixture; }
scenario_e2e_systemd_render() { todo11_ensure_fixture; }
scenario_e2e_migration_dry_run() { todo11_ensure_fixture; }
