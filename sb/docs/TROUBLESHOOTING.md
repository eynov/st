# 测试与故障排查

## 只读检查

```bash
sb status
sb status --json
sb validate
sb doctor
sb doctor --json
sb render --dry-run
```

`status` 包含 enabled、active、PID、实际核心版本、总节点数、启用节点数、预期
TCP/UDP 监听、最近发布和最近回滚。`doctor` 检查：

- 固定核心和 unit
- enabled/active 关系
- state 与 `sing-box check`
- endpoint 来源
- dual/IPv4/IPv6 监听模式
- 实际监听端口
- 证书有效期和 insecure 风险
- state/output/cert/backup 权限
- HY2 Port Hopping 外部网络责任

当存在端口跳跃时 doctor 必须提示：

> 项目无法仅通过本地配置确认云安全组和外部防火墙是否已正确放行。请确认完整 UDP
> 跳跃范围均可到达本机，并已转发到基础端口。

## 隔离测试

测试不测速、不压测、不连接生产。完整命令、固定真实组件、mock 边界、当前结果和
真实 systemd 未验证范围统一维护在 [`TESTING.md`](TESTING.md)，本文件不再维护第二
份测试说明。

## 常见失败

- `endpoint is not configured`：执行 `sb endpoint set <domain-or-public-ip>`。
- 旧 `/opt/sb` 迁移返回退出码 `78`：旧输出里没有可确认的 endpoint。此时未修改任何
  数据，新 manager 仍然可用，执行 `sb install --endpoint <domain-or-public-ip> --yes`
  完成迁移；不要手工编辑 `/var/lib/sb`。
- dual 模式失败：确认 IPv6 可用且 `net.ipv6.bindv6only=0`，否则选 `ipv4`。
- `sing-box version mismatch`：只能显式执行 `sb core install|upgrade`。
- `another sb operation holds...` / 退出码 75：全局锁竞争，live 数据未修改，稍后重试。
- listener missing：检查端口冲突、unit 日志和所选 listen mode；不要先改防火墙。
- hopping 不通：同时核对客户端 range、云放行和本机 range→base redirect。
- TLS hostname 失败：endpoint、SNI 与证书 SAN 是不同字段，必须分别正确。
