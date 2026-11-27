# ssh-init v0.5.8

本版解决一个可能锁住用户的问题：公钥已经写入，不代表 `sshd` 会在该用户、该来源和该认证策略下接受它；配置应用失败也不应留下刚导入的公钥。

## 行为变化

- **先判定，再提交。** 读取目标用户在 `sshd -T -C` 下的配置，检查授权文件路径、密钥签名算法、认证链和用户/组访问限制，同时保留 `-t` 与全局 `-T` 检查。未知来源、外部密钥命令及客户端因子只能提示，不能替用户证明能登录。
- **公钥和 SSH 加固一起成功或一起回滚。** 授权文件按类型和主体去重并原子替换；不会用无限制副本绕过已有 `from=`、`command=` 等选项。回滚涵盖主配置、托管 drop-in、相关文件与 `.ssh` 目录的存在性、权限、所有者及原 immutable 状态。只有尝试过服务操作才需要重新协调原服务状态。
- **并发和中断。** 写锁不影响状态、帮助。捕获的中断尽可能回滚；SIGKILL、断电或回滚失败后，保留私有恢复日志。再次写入时，须确认 `RECOVER` 才回放日志；请先核对中断后有无人工更改。
- **批次恢复。** 默认在 `/etc/ssh/sshd_config.ssh-init.d` 保存发生实际变化的备份批次。“同时恢复”不再各取最新。旧相邻备份保留，只有时间戳而没有批次证明的旧备份会单独提示。
- **保留原策略。** 仅在单独输入 `ROOT` 后才放宽已存在的严格全局 root 策略；不改用户的 Match 或 Allow/Deny 策略。`gen` 仍须明确输入 `SAVED`。GitHub 请求有总限时，不能确认 TLS 验证的 wget 不降级使用。
- **优先 reload。** 不关闭 socket activation；不盲试不存在的服务，也不为强行 restart 而结束已有会话。服务状态不确定或不能安全应用时报告失败。

## 升级与验证

从本 Release 下载 `init.sh` 和 `SHA256SUMS` 到同一目录，运行 `sha256sum -c SHA256SUMS`；看到 `init.sh: OK` 后再执行 `sh init.sh`。

`init.sh` SHA-256：`8b484941f673e675fc88be2a17cb308df0db1d4bea4fe20e4c892fabedd7ed77`。

实际运行的测试、系统版本和未验证范围见 [TEST_RESULTS.md](https://github.com/ike-sh/ssh-init/blob/v0.5.8/TEST_RESULTS.md)。实机操作前确认云控制台可用，保留原 SSH 会话；从预期来源用自己的私钥另开窗口验证。详细恢复说明见 [README.md](https://github.com/ike-sh/ssh-init/blob/v0.5.8/README.md#恢复备份)。
