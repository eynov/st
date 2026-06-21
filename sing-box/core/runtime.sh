#!/bin/bash
# 启动、停止、重启、生成分享链接等运行时状态引擎

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/core/common.sh"

generate_dynamic_uri() {
    local target_dir="$1"
    local mode="$2"
    local meta_file="${target_dir}/meta.json"
    
    if [ ! -f "$meta_file" ]; then return; fi
    
    local current_ip=$(get_ip)
    local proto=$(jq -r '.protocol' "$meta_file")
    local port=$(jq -r '.port' "$meta_file")
    local pwd=$(jq -r '.password' "$meta_file")
    local method=$(jq -r '.method // "2022-blake3-aes-256-gcm"' "$meta_file")
    
    if [ "$mode" == "uri" ]; then
        case "$proto" in
            "SS")
                local b64=$(echo -n "${method}:${pwd}" | base64 | tr -d '\n')
                echo "ss://${b64}@${current_ip}:${port}#SS_${port}"
                ;;
            "SS2022")
                echo "ss://${method}:${pwd}@${current_ip}:${port}#SS2022_${port}"
                ;;
            "HY2")
                local sni=$(jq -r '.sni' "$meta_file")
                echo "hysteria2://${pwd}@${current_ip}:${port}?sni=${sni}&insecure=1#HY2_${port}"
                ;;
        esac
    elif [ "$mode" == "surge" ]; then
        case "$proto" in
            "SS") echo "🟢 SS_${port} = ss, ${current_ip}, ${port}, encrypt-method=${method}, password=${pwd}" ;;
            "SS2022") echo "🟢 SS2022_${port} = ss, ${current_ip}, ${port}, encrypt-method=${method}, password=${pwd}" ;;
            "HY2") local sni=$(jq -r '.sni' "$meta_file")
                   echo "🔵 HY2_${port} = hysteria2, ${current_ip}, ${port}, password=${pwd}, sni=${sni}, skip-cert-verify=true" ;;
        esac
    fi
}

restart_all() {
    local has_any=false
    for d in "${INST_DIR}"/*; do
        [ -e "$d" ] || break
        [ -d "$d" ] || continue
        local p=$(basename "$d")
        if [ -f "/etc/systemd/system/sb-${p}.service" ]; then
            has_any=true
            systemctl restart sb-${p}
            echo "🔄 实例 [${p}] 已完成平滑热重载"
        fi
    done
    $has_any && ok "所有活跃运行期实例已重新调配上线。" || warn "任务终止：未检索到可调度的实体实例。"
}
