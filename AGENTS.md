# AI 工作规范

本文件是本仓库供 Codex、Claude Code 及其他 AI Coding Agent 使用的唯一长期工作
规范。项目当前状态只记录在 `sb/docs/AI_HANDOFF.md`，不要写入本文件。

## 项目范围

当前生产化维护对象是 `sb/` 及其仓库级路由 `file.sh`。`fwctl/`、`box/`、
`Telegram_chatbot/` 和 `Treehole/` 是同仓库的独立项目；除非任务明确要求，不得
修改。调整 `file.sh` 时必须保留其他项目的通用安装路由。

## 开始工作前

先在仓库根目录执行：

```bash
git status --short --branch
git diff --stat
git diff -- file.sh sb/
```

随后完整阅读：

1. `sb/docs/AI_HANDOFF.md`
2. `sb/docs/FINAL_REVIEW_PACK.md`
3. `sb/README.md`
4. 与任务直接相关的代码、测试和专题文档

`AI_HANDOFF.md` 是当前阶段、阻断项和下一步的事实来源。
`FINAL_REVIEW_PACK.md` 是一次修复工作的完整证据快照；若两者的状态结论不同，以
更新后的独立复审证据和 `AI_HANDOFF.md` 为准，不得只凭 Review Pack 宣布通过。

## 工程规范

- 只修改完成当前任务所需的文件，不扩展无关功能。
- 不依赖调用方条件上下文中的 `set -e`。安全关键命令必须显式检查退出码并向上传播。
- state、settings、generation 和客户端输出必须共用统一事务边界、全局锁和整体
  rollback，不允许部分发布或状态漂移。
- 发布、回滚、备份、迁移、升级和 service control 的成功提示只能在全部验收通过
  后输出；失败必须返回非零。
- 配置必须先生成候选、完成 schema/格式检查和固定 sing-box `check`，再做原子切换。
- 不自动管理 nftables、iptables、fwctl、云安全组或控制面板防火墙。项目只生成需求、
  提示和示例。
- 不连接或部署生产 VPS，除非用户在当前任务中明确授权。
- 不自动执行 Git commit 或 push。只有用户明确授权后才可执行。
- 不把密码、UUID、私钥、完整订阅 URI 或其他凭据写入日志、文档或仓库。
- 临时文件只能位于隔离临时目录，任务结束前清理。

## 测试规范

测试命令、真实组件前置条件和 mock 边界以 `sb/docs/TESTING.md` 为准。当前已有的
主要验证入口是：

```bash
SB_TEST_REAL_CORE=/path/to/sing-box-1.13.14 \
SB_TEST_HYSTERIA_BIN=/path/to/hysteria-v2.10.0-linux-amd64 \
SB_TEST_SSURL_BIN=/path/to/shadowsocks-rust-v1.24.0/ssurl \
  sb/tests/run.sh

shellcheck --version
git diff --check
```

Shell 语法检查必须覆盖 `file.sh`、`sb/sb`、`sb/install.sh`、`sb/core/*.sh`、
`sb/protocols/*.sh`、`sb/tests/*.sh` 和测试 fixtures 中的 Shell 脚本。不得用 mock
结果声称真实 systemd、cgroup、reboot 或 VPS 网络行为已经通过。

## 文档维护

重要代码或结论变化时同步更新：

- `sb/README.md`：稳定的用户使用方式和项目状态标签；
- `sb/docs/AI_HANDOFF.md`：当前 Git 状态、已完成内容、阻断和下一步；
- `sb/docs/FINAL_REVIEW_PACK.md`：该轮完整实现与验证证据。

长期架构决策新增或改变时同步更新 `sb/docs/ARCHITECTURE.md` 和对应 ADR。测试入口、
依赖或 mock 边界变化时更新 `sb/docs/TESTING.md`。不要在多个文档复制当前问题清单。
