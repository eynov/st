# ADR 0002：只管理自己的表，禁止 flush ruleset

- 状态：Accepted
- 日期：2026-07-31

## 背景

旧版本生成的配置文件以 `flush ruleset` 开头，然后重建 `sb_filter` 与 `sb_nat`。
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

同一份文件额外收编并删除遗留表：

```text
table ip sb_filter { }
delete table ip sb_filter
table ip sb_nat { }
delete table ip sb_nat
```

### 旧表接管的三个限制

表名统一为 `table ip fwctl`。**不**保留 `sb_filter` / `sb_nat` 作为长期兼容表名，
**不**创建空的兼容表，**不**用重复规则同时维护新旧两套表。旧表只是遗留资产。

1. **只接管指纹匹配的表。** 删除前必须通过结构指纹确认该表确实属于旧 fwctl：
   `sb_filter` 需同时具备 `input` / `forward` 两条 chain（hook 与 priority 匹配）
   和 `blacklist`、`allowed_ports_tcp`、`allowed_ports_udp` 三个 set；`sb_nat` 需
   具备 nat 类型的 `prerouting` / `postrouting`。指纹不匹配即判定为来源未知，
   **保留不删**，转为 doctor 持续告警，需 `--adopt-legacy --force` 才强制接管。
   同名不等于同源——删掉别人的表比留着一张废表严重得多。
2. **只在首次迁移时执行一次。** 接管成功后写入 `metadata.legacy_adopted_at`，
   此后普通 render 不再输出任何旧表相关语句。
3. **接管标记的提交时机是安全关键的。** `legacy_adopted_at` 只能在 `nft apply`
   成功之后随事务提交写入，不能在渲染或 apply 之前预写：否则一次失败的首次迁移
   会让旧表永久失去被接管的机会（下次 render 认为已接管、不再输出删除语句，旧表
   就此滞留）。这个字段因此必须落在事务日志的崩溃恢复边界内，见
   [ADR 0003](0003-single-transaction-boundary.md)。

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

- **这是用户可见的 breaking change。** 表名从 `sb_filter` / `sb_nat` 变为
  `fwctl`，任何按旧表名采集规则或计数的外部脚本、监控和告警都必须迁移到
  `table ip fwctl`。迁移文档与 README 都要明确列出这一点。
- `policy drop` 的 input chain 与其他表的 input chain 并存时，nftables 会评估
  所有 chain，任一 drop 生效。这与旧版本行为相同（旧版也是 policy drop），但由于
  不再 flush，同机其他表的 input 规则会真正保留下来，需要在 `fw doctor` 中提示
  存在其他 input hook 的表。
- 空 set 不再需要 `127.0.0.2` / `65535` 占位元素，nftables 支持声明无 `elements`
  的空 set（已实测）。
