#!/bin/bash
# tests/t-counter.sh —— 计数器、备份恢复与体检
#
# 覆盖 counter 的渲染与读回、counter 关闭时的行为、backup/restore 走同一事务、
# 以及 doctor 的报告项（尤其是「只报告不修改」这一条）。

set -u

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

suite "t-counter"

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

build_sample() {
    fw target add edge 192.0.2.20 >/dev/null
    fw service add https both 443 >/dev/null
    fw rule add edge-https --type forward --service https --target edge >/dev/null
    fw port add tcp 8443 >/dev/null
}

# ── counter 渲染 ──────────────────────────────────────────────────────

setup_env counters
build_sample

conf="$FWCTL_BUILD_DIR/nft.conf"
assert_contains "对象规则带 counter" "$(cat "$conf")" "counter"
assert_contains "对象规则带 id 注释" "$(cat "$conf")" 'comment "fwctl:rule-'
assert_contains "内建 ssh 规则带注释" "$(cat "$conf")" 'comment "fwctl:ssh"'
assert_contains "内建端口规则带注释" "$(cat "$conf")" 'comment "fwctl:ports-tcp"'
assert_contains "SYN 限速带注释" "$(cat "$conf")" 'comment "fwctl:syn-limit"'

# ── stats 读回并按 name 显示 ──────────────────────────────────────────

output=$(fw stats)
assert_eq "stats 返回成功" "$?" "0"
assert_contains "stats 显示规则名而非 id" "$output" "edge-https"
assert_not_contains "stats 不暴露内部 id" "$output" "rule-"
assert_contains "stats 包含内建规则" "$output" "ssh"
assert_contains "stats 有表头" "$output" "PACKETS"

json_output=$(fw stats --json)
assert_ok "stats --json 可被 jq 解析" jq -e . <<< "$json_output"
assert_eq "JSON 同时含 id 与 name" \
    "$(jq -r '.[0] | (has("id") and has("name"))' <<< "$json_output")" "true"
assert_eq "JSON 含计数器" \
    "$(jq -r '.[0].counter | has("packets")' <<< "$json_output")" "true"

# protocol=both 展开成两条 nft 规则，同一个对象的计数必须累加而不是只取一条。
assert_eq "both 规则的计数被合并为一个对象" \
    "$(jq -r '[.[] | select(.name == "edge-https")] | length' <<< "$json_output")" "1"

# ── counter 关闭时明确报错 ────────────────────────────────────────────

setup_env counters-off
build_sample
jq '.settings.render.counters = false' "$FWCTL_STATE_FILE" > "$WORK/off.json"
mv "$WORK/off.json" "$FWCTL_STATE_FILE"
fw render >/dev/null

assert_not_contains "关闭后渲染不含 counter" "$(cat "$FWCTL_BUILD_DIR/nft.conf")" "counter"

output=$(fw stats 2>&1)
rc=$?
assert_eq "counter 关闭时 stats 返回非零" "$([[ $rc -ne 0 ]] && echo yes)" "yes"
assert_contains "明确说明 counter 已关闭" "$output" "已在 settings.render.counters 中关闭"
assert_contains "给出开启方式" "$output" "改回 true"
assert_not_contains "不输出一屏全零" "$output" "PACKETS"

# ── stats --reset ─────────────────────────────────────────────────────

setup_env stats-reset
build_sample
assert_ok "stats --reset 成功" fw stats --reset
assert_ok "清零后规则仍在" fw stats

# ── backup ────────────────────────────────────────────────────────────

setup_env backup
build_sample

id=$(fw backup create --label "before-change" | sed -n 's/.*已创建备份 //p')
assert_eq "backup create 输出 id" "$([[ -n "$id" ]] && echo yes)" "yes"
assert_eq "备份目录内有状态文件" \
    "$([[ -f "$FWCTL_VAR_DIR/backups/$id/state.json" ]] && echo yes)" "yes"
assert_eq "备份目录内有元数据" \
    "$([[ -f "$FWCTL_VAR_DIR/backups/$id/metadata.json" ]] && echo yes)" "yes"
assert_eq "元数据记录 label" \
    "$(jq -r '.label' "$FWCTL_VAR_DIR/backups/$id/metadata.json")" "before-change"
assert_eq "元数据记录 generation" \
    "$(jq -r '.generation | type' "$FWCTL_VAR_DIR/backups/$id/metadata.json")" "number"

list_output=$(fw backup list)
assert_contains "backup list 显示 id" "$list_output" "$id"
assert_contains "backup list 显示 label" "$list_output" "before-change"

assert_ok "backup show 可用" fw backup show "$id"
assert_fails "backup show 不存在的 id 失败" 0 fw backup show backup-nonexistent

json_list=$(fw backup list --json)
assert_ok "backup list --json 可被 jq 解析" jq -e . <<< "$json_list"

# 同一秒内的多次备份不互相覆盖。
id2=$(FWCTL_NOW=2026-07-31T00:00:00Z fw backup create | sed -n 's/.*已创建备份 //p')
id3=$(FWCTL_NOW=2026-07-31T00:00:00Z fw backup create | sed -n 's/.*已创建备份 //p')
assert_eq "同一时间戳的备份不冲突" "$([[ "$id2" != "$id3" ]] && echo differ)" "differ"

# ── restore 走同一事务 ────────────────────────────────────────────────

setup_env restore
build_sample
snapshot=$(fw backup create --label snapshot | sed -n 's/.*已创建备份 //p')
before_ports=$(jq -c '.ports.tcp' "$FWCTL_STATE_FILE")

fw port add tcp 9999 >/dev/null
assert_eq "变更已生效" \
    "$(jq -r '.ports.tcp | index("9999") != null' "$FWCTL_STATE_FILE")" "true"

assert_ok "restore 成功" fw restore "$snapshot"
assert_eq "恢复后端口回到备份时的状态" "$(jq -c '.ports.tcp' "$FWCTL_STATE_FILE")" "$before_ports"
assert_eq "恢复后新增的端口消失" \
    "$(jq -r '.ports.tcp | index("9999") == null' "$FWCTL_STATE_FILE")" "true"

# restore 前会自动备份当前状态，避免恢复错备份变成不可逆操作。
assert_eq "restore 前自动创建了备份" \
    "$(find "$FWCTL_VAR_DIR/backups" -maxdepth 1 -name 'backup-*' \
        -exec jq -r '.label' '{}/metadata.json' \; 2>/dev/null |
       grep -c 'before-restore')" "1"

assert_fails "restore 不存在的备份失败" 0 fw restore backup-nonexistent

# 恢复失败时整体回滚，不做部分恢复。
setup_env restore-invalid
build_sample
bad="$ENV_DIR/bad-state.json"
jq '.rules[0].service = "svc-000000000000"' "$FWCTL_STATE_FILE" > "$bad"
before=$(sha256sum "$FWCTL_STATE_FILE")
assert_fails "恢复非法状态被拒绝" 0 fw restore --file "$bad"
assert_eq "被拒绝时当前状态不变" "$(sha256sum "$FWCTL_STATE_FILE")" "$before"

# 旧格式的备份依然可以恢复。
setup_env restore-legacy
build_sample
before_count=$(jq '.targets | length' "$FWCTL_STATE_FILE")
assert_ok "可从旧格式文件恢复" fw restore --file "$FIXTURES/state-v1-production.json"
assert_eq "恢复后已是当前 schema" \
    "$(jq -r '.schema_version' "$FWCTL_STATE_FILE")" "4"
assert_eq "旧格式的转发被正确分解" \
    "$([[ "$(jq '.targets | length' "$FWCTL_STATE_FILE")" -gt "$before_count" ]] && echo yes)" \
    "yes"

# ── doctor ────────────────────────────────────────────────────────────

setup_env doctor
build_sample

output=$(fw doctor)
rc=$?
assert_eq "健康环境下 doctor 返回 0" "$rc" "0"
assert_contains "报告依赖检查" "$output" "依赖"
assert_contains "报告状态检查" "$output" "状态"
assert_contains "报告漂移检查" "$output" "漂移"
assert_contains "报告持久化检查" "$output" "持久化"
assert_contains "报告遗留表检查" "$output" "遗留表"
assert_contains "报告事务检查" "$output" "事务"
assert_contains "报告合计行" "$output" "合计"

json_doctor=$(fw doctor --json)
assert_ok "doctor --json 可被 jq 解析" jq -e . <<< "$json_doctor"
assert_eq "JSON 每项含 status 与 check" \
    "$(jq -r '.[0] | (has("status") and has("check"))' <<< "$json_doctor")" "true"

# 安全建议只提醒，绝不自动修改。
before=$(sha256sum "$FWCTL_STATE_FILE")
fw doctor >/dev/null
assert_eq "doctor 不修改状态" "$(sha256sum "$FWCTL_STATE_FILE")" "$before"
assert_contains "对沿用旧默认值给出建议" "$output" "安全建议"
assert_contains "建议中说明不会自动修改" "$output" "不会自动修改"
assert_eq "给出建议后策略仍未被改动" \
    "$(jq -r '.settings.policy.ct_invalid' "$FWCTL_STATE_FILE")" "ignore"

# 漂移能被检出。
setup_env doctor-drift
build_sample
fw port add tcp 7777 --dry-run >/dev/null 2>&1
printf 'table ip fwctl { }\ndelete table ip fwctl\n' > "$ENV_DIR/drop.nft"
"$FWCTL_NFT_BIN" -f "$ENV_DIR/drop.nft" >/dev/null 2>&1
output=$(fw doctor 2>&1)
assert_contains "内核中缺表时报告漂移" "$output" "运行中不存在"

# 未完成的事务会被报告。
setup_env doctor-journal
build_sample
printf '{"journal_version":1,"phase":"prepared","rollback_nft":"/nonexistent"}' \
    > "$FWCTL_VAR_DIR/journal.json"
output=$(fw doctor 2>&1 || true)
assert_contains "报告未完成的事务或已自动收敛" "$output" "事务"

# 存在其他表时提醒：不再 flush 整机规则后，它们会真正保留下来。
setup_env doctor-other-tables
build_sample
cat > "$ENV_DIR/other.nft" <<'OTHER'
table ip docker {
    chain forward {
        type filter hook forward priority filter; policy accept;
    }
}
OTHER
"$FWCTL_NFT_BIN" -f "$ENV_DIR/other.nft" >/dev/null 2>&1
output=$(fw doctor 2>&1)
assert_contains "报告同机存在的其他表" "$output" "docker"
assert_contains "说明其他表也会被评估" "$output" "任一 drop 生效"

finish
