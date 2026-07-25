# 架构与目录

本文档描述已接受的目标架构。当前实现与目标之间的已知阻断只维护在
[`AI_HANDOFF.md`](AI_HANDOFF.md)；在阻断清零前，不得把下述事务模型视为已经达到
Production Ready。

## 事实来源

`/var/lib/sb/current/instances.json` 与同一 generation 内的 `settings.json` 是
运行输入事实来源。服务端配置、客户端订阅、端口需求与 manifest 都是由两者重建的
派生数据，不允许反向修改。`/etc/sb/settings.json` 是只读兼容入口，原子指向
current generation 的 settings，不是第二份可独立修改的数据。

```text
/opt/sb/
├── app -> releases/<active-release>
└── releases/<immutable-release>/

/etc/sb/
├── settings.json -> /var/lib/sb/current/settings.json
└── settings.bootstrap.json

/var/lib/sb/
├── current -> generations/<active-generation>
├── generations/<immutable-generation>/
│   ├── instances.json
│   ├── settings.json
│   └── output/
│       ├── config.json
│       ├── manifest.json
│       ├── firewall-requirements.json
│       └── clients/
│           ├── sing-box.json
│           ├── clash.yaml
│           ├── surge.conf
│           └── uris.txt
├── certs/<instance>/<immutable-version>/
└── status.json

/var/backups/sb/<backup-id>/
/run/lock/sb/manager.lock
```

程序升级只增加 release 并原子切换 `/opt/sb/app`，不会删除 state、证书或输出。
配置发布只增加 generation 并原子切换 `/var/lib/sb/current`。

## 配置发布

所有 add/edit/delete/enable/disable、重新渲染、endpoint 和 listen 变更走同一流程：

```text
flock
→ 复制当前 generation 到同文件系统临时目录
→ 修改候选 state/settings
→ schema/协议/唯一性校验
→ 编译服务端与全部客户端输出
→ JSON/YAML/URI 结构校验
→ 固定 sing-box check
→ 原子候选备份并验证 current generation/settings/certs
→ 原子切换 current
→ 受控 restart（用新 PID/cwd 证明 generation 已加载）
→ active、PID/cgroup、监听地址及预期 TCP/UDP socket 验收
→ 确认被删除/停用节点的旧 socket 已消失
→ 失败则恢复旧 current、恢复服务并再次验收
→ 记录 publish/rollback 结果
→ 释放锁并清理临时文件
```

未通过候选校验的 state 永远不会成为 current。运行验收失败时，新 generation
会被移除；settings、state、服务端配置和全部客户端输出作为一个整体回滚。

## 无节点行为

零个启用节点时生成合法的 `{"inbounds":[]}` 配置，`sb-core` 保持 enabled 但
stopped。unit 的 `ExecCondition` 在主机重启时阻止零节点空服务自动启动。删除或
停用最后一个节点会先发布空 generation，再停止服务并确认旧 socket 消失。重新
启用首个节点后由同一事务启动并验收服务。

## systemd

unit 使用固定核心和 current 配置：

- `ExecStartPre=sing-box check`
- `ExecCondition=sb internal should-run`
- `Restart=on-failure`、`RestartSec=5s`
- `UMask=0077`、`LimitNOFILE=1048576`
- `NoNewPrivileges`、`PrivateTmp`、只读系统与内核保护
- 仅保留 `CAP_NET_BIND_SERVICE`

安装时执行 daemon-reload 和 enable。`sb reload` 表示重新编译并加载全部节点；
`sb restart` 明确重启单一 `sb-core` 进程，不提供误导性的“重启单节点”。

## 监听和 endpoint

监听模式集中保存：

- `dual`：监听 `::`，要求 Linux IPv6 可用且 `net.ipv6.bindv6only=0`
- `ipv4`：监听 `0.0.0.0`
- `ipv6`：监听 `::`

endpoint 优先使用用户显式域名/IP。只有显式执行 `sb endpoint detect` 才访问
第三方 IPv4 探测服务；失败不会回退到私网接口地址。RFC1918、loopback、
link-local、CGNAT、unspecified、multicast、documentation ranges、ULA 等非全局
地址默认拒绝。域名必须成功解析，且所有解析结果均为全局地址；只有明确 override
才允许非全局 endpoint。

## Architecture Decision Records

- [ADR 0001：事务式 generation 发布](adr/0001-transactional-generation-publishing.md)
- [ADR 0002：防火墙是外部责任](adr/0002-firewall-is-an-external-responsibility.md)
- [ADR 0003：固定并验证 sing-box 核心](adr/0003-pin-and-verify-sing-box-core.md)
- [ADR 0004：单一全局 writer 锁](adr/0004-single-global-writer-lock.md)
