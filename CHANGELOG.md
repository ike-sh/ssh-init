# Changelog

本文件记录 [ssh-init](https://github.com/ike-sh/ssh-init) 的版本变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [v0.5.7] - 2026-09-06

### 升级注意

- `gen` 的安全确认交互已改变：必须先保存私钥并输入大写 `SAVED`，才会写入授权文件并禁用密码登录。`SSH_INIT_ASSUME_YES=1` 不再能跳过这一步；使用无人值守生成流程的用户需要调整交互。

### 修复

- 追加公钥前处理已有 `authorized_keys` 末尾缺少换行的情况，避免新密钥粘入旧行。
- `gen` 模式先交付密钥并要求输入 `SAVED` 确认保存，再修改授权与 SSH 配置；自动确认变量不能跳过保存确认。
- 递归扫描 `Match` 内的 `Include`，隔离递归状态并使用唯一临时文件，避免引用文件漏扫。
- 恢复失败时同时回滚主配置、受影响 drop-in 和可选授权文件，保留原先不存在的状态。
- 临时目录在父 shell 初始化，避免命令替换产生无法清理的目录。

### 测试与文档

- 新增上述缺陷的回归测试；隔离单元测试的网络和服务命令，修正 BusyBox wget 用例误走 curl 的问题。
- 本轮新增 40 条回归断言，完整单元测试在 Windows/Git sh 下实测 115 条通过；ShellCheck 与语法检查通过。
- Docker 复验：Ubuntu 24.04 和 Alpine 3.22 均通过 115 条单元测试、4 项真实 OpenSSH 配置检查及各发行版 ShellCheck；局部兼容旧版 ShellCheck 的测试 mock 提示。
- 新增受严格路径和 PID 校验保护的远端沙箱辅助脚本，并在 Debian 13 独立 loopback sshd 上通过 12 项真实登录、禁密码、恢复及私钥交付检查；原有 22 端口服务保持不变。详见 `TEST_RESULTS.md`。
- 新增真实 OpenSSH 配置解析集成检查与独立 CI 作业，不启动或重启系统 SSH 服务。
- 更正 `sshd -T` 对 `Match` 条件的验证范围和生成密钥的交付说明。

## [v0.5.6] - 2026-06-08

### 修复

- **恢复逻辑**：恢复 `sshd_config` 时同步处理 `00-ssh-init-hardening.conf` drop-in 文件——有备份则恢复，无备份的 ssh-init 托管文件则删除，避免主配置恢复后仍被 drop-in 保持加固状态
- **恢复原子性**：菜单选项 3「同时恢复」在 `authorized_keys` 恢复失败时自动回滚 `sshd_config`
- **wget 超时**：GitHub 公钥拉取增加超时；GNU wget 使用 `--timeout=10`，BusyBox wget 回退 `-T 10`
- **Match 块检测**：`Match` 块内的危险 `AuthenticationMethods`（含 `password` / `keyboard-interactive`）现在也会阻止加固

### 变更

- `gen` 模式临时公钥文件权限由 600 改为 644，与 `keygen` 菜单一致

### 新增

- 恢复菜单备份列表展示 SSH drop-in 备份
- GitHub Actions CI：push/PR 时自动执行 shellcheck + 75 项测试
- `REVIEW.md` 代码审查报告

### 测试

- 新增 7 项测试覆盖 drop-in 恢复、Match AuthenticationMethods、BusyBox wget、双恢复回滚、公钥权限

**固定版本安装：**

```sh
curl -fsSL https://raw.githubusercontent.com/ike-sh/ssh-init/v0.5.6/init.sh -o init.sh && sh init.sh
```

## [v0.5.5] - 2026-04

- drop-in 目录加固策略（`00-ssh-init-hardening.conf`）
- `sshd -T` 最终生效配置校验

## [v0.5.2] - 2026-04

- 本机 Ed25519 密钥生成菜单
- GitHub 公钥导入教程与占位符检测

[v0.5.7]: https://github.com/ike-sh/ssh-init/compare/v0.5.6...v0.5.7
[v0.5.6]: https://github.com/ike-sh/ssh-init/compare/v0.5.5...v0.5.6
[v0.5.5]: https://github.com/ike-sh/ssh-init/compare/v0.5.4...v0.5.5
[v0.5.2]: https://github.com/ike-sh/ssh-init/compare/v0.5.1...v0.5.2
