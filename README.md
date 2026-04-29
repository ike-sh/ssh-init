# ssh-init

`ssh-init` 只做一件事：Linux VPS 的 SSH 密钥登录初始化和安全加固。

它不会配置 BBR，不会执行系统 `update/upgrade`，不会安装 Docker，不会建站、申请 SSL、配置反代、WARP、DD 系统，也不是大菜单工具箱。

## 默认模式

默认登录用户是 `root`。

脚本会把 SSH 配置为：

```text
PermitRootLogin prohibit-password
```

含义是：禁止 root 密码登录，但允许 root 使用私钥登录。

## 推荐用法：服务器生成密钥

推荐让脚本在服务器临时生成一对 `ed25519` 密钥：

```sh
sh ./init.sh --port=22222 --gen-key --strict --yes --no-firewall
```

脚本会：

- 在安全临时目录中生成 SSH 密钥对。
- 把公钥写入目标用户的 `authorized_keys`。
- SSH 加固成功后，把私钥完整打印到终端。
- 打印后删除服务器上的临时私钥和公钥文件。

请把终端中这段私钥复制保存到本地电脑。私钥不会写入 README、备份目录或长期保存在服务器上。

## 保存私钥

Windows PowerShell 可保存为：

```powershell
notepad $env:USERPROFILE\.ssh\id_ed25519_SERVER
```

把脚本打印的完整私钥粘贴进去，保存后使用：

```powershell
ssh -i $env:USERPROFILE\.ssh\id_ed25519_SERVER -p 22222 root@SERVER_IP
```

Linux/macOS 可保存为：

```sh
mkdir -p ~/.ssh
vi ~/.ssh/id_ed25519_SERVER
chmod 600 ~/.ssh/id_ed25519_SERVER
ssh -i ~/.ssh/id_ed25519_SERVER -p 22222 root@SERVER_IP
```

FinalShell 使用方式：

- 用户名：`root`
- 端口：你的 SSH 端口，例如 `22222`
- 认证方式：选择“公钥”
- 私钥：导入刚才保存的私钥文件
- 注意：FinalShell 导入的是私钥，不是公钥

## 可选方式：GitHub 公钥

如果你已经把公钥放在 GitHub，也可以使用：

```sh
sh ./init.sh --port=22222 --key-gh=GitHubUser --strict --yes --no-firewall
```

`ALLOWED_GH_USERS` 默认是空，表示允许任意合法 GitHub 用户名。你也可以在脚本顶部设置白名单：

```sh
ALLOWED_GH_USERS="alice bob"
```

当白名单非空时，`--key-gh` 只允许白名单内的用户。

## 可选方式：手动传入公钥

```sh
sh ./init.sh \
  --port=22222 \
  --key-raw='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... you@example' \
  --strict \
  --yes \
  --no-firewall
```

## 运行前检查

运行前请先在云厂商安全组/防火墙放行目标 SSH 端口，例如 `22222/tcp`。

脚本只能自动处理服务器内的 `ufw` 或 `firewalld`，无法自动修改云厂商安全组。使用 `--no-firewall` 时，脚本不会修改本机防火墙。

不推荐直接 `curl | sh` 跑主分支。推荐固定 tag、release 或 commit 下载后，先阅读脚本，再执行。

## 支持系统

基础检测支持：

- Debian
- Ubuntu
- Alpine
- CentOS
- AlmaLinux
- Rocky Linux

脚本使用 POSIX `sh`，入口文件是 `init.sh`。

## 参数

支持：

```text
--user=root
--port=22222
--gen-key
--key-raw='ssh-ed25519 AAAA...'
--key-gh=GitHubUser
--strict
--yes
--dry-run
--rollback-last
--no-firewall
--sudo-nopasswd
```

三种密钥来源互斥，只能选择一种：

```text
--gen-key
--key-gh=GitHubUser
--key-raw='ssh-ed25519 AAAA...'
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

## sudo 行为

目标用户为 `root` 时，不需要写入 sudoers。

如果使用 `--user=deploy` 等普通用户，默认会写入需要密码的 sudo 配置：

```text
deploy ALL=(ALL) ALL
```

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

写入后会执行 `sshd -t` 或 `/usr/sbin/sshd -t` 校验，然后优先 restart SSH 服务，并等待新端口确认由 `sshd` 或 SSH banner 监听。失败会自动回滚。

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
sh /var/backups/ike-ssh-init/<TIMESTAMP>/restore.sh
```

也可以自动回滚最近一次备份：

```sh
sh ./init.sh --rollback-last
```

回滚需要 root 权限。如果当前是普通用户，不能执行 `/root/init.sh --rollback-last`。请使用仍然打开的 root 窗口，或者通过云厂商 Console 登录 root 后执行。若普通用户仍有 sudo 权限，也可以执行：

```sh
sudo sh /var/backups/ike-ssh-init/<TIMESTAMP>/restore.sh
```

## 成功后请检查

脚本成功后会输出登录命令。`--gen-key` 模式示例：

```sh
ssh -i /path/to/saved_private_key -p 22222 root@SERVER_IP
```

请务必：

- 不要关闭当前 SSH 窗口。
- 新开终端测试登录。
- 确认云厂商安全组已放行目标端口。
- 确认无法登录时知道如何执行 `restore.sh`。

## 测试

基础测试在 `tests/run.sh`：

```sh
sh tests/run.sh
```
