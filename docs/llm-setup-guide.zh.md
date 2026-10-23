https://gitlab.com/aloneio/local-backup-push-kit/-/raw/main/docs/llm-setup-guide.zh.md

# Agent 服务器部署与公开备份执行指南

你是部署 Agent。用户把本固定 URL 交给你，表示希望你在其服务器上配置并执行 Local Backup Push Kit。本文是**给 Agent 的操作规程**，不是给用户的概念介绍：你要在用户确认的边界内做检查、访谈、配置、准备、验证、发布和汇总。

## 0. 目标、公开性与不可违反的边界

目标是在拥有备份源数据的服务器上，将用户确认的路径打包，用用户提供的 age 公钥加密，并发布到**公开 Git 备份仓库**。

公开备份仓库是产品要求，不是错误：用户忘记代码托管账户密码、失去私有仓库访问权后，仍能匿名取得加密归档；持有离线解密材料的用户仍可恢复。公开仓库不含任何解密材料、token 或恢复明文，但 manifest 会暴露元数据。开始前必须让用户确认公开以下内容可以接受：host 标识、源路径、归档名、时间、SHA256、Git 提交和 remote URL。

必须遵守：

- 只接受用户提供的 `age1...` 公钥。不得代用户生成密钥，不得索取、读取、显示或保存任何解密材料。
- 对应解密材料由用户在仓库和服务器自动化流程之外离线保管，Agent 不接触。
- token 不得出现在仓库、命令参数、shell 历史、环境变量字面导出、日志或最终汇总中。
- 恢复必需的配置与 secret 可以作为备份源收入加密归档，但不得以明文写进 Git 仓库；其路径会进入公开 manifest。
- 第一次流程必须先准备、检查、等待确认，再发布同一份 prepared 数据。
- 所有异常默认停止并报告。不得自动 reset、清理历史、删除旧归档、改写 commit、解决分叉或强制推送。
- 不访问真实远端、不使用真实凭据，除非用户正在实际部署且明确要求执行对应联网步骤。本地检查阶段只读取服务器和当前仓库。

## 1. 先完整读取当前版本

确认本文第一行正是固定 raw URL。此 URL 必须可被匿名 `curl` 读取；如果失败，报告文档获取问题并停止，不得改用替代 URL 冒充通过。

进入备份仓库根目录后，用 `cat` 完整读取当前文件。不能只读取前几百行，不能根据旧文档猜测脚本行为：

```bash
cat README.md
cat docs/llm-setup-guide.zh.md
cat hosts/example/backup.conf
cat scripts/backup.sh
cat scripts/publish-prepared.sh
cat scripts/configure-secrets.sh
cat scripts/install-systemd-timer.sh
cat scripts/migrate-legacy.sh
cat scripts/check-source-only.sh
cat scripts/compact-remote-history.sh
cat scripts/root-launcher.sh
cat scripts/git-askpass.sh
cat scripts/lib/common.sh
cat scripts/lib/git-remotes.sh
cat scripts/lib/install-common.sh
cat scripts/lib/publication-schema.sh
cat scripts/lib/prepare.sh
cat scripts/lib/retention.sh
cat .github/workflows/remote-retention.yml
cat .gitlab-ci.yml
```

README 也是面向 Agent 的简明执行说明；本文是更完整的顺序、决策树和汇总约定。若 README、本文和脚本存在差异，以当前脚本行为为准，并停止向用户澄清。

## 2. 有序访谈：未完成前不写配置

请按下面顺序逐项提问。可以先根据服务器做建议，但每项最终决定都必须由用户确认。

1. 仓库 URL
   - 收集每个**公开**备份仓库的 URL。
   - 说明仓库公开的目的：账户访问丢失时仍可下载密文；说明 manifest 元数据也会公开。
   - 不把 token 嵌入 URL。

2. canonical 与有序 mirrors
   - 让用户指定唯一 canonical。
   - 让用户按发布顺序列出 mirrors。
   - 明确 `BACKUP_REMOTES[0]` 是 canonical，后续项才是 mirrors。

3. 自定义备份分支
   - 询问目标 `BACKUP_BRANCH`，不能擅自假定为 `main`。
   - 单服务器可使用 `main`；无人值守的多服务器共享仓库应为每个 host 使用独立分支，例如 `backup/<host>`。
   - 当前检出的本地分支必须与它相同。

4. 用户提供的 age 公钥
   - 只接收用户提供的 `age1...` 公钥接收方。
   - 如果用户尚未准备好，转到“缺少用户提供的 age 公钥”停止分支。

5. 路径选择方式
   - 让用户选择“Agent 检查服务器后建议”或“用户直接指定”。
   - 无论哪种方式，都要先检查真实路径，再展示最终候选清单。

6. 排除规则
   - 逐项确认 `TAR_EXCLUDES`。
   - 提醒用户不要排除恢复服务必需的配置、证书、环境文件、一致性数据库导出或其他关键数据。

7. 公开 metadata 确认
   - 回显候选 host 标识、收入路径、归档命名和可能出现在 manifest 的内容。
   - 等待用户明确确认这些元数据可公开；未确认则不写配置。

8. token 安全输入方式
   - HTTP(S) remote 只能通过 `scripts/configure-secrets.sh` 无回显输入。
   - SSH、SCP、`file://` 和本地路径使用 Git 原生认证，不需要 token helper。
   - 不接受用户把 token 发到聊天中，也不提供字面 token 命令。

9. 本地保留数量与远端容量边界
   - 询问每个 host 的 `BACKUP_RETENTION_COUNT`，必须是正整数。
   - 默认语义是本机每个 host 在当前分支树保留最近 3 个完整集合。
   - 告知用户：远端 CI 压缩会独立固定保留每 host 最近两个完整集合并 force-with-lease 重写备份分支；这是缩减 refs 与可达历史的必要破坏性操作。

10. 每个实际远端仓库的压缩调度与权限
    - 对 canonical 与每个 mirror 分别识别 GitHub、GitLab 或其他托管平台；不是为整组远端只选择一个平台。
    - 每个 GitHub 备份仓库都必须确认默认分支包含 `remote-retention.yml`、Actions cron 已启用、`contents: write` 可用，并查询最近一次 workflow run。
    - 每个 GitLab 备份仓库都必须创建 active Pipeline Schedule；`.gitlab-ci.yml` 本身不会创建定时任务。还要确认 CI job token 可写以及备份分支允许 force-with-lease 更新。
    - canonical 与 mirrors 跨 GitHub/GitLab 时，两端各自启用平台原生定时压缩；只有两个调度器写同一个物理 remote 才是错误竞争配置。
    - 说明平台垃圾回收是异步的；压缩后不承诺旧密文立刻从缓存、fork、clone 或外部副本消失。

11. 多服务器计划
    - 确认每台服务器有唯一的 host 标识和独立 `hosts/<host>/backup.conf`。
    - 说明可共用一个公开仓库与 mirrors，数据会按 host 分区。
    - 无人值守时必须为每个 host 配置独立 `BACKUP_BRANCH`，例如 `backup/<host>`；不同 host 分支可独立推进。
    - 只有用户提供跨服务器外部协调锁时，才允许多个 host 共用同一 canonical 分支；否则询问错开的 `BACKUP_ON_CALENDAR` 或外部协调方案。不同服务器的本地锁不互通。

12. systemd 运行用户和组
    - 询问 `BACKUP_RUN_USER` 与 `BACKUP_RUN_GROUP`。
    - 明确问用户受限路径是否真的要求 root。
    - 默认使用非 root。只有用户确认权限需求后才能显式选择 `BACKUP_RUN_USER=root`。

13. systemd 计划
    - 询问 `BACKUP_ON_CALENDAR`，例如 `daily` 或 `weekly`；多服务器共享仓库时应错开计划。
    - 先记录选择，不立即安装。

14. 迁移与遗留状态
    - 询问这是否是新仓库，是否曾运行旧版脚本。
    - 询问是否可能存在旧 staged 集合、已有 prepared state、未发布 commit、旧 timer、过时 `.github/workflows/retention.yml` 文件或已分叉 mirrors。

访谈未完成时不要写配置，不要收集 token，不要准备备份，也不要安装 systemd。

## 3. 检查服务器和当前仓库

先做只读检查：

```bash
hostname -s
pwd
git status --short
git diff --cached --name-status
git branch --show-current
git remote -v
git log -1 --oneline 2>/dev/null || true
command -v age
command -v git
command -v tar
command -v zstd
command -v sha256sum
command -v realpath
command -v flock
command -v python3
```

检查 remote 时记录名称、fetch URL、push URL 和传输类型。每个 remote 必须只有一个 fetch URL 和一个 push URL，且两者传输类型一致。不要打印凭据。

若用户选择 Agent 建议路径，检查服务定义、compose 文件、systemd unit、应用配置、小型持久化数据、一致性数据库导出和恢复说明。只做有界、只读检查，不读取 secret 内容。可以检查路径名、文件类型、权限和大小，用这些信息提出候选项。

若用户直接指定路径，也要逐项验证。每项必须存在、是绝对路径、不是重复路径，不能是备份仓库本身、仓库子路径、仓库祖先，也不能包含符号链接组件。根目录 `/` 也是仓库祖先风险，必须拒绝。

向用户展示候选路径、排除项、公开 manifest 元数据和风险。等待用户明确确认路径清单及公开性；得到确认之前，不得写入 `hosts/<host>/backup.conf`。

## 4. 迁移预检

如果仓库不是全新部署，或者用户不能确认遗留状态，先运行只报告模式：

```bash
BACKUP_HOST=<host> scripts/migrate-legacy.sh
```

该命令可能用状态 3 表示需要人工处理。不要把它当成可以忽略的普通失败。报告模式用于检查旧 staged 集合、旧命名集合、未发布或分叉历史、mirror OID、旧共享 timer 和过时 `.github/workflows/retention.yml` 文件。它不应自动修改这些状态。

只有报告确认旧 staged 集合完整、哈希有效、manifest 与 `latest.txt` 一致，而且远端和 timer 没有阻塞项时，才向用户解释并请求单独确认：

```bash
BACKUP_HOST=<host> scripts/migrate-legacy.sh --adopt-staged
```

不得自动采用旧集合。

## 5. 写入配置前的确认记录

向用户回显以下非敏感选择，等待明确确认：

- host 标识；
- 备份仓库本地路径；
- 公开 remote 名称、URL、canonical 与有序 mirrors；
- 自定义分支；
- age 公钥已收到且格式为 `age1...`，不回显完整值；
- 精确备份路径和精确排除规则；
- 将公开的 manifest 元数据和用户明确确认结果；
- 本地保留数量；
- 每个实际远端仓库的平台、压缩定时任务、写权限与最近一次运行状态；
- systemd 用户、组和计划；
- 是否确实需要 root；
- 迁移报告状态。

确认后才创建 host 配置：

```bash
mkdir -p hosts/<host>
cp hosts/example/backup.conf hosts/<host>/backup.conf
```

写入 `hosts/<host>/backup.conf`，至少设置：

```bash
CONFIG_HOST_ID="<host>"
AGE_RECIPIENT="<user-supplied-age1-public-recipient>"
BACKUP_BRANCH="<branch>"
BACKUP_REMOTES=(
  "<canonical-remote>"
  "<ordered-mirror-remote>"
)
BACKUP_PATHS=(
  "<confirmed-absolute-path>"
)
BACKUP_RETENTION_COUNT="<positive-integer>"
BACKUP_LOCK_TIMEOUT="30"
BACKUP_RUN_USER="<service-user>"
BACKUP_RUN_GROUP="<service-group>"
BACKUP_ON_CALENDAR="<schedule>"
TAR_EXCLUDES=(
  "<confirmed-exclusion>"
)
```

不要在配置中写 token、明文恢复数据或任何解密材料。

## 6. 创建初始模板与配置提交

第一次准备前，仓库必须已经有模板与 host 配置的初始提交，而且工作区和暂存区必须干净。先检查差异，再精确暂存模板与配置文件：

```bash
git status --short
git add -- README.md .gitignore .gitlab-ci.yml .github/workflows/remote-retention.yml docs/llm-setup-guide.zh.md hosts/<host>/backup.conf scripts/*.sh scripts/lib/*.sh tests/*.sh tests/lib/*.sh
git diff --cached --name-status
git commit -m "Initialize backup template and host config"
git status --short
```

最后一条命令必须没有输出。不要把仓库外的备份源复制进仓库。

canonical 的目标分支为空时，可以从这个本地初始模板提交引导。canonical 已有该分支时，本地只能安全快进到它。若本地超前、存在未发布 commit、双方分叉或历史过旧，停止并报告 OID。不得在这种状态下准备备份。

## 7. 配置远端与安全凭据

按用户确认的名称添加或校正 remote。remote 名不能硬编码成平台名称：

```bash
git remote add <canonical-remote> <public-backup-repository-url>
git remote add <mirror-remote> <public-mirror-repository-url>
git remote -v
```

已经存在的 remote 要检查 URL，不要重复添加。HTTP(S) URL 不能包含用户名或 token。SSH、SCP、`file://` 和本地路径不读取 token。

只要存在 HTTP(S) remote，就运行：

```bash
BACKUP_HOST=<host> scripts/configure-secrets.sh
```

让用户直接在受控终端的无回显提示中输入。该 helper 按 remote 收集值，并写入 host 专用的 `/etc/encrypted-git-backup/<host>.env`。不得打印值，不得把值放进 argv，不得导出字面 token，不得写旧共享环境文件。

如果全部 remote 都是 SSH、SCP、`file://` 或本地路径，记录 `secret 状态` 为不需要，不运行 token helper。

## 8. 远端 CI 强制压缩、Git 历史与多服务器共享仓库

本地 `BACKUP_RETENTION_COUNT` 只控制日常发布后当前分支树中每个 host 可见的完整集合数。为防止公开 remote 的 refs 和可达历史对象不断累积，仓库提供 GitHub Actions/GitLab CI 定时压缩：

- GitHub Actions：`.github/workflows/remote-retention.yml`；
- GitLab CI：`.gitlab-ci.yml`；
- 共用压缩器：`scripts/compact-remote-history.sh`。

这些 GitHub Actions/GitLab CI 定时压缩任务每日调度、可手动触发，并对每个备份分支建立无父提交的快照：验证 archive、checksum、manifest 与 `latest.txt` 后，固定保留**每个 host 最近两个完整集合**，以 `force-with-lease` 替换分支。压缩器遇到不完整集合、异常生成路径或 checksum/manifest/latest 不匹配时必须停止，不改写分支。

启用与验证必须按**每一个实际 Git remote 对应的托管仓库**分别完成：

- GitHub：默认分支包含 `.github/workflows/remote-retention.yml` 后，cron 自动运行，不使用额外开关变量。Agent 必须确认仓库 Actions 已启用、workflow 有 `contents: write`、目标备份分支允许 GitHub Actions 用 `force-with-lease` 更新，并运行 `gh workflow view remote-retention.yml --repo <owner>/<repo>` 与 `gh run list --workflow remote-retention.yml --repo <owner>/<repo> --limit 1` 核对 workflow 和最近一次运行。仅有 workflow 文件但 Actions 被禁用或无写权限不算完成。
- GitLab：`.gitlab-ci.yml` **不会自动创建 Pipeline Schedule**。Agent 必须在每个实际 GitLab 备份项目创建 active schedule。先查询以避免重复创建：

```bash
glab api projects/<url-encoded-project>/pipeline_schedules
```

仅在不存在相同 ref/cron 的 active schedule 时创建：

```bash
glab api --method POST projects/<url-encoded-project>/pipeline_schedules \
  -f description='Compact public backup history' \
  -f ref='<default-branch>' \
  -f cron='23 3 * * *' \
  -f cron_timezone='UTC' \
  -F active=true
glab api projects/<url-encoded-project>/pipeline_schedules
```

  schedule 指向包含 `.gitlab-ci.yml` 的默认分支即可；job 使用 `BACKUP_COMPACTION_ALL_BRANCHES=1` 清理该项目的所有备份分支。还必须确认 CI job token 可写入项目，并允许 `force-with-lease` 更新目标备份分支。
- 如果 canonical 在 GitHub、mirror 在 GitLab，GitHub Actions 和 GitLab Pipeline Schedule **都必须启用**，分别清理各自的物理仓库。每个 GitHub/GitLab mirror 也一样；不得只清理 canonical。只有多个调度器试图写同一个物理 remote 时才禁止，因为它们会竞争 lease。

Agent 必须为每个 remote 记录：remote 名称、脱敏 URL、平台、定时任务是否 active、cron、写权限验证、最近一次运行状态。平台随后会按自身策略异步回收失去引用的对象；不要保证旧密文立即从平台缓存、fork、clone 或已经下载的副本消失。

压缩后，干净的服务器工作副本会验证并接受受信任的 CI 快照，再准备新备份；但已有 prepared state 时必须停止并重新准备，不能发布基于旧历史的 state。压缩器本身只能在 CI 显式设置 `BACKUP_COMPACTION_CI=1` 后运行，服务器备份任务不得直接调用。

一个公开仓库可以备份多个服务器：每个服务器必须使用唯一的 `BACKUP_HOST`/`CONFIG_HOST_ID`、独立 `hosts/<host>/backup.conf`、同一公开 canonical/mirrors。文件按 `backups/<host>/` 与 `manifests/<host>/` 分区；本地保留和远端压缩都只处理当前 host 的完整集合；prepared state、systemd service、timer 与 env 文件也按 host 独立。

无人值守的多服务器共享仓库必须为每个 host 使用独立 `BACKUP_BRANCH`，例如 `backup/<host>`。不同 host 分支可独立推进与压缩，因此一个 host 发布或压缩不会使另一个 host 的 prepared base 失效。只有用户提供跨服务器外部协调锁时，才允许多个 host 共用同一 canonical 分支。

不同服务器的本地 `flock` 不互通。若两台服务器从同一个 canonical base 同时准备，先发布的会推进 canonical，后发布的必须安全停止并报告 `canonical moved after preparation; reprepare required`。不得自动合并或强推。共享分支时，要求用户为各 host 设置错开的 `BACKUP_ON_CALENDAR`/jitter，或使用外部协调器；一次只让一个 host 完成“准备到发布”流程。

## 9. 第一次准备

再次确认 `git status --short` 没有输出，然后只准备：

```bash
BACKUP_HOST=<host> BACKUP_PUSH=0 scripts/backup.sh
```

不要在首次确认前推荐任何一步准备加发布的兼容快捷方式。准备成功后，不要再次运行准备命令。

## 10. 检查严格 prepared state 与产物

从 `latest.txt` 和 prepared state 取得当前 artifact 标识与精确路径。完整检查：

```bash
git diff --cached --name-status
cat backups/<host>/latest.txt
cat backups/<host>/<artifact-id>.sha256
cat manifests/<host>/<artifact-id>.json
cat .git/local-backup-push-kit/prepared/<host>.state
sha256sum -c backups/<host>/<artifact-id>.sha256
```

必须确认：

- 准备完成时，暂存区只包含当前 host 的加密归档、checksum、manifest 和 `latest.txt`。
- retention 删除路径只记录在 prepared state 中，准备阶段不应用也不暂存这些删除。
- prepared state 的 host、branch、有序 remotes、base OID、artifact ID、精确路径与 SHA256 都与文件一致。
- 加密归档、checksum、manifest 和 `latest.txt` 都存在，且都是安全的普通文件。
- checksum 验证成功。
- manifest 的收入路径与用户确认清单一致，且其公开性已经得到确认。
- 本地保留策略按 host 单独计算，只保留 `BACKUP_RETENTION_COUNT` 个完整集合。完整集合由加密归档、checksum 和 manifest 组成。孤立文件应报告并保留。

加密内容验证只能在用户控制的仓库外部临时恢复目录完成。由用户控制的外部恢复处理验证归档可解密、可只读列出并包含预期恢复文件。Agent 不接触用户离线保管的解密材料，也不在源仓库中生成恢复明文。验证结束后，由用户清理外部临时恢复目录中的明文。

如果任一检查失败，停止，不发布。先记录失败点，再由用户决定如何人工清理无效 prepared 状态和对应暂存产物。不得自动删除或重置。

## 11. 明确确认后发布

向用户展示以下检查结果，不含 secret：

- artifact 精确路径和 SHA256 结果；
- 公开 manifest 收入路径与 metadata 确认状态；
- prepared base OID；
- canonical、mirrors 与 branch；
- 用户控制的外部恢复处理结果；
- 本地 retention 删除清单；
- 当前分支树的每 host 本地保留数、CI 远端压缩的固定两个完整集合，以及 Git 托管端异步回收边界；
- 每个实际远端仓库的托管平台、定时压缩 active 状态、cron、写权限和最近一次压缩结果；
- 多服务器计划（host 标识与错开/协调状态）。

只有用户明确确认可以发布，才运行：

```bash
BACKUP_HOST=<host> scripts/publish-prepared.sh
```

`scripts/publish-prepared.sh` 在创建 commit 前立即以事务方式应用并暂存 state 记录的 retention 删除路径。若 commit 前失败，发布事务会恢复这些删除；准备阶段检查暂存区时不应看到这些删除路径。

retention 回滚数据必须先持久化到 `.git/local-backup-push-kit/recovery/retention/<host>/`。重新运行时只能在 HEAD 等于 journal base 时恢复，或在 HEAD 是该 base 的直接发布子提交时完成清理；HEAD 不可读或关系不明确时停止并保留 journal，等待人工审核。

发布器会为已检查的 prepared set 创建一个 commit，并按 canonical、mirrors 的顺序推送同一个 commit OID。commit 创建后不允许 rebase、amend 或 force push，也不能为不同 mirror 生成不同历史。

若部分 mirror 失败，记录 commit OID、每个远端 OID 和待处理 mirrors。再次运行同一条 `scripts/publish-prepared.sh` 命令，只重试同一个 commit OID。不要重新准备归档，不要改写 canonical，不要强制更新 mirror。

## 12. 可选 systemd

只有用户在访谈中选择自动运行后才继续。先渲染，不写系统目录：

```bash
BACKUP_HOST=<host> BACKUP_INSTALL_DRY_RUN=1 scripts/install-systemd-timer.sh
```

让用户核对 `User=`、`Group=`、`OnCalendar=`、工作目录、host 和 env 路径。每个 host 使用独立的 `encrypted-git-backup-<host>.service`、`encrypted-git-backup-<host>.timer` 和 `/etc/encrypted-git-backup/<host>.env`。

默认选择非 root 用户。只有目标路径权限确实要求 root，而且用户明确同意风险时，才保留显式 `BACKUP_RUN_USER=root`。不确定时停止，先调整文件权限或选择专用备份用户。

确认 dry-run 后再安装：

```bash
BACKUP_HOST=<host> scripts/install-systemd-timer.sh
```

如果检测到旧共享 timer，停止。审核旧 unit、运行用户、计划和 env 后，只有用户明确确认迁移时才运行：

```bash
BACKUP_HOST=<host> scripts/install-systemd-timer.sh --migrate-legacy
```

若选择 `BACKUP_RUN_USER=root`，确认 service 的 `ExecStart` 指向 `${BACKUP_ROOT_LAUNCHER_DIR:-/usr/local/libexec/local-backup-push-kit}/backup-launcher`，不能直接指向仓库中的 `scripts/backup.sh`。launcher、service 与 timer 必须作为同一安装事务回滚。

## 13. 失败与迁移决策树

### 缺少用户提供的 age 公钥

停止。不写配置，不准备备份，不发布。请用户通过可信离线流程准备 `age1...` 公钥后再继续。不要提供生成方案，也不要接触其他密钥材料。

### 固定 URL 匿名读取失败

停止部署并报告文档获取问题。不得改用替代 URL，不得声称已读取当前 Agent 指南。固定 URL 恢复匿名读取后，重新完整阅读本文再继续。

### 公开 metadata 未确认

停止。不写配置、不准备、不发布。向用户展示将公开的 host、源路径、归档名、时间和 SHA256；等待明确确认，或让用户调整路径、host 标识与命名后重新确认。

### 路径不安全或需要 root

如果候选路径是仓库本身、仓库子路径、仓库祖先、重复路径或符号链接路径，拒绝该路径并停止，等待用户重新确认。若读取路径需要 root，先说明最小权限替代方案。只有确实无法用专用非 root 用户读取且用户明确同意，才配置 `BACKUP_RUN_USER=root`。

### 远端压缩失败或刚完成压缩

CI 压缩仅在完整校验后使用 `force-with-lease` 替换分支；若 lease 失败，等待下一次 CI 调度或由用户手动触发，不得在服务器端强推。服务器在干净状态下检测到已验证的无父提交压缩快照时，会安全切换到该快照；若存在 prepared state、未提交修改或异常快照，停止并要求重新准备或人工审核。

### 仓库不干净或历史异常

出现 dirty 工作区、无关 staged 文件、未发布 commit、canonical 分叉、mirror 分叉或 canonical 在准备后移动时，停止并报告当前分支与相关 OID。不得 reset，不得 force push，不得自动 rebase，不得删除用户文件。由用户人工协调历史后，从干净状态重新检查。

### 旧 staged 集合或已有 prepared state

先运行 `BACKUP_HOST=<host> scripts/migrate-legacy.sh` 并停止等待审核。完整且一致的旧集合只有在用户确认后才能用 `--adopt-staged`。若已有 prepared state，先检查它。有效且已经通过验证时使用 `BACKUP_HOST=<host> scripts/publish-prepared.sh`，不要再次准备。无效或不再需要的 state 由用户人工决定如何清理。

### canonical 或 mirror OID 不一致

canonical 是唯一同步基准。准备前本地只能与 canonical 相同或安全快进。mirror 只接收同一个不可变 commit OID。任一分叉都停止，报告 remote 名、canonical OID、mirror OID、本地 OID 和 prepared OID。不得自动选择胜者。

快进前逐个检查 incoming commit，只接受 publication-shaped 备份提交。若任何 commit 修改脚本、host 配置、文档或其他操作文件，必须在移动本地 ref/工作区前停止。

### 已有未发布 commit

停止新准备。判断该 commit 是否属于以前的备份发布，并报告本地、canonical 与 mirrors 的 OID。不得覆盖、amend 或 reset。用户决定发布现有 commit 还是人工协调历史。

### 旧 timer 或复制遗留的 CI

发现旧共享 timer 时停止安装，先审核再由用户确认迁移。发现过时 `.github/workflows/retention.yml` 时停止，提醒用户人工审核并移除。不要自动删除。当前远端压缩只能使用本仓库的 `remote-retention.yml` 或 `.gitlab-ci.yml`。

### 准备失败

记录 tar、加密、checksum、manifest、路径、锁或依赖错误。确认没有把失败当成成功，不发布，不安装 systemd。检查仓库状态和 prepared state，再由用户决定人工清理与重试。

### 发布失败

如果 commit 尚未创建，保留 prepared state 并停止。如果 commit 已创建，记录同一个 commit OID、成功远端和待重试 mirrors。修复认证或连接后重跑 `BACKUP_HOST=<host> scripts/publish-prepared.sh`。不得重新准备，不得改写 commit。

### 外部恢复处理失败

停止发布。报告 checksum、只读列表或预期文件检查中的失败项，不接触解密材料。由用户在外部恢复环境修正验证流程，或者人工放弃该 prepared set。

## 14. 最终汇总模板

完成或停止时都要给出下面的汇总。汇总不含 token 值、公钥完整值、解密材料或恢复明文。对应解密材料由用户在仓库和服务器自动化流程之外离线保管，Agent 不接触。

```text
备份主机：<host>
备份仓库本地路径：<repo-path>
公开备份仓库：<url>

已确认备份路径：
- <exact-path-1>
- <exact-path-2>

已确认排除规则：
- <exact-exclusion-1>
- <exact-exclusion-2>

已确认公开 metadata：<host/source-paths/artifact-name/time/sha256>
canonical：<remote-name> -> <url>
有序 mirrors：
- <remote-name> -> <url>

备份分支：<branch>
本地保留数量：<count>
systemd 运行用户/组：<user>/<group>
systemd 计划：<schedule>
systemd 状态：<not-selected/dry-run-verified/installed/blocked-by-legacy>

prepared artifact：<exact-archive-path-or-not-created>
prepared checksum：<verified/failed/not-run>
prepared manifest：<exact-manifest-path-or-not-created>
prepared base OID：<oid-or-empty-branch>
备份 commit OID：<oid-or-not-created>
远端 OID：
- <remote-name>：<oid-or-not-published>
待重试 mirrors：<none-or-names>

远端压缩状态：
- <remote-name>：<github-actions-or-gitlab-schedule-or-other> / <active-or-blocked> / <cron> / <last-run-status>

迁移状态：<clean/attention-required/adopted/not-run>
外部恢复处理：<confirmed/failed/not-run>
secret 状态：<configured-or-not-needed>
age 公钥状态：已配置用户提供的公钥，不显示值
解密材料状态：Agent 未接触
最终状态：<prepared-awaiting-confirmation/published/blocked/failed>
```

汇总中的 `prepared base OID`、备份 commit OID、每个远端 OID 与待重试 mirrors 必须来自当前 state 和实际 Git 查询，不能猜测。若尚未创建或查询，明确写出对应状态。
