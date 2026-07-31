# fwctl

声明式 nftables 管理器。用持久状态描述防火墙、NAT 和端口转发，编译成 nftables
规则并事务化地发布。

安装后的命令名是 `fw`。

## 开发与生产目录

本目录是 fwctl 的唯一开发源。Gitea 仓库是权威源，GitHub 只是镜像。

生产部署位于 `/opt/fwctl`，生产配置位于 `/srv/docker/host-config/fwctl`。
不要直接在生产目录里开发。

## 升级须知（重要）

从旧版本升级时，**状态会在第一次写操作时自动迁移**，不需要手工改
`state.json`，也不需要执行任何迁移命令。迁移前会自动备份。

有一处需要人工检查的变化：

> **表名从 `sb_filter` / `sb_nat` 变成了 `fwctl`。**
> 任何按旧表名采集规则或计数的脚本、监控和告警都必须改为 `table ip fwctl`，
> 否则会静默采集不到数据。

旧表会在首次迁移时被识别、接管并删除，但只删除结构指纹确认属于旧版 fwctl 的
表——同名但来源未知的表会被保留并持续告警。

其余变化对用户不可见：`fw port`、`fw render`、交互菜单的用法和输出都没有变。
完整说明见 [docs/MIGRATION.md](docs/MIGRATION.md)。

## 快速开始

```bash
fw                      # 交互式菜单
fw port add tcp 443     # 放行端口
fw port list
fw render               # 重新编译并应用
fw doctor               # 体检
```

## 端口放行

```bash
fw port add tcp 443
fw port add udp 60000-61000
fw port add both 443
fw port remove tcp 443
fw port list
```

支持单端口和闭区间范围；协议支持 `tcp`、`udp`、`both`，输入大小写不敏感。
`both` 是一次逻辑操作，在 TCP 与 UDP 各存一份，渲染为两个 nftables interval
set，不会把范围展开成独立端口。重复添加与删除不存在的端口都是幂等的。

SSH 管理端口由独立规则放行，不需要再加进业务端口。SSH 和已放行端口的 accept
规则位于全局 SYN 限速之前，因此明确放行的端口不会被面向未放行端口的聚合限速
提前丢弃。

## 对象模型

端口转发用三层对象表达，而不是一张扁平表：

```text
Target        Service
      ↘      ↙
        Rule
```

- **Target**：命名地址对象。地址集中存放，换落地机 IP 只需要改一处。
- **Service**：命名端口 + 协议对象，可被多条规则复用。
- **Rule**：引用 Target 与 Service，自身不保存地址与端口。

```bash
fw target add edge 192.0.2.20
fw service add https both 443
fw rule add edge-https --type forward --service https --target edge

fw target list
fw rule list
fw rule disable edge-https
```

三类对象都有不可变 `id` 和可读 `name`。规则按 `id` 引用，因此重命名不破坏任何
引用；CLI 输出一律优先显示 `name`。

**Target 可变，Service 不可变。** 改 Target 的地址会传播到全部引用它的规则——
这正是它存在的意义。Service 的 `(protocol, ports)` 是值，创建后冻结；改值等于
新建对象并重写引用，因此必须显式声明范围：

```bash
fw service edit https --ports 8443 --refs edge-https
fw service edit https --ports 8443 --all-refs
```

缺少 `--refs` / `--all-refs` 时命令会拒绝执行，并列出当前全部引用方。
Service 没有 `enable` / `disable`：启用状态属于 Rule。

## NAT 出站模式

```json
{ "settings": { "nat": { "mode": "auto", "snat_address": null } } }
```

- `auto`：优先使用 `snat_address`，未配置时查询公网 IPv4。只有候选地址确实存在
  于本机接口，才生成 `snat to <地址>`；否则生成 `masquerade`。
- `snat`：必须设置合法且存在于本机接口的 `snat_address`，否则拒绝生成。
- `masquerade`：始终使用出口接口地址做源 NAT。

普通 VPS 通常把公网 IPv4 直接配置在网卡上，`auto` 会选择显式 SNAT。AWS EC2 的
EIP 等 1:1 NAT 地址不出现在实例网卡中，把它写进 `snat to` 会产生源地址不属于
本机的数据包并可能被云网络丢弃，因此 `auto` 会选择 `masquerade`。判断不依赖
云厂商的 Metadata Service。

## 安全默认值与推荐配置

`settings.policy` 的默认值刻意与旧版本保持一致，**升级和全新安装取同一套默认
值**。升级不应该静默改变已生效的放行与拦截语义。

| 字段 | 默认 | 效果 | 更严格的选择 |
|---|---|---|---|
| `input` | `drop` | 未放行的入站一律丢弃 | — |
| `syn_limit.enabled` | `true` | 对未放行端口的 SYN 聚合限速 | — |
| `ct_invalid` | `ignore` | 不处理 invalid 状态的包 | `drop` |
| `icmp_echo` | `drop` | ping 不通 | `limit`（限速放行，便于排障） |

推荐的两处调整及其影响：

- **`ct_invalid: "drop"`**：丢弃 conntrack 判定为 invalid 的包。这类包通常是
  扫描、乱序重传或连接跟踪表溢出的产物。风险很低，但在连接跟踪表被打满时可能
  误伤正常连接。
- **`icmp_echo: "limit"`**：以 10/s 的速率放行 ping。代价是主机变得可被探测
  存活；收益是排障时能直接 ping 通。

修改方式是编辑 `state.json` 的 `settings.policy` 后执行 `fw render`。
`fw doctor` 会把这些作为建议输出，但**绝不会自动修改**。

## 事务与回滚

所有会改变状态、持久配置或运行中规则的操作都走同一条路径：

```text
全局锁 → 崩溃恢复 → 候选 → 校验 → 渲染 → nft -c → 内核快照
      → apply → 应用后验证 → 提交
```

任何一步失败都回到变更前的状态。退出码区分「什么都没发生」和「发生了但已撤销」：

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 校验失败 |
| 2 | 用法错误 |
| 3 | 运行时失败（渲染、apply、系统调用）——发生在 apply 之前，系统未被改动 |
| 4 | 锁冲突，另一个事务进行中 |
| 5 | 已回滚——变更曾被应用但随后失败，**内核状态已恢复**，无需人工处理 |

进程如果在 apply 与 commit 之间被 kill 或断电，下次执行任意 fwctl 命令时会自动
收敛：依据事务日志判断 commit 是否真的完成，要么补齐提交，要么回滚内核。

fwctl 只管理 `table ip fwctl` 一张表，**绝不执行 `flush ruleset`**，因此不会破坏
同机 Docker、fail2ban 或云 agent 写入的规则。

## 备份与恢复

```bash
fw backup create --label before-change
fw backup list
fw restore <backup-id>
```

`restore` 走与其他写操作相同的事务，恢复前会自动备份当前状态。

## 观测

```bash
fw doctor          # 14 项体检，只报告不修改
fw validate        # 校验状态
fw diff            # 比较当前状态与运行中的规则
fw stats           # 按规则统计流量
```

每条由对象生成的规则都带 `counter` 和 `comment "fwctl:<id>"`，`fw stats` 依据
这个前缀把内核计数器关联回对象并按名称显示。

## 其他

```bash
/opt/fwctl/render.sh --render-only    # 只生成并检查，不加载（兼容入口）
```

`net.ipv4.ip_forward` 在存在启用的转发规则且当前为 0 时会被开启，**但不会被自动
关闭**——它是全机共享的内核开关，Docker 或 WireGuard 可能正依赖它。需要恢复时
`fw doctor` 会给出确切命令。

## 文档

| 文档 | 内容 |
|---|---|
| [ARCHITECTURE](docs/ARCHITECTURE.md) | 分层、事实来源、渲染契约、事务模型 |
| [STATE_SCHEMA](docs/STATE_SCHEMA.md) | 状态结构、约束与校验清单 |
| [CLI](docs/CLI.md) | 完整命令契约与退出码 ABI |
| [MIGRATION](docs/MIGRATION.md) | 旧格式自动迁移与降级路径 |
| [DEVELOPER](docs/DEVELOPER.md) | 模块约定、测试计划、提交前检查 |
| [ADR](docs/adr/) | 架构决策记录 |

## 测试

```bash
fwctl/tests/run.sh                          # 默认：无 root、无内核
FWCTL_TEST_REAL_NFT=1 fwctl/tests/run.sh    # 追加真实 nft -c 复核
FWCTL_TEST_NETNS=1 fwctl/tests/run.sh       # 追加真实 apply / 回滚 / 崩溃恢复
```
