#!/usr/bin/env bash

publication_git() {
  env \
    -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    -u GIT_CONFIG -u GIT_CONFIG_SYSTEM -u GIT_CONFIG_GLOBAL \
    -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT \
    -u GIT_NO_REPLACE_OBJECTS -u GIT_ATTR_NOSYSTEM \
    -u GIT_ASKPASS -u GIT_ASKPASS_USERNAME -u GIT_ASKPASS_TOKEN \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_NO_REPLACE_OBJECTS=1 GIT_ATTR_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_MASTER=1 \
    git --no-replace-objects -c core.hooksPath=/dev/null -C "$REPO_DIR" "$@"
}

publication_python() {
  env \
    -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    -u GIT_CONFIG -u GIT_CONFIG_SYSTEM -u GIT_CONFIG_GLOBAL \
    -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT \
    -u GIT_NO_REPLACE_OBJECTS -u GIT_ATTR_NOSYSTEM \
    -u GIT_ASKPASS -u GIT_ASKPASS_USERNAME -u GIT_ASKPASS_TOKEN \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_NO_REPLACE_OBJECTS=1 GIT_ATTR_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_MASTER=1 \
    python3 "$@"
}

publication_commit_shape_valid() {
  local oid="$1" expected_parent="${2:-}"
  env \
    -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    -u GIT_CONFIG -u GIT_CONFIG_SYSTEM -u GIT_CONFIG_GLOBAL \
    -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT \
    -u GIT_NO_REPLACE_OBJECTS -u GIT_ATTR_NOSYSTEM \
    -u GIT_ASKPASS -u GIT_ASKPASS_USERNAME -u GIT_ASKPASS_TOKEN \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_NO_REPLACE_OBJECTS=1 GIT_ATTR_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_MASTER=1 \
    python3 - "$REPO_DIR" "$oid" "$expected_parent" <<'PY'
import hashlib
import json
import os
import re
import subprocess
import sys

root, oid, expected_parent = sys.argv[1:]
oid_pattern = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
artifact_pattern = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z(?:-[0-9]{9})?"


def git_environment() -> dict[str, str]:
    environment = os.environ.copy()
    for name in tuple(environment):
        if name.startswith("GIT_CONFIG_KEY_") or name.startswith("GIT_CONFIG_VALUE_"):
            environment.pop(name, None)
    for name in (
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CONFIG",
        "GIT_CONFIG_SYSTEM",
        "GIT_CONFIG_PARAMETERS",
        "GIT_CONFIG_COUNT",
        "GIT_ASKPASS",
        "GIT_ASKPASS_USERNAME",
        "GIT_ASKPASS_TOKEN",
    ):
        environment.pop(name, None)
    environment.update(
        {
            "GIT_ATTR_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_MASTER": "1",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "LC_ALL": "C",
        }
    )
    return environment


def git(*arguments: str, input_bytes: bytes | None = None) -> bytes:
    return subprocess.check_output(
        [
            "git",
            "--no-replace-objects",
            "-c",
            "core.hooksPath=/dev/null",
            "-C",
            root,
            *arguments,
        ],
        input=input_bytes,
        stderr=subprocess.DEVNULL,
        env=git_environment(),
    )


def parse_commit() -> tuple[str, str]:
    raw = git("cat-file", "commit", oid)
    headers, separator, body = raw.partition(b"\n\n")
    if not separator:
        raise ValueError
    parents = []
    for line in headers.splitlines():
        if line.startswith(b"parent "):
            parent = line[7:].decode("ascii")
            if oid_pattern.fullmatch(parent) is None:
                raise ValueError
            parents.append(parent)
    if len(parents) != 1:
        raise ValueError
    if expected_parent and parents[0] != expected_parent:
        raise ValueError
    subject = body.split(b"\n", 1)[0].decode("utf-8")
    return parents[0], subject


def parse_raw_diff(parent: str) -> list[tuple[str, str, str, str, str]]:
    fields = git(
        "diff-tree",
        "--no-commit-id",
        "--raw",
        "-r",
        "-z",
        "--no-renames",
        parent,
        oid,
    ).split(b"\0")
    if fields[-1:] != [b""] or (len(fields) - 1) % 2:
        raise ValueError
    entries = []
    header_pattern = re.compile(rb":([0-7]{6}) ([0-7]{6}) ([0-9a-f]+) ([0-9a-f]+) ([AMDT])")
    for index in range(0, len(fields) - 1, 2):
        match = header_pattern.fullmatch(fields[index])
        if match is None:
            raise ValueError
        old_mode, new_mode, _old_oid, new_oid, status = (value.decode("ascii") for value in match.groups())
        path = fields[index + 1].decode("utf-8")
        entries.append((status, old_mode, new_mode, new_oid, path))
    if len({entry[4] for entry in entries}) != len(entries):
        raise ValueError
    return entries


def regular_blob(mode: str, blob_oid: str) -> bytes:
    if mode != "100644" or oid_pattern.fullmatch(blob_oid) is None:
        raise ValueError
    if git("cat-file", "-t", blob_oid) != b"blob\n":
        raise ValueError
    return git("cat-file", "blob", blob_oid)


def json_object(raw: bytes) -> dict[str, object]:
    def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError
            result[key] = value
        return result

    value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    if not isinstance(value, dict):
        raise ValueError
    return value


try:
    parent, subject = parse_commit()
    subject_match = re.fullmatch(
        rf"Add ([A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?) encrypted backup ({artifact_pattern})",
        subject,
    )
    if subject_match is None:
        raise ValueError
    host, artifact = subject_match.groups()
    archive_path = f"backups/{host}/{artifact}.tar.zst.age"
    checksum_path = f"backups/{host}/{artifact}.sha256"
    manifest_path = f"manifests/{host}/{artifact}.json"
    latest_path = f"backups/{host}/latest.txt"
    required = {
        archive_path: "A",
        checksum_path: "A",
        manifest_path: "A",
        latest_path: None,
    }
    required_blobs = {}
    deleted_by_artifact: dict[str, set[str]] = {}
    deletion_patterns = (
        ("archive", re.compile(rf"backups/{re.escape(host)}/({artifact_pattern})\.tar\.zst\.age")),
        ("checksum", re.compile(rf"backups/{re.escape(host)}/({artifact_pattern})\.sha256")),
        ("manifest", re.compile(rf"manifests/{re.escape(host)}/({artifact_pattern})\.json")),
    )
    seen = set()
    for status, old_mode, new_mode, blob_oid, path in parse_raw_diff(parent):
        if path in required:
            expected_status = required[path]
            if path in seen or status not in ({"A", "M"} if expected_status is None else {expected_status}):
                raise ValueError
            if status == "A" and old_mode != "000000":
                raise ValueError
            if status == "M" and old_mode != "100644":
                raise ValueError
            required_blobs[path] = regular_blob(new_mode, blob_oid)
            seen.add(path)
            continue
        if status != "D" or old_mode != "100644" or new_mode != "000000" or blob_oid.strip("0"):
            raise ValueError
        matches = [(role, pattern.fullmatch(path)) for role, pattern in deletion_patterns]
        matches = [(role, match) for role, match in matches if match is not None]
        if len(matches) != 1:
            raise ValueError
        role, match = matches[0]
        old_artifact = match.group(1)
        if old_artifact == artifact:
            raise ValueError
        roles = deleted_by_artifact.setdefault(old_artifact, set())
        if role in roles:
            raise ValueError
        roles.add(role)
    if seen != set(required):
        raise ValueError
    if any(roles != {"archive", "checksum", "manifest"} for roles in deleted_by_artifact.values()):
        raise ValueError
    if list(deleted_by_artifact) != sorted(deleted_by_artifact):
        raise ValueError

    archive = required_blobs[archive_path]
    if not archive:
        raise ValueError
    archive_hash = hashlib.sha256(archive).hexdigest()
    if required_blobs[checksum_path] != f"{archive_hash}  {archive_path}\n".encode("ascii"):
        raise ValueError
    if required_blobs[latest_path] != f"{archive_path}\n".encode("ascii"):
        raise ValueError
    manifest = json_object(required_blobs[manifest_path])
    if set(manifest) not in (
        {"host_id", "timestamp_utc", "encrypted_archive", "encrypted_archive_sha256"},
        {"host_id", "timestamp_utc", "encrypted_archive", "encrypted_archive_sha256", "included_paths"},
    ):
        raise ValueError
    expected_manifest = {
        "host_id": host,
        "timestamp_utc": artifact,
        "encrypted_archive": archive_path,
        "encrypted_archive_sha256": archive_hash,
    }
    if any(manifest.get(key) != value for key, value in expected_manifest.items()):
        raise ValueError
    if "included_paths" in manifest and (
        not isinstance(manifest["included_paths"], list)
        or not manifest["included_paths"]
        or not all(isinstance(path, str) and path.startswith("/") and "\x00" not in path for path in manifest["included_paths"])
    ):
        raise ValueError
except (OSError, subprocess.CalledProcessError, UnicodeDecodeError, json.JSONDecodeError, ValueError):
    raise SystemExit(1)
PY
}

validate_compaction_snapshot_commit() {
  local snapshot_oid="$1" local_oid="$2"
  publication_git cat-file -e "$snapshot_oid^{commit}" 2>/dev/null || return 1
  publication_git cat-file -e "$local_oid^{commit}" 2>/dev/null || return 1
  publication_python - "$REPO_DIR" "$snapshot_oid" "$local_oid" <<'PY'
from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys

root, snapshot_oid, local_oid = sys.argv[1:]
oid_pattern = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
host_pattern = r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?"
artifact_pattern = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z(?:-[0-9]{9})?"
archive_re = re.compile(rf"backups/({host_pattern})/({artifact_pattern})\.tar\.zst\.age")
checksum_re = re.compile(rf"backups/({host_pattern})/({artifact_pattern})\.sha256")
manifest_re = re.compile(rf"manifests/({host_pattern})/({artifact_pattern})\.json")
latest_re = re.compile(rf"backups/({host_pattern})/latest\.txt")


def git(*args: str) -> bytes:
    return subprocess.check_output(
        ["git", "-C", root, "--no-replace-objects", "-c", "core.hooksPath=/dev/null", *args],
        stderr=subprocess.DEVNULL,
    )


def tree(oid: str) -> dict[str, tuple[str, str]]:
    result: dict[str, tuple[str, str]] = {}
    for record in git("ls-tree", "-r", "-z", oid).split(b"\0"):
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, kind, object_oid = metadata.decode("ascii").split(" ")
        if kind != "blob" or mode not in {"100644", "100755"} or not oid_pattern.fullmatch(object_oid):
            raise ValueError
        path = raw_path.decode("utf-8")
        if path in result:
            raise ValueError
        result[path] = (mode, object_oid)
    return result


def blob(oid: str) -> bytes:
    if git("cat-file", "-t", oid) != b"blob\n":
        raise ValueError
    return git("cat-file", "blob", oid)


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError
        result[key] = value
    return result


def generated(path: str) -> bool:
    return path.startswith("backups/") or path.startswith("manifests/")


def valid_data_path(path: str) -> bool:
    return bool(archive_re.fullmatch(path) or checksum_re.fullmatch(path) or manifest_re.fullmatch(path) or latest_re.fullmatch(path))

raw_commit = git("cat-file", "commit", snapshot_oid)
headers, separator, body = raw_commit.partition(b"\n\n")
if not separator:
    raise ValueError
parents = [line[7:] for line in headers.splitlines() if line.startswith(b"parent ")]
if parents or body.split(b"\n", 1)[0] != b"Compact encrypted backup history (keep 2 complete sets per host)":
    raise ValueError

snapshot = tree(snapshot_oid)
local = tree(local_oid)
for path in set(snapshot) | set(local):
    if not generated(path) and snapshot.get(path) != local.get(path):
        raise ValueError
for path in snapshot:
    if generated(path) and not valid_data_path(path):
        raise ValueError
for path, entry in local.items():
    if generated(path) and path in snapshot and snapshot[path] != entry:
        raise ValueError

sets: dict[str, dict[str, dict[str, tuple[str, str]]]] = {}
latest: dict[str, tuple[str, str]] = {}
for path, entry in snapshot.items():
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
            raise ValueError
        roles = sets.setdefault(match.group(1), {}).setdefault(match.group(2), {})
        if role in roles:
            raise ValueError
        roles[role] = (path, entry[1])
        continue
    match = latest_re.fullmatch(path)
    if match is not None:
        if entry[0] != "100644" or match.group(1) in latest:
            raise ValueError
        latest[match.group(1)] = (path, entry[1])

local_artifacts: dict[str, list[str]] = {}
for path in local:
    match = archive_re.fullmatch(path)
    if match is not None:
        local_artifacts.setdefault(match.group(1), []).append(match.group(2))
for host, artifacts in local_artifacts.items():
    if host not in sets or not set(sorted(artifacts)[-2:]).issubset(sets[host]):
        raise ValueError

local_hosts = {match.group(1) for path in local for match in [archive_re.fullmatch(path)] if match is not None}
if not local_hosts.issubset(sets):
    raise ValueError
for host, by_artifact in sets.items():
    if not 1 <= len(by_artifact) <= 2:
        raise ValueError
    complete = []
    for artifact, roles in by_artifact.items():
        if set(roles) != {"archive", "checksum", "manifest"}:
            raise ValueError
        archive_path, archive_oid = roles["archive"]
        checksum_path, checksum_oid = roles["checksum"]
        manifest_path, manifest_oid = roles["manifest"]
        digest = hashlib.sha256(blob(archive_oid)).hexdigest()
        if blob(checksum_oid) != f"{digest}  {archive_path}\n".encode("ascii"):
            raise ValueError
        manifest = json.loads(blob(manifest_oid).decode("utf-8"), object_pairs_hook=unique_object)
        expected = {
            "host_id": host,
            "timestamp_utc": artifact,
            "encrypted_archive": archive_path,
            "encrypted_archive_sha256": digest,
        }
        if not isinstance(manifest, dict) or set(manifest) not in (set(expected), set(expected) | {"included_paths"}):
            raise ValueError
        if any(manifest.get(key) != value for key, value in expected.items()):
            raise ValueError
        if "included_paths" in manifest and (
            not isinstance(manifest["included_paths"], list)
            or not manifest["included_paths"]
            or not all(isinstance(value, str) and value.startswith("/") and "\0" not in value for value in manifest["included_paths"])
        ):
            raise ValueError
        complete.append(artifact)
    complete.sort()
    latest_entry = latest.get(host)
    if latest_entry is None or blob(latest_entry[1]) != f"backups/{host}/{complete[-1]}.tar.zst.age\n".encode("ascii"):
        raise ValueError
if set(latest) != set(sets):
    raise ValueError
PY
}

validate_publication_commit_range() {
  local base_oid="$1" tip_oid="$2" oid expected
  expected="$base_oid"
  while IFS= read -r oid; do
    [[ -n "$oid" ]] || continue
    publication_commit_shape_valid "$oid" "$expected" || return 1
    expected="$oid"
  done < <(publication_git rev-list --reverse "$base_oid..$tip_oid")
  [[ "$expected" == "$tip_oid" ]]
}
