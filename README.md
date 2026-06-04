# ssh-init

`ssh-init` 是一个用于 Linux VPS 的 SSH 密钥登录配置脚本。它只做 SSH 公钥导入、服务器生成密钥、禁用密码登录和备份恢复，不包含 BBR、系统更新、Docker、建站、WARP、DD、SSL 等功能。

## 一键使用

最简单的公开使用方式是拉取 `main` 最新版并进入中文交互菜单：

```sh
curl -fsSL https://raw.githubusercontent.com/ike-sh/ssh-init/main/init.sh -o init.sh && sh init.sh
```

这适合普通用户快速使用。运行前建议确认云厂商 VNC/Console 可用，执行后不要立刻关闭当前 SSH 窗口。

## 固定版本/高级用法

如果你想固定行为、不受 `main` 更新影响，可以使用 tag 版本。生产环境更建议固定 tag；普通用户可以直接用 `main`。

```sh
curl -fsSL https://raw.githubusercontent.com/ike-sh/ssh-init/v0.5.2/init.sh -o init.sh && sh init.sh
```

运行后会看到：

```text
============================================================
 SSH 密钥登录配置工具
============================================================
  1. 从 GitHub 导入公钥并禁用密码登录
  2. 在服务器生成 Ed25519 密钥并配置登录
  3. 查看本机已有 SSH 密钥
  4. 生成新的本机 Ed25519 密钥
  5. 恢复 SSH 配置备份
  6. 查看当前 SSH 登录配置
  7. 退出
============================================================
请选择 [1-7]:
```

建议优先选择 `1`，输入真实 GitHub 用户名。`GitHubUser`、`username`、`yourname`、`你的用户名` 都只是示例占位符，不是可直接使用的用户名。

## GitHub 公钥导入

GitHub 模式会从下面的公开地址拉取公钥：

```text
https://github.com/你的GitHub用户名.keys
```

GitHub 上保存的是公钥，本地电脑保存的是私钥。脚本只会把有效公钥追加写入当前运行用户的 `~/.ssh/authorized_keys`，不会覆盖已有内容，重复公钥不会重复写入。

添加 GitHub 公钥的步骤：

1. 打开 GitHub SSH Keys 设置页面：
   <https://github.com/settings/keys>
2. 点击 New SSH key 或 Add SSH key。
3. Key type 选择 Authentication Key。
4. Title 可随便填写，例如 `VPS`、`Home Laptop`、`ssh-init`。
5. Key 输入框中粘贴“公钥”，不是私钥。

公钥通常长这样：

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@device
```

不要粘贴这种私钥：

```text
-----BEGIN OPENSSH PRIVATE KEY-----
...
-----END OPENSSH PRIVATE KEY-----
```

添加后可以访问下面地址，检查是否能看到公钥：

```text
https://github.com/你的用户名.keys
```

保存后再运行本脚本并选择菜单 `1`。

如果 Windows 连接时报 `Identity file not accessible`，通常表示本地私钥文件不存在、路径写错，或者你把 `.pub` 公钥当成私钥用了。FinalShell 导入的是私钥，不是 `.pub` 公钥。

命令行兼容模式仍可使用：

```sh
sh init.sh github your-real-github-name
```

## 不想在本地电脑生成密钥？

可以在服务器上选择菜单 `4`：

1. 生成新的本机 Ed25519 密钥
2. 复制输出的公钥到 GitHub
3. 保存私钥到本地或导入 FinalShell
4. 再运行脚本选择菜单 `1`，从 GitHub 导入公钥并禁用密码登录

注意：

- 公钥可以放 GitHub。
- 私钥不能放 GitHub，也不要发给别人。
- FinalShell 导入的是私钥。
- GitHub 粘贴的是公钥。
- 如果误把私钥粘到 GitHub，GitHub 会报 invalid key，建议重新生成密钥。

菜单 `3` 可以查看本机已有 SSH 密钥。默认只显示公钥和私钥文件路径，不会打印私钥全文；只有输入 `SHOW` 才会显示私钥内容。

命令行兼容模式：

```sh
sh init.sh keys
sh init.sh keygen
```

## 服务器生成密钥

菜单 `2` 会在服务器安全临时目录中生成 Ed25519 密钥对，把公钥写入当前用户的 `authorized_keys`，禁用密码登录，然后打印公钥和私钥。你必须复制保存这段私钥；脚本打印后会删除服务器临时私钥和公钥。

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

如果主配置中包含可用的 drop-in 目录，例如：

```text
Include /etc/ssh/sshd_config.d/*.conf
```

脚本会优先新增或更新：

```text
/etc/ssh/sshd_config.d/00-ssh-init-hardening.conf
```

这样安全配置会在 `01-*`、`50-*` 等云厂商或发行版 drop-in 之前加载，避免被 OpenSSH 的 first obtained value 规则绕过。脚本不会删除用户已有的 drop-in 文件。

脚本会在修改前备份：

```text
/etc/ssh/sshd_config.bak.YYYYmmdd_HHMMSS
~/.ssh/authorized_keys.bak.YYYYmmdd_HHMMSS
```

修改后会先执行 `sshd -t -f /etc/ssh/sshd_config` 做语法校验，再执行 `sshd -T -f /etc/ssh/sshd_config` 检查最终生效配置，确认密码登录确实关闭、公钥登录仍启用。`sshd -T` 可以发现 `Include`、`Match` 等配置导致的最终生效值偏差；如果最终生效配置不符合预期，脚本会恢复备份并停止，不会重启 SSH。

如果全局配置或 `Include` 引入的配置中存在 `AuthenticationMethods publickey,password` 或包含 `keyboard-interactive` 的多因素认证要求，脚本会中止加固。因为脚本会禁用 `password`/`keyboard-interactive`，继续执行可能导致 SSH 无法登录。请先手动改为 `AuthenticationMethods publickey`，或删除该项后重试。

脚本不会自动修改 `Match` 块；如果 `Match` 块里覆盖了 `PasswordAuthentication yes`、`KbdInteractiveAuthentication yes`、`ChallengeResponseAuthentication yes`、`PubkeyAuthentication no` 或 `PermitRootLogin yes`，脚本会输出醒目警告，请确认特定用户或地址仍允许密码登录是否符合预期。

最终校验通过后，脚本会按顺序尝试重启 SSH：

```text
systemctl restart ssh
systemctl restart sshd
service ssh restart
service sshd restart
rc-service ssh restart
rc-service sshd restart
```

Ubuntu 上如果缺少 `/run/sshd`，脚本会自动创建并设置权限为 `755`。

部分 NAT VPS 商家会用 `chattr +i /etc/ssh/sshd_config` 锁定 SSH 配置，防止用户误改端口导致端口转发失效。脚本检测到这种情况时会临时执行 `chattr -i` 解锁，只修改密钥登录相关配置，不会修改 `Port`，完成校验和重启后会尝试恢复 immutable 锁定状态。

## 为什么提示“配置语法通过，但最终生效配置不符合预期”？

很多云服务器会在 `/etc/ssh/sshd_config` 中包含：

```text
Include /etc/ssh/sshd_config.d/*.conf
```

这些 drop-in 文件可能包括：

```text
01-permitrootlogin.conf
50-cloud-init.conf
```

它们可能提前设置：

```text
PermitRootLogin yes
PasswordAuthentication yes
```

OpenSSH 对同一关键字通常采用 first obtained value，所以只在主配置后面追加 `PasswordAuthentication no` 可能不生效。新版脚本会在可用时写入 `/etc/ssh/sshd_config.d/00-ssh-init-hardening.conf`，让安全配置优先加载，并继续通过 `sshd -T` 验证最终生效配置。

如果存在危险配置，例如 `AuthenticationMethods publickey,password` 或 `AuthenticationMethods publickey,keyboard-interactive`，脚本仍会中止，避免禁用密码/键盘交互后把 SSH 登录链路锁死。

执行成功后仍建议不要关闭当前 SSH 窗口，另开新窗口测试密钥登录。

诊断最终生效配置可以运行：

```sh
sh init.sh --debug-effective
```

也可以手动排查：

```sh
sshd_bin="$(command -v sshd || printf /usr/sbin/sshd)"

"$sshd_bin" -T -f /etc/ssh/sshd_config | grep -Ei '^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitemptypasswords|permitrootlogin|authenticationmethods) '

grep -RInE '^[[:space:]]*(Include|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitEmptyPasswords|PermitRootLogin|PubkeyAuthentication|AuthenticationMethods|Match)\b' \
  /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null
```

## 恢复备份

如果登录异常，请通过云厂商 VNC/Console 登录服务器，重新运行脚本并选择菜单 `5`：

```sh
sh init.sh
```

恢复菜单可以恢复最新的 `sshd_config` 备份、最新的 `authorized_keys` 备份，或同时恢复二者。恢复 `sshd_config` 后脚本会再次执行 `sshd -t` 并重启 SSH 服务。

“恢复最新备份”表示恢复到脚本上次修改前的状态。`authorized_keys` 恢复不是清空文件，而是恢复备份文件内容；如果恢复后仍有公钥行，说明备份中本来就有这些公钥。

恢复菜单还提供“清空当前用户 authorized_keys（危险）”选项。这个操作会先创建：

```text
~/.ssh/authorized_keys.before-clear.YYYYmmdd_HHMMSS
```

然后清空当前用户所有 SSH 公钥。执行前必须输入大写 `YES`，不建议在没有 VNC/Console 的情况下使用。

命令行兼容模式：

```sh
sh init.sh restore
```

## 查看状态

菜单 `6` 会显示当前用户、HOME、`.ssh` 权限、`authorized_keys` 状态、`sshd -T` 关键配置和 SSH 服务监听端口。

命令行兼容模式：

```sh
sh init.sh status
sh init.sh --debug-effective
```

## 安全提醒

运行前建议确认云厂商 VNC/Console 可用。脚本执行成功后，请不要立即关闭当前 SSH 窗口，建议另开一个新的 SSH 窗口测试密钥登录是否成功，确认可以用私钥登录后再关闭当前窗口。

不建议使用 `curl | sh` 直接管道执行；推荐像上面的命令一样先下载固定版本脚本，再执行。

## 测试

```sh
sh tests/run.sh
```
