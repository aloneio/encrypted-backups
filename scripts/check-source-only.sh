#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW_GUIDE_URL='https://gitlab.com/aloneio/local-backup-push-kit/-/raw/main/docs/llm-setup-guide.zh.md'
bad=0

mark_bad() {
  printf 'ERROR: %s\n' "$*" >&2
  bad=1
}

quote_path() {
  printf '%q' "$1"
}

required_files=(
  .gitignore
  README.md
  docs/llm-setup-guide.zh.md
  hosts/example/backup.conf
  scripts/backup.sh
  scripts/check-source-only.sh
  scripts/compact-remote-history.sh
  scripts/configure-secrets.sh
  scripts/git-askpass.sh
  scripts/install-systemd-timer.sh
  scripts/migrate-legacy.sh
  scripts/publish-prepared.sh
  scripts/root-launcher.sh
  scripts/lib/common.sh
  scripts/lib/git-remotes.sh
  scripts/lib/install-common.sh
  scripts/lib/prepare.sh
  scripts/lib/publication-schema.sh
  scripts/lib/retention.sh
  tests/run.sh
  tests/lib/harness.sh
  tests/lib/todo3.sh
  tests/lib/todo4.sh
  tests/lib/todo4_verifier_regressions.sh
  tests/lib/todo5.sh
  tests/lib/todo5_adversarial.sh
  tests/lib/todo6.sh
  tests/lib/todo6_adversarial.sh
  tests/lib/todo7.sh
  tests/lib/todo7_adversarial.sh
  tests/lib/todo8.sh
  tests/lib/todo8_adversarial.sh
  tests/lib/todo9.sh
  tests/lib/todo10.sh
  tests/lib/todo11.sh
  tests/lib/todo12.sh
  tests/lib/f2_blockers.sh
)

for relative in "${required_files[@]}"; do
  if [[ ! -f "$REPO_DIR/$relative" ]]; then
    mark_bad "required source file missing: $relative"
  fi
done

for ci_file in .github/workflows/retention.yml; do
  if [[ -e "$REPO_DIR/$ci_file" || -L "$REPO_DIR/$ci_file" ]]; then
    mark_bad "obsolete mutating retention CI must be absent: $ci_file"
  fi
done

while IFS= read -r -d '' path; do
  rel="${path#"$REPO_DIR"/}"
  case "$rel" in
    .git/local-backup-push-kit|.git/local-backup-push-kit/*)
      mark_bad "prepared/publication state: $(quote_path "$rel")"
      continue
      ;;
    .git|.git/*) continue ;;
  esac

  if [[ -L "$path" ]]; then
    case "$rel" in
      backups|backups/*|manifests|manifests/*|output|output/*|*.tar|*.tar.zst|*.tar.zst.age|*.sha256|*.manifest.json|latest|latest.*)
        mark_bad "generated-data symlink: $(quote_path "$rel")"
        ;;
    esac
  fi

  case "$rel" in
    .omo|.omo/*|.pi-loop.json.lock|.pi-subagents|.pi-subagents/*)
      mark_bad "local development artifact: $(quote_path "$rel")"
      ;;
    backups|backups/*|manifests|manifests/*|output|output/*)
      mark_bad "generated backup data: $(quote_path "$rel")"
      ;;
    *.tar|*.tar.zst|*.tar.zst.age|*.zip|*.7z|*.sql|*.dump|*.bak|*.sha256|*.manifest.json|latest|latest.*)
      mark_bad "generated backup data: $(quote_path "$rel")"
      ;;
    *.key|*.pem|*.env|*.sqlite|*.db|*.log|age-identity*|*/age-identity*|id_*|*/id_*|*_rsa|*_ed25519)
      mark_bad "forbidden source-only file: $(quote_path "$rel")"
      ;;
  esac
done < <(find "$REPO_DIR" -mindepth 1 -print0)

if [[ ! -d "$REPO_DIR/hosts/example" ]]; then
  mark_bad 'required host template directory missing: hosts/example'
fi
while IFS= read -r -d '' path; do
  rel="${path#"$REPO_DIR"/}"
  case "$rel" in
    hosts/example|hosts/example/backup.conf) ;;
    *) mark_bad "unexpected host template path: $(quote_path "$rel")" ;;
  esac
done < <(find "$REPO_DIR/hosts" -mindepth 1 -print0 2>/dev/null)

for document in README.md docs/llm-setup-guide.zh.md; do
  if [[ -f "$REPO_DIR/$document" ]] && ! grep -Fq "$RAW_GUIDE_URL" "$REPO_DIR/$document"; then
    mark_bad "fixed raw guide URL missing or wrong in $document"
  fi
done

for ci_file in .github/workflows/remote-retention.yml .gitlab-ci.yml; do
  [[ -f "$REPO_DIR/$ci_file" && ! -L "$REPO_DIR/$ci_file" ]] || mark_bad "required remote compaction CI file missing or unsafe: $ci_file"
done
if [[ -f "$REPO_DIR/.github/workflows/remote-retention.yml" ]]; then
  grep -Fq 'scripts/compact-remote-history.sh' "$REPO_DIR/.github/workflows/remote-retention.yml" || \
    mark_bad 'GitHub remote compaction workflow must invoke the compaction script'
  grep -Fq 'contents: write' "$REPO_DIR/.github/workflows/remote-retention.yml" || \
    mark_bad 'GitHub remote compaction workflow must declare contents write permission'
  if grep -Fq 'BACKUP_ENABLE_GITHUB_COMPACTION' "$REPO_DIR/.github/workflows/remote-retention.yml"; then
    mark_bad 'GitHub scheduled compaction must not depend on an extra repository variable gate'
  fi
  grep -Fq 'cron:' "$REPO_DIR/.github/workflows/remote-retention.yml" || \
    mark_bad 'GitHub remote compaction workflow must have a cron schedule'
fi
if [[ -f "$REPO_DIR/.gitlab-ci.yml" ]]; then
  grep -Fq 'scripts/compact-remote-history.sh' "$REPO_DIR/.gitlab-ci.yml" || \
    mark_bad 'GitLab remote compaction pipeline must invoke the compaction script'
  grep -Fq 'CI_PIPELINE_SOURCE == "schedule"' "$REPO_DIR/.gitlab-ci.yml" || \
    mark_bad 'GitLab remote compaction pipeline must accept scheduled pipelines'
fi

if [[ -f "$REPO_DIR/scripts/backup.sh" ]]; then
  grep -Fq 'PUSH="${BACKUP_PUSH:-0}"' "$REPO_DIR/scripts/backup.sh" || \
    mark_bad 'scripts/backup.sh no longer defaults BACKUP_PUSH to disabled'
  grep -Fq 'if [[ "$PUSH" == "1" ]]' "$REPO_DIR/scripts/backup.sh" || \
    mark_bad 'scripts/backup.sh no longer gates commit/push behind BACKUP_PUSH=1'
  grep -Fq 'publish_prepared_state_machine' "$REPO_DIR/scripts/backup.sh" || \
    mark_bad 'backup publication should use the immutable publisher state machine'
  grep -Fq 'validate_compaction_snapshot_commit' "$REPO_DIR/scripts/lib/publication-schema.sh" || \
    mark_bad 'publication schema must validate CI compaction snapshots'
fi
if [[ -f "$REPO_DIR/scripts/compact-remote-history.sh" ]]; then
  [[ -x "$REPO_DIR/scripts/compact-remote-history.sh" ]] || \
    mark_bad 'scripts/compact-remote-history.sh must be executable'
  grep -Fq 'BACKUP_COMPACTION_CI' "$REPO_DIR/scripts/compact-remote-history.sh" || \
    mark_bad 'remote compaction script must require an explicit CI marker'
  grep -Fq -- '--force-with-lease' "$REPO_DIR/scripts/compact-remote-history.sh" || \
    mark_bad 'remote compaction script must use force-with-lease'
fi
if [[ -f "$REPO_DIR/hosts/example/backup.conf" ]]; then
  grep -Fq 'BACKUP_REMOTES' "$REPO_DIR/hosts/example/backup.conf" || \
    mark_bad 'hosts/example/backup.conf should document BACKUP_REMOTES'
fi
if [[ -f "$REPO_DIR/scripts/git-askpass.sh" ]]; then
  grep -Fq 'GIT_ASKPASS_TOKEN' "$REPO_DIR/scripts/git-askpass.sh" || \
    mark_bad 'scripts/git-askpass.sh should use generic token input'
fi

while IFS= read -r -d '' script; do
  [[ "$script" == "$REPO_DIR/scripts/check-source-only.sh" ]] && continue
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ git.*[[:space:]]add[[:space:]]+(-A|--all|\.)([[:space:]]|$) ]] ||
       [[ "$line" =~ git.*[[:space:]]add[[:space:]]+(--[[:space:]]+)?(backups|manifests|output)/?([[:space:]]|$) ]]; then
      mark_bad "broad staging command in ${script#"$REPO_DIR"/}"
    fi
  done <"$script"
done < <(find "$REPO_DIR/scripts" -type f -name '*.sh' -print0)

if ! command -v python3 >/dev/null 2>&1; then
  mark_bad 'python3 is required for finite lexical private-key policy validation'
else
  policy_output=''
  if ! policy_output="$(python3 - "$REPO_DIR" <<'PY'
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
import sys
import unicodedata

ELLIPSIS = "\ue000"
HARD_BOUNDARY = re.compile(r"[;.!?]")
CONTRAST = re.compile(r"\b(?:but|however|yet)\b|但是|然而|但|却")
TOPIC_PRIVATE = re.compile(r"私钥|\bprivate[\s-]+keys?\b")
TOPIC_AGE = re.compile(r"\bage\b")
TOPIC_KEY = re.compile(r"密钥|\bkeys?\b")
PREFIX_NEGATION = re.compile(
    r"不要|禁止|拒绝|不得|切勿|避免|不应|不可|不能|不允许|严禁|"
    r"\bnever\b|\bdo\s+not\b|\bdon't\b|\bmust\s+not\b|"
    r"\bshould\s+not\b|\bshall\s+not\b|\bcannot\b|\bcan't\b|"
    r"\bnot\s+yet\b|\breject(?:s|ed|ing)?\b|\bforbid(?:s|ding)?\b|"
    r"\bprohibit(?:s|ed|ing)?\b|\bavoid(?:s|ed|ing)?\b|"
    r"\bdisallow(?:s|ed|ing)?\b"
)
POSITIVE_RESET = re.compile(r"\bplease\b|\bthen\b|请|然后|再")
POSTFIX_DENIAL = re.compile(
    r"\b(?:is|are)\s+(?:forbidden|prohibited|not\s+allowed)\b|"
    r"是不允许的|被禁止"
)
ACTOR_CONTROL = re.compile(
    r"(?:由|交由)(?:用户|读者)|(?:用户|读者)(?:必须|应当|应该|需|自行|本人)|"
    r"\bby\s+(?:the\s+)?(?:users?|readers?)\b|"
    r"\b(?:users?|readers?)\s+(?:must|should)\b|"
    r"\byou\s+(?:must|should)\b|\byour\b"
)
APPROVED_CUSTODY = re.compile(
    r"离线|服务器自动化流程之外|仓库和服务器自动化流程之外|\boffline\b|"
    r"\boutside\s+(?:the\s+)?server\s+automation\b"
)
FORBIDDEN_DESTINATION = re.compile(
    r"服务器|仓库|\bagent\b|\bserver\b|\brepository\b|\brepo\b|"
    r"日志|\blogs?\b|\bstdout\b|终端"
)
OUTSIDE_PHRASE = re.compile(
    r"仓库和服务器自动化流程之外|服务器自动化流程之外|仓库外|"
    r"\boutside\s+(?:the\s+)?server\s+automation\b|"
    r"\boutside\s+(?:the\s+)?(?:repository|repo)\b"
)
POSTFIX_BRIDGE_RESET = re.compile(
    r",|\band\b|\bor\b|和|或|并且|以及|\bplease\b|\bthen\b|请|然后|再"
)


@dataclass(frozen=True)
class Action:
    kind: str
    start: int
    end: int


ACTION_PATTERNS = (
    (
        "generation",
        re.compile(
            r"\bage-keygen\b|生成|创建|产生|新建|"
            r"\bgenerat(?:e|es|ed|ing|ion)\b|"
            r"\bcreat(?:e|es|ed|ing|ion)\b"
        ),
    ),
    (
        "access",
        re.compile(
            r"读取|读出|查看|显示|索取|请求|"
            r"\bread(?:s|ing)?\b|\bview(?:s|ed|ing)?\b|"
            r"\bdisplay(?:s|ed|ing)?\b|\brequest(?:s|ed|ing)?\b|"
            r"\bask(?:s|ed|ing)?\s+for\b"
        ),
    ),
    (
        "output",
        re.compile(
            r"打印|输出|回显|\bprint(?:s|ed|ing)?\b|"
            r"\boutput(?:s|ted|ting)?\b|\becho(?:s|ed|ing)?\b"
        ),
    ),
    (
        "storage",
        re.compile(
            r"保存|存储|写入|落盘|保管|\bsav(?:e|es|ed|ing)\b|"
            r"\bstor(?:e|es|ed|ing)\b|\bwrite(?:s|ing)?\b|"
            r"\bwrote\b|\bwritten\b|\bpersist(?:s|ed|ing)?\b|"
            r"\bkeep(?:s|ing)?\b|\bkept\b"
        ),
    ),
)


def normalize(line: str) -> str:
    protected = line.replace("...", ELLIPSIS)
    return unicodedata.normalize("NFKC", protected).lower()


def hard_clauses(line: str) -> list[str]:
    return [part.strip() for part in HARD_BOUNDARY.split(line) if part.strip()]


def contrast_pieces(clause: str) -> list[str]:
    pieces: list[str] = []
    start = 0
    for match in CONTRAST.finditer(clause):
        token = match.group(0)
        if token == "yet" and re.search(r"\bnot\s*$", clause[: match.start()]):
            continue
        piece = clause[start : match.start()].strip(" ,")
        if piece:
            pieces.append(piece)
        start = match.end()
    tail = clause[start:].strip(" ,")
    if tail:
        pieces.append(tail)
    return pieces


def has_direct_topic(piece: str) -> bool:
    return bool(
        TOPIC_PRIVATE.search(piece)
        or re.search(r"\bage-keygen\b", piece)
        or (TOPIC_AGE.search(piece) and TOPIC_KEY.search(piece))
    )


def actions(piece: str) -> list[Action]:
    found = [
        Action(kind, match.start(), match.end())
        for kind, pattern in ACTION_PATTERNS
        for match in pattern.finditer(piece)
    ]
    return sorted(found, key=lambda action: (action.start, action.end, action.kind))


def postfix_denied_actions(piece: str, found_actions: list[Action]) -> set[Action]:
    denied: set[Action] = set()
    for denial in POSTFIX_DENIAL.finditer(piece):
        candidates = [action for action in found_actions if action.end <= denial.start()]
        if not candidates:
            continue
        action = max(candidates, key=lambda candidate: (candidate.end, candidate.start))
        bridge = piece[action.end : denial.start()]
        if POSTFIX_BRIDGE_RESET.search(bridge):
            continue
        denied.add(action)
    return denied


def action_has_prefix_negation(piece: str, action: Action) -> bool:
    preceding = [match for match in PREFIX_NEGATION.finditer(piece) if match.end() <= action.start]
    if not preceding:
        return False
    negator = preceding[-1]
    return not any(
        reset.start() >= negator.end() and reset.start() < action.start
        for reset in POSITIVE_RESET.finditer(piece)
    )


def storage_is_offline_user_custody(piece: str, action: Action) -> bool:
    left = piece.rfind(",", 0, action.start) + 1
    right = piece.find(",", action.end)
    if right < 0:
        right = len(piece)
    segment = piece[left:right]
    if not ACTOR_CONTROL.search(segment) or not APPROVED_CUSTODY.search(segment):
        return False
    destination_text = OUTSIDE_PHRASE.sub("", segment)
    return not FORBIDDEN_DESTINATION.search(destination_text)


def piece_is_unsafe(piece: str, topic: bool) -> bool:
    if not topic:
        return False
    found_actions = actions(piece)
    postfix_denied = postfix_denied_actions(piece, found_actions)
    for action in found_actions:
        if action in postfix_denied or action_has_prefix_negation(piece, action):
            continue
        if action.kind == "storage" and storage_is_offline_user_custody(piece, action):
            continue
        return True
    return False


def line_is_unsafe(line: str) -> bool:
    for clause in hard_clauses(normalize(line)):
        topic = False
        for piece in contrast_pieces(clause):
            topic = topic or has_direct_topic(piece)
            if piece_is_unsafe(piece, topic):
                return True
    return False


root = Path(sys.argv[1])
for relative in ("README.md", "docs/llm-setup-guide.zh.md"):
    path = root / relative
    if not path.is_file():
        continue
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if line_is_unsafe(line):
            print(f"positive private-key instruction in {relative}:{line_number}")
PY
)"; then
    mark_bad 'finite lexical private-key policy evaluator failed'
  elif [[ -n "$policy_output" ]]; then
    while IFS= read -r diagnostic; do
      [[ -n "$diagnostic" ]] && mark_bad "$diagnostic"
    done <<<"$policy_output"
  fi
fi

if [[ "$bad" -ne 0 ]]; then
  exit 1
fi

printf '%s\n' 'Structural/content source-only policy check passed.'
printf '%s\n' 'Finite lexical grammar only. This check does not prove arbitrary secret values are absent or semantic completeness.'
