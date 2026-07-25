# 协议插件开发契约

协议插件由 `core/registry.sh` 加载。每个插件必须注册 13 个字段：

```text
key label transport create edit validate inbound uri surge clash
outbound firewall expected-listener
```

不支持的客户端输出返回状态 2，runtime 会明确跳过；禁止使用 direct 占位、伪造
字段或静默 insecure。任何新协议必须先固定上游 schema，再增加服务端—客户端参数
矩阵、增删改启停、端口冲突、最后节点和真实固定核心 check 测试，之后才能注册。

