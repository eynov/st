#!/bin/bash
# ==============================================================================
# 运行时引擎：分享链接生成 + 全量热重载
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/core/common.sh"
source "$BASE_DIR/core/state.sh"

# ------------------------------------------------------------------------------
# 动态生成分享链接
# 用法: generate_dynamic_uri <instance_dir> <uri|surge>
#
# 升级点：
# 不再在 runtime.sh 写死 SS / SS2022 / HY2 case。
# 改为从协议插件注册表 PROTO_URI / PROTO_SURGE 自动调用。
#
# 每个协议插件只需要提供：
#   uri_xxx <meta_file> <current_ip>
#   surge_xxx <meta_file> <current_ip>
# ------------------------------------------------------------------------------
generate_dynamic_uri() {
    local target_dir="$1"
    local mode="$2"
    local meta_file="${target_dir}/meta.json"

    [ -f "$meta_file" ] || return

    local current_ip proto fn
    current_ip=$(get_ip)
    proto=$(jq -r '.protocol // empty' "$meta_file")

    if [ -z "$proto" ]; then
        warn "meta.json 中缺少 protocol 字段，无法生成分享链接。"
        return 1
    fi

    case "$mode" in
        uri)
            fn="${PROTO_URI[$proto]}"
            ;;
        surge)
            fn="${PROTO_SURGE[$proto]}"
            ;;
        *)
            warn "未知分享链接生成模式: ${mode}"
            return 1
            ;;
    esac

    if [ -z "$fn" ]; then
        warn "协议 [${proto}] 未注册 ${mode} 生成函数。"
        return 1
    fi

    if ! declare -F "$fn" >/dev/null 2>&1; then
        warn "协议 [${proto}] 的 ${mode} 生成函数 [${fn}] 不存在。"
        return 1
    fi

    "$fn" "$meta_file" "$current_ip"
}

# ------------------------------------------------------------------------------
# 全量热重载
# 升级点：从 state_list_enabled 读取端口，不再遍历目录
# ------------------------------------------------------------------------------
restart_all() {
    local has_any=false
    local ports

    # 只重启 enabled=true 的实例
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