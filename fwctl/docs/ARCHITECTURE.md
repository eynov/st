# fwctl 架构

本文档描述 fwctl 的目标架构。它源自一次架构重写而非对旧实现的增量修补，但旧版本
的全部能力、CLI 入口和 `state.json` 都必须继续可用。重写前后的差异见
[MIGRATION.md](MIGRATION.md) 与各 ADR 的背景小节。

## 项目边界

fwctl 只负责一件事：**把声明式状态编译成 nftables ruleset 并安全发布**。

| 属于 fwctl | 不属于 fwctl |
|---|---|
| nftables filter 规则 | WireGuard |
| NAT（SNAT / masquerade / DNAT） | 任何 VPN 隧道 |
| 端口转发 | 代理与订阅 |
| 地址对象与端口对象模型 | DNS 解析服务 |
| 事务、校验、回滚 | 路由表与策略路由 |
| 渲染引擎 | 证书管理 |

边界是架构约束，不是当前实现范围的描述。任何新增能力若不能表达为
「一段 nftables 规则」，都不进入 fwctl。参见
[ADR 0005](adr/0005-scope-boundary.md)。

## 分层

```text
CLI 层        fw.sh  →  core/cli.sh
              命令解析、交互菜单、输出格式化。不直接写 state，不直接调用 nft。

模型层        core/model.sh  +  core/state.sh
              Target / Service / Rule 的 CRUD、引用解析、唯一性与语义校验。

迁移层        core/migration.sh
              schema_version 探测与旧格式升级。只在加载路径上运行一次。

渲染层        core/render.sh
              纯函数：state（JSON）→ nftables 配置文本。不触碰内核，不写系统文件。

事务层        core/transaction.sh
              候选 → 校验 → 渲染 → nft -c → apply → commit / rollback。
              唯一被允许调用 `nft -f` 和写 /etc/nftables.conf 的模块。

支撑层        core/common.sh   日志、错误、退出码、全局锁、临时文件
              core/backup.sh   备份与恢复
              core/doctor.sh   环境与一致性体检
              core/stats.sh    counter 读取
```

依赖方向自上而下，不允许反向依赖。渲染层不得读取内核状态；需要的外部事实
（公网地址、本机地址、SSH 端口）由事务层探测后作为参数传入。这样渲染是可
重放的纯函数，测试无需 root 也无需 mock 内核。

## 事实来源

`state.json` 是唯一事实来源。

- 运行中的 ruleset 是派生数据。
- `/etc/nftables.conf` 是派生数据。
- `build/nft.conf` 是派生数据。

三者都可以从 `state.json` 完整重建。任何直接修改 ruleset 或
`/etc/nftables.conf` 的操作都会在下一次 `fw render` 时被覆盖，`fw doctor`
会检出这种漂移。

## 目录布局

```text
fwctl/
├── fw.sh                  # 唯一 CLI 入口，安装后命令名为 fw
├── render.sh              # 兼容入口，转发到 core/render 的事务封装
├── install.sh
├── state.json             # 事实来源；仓库中的这份是当前 schema 的空状态模板
├── core/
│   ├── common.sh
│   ├── state.sh
│   ├── migration.sh
│   ├── model.sh
│   ├── render.sh
│   ├── transaction.sh
│   ├── backup.sh
│   ├── doctor.sh
│   ├── stats.sh
│   └── cli.sh
├── docs/
│   ├── ARCHITECTURE.md
│   ├── STATE_SCHEMA.md
│   ├── CLI.md
│   ├── MIGRATION.md
│   ├── DEVELOPER.md
│   └── adr/
└── tests/
```

运行期路径：

```text
/var/lib/fwctl/backups/<backup-id>/   备份
/var/lib/fwctl/rollback.nft           最近一次 apply 前的 ruleset 快照
/var/lib/fwctl/journal.json           未完成事务的日志，正常结束后删除
/run/lock/fwctl/fwctl.lock            全局写锁
/etc/nftables.conf                    持久化 ruleset
```

## 渲染契约

fwctl 只管理 `table ip fwctl` 一张表，绝不执行 `flush ruleset`。表的整体替换
使用 nftables 的原子惯用法：

```text
table ip fwctl { }        # 确保存在，已存在则为空操作
delete table ip fwctl     # 连同全部 chain / set / 计数器一起删除
table ip fwctl { ... }    # 用新内容重建
```

整份文件作为一个 netlink 事务提交，不存在规则为空的时间窗口。同一份文件还会
收编并删除 v3 遗留的 `sb_filter` 与 `sb_nat` 表。其他表（Docker、Kubernetes、
云 agent 写入的规则）完全不受影响。参见
[ADR 0002](adr/0002-own-table-no-flush.md)。

旧表的收编有前提：只删除通过**结构指纹**确认属于旧 fwctl 的表，且只在首次迁移时
执行一次。指纹不匹配的同名表一律保留并持续告警，绝不删除。详见
[ADR 0002](adr/0002-own-table-no-flush.md)。

表内同时容纳 filter 与 nat 两类 chain：

```text
table ip fwctl {
    set  blacklist / allow_tcp / allow_udp / tgt_<name>
    chain input        type filter hook input       priority filter;  policy drop;
    chain forward      type filter hook forward     priority filter;  policy accept;
    chain prerouting   type nat    hook prerouting  priority dstnat;  policy accept;
    chain postrouting  type nat    hook postrouting priority srcnat;  policy accept;
}
```

每条由对象生成的规则都带 `counter` 和 `comment "fwctl:<object-id>"`。comment
是稳定句柄：`fw stats` 通过 `nft -j list table ip fwctl` 读回 counter 并按
comment 关联回对象。counter 可以在 settings 中整体关闭。

### 渲染确定性

渲染必须是确定性的，且**与对象的插入历史无关**：相同 state 加相同外部事实，逐字节
产出相同文件。

- `state.json` 内各对象数组按 `id` 升序规范化存储；
- 规则按 `(priority, id)` 升序渲染；
- set 元素按区间起止数值排序并去重；
- chain 按固定顺序输出。

目的是让无关的变更不产生 diff 噪声：`fw diff` 中出现的每一行差异都对应一次真实的
语义变化，而不是某个对象恰好被后添加。

## 事务模型

所有写操作走同一条路径，没有例外：

```text
flock（全局写锁，非阻塞，冲突返回退出码 4）
  → 崩溃恢复：若存在未完成的 journal，先收敛它
  → 复制 state.json 为同目录候选文件
  → 在候选上应用变更
  → schema 校验 + 语义校验（引用可解析、地址合法、SNAT 地址在本机）
  → 渲染候选 → build/candidate.nft
  → nft -c -f candidate.nft            语法与内核可接受性检查
  → 快照当前 ruleset → rollback.nft    记录表此前是否存在
  → 写 journal（阶段=prepared，含候选路径、快照路径、是否含旧表接管）
  → nft -f candidate.nft               原子应用
  → journal 标记 applied
  → 应用后验证（表存在、chain 齐全、规则条数符合预期）
  → commit：原子替换 state.json、build/nft.conf、/etc/nftables.conf
  → journal 标记 committed 并删除
  → 释放锁
```

任何一步失败都回到进入事务前的状态：

- apply 之前失败 → 丢弃候选文件，内核与磁盘均未被触碰。
- apply 之后、commit 之前失败 → 重放 `rollback.nft` 恢复内核 ruleset，丢弃
  候选文件。若表在事务前不存在，回滚即删除该表。
- commit 阶段失败 → 同上回滚内核，并保留原 `state.json`。

无论成功还是失败，候选渲染产物 `build/candidate.nft` 都会在事务结束时被删除。
回滚之后若留下一份从未生效的渲染结果，运维检查 `build/` 时会把它误认成当前生效
的配置；已发布的配置始终是 `build/nft.conf` 与系统配置文件。

### 崩溃恢复

进程可能在 apply 与 commit 之间被 kill、OOM 或断电。这个窗口里内核已改而磁盘未改，
仅靠退出路径上的回滚无法覆盖。

因此事务在 apply 前写入 `journal.json`，其中带 `journal_version` 字段——日志格式
从第一天起就是有版本的，未来演进不会与旧日志产生歧义。恢复逻辑遇到未知的更高
`journal_version` 时拒绝自动恢复并明确报错，而不是按当前格式误解析。

任何 fwctl 命令启动时若发现处于非终态的 journal，先执行恢复：依据记录的阶段与
rollback 快照判定停在哪一步，要么重放回滚、要么完成提交，并把恢复结果输出给用户。

`metadata.legacy_adopted_at` 必须在这个边界内原子化：它只能在 `nft apply` 成功后
随事务提交写入。若在 apply 前预写，一次失败的首次迁移会让旧表永久失去被接管的
机会——下次 render 认为已接管、不再输出删除语句，旧表就此滞留。

成功提示只在全部步骤通过后输出，失败一律返回非零。退出码语义见 [CLI.md](CLI.md)，
完整决策见 [ADR 0003](adr/0003-single-transaction-boundary.md)。

## 只读路径

`fw port list`、`fw target list`、`fw rule show`、`fw validate`、`fw diff`、
`fw stats`、`fw doctor` 不获取写锁、不修改任何文件。`fw validate` 与
`fw diff` 会在临时目录渲染，但只读比较，不发布。

## 决策记录

| ADR | 主题 |
|---|---|
| [0001](adr/0001-declarative-object-model.md) | 声明式对象模型取代 `forwards[]` |
| [0002](adr/0002-own-table-no-flush.md) | 只管理自己的表，禁止 `flush ruleset` |
| [0003](adr/0003-single-transaction-boundary.md) | 单一事务边界与整体回滚 |
| [0004](adr/0004-automatic-schema-migration.md) | 自动 schema 迁移与渲染等价性验收 |
| [0005](adr/0005-scope-boundary.md) | fwctl 的能力边界 |

## 与 sb 的关系

`sb` 不管理防火墙（见 `sb/docs/adr/0002-firewall-is-an-external-responsibility.md`），
只输出端口需求。fwctl 是消费方，但两个项目之间没有代码依赖，也没有共享状态：
用户或运维把 sb 的端口需求通过 `fw port add` 写入 fwctl。这条边界保持不变。
