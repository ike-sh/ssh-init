# ssh-init v0.5.7

发布日期：2026-09-06。

本版本修复 SSH 密钥追加、密钥交付、Include 扫描与备份恢复中的安全边界问题，并补充多发行版和真实 SSH 登录验证。

## 升级注意

`gen` 模式现在先显示公私钥，必须保存私钥并输入大写 `SAVED` 后，才会修改授权文件和禁用密码登录。`SSH_INIT_ASSUME_YES=1` 不能跳过保存确认；已有无人值守生成流程需要调整交互。取消、EOF 或密钥输出失败时不会修改登录配置。

## 主要修复

- 已有 `authorized_keys` 末尾没有换行时，追加新密钥前补换行，避免新旧公钥粘行。
- 递归扫描全局和 `Match` 内的 `Include`，隔离递归状态及临时文件，避免跳过后续引用；兼容关键字与参数之间的等号写法。
- 无法可靠读取、展开或解析配置时停止加固，而不是继续操作。
- 恢复失败时按操作前快照回滚主配置、drop-in 及相关授权文件，并保留原先不存在的状态。
- 临时目录由父 shell 管理，避免命令替换产生无法清理的目录。

## 验证

- Windows/Git sh：115 项单元测试通过。
- Docker Ubuntu 24.04 与 Alpine 3.22：各 115 项单元测试、4 项真实 OpenSSH 配置检查通过。
- Debian 13 独立 loopback sshd：12 项端到端检查通过，包括密钥登录、禁密码、失败回滚、备份恢复与 `SAVED` 确认前后的实际登录行为。
- ShellCheck 0.9.0、0.10.0、0.11.0 验证通过；新增 Linux/OpenSSH CI 作业。

完整记录：[TEST_RESULTS.md](https://github.com/ike-sh/ssh-init/blob/v0.5.7/TEST_RESULTS.md)。这些测试不代替目标服务器上的新会话登录验证，也不代表覆盖了所有 PAM 或 Match 策略。

## 安装

```sh
curl -fsSL https://raw.githubusercontent.com/ike-sh/ssh-init/v0.5.7/init.sh -o init.sh
sh init.sh
```

Release 附件提供 `init.sh` 与 `SHA256SUMS`。下载二者后可运行 `sha256sum -c SHA256SUMS` 核对文件完整性。

操作前确认云厂商 VNC/Console 可用，保留当前 SSH 窗口；另开新窗口确认密钥登录成功后再关闭旧会话。此版本仍会保留 `Match` 块，并对危险覆盖进行提示；复杂策略需使用带连接参数的 `sshd -T -C` 单独检查。

完整变更：[v0.5.6...v0.5.7](https://github.com/ike-sh/ssh-init/compare/v0.5.6...v0.5.7)。
