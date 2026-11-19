# box/90ssh.sh — 通用 SSH 端口迁移工具（v2.1.0）

同一入口，同时适用于 HomeLab（47032，systemd 常规服务）和 VPS（37091，socket 激活 /
nft drop / 云安全组）。**默认只改端口面**：认证策略、authorized_keys、host key
一律不写。

## 与 v2.0.0 的差异（都是审计里确认过的缺陷）

| 项 | v2.0.0 | v2.1.0 |
|---|---|---|
| dual 保留的旧端口 | 写死 22 | 当前已生效的全部端口（`sshd -T` + 活动 socket + `--keep-port`），无法判定时拒绝执行 |
| final 成功判据 | `--confirmed` + 本机监听 | 必须带 `--evidence`：另一台主机用公钥登录新端口的挑战-应答记录，且服务端确认 `SSH_CONNECTION` 的服务端口 = 新端口 |
| 防火墙 / 安全组 | 不看 | 主机防火墙 drop 且无放行规则时 final 只能靠“外部登录成功”这一类证据放行；证据客户端是私网地址时还需显式 `--allow-private-verifier` |
| guard 路径 | `$0`，面板下载到 /tmp 时失效 | 复制到 `/var/lib/90ssh/90ssh.sh`，用绝对路径交给 systemd-run；**武装失败直接拒绝 apply，尚未写任何文件** |
| 未确认状态 | 仅进程内 | `/var/lib/90ssh/pending` 落盘，重启后 `status` 仍能看到；apply 会拒绝叠加第二次迁移 |
| 服务单元 | `ssh` 写死 | `ssh.service` / `sshd.service` 自动探测（优先运行中的），可用 `--service` 指定 |
| socket | `ssh.socket.d` 写死、文件名排序早于 override | `ssh.socket` / `sshd.socket` 各自目录；`zz-90ssh.conf` 排序最后；若有更晚的 ListenStream drop-in 直接拒绝 |
| socket 监听地址 | 无条件写 v4+v6 | 复用当前 socket 实际绑定的地址族（v4-only 主机不会被动开 v6） |
| final 的 ListenAddress | 只追加 | 写入后核对**全量** `listenaddress` 集合与 `ss` 实际绑定，任何多余地址/端口都回滚；foreign ListenAddress 必须先 `--take-over` |
| 命名 | `10-homelab-ssh.conf`、`p6-` token | 默认 `90-ssh-port.conf`；检测到旧文件时沿用，不产生第二个 Port 源 |

## 用法

```
90ssh.sh                                   # 交互式菜单（终端）；非终端打印用法后退出
90ssh.sh status                            # 只读
90ssh.sh plan --port 47040                 # 只读
90ssh.sh apply --port 47040 --mode dual --guard 300 --take-over
90ssh.sh verify --issue-token --port 47040 # 在服务器上生成挑战 token，并打印客户端命令
90ssh.sh verify --port 47040 --host <ip> --key <私钥> --token <t> --evidence /tmp/ev.txt
90ssh.sh apply --port 47040 --mode final --confirmed --evidence /tmp/ev.txt
90ssh.sh confirm --token <t>               # 保留双端口状态并解除 guard
90ssh.sh rollback [--backup DIR]
90ssh.sh test                              # 隔离自测，不需要 root
```

### 端口迁移的完整流程

1. `status` / `plan` 只读确认：当前端口、socket 单元、foreign Port/ListenAddress、防火墙。
2. `apply --mode dual --guard 300 --take-over`：旧端口与新端口并存，guard 到期未确认即自动回滚。
3. `verify --issue-token`（服务器）→ `verify ... --evidence`（另一台机器）。
4. `apply --mode final --confirmed --evidence <文件>`：只剩新端口，按 `--listen`（默认 IPv4-only
   `0.0.0.0`）核对实际绑定，多余监听一律回滚。
5. `--guard` 的确认也可用 `confirm --token`：只解除 guard，不进入 final。

### 证据（evidence）怎么算“真实”

`verify` 在客户端用 `PreferredAuthentications=publickey`、`PasswordAuthentication=no` 登录，
在远端执行一条只读命令，拿回：

- `SSH_CONNECTION`（服务端看到的客户端地址 + **服务端口**）
- 服务器 `/run/90ssh/verify.token`（只有登录成功才能读到）
- 主机名、machine-id、sshd pid、当前生效端口、主机密钥指纹

`final` 校验：token 必须等于本机当前值（一次性，final 成功后删除）、`server_port` 必须等于
新端口、客户端地址不能是本机/回环、时间戳在 `--max-evidence-age`（默认 86400s）内、
machine-id 一致。因此：

- 本机 `ss` 看到端口在听 **不能** 代替验证；
- 从同一台机器 `ssh 127.0.0.1` 得到的记录会被拒绝；
- 从私网地址验证（HomeLab 常见）需要显式 `--allow-private-verifier`，因为它证明不了云安全组。

### 重启与恢复

`/var/lib/90ssh/pending` 落盘，重启后 `status` 仍显示未确认迁移；`systemd-run --on-active`
是瞬时定时器，重启后不会自己再回滚（期间双端口都在，不会失联）。恢复动作：

```
90ssh.sh status
90ssh.sh confirm --token <token>                  # 新端口已验证，保留双端口
90ssh.sh rollback --backup /root/90ssh-backup-*   # 回到迁移前
```

`apply` 在 pending 存在时拒绝执行（`--force-pending` 可覆盖）。

## 兼容性验证

| 环境 | sshd | 结果 |
|---|---|---|
| Debian 12 容器 | 9.2p1 | `test` 84/84 PASS |
| Debian 13 容器 | 10.0p2 | 84/84 PASS |
| Ubuntu 22.04 容器 | 8.9p1 | 84/84 PASS |
| Ubuntu 24.04 容器 | 9.6p1 | 84/84 PASS |
| Debian 13 实机（VM102） | 10.0p2 | 84/84 PASS |
| Alpine（iSH） | 9.9p2 | 84/84 PASS |

**未真实验证**：Rocky/AlmaLinux 8/9 的 SELinux `ssh_port_t`、firewalld 与 `sshd.service`
组合。代码里 `--service sshd`、`--selinux-add`、firewalld 探测都只是逻辑分支，没有在
RHEL 系实机跑过；在这些系统上请先 `plan` 再人工确认。

容器测试只覆盖配置解析/端口面（镜像内无 systemd），unit 名与 socket 排序由自测里的
桩覆盖；socket 激活的真实重启只在 Debian 13 实机评审过配置，未做生产迁移。

## 不改什么

- 不写 `PermitRootLogin` / `PasswordAuthentication` / `PubkeyAuthentication` 等任何认证指令；
- 不读写 `authorized_keys`、host key；`apply` 后用 `sshd -T` 全量对比，除 port/listenaddress
  外的任何差异都会触发回滚；
- 不 enable/disable/mask 任何 unit；
- 不自动改防火墙，只检测并报告（`--allow-firewall-pending` 仅影响 dual 的告警）。

## key-only 模式（本轮未实现）

设计约束（下一轮再做时照此实现）：独立 `20-90ssh-auth.conf`、独立备份/回滚、与端口迁移
解耦、必须用真实公钥登录验证（不能只看本机生成的标记文件）、默认仍是 preserve。
本轮 `--auth-mode` 不存在，任何认证策略都必须由用户自己在变更窗口处理。

## 退出码

`0` 成功；`3` sshd 语法失败已回滚；`4` reload/重启失败已回滚；`5` 新端口未监听或旧端口
丢失已回滚；`6` final 的端口/监听集合不符已回滚；`7` 非端口配置漂移已回滚。
