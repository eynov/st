# fwctl State Schema

`state.json` 是 fwctl 的唯一事实来源。本文档定义当前 schema（`schema_version: 4`）
的结构、约束和校验规则。旧格式（无版本号）的兼容与升级见
[MIGRATION.md](MIGRATION.md)。

## 顶层结构

```json
{
  "schema_version": 4,
  "settings": {},
  "ports": {},
  "targets": [],
  "services": [],
  "rules": [],
  "comments": {},
  "metadata": {}
}
```

八个顶层字段全部必填。多余的顶层字段导致校验失败——这样才能保证降级时不会静默
丢弃数据。

`schema_version` 是整数。

- `4`：当前版本，直接加载。
- 缺失：识别为旧格式，自动迁移。
- `> 4`：拒绝加载并返回非零。旧程序不得覆盖新程序写入的状态。

## 对象图方向

对象图严格单向，Rule 是唯一的绑定者：

```text
Target        Service
      ↘      ↙
        Rule
```

Target 与 Service **永不互相引用**，也不引用 Rule。这是可被校验的硬约束：Target
与 Service 的对象内不得出现任何指向另外两类对象的字段（第 15 项校验）。

单向图的价值在于删除与替换的推理是局部的：删除一个 Service 只需检查 Rule 的引用，
不必递归追踪 Target；Service 的值变更也不可能沿着某条隐藏边传播到 Target。

## 对象身份

三类对象共用同一套身份规则。

| | 规则 |
|---|---|
| `id` | `<tgt\|svc\|rule>-` + 12 位小写十六进制。创建时生成一次，此后**永不重算** |
| `name` | `^[a-z0-9][a-z0-9_-]{0,31}$`，在各自类型内唯一，可自由重命名 |
| 引用 | 规则始终按 `id` 引用，因此重命名不破坏任何引用 |
| 显示 | CLI、doctor、stats 和日志优先显示 `name`，仅在需要消歧时附带 `id` |

`id` 由 `sha256(kind + 规范化内容)` 的前 12 位十六进制派生，不使用随机数或当前
时间——迁移的确定性依赖这一点（[ADR 0004](adr/0004-automatic-schema-migration.md)）。
碰撞时向哈希输入追加 `#<n>`（n 从 2 起递增）重算，直到不冲突。

重命名、改地址、改 description 都不重算 `id`。

## settings

全局行为开关。所有字段都有默认值，缺失时按默认值补齐并写回。

```json
{
  "settings": {
    "nat": {
      "mode": "auto",
      "snat_address": null
    },
    "ssh": {
      "mode": "auto",
      "port": null
    },
    "policy": {
      "input": "drop",
      "forward": "accept",
      "syn_limit": {
        "enabled": true,
        "rate": "50/second",
        "burst": 5
      },
      "ct_invalid": "ignore",
      "icmp_echo": "drop"
    },
    "render": {
      "counters": true,
      "comments": true
    }
  }
}
```

| 字段 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `nat.mode` | `auto` / `snat` / `masquerade` | `auto` | 语义与旧版本完全一致 |
| `nat.snat_address` | IPv4 或 `null` | `null` | `mode=snat` 时必填且必须存在于本机接口 |
| `ssh.mode` | `auto` / `fixed` | `auto` | `auto` 沿用旧版的 ss/sshd_config/22 探测顺序 |
| `ssh.port` | 1–65535 或 `null` | `null` | `mode=fixed` 时必填 |
| `policy.input` | `drop` / `accept` | `drop` | input chain 默认策略 |
| `policy.forward` | `accept` / `drop` | `accept` | forward chain 默认策略 |
| `policy.syn_limit.enabled` | 布尔 | `true` | 全局 SYN 限速 |
| `policy.ct_invalid` | `ignore` / `drop` | `ignore` | `ignore` 不产生规则 |
| `policy.icmp_echo` | `drop` / `accept` / `limit` | `drop` | `drop` 不产生规则 |
| `render.counters` | 布尔 | `true` | 关闭后 `fw stats` 不可用 |
| `render.comments` | 布尔 | `true` | 关闭后 `fw stats` 与 `fw diff` 精度下降 |

### 安全默认值是兼容默认值

`ct_invalid` 与 `icmp_echo` 的默认值刻意选择「与旧版本行为一致」而不是「更安全」，
并且**升级与全新安装取同一套默认值**，不做分裂。

理由：升级不得静默改变已生效的放行与拦截语义；而如果新装默认与升级默认不同，
同一份文档就无法描述两台机器的实际行为，排障时的第一个假设就会是错的。

`fw doctor` 会把更严格的取值作为最佳实践**建议**输出，但绝不自动修改。推荐配置及其
安全影响见 README。

## ports

简单放行清单，`fw port` 命令的直接后端，语义与旧版本 `open_ports` 逐字保留。

```json
{
  "ports": {
    "tcp": ["443", "60000-61000"],
    "udp": ["443"]
  }
}
```

- 元素是**字符串**形式的 port spec：`"N"` 或 `"N-M"`。
- `1 <= N <= M <= 65535`，无前导零。
- 数组内去重，按 `(起始端口, 结束端口)` 升序排序。
- `both` 不是存储形态：它是一次逻辑操作，在 `tcp` 和 `udp` 中各写入一份相同
  spec。`fw port list` 通过求交集反推 `BOTH` 分组显示。

`ports` 与 `rules` 中的 `accept` 规则渲染进同一组 nftables set。`ports` 是面向
「我要开个端口」的直达路径，`rules` 是面向「我要一条有名字、可禁用、可统计的
规则」的通用路径。两者是同一底层能力的两个入口，不是两套实现。

## targets

命名地址对象。地址集中保存在这里，规则只持引用——这是取代 `forwards[]` 的核心
动机：换落地机 IP 只需要改一处。

```json
{
  "targets": [
    {
      "id": "tgt-9f2c41a7be03",
      "name": "edge-node",
      "description": "香港落地",
      "kind": "ipv4",
      "addresses": ["192.0.2.20"],
      "enabled": true,
      "created_at": "2026-07-31T00:00:00Z",
      "updated_at": "2026-07-31T00:00:00Z"
    }
  ]
}
```

| 字段 | 约束 |
|---|---|
| `id` | `tgt-` + 12 位小写十六进制，创建后不可变，全局唯一 |
| `name` | `^[a-z0-9][a-z0-9_-]{0,31}$`，全局唯一，可重命名 |
| `description` | 显示元数据，可为空字符串；不渲染，不参与任何语义判断 |
| `kind` | `ipv4`（单地址或 CIDR 列表）/ `hostname`（记录解析来源） |
| `addresses` | 非空数组；IPv4 点分十进制或 `a.b.c.d/len`；数组内去重并排序 |
| `enabled` | 布尔；禁用后引用它的规则不渲染 |

### Target 是可变实体

Target 的身份是 `id`。地址可以原地修改，全部引用它的规则随之改变——**这是刻意的
传播行为，也是引入 Target 的全部意义**。与 Service 的不可变性对照见
[ADR 0001](adr/0001-declarative-object-model.md)。

约束：

1. **地址不要求跨 target 唯一。** 同一个地址可以同时属于多个 Target，用于表达
   不同用途的逻辑目标、不同生命周期或所有者、同一主机上的不同业务，以及迁移期
   新旧对象并存。地址集合完全相同的多个 Target 由 `fw validate` 与 `fw doctor`
   输出 WARN 提醒可能重复，schema 层不拒绝。
2. `kind=hostname` 时额外保存 `hostname` 与 `resolved_at`。解析在写入时完成，
   渲染永不做 DNS 查询——渲染必须是不依赖网络的纯函数。
3. 单地址 target 渲染为字面量地址；多地址 target 渲染为 `set tgt_<name>`。
4. 对象内不得出现指向 Service 或 Rule 的字段。

## services

命名端口 + 协议对象，可被多条规则复用。

```json
{
  "services": [
    {
      "id": "svc-3d81c0be5f24",
      "name": "https",
      "description": "对外 HTTPS",
      "protocol": "both",
      "ports": ["443"],
      "created_at": "2026-07-31T00:00:00Z",
      "updated_at": "2026-07-31T00:00:00Z"
    }
  ]
}
```

| 字段 | 约束 |
|---|---|
| `id` | `svc-` + 12 位小写十六进制，不可变，全局唯一 |
| `name` | `^[a-z0-9][a-z0-9_-]{0,31}$`，全局唯一，可重命名 |
| `description` | 显示元数据，可为空字符串；不渲染 |
| `protocol` | `tcp` / `udp` / `both`，**创建后不可变** |
| `ports` | 非空 port spec 数组，去重排序，**创建后不可变** |

### Service 是不可变值对象

`(protocol, ports)` 构成 Service 的**值**，创建后冻结。`name` 与 `description`
是显示元数据，可以自由修改。

**Service 没有 `enabled` 字段。** 启用状态属于 Rule。一个 Service 可能被多条互不
相关的规则引用，如果它可以被禁用，那么禁用动作就会隐式影响所有引用方——这正是
值对象要避免的爆炸半径。「停掉某条转发」的正确表达是禁用那条 Rule。

改变 Service 的值不是原地修改，而是新建对象 + 显式重写引用：

```bash
fw service edit https --ports 8443 --refs edge-https,backup-https
fw service edit https --ports 8443 --all-refs
```

`--refs` 或 `--all-refs` 是必填的，命令在同一事务内新建 Service 并只重写指定的
引用，输出与 `--dry-run` 列出全部受影响规则。旧 Service 若因此失去全部引用则被
保留（可能仍有复用价值），由 `fw doctor` 报告为孤儿，用 `fw service delete` 清理。

`protocol=both` 在存储中是**一个** Service，渲染时展开成 TCP 与 UDP 两条规则。
旧格式需要为同一映射保存两份 `forwards[]` 条目。

约束：对象内不得出现指向 Target 或 Rule 的字段。

## rules

规则引用 target 和 service，自身不保存地址或端口。

```json
{
  "rules": [
    {
      "id": "rule-7a0e4b19cc85",
      "name": "edge-https",
      "description": "",
      "type": "forward",
      "enabled": true,
      "priority": 100,
      "service": "svc-3d81c0be5f24",
      "target": "tgt-9f2c41a7be03",
      "source": null,
      "translate": { "port": "8443" },
      "created_at": "2026-07-31T00:00:00Z",
      "updated_at": "2026-07-31T00:00:00Z"
    }
  ]
}
```

| 字段 | 约束 |
|---|---|
| `id` | `rule-` + 12 位小写十六进制，不可变，全局唯一 |
| `name` | `^[a-z0-9][a-z0-9_-]{0,31}$`，全局唯一，可重命名 |
| `description` | 显示元数据，不渲染 |
| `type` | `accept` / `forward` / `block` |
| `enabled` | 布尔；`false` 时完全不渲染，不留占位规则 |
| `priority` | 0–65535 整数，默认 100；同 chain 内按 `(priority, id)` 升序渲染 |
| `service` | service 的 id；`accept`、`forward` 必填，`block` 必须为 `null` |
| `target` | target 的 id，作为 **DNAT 目的地**；仅 `forward` 必填，其余为 `null` |
| `source` | target 的 id，作为 **saddr 匹配源**；仅 `block` 必填，其余为 `null` |
| `translate.port` | 单端口 spec 或 `null`；仅 `forward` 允许 |

三种规则类型的渲染：

| type | chain | 生成 |
|---|---|---|
| `accept` | `input` | `<proto> dport <ports> counter accept` |
| `block` | `input` | `ip saddr <source> counter drop`，置于 accept 规则之前 |
| `forward` | `prerouting` + `postrouting` | DNAT 加对应 SNAT/masquerade |

`translate.port` 为 `null` 时渲染 `dnat to <addr>`（保持原目的端口）；有值时
渲染 `dnat to <addr>:<port>`。service 是端口范围而 `translate.port` 是单端口
时，整个范围映射到该单端口——这正是旧格式 `dest_port` 的语义。

引用完整性：`service`、`target`、`source` 必须指向存在的对象，否则校验失败。
删除仍被引用的对象会被拒绝，并列出引用方；`--cascade` 可一并删除引用它的规则。

## comments

**渲染进 nftables `comment` 属性**的运维注释，键是对象 id。

```json
{
  "comments": {
    "rule-7a0e4b19cc85": "对外 HTTPS 入口，2026-07 迁移自旧网关",
    "tcp:443": "sb VLESS"
  }
}
```

与对象上的 `description` 的分工：

| | 存放位置 | 是否渲染 | 用途 |
|---|---|---|---|
| `description` | 对象内 | 否 | CLI `list` / `show` 的显示元数据 |
| `comments` | 顶层映射 | 是 | `nft list` 中可见的运维注释，`fw stats` 的关联句柄 |

集中存放而非放在对象内部，有两个原因：

1. `ports` 的元素是裸字符串，没有可挂载注释的对象，只能用 `tcp:<spec>` /
   `udp:<spec>` 形式的合成键。
2. 注释是纯人类元数据，与渲染语义无关。集中存放让「删除注释」不构成对象变更，
   也让 `fw diff` 可以忽略注释噪声。

注释文本禁止出现 `"` 与换行；渲染进 nft `comment` 时截断到 128 字节（nftables
上限）。孤儿注释（对象已删除）在下一次写事务中被清理。

## metadata

由程序维护，用户不应手工编辑。

```json
{
  "metadata": {
    "created_at": "2026-07-31T00:00:00Z",
    "updated_at": "2026-07-31T00:00:00Z",
    "last_applied_at": "2026-07-31T00:00:00Z",
    "generation": 42,
    "fwctl_version": "4.0.0",
    "migrated_from": 1,
    "legacy_adopted_at": "2026-07-31T00:00:00Z",
    "ip_forward": {
      "changed_by_fwctl": true,
      "original_value": "0",
      "changed_at": "2026-07-31T00:00:00Z"
    }
  }
}
```

| 字段 | 说明 |
|---|---|
| `generation` | 每次成功 commit 递增，用于 `fw diff` 与备份标识 |
| `migrated_from` | 迁移来源 schema 版本，未迁移过则为 `null` |
| `legacy_adopted_at` | 旧表接管完成时间。**只在 `nft apply` 成功后随事务提交写入**，见 [ADR 0002](adr/0002-own-table-no-flush.md)。为 `null` 时每次 render 都会重新探测旧表 |
| `ip_forward` | fwctl 是否修改过 `net.ipv4.ip_forward` 及其原值。fwctl 只开不关，此字段供 doctor 输出恢复命令和卸载流程使用，见 [ADR 0005](adr/0005-scope-boundary.md) |

## 校验清单

`fw validate` 与每次写事务执行相同的校验，分两级。

**结构校验（schema）**

1. 合法 JSON；顶层字段集合恰好为规定的八个。
2. `schema_version == 4`。
3. 每个字段类型正确；对象数组元素含全部必填字段。
4. id 前缀与 12 位十六进制格式正确；name 匹配命名正则。
5. port spec 格式与 1–65535 范围；起始端口不大于结束端口。
6. 枚举字段取值在允许集合内。
7. Service 不含 `enabled` 字段。

**语义校验（semantic）**

8. id 全局唯一；name 在各自类型内唯一。
9. `service` / `target` / `source` 引用可解析。
10. 规则类型与字段组合合法（如 `block` 不得带 `service`）。
11. `nat.mode=snat` 时 `snat_address` 合法且存在于本机 IPv4 接口。
12. `ssh.mode=fixed` 时 `ssh.port` 合法。
13. `translate.port` 为单端口，不是范围。
14. `comments` 的键要么是存在的对象 id，要么是合法的 `tcp:`/`udp:` 合成键。
15. 对象图方向：Target 与 Service 对象内不含指向其他对象类型的字段。

**警告（WARN，不阻断）**

- 地址集合完全相同的多个 Target。
- 失去全部引用的孤儿 Service。
- 存在来源未知、指纹不匹配的同名旧表。

第 11 项依赖本机接口这一外部事实，因此由事务层探测后传入，`fw validate --offline`
可跳过该项以便在非目标主机上校验状态文件。

## 完整示例

```json
{
  "schema_version": 4,
  "settings": {
    "nat": { "mode": "auto", "snat_address": null },
    "ssh": { "mode": "auto", "port": null },
    "policy": {
      "input": "drop",
      "forward": "accept",
      "syn_limit": { "enabled": true, "rate": "50/second", "burst": 5 },
      "ct_invalid": "ignore",
      "icmp_echo": "drop"
    },
    "render": { "counters": true, "comments": true }
  },
  "ports": {
    "tcp": ["443"],
    "udp": ["60000-61000"]
  },
  "targets": [
    {
      "id": "tgt-9f2c41a7be03", "name": "edge-node", "description": "",
      "kind": "ipv4", "addresses": ["192.0.2.20"], "enabled": true,
      "created_at": "2026-07-31T00:00:00Z", "updated_at": "2026-07-31T00:00:00Z"
    },
    {
      "id": "tgt-0b5e77d1a942", "name": "blacklist", "description": "",
      "kind": "ipv4", "addresses": ["198.51.100.7", "203.0.113.0/24"],
      "enabled": true,
      "created_at": "2026-07-31T00:00:00Z", "updated_at": "2026-07-31T00:00:00Z"
    }
  ],
  "services": [
    {
      "id": "svc-3d81c0be5f24", "name": "https", "description": "",
      "protocol": "both", "ports": ["443"],
      "created_at": "2026-07-31T00:00:00Z", "updated_at": "2026-07-31T00:00:00Z"
    }
  ],
  "rules": [
    {
      "id": "rule-7a0e4b19cc85", "name": "edge-https", "description": "",
      "type": "forward", "enabled": true, "priority": 100,
      "service": "svc-3d81c0be5f24", "target": "tgt-9f2c41a7be03", "source": null,
      "translate": { "port": null },
      "created_at": "2026-07-31T00:00:00Z", "updated_at": "2026-07-31T00:00:00Z"
    },
    {
      "id": "rule-c41d8f5a2e60", "name": "blacklist-drop", "description": "",
      "type": "block", "enabled": true, "priority": 10,
      "service": null, "target": null, "source": "tgt-0b5e77d1a942",
      "translate": { "port": null },
      "created_at": "2026-07-31T00:00:00Z", "updated_at": "2026-07-31T00:00:00Z"
    }
  ],
  "comments": {
    "rule-7a0e4b19cc85": "对外 HTTPS 入口"
  },
  "metadata": {
    "created_at": "2026-07-31T00:00:00Z",
    "updated_at": "2026-07-31T00:00:00Z",
    "last_applied_at": "2026-07-31T00:00:00Z",
    "generation": 1,
    "fwctl_version": "4.0.0",
    "migrated_from": 1,
    "legacy_adopted_at": "2026-07-31T00:00:00Z",
    "ip_forward": {
      "changed_by_fwctl": true,
      "original_value": "0",
      "changed_at": "2026-07-31T00:00:00Z"
    }
  }
}
```
