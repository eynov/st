#!/bin/bash
# tests/t-migration.sh —— 旧格式迁移
#
# 覆盖 docs/MIGRATION.md 的用例矩阵：字段映射、对象分解、协议合并、确定性、
# 幂等性、失败处理。
#
# 渲染等价性断言（旧渲染器 vs 迁移后新渲染器）需要渲染层，位于本文件末尾的
# 「渲染等价性」小节，由 Layer 3 补齐。

set -u

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TEST_PROJECT_DIR/core/common.sh"
source "$TEST_PROJECT_DIR/core/state.sh"
source "$TEST_PROJECT_DIR/core/model.sh"
source "$TEST_PROJECT_DIR/core/migration.sh"

suite "t-migration"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FIXTURES="$TEST_PROJECT_DIR/tests/fixtures"

# 迁移一个固件，输出结果路径。
migrate_fixture() {
    # 必须分两条 local：同一条 local 里后面的赋值看到的是外层的旧变量值，
    # 而不是刚刚赋好的参数。
    local name=$1
    local out="$WORK/migrated-$name.json"
    local err="$WORK/migrated-$name.err"
    if ! migration_v1_to_current "$FIXTURES/state-v1-$name.json" > "$out" 2>"$err"; then
        printf '%s\n' "MIGRATION-FAILED"
        return 1
    fi
    printf '%s\n' "$out"
}

# ── 版本判定 ──────────────────────────────────────────────────────────

assert_ok "旧格式被识别为需要迁移" \
    migration_is_legacy "$FIXTURES/state-v1-empty.json"

state_default > "$WORK/current.json"
assert_fails "当前 schema 不需要迁移" 0 \
    migration_is_legacy "$WORK/current.json"

# ── 每个固件都能迁移并通过完整校验 ────────────────────────────────────

for fixture in "$FIXTURES"/state-v1-*.json; do
    name=$(basename "$fixture" .json)
    name=${name#state-v1-}
    out=$(migrate_fixture "$name") || {
        not_ok "固件 $name 迁移成功" "$(cat "$WORK/migrated-$name.err" 2>/dev/null)"
        continue
    }
    ok "固件 $name 迁移成功"
    if output=$(state_validate "$out" 2>&1); then
        ok "固件 $name 的迁移结果通过校验"
    else
        not_ok "固件 $name 的迁移结果通过校验" "${output:0:300}"
    fi
done

# ── 确定性与幂等性 ────────────────────────────────────────────────────

migration_v1_to_current "$FIXTURES/state-v1-production.json" > "$WORK/det1.json"
migration_v1_to_current "$FIXTURES/state-v1-production.json" > "$WORK/det2.json"
assert_files_eq "同一输入的两次迁移逐字节相同" "$WORK/det1.json" "$WORK/det2.json"

# 已是当前 schema 时再迁移一次应为空操作。
migration_to_current "$WORK/det1.json" > "$WORK/det3.json"
assert_files_eq "对已迁移状态再次迁移是空操作" "$WORK/det1.json" "$WORK/det3.json"

# 时间戳来自源文件 mtime 而非当前时间：改变 FWCTL_NOW 不应影响结果。
FWCTL_NOW=2000-01-01T00:00:00Z migration_v1_to_current \
    "$FIXTURES/state-v1-production.json" > "$WORK/det4.json"
assert_files_eq "迁移结果不受当前时间影响" "$WORK/det1.json" "$WORK/det4.json"

mtime=$(fwctl_file_mtime "$FIXTURES/state-v1-production.json")
assert_eq "时间戳取自源文件 mtime" \
    "$(jq -r '.targets[0].created_at' "$WORK/det1.json")" "$mtime"

# ── 字段映射 ──────────────────────────────────────────────────────────

out=$(migrate_fixture ports-only)
assert_eq "tcp 端口被搬运并数值排序" \
    "$(jq -rc '.ports.tcp' "$out")" '["80","443","20000-20010"]'
assert_eq "udp 端口被搬运并数值排序" \
    "$(jq -rc '.ports.udp' "$out")" '["53","60000-61000"]'
assert_eq "端口区间不被展开" \
    "$(jq -r '.ports.tcp | index("20000-20010") != null' "$out")" "true"

out=$(migrate_fixture nat-masquerade)
assert_eq "nat_mode=masquerade 被搬运" \
    "$(jq -r '.settings.nat.mode' "$out")" "masquerade"

out=$(migrate_fixture nat-snat)
assert_eq "nat_mode=snat 被搬运" \
    "$(jq -r '.settings.nat.mode' "$out")" "snat"
assert_eq "snat_address 被搬运" \
    "$(jq -r '.settings.nat.snat_address' "$out")" "198.51.100.10"

out=$(migrate_fixture empty)
assert_eq "迁移标记被记录" "$(jq -r '.metadata.migrated_from' "$out")" "1"
assert_eq "迁移不预写旧表接管标记" \
    "$(jq -r '.metadata.legacy_adopted_at' "$out")" "null"

# ── 空 blacklist 不生成任何对象 ───────────────────────────────────────
# Target 的 addresses 必须非空，且空地址集合渲染出来匹配不到任何流量。

out=$(migrate_fixture empty)
assert_eq "空 blacklist 不生成 Target" "$(jq '.targets | length' "$out")" "0"
assert_eq "空 blacklist 不生成 Rule" "$(jq '.rules | length' "$out")" "0"
assert_eq "空状态不生成 Service" "$(jq '.services | length' "$out")" "0"

out=$(migrate_fixture blacklist-only)
assert_eq "非空 blacklist 生成一个 Target" \
    "$(jq '[.targets[] | select(.name == "blacklist")] | length' "$out")" "1"
assert_eq "blacklist 地址被完整保留" \
    "$(jq -rc '.targets[] | select(.name == "blacklist") | .addresses' "$out")" \
    '["198.51.100.7","203.0.113.0/24"]'
assert_eq "blacklist 生成 block 规则" \
    "$(jq -r '.rules[] | select(.name == "blacklist") | .type' "$out")" "block"
assert_eq "blacklist 规则引用 source 而非 target" \
    "$(jq -r '.rules[] | select(.name == "blacklist") | .target' "$out")" "null"
assert_eq "blacklist 规则优先级为 10" \
    "$(jq -r '.rules[] | select(.name == "blacklist") | .priority' "$out")" "10"

# ── 转发分解 ──────────────────────────────────────────────────────────

out=$(migrate_fixture forward-tcp)
assert_eq "单条 tcp 转发生成一个 Target" "$(jq '.targets | length' "$out")" "1"
assert_eq "单条 tcp 转发生成一个 Service" "$(jq '.services | length' "$out")" "1"
assert_eq "单条 tcp 转发生成一条 Rule" "$(jq '.rules | length' "$out")" "1"
assert_eq "Service 协议为 tcp" "$(jq -r '.services[0].protocol' "$out")" "tcp"
assert_eq "Rule 类型为 forward" "$(jq -r '.rules[0].type' "$out")" "forward"

# tcp 与 udp 成对的转发合并成一条 protocol=both 的规则，对象数减半。
out=$(migrate_fixture forward-both)
assert_eq "成对转发只生成一个 Service" "$(jq '.services | length' "$out")" "1"
assert_eq "合并后协议为 both" "$(jq -r '.services[0].protocol' "$out")" "both"
assert_eq "成对转发只生成一条 Rule" "$(jq '.rules | length' "$out")" "1"
assert_eq "成对转发只生成一个 Target" "$(jq '.targets | length' "$out")" "1"

# 同一落地 IP 的多条转发只保存一次地址——这是取代 forwards[] 的核心动机。
out=$(migrate_fixture shared-dip)
assert_eq "共享 dip 只生成一个 Target" "$(jq '.targets | length' "$out")" "1"
assert_eq "共享 dip 生成三条 Rule" "$(jq '.rules | length' "$out")" "3"
assert_eq "地址在状态中只出现一次" \
    "$(jq '[.. | strings | select(. == "192.0.2.20")] | length' "$out")" "1"

# 相同端口组合的多条转发复用同一个 Service。
out=$(migrate_fixture shared-ports)
assert_eq "共享端口组合只生成一个 Service" "$(jq '.services | length' "$out")" "1"
assert_eq "不同落地 IP 生成两个 Target" "$(jq '.targets | length' "$out")" "2"
assert_eq "两条 Rule 引用同一个 Service" \
    "$(jq -r '[.rules[].service] | unique | length' "$out")" "1"

out=$(migrate_fixture forward-range)
assert_eq "端口区间成为 Service 的区间端口" \
    "$(jq -rc '.services[0].ports' "$out")" '["40000-40010"]'
assert_eq "区间转发的目标端口被保留" \
    "$(jq -r '.rules[0].translate.port' "$out")" "40000"

out=$(migrate_fixture dest-port-differs)
assert_eq "dest_port 不同于 sport 时写入 translate.port" \
    "$(jq -r '.rules[0].translate.port' "$out")" "80"
assert_eq "服务端口仍是对外端口" \
    "$(jq -rc '.services[0].ports' "$out")" '["8080"]'

out=$(migrate_fixture no-dest-port)
assert_eq "缺少 dest_port 时回退到 sport" \
    "$(jq -r '.rules[0].translate.port' "$out")" "443"

# ── 顺序保留 ──────────────────────────────────────────────────────────

out=$(migrate_fixture production)
assert_eq "转发规则的优先级保留 v1 相对顺序" \
    "$(jq -r '[.rules[] | select(.type == "forward")] | sort_by(.priority)
              | map(.priority) | join(",")' "$out")" \
    "100,102,103"
assert_eq "合并掉的 udp 条目不额外占用优先级" \
    "$(jq '[.rules[] | select(.type == "forward")] | length' "$out")" "3"

# ── ID 规则 ───────────────────────────────────────────────────────────

out=$(migrate_fixture production)
assert_eq "全部 id 均为 12 位十六进制" \
    "$(jq -r '[ (.targets[].id), (.services[].id), (.rules[].id) ]
              | map(select(test("^(tgt|svc|rule)-[0-9a-f]{12}$"))) | length' "$out")" \
    "$(jq -r '[ (.targets[].id), (.services[].id), (.rules[].id) ] | length' "$out")"

assert_eq "id 在状态内唯一" \
    "$(jq -r '[ (.targets[].id), (.services[].id), (.rules[].id) ]
              | (length) == (unique | length)' "$out")" "true"

# 碰撞路径：预先占用将要生成的 id，迫使分配器走 #2 重算分支。
collide="$WORK/collide.json"
state_default > "$collide"
expected_id=$(fwctl_object_id target 192.0.2.20)
jq --arg id "$expected_id" '
    .targets = [{id: $id, name: "squatter", description: "", kind: "ipv4",
                 addresses: ["10.9.9.9"], enabled: true,
                 created_at: "2026-07-31T00:00:00Z",
                 updated_at: "2026-07-31T00:00:00Z"}]
' "$collide" > "$WORK/collide2.json"
allocated=$(model_allocate_id "$WORK/collide2.json" target 192.0.2.20)
assert_eq "碰撞时不会复用已占用的 id" \
    "$([[ "$allocated" != "$expected_id" ]] && echo differ)" "differ"
assert_eq "碰撞重算的结果与 #2 盐一致" \
    "$allocated" "$(fwctl_object_id target 192.0.2.20 '#2')"
assert_eq "碰撞重算是确定的" \
    "$allocated" "$(model_allocate_id "$WORK/collide2.json" target 192.0.2.20)"

# ── 名称派生 ──────────────────────────────────────────────────────────

out=$(migrate_fixture production)
assert_eq "Target 名称由地址派生" \
    "$(jq -r '[.targets[].name] | sort | join(",")' "$out")" \
    "blacklist,t-10-0-0-5,t-10-0-0-6,t-192-0-2-20"
assert_eq "全部名称符合命名规则" \
    "$(jq -r '[ (.targets[].name), (.services[].name), (.rules[].name) ]
              | map(select(test("^[a-z0-9][a-z0-9_-]{0,31}$"))) | length' "$out")" \
    "$(jq -r '[ (.targets[].name), (.services[].name), (.rules[].name) ] | length' "$out")"

# CIDR 中的斜杠必须被替换，否则名称不合法。
out=$(migrate_fixture blacklist-only)
assert_ok "含 CIDR 的 blacklist 迁移后名称合法" state_validate "$out"

# ── 非法输入 ──────────────────────────────────────────────────────────

echo '{"nat_mode":"bridge","forwards":[],"open_ports":{"tcp":[],"udp":[]},"blacklist":[]}' \
    > "$WORK/bad-mode.json"
assert_fails "非法 nat_mode 的旧状态被拒绝" 0 \
    migration_v1_to_current "$WORK/bad-mode.json"

echo '{"nat_mode":"auto","forwards":[{"sport":"1","dport":"1","dip":"192.0.2.1","proto":"sctp"}],"open_ports":{"tcp":[],"udp":[]},"blacklist":[]}' \
    > "$WORK/bad-proto.json"
assert_fails "非法协议的旧状态被拒绝" 0 \
    migration_v1_to_current "$WORK/bad-proto.json"

echo '{"nat_mode":"auto","forwards":[{"sport":"1","dport":"1","proto":"tcp"}],"open_ports":{"tcp":[],"udp":[]},"blacklist":[]}' \
    > "$WORK/no-dip.json"
assert_fails "缺少 dip 的旧状态被拒绝" 0 \
    migration_v1_to_current "$WORK/no-dip.json"

echo '{"nat_mode":"auto","forwards":"nope","open_ports":{"tcp":[],"udp":[]},"blacklist":[]}' \
    > "$WORK/bad-type.json"
assert_fails "forwards 类型错误被拒绝" 0 \
    migration_v1_to_current "$WORK/bad-type.json"

# 迁移失败时不得修改源文件。
before=$(sha256sum "$WORK/bad-mode.json")
migration_v1_to_current "$WORK/bad-mode.json" >/dev/null 2>&1 || true
after=$(sha256sum "$WORK/bad-mode.json")
assert_eq "迁移失败不修改源状态" "$before" "$after"

# ── 迁移不写盘 ────────────────────────────────────────────────────────
# migration_* 只把结果输出到 stdout，落盘由事务层决定。

before=$(sha256sum "$FIXTURES/state-v1-production.json")
migration_v1_to_current "$FIXTURES/state-v1-production.json" >/dev/null
after=$(sha256sum "$FIXTURES/state-v1-production.json")
assert_eq "迁移不修改输入文件" "$before" "$after"

# ── 渲染等价性 ────────────────────────────────────────────────────────
#
# 这是迁移正确性的真正判据（ADR 0004）：不是「字段搬完了」，而是「防火墙行为
# 没变」。对每个固件断言
#     归一化(旧渲染器(v1)) == 归一化(新渲染器(迁移(v1)))
# 归一化只消除已声明的三类差异，见 tests/lib.sh 的 normalize_ruleset。

source "$TEST_PROJECT_DIR/core/render.sh"

# 旧实现无法渲染的输入。这些不是迁移缺陷，而是旧实现自身的缺陷；
# 列在这里是为了让「旧渲染器失败」永远是显式声明的例外，而不是被静默跳过。
#
# blacklist-only：旧实现用 sed 把黑名单替换进模板，CIDR 里的 / 会破坏
#   s/// 表达式，因此含 CIDR 的黑名单在旧版本上根本渲染不出来。
V3_CANNOT_RENDER="blacklist-only"

# 两组外部事实分别覆盖 NAT 的两条分支：公网地址不在本机（EIP，走 masquerade）
# 与公网地址就在本机（走显式 SNAT）。两个渲染器必须在两种情形下都一致。
equivalence_sweep() {
    local label=$1 locals=$2
    local fixture name v3_out v4_out migrated facts

    facts=$(render_facts 37091 "$locals" "198.51.100.10" "")

    for fixture in "$FIXTURES"/state-v1-*.json; do
        name=$(basename "$fixture" .json)
        name=${name#state-v1-}

        v3_out="$WORK/eq-$label-$name-v3.nft"
        v4_out="$WORK/eq-$label-$name-v4.nft"
        migrated="$WORK/eq-$label-$name.json"

        if ! render_with_v3 "$fixture" "$v3_out" 37091 198.51.100.10 "$locals"; then
            # 旧渲染器拒绝时，要么是它自身的已知缺陷，要么是它正确地拒绝了
            # 一个非法配置（例如 snat 地址不在本机）——后者新实现也必须拒绝。
            if [[ " $V3_CANNOT_RENDER " == *" $name "* ]]; then
                ok "[$label] $name 旧实现无法渲染（已知旧缺陷），新实现不受影响"
                continue
            fi
            if ! migration_v1_to_current "$fixture" > "$migrated" 2>/dev/null; then
                ok "[$label] $name 新旧实现都拒绝"
                continue
            fi
            if render_ruleset "$migrated" "$facts" >/dev/null 2>&1; then
                not_ok "[$label] $name 新旧实现都拒绝" \
                    "旧实现拒绝渲染，但新实现接受了同一份配置"
            else
                ok "[$label] $name 新旧实现都拒绝"
            fi
            continue
        fi

        if ! migration_v1_to_current "$fixture" > "$migrated" 2>/dev/null; then
            not_ok "[$label] $name 渲染等价" "迁移失败"
            continue
        fi
        if ! render_ruleset "$migrated" "$facts" > "$v4_out" 2>/dev/null; then
            not_ok "[$label] $name 渲染等价" "新渲染器失败"
            continue
        fi
        assert_ruleset_equivalent "[$label] $name 渲染等价" "$v3_out" "$v4_out"
    done
}

equivalence_sweep "eip" "10.0.0.10"
equivalence_sweep "local" "10.0.0.10 198.51.100.10"

# 声明的差异必须真实存在且被测到，而不是「恰好没出现」。
render_with_v3 "$FIXTURES/state-v1-empty.json" "$WORK/decl-v3.nft" \
    37091 198.51.100.10 10.0.0.10
assert_contains "旧实现确实使用 127.0.0.2 占位" \
    "$(cat "$WORK/decl-v3.nft")" "127.0.0.2"
assert_contains "旧实现确实使用 65535 占位" \
    "$(cat "$WORK/decl-v3.nft")" "65535"

migration_v1_to_current "$FIXTURES/state-v1-empty.json" > "$WORK/decl.json"
render_ruleset "$WORK/decl.json" "$(render_facts 37091 "10.0.0.10" "" "")" \
    > "$WORK/decl-v4.nft"
assert_not_contains "新实现不再产生 127.0.0.2 占位" \
    "$(cat "$WORK/decl-v4.nft")" "127.0.0.2"
assert_not_contains "新实现不再产生 65535 占位" \
    "$(cat "$WORK/decl-v4.nft")" "65535"
assert_not_contains "旧实现使用 flush ruleset" \
    "$(cat "$WORK/decl-v4.nft")" "flush ruleset"
assert_contains "旧实现确实 flush 整机规则" \
    "$(cat "$WORK/decl-v3.nft")" "flush ruleset"

finish
