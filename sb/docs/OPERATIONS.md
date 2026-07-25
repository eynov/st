# 安装、升级、迁移、备份与恢复

> 本文描述预期运维契约。app/current 链接切换的失败传播与回滚阻断已经修复，但整个
> 变更集尚未通过独立只读复审，也尚未做过真实 systemd 验收，因此仍不允许用于生产安装
> 或升级；以 [`AI_HANDOFF.md`](internal/AI_HANDOFF.md) 的当前状态为准。

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
```

升级前备份 app、state、cert、output、unit 与核心。设计要求新源码先执行 Bash
语法、版本元数据和 self-check，随后写入新 release 并原子切换 app；新版本应再次
执行完整 install 验收，失败时恢复 app 链接和 unit，并删除失败 release。当前
manager 链接失败传播与首次 CLI link 失败恢复尚未满足此契约，详见
[`AI_HANDOFF.md`](internal/AI_HANDOFF.md)。升级流程不会整体删除 `/opt/sb`。

## sing-box 核心

普通节点操作不会升级核心：

```bash
sb core install
sb core upgrade
```

项目固定 `1.13.14`：

| 架构 | 官方归档 SHA256 |
|---|---|
| linux-amd64 | `f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697` |
| linux-arm64 | `4742df6a4314e8ecc41736849fca6d73b8f9e91b6e8b06ee794ff17ba180579e` |

安装后二进制 SHA256：

| 架构 | 官方归档内 `sing-box` SHA256 |
|---|---|
| linux-amd64 | `68aeab83cc4ab2659a5b92232261a20746ccdafc3b3d1e19b2d63247eec3bbf7` |
| linux-arm64 | `85f570b96754cd7c354d28e50f66e9340b374e06b5d77ec9e15e8d04f0c87a25` |

上述值来自对应官方 Release 归档；`checksums.json` 自身的固定摘要写入
`core/common.sh`。更新核心时必须从官方 release 获取两种架构归档，分别验证归档
摘要、精确内部路径、解压后二进制摘要和版本，再更新文件及其固定摘要。

下载使用 HTTPS。候选归档先校验 checksum 来源、归档 SHA256、精确内部路径、架构、
二进制 SHA256 与 `sing-box version`，再对 current 执行 `sing-box check`。安装成功
后将版本、架构、digest 与来源写入 `core.json` receipt；同版本但 digest 不符不会
被视为已安装。替换前备份旧二进制与 receipt；运行验收失败则恢复并重启旧核心。

## 旧 `/opt/sb` 迁移

首次安装检测 `/opt/sb/instances.json`：

1. 在 `/var/backups/sb` 候选目录保存完整旧 `/opt/sb`（含 output）、settings、
   unit 和核心（存在时），验证后原子发布备份。
2. 复制证书到 `/var/lib/sb/certs`，保持内容和哈希，不轮换。
3. state schema v1→v2，保留 ID、密码、UUID、密钥、端口和时间。
4. 旧 TLS 节点迁为显式 `insecure` 兼容模式，避免无提示改变客户端行为。
5. 校验证书 SNI、state、全部输出和固定核心。
6. 成功后原子创建 current；旧目录不删除。

重复执行发现 current 后验证其完整 generation，不重新生成任何凭据或证书。新旧
路径同时存在时以已验证的 current 为准，旧目录保留；current 损坏时拒绝继续，不会
退回旧目录覆盖新 schema。迁移中途失败会清理 `.migrate-*`/候选证书并保留旧数据，
重试幂等。

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

`sb upgrade --source DIR` 分为三个阶段：数据备份、应用切换、由新 manager 执行 `install`。
第三阶段之后的任何失败都必须假设 live 数据已被修改，此时会**先**恢复 app 链接与 systemd
unit，**再**由恢复后的旧 manager 用升级前备份恢复 settings、state、generation、证书与
输出，最后用旧 manager 重新 `validate` 和 `doctor`。

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
