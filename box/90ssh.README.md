# box/90ssh.sh — 通用 SSH 端口迁移工具（v2.1.0-rc1）

本分支只用于评审，**未合并 main、未部署任何 VPS**。

## 背景

v2.0.0 在 HomeLab（Debian 13 + ssh.service + 22→47032）验证通过，但用于购买的 VPS 时有三个硬阻塞：

1. `SVC="ssh"` 写死，RHEL 系只有 `sshd.service`；
2. `dual` 模式写死 `Port 22`，而 VPS 现行端口是 37091；配合 `--take-over` 会直接丢掉旧端口；
3. 只检查本机 `ss` 监听，不检查 nft/firewalld/安全组，5 台 VPS 的 input 链是 `policy drop` 且只放行 37091。

v2.1.0 保留 v2.0 的备份、双端口、独立校验、guard 回滚、幂等与「不写认证策略」语义，只修上述可移植性问题。

## 新增选项

| 选项 | 作用 |
|---|---|
| `--service ssh\|sshd\|auto` | 指定/自动识别拥有 sshd 的 unit（默认 auto） |
| `--socket auto\|none\|NAME` | 指定/自动识别 socket unit（默认 auto） |
| `--keep-port N` | dual 模式额外保留的端口，可重复；默认保留**当前所有生效端口** |
| `--listen ADDR\|all` | final 模式监听地址（默认 0.0.0.0；all = IPv4+IPv6） |
| `--create-include` | sshd_config 没有 Include 时才追加（默认拒绝） |
| `--allow-firewall-pending` | 已知新端口尚未在防火墙/安全组放行时继续 |
| `--selinux-add` | SELinux enforcing 时把新端口加入 `ssh_port_t` |

## 行为变化（相对 v2.0）

- dual 不再假设旧端口是 22：先用 `sshd -T` + 活动 socket 的 `ListenStream` 计算当前端口，全部保留，再追加新端口；后置校验逐个检查保留端口仍在监听。
- socket 覆盖文件改为 `zz-90ssh.conf`（排序最后，压过 `override.conf` 与 generator 生成的 `addresses.conf`），并列出其他会设置 `ListenStream` 的 drop-in。
- guard：用 `readlink -f` 取脚本绝对路径；另写 `/var/lib/90ssh/pending`，重启后 `status` 能发现「未确认的迁移」。
- rollback：`reload` 失败时回退 `restart`，避免恢复后 sshd 未运行。
- 预检新增：Match 在 Include 之前、SELinux、input drop 且未放行新端口、其他 socket drop-in。
- 版本号 2.1.0。

## 兼容矩阵

| 系统 | 服务/socket | 结论 |
|---|---|---|
| Debian 12/13 | ssh.service，ssh.socket 通常 disabled/masked | 支持 |
| Ubuntu 22.04 | ssh.service + ssh.socket | 支持（socket 覆盖） |
| Ubuntu 24.04 | ssh.service + ssh.socket 默认激活 | 支持（已验证 dmit 的 drop-in 顺序） |
| Rocky/Alma 8/9 | sshd.service，SELinux enforcing，firewalld | 需 `--service sshd`；`--selinux-add`；防火墙需先放行 |
| Alpine/OpenRC、无 Include 的发行版 | 无 ssh.service | 不支持（systemd 假设） |

已在 OpenSSH 9.2p1（Debian 12）、9.6p1（Ubuntu 24.04）、10.0p2（Debian 13）、9.9p2（本地）运行 `90ssh.sh test`：45 项全 PASS。

## 推荐流程（每台 VPS）

```sh
# 0) 只读
90ssh.sh status
90ssh.sh plan --port 47040

# 1) 先在控制台/安全组放行 47040/tcp，再在主机防火墙放行
#    nft: 在现有 input 链加 tcp dport 47040 accept（沿用该机 fwctl/sb_filter 的写法）
#    firewalld: firewall-cmd --add-port=47040/tcp

# 2) 双端口：保留 37091 + 47040
90ssh.sh apply --port 47040 --mode dual --guard 300 --take-over

# 3) 从另一台机器验证（必须成功）
90ssh.sh verify --port 47040 --host <ip> --key /root/.ssh/vps --user root

# 4) 确认
90ssh.sh confirm --token <token>

# 5) 需要时再收口（单独一次）
90ssh.sh apply --port 47040 --mode final --confirmed --listen all
```

## key-only 认证策略（设计，未实现）

目标：只关闭密码认证，且必须以「独立客户端已用公钥登录成功」为前提。

- `apply --auth-mode preserve|key-only`，默认 `preserve`。
- key-only 只写独立 drop-in `20-90ssh-auth.conf`：
  ```
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  ```
  不写 `PermitRootLogin`、不写 `AuthorizedKeysFile`、不改 `authorized_keys`。
- 前置：
  1. `verify` 在目标端口用指定私钥登录成功，并把 `{host,port,key_fp,time,sshd_pid}` 写入 `/run/90ssh/verify-*.json`；
  2. 该 token 在 10 分钟内、端口一致；
  3. 检测 `Match` 块：若某个 Match 允许密码，拒绝执行并打印该块；
  4. 操作者确认云控制台/VNC 可用（`--console-confirmed`）。
- 执行顺序：双端口 → 外部验证 → key-only → final。
- 回滚：auth 变更单独备份，`rollback --auth` 只恢复认证 drop-in。
- 测试方案（隔离）：
  - 起一个临时 sshd（PREFIX，非 22 高端口），生成两把密钥；
  - 未 verify → 拒绝；
  - verify 后 key-only → `ssh -o PreferredAuthentications=password` 必须失败、公钥必须成功；
  - `Match User x` 场景 → 拒绝；
  - rollback → 密码登录恢复；
  - 在 Debian 12/Ubuntu 24.04 各跑一遍。

## 未验证 / 边界

- RHEL 系无实机，SELinux 与 firewalld 分支仅按文档实现，未在 enforcing 主机验证。
- 云安全组无法从主机读取，只能外部探测；工具不会自动改安全组。
- `apply` 的后置校验仍是本机监听，远程可达性必须靠 `verify`。
