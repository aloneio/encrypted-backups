#!/bin/bash
set -euo pipefail

fail() { printf 'ERROR: root launcher: %s\n' "$*" >&2; exit 1; }

verify_only=0
verify_token=0
if [[ "${1:-}" == --verify || "${1:-}" == --verify-paths ]]; then
  [[ $# -eq 3 || $# -eq 4 ]] || fail 'expected --verify, repository path, host ID, and optional token environment path'
  verify_only=1
  [[ "$1" == --verify ]] && verify_token=1
  repo="$2"
  host="$3"
  token_env="${4:-/etc/encrypted-git-backup/$host.env}"
else
  [[ $# -eq 2 || $# -eq 3 ]] || fail 'expected repository path, host ID, and optional token environment path'
  repo="$1"
  host="$2"
  token_env="${3:-/etc/encrypted-git-backup/$host.env}"
fi
launcher_path="${BASH_SOURCE[0]}"
[[ "$repo" == /* && "$token_env" == /* && "$launcher_path" == /* ]] || fail 'launcher, repository, and token environment paths must be absolute'
[[ "$host" =~ ^([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9])$ ]] || fail 'invalid host ID'
[[ "$verify_only" == 1 || "$EUID" -eq 0 ]] || fail 'must be executed as root'

exec /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LANG=C LC_ALL=C \
  /usr/bin/python3 -I -P - "$verify_only" "$verify_token" "$repo" "$host" "$token_env" "$launcher_path" <<'PY'
import os
import pathlib
import re
import stat
import sys


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"ERROR: root launcher: {message}")


def normalized_absolute(raw: str, label: str) -> pathlib.Path:
    if not raw.startswith("/") or os.path.normpath(raw) != raw or "//" in raw:
        fail(f"{label} must be a normalized absolute path")
    return pathlib.Path(raw)


def path_components(path: pathlib.Path):
    current = pathlib.Path(path.anchor)
    yield current
    for part in path.parts[1:]:
        current = current / part
        yield current


def validate_component(path: pathlib.Path, *, expected: str | None = None, hard_links: bool = False):
    try:
        info = path.lstat()
    except OSError as error:
        fail(f"unsafe or missing path: {path}: {error}")
    if stat.S_ISLNK(info.st_mode):
        fail(f"symlink component: {path}")
    if info.st_uid != 0 or info.st_mode & 0o022:
        fail(f"unsafe ownership or permissions: {path}")
    if expected == "directory" and not stat.S_ISDIR(info.st_mode):
        fail(f"expected directory: {path}")
    if expected == "file" and not stat.S_ISREG(info.st_mode):
        fail(f"expected regular file: {path}")
    if hard_links and stat.S_ISREG(info.st_mode) and info.st_nlink != 1:
        fail(f"unsafe hard link count: {path}")
    return info


def validate_path(path: pathlib.Path, *, expected: str, hard_links: bool = False):
    components = list(path_components(path))
    for component in components[:-1]:
        validate_component(component, expected="directory")
    return validate_component(path, expected=expected, hard_links=hard_links)


def validate_existing_ancestors(path: pathlib.Path):
    for component in path_components(path.parent):
        try:
            component.lstat()
        except FileNotFoundError:
            break
        except OSError as error:
            fail(f"unsafe path component: {component}: {error}")
        validate_component(component, expected="directory")


def trusted_program_paths(repository: pathlib.Path, host_id: str, launcher: pathlib.Path):
    scripts = repository / "scripts"
    library = scripts / "lib"
    targets = [
        (repository, "directory", False),
        (scripts, "directory", False),
        (library, "directory", False),
        (repository / "hosts", "directory", False),
        (repository / "hosts" / host_id, "directory", False),
        (repository / "hosts" / host_id / "backup.conf", "file", True),
        (launcher, "file", True),
    ]
    for target, expected_type, check_links in targets:
        validate_path(target, expected=expected_type, hard_links=check_links)
    for child in scripts.iterdir():
        if child.name.endswith(".sh"):
            validate_path(child, expected="file", hard_links=True)
    for child in library.iterdir():
        if child.name.endswith(".sh"):
            validate_path(child, expected="file", hard_links=True)


TOKEN_NAME = re.compile(r"(?:BACKUP_TOKEN_[A-Z0-9_]+|BACKUP_GIT_TOKEN|BACKUP_GIT_USER|GITHUB_TOKEN|GITLAB_TOKEN)\Z")
TOKEN_VALUE = re.compile(r"[A-Za-z0-9._~:/+=,@%#-]+\Z")


def parse_quoted_value(raw: str, line_number: int) -> str:
    if len(raw) < 2 or not raw.endswith('"'):
        fail(f"malformed token environment line {line_number}")
    result = []
    index = 1
    end = len(raw) - 1
    while index < end:
        character = raw[index]
        if character == '"':
            fail(f"malformed token environment line {line_number}")
        if character == "\\":
            index += 1
            if index >= end or raw[index] not in ('"', "\\"):
                fail(f"unsupported token environment escape on line {line_number}")
            character = raw[index]
        result.append(character)
        index += 1
    return "".join(result)


def parse_token_environment(data: bytes):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        fail("token environment is not valid UTF-8")
    if "\x00" in text or "\r" in text:
        fail("token environment contains forbidden control characters")
    values = {}
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line:
            continue
        if any(ord(character) < 32 or ord(character) == 127 for character in line):
            fail(f"token environment contains control characters on line {line_number}")
        match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=(.*)", line)
        if match is None:
            fail(f"malformed token environment line {line_number}")
        name, raw_value = match.groups()
        if TOKEN_NAME.fullmatch(name) is None:
            fail(f"token environment variable is not permitted: {name}")
        if name in values:
            fail(f"duplicate token environment variable: {name}")
        if raw_value.startswith('"'):
            value = parse_quoted_value(raw_value, line_number)
        else:
            if '"' in raw_value or "\\" in raw_value or raw_value != raw_value.strip():
                fail(f"malformed unquoted token value on line {line_number}")
            value = raw_value
        if not value:
            fail(f"empty token value on line {line_number}")
        if TOKEN_VALUE.fullmatch(value) is None:
            fail(f"unsafe token environment value on line {line_number}")
        values[name] = value
    return values


def read_token_environment(path: pathlib.Path):
    validate_existing_ancestors(path)
    try:
        before = path.lstat()
    except FileNotFoundError:
        return {}
    except OSError as error:
        fail(f"cannot inspect token environment: {error}")
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        fail("token environment must be a regular non-symlink file")
    if before.st_uid != 0 or before.st_mode & 0o022 or before.st_nlink != 1:
        fail("unsafe token environment ownership, permissions, or hard link count")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        fail(f"cannot open trusted token environment: {error}")
    try:
        after = os.fstat(descriptor)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            fail("token environment changed during validation")
        if after.st_uid != 0 or after.st_mode & 0o022 or after.st_nlink != 1 or not stat.S_ISREG(after.st_mode):
            fail("unsafe token environment metadata after open")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            data = handle.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            fail("token environment exceeds 1 MiB")
    finally:
        os.close(descriptor)
    return parse_token_environment(data)


verify_only = sys.argv[1] == "1"
verify_token = sys.argv[2] == "1"
repository = normalized_absolute(sys.argv[3], "repository path")
host = sys.argv[4]
token_path = normalized_absolute(sys.argv[5], "token environment path")
launcher = normalized_absolute(sys.argv[6], "launcher path")
if re.fullmatch(r"(?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9])", host) is None:
    fail("invalid host ID")

trusted_program_paths(repository, host, launcher)

if verify_only:
    if verify_token:
        read_token_environment(token_path)
    raise SystemExit(0)

backup = repository / "scripts" / "backup.sh"
tokens = read_token_environment(token_path)
environment = {
    "BACKUP_HOST": host,
    "BACKUP_PUSH": "1",
    "HOME": "/root",
    "LANG": "C",
    "LC_ALL": "C",
    "LOGNAME": "root",
    "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "SHELL": "/bin/bash",
    "USER": "root",
}
environment.update(tokens)
try:
    os.chdir(repository)
    os.execve("/bin/bash", ["/bin/bash", str(backup)], environment)
except OSError as error:
    fail(f"cannot execute trusted backup: {error}")
PY
