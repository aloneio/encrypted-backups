#!/usr/bin/env bash

TODO7_RAW_URL='https://gitlab.com/aloneio/local-backup-push-kit/-/raw/main/docs/llm-setup-guide.zh.md'

todo7_setup() {
  local name="$1"
  new_fixture "todo7-$name" || return 2
  TODO7_FIXTURE="$FIXTURE"
  TODO7_REPO="$TODO7_FIXTURE/repo"
  copy_template "$TODO7_REPO"
}

todo7_run_checker() {
  local output="$1"
  run_captured "$output" 10 bash "$TODO7_REPO/scripts/check-source-only.sh"
}

todo7_expect_failure() {
  local output="$1" diagnostic="$2"
  if todo7_run_checker "$output"; then return 2; fi
  grep -Fq "$diagnostic" "$output" || return 2
}

scenario_todo7_baseline() {
  [[ -x "$PROJECT_ROOT/scripts/check-source-only.sh" ]] || return 2
  bash "$PROJECT_ROOT/scripts/check-source-only.sh" >/dev/null || return 2
  grep -Fq "$TODO7_RAW_URL" "$PROJECT_ROOT/README.md" || return 2
  grep -Fq "$TODO7_RAW_URL" "$PROJECT_ROOT/docs/llm-setup-guide.zh.md" || return 2
  [[ -f "$PROJECT_ROOT/scripts/lib/retention.sh" && -x "$PROJECT_ROOT/scripts/publish-prepared.sh" ]] || return 2
}

scenario_source_only() {
  local output="$RUN_ROOT/todo7-source-only.log"
  run_captured "$output" 10 bash "$PROJECT_ROOT/scripts/check-source-only.sh" || return 2
  grep -Fq 'Structural/content source-only policy check passed.' "$output" || return 2
  grep -Fq 'Finite lexical grammar only.' "$output" || return 2
  grep -Fq 'does not prove arbitrary secret values are absent' "$output" || return 2
}

scenario_ci_absence() {
  [[ ! -e "$PROJECT_ROOT/.github/workflows/retention.yml" ]] || return 2
  [[ -f "$PROJECT_ROOT/.github/workflows/remote-retention.yml" && ! -L "$PROJECT_ROOT/.github/workflows/remote-retention.yml" ]] || return 2
  [[ -f "$PROJECT_ROOT/.gitlab-ci.yml" && ! -L "$PROJECT_ROOT/.gitlab-ci.yml" ]] || return 2
  grep -Fq 'scripts/compact-remote-history.sh' "$PROJECT_ROOT/.github/workflows/remote-retention.yml" || return 2
  grep -Fq 'contents: write' "$PROJECT_ROOT/.github/workflows/remote-retention.yml" || return 2
  grep -Fq 'cron:' "$PROJECT_ROOT/.github/workflows/remote-retention.yml" || return 2
  ! grep -Fq 'BACKUP_ENABLE_GITHUB_COMPACTION' "$PROJECT_ROOT/.github/workflows/remote-retention.yml" || return 2
  grep -Fq 'scripts/compact-remote-history.sh' "$PROJECT_ROOT/.gitlab-ci.yml" || return 2
  grep -Fq 'CI_PIPELINE_SOURCE == "schedule"' "$PROJECT_ROOT/.gitlab-ci.yml" || return 2
}

scenario_docs_key_policy() {
  local output="$RUN_ROOT/todo7-docs-policy.log"
  run_captured "$output" 10 bash "$PROJECT_ROOT/scripts/check-source-only.sh" || return 2
  if grep -Eq 'age-keygen[[:space:]]+-o|Agent 在服务器上自动生成|age 公钥或自动生成密钥选项|公钥和私钥完整打印|完整内容打印给用户|生成的 age 公钥和私钥' \
    "$PROJECT_ROOT/README.md" "$PROJECT_ROOT/docs/llm-setup-guide.zh.md"; then return 2; fi
}
