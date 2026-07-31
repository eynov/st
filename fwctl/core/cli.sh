#!/bin/bash
# core/cli.sh —— 命令行层
#
# 职责：参数解析、子命令分发、输出格式化、交互菜单。
#
# 依赖：core/common.sh、core/state.sh、core/model.sh、core/migration.sh、
#       core/render.sh、core/transaction.sh
# 用法：本文件只能被 source，不能直接执行。
#
# 本层不直接写状态，也不直接调用 nft：所有写操作都交给 txn_publish_locked，
# 因此它们共享同一个互斥边界与同一套回滚语义。
#
# 旧版本的命令、提示文本与交互菜单编号在这里逐字保留，见 docs/CLI.md 的
# 「兼容承诺」。

[[ -n "${FWCTL_CLI_LOADED:-}" ]] && return 0
FWCTL_CLI_LOADED=1

# ── 状态准备 ──────────────────────────────────────────────────────────

# 把当前状态整理成当前 schema，写入指定路径。
#
# 旧格式在这里被迁移。**只读命令不会因此写盘**：迁移结果只落在调用方给的临时
# 文件里，磁盘上的 state.json 要等到写事务提交才更新。
# 参数：$1=输出路径。
cli_working_state() {
    local out=$1 path="${FWCTL_STATE_FILE:?FWCTL_STATE_FILE 未设置}"

    if [[ ! -f "$path" || ! -s "$path" ]]; then
        state_default > "$out" || return "$FWCTL_EXIT_RUNTIME"
        return 0
    fi

    if ! migration_to_current "$path" > "$out"; then
        return "$FWCTL_EXIT_VALIDATION"
    fi
    return 0
}

# 判断磁盘上的状态是否需要迁移，供写路径决定是否输出升级提示。
cli_needs_migration() {
    local path="${FWCTL_STATE_FILE:-}"
    [[ -f "$path" && -s "$path" ]] || return 1
    migration_is_legacy "$path"
}

# 迁移前备份。
cli_backup_before_migration() {
    local path="${FWCTL_STATE_FILE:?}" dir stamp
    stamp=$(fwctl_now | tr -d ':-')
    dir="${FWCTL_BACKUP_DIR:-$(txn_var_dir)/backups}/pre-migration-$stamp"
    mkdir -p "$dir" || return 1
    cp "$path" "$dir/state.json" || return 1
    cp "$path" "${path}.v1.bak" || return 1
    printf '%s\n' "$dir"
}

# 执行一次写事务：准备候选 → 交给事务层发布。
#
# 参数：$1=一个函数名，它接收「当前状态路径」和「候选输出路径」，
#       负责把变更写进候选。
# 其余参数原样传给该函数。
cli_transact() {
    local mutator=$1
    shift
    local work current candidate rc backup

    work=$(mktemp -d) || return "$FWCTL_EXIT_RUNTIME"
    current="$work/current.json"
    candidate="$work/candidate.json"

    if cli_needs_migration; then
        if ! backup=$(cli_backup_before_migration); then
            fwctl_err "迁移前备份失败，未做任何变更"
            rm -rf "$work"
            return "$FWCTL_EXIT_RUNTIME"
        fi
        fwctl_info "已升级状态格式，备份位于 $backup"
    fi

    if ! cli_working_state "$current"; then
        rc=$?
        rm -rf "$work"
        return "$rc"
    fi

    if ! "$mutator" "$current" "$candidate" "$@"; then
        rm -rf "$work"
        return "$FWCTL_EXIT_VALIDATION"
    fi

    # 清理指向已删除对象的注释，避免孤儿注释越积越多。
    if model_comment_prune "$candidate" > "$work/pruned.json"; then
        mv -f "$work/pruned.json" "$candidate"
    fi

    txn_publish_locked "$candidate"
    rc=$?
    rm -rf "$work"
    return "$rc"
}

# 只读命令用的状态快照。
cli_read_state() {
    local out=$1
    cli_working_state "$out"
}

# ── port（旧版本入口，逐字兼容）────────────────────────────────────────

_cli_port_mutator() {
    local current=$1 candidate=$2 action=$3 proto=$4 port=$5
    model_port_update "$current" "$action" "$proto" "$port" > "$candidate"
}

cli_port_update() {
    local action=$1 requested_proto=$2 requested_port=$3
    local proto port work current rc label

    # 先校验参数，错误文案与旧版本逐字一致。
    proto=$(fwctl_validate_protocol "$requested_proto") || return "$FWCTL_EXIT_VALIDATION"
    port=$(fwctl_normalize_port_spec "$requested_port") || return "$FWCTL_EXIT_VALIDATION"

    work=$(mktemp -d) || return "$FWCTL_EXIT_RUNTIME"
    current="$work/current.json"
    if ! cli_working_state "$current"; then
        rc=$?
        rm -rf "$work"
        return "$rc"
    fi

    # 幂等提示：不产生变更时直接返回成功，与旧版本一致。
    if ! model_port_would_change "$current" "$action" "$proto" "$port"; then
        if [[ "$action" == add ]]; then
            echo "ℹ️ $proto/$port 已存在，无需重复添加"
        else
            echo "ℹ️ $proto/$port 不存在，未做修改"
        fi
        rm -rf "$work"
        return "$FWCTL_EXIT_OK"
    fi
    rm -rf "$work"

    cli_transact _cli_port_mutator "$action" "$proto" "$port"
    rc=$?
    if ((rc == FWCTL_EXIT_OK)); then
        [[ "$action" == add ]] && label=添加 || label=删除
        echo "✅ 已${label} ${proto}/${port}"
    else
        echo "❌ 端口变更未保存" >&2
    fi
    return "$rc"
}

cli_port_list() {
    local work current rc
    work=$(mktemp -d) || return "$FWCTL_EXIT_RUNTIME"
    current="$work/current.json"
    if ! cli_read_state "$current"; then
        rc=$?
        rm -rf "$work"
        return "$rc"
    fi

    if [[ "${FWCTL_JSON:-0}" == 1 ]]; then
        jq -c '.ports' "$current"
    else
        # 输出格式与旧版本逐字一致：TCP / UDP / BOTH 三行。
        jq -r "
            $(fwctl_jq_port_sort_def)
            (.ports.tcp // []) as \$tcp
            | (.ports.udp // []) as \$udp
            | (\$tcp - \$udp | sorted_ports | join(\", \")) as \$tcp_only
            | (\$udp - \$tcp | sorted_ports | join(\", \")) as \$udp_only
            | ([\$tcp[] | select(. as \$p | \$udp | index(\$p))] | sorted_ports | join(\", \")) as \$both
            | \"TCP: \(\$tcp_only)\nUDP: \(\$udp_only)\nBOTH: \(\$both)\"
        " "$current"
    fi
    rm -rf "$work"
    return "$FWCTL_EXIT_OK"
}

# ── render（旧版本入口）───────────────────────────────────────────────

_cli_render_mutator() {
    local current=$1 candidate=$2
    cp "$current" "$candidate"
}

cli_render() {
    local rc
    cli_transact _cli_render_mutator
    rc=$?
    if ((rc == FWCTL_EXIT_OK)); then
        if [[ "${FWCTL_DRY_RUN:-0}" != 1 && "${FWCTL_APPLY:-1}" != 0 ]]; then
            echo "✅ 编译成功，规则已实时应用！"
        fi
    else
        echo "❌ 编译或加载失败；上一份运行配置和持久配置保持不变。" >&2
    fi
    return "$rc"
}

# 只渲染并输出，不进入事务。
# 目标为 "-" 时写 stdout，否则写指定路径。无论哪种情况都不修改内核、
# state.json、build/ 与系统配置文件——这是唯一一条能在不发起事务的前提下
# 查看渲染结果的路径，供人工审阅与外部 diff 使用。
# 探测外部事实时会只读地列一次内核中的表（判断有无待接管的遗留表），
# 与 fw diff 的行为一致。
# 参数：$1=输出目标（"-" 或文件路径）。
cli_render_output() {
    local dest=$1
    local work current facts rendered rc

    work=$(mktemp -d) || return "$FWCTL_EXIT_RUNTIME"
    current="$work/current.json"
    rendered="$work/rendered.nft"

    # 与其他只读路径一致：旧格式只在内存里迁移，不写回磁盘。
    if ! cli_read_state "$current"; then
        rm -rf "$work"
        return "$FWCTL_EXIT_VALIDATION"
    fi

    facts=$(txn_probe_facts "$current") || {
        rm -rf "$work"
        return "$FWCTL_EXIT_RUNTIME"
    }

    if ! render_ruleset "$current" "$facts" > "$rendered"; then
        rm -rf "$work"
        return "$FWCTL_EXIT_RUNTIME"
    fi

    rc="$FWCTL_EXIT_OK"
    if [[ "$dest" == "-" ]]; then
        cat "$rendered"
    elif ! cat "$rendered" > "$dest"; then
        fwctl_err "无法写入渲染结果：$dest"
        rc="$FWCTL_EXIT_RUNTIME"
    fi

    rm -rf "$work"
    return "$rc"
}

# ── target ────────────────────────────────────────────────────────────

_cli_target_add_mutator() {
    local current=$1 candidate=$2 name=$3 addresses=$4 description=$5
    model_target_add "$current" "$name" "$addresses" "$description" ipv4 > "$candidate"
}

_cli_target_edit_mutator() {
    local current=$1 candidate=$2 ref=$3
    shift 3
    local id
    id=$(model_resolve "$current" target "$ref") || return 1
    model_target_edit "$current" "$id" "$@" > "$candidate"
}

_cli_target_delete_mutator() {
    local current=$1 candidate=$2 ref=$3 cascade=$4
    local id
    id=$(model_resolve "$current" target "$ref") || return 1
    model_target_delete "$current" "$id" "$cascade" > "$candidate"
}

_cli_target_enable_mutator() {
    local current=$1 candidate=$2 ref=$3 enabled=$4
    local id
    id=$(model_resolve "$current" target "$ref") || return 1
    model_target_set_enabled "$current" "$id" "$enabled" > "$candidate"
}

# ── service ───────────────────────────────────────────────────────────

_cli_service_add_mutator() {
    local current=$1 candidate=$2 name=$3 protocol=$4 ports=$5 description=$6
    model_service_add "$current" "$name" "$protocol" "$ports" "$description" > "$candidate"
}

_cli_service_meta_mutator() {
    local current=$1 candidate=$2 ref=$3
    shift 3
    local id
    id=$(model_resolve "$current" service "$ref") || return 1
    model_service_edit_metadata "$current" "$id" "$@" > "$candidate"
}

_cli_service_replace_mutator() {
    local current=$1 candidate=$2 ref=$3 new_name=$4 protocol=$5 ports=$6 refs=$7
    local id rule_ids=""

    id=$(model_resolve "$current" service "$ref") || return 1

    if [[ "$refs" == "--all-refs" ]]; then
        rule_ids=$(jq -r --arg id "$id" \
            '[.rules[] | select(.service == $id) | .id] | join(",")' "$current")
    elif [[ -n "$refs" ]]; then
        local name resolved
        for name in ${refs//,/ }; do
            resolved=$(model_resolve "$current" rule "$name") || return 1
            rule_ids="${rule_ids:+$rule_ids,}$resolved"
        done
    fi

    model_service_replace "$current" "$id" "$new_name" "$protocol" "$ports" "$rule_ids" \
        > "$candidate"
}

_cli_service_delete_mutator() {
    local current=$1 candidate=$2 ref=$3 cascade=$4
    local id
    id=$(model_resolve "$current" service "$ref") || return 1
    model_service_delete "$current" "$id" "$cascade" > "$candidate"
}

# ── rule ──────────────────────────────────────────────────────────────

_cli_rule_add_mutator() {
    local current=$1 candidate=$2 name=$3 type=$4 service=$5 target=$6 source=$7
    local translate=$8 priority=$9 description=${10} comment=${11}
    local service_id="" target_id="" source_id="" tmp

    [[ -n "$service" ]] && { service_id=$(model_resolve "$current" service "$service") || return 1; }
    [[ -n "$target" ]] && { target_id=$(model_resolve "$current" target "$target") || return 1; }
    [[ -n "$source" ]] && { source_id=$(model_resolve "$current" target "$source") || return 1; }

    model_rule_add "$current" "$name" "$type" "$service_id" "$target_id" "$source_id" \
        "$translate" "$priority" "$description" > "$candidate" || return 1

    if [[ -n "$comment" ]]; then
        local id
        id=$(model_resolve "$candidate" rule "$name") || return 1
        tmp=$(mktemp) || return 1
        model_comment_set "$candidate" "$id" "$comment" > "$tmp" || { rm -f "$tmp"; return 1; }
        mv -f "$tmp" "$candidate"
    fi
    return 0
}

_cli_rule_edit_mutator() {
    local current=$1 candidate=$2 ref=$3
    shift 3
    local id
    id=$(model_resolve "$current" rule "$ref") || return 1
    model_rule_edit "$current" "$id" "$@" > "$candidate"
}

_cli_rule_delete_mutator() {
    local current=$1 candidate=$2 ref=$3
    local id
    id=$(model_resolve "$current" rule "$ref") || return 1
    model_rule_delete "$current" "$id" > "$candidate"
}

_cli_rule_enable_mutator() {
    local current=$1 candidate=$2 ref=$3 enabled=$4
    local id
    id=$(model_resolve "$current" rule "$ref") || return 1
    model_rule_set_enabled "$current" "$id" "$enabled" > "$candidate"
}

# ── 列表与详情 ────────────────────────────────────────────────────────
# 一律优先显示 name，仅在需要消歧时附带 id。

cli_list() {
    local kind=$1 work current rc array
    case "$kind" in
        target)  array=targets ;;
        service) array=services ;;
        rule)    array=rules ;;
    esac

    work=$(mktemp -d) || return "$FWCTL_EXIT_RUNTIME"
    current="$work/current.json"
    if ! cli_read_state "$current"; then
        rc=$?
        rm -rf "$work"
        return "$rc"
    fi

    if [[ "${FWCTL_JSON:-0}" == 1 ]]; then
        jq -c ".$array" "$current"
        rm -rf "$work"
        return 0
    fi

    case "$kind" in
        target)
            # 地址集合完全相同的 Target 标注 DUP：这是合法的，但通常是无意的重复。
            # 注意 $dups | index(...) 的参数必须先用 as 绑定：在 index() 内部
            # `.` 指的是 $dups 数组本身，写成 index(.name) 会去用 "name" 索引
            # 数组而报错。
            jq -r '
                ([ .targets[] | {name, key: (.addresses | sort | join(","))} ]
                 | group_by(.key) | map(select(length > 1)) | flatten
                 | map(.name)) as $dups
                | "NAME                 ENABLED  ADDRESSES",
                  (.targets[]
                   | . as $t
                   | "\($t.name | . + (" " * (20 - length)))"
                     + " \(if $t.enabled then "yes    " else "no     " end)"
                     + " \($t.addresses | join(", "))"
                     + (if ($dups | index($t.name)) then "  [DUP]" else "" end))
            ' "$current"
            ;;
        service)
            jq -r '
                "NAME                 PROTO  PORTS",
                (.services[]
                 | "\(.name | . + (" " * (20 - length)))"
                   + " \(.protocol | . + (" " * (6 - length)))"
                   + " \(.ports | join(", "))")
            ' "$current"
            ;;
        rule)
            jq -r '
                ([ .services[] | {key: .id, value: .} ] | from_entries) as $svc
                | ([ .targets[] | {key: .id, value: .} ] | from_entries) as $tgt
                | "NAME                 TYPE     ENABLED  PRI    SERVICE        TARGET/SOURCE",
                  (.rules[]
                   | "\(.name | . + (" " * (20 - length)))"
                     + " \(.type | . + (" " * (8 - length)))"
                     + " \(if .enabled then "yes    " else "no     " end)"
                     + " \(.priority | tostring | . + (" " * (6 - length)))"
                     + " \(if .service then ($svc[.service].name + "(" + $svc[.service].protocol + ")") else "-" end | . + (" " * 2))"
                     + " \(if .target then $tgt[.target].name elif .source then $tgt[.source].name else "-" end)")
            ' "$current"
            ;;
    esac
    rm -rf "$work"
    return 0
}

cli_show() {
    local kind=$1 ref=$2 work current rc id array
    case "$kind" in
        target)  array=targets ;;
        service) array=services ;;
        rule)    array=rules ;;
    esac

    work=$(mktemp -d) || return "$FWCTL_EXIT_RUNTIME"
    current="$work/current.json"
    if ! cli_read_state "$current"; then
        rc=$?
        rm -rf "$work"
        return "$rc"
    fi

    if ! id=$(model_resolve "$current" "$kind" "$ref"); then
        rm -rf "$work"
        return "$FWCTL_EXIT_VALIDATION"
    fi

    jq --arg id "$id" --arg array "$array" '.[$array][] | select(.id == $id)' "$current"
    rm -rf "$work"
    return 0
}

# ── validate ──────────────────────────────────────────────────────────

cli_validate() {
    local offline=${1:-0} work current facts rc

    work=$(mktemp -d) || return "$FWCTL_EXIT_RUNTIME"
    current="$work/current.json"
    if ! cli_read_state "$current"; then
        rm -rf "$work"
        return "$FWCTL_EXIT_VALIDATION"
    fi

    if [[ "$offline" == 1 ]]; then
        facts='{"offline":true}'
    else
        facts=$(txn_probe_facts "$current") || facts='{"offline":true}'
    fi

    if state_validate "$current" "$facts"; then
        local warnings
        warnings=$(state_warnings "$current")
        if [[ -n "$warnings" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && fwctl_warn "$line"
            done <<< "$warnings"
        fi
        fwctl_ok "状态校验通过"
        rc=$FWCTL_EXIT_OK
    else
        rc=$FWCTL_EXIT_VALIDATION
    fi
    rm -rf "$work"
    return "$rc"
}

# ── diff ──────────────────────────────────────────────────────────────

cli_diff() {
    local exit_code=${1:-0} work current facts rendered live rc

    work=$(mktemp -d) || return "$FWCTL_EXIT_RUNTIME"
    current="$work/current.json"
    rendered="$work/rendered.nft"
    live="$work/live.nft"

    if ! cli_read_state "$current"; then
        rm -rf "$work"
        return "$FWCTL_EXIT_VALIDATION"
    fi

    facts=$(txn_probe_facts "$current") || {
        rm -rf "$work"
        return "$FWCTL_EXIT_RUNTIME"
    }
    if ! render_ruleset "$current" "$facts" > "$rendered"; then
        rm -rf "$work"
        return "$FWCTL_EXIT_RUNTIME"
    fi

    if ! "$(txn_nft_bin)" list table ip "$FWCTL_TABLE" > "$live" 2>/dev/null; then
        printf '运行中不存在 table ip %s；执行 fw render 可以应用当前状态\n' "$FWCTL_TABLE"
        rm -rf "$work"
        ((exit_code == 1)) && return "$FWCTL_EXIT_VALIDATION"
        return "$FWCTL_EXIT_OK"
    fi

    # 比较渲染产物与运行中规则的语义行，忽略排版差异。
    if diff -u <(_cli_semantic_lines "$rendered") <(_cli_semantic_lines "$live") \
        > "$work/diff.txt"; then
        printf '无差异\n'
        rc=$FWCTL_EXIT_OK
    else
        cat "$work/diff.txt"
        if ((exit_code == 1)); then
            rc=$FWCTL_EXIT_VALIDATION
        else
            rc=$FWCTL_EXIT_OK
        fi
    fi
    rm -rf "$work"
    return "$rc"
}

# 提取可比较的语义行：去掉表声明、计数值与排版差异。
#
# 两处排版差异必须归一化，否则 fw diff 会报告并不存在的漂移，从而失去发现真实
# 漂移的作用：
#
#   * `burst N packets`：nftables 1.0.6 回读时省略它，1.1.x 会打印。
#   * 换行的 `elements = { ... }`：元素较多时 nft 会把集合折行输出，而我们渲染
#     成一行。折行阈值取决于元素个数，因此端口一多就必然触发。
_cli_semantic_lines() {
    # 先把折行的 elements 块拼回一行，再做既有的空白归一化。
    # 只处理 elements 构造本身，其余行原样透传，避免掩盖真实差异。
    awk '
        joining {
            buf = buf " " $0
            if (index($0, "}")) { print buf; joining = 0 }
            next
        }
        /elements[[:space:]]*=[[:space:]]*\{/ && index($0, "}") == 0 {
            buf = $0; joining = 1; next
        }
        { print }
        END { if (joining) print buf }
    ' "$1" |
    sed -e '/^table ip .* { }$/d' -e '/^delete table/d' \
        -e 's/counter packets [0-9]* bytes [0-9]*/counter/' \
        -e 's/ burst [0-9]* packets//' \
        -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//' |
    grep -v '^$'
}


# ── doctor ────────────────────────────────────────────────────────────

cli_doctor() {
    local work current rc
    work=$(mktemp -d) || return "$FWCTL_EXIT_RUNTIME"
    current="$work/current.json"
    if ! cli_read_state "$current"; then
        rm -rf "$work"
        return "$FWCTL_EXIT_VALIDATION"
    fi
    doctor_run "$current"
    doctor_report
    doctor_exit_code
    rc=$?
    rm -rf "$work"
    return "$rc"
}

# ── backup / restore ──────────────────────────────────────────────────

cli_backup() {
    local verb=${1:-create} id
    shift 2>/dev/null || true

    case "$verb" in
        create)
            local label=""
            [[ "${1:-}" == "--label" ]] && label=${2:-}
            if id=$(backup_create "$label"); then
                fwctl_ok "已创建备份 $id"
                return "$FWCTL_EXIT_OK"
            fi
            return "$FWCTL_EXIT_RUNTIME"
            ;;
        list)
            backup_list
            ;;
        show)
            [[ $# -eq 1 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            backup_show "$1" || return "$FWCTL_EXIT_VALIDATION"
            ;;
        *)
            cli_usage >&2
            return "$FWCTL_EXIT_USAGE"
            ;;
    esac
}

_cli_restore_mutator() {
    local current=$1 candidate=$2 source=$3
    local resolved
    resolved=$(backup_resolve_state "$source") || return 1
    # 恢复的内容同样要先迁移到当前 schema，旧备份因此依然可用。
    migration_to_current "$resolved" > "$candidate"
}

cli_restore() {
    local source=$1 id rc

    # 恢复前先备份当前状态，避免「恢复错了备份」变成不可逆操作。
    if id=$(backup_create "before-restore"); then
        fwctl_info "已备份当前状态为 $id"
    else
        fwctl_err "恢复前备份失败，未做任何变更"
        return "$FWCTL_EXIT_RUNTIME"
    fi

    cli_transact _cli_restore_mutator "$source"
    rc=$?
    if ((rc == FWCTL_EXIT_OK)); then
        fwctl_ok "已从 $source 恢复"
    fi
    return "$rc"
}

# ── stats ─────────────────────────────────────────────────────────────

cli_stats() {
    local ref=${1:-} work current rc
    work=$(mktemp -d) || return "$FWCTL_EXIT_RUNTIME"
    current="$work/current.json"
    if ! cli_read_state "$current"; then
        rm -rf "$work"
        return "$FWCTL_EXIT_VALIDATION"
    fi
    if [[ "$ref" == "--reset" ]]; then
        stats_reset
        rc=$?
    else
        stats_report "$current" "$ref"
        rc=$?
    fi
    rm -rf "$work"
    ((rc == 0)) || return "$FWCTL_EXIT_RUNTIME"
    return "$FWCTL_EXIT_OK"
}

# ── 用法 ──────────────────────────────────────────────────────────────

cli_usage() {
    local command_name=${FWCTL_COMMAND_NAME:-fw}
    cat <<EOF
用法：
  $command_name port add tcp|udp|both PORT|START-END
  $command_name port remove tcp|udp|both PORT|START-END
  $command_name port list
  $command_name render [--output PATH|-]

  $command_name target add|edit|delete|list|show|enable|disable ...
  $command_name service add|edit|delete|list|show ...
  $command_name rule add|edit|delete|list|show|enable|disable ...

  $command_name validate [--offline]
  $command_name diff [--exit-code]
  $command_name doctor
  $command_name backup [create [--label TEXT] | list | show ID]
  $command_name restore <backup-id>|--file PATH
  $command_name stats [RULE|--reset]

选项：
  --dry-run    只校验与渲染，不应用
  --json       以 JSON 输出
  --yes        跳过确认
  --quiet      只输出错误
  -h, --help   显示本帮助

退出码：0 成功  1 校验失败  2 用法错误  3 运行时失败  4 锁冲突  5 已回滚
EOF
}

# ── 分发 ──────────────────────────────────────────────────────────────

# 解析全局选项，剩余参数留在 CLI_ARGS 数组里。
cli_parse_globals() {
    CLI_ARGS=()
    while (($# > 0)); do
        case "$1" in
            --dry-run) export FWCTL_DRY_RUN=1 ;;
            --json)    export FWCTL_JSON=1 ;;
            --yes)     export FWCTL_ASSUME_YES=1 ;;
            --quiet)   export FWCTL_QUIET=1 ;;
            *)         CLI_ARGS+=("$1") ;;
        esac
        shift
    done
}

cli_main() {
    local noun verb

    cli_parse_globals "$@"
    set -- "${CLI_ARGS[@]+"${CLI_ARGS[@]}"}"

    (($# > 0)) || return 100   # 100 表示「无参数」，由入口决定是否进交互菜单

    noun=$1
    shift

    case "$noun" in
        port)
            verb=${1:-}
            shift 2>/dev/null || true
            case "$verb" in
                add|remove|delete)
                    [[ $# -eq 2 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
                    [[ "$verb" == delete ]] && verb=remove
                    cli_port_update "$verb" "$1" "$2"
                    ;;
                list)
                    [[ $# -eq 0 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
                    cli_port_list
                    ;;
                *)
                    cli_usage >&2
                    return "$FWCTL_EXIT_USAGE"
                    ;;
            esac
            ;;
        target|service|rule)
            cli_object_dispatch "$noun" "$@"
            ;;
        render)
            case "${1:-}" in
                "")
                    cli_render
                    ;;
                --output)
                    [[ $# -eq 2 && -n "$2" ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
                    cli_render_output "$2"
                    ;;
                *)
                    cli_usage >&2
                    return "$FWCTL_EXIT_USAGE"
                    ;;
            esac
            ;;
        validate)
            local offline=0
            [[ "${1:-}" == "--offline" ]] && offline=1
            cli_validate "$offline"
            ;;
        diff)
            local want_code=0
            [[ "${1:-}" == "--exit-code" ]] && want_code=1
            cli_diff "$want_code"
            ;;
        doctor)
            cli_doctor
            ;;
        backup)
            cli_backup "$@"
            ;;
        restore)
            [[ $# -ge 1 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            if [[ "$1" == "--file" ]]; then
                [[ $# -ge 2 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
                cli_restore "$2"
            else
                cli_restore "$1"
            fi
            ;;
        stats)
            cli_stats "${1:-}"
            ;;
        -h|--help|help)
            cli_usage
            return "$FWCTL_EXIT_OK"
            ;;
        *)
            cli_usage >&2
            return "$FWCTL_EXIT_USAGE"
            ;;
    esac
}

# target / service / rule 的动词分发。
cli_object_dispatch() {
    local kind=$1 verb=${2:-}
    shift 2 2>/dev/null || true

    case "$kind:$verb" in
        target:add)
            [[ $# -ge 2 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            local name=$1 addresses=$2 description=""
            shift 2
            while (($# > 0)); do
                case "$1" in
                    --description) description=${2:-}; shift 2 ;;
                    *) cli_usage >&2; return "$FWCTL_EXIT_USAGE" ;;
                esac
            done
            cli_transact _cli_target_add_mutator "$name" "$addresses" "$description"
            ;;
        target:edit)
            [[ $# -ge 1 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            local ref=$1
            shift
            local -a fields=()
            while (($# > 0)); do
                case "$1" in
                    --name)        fields+=("name=${2:-}"); shift 2 ;;
                    --description) fields+=("description=${2:-}"); shift 2 ;;
                    --address)     fields+=("addresses=${2:-}"); shift 2 ;;
                    *) cli_usage >&2; return "$FWCTL_EXIT_USAGE" ;;
                esac
            done
            ((${#fields[@]} > 0)) || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            cli_transact _cli_target_edit_mutator "$ref" "${fields[@]}"
            ;;
        target:delete)
            [[ $# -ge 1 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            local ref=$1 cascade=0
            [[ "${2:-}" == "--cascade" ]] && cascade=1
            cli_transact _cli_target_delete_mutator "$ref" "$cascade"
            ;;
        target:enable|target:disable)
            [[ $# -eq 1 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            local enabled=true
            [[ "$verb" == disable ]] && enabled=false
            cli_transact _cli_target_enable_mutator "$1" "$enabled"
            ;;
        target:list|service:list|rule:list)
            cli_list "$kind"
            ;;
        target:show|service:show|rule:show)
            [[ $# -eq 1 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            cli_show "$kind" "$1"
            ;;

        service:add)
            [[ $# -ge 3 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            local name=$1 protocol=$2 ports=$3 description=""
            shift 3
            while (($# > 0)); do
                case "$1" in
                    --description) description=${2:-}; shift 2 ;;
                    *) cli_usage >&2; return "$FWCTL_EXIT_USAGE" ;;
                esac
            done
            cli_transact _cli_service_add_mutator "$name" "$protocol" "$ports" "$description"
            ;;
        service:edit)
            [[ $# -ge 1 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            cli_service_edit "$@"
            ;;
        service:delete)
            [[ $# -ge 1 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            local ref=$1 cascade=0
            [[ "${2:-}" == "--cascade" ]] && cascade=1
            cli_transact _cli_service_delete_mutator "$ref" "$cascade"
            ;;
        service:enable|service:disable)
            fwctl_err "Service 是不可变值对象，不持有启用状态"
            fwctl_err "要停用某条转发，请禁用对应的 Rule：fw rule disable <name>"
            return "$FWCTL_EXIT_USAGE"
            ;;

        rule:add)
            [[ $# -ge 1 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            local name=$1 type="" service="" target="" source=""
            local translate="" priority=100 description="" comment=""
            shift
            while (($# > 0)); do
                case "$1" in
                    --type)        type=${2:-}; shift 2 ;;
                    --service)     service=${2:-}; shift 2 ;;
                    --target)      target=${2:-}; shift 2 ;;
                    --source)      source=${2:-}; shift 2 ;;
                    --to-port)     translate=${2:-}; shift 2 ;;
                    --priority)    priority=${2:-}; shift 2 ;;
                    --description) description=${2:-}; shift 2 ;;
                    --comment)     comment=${2:-}; shift 2 ;;
                    *) cli_usage >&2; return "$FWCTL_EXIT_USAGE" ;;
                esac
            done
            [[ -n "$type" ]] || { fwctl_err "缺少 --type"; return "$FWCTL_EXIT_USAGE"; }
            cli_transact _cli_rule_add_mutator "$name" "$type" "$service" "$target" \
                "$source" "$translate" "$priority" "$description" "$comment"
            ;;
        rule:edit)
            [[ $# -ge 1 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            local ref=$1
            shift
            local -a fields=()
            while (($# > 0)); do
                case "$1" in
                    --name)        fields+=("name=${2:-}"); shift 2 ;;
                    --description) fields+=("description=${2:-}"); shift 2 ;;
                    --priority)    fields+=("priority=${2:-}"); shift 2 ;;
                    --to-port)     fields+=("translate=${2:-}"); shift 2 ;;
                    --no-translate) fields+=("translate="); shift ;;
                    *) cli_usage >&2; return "$FWCTL_EXIT_USAGE" ;;
                esac
            done
            ((${#fields[@]} > 0)) || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            cli_transact _cli_rule_edit_mutator "$ref" "${fields[@]}"
            ;;
        rule:delete)
            [[ $# -eq 1 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            cli_transact _cli_rule_delete_mutator "$1"
            ;;
        rule:enable|rule:disable)
            [[ $# -eq 1 ]] || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }
            local enabled=true
            [[ "$verb" == disable ]] && enabled=false
            cli_transact _cli_rule_enable_mutator "$1" "$enabled"
            ;;
        *:-h|*:--help|*:help)
            cli_usage
            return "$FWCTL_EXIT_OK"
            ;;
        *:)
            # 只给出名词而没有动词是用法错误，不是求助。
            cli_usage >&2
            return "$FWCTL_EXIT_USAGE"
            ;;
        *)
            cli_usage >&2
            return "$FWCTL_EXIT_USAGE"
            ;;
    esac
}

# service edit 的值变更必须显式声明引用范围。
cli_service_edit() {
    local ref=$1
    shift
    local new_name="" protocol="" ports="" description="" refs=""
    local has_value=0 has_meta=0

    while (($# > 0)); do
        case "$1" in
            --name)        new_name=${2:-}; has_meta=1; shift 2 ;;
            --description) description=${2:-}; has_meta=1; shift 2 ;;
            --protocol)    protocol=${2:-}; has_value=1; shift 2 ;;
            --ports)       ports=${2:-}; has_value=1; shift 2 ;;
            --refs)        refs=${2:-}; shift 2 ;;
            --all-refs)    refs="--all-refs"; shift ;;
            *) cli_usage >&2; return "$FWCTL_EXIT_USAGE" ;;
        esac
    done

    if ((has_value)); then
        # 值变更 = 新建对象 + 重写引用，爆炸半径必须由调用方显式声明。
        if [[ -z "$refs" ]]; then
            fwctl_err "修改 Service 的 protocol 或 ports 会影响引用它的规则"
            fwctl_err "请显式声明重写范围：--refs <规则列表> 或 --all-refs"
            cli_service_show_refs "$ref"
            return "$FWCTL_EXIT_USAGE"
        fi
        local work current
        work=$(mktemp -d) || return "$FWCTL_EXIT_RUNTIME"
        current="$work/current.json"
        cli_read_state "$current" || { rm -rf "$work"; return "$FWCTL_EXIT_VALIDATION"; }
        # 未指定的字段沿用原值。
        local id
        id=$(model_resolve "$current" service "$ref") || {
            rm -rf "$work"
            return "$FWCTL_EXIT_VALIDATION"
        }
        [[ -n "$protocol" ]] ||
            protocol=$(jq -r --arg id "$id" '.services[]|select(.id==$id)|.protocol' "$current")
        [[ -n "$ports" ]] ||
            ports=$(jq -r --arg id "$id" '.services[]|select(.id==$id)|.ports|join(",")' "$current")
        [[ -n "$new_name" ]] ||
            new_name=$(jq -r --arg id "$id" '.services[]|select(.id==$id)|.name' "$current")"-new"
        rm -rf "$work"

        cli_transact _cli_service_replace_mutator "$ref" "$new_name" "$protocol" "$ports" "$refs"
        return $?
    fi

    ((has_meta)) || { cli_usage >&2; return "$FWCTL_EXIT_USAGE"; }

    local -a fields=()
    [[ -n "$new_name" ]] && fields+=("name=$new_name")
    [[ -n "$description" ]] && fields+=("description=$description")
    cli_transact _cli_service_meta_mutator "$ref" "${fields[@]}"
}

# 列出引用某个 Service 的全部规则，帮助用户看清爆炸半径。
cli_service_show_refs() {
    local ref=$1 work current id refs
    work=$(mktemp -d) || return 1
    current="$work/current.json"
    if cli_read_state "$current" && id=$(model_resolve "$current" service "$ref" 2>/dev/null); then
        refs=$(jq -r --arg id "$id" \
            '[.rules[] | select(.service == $id) | .name] | join("、")' "$current")
        [[ -n "$refs" ]] && fwctl_err "当前引用它的规则：$refs"
    fi
    rm -rf "$work"
}
