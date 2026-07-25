# Local Backup Push Kit

一个用于**服务器本地加密备份**的模板：把你指定的绝对路径打包、用你提供的 age 公钥加密，然后将加密归档、校验和和 manifest 提交到**私有** Git 备份仓库。

它适合需要定期备份应用配置、小型数据目录、服务定义和恢复资料的场景。默认流程是：

1. 准备一份加密备份，但不提交、不推送；
2. 由你检查校验和、manifest 与恢复结果；
3. 仅在你明确确认后，发布刚刚检查过的同一份数据。

> 这不是恢复工具，也不会替你保管解密材料。备份是否可靠，最终要靠定期恢复演练验证。

## 开始前先确认

你需要准备：

- 一台运行备份任务的服务器；
- `git`、`age`、`tar`、`zstd`、`sha256sum`、`flock`、`python3` 等命令；
- **用户提供的 `age1...` 公钥**；
- 至少一个已创建的**私有** Git 备份仓库；
- 明确的备份路径、排除规则和保留数量。

模板和指令仓库必须公开，便于首次获取说明；实际备份仓库应设为私有。即使归档已加密，manifest 会暴露主机标识、归档名、时间、SHA256 和源路径等元数据。

本项目固定的部署指引地址是：

```text
https://gitlab.com/aloneio/local-backup-push-kit/-/raw/main/docs/llm-setup-guide.zh.md
```

该地址应能被匿名 `curl` 读取。若返回 403，这是发布阻塞项；在实际匿名读取成功前，不能宣称检查已经通过。

## 安全规则

请在开始前理解这些约束：

- 只填写用户提供的 `age1...` 公钥；私钥由用户离线保管，Agent 不接触。
- 不要把 token、恢复明文或私钥写入 Git 仓库；不要把明文 secret 写进 Git 仓库。
- 恢复必需的配置文件和 secret 应作为备份源加密收入归档，而不是明文提交。
- `BACKUP_PATHS` 必须是存在的绝对路径，且不能是备份仓库本身、仓库子路径、仓库祖先、重复路径或包含符号链接的路径。
- 解密和恢复只在你控制的外部临时目录中进行；源备份仓库不应出现恢复明文。
- 出现校验、路径、远端或历史异常时，先停止并核对，不要强制推送或改写历史。

## 1. 创建你的私有备份工作仓库

本项目是公开模板。请在服务器上把它克隆到一个工作目录，然后把 Git remote 指向你自己的私有备份仓库：

```bash
git clone https://gitlab.com/aloneio/local-backup-push-kit.git local-backup-push-kit
cd local-backup-push-kit

git remote remove origin
git remote add <canonical-remote> <private-backup-repository-url>
# 可选：添加镜像仓库
# git remote add <mirror-remote> <private-mirror-repository-url>
```

第一个远端是唯一的 canonical，后续远端都是 mirror。脚本只会先与 canonical 同步；发布时所有远端接收同一个不可变 commit OID。

可使用 HTTPS、SSH、SCP、`file://` 和本地路径：

- HTTPS 远端在后续步骤中通过无回显输入配置 token；
- SSH、SCP、`file://` 和本地路径使用 Git 原生认证，不需要 token helper；
- 不要把用户名或 token 写进远端 URL。

## 2. 创建并填写主机配置

选一个主机标识。它只能包含字母、数字、点、下划线和短横线，且首尾必须是字母或数字。

```bash
mkdir -p hosts/<host>
cp hosts/example/backup.conf hosts/<host>/backup.conf
```

编辑 `hosts/<host>/backup.conf`，逐项替换占位符：

| 配置项 | 你需要填写的内容 |
| --- | --- |
| `CONFIG_HOST_ID` | 当前主机标识，必须与 `BACKUP_HOST` 相同 |
| `AGE_RECIPIENT` | 用户提供的 `age1...` 公钥 |
| `BACKUP_BRANCH` | 备份分支，例如 `main` 或自定义分支 |
| `BACKUP_REMOTES` | remote 名称列表；第一项为 canonical |
| `BACKUP_PATHS` | 要备份的绝对路径列表 |
| `TAR_EXCLUDES` | 不应进入归档的路径模式 |
| `BACKUP_RETENTION_COUNT` | 每个 host 保留的完整集合数 |
| `BACKUP_LOCK_TIMEOUT` | 等待并发备份锁的秒数，范围为 0–3600 |
| `BACKUP_RUN_USER`、`BACKUP_RUN_GROUP`、`BACKUP_ON_CALENDAR` | 可选 systemd 定时任务设置 |

建议先备份真正影响恢复的内容：应用配置、服务定义、小型持久化数据、数据库一致性导出和恢复说明。不要把大型数据库运行目录直接当作普通文件目录打包。

## 3. 创建初始干净提交

配置文件是你的私有备份工作仓库的一部分。确认内容无误后，创建初始干净提交：

```bash
git status --short
git add -- \
  .gitignore README.md docs/llm-setup-guide.zh.md \
  hosts/<host>/backup.conf \
  scripts/*.sh scripts/lib/*.sh tests/*.sh tests/lib/*.sh
git diff --cached --name-status
git commit -m "Initialize backup template and host config"
git status --short
```

最后一条命令应没有输出。这个初始干净提交必须早于第一份备份。canonical 为空分支时，首次发布会以该提交为基础；如 canonical 已有分支，脚本只接受安全快进，落后或分叉都会停止。

## 4. 配置 HTTPS token（仅 HTTPS 远端需要）

如果配置中包含 HTTP(S) remote，在受控终端运行：

```bash
BACKUP_HOST=<host> scripts/configure-secrets.sh
```

脚本会逐个无回显询问 token，并以 0600 权限写入 `/etc/encrypted-git-backup/<host>.env`。不要把 token 发到聊天、复制进配置文件、写进命令行或 shell 历史。

若所有远端都使用 SSH、SCP、`file://` 或本地路径，则不需要运行此步骤。

## 5. 准备备份：不提交、不推送

确认仓库干净后运行：

```bash
BACKUP_HOST=<host> BACKUP_PUSH=0 scripts/backup.sh
```

脚本会先检查 canonical，再创建加密归档并只暂存以下当前 host 的文件：

- `backups/<host>/<artifact-id>.tar.zst.age`
- `backups/<host>/<artifact-id>.sha256`
- `backups/<host>/latest.txt`
- `manifests/<host>/<artifact-id>.json`

同时会在 `.git/local-backup-push-kit/prepared/<host>.state` 保存 prepared state。此时不会创建备份 commit，也不会向任何远端推送。

如果已有 prepared state，不要再次准备另一份备份；先检查现有产物，或在确认后发布它。

## 6. 检查备份并做恢复验证

先检查暂存内容和校验和：

```bash
git diff --cached --name-status
cat backups/<host>/latest.txt
sha256sum -c backups/<host>/<artifact-id>.sha256
cat manifests/<host>/<artifact-id>.json
cat .git/local-backup-push-kit/prepared/<host>.state
```

你应确认：

- 暂存区只包含本次备份对应的归档、校验和、manifest 和 `latest.txt`；
- manifest 中的源路径、主机和时间符合预期；
- SHA256 校验成功；
- canonical、mirrors 和 `BACKUP_BRANCH` 配置正确；
- 实际备份仓库均为私有。

随后将加密归档、校验和和 manifest 复制到仓库外的外部临时目录，使用**用户控制的外部恢复处理**完成可解密、可列出及内容核对。恢复演练的明文不得回写到备份仓库。

如果校验失败、路径不对、manifest 信息不应公开，或恢复验证失败，**不要执行发布命令**。先人工处理 prepared state 和暂存产物，修正配置后重新准备。

## 7. 明确确认后发布

只有在你已检查并明确确认可以发布后，运行：

```bash
BACKUP_HOST=<host> scripts/publish-prepared.sh
```

发布器会再次确认 canonical 没有在准备后移动，然后为 prepared state 中记录的精确路径创建一个 commit，按 canonical、mirrors 的顺序发布。

- 某个 mirror 失败时，canonical 和已成功 mirrors 不会被改写；再次运行同一命令只重试尚未成功的 mirror。
- 提交创建后不允许 rebase、amend 或 force push。
- 保留删除与发布 commit 是同一事务；发生发布失败时，旧集合仍可从父提交恢复。
- `BACKUP_PUSH=1` 是高级兼容快捷方式，可在一次运行中准备并发布；它不能替代首次部署时的检查与明确确认。

## 8. 可选：安装 systemd 定时任务

先渲染并检查 unit，不写入系统目录：

```bash
BACKUP_HOST=<host> BACKUP_INSTALL_DRY_RUN=1 scripts/install-systemd-timer.sh
```

核对输出中的 `User=`、`Group=`、`OnCalendar=`、工作目录和环境文件路径。满意后再安装：

```bash
BACKUP_HOST=<host> scripts/install-systemd-timer.sh
```

每个 host 都有独立的 service、timer 和环境文件：

```bash
systemctl status encrypted-git-backup-<host>.timer
journalctl -u encrypted-git-backup-<host>.service -n 100 --no-pager
```

默认应使用非 root 用户。仅当备份路径确实需要 root 权限时，才显式设置 `BACKUP_RUN_USER=root`；root 模式通过受信任 launcher 启动，而不是让 systemd 直接执行仓库脚本。

## 本地保留策略

`BACKUP_RETENTION_COUNT` 按每个 host 单独计算。一个完整集合由加密归档、对应 SHA256 和 manifest 组成；孤立文件会保留并报告，不会被当成可删除备份。

保留只在服务器本地执行，远端 CI 保留任务已经移除。若发布中断，恢复 journal 会保留在 Git 内部目录，后续运行会在可证明安全时恢复或完成清理；关系不明确时会停止，等待人工审核。

## 迁移旧部署

如果这个仓库以前使用过旧脚本，先执行只读报告：

```bash
BACKUP_HOST=<host> scripts/migrate-legacy.sh
```

报告会检查旧 staged 集合、未发布或分叉的历史、mirror 状态和旧 timer。不要让脚本自动猜测正确历史。

只有在你审核并确认旧 staged 集合完整、一致且可安全采用后，才执行：

```bash
BACKUP_HOST=<host> scripts/migrate-legacy.sh --adopt-staged
```

## 常见问题

| 提示 | 应对方式 |
| --- | --- |
| `missing or unsafe config` | 确认 `BACKUP_HOST` 与 `hosts/<host>/backup.conf`，并确保配置文件不是符号链接。 |
| `backup repository must be clean before preparation` | 先审阅并处理所有已修改、已暂存和未跟踪文件。 |
| `prepared backup already exists` | 检查现有 prepared state；通过验证后使用 `scripts/publish-prepared.sh`，不要重新打包。 |
| `canonical moved after preparation` | 不要发布旧 state；人工处理远端历史后重新准备。 |
| `missing token for HTTP remote` | 重新运行 `scripts/configure-secrets.sh`，不要显示或导出 token。 |
| `remote divergence` | 记录各 remote 的 OID，停止自动操作，由你决定如何协调。 |

## 文件说明

- `scripts/backup.sh`：准备加密备份；默认不发布。
- `scripts/publish-prepared.sh`：发布已经检查过的 prepared 数据。
- `scripts/configure-secrets.sh`：无回显保存 HTTP(S) remote token。
- `scripts/install-systemd-timer.sh`：渲染或安装 host 专用 systemd timer。
- `scripts/migrate-legacy.sh`：检查并在显式确认后采用旧 staged 集合。
- `hosts/example/backup.conf`：可复制的脱敏配置模板。
- `docs/llm-setup-guide.zh.md`：自动化部署助手的详细执行指引。
