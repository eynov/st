# fwctl CLI 规范

安装后命令名为 `fw`。本文档是完整的命令契约：旧版本已有的命令必须逐字保持行为
不变，新增命令遵循统一的名词 + 动词结构。

## 兼容承诺

以下入口行为不变，包括提示文本、成功与失败的判定和交互流程：

```bash
fw                          # 交互式菜单
fw port add tcp|udp|both PORT|START-END
fw port remove tcp|udp|both PORT|START-END
fw port list
fw render
fw -h | --help | help
/opt/fwctl/render.sh --render-only
```

交互菜单的 12 个选项编号与含义不变。菜单新增的条目只能追加在末尾，不得改变
既有编号——用户和文档里存在「输入 4 放行端口」这样的肌肉记忆。

**关于退出码的一处例外**：旧版本从未文档化过自己的非零取值（渲染失败返回 1，
用法错误返回 2）。本文档冻结的 ABI 把「运行时失败」定为 3，因此渲染失败的取值
由 1 变为 3。零与非零的语义完全不变，`if fw port add ...; then` 这类判断不受
影响；只有区分具体非零取值的脚本会看到差异，而那本来就没有契约可依。用法错误
仍然是 2。

## 通用结构

```text
fw <名词> <动词> [参数...] [选项...]
fw <动作> [选项...]
```

名词：`port`、`target`、`service`、`rule`
动词：`add`、`edit`、`delete`、`list`、`show`、`enable`、`disable`

动作：`render`、`validate`、`diff`、`doctor`、`backup`、`restore`、`stats`

`port` 是遗留形态，只支持 `add`、`remove`、`list`。`remove` 是旧版拼写并永久保留；
同时接受 `delete` 作为别名，与新名词保持一致。

`service` 没有 `enable` / `disable`——Service 是不可变值对象，不持有启用状态。
需要停用某条转发时禁用对应的 Rule。

## 对象的显示

CLI、doctor、stats 和日志一律**优先显示 `name`**，仅在名称缺失或需要消歧时附带
`id`：

```text
edge-https                       # 常规
edge-https (rule-7a0e4b19cc85)   # 需要消歧时
```

`--json` 输出始终同时包含 `id` 与 `name`，供脚本按稳定标识消费。

## 全局选项

| 选项 | 说明 |
|---|---|
| `--dry-run` | 走完候选、校验、渲染、`nft -c`，不 apply、不 commit，打印将要发生的变更 |
| `--json` | 以 JSON 输出，供脚本消费。所有 `list` / `show` / `stats` / `validate` / `doctor` 支持 |
| `--yes` | 跳过破坏性操作的确认提示（`delete --cascade`、`restore`） |
| `--quiet` | 只输出错误 |
| `-h` `--help` | 任意层级可用；`fw rule --help` 输出该名词的用法 |

## 退出码 ABI

这套语义已冻结，是对外承诺的接口，不得随意扩展：

| 码 | 含义 |
|---|---|
| 0 | success |
| 1 | validation —— schema、语义、引用不存在 |
| 2 | usage —— 未知命令、参数个数不对 |
| 3 | runtime —— 渲染、apply、系统调用失败 |
| 4 | lock —— 获取全局写锁失败，另一个 fwctl 事务进行中 |
| 5 | rollback completed —— 变更已应用后失败，**内核状态已回滚**，无需人工恢复 |

退出码 5 与 3 的区别很重要：5 明确表示内核已经回滚到变更前状态；3 表示失败发生在
apply 之前，系统本就未被改动。运维不需要猜测系统处于哪种状态。

不新增退出码，除非确无替代方案。

## port

```bash
fw port add tcp 443
fw port add udp 60000-61000
fw port add both 443
fw port remove tcp 443
fw port delete tcp 443        # remove 的别名
fw port list
fw port list --json
```

语义与旧版本一致：`both` 是一次逻辑操作，在 tcp 与 udp 各写一份；重复添加幂等
并提示；删除不存在的端口提示且不改状态；非法协议与非法端口返回非零且不改状态。

## target

```bash
fw target add <name> <address>[,<address>...] [--description TEXT]
fw target add edge-node 192.0.2.20
fw target add cn-blocks 203.0.113.0/24,198.51.100.0/24
fw target add relay --hostname relay.example.com

fw target edit <name|id> [--name NEW] [--description TEXT]
                         [--address LIST] [--add-address A] [--del-address A] [--resolve]
fw target delete <name|id> [--cascade]
fw target list [--json]
fw target show <name|id> [--json]
fw target enable <name|id>
fw target disable <name|id>
```

Target 是可变实体：改地址会影响全部引用它的规则，这是设计意图。`fw target edit`
在修改地址时输出受影响的规则列表，`--dry-run` 可预览。

`--hostname` 在写入时解析一次并保存解析结果与时间戳；渲染不做 DNS 查询。
`fw target edit --resolve` 重新解析。

删除被规则引用的 target 返回退出码 1 并列出引用方；`--cascade` 连同引用它的
规则一起删除，需要 `--yes` 或交互确认。

`fw target list` 对地址集合完全相同的多个 Target 标注 `DUP`，提示可能重复，但这
不是错误——同一地址允许属于多个 Target。

## service

```bash
fw service add <name> <protocol> <port>[,<port>...] [--description TEXT]
fw service add https both 443
fw service add hy2-hop udp 60000-61000

fw service edit <name|id> --name NEW                    # 显示元数据，可直接改
fw service edit <name|id> --description TEXT
fw service edit <name|id> --ports LIST    --refs R1,R2  # 值变更，必须声明引用范围
fw service edit <name|id> --protocol P    --all-refs
fw service delete <name|id> [--cascade]
fw service list [--json]
fw service show <name|id> [--json]
```

Service 的 `(protocol, ports)` 是不可变的值。修改它们不是原地编辑，而是在同一
事务内新建一个 Service 并重写引用，因此必须显式声明重写范围：

- `--refs <规则列表>`：只把这些规则改指向新 Service，其余引用保持不变。
- `--all-refs`：重写全部引用。

缺少这两个选项时命令以退出码 2 拒绝，并列出当前的全部引用方，让用户看清楚爆炸
半径再决定。命令输出与 `--dry-run` 都会列出受影响的规则。

旧 Service 失去全部引用后仍被保留（可能仍有复用价值），`fw doctor` 报告为孤儿，
`fw service delete` 清理。

没有 `fw service enable/disable`：启用状态属于 Rule。

## rule

```bash
fw rule add <name> --type accept --service <ref> [--priority N] [--comment TEXT] [--description TEXT]
fw rule add <name> --type forward --service <ref> --target <ref> [--to-port P] [--priority N]
fw rule add <name> --type block --source <ref> [--priority N]

fw rule edit <name|id> [--name NEW] [--service R] [--target R] [--source R]
                       [--to-port P|--no-translate] [--priority N]
                       [--comment TEXT] [--description TEXT]
fw rule delete <name|id>
fw rule list [--type T] [--json]
fw rule show <name|id> [--json]
fw rule enable <name|id>
fw rule disable <name|id>
```

`<ref>` 接受 name 或 id。`--comment` 写入顶层 `comments` 映射并渲染进 nft
`comment`；`--description` 只是 CLI 显示用的元数据，不渲染。

`fw rule list` 默认输出：

```text
NAME          TYPE     ENABLED  PRI  SERVICE      TARGET/SOURCE   RENDERED
edge-https    forward  yes      100  https(both)  edge-node       2 rules
blacklist     block    yes       10  -            blacklist(2)    1 rule
```

## render

```bash
fw render              # 渲染 + 校验 + apply + 持久化
fw render --dry-run    # 渲染 + 校验 + nft -c，不 apply
fw render --output -   # 只把渲染结果写到 stdout，不接触内核与系统文件
```

`fw render` 无参数时的行为与旧版本相同。

渲染是确定性的：相同状态加相同外部事实产出逐字节相同的文件，输出顺序与对象的
插入历史无关。这样 `fw diff` 的差异只反映真实变更，不含排序噪声。

## validate

```bash
fw validate                 # schema + 语义 + 渲染 + nft -c
fw validate --offline       # 跳过依赖本机接口和内核的检查
fw validate --file PATH     # 校验指定状态文件而非当前状态
fw validate --json
```

只读，不获取写锁，不产生任何副作用。校验失败返回 1；WARN 不影响退出码。

## diff

```bash
fw diff                # 由当前 state 渲染，与运行中的 table ip fwctl 比较
fw diff --persisted    # 与 /etc/nftables.conf 中 fwctl 表的内容比较
fw diff --state PATH   # 比较两份状态文件的对象级差异
```

无差异时输出 `无差异` 并返回 0；有差异输出统一 diff 并返回 0（差异不是错误）。
`--exit-code` 时有差异返回 1，便于纳入巡检。

## doctor

```bash
fw doctor [--json]
```

按顺序检查并逐项报告 OK / WARN / FAIL：

1. 依赖：`nft`、`jq`、`flock` 存在且可执行。
2. 权限：以 root 运行。
3. 内核：nftables 可用，`nft list tables` 成功。
4. 状态：`state.json` 存在、可读、schema 与语义校验通过。
5. 迁移：是否存在待迁移的旧格式状态。
6. 事务：是否存在未完成的事务 journal。
7. 转发：`net.ipv4.ip_forward` 当前值、是否由 fwctl 修改过、恢复命令。
8. SSH 自锁风险：探测到的 SSH 端口是否会被当前策略放行。
9. 遗留表：是否仍存在 `sb_filter` / `sb_nat`，以及指纹是否匹配。
10. 漂移：运行中的 `table ip fwctl` 是否与当前 state 渲染结果一致。
11. 持久化：`/etc/nftables.conf` 是否与渲染结果一致，`nftables.service` 是否
    enabled。
12. 其他 input hook：同机是否存在其他会影响入站的表。
13. 对象卫生：孤儿 Service、地址完全重复的 Target。
14. 安全建议：`ct_invalid` / `icmp_echo` 的更严格取值建议。

第 14 项**只建议，绝不自动修改**。FAIL 时返回退出码 3，仅 WARN 返回 0。

## backup / restore

```bash
fw backup [--label TEXT]           # 输出 backup-id
fw backup list [--json]
fw backup show <backup-id>
fw restore <backup-id> [--dry-run] [--yes]
fw restore --file PATH             # 从导出的状态文件恢复
```

备份内容：`state.json`、渲染出的 `nft.conf`、`metadata`（时间、generation、
fwctl 版本、label）。存放于 `/var/lib/fwctl/backups/<backup-id>/`。

`restore` 走与其他写操作完全相同的事务：候选 → 校验 → 渲染 → `nft -c` →
apply → 验证 → commit。恢复的状态若校验不通过则整体拒绝，不做部分恢复。
restore 前自动创建一次当前状态的备份。

## stats

```bash
fw stats [--json]
fw stats <rule-name|id>
fw stats --reset [<rule-name|id>]
```

从 `nft -j list table ip fwctl` 读取 counter，按 `comment` 中的
`fwctl:<object-id>` 关联回对象，并按 name 显示：

```text
NAME          TYPE     PACKETS      BYTES
edge-https    forward   1,204,332   1.8 GiB
blacklist     block        84,201    5.1 MiB
ports-tcp     builtin     932,110    412 MiB
```

`settings.render.counters` 为 false 时，`fw stats` 明确报错说明 counter 已关闭
并给出开启方式，而不是输出全零。`--reset` 只清零计数器，不重建规则。

## 交互菜单

`fw` 不带参数时进入菜单。旧版的 1–12 项保持不变，新增：

```text
13. 对象管理 (target / service / rule)
14. 体检 (doctor)
15. 备份与恢复
16. 流量统计 (stats)
```

菜单项 10、11 继续输出「防护逻辑内嵌于模板」的提示，但文本改为指向
`settings.policy`——提示内容更新，编号与位置不变。

## 命令到事务的映射

| 命令 | 写锁 | 事务 | 触碰内核 |
|---|---|---|---|
| `port add/remove`、`target`/`service`/`rule` 的写动词、`render`、`restore` | 是 | 是 | 是 |
| `backup` | 是 | 否（只读快照） | 否 |
| `port list`、各 `list`/`show`、`validate`、`diff`、`doctor`、`stats` | 否 | 否 | 只读 |
| 任意命令加 `--dry-run` | 是 | 到 `nft -c` 为止 | 否 |

任何命令启动时若发现未完成的事务 journal，都会先执行崩溃恢复，然后再继续本次
操作（见 [ADR 0003](adr/0003-single-transaction-boundary.md)）。
