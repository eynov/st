# ADR 0003：单一事务边界、崩溃恢复与退出码 ABI

- 状态：Accepted
- 日期：2026-07-31

## 背景

旧版本只有 `fw port` 走了「候选状态 → 渲染 → `nft -c` → 成功后保存」的流程。其余
写入路径（添加/删除转发、封禁/解封 IP）都是 `jq ... > tmp && mv tmp state.json`
之后再调 `trigger_render`：状态先落盘，渲染失败时磁盘上已经是新状态，而内核里
还是旧规则。这是可以长期存在且不会自愈的漂移。

`render.sh` 与 `fw.sh` 各自持有不同的锁文件（`fwctl_render.lock` 与无锁），
并发写入没有统一的互斥边界。

进程还可能在「已应用到内核」和「已提交到磁盘」之间被 kill、OOM 或断电。这个窗口
里内核已改而磁盘未改，仅靠退出路径上的回滚代码无法覆盖——进程根本没有机会执行
那段代码。

## 决策

### 单一事务边界

所有会改变 `state.json`、`/etc/nftables.conf` 或运行中 ruleset 的操作，无一例外
地走同一个事务函数：

```text
flock(/run/lock/fwctl/fwctl.lock, 非阻塞)   冲突 → 退出码 4
  → 崩溃恢复：若存在未完成的 journal，先收敛
  → 候选：复制 state.json 到同目录同文件系统的临时文件
  → 变更：在候选上应用
  → 校验：schema + 语义 + 引用完整性 + 对象图方向
  → 渲染：候选 → build/candidate.nft
  → 检查：nft -c -f candidate.nft
  → 快照：nft list table ip fwctl → rollback.nft（并记录表是否存在）
  → journal：写入 prepared
  → 应用：nft -f candidate.nft
  → journal：标记 applied
  → 验证：表存在、chain 齐全、规则数符合渲染预期
  → 提交：原子替换 state.json、build/nft.conf、/etc/nftables.conf
  → journal：标记 committed 并删除
  → 释放锁
```

### 退出码 ABI

这套语义已冻结，是对外承诺的接口：

```text
0 success    1 validation    2 usage    3 runtime    4 lock    5 rollback completed
```

失败处理按阶段划分：

| 失败阶段 | 系统状态 | 动作 | 退出码 |
|---|---|---|---|
| 校验 | 完全未改动 | 删除候选 | 1 |
| 参数解析 | 完全未改动 | — | 2 |
| 渲染 / `nft -c` | 完全未改动 | 删除候选 | 3 |
| 获取锁 | 完全未改动 | — | 4 |
| 应用 | 内核可能已改 | 重放 rollback.nft | 5 |
| 应用后验证 | 内核已改 | 重放 rollback.nft | 5 |
| 提交 | 内核已改，磁盘未改 | 重放 rollback.nft | 5 |

退出码 5 的唯一含义是「内核已回滚到事务前状态，无需人工恢复」，与退出码 3 的
「失败发生在 apply 之前，系统本就未被改动」区分开。不新增退出码，除非确无替代
方案。

### 事务日志与崩溃恢复

事务在 apply 前写入 `journal.json`，记录阶段、候选路径、rollback 快照路径、本次
是否包含旧表接管。日志带 `journal_version` 字段——格式从第一天起就是有版本的，
未来演进不会与旧日志产生歧义；恢复逻辑遇到未知的更高 `journal_version` 时拒绝
自动恢复并明确报错，而不是按当前格式误解析。

任何 fwctl 命令启动时若发现处于非终态的 journal，先执行恢复：依据记录的阶段与
rollback 快照判定停在哪一步，要么重放回滚、要么完成提交，并把恢复结果输出给用户。

`metadata.legacy_adopted_at` 必须落在这个边界内：只能在 apply 成功后随提交写入，
理由见 [ADR 0002](0002-own-table-no-flush.md)。

### 显式错误传播

不依赖调用方的 `set -e`：`nft`、`mv`、`flock`、`mktemp` 等安全关键命令逐条显式
检查退出码并向上传播。成功提示只在提交完成后输出，任何中间步骤都不打印成功。

## 原因

- 状态、渲染产物和内核规则要么一起变，要么都不变，不存在部分发布。
- 单一锁文件让 CLI、render 兼容入口、restore、migration 共享同一个互斥边界。
- 回滚快照取自内核而非磁盘，因此即使 `/etc/nftables.conf` 已被手工改坏，回滚
  依然能把内核恢复到事务前的真实状态。
- 退出码可区分「什么都没发生」和「发生了但已撤销」，运维不需要猜。
- journal 覆盖的是进程根本没机会执行回滚代码的那段窗口，这是纯退出路径处理无法
  解决的。

## 后果

- `render.sh` 降级为兼容入口，内部调用同一事务函数，不再自带独立锁。
- 只读命令一律不获取写锁，避免巡检脚本阻塞真正的写操作；但它们同样会先收敛未完成
  的 journal。
- 事务需要探测外部事实（公网地址、本机地址、SSH 端口、待接管的旧表），这些探测在
  进入渲染之前完成并作为参数传入，渲染层保持为不接触网络与内核的纯函数，这样渲染
  可以在无 root 的测试环境中被完整验证。
- 备份在 restore 之前自动创建，restore 本身也走同一事务，失败即整体回滚。
- 崩溃恢复必须有测试：在 apply 与 commit 之间注入中断，断言下次调用能判定停留阶段
  并正确收敛。
