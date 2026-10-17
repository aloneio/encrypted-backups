#!/usr/bin/env bash
# Rewrite CI-managed backup branches to root snapshots retaining two complete sets per host.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REMOTE="${BACKUP_COMPACTION_REMOTE:-origin}"
KEEP="${BACKUP_COMPACTION_KEEP:-2}"
ALL_BRANCHES="${BACKUP_COMPACTION_ALL_BRANCHES:-0}"
REQUESTED_BRANCH="${BACKUP_COMPACTION_BRANCH:-}"

fail() {
  printf 'ERROR: remote compaction: %s\n' "$*" >&2
  exit 1
}

[[ "${BACKUP_COMPACTION_CI:-}" == 1 ]] || fail 'refusing to run outside an explicitly marked CI job'
[[ "$KEEP" == 2 ]] || fail 'BACKUP_COMPACTION_KEEP must be exactly 2'
[[ "$ALL_BRANCHES" == 0 || "$ALL_BRANCHES" == 1 ]] || fail 'BACKUP_COMPACTION_ALL_BRANCHES must be 0 or 1'
[[ -d "$REPO_DIR/.git" ]] || fail 'repository is not initialized'
git -C "$REPO_DIR" remote get-url --all "$REMOTE" >/dev/null 2>&1 || fail "remote '$REMOTE' is unavailable"

validate_branch() {
  local branch="$1"
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || fail "invalid branch: $branch"
}

plan_compaction() {
  local head="$1" plan="$2"
  python3 - "$REPO_DIR" "$head" "$KEEP" "$plan" <<'PY'
from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys

root, head, keep_text, destination = sys.argv[1:]
keep = int(keep_text)
if keep != 2:
    raise SystemExit("retention count must be two")

host = r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?"
artifact = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z(?:-[0-9]{9})?"
archive_re = re.compile(rf"backups/({host})/({artifact})\.tar\.zst\.age")
checksum_re = re.compile(rf"backups/({host})/({artifact})\.sha256")
manifest_re = re.compile(rf"manifests/({host})/({artifact})\.json")
latest_re = re.compile(rf"backups/({host})/latest\.txt")


def git(*args: str) -> bytes:
    return subprocess.check_output(
        ["git", "-C", root, "--no-replace-objects", "-c", "core.hooksPath=/dev/null", *args],
        stderr=subprocess.DEVNULL,
    )


def blob(oid: str) -> bytes:
    if git("cat-file", "-t", oid) != b"blob\n":
        raise ValueError("tree item is not a blob")
    return git("cat-file", "blob", oid)


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result

raw = git("ls-tree", "-r", "-z", head)
entries: dict[str, tuple[str, str]] = {}
for record in raw.split(b"\0"):
    if not record:
        continue
    metadata, raw_path = record.split(b"\t", 1)
    mode, kind, oid = metadata.decode("ascii").split(" ")
    path = raw_path.decode("utf-8")
    if path in entries:
        raise ValueError("duplicate tree path")
    entries[path] = (mode, oid)

sets: dict[str, dict[str, dict[str, tuple[str, str]]]] = {}
latest_paths: dict[str, tuple[str, str]] = {}
for path, entry in entries.items():
    match = archive_re.fullmatch(path)
    role = "archive"
    if match is None:
        match = checksum_re.fullmatch(path)
        role = "checksum"
    if match is None:
        match = manifest_re.fullmatch(path)
        role = "manifest"
    if match is not None:
        if entry[0] != "100644":
            raise ValueError(f"unsafe artifact mode: {path}")
        current = sets.setdefault(match.group(1), {}).setdefault(match.group(2), {})
        if role in current:
            raise ValueError(f"duplicate artifact role: {path}")
        current[role] = (path, entry[1])
        continue
    latest = latest_re.fullmatch(path)
    if latest is not None:
        if entry[0] != "100644" or latest.group(1) in latest_paths:
            raise ValueError(f"unsafe latest mode: {path}")
        latest_paths[latest.group(1)] = (path, entry[1])
        continue
    if path.startswith(("backups/", "manifests/")):
        raise ValueError(f"unexpected generated path: {path}")

remove: list[str] = []
complete_hosts: dict[str, list[str]] = {}
for name, by_id in sets.items():
    complete: list[str] = []
    for identifier, roles in by_id.items():
        if set(roles) != {"archive", "checksum", "manifest"}:
            raise ValueError(f"incomplete backup set for {name}: {identifier}")
        archive_path, archive_oid = roles["archive"]
        checksum_path, checksum_oid = roles["checksum"]
        manifest_path, manifest_oid = roles["manifest"]
        digest = hashlib.sha256(blob(archive_oid)).hexdigest()
        if blob(checksum_oid) != f"{digest}  {archive_path}\n".encode("ascii"):
            raise ValueError(f"invalid checksum: {checksum_path}")
        manifest = json.loads(blob(manifest_oid).decode("utf-8"), object_pairs_hook=unique_object)
        expected = {
            "host_id": name,
            "timestamp_utc": identifier,
            "encrypted_archive": archive_path,
            "encrypted_archive_sha256": digest,
        }
        if not isinstance(manifest, dict) or set(manifest) not in (set(expected), set(expected) | {"included_paths"}):
            raise ValueError(f"invalid manifest shape: {manifest_path}")
        if any(manifest.get(key) != value for key, value in expected.items()):
            raise ValueError(f"invalid manifest metadata: {manifest_path}")
        if "included_paths" in manifest and (
            not isinstance(manifest["included_paths"], list)
            or not manifest["included_paths"]
            or not all(isinstance(value, str) and value.startswith("/") and "\0" not in value for value in manifest["included_paths"])
        ):
            raise ValueError(f"invalid manifest paths: {manifest_path}")
        complete.append(identifier)
    complete.sort()
    latest = f"backups/{name}/{complete[-1]}.tar.zst.age\n".encode("ascii")
    latest_entry = latest_paths.get(name)
    if latest_entry is None or blob(latest_entry[1]) != latest:
        raise ValueError(f"latest pointer does not match newest complete set for {name}")
    complete_hosts[name] = complete
    for identifier in complete[:-keep]:
        remove.extend(role[0] for role in by_id[identifier].values())

parents = git("rev-list", "--parents", "-n", "1", head).split()
has_parent = len(parents) > 1
plan = {
    "remove": sorted(remove),
    "rewrite": bool(complete_hosts) and (bool(remove) or has_parent),
    "hosts": {name: len(values) for name, values in sorted(complete_hosts.items())},
}
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(plan, handle, sort_keys=True)
    handle.write("\n")
PY
}

compact_branch() {
  local branch="$1" ref head plan index rewrite new_tree new_oid path snapshot_epoch
  validate_branch "$branch"
  ref="refs/local-backup-push-kit/compaction/${REMOTE}/${branch}"
  git -C "$REPO_DIR" fetch --no-tags "$REMOTE" "+refs/heads/$branch:$ref" >/dev/null 2>&1 || fail "cannot fetch $REMOTE/$branch"
  head="$(git -C "$REPO_DIR" rev-parse "$ref")" || fail "cannot resolve fetched branch $branch"
  plan="$(mktemp "${TMPDIR:-/tmp}/local-backup-push-kit-compaction.XXXXXX")"
  trap 'rm -f -- "${plan:-}"' RETURN
  plan_compaction "$head" "$plan" || fail "branch '$branch' has malformed or incomplete backup data; refusing destructive compaction"
  rewrite="$(python3 - "$plan" <<'PY'
import json, sys
print("1" if json.load(open(sys.argv[1], encoding="utf-8"))["rewrite"] else "0")
PY
)"
  if [[ "$rewrite" != 1 ]]; then
    printf 'COMPACTION_NOOP branch=%s\n' "$branch"
    rm -f -- "$plan"
    trap - RETURN
    return 0
  fi
  mapfile -t removals < <(python3 - "$plan" <<'PY'
import json, sys
for path in json.load(open(sys.argv[1], encoding="utf-8"))["remove"]:
    print(path)
PY
)
  git -C "$REPO_DIR" read-tree "$head" || fail "cannot load branch tree for $branch"
  if [[ ${#removals[@]} -gt 0 ]]; then
    git -C "$REPO_DIR" update-index --force-remove -- "${removals[@]}" || fail "cannot stage retention removals for $branch"
  fi
  new_tree="$(git -C "$REPO_DIR" write-tree)" || fail "cannot write compacted tree for $branch"
  snapshot_epoch="$(git -C "$REPO_DIR" show -s --format=%ct "$head")" || fail "cannot read source commit timestamp for $branch"
  [[ "$snapshot_epoch" =~ ^[0-9]+$ ]] || fail "invalid source commit timestamp for $branch"
  new_oid="$(GIT_AUTHOR_NAME=backup-compactor GIT_AUTHOR_EMAIL=backup-compactor@example.invalid \
    GIT_COMMITTER_NAME=backup-compactor GIT_COMMITTER_EMAIL=backup-compactor@example.invalid \
    GIT_AUTHOR_DATE="@${snapshot_epoch} +0000" GIT_COMMITTER_DATE="@${snapshot_epoch} +0000" \
    git -C "$REPO_DIR" commit-tree "$new_tree" -m 'Compact encrypted backup history (keep 2 complete sets per host)')" || fail "cannot create compacted snapshot for $branch"
  git -C "$REPO_DIR" push "$REMOTE" "$new_oid:refs/heads/$branch" "--force-with-lease=refs/heads/$branch:$head" >/dev/null 2>&1 || \
    fail "cannot replace $REMOTE/$branch; branch changed or force-push permission is unavailable"
  printf 'COMPACTION_PUBLISHED branch=%s old=%s new=%s removed=%s\n' "$branch" "$head" "$new_oid" "${#removals[@]}"
  rm -f -- "$plan"
  trap - RETURN
}

if [[ -n "$REQUESTED_BRANCH" ]]; then
  [[ "$ALL_BRANCHES" == 0 ]] || fail 'cannot combine BACKUP_COMPACTION_BRANCH with BACKUP_COMPACTION_ALL_BRANCHES=1'
  compact_branch "$REQUESTED_BRANCH"
elif [[ "$ALL_BRANCHES" == 1 ]]; then
  git -C "$REPO_DIR" fetch --no-tags "$REMOTE" "+refs/heads/*:refs/local-backup-push-kit/compaction/${REMOTE}/*" >/dev/null 2>&1 || fail "cannot fetch branches from '$REMOTE'"
  while IFS=$'\t' read -r _ ref; do
    [[ "$ref" == refs/heads/* ]] || continue
    compact_branch "${ref#refs/heads/}"
  done < <(git -C "$REPO_DIR" ls-remote --heads "$REMOTE")
else
  fail 'set BACKUP_COMPACTION_BRANCH or BACKUP_COMPACTION_ALL_BRANCHES=1'
fi
