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
