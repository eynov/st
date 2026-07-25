# Repair Review Pack — sb 3.0

日期：2026-07-25  
范围：Gitea `S/st` 仓库的 `sb` 项目  
边界：仅仓库与 `/tmp` 隔离环境；未连接 VPS、未部署、未操作防火墙、未
commit/push。

## Executive Summary

本轮针对《Final Independent Review》确认的 8 个 High 和直接相关 Medium 做了
代码级修复，没有以改文档或降低严重度代替实现。当前隔离回归结果：

```text
完整自动测试：241 pass / 0 fail（无 skip、无 xfail）
真实 sing-box：1.13.14
真实 Hysteria parser/client：v2.10.0
真实 SIP002 parser：shadowsocks-rust ssurl v1.24.0
ShellCheck：0.11.0，warning 级 0
bash -n：通过
git diff --check：通过
```

当前没有已知未解决 Critical/High。由于容器 PID 1 为 `bwrap`，systemd system bus
不可用，真实 systemd/cgroup 集成未在本轮验证；因此结论为
**Repository Production Candidate，不标记 Production Ready**。完成再次独立复审
后，可以进入单台 VPS 的受控低流量灰度，并把真实 systemd 验收作为强制门槛。

## 8 个 High 的逐项修复证据

### H1 — 备份失败曾可能返回成功

- `core/backup.sh` 使用隐藏候选目录；只有 state、settings、generation、全部输出、
  TLS cert/key、metadata 和权限验证通过后才原子 rename 为正式备份。
- `cp`、`find`、`chmod`、metadata write、目录创建均传播非零。
- TLS 验证包含证书/私钥解析、公钥配对、SAN/SNI、有效期与完整证书 fingerprint。
- 事务、迁移、manager/core upgrade 在备份失败时立即停止。
- 故障注入覆盖 `state-copy`、`generation-copy`、`cert-copy`、`settings-copy`、
  `metadata-write`、`target-dir`：`20 pass / 0 fail`；无可见成功目录、无隐藏候选。

### H2 — settings 曾在锁外修改

- live settings 进入 generation；`/etc/sb/settings.json` 仅为 current settings
  兼容 symlink。
- endpoint/listen 在同一 global flock 内读取候选 settings/state，生成候选输出，
  backup、current 原子切换、服务验收；失败只切回旧 current 即同时恢复
  settings/state/config/全部客户端输出。
- endpoint vs add/backup/restore/endpoint 以及 listen vs edit 并发均稳定返回
  `75`；settings 发布失败哈希整体恢复：`9 pass / 0 fail`。

### H3 — HY2 URI 曾混淆 SPKI 与证书 fingerprint

- sing-box `certificate_public_key_sha256` 继续使用 SPKI。
- Hysteria URI `pinSHA256` 改为叶证书 DER SHA-256，即
  `openssl x509 -fingerprint -sha256` 的值。
- trusted URI 无 insecure/pin；provided/self-signed 为
  `insecure=1 + pinSHA256`；explicit insecure 只有 `insecure=1`。
- 官方 Hysteria v2.10.0 完成 trusted、provided、self-signed、insecure 四次本地
  回环低流量 TLS 握手；两种 pin 模式均断言证书 fingerprint 等于 URI pin 且不等于
  SPKI。

### H4 — SS2022 URI 曾错误整体 Base64URL

- AEAD-2022 userinfo 改为 `percent(method):percent(password)`，不再整体 Base64URL。
- 普通 SS 保持其独立 SIP002 Base64URL 逻辑。
- 官方 shadowsocks-rust v1.24.0 `ssurl` 实际解析 Base64 PSK 中的 `+ / =`、
  percent encoding、IPv4、IPv6、域名以及 Unicode/空格 tag。
- SS2022 Surge 仍明确禁用，不生成未经验证的伪配置。

### H5 — listener 验收曾只证明“有人占端口”

- 使用 systemd MainPID；生产路径同时验证 executable 与 unit cgroup。
- socket 必须由 MainPID 持有，且 network、listen address、port 全部匹配。
- `/proc/<MainPID>/cwd` 必须解析到 current generation output，用新 PID 证明
  generation 已加载；发布采用受控 restart，不把 HUP 成功当配置生效。
- 删除/停用节点检查旧 socket 消失，零节点 stop 后同样检查。
- “其他进程占用、无 socket、错误地址、stale generation、restart 假成功、
  delete 后残留”测试：`7 pass / 0 fail`。mock socket 状态不再从 expected manifest
  自动生成查询结果，避免循环证明。

### H6 — 同版本核心曾只看 version

- `checksums.json` 固定官方归档与解压后二进制双重 SHA256；文件自身 digest 固定在
  `core/common.sh`。
- 安装 receipt 保存 version、architecture、binary SHA256、source、verified_at。
- install/upgrade/doctor 同时验证 checksum source、archive、内部路径、binary
  digest、version、receipt 与真实 `sing-box check`。
- 同版本伪造程序会被识别并修复；错误 digest、正确 digest 但不可执行、篡改
  checksum、错误架构、非归档、错误内部路径均被拒绝：`8 pass / 0 fail`。

固定值：

| 架构 | archive SHA256 | binary SHA256 |
|---|---|---|
| amd64 | `f48703461a15476951ac4967cdad339d986f4b8096b4eb3ff0829a500502d697` | `68aeab83cc4ab2659a5b92232261a20746ccdafc3b3d1e19b2d63247eec3bbf7` |
| arm64 | `4742df6a4314e8ecc41736849fca6d73b8f9e91b6e8b06ee794ff17ba180579e` | `85f570b96754cd7c354d28e50f66e9340b374e06b5d77ec9e15e8d04f0c87a25` |

### H7 — 根安装器曾隐式注入 `--yes`

- `file.sh` 和 `sb/install.sh` 只在调用者实际传入 `--yes` 时向下游传递。
- 测试捕获真实下游 argv，确认无 `--yes`。
- 非交互 HY2 hopping 即使存在 `--yes` 仍必须显式
  `--ack-port-hopping`；确认内容覆盖完整 UDP range 放行、range→base 转发和项目
  不操作防火墙三项责任。
- 旧未确认 hopping 保留配置但 disabled，并标记 `confirmation_required`；
  validate/doctor 告警，显式确认后才能 enable。

### H8 — 重复安装/升级曾不完整验证 live 数据

- repeat install 在写 unit 前验证 current state、settings、manifest、config、
  clients、schema、权限及真实固定核心 check。
- 未知/缺失 schema、损坏 state JSON、损坏 settings JSON、broken current
  symlink、缺失 manifest、零节点损坏 state 均非零且无成功提示：
  `14 pass / 0 fail`。
- 未知更高 schema 不会被旧程序迁移或覆盖。

## 直接相关 Medium

- 零节点策略：unit enabled、service stopped；`ExecCondition` 阻止重启后启动空
  generation。首节点启动，有节点重启恢复，停用/删除最后节点跨重启保持 stopped：
  `8 pass / 0 fail`（mock systemd；真实 systemd 待灰度）。
- 迁移：不使用 `cp -an`；整棵候选 cert 原子切换；备份包含旧 output；旧源不删除。
  legacy backup、cert swap 后、render 后三种中断均清理候选并可幂等重试，密码和
  证书哈希保持：`18 pass / 0 fail`。
- 首次安装失败：恢复旧 app/command 状态，删除失败 release；测试无 broken link。
- restore：恢复 settings/state/重新生成 generation/整棵 cert；即使 live cert
  已缺失也能从备份恢复。app/unit/core 明确不属于 `sb restore` 自动数据恢复。
- 核心升级前有启用节点但服务 inactive：升级后主动 start 并验证。
- endpoint：拒绝 RFC1918、loopback、link-local、CGNAT、unspecified、multicast、
  documentation ranges、ULA 等；域名无解析或解析到非全局地址也拒绝，除非显式
  override。
- `75` 明确定义为 global lock 的 `EX_TEMPFAIL`。
- 根 `file.sh` 恢复通用 `--source-dir` 项目路由，并对失败做原子回退测试。
- 测试输出使用每次 `mktemp`，不再遗留固定 `/tmp/sb-test-failure.out`。

## 实际修改文件

入口/元数据：`file.sh`、`sb/install.sh`、`sb/sb`、`sb/version.json`、
`sb/checksums.json`、`sb/README.md`。

核心：`core/common.sh`、`settings.sh`、`state.sh`、`registry.sh`、`runtime.sh`、
`transaction.sh`、`service.sh`、`install.sh`、`manager.sh`、`migration.sh`、
`backup.sh`、`tls.sh`、`doctor.sh`。

协议：`protocols/ss.sh`、`ss2022.sh`、`anytls.sh`、`vless.sh`、`hy2.sh`。

测试：`tests/run.sh`、`tests/real-hysteria-handshake.sh`、`tests/fixtures/mock-systemctl`、
`mock-ss`、`mock-getent`、`mock-sing-box-fail-check`。

文档：`README.md` 与 `docs/` 下架构、协议、运维、防火墙、TLS、schema、排障、
限制、生产清单和本 Review Pack。

删除 tracked 生产数据 `sb/instances.json` 与失效占位文件
`sb/protocols/xxxx.txt`。

## 测试可信度与 mock 边界

真实组件：

- sing-box `1.13.14`：所有 server config 与生成 outbound 的实际 `check`；
- Hysteria v2.10.0：官方 parser/client 与四种本地 TLS 握手；
- shadowsocks-rust v1.24.0 `ssurl`：真实 SIP002 decode；
- OpenSSL：SAN、链、cert/key、公钥与完整证书 fingerprint；
- 实际 `flock` 与并发进程。

mock：

- `systemctl`：enabled/active/MainPID、restart 失败、inactive、零节点启动状态机；
- `ss`：从独立 runtime socket 表返回 PID/address/network，不读取 expected manifest。

mock 无法证明真实 systemd D-Bus、unit sandbox、kernel cgroup 与真实 sing-box socket
ownership；这些项目明确未标记通过。

## 静态、权限与临时文件

- `bash -n`：通过。
- ShellCheck `0.11.0 --severity=warning --external-sources`：0 issue。
- `git diff --check`：通过。
- generation/state/settings/client/cert/backup/temp 权限测试：通过；敏感文件
  `0600`，私有目录和备份可执行文件 `0700`。
- 测试日志未输出密码、UUID、私钥或完整订阅；state export 默认脱敏。
- 测试退出后检查 `.txn-*`、`.migrate-*`、`.cert-migrate-*`、固定 failure output：
  无当前测试遗留。

## 尚未验证与结论

本轮环境：

```text
PID 1: bwrap
systemctl: Failed to connect to system scope bus
```

因此真实 systemd unit、MainPID/cgroup 和主机重启行为是唯一重要未验证项；云安全组、
外部 NAT/UDP 与 DDoS 限制也不属于仓库隔离测试可证明范围。

- 当前已知 Critical：`0`
- 当前已知 High：`0`
- Repository Production Ready：**否（真实 systemd 门槛未完成）**
- 单台 VPS 灰度：**建议在再次独立复审通过后进入，且只做低流量灰度**

灰度前必须：保存旧 app/state/settings/output/certs/unit/core 与 digest；确认源码
归档摘要；确认 TCP/UDP 和 HY2 range→base 外部规则；先验证零节点
enabled/stopped/重启，再逐一验证首节点、MainPID/cgroup/socket owner、stale
generation、异常退出重启、最后节点 stop 与恢复。失败时恢复旧 app link、data
backup、unit 与核心，`daemon-reload` 后重新验证；防火墙由使用者按灰度前记录单独
回滚。

本轮未连接或修改任何生产 VPS，未执行生产部署、服务重启、防火墙操作、Git
commit 或 push。
