# ADR 0002：只管理自己的表，禁止 flush ruleset

- 状态：Proposed
- 日期：2026-07-31

## 背景

v3 生成的配置文件以 `flush ruleset` 开头，然后重建 `sb_filter` 与 `sb_nat`。
`flush ruleset` 清空的是**整机全部 nftables 规则**，包括 Docker、Kubernetes、
云厂商 agent、fail2ban 以及用户手工添加的表。虽然整份文件作为单个 netlink 事务
提交、不存在空窗，但事务提交后那些第三方规则确实消失了，只能等对应组件自己重
建（Docker 需要重启守护进程才会恢复）。

## 决策

fwctl 只拥有 `table ip fwctl` 一张表，永不执行 `flush ruleset`。整表替换使用
nftables 的原子惯用法：

```text
table ip fwctl { }        # 确保存在，已存在则为空操作
delete table ip fwctl     # 连同 chain、set、counter 一并删除
table ip fwctl { ... }    # 用新内容重建
```

同一份文件额外收编并删除 v3 遗留表：

```text
table ip sb_filter { }
delete table ip sb_filter
table ip sb_nat { }
delete table ip sb_nat
```

filter 与 nat 两类 chain 放在同一张表内，因此一次 `delete table` 就能原子替换
全部 fwctl 规则。

回滚快照同理：`nft list table ip fwctl` 的输出前面拼上「预声明 + delete」两行
即可重放。若事务开始时表不存在，回滚文件就只有这两行，效果是删除该表。

上述四点（预声明 + delete 惯用法、遗留表收编、单表容纳两类 chain、快照重放的
幂等性）已在 nftables v1.1.3 上实测通过，不是推断。

## 原因

- 不再破坏同机其他组件的防火墙规则。
- 所有权边界清晰：`table ip fwctl` 内的一切归 fwctl，外面的一切不归它。
- `delete table` 是内核侧的原子操作，与 `flush ruleset` 一样没有空窗，但作用域
  收敛到一张表。
- 表内计数器随表删除而清零，因此「重建即清零」的语义明确，`fw stats --reset`
  只需重放而不需要额外接口。

## 后果

- 表名从 `sb_filter` / `sb_nat` 变为 `fwctl`。依赖旧表名的外部脚本需要调整，这
  在迁移文档中作为用户可见变化列出。
- `policy drop` 的 input chain 与其他表的 input chain 并存时，nftables 会评估
  所有 chain，任一 drop 生效。这与 v3 行为相同（v3 也是 policy drop），但由于
  不再 flush，同机其他表的 input 规则会真正保留下来，需要在 `fw doctor` 中提示
  存在其他 input hook 的表。
- 空 set 不再需要 `127.0.0.2` / `65535` 占位元素，nftables 支持声明无 `elements`
  的空 set（已实测）。
