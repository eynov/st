#!/bin/bash
# core/transaction.sh —— 事务层
#
# 职责：候选 → 校验 → 渲染 → nft -c → 快照 → journal → apply → 验证 → commit，
#       以及分阶段回滚与崩溃恢复。
#
# 依赖：core/common.sh、core/state.sh、core/render.sh
# 用法：本文件只能被 source，不能直接执行。
#
# 这是**唯一**允许调用 `nft -f` 和写 /etc/nftables.conf 的模块。其他任何模块都
# 不得改变内核状态。见 docs/adr/0003-single-transaction-boundary.md。

[[ -n "${FWCTL_TRANSACTION_LOADED:-}" ]] && return 0
FWCTL_TRANSACTION_LOADED=1

# journal 格式版本。从第一天起就带版本号，未来演进不会与旧日志产生歧义；
# 恢复逻辑遇到更高版本时拒绝自动恢复，而不是按当前格式误解析。
declare -rx FWCTL_JOURNAL_VERSION=1

# ── 路径 ──────────────────────────────────────────────────────────────

txn_var_dir()      { printf '%s\n' "${FWCTL_VAR_DIR:-/var/lib/fwctl}"; }
txn_journal_path() { printf '%s/journal.json\n' "$(txn_var_dir)"; }
txn_rollback_path(){ printf '%s/rollback.nft\n' "$(txn_var_dir)"; }
txn_system_conf()  { printf '%s\n' "${FWCTL_SYSTEM_CONF:-/etc/nftables.conf}"; }
txn_build_dir()    { printf '%s\n' "${FWCTL_BUILD_DIR:-$(txn_var_dir)/build}"; }
txn_nft_bin()      { printf '%s\n' "${FWCTL_NFT_BIN:-nft}"; }

# ── 外部事实探测 ──────────────────────────────────────────────────────
# 探测结果作为参数传给渲染层，渲染因此保持为纯函数。

# 列出本机 IPv4 地址。
txn_local_ipv4s() {
    if [[ -n "${FWCTL_LOCAL_IPV4S:-}" ]]; then
        tr ' ,' '\n' <<< "$FWCTL_LOCAL_IPV4S" | sed '/^$/d'
    else
        ip -4 -o addr show 2>/dev/null | awk '{split($4, a, "/"); print a[1]}'
    fi
}

# 探测公网 IPv4。失败时输出空——调用方据此安全回退到 masquerade。
txn_public_ipv4() {
    local candidate="" endpoint
    if [[ -n "${FWCTL_PUBLIC_IPV4:-}" ]]; then
        printf '%s\n' "$FWCTL_PUBLIC_IPV4"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || return 0
    for endpoint in \
        https://api.ip.sb/ip \
        https://ifconfig.me \
        https://api.ipify.org \
        https://ip4.seeip.org; do
        candidate=$(curl -fsS4 -m 5 "$endpoint" 2>/dev/null || true)
        candidate=${candidate//$'\n'/}
        fwctl_is_ipv4 "$candidate" && { printf '%s\n' "$candidate"; return 0; }
        candidate=""
    done
    return 0
}

# 探测 SSH 端口。顺序与旧实现一致：运行中的 sshd、sshd_config、默认 22。
txn_ssh_port() {
    local port="${FWCTL_SSH_PORT:-}"
    if [[ -z "$port" ]]; then
        port=$(ss -tlnp 2>/dev/null | awk '/sshd/ {sub(/^.*:/, "", $4); print $4; exit}')
    fi
    if [[ -z "$port" && -r /etc/ssh/sshd_config ]]; then
        port=$(awk '/^[[:space:]]*Port[[:space:]]/ {print $2; exit}' /etc/ssh/sshd_config)
    fi
    [[ -n "$port" ]] || port=22
    if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
        fwctl_err "无法确定合法的 SSH 端口：$port"
        return 1
    fi
    printf '%s\n' "$port"
}

# 判断一张遗留表是否确实属于旧版 fwctl。
#
# 同名不等于同源：删掉别人的表比留着一张废表严重得多，因此只有结构指纹完全
# 吻合才接管。见 docs/adr/0002-own-table-no-flush.md。
# 参数：$1=表名。返回：0 指纹匹配；1 不匹配或表不存在。
txn_legacy_fingerprint_matches() {
    local table=$1 listing marker

    listing=$("$(txn_nft_bin)" list table ip "$table" 2>/dev/null) || return 1

    case "$table" in
        sb_filter)
            for marker in 'chain input' 'chain forward' 'set blacklist' \
                'set allowed_ports_tcp' 'set allowed_ports_udp'; do
                grep -q "$marker" <<< "$listing" || return 1
            done
            grep -q 'type filter hook input' <<< "$listing" || return 1
            ;;
        sb_nat)
            for marker in 'chain prerouting' 'chain postrouting'; do
                grep -q "$marker" <<< "$listing" || return 1
            done
            grep -q 'type nat hook prerouting' <<< "$listing" || return 1
            grep -q 'type nat hook postrouting' <<< "$listing" || return 1
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# 列出本次应当接管的遗留表。
# 已经接管过（metadata.legacy_adopted_at 非空）就不再探测。
# 参数：$1=状态文件。输出：空格分隔的表名。
txn_legacy_tables() {
    local state=$1 adopted table found=()

    adopted=$(jq -r '.metadata.legacy_adopted_at // empty' "$state" 2>/dev/null)
    [[ -n "$adopted" ]] && return 0

    for table in sb_filter sb_nat; do
        if txn_legacy_fingerprint_matches "$table"; then
            found+=("$table")
        elif "$(txn_nft_bin)" list table ip "$table" >/dev/null 2>&1; then
            fwctl_warn "存在同名表 $table 但结构指纹不匹配，判定为来源未知，不予删除"
            fwctl_warn "确认它确实属于旧版 fwctl 时，可用 --adopt-legacy --force 强制接管"
        fi
    done

    ((${#found[@]} > 0)) && printf '%s\n' "${found[*]}"
    return 0
}

# 汇总全部外部事实。
# 参数：$1=状态文件。输出：外部事实 JSON。
txn_probe_facts() {
    local state=$1 ssh_port locals public legacy

    ssh_port=$(txn_ssh_port) || return 1
    locals=$(txn_local_ipv4s | paste -sd' ')
    public=$(txn_public_ipv4)
    legacy=$(txn_legacy_tables "$state")

    render_facts "$ssh_port" "$locals" "$public" "$legacy"
}

# ── 内核快照与回滚 ────────────────────────────────────────────────────

# 把当前运行中的 fwctl 表快照成一份可重放的配置。
#
# 快照取自内核而不是磁盘：即使 /etc/nftables.conf 已被手工改坏，回滚依然能把
# 内核恢复到事务前的真实状态。
# 参数：$1=输出路径。输出到 stdout：表在事务前是否存在（yes/no）。
txn_snapshot() {
    local out=$1 listing

    if listing=$("$(txn_nft_bin)" list table ip "$FWCTL_TABLE" 2>/dev/null); then
        {
            printf 'table ip %s { }\n' "$FWCTL_TABLE"
            printf 'delete table ip %s\n' "$FWCTL_TABLE"
            printf '%s\n' "$listing"
        } > "$out" || return 1
        printf 'yes\n'
    else
        # 表此前不存在：回滚就是把它删掉。
        {
            printf 'table ip %s { }\n' "$FWCTL_TABLE"
            printf 'delete table ip %s\n' "$FWCTL_TABLE"
        } > "$out" || return 1
        printf 'no\n'
    fi
    return 0
}

# 重放回滚快照。
# 参数：$1=快照路径。
txn_rollback() {
    local snapshot=$1
    if [[ ! -f "$snapshot" ]]; then
        fwctl_err "回滚失败：找不到快照 $snapshot"
        return 1
    fi
    if ! "$(txn_nft_bin)" -f "$snapshot"; then
        fwctl_err "回滚失败：无法重放 $snapshot"
        fwctl_err "内核规则可能处于不确定状态，请人工检查 nft list ruleset"
        return 1
    fi
    return 0
}

# ── 事务日志 ──────────────────────────────────────────────────────────

# 写入或更新 journal。
# 参数：$1=阶段，其余为 key=value 形式的附加字段。
txn_journal_write() {
    local phase=$1
    shift
    local path now tmp extra="{}" kv key value

    path=$(txn_journal_path)
    now=$(fwctl_now) || return 1
    mkdir -p "$(dirname "$path")" || return 1

    for kv in "$@"; do
        key=${kv%%=*}
        value=${kv#*=}
        extra=$(jq --arg k "$key" --arg v "$value" '.[$k] = $v' <<< "$extra") || return 1
    done

    tmp=$(fwctl_mktemp_beside "$path") || return 1
    if ! jq -n \
        --argjson version "$FWCTL_JOURNAL_VERSION" \
        --arg phase "$phase" \
        --arg at "$now" \
        --argjson extra "$extra" \
        '{journal_version: $version, phase: $phase, updated_at: $at} + $extra' \
        > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    fwctl_atomic_install "$tmp" "$path" 0600
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}

# 合并字段到已有 journal（保留原有内容）。
txn_journal_update_phase() {
    local phase=$1 path tmp now
    path=$(txn_journal_path)
    [[ -f "$path" ]] || return 0
    now=$(fwctl_now) || return 1
    tmp=$(fwctl_mktemp_beside "$path") || return 1
    if ! jq --arg phase "$phase" --arg at "$now" \
        '.phase = $phase | .updated_at = $at' "$path" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    fwctl_atomic_install "$tmp" "$path" 0600
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}

txn_journal_clear() {
    rm -f "$(txn_journal_path)"
}

# 崩溃恢复：收敛处于非终态的 journal。
#
# 覆盖的是进程在 apply 与 commit 之间被 kill / OOM / 断电的窗口——那种情况下
# 内核已改而磁盘未改，退出路径上的回滚代码根本没有机会执行。
#
# 任何 fwctl 命令启动时都应先调用一次。
txn_recover() {
    local path version phase rollback candidate_sha state_sha state

    path=$(txn_journal_path)
    [[ -f "$path" ]] || return 0

    if ! jq empty "$path" >/dev/null 2>&1; then
        fwctl_err "事务日志损坏：$path"
        fwctl_err "请人工检查 nft list ruleset 与 state.json 是否一致后删除该文件"
        return "$FWCTL_EXIT_RUNTIME"
    fi

    version=$(jq -r '.journal_version // 0' "$path")
    if ((version > FWCTL_JOURNAL_VERSION)); then
        fwctl_err "事务日志版本 $version 高于本程序支持的 $FWCTL_JOURNAL_VERSION"
        fwctl_err "拒绝自动恢复：按当前格式解析可能做出错误的回滚决定"
        fwctl_err "请升级 fwctl 后重试"
        return "$FWCTL_EXIT_RUNTIME"
    fi

    phase=$(jq -r '.phase // ""' "$path")
    rollback=$(jq -r '.rollback_nft // ""' "$path")
    candidate_sha=$(jq -r '.candidate_state_sha // ""' "$path")
    state="${FWCTL_STATE_FILE:-}"

    case "$phase" in
        committed|"")
            txn_journal_clear
            return 0
            ;;
        prepared)
            # apply 尚未开始或未完成，内核应当仍是事务前的状态。
            # 重放快照是幂等的，做一次以确保确定性。
            fwctl_warn "发现未完成的事务（阶段 prepared），正在恢复到变更前状态"
            if [[ -n "$rollback" && -f "$rollback" ]]; then
                txn_rollback "$rollback" || return "$FWCTL_EXIT_RUNTIME"
            fi
            txn_journal_clear
            fwctl_ok "已恢复到变更前状态，未提交任何变更"
            return 0
            ;;
        applied)
            # 内核已改。磁盘是否也改了，用状态文件的校验和判断。
            state_sha=""
            [[ -n "$state" && -f "$state" ]] && state_sha=$(sha256sum "$state" | cut -d' ' -f1)

            if [[ -n "$candidate_sha" && "$state_sha" == "$candidate_sha" ]]; then
                # 状态已落盘，说明 commit 实际上完成了，只是没来得及标记。
                fwctl_warn "发现未完成的事务（阶段 applied），状态已落盘，补齐提交标记"
                txn_journal_clear
                fwctl_ok "事务已完成"
                return 0
            fi

            fwctl_warn "发现未完成的事务（阶段 applied），内核已变更但状态未落盘"
            fwctl_warn "正在回滚内核规则"
            if [[ -n "$rollback" && -f "$rollback" ]]; then
                txn_rollback "$rollback" || return "$FWCTL_EXIT_RUNTIME"
            else
                fwctl_err "缺少回滚快照，无法自动恢复"
                return "$FWCTL_EXIT_RUNTIME"
            fi
            txn_journal_clear
            fwctl_ok "已回滚到变更前状态"
            return 0
            ;;
        *)
            fwctl_err "无法识别的事务阶段：$phase"
            return "$FWCTL_EXIT_RUNTIME"
            ;;
    esac
}

# ── ip_forward ────────────────────────────────────────────────────────

# 按需开启 IPv4 转发。
#
# **只开不关。** net.ipv4.ip_forward 是全机共享的内核开关，Docker、WireGuard
# 或任何其他转发用户都可能正依赖它；fwctl 无法确认自己是唯一使用者，因此关闭
# 它就是拿别人的服务冒险。删除最后一条转发规则时不做任何事。
# 见 docs/adr/0005-scope-boundary.md。
#
# 参数：$1=候选状态文件。输出：原值（仅在本次确实修改时输出）。
txn_ip_forward_ensure() {
    local state=$1 needs current

    [[ "${FWCTL_SKIP_SYSTEM_SETUP:-0}" == 1 ]] && return 0

    needs=$(jq -r '[.rules[] | select(.enabled and .type == "forward")] | length' "$state")
    ((needs > 0)) || return 0

    current=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "")
    [[ "$current" == 0 ]] || return 0

    if ! sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
        fwctl_err "无法开启 net.ipv4.ip_forward，端口转发不会生效"
        return 1
    fi
    printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-fwctl-forward.conf 2>/dev/null || true
    fwctl_info "已开启 net.ipv4.ip_forward（原值 0）；fwctl 不会自动关闭它"
    printf '0\n'
    return 0
}

# ── 应用后验证 ────────────────────────────────────────────────────────

# 确认内核里的表确实是刚刚渲染出来的那份。
# 参数：$1=渲染产物路径。
txn_verify_applied() {
    local rendered=$1 listing expected actual chain

    if ! listing=$("$(txn_nft_bin)" list table ip "$FWCTL_TABLE" 2>/dev/null); then
        fwctl_err "应用后验证失败：找不到 table ip $FWCTL_TABLE"
        return 1
    fi

    for chain in input forward prerouting postrouting; do
        grep -q "chain $chain" <<< "$listing" || {
            fwctl_err "应用后验证失败：缺少 chain $chain"
            return 1
        }
    done

    # 规则条数以 comment 为准：每条由对象生成的规则都带 fwctl: 前缀。
    expected=$(grep -c 'comment "fwctl:' "$rendered" || true)
    actual=$(grep -c 'comment "fwctl:' <<< "$listing" || true)
    if [[ "$expected" != "$actual" ]]; then
        fwctl_err "应用后验证失败：规则条数不符（期望 $expected，实际 $actual）"
        return 1
    fi

    return 0
}

# ── 事务主流程 ────────────────────────────────────────────────────────

# 把候选状态发布出去。
#
# 参数：$1=候选状态文件（调用方已在其上应用了变更）。
# 选项（环境变量）：
#   FWCTL_DRY_RUN=1   走到 nft -c 为止，不 apply、不 commit
#   FWCTL_APPLY=0     渲染并检查，但不触碰内核（兼容旧入口的 --render-only）
#
# 返回：docs/CLI.md 冻结的退出码。
# 对外入口：执行发布并保证清理候选渲染产物。
#
# 内部实现有十几个返回点，逐个 rm 容易漏。这里统一包一层：无论成功还是失败，
# 都删掉 build/candidate.nft。失败回滚之后留下一份从未生效的渲染结果，会让人
# 误以为它就是当前生效的配置——已发布的配置在 build/nft.conf 与系统配置里。
# 参数：$1=候选状态文件。
txn_publish() {
    local rc
    _txn_publish_impl "$@"
    rc=$?
    rm -f "$(txn_build_dir)/candidate.nft"
    return "$rc"
}

_txn_publish_impl() {
    local candidate=$1
    local facts rendered snapshot table_existed build_dir system_conf
    local state="${FWCTL_STATE_FILE:?FWCTL_STATE_FILE 未设置}"
    local rc original_forward candidate_sha legacy now

    build_dir=$(txn_build_dir)
    system_conf=$(txn_system_conf)
    mkdir -p "$build_dir" "$(txn_var_dir)" || {
        fwctl_err "无法创建工作目录"
        return "$FWCTL_EXIT_RUNTIME"
    }

    rendered="$build_dir/candidate.nft"
    snapshot=$(txn_rollback_path)

    # ── 校验 ──
    facts=$(txn_probe_facts "$candidate") || return "$FWCTL_EXIT_RUNTIME"
    if ! state_validate "$candidate" "$facts"; then
        return "$FWCTL_EXIT_VALIDATION"
    fi

    # ── 渲染 ──
    if ! render_ruleset "$candidate" "$facts" > "$rendered"; then
        fwctl_err "渲染失败"
        rm -f "$rendered"
        return "$FWCTL_EXIT_RUNTIME"
    fi

    # ── 语法检查 ──
    if ! "$(txn_nft_bin)" -c -f "$rendered"; then
        fwctl_err "nft 语法检查未通过，未做任何变更"
        return "$FWCTL_EXIT_RUNTIME"
    fi

    if [[ "${FWCTL_DRY_RUN:-0}" == 1 || "${FWCTL_APPLY:-1}" == 0 ]]; then
        fwctl_ok "配置已生成并通过语法检查（未加载）"
        return "$FWCTL_EXIT_OK"
    fi

    # ── 快照 ──
    table_existed=$(txn_snapshot "$snapshot") || {
        fwctl_err "无法创建回滚快照"
        return "$FWCTL_EXIT_RUNTIME"
    }

    candidate_sha=$(sha256sum "$candidate" | cut -d' ' -f1)
    legacy=$(jq -r '.legacy_tables | join(" ")' <<< "$facts")

    # ── journal ──
    txn_journal_write prepared \
        "candidate_nft=$rendered" \
        "rollback_nft=$snapshot" \
        "table_existed=$table_existed" \
        "adopts_legacy=$legacy" \
        "candidate_state_sha=$candidate_sha" || {
        fwctl_err "无法写入事务日志"
        return "$FWCTL_EXIT_RUNTIME"
    }

    # ── 应用 ──
    if ! "$(txn_nft_bin)" -f "$rendered"; then
        fwctl_err "规则加载失败，正在回滚"
        txn_rollback "$snapshot"
        txn_journal_clear
        return "$FWCTL_EXIT_ROLLBACK"
    fi
    txn_journal_update_phase applied

    # ── 应用后验证 ──
    if ! txn_verify_applied "$rendered"; then
        fwctl_err "正在回滚"
        txn_rollback "$snapshot"
        txn_journal_clear
        return "$FWCTL_EXIT_ROLLBACK"
    fi

    # ── ip_forward ──
    original_forward=$(txn_ip_forward_ensure "$candidate") || {
        fwctl_err "正在回滚"
        txn_rollback "$snapshot"
        txn_journal_clear
        return "$FWCTL_EXIT_ROLLBACK"
    }

    # ── 提交 ──
    # 顺序：先落盘派生数据，最后写 state.json。state.json 是事实来源，
    # 它写成功即表示整个事务完成，崩溃恢复据此判断 commit 是否真的结束。
    now=$(fwctl_now)
    if [[ -n "$original_forward" ]]; then
        local tmp_meta
        tmp_meta=$(fwctl_mktemp_beside "$candidate") || return "$FWCTL_EXIT_RUNTIME"
        jq --arg now "$now" --arg original "$original_forward" '
            .metadata.ip_forward = {
                changed_by_fwctl: true,
                original_value: $original,
                changed_at: $now
            }' "$candidate" > "$tmp_meta" && mv -f "$tmp_meta" "$candidate"
    fi

    # legacy_adopted_at 只在 apply 成功之后写入：在 apply 之前预写的话，
    # 一次失败的首次迁移会让旧表永久失去被接管的机会。
    if [[ -n "$legacy" ]]; then
        local tmp_legacy
        tmp_legacy=$(fwctl_mktemp_beside "$candidate") || return "$FWCTL_EXIT_RUNTIME"
        jq --arg now "$now" '.metadata.legacy_adopted_at = $now' "$candidate" \
            > "$tmp_legacy" && mv -f "$tmp_legacy" "$candidate"
        fwctl_info "已接管并删除遗留表：$legacy"
    fi

    local tmp_applied
    tmp_applied=$(fwctl_mktemp_beside "$candidate") || return "$FWCTL_EXIT_RUNTIME"
    jq --arg now "$now" '
        .metadata.last_applied_at = $now
        | .metadata.updated_at = $now
        | .metadata.generation = ((.metadata.generation // 0) + 1)
    ' "$candidate" > "$tmp_applied" && mv -f "$tmp_applied" "$candidate"

    candidate_sha=$(state_normalize "$candidate" | sha256sum | cut -d' ' -f1)

    if ! fwctl_atomic_install "$rendered" "$system_conf" 0644; then
        fwctl_err "无法写入 $system_conf，正在回滚"
        txn_rollback "$snapshot"
        txn_journal_clear
        return "$FWCTL_EXIT_ROLLBACK"
    fi
    if ! fwctl_atomic_install "$rendered" "$build_dir/nft.conf" 0644; then
        fwctl_err "无法写入 $build_dir/nft.conf，正在回滚"
        txn_rollback "$snapshot"
        txn_journal_clear
        return "$FWCTL_EXIT_ROLLBACK"
    fi
    if ! state_write "$candidate" "$state"; then
        fwctl_err "无法写入状态文件，正在回滚"
        txn_rollback "$snapshot"
        txn_journal_clear
        return "$FWCTL_EXIT_ROLLBACK"
    fi

    txn_journal_update_phase committed
    txn_journal_clear

    if [[ "${FWCTL_SKIP_SYSTEM_SETUP:-0}" != 1 ]]; then
        systemctl enable nftables >/dev/null 2>&1 || true
    fi

    rc=$FWCTL_EXIT_OK
    return "$rc"
}

# 在全局写锁内执行一次发布。
#
# 这是所有写路径的统一入口：CLI 的写动词、render 兼容入口、restore、迁移落盘
# 都走这里，因此它们共享同一个互斥边界与同一套回滚语义。
#
# 参数：$1=候选状态文件。
txn_publish_locked() {
    local candidate=$1 rc

    fwctl_lock_acquire || return $?

    txn_recover
    rc=$?
    if ((rc != 0)); then
        fwctl_lock_release
        return "$rc"
    fi

    txn_publish "$candidate"
    rc=$?

    fwctl_lock_release
    return "$rc"
}
