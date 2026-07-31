#!/bin/bash
# core/stats.sh —— 计数器读取
#
# 职责：从内核读回 counter，按 comment 中的 fwctl:<id> 前缀关联回对象。
#
# 依赖：core/common.sh、core/state.sh、core/render.sh
# 用法：本文件只能被 source，不能直接执行。
#
# 只读模块：不获取写锁，不改变任何状态。

[[ -n "${FWCTL_STATS_LOADED:-}" ]] && return 0
FWCTL_STATS_LOADED=1

# 从内核读出「对象 id → 计数」的映射。
#
# 渲染时每条规则都带 `comment "fwctl:<id> [用户注释]"`，这里按前缀反解。
# protocol=both 的规则会展开成两条 nft 规则，因此同一个 id 可能出现多次，
# 需要累加而不是取第一条。
# 输出：JSON 对象 {"<id>": {"packets": N, "bytes": N}}
stats_collect() {
    local listing

    if ! listing=$("$(txn_nft_bin)" -j list table ip "$FWCTL_TABLE" 2>/dev/null); then
        fwctl_err "无法读取 table ip $FWCTL_TABLE；规则可能尚未应用"
        return 1
    fi

    jq -c '
        [ .nftables[]
          | select(.rule != null)
          | select(.rule.comment != null)
          | select(.rule.comment | startswith("fwctl:"))
          | {
              id: (.rule.comment | ltrimstr("fwctl:") | split(" ")[0]),
              counter: ([ .rule.expr[]? | select(.counter != null) | .counter ] | first)
            }
          | select(.counter != null)
        ]
        | group_by(.id)
        | map({
            key: .[0].id,
            value: {
              packets: (map(.counter.packets) | add),
              bytes: (map(.counter.bytes) | add)
            }
          })
        | from_entries
    ' <<< "$listing"
}

# 人类可读的字节数。
_stats_human_bytes() {
    local bytes=$1
    if ((bytes < 1024)); then
        printf '%d B\n' "$bytes"
    elif ((bytes < 1048576)); then
        printf '%.1f KiB\n' "$(bc -l <<< "$bytes/1024")" 2>/dev/null ||
            printf '%d KiB\n' "$((bytes / 1024))"
    elif ((bytes < 1073741824)); then
        printf '%d MiB\n' "$((bytes / 1048576))"
    else
        printf '%d GiB\n' "$((bytes / 1073741824))"
    fi
}

# 输出统计表。
# 参数：$1=状态文件，$2=可选的对象引用（只看某一条规则）。
stats_report() {
    local state=$1 ref=${2:-} counters id

    # counter 关闭时明确报错，而不是输出一屏全零让用户以为没有流量。
    if [[ "$(jq -r '.settings.render.counters' "$state")" != "true" ]]; then
        fwctl_err "counter 已在 settings.render.counters 中关闭，无法统计"
        fwctl_err "开启方式：把该字段改回 true 后执行 fw render"
        return 1
    fi

    counters=$(stats_collect) || return 1

    if [[ -n "$ref" ]]; then
        id=$(model_resolve "$state" rule "$ref") || return 1
        counters=$(jq -c --arg id "$id" '{($id): .[$id]}' <<< "$counters")
    fi

    if [[ "${FWCTL_JSON:-0}" == 1 ]]; then
        # JSON 输出同时给出 id 与 name，便于脚本按稳定标识消费。
        jq -c --argjson counters "$counters" '
            [ (.rules[] | {id, name, type}),
              {id: "ssh", name: "ssh", type: "builtin"},
              {id: "ports-tcp", name: "ports-tcp", type: "builtin"},
              {id: "ports-udp", name: "ports-udp", type: "builtin"},
              {id: "syn-limit", name: "syn-limit", type: "builtin"} ]
            | map(. + {counter: ($counters[.id] // null)})
            | map(select(.counter != null))
        ' "$state"
        return 0
    fi

    # 表格输出优先显示 name。
    {
        printf 'NAME                 TYPE      PACKETS        BYTES\n'
        jq -r --argjson counters "$counters" '
            [ (.rules[] | {id, name, type}),
              {id: "ssh", name: "ssh", type: "builtin"},
              {id: "ports-tcp", name: "ports-tcp", type: "builtin"},
              {id: "ports-udp", name: "ports-udp", type: "builtin"},
              {id: "syn-limit", name: "syn-limit", type: "builtin"} ]
            | map(. + {counter: ($counters[.id] // null)})
            | map(select(.counter != null))
            | .[]
            | "\(.name)\t\(.type)\t\(.counter.packets)\t\(.counter.bytes)"
        ' "$state" |
        while IFS=$'\t' read -r name type packets bytes; do
            printf '%-20s %-9s %-14s %s\n' \
                "$name" "$type" "$packets" "$(_stats_human_bytes "$bytes")"
        done
    }
    return 0
}

# 清零计数器。
#
# 只重放一次渲染产物即可：整表被 delete 后重建，计数器随之归零。
# 这不改变任何规则语义，因此不需要走完整事务。
stats_reset() {
    local conf="${FWCTL_BUILD_DIR:-$(txn_var_dir)/build}/nft.conf"

    if [[ ! -f "$conf" ]]; then
        fwctl_err "找不到已发布的规则文件：$conf"
        fwctl_err "请先执行 fw render"
        return 1
    fi
    if ! "$(txn_nft_bin)" -f "$conf"; then
        fwctl_err "清零计数器失败"
        return 1
    fi
    fwctl_ok "计数器已清零"
    return 0
}
