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
  todo9_require_text '每个 host 应使用独立分支，例如 backup/<host-id>' "$PROJECT_ROOT/hosts/example/backup.conf" || return 2
  todo9_require_text '远端 GitHub Actions/GitLab CI 压缩独立固定每个 host 最近两个完整集合' "$PROJECT_ROOT/hosts/example/backup.conf" || return 2
  todo9_require_text '每个实际 GitHub/GitLab remote 都必须各自启用并验证平台原生定时压缩' "$PROJECT_ROOT/hosts/example/backup.conf" || return 2
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
  todo9_reject_pattern '\.github/workflows/retention\.yml' || return 2
  todo9_require_text 'remote-retention.yml' || return 2
  todo9_require_text 'compact-remote-history.sh' || return 2
  todo9_require_text '.github/workflows/remote-retention.yml' || return 2
  todo9_require_text '.gitlab-ci.yml' || return 2
  todo9_require_text 'git add -- README.md .gitignore .gitlab-ci.yml .github/workflows/remote-retention.yml' || return 2
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
  todo9_require_text '远端压缩任务' || return 2
}

scenario_readme_remote_retention_and_multi_host() {
  for text in \
    '当前分支树中每个 host 可见的完整集合数' \
    'CI 定时压缩' \
    '最近两个完整集合' \
    '以 `force-with-lease` 替换该分支' \
    '每个实际远端仓库都必须有自己的平台原生定时压缩' \
    '不能只清理 canonical' \
    '默认分支' \
    'gh run list --workflow remote-retention.yml' \
    'Pipeline Schedule' \
    '先用 `glab api projects/<url-encoded-project>/pipeline_schedules` 查询' \
    '`.gitlab-ci.yml` 本身**不会创建定时任务**' \
    '每个实际远端仓库的平台/定时压缩状态/最近运行结果' \
    '一个公开仓库可以备份多个服务器' \
    '每个服务器必须使用唯一的 `BACKUP_HOST`/`CONFIG_HOST_ID`' \
    '不同服务器的本地 `flock` 不能跨服务器协调' \
    'canonical moved after preparation; reprepare required' \
    '一次只让一个**共享分支**上的 host 完成“准备到发布”流程'; do
    todo9_require_text "$text" || return 2
  done
}

scenario_readme_no_private_key() {
  local output="$RUN_ROOT/todo9-source-policy.log"
  run_captured "$output" 10 bash "$PROJECT_ROOT/scripts/check-source-only.sh" || return 2
  todo9_reject_pattern 'age-keygen|age[[:space:]]+-d|age[[:space:]].*-i[[:space:]]|identity\.txt|私钥命令|私钥内容' || return 2
  todo9_require_text '对应解密材料由用户离线保管' || return 2
  todo9_require_text 'Agent 不接触' || return 2
}

scenario_readme_private_backup_repo() {
  todo9_require_text '公开 Git 备份仓库' || return 2
  todo9_require_text '匿名取得公开仓库中的加密备份' || return 2
  todo9_require_text '本文是给部署 Agent 看的执行说明' || return 2
  todo9_require_text '固定的详细指令' || return 2
  todo9_require_text '公开 Git 备份仓库不含任何解密材料、token 或恢复明文' || return 2
  todo9_require_text '用户确认公开' || return 2
  todo9_reject_pattern '实际备份仓库应设为私有|实际备份仓库必须保持私有|实际备份仓库均为私有'
}

scenario_readme_public_curl_gate() {
  todo9_require_text "$TODO9_RAW_URL" || return 2
  todo9_require_text '固定指南 URL' || return 2
  todo9_require_text '可匿名读取' || return 2
  todo9_require_text '不得改用替代 URL' || return 2
  todo9_require_text '不能根据截断片段或旧文档猜测行为' || return 2
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
