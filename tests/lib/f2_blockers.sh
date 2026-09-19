#!/usr/bin/env bash

scenario_f2_retention_durable_tristate() {
  local publication_pid status recovery_dir relative base tree unsafe
  local -a environment=() deletions=()
  todo5_setup f2-durable-tristate || return 2
  todo5_seed_mixed_hosts
  todo5_finalize_setup || return 2
  todo5_prepare || return 2
  mapfile -t deletions < <(/usr/bin/python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1], encoding="utf-8"))["retention_deletions"]))' "$TODO5_STATE")
  todo5_install_hung_commit_wrapper
  mapfile -t environment < <(fixture_env "$TODO5_FIXTURE")
  setsid env \
    "${environment[@]}" \
    TODO5_HANG_MARKER="$TODO5_FIXTURE/hang.marker" \
    BACKUP_HOST=testbox BACKUP_RETENTION_COUNT=3 \
    bash "$TODO5_REPO/scripts/publish-prepared.sh" >"$TODO5_FIXTURE/killed.log" 2>&1 &
  publication_pid=$!
  ACTIVE_GROUPS+=("$publication_pid")
  todo5_wait_for_hang_marker "$TODO5_FIXTURE/hang.marker" || return 2
  kill -KILL -- "-$publication_pid" 2>/dev/null || true
  wait "$publication_pid"; status=$?
  ACTIVE_GROUPS=()
  [[ "$status" -ne 0 ]] || return 2
  recovery_dir="$TODO5_REPO/.git/local-backup-push-kit/recovery/retention/testbox"
  if [[ ! -f "$recovery_dir/journal" ]]; then
    known_failure "retention rollback is not durably journaled per host before destructive mutation"
    return $?
  fi
  if ! /usr/bin/python3 - "$recovery_dir/journal" <<'PY'
import json, pathlib, sys
state=json.loads(pathlib.Path(sys.argv[1]).read_text())
required={"version","host","branch","base_oid","index_tree","prepared_state_sha256","commit_message","prepared_paths","prepared_hashes","retention","payload"}
assert set(state)==required
assert all(set(item)=={"archive","checksum","manifest"} for item in state["retention"])
assert all(set(item)=={"path","sha256","mode"} for item in state["payload"])
PY
  then
    known_failure "retention durable journal is not bound to exact prepared publication and payload metadata"
    return $?
  fi
  for relative in "${deletions[@]}"; do [[ ! -e "$TODO5_REPO/$relative" ]] || return 2; done
  rm -f -- "$TODO5_FIXTURE/bin/git"
  base="$(/usr/bin/git -C "$TODO5_REPO" rev-parse HEAD)"
  tree="$(/usr/bin/git -C "$TODO5_REPO" rev-parse 'HEAD^{tree}')"
  unsafe="$(printf 'unsafe recovery child\n' | GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid /usr/bin/git -C "$TODO5_REPO" commit-tree "$tree" -p "$base")" || return 2
  /usr/bin/git -C "$TODO5_REPO" update-ref refs/heads/main "$unsafe" "$base" || return 2
  if todo5_publish; then return 2; fi
  grep -Fq 'retention recovery state is unknown; journal preserved' "$TODO5_FIXTURE/publish.log" || return 2
  [[ -f "$recovery_dir/journal" ]] || return 2
  /usr/bin/git -C "$TODO5_REPO" update-ref refs/heads/main "$base" "$unsafe" || return 2
  todo5_publish || return 2
  [[ ! -e "$recovery_dir" ]] || return 2
  [[ -z "$(/usr/bin/git -C "$TODO5_REPO" status --porcelain=v1 --untracked-files=all)" ]] || return 2
}

scenario_f2_canonical_publication_shape() {
  local before_oid before_hash attacker output artifact archive
  todo5_setup f2-canonical-shape || return 2
  todo5_finalize_setup || return 2
  before_oid="$(/usr/bin/git -C "$TODO5_REPO" rev-parse HEAD)"
  before_hash="$(/usr/bin/sha256sum "$TODO5_REPO/scripts/backup.sh")"
  attacker="$TODO5_FIXTURE/attacker"
  /usr/bin/git clone -q --branch main "$TODO5_CANONICAL" "$attacker" || return 2
  /usr/bin/git -C "$attacker" config user.name fixture
  /usr/bin/git -C "$attacker" config user.email fixture@example.invalid
  printf '\n# unsafe canonical operational change\n' >>"$attacker/scripts/backup.sh"
  /usr/bin/git -C "$attacker" add scripts/backup.sh
  /usr/bin/git -C "$attacker" commit -qm 'unsafe operational change'
  /usr/bin/git -C "$attacker" push -q origin HEAD:refs/heads/main || return 2
  output="$TODO5_FIXTURE/unsafe-canonical.log"
  if todo5_run "$output" BACKUP_PUSH=0 bash "$TODO5_REPO/scripts/backup.sh"; then
    known_failure "canonical fast-forward accepts commits that are not publication-shaped"
    return $?
  fi
  [[ "$(/usr/bin/git -C "$TODO5_REPO" rev-parse HEAD)" == "$before_oid" ]] || return 2
  [[ "$(/usr/bin/sha256sum "$TODO5_REPO/scripts/backup.sh")" == "$before_hash" ]] || return 2
  grep -Fq 'canonical commit is not publication-shaped' "$output" || return 2

  new_fixture f2-canonical-credential-controls || return 2
  local credential_fixture="$FIXTURE" credential_helper header_output
  credential_helper="$credential_fixture/credential-helper"
  cat >"$credential_helper" <<'EOF'
#!/usr/bin/env bash
: >"${F2_CREDENTIAL_HELPER_MARKER:?}"
EOF
  chmod +x "$credential_helper"
  /usr/bin/git -C "$credential_fixture" init -q || return 2
  if ! env \
    F2_CREDENTIAL_HELPER_MARKER="$credential_fixture/credential-helper.marker" \
    GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0=credential.helper \
    GIT_CONFIG_VALUE_0="!$credential_helper" \
    GIT_CONFIG_KEY_1=http.extraheader \
    GIT_CONFIG_VALUE_1='X-Injected-Authorization: sentinel' \
    bash -c '
      set -euo pipefail
      REPO_DIR="$1"
      source "$2/scripts/lib/common.sh"
      source "$2/scripts/lib/git-remotes.sh"
      printf "protocol=https\nhost=canonical.invalid\n\n" | git_without_credentials credential fill >/dev/null 2>&1 || true
      git_without_credentials config --get-all http.extraheader >"$3" || true
    ' _ "$credential_fixture" "$PROJECT_ROOT" "$credential_fixture/extraheader.log"; then
    return 2
  fi
  header_output="$(<"$credential_fixture/extraheader.log")"
  if [[ -e "$credential_fixture/credential-helper.marker" || "$header_output" == *sentinel* ]]; then
    known_failure "credentialless canonical Git preserves injected credential helper or HTTP extraheader"
    return $?
  fi
  mkdir -p "$credential_fixture/bin"
cat >"$credential_fixture/bin/git" <<EOF
#!/usr/bin/env bash
: >"$credential_fixture/ssh-git.marker"
if [[ "\${GIT_SSH_COMMAND:-}" == "$credential_fixture/ssh-sentinel" ]]; then
  "\$GIT_SSH_COMMAND"
fi
exit 1
EOF
  cat >"$credential_fixture/ssh-sentinel" <<'EOF'
#!/usr/bin/env bash
: >"${F2_SSH_MARKER:?}"
EOF
  chmod +x "$credential_fixture/bin/git" "$credential_fixture/ssh-sentinel"
  PATH="$credential_fixture/bin:$PATH" \
    F2_SSH_MARKER="$credential_fixture/ssh.marker" \
    GIT_SSH_COMMAND="$credential_fixture/ssh-sentinel" \
    bash -c '
      set -euo pipefail
      REPO_DIR="$1"
      source "$2/scripts/lib/common.sh"
      source "$2/scripts/lib/git-remotes.sh"
      git_without_credentials ls-remote ssh://canonical.invalid/backup.git || true
    ' _ "$credential_fixture" "$PROJECT_ROOT" || return 2
  if [[ ! -e "$credential_fixture/ssh-git.marker" || -e "$credential_fixture/ssh.marker" ]]; then
    known_failure "credentialless canonical Git preserves injected SSH command"
    return $?
  fi

  todo5_setup f2-canonical-malformed-blobs || return 2
  todo5_finalize_setup || return 2
  attacker="$TODO5_FIXTURE/attacker"
  /usr/bin/git clone -q --branch main "$TODO5_CANONICAL" "$attacker" || return 2
  /usr/bin/git -C "$attacker" config user.name fixture
  /usr/bin/git -C "$attacker" config user.email fixture@example.invalid
  artifact=2026-01-01T00-00-00Z
  archive="backups/testbox/$artifact.tar.zst.age"
  mkdir -p "$attacker/backups/testbox" "$attacker/manifests/testbox"
  printf 'x' >"$attacker/$archive"
  printf 'malformed checksum\n' >"$attacker/backups/testbox/$artifact.sha256"
  printf '{}\n' >"$attacker/manifests/testbox/$artifact.json"
  printf '%s\n' "$archive" >"$attacker/backups/testbox/latest.txt"
  /usr/bin/git -C "$attacker" add -- "$archive" "backups/testbox/$artifact.sha256" "manifests/testbox/$artifact.json" backups/testbox/latest.txt
  /usr/bin/git -C "$attacker" commit -qm "Add testbox encrypted backup $artifact"
  /usr/bin/git -C "$attacker" push -q origin HEAD:refs/heads/main || return 2
  if todo5_run "$TODO5_FIXTURE/malformed-blobs.log" BACKUP_PUSH=0 bash "$TODO5_REPO/scripts/backup.sh"; then
    known_failure "canonical validation accepts malformed archive/checksum/manifest blob semantics"
    return $?
  fi
}

scenario_f2_root_launcher_transaction() {
  local output launcher_dir marker
  todo6_setup f2-root-launcher || return 2
  todo6_write_config root root daily origin
  launcher_dir="$TODO6_FIXTURE/libexec"
  output="$TODO6_FIXTURE/root-launcher.log"
  if todo6_run_installer "$output" BACKUP_INSTALL_DRY_RUN=1 BACKUP_ROOT_LAUNCHER_DIR="$launcher_dir"; then return 2; fi
  grep -Fq 'trusted repository' "$output" || return 2
  marker="$TODO6_FIXTURE/unsafe-executed"
  printf '\nprintf %s\\n reached >%q\n' "$marker" "$marker" >>"$TODO6_REPO/scripts/backup.sh"
  if bash "$TODO6_REPO/scripts/root-launcher.sh" "$TODO6_REPO" "$TODO6_HOST" >"$TODO6_FIXTURE/launcher-reject.log" 2>&1; then return 2; fi
  grep -Fq 'must be executed as root' "$TODO6_FIXTURE/launcher-reject.log" || return 2
  [[ ! -e "$marker" ]] || return 2
  todo8_setup f2-root-migration || return 2
  cat >"$TODO8_SYSTEMD_DIR/encrypted-git-backup-testbox.service" <<EOF
[Service]
User=root
ExecStart=/bin/bash "$TODO8_REPO/scripts/backup.sh"
EOF
  if todo8_run "$TODO8_FIXTURE/root-migration.log" bash "$TODO8_REPO/scripts/migrate-legacy.sh"; then return 2; fi
  grep -Fq 'direct root repository timer unit encrypted-git-backup-testbox.service' "$TODO8_FIXTURE/root-migration.log" || return 2
  grep -Fq 'trusted launcher' "$TODO8_FIXTURE/root-migration.log" || return 2
}
