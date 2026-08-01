# 已知限制

本文件记录产品边界与尚未验证的范围。测试入口与真实主机验证记录见
[`AI_HANDOFF.md`](AI_HANDOFF.md)。

- 项目无法从本机证明云安全组、上游 NAT、DDoS 清洗或外部防火墙允许 UDP。
- HY2 Port Hopping interval 固定为 30 秒，以保证不携带 interval 的标准 URI 与
  其他客户端输出语义一致。
- AnyTLS 没有启用未经版本化验证的通用 URI；AnyTLS、SS2022、VLESS 三模式的
  Surge 输出禁用；HY2 自签/用户证书的 Surge 输出禁用。
- `clash.yaml` 使用 JSON 表示；JSON 是 YAML 1.2 的可解析子集，但文件不是手写
  YAML 风格。
- `endpoint detect` 只在用户明确调用时访问 `api.ipify.org`，当前只探测 IPv4。
- 本项目不签发公共 CA 证书，不自动续期用户证书，也不自动修改任何防火墙。
- 已具备依赖的 systemd Linux 可直接使用；缺少依赖时自动包安装仅支持 apt，其他
  发行版会列出缺失命令并要求使用主机包管理器安装。
- dual 监听依赖 Linux IPv6 与 `bindv6only=0`；不满足时必须选择 ipv4 或 ipv6。
- 隔离测试环境的 PID 1 是 `bwrap`，无法连接 system scope bus，因此隔离测试中的
  systemd 行为来自 mock，不得被描述为真实 systemd 通过。真实 systemd 行为已在单台
  VPS 上单独验证，范围见下。

## 真实主机已验证的范围

在一台 Debian 12 VPS（`de`）上实测通过：真实 systemd unit 与 MainPID/cgroup 归属、
generation 实际加载、restart/reload、删除节点后旧 socket 消失、事务失败后的真实
service 回滚、七种协议与模式的真实客户端握手，以及一次真实重启后带节点自动恢复。

## 尚未验证的边界

- 零节点状态下的重启行为（重启时主机上有节点，未测过零节点保持 stopped）；
- `Restart=on-failure` 在真实崩溃后的恢复；
- 核心升级失败后的真实 service 恢复；
- 真实主机上的 v1→v2 迁移（验证主机没有旧 `/opt/sb` 数据）；
- 客户端握手验证走的是本机回环，未覆盖公网路径、云安全组与上游 NAT。
