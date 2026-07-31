# ADR 0005：fwctl 的能力边界

- 状态：Proposed
- 日期：2026-07-31

## 背景

fwctl 与 `sb` 位于同一仓库，同一批机器上还运行着 WireGuard、代理和 DNS。重写
架构时很容易顺手把「反正都要配防火墙」的相邻功能吸收进来：帮用户起隧道、同步
代理端口、管理解析记录、写路由表。v3 已经出现过苗头——`render.sh` 直接写
`/etc/sysctl.d/99-forward.conf` 并调用 `sysctl -w`，这是路由子系统而不是防火墙。

## 决策

fwctl 的能力边界是一句话：**能表达为一段 nftables 规则的，属于 fwctl；不能的，
不属于**。

属于：nftables filter、NAT（SNAT / masquerade / DNAT）、端口转发、地址与端口
对象模型、渲染、事务、校验、回滚、备份、计数。

不属于：WireGuard、任何 VPN 隧道、代理与订阅、DNS 服务、路由表与策略路由、
证书管理、云安全组、面板类防火墙。

重写不是引入这些能力的时机。任何新增需求若不能落成 nftables 规则，答案是「这
不是 fwctl 的职责」，而不是「加个模块」。

对 `ip_forward` 这一既有越界：保留行为（否则端口转发不工作），但收敛为受控的
显式步骤——仅当状态中存在启用的 forward 规则时才开启，写入前记录原值，并在
`fw doctor` 中报告。它是端口转发的前置条件，不是 fwctl 开始管理路由的入口。

## 原因

- 边界模糊的运维工具最终会变成谁都不敢升级的黑盒。
- 单一职责让事务模型成立：fwctl 的全部产出就是一张 nftables 表，因此「整体
  发布或整体回滚」是可实现的。一旦掺入隧道或 DNS，回滚就不再是原子的。
- `sb` 已经明确把防火墙划为外部职责（见
  `sb/docs/adr/0002-firewall-is-an-external-responsibility.md`）。对称地，fwctl
  也不反向管理 sb。两个项目通过「端口需求」这一数据契约协作，不共享代码或状态。

## 后果

- 依赖 fwctl 之外能力的需求，通过文档给出手工步骤或指向对应项目，不在 fwctl
  内实现。
- CLI 的名词集合封闭为 `port`、`target`、`service`、`rule`。新增名词需要新的
  ADR 说明它为什么是 nftables 概念。
- `ip_forward` 之外不得再新增对内核非 netfilter 子系统的写操作。
