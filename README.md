# ssh-init

`ssh-init` 用于 SSH 密钥登录配置和禁用密码登录。它只做 SSH 初始化与安全加固，不包含 BBR、系统更新、Docker、建站、WARP、DD、SSL 等功能。

脚本参考 [kejilion SSH 密钥登录教程](https://blog.kejilion.pro/ssh-key/) 的交互方式，提供中文菜单：

```text
================ SSH 密钥登录配置 ================
1. 生成全新的 Ed25519 密钥对，并配置当前用户免密登录
2. 输入 GitHub 用户名，拉取 GitHub 公钥并配置当前用户免密登录
3. 退出
=================================================
请选择 [1-3]:
```

“当前用户”指运行脚本时的用户。如果是 root 运行，则配置 `/root/.ssh/authorized_keys`；如果是普通用户运行，则配置该用户的 `~/.ssh/authorized_keys`。修改 `/etc/ssh/sshd_config` 和重启 SSH 服务需要 root 权限，因此建议使用 root 或 sudo 运行。

## GitHub 公钥导入

GitHub 模式会从下面的地址拉取公钥：

```text
https://github.com/用户名.keys
```

GitHub 上保存的是公钥，本地电脑保存的是私钥。脚本会过滤无效公钥、追加写入当前用户的 `authorized_keys`，不会覆盖已有内容，重复公钥不会重复写入。

一键命令示例：

```sh
curl -fsSL https://raw.githubusercontent.com/ike-sh/ssh-init/v0.4.0/init.sh -o init.sh
sh init.sh github GitHubUser
```

## 生成 Ed25519 密钥

生成密钥模式会在服务器安全临时目录中生成 Ed25519 密钥对，把公钥写入当前用户的 `authorized_keys`，然后把私钥打印在终端。用户必须复制并保存私钥，脚本打印后会删除服务器临时私钥和公钥。

```sh
sh init.sh gen
```

私钥输出格式：

```text
==================== 请复制保存以下私钥 ====================
-----BEGIN OPENSSH PRIVATE KEY-----
...
-----END OPENSSH PRIVATE KEY-----
==================== 私钥结束 ====================
```

Windows 可保存为：

```text
C:\Users\你的用户名\.ssh\id_ed25519_SERVER
```

Linux/macOS 可保存为：

```sh
~/.ssh/id_ed25519_SERVER
chmod 600 ~/.ssh/id_ed25519_SERVER
```

FinalShell 导入的是私钥，不是公钥。

## SSH 加固

成功导入公钥后，脚本会修改 `/etc/ssh/sshd_config`，确保以下配置生效：

```text
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
```

`PermitRootLogin prohibit-password` 表示禁止 root 密码登录，但允许 root 密钥登录。

修改前会备份：

```text
/etc/ssh/sshd_config.bak.YYYYmmdd_HHMMSS
```

修改后会执行 `sshd -t` 或 `/usr/sbin/sshd -t` 校验，并按顺序尝试重启 SSH：

```text
systemctl restart ssh
systemctl restart sshd
service ssh restart
service sshd restart
rc-service ssh restart
rc-service sshd restart
```

如果 Ubuntu 缺少 `/run/sshd`，脚本会自动创建并设置权限为 `755`，避免 `Missing privilege separation directory: /run/sshd`。

## 安全提醒

运行前建议确认云厂商 VNC/Console 可用。执行后请不要立即关闭当前 SSH 窗口，先新开一个终端测试密钥登录是否成功，确认可以用私钥登录后再关闭当前窗口。

如果无法登录，请通过云厂商 VNC/Console 恢复 SSH 配置，例如使用备份文件：

```sh
cp -p /etc/ssh/sshd_config.bak.YYYYmmdd_HHMMSS /etc/ssh/sshd_config
systemctl restart ssh || systemctl restart sshd
```

## 测试

```sh
sh tests/run.sh
```
