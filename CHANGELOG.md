# Changelog

本文件记录 [ssh-init](https://github.com/ike-sh/ssh-init) 的版本变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

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

[v0.5.6]: https://github.com/ike-sh/ssh-init/compare/v0.5.5...v0.5.6
[v0.5.5]: https://github.com/ike-sh/ssh-init/compare/v0.5.4...v0.5.5
[v0.5.2]: https://github.com/ike-sh/ssh-init/compare/v0.5.1...v0.5.2
