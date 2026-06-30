#!/bin/bash
# ==============================================================================
# 运行时编译器
# 职责：instances.json → output/config.json + output/sub.yaml
# 不触碰 systemd，不调用 service.sh
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/core/common.sh"
source "$BASE_DIR/core/state.sh"
source "$BASE_DIR/core/registry.sh"

# 注：load_protocols 由入口脚本 sb 统一调用，此处不再重复调用。
# registry.sh 仍需 source，因为本文件依赖 PROTO_INBOUND / PROTO_CLASH /
# PROTO_SURGE 等关联数组的声明。

# ------------------------------------------------------------------------------
# 编译 output/config.json
# ------------------------------------------------------------------------------
compile_config() {
    ensure_dirs

    local ids
    mapfile -t ids < <(state_list_enabled)

    if [ "${#ids[@]}" -eq 0 ]; then
        warn "无任何启用中的实例，config.json 不会生成。"
        return 1
    fi

    local inbounds_json="[]"

    for id in "${ids[@]}"; do
        local payload proto fn inbound_fragment

        payload=$(state_get "$id")
        [ -z "$payload" ] && { warn "实例 [${id}] 数据为空，跳过"; continue; }

        proto=$(echo "$payload" | jq -r '.protocol')
        fn="${PROTO_INBOUND[$proto]}"

        if [ -z "$fn" ] || ! declare -F "$fn" >/dev/null 2>&1; then
            warn "协议 [${proto}] 未注册 inbound 函数，跳过 [${id}]"
            continue
        fi

        inbound_fragment=$("$fn" "$payload")
        [ -z "$inbound_fragment" ] && { warn "[${id}] inbound 片段为空，跳过"; continue; }

        inbounds_json=$(echo "$inbounds_json" \
            | jq --argjson ib "$inbound_fragment" '. += [$ib]')
    done

    jq -n \
        --argjson inbounds "$inbounds_json" \
        '{
            "log": { "level": "info", "timestamp": true },
            "inbounds": $inbounds,
            "outbounds": [{ "type": "direct" }]
        }' > "$OUTPUT_CONFIG"

    ok "config.json 已编译（${#ids[@]} 个实例）"
}

# ------------------------------------------------------------------------------
# 编译 output/sub.yaml
# ------------------------------------------------------------------------------
compile_sub() {
    ensure_dirs

    local ids
    mapfile -t ids < <(state_list_enabled)

    if [ "${#ids[@]}" -eq 0 ]; then
        warn "无任何启用中的实例，sub.yaml 不会生成。"
        return 1
    fi

    local ipv4
    ipv4=$(get_ipv4)
    [ -z "$ipv4" ] && warn "无法获取公网 IPv4，订阅可能不完整。"

    local clash_proxies="[]"
    local surge_lines=()

    for id in "${ids[@]}"; do
        local payload proto

        payload=$(state_get "$id")
        [ -z "$payload" ] && continue
        proto=$(echo "$payload" | jq -r '.protocol')

        # Clash
        local clash_fn="${PROTO_CLASH[$proto]}"
        if [ -n "$clash_fn" ] && declare -F "$clash_fn" >/dev/null 2>&1; then
            local clash_node
            clash_node=$("$clash_fn" "$payload" "$ipv4")
            [ -n "$clash_node" ] && \
                clash_proxies=$(echo "$clash_proxies" \
                    | jq --argjson n "$clash_node" '. += [$n]')
        fi

        # Surge
        local surge_fn="${PROTO_SURGE[$proto]}"
        if [ -n "$surge_fn" ] && declare -F "$surge_fn" >/dev/null 2>&1; then
            local surge_line
            surge_line=$("$surge_fn" "$payload" "$ipv4")
            [ -n "$surge_line" ] && surge_lines+=("$surge_line")
        fi
    done

    {
        echo "# 自动生成 - $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "proxies:"
        echo "$clash_proxies" | jq -r '.[] | "  - " + (. | tojson)' 2>/dev/null
        echo ""
        echo "# [Proxy]"
        for line in "${surge_lines[@]}"; do
            echo "# ${line}"
        done
    } > "$OUTPUT_SUB"

    ok "sub.yaml 已生成（${#ids[@]} 个节点）"
}

# ------------------------------------------------------------------------------
# 全量重编译
# ------------------------------------------------------------------------------
compile_all() {
    compile_config && compile_sub
}

# ------------------------------------------------------------------------------
# 打印单个实例分享 URI
# 用法: print_uri <id>
# ------------------------------------------------------------------------------
print_uri() {
    local id="$1"
    local payload proto fn ipv4

    payload=$(state_get "$id")
    [ -z "$payload" ] && { err "实例 [${id}] 不存在"; return 1; }

    proto=$(echo "$payload" | jq -r '.protocol')
    fn="${PROTO_URI[$proto]}"
    ipv4=$(get_ipv4)

    if [ -z "$fn" ] || ! declare -F "$fn" >/dev/null 2>&1; then
        warn "协议 [${proto}] 未注册 URI 函数"
        return 1
    fi

    "$fn" "$payload" "$ipv4"
}

