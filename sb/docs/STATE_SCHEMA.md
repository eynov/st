# State 与 Settings Schema

## State schema v2

`instances.json` 顶层字段：

```json
{
  "schema_version": 2,
  "project_version": "3.0.0",
  "updated_at": "RFC3339 UTC",
  "instances": {}
}
```

每个实例都有稳定的 `id`、protocol、port、enabled、created_at 和 updated_at，
以及协议专属凭据。加载时校验类型、ID/tag、端口、传输层冲突、密码/PSK、UUID、
Reality key、TLS 引用、证书有效性和 HY2 跳跃范围。

schema v1→v2 迁移保留 ID、密码、UUID、证书、Reality key 和节点标识。未知的更高
schema 会被拒绝，旧程序不会覆盖它。

```bash
sb state validate
sb state export
sb state export --show-secrets
```

export 默认脱敏。只有明确使用 `--show-secrets` 才输出敏感字段。

## Settings schema v2

settings 与 state 位于同一 generation，保存 endpoint 与 listen；兼容路径
`/etc/sb/settings.json` 始终指向 current generation：

```json
{
  "schema_version": 2,
  "endpoint": {
    "mode": "domain",
    "value": "node.example.com",
    "allow_private": false,
    "source": "explicit",
    "updated_at": "RFC3339 UTC"
  },
  "listen": {
    "mode": "dual",
    "address": "::",
    "updated_at": "RFC3339 UTC"
  }
}
```

settings v1→v2 自动增加 `listen=dual`，保留原 endpoint。未知更高版本同样拒绝。
endpoint/listen 修改先持有与 node writer、backup、restore、migration、upgrade 相同
的全局锁，再将候选 settings/state/output 一起发布或一起回滚；外部探测不是 render
的隐式依赖。

## Dry-run

add/edit/delete/enable/disable、render/reload、endpoint/listen 变更支持 `--dry-run`。
它在同文件系统候选目录完成 state、输出、URI 和固定核心检查，显示脱敏 state diff
与候选文件哈希，不切换 current、不控制服务、不留下候选证书。
