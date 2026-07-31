# ADR 0003：单一事务边界与整体回滚

- 状态：Proposed
- 日期：2026-07-31

## 背景

v3 只有 `fw port` 走了「候选状态 → 渲染 → `nft -c` → 成功后保存」的流程。其余
写入路径（添加/删除转发、封禁/解封 IP）都是 `jq ... > tmp && mv tmp state.json`
之后再调 `trigger_render`：状态先落盘，渲染失败时磁盘上已经是新状态，而内核里
还是旧规则。这是可以长期存在且不会自愈的漂移。

`render.sh` 与 `fw.sh` 各自持有不同的锁文件（`fwctl_render.lock` 与无锁），
并发写入没有统一的互斥边界。

## 决策

所有会改变 `state.json`、`/etc/nftables.conf` 或运行中 ruleset 的操作，无一例外
地走同一个事务函数：

```text
flock(/run/lock/fwctl/fwctl.lock, 非阻塞)   冲突 → 退出码 4
  → 候选：复制 state.json 到同目录同文件系统的临时文件
  → 变更：在候选上应用
  → 校验：schema + 语义 + 引用完整性
  → 渲染：候选 → build/candidate.nft
  → 检查：nft -c -f candidate.nft
  → 快照：nft list table ip fwctl → rollback.nft（并记录表是否存在）
  → 应用：nft -f candidate.nft
  → 验证：表存在、chain 齐全、规则数符合渲染预期
  → 提交：原子替换 state.json、build/nft.conf、/etc/nftables.conf
  → 释放锁
```

失败处理按阶段划分，并用退出码区分：

| 失败阶段 | 系统状态 | 动作 | 退出码 |
|---|---|---|---|
| 校验 / 渲染 / `nft -c` | 完全未改动 | 删除候选 | 3 或 1 |
| 应用 | 内核可能已改 | 重放 rollback.nft | 5 |
| 应用后验证 | 内核已改 | 重放 rollback.nft | 5 |
| 提交 | 内核已改，磁盘未改 | 重放 rollback.nft | 5 |

退出码 5 的唯一含义是「内核已回滚到事务前状态，无需人工恢复」。

成功提示只在提交完成后输出。任何中间步骤都不打印成功。

不依赖调用方的 `set -e`：`nft`、`mv`、`flock`、`mktemp` 等安全关键命令逐条显式
检查退出码并向上传播。

## 原因

- 状态、渲染产物和内核规则要么一起变，要么都不变，不存在部分发布。
- 单一锁文件让 CLI、render 兼容入口、restore、migration 共享同一个互斥边界。
- 回滚快照取自内核而非磁盘，因此即使 `/etc/nftables.conf` 已被手工改坏，回滚
  依然能把内核恢复到事务前的真实状态。
- 退出码可区分「什么都没发生」和「发生了但已撤销」，运维不需要猜。

## 后果

- `render.sh` 降级为兼容入口，内部调用同一事务函数，不再自带独立锁。
- 只读命令一律不获取写锁，避免巡检脚本阻塞真正的写操作。
- 事务需要探测外部事实（公网地址、本机地址、SSH 端口），这些探测在进入渲染
  之前完成并作为参数传入，渲染层保持为不接触网络与内核的纯函数，这样渲染可以
  在无 root 的测试环境中完整验证。
- 备份在 restore 之前自动创建，restore 本身也走同一事务，失败即整体回滚。
