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
