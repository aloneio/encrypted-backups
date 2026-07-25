#!/usr/bin/env bash

TODO9_RAW_URL='https://gitlab.com/aloneio/local-backup-push-kit/-/raw/main/docs/llm-setup-guide.zh.md'

todo9_require_text() {
  local text="$1" file="${2:-$PROJECT_ROOT/README.md}"
  grep -Fq -- "$text" "$file" || {
    say_error "Todo 9 document text missing: $text"
    return 2
  }
}

todo9_reject_pattern() {
  local pattern="$1"
  if grep -Eq -- "$pattern" "$PROJECT_ROOT/README.md"; then
    say_error "Todo 9 forbidden README pattern present: $pattern"
    return 2
  fi
}

scenario_readme_contract() {
  local script field
  todo9_require_text "$TODO9_RAW_URL" || return 2
  for script in \
    scripts/backup.sh \
    scripts/publish-prepared.sh \
    scripts/configure-secrets.sh \
    scripts/install-systemd-timer.sh \
    scripts/migrate-legacy.sh; do
    [[ -x "$PROJECT_ROOT/$script" ]] || return 2
    todo9_require_text "$script" || return 2
  done
  for field in \
    CONFIG_HOST_ID AGE_RECIPIENT BACKUP_BRANCH BACKUP_REMOTES BACKUP_PATHS \
    TAR_EXCLUDES BACKUP_RETENTION_COUNT BACKUP_LOCK_TIMEOUT BACKUP_RUN_USER \
    BACKUP_RUN_GROUP BACKUP_ON_CALENDAR; do
    todo9_require_text "$field" "$PROJECT_ROOT/hosts/example/backup.conf" || return 2
  done
  todo9_require_text '<host-id>' "$PROJECT_ROOT/hosts/example/backup.conf" || return 2
  todo9_require_text '<user-supplied-age1-public-recipient>' "$PROJECT_ROOT/hosts/example/backup.conf" || return 2
  todo9_require_text '<canonical-remote>' "$PROJECT_ROOT/hosts/example/backup.conf" || return 2
  todo9_require_text '<positive-integer>' "$PROJECT_ROOT/hosts/example/backup.conf" || return 2
  if grep -Eq 'github-main|gitlab-main|/srv/example|BACKUP_TOKEN_|GITHUB_TOKEN|GITLAB_TOKEN' "$PROJECT_ROOT/hosts/example/backup.conf"; then
    say_error 'Todo 9 example config contains an old literal or token field'
    return 2
  fi
  todo9_require_text '用户提供的 `age1...` 公钥' || return 2
  todo9_require_text 'BACKUP_HOST=<host> BACKUP_PUSH=0 scripts/backup.sh' || return 2
  todo9_require_text 'BACKUP_HOST=<host> scripts/publish-prepared.sh' || return 2
  todo9_require_text 'BACKUP_HOST=<host> scripts/configure-secrets.sh' || return 2
  todo9_require_text 'BACKUP_INSTALL_DRY_RUN=1' || return 2
  todo9_require_text 'BACKUP_HOST=<host> scripts/migrate-legacy.sh' || return 2
  todo9_require_text 'BACKUP_HOST=<host> scripts/migrate-legacy.sh --adopt-staged' || return 2
  todo9_require_text 'BACKUP_BRANCH' || return 2
  todo9_require_text 'SSH' || return 2
  todo9_require_text 'manifest' || return 2
  todo9_require_text '外部临时目录' || return 2
  todo9_reject_pattern 'export[[:space:]]+BACKUP_TOKEN_' || return 2
  todo9_reject_pattern 'git[[:space:]]+pull[[:space:]]+--rebase|git[[:space:]]+rebase|git[[:space:]]+push[^\n]*--force' || return 2
  todo9_reject_pattern '\.github/workflows/retention\.yml|\.gitlab-ci\.yml' || return 2
}

scenario_readme_novice_flow() {
  python3 - "$PROJECT_ROOT/README.md" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
ordered = [
    "cp hosts/example/backup.conf hosts/<host>/backup.conf",
    "git commit",
    "BACKUP_HOST=<host> scripts/configure-secrets.sh",
    "BACKUP_HOST=<host> BACKUP_PUSH=0 scripts/backup.sh",
    "sha256sum -c",
    "用户控制的外部恢复处理",
    "明确确认",
    "BACKUP_HOST=<host> scripts/publish-prepared.sh",
    "BACKUP_HOST=<host> scripts/install-systemd-timer.sh",
]
position = -1
for token in ordered:
    next_position = text.find(token, position + 1)
    if next_position < 0:
        raise SystemExit(f"missing ordered novice token: {token}")
    if next_position <= position:
        raise SystemExit(f"out of order novice token: {token}")
    position = next_position
PY
  todo9_require_text '初始干净提交' || return 2
  todo9_require_text '可选' || return 2
  todo9_require_text '不要执行发布命令' || return 2
  todo9_require_text '兼容快捷方式' || return 2
}

scenario_readme_local_remotes() {
  todo9_require_text '第一个远端是唯一的 canonical' || return 2
  todo9_require_text '后续远端都是 mirror' || return 2
  todo9_require_text '空分支' || return 2
  todo9_require_text '自定义分支' || return 2
  todo9_require_text 'SSH、SCP、`file://` 和本地路径' || return 2
  todo9_require_text '同一个不可变 commit OID' || return 2
  todo9_require_text '只重试尚未成功的 mirror' || return 2
  todo9_require_text '提交创建后不允许 rebase、amend 或 force push' || return 2
  todo9_require_text '父提交' || return 2
  todo9_require_text '每个 host 单独计算' || return 2
  todo9_require_text '完整集合' || return 2
  todo9_require_text '远端 CI 保留任务已经移除' || return 2
}

scenario_readme_no_private_key() {
  local output="$RUN_ROOT/todo9-source-policy.log"
  run_captured "$output" 10 bash "$PROJECT_ROOT/scripts/check-source-only.sh" || return 2
  todo9_reject_pattern 'age-keygen|age[[:space:]]+-d|age[[:space:]].*-i[[:space:]]|identity\.txt|私钥命令|私钥内容' || return 2
  todo9_require_text '私钥由用户离线保管' || return 2
  todo9_require_text 'Agent 不接触' || return 2
}

scenario_readme_private_backup_repo() {
  todo9_require_text '模板和指令仓库必须公开' || return 2
  todo9_require_text '实际备份仓库应设为私有' || return 2
  todo9_require_text 'manifest 会暴露' || return 2
  todo9_require_text '恢复必需的配置文件和 secret 应作为备份源加密收入归档' || return 2
  todo9_require_text '不要把明文 secret 写进 Git 仓库' || return 2
}

scenario_readme_public_curl_gate() {
  todo9_require_text "$TODO9_RAW_URL" || return 2
  todo9_require_text '匿名 `curl`' || return 2
  todo9_require_text '403' || return 2
  todo9_require_text '发布阻塞项' || return 2
  todo9_require_text '不能宣称检查已经通过' || return 2
}

scenario_prepared_state_diagnostic() {
  local before_state after_state output
  todo3_setup_fixture todo9-prepared-state-diagnostic || return 2
  todo3_run 0 || return 2
  before_state="$(sha256sum "$TODO3_STATE")" || return 2

  if todo3_run 0; then
    say_error 'existing prepared state unexpectedly accepted BACKUP_PUSH=0'
    return 2
  fi

  output="$TODO3_FIXTURE/run.log"
  after_state="$(sha256sum "$TODO3_STATE")" || return 2
  [[ "$after_state" == "$before_state" ]] || {
    say_error 'existing prepared state diagnostic path mutated prepared state'
    return 2
  }
  grep -Fq 'prepared backup already exists for testbox; publish it with BACKUP_HOST=testbox scripts/publish-prepared.sh' "$output" || {
    say_error 'existing prepared state diagnostic does not direct users to publish-prepared.sh'
    return 2
  }
  if grep -Fq 'publish it with BACKUP_PUSH=1' "$output"; then
    say_error 'existing prepared state diagnostic still recommends BACKUP_PUSH=1'
    return 2
  fi
}
