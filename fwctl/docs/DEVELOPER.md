# fwctl 开发者指南

本文档定义 v4 的模块约定、编码规范和测试计划。实现阶段以此为准。

## 模块约定

每个 `core/*.sh` 是一个只被 source 的库，不可直接执行，文件顶部声明职责与依赖。
依赖方向严格自上而下（CLI → 模型 → 事务 → 渲染 → 支撑），不允许反向或循环。

| 模块 | 职责 | 允许触碰 |
|---|---|---|
| `common.sh` | 日志、错误、退出码、全局锁、临时文件、原子替换 | 文件系统 |
| `state.sh` | 加载、schema 校验、语义校验、原子写回 | `state.json` |
| `migration.sh` | 版本探测、v1 → v4 转换 | 内存中的 JSON |
| `model.sh` | Target / Service / Rule 的 CRUD、引用解析、id 生成 | 内存中的 JSON |
| `render.sh` | state + 外部事实 → nft 文本 | 无（纯函数） |
| `transaction.sh` | 候选、校验、渲染、`nft -c`、apply、commit、rollback | 内核、系统文件 |
| `backup.sh` | 备份、列举、恢复 | 备份目录 |
| `doctor.sh` | 环境与一致性体检 | 只读探测 |
| `stats.sh` | counter 读取与格式化 | 只读 `nft -j` |
| `cli.sh` | 参数解析、子命令分发、输出格式化、交互菜单 | 以上模块 |

关键约束：

1. **只有 `transaction.sh` 可以调用 `nft -f` 和写 `/etc/nftables.conf`。** 其他
   模块一律不得改变内核状态。
2. **`render.sh` 是纯函数**：输入是状态 JSON 加一个「外部事实」JSON（公网地址、
   本机地址列表、SSH 端口），输出是 nft 文本。它不查 DNS、不读接口、不调
   `sysctl`、不读内核。这让渲染可以在无 root 环境中被完整测试。
3. 不依赖调用方的 `set -e`。安全关键命令逐条显式检查退出码并向上传播。
4. 函数职责单一；跨模块共享的逻辑放进 `common.sh`，不复制粘贴。
5. 所有新增函数都有注释说明用途、参数和退出码语义。

## 命名与错误

- 函数名 `<模块>_<动作>`，如 `state_load`、`render_table`、`txn_commit`。
- 模块私有函数加 `_` 前缀。
- 全局变量全大写并带 `FWCTL_` 前缀；局部变量一律 `local`。
- 错误信息写 stderr，成功信息写 stdout，退出码语义见 [CLI.md](CLI.md)。

## 环境变量（测试注入点）

沿用 v3 已有的注入点，v4 补齐缺口。所有变量都有生产默认值，测试通过覆盖它们
在无 root、无内核、无网络的条件下运行。

| 变量 | 用途 |
|---|---|
| `FWCTL_STATE_FILE` | 状态文件路径 |
| `FWCTL_BUILD_DIR` | 渲染产物目录 |
| `FWCTL_SYSTEM_CONF` | 持久化目标，默认 `/etc/nftables.conf` |
| `FWCTL_NFT_BIN` | nft 可执行文件，测试指向 fake-nft |
| `FWCTL_LOCKFILE` | 全局锁路径 |
| `FWCTL_BACKUP_DIR` | 备份根目录 |
| `FWCTL_PUBLIC_IPV4` | 覆盖公网地址探测 |
| `FWCTL_LOCAL_IPV4S` | 覆盖本机地址列表 |
| `FWCTL_SSH_PORT` | 覆盖 SSH 端口探测 |
| `FWCTL_ALLOW_UNPRIVILEGED` | 允许非 root 运行 |
| `FWCTL_SKIP_SYSTEM_SETUP` | 跳过 sysctl 与 systemd 操作 |
| `FWCTL_APPLY` | 置 0 时只渲染不 apply |
| `FWCTL_NOW` | 固定时间戳，用于确定性测试 |

## 测试计划

入口 `fwctl/tests/run.sh`，逐个执行 `tests/t-*.sh`，TAP 风格输出。默认全部用例
在无 root、无真实内核的环境中通过；带 `FWCTL_TEST_REAL_NFT=1` 时额外用真实
`nft -c` 复核渲染产物的语法。

| 套件 | 覆盖 |
|---|---|
| `t-schema.sh` | 八个顶层字段的存在性与类型；`schema_version` 缺失/等于 4/大于 4；多余顶层字段被拒；id 与 name 正则；port spec 边界 1 与 65535、反向区间、前导零、非法字符；枚举取值；引用完整性；跨 target 地址重复；`block` 携带 `service` 等非法字段组合；comments 键合法性 |
| `t-migration.sh` | [MIGRATION.md](MIGRATION.md) 的完整用例矩阵；渲染等价性断言；幂等性（迁移两次逐字节相同）；确定性（同输入同 id）；只读命令不写盘；迁移失败保留 v1；备份确实生成 |
| `t-render.sh` | 无 `flush ruleset`；预声明 + delete 惯用法存在；遗留表被收编删除；filter/nat chain 齐全；单地址渲染为字面量、多地址渲染为 set；空 set 无占位元素；`protocol=both` 展开为两条规则；端口范围渲染为 interval；`translate.port` 有值与为 `null` 的两种 dnat 形态；规则按 `(priority, id)` 排序；禁用对象不渲染；重复渲染逐字节一致 |
| `t-transaction.sh` | 校验失败不触碰内核与磁盘；`nft -c` 失败不 apply；apply 失败重放 rollback 并返回 5；应用后验证失败同样回滚；commit 失败回滚内核并保留原状态；候选文件在各失败路径均被清理；锁冲突返回 4；表此前不存在时回滚等于删表 |
| `t-cli.sh` | v3 命令逐字兼容（`port add/remove/list`、`render`、`--help`、退出码）；新增名词的 add/edit/delete/list/show/enable/disable 七个动词各自可用；`--json` 输出可被 jq 解析；用法错误返回 2；`--dry-run` 不改变任何文件 |
| `t-counter.sh` | 渲染产物中每条对象规则都带 `counter`；`render.counters=false` 时不带；`nft -j` 解析路径能按 comment 关联回对象；`fw stats` 在 counter 关闭时明确报错而非输出全零 |
| `t-comment.sh` | comment 渲染为 `fwctl:<id>`；用户注释写入与截断到 128 字节；含引号与换行的注释被拒；孤儿注释在写事务中清理；`render.comments=false` 时不渲染 |
| `t-compat.sh` | v1 状态文件直接可用；v3 的 `render.sh --render-only` 入口仍工作；交互菜单编号 1–12 未变；`fw port` 的提示文本与 v3 一致；生产状态快照端到端通过 |

固件：

- `tests/fixtures/render-v3.sh`：v3 渲染器快照，迁移等价性测试的基准。
- `tests/fixtures/fake-nft`：扩展现有版本，支持 `-f`、`-j list table`、可注入
  失败，用于事务与 counter 测试。
- `tests/fixtures/state-v1-*.json`：迁移用例矩阵的输入。
- `tests/fixtures/golden/*.nft`：渲染黄金文件。

## 提交前检查

```bash
fwctl/tests/run.sh
shellcheck fwctl/fw.sh fwctl/render.sh fwctl/install.sh \
           fwctl/core/*.sh fwctl/tests/*.sh fwctl/tests/fixtures/*.sh
git diff --check
```

ShellCheck 必须零 warning。不使用 `# shellcheck disable` 掩盖真实问题；确需
禁用时在同一行注明原因。
