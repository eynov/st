# sb 开发交接

本文档是 sb 当前开发阶段、阻断项和下一步工作的唯一事实来源。稳定的用户说明见
[`../README.md`](../README.md)，完整修复证据见
[`FINAL_REVIEW_PACK.md`](FINAL_REVIEW_PACK.md)。

## 当前 Git 状态

Development Snapshot 建立于 2026-07-25：

- 分支：`main...origin/main`
- 快照提交：`53acf0835e922ead26315ead3d1d81df11d910ad`
- `HEAD` 与 `origin/main` 相同
- sb 生产化升级、测试、元数据和 Documentation Baseline 已作为同一自洽快照提交
- `sb/instances.json` 和 `sb/protocols/xxxx.txt` 的预期删除已纳入快照
- 快照推送后工作树 clean，分支与 Gitea `origin/main` 同步

开始新任务时必须重新执行 `AGENTS.md` 指定的 Git 检查；本节不是永久不变的仓库
状态快照。

## 当前开发阶段

**Repository Production Candidate — Not Production Ready**

代码已完成第一轮生产化实现和修复，但最终独立只读复审发现两个尚未修复的 High。
不得依据 `FINAL_REVIEW_PACK.md` 中较早的 “High 0” 结论宣布通过。该文件保留当轮
修复证据；当前准入结论以本交接文档及后续独立复审为准。

## 已完成内容

- 程序、settings、state、generation、证书、输出与备份目录分离
- state/settings schema、派生输出和旧 `/opt/sb` 数据迁移框架
- 全局锁、候选 generation、备份、service 验收和整体 rollback 的事务框架
- endpoint/listen settings 事务化与非全局地址校验框架
- 原子候选备份与 restore 数据恢复流程
- SS、SS2022、AnyTLS、VLESS Reality、HY2 服务端及客户端输出矩阵
- HY2 显式 Port Hopping 与外部防火墙责任提示
- trusted、provided、self-signed、explicit insecure TLS 模式
- SS2022 SIP002 URI 与 HY2 certificate fingerprint 契约
- 固定 sing-box `1.13.14`、架构映射、archive/binary digest 和 receipt
- 零节点 enabled/stopped 策略及 systemd unit
- 隔离测试、真实 sing-box/Hysteria/ssurl 测试入口和 mock systemd 故障注入

## 当前阻断

最新独立只读复审结论：

```text
Critical: 0
High: 2
Medium: 4
```

### High 1：current generation 链接切换未可靠传播失败

证据位置：

- `sb/core/transaction.sh:45-49`：`transaction_restore_link`
- `sb/core/transaction.sh:124-127`：候选 generation 发布

`ln -s`、`mv -fT` 等关键步骤没有逐项显式检查。在函数被条件调用的 Shell 上下文中，
不能依赖 `set -e`；故障注入曾观察到 current 链接切换失败却返回成功，或 rollback
失败后 state/current 与运行服务漂移。

### High 2：manager app 链接切换未可靠传播失败

证据位置：

- `sb/core/manager.sh:66-71`：release 发布与第一次 rollback
- `sb/core/manager.sh:79-94`：下游失败 rollback 与 CLI link

`.app.new` 的创建和 `mv -fT` 切换没有逐项显式检查。故障注入曾观察到 app 链接没有
切换、失败 release 被保留，但命令仍返回 0 并打印安装成功。

### 相关 Medium

1. `sb/tests/fixtures/mock-systemctl:37-43` 仍从 current generation 的预期 manifest
   生成 runtime socket 表，监听测试存在循环证明。
2. `sb/core/common.sh` 的 IPv6 global-unicast 判定仍接受部分保留或非公网范围，例如
   `2001::1`、`2001:2::1`、`3fff::1`。
3. manager upgrade 创建的数据备份没有形成下游失败时的完整数据 rollback。
4. 首次安装创建 CLI symlink 失败时的 release/app 恢复路径仍不完整。

## 当前禁止事项

- 不得部署到生产 VPS。
- 不得宣布 Repository Production Ready。
- 两个 High 修复并重新独立复审前，不得进入测试 VPS 灰度。
- 未经用户明确授权，不得 commit 或 push。
- 不得用修改 Review Pack、降低严重度或增加宽松测试代替代码修复。
- 不得把 mock systemd 结果表述为真实 systemd 验收。

## 下一步工作

1. 对 generation 与 app 的每个 symlink/rename/rollback 操作显式检查退出码，并确保
   失败不会输出成功、不会保留错误 release 或造成 live 数据漂移。
2. 增加独立故障注入，验证发布失败和 rollback 失败的非零退出码及 state/current/
   service 哈希一致性。
3. 让监听 mock 的运行事实独立于 expected manifest，消除循环证明。
4. 收紧 IPv6 endpoint global-unicast 判定。
5. 补齐 manager upgrade 数据 rollback 和首次安装 CLI link 失败恢复。
6. 重新执行完整隔离测试、真实组件测试、ShellCheck、`bash -n` 和
   `git diff --check`。
7. 再做一次独立只读复审。只有 Critical 0 / High 0 后，才讨论 commit、push 和单台
   测试 VPS 的真实 systemd 灰度。

## 尚未验证边界

当前隔离环境 PID 1 为 `bwrap`，无法连接 systemd system bus。以下只能在获批的单台
测试 VPS 验证：真实 MainPID/cgroup/socket 归属，enable/start/restart/stop，
generation 实际加载，旧 socket 消失，异常退出 Restart，主机 reboot 后有节点和
零节点行为，以及事务失败后的真实 service rollback。
