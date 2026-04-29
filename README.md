# ssh-init

`ssh-init` 只做一件事：Linux VPS 的 SSH 密钥登录初始化和安全加固。

它不会配置 BBR，不会执行系统 `update/upgrade`，不会安装 Docker，不会建站、申请 SSL、配置反代、WARP、DD 系统，也不是大菜单工具箱。脚本目标是简单、可审计、可回滚，适合长期在新 VPS 上重复使用。

## 安全提醒

- 私钥永远只保存在你的本地电脑，不要上传到服务器。
- GitHub 只保存公钥，例如 `id_ed25519.pub` 的内容。
- 运行前先在云厂商安全组/防火墙放行目标 SSH 端口，例如 `2222/tcp`。
- 脚本只能自动处理服务器内的 `ufw` 或 `firewalld`，无法自动修改云厂商安全组。
- 不推荐直接 `curl | sh` 跑主分支。
- 推荐固定 release 或固定 commit 下载后，先阅读脚本，再执行。

## 支持系统

基础检测支持：

- Debian
- Ubuntu
- Alpine
- CentOS
- AlmaLinux
- Rocky Linux

脚本使用 POSIX `sh`，入口文件是 `init.sh`。

## Windows 生成 SSH 密钥

在 Windows PowerShell 中执行：

```powershell
ssh-keygen -t ed25519 -C "your_email@example.com" -f $env:USERPROFILE\.ssh\id_ed25519
```

生成后：

- 私钥：`%USERPROFILE%\.ssh\id_ed25519`，只留在本地。
- 公钥：`%USERPROFILE%\.ssh\id_ed25519.pub`，可以复制到 GitHub。

查看公钥：

```powershell
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub
```

## GitHub 添加公钥

1. 打开 GitHub。
2. 进入 `Settings`。
3. 进入 `SSH and GPG keys`。
4. 点击 `New SSH key`。
5. 粘贴 `id_ed25519.pub` 的内容。
6. 保存。

注意：只粘贴公钥，永远不要粘贴私钥。

## 参数

支持：

```text
--user=deploy
--port=2222
--key-raw='ssh-ed25519 AAAA...'
--key-gh=GitHubUser
--strict
--yes
--dry-run
--rollback-last
--no-firewall
--sudo-nopasswd
```

不支持，也不会实现：

```text
--bbr
--update
--key-url
--docker
--warp
--dd
--site
--ssl
```

`--key-gh` 受 `init.sh` 顶部 `ALLOWED_GH_USERS` 白名单限制，默认示例：

```sh
ALLOWED_GH_USERS="ike666888 ike-sh"
```

## 典型用法

先下载固定版本或固定 commit 的 `init.sh`，阅读确认后执行。

手动传入公钥：

```sh
sh init.sh \
  --user=deploy \
  --port=2222 \
  --key-raw='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... your_email@example.com' \
  --strict \
  --yes
```

从白名单 GitHub 用户导入公钥：

```sh
sh init.sh \
  --user=deploy \
  --port=2222 \
  --key-gh=ike666888 \
  --strict \
  --yes
```

不修改本机防火墙：

```sh
sh init.sh \
  --user=deploy \
  --port=2222 \
  --key-gh=ike666888 \
  --no-firewall \
  --strict \
  --yes
```

仅打印计划，不改系统：

```sh
sh init.sh --user=deploy --port=2222 --key-gh=ike666888 --dry-run
```

交互模式：

```sh
sh init.sh
```

## sudo 行为

默认会写入需要密码的 sudo 配置：

```text
deploy ALL=(ALL) ALL
```

如果脚本新建了 `deploy` 用户，且你没有使用 `--sudo-nopasswd`，成功提示中会明显提醒：

```sh
passwd deploy
```

请先在当前 root 窗口执行该命令，为新建用户设置 sudo 所需密码，然后再验证 `sudo`。脚本不会保存或上传任何密码。

只有显式传入 `--sudo-nopasswd` 时，才会写入：

```text
deploy ALL=(ALL) NOPASSWD: ALL
```

sudoers 文件写入后会使用 `visudo -cf` 校验，校验失败会删除该文件并触发回滚。

## SSH 加固内容

脚本优先写入：

```text
/etc/ssh/sshd_config.d/99-ike-hardening.conf
```

如果当前系统没有启用 `Include /etc/ssh/sshd_config.d/*.conf`，则回退修改：

```text
/etc/ssh/sshd_config
```

并使用托管块：

```text
# BEGIN IKE-SSH-INIT MANAGED BLOCK
# END IKE-SSH-INIT MANAGED BLOCK
```

加固配置包含：

```text
Port PORT
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
X11Forwarding no
PermitRootLogin prohibit-password
ClientAliveInterval 300
ClientAliveCountMax 2
```

写入后会执行 `sshd -t` 或 `/usr/sbin/sshd -t` 校验。校验失败、SSH reload/restart 失败都会自动回滚。

## 备份与回滚

每次修改前会备份：

```text
/etc/ssh/sshd_config
/etc/ssh/sshd_config.d
/etc/sudoers.d
```

备份目录：

```text
/var/backups/ike-ssh-init/YYYYmmdd_HHMMSS/
```

每个备份目录都有：

```text
restore.sh
```

`restore.sh` 和 `--rollback-last` 会恢复：

- `/etc/ssh/sshd_config`
- `/etc/ssh/sshd_config.d`
- `/etc/sudoers.d`

它们不会自动删除脚本新建的 Linux 用户，也不会删除该用户的 home 目录。自动删除用户和家目录风险更高，应由用户根据实际情况手动决定。

如果 `deploy` 是脚本新建用户，且 sudoers 配置也是脚本写入的，那么回滚后 `/etc/sudoers.d` 会恢复到执行前状态。如果执行前 `deploy` 没有 sudoers 配置，回滚后 `deploy` 将不再有 sudo 权限，这是预期行为。

如果新 SSH 登录失败，可通过云厂商 VNC/Console 进入服务器后执行：

```sh
sh /var/backups/ike-ssh-init/<latest>/restore.sh
```

也可以自动回滚最近一次备份：

```sh
sh init.sh --rollback-last
```

回滚需要 root 权限。如果当前是普通用户，不能执行 `/root/init.sh --rollback-last`。请使用仍然打开的 root 窗口，或者通过云厂商 Console 登录 root 后执行。若普通用户仍有 sudo 权限，也可以执行：

```sh
sudo sh /var/backups/ike-ssh-init/<TIMESTAMP>/restore.sh
```

## 成功后请检查

脚本成功后会输出类似：

```sh
ssh -i ~/.ssh/id_ed25519 -p 2222 deploy@SERVER_IP
```

请务必：

- 不要关闭当前 SSH 窗口。
- 新开终端测试登录。
- 确认 `sudo` 可用。
- 确认云厂商安全组已放行目标端口。
- 确认无法登录时知道如何执行 `restore.sh`。

## 测试

基础测试在 `tests/run.sh`：

```sh
sh tests/run.sh
```

覆盖参数解析、公钥格式、dry-run、rollback-last、GitHub 白名单、端口校验、sudo NOPASSWD 逻辑和 `sshd_config.d` 写入逻辑。
