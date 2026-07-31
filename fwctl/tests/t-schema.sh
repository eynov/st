#!/bin/bash
# tests/t-schema.sh —— 结构与语义校验、对象模型
#
# 覆盖 docs/STATE_SCHEMA.md 的两级校验清单，以及 ADR 0001 冻结的对象生命周期
# 语义（Service 不可变且无 enabled、Target 地址可重复、对象图单向、ID 规则）。

set -u

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TEST_PROJECT_DIR/core/common.sh"
source "$TEST_PROJECT_DIR/core/state.sh"
source "$TEST_PROJECT_DIR/core/model.sh"

suite "t-schema"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export FWCTL_NOW=2026-07-31T00:00:00Z

BASE="$WORK/base.json"
make_sample_state "$BASE"

# 把一个 jq 变换应用到样例状态上，输出到临时文件并返回路径。
mutate() {
    local filter=$1 out="$WORK/mutated.$RANDOM.json"
    jq "$filter" "$BASE" > "$out"
    printf '%s\n' "$out"
}

# 断言变换后的状态被校验拒绝，且错误信息包含指定关键词。
reject() {
    local message=$1 filter=$2 needle=${3:-}
    local path output
    path=$(mutate "$filter")
    if output=$(state_validate "$path" 2>&1); then
        not_ok "$message" "本应被拒绝但通过了校验"
        return
    fi
    if [[ -n "$needle" && "$output" != *"$needle"* ]]; then
        not_ok "$message" "错误信息未包含: $needle" "actual: ${output:0:300}"
        return
    fi
    ok "$message"
}

# 断言变换后的状态仍然合法。
accept() {
    local message=$1 filter=$2
    local path output
    path=$(mutate "$filter")
    if output=$(state_validate "$path" 2>&1); then
        ok "$message"
    else
        not_ok "$message" "本应通过但被拒绝" "output: ${output:0:300}"
    fi
}

# ── 基线 ──────────────────────────────────────────────────────────────

state_default > "$WORK/default.json"
assert_ok "默认状态通过完整校验" state_validate "$WORK/default.json"
assert_ok "样例状态通过完整校验" state_validate "$BASE"

# ── 顶层结构 ──────────────────────────────────────────────────────────

reject "多余顶层字段被拒绝" '.extra = 1' '顶层字段'
reject "缺少顶层字段被拒绝" 'del(.comments)' '顶层字段'
reject "schema_version 为 3 被拒绝" '.schema_version = 3' 'schema_version'
reject "schema_version 为字符串被拒绝" '.schema_version = "4"' 'schema_version'

# ── 版本探测 ──────────────────────────────────────────────────────────

echo '{"nat_mode":"auto","forwards":[]}' > "$WORK/v1.json"
assert_eq "无 schema_version 识别为旧格式(0)" \
    "$(state_detect_version "$WORK/v1.json")" "0"
assert_eq "当前 schema 识别为 4" \
    "$(state_detect_version "$BASE")" "4"

echo '{"schema_version":99}' > "$WORK/future.json"
assert_eq "更高版本被正确读出" \
    "$(state_detect_version "$WORK/future.json")" "99"
assert_fails "更高 schema 版本被拒绝" 0 state_version_supported 99
assert_ok "旧格式版本可处理" state_version_supported 0
assert_ok "当前版本可处理" state_version_supported 4

printf 'not json at all' > "$WORK/broken.json"
assert_fails "非法 JSON 被拒绝" 0 state_detect_version "$WORK/broken.json"

# ── ID 规则 ───────────────────────────────────────────────────────────

reject "6 位 id 被拒绝" \
    '.targets[0].id = "tgt-abc123" | .rules[0].target = "tgt-abc123"' '12 位'
reject "大写十六进制 id 被拒绝" \
    '.targets[0].id = "tgt-9F2C41A7BE03" | .rules[0].target = "tgt-9F2C41A7BE03"' '12 位'
reject "错误前缀被拒绝" \
    '.services[0].id = "tgt-3d81c0be5f24" | .rules[0].service = "tgt-3d81c0be5f24"' 'svc-'
reject "重复 id 被拒绝" '.services[1] = .services[0]' '重复'
reject "重复 name 被拒绝" \
    '.targets[1].name = "edge"' '重复'

assert_eq "ID 生成确定" \
    "$(fwctl_object_id target 192.0.2.20)" "$(fwctl_object_id target 192.0.2.20)"
assert_eq "ID 前缀正确" \
    "$(fwctl_object_id rule x | cut -d- -f1)" "rule"
assert_eq "ID 为 12 位十六进制" \
    "$(fwctl_object_id service x | sed 's/^svc-//' | grep -cE '^[0-9a-f]{12}$')" "1"

# 盐使碰撞可解：相同内容加不同盐产出不同 ID，且各自确定。
assert_eq "加盐后 ID 变化" \
    "$([[ "$(fwctl_object_id rule a)" != "$(fwctl_object_id rule a '#2')" ]] && echo differ)" \
    "differ"
assert_eq "加盐后仍然确定" \
    "$(fwctl_object_id rule a '#2')" "$(fwctl_object_id rule a '#2')"

# NUL 分隔避免字段拼接歧义："ab"+"" 与 "a"+"b" 必须不同。
assert_eq "字段边界不产生哈希歧义" \
    "$([[ "$(fwctl_object_id target ab)" != "$(fwctl_object_id target a b)" ]] && echo differ)" \
    "differ"

# ── 命名 ──────────────────────────────────────────────────────────────

reject "含空格的 name 被拒绝" '.targets[0].name = "edge node"' '命名规则'
reject "大写 name 被拒绝" '.targets[0].name = "Edge"' '命名规则'
reject "以连字符开头的 name 被拒绝" '.targets[0].name = "-edge"' '命名规则'
accept "含下划线与数字的 name 合法" '.targets[0].name = "edge_2"'
accept "32 字符 name 合法" '.targets[0].name = "a234567890123456789012345678901c"'
reject "33 字符 name 被拒绝" '.targets[0].name = "a2345678901234567890123456789012c"' '命名规则'

# ── 端口规范 ──────────────────────────────────────────────────────────

reject "端口 0 被拒绝" '.ports.tcp = ["0"]' '非法端口'
reject "端口 65536 被拒绝" '.ports.tcp = ["65536"]' '非法端口'
reject "反向区间被拒绝" '.ports.tcp = ["600-500"]' '非法端口'
reject "前导零端口被拒绝" '.ports.tcp = ["0443"]' '非法端口'
reject "非数字端口被拒绝" '.ports.tcp = ["abc"]' '非法端口'
reject "数字类型端口被拒绝" '.ports.tcp = [443]' '非法端口'
accept "边界端口 1 合法" '.ports.tcp = ["1"]'
accept "边界端口 65535 合法" '.ports.tcp = ["65535"]'
accept "端口区间合法" '.ports.tcp = ["60000-61000"]'

# ── 地址 ──────────────────────────────────────────────────────────────

reject "八位组超过 255 被拒绝" '.targets[0].addresses = ["192.0.2.999"]' '非法地址'
reject "前导零八位组被拒绝" '.targets[0].addresses = ["192.000.2.20"]' '非法地址'
reject "三段地址被拒绝" '.targets[0].addresses = ["1.2.3"]' '非法地址'
reject "五段地址被拒绝" '.targets[0].addresses = ["1.2.3.4.5"]' '非法地址'
reject "前缀长度 33 被拒绝" '.targets[0].addresses = ["203.0.113.0/33"]' '非法地址'
reject "空地址数组被拒绝" '.targets[0].addresses = []' '非空数组'
accept "单地址合法" '.targets[0].addresses = ["192.0.2.20"]'
accept "CIDR 合法" '.targets[0].addresses = ["203.0.113.0/24"]'
accept "0.0.0.0/0 合法" '.targets[0].addresses = ["0.0.0.0/0"]'
accept "255.255.255.255 合法" '.targets[0].addresses = ["255.255.255.255"]'

# ── Service 是不可变值对象（ADR 0001）────────────────────────────────

reject "Service 含 enabled 被拒绝" '.services[0].enabled = true' 'enabled'
reject "Service 含 enabled 时错误信息说明原因" \
    '.services[0].enabled = false' 'Service'

assert_fails "model 层拒绝原地修改 ports" 0 \
    model_service_edit_metadata "$BASE" svc-3d81c0be5f24 ports=8443

output=$(model_service_edit_metadata "$BASE" svc-3d81c0be5f24 ports=8443 2>&1 || true)
assert_contains "原地改 ports 的错误信息指向 --refs" "$output" '--refs'
assert_contains "原地改 ports 的错误信息说明值不可变" "$output" '不可变'

output=$(model_service_edit_metadata "$BASE" svc-3d81c0be5f24 protocol=tcp 2>&1 || true)
assert_contains "原地改 protocol 同样被拒绝" "$output" '不可变'

assert_ok "改 Service 的 name 允许" \
    model_service_edit_metadata "$BASE" svc-3d81c0be5f24 name=web

# 替换语义：新建对象 + 只重写显式指定的引用
replaced="$WORK/replaced.json"
model_service_replace "$BASE" svc-3d81c0be5f24 web both 8443 rule-7a0e4b19cc85 > "$replaced"
assert_eq "替换后 Service 数量加一" \
    "$(jq '.services | length' "$replaced")" "2"
assert_eq "旧 Service 仍然保留" \
    "$(jq -r '.services[] | select(.name == "https") | .name' "$replaced")" "https"
assert_eq "指定的规则改指向新 Service" \
    "$(jq -r '(.rules[] | select(.name == "edge-https") | .service) as $ref
              | .services[] | select(.id == $ref) | .name' "$replaced")" \
    "web"
assert_ok "替换后状态仍然合法" state_validate "$replaced"

# 不指定引用时，旧 Service 的引用保持不变
untouched="$WORK/untouched.json"
model_service_replace "$BASE" svc-3d81c0be5f24 web both 8443 "" > "$untouched"
assert_eq "未指定引用时原规则不被改动" \
    "$(jq -r '.rules[] | select(.name == "edge-https") | .service' "$untouched")" \
    "svc-3d81c0be5f24"

# ── Target 是可变实体：地址允许跨对象重复 ────────────────────────────

accept "两个 Target 可以拥有相同地址" \
    '.targets[1].addresses = ["192.0.2.20"] | .targets[1].kind = "ipv4"'

dup_state=$(mutate '.targets[1].addresses = ["192.0.2.20"]')
warnings=$(state_warnings "$dup_state")
assert_contains "地址完全重复的 Target 产生 WARN" "$warnings" "地址集合完全相同"
assert_ok "地址重复只是警告，不影响校验通过" state_validate "$dup_state"

# 改地址会传播到引用它的规则——这是 Target 作为实体的预期行为
edited="$WORK/edited.json"
model_target_edit "$BASE" tgt-9f2c41a7be03 addresses=198.51.100.5 > "$edited"
assert_eq "改地址后 id 不变" \
    "$(jq -r '.targets[] | select(.name == "edge") | .id' "$edited")" \
    "tgt-9f2c41a7be03"
assert_eq "改地址后规则引用不受影响" \
    "$(jq -r '.rules[] | select(.name == "edge-https") | .target' "$edited")" \
    "tgt-9f2c41a7be03"
assert_eq "地址确实被改写" \
    "$(jq -r '.targets[] | select(.name == "edge") | .addresses[0]' "$edited")" \
    "198.51.100.5"

renamed="$WORK/renamed.json"
model_target_edit "$BASE" tgt-9f2c41a7be03 name=relay > "$renamed"
assert_eq "重命名后 id 不变" \
    "$(jq -r '.targets[] | select(.name == "relay") | .id' "$renamed")" \
    "tgt-9f2c41a7be03"
assert_ok "重命名后引用完整性仍然成立" state_validate "$renamed"

# ── 对象图严格单向 ────────────────────────────────────────────────────

reject "Target 含 service 字段被拒绝" \
    '.targets[0].service = "svc-3d81c0be5f24"' 'service'
reject "Target 含 rules 字段被拒绝" \
    '.targets[0].rules = []' 'rules'
reject "Service 含 target 字段被拒绝" \
    '.services[0].target = "tgt-9f2c41a7be03"' 'target'
reject "Service 含 source 字段被拒绝" \
    '.services[0].source = "tgt-9f2c41a7be03"' 'source'

# ── 引用完整性 ────────────────────────────────────────────────────────

reject "悬空 Service 引用被拒绝" \
    '.rules[0].service = "svc-000000000000"' '不存在的 Service'
reject "悬空 Target 引用被拒绝" \
    '.rules[0].target = "tgt-000000000000"' '不存在的 Target'
reject "悬空 source 引用被拒绝" \
    '.rules[1].source = "tgt-000000000000"' '不存在的 Target'

# ── 规则类型与字段组合 ────────────────────────────────────────────────

reject "block 携带 service 被拒绝" \
    '.rules[1].service = "svc-3d81c0be5f24"' 'service 必须为 null'
reject "block 携带 target 被拒绝" \
    '.rules[1].target = "tgt-9f2c41a7be03"' 'target 必须为 null'
reject "block 缺少 source 被拒绝" \
    '.rules[1].source = null' '必须引用 Target'
reject "forward 缺少 target 被拒绝" \
    '.rules[0].target = null' '必须引用 Target'
reject "forward 缺少 service 被拒绝" \
    '.rules[0].service = null' '必须引用 Service'
reject "accept 携带 target 被拒绝" \
    '.rules[0].type = "accept" | .rules[0].translate.port = null' 'target 必须为 null'
reject "translate 为范围被拒绝" \
    '.rules[0].translate.port = "100-200"' '单端口'
accept "translate 为单端口合法" '.rules[0].translate.port = "8443"'
reject "priority 超出上限被拒绝" '.rules[0].priority = 65536' 'priority'
reject "priority 为负被拒绝" '.rules[0].priority = -1' 'priority'
reject "priority 为小数被拒绝" '.rules[0].priority = 1.5' 'priority'
accept "priority 边界 0 合法" '.rules[0].priority = 0'
accept "priority 边界 65535 合法" '.rules[0].priority = 65535'
# 上限放宽到 65535 是为了让迁移能保留任意规模 v1 状态的原始顺序，
# 而不必截断——截断会让重叠规则的 DNAT 优先级在升级时静默改变。
accept "priority 2000 合法（迁移大状态所需）" '.rules[0].priority = 2000'

# ── 注释 ──────────────────────────────────────────────────────────────

reject "含双引号的注释被拒绝" \
    '.comments = {"rule-7a0e4b19cc85": "say \"hi\""}' '双引号'
reject "孤儿注释键被拒绝" '.comments = {"nope": "x"}' '注释键'
accept "对象 id 作为注释键合法" '.comments = {"rule-7a0e4b19cc85": "note"}'
accept "tcp 合成键合法" '.comments = {"tcp:443": "note"}'
accept "udp 区间合成键合法" '.comments = {"udp:60000-61000": "note"}'

pruned="$WORK/pruned.json"
jq '.comments = {"rule-7a0e4b19cc85": "keep", "tcp:443": "keep", "gone": "drop"}' \
    "$BASE" > "$WORK/withorphan.json"
model_comment_prune "$WORK/withorphan.json" > "$pruned"
assert_eq "孤儿注释被清理" "$(jq -r '.comments | has("gone")' "$pruned")" "false"
assert_eq "有效注释被保留" "$(jq -r '.comments | has("rule-7a0e4b19cc85")' "$pruned")" "true"
assert_eq "合成键注释被保留" "$(jq -r '.comments | has("tcp:443")' "$pruned")" "true"

# nftables 的 comment 上限是 128 **字节**，而渲染时还要加上 "fwctl:<id> "
# 前缀（24 字节），因此写入时按剩余预算截断，保证渲染结果一定能被内核接受。
truncated="$WORK/truncated.json"
long=$(printf 'x%.0s' {1..200})
model_comment_set "$BASE" rule-7a0e4b19cc85 "$long" 2>/dev/null > "$truncated"
assert_eq "超长注释按可用字节预算截断" \
    "$(jq -r '.comments["rule-7a0e4b19cc85"] | utf8bytelength' "$truncated")" "104"

# 中文注释必须按字节而不是字符截断：43 个中文字就超过 128 字节。
cjk_truncated="$WORK/cjk-truncated.json"
cjk=$(printf '中%.0s' {1..200})
model_comment_set "$BASE" rule-7a0e4b19cc85 "$cjk" 2>/dev/null > "$cjk_truncated"
cjk_bytes=$(jq -r '.comments["rule-7a0e4b19cc85"] | utf8bytelength' "$cjk_truncated")
assert_eq "中文注释按字节截断" "$([[ "$cjk_bytes" -le 104 ]] && echo yes)" "yes"
assert_eq "截断不切断多字节字符" \
    "$(jq -r '.comments["rule-7a0e4b19cc85"]' "$cjk_truncated" |
       iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && echo valid)" "valid"

assert_fails "含引号的注释被 model 层拒绝" 0 \
    model_comment_set "$BASE" rule-7a0e4b19cc85 'say "hi"'

# ── settings ──────────────────────────────────────────────────────────

reject "非法 nat.mode 被拒绝" '.settings.nat.mode = "bridge"' 'nat.mode'
reject "非法 icmp_echo 被拒绝" '.settings.policy.icmp_echo = "maybe"' 'icmp_echo'
reject "非法 ct_invalid 被拒绝" '.settings.policy.ct_invalid = "maybe"' 'ct_invalid'
reject "snat 模式缺少地址被拒绝" '.settings.nat.mode = "snat"' 'snat_address'
reject "snat 地址非法被拒绝" \
    '.settings.nat.mode = "snat" | .settings.nat.snat_address = "not-an-ip"' '合法 IPv4'
reject "fixed ssh 模式缺少端口被拒绝" '.settings.ssh.mode = "fixed"' 'ssh.port'
accept "fixed ssh 模式带端口合法" \
    '.settings.ssh.mode = "fixed" | .settings.ssh.port = 22'

# snat 地址是否在本机由外部事实决定
snat=$(mutate '.settings.nat.mode = "snat" | .settings.nat.snat_address = "198.51.100.10"')
assert_ok "离线模式跳过本机地址检查" \
    state_validate_semantic "$snat" '{"offline":true}'
assert_ok "地址存在于本机时通过" \
    state_validate_semantic "$snat" '{"local_ipv4s":["198.51.100.10"]}'
assert_fails "地址不在本机时拒绝" 0 \
    state_validate_semantic "$snat" '{"local_ipv4s":["10.0.0.1"]}'

# ── 默认值与旧版本行为一致 ────────────────────────────────────────────

defaults="$WORK/defaults.json"
state_default > "$defaults"
assert_eq "ct_invalid 默认沿用旧行为" \
    "$(jq -r '.settings.policy.ct_invalid' "$defaults")" "ignore"
assert_eq "icmp_echo 默认沿用旧行为" \
    "$(jq -r '.settings.policy.icmp_echo' "$defaults")" "drop"
assert_eq "input 策略默认 drop" \
    "$(jq -r '.settings.policy.input' "$defaults")" "drop"
assert_eq "SYN 限速默认开启" \
    "$(jq -r '.settings.policy.syn_limit.enabled' "$defaults")" "true"
assert_eq "counter 默认开启" \
    "$(jq -r '.settings.render.counters' "$defaults")" "true"
assert_eq "新装状态没有迁移来源" \
    "$(jq -r '.metadata.migrated_from' "$defaults")" "null"
assert_eq "新装状态未接管旧表" \
    "$(jq -r '.metadata.legacy_adopted_at' "$defaults")" "null"

# ── 规范化与确定性 ────────────────────────────────────────────────────

state_normalize "$BASE" > "$WORK/n1.json"
state_normalize "$WORK/n1.json" > "$WORK/n2.json"
assert_files_eq "规范化是幂等的" "$WORK/n1.json" "$WORK/n2.json"

shuffled=$(mutate '.targets = (.targets | reverse)
                   | .services = (.services | reverse)
                   | .rules = (.rules | reverse)
                   | .ports.tcp = (.ports.tcp | reverse)')
state_normalize "$shuffled" > "$WORK/n3.json"
assert_files_eq "规范化结果与插入顺序无关" "$WORK/n1.json" "$WORK/n3.json"

assert_eq "规范化后顶层字段顺序固定" \
    "$(jq -r 'keys_unsorted | join(",")' "$WORK/n1.json")" \
    "comments,metadata,ports,rules,schema_version,services,settings,targets"

# 数值排序而非字典序：字典序会把 "1000" 排在 "22" 之前。
normalized_ports=$(state_normalize "$(mutate '.ports.tcp = ["443","22","1000"]')" |
    jq -rc '.ports.tcp')
assert_eq "规范化后端口按数值升序" "$normalized_ports" '["22","443","1000"]'

normalized_addrs=$(state_normalize \
    "$(mutate '.targets[0].addresses = ["192.0.2.100","192.0.2.20","10.0.0.1"]')" |
    jq -rc '.targets[] | select(.name == "edge") | .addresses')
assert_eq "规范化后地址按数值升序" "$normalized_addrs" \
    '["10.0.0.1","192.0.2.20","192.0.2.100"]'

# ── 截断与损坏的状态文件 ──────────────────────────────────────────────
# jq empty 对空输入返回 0，因此空文件必须被单独拦截，否则会被当成合法状态。

: > "$WORK/empty.json"
assert_fails "空状态文件被拒绝" 0 state_validate "$WORK/empty.json"
assert_fails "空状态文件的结构校验也拒绝" 0 state_validate_schema "$WORK/empty.json"

printf '[]' > "$WORK/array.json"
assert_fails "顶层为数组的状态被拒绝" 0 state_validate "$WORK/array.json"

printf '"just a string"' > "$WORK/string.json"
assert_fails "顶层为字符串的状态被拒绝" 0 state_validate "$WORK/string.json"

printf '{"schema_version": 4, "settings":' > "$WORK/truncated.json"
assert_fails "被截断的 JSON 被拒绝" 0 state_validate "$WORK/truncated.json"

assert_fails "不存在的状态文件被拒绝" 0 state_validate "$WORK/nonexistent.json"

# ── 引用解析 ──────────────────────────────────────────────────────────

assert_eq "按 name 解析 Target" \
    "$(model_resolve "$BASE" target edge)" "tgt-9f2c41a7be03"
assert_eq "按 id 解析 Target" \
    "$(model_resolve "$BASE" target tgt-9f2c41a7be03)" "tgt-9f2c41a7be03"
assert_eq "按 name 解析 Rule" \
    "$(model_resolve "$BASE" rule edge-https)" "rule-7a0e4b19cc85"
assert_fails "解析不存在的对象失败" 0 model_resolve "$BASE" target nope

# ── 删除与引用保护 ────────────────────────────────────────────────────

assert_fails "删除被引用的 Target 被拒绝" 0 \
    model_target_delete "$BASE" tgt-9f2c41a7be03 0
output=$(model_target_delete "$BASE" tgt-9f2c41a7be03 0 2>&1 || true)
assert_contains "拒绝信息列出引用方" "$output" "edge-https"
assert_contains "拒绝信息提示 cascade" "$output" "--cascade"

cascaded="$WORK/cascaded.json"
model_target_delete "$BASE" tgt-9f2c41a7be03 1 > "$cascaded"
assert_eq "cascade 删除同时移除引用规则" \
    "$(jq '[.rules[] | select(.name == "edge-https")] | length' "$cascaded")" "0"
assert_eq "cascade 保留无关规则" \
    "$(jq '[.rules[] | select(.name == "blacklist-drop")] | length' "$cascaded")" "1"
assert_ok "cascade 后状态仍然合法" state_validate "$cascaded"

assert_fails "删除被引用的 Service 被拒绝" 0 \
    model_service_delete "$BASE" svc-3d81c0be5f24 0

# ── 端口清单 ──────────────────────────────────────────────────────────

added="$WORK/added.json"
model_port_update "$BASE" add both 8443 > "$added"
assert_eq "both 在 tcp 写入一份" \
    "$(jq -r '.ports.tcp | index("8443") != null' "$added")" "true"
assert_eq "both 在 udp 写入一份" \
    "$(jq -r '.ports.udp | index("8443") != null' "$added")" "true"
assert_ok "端口变更后状态仍然合法" state_validate "$added"

assert_fails "重复添加是空操作" 0 model_port_would_change "$BASE" add tcp 443
assert_ok "添加新端口会产生变更" model_port_would_change "$BASE" add tcp 8443
assert_fails "删除不存在的端口是空操作" 0 model_port_would_change "$BASE" remove tcp 9999
assert_ok "删除已存在的端口会产生变更" model_port_would_change "$BASE" remove tcp 443

removed="$WORK/removed.json"
model_port_update "$BASE" remove tcp 443 > "$removed"
assert_eq "删除后 tcp 不含该端口" \
    "$(jq -r '.ports.tcp | index("443") == null' "$removed")" "true"

range="$WORK/range.json"
model_port_update "$BASE" add udp 30000-30010 > "$range"
assert_eq "端口区间不被展开" \
    "$(jq -r '.ports.udp | index("30000-30010") != null' "$range")" "true"

finish
