# 当前已知限制

本文件只记录稳定的产品边界；当前开发阻断及严重度统一见
[`AI_HANDOFF.md`](AI_HANDOFF.md)。

- 项目无法从本机证明云安全组、上游 NAT、DDoS 清洗或外部防火墙允许 UDP。
- HY2 Port Hopping interval 固定为 30 秒，以保证不携带 interval 的标准 URI 与
  其他客户端输出语义一致。
- AnyTLS 没有启用未经版本化验证的通用 URI；AnyTLS、SS2022、VLESS Reality 的
  Surge 输出禁用；HY2 自签/用户证书的 Surge 输出禁用。
- `clash.yaml` 使用 JSON 表示；JSON 是 YAML 1.2 的可解析子集，但文件不是手写
  YAML 风格。
- `endpoint detect` 只在用户明确调用时访问 `api.ipify.org`，当前只探测 IPv4。
- 本项目不签发公共 CA 证书，不自动续期用户证书，也不自动修改任何防火墙。
- 已具备依赖的 systemd Linux 可直接使用；缺少依赖时自动包安装仅支持 apt，其他
  发行版会列出缺失命令并要求使用主机包管理器安装。
- dual 监听依赖 Linux IPv6 与 `bindv6only=0`；不满足时必须选择 ipv4 或 ipv6。
- 本轮已完成真实 sing-box、官方 Hysteria parser/client 本地回环握手和官方
  shadowsocks-rust `ssurl` 解析；PID 1 是 `bwrap`，无法连接 system scope bus，
  因而真实 systemd unit/内核 cgroup 集成仍未验证。云网络与真实 systemd 必须在
  单台 VPS 灰度确认，不得把 mock 结果描述为真实 systemd 通过。
