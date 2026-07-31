#!/bin/bash
# tests/t-cli.sh —— 新增名词与动词
#
# 覆盖 docs/CLI.md 的名词 + 动词结构、退出码 ABI、name 优先显示、
# 以及 Service 值变更必须显式声明引用范围（ADR 0001）。

set -u

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

suite "t-cli"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FW="$TEST_PROJECT_DIR/fw.sh"
FIXTURES="$TEST_PROJECT_DIR/tests/fixtures"

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
    printf '%s\n' '{"nat_mode":"auto","snat_address":null,"forwards":[],"open_ports":{"tcp":[],"udp":[]},"blacklist":[]}' \
        > "$FWCTL_STATE_FILE"
}

fw() { bash "$FW" "$@"; }

# ── target 的七个动词 ─────────────────────────────────────────────────

setup_env target
assert_ok "target add" fw target add edge 192.0.2.20
assert_eq "target 已写入" \
    "$(jq -r '[.targets[] | select(.name=="edge")] | length' "$FWCTL_STATE_FILE")" "1"
assert_eq "地址正确" \
    "$(jq -r '.targets[] | select(.name=="edge") | .addresses[0]' "$FWCTL_STATE_FILE")" \
    "192.0.2.20"

assert_ok "target add 多地址" fw target add pool 203.0.113.1,203.0.113.2
assert_eq "多地址被保存并排序" \
    "$(jq -rc '.targets[] | select(.name=="pool") | .addresses' "$FWCTL_STATE_FILE")" \
    '["203.0.113.1","203.0.113.2"]'

assert_ok "target add 带描述" fw target add relay 198.51.100.9 --description "备用"
assert_eq "描述被保存" \
    "$(jq -r '.targets[] | select(.name=="relay") | .description' "$FWCTL_STATE_FILE")" \
    "备用"

original_id=$(jq -r '.targets[] | select(.name=="edge") | .id' "$FWCTL_STATE_FILE")
assert_ok "target edit 改名" fw target edit edge --name edge-node
assert_eq "改名后 id 不变" \
    "$(jq -r '.targets[] | select(.name=="edge-node") | .id' "$FWCTL_STATE_FILE")" \
    "$original_id"

assert_ok "target edit 改地址" fw target edit edge-node --address 198.51.100.5
assert_eq "地址已更新" \
    "$(jq -r '.targets[] | select(.name=="edge-node") | .addresses[0]' "$FWCTL_STATE_FILE")" \
    "198.51.100.5"
assert_eq "改地址后 id 仍不变" \
    "$(jq -r '.targets[] | select(.name=="edge-node") | .id' "$FWCTL_STATE_FILE")" \
    "$original_id"

assert_ok "target disable" fw target disable edge-node
assert_eq "禁用状态已保存" \
    "$(jq -r '.targets[] | select(.name=="edge-node") | .enabled' "$FWCTL_STATE_FILE")" \
    "false"
assert_ok "target enable" fw target enable edge-node
assert_eq "启用状态已恢复" \
    "$(jq -r '.targets[] | select(.name=="edge-node") | .enabled' "$FWCTL_STATE_FILE")" \
    "true"

assert_ok "target list" fw target list
assert_ok "target show" fw target show edge-node
assert_eq "target show 输出 JSON 对象" \
    "$(fw target show edge-node | jq -r '.name')" "edge-node"

assert_ok "target delete" fw target delete relay
assert_eq "target 已删除" \
    "$(jq -r '[.targets[] | select(.name=="relay")] | length' "$FWCTL_STATE_FILE")" "0"

assert_fails "重复名称被拒绝" 0 fw target add edge-node 10.0.0.1
assert_fails "非法地址被拒绝" 0 fw target add bad 999.1.1.1
assert_fails "不存在的对象被拒绝" 0 fw target show nope

# ── service ───────────────────────────────────────────────────────────

setup_env service
assert_ok "service add" fw service add https both 443
assert_eq "service 已写入" \
    "$(jq -r '.services[] | select(.name=="https") | .protocol' "$FWCTL_STATE_FILE")" \
    "both"
assert_eq "Service 不含 enabled 字段" \
    "$(jq -r '.services[0] | has("enabled")' "$FWCTL_STATE_FILE")" "false"

assert_ok "service add 区间" fw service add hop udp 60000-61000
assert_eq "区间被保存" \
    "$(jq -rc '.services[] | select(.name=="hop") | .ports' "$FWCTL_STATE_FILE")" \
    '["60000-61000"]'

assert_ok "service add 多端口" fw service add web tcp 80,443
assert_eq "多端口被保存并排序" \
    "$(jq -rc '.services[] | select(.name=="web") | .ports' "$FWCTL_STATE_FILE")" \
    '["80","443"]'

assert_ok "service edit 改名" fw service edit https --name secure
assert_eq "改名成功" \
    "$(jq -r '[.services[] | select(.name=="secure")] | length' "$FWCTL_STATE_FILE")" "1"

assert_ok "service list" fw service list
assert_ok "service show" fw service show secure

# Service 没有 enable/disable：启用状态属于 Rule。
output=$(fw service disable secure 2>&1)
rc=$?
assert_eq "service disable 返回 2 (usage)" "$rc" "2"
assert_contains "拒绝理由说明 Service 是值对象" "$output" "不可变值对象"
assert_contains "拒绝时给出正确做法" "$output" "fw rule disable"

assert_ok "service delete" fw service delete hop

# ── rule ──────────────────────────────────────────────────────────────

setup_env rule
fw target add edge 192.0.2.20 >/dev/null
fw target add blocklist 203.0.113.0/24 >/dev/null
fw service add https both 443 >/dev/null

assert_ok "rule add forward" fw rule add edge-https --type forward \
    --service https --target edge
assert_eq "forward 规则已写入" \
    "$(jq -r '.rules[] | select(.name=="edge-https") | .type' "$FWCTL_STATE_FILE")" \
    "forward"
assert_eq "引用按 id 保存" \
    "$(jq -r '.rules[] | select(.name=="edge-https") | .service | startswith("svc-")' \
        "$FWCTL_STATE_FILE")" "true"

assert_ok "rule add block" fw rule add deny --type block --source blocklist --priority 10
assert_eq "block 规则已写入" \
    "$(jq -r '.rules[] | select(.name=="deny") | .type' "$FWCTL_STATE_FILE")" "block"

assert_ok "rule add accept" fw rule add allow-https --type accept --service https
assert_eq "accept 规则已写入" \
    "$(jq -r '.rules[] | select(.name=="allow-https") | .type' "$FWCTL_STATE_FILE")" \
    "accept"

assert_ok "rule add 带注释" fw rule add noted --type accept --service https \
    --comment "对外入口"
noted_id=$(jq -r '.rules[] | select(.name=="noted") | .id' "$FWCTL_STATE_FILE")
assert_eq "注释写入 comments 映射" \
    "$(jq -r --arg id "$noted_id" '.comments[$id]' "$FWCTL_STATE_FILE")" "对外入口"

assert_ok "rule add 带 to-port" fw rule add mapped --type forward \
    --service https --target edge --to-port 8443
assert_eq "to-port 写入 translate" \
    "$(jq -r '.rules[] | select(.name=="mapped") | .translate.port' "$FWCTL_STATE_FILE")" \
    "8443"

assert_ok "rule edit 改优先级" fw rule edit edge-https --priority 500
assert_eq "优先级已更新" \
    "$(jq -r '.rules[] | select(.name=="edge-https") | .priority' "$FWCTL_STATE_FILE")" \
    "500"

assert_ok "rule disable" fw rule disable edge-https
assert_eq "禁用状态已保存" \
    "$(jq -r '.rules[] | select(.name=="edge-https") | .enabled' "$FWCTL_STATE_FILE")" \
    "false"
assert_ok "rule enable" fw rule enable edge-https

assert_ok "rule list" fw rule list
assert_ok "rule show" fw rule show edge-https
assert_ok "rule delete" fw rule delete mapped

assert_fails "缺少 --type 被拒绝" 2 fw rule add bad --service https
assert_fails "引用不存在的 Service 被拒绝" 0 \
    fw rule add bad --type accept --service nope
assert_fails "forward 缺少 target 被拒绝" 0 \
    fw rule add bad --type forward --service https

# ── 引用保护与级联 ────────────────────────────────────────────────────

setup_env cascade
fw target add edge 192.0.2.20 >/dev/null
fw service add https both 443 >/dev/null
fw rule add edge-https --type forward --service https --target edge >/dev/null

output=$(fw target delete edge 2>&1)
rc=$?
assert_eq "删除被引用的 Target 返回 1 (validation)" "$rc" "1"
assert_contains "拒绝时列出引用方" "$output" "edge-https"
assert_contains "拒绝时提示 cascade" "$output" "--cascade"

assert_ok "cascade 删除成功" fw target delete edge --cascade
assert_eq "cascade 同时删除引用规则" \
    "$(jq -r '[.rules[] | select(.name=="edge-https")] | length' "$FWCTL_STATE_FILE")" "0"

# ── Service 值变更必须声明引用范围 ────────────────────────────────────

setup_env service-replace
fw target add edge 192.0.2.20 >/dev/null
fw service add https both 443 >/dev/null
fw rule add a --type forward --service https --target edge >/dev/null
fw rule add b --type accept --service https >/dev/null

output=$(fw service edit https --ports 8443 2>&1)
rc=$?
assert_eq "缺少引用范围返回 2 (usage)" "$rc" "2"
assert_contains "提示需要显式声明范围" "$output" "--refs"
assert_contains "提示 --all-refs 选项" "$output" "--all-refs"
assert_contains "列出当前引用方" "$output" "a"

before_services=$(jq '.services | length' "$FWCTL_STATE_FILE")
assert_eq "被拒绝时不产生新 Service" \
    "$(jq '.services | length' "$FWCTL_STATE_FILE")" "$before_services"

# --refs 只重写指定的规则
assert_ok "--refs 指定单条规则" fw service edit https --ports 8443 --refs a
assert_eq "产生了新的 Service" "$(jq '.services | length' "$FWCTL_STATE_FILE")" "2"
assert_eq "旧 Service 仍然保留" \
    "$(jq -r '[.services[] | select(.name=="https")] | length' "$FWCTL_STATE_FILE")" "1"
rule_a_svc=$(jq -r '.rules[] | select(.name=="a") | .service' "$FWCTL_STATE_FILE")
rule_b_svc=$(jq -r '.rules[] | select(.name=="b") | .service' "$FWCTL_STATE_FILE")
assert_eq "指定的规则改指向新 Service" \
    "$(jq -r --arg id "$rule_a_svc" '.services[] | select(.id==$id) | .ports[0]' \
        "$FWCTL_STATE_FILE")" "8443"
assert_eq "未指定的规则保持原引用" \
    "$(jq -r --arg id "$rule_b_svc" '.services[] | select(.id==$id) | .ports[0]' \
        "$FWCTL_STATE_FILE")" "443"

# --all-refs 重写全部引用
setup_env service-replace-all
fw target add edge 192.0.2.20 >/dev/null
fw service add https both 443 >/dev/null
fw rule add a --type forward --service https --target edge >/dev/null
fw rule add b --type accept --service https >/dev/null
assert_ok "--all-refs 重写全部引用" fw service edit https --ports 9443 --all-refs
all_ports=$(jq -r '[.rules[] | .service] as $refs
    | [.services[] | select(.id as $i | $refs | index($i)) | .ports[0]] | unique | join(",")' \
    "$FWCTL_STATE_FILE")
assert_eq "全部规则都指向新端口" "$all_ports" "9443"

# ── 退出码 ABI ────────────────────────────────────────────────────────

setup_env exitcodes
assert_fails "用法错误返回 2" 2 fw target
assert_fails "未知子命令返回 2" 2 fw target bogus x
assert_fails "校验失败返回 1" 1 fw target add bad 999.999.999.999
assert_fails "引用不存在返回 1" 1 fw target delete nonexistent

FAKE_NFT_FAIL_CHECK=1 fw target add ok 10.0.0.1 >/dev/null 2>&1
assert_eq "渲染失败返回 3 (runtime)" "$?" "3"

# ── 显示优先使用 name ─────────────────────────────────────────────────

setup_env display
fw target add edge 192.0.2.20 >/dev/null
fw service add https both 443 >/dev/null
fw rule add edge-https --type forward --service https --target edge >/dev/null

list_output=$(fw rule list)
assert_contains "rule list 显示规则名" "$list_output" "edge-https"
assert_contains "rule list 显示 Service 名" "$list_output" "https"
assert_contains "rule list 显示 Target 名" "$list_output" "edge"
assert_not_contains "rule list 不暴露内部 id" "$list_output" "rule-"

target_list=$(fw target list)
assert_contains "target list 显示名称与地址" "$target_list" "edge"
assert_contains "target list 显示地址" "$target_list" "192.0.2.20"

# 地址完全相同的 Target 标注 DUP。
fw target add edge2 192.0.2.20 >/dev/null
dup_output=$(fw target list)
assert_contains "地址重复的 Target 标注 DUP" "$dup_output" "[DUP]"

# ── --json ────────────────────────────────────────────────────────────

setup_env json
fw target add edge 192.0.2.20 >/dev/null
fw service add https both 443 >/dev/null

json_out=$(fw target list --json)
assert_ok "target list --json 可被 jq 解析" jq -e . <<< "$json_out"
assert_eq "JSON 同时包含 id 与 name" \
    "$(jq -r '.[0] | (has("id") and has("name"))' <<< "$json_out")" "true"
port_json=$(fw port list --json)
assert_ok "port list --json 可被 jq 解析" jq -e . <<< "$port_json"

# ── --dry-run 不改变任何东西 ──────────────────────────────────────────

setup_env dryrun
fw target add edge 192.0.2.20 >/dev/null
before=$(sha256sum "$FWCTL_STATE_FILE")
before_conf=$(sha256sum "$FWCTL_SYSTEM_CONF")
assert_ok "dry-run 返回成功" fw target add other 10.0.0.9 --dry-run
assert_eq "dry-run 不修改状态" "$(sha256sum "$FWCTL_STATE_FILE")" "$before"
assert_eq "dry-run 不改动持久化配置" "$(sha256sum "$FWCTL_SYSTEM_CONF")" "$before_conf"
assert_eq "dry-run 不产生新对象" \
    "$(jq -r '[.targets[] | select(.name=="other")] | length' "$FWCTL_STATE_FILE")" "0"

# ── validate 与 diff ──────────────────────────────────────────────────

setup_env validate
fw target add edge 192.0.2.20 >/dev/null
assert_ok "validate 通过" fw validate
assert_ok "validate --offline 通过" fw validate --offline

output=$(fw validate 2>&1)
assert_contains "validate 输出通过信息" "$output" "状态校验通过"

setup_env diff
fw target add edge 192.0.2.20 >/dev/null
fw render >/dev/null
output=$(fw diff)
assert_eq "应用后 diff 无差异" "$?" "0"
assert_contains "无差异时明确说明" "$output" "无差异"

fw port add tcp 8443 --dry-run >/dev/null 2>&1
assert_ok "diff 是只读的，不改变状态" fw diff

finish
