# sb 3.0

`sb` 是面向通用 Linux VPS 的 sing-box 多协议管理器。它以 state 为唯一事实来源，
统一编译服务端配置与客户端输出，并用原子 generation 切换、固定核心校验、systemd
验收和失败回滚管理节点生命周期。

本项目不绑定云厂商、控制面板、fwctl 或任何防火墙实现。它只输出端口需求及
nftables/iptables 示例，绝不默认执行防火墙命令。

> 当前状态：**Repository Production Candidate — Not Production Ready**。三轮独立只读复审
> 提出的全部阻断项均已修复（当前 Critical 0 / High 0 / Medium 0 阻断），但真实 systemd
> 验收尚未完成，仍有非阻断项开放。请先阅读
> [AI 交接状态](docs/internal/AI_HANDOFF.md)，不要直接用于生产环境。

## 支持范围

- Shadowsocks AEAD
- Shadowsocks 2022
- AnyTLS
- VLESS TCP Reality（默认 XTLS-Vision；可选纯 Reality）
- VLESS WebSocket TLS
- Hysteria2
- Hysteria2 显式 Port Hopping
- sing-box、Mihomo/Clash、标准 URI，以及经过测试的 Surge 子集

完整兼容性见 [协议矩阵](docs/PROTOCOLS.md)。

## 安全边界

- 程序：`/opt/sb/releases/<release>`，`/opt/sb/app` 为原子切换链接
- 设置入口：`/etc/sb/settings.json`（指向 current generation 内的事务式 settings）
- 状态、settings 与派生输出：`/var/lib/sb`
- 证书：`/var/lib/sb/certs`
- 备份：`/var/backups/sb`
- 锁：`/run/lock/sb/manager.lock`
- 核心：固定 sing-box `1.13.14`，按架构校验 SHA256

所有含凭据的文件默认 `0600`，目录默认 `0700`，进程与脚本使用 `umask 077`。

## 安装

复审通过并制作不可变源码归档后：

```bash
./file.sh sb \
  --archive-url https://example.invalid/st-3.0.0.tar.gz \
  --archive-sha256 <64-hex-sha256> \
  --endpoint node.example.com \
  --listen-mode dual \
  --yes
```

仓库内或隔离环境：

```bash
./file.sh sb --source-dir ./sb --endpoint node.example.com --yes
```

安装管理器、安装核心、创建 unit 与添加首个节点是明确分离的步骤。无节点时
`sb-core` 为 `enabled` 但 `stopped`；首个节点成功发布后才启动。

## 常用命令

```text
sb install
sb upgrade --source DIR
sb core install
sb core upgrade
sb endpoint set HOST
sb listen set dual|ipv4|ipv6
sb add|edit|delete|enable|disable
sb list|status|validate|render|doctor
sb reload|restart
sb backup|restore
sb state validate|export|import
sb version
```

全局选项：`--yes`、`--json`、`--dry-run`、`--show-secrets`。节点变更和 endpoint/
listen 变更支持只读 dry-run；state export 默认脱敏。

## VLESS 三模式

VLESS 只实现三个经过固定 sing-box `1.13.14` 检查的模式，不提供其他 transport 或
参数组合：

```bash
# 默认：TCP + REALITY + flow=xtls-rprx-vision
sb add vless --port 443 --server-name www.icloud.com

# 兼容模式：TCP + REALITY，无 flow
sb add vless --port 8443 --mode reality --server-name www.icloud.com

# WebSocket + TLS；TLS 默认 self-signed，也可使用通用 TLS 参数
sb add vless --port 9443 --mode ws --path /vless \
  --sni ws.example.com --tls-mode self-signed
```

### Reality 借用站点（`--server-name`）的硬性要求

Reality 会把目标站点的真实 TLS 握手转发给客户端，因此**目标站点必须选对**，否则
节点能发布、能通过 `sing-box check`、`sb doctor` 全绿，但**每一次客户端握手都会
失败**。目标站点必须同时满足：

- 支持 TLS 1.3；
- 证书链**足够小**。证书链过大时转发的握手无法在缓冲区内完成，服务端日志出现
  `REALITY: processed invalid connection`，客户端只看到 `EOF`；
- 从服务器本机可直接建立 TLS 1.3 连接（注意 IPv4-only 主机需要目标有 A 记录）。

在 sing-box `1.13.14` 上实测（同一份配置只改目标）：

| 目标 | 证书链 | 握手 |
|---|---|---|
| `www.icloud.com` | ~4.7 KB | 成功 |
| `www.apple.com` | ~4.7 KB | 成功 |
| `addons.mozilla.org` | ~4.1 KB | 成功 |
| `www.microsoft.com` | ~8.3 KB | **失败** |

`www.microsoft.com` 经 Akamai 分发，证书链约 8.3 KB，实测无法完成 Reality 握手，
**不要用作借用站点**。本文档的示例一律使用 `www.icloud.com`。

注意 `sing-box check` 只做结构校验，不会发起真实握手，因此这个问题不会在配置检查
或 `sb doctor` 中暴露，只能通过真实客户端连接发现。

模式名分别是 `vision-reality`（默认）、`reality` 和 `ws`。WS 不支持 REALITY 或
Vision；Reality 模式不支持 WS、gRPC、XHTTP、HTTPUpgrade、H2、QUIC。项目也不提供
`packet_encoding`、`spiderX` 或 uTLS 自定义。

完整 state 可以显式导出后通过同一事务边界导入：

```bash
sb state export --show-secrets > state.json
sb state import state.json
```

默认脱敏的 export 不能重新导入；WS state 中的证书路径必须仍指向本机有效的受管证书。

## 升级、备份与恢复

管理器升级使用显式来源，不从未固定的 `latest` 隐式更新：

```bash
sb upgrade --source /path/to/reviewed/sb
sb core upgrade
```

核心升级与管理器升级分离。执行任何升级前先运行 `sb validate`、`sb doctor` 和
`sb backup`。数据恢复入口为：

```bash
sb backup
sb restore <backup-id>
```

`sb restore` 恢复 settings、state、generation 和证书数据；app、systemd unit 与
sing-box 核心不属于数据恢复范围。

`sb upgrade` 在应用切换之后失败时，会先恢复 app 链接与 systemd unit，再由恢复后的旧
manager 用升级前备份完整恢复 settings、state、generation、证书与输出，并重新校验。若
恢复本身失败，命令以退出码 `70` 报告不可自动恢复，并保留全部恢复材料。完整语义与
rollback 边界见 [运维文档](docs/OPERATIONS.md)。

## TLS

TLS 协议区分 `trusted`、`provided`、`self-signed` 和显式 `insecure`。正式域名优先
使用系统 CA 信任的证书；`insecure` 必须由用户明确选择。provided 证书不会被项目
擅自轮换，self-signed 证书包含 SNI 对应 SAN。详见 [TLS 与证书](docs/TLS.md)。

## HY2 Port Hopping

Port Hopping 默认关闭，启用时必须显式确认。客户端跳跃范围、云侧 UDP 放行范围和
系统防火墙转发范围必须一致：

```text
UDP <hop-start>-<hop-end> → UDP <base-port>
```

仅放行范围不等于已经完成 Port Hopping；还必须把完整跳跃范围转发到基础监听端口。
项目只输出要求和示例，不执行防火墙操作。详见
[端口与防火墙](docs/FIREWALL.md)。

## 文档

- [当前开发状态与交接](docs/internal/AI_HANDOFF.md)
- [架构与事务模型](docs/ARCHITECTURE.md)
- [测试体系与真实/mock 边界](docs/TESTING.md)
- [协议与客户端参数矩阵](docs/PROTOCOLS.md)
- [安装、升级、迁移、备份和恢复](docs/OPERATIONS.md)
- [端口、防火墙与 HY2 Port Hopping](docs/FIREWALL.md)
- [TLS 模式与证书轮换](docs/TLS.md)
- [state/settings schema](docs/STATE_SCHEMA.md)
- [测试与故障排查](docs/TROUBLESHOOTING.md)
- [生产灰度检查清单](docs/internal/PRODUCTION_CHECKLIST.md)
- [当前限制](docs/internal/KNOWN_LIMITATIONS.md)
- [完整修复证据快照](docs/internal/FINAL_REVIEW_PACK.md)
