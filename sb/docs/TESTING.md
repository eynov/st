# 测试体系

本文档定义 sb 当前可重复执行的验证入口、真实组件与 mock 边界。故障排查命令见
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)。

## 前置条件

完整套件要求以下已经独立校验来源与摘要的可执行文件：

- sing-box `1.13.15`
- Hysteria `v2.10.0`
- shadowsocks-rust `ssurl` `v1.24.0`
- Bash、jq、OpenSSL、Python 3、ripgrep、flock、sha256sum
- ShellCheck `0.11.0` 用于当前静态验收

测试不得自动从未固定的 `latest` 下载依赖。组件获取与 digest 更新流程见
[`OPERATIONS.md`](OPERATIONS.md)。

## 完整隔离测试

```bash
SB_TEST_REAL_CORE=/path/to/sing-box-1.13.15 \
SB_TEST_HYSTERIA_BIN=/path/to/hysteria-v2.10.0-linux-amd64 \
SB_TEST_SSURL_BIN=/path/to/shadowsocks-rust-v1.24.0/ssurl \
  sb/tests/run.sh
```

`sb/tests/run.sh` 当前注册 52 个测试函数。VLESS 三模式新增专项入口
`test_vless_three_mode_contract`，覆盖 add/edit/enable/disable/delete、非法组合、旧 state
兼容、backup/restore、state export/import、manager upgrade、URI、Mihomo，以及固定核心对
服务端和客户端配置的真实 check。`test_cross_pin_upgrade_bootstrap` 与
`test_cross_pin_upgrade_rollback` 覆盖核心 pin 变化时的无修改拒绝、显式组合升级、完整回滚及
rc=70 恢复材料保留。`test_legacy_endpoint_recovery` 与 `test_legacy_bootstrap_no_deadlock`
覆盖 v2→v3 迁移的 endpoint 恢复：从旧 `sub.yaml` 恢复成功、显式 `--endpoint` 优先、
旧输出缺失/多值不一致/非全局地址三种拒绝，以及拒绝时 rc=78、零修改、保留新 release
与新 manager、单条命令补齐后完成迁移；同时固定「其他失败仍整体回滚并删除 release」这条
边界。

当前套件的执行结果为：

```text
RESULT: pass=750 fail=0
skip=0
xfail=0
```

这个 pass 数说明现有断言通过，不等于所有真实 systemd、cgroup、reboot 或 VPS 网络行为
已经验收；真实主机验证的范围见
[`KNOWN_LIMITATIONS.md`](internal/KNOWN_LIMITATIONS.md)。

## 静态检查

在 Bash 中执行：

```bash
mapfile -d '' -t shell_files < <(
  find sb -type f \( -name '*.sh' -o -name sb -o -path '*/fixtures/mock-*' \) -print0
)
bash -n file.sh "${shell_files[@]}"
shellcheck --severity=warning --external-sources file.sh "${shell_files[@]}"
git diff --check
```

不要忽略失败退出码，也不要用减少扫描文件范围的方式消除告警。

## 使用真实组件的验证

- 固定 sing-box 对生成的服务端配置和 sing-box outbound 执行真实 `check`。
- Hysteria 官方客户端/parser 对 trusted、provided、self-signed、explicit insecure
  执行本地回环、低流量 TLS 握手。
- shadowsocks-rust `ssurl` 解析 SS2022 SIP002 URI，包括 IPv4、IPv6、域名、保留
  字符与 Unicode tag。
- OpenSSL 验证 SAN、cert/key 配对、证书 fingerprint 与 SPKI 的字段边界。
- 内核 `flock` 和并发子进程验证全局锁竞争。

## 使用 mock 的验证

- `tests/fixtures/mock-systemctl`：enabled/active/MainPID、start/restart/stop 和失败注入。
- `tests/fixtures/mock-ss`：socket PID、协议、地址与端口输入。
- `tests/fixtures/mock-getent`：endpoint 域名解析结果。
- `tests/fixtures/mock-sing-box-fail-check`：候选配置检查失败。

`mock-systemctl` 的 observed socket 数据**不读取** `output/manifest.json`。它从
`output/config.json` 的 inbounds 推导应绑定的端口，即真实 sing-box 会绑定的东西，并按
inbound type 映射传输层（shadowsocks→tcp+udp、hysteria2→udp、vless→tcp、anytls→tcp）。
`config.json` 由 `PROTO_INBOUND` 渲染，`manifest.json` 由独立的 `PROTO_EXPECTED` 渲染，
因此 `service_verify_listeners` 比较的两侧来自不同代码路径，不构成循环证明。

测试也可以完全接管 observed 世界，用于差异测试：

- `$SB_TEST_RUNTIME_DIR/observed-sockets.tsv`：`network<TAB>address<TAB>port<TAB>pid<TAB>generation`，
  其中 `MAINPID` 会被替换为 mock 实际启动的 PID；存在时完全取代 config 推导的表；
- `$SB_TEST_RUNTIME_DIR/observed-generation`：服务报告的 cwd（其加载的 generation）；
- `$SB_TEST_RUNTIME_DIR/observed-mainpid`：`systemctl show` 报告的 MainPID。

隔离 mock 只验证 verifier 逻辑，不能替代真实 systemd/ss/cgroup 验证。

## 故障注入

安全关键路径的失败分支由 `SB_TEST_FAULTS`（冒号分隔的注入点名）配合 `SB_TEST_MODE=true`
触发。注入**不伪造返回码**：它扰动文件系统，让真实命令以真实 errno 失败（暂存路径重定向到
不存在的目录 → `ln` ENOENT；rename 前删除暂存文件 → `mv` ENOENT；预先占用重命名目标 →
`mv -T` ENOTEMPTY）。`SB_TEST_MODE` 非 true 时全部注入点均无效，生产路径不可能走到注入分支。

| 注入点 | 触发的失败 |
|---|---|
| `generation-final-mv` | candidate → final generation 重命名 |
| `current-new-create` | `.current.new` 符号链接创建 |
| `current-new-switch` | `.current.new` → `current` 原子切换 |
| `current-rollback-create` | 回滚用符号链接创建 |
| `current-rollback-switch` | 回滚 current 切换 |
| `release-stage-mkdir` | release 暂存目录创建 |
| `release-copy` | 源码树复制进 release 暂存目录 |
| `release-validate` | staged release 校验 |
| `release-final-mv` | stage → release 目录重命名 |
| `app-new-create` / `app-new-switch` | `.app.new` 创建 / 切换 |
| `app-selfcheck` | 新 manager 自检 |
| `app-rollback-create` / `app-rollback-switch` | app 回滚链接创建 / 切换 |
| `cli-link-create` / `cli-link-switch` | 管理命令链接创建 / 切换 |
| `upgrade-app-rollback-create` / `-switch` | upgrade 路径的 app 回滚 |
| `state-set-write` | state 写入的 mktemp（mutator 层失败，符号链接矩阵到不了这里） |
| `core-post-switch-verify` | 核心切换后的校验 |
| `core-backup-restore` | `core_switch` 回滚旧二进制 |
| `core-upgrade-restore` | `core_upgrade` 回滚旧二进制 |

备份路径另有独立的 `SB_TEST_BACKUP_FAIL_AT`（`state-copy`、`generation-copy`、`cert-copy`、
`settings-copy`、`metadata-write`、`target-dir` 等）。

## errexit 条件上下文检查

`tests/errexit-audit.sh` 作为测试项 `test_errexit_audit_guard` 运行，扫描生产文件函数体中
未显式检查退出码的状态变更命令。它是启发式检查，**不能替代人工审计**；期望结果为
`0 blocking`。确需例外时在同一行标注 `# errexit-audit: ok <理由>`。

## 真实 systemd 边界

隔离环境不能证明：

- systemd system bus 和 unit sandbox 行为
- MainPID 与真实 cgroup/socket owner
- reload/restart 后 generation 是否真正加载
- 删除节点后旧 socket 是否真实消失
- `Restart=on-failure`
- VPS reboot 后有节点恢复（已在 `de` 实测通过）和零节点保持 stopped（仍未验证）
- 核心升级及事务 rollback 后的真实 service 恢复

这些项目只能在真实主机上做低流量验证；已验证与未验证的划分见
[`KNOWN_LIMITATIONS.md`](internal/KNOWN_LIMITATIONS.md)。
mock 结果不得写成上述项目已通过。

## 临时文件

测试通过 `mktemp` 创建隔离根目录，并在退出 trap 中清理。失败调试时若显式设置
`SB_TEST_KEEP=true`，执行者负责记录并删除保留目录。禁止使用固定
`/tmp/sb-test-failure.out` 或把下载二进制、证书、state、订阅写入仓库。

## salvage 快照

`backup_create` 的 salvage 模式只在恢复路径启用，且只在 **live 源确实无法通过校验**时进入
（`backup_live_source_valid`：generation 结构、`runtime_validate_generation`、state 与
settings schema）。健康安装上的 `sb restore` 必须产生 `salvage:false` 的已校验快照。

salvage 快照在 `metadata.json` 中标记 `salvage: true`，默认**拒绝**被恢复；需要
`--restore-unvalidated-salvage` 显式确认，并会打印 `DANGEROUS` 警告、把
「UNVALIDATED salvage snapshot」写入 `status.json` 的 `last_publish.description`。

该标志是知情确认而不是绕过：内容确实损坏的快照仍会被随后的 `backup_validate` 拒绝。

salvage 不可从环境启用。`SB_TXN_SALVAGE_BACKUP` 在 `core/common.sh` 中于任何命令运行前被
`unset`，内部调用方传递每进程随机的 `SB_INTERNAL_MARKER`。
