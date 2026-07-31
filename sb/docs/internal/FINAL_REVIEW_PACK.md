# Repair Review Pack — sb 3.0（第二轮 + 第二次复审整改）

日期：2026-07-25
范围：Gitea `S/st` 仓库的 `sb` 项目
边界：仅仓库与隔离临时目录；未连接 VPS、未部署、未操作防火墙、未 commit/push。

本轮针对上一轮《Final Read-Only Sign-off》确认的 **2 个 High 和 4 个 Medium** 做代码级
修复，并补充故障注入证据。上一轮 Review Pack 的内容已被本文件整体替换。

## Executive Summary

```text
完整自动测试：567 pass / 0 fail（无 skip、无 xfail；基线 241 → 479 → 559 → 567）
真实 sing-box：1.13.14
真实 Hysteria parser/client：v2.10.0
真实 SIP002 parser：shadowsocks-rust ssurl v1.24.0
ShellCheck：0.11.0 --severity=warning --external-sources，0 issue
bash -n：通过
git diff --check：通过
errexit 条件上下文审计：0 blocking / 49 advisory
```

两个 High 在修复前均已在隔离环境**实际复现**，修复后在同一注入点复测不再出现。
真实 systemd/cgroup 集成仍未验证，结论仍为 **Repository Production Candidate，不标记
Production Ready**，且本轮不自行批准灰度。

## 修复前复现（Before）

复现方式：对 `HEAD` 的只读副本，在被点名的那一行强制该命令真实失败，然后执行正常业务命令。

### HIGH-01 复现

```text
$ sb add SS --port 10001 --yes        # .current.new 符号链接创建被强制失败
ln: failed to create symbolic link '.../data/.nonexistent-dir/.current.new.79400': No such file or directory
mv: cannot stat '.../data/.current.new.79400': No such file or directory
OK: publish completed: add SS
OK: instance created: is01

exit code                  : 0
current switched           : NO（仍为 generations/20260725T111816-78949-ca1ef037）
instances in live state    : 0
printed 'publish completed': 1
printed 'instance created' : 1
```

### HIGH-02 复现

```text
$ sb upgrade --source ...             # .app.new 符号链接创建被强制失败
ln: failed to create symbolic link '.../opt/.nonexistent-dir/.app.new.80545': No such file or directory
mv: cannot stat '.../opt/.app.new.80545': No such file or directory
OK: sb manager installed: .../opt/releases/3.0.0-20260725T111853Z-0a4c85
OK: sb manager initialization verified

exit code                  : 0
app link switched          : NO
release count before/after : 1 / 2（孤儿 release）
printed 'manager installed': 1
```

两处症状与复审描述完全一致：**rc=0、链接未切换、却打印业务成功信息**。

## 根因

`sb`、`install.sh`、`file.sh` 使用 `set -Eeuo pipefail`，而 `core/*.sh` 中的关键函数依赖
该 errexit 传播失败。但 `transaction_run` 由 `cmd_add` 以 `if transaction_run ...; then`
调用，`manager_install_source` 由 `cmd_upgrade` 以 `... || return 1` 调用。Bash 在这两种
条件上下文中**关闭被调函数内部的 errexit**，于是 `ln`/`mv` 失败后继续向下执行，最终走到
成功分支。这不是个别行的疏漏，而是一类模式，因此本轮同时做了仓库级审计并加了常驻检查。

## HIGH-01：generation/current 发布与回滚失败传播

### 代码修复

- `core/common.sh` 新增 `symlink_switch <target> <link> <staging> [fault]`：`rm`、`ln -s`、
  `mv -fT` 三步逐项显式检查并各自传播失败，不依赖 errexit。
- `core/transaction.sh` 重写发布路径为显式阶段机：
  - 阶段 1 candidate → final：改用 `mv -T`（避免把新 generation 嵌套进已存在目录），
    失败即 `return 1` 并写入 `failed` 状态；
  - 阶段 2 current 切换：经 `symlink_switch`，失败时删除尚未被引用的 final、写入
    `failed`、返回非零，live generation 完全不变；
  - 阶段 3 回滚：`transaction_restore_link` 同样经 `symlink_switch`。
- 回滚失败区分两种严重度：
  - **current 链接未能恢复** → 返回 `SB_EX_UNRECOVERABLE`(70)、打印 `CRITICAL` 与人工恢复
    路径、保留新旧两个 generation 与候选证书材料、状态记为
    `rollback-failed` / `current-link-restore-failed`；
  - **链接已恢复但服务未恢复** → 返回 1、状态记为 `service-restore-failed`、**保留**被拒
    generation（服务可能仍在其中运行，删除会抽掉运行中进程的文件并销毁证据）。
- 仅在回滚完整成功时才清理被拒 generation 和候选证书路径。
- `cp -a` 播种候选、`rm -rf` 候选 output、`mktemp`、`readlink`、`state_enabled_count_file`
  等全部显式检查。
- `core/doctor.sh` 新增 `generation_drift`（current 与运行服务实际加载的 generation 比对）
  和 `last_publish`（识别 `rollback-failed` / `service-restore-failed`）检查。

### 故障注入证据

注入不伪造返回码：把暂存路径重定向到不存在的目录（`ln` 真实 ENOENT）、在 rename 前删除
暂存链接（`mv` 真实 ENOENT）、或预先占用重命名目标（`mv -T` 真实 ENOTEMPTY）。注入仅在
`SB_TEST_MODE=true` 且 `SB_TEST_FAULTS` 指名时生效。

| 注入点 | rc | current | state hash | settings hash | generation hash | 服务加载 generation | rollback 结果 | 错误成功提示 |
|---|---|---|---|---|---|---|---|---|
| `generation-final-mv` (add) | 1 | 旧 | 未变 | 未变 | 未变 | stopped | not-required | 无 |
| `current-new-create` (add) | 1 | 旧 | 未变 | 未变 | 未变 | stopped | not-required | 无 |
| `current-new-switch` (add) | 1 | 旧 | 未变 | 未变 | 未变 | stopped | not-required | 无 |
| `current-rollback-create`（服务失败后） | **70** | 未恢复（有意保留） | 新值 | 未变 | 未变 | stopped | current-link-restore-failed | 无 |
| `current-rollback-switch`（服务失败后） | **70** | 未恢复（有意保留） | 新值 | 未变 | 未变 | stopped | current-link-restore-failed | 无 |
| 无注入，服务 start 失败 | 1 | 旧 | 未变 | 未变 | 未变 | stopped | success | 无 |
| `current-new-switch` (edit) | 1 | 旧 | 未变 | 未变 | 未变 | 旧 generation | not-required | 无 |
| `current-new-switch` (disable) | 1 | 旧 | 未变 | 未变 | 未变 | 旧 generation | not-required | 无 |
| `current-new-switch` (delete) | 1 | 旧 | 未变 | 未变 | 未变 | 旧 generation | not-required | 无 |
| `current-new-switch` (endpoint set) | 1 | 旧 | 未变 | 未变 | 未变 | 旧 generation | not-required | 无 |
| `current-new-switch` (listen set) | 1 | 旧 | 未变 | 未变 | 未变 | 旧 generation | not-required | 无 |

两行 rc=70 的 `state hash` 显示为新值是**预期且正确**的：rollback 未能恢复 current 链接，
所以 `current/instances.json` 仍解析到新 generation。这正是「不可自动恢复」的定义，因此以
非零 70、`CRITICAL` 日志、保留全部恢复材料的方式如实上报，而不是掩饰为普通失败。

`test_transaction_publish_fault_injection` 另含一条针对性回归断言：
"unswitched current can never report success"。

### 候选目录清理

- 阶段 1/2 失败：final 被删除，无 `.current.*` 暂存残留（已断言）。
- 回滚成功：被拒 generation 删除，仅剩 1 个 generation（已断言）。
- 回滚失败：保留 ≥2 个 generation 供人工恢复（已断言）。

## HIGH-02：manager app 原子切换失败传播

### 代码修复

`core/manager.sh` 中 `manager_install_source` 全面重写：

- release 目录创建、`cp -a` 源复制、staged release 校验、`mv -T` 发布全部显式检查；
- `.app.new` 创建与切换经 `symlink_switch`；
- 新增 `manager_rollback_app()`：统一处理自检失败、命令目录创建失败、CLI link 失败三种
  回滚，回滚自身失败返回 70 并保留被拒 release；
- 新增 `manager_command_link_conflict()`：在 **app 链接切换之前**判定命令路径冲突，避免
  留下半安装状态；普通文件和指向非 sb 管理路径的符号链接都拒绝，不静默替换；
- CLI link 改为「同目录暂存 + rename」，失败绝不留下悬空 `/usr/local/bin/sb`；
- 任一失败路径都清空 `SB_MANAGER_INSTALLED_RELEASE`，不产生孤儿 release。

### 故障注入证据

| 注入点 | rc | app link | CLI link | release 数 | 孤儿 release | `.app.new` 残留 | 错误成功提示 |
|---|---|---|---|---|---|---|---|
| `release-stage-mkdir` | 1 | 未变 | 未变 | 1→1 | 无 | 0 | 无 |
| `release-copy` | 1 | 未变 | 未变 | 1→1 | 无 | 0 | 无 |
| `release-validate` | 1 | 未变 | 未变 | 1→1 | 无 | 0 | 无 |
| `release-final-mv` | 1 | 未变 | 未变 | 1→1 | 无 | 0 | 无 |
| `app-new-create` | 1 | 未变 | 未变 | 1→1 | 无 | 0 | 无 |
| `app-new-switch` | 1 | 未变 | 未变 | 1→1 | 无 | 0 | 无 |
| `app-selfcheck` | 1 | 未变 | 未变 | 1→1 | 无 | 0 | 无 |
| `cli-link-create` | 1 | 未变 | 未变 | 1→1 | 无 | 0 | 无 |
| `cli-link-switch` | 1 | 未变 | 未变 | 1→1 | 无 | 0 | 无 |
| `app-rollback-create` | **70** | 未恢复（有意保留） | 未变 | 1→2 | 有意保留 | 0 | 无 |
| `app-rollback-switch` | **70** | 未恢复（有意保留） | 未变 | 1→2 | 有意保留 | 0 | 无 |

全部 11 种注入均另行断言「旧 manager 仍可运行」（`$SB_APP_LINK/sb self-check` 成功）与
「不存在悬空命令链接」。回归断言 "unswitched app link can never report installed" 覆盖复审
复现的原始场景。

## MEDIUM-01：listener 正向 mock 循环证明

**问题**：旧 `mock-systemctl` 从被测 generation 的 `manifest.json` 的 `.expected_listeners`、
`.listen.address`、`.generation_id` 直接生成 observed socket 表，而 `service_verify_listeners`
的 expected 也来自同一文件，等于自证。

**修复**：observed 一侧改为从 `output/config.json` 的 inbounds 推导——即真实 sing-box 实际会
绑定的东西——并按 inbound type 映射传输层（shadowsocks→tcp+udp，hysteria2→udp，vless→tcp，
anytls→tcp）。`config.json` 由 `PROTO_INBOUND` 渲染，`manifest.json` 由独立的 `PROTO_EXPECTED`
渲染，两侧来自不同代码路径，两者不一致即为可检出的真实缺陷。

测试另可通过 `observed-sockets.tsv`、`observed-generation`、`observed-mainpid` 三个文件完全
接管 observed 世界，用于差异测试。

新增 `test_listener_expected_observed_divergence` 差异矩阵（全部要求 verifier 拒绝）：

| 差异 | 结果 |
|---|---|
| expected TCP，observed 仅 UDP | 拒绝 |
| expected `::`，observed `127.0.0.1` | 拒绝 |
| observed 端口不同 | 拒绝 |
| observed PID 不同 | 拒绝 |
| 缺少一个 expected socket | 拒绝 |
| 加载的 generation 不同（进程 cwd） | 拒绝 |
| systemd 报告的 MainPID 不持有 socket | 拒绝 |

并静态断言 `mock-systemctl` 不含 `expected_listeners`、`mock-ss` 不读 manifest。

**边界声明**：隔离 mock 只验证 verifier 逻辑，不能替代真实 systemd/ss/cgroup 验证。

## MEDIUM-02：endpoint global-unicast 判定

旧实现对 IPv6 仅用 `2000::/3` 粗判，实测 `2001::1`、`2001:2::1`、`3fff::1` 均被错误接受。

**修复**：`core/common.sh` 改为显式 IANA Special-Purpose 表 + 位精确前缀匹配
（`ipv6_expand` 展开为 32 nibble，`ipv6_prefix_matches` 支持 `/7`、`/10`、`/23` 等非
半字节边界前缀）。IPv4 同样改为 `network/prefixlen` 表驱动。

覆盖 IPv4：`0/8`、`10/8`、`100.64/10`、`127/8`、`169.254/16`、`172.16/12`、`192.0.0/24`、
`192.0.2/24`、`192.31.196/24`、`192.52.193/24`、`192.88.99/24`、`192.168/16`、`192.175.48/24`、
`198.18/15`、`198.51.100/24`、`203.0.113/24`、`224/4`、`240/4`。

覆盖 IPv6：`::/128`、`::1/128`、`::ffff:0:0/96`、`64:ff9b::/96`、`64:ff9b:1::/48`、`100::/64`、
`2001::/23`（含 IETF 协议分配、TEREDO、benchmarking、ORCHIDv2）、`2001:db8::/32`、`2002::/16`、
`3fff::/20`、`5f00::/16`、`fc00::/7`、`fe80::/10`、`ff00::/8`，以及 `2000::/3` 之外一律拒绝。

`test_endpoint_special_purpose_matrix` 表驱动 44 个样本全部符合预期，其中：

```text
2001::1    → reject（旧实现 accept）
2001:2::1  → reject（旧实现 accept）
3fff::1    → reject（旧实现 accept）
2002::1    → reject（旧实现 accept）
```

新表同时修正了旧实现的**过度拒绝**：`192.0.3.1`、`172.32.0.1`、`100.128.0.1`、`198.20.0.1`
现在被正确接受。

其余要求：

- 域名策略明确为「每条 A/AAAA 都必须是可公开访问地址」，混合结果整体拒绝，绝不静默挑选；
  DNS 解析失败一律报错，不写入 live settings（已断言 "rejected endpoints never reach live
  settings"）。
- override 是独立的 `--allow-private-endpoint`，`--yes` 不隐含它（已断言）；实际抑制拒绝时
  打印风险 `WARN`（已断言）。

## MEDIUM-03：upgrade 数据恢复最后防线

`cmd_upgrade` 改为显式阶段：

1. **数据备份**（尚未修改任何东西，失败无需回滚）；
2. **app 切换**（`manager_install_source` 自行回滚，且不触碰 settings/state/generation/certs，
   失败无需数据回滚）；
3. **新 manager 执行 install**（可能迁移 schema、重建 generation、迁移证书）——此后任何失败
   都必须假设 live 数据已被修改。

`upgrade_rollback()` 的顺序被明确固定：**先恢复 app link 与 unit，再由已恢复的旧 manager
执行数据恢复**。这同时避免「旧 manager 读到新 schema」和「新 manager 读到半恢复数据」。恢复后
用旧 manager 重新 `validate` + `doctor`，任一环节失败返回 70 并保留备份。

### 连带发现并修复的缺陷

实现过程中发现 `sb restore` 在 live 数据已损坏时**无法执行**：它的事务会先为当前（已损坏的）
generation 创建 pre-publish 备份，而该备份的校验必然失败，于是整个恢复被阻断——恰好在最需要
恢复的时刻失效。修复为 `backup_create` 增加 `salvage` 模式：仅在恢复路径启用，仅把**校验**
失败降级为带 `salvage: true` 标记的取证快照并打印 `WARN`；注入故障与真实的 cp/权限/metadata
失败在任何模式下仍然致命，因此不削弱上一轮 H1 的备份原子性结论。

### 迁移失败模拟证据

测试构造一个能通过 `manager_validate_source` 的源码树，其 `sb install` 先修改 live 数据再以
非零退出，模拟半途失败的迁移。四种变体全部通过：

| 模拟失败点 | rc | state hash | settings hash | 证书 hash | config 通过固定核心 | 旧 manager validate |
|---|---|---|---|---|---|---|
| migration 修改 state 后失败 | 非零 | 恢复为升级前值 | 恢复 | 恢复 | 通过 | 通过 |
| migration 修改 settings 后失败 | 非零 | 恢复 | 恢复为升级前值 | 恢复 | 通过 | 通过 |
| generation rebuild 后失败 | 非零 | 恢复 | 恢复 | 恢复 | 通过 | 通过 |
| cert migration 后失败 | 非零 | 恢复 | 恢复 | 恢复为升级前值 | 通过 | 通过 |

每种变体另断言：无 `sb manager upgraded` 成功提示、current 解析到有效 generation、
app link 指向可用 release、恢复后所有文件仍为 `0600`。

## MEDIUM-04：首次 CLI symlink 创建失败回滚

- CLI link 创建改为暂存 + rename 并显式检查（`symlink_switch`，故障点 `cli-link-create` /
  `cli-link-switch`）。
- 创建前先分类命令路径：普通文件、指向非 sb 管理目标的符号链接一律拒绝且**在 app 切换之前**
  就拒绝；受管链接才继续。
- 失败时 app link 恢复旧 target、新 release 清理、不留下悬空 `/usr/local/bin/sb`、不覆盖
  无法恢复的原文件。
- `install.sh` 的首次安装回滚路径也改用 `symlink_switch`，回滚失败返回 70。

`test_command_link_conflicts` 证据：

| 场景 | rc | 命令路径 | app link | 孤儿 release |
|---|---|---|---|---|
| `/usr/local/bin/sb` 是普通文件 | 非零 | 原文件内容保持 `not-sb` | 未变 | 无 |
| `/usr/local/bin/sb` 指向其他项目 | 非零 | 仍指向原 target | 未变 | 无 |
| symlink 创建失败 | 非零 | 无悬空链接 | 恢复旧 target | 无 |

`cli-link-switch`（创建成功但 rename 失败）与 `app-rollback-*`（回滚自身失败）见 HIGH-02 表。

## Bash errexit 条件上下文审计

新增常驻检查 `sb/tests/errexit-audit.sh`，作为测试项 `test_errexit_audit_guard` 执行。

- 只分析**生产文件的函数体**；`set -e` 脚本顶层语句不受该陷阱影响，测试驱动不随产品分发。
- **Blocking** 类（失败即意味着预期状态变更没有发生）：`mkdir cp mv ln chmod chown install
  tar sha256sum`。
- **Advisory** 类（`rm rmdir touch`）：失败无法伪造成功，单独列出不阻断。
- 例外需在同一行标注 `# errexit-audit: ok <理由>`。
- 明确声明为启发式，不能替代人工审计。

首次运行对基线 `aaa7de7` 报出 **76 个 blocking / 44 个 advisory**（本文件早前写作 47，
系笔误，第二次独立复审已指出；重新对基线运行本仓库当前的 `errexit-audit.sh` 可复现 76）。
已逐一修复，涉及 `file.sh`、`sb/sb`、`sb/install.sh`、
`core/{install,manager,migration,runtime,service,settings,state,tls,transaction,common}.sh`。
其中若干本身就是「回滚失败被静默吞掉」的同类问题，例如 `core_switch` 恢复旧二进制、
`core_upgrade` 恢复旧核心、`cmd_restore` 证书目录换回，现在都会返回 70 并打印人工恢复路径。

当前结果：

```text
errexit 审计：0 blocking / 49 advisory
```

## 实际修改文件

```text
file.sh
sb/sb
sb/install.sh
sb/core/common.sh      sb/core/transaction.sh  sb/core/manager.sh
sb/core/backup.sh      sb/core/doctor.sh       sb/core/install.sh
sb/core/migration.sh   sb/core/runtime.sh      sb/core/service.sh
sb/core/settings.sh    sb/core/state.sh        sb/core/tls.sh
sb/tests/run.sh
sb/tests/fixtures/mock-systemctl
sb/tests/errexit-audit.sh   （新增）
sb/docs/FINAL_REVIEW_PACK.md、sb/docs/AI_HANDOFF.md、sb/docs/TESTING.md、
sb/docs/ARCHITECTURE.md、sb/README.md
```

统计：代码与测试 17 个文件，+1329 / −187。协议实现 `protocols/*.sh` 未改动。

## 完整测试结果

```text
RESULT: pass=567 fail=0
```

新增测试项：

```text
test_transaction_publish_fault_injection      发布阶段 3 种注入 × 全量断言
test_transaction_rollback_fault_injection     回滚阶段 2 种注入 + 服务恢复失败区分
test_transaction_fault_across_operations      add/edit/disable/delete/endpoint/listen
test_manager_app_switch_fault_injection       11 种 manager 注入
test_command_link_conflicts                   CLI 链接冲突与回滚
test_upgrade_data_rollback                    4 种迁移失败模拟 + 完整数据恢复
test_listener_expected_observed_divergence    7 种 expected/observed 差异
test_endpoint_special_purpose_matrix          44 个 IANA 样本表驱动
test_errexit_audit_guard                      errexit 条件上下文常驻检查

第二次复审整改新增：
test_mutator_state_write_fault_injection      mutator 层 state 写入失败（add/edit/disable/delete）
test_salvage_mode_boundaries                  salvage 进入条件、默认拒绝、显式 override、环境不可达
test_unrecoverable_code_reaches_the_cli       sb restore / sb core upgrade 的 rc=70 到达 CLI 边界
test_recovery_artifacts_survive_exit          CRITICAL 指名的恢复物在进程退出后仍存在
test_ipv4_leading_zero_rejection              前导零字面量与全数字末标签
test_doctor_drift_check_without_proc_access   /proc 不可读时记为 info 而非 fail

第三次复审整改新增断言：
test_unrecoverable_code_reaches_the_cli       追加 sb install 经 core_install 的 rc=70
test_salvage_mode_boundaries                  追加继承/导出的 salvage 确认不得授权恢复
```

静态与卫生检查：

```text
bash -n                                   通过（file.sh、sb、install.sh、core、protocols、tests、fixtures）
ShellCheck 0.11.0 --severity=warning      0 issue
git diff --check                          通过
固定 /tmp 残留（sb-test-failure.out 等）  无
.txn-* / .migrate-* / .cert-* 残留        无
测试结束后遗留测试根目录                  0
失败输出中的凭据                          无（已断言 rollback 输出不含 password/私钥）
```

## 真实组件与 mock 组件

真实：

- sing-box `1.13.14`：所有 server config 与生成 outbound 的实际 `check`；
- Hysteria `v2.10.0`：官方 parser/client 与 trusted/provided/self-signed/insecure 四次本地
  回环低流量 TLS 握手；
- shadowsocks-rust `v1.24.0` `ssurl`：真实 SIP002 decode；
- OpenSSL：SAN、链、cert/key 配对、完整证书 fingerprint；
- 实际 `flock` 与并发进程；
- 真实 `ln`/`mv`/`cp`/`mktemp` 的 errno——故障注入通过扰动文件系统让真实命令失败，
  不伪造返回码。

mock：

- `systemctl`：enabled/active/MainPID、restart 失败、inactive、零节点状态机；observed
  socket 由 `config.json` 推导，或由测试显式接管；
- `ss`：只回放 runtime socket 表，不读 manifest。

mock **无法**证明真实 systemd D-Bus、unit sandbox、kernel cgroup、真实 sing-box socket
ownership 与主机 reboot 行为；这些项目明确未标记通过。

## 第二次独立复审整改（HIGH-A..D、M1..M4）

第二次独立只读复审确认 Critical 0 / High 4（阻断）/ Medium 8（2 阻断）。四个 High 全部
在整改前实际复现，整改后在同一注入点复测通过。

### HIGH-A：`mutator_add` 吞掉 state 写入失败

`state_set_file` 不是 `mutator_add` 的最后一条命令，尾部的 `[[ ]] && printf` 成为函数返回
状态；`cmd_add` 永远设置 `SB_TXN_RESULT_FILE`，因此该表达式恒真。

```text
Before（state_set_file 的 mktemp 真实 ENOENT）   After
exit code                  : 0                  exit code                  : 1
instances in live state    : 0                  instances in live state    : 0
printed 'publish completed': 1                  printed 'publish completed': 0
printed 'instance created' : 1                  printed 'instance created' : 0
```

修复：`state_set_file` 显式检查；result-file 写入只能**导致**失败、不能掩盖失败；函数以
显式 `return 0` 结尾。同一类修复应用到全部 mutator（edit/delete/enabled/endpoint/listen/
install/restore），使「成功」成为局部不变量而非位置巧合。新增 `state-set-write` 注入点，
覆盖 add/edit/disable/delete 四条路径（`test_mutator_state_write_fault_injection`）。

### HIGH-B：salvage 模式被无条件进入

`backup_validate` 硬性要求 `metadata.json`，而探测发生在写 metadata 之前，因此探测恒失败，
只要传入 `salvage=true` 就必然进入 salvage 模式，与 live 数据健康与否无关。

```text
Before（live 数据 sb validate 通过）             After
salvage of pre-publish snapshot : true          salvage of pre-publish snapshot : false
WARN 'did not validate'         : 1             WARN 'did not validate'         : 0
```

修复：salvage 的判定改为在任何复制之前检查 **live 源**（`backup_live_source_valid`：
generation 结构、`runtime_validate_generation`、state 与 settings schema），而不是检查半成品
候选目录。新增 `test_salvage_mode_boundaries`：健康安装 → `salvage:false`；live 数据确实
无效 → `salvage:true` 且打印 WARN。

### HIGH-C：rc=70 在两处调用点被压成 1

```text
Before                                          After
sb restore（current-rollback-create）: rc=1     rc=70
sb core upgrade（core_switch 返回 70）: rc=1    rc=70
```

修复：`cmd_restore` 捕获并原样返回 `$?`；`core_upgrade` 改为 `core_switch upgrade || return $?`。
同时修正了 `cmd_install` 里的 `transaction_run` 调用、`cmd_edit`、`cmd_delete`、`cmd_enabled`、
`reload`、`install.sh` 等调用点。

> **更正（第三次独立复审 M-3.1）**：上面这段此前写作「同时排查并修正了其余会压平返回码的
> 调用点」并把 `cmd_install` 列为已完成。实际上当时只覆盖了它的 `transaction_run` 调用，
> 遗漏了同一函数里的 `core_install || return 1`——该路径经 `core_install → core_switch install`
> 同样会产生 70 并被压平成 1。第三次复审独立复现了这一点。现已改为 `core_install || return $?`
> 并补上 CLI 边界回归测试。原先的「已全部排查」表述不成立，特此更正。

更重要的是：`cmd_restore` 在 current 链接恢复失败后**不再继续做证书目录回退**。此前它会把
恢复前的证书目录换回到一个仍指向未验证 generation 的 `current` 之下，使损坏叠加。现在该
分支直接返回 70，保留 `.cert-before-restore.*` 并打印其路径。

### HIGH-D：CRITICAL 中指名的恢复物被 EXIT trap 删除

`core_switch` 的 trap 删除 `$backup_bin`、`core_upgrade` 的 trap 删除 `$restore_stage`，
而这两个路径正是 CRITICAL 输出让操作者去移动的对象。前者会让节点既没有可用的新核心、也
没有旧二进制的任何副本。

```text
Before（隔离验证 trap-on-return 语义）           After（对真实代码路径注入）
artifact exists after exit : NO                 core_switch  : rc=70, artifact exists after exit: YES
                                                core_upgrade : rc=70, artifact exists after exit: YES
```

修复：在返回 70 之前把对应变量置空，使 trap 跳过它们。同时修正 `service-restore-failed`
路径：既然它保留被拒 generation，就不能再让 EXIT trap 回收该 generation 的候选证书材料
（第二次复审 LOW-4）。新增 `test_recovery_artifacts_survive_exit`，断言 CRITICAL 中打印的
路径在进程退出后仍然存在。

### M1：salvage 快照必须默认拒绝恢复

`cmd_restore` 此前从不读 `metadata.salvage`，`backup.sh` 打印的「不可恢复」保证没有任何
实现。现在：默认拒绝并说明原因与风险，提供显式 `--restore-unvalidated-salvage`；使用该
标志时打印 `DANGEROUS` 警告，并把「UNVALIDATED salvage snapshot」写入 `status.json` 的
`last_publish.description` 作为证据。

salvage 标记的检查被放在内容校验**之前**，否则拒绝理由会退化成笼统的 `invalid backup`，
override 也永远无法生效。override 是**知情确认而非绕过**：内容确实损坏的快照仍会被后续
校验如实拒绝，测试对两种情况分别断言。

### M2：`SB_TXN_SALVAGE_BACKUP` 的生产可达性

此前该变量从环境直读，任何命令都可以用 `SB_TXN_SALVAGE_BACKUP=true sb add ...` 关闭备份
校验。现在 `core/common.sh` 在任何命令运行前 `unset` 掉继承值，内部调用方改为传递每进程
随机的 `SB_INTERNAL_MARKER`，环境无法伪造。

```text
Before: SB_TXN_SALVAGE_BACKUP=true sb add ...  -> 快照 salvage=true（未校验）
After : 同一命令                                -> 快照 salvage=false
```

未将其改成「仅测试可用」：`upgrade_rollback` 依赖它在生产环境从损坏数据中恢复，那正是
MEDIUM-03 最后防线的用途。实际要求是「环境不可达」，已通过内部标记满足。

### M3：IPv4 前导零绕过

`ipv4_valid` 接受前导零、`ipv4_to_int` 按 bash 八进制解释，于是被校验的地址与被存储、被
写进客户端 URI 的字面量不是同一个地址。

```text
Before                                  After
010.0.0.1   -> ACCEPTED（实为 10.0.0.1）  rejected
0100.64.0.1 -> ACCEPTED（实为 CGNAT）     rejected
08.0.0.1    -> 泄漏 "value too great"     rejected，无原始 shell 报错
8.8.8.8     -> accepted                   accepted
```

修复分两层：`ipv4_valid` 拒绝前导零；`domain_valid` 拒绝全数字的最右标签（RFC 1123 2.1）。
只做第一层是不够的——畸形点分四段会落到域名分支并被当作主机名接受，这一点在实现过程中
实测确认。

### M4：非 root `sb doctor` 的 `generation_drift` 必然误报

`sb doctor` 不要求 root，而非 root 读不到 root 进程的 `/proc/<pid>/cwd`，此前会落入 fail
分支，使健康系统上的 `doctor` 返回非零。现在无法观测时记为 `info` 并说明需要 root。

### 第三次独立复审整改（M-3.1、M-3.2）

第三次独立只读复审确认 Critical 0 / High 0 / Medium 5（0 阻断）。按指示本轮只处理
M-3.1 与 M-3.2，两项均在整改前实际复现。

**M-3.1 — `cmd_install` 仍会把 rc=70 压平**

复现前置：把 `core.json` 的 `binary_sha256` 改坏，使 `core_validate_installed` 失败而版本号
仍匹配，于是 `core_install` 不再短路而进入 `core_switch`；再注入核心回滚故障。

```text
Before                                     After
sb install      : rc=1                     rc=70
sb core upgrade : rc=70（对照，本就正确）  rc=70
CRITICAL 打印   : 1                        1
指名恢复物存在  : YES                      YES
```

修复：`sb/sb` 中 `core_install || return 1` → `core_install || return $?`。
`test_unrecoverable_code_reaches_the_cli` 新增 `sb install` 的 rc=70 断言，并额外断言该路径
不打印 `sb manager initialization verified`。

**M-3.2 — salvage 确认可以从环境继承**

`SB_ALLOW_SALVAGE_RESTORE` 此前从环境读取（`common.sh`）并被 `sb` 导出，于是一次有意的恢复
会授权同一 shell 会话、以及每一个子 `sb` 进程中之后的所有 salvage 恢复。

```text
                                                  Before   After
SB_ALLOW_SALVAGE_RESTORE=true sb restore <salvage>  rc=0     rc=1
  其中 DANGEROUS 警告                               1        0
经子进程继承                                        rc=0     rc=1
显式键入 --restore-unvalidated-salvage              rc=0     rc=0（不变）
```

修复：`common.sh` 无条件将其置为 `false`（丢弃任何继承值），`sb` 不再导出它。授权只能来自
本次调用键入的 `--restore-unvalidated-salvage`。新增三条继承断言与一条跨进程断言。

与 M2 对 `SB_TXN_SALVAGE_BACKUP` 的处理相比：salvage **模式**需要进程内随机标记，因为仍有
内部调用方要启用它；而 salvage **恢复确认**是纯粹的操作者意图，没有任何内部调用方需要传递，
因此直接禁用环境来源即可，无需标记。

### 本轮未处理的非阻断项

第二次复审的 M5、M6、LOW-1、LOW-2、LOW-3、LOW-5..9，以及第三次复审的 M-3.3（非 root
`sb doctor` 的 `listeners` 检查仍会失败）、M-3.4、M-3.5 及其 Low 列表，均仍然开放。按指示
本轮只处理 M-3.1 与 M-3.2。

其中值得下轮优先考虑的仍是 **M-3.5 / M6**（`errexit-audit.sh` 只匹配字面命令，不覆盖
`safe_mkdir`/`atomic_write`/`state_set_file` 等包装函数——正是这个盲区放过了 HIGH-A）。
第三次复审独立复扫后确认剩余 13 处包装调用点当前都不会掩盖失败。

## 当前问题计数

```text
Critical : 0
High     : 0（第一轮复审的 2 个 + 第二次复审的 4 个，均已复现并复测）
Medium   : 0 blocking（第一轮 4 个 + 第二次复审的 M1/M2/M3/M4 + 第三次复审的 M-3.1/M-3.2）
```

以上为**自测结论**，不构成准入结论。第二次与第三次独立复审列出的非阻断项仍然开放，
见上一节。

## 结论与建议

- 独立只读复审：已完成三轮。第三轮结论为 Critical 0 / High 0 / Medium 5（0 阻断），
  并在用户明确授权的前提下允许 commit 与 push；其 M-3.1、M-3.2 已在本文件上一节整改。
- Repository Production Ready：**否**（真实 systemd 门槛未完成），本文件不自行批准灰度。
- 建议复审重点：`backup_live_source_valid` 的判定是否恰好覆盖「不可恢复」的定义、
  salvage override 的语义（知情确认而非绕过）是否被测试如实覆盖、`SB_INTERNAL_MARKER`
  是否在所有子进程边界上都成立、rc=70 是否还有未排查到的压平点、mutator 层「显式
  return 0」是否可被静态检查覆盖（第二次复审 M6 的包装函数盲区）。

## 尚未验证边界

本轮环境 PID 1 为 `bwrap`，systemd system bus 不可用。以下只能在获批的单台测试 VPS 验证：

- 真实 MainPID / cgroup / socket 归属；
- `enable`/`start`/`restart`/`stop` 与 generation 实际加载、旧 socket 消失；
- 异常退出后的 `Restart=on-failure`；
- 主机 reboot 后的有节点与零节点行为；
- 事务失败后的真实 service rollback；
- 云安全组、外部 NAT/UDP、DDoS 限制均不属于仓库隔离测试可证明范围。

本轮未连接或修改任何生产 VPS，未执行生产部署、服务重启、防火墙操作、Git commit 或 push。

---

## 2026-07-31 VLESS 三模式升级证据

### 范围与设计

本轮只扩展 VLESS 及其必要公共边界：

- 新建默认 `vision-reality`：TCP + REALITY +
  `flow=xtls-rprx-vision`；
- `reality`：TCP + REALITY，无 flow；
- `ws`：WebSocket + TLS，无 REALITY/flow。

没有增加 XHTTP、gRPC、HTTPUpgrade、H2、QUIC、Vision + 普通 TLS、
`packet_encoding` 自定义、`spiderX` 或 uTLS 自定义。mode 是 state 中的唯一选择源，
renderer 从它同时推导 inbound、sing-box outbound、URI 和 Mihomo，避免两端 flow 漂移。
旧 VLESS state 缺 mode 时保持历史纯 REALITY 语义。

### 公共事务边界

- 新增 `sb state import FILE`：导入前完整 schema/协议校验，导入与所有派生输出在全局锁和
  generation 事务中整体发布或回滚。
- VLESS WS 的受管 TLS 证书进入既有 backup/restore 校验与 doctor。
- 固定核心检查从服务端扩展到客户端 `clients/sing-box.json`，覆盖 publish、validate、
  render、generation validation 和 doctor。

### 实际验证

```text
完整隔离测试：595 pass / 0 fail
VLESS 三模式专项：28 pass / 0 fail
固定 sing-box：1.13.14
服务端三模式 sing-box check：通过
客户端三模式 sing-box check：通过
errexit audit：0 blocking / 49 advisory
```

专项实际覆盖三种 add、mode/path 与跨模式 edit、enable/disable/delete、非法模式混合拒绝、
旧无-mode state、backup/restore、state export/import、manager upgrade、URI、Mihomo、
服务端 inbound 和 sing-box outbound。

第一次在受限 sandbox 中运行全量套件时，最后的 Hysteria 本地 UDP 回环因 sandbox 禁止创建
socket 而中止；同一固定版本套件在允许本地 socket 的隔离执行环境重跑后取得上述
`595 pass / 0 fail`。未访问公网节点或生产服务。
