# S/st

本仓库收录若干 Linux 服务与 VPS 运维项目。各项目相互独立；使用前请先阅读对应
目录的说明，并在隔离环境验证。

## 项目

- [`sb`](sb/README.md)：面向通用 Linux VPS 的 sing-box 多协议管理器。
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
- sb 维护记录：[`sb/docs/internal/AI_HANDOFF.md`](sb/docs/internal/AI_HANDOFF.md)
- sb 已知限制：[`sb/docs/internal/KNOWN_LIMITATIONS.md`](sb/docs/internal/KNOWN_LIMITATIONS.md)
- sb 架构：[`sb/docs/ARCHITECTURE.md`](sb/docs/ARCHITECTURE.md)
- sb 测试：[`sb/docs/TESTING.md`](sb/docs/TESTING.md)
- AI 协作规范：[`AGENTS.md`](AGENTS.md)

## 验证与限制

`sb` 的隔离测试、静态检查与单台 VPS 的真实 systemd 验证记录见
[`sb/docs/internal/AI_HANDOFF.md`](sb/docs/internal/AI_HANDOFF.md)，已知边界见
[`sb/docs/internal/KNOWN_LIMITATIONS.md`](sb/docs/internal/KNOWN_LIMITATIONS.md)。
部署到新主机前请先阅读这两份文档。
