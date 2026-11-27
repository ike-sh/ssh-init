# SSH 初始化修复验证记录

## v0.5.8 发布前验证

- 基线：上游 `main` / `v0.5.7`，提交 `0190da5370396c39f9d1fdbc4ead041a1b9a0976`。下述本地测试在发布前完成；其验证对象由脚本 SHA-256 标识。
- `init.sh` SHA-256：`8b484941f673e675fc88be2a17cb308df0db1d4bea4fe20e4c892fabedd7ed77`。校验命令：`sha256sum -c SHA256SUMS`。
- WSL2 Ubuntu 上另用真实 Linux 文件验证了中断恢复：在专属临时文件设置 `0640`、`user.ssh_init_test` 扩展属性和 `chattr +i`，事务替换文件后向事务进程发送 TERM。实际退出 143，内容、权限、xattr 与 immutable 均恢复，`pending` 已清理。服务接口为测试桩，不调用宿主服务。

### 隔离 Linux 矩阵

使用官方 amd64 用户空间，各自在新的 mount、PID 和网络命名空间运行；使用私有只读 `/proc`、临时主机密钥和夹具配置，不连接宿主的 SSH 或服务管理器。三者共用 WSL2 内核，不是三台独立内核的 VPS。

| 用户空间 | Shell / OpenSSH / ShellCheck | `sh -n` / ShellCheck | 原有回归 | v0.5.8 独立回归 | 真实 OpenSSH 配置检查 |
|---|---|---|---:|---:|---:|
| Debian 12.15 | dash 0.5.12 / 9.2p1 / 0.9.0 | 通过 / 通过 | 115/115 | 82/82 | 7/7 |
| Ubuntu 24.04.5 | dash 0.5.12 / 9.6p1 / 0.9.0 | 通过 / 通过 | 115/115 | 82/82 | 7/7 |
| Alpine 3.22.8 | BusyBox ash 1.37.0 / 10.0p2 / 0.10.0 | 通过 / 通过 | 115/115 | 82/82 | 7/7 |

每套系统的 82 项独立回归为：认证 37、服务管理 17、密钥与下载 8、事务及中断 14、备份批次 6。包括外部认证仅警示、严格 root 的保留/明确放宽、带选项公钥去重、原文件不存在、服务恢复也失败时保留快照、SIGKILL 后确认恢复，以及两种写锁路径。实际执行：

```sh
for script in init.sh tests/*.sh tests/fixtures/*.sh; do sh -n "$script" || exit 1; done
shellcheck -x -e SC2034,SC2086,SC2012 init.sh tests/*.sh tests/fixtures/*.sh
sh tests/run.sh
for suite in auth service keys txn batch; do sh "tests/$suite-v058.sh" || exit 1; done
sh tests/integration.sh
```

各命令在三套系统均退出 0；另在 Windows 上用 ShellCheck 0.11.0 检查了同一组脚本。本文记录的是发布前本地测试，不含 GitHub Actions 的结果；远端 CI 请查看对应发布提交的 [Actions 运行记录](https://github.com/ike-sh/ssh-init/actions/workflows/test.yml)。Linux 冻结脚本清单 SHA-256：`2e754caa9e9d65cd3829db072d976509bafabb2343bfbd087af01eb08e1f9406`。

### 独立 Debian sshd：真实认证 13/13

使用新的根文件系统和网络命名空间。专属监听器只绑定该命名空间的 `127.0.0.1:24381`，客户端固定校验临时主机密钥。成功断言须执行远程命令并验证输出；拒绝断言须同时得到退出码 255 和 `Permission denied`，不把网络故障算作拒绝认证。

| 阶段 | 实测 |
|---|---|
| 初始 | 旧密钥 A 和临时密码可登录，新密钥 B 被拒 |
| 单独追加 B，再撤销追加 | 追加后 B 可登录；撤销后 B 被拒 |
| 加固并导入 B | A、B 均可登录，原密码被拒 |
| 尝试恢复无效配置 | B 仍可登录，原密码仍被拒 |
| 恢复原批次 | A 和原密码可登录，B 被拒；主配置与授权文件逐字节恢复，新建的托管 drop-in 已移除 |

五次操作、十三次认证断言全部通过。两次 HUP 均发给已通过 PID 和配置路径核验的临时 sshd。专属监听器、实际密码、临时密钥和测试根克隆均已清理。

### 本轮验证边界

- 真实网络登录只在隔离 Debian 实例测试；Ubuntu / Alpine 的 7 项是配置解析，不是登录。发行版 systemd、OpenRC、SysV 和 socket 的异常路径用测试桩覆盖，未在正在管理宿主 SSH 的服务管理器上破坏性测试。
- GitHub 下载的 HTTP 错误、限时、证书验证能力判断及部分响应使用隔离夹具；未将访问公网 GitHub 计为成功测试。未模拟物理断电或损坏文件系统；SIGKILL、回滚失败和显式 `RECOVER` 路径有实际进程测试。
- 研发首轮 Alpine 夹具未模拟新的服务状态探测，按预期在写入前被拒；补齐隔离服务探测、应用及回滚接口后重新执行全矩阵。测试未改变生产服务发现规则来规避断言。

## 历史记录：v0.5.7（非本轮结果）

验证日期：2026-09-06。

本记录对应 v0.5.7 发布的 `init.sh`，SHA-256：

```text
041dbd4100976fb44c5bac0461f7bd1094fc35bda42f99486931f308f4e90f92
```

## Docker 验证

使用只读项目挂载和专属 `--rm` 临时容器，不修改宿主 SSH 配置，不操作其他项目容器。

| 环境 | OpenSSH | ShellCheck | 单元测试 | 真实 OpenSSH 配置检查 |
|---|---|---|---|---|
| Ubuntu 24.04.4 LTS | 9.6p1 Ubuntu-3ubuntu13.19 | 0.9.0：通过 | 115 通过 | 4 通过 |
| Alpine 3.22.5 | 10.0p2 | 0.10.0：通过 | 115 通过 | 4 通过 |

两组命令均退出 0，测试容器均已自动删除。实际执行 ShellCheck、`sh tests/run.sh` 和 `sh tests/integration.sh`。

兼容性修正：部分旧版 ShellCheck 将测试中间接调用的 mock 标记为 SC2317，新版标记为 SC2329。仅在相关测试 mock 上局部说明并排除这两个提示，未扩大生产代码的检查排除项。远端测试辅助脚本的路径检查也改为显式条件分支，避免旧版本的 SC2015 提示；完整脚本集合再次通过 ShellCheck 0.9.0 和 0.10.0。

Alpine 构建未启用 PAM，配置夹具中的 `UsePAM no` 会产生非致命提示；全部断言仍实际执行并通过。配置检查不启动 SSH 监听，也不调用真实服务管理器。

## 内网服务器端到端验证

通过一台已授权测试服务器的 22 端口建立控制连接，服务器地址及凭据不公开。系统为 Debian GNU/Linux 13.6，OpenSSH 为 `10.0p2 Debian-7+deb13u4`。

在规范化、root 所有的 `/run/ssh-init-e2e.*` 临时目录中启动独立 sshd，仅监听 `127.0.0.1` 的临时高端口；通过原有 22 端口的 SSH 通道连接。使用临时主机密钥和授权文件，真实执行 chmod/chown，并保持 `StrictModes yes`。服务重载仅向已核对命令行与可执行文件的测试 sshd PID 发送 HUP。

以下 12 项均通过：

1. 基线公钥登录和正确密码登录均成功。
2. 将旧授权行的末尾换行移除后追加新公钥，新旧两把密钥都可真实登录。
3. 加固并重载后，新密钥可登录；密码和 keyboard-interactive 不再可用。
4. 无效配置恢复被拒绝，主配置、drop-in、授权文件保持失败前状态，密钥仍可登录。
5. 同时恢复配置和授权备份后，密码及旧密钥可登录，新导入密钥被拒绝。
6. 取消 `gen` 时，配置和授权文件均不变。
7. `SAVED` 确认前，密码仍可用，已交付的新密钥尚未授权。
8. `SAVED` 确认后，使用交付的私钥登录成功，密码被禁用。
9. 生成模式的服务器临时私钥已删除。
10. 恢复生成模式之前的备份后，密码重新可用，生成密钥不再获准登录。
11. 原有 SSH 主配置、drop-in、root `authorized_keys` 的内容和相关元数据，以及 22 端口监听进程，与测试前一致。
12. 新建至原有 22 端口的密码连接仍成功。

最终临时 sshd 与对应目录已清理。没有更改原有服务器密码、22 端口配置或防火墙；密码及生成私钥没有写入项目或测试报告。

## 测试边界与首次失败

首轮夹具使用 `/tmp/ssh-init-e2e.*` 放置授权文件，真实 sshd 明确报 `bad ownership or modes for directory /tmp`，因此基线登录失败。该次测试退出后已清理，并确认生产连接未受影响。将夹具迁至权限安全的 `/run` 后，在不关闭 `StrictModes` 的情况下完成全部端到端验证。

端到端夹具使用 `UsePAM no`，并仅在临时 sshd 中关闭来源惩罚，避免预期的拒绝登录测试影响后续 loopback 用例；没有变更生产服务的这些策略。结果不等于已覆盖任意发行版 PAM、所有用户/地址 Match 组合或生产环境网络故障。远端辅助脚本是 `tests/remote-sandbox.sh`，不是直接用于修改生产 SSH 服务的入口。
