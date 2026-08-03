# 安装、升级、迁移、备份与恢复

> 本文描述本项目的运维契约。其中 app/current 链接切换的失败传播、manager 安装与回滚、
> rc=70 不可自动恢复的传播，都有覆盖测试；真实 systemd 层面的行为另在真实主机上验证，
> 范围与尚未验证的边界见 [`KNOWN_LIMITATIONS.md`](internal/KNOWN_LIMITATIONS.md)。

## 安装分层

1. 根入口 `file.sh sb` 获取本地 source 或 HTTPS 归档；归档必须提供 SHA256。
2. `sb/install.sh` 校验源码，把程序复制到 staging release，通过自检后原子切换 app。
3. `sb install` 安装依赖与固定 sing-box 核心，创建目录和 systemd unit。
4. 迁移旧数据或创建空 state；无节点时服务 enabled 但 stopped。
5. 用户显式执行 `sb add` 添加首个节点，候选配置通过后才启动服务。

任一步失败均返回非零；只有命令链接、固定核心、配置目录、unit、enabled 状态和
有节点时 active/listener 验收全部通过后才显示成功。

非交互安装必须提供 endpoint，并使用 `--yes`。可同时选择
`--listen-mode dual|ipv4|ipv6`。

## 管理器升级

```bash
sb upgrade --source /path/to/reviewed/sb --yes

# 当 reviewed source 改变 sing-box pin 时
sb upgrade --source /path/to/reviewed/sb --upgrade-core --yes

# 首次迁移：已安装的旧 manager 还不认识 --upgrade-core
env -u SB_APP_DIR /path/to/reviewed/sb/sb upgrade \
  --source /path/to/reviewed/sb --upgrade-core --yes
```

升级前备份 app、state、cert、output、unit 与核心。新源码先执行 Bash 语法、版本
元数据与来源校验，复制进 staging 目录后**再校验一次**，才原子发布为新 release；
随后原子切换 app 链接，由新版本执行 self-check 与完整 install 验收。

manager 在任何备份或链接切换之前读取当前 pin 与 source pin。二者不同时，未带
`--upgrade-core` 的命令以 `64` 拒绝并给出精确迁移命令。显式授权后，升级共用一个全局锁和
一份 pre-manager 备份：先切换新 manager，再由新 manager 安装并验证其固定核心，最后执行
install。app、旧核心与 receipt、unit、settings/state/generation/certs/output 属于同一个
rollback 边界。

首个引入该能力的生产升级必须使用上面的 reviewed-source 入口。它加载新升级逻辑，但从
`/opt/sb/app` 读取实际已安装 manager 的 pin，并让**旧 manager**在同一继承锁内创建备份，
因此备份校验仍使用旧 schema 与旧核心。直接调用不支持该标志的旧 `/usr/local/bin/sb` 仍会
走旧流程，无法解决 bootstrap；不要用它完成这一次迁移。迁移完成后的 manager 已支持普通
`sb upgrade ... --upgrade-core`。

该契约现已实现，具体行为如下：

- app 链接存在但不是受管符号链接时**拒绝替换**，不静默覆盖；
- 命令路径冲突在 app 链接移动**之前**判定并拒绝，不会留下半安装的 manager；
- app 链接与 CLI 链接都经 `symlink_switch()` 三步切换（先在目标旁建临时链接再
  rename），因此不会留下悬空的 `/usr/local/bin/sb`；
- 链接切换失败时上一个 release 保持生效，失败的 release 被删除；
- self-check、命令目录创建或 CLI 链接失败都会调用 `manager_rollback_app()` 回滚，
  **并原样传播其返回码**——包括表示不可自动恢复的 `70`，该值不会被压平成 1。
- 组合升级在 core 或 install 验收失败时，先恢复旧 app 和旧核心/receipt，再恢复 unit 与
  数据，并由旧 manager 重跑 `validate`、`doctor`；回滚本身失败仍返回 `70` 并保留恢复材料。

升级流程不会整体删除 `/opt/sb`。unit 重载与 MainPID/cgroup 归属已在真实主机上验证，
零节点状态下的升级不会启动服务。

## sing-box 核心

普通节点操作不会升级核心：

```bash
sb core install
sb core upgrade
```

这两个命令始终使用**当前已安装 manager** 的固定 pin，既不查询上游 `latest`，也不能解决
“源码 manager pin 已更新、已安装 manager pin 尚未更新”的 bootstrap。首次跨 pin 迁移必须
使用 `sb upgrade --source DIR --upgrade-core`；不支持先从新源码手工升级核心再尝试 manager
升级，因为后一阶段失败时旧 manager 无法对新核心提供完整回滚保证。

项目固定 `1.13.15`：

| 架构 | 官方归档 SHA256 |
|---|---|
| linux-amd64 | `a3a3ff223b23c3f4731d0a17cb0ef94c97ce257c70721a5b07dc7ca079203c9f` |
| linux-arm64 | `f0810bbb5722ae36635687c421019defcc8b328d31a0b3c287901f331747ca93` |

安装后二进制 SHA256：

| 架构 | 官方归档内 `sing-box` SHA256 |
|---|---|
| linux-amd64 | `fc3f1ff0d83d8d640e785fdd45ccd4d506ee6e8d67ba47b521382c448eee954a` |
| linux-arm64 | `62635ec87393e0860f24def24ecbc7415691c643dfdbc4faf7aa719263706096` |

上述值来自对应官方 Release 归档；`checksums.json` 自身的固定摘要写入
`core/common.sh`。更新核心时必须从官方 release 获取两种架构归档，分别验证归档
摘要、精确内部路径、解压后二进制摘要和版本，再更新文件及其固定摘要。

下载使用 HTTPS。候选归档先校验 checksum 来源、归档 SHA256、精确内部路径、架构、
二进制 SHA256 与 `sing-box version`，再对 current 执行 `sing-box check`。安装成功
后将版本、架构、digest 与来源写入 `core.json` receipt；同版本但 digest 不符不会
被视为已安装。替换前备份旧二进制与 receipt；运行验收失败则恢复并重启旧核心。

## 旧 `/opt/sb` 迁移

首次安装检测 `/opt/sb/instances.json`：

1. 先确定 endpoint，此时尚未修改任何数据（见下节）。
2. 在 `/var/backups/sb` 候选目录保存完整旧 `/opt/sb`（含 output）、settings、
   unit 和核心（存在时），验证后原子发布备份。
3. 复制证书到 `/var/lib/sb/certs`，保持内容和哈希，不轮换。
4. state schema v1→v2，保留 ID、密码、UUID、密钥、端口和时间。
5. 旧 TLS 节点迁为显式 `insecure` 兼容模式，避免无提示改变客户端行为。
6. 校验证书 SNI、state、全部输出和固定核心。
7. 成功后原子创建 current；旧目录不删除。

重复执行发现 current 后验证其完整 generation，不重新生成任何凭据或证书。新旧
路径同时存在时以已验证的 current 为准，旧目录保留；current 损坏时拒绝继续，不会
退回旧目录覆盖新 schema。迁移中途失败会清理 `.migrate-*`/候选证书并保留旧数据，
重试幂等。

### 迁移的 endpoint 恢复

sb v2 不保存 endpoint：它在每次编译客户端输出时重新探测地址，并把结果直接渲染进
`/opt/sb/output/sub.yaml`。因此迁移**从旧客户端输出里恢复** endpoint，而不是要求
管理员补录一个旧安装已经知道的值：读取 `proxies:` 下每条 clash 节点的 `server`
字段，只有在全部条目一致、且该值仍然通过与手工输入完全相同的 endpoint 校验
（全局地址策略、域名解析策略）时才接受，写入 settings 时记为
`source="sb-v2-migration"`。只读取结构化字段，不扫描自由文本——SNI 与伪装域名不是
endpoint。本次调用显式给出的 `--endpoint` 始终优先于恢复值。

恢复不成功时（旧输出缺失、多个不一致的地址、或该地址是私网/CGNAT 等非全局地址），
迁移在**修改任何数据之前**停止并返回退出码 `78`：不写备份、不换证书、不发布
generation，旧 `/opt/sb` 与正在运行的服务原样保留。此时安装器**不会**回滚应用切换、
也不会删除新 release——新 manager 是唯一能接受该输入的程序，删掉它才会造成
无法自举的升级循环。补齐方式是一条受支持的命令，不需要手工编辑 `/var/lib/sb`：

```bash
sb install --endpoint <domain-or-public-ip> --yes
```

除此之外的任何 install 失败仍然按原有语义整体回滚并删除新 release。

## 备份与恢复

```bash
sb backup
sb restore <backup-id> --yes
```

手工备份包含 active generation（state、settings、服务端配置和全部客户端输出）、
完整 cert、unit、app、核心及核心 receipt；事务发布的轻量备份不重复保存大型
app/core。所有内容先写隐藏候选目录，state/settings/generation/TLS/metadata/权限
全部验证后才原子发布。目录 `0700`、普通敏感文件 `0600`、可执行文件 `0700`。

`sb restore` 的“数据恢复”范围是 settings、state、generation 派生输出和证书。
它先独立验证备份中的证书与 state，再候选复制整棵证书目录，通过正常事务重新编译
输出、固定核心校验、切换、服务验收和失败整体回滚。手工备份中的 app、unit 和核心
用于管理器/核心灾难恢复参考，不由 `sb restore` 自动替换。

### salvage 快照

当 `sb restore` 要替换的 live generation 本身已经无法通过校验时，它的 pre-publish 安全网
无法成为一个「已校验备份」。这种情况下备份会被标记 `salvage: true`，并打印警告说明该快照
未经校验。健康安装上的 `sb restore` 不会进入该模式，其快照始终是 `salvage: false`。

salvage 快照默认**不可恢复**：

```bash
sb restore <salvage-id> --yes                                  # 拒绝，并说明原因
sb restore <salvage-id> --restore-unvalidated-salvage --yes    # 显式承担风险
```

使用该标志会打印 `DANGEROUS` 警告，并把「UNVALIDATED salvage snapshot」写入
`status.json` 的 `last_publish.description`。这是知情确认而非绕过：内容确实损坏的快照
仍会被内容校验拒绝。恢复后务必执行 `sb doctor`。

salvage 模式不能从环境变量启用。

## 升级失败与数据回滚

普通同 pin 的 `sb upgrade --source DIR` 分为三个阶段：数据备份、应用切换、由新 manager
执行 `install`。跨 pin 的 `sb upgrade --source DIR --upgrade-core` 在应用切换和 install
之间增加核心切换阶段。新 app 切换之后的任何失败都必须假设 live 状态已被修改，此时会
**先**恢复 app 链接；组合升级再恢复旧核心与 receipt；随后恢复 systemd unit，**再**由
恢复后的旧 manager 用升级前备份恢复 settings、state、generation、证书与输出，最后用旧
manager 重新 `validate` 和 `doctor`。

顺序是有意的：反过来会让旧 manager 读到新 schema，或让新 manager 读到半恢复的数据。

## 退出码 70：不可自动恢复

除锁竞争的 `75` 外，还有一个专用退出码：

```text
70  管理器无法自行恢复，需要人工介入
```

它只在回滚自身失败时出现，例如 current 链接无法恢复、app 链接无法恢复、旧 sing-box
二进制无法放回。这些路径会：

- 打印 `CRITICAL` 与可操作的人工恢复路径（不含任何凭据）；
- **保留**恢复所需的全部材料——新旧 generation、被拒 release、旧核心二进制的暂存副本、
  恢复前的证书目录——即使进程随后退出；
- 不再继续执行后续的「补救」动作。例如 current 链接恢复失败后，`sb restore` 不会再把证书
  目录换回，因为那只会在一个指向未验证 generation 的 `current` 之下叠加损坏。

出现 70 之后应先运行 `sb doctor`，它的 `generation_drift`、`last_publish` 和 `app_release`
检查用于定位 current、state 与运行中服务之间的漂移。

## 并发与退出码

writer、endpoint/listen、backup、restore、migration、manager/core upgrade 共用
`/run/lock/sb/manager.lock`。锁已被其他操作持有时不等待、不写 live 数据，返回
`75`（`EX_TEMPFAIL`）；调用方可在稍后安全重试。
