#!/bin/bash
# tests/t-transaction.sh —— 事务、回滚与崩溃恢复
#
# 覆盖 docs/adr/0003-single-transaction-boundary.md：分阶段失败处理、冻结的
# 退出码 ABI、带版本的事务日志与崩溃恢复，以及 ADR 0002 的旧表接管时机、
# ADR 0005 的 ip_forward 只开不关。
#
# 默认用 tests/fixtures/fake-nft 充当内核。FWCTL_TEST_NETNS=1 时改用真实 nft
# 在隔离 network namespace 中执行，让回滚与恢复跑在真实内核上。

set -u

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TEST_PROJECT_DIR/core/common.sh"
source "$TEST_PROJECT_DIR/core/state.sh"
source "$TEST_PROJECT_DIR/core/model.sh"
source "$TEST_PROJECT_DIR/core/render.sh"
source "$TEST_PROJECT_DIR/core/transaction.sh"

suite "t-transaction"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export FWCTL_NOW=2026-07-31T00:00:00Z
export FWCTL_SKIP_SYSTEM_SETUP=1
export FWCTL_ALLOW_UNPRIVILEGED=1
export FWCTL_SSH_PORT=37091
export FWCTL_LOCAL_IPV4S="10.0.0.10"
export FWCTL_PUBLIC_IPV4="198.51.100.10"

# 选择「内核」：默认 fake-nft，netns 模式下是隔离 namespace 里的真实 nft。
if [[ "${FWCTL_TEST_NETNS:-0}" == 1 ]]; then
    export FWCTL_NFT_BIN="$TEST_PROJECT_DIR/tests/fixtures/netns-nft"
    KERNEL_MODE="真实内核 (netns)"
else
    export FWCTL_NFT_BIN="$TEST_PROJECT_DIR/tests/fixtures/fake-nft"
    export FAKE_NFT_STATE="$WORK/kernel"
    KERNEL_MODE="fake-nft"
fi
printf '# 内核后端：%s\n' "$KERNEL_MODE"

# 每个用例一套独立的目录，避免相互污染。
# 结果通过全局 dir 返回，**不能**用 $(new_env ...) 调用：那会在子 shell 里执行，
# 里面的 export 不会传回当前 shell。
new_env() {
    local name=$1
    dir="$WORK/$name"
    mkdir -p "$dir"
    export FWCTL_VAR_DIR="$dir/var"
    export FWCTL_BUILD_DIR="$dir/build"
    export FWCTL_SYSTEM_CONF="$dir/nftables.conf"
    export FWCTL_LOCKFILE="$dir/lock"
    export FWCTL_STATE_FILE="$dir/state.json"
    [[ "${FWCTL_TEST_NETNS:-0}" == 1 ]] || export FAKE_NFT_STATE="$dir/kernel"
    mkdir -p "$FWCTL_VAR_DIR"
    make_sample_state "$FWCTL_STATE_FILE"
}

# 清空「内核」，回到没有 fwctl 表的初始状态。
reset_kernel() {
    local drop="$WORK/drop.nft"
    printf 'table ip fwctl { }\ndelete table ip fwctl\n' > "$drop"
    "$FWCTL_NFT_BIN" -f "$drop" >/dev/null 2>&1 || true
    # 确认重置确实生效：残留的表会让后续断言在错误的初始状态上执行。
    if kernel_has_table && kernel_contains 'chain input'; then
        printf '# 警告：重置后内核仍存在 fwctl 表，后续断言可能不可靠\n'
    fi
}

# 内核里当前是否存在 fwctl 表。
kernel_has_table() {
    "$FWCTL_NFT_BIN" list table ip fwctl >/dev/null 2>&1
}

# 内核里 fwctl 表的规则条数（按 comment 计）。
kernel_rule_count() {
    "$FWCTL_NFT_BIN" list table ip fwctl 2>/dev/null | grep -c 'comment "fwctl:' || true
}

# 内核里的 fwctl 表是否包含指定片段。
kernel_contains() {
    "$FWCTL_NFT_BIN" list table ip fwctl 2>/dev/null | grep -qF "$1"
}

# 制作一份候选状态：在当前状态上加一条放行端口。
make_candidate() {
    local out=$1 port=${2:-8443}
    model_port_update "$FWCTL_STATE_FILE" add tcp "$port" > "$out"
}

# ── 成功路径 ──────────────────────────────────────────────────────────

new_env happy
reset_kernel
candidate="$dir/candidate.json"
make_candidate "$candidate"

txn_publish "$candidate" >/dev/null 2>&1
rc=$?
assert_eq "成功发布返回 0" "$rc" "0"
assert_ok "发布后内核里有 fwctl 表" kernel_has_table
assert_eq "状态文件已更新" \
    "$(jq -r '.ports.tcp | index("8443") != null' "$FWCTL_STATE_FILE")" "true"
assert_eq "持久化配置已写入" "$([[ -f "$FWCTL_SYSTEM_CONF" ]] && echo yes)" "yes"
assert_eq "generation 递增" \
    "$(jq -r '.metadata.generation' "$FWCTL_STATE_FILE")" "1"
assert_eq "记录了应用时间" \
    "$(jq -r '.metadata.last_applied_at != null' "$FWCTL_STATE_FILE")" "true"
assert_eq "成功后不留 journal" \
    "$([[ -f "$(txn_journal_path)" ]] && echo yes || echo no)" "no"

# ── 校验失败：退出码 1，不触碰内核与磁盘 ──────────────────────────────

new_env invalid
reset_kernel
before_state=$(sha256sum "$FWCTL_STATE_FILE")
candidate="$dir/candidate.json"
jq '.rules[0].service = "svc-000000000000"' "$FWCTL_STATE_FILE" > "$candidate"

txn_publish "$candidate" >/dev/null 2>&1
assert_eq "校验失败返回 1 (validation)" "$?" "1"
assert_fails "校验失败时内核未被改动" 0 kernel_has_table
assert_eq "校验失败时状态文件未变" "$(sha256sum "$FWCTL_STATE_FILE")" "$before_state"
assert_eq "校验失败不写持久化配置" \
    "$([[ -f "$FWCTL_SYSTEM_CONF" ]] && echo yes || echo no)" "no"
assert_eq "校验失败不留 journal" \
    "$([[ -f "$(txn_journal_path)" ]] && echo yes || echo no)" "no"

# ── nft -c 失败：退出码 3，不 apply ───────────────────────────────────

if [[ "${FWCTL_TEST_NETNS:-0}" != 1 ]]; then
    new_env checkfail
    reset_kernel
    candidate="$dir/candidate.json"
    make_candidate "$candidate"

    FAKE_NFT_FAIL_CHECK=1 txn_publish "$candidate" >/dev/null 2>&1
    assert_eq "语法检查失败返回 3 (runtime)" "$?" "3"
    assert_fails "语法检查失败时内核未被改动" 0 kernel_has_table
    assert_eq "语法检查失败不留 journal" \
        "$([[ -f "$(txn_journal_path)" ]] && echo yes || echo no)" "no"

    # ── apply 失败：退出码 5，内核已回滚 ──────────────────────────────

    new_env applyfail
    reset_kernel
    candidate="$dir/candidate.json"
    make_candidate "$candidate"

    FAKE_NFT_FAIL_APPLY=1 txn_publish "$candidate" >/dev/null 2>&1
    assert_eq "应用失败返回 5 (rollback completed)" "$?" "5"
    assert_fails "表此前不存在时回滚等于删表" 0 kernel_has_table
    assert_eq "应用失败不更新状态文件" \
        "$(jq -r '.ports.tcp | index("8443") == null' "$FWCTL_STATE_FILE")" "true"
    assert_eq "回滚后不留 journal" \
        "$([[ -f "$(txn_journal_path)" ]] && echo yes || echo no)" "no"

    # 表此前已存在时，回滚必须恢复到原来的内容而不是删表。
    new_env rollback-existing
    reset_kernel
    first="$dir/first.json"
    make_candidate "$first" 9001
    txn_publish "$first" >/dev/null 2>&1
    baseline_rules=$(kernel_rule_count)
    assert_ok "先建立一份基线规则" kernel_has_table

    second="$dir/second.json"
    model_port_update "$FWCTL_STATE_FILE" add tcp 9002 > "$second"
    FAKE_NFT_FAIL_APPLY=1 txn_publish "$second" >/dev/null 2>&1
    assert_eq "已有规则时应用失败仍返回 5" "$?" "5"
    assert_ok "回滚后表依然存在" kernel_has_table
    assert_eq "回滚后规则条数恢复原值" "$(kernel_rule_count)" "$baseline_rules"
    assert_eq "回滚后状态文件保持旧值" \
        "$(jq -r '.ports.tcp | index("9002") == null' "$FWCTL_STATE_FILE")" "true"
    assert_eq "回滚后仍保留先前成功的变更" \
        "$(jq -r '.ports.tcp | index("9001") != null' "$FWCTL_STATE_FILE")" "true"

    # ── 应用后验证失败：退出码 5 ──────────────────────────────────────
    # FAKE_NFT_CORRUPT_APPLY 让 apply 声称成功但不真正改变内核，
    # 模拟「命令返回 0 但结果不对」这类最难发现的故障。

    new_env verifyfail
    reset_kernel
    candidate="$dir/candidate.json"
    make_candidate "$candidate"

    FAKE_NFT_CORRUPT_APPLY=1 txn_publish "$candidate" >/dev/null 2>&1
    assert_eq "应用后验证失败返回 5" "$?" "5"
    assert_eq "验证失败不更新状态文件" \
        "$(jq -r '.ports.tcp | index("8443") == null' "$FWCTL_STATE_FILE")" "true"

    # ── 提交失败：退出码 5，内核已回滚 ────────────────────────────────
    # 把持久化目标设成不可写的路径，触发提交阶段失败。

    new_env commitfail
    reset_kernel
    candidate="$dir/candidate.json"
    make_candidate "$candidate"
    saved_conf=$FWCTL_SYSTEM_CONF
    # 把本该是目录的位置做成普通文件，mkdir -p 必然失败，从而触发提交阶段失败。
    printf 'blocker\n' > "$dir/blocker"
    export FWCTL_SYSTEM_CONF="$dir/blocker/nftables.conf"

    txn_publish "$candidate" >/dev/null 2>&1
    rc=$?
    export FWCTL_SYSTEM_CONF=$saved_conf
    assert_eq "提交失败返回 5" "$rc" "5"
    assert_eq "提交失败不更新状态文件" \
        "$(jq -r '.ports.tcp | index("8443") == null' "$FWCTL_STATE_FILE")" "true"
fi

# ── 锁 ────────────────────────────────────────────────────────────────

new_env lock
reset_kernel
candidate="$dir/candidate.json"
make_candidate "$candidate"

# 在子 shell 里占住锁，模拟另一个事务正在进行。
(
    exec 9>"$FWCTL_LOCKFILE"
    flock -n 9
    sleep 5
) &
holder=$!
sleep 0.3

txn_publish_locked "$candidate" >/dev/null 2>&1
assert_eq "锁冲突返回 4 (lock)" "$?" "4"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

assert_ok "锁释放后可以正常获取" fwctl_lock_acquire
fwctl_lock_release

# ── 事务日志与崩溃恢复 ────────────────────────────────────────────────

new_env recover-applied
reset_kernel
candidate="$dir/candidate.json"
make_candidate "$candidate"
txn_publish "$candidate" >/dev/null 2>&1
baseline_rules=$(kernel_rule_count)
baseline_state=$(sha256sum "$FWCTL_STATE_FILE")

# 手工构造一个停在 applied 的 journal：内核已改、磁盘未改。
# 这正是进程在 apply 与 commit 之间被 kill 时留下的现场。
crash_candidate="$dir/crash.json"
model_port_update "$FWCTL_STATE_FILE" add tcp 9999 > "$crash_candidate"
crash_rendered="$dir/crash.nft"
render_ruleset "$crash_candidate" "$(txn_probe_facts "$crash_candidate")" > "$crash_rendered"
txn_snapshot "$(txn_rollback_path)" >/dev/null
"$FWCTL_NFT_BIN" -f "$crash_rendered" >/dev/null 2>&1
txn_journal_write applied \
    "candidate_nft=$crash_rendered" \
    "rollback_nft=$(txn_rollback_path)" \
    "table_existed=yes" \
    "adopts_legacy=" \
    "candidate_state_sha=$(sha256sum "$crash_candidate" | cut -d' ' -f1)"

# 加放行端口改变的是 set 元素而不是规则条数，因此按内容而不是条数判断。
assert_ok "崩溃现场：内核已含新端口" kernel_contains "9999"

txn_recover >/dev/null 2>&1
assert_eq "恢复返回 0" "$?" "0"
assert_eq "恢复后内核回到变更前的规则数" "$(kernel_rule_count)" "$baseline_rules"
assert_fails "恢复后新端口已从内核消失" 0 kernel_contains "9999"
assert_eq "恢复后状态文件未被改动" "$(sha256sum "$FWCTL_STATE_FILE")" "$baseline_state"
assert_eq "恢复后 journal 被清除" \
    "$([[ -f "$(txn_journal_path)" ]] && echo yes || echo no)" "no"

# 停在 applied 但状态已落盘 → 说明 commit 其实完成了，只差标记，应当补齐而非回滚。
new_env recover-committed
reset_kernel
candidate="$dir/candidate.json"
make_candidate "$candidate"
txn_publish "$candidate" >/dev/null 2>&1
committed_rules=$(kernel_rule_count)

txn_snapshot "$(txn_rollback_path)" >/dev/null
txn_journal_write applied \
    "candidate_nft=$dir/build/candidate.nft" \
    "rollback_nft=$(txn_rollback_path)" \
    "table_existed=yes" \
    "adopts_legacy=" \
    "candidate_state_sha=$(sha256sum "$FWCTL_STATE_FILE" | cut -d' ' -f1)"

txn_recover >/dev/null 2>&1
assert_eq "状态已落盘时恢复不回滚内核" "$(kernel_rule_count)" "$committed_rules"
assert_eq "补齐提交后 journal 被清除" \
    "$([[ -f "$(txn_journal_path)" ]] && echo yes || echo no)" "no"

# 停在 prepared → apply 尚未完成，恢复到变更前状态。
new_env recover-prepared
reset_kernel
candidate="$dir/candidate.json"
make_candidate "$candidate"
txn_publish "$candidate" >/dev/null 2>&1
prepared_rules=$(kernel_rule_count)
txn_snapshot "$(txn_rollback_path)" >/dev/null
txn_journal_write prepared \
    "candidate_nft=$dir/build/candidate.nft" \
    "rollback_nft=$(txn_rollback_path)" \
    "table_existed=yes" \
    "adopts_legacy=" \
    "candidate_state_sha=deadbeef"
txn_recover >/dev/null 2>&1
assert_eq "prepared 阶段恢复后规则数不变" "$(kernel_rule_count)" "$prepared_rules"
assert_eq "prepared 恢复后 journal 被清除" \
    "$([[ -f "$(txn_journal_path)" ]] && echo yes || echo no)" "no"

# 未知的更高 journal_version → 拒绝自动恢复，而不是按当前格式误解析。
new_env recover-future
mkdir -p "$FWCTL_VAR_DIR"
jq -n '{journal_version: 99, phase: "applied", rollback_nft: "/nonexistent"}' \
    > "$(txn_journal_path)"
output=$(txn_recover 2>&1)
rc=$?
assert_eq "未知 journal 版本拒绝恢复并返回 3" "$rc" "3"
assert_contains "拒绝理由说明版本过高" "$output" "高于本程序支持"
assert_eq "拒绝恢复时不删除 journal" \
    "$([[ -f "$(txn_journal_path)" ]] && echo yes)" "yes"
rm -f "$(txn_journal_path)"

# 损坏的 journal → 明确报错，不猜测。
new_env recover-corrupt
mkdir -p "$FWCTL_VAR_DIR"
printf 'not json' > "$(txn_journal_path)"
output=$(txn_recover 2>&1)
assert_eq "损坏的 journal 返回 3" "$?" "3"
assert_contains "损坏的 journal 明确报错" "$output" "事务日志损坏"
rm -f "$(txn_journal_path)"

# journal 带版本号，便于未来演进。
new_env journal-version
reset_kernel
candidate="$dir/candidate.json"
make_candidate "$candidate"
txn_journal_write prepared "rollback_nft=/tmp/x"
assert_eq "journal 写入版本号" \
    "$(jq -r '.journal_version' "$(txn_journal_path)")" "1"
assert_eq "journal 记录阶段" \
    "$(jq -r '.phase' "$(txn_journal_path)")" "prepared"
txn_journal_clear

# ── 旧表接管 ──────────────────────────────────────────────────────────

if [[ "${FWCTL_TEST_NETNS:-0}" != 1 ]]; then
    # 指纹匹配的旧表被接管并删除。
    new_env legacy-match
    reset_kernel
    legacy_conf="$dir/legacy.nft"
    cat > "$legacy_conf" <<'LEGACY'
table ip sb_filter {
    set blacklist {
        type ipv4_addr
        flags interval
    }
    set allowed_ports_tcp {
        type inet_service
        flags interval
    }
    set allowed_ports_udp {
        type inet_service
        flags interval
    }
    chain input {
        type filter hook input priority filter; policy drop;
        ip saddr @blacklist drop
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
    }
}
table ip sb_nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
    }
}
LEGACY
    "$FWCTL_NFT_BIN" -f "$legacy_conf" >/dev/null 2>&1

    assert_ok "旧表指纹被识别 (sb_filter)" txn_legacy_fingerprint_matches sb_filter
    assert_ok "旧表指纹被识别 (sb_nat)" txn_legacy_fingerprint_matches sb_nat
    assert_eq "探测到两张待接管的旧表" \
        "$(txn_legacy_tables "$FWCTL_STATE_FILE")" "sb_filter sb_nat"

    candidate="$dir/candidate.json"
    make_candidate "$candidate"
    txn_publish "$candidate" >/dev/null 2>&1
    assert_eq "接管后 sb_filter 已被删除" \
        "$("$FWCTL_NFT_BIN" list table ip sb_filter >/dev/null 2>&1 && echo yes || echo no)" "no"
    assert_eq "接管后 sb_nat 已被删除" \
        "$("$FWCTL_NFT_BIN" list table ip sb_nat >/dev/null 2>&1 && echo yes || echo no)" "no"
    assert_eq "接管完成后记录时间戳" \
        "$(jq -r '.metadata.legacy_adopted_at != null' "$FWCTL_STATE_FILE")" "true"
    assert_eq "已接管后不再重复探测" \
        "$(txn_legacy_tables "$FWCTL_STATE_FILE")" ""

    # 指纹不匹配的同名表必须保留，并持续告警。
    new_env legacy-mismatch
    reset_kernel
    foreign="$dir/foreign.nft"
    cat > "$foreign" <<'FOREIGN'
table ip sb_filter {
    chain someone_elses {
        type filter hook input priority filter; policy accept;
    }
}
FOREIGN
    "$FWCTL_NFT_BIN" -f "$foreign" >/dev/null 2>&1

    assert_fails "来源未知的同名表指纹不匹配" 0 \
        txn_legacy_fingerprint_matches sb_filter
    output=$(txn_legacy_tables "$FWCTL_STATE_FILE" 2>&1)
    assert_contains "不匹配时发出告警" "$output" "结构指纹不匹配"
    assert_not_contains "不匹配的表不进入接管清单" "$output" "sb_filter sb_nat"

    candidate="$dir/candidate.json"
    make_candidate "$candidate"
    txn_publish "$candidate" >/dev/null 2>&1
    assert_ok "来源未知的同名表未被删除" \
        "$FWCTL_NFT_BIN" list table ip sb_filter
    assert_eq "未接管时不写接管标记" \
        "$(jq -r '.metadata.legacy_adopted_at' "$FWCTL_STATE_FILE")" "null"

    # 接管过程中崩溃时，不得留下「已接管」的假标记。
    new_env legacy-crash
    reset_kernel
    "$FWCTL_NFT_BIN" -f "$legacy_conf" >/dev/null 2>&1
    candidate="$dir/candidate.json"
    make_candidate "$candidate"
    FAKE_NFT_FAIL_APPLY=1 txn_publish "$candidate" >/dev/null 2>&1
    assert_eq "接管失败时不写 legacy_adopted_at" \
        "$(jq -r '.metadata.legacy_adopted_at' "$FWCTL_STATE_FILE")" "null"
    assert_ok "接管失败后旧表仍在，下次可重试" \
        "$FWCTL_NFT_BIN" list table ip sb_filter
fi

# ── 只读路径不获取写锁 ────────────────────────────────────────────────

new_env readonly
reset_kernel
(
    exec 9>"$FWCTL_LOCKFILE"
    flock -n 9
    sleep 3
) &
holder=$!
sleep 0.3
assert_ok "持锁期间仍可执行只读校验" state_validate "$FWCTL_STATE_FILE"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

# ── dry-run 不改变任何东西 ────────────────────────────────────────────

new_env dryrun
reset_kernel
candidate="$dir/candidate.json"
make_candidate "$candidate"
before_state=$(sha256sum "$FWCTL_STATE_FILE")

FWCTL_DRY_RUN=1 txn_publish "$candidate" >/dev/null 2>&1
assert_eq "dry-run 返回 0" "$?" "0"
assert_fails "dry-run 不触碰内核" 0 kernel_has_table
assert_eq "dry-run 不修改状态文件" "$(sha256sum "$FWCTL_STATE_FILE")" "$before_state"
assert_eq "dry-run 不写持久化配置" \
    "$([[ -f "$FWCTL_SYSTEM_CONF" ]] && echo yes || echo no)" "no"
assert_eq "dry-run 不留 journal" \
    "$([[ -f "$(txn_journal_path)" ]] && echo yes || echo no)" "no"

# ── ip_forward 只开不关 ───────────────────────────────────────────────

new_env forward
# 无转发规则时不应触碰 ip_forward。
no_forward="$dir/no-forward.json"
jq '.rules |= map(select(.type != "forward"))' "$FWCTL_STATE_FILE" > "$no_forward"
assert_eq "没有转发规则时不修改 ip_forward" \
    "$(FWCTL_SKIP_SYSTEM_SETUP=0 txn_ip_forward_ensure "$no_forward" 2>/dev/null; echo "rc=$?")" \
    "rc=0"

# 删除最后一条转发规则不会关闭 ip_forward——它是全机共享开关，
# Docker 或 WireGuard 可能正依赖它。
assert_not_contains "实现中不存在关闭 ip_forward 的代码路径" \
    "$(grep -c 'ip_forward=0' "$TEST_PROJECT_DIR/core/transaction.sh")" "1"

# ── 真实内核上的回滚 ──────────────────────────────────────────────────
#
# 上面的失败注入依赖 fake-nft，真实 nft 无法被这样驱动。但回滚本身可以在真实
# 内核上直接验证：应用 A → 快照 → 应用 B → 重放快照 → 断言内核回到 A。
# 这条路径不需要注入失败，因此在两种后端下都能跑，也是「回滚确实有效」这一
# 安全关键行为的唯一真实证据。

new_env rollback-real
reset_kernel

state_a="$dir/a.json"
make_candidate "$state_a" 7001
txn_publish "$state_a" >/dev/null 2>&1
assert_ok "应用状态 A 成功" kernel_has_table
assert_ok "内核含有 A 的端口" kernel_contains "7001"
rules_a=$(kernel_rule_count)

# 事务前快照。
snapshot_real="$dir/rollback-a.nft"
existed=$(txn_snapshot "$snapshot_real")
assert_eq "快照记录表此前存在" "$existed" "yes"

state_b="$dir/b.json"
model_port_update "$FWCTL_STATE_FILE" add tcp 7002 > "$state_b"
rendered_b="$dir/b.nft"
render_ruleset "$state_b" "$(txn_probe_facts "$state_b")" > "$rendered_b"
"$FWCTL_NFT_BIN" -f "$rendered_b" >/dev/null 2>&1
assert_ok "应用状态 B 后内核含有 B 的端口" kernel_contains "7002"

assert_ok "重放快照" txn_rollback "$snapshot_real"
assert_ok "回滚后内核恢复 A 的端口" kernel_contains "7001"
assert_fails "回滚后 B 的端口已消失" 0 kernel_contains "7002"
assert_eq "回滚后规则条数与 A 一致" "$(kernel_rule_count)" "$rules_a"

# 重放是幂等的：再放一次结果不变，不会把规则叠加成两份。
assert_ok "再次重放快照" txn_rollback "$snapshot_real"
assert_eq "重复重放不叠加规则" "$(kernel_rule_count)" "$rules_a"

# 表此前不存在时，回滚等于把表删掉。
new_env rollback-real-absent
reset_kernel
snapshot_absent="$dir/rollback-absent.nft"
existed=$(txn_snapshot "$snapshot_absent")
assert_eq "表不存在时快照如实记录" "$existed" "no"

candidate="$dir/candidate.json"
make_candidate "$candidate" 7003
txn_publish "$candidate" >/dev/null 2>&1
assert_ok "应用后表存在" kernel_has_table

assert_ok "重放「表不存在」快照" txn_rollback "$snapshot_absent"
assert_fails "回滚后表被删除" 0 kernel_has_table

if [[ "${FWCTL_TEST_NETNS:-0}" != 1 ]]; then
    printf '# 提示：以 root 运行 FWCTL_TEST_NETNS=1 可让本套件在真实内核上验证回滚与恢复\n'
fi

finish
