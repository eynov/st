# 单台 VPS 部署检查清单

在一台新主机上部署 sb 时的操作流程。首次部署建议先选一台非关键主机。

## 部署前

- 保存旧 `/opt/sb`、unit、核心版本/哈希、state、cert、output。
- 记录公网 A/AAAA、NAT、云安全组和系统防火墙现状。
- 根据主机选择 `dual`、`ipv4` 或 `ipv6`。
- 为每个端口确认 TCP/UDP；HY2 hopping 同时确认 range→base 转发。
- 校验源码归档 SHA256 与 `checksums.json`。

## 灰度

已有安装跨核心 pin 升级时，先确认 reviewed checkout 的 commit，再执行：

```bash
sb validate
sb doctor
sb backup
env -u SB_APP_DIR /path/to/reviewed/sb/sb upgrade \
  --source /path/to/reviewed/sb --upgrade-core --yes
sb version
sb validate
sb doctor
```

首个不支持该标志的旧 manager 必须由 reviewed source 的 `sb` 启动迁移；不要再次调用旧
`/usr/local/bin/sb`，也不要先从新源码单独运行核心升级。未带 `--upgrade-core` 的跨 pin
manager upgrade 必须在任何修改前以 `64` 拒绝；组合升级失败必须自动恢复旧 manager、旧
核心/receipt、unit 与数据。

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

组合升级的自动回滚会恢复 `/opt/sb/app`、旧 sing-box binary/receipt、备份 unit 与数据。
只有命令返回 `70` 时才进入人工恢复：严格按错误输出指名的 pre-manager backup 和暂存路径
恢复，不要继续重试或清理材料。最后复核 state、config、client output 哈希、active 与监听。
防火墙变更不属于项目自动回滚范围，必须按灰度前记录由使用者单独恢复。

## 验收标准

- 隔离测试、ShellCheck、Bash syntax、fixed-core check、diff check 全部通过。
- 真实 systemd unit、MainPID/cgroup 归属与 generation 加载在目标主机上确认。
- 不存在 Critical/High 未解决问题。
- 目标主机完成上述低流量验收。

隔离环境没有 systemd system bus，因此仓库级测试通过本身不能替代目标主机上的验收；
已验证与尚未验证的划分见 [`KNOWN_LIMITATIONS.md`](KNOWN_LIMITATIONS.md)。
