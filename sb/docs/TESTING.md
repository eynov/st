# 测试体系

本文档定义 sb 当前可重复执行的验证入口、真实组件与 mock 边界。故障排查命令见
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)。

## 前置条件

完整套件要求以下已经独立校验来源与摘要的可执行文件：

- sing-box `1.13.14`
- Hysteria `v2.10.0`
- shadowsocks-rust `ssurl` `v1.24.0`
- Bash、jq、OpenSSL、Python 3、ripgrep、flock、sha256sum
- ShellCheck `0.11.0` 用于当前静态验收

测试不得自动从未固定的 `latest` 下载依赖。组件获取与 digest 更新流程见
[`OPERATIONS.md`](OPERATIONS.md)。

## 完整隔离测试

```bash
SB_TEST_REAL_CORE=/path/to/sing-box-1.13.14 \
SB_TEST_HYSTERIA_BIN=/path/to/hysteria-v2.10.0-linux-amd64 \
SB_TEST_SSURL_BIN=/path/to/shadowsocks-rust-v1.24.0/ssurl \
  sb/tests/run.sh
```

`sb/tests/run.sh` 当前注册 29 个测试函数。最近一次独立复审实际执行结果为：

```text
RESULT: pass=241 fail=0
skip=0
xfail=0
```

这个 pass 数不覆盖当前已知的两个 High；它说明现有断言通过，不等于所有安全关键
失败路径已被正确建模。当前准入状态见 [`AI_HANDOFF.md`](AI_HANDOFF.md)。

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

当前 `mock-systemctl` 的 socket 数据仍由 current generation 的预期 manifest 派生，
因此监听归属相关测试存在循环证明，不能作为独立运行事实。此问题是
`AI_HANDOFF.md` 记录的 Medium。

## 真实 systemd 边界

隔离环境不能证明：

- systemd system bus 和 unit sandbox 行为
- MainPID 与真实 cgroup/socket owner
- reload/restart 后 generation 是否真正加载
- 删除节点后旧 socket 是否真实消失
- `Restart=on-failure`
- VPS reboot 后有节点恢复和零节点保持 stopped
- 核心升级及事务 rollback 后的真实 service 恢复

这些项目必须在两个 High 清零并获批后，于单台测试 VPS 做低流量灰度。mock 结果不得
写成上述项目已通过。

## 临时文件

测试通过 `mktemp` 创建隔离根目录，并在退出 trap 中清理。失败调试时若显式设置
`SB_TEST_KEEP=true`，执行者负责记录并删除保留目录。禁止使用固定
`/tmp/sb-test-failure.out` 或把下载二进制、证书、state、订阅写入仓库。
