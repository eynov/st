# fwctl v1 → v4 迁移方案

目标：**升级即可用**。用户不需要修改 `state.json`，不需要执行迁移命令，不需要
重新添加任何规则。升级后第一次运行 fwctl 时自动完成迁移，且迁移失败不会破坏
原状态、不会改变运行中的 ruleset。

## 版本识别

| 检测结果 | 处理 |
|---|---|
| 文件不存在或为空 | 写入 v4 默认状态 |
| 合法 JSON 且无 `schema_version` | 识别为 v1，执行迁移 |
| `schema_version == 4` | 直接加载 |
| `schema_version` 为其他整数或 `> 4` | 拒绝，退出码 3，提示程序版本过旧 |
| 非法 JSON | 拒绝，退出码 3，提示手工修复或 `fw restore` |

v3 的状态文件没有版本号，这是 v1。中间不存在 v2、v3 的磁盘格式——v3 程序沿用
了 v1 的文件结构，因此只有一条迁移路径。

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

| v1 | v4 |
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

**第一步：抽取 target。** 收集全部 `dip` 去重，按点分十进制数值升序编号：

```text
192.0.2.20  → target name "t-192-0-2-20"，id 由地址的稳定哈希前 6 位生成
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
```

`translate.port` 在「目的端口与源端口相同的单端口映射」这一最常见情况下置为
`null`，渲染成 `dnat to <ip>`。这与 v1 渲染的 `dnat to <ip>:<port>` 在语义上
等价；为了让迁移后 ruleset 与迁移前**逐字节一致**，迁移保留显式端口，`null`
优化只在用户后续显式编辑时才可能出现。逐字节一致是迁移测试的验收条件。

## blacklist 的分解

```text
target: name="blacklist", kind="ipv4", addresses=<去重排序后的 v1 blacklist>
rule:   name="blacklist", type="block", source=<该 target>, priority=10
```

v1 的空 blacklist 会被 v3 渲染成占位地址 `127.0.0.2`（因为空 set 曾经无法表达）。
v4 支持空 set，因此迁移时空 blacklist 生成一个空 target 与一条被**禁用**的规则，
渲染结果中不再出现 `127.0.0.2`。这是 v4 唯一一处刻意的渲染差异，它去掉了一条
从未生效的伪规则，不改变任何放行或拦截语义。同理，v3 对空 `open_ports` 使用的
`65535` 占位也随之消失。

这两处差异在迁移测试中被显式断言，不是「渲染逐字节一致」条款的例外遗漏。

## 迁移的执行时机与安全性

迁移在状态加载路径上运行，任何 fwctl 命令都会触发，包括只读命令。但**只读命令
不写盘**：它们在内存中迁移后继续执行，磁盘上仍是 v1。首次写事务才把 v4 状态
落盘。这样 `fw port list` 不会因为被 root 之外的方式调用而意外改变文件。

写盘时的顺序：

```text
持有全局写锁
  → 校验 v1 状态可解析
  → 备份原文件到 /var/lib/fwctl/backups/pre-migration-<timestamp>/
    同时在状态目录留一份 state.json.v1.bak
  → 在内存中转换为 v4
  → v4 schema + 语义校验
  → 渲染 v4，与「用 v3 渲染器渲染同一份 v1」的结果比对
  → nft -c 检查
  → 原子替换 state.json
```

任一步失败：删除候选文件，保留原 v1 `state.json` 与备份，返回退出码 3，不触碰
内核。用户可以继续使用 v3 程序，或修正问题后重试。

迁移是幂等的：对已经是 v4 的状态执行迁移是空操作。对同一份 v1 反复迁移产生
逐字节相同的 v4（id 由内容哈希派生，不用随机数，时间戳来自文件 mtime 而非
当前时间）。这一点让迁移测试可以直接比对黄金文件。

## 渲染等价性验证

迁移正确性的判定标准不是「字段搬完了」，而是「防火墙行为没变」。实现阶段保留
一份 v3 渲染器的快照（`tests/fixtures/render-v3.sh`），迁移测试对每个用例执行：

```text
v1 状态 --v3渲染器--> ruleset A
v1 状态 --迁移--> v4 状态 --v4渲染器--> ruleset B
归一化(A) == 归一化(B)
```

归一化只允许消除下列已声明的差异：表名（`sb_filter`/`sb_nat` → `fwctl`）、
counter 与 comment 的增加、空 set 占位元素的移除。其余任何差异都是迁移缺陷。

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

v4 不提供自动降级。用户若需回到 v3：

```bash
fw backup list
# 迁移前的备份 id 形如 pre-migration-20260731-120000
```

恢复 `state.json.v1.bak` 或该备份目录中的 `state.json`，再运行 v3 的
`render.sh`。v4 的 `delete table ip fwctl` 与 v3 的 `flush ruleset` 都会清掉对方
的规则，因此降级后 ruleset 由 v3 完全重建，不会残留 v4 的表。

## 用户视角

普通用户在升级后看到的全部变化：

1. 第一次执行写命令时输出一行 `已将状态从 v1 升级到 v4，备份位于 ...`。
2. `fw port`、`fw render`、交互菜单的用法和输出完全不变。
3. 多出 `fw target/service/rule/doctor/validate/diff/backup/restore/stats`。
4. `nft list ruleset` 中表名从 `sb_filter`/`sb_nat` 变为 `fwctl`，规则带上了
   counter 和 comment。

除此之外没有需要用户执行的动作。
