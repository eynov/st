# ADR 0001：事务式 generation 发布

- 状态：Accepted
- 日期：2026-07-25

## 决策

state 与 settings 是输入事实，服务端配置和客户端输出是派生数据。所有节点及
settings 变更必须在同文件系统候选 generation 中完成编译和校验，再通过单一 current
链接原子发布。服务验收失败时，state、settings、服务端配置和全部客户端输出整体
回滚，不允许逐文件修补 live 数据。

## 原因

单独写入 state、配置或订阅会产生无法可靠诊断的漂移。不可变 generation 让候选
校验、原子切换、完整 rollback 和审计边界保持一致。

## 后果

所有 writer 必须使用统一事务 API。current 链接的创建、切换和 rollback 都属于安全
关键操作，必须显式检查退出码；仅依赖 `set -e` 不满足本决策。
