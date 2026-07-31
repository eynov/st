#!/bin/bash
# tests/t-render.sh —— 渲染引擎
#
# 覆盖 docs/adr/0002-own-table-no-flush.md 的渲染契约与 ARCHITECTURE.md 的
# 「渲染确定性」：不 flush ruleset、只管理自己的表、旧表收编、对象展开、
# 排序稳定、counter 与 comment、启用状态。
#
# FWCTL_TEST_REAL_NFT=1 时额外用真实 nft -c 复核每一份渲染产物的语法。

set -u

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TEST_PROJECT_DIR/core/common.sh"
source "$TEST_PROJECT_DIR/core/state.sh"
source "$TEST_PROJECT_DIR/core/model.sh"
source "$TEST_PROJECT_DIR/core/migration.sh"
source "$TEST_PROJECT_DIR/core/render.sh"

suite "t-render"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export FWCTL_NOW=2026-07-31T00:00:00Z

FACTS=$(render_facts 37091 "10.0.0.10" "198.51.100.10" "")
FACTS_LEGACY=$(render_facts 37091 "10.0.0.10" "198.51.100.10" "sb_filter sb_nat")
FACTS_ALL_LOCAL=$(render_facts 37091 "10.0.0.10 198.51.100.10" "198.51.100.10" "")

BASE="$WORK/base.json"
make_sample_state "$BASE"

render_to() {
    local state=$1 out=$2 facts=${3:-$FACTS}
    render_ruleset "$state" "$facts" > "$out"
}

# 用真实 nft 复核语法；未启用时跳过但不静默假装通过。
check_nft_syntax() {
    local message=$1 path=$2
    if [[ "${FWCTL_TEST_REAL_NFT:-0}" != 1 ]]; then
        return 0
    fi
    if output=$(nft -c -f "$path" 2>&1); then
        ok "$message"
    else
        not_ok "$message" "nft -c 失败" "${output:0:300}"
    fi
}

OUT="$WORK/base.nft"
render_to "$BASE" "$OUT"
RENDERED=$(cat "$OUT")

# ── 表所有权：绝不 flush ruleset ──────────────────────────────────────

assert_not_contains "渲染结果不含 flush ruleset" "$RENDERED" "flush ruleset"
assert_contains "预声明自己的表" "$RENDERED" "table ip fwctl { }"
assert_contains "删除自己的表以实现整表替换" "$RENDERED" "delete table ip fwctl"
assert_contains "随后重建自己的表" "$RENDERED" "table ip fwctl {"

# 预声明必须在 delete 之前，否则表不存在时 delete 会失败。
declare_line=$(grep -n 'table ip fwctl { }' "$OUT" | head -1 | cut -d: -f1)
delete_line=$(grep -n 'delete table ip fwctl' "$OUT" | head -1 | cut -d: -f1)
assert_eq "预声明位于 delete 之前" \
    "$([[ "$declare_line" -lt "$delete_line" ]] && echo yes)" "yes"

assert_not_contains "默认不触碰遗留表" "$RENDERED" "sb_filter"

# ── 旧表收编 ──────────────────────────────────────────────────────────

render_to "$BASE" "$WORK/legacy.nft" "$FACTS_LEGACY"
LEGACY=$(cat "$WORK/legacy.nft")
assert_contains "接管时预声明 sb_filter" "$LEGACY" "table ip sb_filter { }"
assert_contains "接管时删除 sb_filter" "$LEGACY" "delete table ip sb_filter"
assert_contains "接管时预声明 sb_nat" "$LEGACY" "table ip sb_nat { }"
assert_contains "接管时删除 sb_nat" "$LEGACY" "delete table ip sb_nat"
assert_not_contains "接管不重建遗留表内容" "$LEGACY" "sb_filter {
    set"
check_nft_syntax "收编遗留表的产物通过 nft -c" "$WORK/legacy.nft"

# ── chain 齐全 ────────────────────────────────────────────────────────

assert_contains "input chain 存在" "$RENDERED" \
    "chain input {"
assert_contains "input hook 与优先级正确" "$RENDERED" \
    "type filter hook input priority filter; policy drop;"
assert_contains "forward chain 存在" "$RENDERED" \
    "type filter hook forward priority filter; policy accept;"
assert_contains "prerouting 为 nat 类型" "$RENDERED" \
    "type nat hook prerouting priority dstnat; policy accept;"
assert_contains "postrouting 为 nat 类型" "$RENDERED" \
    "type nat hook postrouting priority srcnat; policy accept;"

# filter 与 nat chain 位于同一张表内，一次 delete 即可原子替换全部规则。
assert_eq "四条 chain 都在同一张表里" \
    "$(awk '/^table ip fwctl \{$/{t=1} t&&/chain /{c++} END{print c}' "$OUT")" "4"

# ── 规则顺序 ──────────────────────────────────────────────────────────
# SYN 限速必须在放行规则之后，否则已放行端口会被聚合限速提前丢弃。

ssh_line=$(grep -n 'tcp dport 37091' "$OUT" | cut -d: -f1)
allow_line=$(grep -n '@allowed_ports_tcp' "$OUT" | cut -d: -f1)
block_line=$(grep -n 'ip saddr @blacklist' "$OUT" | cut -d: -f1)
limit_line=$(grep -n 'tcp flags syn limit' "$OUT" | cut -d: -f1)
assert_eq "SSH 放行在 SYN 限速之前" \
    "$([[ "$ssh_line" -lt "$limit_line" ]] && echo yes)" "yes"
assert_eq "放行端口在 SYN 限速之前" \
    "$([[ "$allow_line" -lt "$limit_line" ]] && echo yes)" "yes"
assert_eq "block 规则在放行规则之前" \
    "$([[ "$block_line" -lt "$ssh_line" ]] && echo yes)" "yes"

# ── 空 set 不使用占位元素 ─────────────────────────────────────────────

empty="$WORK/empty.json"
state_default > "$empty"
render_to "$empty" "$WORK/empty.nft"
EMPTY=$(cat "$WORK/empty.nft")
assert_contains "空状态仍声明放行端口 set" "$EMPTY" "set allowed_ports_tcp {"
assert_not_contains "空 set 不写 elements 行" "$EMPTY" "elements"
assert_not_contains "不再使用 127.0.0.2 占位" "$EMPTY" "127.0.0.2"
assert_not_contains "不再使用 65535 占位" "$EMPTY" "65535"
check_nft_syntax "空状态的产物通过 nft -c" "$WORK/empty.nft"

# ── 对象展开 ──────────────────────────────────────────────────────────

# protocol=both 在存储中是一个对象，渲染成 tcp 与 udp 两条规则。
assert_eq "both 服务展开为两条 DNAT" \
    "$(grep -c 'dnat to' "$OUT")" "2"
assert_contains "both 展开出 tcp 分支" "$RENDERED" "tcp dport 443 counter dnat to 192.0.2.20"
assert_contains "both 展开出 udp 分支" "$RENDERED" "udp dport 443 counter dnat to 192.0.2.20"

# translate.port 为 null 时保持原目的端口。
assert_contains "translate 为 null 时不写端口" "$RENDERED" "dnat to 192.0.2.20 comment"

translated="$WORK/translated.json"
jq '.rules |= map(if .type == "forward" then .translate.port = "8443" else . end)' \
    "$BASE" > "$translated"
render_to "$translated" "$WORK/translated.nft"
assert_contains "translate 有值时写入目的端口" \
    "$(cat "$WORK/translated.nft")" "dnat to 192.0.2.20:8443"
assert_contains "SNAT 匹配转换后的端口" \
    "$(cat "$WORK/translated.nft")" "ip daddr 192.0.2.20 tcp dport 8443"

# 端口区间渲染为 interval，不展开成单端口。
ranged="$WORK/ranged.json"
jq '.services |= map(.ports = ["40000-40010"])' "$BASE" > "$ranged"
render_to "$ranged" "$WORK/ranged.nft"
assert_contains "端口区间保持为区间" \
    "$(cat "$WORK/ranged.nft")" "dport 40000-40010"

# 多端口服务渲染为匿名 set。
multi="$WORK/multi.json"
jq '.services |= map(.ports = ["80","443"])' "$BASE" > "$multi"
render_to "$multi" "$WORK/multi.nft"
assert_contains "多端口服务渲染为匿名 set" \
    "$(cat "$WORK/multi.nft")" "dport { 80, 443 }"
check_nft_syntax "多端口产物通过 nft -c" "$WORK/multi.nft"

# block 的来源始终是具名 set；转发目的地始终是字面量地址。
assert_contains "block 来源引用具名 set" "$RENDERED" "ip saddr @blacklist"
assert_contains "具名 set 以 Target 名字命名" "$RENDERED" "set blacklist {"
assert_contains "转发目的地是字面量地址" "$RENDERED" "dnat to 192.0.2.20"

# ── 启用状态 ──────────────────────────────────────────────────────────

disabled="$WORK/disabled.json"
jq '.rules |= map(if .type == "forward" then .enabled = false else . end)' \
    "$BASE" > "$disabled"
render_to "$disabled" "$WORK/disabled.nft"
DISABLED=$(cat "$WORK/disabled.nft")
assert_not_contains "禁用的规则不渲染" "$DISABLED" "dnat to"
assert_not_contains "禁用的规则不留占位" "$DISABLED" "192.0.2.20"
assert_contains "禁用一条规则不影响其他规则" "$DISABLED" "ip saddr @blacklist"

disabled_target="$WORK/disabled-target.json"
jq '.targets |= map(if .name == "edge" then .enabled = false else . end)' \
    "$BASE" > "$disabled_target"
render_to "$disabled_target" "$WORK/disabled-target.nft"
assert_not_contains "禁用 Target 后引用它的规则不渲染" \
    "$(cat "$WORK/disabled-target.nft")" "dnat to"

# ── counter 与 comment ────────────────────────────────────────────────

assert_contains "规则默认带 counter" "$RENDERED" "counter accept"
assert_contains "规则默认带对象 id 注释" "$RENDERED" 'comment "fwctl:rule-'
assert_contains "内建规则也带注释便于统计" "$RENDERED" 'comment "fwctl:ssh"'

no_counter="$WORK/no-counter.json"
jq '.settings.render.counters = false' "$BASE" > "$no_counter"
render_to "$no_counter" "$WORK/no-counter.nft"
assert_not_contains "关闭后不再输出 counter" \
    "$(cat "$WORK/no-counter.nft")" "counter"
assert_contains "关闭 counter 不影响 comment" \
    "$(cat "$WORK/no-counter.nft")" 'comment "fwctl:'
check_nft_syntax "关闭 counter 的产物通过 nft -c" "$WORK/no-counter.nft"

no_comment="$WORK/no-comment.json"
jq '.settings.render.comments = false' "$BASE" > "$no_comment"
render_to "$no_comment" "$WORK/no-comment.nft"
assert_not_contains "关闭后不再输出 comment" \
    "$(cat "$WORK/no-comment.nft")" "comment"
assert_contains "关闭 comment 不影响 counter" \
    "$(cat "$WORK/no-comment.nft")" "counter"

commented="$WORK/commented.json"
jq '.comments = {"rule-7a0e4b19cc85": "对外入口"}' "$BASE" > "$commented"
render_to "$commented" "$WORK/commented.nft"
assert_contains "用户注释渲染进 nft" \
    "$(cat "$WORK/commented.nft")" 'comment "fwctl:rule-7a0e4b19cc85 对外入口"'

# ── 渲染确定性 ────────────────────────────────────────────────────────

render_to "$BASE" "$WORK/det1.nft"
render_to "$BASE" "$WORK/det2.nft"
assert_files_eq "重复渲染逐字节一致" "$WORK/det1.nft" "$WORK/det2.nft"

# 打乱数组顺序后渲染结果必须不变——输出与插入历史无关。
shuffled="$WORK/shuffled.json"
jq '.targets = (.targets | reverse)
    | .services = (.services | reverse)
    | .rules = (.rules | reverse)
    | .ports.tcp = (.ports.tcp | reverse)' "$BASE" > "$shuffled"
render_to "$shuffled" "$WORK/shuffled.nft"
assert_files_eq "渲染结果与对象插入顺序无关" "$WORK/det1.nft" "$WORK/shuffled.nft"

# priority 在同类型规则之间排序。
multi_block="$WORK/multi-block.json"
jq '.targets += [{id:"tgt-111111111111", name:"second", description:"", kind:"ipv4",
                  addresses:["203.0.113.9"], enabled:true,
                  created_at:"2026-07-31T00:00:00Z", updated_at:"2026-07-31T00:00:00Z"}]
    | .rules += [{id:"rule-222222222222", name:"second-block", description:"",
                  type:"block", enabled:true, priority:5, service:null, target:null,
                  source:"tgt-111111111111", translate:{port:null},
                  created_at:"2026-07-31T00:00:00Z", updated_at:"2026-07-31T00:00:00Z"}]' \
    "$BASE" > "$multi_block"
render_to "$multi_block" "$WORK/multi-block.nft"
first_block=$(grep -n 'ip saddr @second' "$WORK/multi-block.nft" | cut -d: -f1)
later_block=$(grep -n 'ip saddr @blacklist' "$WORK/multi-block.nft" | cut -d: -f1)
assert_eq "同类型规则按 priority 升序排列" \
    "$([[ "$first_block" -lt "$later_block" ]] && echo yes)" "yes"

# block 永远排在 accept 之前，与 priority 无关——先拒绝后放行是安全默认，
# 不应因为某条规则的排序数字被绕过。
ordered="$WORK/ordered.json"
jq '.rules |= map(if .type == "block" then .priority = 65535 else . end)' \
    "$BASE" > "$ordered"
render_to "$ordered" "$WORK/ordered.nft"
new_block=$(grep -n 'ip saddr @blacklist' "$WORK/ordered.nft" | cut -d: -f1)
new_ssh=$(grep -n 'tcp dport 37091' "$WORK/ordered.nft" | cut -d: -f1)
assert_eq "即使 priority 最大，block 仍排在放行之前" \
    "$([[ "$new_block" -lt "$new_ssh" ]] && echo yes)" "yes"

# ── 策略开关 ──────────────────────────────────────────────────────────

assert_not_contains "ct_invalid 默认不产生规则" "$RENDERED" "ct state invalid"
ct_drop="$WORK/ct-drop.json"
jq '.settings.policy.ct_invalid = "drop"' "$BASE" > "$ct_drop"
render_to "$ct_drop" "$WORK/ct-drop.nft"
assert_contains "开启后产生 ct invalid 规则" \
    "$(cat "$WORK/ct-drop.nft")" "ct state invalid"

assert_not_contains "icmp_echo 默认不产生规则" "$RENDERED" "icmp type echo-request"
icmp="$WORK/icmp.json"
jq '.settings.policy.icmp_echo = "limit"' "$BASE" > "$icmp"
render_to "$icmp" "$WORK/icmp.nft"
assert_contains "limit 模式产生限速的 echo 规则" \
    "$(cat "$WORK/icmp.nft")" "icmp type echo-request limit rate"
check_nft_syntax "开启 icmp 与 ct 的产物通过 nft -c" "$WORK/icmp.nft"

no_syn="$WORK/no-syn.json"
jq '.settings.policy.syn_limit.enabled = false' "$BASE" > "$no_syn"
render_to "$no_syn" "$WORK/no-syn.nft"
assert_not_contains "关闭后不产生 SYN 限速" \
    "$(cat "$WORK/no-syn.nft")" "tcp flags syn limit"

# ── NAT 动作选择 ──────────────────────────────────────────────────────
# 语义与旧实现一致：候选地址必须真实存在于本机接口才生成显式 SNAT。

assert_eq "auto 且公网地址不在本机时用 masquerade" \
    "$(render_nat_action "$BASE" "$(render_facts 22 "10.0.0.10" "198.51.100.10" "")")" \
    "masquerade"
assert_eq "auto 且公网地址在本机时用显式 SNAT" \
    "$(render_nat_action "$BASE" "$(render_facts 22 "198.51.100.10" "198.51.100.10" "")")" \
    "snat to 198.51.100.10"
assert_eq "auto 且无法获取公网地址时回退 masquerade" \
    "$(render_nat_action "$BASE" "$(render_facts 22 "10.0.0.10" "" "")")" \
    "masquerade"

masq="$WORK/masq.json"
jq '.settings.nat.mode = "masquerade"' "$BASE" > "$masq"
assert_eq "masquerade 模式始终 masquerade" \
    "$(render_nat_action "$masq" "$(render_facts 22 "198.51.100.10" "198.51.100.10" "")")" \
    "masquerade"

snat="$WORK/snat.json"
jq '.settings.nat.mode = "snat" | .settings.nat.snat_address = "198.51.100.10"' \
    "$BASE" > "$snat"
assert_eq "snat 模式且地址在本机时生成显式 SNAT" \
    "$(render_nat_action "$snat" "$(render_facts 22 "198.51.100.10" "" "")")" \
    "snat to 198.51.100.10"
assert_fails "snat 模式且地址不在本机时拒绝渲染" 0 \
    render_nat_action "$snat" "$(render_facts 22 "10.0.0.10" "" "")"

# ── SSH 端口 ──────────────────────────────────────────────────────────

assert_fails "非法 SSH 端口拒绝渲染" 0 \
    render_ruleset "$BASE" "$(render_facts 0 "10.0.0.10" "" "")"
assert_fails "越界 SSH 端口拒绝渲染" 0 \
    render_ruleset "$BASE" "$(render_facts 70000 "10.0.0.10" "" "")"

# ── 渲染是纯函数 ──────────────────────────────────────────────────────
# 不写任何文件、不修改输入。

before=$(sha256sum "$BASE")
render_ruleset "$BASE" "$FACTS" >/dev/null
after=$(sha256sum "$BASE")
assert_eq "渲染不修改输入状态" "$before" "$after"

# ── 真实 nft 语法复核 ─────────────────────────────────────────────────

check_nft_syntax "样例状态的产物通过 nft -c" "$OUT"
check_nft_syntax "translate 产物通过 nft -c" "$WORK/translated.nft"
check_nft_syntax "区间产物通过 nft -c" "$WORK/ranged.nft"

for fixture in "$TEST_PROJECT_DIR"/tests/fixtures/state-v1-*.json; do
    name=$(basename "$fixture" .json)
    name=${name#state-v1-}
    migrated="$WORK/mig-$name.json"
    if ! migration_v1_to_current "$fixture" > "$migrated" 2>/dev/null; then
        not_ok "固件 $name 可迁移并渲染" "迁移失败"
        continue
    fi
    # 本机地址列表包含 nat-snat 固件所需的地址，否则 snat 模式会被正确拒绝。
    if ! render_ruleset "$migrated" "$FACTS_ALL_LOCAL" > "$WORK/mig-$name.nft" 2>/dev/null; then
        not_ok "固件 $name 可迁移并渲染" "渲染失败"
        continue
    fi
    ok "固件 $name 可迁移并渲染"
    check_nft_syntax "固件 $name 的产物通过 nft -c" "$WORK/mig-$name.nft"
done

if [[ "${FWCTL_TEST_REAL_NFT:-0}" != 1 ]]; then
    printf '# 提示：设置 FWCTL_TEST_REAL_NFT=1 可用真实 nft -c 复核全部渲染产物\n'
fi

finish
