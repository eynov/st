#!/bin/bash
# ==============================================================================
# State Store：instances.json 全局状态索引读写引擎
# ==============================================================================
# 依赖 common.sh 已被引入（STATE_FILE 变量）

# ------------------------------------------------------------------------------
# 初始化 state 文件（不存在则创建空结构）
# ------------------------------------------------------------------------------
state_init() {
    if [ ! -f "$STATE_FILE" ]; then
        echo '{"instances":{}}' > "$STATE_FILE"
    fi
}

# ------------------------------------------------------------------------------
# 写入 / 更新一个实例记录
# 用法: state_set <port> <json_payload>
# 示例: state_set 8388 '{"protocol":"SS","enabled":true,...}'
# ------------------------------------------------------------------------------
state_set() {
    local port="$1"
    local payload="$2"
    state_init

    local tmp
    tmp=$(mktemp)
    if jq --arg p "$port" --argjson v "$payload" \
        '.instances[$p] = $v' "$STATE_FILE" > "$tmp"; then
        mv "$tmp" "$STATE_FILE"
    else
        rm -f "$tmp"
        err "state_set: 写入端口 [${port}] 失败，JSON 格式异常"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 读取一个实例的完整 JSON 对象
# 用法: state_get <port>
# ------------------------------------------------------------------------------
state_get() {
    local port="$1"
    state_init
    jq -r --arg p "$port" '.instances[$p] // empty' "$STATE_FILE"
}

# ------------------------------------------------------------------------------
# 读取一个实例的单个字段值
# 用法: state_get_field <port> <field>
# 示例: state_get_field 8388 protocol
# ------------------------------------------------------------------------------
state_get_field() {
    local port="$1"
    local field="$2"
    state_init
    jq -r --arg p "$port" --arg f "$field" \
        '.instances[$p][$f] // empty' "$STATE_FILE"
}

# ------------------------------------------------------------------------------
# 删除一个实例记录（硬删除）
# 用法: state_del <port>
# ------------------------------------------------------------------------------
state_del() {
    local port="$1"
    state_init

    local tmp
    tmp=$(mktemp)
    if jq --arg p "$port" 'del(.instances[$p])' "$STATE_FILE" > "$tmp"; then
        mv "$tmp" "$STATE_FILE"
    else
        rm -f "$tmp"
        err "state_del: 删除端口 [${port}] 失败"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 列出所有实例的端口号
# 用法: state_list
# ------------------------------------------------------------------------------
state_list() {
    state_init
    jq -r '.instances | keys[]' "$STATE_FILE" 2>/dev/null
}

# ------------------------------------------------------------------------------
# 列出所有 enabled=true 的实例端口号
# 用法: state_list_enabled
# ------------------------------------------------------------------------------
state_list_enabled() {
    state_init
    jq -r '.instances | to_entries[] | select(.value.enabled == true) | .key' \
        "$STATE_FILE" 2>/dev/null
}

# ------------------------------------------------------------------------------
# 软停用：保留数据，标记 enabled=false
# 用法: state_disable <port>
# ------------------------------------------------------------------------------
state_disable() {
    local port="$1"
    local tmp
    tmp=$(mktemp)
    if jq --arg p "$port" '.instances[$p].enabled = false' \
        "$STATE_FILE" > "$tmp"; then
        mv "$tmp" "$STATE_FILE"
    else
        rm -f "$tmp"
        err "state_disable: 操作失败"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 软启用：标记 enabled=true
# 用法: state_enable <port>
# ------------------------------------------------------------------------------
state_enable() {
    local port="$1"
    local tmp
    tmp=$(mktemp)
    if jq --arg p "$port" '.instances[$p].enabled = true' \
        "$STATE_FILE" > "$tmp"; then
        mv "$tmp" "$STATE_FILE"
    else
        rm -f "$tmp"
        err "state_enable: 操作失败"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 从 instances/*/meta.json 自动同步到 State Store
# 用于兼容旧版本目录实例，防止 instances.json 丢失后面板看不到实例
# ------------------------------------------------------------------------------
state_sync_from_instances() {
    state_init

    local meta port payload

    for meta in "$INST_DIR"/*/meta.json; do
        [ -f "$meta" ] || continue

        port=$(jq -r '.port // empty' "$meta" 2>/dev/null)

        if [ -z "$port" ] || [ "$port" = "null" ]; then
            port=$(basename "$(dirname "$meta")")
        fi

        if [ -z "$port" ]; then
            continue
        fi

        payload=$(jq '.enabled = (.enabled // true)' "$meta" 2>/dev/null)
        if [ -z "$payload" ]; then
            warn "跳过异常 meta 文件: $meta"
            continue
        fi

        state_set "$port" "$payload"
    done
}
