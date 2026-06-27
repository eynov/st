#!/bin/bash
# ==============================================================================
# 运行时引擎：分享链接生成 + 全量热重载
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/core/common.sh"
source "$BASE_DIR/core/state.sh"

# ------------------------------------------------------------------------------
# 动态生成分享链接（双栈：IPv4 + IPv6 各一条）
# 用法: generate_dynamic_uri <instance_dir> <uri|surge>
# ------------------------------------------------------------------------------
generate_dynamic_uri() {
    local target_dir="$1"
    local mode="$2"
    local meta_file="${target_dir}/meta.json"

    [ -f "$meta_file" ] || return

    local ipv4 ipv6 proto fn output=""
    ipv4=$(get_ipv4)
    ipv6=$(get_ipv6)
    proto=$(jq -r '.protocol // empty' "$meta_file")

    if [ -z "$proto" ]; then
        warn "meta.json 中缺少 protocol 字段，无法生成分享链接。"
        return 1
    fi

    case "$mode" in
        uri)   fn="${PROTO_URI[$proto]}"   ;;
        surge) fn="${PROTO_SURGE[$proto]}" ;;
        *)
            warn "未知分享链接生成模式: ${mode}"
            return 1
            ;;
    esac

    if [ -z "$fn" ] || ! declare -F "$fn" >/dev/null 2>&1; then
        warn "协议 [${proto}] 未注册 ${mode} 生成函数。"
        return 1
    fi

    if [ -n "$ipv4" ]; then
        output+="$("$fn" "$meta_file" "$ipv4")"$'\n'
    else
        warn "未能获取 IPv4 地址，跳过。"
    fi

    if [ -n "$ipv6" ]; then
        local ip_arg="$ipv6"
        [ "$mode" = "uri" ] && ip_arg="[${ipv6}]"
        output+="$("$fn" "$meta_file" "$ip_arg")"$'\n'
    else
        warn "未能获取 IPv6 地址，跳过。"
    fi

    printf '%s' "$output"
}

# ------------------------------------------------------------------------------
# 全量热重载（只重启 enabled=true 的实例）
# ------------------------------------------------------------------------------
restart_all() {
    local has_any=false
    local ports

    mapfile -t ports < <(state_list_enabled)

    if [ "${#ports[@]}" -eq 0 ]; then
        warn "任务终止：State Store 中无任何启用中的实例。"
        return
    fi

    for p in "${ports[@]}"; do
        if [ -f "/etc/systemd/system/sb-${p}.service" ]; then
            has_any=true
            systemctl restart "sb-${p}"
            ok "实例 [${p}] 已完成平滑热重载"
        else
            warn "实例 [${p}] 在 State Store 中存在，但 Systemd 服务文件缺失，跳过。"
        fi
    done

    $has_any && ok "所有活跃实例已重新调配上线。"
}
