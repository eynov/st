# sb 维护记录

本文件记录 sb 的验证入口、真实主机验证结果和仍然开放的复审发现。稳定的用户说明见
[`../../README.md`](../../README.md)，产品边界见
[`KNOWN_LIMITATIONS.md`](KNOWN_LIMITATIONS.md)，历次复审的完整证据快照见
[`FINAL_REVIEW_PACK.md`](FINAL_REVIEW_PACK.md)。

修改代码前请按 [`AGENTS.md`](../../AGENTS.md) 指定的方式确认工作树状态；本文件不记录
工作树快照，Git 才是事实来源。

## 复现与验证入口

```bash
SB_TEST_REAL_CORE=/path/to/sing-box-1.13.15 \
SB_TEST_HYSTERIA_BIN=/path/to/hysteria-v2.10.0-linux-amd64 \
SB_TEST_SSURL_BIN=/path/to/shadowsocks-rust-v1.24.0/ssurl \
  sb/tests/run.sh

sb/tests/errexit-audit.sh            # 期望 0 blocking

mapfile -d '' -t shell_files < <(
  find sb -type f \( -name '*.sh' -o -name sb -o -path '*/fixtures/mock-*' \) -print0
)
bash -n file.sh "${shell_files[@]}"
shellcheck --severity=warning --external-sources file.sh "${shell_files[@]}"
git diff --check
```

故障注入通过 `SB_TEST_FAULTS`（冒号分隔）配合 `SB_TEST_MODE=true` 启用；注入点清单见
[`TESTING.md`](../TESTING.md)。测试所需的固定二进制、真实组件与 mock 边界同样以
`TESTING.md` 为准。

## 当前核心 pin 验证

2026-08-03 将受控核心 pin 从 `1.13.14` 更新到官方 Stable `1.13.15`。官方 amd64/arm64
归档摘要和解压后二进制摘要均已独立核对；完整隔离套件使用真实 `1.13.15` 核心、Hysteria
v2.10.0 与 shadowsocks-rust ssurl v1.24.0，结果为 `652 pass / 0 fail`。该轮没有在生产
VPS 上执行 manager/core upgrade；真实部署仍须按生产 checklist 单独验收。

MainPID 的 fork-before-exec 窗口已由 `service_wait_ownership()` 的有界等待覆盖；测试同时
固定 executable 与 cgroup 两个归属谓词，永久不匹配时仍失败并回滚，不能把 mock 结果表述
为新的真实 systemd 验收。

同日发现首个 `1.13.14 → 1.13.15` 生产迁移存在 bootstrap deadlock：旧 manager 的
`sb core upgrade` 只能安装旧 pin，而新 manager 在 install 阶段会拒绝旧核心并回滚。修复后，
跨 pin 的普通 `sb upgrade` 在任何修改前返回 `64`；显式
`sb upgrade --source DIR --upgrade-core` 在一个锁和一份 pre-manager 备份内切换新 manager、
升级固定核心并执行 install，失败时整体恢复旧 app/core receipt/unit/data。专项测试覆盖成功、
未授权拒绝、source metadata 漂移、core switch 失败、install 失败及恢复失败 rc=70；真实 VPS
部署仍未在仓库隔离测试中验证。加入这些回归后，完整 50 函数隔离套件为
`689 pass / 0 fail`。

同日在生产 aws-sg（sb v2 + sing-box 1.13.15，HY2 + VLESS 在跑）上发现第二个 bootstrap
deadlock，与跨 pin 那个无关：v2 从不保存 endpoint，`sb install` 迁移旧 `/opt/sb` 时
bootstrap settings 的 endpoint 仍是 `unset`，渲染阶段 `endpoint_get` 失败，`install.sh`
把应用切换整体回滚并删除新 release，于是能配置 endpoint 的新 manager 不复存在，重试
无限循环。修复分两层：迁移在**改动任何数据之前**从旧 `/opt/sb/output/sub.yaml` 的 clash
`server` 字段恢复 endpoint（要求全部条目一致，并通过与手工输入完全相同的校验），显式
`--endpoint` 优先；无法确认时返回新的 `SB_EX_MIGRATION_INPUT=78`，`install.sh` 与
`cmd_upgrade` 对这个码**保留**新 release 和应用链接，只提示
`sb install --endpoint <host> --yes`，其他失败仍按原语义整体回滚。加入两组回归后
完整 52 函数隔离套件为 `750 pass / 0 fail`；该修复尚未在任何真实主机上验证。

2026-08-03 首次真实 v2→v3 生产迁移（aws-sg）暴露第三个问题，endpoint 恢复本身工作正常
（Path A，从旧 `sub.yaml` 恢复出的地址与该主机 A 记录和当前公网 IPv4 一致）。两个缺陷：
其一，`cmd_install` 在刚创建 layout 时若发现 `sb-core` 已 active 就只做 config 检查，不
重启——同名 unit 下跑的是 sb v2 进程，cwd 仍是 `/opt/sb/output`，且此前失败尝试的
`core_switch` 已替换二进制，使它的 `/proc/<pid>/exe` 变成 `(deleted)`，归属验收必然失败；
其二，`install.sh` 回滚时不恢复 systemd unit，于是 `ExecCondition=/opt/sb/app/sb` 的新 unit
留在盘上而 release 已删除——服务靠内存中的旧进程继续服务，但**下次重启必然起不来**。真实
主机上确实进入了这个状态，已用迁移自己生成的 legacy backup 中的 `sb-core.service` 恢复。
修复：layout 为本次新建时强制 `service_restart`；install.sh 保存并按字节恢复原 unit（原本
没有则删除），恢复失败返回 `70`。加入回归后完整 53 函数隔离套件为 `766 pass / 0 fail`。

bootstrap 的首个调用必须来自 reviewed checkout：
`env -u SB_APP_DIR /root/st/sb/sb upgrade --source /root/st/sb --upgrade-core --yes`。
原因是此前已安装的 manager 不可能认识后来新增的 flag。新源码入口比较 source pin 与
`/opt/sb/app/version.json` 中的 installed pin，并调用旧 manager 在继承锁内创建 pre-upgrade
backup；测试不能只模拟“旧 pin + 新代码”，必须保留这个 source-entrypoint 边界。

## 真实主机验证

隔离环境的 PID 1 是 `bwrap`，无法连接 systemd system bus，因此涉及真实 systemd、内核
cgroup、reboot 与 VPS 网络的行为必须在真实主机上单独验证。

已在一台 Debian 12 VPS 上实测通过：真实 systemd unit 与 MainPID/cgroup 归属、generation
实际加载、restart/reload、删除节点后旧 socket 消失、事务失败后的真实 service 回滚、七种
协议与模式的真实客户端握手，以及一次真实重启后带节点自动恢复。

尚未验证的边界统一记录在 [`KNOWN_LIMITATIONS.md`](KNOWN_LIMITATIONS.md)，不在本文件重复。

新主机的部署与验收步骤见 [`PRODUCTION_CHECKLIST.md`](PRODUCTION_CHECKLIST.md)。

## 开放的复审发现

三轮独立只读复审的阻断项（Critical、High、阻断 Medium）均已修复，并在同一注入点复测通过。
以下非阻断项仍然开放：

- **M-3.5 / M6**：`errexit-audit.sh` 只匹配字面命令，不覆盖 `safe_mkdir`、`atomic_write`、
  `state_set_file` 等包装函数。正是这个盲区放过了 HIGH-A。复扫确认剩余 13 处包装调用点
  当前都不会掩盖失败，但审计覆盖本身仍需补齐——这是优先级最高的一项。
- **M-3.3**：非 root 运行 `sb doctor` 时 `listeners` 检查仍失败。
- **M-3.4**、第二次复审的 M5，以及两轮复审的 Low 列表。

修复这些项时仍适用两条要求：不得用修改 Review Pack、降低严重度或增加宽松测试代替代码
修复；不得把 mock systemd 结果表述为真实 systemd 验收。
