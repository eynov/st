# ADR 0004：单一全局 writer 锁

- 状态：Accepted
- 日期：2026-07-25

## 决策

节点 writer、settings writer、backup、restore、migration 和 manager upgrade 共享
同一全局锁协议。锁竞争稳定返回退出码 `75`（`EX_TEMPFAIL`），调用方可稍后重试。

## 原因

不同锁文件无法阻止跨模块并发，可能让备份捕获半发布状态，或让 restore、migration
覆盖同时发生的节点/settings 变更。

## 后果

新增写路径必须在读取 live state/settings 前取得全局锁，并将锁持有到发布、服务
验收或 rollback 完成。只读 status/doctor 不得获取写锁或修改系统。
