# 端口、防火墙与 HY2 Port Hopping

项目不配置防火墙。`sb firewall` 输出每个启用节点所需的 TCP/UDP 端口、HY2 转发
关系和示例；使用者可以选择 nftables、iptables、云安全组、控制面板、自有管理
工具或其他实现。项目没有 fwctl 运行时依赖。

| 协议 | 要求 |
|---|---|
| SS / SS2022 | 同一基础端口 TCP+UDP |
| AnyTLS / VLESS（三种模式） | 基础端口 TCP |
| Hysteria2 无跳跃 | 基础端口 UDP |
| Hysteria2 有跳跃 | 基础端口 UDP + 完整跳跃范围 UDP + 范围到基础端口转发 |

## Port Hopping 的必要条件

放行 UDP 跳跃端口范围并不等于已经实现 Port Hopping。
如果 sing-box 服务端只监听基础端口，还必须将完整跳跃端口范围转发到基础端口。
客户端范围、云防火墙放行范围和系统防火墙转发范围必须一致。

例：基础端口 `443`，范围 `20000-21000`：

```text
UDP 20000-21000 → UDP 443
```

创建命令：

```bash
sb add HY2 --port 443 --sni hy.example.com --tls-mode trusted \
  --certificate /path/fullchain.pem --key /path/privkey.pem \
  --hop-range 20000-21000 --hop-interval 30 \
  --ack-port-hopping --yes
```

启用后 CLI 明确显示云安全组放行、系统防火墙转发和三方范围一致的要求。交互模式
要求确认；非交互模式必须同时显式提供 `--ack-port-hopping`。`--yes` 只跳过普通
危险操作确认，不能代替三项 Port Hopping 网络责任确认。

范围必须是合法 UDP 端口，start 小于 end，不得包含基础端口，最多 2048 个端口。
本版本为保证 URI/Surge/Mihomo/sing-box 一致，只支持 30 秒 interval。关闭跳跃后
URI、Surge、Mihomo 和 sing-box 不包含 mport、ports、hop-interval 或
server_ports。

## nftables 示例（不会自动执行）

先按你的规则体系创建表/链；以下是独立示意，应用前必须复核并纳入现有规则集：

```nft
table inet sb_hy2_example {
  chain input {
    type filter hook input priority filter; policy accept;
    udp dport { 443, 20000-21000 } accept
  }
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    udp dport 20000-21000 redirect to :443
  }
}
```

## iptables 示例（不会自动执行）

```bash
iptables -A INPUT -p udp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 20000:21000 -j ACCEPT
iptables -t nat -A PREROUTING -p udp --dport 20000:21000 \
  -j REDIRECT --to-ports 443
```

IPv6 需要在实际环境使用等效 nftables inet 规则或经验证的 ip6tables 规则。
云安全组/NAT 网关还必须单独放行/转发；本机 `doctor` 无法证明外部网络已正确配置。
