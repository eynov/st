# 单台 VPS 灰度检查清单

复审通过后可选择一台非关键 VPS 灰度。**该灰度已于 2026-08-01 在 `de` 上完成**，本清单
保留为后续主机的操作流程。

## 部署前

- 保存旧 `/opt/sb`、unit、核心版本/哈希、state、cert、output。
- 记录公网 A/AAAA、NAT、云安全组和系统防火墙现状。
- 根据主机选择 `dual`、`ipv4` 或 `ipv6`。
- 为每个端口确认 TCP/UDP；HY2 hopping 同时确认 range→base 转发。
- 校验源码归档 SHA256 与 `checksums.json`。

## 灰度

1. 先执行 `file.sh sb ...`，不添加新节点。
2. 确认 `sb-core` enabled；无节点时必须 stopped。
3. 执行 `sb validate`、`sb doctor --json`。
4. 用 `sb add ... --dry-run --yes` 检查脱敏 diff 和候选哈希。
5. 添加一个节点，确认事务 success、active 和预期监听。
6. 用生成的 sing-box/Mihomo/URI 做单次低流量握手，不测速、不压测。
7. 验证 edit、disable/enable；最后再测试 delete/restore。
8. 观察 journal 和资源，再决定是否扩大。

## 灰度回滚

应用发布失败会自动恢复旧 generation 和服务。人工回滚：

```bash
sb backup
sb restore <pre-grey-backup-id> --yes
sb validate
sb doctor
```

若新管理器本身不可用，恢复 `/opt/sb/app` 到旧 release，并恢复备份 unit 后执行
daemon-reload；若核心升级失败，恢复备份 sing-box 二进制。最后复核 state、config、
client output 哈希、active 与监听。防火墙变更不属于项目自动回滚范围，必须按灰度前
记录由使用者单独恢复。

## Production Ready 门槛

- 隔离测试、ShellCheck、Bash syntax、fixed-core check、diff check 全部通过。
- 真实 systemd unit、MainPID/cgroup、零节点重启与异常重启策略通过隔离或灰度验收。
- 不存在 Critical/High 未解决问题。
- 单台真实 VPS 灰度完成上述低流量验收。

隔离环境没有 systemd system bus，因此仓库级测试通过本身只能标记为“生产候选”。
`de` 的真实 systemd 灰度已完成，上述门槛中仍未满足的是**零节点重启与异常重启策略**，
因此目前仍不得标记 Repository Production Ready。
