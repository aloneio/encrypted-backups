# Local Backup Push Kit

这是一个服务器本地加密备份模板。它把指定的绝对路径打包到仓库外的临时目录，用用户提供的 `age1...` 公钥加密，再把加密归档、SHA256、manifest 和 `latest.txt` 放进 Git 仓库。

默认安全流程分成两个阶段。先用 `BACKUP_PUSH=0` 只准备一份不可变备份，检查完成并由用户明确确认后，再用 `scripts/publish-prepared.sh` 发布刚才检查过的同一份数据。发布阶段不会重新打包。

## 先分清两类仓库

- 模板和指令仓库必须公开，未登录的用户与 Agent 才能匿名 `curl` 读取配置指南。
- 实际备份仓库应设为私有，因为归档虽然已加密，文件名、host 名、提交时间和 manifest 元数据仍可能暴露运维信息。
- 模板仓库只放脚本、文档、测试和脱敏示例。实际备份仓库才会出现 `backups/` 与 `manifests/`。

Agent 指令的固定地址只能使用：

```bash
curl -fsSL https://gitlab.com/aloneio/local-backup-push-kit/-/raw/main/docs/llm-setup-guide.zh.md
```

当前 GitLab 项目如果尚未公开，匿名 `curl` 可能返回 403。这是发布阻塞项。在项目公开并实际完成匿名读取检查之前，不能宣称检查已经通过，也不要访问其他替代地址冒充结果。

## 安全边界

- 只接受用户提供的 `age1...` 公钥。不得生成私钥。不得请求私钥。不得读取私钥。不得显示私钥。不得保存私钥。
- 私钥由用户离线保管，Agent 不接触。
- token 只能通过 `scripts/configure-secrets.sh` 的无回显输入收集，不能写进仓库、命令行参数、shell 历史或 Agent 输出。
- 不要把明文 secret 写进 Git 仓库。恢复必需的配置文件和 secret 应作为备份源加密收入归档。
- `BACKUP_PATHS` 必须是存在的绝对路径，不能是仓库本身、仓库子路径、仓库祖先、重复路径或经过符号链接的路径。
- manifest 会暴露 host、归档名、时间、SHA256 和收入归档的源路径。实际备份仓库应保持私有，并限制读取权限。
- 解密与恢复只在用户控制的外部恢复环境进行。不要在源备份仓库中生成恢复明文。

## 适合备份什么

建议收入恢复服务真正需要的内容，例如：

- compose 文件和应用配置
- 小型持久化数据目录
- systemd unit 与恢复说明
- 证书、环境文件或其他恢复所需 secret，但它们只能作为加密归档的输入

不建议直接收入大型数据库运行目录。先按数据库自身规则生成一致性导出，再把导出路径加入备份源。

## 交给 Agent 的最短说明

把下面这段交给已经连接服务器的 Agent：

```text
请完整读取 https://gitlab.com/aloneio/local-backup-push-kit/-/raw/main/docs/llm-setup-guide.zh.md 和当前仓库文件。只接收我提供的 age1... 公钥。先确认备份路径、canonical 与 mirrors、自定义分支、保留数量、运行用户和计划，再建立初始干净提交。使用 scripts/configure-secrets.sh 安全收集 HTTPS token。先运行 BACKUP_PUSH=0，展示状态、归档、校验和、manifest 与外部恢复验证结果，等我明确确认后再运行 scripts/publish-prepared.sh。systemd 只有在我选择后才安装。不要输出任何 secret。
```

下面是同一流程的人类手动版。

## 完整的新手流程

### 1. 检查并复制模板

先在服务器上的模板目录中完整查看关键文件：

```bash
cat README.md
cat hosts/example/backup.conf
cat scripts/backup.sh
cat scripts/publish-prepared.sh
cat scripts/configure-secrets.sh
cat scripts/install-systemd-timer.sh
cat scripts/migrate-legacy.sh
cat scripts/root-launcher.sh
cat scripts/git-askpass.sh
cat scripts/lib/common.sh
cat scripts/lib/git-remotes.sh
cat scripts/lib/publication-schema.sh
cat scripts/lib/prepare.sh
```

为当前主机复制配置。把 `<host>` 换成只含字母、数字、点、下划线或短横线、且首尾均为字母或数字的主机标识：

```bash
mkdir -p hosts/<host>
cp hosts/example/backup.conf hosts/<host>/backup.conf
```

不要直接运行示例配置。先替换其中每个尖括号占位符。

### 2. 填写主机、路径、远端、分支与保留策略

编辑 `hosts/<host>/backup.conf`，至少确认这些字段：

- `CONFIG_HOST_ID` 与运行时 `BACKUP_HOST` 完全相同。
- `AGE_RECIPIENT` 是用户提供的 `age1...` 公钥。
- `BACKUP_PATHS` 是需要恢复的真实绝对路径。把恢复必需的配置和 secret 文件作为源路径收入加密归档。
- `BACKUP_BRANCH` 可以是 `main`，也可以是合法的自定义分支，例如 `backup/production`。
- `BACKUP_REMOTES` 至少有一个已存在的 Git remote 名。
- `BACKUP_RETENTION_COUNT` 是每个 host 本地保留的完整集合数量，默认语义为 3。
- `BACKUP_LOCK_TIMEOUT` 是等待仓库锁的秒数，允许 0 到 3600。
- `BACKUP_RUN_USER`、`BACKUP_RUN_GROUP`、`BACKUP_ON_CALENDAR` 用于可选 systemd 安装。

添加远端时只把 URL 记录到 Git 配置，不要把 token 放进 URL：

```bash
git remote add <canonical-remote> <repository-url>
git remote add <mirror-remote> <repository-url>
git remote -v
```

第一个远端是唯一的 canonical。准备前只允许从它进行快进同步。后续远端都是 mirror，只接收 canonical 流程产生的同一个不可变 commit OID。

canonical 的目标空分支可以直接完成首次引导。脚本也支持自定义分支，但当前检出的本地分支必须等于 `BACKUP_BRANCH`。如果 canonical 已有提交，本地分支必须能快进到它。若本地超前或双方分叉，脚本会停止，要求人工处理。

快进前会逐 commit 验证 canonical 新历史。只接受由本工具产生的 publication-shaped 提交；任何脚本、配置、文档或其他操作文件变更都会在本地 ref 与工作区移动前被拒绝。

HTTPS 远端使用 AskPass token。SSH、SCP、`file://` 和本地路径使用 Git 原生认证，不需要 token，也不会弹出 token 提示。每个 remote 只能有一个 fetch URL 和一个 push URL，且两者传输类型必须一致。

### 3. 在首次备份前创建初始干净提交

发布脚本要求本地分支已经有模板提交。配置完成后先检查差异，再创建初始干净提交：

```bash
git status --short
git add -- README.md .gitignore docs/llm-setup-guide.zh.md hosts/<host>/backup.conf scripts/*.sh scripts/lib/*.sh tests/*.sh tests/lib/*.sh
git diff --cached --name-status
git commit -m "Initialize backup template and host config"
git status --short
```

最后一条命令必须没有输出。这个初始干净提交必须早于第一份备份。不要把 token、明文恢复数据或仓库外的备份源复制进提交。

如果 canonical 的 `BACKUP_BRANCH` 还是空分支，首次发布会从这个模板提交开始。如果远端已有该分支，先让本地分支安全快进并再次确认工作区干净。

### 4. 安全配置 HTTPS token

只要配置中存在 HTTP 或 HTTPS 远端，就运行安全 helper：

```bash
BACKUP_HOST=<host> scripts/configure-secrets.sh
```

它逐个提示 HTTP(S) remote，使用无回显输入，把结果以 0600 权限写到 `/etc/encrypted-git-backup/<host>.env`。SSH、本地和 `file://` remote 会被跳过。不要用字面 token 导出命令，也不要把 token 粘进配置文件。

### 5. 只准备，不发布

确认仓库干净后运行：

```bash
BACKUP_HOST=<host> BACKUP_PUSH=0 scripts/backup.sh
```

脚本会先同步 canonical，再在仓库外建立临时明文包，完成加密后删除临时明文，生成一组文件并暂存精确路径：

- `backups/<host>/<artifact-id>.tar.zst.age`
- `backups/<host>/<artifact-id>.sha256`
- `backups/<host>/latest.txt`
- `manifests/<host>/<artifact-id>.json`
- `.git/local-backup-push-kit/prepared/<host>.state`

`BACKUP_PUSH=0` 不创建备份 commit，也不推送。只要 prepared state 仍存在，就不要再次准备另一份备份。

### 6. 检查状态、产物、校验和与 manifest

先静态检查：

```bash
git diff --cached --name-status
cat backups/<host>/latest.txt
sha256sum -c backups/<host>/<artifact-id>.sha256
cat manifests/<host>/<artifact-id>.json
cat .git/local-backup-push-kit/prepared/<host>.state
```

确认暂存区只有当前 host 的归档、校验和、manifest 与 `latest.txt`。核对 state 中的 branch、remotes、base OID、路径和哈希，不要修改这些文件。

加密内容的验证与解密只能交给用户控制的外部恢复处理。把归档、校验和与 manifest 复制到仓库外的外部临时目录，由用户控制的恢复工具验证可解密、可列出和包含预期文件。源仓库中不能出现恢复明文，Agent 也不能接触用户离线保管的解密材料。

如果校验失败、路径不对、manifest 暴露了不应公开的信息，或者外部恢复处理失败，不要执行发布命令。先人工清理 prepared 状态与暂存产物，修正配置，再重新准备。

### 7. 明确确认后发布准备好的同一份数据

用户应明确确认以下内容：

- SHA256 成功
- manifest 与源路径正确
- 用户控制的外部恢复处理成功
- canonical、mirrors 和 `BACKUP_BRANCH` 正确
- 实际备份仓库均为私有

明确确认后运行：

```bash
BACKUP_HOST=<host> scripts/publish-prepared.sh
```

发布器先再次检查 canonical 是否仍等于准备时记录的 base OID，然后只为 state 记录的路径创建一个 commit。它按顺序发布到 canonical 与 mirrors，所有成功远端都必须指向同一个不可变 commit OID。

若某个 mirror 失败，canonical 和已成功 mirrors 不会被改写。再次运行同一条发布命令时，只重试尚未成功的 mirror，并继续使用 state 中的同一个 OID。若发现 mirror 指向其他历史，脚本会报告双方 OID 并停止，不会自动解决分叉。

提交创建后不允许 rebase、amend 或 force push，也不要强制推送。发布失败后的本地 commit 保持不变，旧的保留集仍可从父提交恢复。

`BACKUP_PUSH=1` 是高级兼容快捷方式，只能在已经理解并完成上述安全两阶段流程后使用。它在一次加锁运行中准备并发布，不能替代首次人工检查与明确确认。

### 8. 可选安装每 host 的 systemd

先渲染检查，不写系统目录：

```bash
BACKUP_HOST=<host> BACKUP_INSTALL_DRY_RUN=1 scripts/install-systemd-timer.sh
```

核对输出中的 `User=`、`Group=`、`OnCalendar=`、工作目录和 host 专用 env 路径。默认运行用户取 `SUDO_USER` 或当前用户，默认组取该用户的组，默认计划为 `daily`。

确实要安装时运行：

```bash
BACKUP_HOST=<host> scripts/install-systemd-timer.sh
```

每个 host 使用独立的 `encrypted-git-backup-<host>.service`、`encrypted-git-backup-<host>.timer` 和 `/etc/encrypted-git-backup/<host>.env`。查看状态时也要使用 host 专用名称：

```bash
systemctl status encrypted-git-backup-<host>.timer
journalctl -u encrypted-git-backup-<host>.service -n 100 --no-pager
```

不要默认以 root 运行。只有确实需要读取受限路径时，才在配置中明确写 `BACKUP_RUN_USER=root`，并接受安装脚本的 root 权限警告。旧的共享 timer 若存在，安装器会停止。审核后才能显式迁移：

```bash
BACKUP_HOST=<host> scripts/install-systemd-timer.sh --migrate-legacy
```

systemd 服务内部使用兼容的单次准备加发布模式。首次人工流程仍必须先完成两阶段验证。

当 `BACKUP_RUN_USER=root` 时，unit 执行 `${BACKUP_ROOT_LAUNCHER_DIR:-/usr/local/libexec/local-backup-push-kit}/backup-launcher`，不直接执行仓库脚本。安装器把 launcher、service 与 timer 作为同一回滚事务；launcher 会在执行前拒绝符号链接、非 root 所有权、危险写权限或异常硬链接。

## 本地保留策略

保留策略只在服务器本地执行，远端 CI 保留任务已经移除。`BACKUP_RETENTION_COUNT` 按每个 host 单独计算，不会让一个 host 的备份删除另一个 host 的文件。

一个完整集合包含加密归档、对应 SHA256 和 manifest。只有新的完整集合成功准备后，脚本才计算旧集合删除列表。孤立文件会报告并保留，不会被当成完整集合删除。`latest.txt` 指向当前最新归档。

保留删除与发布 commit 属于同一事务。commit 前失败会恢复删除项。commit 已创建但远端发布失败时，删除记录只存在于该本地 commit，旧文件仍可从父提交恢复。

事务开始前，回滚载荷与 journal 会先原子写入 `.git/local-backup-push-kit/recovery/retention/<host>/`。下次持锁启动时，HEAD 等于记录的 base 会自动恢复；HEAD 是该 base 的直接发布子提交会完成清理；HEAD 无法读取或关系不明确时会保留 journal 并停止，必须人工审核。

## 旧部署迁移

先运行只报告、不自动修改的检查：

```bash
BACKUP_HOST=<host> scripts/migrate-legacy.sh
```

报告会检查旧的 staged 集合、未发布或分叉的本地历史、旧时间戳集合、mirror OID、旧 root timer 和复制遗留的远端清理配置。发现问题时按下面路径处理：

- 旧 staged 集合完整且哈希、manifest、`latest.txt` 一致，审核后可采用：

  ```bash
  BACKUP_HOST=<host> scripts/migrate-legacy.sh --adopt-staged
  ```

- staged 集合不完整或混入无关文件，先用 `git diff --cached --name-status` 人工判断。不要自动删除旧归档。
- 本地分支未发布、落后或已分叉，先人工协调本地与 canonical。helper 不会 reset commit。
- mirror OID 与 canonical 不同，人工判断正确历史。helper 不会 force push。
- 发现旧 timer，先审核，再使用 `scripts/install-systemd-timer.sh --migrate-legacy`。
- 发现旧的远端清理配置，人工审核并删除。迁移 helper 不会自动删除文件。

报告与采用命令都不会替你重置历史、删除归档、替换 timer 或解决远端分叉。任何破坏性动作都需要人工决定。

## 远端发布模型

`BACKUP_REMOTES[0]` 是 canonical，其他项是 mirrors。准备前脚本查询 canonical 的 `BACKUP_BRANCH`：

- 分支不存在时，允许从本地初始模板提交引导。
- 分支与本地 HEAD 相同时，直接准备。
- 本地可快进时，只做 fast-forward。
- 本地超前或分叉时，停止并要求人工处理。

发布 commit 创建后，脚本按 `<commit_oid>:refs/heads/<branch>` 推送固定 OID。它不会在 mirror 之间 pull，不会为不同远端生成不同 commit，也不会在失败后改写已发布历史。

## 恢复原则

恢复演练必须在外部临时目录进行，而不是在源仓库中进行：

1. 从私有备份仓库取得加密归档、SHA256 与 manifest。
2. 在仓库外建立权限受控的外部临时目录。
3. 先验证 SHA256。
4. 由用户控制的外部恢复处理完成解密、只读列出和内容检查。
5. 确认目标主机、路径、所有者和服务停机条件后，再人工恢复。
6. 演练结束后清理外部临时目录中的明文。

备份是否成功不能只看 push。必须定期完成外部恢复演练。

## 模板维护检查

这些命令只适用于尚未生成备份数据的 source-only 模板：

```bash
bash scripts/check-source-only.sh
bash -n scripts/*.sh scripts/lib/*.sh tests/*.sh tests/lib/*.sh
bash tests/run.sh readme-contract
```

真正的备份仓库包含 `backups/` 与 `manifests/`，不要为了让 source-only 检查通过而删除备份。

## 常见停止原因

- `missing config`：确认 `BACKUP_HOST` 与 `hosts/<host>/backup.conf`。
- `host mismatch`：让 `CONFIG_HOST_ID` 与 `BACKUP_HOST` 完全一致。
- `AGE_RECIPIENT must be a valid age X25519 public recipient`：让用户重新提供有效的 `age1...` 公钥。
- `backup repository must be clean before preparation`：先审核并处理所有暂存、修改和未跟踪文件。
- `local repository has no template commit`：先创建初始干净提交。
- `canonical moved after preparation`：不要发布旧 state，先人工清理并重新准备。
- `missing token for HTTP remote`：重新运行 `scripts/configure-secrets.sh`，不要显示 token。
- `remote divergence`：记录 remote 与 OID，停止自动操作，人工决定历史。
- `prepared backup already exists`：检查并发布现有 prepared state，或者人工放弃后再准备。

## 文件说明

- `scripts/backup.sh`：同步 canonical 并准备加密备份。
- `scripts/publish-prepared.sh`：发布已经验证的 prepared state。
- `scripts/configure-secrets.sh`：无回显收集 HTTP(S) token，写入 host 专用 0600 env 文件。
- `scripts/install-systemd-timer.sh`：渲染或安装 host 专用 systemd service 与 timer。
- `scripts/migrate-legacy.sh`：报告旧状态，并在显式参数下采用完整 staged 集合。
- `scripts/check-source-only.sh`：检查公开模板结构与有限词法策略。
- `scripts/lib/retention.sh`：计算 host 隔离的本地完整集合保留计划。
- `hosts/example/backup.conf`：必须复制并替换占位符的配置模板。
- `docs/llm-setup-guide.zh.md`：给已连接服务器 Agent 的中文配置指令。
