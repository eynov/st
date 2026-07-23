# fwctl

`fwctl` 项目安装后的命令名为 `fw`。它使用持久状态生成 nftables 的 input、forward 和
NAT 规则。业务端口和端口转发必须写入
`state.json`，不要只修改运行中的 ruleset。

## NAT 出站模式

`state.json` 支持：

```json
{
  "nat_mode": "auto",
  "snat_address": null
}
```

允许的 `nat_mode`：

- `auto`：优先使用 `snat_address`，未配置时查询公网 IPv4。只有候选地址真实存在于
  `ip -4 -o addr show` 的本机接口列表中，才生成 `snat to <地址>`；否则生成
  `masquerade`。
- `snat`：必须设置合法的 `snat_address`，而且该地址必须存在于本机 IPv4 接口；
  不满足条件时拒绝生成和加载。
- `masquerade`：始终使用出口接口地址做源 NAT。

普通 VPS 通常直接把公网 IPv4 配置在网卡上，`auto` 会选择显式 SNAT。AWS EC2 的 EIP
等 1:1 NAT 地址不出现在实例网卡中；实例只看到 ENI 私网地址。把 EIP 直接写入
`snat to` 会产生源地址不属于 ENI 的数据包，可能被云网络丢弃，因此 `auto` 会选择
`masquerade`。

检测公网地址失败或结果不明确时，`auto` 会输出日志并安全回退到 `masquerade`。判断不依赖
AWS Metadata Service。

AWS 推荐：

```json
{
  "nat_mode": "auto",
  "snat_address": null
}
```

也可以明确设置：

```json
{
  "nat_mode": "masquerade",
  "snat_address": null
}
```

## 公网业务端口

SSH 管理端口由模板中的独立规则放行，不应重复加入普通业务端口。
SSH 和普通 TCP 业务端口的 accept 规则位于全局 SYN 限速之前，因此已明确放行的端口不会
被面向未放行端口的聚合限速提前丢弃。

```bash
fw port add tcp 443
fw port add udp 443
fw port remove tcp 443
fw port list
```

协议只能是 `tcp` 或 `udp`，端口必须是 `1-65535` 的整数。命令会自动去重和数值排序。
删除不存在的端口会明确提示且不修改状态。

端口操作采用事务流程：先生成候选状态和临时 nft 配置，执行 `nft -c -f`，成功加载后才保存
状态。语法检查或加载失败时，原状态、运行 ruleset 和持久配置保持不变。

## 端口转发

运行交互入口并选择“添加端口转发”：

```bash
fw
```

选择协议 `both` 可为同一映射生成 TCP 和 UDP 两条规则。例如，将公网 `29312` 转发到
`192.0.2.20:29312`：

```text
目标落地 IP: 192.0.2.20
起始端口: 29312
结束端口: [回车]
目标端口: 29312
协议: both
```

## render/apply 安全行为

```bash
fw render
```

渲染过程：

1. 验证 JSON schema、NAT 模式、协议和端口范围。
2. 在 `build/` 中创建临时文件。
3. 执行 `nft -c -f <临时文件>`。
4. 将完整规则作为一个原子 nft netlink batch 加载。文件中的 `flush ruleset` 和新规则处于
   同一事务，不会产生空规则窗口。
5. 加载成功后，原子替换 `build/nft.conf` 和 `/etc/nftables.conf`。

render 不执行 `systemctl restart nftables`，因此不会因 stop/flush/start 中断 SSH。

只生成和检查、不加载：

```bash
/opt/fwctl/render.sh --render-only
```

## 回滚

修改前应备份整个项目和系统配置：

```bash
backup="/root/fwctl-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 "$backup"
cp -a /opt/fwctl "$backup/fwctl"
cp -a /etc/nftables.conf "$backup/nftables.conf"
```

回滚时恢复生成源和持久配置，再先检查、后原子加载：

```bash
cp -a "$backup/fwctl/." /opt/fwctl/
cp -a "$backup/nftables.conf" /etc/nftables.conf
nft -c -f /etc/nftables.conf
nft -f /etc/nftables.conf
```

不要以停止 nftables 作为长期回滚方案。

## 测试

```bash
fwctl/tests/test_fwctl.sh
nft -c -f /etc/nftables.conf
```

测试覆盖 NAT 模式选择、非法模式和地址、TCP/UDP 端口增删、重复添加、非法协议、端口越界和
连续 render 幂等性。
