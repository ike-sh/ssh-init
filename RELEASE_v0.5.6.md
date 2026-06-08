# ssh-init v0.5.6 发布公告

**发布日期**：2026-06-08  
**仓库**：https://github.com/ike-sh/ssh-init  
**标签**：v0.5.6

---

## 一句话总结

修复了恢复 `sshd_config` 后 drop-in 加固文件仍生效导致「假恢复」的问题，并增强了若干边界场景的安全性。

## 为什么要升级

如果你在使用 `Include /etc/ssh/sshd_config.d/*.conf` 的服务器（云厂商常见配置）上运行过 ssh-init，旧版「恢复 sshd_config 备份」可能**看起来恢复了，但密码登录实际上仍被禁用**——因为 `00-ssh-init-hardening.conf` 没有被同步处理。v0.5.6 已修复。

## 主要变更

### 修复
- 恢复 `sshd_config` 时同步恢复或移除 `00-ssh-init-hardening.conf`
- 「同时恢复」选项在 `authorized_keys` 失败时自动回滚 `sshd_config`
- `wget` 拉取 GitHub 公钥增加超时（兼容 BusyBox）
- `Match` 块内的危险 `AuthenticationMethods` 也会阻止加固

### 新增
- GitHub Actions 自动测试（75 项）
- 代码审查报告 `REVIEW.md`
- `CHANGELOG.md`

## 安装 / 升级

```sh
curl -fsSL https://raw.githubusercontent.com/ike-sh/ssh-init/v0.5.6/init.sh -o init.sh && sh init.sh
```

## 验证

```sh
sh tests/run.sh   # 预期：75 test(s) passed
```

## 升级建议

- 生产环境建议固定 tag `v0.5.6`，不要使用 `main` 浮动版本
- 升级前确认云厂商 VNC/Console 可用
- 升级后新开终端测试密钥登录，不要关闭当前会话

---

**完整变更日志**：[CHANGELOG.md](./CHANGELOG.md)
