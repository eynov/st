#!/bin/bash
# core/doctor.sh —— 环境与一致性体检
#
# 职责：逐项检查依赖、权限、内核、状态、事务、转发、自锁风险、遗留表、漂移、
#       持久化、对象卫生与安全建议。
#
# 依赖：core/common.sh、core/state.sh、core/render.sh、core/transaction.sh
# 用法：本文件只能被 source，不能直接执行。
#
# 只读模块：**只报告，绝不自动修改**。安全默认值的建议尤其如此——防火墙语义的
# 变更必须由用户显式发起，见 docs/adr/0005-scope-boundary.md。

[[ -n "${FWCTL_DOCTOR_LOADED:-}" ]] && return 0
FWCTL_DOCTOR_LOADED=1

DOCTOR_FAIL=0
DOCTOR_WARN=0
DOCTOR_ROWS=()

# 记录一项检查结果。
# 参数：$1=OK|WARN|FAIL，$2=检查项，$3=说明。
_doctor_row() {
    local status=$1 name=$2 detail=$3
    case "$status" in
        FAIL) DOCTOR_FAIL=$((DOCTOR_FAIL + 1)) ;;
        WARN) DOCTOR_WARN=$((DOCTOR_WARN + 1)) ;;
    esac
    DOCTOR_ROWS+=("$status"$'\t'"$name"$'\t'"$detail")
}

# 执行全部检查。
# 参数：$1=状态文件（已迁移到当前 schema）。
doctor_run() {
    local state=$1
    local command missing="" facts rendered listing conf

    DOCTOR_FAIL=0
    DOCTOR_WARN=0
    DOCTOR_ROWS=()

    # 1. 依赖
    for command in nft jq flock; do
        command -v "$command" >/dev/null 2>&1 || missing="$missing $command"
    done
    if [[ -n "$missing" ]]; then
        _doctor_row FAIL "依赖" "缺少：$missing"
    else
        _doctor_row OK "依赖" "nft、jq、flock 均可用"
    fi

    # 2. 权限
    if [[ $EUID -eq 0 ]]; then
        _doctor_row OK "权限" "以 root 运行"
    else
        _doctor_row FAIL "权限" "需要 root 才能读写 nftables"
    fi

    # 3. 内核
    if "$(txn_nft_bin)" list tables >/dev/null 2>&1; then
        _doctor_row OK "内核" "nftables 可用"
    else
        _doctor_row FAIL "内核" "无法执行 nft list tables"
    fi

    # 4. 状态
    if state_validate "$state" '{"offline":true}' >/dev/null 2>&1; then
        _doctor_row OK "状态" "schema 与语义校验通过"
    else
        _doctor_row FAIL "状态" "校验未通过，执行 fw validate 查看详情"
    fi

    # 5. 迁移
    if [[ -f "${FWCTL_STATE_FILE:-}" ]] && migration_is_legacy "${FWCTL_STATE_FILE}"; then
        _doctor_row WARN "迁移" "磁盘上仍是旧格式，下次写操作时会自动升级"
    else
        _doctor_row OK "迁移" "已是当前 schema"
    fi

    # 6. 事务
    if [[ -f "$(txn_journal_path)" ]]; then
        _doctor_row WARN "事务" "存在未完成的事务日志，下次执行任意命令时会自动收敛"
    else
        _doctor_row OK "事务" "没有未完成的事务"
    fi

    # 7. 转发开关
    local needs_forward current_forward
    needs_forward=$(jq -r '[.rules[] | select(.enabled and .type == "forward")] | length' "$state")
    current_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "?")
    if ((needs_forward > 0)) && [[ "$current_forward" == 0 ]]; then
        _doctor_row FAIL "转发" "存在启用的转发规则但 ip_forward=0，转发不会生效"
    elif ((needs_forward == 0)) && [[ "$current_forward" == 1 ]]; then
        local changed
        changed=$(jq -r '.metadata.ip_forward.changed_by_fwctl // false' "$state")
        if [[ "$changed" == true ]]; then
            local original
            original=$(jq -r '.metadata.ip_forward.original_value // "0"' "$state")
            _doctor_row WARN "转发" \
                "ip_forward 由 fwctl 开启（原值 $original），现已无转发规则；fwctl 不会自动关闭它，因为 Docker/WireGuard 等可能正依赖它。确需恢复：sysctl -w net.ipv4.ip_forward=$original 并删除 /etc/sysctl.d/99-fwctl-forward.conf"
        else
            _doctor_row OK "转发" "ip_forward=1，非 fwctl 修改"
        fi
    else
        _doctor_row OK "转发" "ip_forward=$current_forward，与当前规则相符"
    fi

    # 8. SSH 自锁风险
    local ssh_port
    if ssh_port=$(txn_ssh_port 2>/dev/null); then
        if jq -e --arg p "$ssh_port" \
            '(.settings.policy.input == "accept")
             or ((.ports.tcp // []) | index($p) != null)' "$state" >/dev/null; then
            _doctor_row OK "SSH" "端口 $ssh_port 已被放行"
        else
            # 渲染始终为探测到的 SSH 端口生成一条独立放行规则，因此这不是故障。
            _doctor_row OK "SSH" "端口 $ssh_port 由内建规则放行"
        fi
    else
        _doctor_row WARN "SSH" "无法确定 SSH 端口，请用 FWCTL_SSH_PORT 显式指定"
    fi

    # 9. 遗留表
    local legacy_found="" table
    for table in sb_filter sb_nat; do
        "$(txn_nft_bin)" list table ip "$table" >/dev/null 2>&1 || continue
        if txn_legacy_fingerprint_matches "$table"; then
            legacy_found="$legacy_found $table(指纹匹配)"
        else
            legacy_found="$legacy_found $table(来源未知)"
        fi
    done
    if [[ -n "$legacy_found" ]]; then
        _doctor_row WARN "遗留表" \
            "仍存在：$legacy_found；指纹匹配的会在下次写操作时接管删除，来源未知的不会被删除"
    else
        _doctor_row OK "遗留表" "没有 sb_filter / sb_nat"
    fi

    # 10. 漂移
    facts=$(txn_probe_facts "$state" 2>/dev/null) || facts=""
    if [[ -n "$facts" ]]; then
        rendered=$(mktemp)
        if render_ruleset "$state" "$facts" > "$rendered" 2>/dev/null; then
            if listing=$("$(txn_nft_bin)" list table ip "$FWCTL_TABLE" 2>/dev/null); then
                local expected actual
                expected=$(grep -c 'comment "fwctl:' "$rendered" || true)
                actual=$(grep -c 'comment "fwctl:' <<< "$listing" || true)
                if [[ "$expected" == "$actual" ]]; then
                    _doctor_row OK "漂移" "运行中的规则数与当前状态一致（$actual 条）"
                else
                    _doctor_row WARN "漂移" \
                        "运行中 $actual 条，状态应为 $expected 条；执行 fw diff 查看差异"
                fi
            else
                _doctor_row WARN "漂移" "运行中不存在 table ip $FWCTL_TABLE；执行 fw render 应用"
            fi

            # 11. 持久化
            conf=$(txn_system_conf)
            if [[ -f "$conf" ]]; then
                if cmp -s "$rendered" "$conf"; then
                    _doctor_row OK "持久化" "$conf 与当前状态一致"
                else
                    _doctor_row WARN "持久化" "$conf 与当前状态不一致；执行 fw render 重新发布"
                fi
            else
                _doctor_row WARN "持久化" "$conf 不存在，重启后规则不会恢复"
            fi
        else
            _doctor_row FAIL "漂移" "当前状态无法渲染"
        fi
        rm -f "$rendered"
    else
        _doctor_row WARN "漂移" "无法探测外部事实，跳过漂移检查"
    fi

    # 12. 其他 input hook
    # 不再 flush 整机规则之后，其他表的 input 规则会真正保留下来，
    # 而 nftables 会评估所有 chain，任一 drop 生效。
    local other_tables
    other_tables=$("$(txn_nft_bin)" list tables 2>/dev/null |
        awk '{print $NF}' | grep -vx "$FWCTL_TABLE" | paste -sd' ' || true)
    if [[ -n "$other_tables" ]]; then
        _doctor_row WARN "其他表" \
            "同机还存在：$other_tables；nftables 会评估所有 chain，任一 drop 生效"
    else
        _doctor_row OK "其他表" "没有其他 nftables 表"
    fi

    # 13. 对象卫生
    local warnings
    warnings=$(state_warnings "$state")
    if [[ -n "$warnings" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && _doctor_row WARN "对象" "$line"
        done <<< "$warnings"
    else
        _doctor_row OK "对象" "没有孤儿 Service 或重复 Target"
    fi

    # 14. 安全建议（只建议，绝不自动修改）
    local suggestions=""
    [[ "$(jq -r '.settings.policy.ct_invalid' "$state")" == "ignore" ]] &&
        suggestions="${suggestions}ct_invalid=drop（丢弃无效连接状态的包）；"
    [[ "$(jq -r '.settings.policy.icmp_echo' "$state")" == "drop" ]] &&
        suggestions="${suggestions}icmp_echo=limit（限速放行 ping，便于排障）；"
    if [[ -n "$suggestions" ]]; then
        _doctor_row WARN "安全建议" \
            "当前沿用旧版本默认值。可考虑：${suggestions}fwctl 不会自动修改，需手工编辑 state.json 后 fw render"
    else
        _doctor_row OK "安全建议" "策略已高于旧版本默认值"
    fi

    return 0
}

# 输出体检报告。
doctor_report() {
    local row status name detail

    if [[ "${FWCTL_JSON:-0}" == 1 ]]; then
        printf '%s\n' "${DOCTOR_ROWS[@]}" |
            jq -R -s 'split("\n") | map(select(. != ""))
                      | map(split("\t") | {status: .[0], check: .[1], detail: .[2]})'
        return 0
    fi

    # 不使用定宽列：中文是双宽字符，printf 的 %-Ns 按字符数而非显示宽度对齐，
    # 定宽反而会错位。改用「符号 + 检查项：说明」的简单版式。
    printf '%s\n' "------------------------------------------------------------"
    for row in "${DOCTOR_ROWS[@]}"; do
        IFS=$'\t' read -r status name detail <<< "$row"
        case "$status" in
            OK)   printf '✅ %s：%s\n' "$name" "$detail" ;;
            WARN) printf '⚠️  %s：%s\n' "$name" "$detail" ;;
            FAIL) printf '❌ %s：%s\n' "$name" "$detail" ;;
        esac
    done
    printf '%s\n' "------------------------------------------------------------"
    printf '合计：%d 项失败，%d 项提醒\n' "$DOCTOR_FAIL" "$DOCTOR_WARN"
}

# FAIL 时返回运行时错误码，仅 WARN 返回 0。
doctor_exit_code() {
    ((DOCTOR_FAIL > 0)) && return "$FWCTL_EXIT_RUNTIME"
    return 0
}
