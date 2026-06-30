#!/bin/bash
# ==============================================================================
# State Store：instances.json 唯一状态层
#
# 数据结构：
# {
#   "instances": {
#     "is01": { "id": "is01", "protocol": "VLESS", "port": 443, ... },
#     "is02": { "id": "is02", "protocol": "HY2",   "port": 443, ... }
#   }
# }
#
# 所有操作以 id 为主键。
# 支持 proto:port → id 反查。
# ==============================================================================

state_init() {
    [ -f "$STATE_FILE" ] || echo '{"instances":{}}' > "$STATE_FILE"
}

# ------------------------------------------------------------------------------
# ID 生成：递增 is01 is02 ...
# ------------------------------------------------------------------------------
state_next_id() {
    state_init
    local max
    max=$(jq -r '.instances | keys[] | select(test("^is[0-9]+$")) | ltrimstr("is") | tonumber' \
        "$STATE_FILE" 2>/dev/null | sort -n | tail -1)
    local next=$(( ${max:-0} + 1 ))
    printf "is%02d" "$next"
}

# ------------------------------------------------------------------------------
# 写入 / 更新实例（以 id 为 key）
# 用法: state_set <id> <json_payload>
# ------------------------------------------------------------------------------
state_set() {
    local id="$1"
    local payload="$2"
    state_init

    local tmp
    tmp=$(mktemp)
    if jq --arg id "$id" --argjson v "$payload" \
        '.instances[$id] = $v' "$STATE_FILE" > "$tmp"; then
        mv "$tmp" "$STATE_FILE"
    else
        rm -f "$tmp"
        err "state_set: 写入 [${id}] 失败"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 读取实例（by id）
# ------------------------------------------------------------------------------
state_get() {
    local id="$1"
    state_init
    jq -r --arg id "$id" '.instances[$id] // empty' "$STATE_FILE"
}

# ------------------------------------------------------------------------------
# 读取单个字段（by id）
# ------------------------------------------------------------------------------
state_get_field() {
    local id="$1"
    local field="$2"
    state_init
    jq -r --arg id "$id" --arg f "$field" \
        '.instances[$id][$f] // empty' "$STATE_FILE"
}

# ------------------------------------------------------------------------------
# proto:port → id 反查
# 用法: state_find <VLESS> <443>  → is01
# ------------------------------------------------------------------------------
state_find() {
    local proto="${1^^}"
    local port="$2"
    state_init
    jq -r --arg proto "$proto" --argjson port "$port" \
        '.instances | to_entries[]
         | select(.value.protocol == $proto and .value.port == $port)
         | .key' "$STATE_FILE" 2>/dev/null | head -1
}

# ------------------------------------------------------------------------------
# 解析用户输入 → id
# 支持：is01 | VLESS 443 | hy2 443
# 用法: resolve_id <arg1> [arg2]
# ------------------------------------------------------------------------------
resolve_id() {
    local arg1="${1:-}"
    local arg2="${2:-}"

    # 直接是 id
    if [[ "$arg1" =~ ^is[0-9]+$ ]]; then
        echo "$arg1"
        return
    fi

    # proto port
    if [ -n "$arg2" ]; then
        local id
        id=$(state_find "$arg1" "$arg2")
        if [ -z "$id" ]; then
            err "找不到实例 [${arg1^^}:${arg2}]"
            return 1
        fi
        echo "$id"
        return
    fi

    err "无法识别实例标识: ${arg1}"
    return 1
}

# ------------------------------------------------------------------------------
# 删除实例
# ------------------------------------------------------------------------------
state_del() {
    local id="$1"
    state_init

    local tmp
    tmp=$(mktemp)
    if jq --arg id "$id" 'del(.instances[$id])' "$STATE_FILE" > "$tmp"; then
        mv "$tmp" "$STATE_FILE"
    else
        rm -f "$tmp"
        err "state_del: 删除 [${id}] 失败"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 列出所有实例 id
# ------------------------------------------------------------------------------
state_list() {
    state_init
    jq -r '.instances | keys[]' "$STATE_FILE" 2>/dev/null
}

# ------------------------------------------------------------------------------
# 列出所有 enabled=true 的实例 id
# ------------------------------------------------------------------------------
state_list_enabled() {
    state_init
    jq -r '.instances | to_entries[]
        | select(.value.enabled == true)
        | .key' "$STATE_FILE" 2>/dev/null
}

# ------------------------------------------------------------------------------
# 软停用 / 软启用
# ------------------------------------------------------------------------------
state_disable() {
    local id="$1"
    _state_set_enabled "$id" false
}

state_enable() {
    local id="$1"
    _state_set_enabled "$id" true
}

_state_set_enabled() {
    local id="$1"
    local val="$2"
    state_init

    local tmp
    tmp=$(mktemp)
    if jq --arg id "$id" --argjson v "$val" \
        '.instances[$id].enabled = $v
         | .instances[$id].updated_at = (now | strftime("%Y-%m-%d %H:%M:%S"))' \
        "$STATE_FILE" > "$tmp"; then
        mv "$tmp" "$STATE_FILE"
    else
        rm -f "$tmp"
        err "_state_set_enabled: 操作失败"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 更新任意字段（patch）
# 用法: state_patch <id> <jq_filter>
# 示例: state_patch is01 '.port = 8443'
# ------------------------------------------------------------------------------
state_patch() {
    local id="$1"
    local filter="$2"
    state_init

    local tmp
    tmp=$(mktemp)
    if jq --arg id "$id" \
        "(.instances[\$id]) |= ( ${filter} )
         | .instances[\$id].updated_at = (now | strftime(\"%Y-%m-%d %H:%M:%S\"))" \
        "$STATE_FILE" > "$tmp"; then
        mv "$tmp" "$STATE_FILE"
    else
        rm -f "$tmp"
        err "state_patch: 更新 [${id}] 失败"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 检查 id 是否存在
# ------------------------------------------------------------------------------
state_exists() {
    local id="$1"
    state_init
    local val
    val=$(jq -r --arg id "$id" '.instances[$id] // empty' "$STATE_FILE")
    [ -n "$val" ]
}
