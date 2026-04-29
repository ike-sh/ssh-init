# ssh-init

`ssh-init` 是一个用于 Linux VPS 的 SSH 密钥登录配置脚本。它只做 SSH 公钥导入、服务器生成密钥、禁用密码登录和备份恢复，不包含 BBR、系统更新、Docker、建站、WARP、DD、SSL 等功能。

## 推荐用法

主推荐方式是下载固定版本脚本后进入中文交互菜单：

```sh
curl -fsSL https://raw.githubusercontent.com/ike-sh/ssh-init/v0.5.0/init.sh -o init.sh && sh init.sh
```

运行后会看到：

```text
================ SSH 密钥登录配置工具 ================
1. 从 GitHub 导入公钥并禁用密码登录
2. 在服务器生成 Ed25519 密钥并禁用密码登录
3. 恢复 SSH 配置备份
4. 查看当前 SSH 登录配置
5. 退出
====================================================
请选择 [1-5]:
```

建议优先选择 `1`，输入真实 GitHub 用户名。`GitHubUser`、`username`、`yourname`、`你的用户名` 都只是示例占位符，不是可直接使用的用户名。

## GitHub 公钥导入

GitHub 模式会从下面的公开地址拉取公钥：

```text
https://github.com/你的GitHub用户名.keys
```

GitHub 上保存的是公钥，本地电脑保存的是私钥。脚本只会把有效公钥追加写入当前运行用户的 `~/.ssh/authorized_keys`，不会覆盖已有内容，重复公钥不会重复写入。

添加 GitHub 公钥的路径：

1. 打开 GitHub -> Settings -> SSH and GPG keys
2. 点击 New SSH key
3. Key type 选择 Authentication Key
4. 粘贴你本地电脑上的 `.pub` 公钥内容
5. 保存后再运行本脚本并选择菜单 `1`

如果 Windows 连接时报 `Identity file not accessible`，通常表示本地私钥文件不存在、路径写错，或者你把 `.pub` 公钥当成私钥用了。FinalShell 导入的是私钥，不是 `.pub` 公钥。

命令行兼容模式仍可使用：

```sh
sh init.sh github your-real-github-name
```

## 服务器生成密钥

菜单 `2` 会在服务器安全临时目录中生成 Ed25519 密钥对，把公钥写入当前用户的 `authorized_keys`，然后把私钥打印在终端。你必须复制保存这段私钥；脚本打印后会删除服务器临时私钥和公钥。

Windows 可保存为：

```text
C:\Users\你的用户名\.ssh\id_ed25519_SERVER
```

Linux/macOS 可保存为：

```sh
~/.ssh/id_ed25519_SERVER
chmod 600 ~/.ssh/id_ed25519_SERVER
```

FinalShell 新建连接时选择“公钥”认证，私钥导入刚才保存的私钥文件。

命令行兼容模式：

```sh
sh init.sh gen
```

## SSH 加固

成功导入公钥后，脚本会备份并修改 `/etc/ssh/sshd_config`，确保以下配置生效：

```text
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
```

`PermitRootLogin prohibit-password` 表示禁止 root 密码登录，但允许 root 密钥登录。

脚本会在修改前备份：

```text
/etc/ssh/sshd_config.bak.YYYYmmdd_HHMMSS
~/.ssh/authorized_keys.bak.YYYYmmdd_HHMMSS
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

Ubuntu 上如果缺少 `/run/sshd`，脚本会自动创建并设置权限为 `755`。

## 恢复备份

如果登录异常，请通过云厂商 VNC/Console 登录服务器，重新运行脚本并选择菜单 `3`：

```sh
sh init.sh
```

恢复菜单可以恢复最新的 `sshd_config` 备份、最新的 `authorized_keys` 备份，或同时恢复二者。恢复 `sshd_config` 后脚本会再次执行 `sshd -t` 并重启 SSH 服务。

命令行兼容模式：

```sh
sh init.sh restore
```

## 查看状态

菜单 `4` 会显示当前用户、HOME、`.ssh` 权限、`authorized_keys` 状态、`sshd -T` 关键配置和 SSH 服务监听端口。

命令行兼容模式：

```sh
sh init.sh status
```

## 安全提醒

运行前建议确认云厂商 VNC/Console 可用。脚本执行成功后，请不要立即关闭当前 SSH 窗口，先新开一个终端测试密钥登录是否成功，确认可以用私钥登录后再关闭当前窗口。

不建议使用 `curl | sh` 直接管道执行；推荐像上面的命令一样先下载固定版本脚本，再执行。

## 测试

```sh
sh tests/run.sh
```
