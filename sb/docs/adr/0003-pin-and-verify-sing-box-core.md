# ADR 0003：固定并验证 sing-box 核心

- 状态：Accepted
- 日期：2026-07-25

## 决策

项目固定经过测试的 sing-box 版本和每个支持架构的官方 archive/binary SHA256。
安装、升级和 doctor 同时验证版本、架构、摘要、receipt 与真实配置 `check`。普通
节点操作不得隐式升级核心。

## 原因

只检查版本字符串无法发现同名替代程序或被篡改的二进制；使用上游 `latest` 也会让
schema 和行为在未测试时漂移。

## 后果

核心升级必须是显式命令。更新固定版本时需要独立核对官方 release 摘要、更新项目
metadata，并重新运行全部协议矩阵和迁移/rollback 测试。已安装 manager 的
`sb core upgrade` 只安装该 manager 的固定 pin；source 改变 pin 时，必须显式使用
`sb upgrade --source DIR --upgrade-core`，让新 manager 与新核心在一个可回滚事务中迁移。
不自动查询 upstream latest，也不允许普通 manager upgrade 隐式改变核心。
