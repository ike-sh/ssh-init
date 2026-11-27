# ssh-init

`ssh-init` 是一个用于 Linux VPS 的 SSH 密钥登录配置脚本。它只做 SSH 公钥导入、服务器生成密钥、禁用密码登录和备份恢复，不包含 BBR、系统更新、Docker、建站、WARP、DD、SSL 等功能。

## 一键使用

最简单的公开使用方式是拉取 `main` 最新版并进入中文交互菜单：

```sh
curl -fsSL https://raw.githubusercontent.com/ike-sh/ssh-init/main/init.sh -o init.sh && sh init.sh
```

这适合普通用户快速使用。运行前建议确认云厂商 VNC/Console 可用，执行后不要立刻关闭当前 SSH 窗口。

## 固定版本/高级用法

如需固定行为、不受 `main` 更新影响，可直接下载正式 Tag `v0.5.8` 对应的脚本：

```sh
curl -fsSL https://raw.githubusercontent.com/ike-sh/ssh-init/v0.5.8/init.sh -o init.sh && sh init.sh
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

GitHub 上保存的是公钥，本地电脑保存的是私钥。脚本只会把有效公钥追加写入当前运行用户的 `~/.ssh/authorized_keys`，不会覆盖已有内容；按公钥类型和密钥主体去重，注释不同也不重复导入。如果旧行有 `from=`、`command=`、`restrict` 等限制，保留原行，不再追加不限权的相同公钥。旧文件末尾没有换行时，脚本会先补换行，确保新公钥独占一行。

下载连接限时 10 秒、总限时 30 秒；空响应、超限、传输失败或没有有效公钥均不修改登录配置。优先使用 curl；wget 回退要求可确认 HTTPS 证书及主机名验证，不接受重定向。仅有不认证证书的 BusyBox 内置 TLS 时，请使用 curl 或 GNU wget。

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

菜单 `2` 会在服务器安全临时目录中生成 Ed25519 密钥对，先打印公钥和私钥。请先将私钥复制保存到本地，再输入大写 `SAVED` 确认。只有确认后，脚本才会把公钥写入当前用户的 `authorized_keys` 并禁用密码登录。

取消、输入其他内容或遇到输入结束时，不会修改 `authorized_keys` 或 SSH 登录配置，临时密钥会被清理。`SSH_INIT_ASSUME_YES=1` 只能跳过最初的执行确认，不能跳过 `SAVED` 私钥保存确认。保存确认不等同于实际登录验证，操作后仍须另开窗口测试。

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

GitHub 和 `gen` 都在同一笔写事务内安装公钥并应用加固。默认全局策略如下：

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

**原有 root 限制不会静默放宽。** 如果全局 `PermitRootLogin` 已为 `no` 或 `forced-commands-only`，默认保留；仅在单独的提示中输入 `ROOT` 才允许改成 `prohibit-password`。`SSH_INIT_ASSUME_YES=1` 不代表同意放宽。若能确定目标 root 的有效策略仍不允许普通密钥会话，操作会中止。脚本不改写 `Match`、`AllowUsers`、`DenyUsers`、组规则或外部密钥命令。

脚本分三步作静态判断：

1. 写入前读取现有配置和目标账号上下文；递归检查 `Include` 及 `Match`，识别授权文件、签名算法和认证链的明确冲突。`AuthorizedKeysFile` 按目标 HOME 解释相对路径，并展开 `%h`、`%u`、`%U` 和 `%%`。脚本不向不匹配的自定义目录擅自写入公钥。
2. 写入后、服务应用前用 `sshd -t -f` 校验语法，`sshd -T -f` 检查全局结果，`sshd -T -C … -f` 检查目标用户。在已有 SSH 会话中采用可用的 `SSH_CONNECTION` 来源 IP、本机 IP 和端口；在控制台不会用虚构的远端地址冒充真实连接。不会执行 `AuthorizedKeysCommand`。多条 `AuthenticationMethods` 替代路径不等于每条都必须满足。
3. 发现确定冲突即停止或回滚。外部密钥、客户端持有的其他凭据、DNS、未采样来源和复杂条件可能无法静态确定，提示后需分别验证。**这些检查不是 SSH 登录测试**；请保留当前连接，用另一终端从预期来源实测。

服务应用使用预先记录的服务名和运行状态，优先 reload。systemd 仅在能确认不会按控制组停止已有会话时回退 `try-restart`；SysV / OpenRC 的自定义停止脚本语义不可知，reload 失败不会盲目 restart。Ubuntu 的 socket activation 不会被关闭，原本休眠的服务不被强行拉起。脚本不修改端口、监听地址或防火墙。如果服务管理器不可查询，或文件/服务回滚失败，会明确报错，不宣称恢复成功。

NAT VPS 上原本带 `chattr +i` 的操作目标在快照完成后才临时解锁；提交和回滚都处理原始 immutable 状态。文件系统不支持 `lsattr` 时不会假定能解锁；实际写入失败会中止；探测本身出现 I/O 错误也会中止。快照记录 Linux 的 mode、UID、GID 与文件内容，能保留 xattr 的 GNU cp 会显式复制扩展属性；仅提供基础 `cp -p` 的环境不保证自定义 ACL/xattr 的完整往返。托管写入路径不能是符号链接。

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

如果目标用户所有可用认证链都与禁用密码/键盘交互冲突，会中止操作；仅其他用户的条件链或仍有 `publickey` 替代路径时，不会仅因扫描到了 `password` 字样就中止。

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

恢复子菜单 1/2 分别恢复配置（含对应托管 drop-in）或公钥；菜单 3 只选同时记录两项的**同一批次**。备份原来不存在的文件会恢复为“不存在”，并非恢复为空文件。清空授权文件仍需大写 `YES`，可能导致无法远程登录。

- 默认状态目录是 `/etc/ssh/sshd_config.ssh-init.d/`（随 `SSH_CONFIG` 路径变化），仅运行账户可访问。`batch.000000000001` 等目录保存同一操作前的快照：`*.path`、`*.meta`（存在状态或 mode、UID、GID、immutable）及 `*.data`。只在内容、存在性或必要元数据发生变化时保留批次，不自动清理历史备份。恢复本身若改变文件，也留下可撤销的批次。
- v0.5.7 及更早的相邻 `.bak.*` 等备份保持不动。旧格式没有可靠批次标识；同时恢复只提供相同时间戳的候选，并明确提示仍不能证明它们同源。无法配对时选单项恢复，不拼接各自最新文件。
- 写操作互斥；只读状态、诊断和帮助不取写锁。有 `flock` 时先取内核锁；两条路径共用同一个原子发布的持有者标记，不会因有的进程缺少 `flock` 而失去互斥。不要删除活动锁。若 PID 已被复用、无法读取 `/proc`，或清理死锁的进程本身也被强杀，则保守拒绝写入。请在 Console 先核实进程和 `lock` 指向的持有者目录；**不要删除 `pending` 快照**。
- 捕获 HUP、INT、TERM 时尝试回滚；SIGKILL、断电或失败的回滚可能留下 `pending/active`。先保留该目录，通过 Console 查看 `*.path` 及对应文件。再次选择写操作时，只有输入 `RECOVER` 才会用快照恢复并退出本次操作；若中断后已人工编辑，请先另存这些改动。恢复后重新运行原命令。磁盘损坏、权限错误和外部服务变化不能由脚本保证修复。写锁只协调 ssh-init，操作期间不要同时用编辑器或其他配置管理工具写同一文件。

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
for suite in tests/*-v058.sh; do sh "$suite" || exit 1; done
```

单元测试在专用临时目录中运行，默认阻止真实网络请求和服务管理命令。回归用例覆盖末尾换行、私钥保存确认、Include/Match 扫描与跨文件恢复失败。

Linux 上安装 OpenSSH server 后，还可以运行：

```sh
sh tests/integration.sh
```

该脚本使用临时主机密钥和配置，调用真实 `sshd -t` / `sshd -T -C`，不启动监听端口、不重启系统服务。部分发行版要求预先存在 `/run/sshd`。CI 单独运行这组检查；非 Linux 环境会明确跳过。它仍不能代替目标 VPS 上的新会话登录验证。

当前版本的隔离测试记录、未验证范围以及前一版本的历史结果见 [TEST_RESULTS.md](./TEST_RESULTS.md)。`tests/remote-sandbox.sh` 仅供已准备好安全临时目录和备用 sshd 的测试驱动调用，不要用它操作生产配置或 22 端口监听进程。
