#!/usr/bin/env bash

TODO10_GUIDE="$PROJECT_ROOT/docs/llm-setup-guide.zh.md"
TODO10_RAW_URL='https://gitlab.com/aloneio/local-backup-push-kit/-/raw/main/docs/llm-setup-guide.zh.md'

todo10_require_text() {
  local text="$1"
  grep -Fq -- "$text" "$TODO10_GUIDE" || {
    say_error "Todo 10 guide text missing: $text"
    return 2
  }
}

todo10_reject_pattern() {
  local pattern="$1"
  if grep -Eq -- "$pattern" "$TODO10_GUIDE"; then
    say_error "Todo 10 forbidden guide pattern present: $pattern"
    return 2
  fi
}

todo10_require_order() {
  python3 - "$TODO10_GUIDE" "$@" <<'PY'
from pathlib import Path
import sys

path, *tokens = sys.argv[1:]
text = Path(path).read_text(encoding="utf-8")
position = -1
for token in tokens:
    next_position = text.find(token, position + 1)
    if next_position < 0:
        raise SystemExit(f"missing ordered Todo 10 token: {token}")
    if next_position <= position:
        raise SystemExit(f"out of order Todo 10 token: {token}")
    position = next_position
PY
}

todo10_require_section_order() {
  local heading="$1"
  shift
  python3 - "$TODO10_GUIDE" "$heading" "$@" <<'PY'
from pathlib import Path
import sys

path, heading, *tokens = sys.argv[1:]
text = Path(path).read_text(encoding="utf-8")
start = text.find(heading)
if start < 0:
    raise SystemExit(f"missing Todo 10 section: {heading}")
level = heading.split(" ", 1)[0]
end = text.find(f"\n{level} ", start + len(heading))
if end < 0:
    end = len(text)
section = text[start:end]
position = -1
for token in tokens:
    next_position = section.find(token, position + 1)
    if next_position < 0:
        raise SystemExit(f"missing token in {heading}: {token}")
    if next_position <= position:
        raise SystemExit(f"out of order token in {heading}: {token}")
    position = next_position
PY
}

scenario_llm_guide_contract() {
  local first_line
  first_line="$(python3 - "$TODO10_GUIDE" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()[0])
PY
)"
  [[ "$first_line" == "$TODO10_RAW_URL" ]] || {
    say_error 'Todo 10 guide does not begin with the fixed raw URL'
    return 2
  }
  for text in \
    '公开 Git 备份仓库' \
    '忘记代码托管账户密码' \
    'manifest 元数据' \
    'README 也是面向 Agent 的简明执行说明' \
    '固定 URL 匿名读取失败' \
    '文档获取问题' \
    '不得改用替代 URL' \
    'cat README.md' \
    'cat scripts/backup.sh' \
    'cat scripts/publish-prepared.sh' \
    'cat scripts/configure-secrets.sh' \
    'cat scripts/install-systemd-timer.sh' \
    'cat scripts/migrate-legacy.sh' \
    'cat scripts/compact-remote-history.sh' \
    'cat .github/workflows/remote-retention.yml' \
    'cat .gitlab-ci.yml' \
    'cat scripts/lib/common.sh' \
    'cat scripts/lib/git-remotes.sh' \
    'cat scripts/lib/prepare.sh' \
    'cat scripts/lib/retention.sh' \
    'git status --short' \
    'git diff --cached --name-status' \
    'scripts/configure-secrets.sh' \
    'BACKUP_HOST=<host> BACKUP_PUSH=0 scripts/backup.sh' \
    '准备完成时，暂存区只包含当前 host 的加密归档、checksum、manifest 和 `latest.txt`' \
    'retention 删除路径只记录在 prepared state 中，准备阶段不应用也不暂存这些删除' \
    'sha256sum -c backups/<host>/<artifact-id>.sha256' \
    '用户控制的仓库外部临时恢复目录' \
    'BACKUP_HOST=<host> scripts/publish-prepared.sh' \
    '`scripts/publish-prepared.sh` 在创建 commit 前立即以事务方式应用并暂存 state 记录的 retention 删除路径' \
    '同一个 commit OID' \
    '不允许 rebase、amend 或 force push' \
    'BACKUP_INSTALL_DRY_RUN=1' \
    'encrypted-git-backup-<host>.service' \
    'encrypted-git-backup-<host>.timer' \
    '/etc/encrypted-git-backup/<host>.env' \
    'BACKUP_HOST=<host> scripts/migrate-legacy.sh'; do
    todo10_require_text "$text" || return 2
  done
  todo10_reject_pattern "sed[[:space:]]+-n[[:space:]]+['\"]?1,260p" || return 2
  todo10_reject_pattern 'export[[:space:]]+(BACKUP_TOKEN_|GITHUB_TOKEN|GITLAB_TOKEN|BACKUP_GIT_TOKEN)' || return 2
  todo10_reject_pattern 'BACKUP_PUSH=1[[:space:]]+scripts/backup\.sh' || return 2
  todo10_reject_pattern '/etc/encrypted-git-backup\.env|encrypted-git-backup\.(service|timer)' || return 2
  todo10_reject_pattern 'github-main|gitlab-main' || return 2
  todo10_reject_pattern 'age-keygen|age[[:space:]]+-d|age[[:space:]].*-i[[:space:]]|identity\.txt' || return 2
  todo10_require_text 'remote-retention.yml' || return 2
  todo10_require_text 'compact-remote-history.sh' || return 2
  todo10_require_text 'git add -- README.md .gitignore .gitlab-ci.yml .github/workflows/remote-retention.yml' || return 2
  todo10_reject_pattern 'git[[:space:]]+(reset|clean)|git[[:space:]]+push[^\n]*--force|git[[:space:]]+rebase' || return 2
  todo10_reject_pattern '暂存区[^。\n]*retention 删除项' || return 2
  todo10_require_text '只接受用户提供的 `age1...` 公钥' || return 2
  todo10_require_text '公开 manifest 元数据' || return 2
  todo10_require_text '用户明确确认这些元数据可公开' || return 2
  todo10_require_text 'manifest 元数据也会公开' || return 2
  todo10_require_text 'HTTP(S)' || return 2
  todo10_require_text 'SSH、SCP、`file://` 和本地路径' || return 2
  todo10_require_text 'BACKUP_RETENTION_COUNT' || return 2
  todo10_require_text 'manifest 会暴露' || return 2
  todo10_require_text '恢复必需的配置与 secret' || return 2
  todo10_require_order \
    'BACKUP_HOST=<host> BACKUP_PUSH=0 scripts/backup.sh' \
    '准备完成时，暂存区只包含当前 host 的加密归档、checksum、manifest 和 `latest.txt`' \
    'retention 删除路径只记录在 prepared state 中，准备阶段不应用也不暂存这些删除' \
    '用户明确确认可以发布' \
    'BACKUP_HOST=<host> scripts/publish-prepared.sh' \
    '`scripts/publish-prepared.sh` 在创建 commit 前立即以事务方式应用并暂存 state 记录的 retention 删除路径'
}

scenario_llm_interview_sequence() {
  [[ "${LLM_FIXTURE:-}" == github-gitlab-weekly-nonroot ]] || {
    say_error 'Todo 10 happy selectors require LLM_FIXTURE=github-gitlab-weekly-nonroot'
    return 2
  }
  todo10_require_order \
    '请按下面顺序逐项提问' \
    '1. 仓库 URL' \
    '2. canonical 与有序 mirrors' \
    '3. 自定义备份分支' \
    '无人值守的多服务器共享仓库应为每个 host 使用独立分支' \
    '4. 用户提供的 age 公钥' \
    '5. 路径选择方式' \
    '6. 排除规则' \
    '7. 公开 metadata 确认' \
    '8. token 安全输入方式' \
    '9. 本地保留数量与远端容量边界' \
    '10. 每个实际远端仓库的压缩调度与权限' \
    '11. 多服务器计划' \
    '12. systemd 运行用户和组' \
    '13. systemd 计划' \
    '14. 迁移与遗留状态' \
    '检查服务器和当前仓库' \
    '向用户展示候选路径、排除项、公开 manifest 元数据和风险' \
    '等待用户明确确认路径清单及公开性' \
    '写入 `hosts/<host>/backup.conf`' \
    '创建初始模板与配置提交' \
    'BACKUP_HOST=<host> scripts/configure-secrets.sh' \
    'BACKUP_HOST=<host> BACKUP_PUSH=0 scripts/backup.sh' \
    '检查严格 prepared state' \
    'sha256sum -c backups/<host>/<artifact-id>.sha256' \
    '用户明确确认可以发布' \
    'BACKUP_HOST=<host> scripts/publish-prepared.sh' \
    '可选 systemd'
}

scenario_llm_remote_retention_and_multi_host() {
  for text in \
    '当前分支树中每个 host 可见的完整集合数' \
    'GitHub Actions/GitLab CI 定时压缩' \
    '每个 host 最近两个完整集合' \
    'force-with-lease 重写备份分支' \
    '每一个实际 Git remote 对应的托管仓库' \
    'cron 自动运行，不使用额外开关变量' \
    'gh run list --workflow remote-retention.yml' \
    '`.gitlab-ci.yml` **不会自动创建 Pipeline Schedule**' \
    '先查询以避免重复创建' \
    '每个实际 GitLab 备份项目创建 active schedule' \
    'canonical 在 GitHub、mirror 在 GitLab' \
    'GitHub Actions 和 GitLab Pipeline Schedule **都必须启用**' \
    '不得只清理 canonical' \
    '只有多个调度器试图写同一个物理 remote 时才禁止' \
    '一个公开仓库可以备份多个服务器' \
    '每个服务器必须使用唯一的 `BACKUP_HOST`/`CONFIG_HOST_ID`' \
    '无人值守的多服务器共享仓库必须为每个 host 使用独立 `BACKUP_BRANCH`' \
    '不同 host 分支可独立推进' \
    '不同服务器的本地 `flock` 不互通' \
    'canonical moved after preparation; reprepare required' \
    '一次只让一个 host 完成“准备到发布”流程'; do
    todo10_require_text "$text" || return 2
  done
}

scenario_llm_public_backup_narrative() {
  todo10_require_text '公开 Git 备份仓库' || return 2
  todo10_require_text '失去私有仓库访问权后，仍能匿名取得加密归档' || return 2
  todo10_require_text 'manifest 元数据也会公开' || return 2
  todo10_require_text '公开 metadata 未确认' || return 2
  todo10_reject_pattern '实际备份仓库必须保持私有|实际备份仓库应设为私有|实际备份仓库均为私有' || return 2
}

scenario_llm_final_summary() {
  [[ "${LLM_FIXTURE:-}" == github-gitlab-weekly-nonroot ]] || return 2
  for text in \
    '备份主机：<host>' \
    '备份仓库本地路径：<repo-path>' \
    '已确认备份路径：' \
    '已确认排除规则：' \
    'canonical：<remote-name> -> <url>' \
    '有序 mirrors：' \
    '备份分支：<branch>' \
    '本地保留数量：<count>' \
    'systemd 运行用户/组：<user>/<group>' \
    'systemd 计划：<schedule>' \
    'prepared base OID：<oid-or-empty-branch>' \
    '备份 commit OID：<oid-or-not-created>' \
    '远端 OID：' \
    '待重试 mirrors：<none-or-names>' \
    '远端压缩状态：' \
    '<remote-name>：<github-actions-or-gitlab-schedule-or-other> / <active-or-blocked> / <cron> / <last-run-status>' \
    'secret 状态：<configured-or-not-needed>' \
    'age 公钥状态：已配置用户提供的公钥，不显示值' \
    '解密材料状态：Agent 未接触'; do
    todo10_require_text "$text" || return 2
  done
  todo10_require_section_order '## 14. 最终汇总模板' \
    '已确认备份路径：' \
    '已确认排除规则：' \
    'canonical：' \
    '有序 mirrors：' \
    '备份分支：' \
    '本地保留数量：' \
    'systemd 运行用户/组：' \
    'systemd 计划：' \
    'prepared base OID：' \
    '备份 commit OID：' \
    '远端 OID：' \
    '待重试 mirrors：' \
    '远端压缩状态：'
}

scenario_llm_missing_public_key() {
  todo10_require_section_order '### 缺少用户提供的 age 公钥' \
    '停止' \
    '不写配置' \
    '不准备备份' \
    '不发布' \
    '可信离线流程'
}

scenario_llm_private_raw_url() {
  todo10_require_section_order '### 固定 URL 匿名读取失败' \
    '停止部署' \
    '文档获取问题' \
    '不得改用替代 URL' \
    '不得声称已读取当前 Agent 指南'
}

scenario_llm_root_paths() {
  todo10_require_section_order '### 路径不安全或需要 root' \
    '仓库本身' \
    '仓库子路径' \
    '仓库祖先' \
    '符号链接' \
    '停止' \
    '等待用户重新确认' \
    'BACKUP_RUN_USER=root'
}

scenario_llm_dirty_repo() {
  todo10_require_section_order '### 仓库不干净或历史异常' \
    'dirty' \
    '未发布 commit' \
    'canonical 分叉' \
    'mirror 分叉' \
    '停止' \
    '不得 reset' \
    '不得 force push'
}

scenario_llm_old_staged() {
  todo10_require_section_order '### 旧 staged 集合或已有 prepared state' \
    'scripts/migrate-legacy.sh' \
    '停止' \
    '--adopt-staged' \
    '已有 prepared state' \
    'scripts/publish-prepared.sh' \
    '不要再次准备'
}
