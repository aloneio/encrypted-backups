#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/prepare.sh"
source "$SCRIPT_DIR/lib/publication-schema.sh"
source "$SCRIPT_DIR/lib/git-remotes.sh"

ACTION=report
SYSTEMD_DIR="${MIGRATION_SYSTEMD_DIR:-/etc/systemd/system}"
MIGRATION_TEMP=""
MIGRATION_CREATED_STATE_DIR=0

usage() {
  printf 'Usage: BACKUP_HOST=<host> %s [--adopt-staged]\n' "${0##*/}" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --adopt-staged) ACTION=adopt ;;
    -h|--help) usage; exit 0 ;;
    *) usage; printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
  shift
done

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  printf 'RECOVERY: correct the reported condition, then rerun the report without flags.\n' >&2
  exit 1
}

cleanup_migration() {
  local status=$?
  trap - EXIT INT TERM HUP
  [[ -z "$MIGRATION_TEMP" ]] || rm -f -- "$MIGRATION_TEMP"
  if [[ "$MIGRATION_CREATED_STATE_DIR" == 1 ]]; then
    rmdir "$PREPARED_STATE_DIR" "$REPO_DIR/.git/local-backup-push-kit" 2>/dev/null || true
  fi
  return "$status"
}

handle_migration_signal() {
  local status="$1"
  cleanup_migration
  exit "$status"
}

trap cleanup_migration EXIT
trap 'handle_migration_signal 130' INT
trap 'handle_migration_signal 143' TERM
trap 'handle_migration_signal 129' HUP

load_migration_context() {
  local command_name current_branch
  for command_name in chmod cut git hostname mkdir mktemp mv python3 rm rmdir sha256sum stat; do
    need_cmd "$command_name"
  done
  [[ -d "$REPO_DIR/.git" ]] || fail "backup repository is not initialized"
  HOST_ID="${BACKUP_HOST-$(hostname -s)}"
  CONFIG_FILE="${BACKUP_CONFIG:-${REPO_DIR}/hosts/${HOST_ID}/backup.conf}"
  [[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || fail "missing or unsafe host config"
  source "$CONFIG_FILE"
  PUSH_BRANCH="${BACKUP_BRANCH-main}"
  LOCK_TIMEOUT="${BACKUP_LOCK_TIMEOUT-30}"
  validate_host_identifier BACKUP_HOST "$HOST_ID"
  validate_host_identifier CONFIG_HOST_ID "${CONFIG_HOST_ID:-}"
  [[ "$HOST_ID" == "$CONFIG_HOST_ID" ]] || fail "host mismatch"
  validate_branch_name "$PUSH_BRANCH"
  validate_lock_timeout "$LOCK_TIMEOUT"
  initialize_prepared_state
  current_branch="$(GIT_MASTER=1 git -C "$REPO_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null)" || fail "detached HEAD is not supported"
  [[ "$current_branch" == "$PUSH_BRANCH" ]] || fail "checked-out branch does not match BACKUP_BRANCH"
  BASE_OID="$(GIT_MASTER=1 git -C "$REPO_DIR" rev-parse --verify HEAD 2>/dev/null)" || fail "local repository has no template commit"
}

staged_paths() {
  GIT_MASTER=1 git -C "$REPO_DIR" diff --cached --no-renames --name-only -z
}

classify_staged_set() {
  mapfile -d '' -t STAGED_PATHS < <(staged_paths)
  STAGED_CLASSIFICATION="$(python3 - "$HOST_ID" "${STAGED_PATHS[@]}" <<'PY'
import re
import sys

host, *paths = sys.argv[1:]
identifier = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z(?:-[0-9]{9})?"
archive = re.compile(rf"backups/{re.escape(host)}/({identifier})\.tar\.zst\.age")
checksum = re.compile(rf"backups/{re.escape(host)}/({identifier})\.sha256")
manifest = re.compile(rf"manifests/{re.escape(host)}/({identifier})\.json")
latest = f"backups/{host}/latest.txt"
ids = []
roles = set()
for path in paths:
    if path == latest:
        roles.add("latest")
        continue
    for role, pattern in (("archive", archive), ("checksum", checksum), ("manifest", manifest)):
        match = pattern.fullmatch(path)
        if match:
            roles.add(role)
            ids.append(match.group(1))
            break
    else:
        print("unrelated")
        raise SystemExit
if not paths:
    print("empty")
elif len(paths) == 4 and roles == {"archive", "checksum", "manifest", "latest"} and len(set(ids)) == 1:
    print("complete:" + ids[0])
else:
    print("incomplete")
PY
)" || fail "cannot classify staged files"
}

report_remote_state() {
  local remote canonical_oid="" local_relation oid
  declare -gA MIGRATION_REMOTE_OIDS=()
  MIGRATION_CANONICAL_BRANCH_EXISTS=0
  for remote in "${PUSH_REMOTES[@]}"; do
    query_remote_branch "$remote" "$PUSH_BRANCH"
    oid="$REMOTE_BRANCH_OID"
    MIGRATION_REMOTE_OIDS["$remote"]="$oid"
    if [[ "$remote" == "$CANONICAL_REMOTE" ]]; then
      canonical_oid="$oid"
      MIGRATION_CANONICAL_BRANCH_EXISTS="$REMOTE_BRANCH_EXISTS"
    fi
  done
  if [[ -n "$canonical_oid" && "$BASE_OID" != "$canonical_oid" ]]; then
    local_relation=diverged
    if GIT_MASTER=1 git -C "$REPO_DIR" merge-base --is-ancestor "$canonical_oid" "$BASE_OID" 2>/dev/null; then
      local_relation=ahead
    elif GIT_MASTER=1 git -C "$REPO_DIR" merge-base --is-ancestor "$BASE_OID" "$canonical_oid" 2>/dev/null; then
      local_relation=behind
    fi
    case "$local_relation" in
      ahead)
        printf 'ISSUE: unpublished local commits on %s\n' "$PUSH_BRANCH"
        printf 'RECOVERY: publish or reconcile the local branch before migration.\n'
        ;;
      behind)
        printf 'ISSUE: local branch is behind the canonical remote\n'
        printf 'RECOVERY: fast-forward the local branch before migration.\n'
        ;;
      *)
        printf 'ISSUE: local branch diverges from the canonical remote\n'
        printf 'RECOVERY: reconcile local and canonical history manually; this helper will not reset commits.\n'
        ;;
    esac
    REPORT_ISSUES=$((REPORT_ISSUES + 1))
  fi
  for remote in "${PUSH_REMOTES[@]:1}"; do
    oid="${MIGRATION_REMOTE_OIDS[$remote]}"
    if [[ -n "$canonical_oid" && -n "$oid" && "$oid" != "$canonical_oid" ]]; then
      printf 'ISSUE: divergent mirror OID for remote %s\n' "$remote"
      printf 'RECOVERY: reconcile the mirror manually; no force push is performed by this helper.\n'
      REPORT_ISSUES=$((REPORT_ISSUES + 1))
    fi
  done
}

report_legacy_files() {
  local artifact
  mapfile -t LEGACY_ARTIFACTS < <(python3 - "$REPO_DIR" "$HOST_ID" <<'PY'
import pathlib
import re
import sys

root, host = pathlib.Path(sys.argv[1]), sys.argv[2]
pattern = re.compile(r"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z)\.tar\.zst\.age")
directory = root / "backups" / host
if directory.is_dir() and not directory.is_symlink():
    for path in sorted(directory.iterdir()):
        if path.is_file() and not path.is_symlink():
            match = pattern.fullmatch(path.name)
            if match:
                print(match.group(1))
PY
)
  for artifact in "${LEGACY_ARTIFACTS[@]}"; do
    printf 'ISSUE: legacy timestamp backup set %s\n' "$artifact"
    printf 'RECOVERY: if this exact set is staged and complete, run BACKUP_HOST=%q scripts/migrate-legacy.sh --adopt-staged.\n' "$HOST_ID"
    REPORT_ISSUES=$((REPORT_ISSUES + 1))
  done
}

report_operational_files() {
  local path name service
  for name in encrypted-github-backup encrypted-git-backup; do
    for path in "$SYSTEMD_DIR/$name.service" "$SYSTEMD_DIR/$name.timer"; do
      if [[ -e "$path" || -L "$path" ]]; then
        printf 'ISSUE: legacy root timer unit %s\n' "${path##*/}"
        printf 'RECOVERY: review the unit, then explicitly migrate with BACKUP_HOST=%q scripts/install-systemd-timer.sh --migrate-legacy; this report does not replace units.\n' "$HOST_ID"
        REPORT_ISSUES=$((REPORT_ISSUES + 1))
      fi
    done
  done
  service="$SYSTEMD_DIR/encrypted-git-backup-$HOST_ID.service"
  if [[ -f "$service" && ! -L "$service" ]] && grep -Fq 'User=root' "$service" && grep -Fq "$REPO_DIR/scripts/backup.sh" "$service"; then
    printf 'ISSUE: direct root repository timer unit %s\n' "${service##*/}"
    printf 'RECOVERY: reinstall with BACKUP_HOST=%q scripts/install-systemd-timer.sh so root execution uses the trusted launcher.\n' "$HOST_ID"
    REPORT_ISSUES=$((REPORT_ISSUES + 1))
  fi
  for path in .github/workflows/retention.yml; do
    if [[ -e "$REPO_DIR/$path" || -L "$REPO_DIR/$path" ]]; then
      printf 'ISSUE: copied legacy retention CI file %s\n' "$path"
      printf 'RECOVERY: review and remove the copied legacy CI file manually; this helper does not delete files.\n'
      REPORT_ISSUES=$((REPORT_ISSUES + 1))
    fi
  done
}

run_report() {
  REPORT_ISSUES=0
  classify_staged_set
  case "$STAGED_CLASSIFICATION" in
    complete:*)
      printf 'ISSUE: legacy staged backup set %s\n' "${STAGED_CLASSIFICATION#complete:}"
      printf 'RECOVERY: run BACKUP_HOST=%q scripts/migrate-legacy.sh --adopt-staged after reviewing this report.\n' "$HOST_ID"
      REPORT_ISSUES=$((REPORT_ISSUES + 1))
      ;;
    empty) ;;
    incomplete|unrelated)
      printf 'ISSUE: staged files are not one complete legacy backup set\n'
      printf 'RECOVERY: inspect git diff --cached --name-status and stage exactly one archive/checksum/manifest/latest set.\n'
      REPORT_ISSUES=$((REPORT_ISSUES + 1))
      ;;
  esac
  report_remote_state
  report_legacy_files
  report_operational_files
  if [[ "$REPORT_ISSUES" -eq 0 ]]; then
    printf 'MIGRATION_STATUS=clean\n'
    return 0
  fi
  printf 'MIGRATION_STATUS=attention-required issues=%s\n' "$REPORT_ISSUES"
  return 3
}

validate_and_write_state() {
  local artifact_id="$1" index_before temporary_parent_existed=0
  [[ ! -e "$PREPARED_STATE_FILE" && ! -L "$PREPARED_STATE_FILE" ]] || fail "prepared state already exists"
  [[ ! -e "$PREPARED_STATE_DIR" ]] || temporary_parent_existed=1
  index_before="$(GIT_MASTER=1 git -C "$REPO_DIR" write-tree)" || fail "cannot snapshot the staged index"
  ADOPTION_VALUES="$(python3 - "$REPO_DIR" "$HOST_ID" "$artifact_id" <<'PY'
import hashlib
import json
import pathlib
import re
import stat
import sys

root, host, artifact = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
archive_rel = f"backups/{host}/{artifact}.tar.zst.age"
checksum_rel = f"backups/{host}/{artifact}.sha256"
manifest_rel = f"manifests/{host}/{artifact}.json"
latest_rel = f"backups/{host}/latest.txt"
paths = [archive_rel, checksum_rel, manifest_rel, latest_rel]
for relative in paths:
    path = root / relative
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise SystemExit(f"unsafe legacy file: {relative}")
archive_hash = hashlib.sha256((root / archive_rel).read_bytes()).hexdigest()
checksum_bytes = (root / checksum_rel).read_bytes()
match = re.fullmatch(rb"([0-9a-f]{64})[ \t]+([^\r\n]+)\n?", checksum_bytes)
if match is None or match.group(1).decode() != archive_hash or match.group(2).decode() != archive_rel:
    raise SystemExit("legacy checksum mismatch")
latest_bytes = (root / latest_rel).read_bytes()
if latest_bytes != (archive_rel + "\n").encode():
    raise SystemExit("legacy latest pointer mismatch")
with (root / manifest_rel).open(encoding="utf-8") as handle:
    manifest = json.load(handle)
if not isinstance(manifest, dict):
    raise SystemExit("legacy manifest is not an object")
expected = {
    "host_id": host,
    "timestamp_utc": artifact,
    "encrypted_archive": archive_rel,
    "encrypted_archive_sha256": archive_hash,
}
if any(manifest.get(key) != value for key, value in expected.items()):
    raise SystemExit("legacy manifest mismatch")
hashes = [hashlib.sha256((root / relative).read_bytes()).hexdigest() for relative in paths]
print("\n".join(paths + hashes))
PY
)" || fail "legacy archive/checksum/manifest/latest validation failed"
  mapfile -t ADOPTION_FIELDS <<<"$ADOPTION_VALUES"
  [[ ${#ADOPTION_FIELDS[@]} -eq 8 ]] || fail "legacy validation returned incomplete state data"
  [[ -z "$(GIT_MASTER=1 git -C "$REPO_DIR" diff --name-only)" ]] || fail "legacy staged files differ from the worktree"
  [[ -z "$(GIT_MASTER=1 git -C "$REPO_DIR" ls-files --others --exclude-standard)" ]] || fail "untracked files prevent safe adoption"
  validate_internal_storage_paths
  mkdir -p "$PREPARED_STATE_DIR"
  [[ "$temporary_parent_existed" == 1 ]] || MIGRATION_CREATED_STATE_DIR=1
  MIGRATION_TEMP="$(mktemp "$PREPARED_STATE_DIR/.${HOST_ID}.migration.XXXXXX")"
  [[ "$MIGRATION_CANONICAL_BRANCH_EXISTS" == 0 || "$MIGRATION_CANONICAL_BRANCH_EXISTS" == 1 ]] || fail "canonical branch state is unavailable"
  python3 - "$MIGRATION_TEMP" "$HOST_ID" "$PUSH_BRANCH" "$BASE_OID" "$MIGRATION_CANONICAL_BRANCH_EXISTS" "$artifact_id" \
    "${ADOPTION_FIELDS[@]}" --remotes "${PUSH_REMOTES[@]}" <<'PY'
import json
import sys

destination, host, branch, base_oid, canonical_branch_exists, artifact, *remaining = sys.argv[1:]
if canonical_branch_exists not in {"0", "1"}:
    raise SystemExit("invalid canonical branch state")
separator = remaining.index("--remotes")
fields, remotes = remaining[:separator], remaining[separator + 1:]
if len(fields) != 8 or not remotes:
    raise SystemExit("invalid adoption state arguments")
archive, checksum, manifest, latest, archive_hash, checksum_hash, manifest_hash, latest_hash = fields
paths = {"archive": archive, "checksum": checksum, "manifest": manifest, "latest": latest}
ordered = [archive, checksum, manifest, latest]
state = {
    "version": 2,
    "host": host,
    "branch": branch,
    "base_oid": base_oid,
    "canonical_branch_exists": canonical_branch_exists == "1",
    "remotes": remotes,
    "paths": paths,
    "hashes": dict(zip(ordered, (archive_hash, checksum_hash, manifest_hash, latest_hash))),
    "staged_paths": ordered,
    "retention_deletions": [],
    "committed_oid": "",
    "publication": {
        "artifact_id": artifact,
        "commit_message": f"Add {host} encrypted backup {artifact}",
        "remotes": [
            {"name": remote, "status": "pending", "published_oid": "", "error": ""}
            for remote in remotes
        ],
    },
}
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(state, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  chmod 0600 "$MIGRATION_TEMP"
  [[ "$(GIT_MASTER=1 git -C "$REPO_DIR" rev-parse HEAD)" == "$BASE_OID" ]] || fail "HEAD changed during adoption"
  [[ "$(GIT_MASTER=1 git -C "$REPO_DIR" write-tree)" == "$index_before" ]] || fail "staged index changed during adoption"
  [[ -z "$(GIT_MASTER=1 git -C "$REPO_DIR" diff --name-only)" ]] || fail "legacy staged files changed during adoption"
  [[ -z "$(GIT_MASTER=1 git -C "$REPO_DIR" ls-files --others --exclude-standard)" ]] || fail "untracked files appeared during adoption"
  local index relative actual_hash
  for index in 0 1 2 3; do
    relative="${ADOPTION_FIELDS[$index]}"
    actual_hash="$(sha256sum "$REPO_DIR/$relative" | cut -d ' ' -f 1)"
    [[ "$actual_hash" == "${ADOPTION_FIELDS[$((index + 4))]}" ]] || fail "legacy file changed during adoption"
  done
  mv -f -- "$MIGRATION_TEMP" "$PREPARED_STATE_FILE"
  MIGRATION_TEMP=""
  MIGRATION_CREATED_STATE_DIR=0
  trap - EXIT INT TERM HUP
  printf 'MIGRATION_STATUS=adopted artifact=%s state=%s\n' "$artifact_id" "${PREPARED_STATE_FILE#"$REPO_DIR"/}"
}

run_adoption() {
  local artifact_id name path
  classify_staged_set
  [[ "$STAGED_CLASSIFICATION" == complete:* ]] || fail "staged files are not exactly one complete legacy backup set"
  artifact_id="${STAGED_CLASSIFICATION#complete:}"
  [[ "$artifact_id" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z(-[0-9]{9})?$ ]] || fail "unsupported legacy artifact name"
  REPORT_ISSUES=0
  report_remote_state >/dev/null
  [[ "$REPORT_ISSUES" -eq 0 ]] || fail "remote or branch divergence prevents safe adoption"
  [[ ! -e "$REPO_DIR/.github/workflows/retention.yml" && ! -L "$REPO_DIR/.github/workflows/retention.yml" ]] || fail "copied legacy retention CI prevents safe adoption"
  for name in encrypted-github-backup encrypted-git-backup; do
    for path in "$SYSTEMD_DIR/$name.service" "$SYSTEMD_DIR/$name.timer"; do
      [[ ! -e "$path" && ! -L "$path" ]] || fail "legacy root timer units prevent safe adoption"
    done
  done
  validate_and_write_state "$artifact_id"
}

load_migration_context
case "$ACTION" in
  report)
    validate_remote_configuration
    run_report
    ;;
  adopt)
    acquire_backup_lock
    validate_remote_configuration
    run_adoption
    ;;
esac
