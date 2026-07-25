# sb 开发交接

本文档是 sb 当前开发阶段、阻断项和下一步工作的唯一事实来源。稳定的用户说明见
[`../README.md`](../README.md)，完整修复证据见
[`FINAL_REVIEW_PACK.md`](FINAL_REVIEW_PACK.md)。

## 当前 Git 状态

第二轮修复、第二次与第三次独立复审整改，均完成于 2026-07-25/26：

- 分支：`main`，已在用户明确授权后 commit 并推送到 Gitea `origin/main`
- 工作树：clean
- 上一基线提交：`aaa7de7`（`docs: record development snapshot status`）
- 改动范围：第二轮 17 个代码/测试文件，叠加第二次复审整改后见 `git diff --stat`；
  另新增 `sb/tests/errexit-audit.sh` 与文档更新
- 未执行任何 VPS、部署或防火墙操作

开始新任务时必须重新执行 `AGENTS.md` 指定的 Git 检查；本节不是永久不变的仓库状态快照。

## 当前开发阶段

**Repository Production Candidate — Not Production Ready**

- 第一次独立复审的 2 个 High + 4 个 Medium：已修复（第二轮）。
- 第二次独立复审的 4 个阻断 High（HIGH-A..D）与 2 个阻断 Medium（M1、M2），外加被点名的
  M3（IPv4 前导零）与 M4（非 root `generation_drift` 误报）：已修复。四个 High 在整改前
  全部实际复现，整改后在同一注入点复测通过。
- 第三次独立复审（Critical 0 / High 0 / Medium 5，全部非阻断）指出的 M-3.1（`cmd_install`
  仍压平 rc=70）与 M-3.2（salvage 确认可从环境继承）：已修复，两项均在整改前实际复现。

第三次复审的结论是「commit/push 允许，但需用户明确授权」。用户已明确授权，变更集已提交
并推送到 Gitea `origin/main`。Production Ready 仍为否——真实 systemd/cgroup 门槛未验证。

## 已完成内容

在上一轮基础上，本轮新增：

- `symlink_switch()`：统一的三步显式检查符号链接原子切换原语
- `transaction_run` 发布阶段机与两级回滚严重度（普通失败 vs `SB_EX_UNRECOVERABLE`=70）
- `manager_install_source` 全路径显式检查、`manager_rollback_app()`、命令路径冲突前置判定
- `cmd_upgrade` 阶段化 + `upgrade_rollback()` 完整数据恢复（app/unit 恢复先于数据恢复）
- `backup_create` salvage 模式，使 live 数据已损坏时 `sb restore` 仍可执行
- IANA Special-Purpose 表驱动的 IPv4/IPv6 endpoint 判定（位精确前缀匹配）
- listener mock 的 observed 侧改由 `config.json` 推导，消除循环证明
- `doctor` 新增 `generation_drift`、`last_publish`、`app_release` 检查
- 仓库级 errexit 条件上下文审计与常驻检查 `tests/errexit-audit.sh`

第二次复审整改新增：

- 全部 mutator 以显式 `return 0` 结尾，state 写入逐项检查；新增 `state-set-write` 注入点
- salvage 判定改为检查 **live 源**（`backup_live_source_valid`），不再检查半成品候选
- salvage 快照默认拒绝恢复，需 `--restore-unvalidated-salvage` 显式确认并留下状态证据
- `SB_TXN_SALVAGE_BACKUP` 改为进程内 `SB_INTERNAL_MARKER`，环境不可达
- rc=70 在 `cmd_restore`、`core_upgrade` 及其余调用点原样传播；current 链接恢复失败后
  不再继续做证书目录回退
- CRITICAL 中指名的恢复物（旧核心二进制、暂存副本、被拒 generation 的证书）不再被
  EXIT trap 删除
- IPv4 前导零与全数字末标签一律拒绝；`generation_drift` 在 `/proc` 不可读时记为 info

第三次复审整改新增：

- `cmd_install` 的 `core_install || return $?`：`sb install` 经 `core_switch` 的 rc=70 不再被
  压平；`FINAL_REVIEW_PACK.md` 中「已全部排查压平点」的表述已更正
- `SB_ALLOW_SALVAGE_RESTORE` 不再从环境读取、不再被导出：salvage 恢复授权只能来自本次调用
  键入的 `--restore-unvalidated-salvage`，不会经会话或子进程继承

上一轮已完成的内容（协议矩阵、TLS 模式、固定核心校验、事务框架、零节点策略等）保持不变。

## 当前阻断

```text
自测 Critical: 0
自测 High:     0
自测 Medium:   0 blocking
```

第二次复审的 M5、M6、LOW-1..9，以及第三次复审的 M-3.3（非 root `sb doctor` 的 `listeners`
检查仍失败）、M-3.4、M-3.5 及其 Low 列表，均仍然开放。按指示本轮只处理 M-3.1 与 M-3.2。

下轮优先项仍是 **M-3.5 / M6**：`errexit-audit.sh` 只匹配字面命令，不覆盖 `safe_mkdir`、
`atomic_write`、`state_set_file` 等包装函数，正是这个盲区放过了 HIGH-A。第三次复审复扫后
确认剩余 13 处包装调用点当前都不会掩盖失败。

**当前阻断项：无自测阻断项。** commit/push 需用户明确授权；真实 systemd 验收仍未完成。

## 当前禁止事项

- 不得部署到生产 VPS。
- 不得宣布 Repository Production Ready。
- 未通过第三次独立只读复审前，不得进入测试 VPS 灰度。
- 未经用户明确授权，不得 commit 或 push。
- 不得用修改 Review Pack、降低严重度或增加宽松测试代替代码修复。
- 不得把 mock systemd 结果表述为真实 systemd 验收。

## 下一步工作

1. 下一轮代码工作：M-3.5 的包装函数审计覆盖，然后 M-3.4，再处理 Low 列表。
2. 单台测试 VPS 的真实 systemd 灰度，并把真实 systemd 验收作为强制门槛；同时在真实主机上
   验证非 root `sb doctor` 的可用性（M-3.3）。

## 复现与验证入口

```bash
SB_TEST_REAL_CORE=/path/to/sing-box-1.13.14 \
SB_TEST_HYSTERIA_BIN=/path/to/hysteria-v2.10.0-linux-amd64 \
SB_TEST_SSURL_BIN=/path/to/shadowsocks-rust-v1.24.0/ssurl \
  sb/tests/run.sh                    # 期望 567 pass / 0 fail

sb/tests/errexit-audit.sh            # 期望 0 blocking
shellcheck --severity=warning --external-sources \
  file.sh sb/sb sb/install.sh sb/core/*.sh sb/protocols/*.sh sb/tests/*.sh
git diff --check
```

故障注入通过 `SB_TEST_FAULTS`（冒号分隔）配合 `SB_TEST_MODE=true` 启用；注入点清单见
[`TESTING.md`](TESTING.md)。

## 尚未验证边界

当前隔离环境 PID 1 为 `bwrap`，无法连接 systemd system bus。以下只能在获批的单台测试 VPS
验证：真实 MainPID/cgroup/socket 归属，enable/start/restart/stop，generation 实际加载，
旧 socket 消失，异常退出 Restart，主机 reboot 后有节点和零节点行为，以及事务失败后的真实
service rollback。
