#!/usr/bin/env bash

todo5_write_set() {
  local repo="$1" host="$2" artifact_id="$3" archive relative digest
  mkdir -p "$repo/backups/$host" "$repo/manifests/$host"
  relative="backups/$host/${artifact_id}.tar.zst.age"
  archive="$repo/$relative"
  printf 'encrypted %s %s\n' "$host" "$artifact_id" >"$archive"
  digest="$(/usr/bin/sha256sum "$archive" | cut -d ' ' -f 1)"
  printf '%s  %s\n' "$digest" "$relative" >"$repo/backups/$host/${artifact_id}.sha256"
  printf '{"host_id":"%s","timestamp_utc":"%s","encrypted_archive":"%s","encrypted_archive_sha256":"%s"}\n' \
    "$host" "$artifact_id" "$relative" "$digest" >"$repo/manifests/$host/${artifact_id}.json"
}

todo5_setup() {
  local name="$1"
  new_fixture "todo5-$name" || return 2
  TODO5_FIXTURE="$FIXTURE"
  TODO5_REPO="$TODO5_FIXTURE/repo"
  TODO5_DATA="$TODO5_FIXTURE/data"
  TODO5_CANONICAL="$TODO5_FIXTURE/canonical.git"
  copy_template "$TODO5_REPO"
  install_common_shims "$TODO5_FIXTURE"
  install_fixed_date_shim "$TODO5_FIXTURE"
  rm -f "$TODO5_FIXTURE/bin/git"
  mkdir -p "$TODO5_DATA"
  printf 'payload\n' >"$TODO5_DATA/payload.txt"
  todo4_write_config "$TODO5_REPO" "$TODO5_DATA" main canonical
}

todo5_finalize_setup() {
  init_real_repo "$TODO5_REPO" || return 2
  /usr/bin/git init -q --bare "$TODO5_CANONICAL" || return 2
  /usr/bin/git -C "$TODO5_REPO" remote add canonical "$TODO5_CANONICAL" || return 2
  /usr/bin/git -C "$TODO5_REPO" push -q canonical HEAD:refs/heads/main || return 2
  TODO5_STATE="$TODO5_REPO/.git/local-backup-push-kit/prepared/testbox.state"
}

todo5_run() {
  local output="$1"
  shift
  local -a environment
  mapfile -t environment < <(fixture_env "$TODO5_FIXTURE")
  run_captured "$output" 12 env "${environment[@]}" BACKUP_HOST=testbox BACKUP_RETENTION_COUNT=3 "$@"
}

todo5_prepare() {
  todo5_run "$TODO5_FIXTURE/prepare.log" BACKUP_PUSH=0 bash "$TODO5_REPO/scripts/backup.sh"
}

todo5_publish() {
  todo5_run "$TODO5_FIXTURE/publish.log" bash "$TODO5_REPO/scripts/publish-prepared.sh"
}

todo5_inventory() {
  local destination="$1"
  /usr/bin/python3 - "$TODO5_REPO" "$destination" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
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
pathlib.Path(sys.argv[2]).write_text(digest.hexdigest() + "\n", encoding="utf-8")
PY
}

todo5_seed_mixed_hosts() {
  local artifact_id
  for artifact_id in \
    2025-12-31T23-59-58Z \
    2026-01-01T00-00-00Z-000000001 \
    2026-01-01T00-00-01Z \
    2026-01-01T00-00-02Z-000000001; do
    todo5_write_set "$TODO5_REPO" testbox "$artifact_id"
  done
  for artifact_id in 2025-11-01T00-00-00Z 2025-11-02T00-00-00Z-000000001; do
    todo5_write_set "$TODO5_REPO" host-b "$artifact_id"
  done
  printf '%s\n' 'backups/testbox/2026-01-01T00-00-02Z-000000001.tar.zst.age' >"$TODO5_REPO/backups/testbox/latest.txt"
  printf 'unrelated sentinel\n' >"$TODO5_REPO/backups/testbox/keep.txt"
}

todo5_assert_success_inventory() {
  /usr/bin/python3 - "$TODO5_REPO" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
host_a = sorted((root / "backups/testbox").glob("*.tar.zst.age"))
host_b = sorted((root / "backups/host-b").glob("*.tar.zst.age"))
assert len(host_a) == 3, host_a
assert len(host_b) == 2, host_b
for archive in host_a:
    artifact = archive.name.removesuffix(".tar.zst.age")
    assert (archive.parent / f"{artifact}.sha256").is_file()
    assert (root / "manifests/testbox" / f"{artifact}.json").is_file()
assert (root / "backups/testbox/keep.txt").read_text() == "unrelated sentinel\n"
latest = (root / "backups/testbox/latest.txt").read_text().strip()
assert latest == "backups/testbox/2026-01-02T03-04-05Z-000000001.tar.zst.age", latest
PY
}

scenario_retention_old_new() {
  todo5_setup old-new || return 2
  todo5_seed_mixed_hosts
  todo5_finalize_setup || return 2
  todo5_prepare || return 2
  /usr/bin/python3 - "$TODO5_STATE" <<'PY'
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert state["retention_deletions"] == [
    "backups/testbox/2025-12-31T23-59-58Z.tar.zst.age",
    "backups/testbox/2025-12-31T23-59-58Z.sha256",
    "manifests/testbox/2025-12-31T23-59-58Z.json",
    "backups/testbox/2026-01-01T00-00-00Z-000000001.tar.zst.age",
    "backups/testbox/2026-01-01T00-00-00Z-000000001.sha256",
    "manifests/testbox/2026-01-01T00-00-00Z-000000001.json",
]
for relative in state["retention_deletions"]:
    assert (pathlib.Path(sys.argv[1]).parents[3] / relative).is_file()
PY
  todo5_publish || return 2
  todo5_assert_success_inventory
}

scenario_retention_rename_detection() {
  todo5_setup rename-detection || return 2
  mkdir -p "$TODO5_REPO/manifests/testbox"
  printf '{"shared":"rename candidate"}\n' >"$TODO5_REPO/manifests/testbox/old.json"
  todo5_finalize_setup || return 2
  cp "$TODO5_REPO/manifests/testbox/old.json" "$TODO5_REPO/manifests/testbox/new.json"
  rm -f "$TODO5_REPO/manifests/testbox/old.json"
  /usr/bin/git -C "$TODO5_REPO" add -- manifests/testbox/old.json manifests/testbox/new.json || return 2
  /usr/bin/git -C "$TODO5_REPO" config diff.renames true
  [[ "$(/usr/bin/git -C "$TODO5_REPO" diff --cached --name-only | wc -l)" == 1 ]] || return 2
  [[ "$(/usr/bin/git -C "$TODO5_REPO" diff --cached --no-renames --name-only | wc -l)" == 2 ]] || return 2
  (
    REPO_DIR="$TODO5_REPO"
    source "$TODO5_REPO/scripts/lib/prepare.sh"
    PREPARED_INDEX_PATHS=(
      "manifests/testbox/old.json"
      "manifests/testbox/new.json"
    )
    require_exact_prepared_index
  ) || return 2
}

scenario_retention_empty() {
  todo5_setup empty || return 2
  todo5_finalize_setup || return 2
  todo5_prepare || return 2
  /usr/bin/python3 - "$TODO5_STATE" <<'PY'
import json, pathlib, sys
assert json.loads(pathlib.Path(sys.argv[1]).read_text())["retention_deletions"] == []
PY
  todo5_publish || return 2
  todo5_assert_success_inventory_empty
}

todo5_assert_success_inventory_empty() {
  [[ "$(find "$TODO5_REPO/backups/testbox" -maxdepth 1 -type f -name '*.tar.zst.age' | wc -l)" == 1 ]] || return 2
}

scenario_retention_orphan() {
  todo5_setup orphan || return 2
  todo5_write_set "$TODO5_REPO" testbox 2026-01-01T00-00-02Z
  printf 'orphan archive\n' >"$TODO5_REPO/backups/testbox/2020-01-01T00-00-00Z.tar.zst.age"
  printf 'orphan checksum\n' >"$TODO5_REPO/backups/testbox/2019-01-01T00-00-00Z.sha256"
  printf 'sentinel\n' >"$TODO5_REPO/manifests/testbox/unrelated.txt"
  todo5_finalize_setup || return 2
  todo5_prepare || return 2
  todo5_publish || return 2
  [[ -f "$TODO5_REPO/backups/testbox/2020-01-01T00-00-00Z.tar.zst.age" ]] || return 2
  [[ -f "$TODO5_REPO/backups/testbox/2019-01-01T00-00-00Z.sha256" ]] || return 2
  [[ -f "$TODO5_REPO/manifests/testbox/unrelated.txt" ]] || return 2
}

scenario_latest_repair() {
  todo5_setup latest || return 2
  todo5_write_set "$TODO5_REPO" testbox 2026-01-01T00-00-02Z
  printf 'broken/latest\n' >"$TODO5_REPO/backups/testbox/latest.txt"
  todo5_finalize_setup || return 2
  todo5_prepare || return 2
  todo5_publish || return 2
  [[ "$(<"$TODO5_REPO/backups/testbox/latest.txt")" == 'backups/testbox/2026-01-02T03-04-05Z-000000001.tar.zst.age' ]] || return 2
}

scenario_retention_commit_failure() {
  todo5_setup commit-failure || return 2
  todo5_seed_mixed_hosts
  todo5_finalize_setup || return 2
  todo5_prepare || return 2
  todo5_inventory "$TODO5_FIXTURE/before.inventory"
  /usr/bin/git -C "$TODO5_REPO" write-tree >"$TODO5_FIXTURE/before.index"
  /usr/bin/sha256sum "$TODO5_STATE" >"$TODO5_FIXTURE/before.state"
  local base
  base="$(/usr/bin/git -C "$TODO5_REPO" rev-parse HEAD)"
  cat >"$TODO5_FIXTURE/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *' commit '* ]]; then exit 86; fi
exec /usr/bin/git "$@"
EOF
  chmod +x "$TODO5_FIXTURE/bin/git"
  if todo5_publish; then return 2; fi
  todo5_inventory "$TODO5_FIXTURE/after.inventory"
  /usr/bin/git -C "$TODO5_REPO" write-tree >"$TODO5_FIXTURE/after.index"
  /usr/bin/sha256sum "$TODO5_STATE" >"$TODO5_FIXTURE/after.state"
  cmp -s "$TODO5_FIXTURE/before.inventory" "$TODO5_FIXTURE/after.inventory" || return 2
  cmp -s "$TODO5_FIXTURE/before.index" "$TODO5_FIXTURE/after.index" || return 2
  cmp -s "$TODO5_FIXTURE/before.state" "$TODO5_FIXTURE/after.state" || return 2
  [[ "$(/usr/bin/git -C "$TODO5_REPO" rev-parse HEAD)" == "$base" ]] || return 2
}

scenario_retention() { scenario_retention_old_new; }
scenario_retention_failure() { scenario_retention_commit_failure; }
scenario_retention_multi_host() { scenario_retention_old_new; }
