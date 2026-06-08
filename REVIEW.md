# ssh-init 代码审查报告

**审查日期**：2026-06-08  
**审查范围**：`init.sh`（约 2000 行）、`tests/run.sh`（80+ 用例）、`README.md`  
**审查角色**：资深全栈架构师

---

## 1. 总体结论

`ssh-init` 是一个结构清晰、安全意识较强的 POSIX shell SSH 初始化脚本。代码具备：

- 完整的备份 / 回滚 / 原子写入机制
- `sshd -t` 语法校验 + `sshd -T` 最终生效配置校验
- drop-in 目录优先加载策略（`00-ssh-init-hardening.conf`）
- immutable 文件（`chattr +i`）检测与恢复
- 较完善的单元测试（mock sshd、systemctl、chattr 等）

**孤立代码**：未发现明显死代码。所有函数均在主流程或测试中被调用。`IKE_TEST_*` 变量为测试钩子，属有意设计。

**测试执行**：当前 Windows 环境 WSL 不可用，未能实际运行 `sh tests/run.sh`；结论基于静态分析与测试用例审查。

---

## 2. 已发现并修复的问题

### 2.1 【严重】恢复菜单不处理 drop-in 文件

**问题**：`harden_ssh_config` 在存在 `sshd_config.d` 时会写入 `00-ssh-init-hardening.conf`，但 `restore_sshd_config_from_backup` 仅恢复主配置 `sshd_config`，不处理 drop-in。

**后果**：用户选择「恢复最新 sshd_config 备份」后，主配置虽恢复，但 `00-ssh-init-hardening.conf` 仍保持加固状态，密码登录实际上未被恢复。

**修复**（已实现）：

- 新增 `latest_dropin_backup`、`is_managed_ssh_init_dropin`、`restore_sshd_dropin_from_backup_or_remove`
- 恢复主配置后：有 drop-in 备份则恢复；无备份但存在 ssh-init 托管 drop-in 则删除
- `list_backups` 增加 drop-in 备份列表

### 2.2 【中等】wget 拉取 GitHub 公钥无超时

**问题**：`curl` 使用 `--connect-timeout 10`，`wget` 无超时参数，可能无限挂起。

**修复**（已实现）：`wget -qO- --timeout=10`

### 2.3 【中等】Match 块内 AuthenticationMethods 未检测

**问题**：`config_file_authentication_methods_risk` 跳过 `Match` 块（`!in_match`），导致 `Match User admin` + `AuthenticationMethods publickey,password` 不被拦截。

**后果**：全局禁用 password 后，特定用户的 MFA 要求可能导致该用户无法登录。

**修复**（已实现）：移除 `!in_match` 限制，全局与 Match 块均检测。

---

## 3. 仍存在的低风险 / 设计取舍

| 编号 | 类型 | 描述 | 建议 |
|------|------|------|------|
| L1 | 设计 | `gen_mode` 在终端打印私钥后删除服务器副本 | 已有警告，保持现状 |
| L2 | 设计 | `Match` 块内 `PasswordAuthentication yes` 仅警告不修改 | 符合 README 说明 |
| L3 | 边界 | Include 递归扫描深度限制为 3 层 | 极深嵌套可能漏检 |
| L4 | 边界 | `sshd_dropin_dir_from_config` 只取第一个 `sshd_config.d` | 非标准多 drop-in 目录场景 |
| L5 | 一致性 | `gen_mode` 临时公钥 chmod 600，`keygen` 为 644 | 不影响安全，可统一 |
| L6 | 去重 | 公钥去重对 comment 不敏感，同 key 不同注释可能重复写入 | 影响极小 |
| L7 | UX | 菜单 1/2 成功后直接退出交互循环 | 需重新运行脚本才能继续操作 |
| L8 | 恢复 | 选项 3「同时恢复」若第二步失败，第一步已生效 | 建议后续加重试或原子恢复 |

---

## 4. 安全机制评估

### 4.1 做得好的地方

```
用户确认 → 备份 → 解锁 immutable → 原子写入 → sshd -t → sshd -T → 重启 → 失败回滚 → 重锁 immutable
```

- symlink 路径检测（`~/.ssh`、`authorized_keys`、HOME）
- 公钥格式校验（类型白名单 + base64 + 可选 `ssh-keygen -l`）
- `AuthenticationMethods` 多因素认证前置拦截
- drop-in `00-` 前缀确保优先于 `50-cloud-init.conf` 等

### 4.2 有效配置校验逻辑

`effective_sshd_settings_check` 通过 `sshd -T` 验证最终值，能发现 Include / drop-in 覆盖问题。仅在校验**存在**的键时比较期望值，未出现的键不强制 — 合理，因 OpenSSH 有默认值。

---

## 5. 函数调用关系（无孤立代码）

| 模块 | 核心函数 | 状态 |
|------|----------|------|
| 密钥管理 | `prepare_authorized_keys`, `append_keys_to_authorized_keys`, `generate_local_key_only` | 活跃 |
| GitHub 导入 | `fetch_github_keys`, `filter_valid_keys`, `github_mode` | 活跃 |
| SSH 加固 | `harden_ssh_config`, `write_hardened_sshd_config`, `write_sshd_hardening_dropin` | 活跃 |
| 风险检测 | `detect_authentication_methods_risk`, `detect_match_override_risk` | 活跃 |
| 恢复 | `restore_sshd_config_from_backup`, `restore_sshd_dropin_from_backup_or_remove` | 活跃（已增强） |
| 诊断 | `debug_effective_config`, `show_status` | 活跃 |
| 测试钩子 | `IKE_TEST_USER`, `IKE_TEST_HOME`, `IKE_TEST_SYMLINK_PATH` | 仅测试模式 |

---

## 6. 新增测试用例

| 测试名 | 验证点 |
|--------|--------|
| `test_restore_sshd_restores_existing_dropin_backup` | 恢复主配置时同步恢复 drop-in 备份 |
| `test_restore_sshd_removes_new_managed_dropin` | 无 drop-in 备份时删除 ssh-init 创建的托管文件 |
| `test_match_authentication_methods_blocks_hardening` | Match 块内危险 AuthenticationMethods 拦截加固 |
| `test_list_backups_includes_dropin` | 恢复菜单列表展示 drop-in 备份 |

---

## 7. 第二轮低风险修复（已完成）

| 项目 | 修复内容 |
|------|----------|
| BusyBox wget | 检测 `--timeout` 支持，不支持时回退 `-T 10` |
| 恢复原子性 | 新增 `restore_sshd_and_authorized_keys_from_backups`，选项 3 任一步失败则回滚 |
| 公钥 chmod | `gen_mode` 临时公钥改为 644，与 `keygen` 一致 |

## 8. 建议后续改进（非必须）

1. **CI 集成**：在 Linux runner 上自动执行 `sh tests/run.sh`
2. **BusyBox wget 检测**：当前通过 `wget --help` 探测，可补充 Alpine 容器实测

---

## 9. 审查结论

| 维度 | 评级 | 说明 |
|------|------|------|
| 功能完整性 | ★★★★☆ | 核心流程完备，drop-in 恢复缺口已修复 |
| 安全性 | ★★★★★ | 多层校验 + 回滚，安全意识强 |
| 代码质量 | ★★★★☆ | POSIX sh 规范，函数职责清晰 |
| 测试覆盖 | ★★★★☆ | 80+ 用例，新增 drop-in 恢复场景 |
| 孤立代码 | ★★★★★ | 无明显死代码 |

**综合评定**：生产可用。修复 drop-in 恢复逻辑后，恢复菜单与加固流程形成闭环。
