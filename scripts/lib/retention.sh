#!/usr/bin/env bash

is_retention_artifact_id() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z(-[0-9]{9})?$ ]]
}

insert_artifact_id_ascending() {
  local candidate="$1" index
  for ((index = 0; index < ${#RETENTION_SORTED_IDS[@]}; index++)); do
    if [[ "$candidate" < "${RETENTION_SORTED_IDS[$index]}" ]]; then
      RETENTION_SORTED_IDS=("${RETENTION_SORTED_IDS[@]:0:$index}" "$candidate" "${RETENTION_SORTED_IDS[@]:$index}")
      return 0
    fi
  done
  RETENTION_SORTED_IDS+=("$candidate")
}

report_retention_orphans() {
  local path name artifact_id archive checksum manifest
  while IFS= read -r -d '' path; do
    name="${path##*/}"
    case "$name" in
      *.tar.zst.age) artifact_id="${name%.tar.zst.age}" ;;
      *.sha256) artifact_id="${name%.sha256}" ;;
      *) continue ;;
    esac
    is_retention_artifact_id "$artifact_id" || continue
    archive="$REPO_DIR/backups/$HOST_ID/${artifact_id}.tar.zst.age"
    checksum="$REPO_DIR/backups/$HOST_ID/${artifact_id}.sha256"
    manifest="$REPO_DIR/manifests/$HOST_ID/${artifact_id}.json"
    if [[ ! -f "$archive" || -L "$archive" || ! -f "$checksum" || -L "$checksum" || ! -f "$manifest" || -L "$manifest" ]]; then
      log "retention preserved orphan: ${path#"$REPO_DIR/"}"
    fi
  done < <(find "$REPO_DIR/backups/$HOST_ID" -maxdepth 1 -type f \( -name '*.tar.zst.age' -o -name '*.sha256' \) -print0)
  while IFS= read -r -d '' path; do
    name="${path##*/}"
    artifact_id="${name%.json}"
    is_retention_artifact_id "$artifact_id" || continue
    archive="$REPO_DIR/backups/$HOST_ID/${artifact_id}.tar.zst.age"
    checksum="$REPO_DIR/backups/$HOST_ID/${artifact_id}.sha256"
    if [[ ! -f "$archive" || -L "$archive" || ! -f "$checksum" || -L "$checksum" ]]; then
      log "retention preserved orphan: ${path#"$REPO_DIR/"}"
    fi
  done < <(find "$REPO_DIR/manifests/$HOST_ID" -maxdepth 1 -type f -name '*.json' -print0)
}

compute_retention_deletions() {
  local LC_ALL=C path name artifact_id checksum manifest delete_count index
  local -A seen=()
  RETENTION_DELETIONS=()
  RETENTION_SORTED_IDS=()
  while IFS= read -r -d '' path; do
    name="${path##*/}"
    artifact_id="${name%.tar.zst.age}"
    if ! is_retention_artifact_id "$artifact_id"; then
      log "retention ignored unrelated archive name: ${path#"$REPO_DIR/"}"
      continue
    fi
    checksum="$REPO_DIR/backups/$HOST_ID/${artifact_id}.sha256"
    manifest="$REPO_DIR/manifests/$HOST_ID/${artifact_id}.json"
    if [[ -f "$checksum" && ! -L "$checksum" && -f "$manifest" && ! -L "$manifest" ]]; then
      [[ -z "${seen[$artifact_id]:-}" ]] || fail "duplicate retention artifact ID: $artifact_id"
      seen["$artifact_id"]=1
      insert_artifact_id_ascending "$artifact_id"
    fi
  done < <(find "$REPO_DIR/backups/$HOST_ID" -maxdepth 1 -type f -name '*.tar.zst.age' -print0)
  report_retention_orphans
  delete_count=$((${#RETENTION_SORTED_IDS[@]} - RETENTION_COUNT))
  (( delete_count > 0 )) || return 0
  for ((index = 0; index < delete_count; index++)); do
    artifact_id="${RETENTION_SORTED_IDS[$index]}"
    RETENTION_DELETIONS+=(
      "backups/$HOST_ID/${artifact_id}.tar.zst.age"
      "backups/$HOST_ID/${artifact_id}.sha256"
      "manifests/$HOST_ID/${artifact_id}.json"
    )
  done
}

require_safe_retention_files() {
  local relative links
  for relative in "${PREPARED_RETENTION_DELETIONS[@]}"; do
    require_safe_internal_path "$REPO_DIR/$relative" retention
    [[ -f "$REPO_DIR/$relative" && ! -L "$REPO_DIR/$relative" ]] || fail "retention target is missing or unsafe: $relative"
    links="$(stat -c %h -- "$REPO_DIR/$relative")"
    [[ "$links" == 1 ]] || fail "retention target must have exactly one hard link: $relative"
    GIT_MASTER=1 git -C "$REPO_DIR" ls-files --error-unmatch -- "$relative" >/dev/null 2>&1 || fail "retention target is not tracked: $relative"
  done
}

begin_retention_transaction() {
  local relative backup recovery_parent recovery_root recovery_temp publication_index publication_tree prepared_state_sha256 digest mode
  local -a payload=()
  PREPARED_COMMIT_PATHS=("${PREPARED_PATHS[@]}" "${PREPARED_RETENTION_DELETIONS[@]}")
  PREPARED_INDEX_PATHS=("${PREPARED_COMMIT_PATHS[@]}")
  [[ ${#PREPARED_RETENTION_DELETIONS[@]} -gt 0 ]] || return 0
  require_safe_retention_files
  RETENTION_ROLLBACK_INDEX_TREE="$(GIT_MASTER=1 git -C "$REPO_DIR" write-tree)"
  recovery_parent="$REPO_DIR/.git/local-backup-push-kit/recovery/retention"
  recovery_root="$recovery_parent/$HOST_ID"
  require_safe_internal_path "$recovery_parent" recovery
  require_safe_internal_path "$recovery_root" recovery
  [[ ! -e "$recovery_root" && ! -L "$recovery_root" ]] || fail "unresolved retention recovery exists for $HOST_ID"
  mkdir -p "$recovery_parent"
  recovery_temp="$(mktemp -d "$recovery_parent/.${HOST_ID}.XXXXXX")"
  RETENTION_ROLLBACK_DIR="$recovery_temp/payload"
  mkdir -p "$RETENTION_ROLLBACK_DIR"
  for relative in "${PREPARED_RETENTION_DELETIONS[@]}"; do
    backup="$RETENTION_ROLLBACK_DIR/$relative"
    mkdir -p "${backup%/*}"
    /bin/cp -p -- "$REPO_DIR/$relative" "$backup"
    digest="$(sha256sum "$backup" | cut -d ' ' -f 1)"
    mode="$(stat -c %a -- "$backup")"
    payload+=("$relative" "$digest" "$mode")
  done
  publication_index="$recovery_temp/publication.index"
  GIT_MASTER=1 GIT_INDEX_FILE="$publication_index" git -C "$REPO_DIR" read-tree "$RETENTION_ROLLBACK_INDEX_TREE"
  GIT_MASTER=1 GIT_INDEX_FILE="$publication_index" git -C "$REPO_DIR" update-index --remove -- "${PREPARED_RETENTION_DELETIONS[@]}"
  publication_tree="$(GIT_MASTER=1 GIT_INDEX_FILE="$publication_index" git -C "$REPO_DIR" write-tree)"
  rm -f -- "$publication_index"
  prepared_state_sha256="$(sha256sum "$PREPARED_STATE_FILE" | cut -d ' ' -f 1)"
  python3 - "$recovery_temp/journal" "$HOST_ID" "$PUSH_BRANCH" "$PREPARED_BASE_OID" "$RETENTION_ROLLBACK_INDEX_TREE" "$prepared_state_sha256" "$PREPARED_COMMIT_MESSAGE" "${PREPARED_PATHS[@]}" "${PREPARED_HASHES[@]}" "${#PREPARED_RETENTION_DELETIONS[@]}" "${PREPARED_RETENTION_DELETIONS[@]}" "${payload[@]}" <<'PY'
import json, sys
destination, host, branch, base_oid, index_tree, state_sha256, commit_message, *values = sys.argv[1:]
prepared_paths, prepared_hashes = values[:4], values[4:8]
retention_count = int(values[8])
retention_paths = values[9:9 + retention_count]
payload_values = values[9 + retention_count:]
if len(prepared_paths) != 4 or len(prepared_hashes) != 4 or retention_count < 1 or len(retention_paths) != retention_count or len(payload_values) != retention_count * 3:
    raise SystemExit(1)
retention = [dict(zip(("archive", "checksum", "manifest"), retention_paths[index:index + 3])) for index in range(0, retention_count, 3)]
payload = [dict(zip(("path", "sha256", "mode"), payload_values[index:index + 3])) for index in range(0, len(payload_values), 3)]
with open(destination, "w", encoding="utf-8") as handle:
    json.dump({"version": 3, "host": host, "branch": branch, "base_oid": base_oid, "index_tree": index_tree, "prepared_state_sha256": state_sha256, "commit_message": commit_message, "prepared_paths": prepared_paths, "prepared_hashes": dict(zip(prepared_paths, prepared_hashes)), "retention": retention, "payload": payload}, handle, sort_keys=True)
    handle.write("\n")
PY
  chmod 0600 "$recovery_temp/journal"
  mv -- "$recovery_temp" "$recovery_root"
  RETENTION_ROLLBACK_DIR="$recovery_root/payload"
  RETENTION_ROLLBACK_ACTIVE=1
  rm -f -- "${PREPARED_RETENTION_DELETIONS[@]/#/$REPO_DIR/}"
  GIT_MASTER=1 git -C "$REPO_DIR" add -- "${PREPARED_RETENTION_DELETIONS[@]}"
}

restore_retention_transaction() {
  local relative backup
  [[ "${RETENTION_ROLLBACK_ACTIVE:-0}" == 1 ]] || return 0
  GIT_MASTER=1 git -C "$REPO_DIR" read-tree "$RETENTION_ROLLBACK_INDEX_TREE" >/dev/null 2>&1 || true
  for relative in "${PREPARED_RETENTION_DELETIONS[@]}"; do
    backup="$RETENTION_ROLLBACK_DIR/$relative"
    [[ -f "$backup" ]] || continue
    mkdir -p "$REPO_DIR/${relative%/*}"
    /bin/cp -p -- "$backup" "$REPO_DIR/$relative"
  done
  RETENTION_ROLLBACK_ACTIVE=0
  rm -rf -- "${RETENTION_ROLLBACK_DIR%/payload}"
  RETENTION_ROLLBACK_DIR=""
}

finish_retention_transaction() {
  RETENTION_ROLLBACK_ACTIVE=0
  [[ -z "${RETENTION_ROLLBACK_DIR:-}" ]] || rm -rf -- "${RETENTION_ROLLBACK_DIR%/payload}"
  RETENTION_ROLLBACK_DIR=""
}

settle_retention_transaction() {
  local base_oid="$1" current_oid
  [[ "${RETENTION_ROLLBACK_ACTIVE:-0}" == 1 ]] || return 0
  current_oid="$(GIT_MASTER=1 git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$base_oid" && "$current_oid" == "$base_oid" ]]; then
    restore_retention_transaction
  else
    finish_retention_transaction
  fi
}

recover_pending_retention_transaction() {
  local recovery_root current_oid current_tree expected_tree parent index_tree relative path_entry prepared_state_sha256 actual_state_sha256 publication_index state_index digest mode
  local -a values=() paths=() prepared_paths=() prepared_hashes=() payload=()
  recovery_root="$REPO_DIR/.git/local-backup-push-kit/recovery/retention/$HOST_ID"
  [[ -e "$recovery_root" || -L "$recovery_root" ]] || return 0
  require_safe_internal_path "$recovery_root" recovery
  [[ -d "$recovery_root" && ! -L "$recovery_root" && -f "$recovery_root/journal" && ! -L "$recovery_root/journal" ]] || fail "unsafe retention recovery state for $HOST_ID"
  [[ -f "$PREPARED_STATE_FILE" && ! -L "$PREPARED_STATE_FILE" ]] || fail "retention recovery prepared state is unavailable; journal preserved"
  mapfile -d '' -t values < <(python3 - "$recovery_root/journal" "$PREPARED_STATE_FILE" "$HOST_ID" "$PUSH_BRANCH" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as handle: state = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle: prepared_state = json.load(handle)
host_arg, branch_arg = sys.argv[3:]
if set(state) != {"version", "host", "branch", "base_oid", "index_tree", "prepared_state_sha256", "commit_message", "prepared_paths", "prepared_hashes", "retention", "payload"} or state["version"] != 3 or state["host"] != host_arg or state["branch"] != branch_arg: raise SystemExit(1)
prepared_required_v1 = {"version", "host", "branch", "base_oid", "remotes", "paths", "hashes", "staged_paths", "retention_deletions", "committed_oid", "publication"}
prepared_required_v2 = prepared_required_v1 | {"canonical_branch_exists"}
if type(prepared_state.get("version")) is not int: raise SystemExit(1)
if prepared_state["host"] != host_arg or prepared_state["branch"] != branch_arg or prepared_state["committed_oid"] != "": raise SystemExit(1)
if prepared_state.get("version") == 1:
    if set(prepared_state) != prepared_required_v1: raise SystemExit(1)
elif prepared_state.get("version") == 2:
    if set(prepared_state) != prepared_required_v2 or not isinstance(prepared_state["canonical_branch_exists"], bool): raise SystemExit(1)
else:
    raise SystemExit(1)
oid = r"[0-9a-f]{40}|[0-9a-f]{64}"
if not re.fullmatch(oid, state["base_oid"]) or not re.fullmatch(oid, state["index_tree"]) or not re.fullmatch(r"[0-9a-f]{64}", state["prepared_state_sha256"]): raise SystemExit(1)
host = re.escape(host_arg); artifact = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z(?:-[0-9]{9})?"
match = re.fullmatch(rf"Add {host} encrypted backup ({artifact})", state["commit_message"])
if match is None: raise SystemExit(1)
current = match.group(1)
prepared = [f"backups/{host_arg}/{current}.tar.zst.age", f"backups/{host_arg}/{current}.sha256", f"manifests/{host_arg}/{current}.json", f"backups/{host_arg}/latest.txt"]
if state["prepared_paths"] != prepared or not isinstance(state["prepared_hashes"], dict) or set(state["prepared_hashes"]) != set(prepared) or any(not re.fullmatch(r"[0-9a-f]{64}", state["prepared_hashes"][path]) for path in prepared): raise SystemExit(1)
publication = prepared_state["publication"]
prepared_paths = prepared_state["paths"]
if not isinstance(prepared_paths, dict) or set(prepared_paths) != {"archive", "checksum", "manifest", "latest"} or [prepared_paths[name] for name in ("archive", "checksum", "manifest", "latest")] != prepared: raise SystemExit(1)
if not isinstance(prepared_state["remotes"], list) or not all(isinstance(remote, str) for remote in prepared_state["remotes"]): raise SystemExit(1)
expected_message = f"Add {host_arg} encrypted backup {current}"
expected_publication = {"artifact_id": current, "commit_message": expected_message, "remotes": [{"name": remote, "status": "pending", "published_oid": "", "error": ""} for remote in prepared_state["remotes"]]}
if publication != expected_publication or state["commit_message"] != expected_message or prepared_state["base_oid"] != state["base_oid"] or prepared_state["staged_paths"] != prepared or prepared_state["hashes"] != state["prepared_hashes"]: raise SystemExit(1)
patterns = [rf"backups/{host}/({artifact})\.tar\.zst\.age", rf"backups/{host}/({artifact})\.sha256", rf"manifests/{host}/({artifact})\.json"]
retention = state["retention"]
if not isinstance(retention, list) or not retention: raise SystemExit(1)
paths = []
for item in retention:
    if not isinstance(item, dict) or set(item) != {"archive", "checksum", "manifest"}: raise SystemExit(1)
    triplet = [item[key] for key in ("archive", "checksum", "manifest")]
    matches = [re.fullmatch(pattern, value) for pattern, value in zip(patterns, triplet)]
    if any(match is None for match in matches) or len({match.group(1) for match in matches}) != 1: raise SystemExit(1)
    paths.extend(triplet)
if len(set(paths)) != len(paths) or [re.fullmatch(patterns[0], value).group(1) for value in paths[::3]] != sorted(re.fullmatch(patterns[0], value).group(1) for value in paths[::3]): raise SystemExit(1)
if prepared_state["retention_deletions"] != paths: raise SystemExit(1)
payload = state["payload"]
if not isinstance(payload, list) or len(payload) != len(paths): raise SystemExit(1)
for item, path in zip(payload, paths):
    if not isinstance(item, dict) or set(item) != {"path", "sha256", "mode"} or item["path"] != path or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"]) or not re.fullmatch(r"[0-7]{3,4}", item["mode"]): raise SystemExit(1)
values = [state["base_oid"], state["index_tree"], state["prepared_state_sha256"], state["commit_message"], *prepared, *(state["prepared_hashes"][path] for path in prepared), str(len(paths)), *paths]
for item in payload: values.extend((item["path"], item["sha256"], item["mode"]))
for value in values: sys.stdout.buffer.write(value.encode() + b"\0")
PY
  ) || fail "invalid retention recovery journal for $HOST_ID"
  [[ ${#values[@]} -ge 16 ]] || fail "invalid retention recovery journal for $HOST_ID"
  index_tree="${values[1]}"; prepared_state_sha256="${values[2]}"; prepared_paths=("${values[@]:4:4}"); prepared_hashes=("${values[@]:8:4}")
  [[ "${values[12]}" =~ ^[0-9]+$ ]] || fail "invalid retention recovery journal for $HOST_ID"
  local path_count payload_offset
  path_count="${values[12]}"
  payload_offset=$((13 + path_count))
  [[ "$path_count" -gt 0 && ${#values[@]} -eq $((payload_offset + 3 * path_count)) ]] || fail "invalid retention recovery journal for $HOST_ID"
  paths=("${values[@]:13:path_count}"); payload=("${values[@]:payload_offset}")
  actual_state_sha256="$(sha256sum "$PREPARED_STATE_FILE" | cut -d ' ' -f 1)"
  [[ "$actual_state_sha256" == "$prepared_state_sha256" ]] || fail "retention recovery prepared state changed; journal preserved"
  for ((offset = 0; offset < ${#prepared_paths[@]}; offset++)); do
    [[ -f "$REPO_DIR/${prepared_paths[$offset]}" && ! -L "$REPO_DIR/${prepared_paths[$offset]}" ]] || fail "retention recovery prepared file is unavailable; journal preserved"
    [[ "$(sha256sum "$REPO_DIR/${prepared_paths[$offset]}" | cut -d ' ' -f 1)" == "${prepared_hashes[$offset]}" ]] || fail "retention recovery prepared file changed; journal preserved"
  done
  for ((offset = 0; offset < ${#payload[@]}; offset += 3)); do
    relative="${payload[$offset]}"; digest="${payload[$((offset + 1))]}"; mode="${payload[$((offset + 2))]}"
    [[ -f "$recovery_root/payload/$relative" && ! -L "$recovery_root/payload/$relative" ]] || fail "retention recovery payload is incomplete"
    [[ "$(sha256sum "$recovery_root/payload/$relative" | cut -d ' ' -f 1)" == "$digest" && "$(stat -c %a -- "$recovery_root/payload/$relative")" == "$mode" ]] || fail "retention recovery payload changed; journal preserved"
  done
  state_index="$(mktemp "$recovery_root/.state-index.XXXXXX")"
  GIT_INDEX_FILE="$state_index" GIT_NO_REPLACE_OBJECTS=1 git --no-replace-objects -c core.hooksPath=/dev/null -C "$REPO_DIR" read-tree "${values[0]}" || fail "retention recovery state is unknown; journal preserved"
  GIT_INDEX_FILE="$state_index" GIT_NO_REPLACE_OBJECTS=1 git --no-replace-objects -c core.hooksPath=/dev/null -C "$REPO_DIR" add -- "${prepared_paths[@]}" || fail "retention recovery state is unknown; journal preserved"
  expected_tree="$(GIT_INDEX_FILE="$state_index" GIT_NO_REPLACE_OBJECTS=1 git --no-replace-objects -c core.hooksPath=/dev/null -C "$REPO_DIR" write-tree)" || fail "retention recovery state is unknown; journal preserved"
  rm -f -- "$state_index"
  [[ "$expected_tree" == "$index_tree" ]] || fail "retention recovery state is unknown; journal preserved"
  current_oid="$(publication_git rev-parse --verify HEAD 2>/dev/null)" || fail "retention recovery cannot read HEAD; journal preserved"
  if [[ "$current_oid" == "${values[0]}" ]]; then
    publication_git read-tree "$index_tree" || fail "retention recovery cannot restore index"
    for relative in "${paths[@]}"; do
      [[ -f "$recovery_root/payload/$relative" && ! -L "$recovery_root/payload/$relative" ]] || fail "retention recovery payload is incomplete"
      mkdir -p "$REPO_DIR/${relative%/*}"
      /bin/cp -p -- "$recovery_root/payload/$relative" "$REPO_DIR/$relative"
    done
    rm -rf -- "$recovery_root"
    return 0
  fi
  parent="$(publication_git rev-parse --verify "$current_oid^" 2>/dev/null)" || fail "retention recovery state is unknown; journal preserved"
  [[ "$parent" == "${values[0]}" ]] || fail "retention recovery state is unknown; journal preserved"
  publication_commit_shape_valid "$current_oid" || fail "retention recovery state is unknown; journal preserved"
  [[ "$(publication_git log -1 --format=%s "$current_oid")" == "${values[3]}" ]] || fail "retention recovery state is unknown; journal preserved"
  publication_index="$(mktemp "$recovery_root/.publication-index.XXXXXX")"
  GIT_INDEX_FILE="$publication_index" GIT_NO_REPLACE_OBJECTS=1 git --no-replace-objects -c core.hooksPath=/dev/null -C "$REPO_DIR" read-tree "$index_tree" || fail "retention recovery state is unknown; journal preserved"
  GIT_INDEX_FILE="$publication_index" GIT_NO_REPLACE_OBJECTS=1 git --no-replace-objects -c core.hooksPath=/dev/null -C "$REPO_DIR" update-index --remove -- "${paths[@]}" || fail "retention recovery state is unknown; journal preserved"
  expected_tree="$(GIT_INDEX_FILE="$publication_index" GIT_NO_REPLACE_OBJECTS=1 git --no-replace-objects -c core.hooksPath=/dev/null -C "$REPO_DIR" write-tree)" || fail "retention recovery state is unknown; journal preserved"
  rm -f -- "$publication_index"
  current_tree="$(publication_git rev-parse --verify "$current_oid^{tree}" 2>/dev/null)" || fail "retention recovery state is unknown; journal preserved"
  [[ "$current_tree" == "$expected_tree" ]] || fail "retention recovery state is unknown; journal preserved"
  for relative in "${paths[@]}"; do
    path_entry="$(publication_git ls-tree --name-only "$current_oid" -- "$relative")" || fail "retention recovery cannot verify deleted path; journal preserved"
    [[ -z "$path_entry" ]] || fail "retention recovery publication still contains a deleted path; journal preserved"
  done
  rm -rf -- "$recovery_root"
}
