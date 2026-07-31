#!/bin/bash
# tests/t-compat.sh —— 旧版本兼容面
#
# 这个套件是「升级即可用」承诺的回归保护。它驱动真实的 fw.sh，断言旧版本的
# 命令、提示文本、幂等语义和交互菜单编号逐字未变。
#
# 原 tests/test_fwctl.sh 的全部断言都折进了这里，因此那个文件不再单独保留。

set -u

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

suite "t-compat"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FW="$TEST_PROJECT_DIR/fw.sh"
FIXTURES="$TEST_PROJECT_DIR/tests/fixtures"

# 每个用例一套独立环境，驱动真实入口脚本。
setup_env() {
    local name=$1
    ENV_DIR="$WORK/$name"
    mkdir -p "$ENV_DIR"
    export FWCTL_STATE_FILE="$ENV_DIR/state.json"
    export FWCTL_VAR_DIR="$ENV_DIR/var"
    export FWCTL_BUILD_DIR="$ENV_DIR/build"
    export FWCTL_SYSTEM_CONF="$ENV_DIR/nftables.conf"
    export FWCTL_LOCKFILE="$ENV_DIR/lock"
    export FWCTL_NFT_BIN="$FIXTURES/fake-nft"
    export FAKE_NFT_STATE="$ENV_DIR/kernel"
    export FWCTL_ALLOW_UNPRIVILEGED=1
    export FWCTL_SKIP_SYSTEM_SETUP=1
    export FWCTL_SSH_PORT=37091
    export FWCTL_LOCAL_IPV4S=10.0.0.10
    export FWCTL_PUBLIC_IPV4=198.51.100.10
    unset FWCTL_JSON FWCTL_DRY_RUN FWCTL_QUIET 2>/dev/null || true
    # 以旧格式起步，验证升级路径。
    printf '%s\n' '{"nat_mode":"auto","snat_address":null,"forwards":[],"open_ports":{"tcp":[],"udp":[]},"blacklist":[]}' \
        > "$FWCTL_STATE_FILE"
}

fw() { bash "$FW" "$@"; }

state_ports() { jq -c "$1" "$FWCTL_STATE_FILE"; }

# ── 旧命令：port ──────────────────────────────────────────────────────

setup_env port-basics

assert_ok "port add tcp 单端口" fw port add tcp 10443
assert_eq "TCP 单端口写入状态" "$(state_ports '.ports.tcp')" '["10443"]'
assert_eq "未误写 UDP" "$(state_ports '.ports.udp')" '[]'

assert_ok "port add udp 单端口" fw port add udp 10444
assert_eq "UDP 单端口写入状态" "$(state_ports '.ports.udp')" '["10444"]'

assert_ok "both 大小写不敏感" fw port add BoTh 10445
assert_eq "both 在 TCP 写一份" \
    "$(state_ports '.ports.tcp | index("10445") != null')" "true"
assert_eq "both 在 UDP 写一份" \
    "$(state_ports '.ports.udp | index("10445") != null')" "true"

assert_ok "port add tcp 区间" fw port add tcp 20000-20010
assert_eq "TCP 区间不被展开" \
    "$(state_ports '.ports.tcp | index("20000-20010") != null')" "true"

assert_ok "port add udp 区间" fw port add udp 30000-30010
assert_ok "port add both 区间" fw port add both 40000-40010
assert_eq "both 区间在两个协议各存一份" \
    "$(state_ports '(.ports.tcp | index("40000-40010") != null)
                    and (.ports.udp | index("40000-40010") != null)')" "true"

assert_ok "边界端口 1" fw port add tcp 1
assert_ok "边界端口 65535" fw port add udp 65535
assert_eq "边界端口写入成功" \
    "$(state_ports '(.ports.tcp | index("1") != null)
                    and (.ports.udp | index("65535") != null)')" "true"

# 重复添加幂等，且提示文本与旧版本一致。
before=$(sha256sum "$FWCTL_STATE_FILE")
output=$(fw port add both 40000-40010)
assert_eq "重复添加不改变状态" "$(sha256sum "$FWCTL_STATE_FILE")" "$before"
assert_contains "重复添加的提示文本未变" "$output" "已存在，无需重复添加"
assert_ok "重复添加返回成功" fw port add both 40000-40010

# both 补齐缺失协议时不重复已有的单协议条目。
fw port add tcp 50000-50010 >/dev/null
fw port add both 50000-50010 >/dev/null
assert_eq "both 补齐时不产生重复条目" \
    "$(state_ports '([.ports.tcp[] | select(. == "50000-50010")] | length) == 1
                    and ([.ports.udp[] | select(. == "50000-50010")] | length) == 1')" \
    "true"

# port list 的三行格式逐字未变。
list_output=$(fw port list)
assert_contains "port list 保留 TCP 行" "$list_output" "TCP: 1, 10443, 20000-20010"
assert_contains "port list 保留 UDP 行" "$list_output" "UDP: 10444, 30000-30010, 65535"
assert_contains "port list 保留 BOTH 行" "$list_output" \
    "BOTH: 10445, 40000-40010, 50000-50010"

# 删除
assert_ok "删除单端口" fw port remove tcp 10443
assert_eq "单端口已删除" "$(state_ports '.ports.tcp | index("10443") == null')" "true"
assert_ok "删除区间" fw port remove udp 30000-30010
assert_eq "区间已删除" "$(state_ports '.ports.udp | index("30000-30010") == null')" "true"
assert_ok "删除 both" fw port remove both 40000-40010
assert_eq "both 从两个协议都删除" \
    "$(state_ports '(.ports.tcp | index("40000-40010") == null)
                    and (.ports.udp | index("40000-40010") == null)')" "true"

output=$(fw port remove tcp 59999)
assert_contains "删除不存在端口的提示未变" "$output" "不存在，未做修改"
assert_ok "删除不存在的端口返回成功" fw port remove tcp 59999

# delete 是 remove 的别名（新名词统一用 delete）。
fw port add tcp 12345 >/dev/null
assert_ok "port delete 别名可用" fw port delete tcp 12345
assert_eq "别名确实删除了端口" \
    "$(state_ports '.ports.tcp | index("12345") == null')" "true"

# ── 非法输入：文本与「不改状态」都必须保持 ────────────────────────────

invalid_case() {
    local label=$1 proto=$2 spec=$3 pattern=$4
    local before_hash after_hash output rc
    before_hash=$(sha256sum "$FWCTL_STATE_FILE")
    output=$(fw port add "$proto" "$spec" 2>&1)
    rc=$?
    if ((rc == 0)); then
        not_ok "拒绝 $label" "本应失败但返回 0"
        return
    fi
    after_hash=$(sha256sum "$FWCTL_STATE_FILE")
    if [[ "$before_hash" != "$after_hash" ]]; then
        not_ok "拒绝 $label" "状态被修改了"
        return
    fi
    if [[ "$output" != *"$pattern"* ]]; then
        not_ok "拒绝 $label" "错误文案不含: $pattern" "实际: ${output:0:200}"
        return
    fi
    ok "拒绝 $label 且不改变状态"
}

invalid_case "非法协议" sctp 10443 'tcp、udp 或 both'
invalid_case "空端口" tcp '' '整数或 START-END'
invalid_case "端口 0" tcp 0 '1-65535'
invalid_case "端口 65536" tcp 65536 '1-65535'
invalid_case "反向区间" tcp 61000-60000 '起始端口'
invalid_case "缺少结束端口" tcp 60000- '整数或 START-END'
invalid_case "缺少起始端口" tcp -61000 '整数或 START-END'
invalid_case "多个连字符" tcp 60000-61000-62000 '整数或 START-END'
invalid_case "字母端口" tcp abc '整数或 START-END'

# ── 渲染失败时不保存状态 ──────────────────────────────────────────────

setup_env render-failure
fw port add tcp 443 >/dev/null
before=$(sha256sum "$FWCTL_STATE_FILE")
FAKE_NFT_FAIL_CHECK=1 fw port add both 61000-62000 >/dev/null 2>&1
rc=$?
assert_eq "渲染失败返回非零" "$([[ $rc -ne 0 ]] && echo yes)" "yes"
assert_eq "渲染失败不保存状态" "$(sha256sum "$FWCTL_STATE_FILE")" "$before"
assert_eq "渲染失败不留候选文件" \
    "$(find "$ENV_DIR" -maxdepth 1 -name '.state.json.*' | wc -l)" "0"

output=$(FAKE_NFT_FAIL_CHECK=1 fw port add tcp 61111 2>&1)
assert_contains "渲染失败的提示文本未变" "$output" "端口变更未保存"

# ── 旧命令：render ────────────────────────────────────────────────────

setup_env render
fw port add tcp 443 >/dev/null
output=$(fw render)
assert_eq "render 返回成功" "$?" "0"
assert_contains "render 成功提示未变" "$output" "编译成功，规则已实时应用！"

output=$(FAKE_NFT_FAIL_CHECK=1 fw render 2>&1)
render_rc=$?
assert_eq "render 失败返回非零" "$((render_rc != 0))" "1"
assert_contains "render 失败提示未变" "$output" \
    "编译或加载失败；上一份运行配置和持久配置保持不变。"

# 连续渲染逐字节一致。
fw render >/dev/null
first=$(sha256sum "$FWCTL_BUILD_DIR/nft.conf" | cut -d' ' -f1)
fw render >/dev/null
second=$(sha256sum "$FWCTL_BUILD_DIR/nft.conf" | cut -d' ' -f1)
assert_eq "连续渲染逐字节一致" "$first" "$second"

# ── render.sh 兼容入口 ────────────────────────────────────────────────

setup_env render-shim
fw port add tcp 8443 >/dev/null
before=$(sha256sum "$FWCTL_STATE_FILE")
assert_ok "render.sh --render-only 仍可用" \
    bash "$TEST_PROJECT_DIR/render.sh" --render-only
assert_eq "--render-only 不修改状态" "$(sha256sum "$FWCTL_STATE_FILE")" "$before"
assert_ok "render.sh --check 仍可用" \
    bash "$TEST_PROJECT_DIR/render.sh" --check
assert_fails "render.sh 拒绝未知参数并返回 2" 2 \
    bash "$TEST_PROJECT_DIR/render.sh" --nope

# ── 用法与帮助 ────────────────────────────────────────────────────────

setup_env usage
assert_fails "未知命令返回 2" 2 fw bogus
assert_fails "port 缺少参数返回 2" 2 fw port add tcp
assert_fails "port 多余参数返回 2" 2 fw port list extra
assert_ok "--help 可用" fw --help
assert_ok "-h 可用" fw -h
assert_ok "help 可用" fw help

help_output=$(fw --help)
assert_contains "帮助保留 port add 用法" "$help_output" "port add tcp|udp|both"
assert_contains "帮助保留 port remove 用法" "$help_output" "port remove tcp|udp|both"
assert_contains "帮助保留 port list 用法" "$help_output" "port list"
assert_contains "帮助保留 render 用法" "$help_output" "render"

# ── 旧状态文件兼容 ────────────────────────────────────────────────────

setup_env legacy-state
cp "$FIXTURES/state-v1-production.json" "$FWCTL_STATE_FILE"
assert_ok "含转发与黑名单的旧状态可直接使用" fw port list
assert_ok "旧状态可以渲染" fw render
assert_eq "首次写入后状态已升级" \
    "$(jq -r '.schema_version' "$FWCTL_STATE_FILE")" "4"
assert_eq "记录了迁移来源" \
    "$(jq -r '.metadata.migrated_from' "$FWCTL_STATE_FILE")" "1"
assert_eq "迁移前备份已生成" \
    "$(find "$FWCTL_VAR_DIR/backups" -maxdepth 1 -name 'pre-migration-*' | wc -l)" "1"
assert_eq "状态目录留有 v1 备份" \
    "$([[ -f "$FWCTL_STATE_FILE.v1.bak" ]] && echo yes)" "yes"

# 只读命令不写盘。
setup_env readonly-no-write
cp "$FIXTURES/state-v1-production.json" "$FWCTL_STATE_FILE"
before=$(sha256sum "$FWCTL_STATE_FILE")
fw port list >/dev/null
assert_eq "port list 不写盘" "$(sha256sum "$FWCTL_STATE_FILE")" "$before"
fw validate >/dev/null 2>&1
assert_eq "validate 不写盘" "$(sha256sum "$FWCTL_STATE_FILE")" "$before"
assert_eq "只读命令不生成备份" \
    "$([[ -d "$FWCTL_VAR_DIR/backups" ]] && echo yes || echo no)" "no"

# ── 渲染产物的关键性质 ────────────────────────────────────────────────

setup_env rendered
fw port add tcp 1 >/dev/null
fw port add both 10445 >/dev/null
fw port add tcp 20000-20010 >/dev/null
fw port add udp 60000-61000 >/dev/null
fw render >/dev/null

conf="$FWCTL_BUILD_DIR/nft.conf"
assert_contains "区间渲染为原生 interval" "$(cat "$conf")" "20000-20010"
assert_contains "TCP set 含全部端口" "$(cat "$conf")" \
    "elements = { 1, 10445, 20000-20010 }"
assert_contains "UDP set 含全部端口" "$(cat "$conf")" \
    "elements = { 10445, 60000-61000 }"

ssh_line=$(grep -n 'tcp dport 37091' "$conf" | cut -d: -f1)
allowed_line=$(grep -n 'tcp dport @allowed_ports_tcp' "$conf" | cut -d: -f1)
limit_line=$(grep -n 'tcp flags syn limit rate over' "$conf" | cut -d: -f1)
assert_eq "SSH 放行早于 SYN 限速" \
    "$([[ "$ssh_line" -lt "$limit_line" ]] && echo yes)" "yes"
assert_eq "放行端口早于 SYN 限速" \
    "$([[ "$allowed_line" -lt "$limit_line" ]] && echo yes)" "yes"

# ── 交互菜单编号 ──────────────────────────────────────────────────────
# 用户和文档里存在「输入 4 放行端口」这样的肌肉记忆，编号不能变。

menu_source=$(cat "$TEST_PROJECT_DIR/fw.sh")
assert_contains "菜单 1-3 转发项未变" "$menu_source" \
    "1. 添加端口转发    2. 删除端口转发    3. 查看端口转发"
assert_contains "菜单 4-6 端口项未变" "$menu_source" \
    "4. 放行端口        5. 删除放行端口    6. 查看放行端口"
assert_contains "菜单 7-9 黑名单项未变" "$menu_source" \
    "7. 封禁IP          8. 解封IP          9. 查看黑名单"
assert_contains "菜单 10 未变" "$menu_source" "10. SSH防爆破"
assert_contains "菜单 11 未变" "$menu_source" "11. DDOS防护"
assert_contains "菜单 12 未变" "$menu_source" "12. 重载配置"
assert_contains "菜单 0 退出未变" "$menu_source" "0. 退出"
assert_contains "新增项追加在 13 之后" "$menu_source" "13. 对象管理"

# ── install.sh 仍能选中 fw.sh 作为主脚本 ──────────────────────────────

main_script=$(find "$TEST_PROJECT_DIR" -maxdepth 1 -type f -name "*.sh" \
    ! -name "install.sh" ! -name "render.sh" | sort | head -n1)
assert_eq "install.sh 的主脚本探测仍选中 fw.sh" \
    "$(basename "$main_script")" "fw.sh"

finish
