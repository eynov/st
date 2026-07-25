# TLS 与证书

AnyTLS 和 Hysteria2 支持四种显式模式：

| 模式 | 用途 | 客户端验证 |
|---|---|---|
| `trusted` | 正式域名和受信 CA 证书 | 正常 PKI 验证 |
| `provided` | 用户提供、非公共信任链证书 | 按客户端契约固定身份 |
| `self-signed` | 项目生成自签证书 | 按客户端契约固定身份 |
| `insecure` | 明确兼容模式 | 跳过身份验证，并显示风险 |

`trusted` 导入时还会用系统 CA store 执行 server-purpose chain 验证；不能验证的
证书必须选择 `provided`（pin）或明确 `insecure`，不得伪装成 trusted。

项目不再默认把所有客户端永久设为 insecure。自签证书包含与 SNI 相同的 SAN，
私钥和证书均为 `0600`。用户证书导入不可变托管目录，state 保存证书引用、公钥 pin
和证书指纹。

SNI 变更会重新校验证书；self-signed 模式生成覆盖新 SNI 的候选证书。显式轮换：

```bash
sb edit is01 --rotate-certificate --yes
```

provided/trusted 轮换必须同时传入新的 `--certificate` 和 `--key`。候选证书先校验
私钥、有效期和 hostname，再进入配置事务；发布失败会清理候选证书并保留旧引用。
旧证书迁移绝不会自动轮换。

`sb status` 显示运行概况，`sb doctor` 逐节点检查证书可读性和到期天数；少于 30 天
按失败报告。日志、state export 与 dry-run 默认不显示完整密码、UUID、私钥或 URI。

并非所有客户端生态都支持相同的 pin 字段。本项目只输出经过固定核心/矩阵验证的
映射；无法安全表达 pin 的 Surge 组合会被禁用，而不是退化为无提示 insecure。

pin 类型严格分离：

- sing-box outbound 的 `certificate_public_key_sha256` 使用 SPKI SHA-256；
- Hysteria 官方 URI 的 `pinSHA256` 使用叶证书完整 DER SHA-256 指纹，并按官方
  契约与 `insecure=1` 配合；
- `trusted` HY2 URI 只输出正确 SNI，依赖系统 CA，不输出 insecure 或 pin；
- explicit `insecure` 只输出 `insecure=1`，不会伪装为有证书固定。

四种 HY2 模式均用官方 Hysteria v2.10.0 parser/client 在本机隔离环境完成了低流量
TLS 握手；provided/self-signed 用例还断言 URI 指纹等于
`openssl x509 -fingerprint -sha256` 且不等于 SPKI。
