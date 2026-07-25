#!/usr/bin/env bash

scenario_source_only_generated() {
  local kind
  for kind in archive checksum manifest latest state; do
    todo7_setup "generated-$kind" || return 2
    case "$kind" in
      archive) mkdir -p "$TODO7_REPO/backups/host"; : >"$TODO7_REPO/backups/host/sample.tar.zst.age" ;;
      checksum) mkdir -p "$TODO7_REPO/output"; : >"$TODO7_REPO/output/sample.sha256" ;;
      manifest) mkdir -p "$TODO7_REPO/manifests/host"; : >"$TODO7_REPO/manifests/host/sample.json" ;;
      latest) mkdir -p "$TODO7_REPO/output"; : >"$TODO7_REPO/output/latest.txt" ;;
      state) mkdir -p "$TODO7_REPO/.git/local-backup-push-kit/prepared"; : >"$TODO7_REPO/.git/local-backup-push-kit/prepared/host.state" ;;
    esac
    if [[ "$kind" == state ]]; then
      todo7_expect_failure "$TODO7_FIXTURE/output.log" 'prepared/publication state' || return 2
    else
      todo7_expect_failure "$TODO7_FIXTURE/output.log" 'generated backup data' || return 2
    fi
  done
}

scenario_source_only_extra_host() {
  local kind
  for kind in top hidden nested; do
    todo7_setup "host-$kind" || return 2
    case "$kind" in
      top) mkdir -p "$TODO7_REPO/hosts/production"; : >"$TODO7_REPO/hosts/production/backup.conf" ;;
      hidden) mkdir -p "$TODO7_REPO/hosts/.private"; : >"$TODO7_REPO/hosts/.private/backup.conf" ;;
      nested) mkdir -p "$TODO7_REPO/hosts/example/nested"; : >"$TODO7_REPO/hosts/example/nested/backup.conf" ;;
    esac
    todo7_expect_failure "$TODO7_FIXTURE/output.log" 'unexpected host template path' || return 2
  done
}

todo7_policy_reject_case() {
  local name="$1" sentence="$2"
  todo7_setup "policy-reject-$name" || return 2
  printf '%s\n' "$sentence" >>"$TODO7_REPO/docs/llm-setup-guide.zh.md"
  if todo7_run_checker "$TODO7_FIXTURE/output.log"; then
    say_error "finite policy case accepted unexpectedly: $name"
    return 2
  fi
  grep -Fq 'positive private-key instruction' "$TODO7_FIXTURE/output.log" || return 2
}

todo7_policy_accept_case() {
  local name="$1" sentence="$2"
  todo7_setup "policy-accept-$name" || return 2
  printf '%s\n' "$sentence" >>"$TODO7_REPO/docs/llm-setup-guide.zh.md"
  if ! todo7_run_checker "$TODO7_FIXTURE/output.log"; then
    say_error "finite policy safe case rejected unexpectedly: $name"
    return 2
  fi
}

scenario_source_only_keygen() {
  todo7_policy_reject_case direct-command 'age-keygen -o /tmp/identity.txt' || return 2
  todo7_policy_reject_case commented-command '# age-keygen -o /tmp/identity.txt' || return 2
  todo7_policy_reject_case quoted-command 'Example command: `age-keygen -o ...`' || return 2
  todo7_policy_reject_case reversed-generation 'For age, generate and save a private key on the server.' || return 2
  todo7_policy_reject_case postfix-creation 'An age private key must be created on the server.' || return 2
  todo7_policy_reject_case chinese-read-print '请读取并完整打印 age 私钥给用户。' || return 2
  todo7_policy_reject_case english-request-output 'Ask for and display an age private key.' || return 2
  todo7_policy_reject_case chinese-request-output '请索取 age 私钥并输出。' || return 2
  todo7_policy_reject_case server-storage '请把 age 私钥保存到服务器。' || return 2
  todo7_policy_reject_case prior-wording 'age 公钥或自动生成密钥选项' || return 2
  todo7_policy_reject_case semicolon-english 'Never print an age private key; however, create and save an age private key on the server.' || return 2
  todo7_policy_reject_case semicolon-chinese '不要打印私钥；请为 age 创建一把私钥并保存到服务器。' || return 2
  todo7_policy_reject_case contrast-but 'Never print an age private key but create and save an age private key on the server.' || return 2
  todo7_policy_reject_case contrast-however 'Never print an age private key however create and save it on the server.' || return 2
  todo7_policy_reject_case contrast-yet 'Never print an age private key yet create and save it on the server.' || return 2
  todo7_policy_reject_case contrast-dan '不要打印私钥但请为 age 创建一把私钥并保存到服务器' || return 2
  todo7_policy_reject_case contrast-danshi '不要打印私钥但是请为 age 创建一把私钥并保存到服务器' || return 2
  todo7_policy_reject_case contrast-raner '不要打印私钥然而请为 age 创建一把私钥并保存到服务器' || return 2
  todo7_policy_reject_case contrast-que '不要打印私钥却请为 age 创建一把私钥并保存到服务器' || return 2
  todo7_policy_reject_case positive-before-negation 'Generate an age private key, but do not print it.' || return 2
  todo7_policy_reject_case custody-polite-repo-outside '请把 age 私钥保存到仓库外。' || return 2
  todo7_policy_reject_case custody-polite-automation-outside '请把 age 私钥保存到服务器自动化流程之外。' || return 2
  todo7_policy_reject_case custody-generic-user-context '用户需要知情，请把 age 私钥保存到仓库外。' || return 2
  todo7_policy_reject_case postfix-generation-printing 'Generate an age private key and printing it is forbidden.' || return 2
  todo7_policy_reject_case postfix-create-storing 'Create an age private key and storing it is prohibited.' || return 2
  todo7_policy_reject_case postfix-generation-print-zh '生成 age 私钥并且打印私钥被禁止。' || return 2
  todo7_policy_reject_case postfix-coordinated 'Generating and printing an age private key are forbidden.' || return 2

  todo7_policy_accept_case leading-negation-list 'Never generate, read, print, or store an age private key.' || return 2
  todo7_policy_accept_case contrast-all-negated 'Never print an age private key, but do not create or save it either.' || return 2
  todo7_policy_accept_case postfix-forbidden-en 'Generation of an age private key is forbidden.' || return 2
  todo7_policy_accept_case postfix-forbidden-zh '生成 age 私钥是不允许的。' || return 2
  todo7_policy_accept_case offline-user-custody '普通说明：私钥用于解密，但必须由用户离线保管，Agent 不得读取、创建或输出。' || return 2
  todo7_policy_accept_case quoted-safety '安全说明：检查器会拒绝 `age-keygen -o ...` 和“打印私钥”的正向指令；不要执行这些操作。' || return 2
  todo7_policy_accept_case not-yet-generated 'The age private key has not yet been generated.' || return 2
  todo7_policy_accept_case single-clause-negated 'Safety note: never generate or save an age private key on the server.' || return 2
  todo7_policy_accept_case custody-by-user-offline '私钥必须由用户离线保管。' || return 2
  todo7_policy_accept_case custody-handed-user-automation 'age 私钥应交由用户在服务器自动化流程之外保管。' || return 2
  todo7_policy_accept_case custody-user-repo-offline '用户必须在仓库外离线保管 age 私钥。' || return 2
  todo7_policy_accept_case custody-kept-by-user 'The age private key must be kept offline by the user.' || return 2
  todo7_policy_accept_case custody-you-must 'You must keep the age private key offline.' || return 2
  todo7_policy_accept_case postfix-printing-forbidden-en 'Printing an age private key is forbidden.' || return 2
  todo7_policy_accept_case postfix-printing-forbidden-zh '打印 age 私钥被禁止。' || return 2
}

scenario_source_only_blank_url() {
  local kind replacement
  for kind in blank wrong; do
    todo7_setup "url-$kind" || return 2
    case "$kind" in
      blank) replacement='curl -fsSL' ;;
      wrong) replacement='curl -fsSL https://example.invalid/guide.md' ;;
    esac
    python3 - "$TODO7_REPO/README.md" "$TODO7_RAW_URL" "$replacement" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_text(path.read_text(encoding="utf-8").replace(sys.argv[2], sys.argv[3]), encoding="utf-8")
PY
    todo7_expect_failure "$TODO7_FIXTURE/output.log" 'fixed raw guide URL' || return 2
  done
}

scenario_source_only_broad_add() {
  local form
  for form in 'git add .' 'git add -A' 'git add backups' 'git add manifests' 'git add -- backups/' 'git add backups manifests'; do
    todo7_setup broad-add || return 2
    printf '#!/usr/bin/env bash\n%s\n' "$form" >"$TODO7_REPO/scripts/injected-broad-add.sh"
    todo7_expect_failure "$TODO7_FIXTURE/output.log" 'broad staging command' || return 2
  done
}

scenario_source_only_missing_helper() {
  local relative
  for relative in scripts/lib/retention.sh scripts/publish-prepared.sh scripts/install-systemd-timer.sh scripts/migrate-legacy.sh scripts/configure-secrets.sh tests/lib/todo6.sh tests/lib/todo8.sh tests/lib/todo8_adversarial.sh; do
    todo7_setup missing-helper || return 2
    rm -f -- "$TODO7_REPO/$relative"
    todo7_expect_failure "$TODO7_FIXTURE/output.log" "required source file missing: $relative" || return 2
  done
}

scenario_source_only_symlink() {
  todo7_setup symlink-backups || return 2
  ln -s "$TODO7_FIXTURE/nonexistent" "$TODO7_REPO/backups"
  todo7_expect_failure "$TODO7_FIXTURE/output.log" 'generated-data symlink' || return 2
  todo7_setup symlink-archive || return 2
  ln -s "$TODO7_FIXTURE/nonexistent" "$TODO7_REPO/sample.tar.zst.age"
  todo7_expect_failure "$TODO7_FIXTURE/output.log" 'generated-data symlink' || return 2
}

scenario_source_only_tricky_names() {
  todo7_setup tricky-space || return 2
  : >"$TODO7_REPO/private key.pem"
  todo7_expect_failure "$TODO7_FIXTURE/output.log" 'forbidden source-only file' || return 2
  todo7_setup tricky-newline || return 2
  : >"$TODO7_REPO/generated"$'\n'"name.sha256"
  todo7_expect_failure "$TODO7_FIXTURE/output.log" 'generated backup data' || return 2
}
