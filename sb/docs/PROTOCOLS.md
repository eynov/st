# 协议与客户端矩阵

本矩阵以固定 sing-box `1.13.15` 的实际 `sing-box check` 和隔离参数矩阵测试为准。
“禁用”表示项目不会生成看似可用但未经验证的配置。

| 协议 | 服务端 | URI | Surge | Mihomo/Clash | sing-box outbound | 端口 |
|---|---|---|---|---|---|---|
| SS AEAD | 支持 | 支持 | 支持 | 支持 | 支持 | TCP+UDP |
| SS2022 | 支持 | SIP002 | 禁用 | 支持 | 支持 | TCP+UDP |
| AnyTLS | 支持 | 禁用 | 禁用 | 支持 | 支持 | TCP |
| VLESS Vision Reality（默认） | 支持 | 支持 | 禁用 | 支持 | 支持 | TCP |
| VLESS Reality（无 flow） | 支持 | 支持 | 禁用 | 支持 | 支持 | TCP |
| VLESS WebSocket TLS | 支持 | 支持 | 禁用 | 支持 | 支持 | TCP/WS |
| Hysteria2 | 支持 | 支持 | 条件支持 | 支持 | 支持 | UDP |

Hysteria2 Surge 只在 `trusted` 或明确 `insecure` 模式输出。项目没有建立 Surge
自签/用户证书公钥固定的兼容契约，因此这两种模式不会生成 Surge 节点。

## 服务端—客户端参数

| 协议 | state 中的关键参数 | 服务端与客户端一致性 |
|---|---|---|
| SS | port、method、password | inbound、URI、Surge、Mihomo、outbound 完全同源 |
| SS2022 | port、method、定长 Base64 PSK | inbound、SIP002、Mihomo、outbound 完全同源 |
| AnyTLS | port、password、TLS mode、SNI、cert/pin | inbound、Mihomo、outbound 完全同源 |
| VLESS | mode、port、UUID；Reality keypair/short ID/server name，或 WS path/TLS | inbound、URI、Mihomo、outbound 完全同源 |
| HY2 | base port、password、masquerade、TLS、hop range/interval | inbound 与全部可用客户端输出同源 |

所有 tag 都由稳定节点 ID 生成：服务端 `in-<id>`，客户端 `<PROTOCOL>-<id>`。
启用节点按实际传输层检查端口冲突；SS/SS2022 同时占用 TCP 与 UDP，HY2 只占用
UDP，AnyTLS/VLESS 只占用 TCP，因此相同数字的 TCP 与 UDP 端口可以合法共存。

## 协议审计结论

- SS：修正为 TCP+UDP 端口声明和监听验收；三个客户端字段一致。
- SS2022：按 cipher 自动生成 16/32 字节 PSK；修改 cipher 会同步生成匹配 PSK。
  SIP002 AEAD-2022 userinfo 不做整体 Base64URL，而是分别 percent-encode method 与
  Base64 PSK。IPv4、IPv6、域名、`+`/`/`/`=` 和 Unicode/空格 tag 已通过官方
  shadowsocks-rust v1.24.0 `ssurl` 真实解析。
- AnyTLS：不再臆造 URI/Surge；TLS pin 进入 sing-box/Mihomo 输出。
- VLESS：`vision-reality` 固定在 inbound user 和 outbound 顶层同时写入
  `flow=xtls-rprx-vision`；`reality` 两端均不写 flow；`ws` 两端均写相同 WS path 和
  TLS。UUID、Reality keypair、short ID、SNI 或 WS TLS 参数在 URI、Mihomo 与 sing-box
  输出保持同源。未验证的 Surge 映射被禁用。

VLESS 明确不支持 XHTTP、gRPC、HTTPUpgrade、H2、QUIC、Vision + 普通 TLS、
`packet_encoding` 自定义、`spiderX` 或 uTLS 自定义。

两个 Reality mode 的 `--server-name` 借用站点必须支持 TLS 1.3 且证书链足够小；
证书链过大的站点（例如 `www.microsoft.com`）能通过 `sing-box check` 和
`sb doctor`，但真实客户端握手一定失败。要求、实测数据与推荐取值见
[README 的 Reality 借用站点小节](../README.md#reality-借用站点--server-name-的硬性要求)。
- HY2：基础监听与跳跃范围分离；无跳跃时不输出任何 hopping 残留；URI
  `pinSHA256` 使用完整叶证书指纹，sing-box SPKI pin 保持为独立字段。

增加协议时必须同时实现 create/edit/validate/inbound/URI/Surge/Mihomo/outbound/
firewall/expected-listener 接口，并加入固定核心和参数矩阵测试。旧的占位式协议生成
提示已移除，避免生成与当前 registry 契约不兼容的脚本。
