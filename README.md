# S/st

本仓库收录若干 Linux 服务与 VPS 运维项目。各项目相互独立；使用前请先阅读对应
目录的说明，并在隔离环境验证。

## 项目

- [`sb`](sb/README.md)：面向通用 Linux VPS 的 sing-box 多协议管理器。当前处于
  **Repository Production Candidate / Not Production Ready** 阶段。
- [`fwctl`](fwctl/README.md)：防火墙状态与规则渲染工具。
- `box`：VPS 日常运维脚本集合。
- `Telegram_chatbot`：Telegram Bot 项目。
- `Treehole`：独立的 Web 应用与 systemd service 示例。

## 安装入口

[`file.sh`](file.sh) 是仓库级安装路由。`sb` 使用受校验的专用安装流程；其他项目
保留通用 `--source-dir` 路由。安装会修改目标系统，执行前必须阅读对应项目文档并
明确提供来源，不要直接把未复审分支用于生产环境。

## 文档入口

- sb 用户文档：[`sb/README.md`](sb/README.md)
- sb 当前开发状态：[`sb/docs/internal/AI_HANDOFF.md`](sb/docs/internal/AI_HANDOFF.md)
- sb 架构：[`sb/docs/ARCHITECTURE.md`](sb/docs/ARCHITECTURE.md)
- sb 测试：[`sb/docs/TESTING.md`](sb/docs/TESTING.md)
- AI 协作规范：[`AGENTS.md`](AGENTS.md)

## 开发状态

三轮独立只读复审的阻断项全部关闭：Critical 0、High 0、阻断 Medium 0。

**真实 systemd/cgroup 灰度验证已完成**（2026-08-01，单台非关键 VPS `de`）：真实 unit 与
MainPID/cgroup 归属、generation 实际加载、restart/reload、事务失败后的真实 service 回滚、
七种协议/模式的真实客户端握手，以及**一次真实重启后带节点自动恢复**，均已实测通过。

仍**不得标记为 Production Ready**，也不得在该灰度主机之外扩大部署：零节点状态下的重启
行为、`Restart=on-failure` 的真实崩溃恢复、核心升级失败后的 service 恢复，以及真实主机上的
v1→v2 迁移，都尚未验证。当前结论和下一步以
[`sb/docs/internal/AI_HANDOFF.md`](sb/docs/internal/AI_HANDOFF.md) 为准。
