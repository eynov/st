#!/bin/bash
# tests/t-comment.sh —— 注释
#
# 覆盖 comments 映射与对象 description 的分工、渲染进 nft comment 的形态、
# 长度与字符限制、孤儿清理，以及 render.comments 开关。

set -u

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

suite "t-comment"

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

# ── 注释渲染进 nft ────────────────────────────────────────────────────

setup_env render
fw target add edge 192.0.2.20 >/dev/null
fw service add https both 443 >/dev/null
fw rule add edge-https --type forward --service https --target edge \
    --comment "对外 HTTPS 入口" >/dev/null

conf="$FWCTL_BUILD_DIR/nft.conf"
rule_id=$(jq -r '.rules[] | select(.name == "edge-https") | .id' "$FWCTL_STATE_FILE")

assert_eq "注释存入 comments 映射" \
    "$(jq -r --arg id "$rule_id" '.comments[$id]' "$FWCTL_STATE_FILE")" "对外 HTTPS 入口"
assert_contains "注释以 fwctl:<id> 开头" "$(cat "$conf")" "comment \"fwctl:$rule_id 对外 HTTPS 入口\""

# 没有用户注释时仍带 id，这是 stats 的关联句柄。
fw rule add plain --type accept --service https >/dev/null
plain_id=$(jq -r '.rules[] | select(.name == "plain") | .id' "$FWCTL_STATE_FILE")
assert_contains "无注释的规则仍带 id" "$(cat "$conf")" "comment \"fwctl:$plain_id\""

# ── description 与 comments 的分工 ────────────────────────────────────
# description 只在 CLI 显示，不渲染；comments 渲染进 nft。

setup_env split
fw target add edge 192.0.2.20 --description "香港落地" >/dev/null
assert_eq "description 存入对象" \
    "$(jq -r '.targets[] | select(.name=="edge") | .description' "$FWCTL_STATE_FILE")" \
    "香港落地"
assert_not_contains "description 不渲染进 nft" \
    "$(cat "$FWCTL_BUILD_DIR/nft.conf")" "香港落地"

fw service add https both 443 >/dev/null
fw rule add r1 --type accept --service https --description "只显示" --comment "会渲染" >/dev/null
conf="$FWCTL_BUILD_DIR/nft.conf"
assert_contains "comment 渲染进 nft" "$(cat "$conf")" "会渲染"
assert_not_contains "description 不渲染进 nft" "$(cat "$conf")" "只显示"
assert_eq "两者分别存放" \
    "$(jq -r '.rules[] | select(.name=="r1") | .description' "$FWCTL_STATE_FILE")" "只显示"

# ── 字符与长度限制 ────────────────────────────────────────────────────

setup_env limits
fw service add https both 443 >/dev/null

assert_fails "含双引号的注释被拒绝" 0 \
    fw rule add bad --type accept --service https --comment 'say "hi"'

# nftables 的 comment 上限是 128 **字节**而不是字符，写入时就按字节截断。
# 用真实 nft 复核截断后的产物确实可加载（未启用时跳过）。
assert_loadable() {
    local message=$1
    if [[ "${FWCTL_TEST_REAL_NFT:-0}" != 1 ]]; then
        return 0
    fi
    if nft -c -f "$FWCTL_BUILD_DIR/nft.conf" >/dev/null 2>&1; then
        ok "$message"
    else
        not_ok "$message" "nft -c 拒绝了含长注释的产物"
    fi
}

long=$(printf 'x%.0s' {1..200})
fw rule add longcomment --type accept --service https --comment "$long" >/dev/null 2>&1
long_id=$(jq -r '.rules[] | select(.name=="longcomment") | .id' "$FWCTL_STATE_FILE")
stored_bytes=$(jq -r --arg id "$long_id" '.comments[$id] | utf8bytelength' "$FWCTL_STATE_FILE")
assert_eq "ASCII 超长注释按可用字节截断" \
    "$([[ "$stored_bytes" -le 104 ]] && echo yes)" "yes"

rendered_bytes=$(grep -o "comment \"fwctl:${long_id}[^\"]*\"" "$FWCTL_BUILD_DIR/nft.conf" |
    head -1 | sed 's/^comment "//; s/"$//' | wc -c)
assert_eq "渲染出的 ASCII 注释不超过 128 字节" \
    "$([[ "$rendered_bytes" -le 129 ]] && echo yes)" "yes"
assert_loadable "含超长 ASCII 注释的产物可被 nft 接受"

# 中文注释：43 个中文字就是 129 字节，按字符截断会产生加载不了的 ruleset。
setup_env limits-cjk
fw service add https both 443 >/dev/null
cjk=$(printf '中%.0s' {1..200})
fw rule add cjkcomment --type accept --service https --comment "$cjk" >/dev/null 2>&1
cjk_id=$(jq -r '.rules[] | select(.name=="cjkcomment") | .id' "$FWCTL_STATE_FILE")
cjk_bytes=$(jq -r --arg id "$cjk_id" '.comments[$id] | utf8bytelength' "$FWCTL_STATE_FILE")
assert_eq "中文注释按字节而非字符截断" \
    "$([[ "$cjk_bytes" -le 104 ]] && echo yes)" "yes"

cjk_rendered=$(grep -o "comment \"fwctl:${cjk_id}[^\"]*\"" "$FWCTL_BUILD_DIR/nft.conf" |
    head -1 | sed 's/^comment "//; s/"$//' | wc -c)
assert_eq "渲染出的中文注释不超过 128 字节" \
    "$([[ "$cjk_rendered" -le 129 ]] && echo yes)" "yes"
assert_loadable "含超长中文注释的产物可被 nft 接受"

# 截断不得把多字节字符切成两半。
assert_eq "截断后仍是合法 UTF-8" \
    "$(jq -r --arg id "$cjk_id" '.comments[$id]' "$FWCTL_STATE_FILE" |
       iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && echo valid)" "valid"

# ── 孤儿注释清理 ──────────────────────────────────────────────────────

setup_env orphan
fw target add edge 192.0.2.20 >/dev/null
fw service add https both 443 >/dev/null
fw rule add doomed --type accept --service https --comment "即将删除" >/dev/null
doomed_id=$(jq -r '.rules[] | select(.name=="doomed") | .id' "$FWCTL_STATE_FILE")
assert_eq "注释已写入" \
    "$(jq -r --arg id "$doomed_id" '.comments | has($id)' "$FWCTL_STATE_FILE")" "true"

fw rule delete doomed >/dev/null
assert_eq "删除规则后注释被清理" \
    "$(jq -r --arg id "$doomed_id" '.comments | has($id)' "$FWCTL_STATE_FILE")" "false"

# 手工塞进去的孤儿注释在下一次写事务时被清理。
setup_env orphan-prune
fw target add edge 192.0.2.20 >/dev/null
jq '.comments["rule-ffffffffffff"] = "孤儿"' "$FWCTL_STATE_FILE" > "$WORK/o.json"
mv "$WORK/o.json" "$FWCTL_STATE_FILE"
fw target add other 10.0.0.9 >/dev/null
assert_eq "孤儿注释在写事务中被清理" \
    "$(jq -r '.comments | has("rule-ffffffffffff")' "$FWCTL_STATE_FILE")" "false"

# 合成键的注释不会被误清理。
setup_env synthetic-key
fw port add tcp 443 >/dev/null
jq '.comments["tcp:443"] = "sb VLESS"' "$FWCTL_STATE_FILE" > "$WORK/s.json"
mv "$WORK/s.json" "$FWCTL_STATE_FILE"
fw port add udp 53 >/dev/null
assert_eq "tcp: 合成键注释被保留" \
    "$(jq -r '.comments["tcp:443"]' "$FWCTL_STATE_FILE")" "sb VLESS"

# ── render.comments 开关 ──────────────────────────────────────────────

setup_env toggle
fw target add edge 192.0.2.20 >/dev/null
fw service add https both 443 >/dev/null
fw rule add r --type accept --service https --comment "注释内容" >/dev/null

assert_contains "默认渲染注释" "$(cat "$FWCTL_BUILD_DIR/nft.conf")" "comment"

jq '.settings.render.comments = false' "$FWCTL_STATE_FILE" > "$WORK/t.json"
mv "$WORK/t.json" "$FWCTL_STATE_FILE"
fw render >/dev/null

conf_off=$(cat "$FWCTL_BUILD_DIR/nft.conf")
assert_not_contains "关闭后完全不渲染注释" "$conf_off" "comment"
assert_not_contains "关闭后内建规则也不带注释" "$conf_off" "fwctl:ssh"
assert_not_contains "关闭后 SYN 限速也不带注释" "$conf_off" "fwctl:syn-limit"
assert_contains "关闭注释不影响 counter" "$conf_off" "counter"
assert_eq "关闭注释后状态中的注释仍然保留" \
    "$(jq -r '.comments | length' "$FWCTL_STATE_FILE")" "1"

# ── 注释与 stats 的关联 ───────────────────────────────────────────────
# stats 依赖 fwctl:<id> 前缀把内核计数器关联回对象；带用户注释时前缀必须仍可解析。

setup_env stats-link
fw target add edge 192.0.2.20 >/dev/null
fw service add https both 443 >/dev/null
fw rule add annotated --type accept --service https --comment "带注释的规则" >/dev/null

stats_json=$(fw stats --json)
assert_ok "带注释时 stats 仍可解析" jq -e . <<< "$stats_json"
assert_eq "带注释的规则出现在统计中" \
    "$(jq -r '[.[] | select(.name == "annotated")] | length' <<< "$stats_json")" "1"

finish
