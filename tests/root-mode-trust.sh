#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d /tmp/local-backup-root-mode-trust.XXXXXX)"
root_fixture="/opt/local-backup-root-mode-trust.$$"

as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

cleanup() {
  as_root rm -rf -- "$root_fixture" 2>/dev/null || true
  rm -rf -- "$fixture"
}
trap cleanup EXIT

bash -n "$PROJECT_ROOT/scripts/root-launcher.sh"
bash -n "$PROJECT_ROOT/scripts/install-systemd-timer.sh"

mkdir -p "$fixture/repo"
cp -a "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/hosts" "$fixture/repo/"
mkdir -p "$fixture/repo/hosts/testbox"
cat >"$fixture/repo/hosts/testbox/backup.conf" <<'EOF'
CONFIG_HOST_ID=testbox
BACKUP_RUN_USER=root
BACKUP_RUN_GROUP=root
BACKUP_ON_CALENDAR=daily
EOF
printf '%s\n' 'BACKUP_GIT_TOKEN=trusted-token_123' >"$fixture/token.env"

as_root mkdir -p "$root_fixture/env" "$root_fixture/systemd" "$root_fixture/libexec"
as_root cp -a "$fixture/repo" "$root_fixture/repo"
as_root install -o root -g root -m 0600 "$fixture/token.env" "$root_fixture/env/testbox.env"
as_root chown -R root:root "$root_fixture"
as_root chmod -R go-w "$root_fixture"
as_root bash -c 'printf %s\\n "#!/bin/bash" ": > \"$1\"" > "$2"' _ \
  "$root_fixture/executed" "$root_fixture/repo/scripts/backup.sh"
as_root chmod 0755 "$root_fixture/repo/scripts/backup.sh"

as_root bash "$root_fixture/repo/scripts/root-launcher.sh" --verify \
  "$root_fixture/repo" testbox "$root_fixture/env/testbox.env"
as_root bash "$root_fixture/repo/scripts/root-launcher.sh" \
  "$root_fixture/repo" testbox "$root_fixture/env/testbox.env"
[[ -f "$root_fixture/executed" ]]
env BACKUP_HOST=testbox BACKUP_INSTALL_DRY_RUN=1 \
  BACKUP_SYSTEMD_DIR="$root_fixture/systemd" BACKUP_ENV_DIR="$root_fixture/env" \
  BACKUP_ROOT_LAUNCHER_DIR="$root_fixture/libexec" \
  bash "$root_fixture/repo/scripts/install-systemd-timer.sh" >"$fixture/trusted-install.log" 2>&1
grep -Fq "ExecStart=$root_fixture/libexec/backup-launcher" "$fixture/trusted-install.log"
! grep -Fq 'EnvironmentFile=' "$fixture/trusted-install.log"

as_root mkdir -p "$root_fixture/unsafe-parent/libexec"
as_root chmod 0777 "$root_fixture/unsafe-parent"
if env BACKUP_HOST=testbox BACKUP_INSTALL_DRY_RUN=1 \
  BACKUP_SYSTEMD_DIR="$root_fixture/systemd" BACKUP_ENV_DIR="$root_fixture/env" \
  BACKUP_ROOT_LAUNCHER_DIR="$root_fixture/unsafe-parent/libexec" \
  bash "$root_fixture/repo/scripts/install-systemd-timer.sh" >"$fixture/unsafe-launcher-dir.log" 2>&1; then
  exit 1
fi
grep -Fq 'unsafe root launcher directory path' "$fixture/unsafe-launcher-dir.log"
as_root chmod 0755 "$root_fixture/unsafe-parent"
as_root rm -rf "$root_fixture/unsafe-parent"

as_root mkdir -p "$root_fixture/bin-success"
as_root bash -c 'cat >"$1/systemctl" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$1/systemctl"' _ "$root_fixture/bin-success"
as_root rm -rf "$root_fixture/missing-libexec"
as_root env PATH="$root_fixture/bin-success:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  BACKUP_HOST=testbox BACKUP_REPLACE_EXISTING=1 \
  BACKUP_SYSTEMD_DIR="$root_fixture/systemd" BACKUP_ENV_DIR="$root_fixture/env" \
  BACKUP_ROOT_LAUNCHER_DIR="$root_fixture/missing-libexec" \
  bash "$root_fixture/repo/scripts/install-systemd-timer.sh" >"$fixture/missing-launcher-dir.log" 2>&1
[[ "$(as_root stat -c '%u:%a' "$root_fixture/missing-libexec")" == '0:755' ]]
[[ -x "$root_fixture/missing-libexec/backup-launcher" ]]
as_root rm -f \
  "$root_fixture/systemd/encrypted-git-backup-testbox.service" \
  "$root_fixture/systemd/encrypted-git-backup-testbox.timer"
as_root rm -rf "$root_fixture/missing-libexec"

printf '%s\n' 'old service' | as_root tee "$root_fixture/systemd/encrypted-git-backup-testbox.service" >/dev/null
printf '%s\n' 'old timer' | as_root tee "$root_fixture/systemd/encrypted-git-backup-testbox.timer" >/dev/null
printf '%s\n' 'old launcher' | as_root tee "$root_fixture/libexec/backup-launcher" >/dev/null
as_root mkdir -p "$root_fixture/bin"
as_root bash -c 'cat >"$1/systemctl" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
exit 0
EOF
cat >"$1/install" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
count=0
counter="${0%/*}/install.count"
[[ -f "$counter" ]] && count="$(<"$counter")"
count=$((count + 1))
printf "%s\n" "$count" >"$counter"
[[ "$count" -ne 3 ]] || exit 71
exec /usr/bin/install "$@"
EOF
chmod 0755 "$1/systemctl" "$1/install"' _ "$root_fixture/bin"
if as_root env PATH="$root_fixture/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  BACKUP_HOST=testbox BACKUP_REPLACE_EXISTING=1 \
  BACKUP_SYSTEMD_DIR="$root_fixture/systemd" BACKUP_ENV_DIR="$root_fixture/env" \
  BACKUP_ROOT_LAUNCHER_DIR="$root_fixture/libexec" \
  bash "$root_fixture/repo/scripts/install-systemd-timer.sh" >"$fixture/root-rollback.log" 2>&1; then
  exit 1
fi
[[ "$(as_root cat "$root_fixture/bin/install.count")" == 3 ]]
[[ "$(as_root cat "$root_fixture/systemd/encrypted-git-backup-testbox.service")" == 'old service' ]]
[[ "$(as_root cat "$root_fixture/systemd/encrypted-git-backup-testbox.timer")" == 'old timer' ]]
[[ "$(as_root cat "$root_fixture/libexec/backup-launcher")" == 'old launcher' ]]

if env BACKUP_HOST=testbox BACKUP_INSTALL_DRY_RUN=1 \
  BACKUP_SYSTEMD_DIR="$fixture/systemd" BACKUP_ENV_DIR="$fixture/env" \
  BACKUP_ROOT_LAUNCHER_DIR="$fixture/libexec" \
  bash "$fixture/repo/scripts/install-systemd-timer.sh" >"$fixture/untrusted-install.log" 2>&1; then
  exit 1
fi
grep -Fq 'trusted repository' "$fixture/untrusted-install.log"

printf '%s\n' 'BACKUP_GIT_TOKEN=$(touch /tmp/should-not-run)' >"$fixture/malicious.env"
as_root install -o root -g root -m 0600 "$fixture/malicious.env" "$root_fixture/env/testbox.env"
if as_root bash "$root_fixture/repo/scripts/root-launcher.sh" --verify \
  "$root_fixture/repo" testbox "$root_fixture/env/testbox.env" >"$fixture/malicious.log" 2>&1; then
  exit 1
fi
grep -Fq 'unsafe token environment value' "$fixture/malicious.log"

as_root install -o root -g root -m 0600 "$fixture/token.env" "$root_fixture/env/testbox.env"
as_root mv "$root_fixture/env/testbox.env" "$root_fixture/env/testbox.env.real"
as_root ln -s testbox.env.real "$root_fixture/env/testbox.env"
if as_root bash "$root_fixture/repo/scripts/root-launcher.sh" --verify \
  "$root_fixture/repo" testbox "$root_fixture/env/testbox.env" >"$fixture/token-symlink.log" 2>&1; then
  exit 1
fi
grep -Fq 'regular non-symlink' "$fixture/token-symlink.log"
as_root rm "$root_fixture/env/testbox.env"
as_root mv "$root_fixture/env/testbox.env.real" "$root_fixture/env/testbox.env"

as_root chmod g+w "$root_fixture/repo/hosts/testbox/backup.conf"
if bash "$root_fixture/repo/scripts/root-launcher.sh" --verify-paths "$root_fixture/repo" testbox >"$fixture/unsafe.log" 2>&1; then
  exit 1
fi
grep -Fq 'unsafe ownership or permissions' "$fixture/unsafe.log"
as_root chmod go-w "$root_fixture/repo/hosts/testbox/backup.conf"
as_root chmod g+w "$root_fixture/repo/hosts/testbox"
if bash "$root_fixture/repo/scripts/root-launcher.sh" --verify-paths "$root_fixture/repo" testbox >"$fixture/parent.log" 2>&1; then
  exit 1
fi
grep -Fq 'unsafe ownership or permissions' "$fixture/parent.log"
as_root chmod go-w "$root_fixture/repo/hosts/testbox"
as_root mv "$root_fixture/repo/scripts/backup.sh" "$root_fixture/repo/scripts/backup.sh.real"
as_root ln -s backup.sh.real "$root_fixture/repo/scripts/backup.sh"
if bash "$root_fixture/repo/scripts/root-launcher.sh" --verify-paths "$root_fixture/repo" testbox >"$fixture/symlink.log" 2>&1; then
  exit 1
fi
grep -Fq 'symlink component' "$fixture/symlink.log"

printf 'PASS root-mode-trust\n'
