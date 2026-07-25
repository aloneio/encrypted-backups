#!/usr/bin/env bash

initialize_prepared_state() {
  PREPARED_STATE_DIR="$REPO_DIR/.git/local-backup-push-kit/prepared"
  PREPARED_STATE_FILE="$PREPARED_STATE_DIR/$HOST_ID.state"
}

require_safe_internal_path() {
  local path="$1" kind="$2"
  path_has_symlink_component "$path" && fail "internal $kind path must not contain symlinks: $path"
  return 0
}

validate_internal_storage_paths() {
  local path links
  for path in \
    "$REPO_DIR/.git/local-backup-push-kit" \
    "$REPO_DIR/.git/local-backup-push-kit/lock" \
    "$PREPARED_STATE_DIR" \
    "$PREPARED_STATE_FILE" \
    "$REPO_DIR/backups" \
    "$REPO_DIR/backups/$HOST_ID" \
    "$REPO_DIR/manifests" \
    "$REPO_DIR/manifests/$HOST_ID"; do
    require_safe_internal_path "$path" storage
  done
  for path in "$REPO_DIR/backups" "$REPO_DIR/backups/$HOST_ID" "$REPO_DIR/manifests" "$REPO_DIR/manifests/$HOST_ID" "$PREPARED_STATE_DIR"; do
    [[ ! -e "$path" || -d "$path" ]] || fail "internal storage path is not a directory: $path"
  done
  [[ ! -e "$PREPARED_STATE_FILE" || -f "$PREPARED_STATE_FILE" ]] || fail "prepared state path is not a regular file"
  for path in "$REPO_DIR/.git/local-backup-push-kit/lock" "$PREPARED_STATE_FILE"; do
    if [[ -e "$path" ]]; then
      [[ -f "$path" && ! -L "$path" ]] || fail "internal state path is not a regular file: $path"
      links="$(stat -c %h -- "$path")"
      [[ "$links" == "1" ]] || fail "internal state path must have exactly one hard link: $path"
    fi
  done
}

validate_final_storage_paths() {
  local path links
  for path in "$PREPARATION_ARCHIVE" "$PREPARATION_CHECKSUM" "$PREPARATION_MANIFEST" "$PREPARATION_LATEST"; do
    require_safe_internal_path "$path" output
    if [[ -e "$path" ]]; then
      [[ -f "$path" && ! -L "$path" ]] || fail "existing output path is not a regular file: $path"
      links="$(stat -c %h -- "$path")"
      [[ "$links" == "1" ]] || fail "existing output path must have exactly one hard link: $path"
    fi
  done
}

require_exact_prepared_index() {
  local actual relative
  local -A expected=()
  local -a actual_paths=()
  local -a expected_paths=()
  if declare -p PREPARED_INDEX_PATHS >/dev/null 2>&1; then
    expected_paths=("${PREPARED_INDEX_PATHS[@]}")
  else
    expected_paths=("${PREPARED_PATHS[@]}")
  fi
  for relative in "${expected_paths[@]}"; do
    expected["$relative"]=1
  done
  mapfile -d '' -t actual_paths < <(GIT_MASTER=1 git -C "$REPO_DIR" diff --cached --name-only -z)
  [[ ${#actual_paths[@]} -eq ${#expected_paths[@]} ]] || fail "prepared index does not contain exactly the recorded paths"
  for actual in "${actual_paths[@]}"; do
    [[ -n "${expected[$actual]:-}" ]] || fail "prepared index contains an unrecorded path: $actual"
    unset 'expected[$actual]'
  done
  [[ ${#expected[@]} -eq 0 ]] || fail "prepared index is missing a recorded path"
}

require_no_unrelated_worktree_changes() {
  local unstaged untracked
  unstaged="$(GIT_MASTER=1 git -C "$REPO_DIR" diff --name-only)"
  untracked="$(GIT_MASTER=1 git -C "$REPO_DIR" ls-files --others --exclude-standard)"
  [[ -z "$unstaged" && -z "$untracked" ]] || fail "repository changed during backup preparation"
}

require_safe_prepared_files() {
  local relative links
  for relative in "${PREPARED_PATHS[@]}"; do
    [[ -f "$REPO_DIR/$relative" && ! -L "$REPO_DIR/$relative" ]] || fail "prepared file is missing or unsafe: $relative"
    links="$(stat -c %h -- "$REPO_DIR/$relative")"
    [[ "$links" == "1" ]] || fail "prepared file must have exactly one hard link: $relative"
  done
}

preparation_cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ "${PREPARATION_ACTIVE:-0}" == "1" ]]; then
    GIT_MASTER=1 git -C "$REPO_DIR" read-tree "$PREPARATION_INDEX_TREE" >/dev/null 2>&1 || true
    rm -f -- "${PREPARED_STATE_FILE:-}" "${PREPARATION_STATE_TEMP:-}"
    if [[ "${PREPARATION_FINALIZATION_STARTED:-0}" == "1" ]]; then
      rm -f -- "${PREPARATION_ARCHIVE:-}" "${PREPARATION_CHECKSUM:-}" "${PREPARATION_MANIFEST:-}"
      if [[ "${PREPARATION_LATEST_EXISTED:-0}" == "1" ]]; then
        /bin/cp -p -- "$PREPARATION_PREVIOUS_LATEST" "$PREPARATION_LATEST"
      else
        rm -f -- "${PREPARATION_LATEST:-}"
      fi
    fi
    rmdir "$REPO_DIR/backups/$HOST_ID" "$REPO_DIR/manifests/$HOST_ID" "$REPO_DIR/backups" "$REPO_DIR/manifests" 2>/dev/null || true
  fi
  rm -rf -- "${PREPARATION_TMPDIR:-}"
  return "$status"
}

activate_preparation_traps() {
  trap preparation_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

finish_preparation() {
  PREPARATION_ACTIVE=0
  rm -rf -- "$PREPARATION_TMPDIR"
  PREPARATION_TMPDIR=""
  trap - EXIT INT TERM HUP
}

write_manifest() {
  local destination="$1" artifact_id="$2" archive_rel="$3" archive_digest="$4"
  shift 4
  python3 - "$destination" "$HOST_ID" "$artifact_id" "$archive_rel" "$archive_digest" "$@" <<'PY'
import json
import sys

destination, host, artifact_id, archive, digest, *paths = sys.argv[1:]
data = {
    "host_id": host,
    "timestamp_utc": artifact_id,
    "encrypted_archive": archive,
    "encrypted_archive_sha256": digest,
    "included_paths": paths,
}
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, ensure_ascii=False)
    handle.write("\n")
PY
}

write_prepared_state() {
  local destination="$1" artifact_id="$2" base_oid="$3" canonical_branch_exists="$4"
  local archive_hash="$5" checksum_hash="$6" manifest_hash="$7" latest_hash="$8"
  shift 8
  python3 - "$destination" "$HOST_ID" "$PUSH_BRANCH" "$artifact_id" "$base_oid" "$canonical_branch_exists" \
    "$PREPARATION_REL_ARCHIVE" "$archive_hash" \
    "$PREPARATION_REL_CHECKSUM" "$checksum_hash" \
    "$PREPARATION_REL_MANIFEST" "$manifest_hash" \
    "$PREPARATION_REL_LATEST" "$latest_hash" \
    --retention "${RETENTION_DELETIONS[@]}" --remotes "$@" <<'PY'
import json
import sys

(
    destination,
    host,
    branch,
    artifact_id,
    base_oid,
    canonical_branch_exists,
    archive,
    archive_hash,
    checksum,
    checksum_hash,
    manifest,
    manifest_hash,
    latest,
    latest_hash,
    *remaining,
) = sys.argv[1:]
if "--retention" not in remaining or "--remotes" not in remaining:
    raise SystemExit("invalid state arguments")
retention_index = remaining.index("--retention")
remotes_index = remaining.index("--remotes")
if retention_index != 0 or remotes_index < 1:
    raise SystemExit("invalid state arguments")
if canonical_branch_exists not in {"0", "1"}:
    raise SystemExit("invalid canonical branch state")
retention_deletions = remaining[1:remotes_index]
remotes = remaining[remotes_index + 1:]
paths = {
    "archive": archive,
    "checksum": checksum,
    "manifest": manifest,
    "latest": latest,
}
staged_paths = [archive, checksum, manifest, latest]
commit_message = f"Add {host} encrypted backup {artifact_id}"
data = {
    "version": 2,
    "host": host,
    "branch": branch,
    "base_oid": base_oid,
    "canonical_branch_exists": canonical_branch_exists == "1",
    "remotes": remotes,
    "paths": paths,
    "hashes": {
        archive: archive_hash,
        checksum: checksum_hash,
        manifest: manifest_hash,
        latest: latest_hash,
    },
    "staged_paths": staged_paths,
    "retention_deletions": retention_deletions,
    "committed_oid": "",
    "publication": {
        "artifact_id": artifact_id,
        "commit_message": commit_message,
        "remotes": [
            {"name": remote, "status": "pending", "published_oid": "", "error": ""}
            for remote in remotes
        ],
    },
}
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

prepare_backup() {
  local artifact_id plain_archive encrypted_temp checksum_temp manifest_temp latest_temp archive_digest
  local checksum_digest manifest_digest latest_digest commit_message
  local -a tar_args=() existing_paths=("${BACKUP_PATHS[@]}") remotes=()

  [[ ! -e "$PREPARED_STATE_FILE" ]] || fail "prepared backup already exists for $HOST_ID"
  PREPARATION_ACTIVE=1
  PREPARATION_BASE_OID="$(GIT_MASTER=1 git -C "$REPO_DIR" rev-parse HEAD)"
  [[ "${CANONICAL_BRANCH_EXISTS:-}" == 0 || "${CANONICAL_BRANCH_EXISTS:-}" == 1 ]] || fail "canonical branch state is unavailable"
  PREPARATION_CANONICAL_BRANCH_EXISTS="$CANONICAL_BRANCH_EXISTS"
  PREPARATION_INDEX_TREE="$(GIT_MASTER=1 git -C "$REPO_DIR" write-tree)"
  PREPARATION_TMPDIR="$(mktemp -d)"
  PREPARATION_STATE_TEMP=""
  PREPARATION_LATEST_EXISTED=0
  PREPARATION_FINALIZATION_STARTED=0
  PREPARED_PATHS=()
  PREPARED_INDEX_PATHS=()
  PREPARED_RETENTION_DELETIONS=()
  RETENTION_DELETIONS=()
  activate_preparation_traps

  artifact_id="$(generate_artifact_id)"
  PREPARATION_REL_ARCHIVE="backups/$HOST_ID/${artifact_id}.tar.zst.age"
  PREPARATION_REL_CHECKSUM="backups/$HOST_ID/${artifact_id}.sha256"
  PREPARATION_REL_MANIFEST="manifests/$HOST_ID/${artifact_id}.json"
  PREPARATION_REL_LATEST="backups/$HOST_ID/latest.txt"
  PREPARED_PATHS=("$PREPARATION_REL_ARCHIVE" "$PREPARATION_REL_CHECKSUM" "$PREPARATION_REL_MANIFEST" "$PREPARATION_REL_LATEST")
  PREPARATION_ARCHIVE="$REPO_DIR/$PREPARATION_REL_ARCHIVE"
  PREPARATION_CHECKSUM="$REPO_DIR/$PREPARATION_REL_CHECKSUM"
  PREPARATION_MANIFEST="$REPO_DIR/$PREPARATION_REL_MANIFEST"
  PREPARATION_LATEST="$REPO_DIR/$PREPARATION_REL_LATEST"
  PREPARATION_PREVIOUS_LATEST="$PREPARATION_TMPDIR/previous-latest"
  validate_final_storage_paths

  plain_archive="$PREPARATION_TMPDIR/${HOST_ID}-${artifact_id}.tar.zst"
  encrypted_temp="$PREPARATION_TMPDIR/archive.tar.zst.age"
  checksum_temp="$PREPARATION_TMPDIR/archive.sha256"
  manifest_temp="$PREPARATION_TMPDIR/manifest.json"
  latest_temp="$PREPARATION_TMPDIR/latest.txt"

  log "creating plaintext archive outside repo"
  tar_args+=(--zstd -cpf "$plain_archive" --warning=no-file-changed)
  if declare -p TAR_EXCLUDES >/dev/null 2>&1; then
    tar_args+=("${TAR_EXCLUDES[@]}")
  fi
  tar_args+=("${existing_paths[@]}")
  tar "${tar_args[@]}"
  [[ -s "$plain_archive" ]] || fail "plaintext archive missing or empty"

  log "encrypting archive"
  age -r "$AGE_RECIPIENT" -o "$encrypted_temp" "$plain_archive"
  [[ -s "$encrypted_temp" ]] || fail "encrypted archive missing or empty"
  rm -f -- "$plain_archive"

  archive_digest="$(sha256sum "$encrypted_temp" | cut -d ' ' -f 1)"
  [[ "$archive_digest" =~ ^[0-9a-f]{64}$ ]] || fail "cannot hash encrypted archive"
  printf '%s  %s\n' "$archive_digest" "$PREPARATION_REL_ARCHIVE" >"$checksum_temp"
  printf '%s\n' "$PREPARATION_REL_ARCHIVE" >"$latest_temp"
  write_manifest "$manifest_temp" "$artifact_id" "$PREPARATION_REL_ARCHIVE" "$archive_digest" "${existing_paths[@]}"
  [[ -s "$checksum_temp" && -s "$manifest_temp" && -s "$latest_temp" ]] || fail "prepared metadata is incomplete"

  checksum_digest="$(sha256sum "$checksum_temp" | cut -d ' ' -f 1)"
  manifest_digest="$(sha256sum "$manifest_temp" | cut -d ' ' -f 1)"
  latest_digest="$(sha256sum "$latest_temp" | cut -d ' ' -f 1)"
  commit_message="Add ${HOST_ID} encrypted backup ${artifact_id}"
  if declare -p BACKUP_REMOTES >/dev/null 2>&1; then
    remotes=("${BACKUP_REMOTES[@]}")
  else
    remotes=(origin)
  fi

  mkdir -p "$REPO_DIR/backups/$HOST_ID" "$REPO_DIR/manifests/$HOST_ID" "$PREPARED_STATE_DIR"
  validate_internal_storage_paths
  validate_final_storage_paths
  if [[ -e "$PREPARATION_LATEST" ]]; then
    /bin/cp -p -- "$PREPARATION_LATEST" "$PREPARATION_PREVIOUS_LATEST"
    PREPARATION_LATEST_EXISTED=1
  fi
  PREPARATION_FINALIZATION_STARTED=1
  install -m 0600 -- "$encrypted_temp" "$PREPARATION_ARCHIVE"
  install -m 0600 -- "$checksum_temp" "$PREPARATION_CHECKSUM"
  install -m 0600 -- "$manifest_temp" "$PREPARATION_MANIFEST"
  install -m 0600 -- "$latest_temp" "$PREPARATION_LATEST"
  reject_plaintext_in_repo
  compute_retention_deletions
  PREPARED_RETENTION_DELETIONS=("${RETENTION_DELETIONS[@]}")
  PREPARED_INDEX_PATHS=("${PREPARED_PATHS[@]}")

  GIT_MASTER=1 git -C "$REPO_DIR" add -- "${PREPARED_PATHS[@]}"
  require_exact_prepared_index
  require_no_unrelated_worktree_changes
  require_safe_prepared_files
  validate_staged_files

  PREPARATION_STATE_TEMP="$(mktemp "$PREPARED_STATE_DIR/.${HOST_ID}.state.XXXXXX")"
  write_prepared_state "$PREPARATION_STATE_TEMP" "$artifact_id" "$PREPARATION_BASE_OID" "$PREPARATION_CANONICAL_BRANCH_EXISTS" \
    "$archive_digest" "$checksum_digest" "$manifest_digest" "$latest_digest" "${remotes[@]}"
  chmod 0600 "$PREPARATION_STATE_TEMP"
  require_exact_prepared_index
  require_no_unrelated_worktree_changes
  require_safe_prepared_files
  mv -f -- "$PREPARATION_STATE_TEMP" "$PREPARED_STATE_FILE"
  PREPARATION_STATE_TEMP=""
  finish_preparation
  PREPARED_ARTIFACT_ID="$artifact_id"
  PREPARED_COMMIT_MESSAGE="$commit_message"
  log "backup prepared: $PREPARATION_REL_ARCHIVE"
}

load_prepared_backup() {
  local current_oid relative expected_hash actual_hash artifact_id
  local -a expected_remotes=() state_values=()
  [[ -f "$PREPARED_STATE_FILE" && ! -L "$PREPARED_STATE_FILE" ]] || fail "prepared state is not a regular file: $PREPARED_STATE_FILE"
  current_oid="$(GIT_MASTER=1 git -C "$REPO_DIR" rev-parse HEAD)"
  if declare -p BACKUP_REMOTES >/dev/null 2>&1; then
    expected_remotes=("${BACKUP_REMOTES[@]}")
  else
    expected_remotes=(origin)
  fi
  mapfile -d '' -t state_values < <(python3 - "$PREPARED_STATE_FILE" "$HOST_ID" "$PUSH_BRANCH" "$current_oid" -- "${expected_remotes[@]}" <<'PY'
import json
import pathlib
import re
import sys

state_file, host, branch, current_oid, separator, *remotes = sys.argv[1:]
if separator != "--":
    raise SystemExit("invalid validation arguments")
with open(state_file, encoding="utf-8") as handle:
    state = json.load(handle)
required_v1 = {"version", "host", "branch", "base_oid", "remotes", "paths", "hashes", "staged_paths", "retention_deletions", "committed_oid", "publication"}
required_v2 = required_v1 | {"canonical_branch_exists"}
if type(state.get("version")) is not int:
    raise SystemExit("unsupported prepared state")
if state.get("version") == 1:
    if set(state) != required_v1:
        raise SystemExit("unsupported prepared state")
elif state.get("version") == 2:
    if set(state) != required_v2 or not isinstance(state["canonical_branch_exists"], bool):
        raise SystemExit("unsupported prepared state")
else:
    raise SystemExit("unsupported prepared state")
if not all(isinstance(state[name], str) for name in ("host", "branch", "base_oid", "committed_oid")):
    raise SystemExit("invalid prepared state types")
if state["host"] != host or state["branch"] != branch or state["base_oid"] != current_oid:
    raise SystemExit("prepared state context mismatch")
if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", state["base_oid"]):
    raise SystemExit("invalid prepared base OID")
if state["committed_oid"] != "":
    raise SystemExit("prepared state must be uncommitted")
if not isinstance(state["remotes"], list) or not all(isinstance(value, str) for value in state["remotes"]) or state["remotes"] != remotes:
    raise SystemExit("prepared state remotes mismatch")
paths = state["paths"]
if not isinstance(paths, dict) or set(paths) != {"archive", "checksum", "manifest", "latest"} or not all(isinstance(value, str) for value in paths.values()):
    raise SystemExit("prepared state paths mismatch")
ordered = [paths["archive"], paths["checksum"], paths["manifest"], paths["latest"]]
if not isinstance(state["staged_paths"], list) or not all(isinstance(value, str) for value in state["staged_paths"]):
    raise SystemExit("invalid staged path types")
if not isinstance(state["hashes"], dict) or not all(isinstance(key, str) and isinstance(value, str) for key, value in state["hashes"].items()):
    raise SystemExit("invalid hash types")
if state["staged_paths"] != ordered or len(set(ordered)) != 4 or set(state["hashes"]) != set(ordered):
    raise SystemExit("prepared state staging mismatch")
publication = state["publication"]
if not isinstance(publication, dict) or set(publication) != {"artifact_id", "commit_message", "remotes"}:
    raise SystemExit("invalid publication state")
artifact_id = publication["artifact_id"]
if not isinstance(artifact_id, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z(?:-[0-9]{9})?", artifact_id):
    raise SystemExit("invalid artifact ID")
expected_paths = [
    f"backups/{host}/{artifact_id}.tar.zst.age",
    f"backups/{host}/{artifact_id}.sha256",
    f"manifests/{host}/{artifact_id}.json",
    f"backups/{host}/latest.txt",
]
if ordered != expected_paths:
    raise SystemExit("prepared paths do not match artifact ID")
retention = state["retention_deletions"]
if not isinstance(retention, list) or not all(isinstance(value, str) for value in retention) or len(set(retention)) != len(retention):
    raise SystemExit("invalid retention deletion types")
id_pattern = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z(?:-[0-9]{9})?"
patterns = {
    "archive": re.compile(rf"backups/{re.escape(host)}/({id_pattern})\.tar\.zst\.age"),
    "checksum": re.compile(rf"backups/{re.escape(host)}/({id_pattern})\.sha256"),
    "manifest": re.compile(rf"manifests/{re.escape(host)}/({id_pattern})\.json"),
}
ids = {name: [] for name in patterns}
for value in retention:
    matches = [(name, pattern.fullmatch(value)) for name, pattern in patterns.items()]
    matches = [(name, match) for name, match in matches if match]
    if len(matches) != 1:
        raise SystemExit("invalid retention deletion path")
    name, match = matches[0]
    ids[name].append(match.group(1))
if not (ids["archive"] == ids["checksum"] == ids["manifest"]):
    raise SystemExit("retention deletions must contain complete sets")
if ids["archive"] != sorted(ids["archive"]):
    raise SystemExit("retention deletions must use canonical order")
expected_retention = []
for old_id in ids["archive"]:
    expected_retention.extend([
        f"backups/{host}/{old_id}.tar.zst.age",
        f"backups/{host}/{old_id}.sha256",
        f"manifests/{host}/{old_id}.json",
    ])
if retention != expected_retention:
    raise SystemExit("retention deletions must contain ordered complete sets")
if artifact_id in ids["archive"]:
    raise SystemExit("current artifact cannot be retained for deletion")
if any(not re.fullmatch(r"[0-9a-f]{64}", state["hashes"][path]) for path in ordered):
    raise SystemExit("invalid prepared SHA256")
expected_message = f"Add {host} encrypted backup {artifact_id}"
if not isinstance(publication["commit_message"], str) or publication["commit_message"] != expected_message:
    raise SystemExit("invalid deterministic commit message")
expected_publication = [
    {"name": remote, "status": "pending", "published_oid": "", "error": ""}
    for remote in remotes
]
if publication["remotes"] != expected_publication:
    raise SystemExit("invalid remote publication scaffold")
values = [artifact_id, *ordered, *(state["hashes"][path] for path in ordered), str(len(retention)), *retention]
sys.stdout.buffer.write(b"\0".join(value.encode() for value in values) + b"\0")
PY
  ) || fail "cannot parse prepared state"
  [[ ${#state_values[@]} -ge 10 ]] || fail "prepared state is incomplete"
  PREPARED_ARTIFACT_ID="${state_values[0]}"
  PREPARED_COMMIT_MESSAGE="Add ${HOST_ID} encrypted backup ${PREPARED_ARTIFACT_ID}"
  PREPARED_PATHS=("${state_values[1]}" "${state_values[2]}" "${state_values[3]}" "${state_values[4]}")
  local -a hashes=("${state_values[5]}" "${state_values[6]}" "${state_values[7]}" "${state_values[8]}")
  local retention_count="${state_values[9]}"
  [[ "$retention_count" =~ ^[0-9]+$ && ${#state_values[@]} -eq $((10 + retention_count)) ]] || fail "prepared retention state is incomplete"
  PREPARED_RETENTION_DELETIONS=("${state_values[@]:10:retention_count}")
  PREPARED_INDEX_PATHS=("${PREPARED_PATHS[@]}")
  PREPARED_COMMIT_PATHS=("${PREPARED_PATHS[@]}" "${PREPARED_RETENTION_DELETIONS[@]}")

  validate_internal_storage_paths
  require_exact_prepared_index
  require_no_unrelated_worktree_changes
  require_safe_prepared_files

  local index
  for index in 0 1 2 3; do
    relative="${PREPARED_PATHS[$index]}"
    expected_hash="${hashes[$index]}"
    actual_hash="$(sha256sum "$REPO_DIR/$relative" | cut -d ' ' -f 1)"
    [[ "$actual_hash" == "$expected_hash" ]] || fail "prepared file hash mismatch: $relative"
  done
  [[ "$(<"$REPO_DIR/${PREPARED_PATHS[3]}")" == "${PREPARED_PATHS[0]}" ]] || fail "prepared latest pointer mismatch"
  (cd "$REPO_DIR" && sha256sum -c "${PREPARED_PATHS[1]}") >/dev/null || fail "prepared checksum verification failed"
  python3 - "$REPO_DIR/${PREPARED_PATHS[2]}" "${PREPARED_PATHS[0]}" "${hashes[0]}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
if manifest.get("encrypted_archive") != sys.argv[2] or manifest.get("encrypted_archive_sha256") != sys.argv[3]:
    raise SystemExit("prepared manifest mismatch")
PY
}

write_publication_state_update() {
  local action="$1"
  shift
  local temporary
  validate_internal_storage_paths
  temporary="$(mktemp "$PREPARED_STATE_DIR/.${HOST_ID}.publish.XXXXXX")"
  PUBLICATION_STATE_TEMP="$temporary"
  python3 - "$PREPARED_STATE_FILE" "$temporary" "$action" "$@" <<'PY'
import json
import pathlib
import re
import sys

source, destination, action, *arguments = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    state = json.load(handle)
if action == "commit":
    if len(arguments) != 1 or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", arguments[0]):
        raise SystemExit("invalid commit state update")
    state["committed_oid"] = arguments[0]
elif action == "remote":
    if len(arguments) != 4:
        raise SystemExit("invalid remote state update")
    name, status, published_oid, error = arguments
    if status not in {"pending", "published", "failed"}:
        raise SystemExit("invalid remote status")
    if status == "published":
        if published_oid != state["committed_oid"] or error:
            raise SystemExit("invalid published state")
    elif published_oid:
        raise SystemExit("unpublished remote must not have an OID")
    if status != "failed" and error:
        raise SystemExit("unexpected remote error")
    matches = [item for item in state["publication"]["remotes"] if item["name"] == name]
    if len(matches) != 1:
        raise SystemExit("unknown remote state")
    matches[0].update(status=status, published_oid=published_oid, error=error)
else:
    raise SystemExit("unknown state update")
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(state, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$PREPARED_STATE_FILE"
  PUBLICATION_STATE_TEMP=""
  validate_internal_storage_paths
}

publication_cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  settle_retention_transaction "${PREPARED_BASE_OID:-}"
  rm -f -- "${PUBLICATION_STATE_TEMP:-}"
  return "$status"
}

activate_publication_traps() {
  PUBLICATION_STATE_TEMP=""
  RETENTION_ROLLBACK_ACTIVE=0
  RETENTION_ROLLBACK_DIR=""
  RETENTION_ROLLBACK_INDEX_TREE=""
  trap publication_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

finish_publication() {
  PUBLICATION_STATE_TEMP=""
  trap - EXIT INT TERM HUP
}

require_exact_commit_paths() {
  local oid="$1" actual path
  local -A expected=()
  local -a actual_paths=()
  for path in "${PREPARED_COMMIT_PATHS[@]}"; do expected["$path"]=1; done
  mapfile -d '' -t actual_paths < <(GIT_MASTER=1 git -C "$REPO_DIR" diff-tree --no-commit-id --name-only -r -z "$oid")
  [[ ${#actual_paths[@]} -eq ${#PREPARED_COMMIT_PATHS[@]} ]] || fail "committed paths do not match prepared state"
  for actual in "${actual_paths[@]}"; do
    [[ -n "${expected[$actual]:-}" ]] || fail "commit contains an unrecorded path: $actual"
    unset 'expected[$actual]'
  done
  [[ ${#expected[@]} -eq 0 ]] || fail "commit is missing a prepared path"
}

validate_committed_publication() {
  local oid="$1" parent message cached unstaged untracked
  publication_commit_shape_valid "$oid" || fail "publication commit is not publication-shaped"
  [[ "$(GIT_MASTER=1 git -C "$REPO_DIR" rev-parse HEAD)" == "$oid" ]] || fail "local HEAD does not equal committed publication OID"
  parent="$(GIT_MASTER=1 git -C "$REPO_DIR" rev-parse "$oid^")" || fail "publication commit has no valid parent"
  [[ "$parent" == "$PREPARED_BASE_OID" ]] || fail "publication commit parent does not equal prepared base OID"
  message="$(GIT_MASTER=1 git -C "$REPO_DIR" log -1 --format=%s "$oid")"
  [[ "$message" == "$PREPARED_COMMIT_MESSAGE" ]] || fail "publication commit message does not match prepared state"
  require_exact_commit_paths "$oid"
  cached="$(GIT_MASTER=1 git -C "$REPO_DIR" diff --cached --name-only)"
  unstaged="$(GIT_MASTER=1 git -C "$REPO_DIR" diff --name-only)"
  untracked="$(GIT_MASTER=1 git -C "$REPO_DIR" ls-files --others --exclude-standard)"
  [[ -z "$cached" && -z "$unstaged" && -z "$untracked" ]] || fail "committed publication repository must be clean"
}

load_publication_state() {
  local current_oid relative expected_hash actual_hash
  local -a values=() expected_remotes=("${PUSH_REMOTES[@]}")
  [[ -f "$PREPARED_STATE_FILE" && ! -L "$PREPARED_STATE_FILE" ]] || fail "prepared state is not a regular file"
  mapfile -d '' -t values < <(python3 - "$PREPARED_STATE_FILE" "$HOST_ID" "$PUSH_BRANCH" -- "${expected_remotes[@]}" <<'PY'
import json
import re
import sys

state_file, host, branch, separator, *remotes = sys.argv[1:]
if separator != "--": raise SystemExit("invalid state arguments")
with open(state_file, encoding="utf-8") as handle: state = json.load(handle)
required_v1 = {"version", "host", "branch", "base_oid", "remotes", "paths", "hashes", "staged_paths", "retention_deletions", "committed_oid", "publication"}
required_v2 = required_v1 | {"canonical_branch_exists"}
if type(state.get("version")) is not int: raise SystemExit("unsupported state")
if state.get("version") == 1:
    if set(state) != required_v1: raise SystemExit("unsupported state")
    canonical_branch_exists = "legacy"
elif state.get("version") == 2:
    if set(state) != required_v2 or not isinstance(state["canonical_branch_exists"], bool): raise SystemExit("unsupported state")
    canonical_branch_exists = "1" if state["canonical_branch_exists"] else "0"
else:
    raise SystemExit("unsupported state")
if state["host"] != host or state["branch"] != branch or state["remotes"] != remotes: raise SystemExit("state context mismatch")
oid_pattern = r"[0-9a-f]{40}|[0-9a-f]{64}"
if not isinstance(state["base_oid"], str) or not re.fullmatch(oid_pattern, state["base_oid"]): raise SystemExit("invalid base OID")
if not isinstance(state["committed_oid"], str) or (state["committed_oid"] and not re.fullmatch(oid_pattern, state["committed_oid"])): raise SystemExit("invalid committed OID")
publication = state["publication"]
if not isinstance(publication, dict) or set(publication) != {"artifact_id", "commit_message", "remotes"}: raise SystemExit("invalid publication")
artifact = publication["artifact_id"]
if not isinstance(artifact, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z(?:-[0-9]{9})?", artifact): raise SystemExit("invalid artifact")
message = f"Add {host} encrypted backup {artifact}"
if publication["commit_message"] != message: raise SystemExit("invalid message")
paths = state["paths"]
ordered = [f"backups/{host}/{artifact}.tar.zst.age", f"backups/{host}/{artifact}.sha256", f"manifests/{host}/{artifact}.json", f"backups/{host}/latest.txt"]
if not isinstance(paths, dict) or [paths.get(name) for name in ("archive", "checksum", "manifest", "latest")] != ordered: raise SystemExit("invalid paths")
if state["staged_paths"] != ordered or set(state["hashes"]) != set(ordered): raise SystemExit("invalid staged paths")
if any(not isinstance(state["hashes"][path], str) or not re.fullmatch(r"[0-9a-f]{64}", state["hashes"][path]) for path in ordered): raise SystemExit("invalid hashes")
retention = state["retention_deletions"]
if not isinstance(retention, list) or not all(isinstance(value, str) for value in retention) or len(set(retention)) != len(retention): raise SystemExit("invalid retention deletion types")
id_pattern = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z(?:-[0-9]{9})?"
patterns = {
    "archive": re.compile(rf"backups/{re.escape(host)}/({id_pattern})\.tar\.zst\.age"),
    "checksum": re.compile(rf"backups/{re.escape(host)}/({id_pattern})\.sha256"),
    "manifest": re.compile(rf"manifests/{re.escape(host)}/({id_pattern})\.json"),
}
retention_ids = []
for offset in range(0, len(retention), 3):
    triplet = retention[offset:offset + 3]
    if len(triplet) != 3: raise SystemExit("incomplete retention deletion set")
    matches = [patterns[name].fullmatch(value) for name, value in zip(("archive", "checksum", "manifest"), triplet)]
    if any(match is None for match in matches): raise SystemExit("invalid retention deletion path")
    ids = [match.group(1) for match in matches]
    if len(set(ids)) != 1: raise SystemExit("mixed retention deletion set")
    retention_ids.append(ids[0])
if retention_ids != sorted(retention_ids) or len(set(retention_ids)) != len(retention_ids): raise SystemExit("noncanonical retention deletion order")
if artifact in retention_ids: raise SystemExit("current artifact cannot be retained for deletion")
remote_states = publication["remotes"]
if not isinstance(remote_states, list) or len(remote_states) != len(remotes): raise SystemExit("invalid remote state count")
for expected, item in zip(remotes, remote_states):
    if not isinstance(item, dict) or set(item) != {"name", "status", "published_oid", "error"}: raise SystemExit("invalid remote state")
    if item["name"] != expected or item["status"] not in {"pending", "published", "failed"}: raise SystemExit("invalid remote status")
    if not all(isinstance(item[name], str) for name in ("name", "status", "published_oid", "error")): raise SystemExit("invalid remote state types")
    if item["status"] == "published":
        if not state["committed_oid"] or item["published_oid"] != state["committed_oid"] or item["error"]: raise SystemExit("invalid published state")
    elif item["published_oid"]: raise SystemExit("invalid unpublished OID")
    elif item["status"] != "failed" and item["error"]: raise SystemExit("invalid remote error")
values = [artifact, state["base_oid"], canonical_branch_exists, state["committed_oid"], message, *ordered, *(state["hashes"][path] for path in ordered), str(len(retention)), *retention]
for item in remote_states: values.extend((item["name"], item["status"], item["published_oid"], item["error"]))
sys.stdout.buffer.write(b"\0".join(value.encode() for value in values) + b"\0")
PY
  ) || fail "cannot parse publication state"
  [[ ${#values[@]} -ge 14 ]] || fail "publication state is incomplete"
  PREPARED_ARTIFACT_ID="${values[0]}"
  PREPARED_BASE_OID="${values[1]}"
  PREPARED_CANONICAL_BRANCH_EXISTS="${values[2]}"
  [[ "$PREPARED_CANONICAL_BRANCH_EXISTS" == 0 || "$PREPARED_CANONICAL_BRANCH_EXISTS" == 1 || "$PREPARED_CANONICAL_BRANCH_EXISTS" == legacy ]] || fail "invalid publication canonical branch state"
  PREPARED_COMMITTED_OID="${values[3]}"
  PREPARED_COMMIT_MESSAGE="${values[4]}"
  PREPARED_PATHS=("${values[5]}" "${values[6]}" "${values[7]}" "${values[8]}")
  PREPARED_HASHES=("${values[9]}" "${values[10]}" "${values[11]}" "${values[12]}")
  local retention_count="${values[13]}"
  [[ "$retention_count" =~ ^[0-9]+$ ]] || fail "invalid publication retention count"
  local remote_offset=$((14 + retention_count))
  [[ ${#values[@]} -eq $((remote_offset + 4 * ${#PUSH_REMOTES[@]})) ]] || fail "publication state is incomplete"
  PREPARED_RETENTION_DELETIONS=("${values[@]:14:retention_count}")
  PREPARED_INDEX_PATHS=("${PREPARED_PATHS[@]}")
  PREPARED_COMMIT_PATHS=("${PREPARED_PATHS[@]}" "${PREPARED_RETENTION_DELETIONS[@]}")
  declare -gA PREPARED_REMOTE_STATUS=() PREPARED_REMOTE_OID=() PREPARED_REMOTE_ERROR=()
  local offset="$remote_offset" remote
  for remote in "${PUSH_REMOTES[@]}"; do
    [[ "${values[$offset]}" == "$remote" ]] || fail "publication remote order mismatch"
    PREPARED_REMOTE_STATUS["$remote"]="${values[$((offset + 1))]}"
    PREPARED_REMOTE_OID["$remote"]="${values[$((offset + 2))]}"
    PREPARED_REMOTE_ERROR["$remote"]="${values[$((offset + 3))]}"
    offset=$((offset + 4))
  done
  validate_internal_storage_paths
  require_safe_prepared_files
  local index
  for index in 0 1 2 3; do
    relative="${PREPARED_PATHS[$index]}"
    expected_hash="${PREPARED_HASHES[$index]}"
    actual_hash="$(sha256sum "$REPO_DIR/$relative" | cut -d ' ' -f 1)"
    [[ "$actual_hash" == "$expected_hash" ]] || fail "prepared file hash mismatch: $relative"
  done
  current_oid="$(GIT_MASTER=1 git -C "$REPO_DIR" rev-parse HEAD)"
  if [[ -z "$PREPARED_COMMITTED_OID" ]]; then
    if [[ "$current_oid" == "$PREPARED_BASE_OID" ]]; then
      require_exact_prepared_index
      require_no_unrelated_worktree_changes
    else
      PREPARED_COMMITTED_OID="$current_oid"
      validate_committed_publication "$PREPARED_COMMITTED_OID"
      write_publication_state_update commit "$PREPARED_COMMITTED_OID"
    fi
  else
    validate_committed_publication "$PREPARED_COMMITTED_OID"
  fi
}

clear_prepared_state() {
  rm -f -- "$PREPARED_STATE_FILE"
}
