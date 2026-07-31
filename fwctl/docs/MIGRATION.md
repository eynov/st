# fwctl 状态格式迁移方案

本文档描述从旧的无版本号状态格式（下称 v1）升级到 `schema_version: 4` 的方案。
「v1 / v4」在本文中是**状态格式的版本号**，不是项目品牌——项目本身就叫 fwctl。

目标：**升级即可用**。用户不需要修改 `state.json`，不需要执行迁移命令，不需要
重新添加任何规则。升级后第一次运行 fwctl 时自动完成迁移，且迁移失败不会破坏
原状态、不会改变运行中的 ruleset。

## 版本识别

| 检测结果 | 处理 |
|---|---|
| 文件不存在或为空 | 写入当前 schema 的默认状态 |
| 合法 JSON 且无 `schema_version` | 识别为 v1，执行迁移 |
| `schema_version == 4` | 直接加载 |
| `schema_version` 为其他整数或 `> 4` | 拒绝，退出码 1，提示程序版本过旧 |
| 非法 JSON | 拒绝，退出码 1，提示手工修复或 `fw restore` |

v3 的状态文件没有版本号，这是 v1。中间不存在 v2、v3 的磁盘格式——v3 程序沿用
了 v1 的文件结构，因此只有一条迁移路径。

**随包发布的 `fwctl/state.json` 模板本身就是当前 schema 的空状态**，且已是规范化
形态。因此全新安装不会走迁移路径：不打印升级提示、不写 pre-migration 备份、
`metadata.migrated_from` 保持 `null`。这个模板曾经是 v1 格式，导致每次全新安装
都要跑一次空转迁移并打印"已升级状态格式"——对第一次安装的人来说，那条提示只会
让人误以为自己升级了什么。修改模板不影响真实旧状态的迁移行为。

## v1 结构回顾

```json
{
  "nat_mode": "auto",
  "snat_address": null,
  "forwards": [
    {"sport":"29312","dport":"29312","dip":"192.0.2.20","proto":"tcp","dest_port":"29312"},
    {"sport":"29312","dport":"29312","dip":"192.0.2.20","proto":"udp","dest_port":"29312"}
  ],
  "open_ports": { "tcp": ["443"], "udp": ["60000-61000"] },
  "blacklist": ["198.51.100.7"]
}
```

## 字段映射

| 旧格式 | 当前 schema |
|---|---|
| `nat_mode` | `settings.nat.mode` |
| `snat_address` | `settings.nat.snat_address` |
| `open_ports.tcp` | `ports.tcp`（原样，含排序去重） |
| `open_ports.udp` | `ports.udp` |
| `blacklist[]` | 名为 `blacklist` 的 target + 名为 `blacklist` 的 block 规则 |
| `forwards[]` | 去重后的 targets + services + forward 规则 |
| — | `settings.ssh`、`settings.policy`、`settings.render` 取默认值 |
| — | `metadata.migrated_from = 1` |

v1 中不存在的字段一律取 [STATE_SCHEMA.md](STATE_SCHEMA.md) 的默认值，而默认值
的选取原则是**渲染结果与 v3 完全一致**。

## forwards 的分解

v1 每条 forward 都内联保存 `dip`，同一目标 IP 重复出现 N 次；`both` 协议还会
拆成 tcp、udp 两条记录。迁移要把它折回对象模型。

迁移的处理顺序与碰撞处理必须完全确定，否则黄金文件比对不成立：

- Target 按 IP 的 32 位数值升序处理；
- Service 按 `(protocol, 起始端口, 结束端口)` 升序处理；
- Rule 按其在 v1 `forwards[]` 中的原始下标处理；
- id 由**内容**哈希派生（不派生自本身也是推导结果的 name），碰撞时向哈希输入追加
  `#<n>`（n 从 2 起递增）重算，直到不冲突。

**第一步：抽取 target。** 收集全部 `dip` 去重，按点分十进制数值升序处理：

```text
192.0.2.20  → target name "t-192-0-2-20"，id 为 tgt- 加地址内容哈希的前 12 位
```

命名规则：`t-` + IP 的点替换为连字符。CIDR 的 `/` 替换为 `-`。若产生名称冲突
（理论上不可能，因为地址已去重），追加 `-2`、`-3` 后缀。

**第二步：合并协议。** 把 `(sport, dport, dip, dest_port)` 完全相同、仅 `proto`
不同的两条记录合并为一条 `protocol=both` 的规则。这是 v3 交互式添加 `both` 时
产生的固有形态，合并后对象数减半而渲染结果不变。

**第三步：抽取 service。** 每个不同的 `(protocol, 端口区间)` 组合生成一个
service：

```text
sport=29312, dport=29312           → ports ["29312"]
sport=40000, dport=40010           → ports ["40000-40010"]
```

service 命名：`s-<proto>-<portspec>`，如 `s-both-29312`、`s-udp-40000-40010`。
相同 `(protocol, ports)` 的多条 forward 复用同一个 service。

**第四步：生成 rule。**

```text
type      = "forward"
name      = "f-<target简名>-<service简名>" 截断到 32 字符
service   = 上一步的 service id
target    = 第一步的 target id
translate = { "port": dest_port }，若 dest_port 等于 sport 且 sport==dport 则为 null
priority  = 100 + 该 forward 在 v1 数组中的下标，保留原有顺序
            （priority 的上限是 65535，足以容纳任意规模的 v1 状态而无需截断；
             截断会让重叠规则的 DNAT 优先级在升级时静默改变）
```

`translate.port` 在「目的端口与源端口相同的单端口映射」这一最常见情况下可以置为
`null` 并渲染成 `dnat to <ip>`。这与 v1 渲染的 `dnat to <ip>:<port>` 在语义上
等价，但为了让迁移前后的 ruleset 尽可能贴近，迁移保留显式端口；`null` 优化只在
用户后续显式编辑时才可能出现。

## blacklist 的分解

```text
target: name="blacklist", kind="ipv4", addresses=<去重排序后的 v1 blacklist>
rule:   name="blacklist", type="block", source=<该 target>, priority=10
```

**v1 的 blacklist 为空时，不生成任何 Target 和 Rule。**

Target 的 `addresses` 必须非空（见 [STATE_SCHEMA.md](STATE_SCHEMA.md) 的 target
约束），因此「空 Target」在当前 schema 里根本无法表达。更重要的是，即使放宽这条
约束，一个引用空地址集合的规则也只会静默匹配不到任何流量——对防火墙来说，「看起来
启用、实际不生效」的规则是应当在设计上排除掉的形态。

不生成对象与「生成一个禁用规则」的渲染结果完全相同（都不产生任何规则），因此这个
选择不改变任何行为。用户后续执行 `fw target add blacklist <ip>` 时按需创建。

v1 的空 blacklist 曾被 v3 渲染成占位地址 `127.0.0.2`（因为空 set 当时无法表达）。
新实现不再需要这个占位；同理，v3 对空 `open_ports` 使用的 `65535` 占位也随之消失。

这是本次唯一刻意的渲染差异。它去掉的是从未生效的伪规则，不改变任何放行或拦截
语义。等价性测试**直接忽略这两个占位元素**（见下节归一化规则），并对「它们确实
消失了」单独断言——差异是被显式记录和测试的，不是被容忍范围默默吞掉的。

## 迁移的执行时机与安全性

迁移在状态加载路径上运行，任何 fwctl 命令都会触发，包括只读命令。但**只读命令
不写盘**：它们在内存中迁移后继续执行，磁盘上仍是旧格式。首次写事务才把新状态
落盘。这样 `fw port list` 不会因为被 root 之外的方式调用而意外改变文件。

写盘时的顺序：

```text
持有全局写锁
  → 校验 v1 状态可解析
  → 备份原文件到 /var/lib/fwctl/backups/pre-migration-<timestamp>/
    同时在状态目录留一份 state.json.v1.bak
  → 在内存中转换为新 schema
  → schema + 语义校验
  → 探测旧表并做结构指纹匹配，决定本次是否接管
  → 渲染，与「用旧渲染器渲染同一份 v1」的结果比对
  → nft -c 检查
  → 走标准事务：journal → apply → 验证 → 提交
  → 提交时才写入 metadata.legacy_adopted_at
```

任一步失败：删除候选文件，保留原 v1 `state.json` 与备份，返回非零，不留下半迁移
状态。用户可以继续使用旧程序，或修正问题后重试。

旧表接管有两个安全前提（[ADR 0002](adr/0002-own-table-no-flush.md)）：只删除结构
指纹确认属于旧 fwctl 的表，指纹不匹配的同名表保留并持续告警；`legacy_adopted_at`
只在 `nft apply` 成功后随事务提交写入，避免一次失败的迁移让旧表永久失去被接管的
机会。

迁移是幂等的：对已是当前 schema 的状态执行迁移是空操作。对同一份 v1 反复迁移产生
逐字节相同的结果（id 由内容哈希派生，不用随机数，时间戳来自文件 mtime 而非当前
时间）。这一点让迁移测试可以直接比对黄金文件。

## 入口端口冲突的消解

旧格式允许两条 forward 使用同一入口端口指向不同落地机。旧渲染器会照单生成两条
DNAT，而 `dnat` 是终结语句，因此**后一条从来不会生效**——这是一个静默的错误
配置。当前 schema 的校验会拒绝这种状态（见 STATE_SCHEMA 校验清单第 16 条）。

迁移不因此失败，否则这类主机将彻底无法升级。处理方式是：

- 保留全部规则，只把被遮蔽的那些置为 `enabled: false`；
- 保留的是渲染顺序上排在前面的那条（`priority` 最小），与旧实现「先匹配先生效」
  的语义一致；
- 在 `description` 中记录被禁用的原因与遮蔽它的规则名；
- 迁移时发出明确告警，指名两条冲突规则并给出处置建议。

运行时行为因此与旧版本完全一致——被遮蔽的规则本来就从未匹配到任何流量——同时
原本静默的错误配置变得显式可见。

这构成一处**已声明的渲染差异**：被遮蔽的规则不再出现在渲染结果中。等价性测试
不要求这类固件逐行相同，但要求差异**恰好**是那条失效规则涉及的行：不允许有任何
其他差异，也不允许新实现单方面多出规则。

需要注意的是，通过 CLI 新建或修改规则时，这类重叠**仍然直接被拒绝**（退出码 1）。
自动禁用只发生在迁移这一条路径上，用于承接既有的历史配置。

## 渲染等价性验证

迁移正确性的判定标准不是「字段搬完了」，而是「防火墙行为没变」。仓库**永久保留**
一份旧渲染器的快照（`tests/fixtures/render-v3.sh`）与旧格式状态样本
（`tests/fixtures/state-v1-*.json`），迁移测试对每个用例执行：

```text
v1 状态 --旧渲染器--> ruleset A
v1 状态 --迁移--> 新状态 --新渲染器--> ruleset B
归一化(A) == 归一化(B)
```

归一化只允许消除三类已声明差异：

1. 表名（`sb_filter` / `sb_nat` → `fwctl`）；
2. counter 与 comment 的增加；
3. 空 set 占位元素 `127.0.0.2` 与 `65535`。

其余任何差异都是迁移缺陷。

这些固件是长期资产，不随本次实现结束而删除：今后**任何**渲染改动都必须继续通过
这条链路，否则「升级不改变防火墙行为」这一承诺就失去了回归保护。

用例矩阵：

| 用例 | 覆盖点 |
|---|---|
| 空状态 | 默认值填充 |
| 仅 open_ports（单端口、范围、tcp/udp 各有） | ports 直通 |
| 仅 blacklist | block 规则生成 |
| 空 blacklist / 空 open_ports | 占位元素移除 |
| 单条 tcp forward | target/service/rule 三元组 |
| tcp+udp 成对 forward | 协议合并为 both |
| 多条 forward 共享同一 dip | target 去重，无重复 IP |
| 多条 forward 共享同一端口组合 | service 复用 |
| 端口范围 forward（sport≠dport） | 区间 service |
| dest_port ≠ sport | translate.port |
| nat_mode 三种取值 | settings.nat 映射 |
| 真实生产状态快照 | 端到端 |

## 降级

不提供自动降级。用户若需回到旧版本：

```bash
fw backup list
# 迁移前的备份 id 形如 pre-migration-20260731-120000
```

恢复 `state.json.v1.bak` 或该备份目录中的 `state.json`，再运行旧版的 `render.sh`。
旧版的 `flush ruleset` 会清掉 `table ip fwctl`，因此降级后 ruleset 由旧版完全
重建，不会残留新表。

## 用户视角

普通用户在升级后看到的全部变化：

1. 第一次执行写命令时输出一行 `已升级状态格式，备份位于 ...`。
2. `fw port`、`fw render`、交互菜单的用法和输出完全不变。
3. 多出 `fw target/service/rule/doctor/validate/diff/backup/restore/stats`。
4. **breaking change**：`nft list ruleset` 中表名从 `sb_filter` / `sb_nat` 变为
   `fwctl`，规则带上了 counter 和 comment。

除第 4 项外没有需要用户执行的动作。第 4 项要求检查外部依赖：任何按 `sb_filter` /
`sb_nat` 采集规则或计数的脚本、监控和告警都必须改为 `table ip fwctl`，否则会静默
采集不到数据。这是本次升级唯一需要人工介入的地方。
