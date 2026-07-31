# fwctl State Schema

`state.json` 是 fwctl 的唯一事实来源。本文档定义 v4 schema 的结构、约束和校验
规则。v1（v3 程序使用的无版本号格式）的兼容与升级见
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
- 缺失：识别为 v1，自动迁移。
- `> 4`：拒绝加载并返回非零。旧程序不得覆盖新程序写入的状态。

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
| `nat.mode` | `auto` / `snat` / `masquerade` | `auto` | 语义与 v3 完全一致 |
| `nat.snat_address` | IPv4 或 `null` | `null` | `mode=snat` 时必填且必须存在于本机接口 |
| `ssh.mode` | `auto` / `fixed` | `auto` | `auto` 沿用 v3 的 ss/sshd_config/22 探测顺序 |
| `ssh.port` | 1–65535 或 `null` | `null` | `mode=fixed` 时必填 |
| `policy.input` | `drop` / `accept` | `drop` | input chain 默认策略 |
| `policy.forward` | `accept` / `drop` | `accept` | forward chain 默认策略 |
| `policy.syn_limit.enabled` | 布尔 | `true` | v3 的全局 SYN 限速 |
| `policy.ct_invalid` | `ignore` / `drop` | `ignore` | `ignore` 为 v3 行为，不产生规则 |
| `policy.icmp_echo` | `drop` / `accept` / `limit` | `drop` | `drop` 为 v3 行为，不产生规则 |
| `render.counters` | 布尔 | `true` | 关闭后 `fw stats` 不可用 |
| `render.comments` | 布尔 | `true` | 关闭后 `fw stats` 与 `fw diff` 精度下降 |

`ct_invalid` 和 `icmp_echo` 的默认值刻意选择「与 v3 行为一致」而不是「更安全」。
防火墙的默认行为变更必须由用户显式发起，升级不得改变已生效的放行与拦截语义。

## ports

简单放行清单，`fw port` 命令的直接后端。这是 v3 `open_ports` 的等价物，语义
逐字保留。

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

命名地址对象。**同一地址只保存一次**——这是 v4 取代 `forwards[]` 的核心动机。

```json
{
  "targets": [
    {
      "id": "tgt-a1b2c3",
      "name": "edge-node",
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
| `id` | `tgt-` + 6 位小写十六进制，创建后不可变，全局唯一 |
| `name` | `^[a-z0-9][a-z0-9_-]{0,31}$`，全局唯一，可重命名 |
| `kind` | `ipv4`（单地址或 CIDR 列表）/ `hostname`（记录解析来源） |
| `addresses` | 非空数组；IPv4 点分十进制或 `a.b.c.d/len`；数组内去重并排序 |
| `enabled` | 布尔；禁用后引用它的规则不渲染 |

约束：

1. 跨 target 的地址不得重复。同一个 IP 只能属于一个 target，否则拒绝写入并
   提示已占用它的 target 名。
2. `kind=hostname` 时额外保存 `hostname` 与 `resolved_at`。解析在写入时完成，
   渲染永不做 DNS 查询——渲染必须是不依赖网络的纯函数。
3. 单地址 target 渲染为字面量地址；多地址 target 渲染为 `set tgt_<name>`。

## services

命名端口 + 协议对象，可被多条规则复用。

```json
{
  "services": [
    {
      "id": "svc-d4e5f6",
      "name": "https",
      "protocol": "both",
      "ports": ["443"],
      "enabled": true,
      "created_at": "2026-07-31T00:00:00Z",
      "updated_at": "2026-07-31T00:00:00Z"
    }
  ]
}
```

| 字段 | 约束 |
|---|---|
| `id` | `svc-` + 6 位小写十六进制，不可变，全局唯一 |
| `name` | `^[a-z0-9][a-z0-9_-]{0,31}$`，全局唯一 |
| `protocol` | `tcp` / `udp` / `both` |
| `ports` | 非空 port spec 数组，去重排序，规则同 `ports` |
| `enabled` | 布尔 |

`protocol=both` 在存储中是**一个** service，渲染时展开成 TCP 与 UDP 两条规则。
v3 需要为同一映射保存两份 `forwards[]` 条目，v4 不再如此。

## rules

规则引用 target 和 service，自身不保存地址或端口。

```json
{
  "rules": [
    {
      "id": "rule-090807",
      "name": "edge-https",
      "type": "forward",
      "enabled": true,
      "priority": 100,
      "service": "svc-d4e5f6",
      "target": "tgt-a1b2c3",
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
| `id` | `rule-` + 6 位小写十六进制，不可变，全局唯一 |
| `name` | `^[a-z0-9][a-z0-9_-]{0,31}$`，全局唯一 |
| `type` | `accept` / `forward` / `block` |
| `enabled` | 布尔；`false` 时完全不渲染，不留占位规则 |
| `priority` | 0–1000 整数，默认 100；同 chain 内按 `(priority, id)` 升序渲染 |
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
时，整个范围映射到该单端口——这正是 v3 `dest_port` 的语义。

引用完整性：`service`、`target`、`source` 必须指向存在的对象，否则校验失败。
删除仍被引用的对象会被拒绝，并列出引用方；`--cascade` 可一并删除引用它的规则。

## comments

对象注释的集中存放处，键是对象 id。

```json
{
  "comments": {
    "rule-090807": "对外 HTTPS 入口，2026-07 迁移自旧网关",
    "tcp:443": "sb VLESS"
  }
}
```

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
    "migrated_from": 1
  }
}
```

`generation` 每次成功 commit 递增，用于 `fw diff` 与备份标识。
`migrated_from` 记录迁移来源版本，未迁移过则为 `null`。

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
      "id": "tgt-a1b2c3", "name": "edge-node", "kind": "ipv4",
      "addresses": ["192.0.2.20"], "enabled": true,
      "created_at": "2026-07-31T00:00:00Z", "updated_at": "2026-07-31T00:00:00Z"
    },
    {
      "id": "tgt-000001", "name": "blacklist", "kind": "ipv4",
      "addresses": ["198.51.100.7", "203.0.113.0/24"], "enabled": true,
      "created_at": "2026-07-31T00:00:00Z", "updated_at": "2026-07-31T00:00:00Z"
    }
  ],
  "services": [
    {
      "id": "svc-d4e5f6", "name": "https", "protocol": "both",
      "ports": ["443"], "enabled": true,
      "created_at": "2026-07-31T00:00:00Z", "updated_at": "2026-07-31T00:00:00Z"
    }
  ],
  "rules": [
    {
      "id": "rule-090807", "name": "edge-https", "type": "forward",
      "enabled": true, "priority": 100,
      "service": "svc-d4e5f6", "target": "tgt-a1b2c3", "source": null,
      "translate": { "port": null },
      "created_at": "2026-07-31T00:00:00Z", "updated_at": "2026-07-31T00:00:00Z"
    },
    {
      "id": "rule-000001", "name": "blacklist-drop", "type": "block",
      "enabled": true, "priority": 10,
      "service": null, "target": null, "source": "tgt-000001",
      "translate": { "port": null },
      "created_at": "2026-07-31T00:00:00Z", "updated_at": "2026-07-31T00:00:00Z"
    }
  ],
  "comments": {
    "rule-090807": "对外 HTTPS 入口"
  },
  "metadata": {
    "created_at": "2026-07-31T00:00:00Z",
    "updated_at": "2026-07-31T00:00:00Z",
    "last_applied_at": "2026-07-31T00:00:00Z",
    "generation": 1,
    "fwctl_version": "4.0.0",
    "migrated_from": 1
  }
}
```

## 校验清单

`fw validate` 与每次写事务执行相同的校验，分两级。

**结构校验（schema）**

1. 合法 JSON；顶层字段集合恰好为规定的八个。
2. `schema_version == 4`。
3. 每个字段类型正确；对象数组元素含全部必填字段。
4. id 前缀与格式正确；name 匹配命名正则。
5. port spec 格式与 1–65535 范围；起始端口不大于结束端口。
6. 枚举字段取值在允许集合内。

**语义校验（semantic）**

7. id 全局唯一；name 在各自类型内唯一。
8. `service` / `target` / `source` 引用可解析。
9. 规则类型与字段组合合法（如 `block` 不得带 `service`）。
10. 跨 target 地址不重复。
11. `nat.mode=snat` 时 `snat_address` 合法且存在于本机 IPv4 接口。
12. `ssh.mode=fixed` 时 `ssh.port` 合法。
13. `translate.port` 为单端口，不是范围。
14. `comments` 的键要么是存在的对象 id，要么是合法的 `tcp:`/`udp:` 合成键。

语义校验第 11 项依赖本机接口这一外部事实，因此由事务层探测后传入，`fw validate
--offline` 可跳过该项以便在非目标主机上校验状态文件。
