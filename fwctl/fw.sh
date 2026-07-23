#!/bin/bash
# --- fw.sh (路径自动识别版，改名/换目录无需改代码) ---

# ── 🔎 路径自动识别：永远通过软链接/真实文件位置反查项目目录 ──
if [ -L "${BASH_SOURCE[0]}" ]; then
    REAL_SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "")
    if [ -z "$REAL_SCRIPT_PATH" ]; then
        REAL_SCRIPT_PATH=$(ls -l "${BASH_SOURCE[0]}" | awk -F '-> ' '{print $2}')
    fi
else
    REAL_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
fi

BASE_DIR="$(cd "$(dirname "$REAL_SCRIPT_PATH")" 2>/dev/null && pwd)"

# ── 🛟 锚点校验：确认这确实是项目目录（render.sh 必须存在）──
if [ -z "$BASE_DIR" ] || [ ! -f "$BASE_DIR/render.sh" ]; then
    # 兜底：脚本可能被复制而非软链接调用，自动在 /opt 下搜索一次
    FOUND=$(find /opt -maxdepth 2 -name "render.sh" 2>/dev/null | head -n1)
    if [ -n "$FOUND" ]; then
        BASE_DIR="$(cd "$(dirname "$FOUND")" && pwd)"
    else
        echo "❌ 无法定位项目目录（找不到 render.sh）"
        echo "   请通过 install.sh 安装，或直接用完整路径运行本脚本"
        exit 1
    fi
fi

STATE_FILE="$BASE_DIR/state.json"
RENDER_BIN="$BASE_DIR/render.sh"

if [[ $EUID -ne 0 ]]; then
   echo "❌ 请以 root 权限运行此脚本"
   exit 1
fi

# ── 🛡️ 状态文件合规性防御 ──
if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ] || ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
    echo '{"nat_mode":"auto","snat_address":null,"forwards":[],"open_ports":{"tcp":[],"udp":[]},"blacklist":[]}' > "$STATE_FILE"
    chmod 644 "$STATE_FILE"
fi

trigger_render() {
    echo "⚙️ 正在通过模板编译新规则..."
    bash "$RENDER_BIN"
    if [ $? -eq 0 ]; then
        echo "✅ 编译成功，规则已实时应用！"
    else
        echo "❌ 编译或加载失败；上一份运行配置和持久配置保持不变。"
        return 1
    fi
}

validate_protocol() {
    case "$1" in
        tcp|udp) ;;
        *)
            echo "❌ 非法协议 '$1'；只允许 tcp 或 udp" >&2
            return 1
            ;;
    esac
}

validate_port() {
    local port=$1
    if [[ ! "$port" =~ ^[0-9]+$ ]] || ((10#$port < 1 || 10#$port > 65535)); then
        echo "❌ 非法端口 '$port'；必须是 1-65535 的整数" >&2
        return 1
    fi
}

port_list() {
    echo "TCP: $(jq -r '.open_ports.tcp | map(tonumber) | unique | sort | join(", ")' "$STATE_FILE")"
    echo "UDP: $(jq -r '.open_ports.udp | map(tonumber) | unique | sort | join(", ")' "$STATE_FILE")"
}

port_update() {
    local action=$1 proto=$2 port=$3 candidate action_label
    validate_protocol "$proto" || return 1
    validate_port "$port" || return 1

    if [[ "$action" == add ]] && jq -e --arg proto "$proto" --arg port "$port" \
        '.open_ports[$proto] | index($port) != null' "$STATE_FILE" >/dev/null; then
        echo "ℹ️ $proto/$port 已存在，无需重复添加"
        return 0
    fi
    if [[ "$action" == remove ]] && ! jq -e --arg proto "$proto" --arg port "$port" \
        '.open_ports[$proto] | index($port) != null' "$STATE_FILE" >/dev/null; then
        echo "ℹ️ $proto/$port 不存在，未做修改"
        return 0
    fi

    candidate=$(mktemp "$(dirname "$STATE_FILE")/.state.json.XXXXXX")
    if [[ "$action" == add ]]; then
        jq --arg proto "$proto" --arg port "$port" \
            '.open_ports[$proto] += [$port]
             | .open_ports[$proto] |= (map(tonumber) | unique | sort | map(tostring))' \
            "$STATE_FILE" > "$candidate"
    else
        jq --arg proto "$proto" --arg port "$port" \
            '.open_ports[$proto] -= [$port]
             | .open_ports[$proto] |= (map(tonumber) | unique | sort | map(tostring))' \
            "$STATE_FILE" > "$candidate"
    fi
    chmod 0644 "$candidate"

    if FWCTL_STATE_FILE="$candidate" bash "$RENDER_BIN"; then
        mv -f "$candidate" "$STATE_FILE"
        [[ "$action" == add ]] && action_label=添加 || action_label=删除
        echo "✅ 已${action_label} ${proto}/${port}"
    else
        rm -f "$candidate"
        echo "❌ 端口变更未保存" >&2
        return 1
    fi
}

cli_usage() {
    local command_name
    command_name=$(basename "${BASH_SOURCE[0]}" .sh)
    cat <<'EOF'
用法：
EOF
    echo "  $command_name port add tcp|udp PORT"
    echo "  $command_name port remove tcp|udp PORT"
    echo "  $command_name port list"
    echo "  $command_name render"
}

if [[ $# -gt 0 ]]; then
    case "${1:-}" in
        port)
            case "${2:-}" in
                add|remove)
                    [[ $# -eq 4 ]] || { cli_usage >&2; exit 2; }
                    port_update "$2" "$3" "$4"
                    exit $?
                    ;;
                list)
                    [[ $# -eq 2 ]] || { cli_usage >&2; exit 2; }
                    port_list
                    exit 0
                    ;;
                *)
                    cli_usage >&2
                    exit 2
                    ;;
            esac
            ;;
        render)
            [[ $# -eq 1 ]] || { cli_usage >&2; exit 2; }
            trigger_render
            exit $?
            ;;
        -h|--help|help)
            cli_usage
            exit 0
            ;;
        *)
            cli_usage >&2
            exit 2
            ;;
    esac
fi

add_forward() {
    read -p "🔹 请输入目标落地 IP 或域名 (可带端口如 127.0.0.1:443): " dest_addr

    if [[ "$dest_addr" =~ ^([^:]+):([0-9]+)$ ]]; then
        raw_host="${BASH_REMATCH[1]}"
        dest_port_default="${BASH_REMATCH[2]}"
    else
        raw_host="$dest_addr"
        dest_port_default=""
    fi

    if [[ "$raw_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        dip="$raw_host"
    else
        dip=$(dig +short "$raw_host" | tail -n1)
        if [ -z "$dip" ]; then echo "❌ 域名解析失败！"; return; fi
    fi

    read -p "🔹 请输入起始端口: " sport
    read -p "🔹 请输入结束端口 (若单端口直接回车): " dport
    [ -z "$dport" ] && dport="$sport"

    if [ -n "$dest_port_default" ]; then
        dest_port="$dest_port_default"
        echo "ℹ️  目标端口自动使用: $dest_port"
    else
        read -p "🔹 请输入目标端口 (直接回车默认与起始端口相同): " dest_port
        [ -z "$dest_port" ] && dest_port="$sport"
    fi

    read -p "🔹 请输入协议 (tcp/udp/both, 默认 both): " proto
    [ -z "$proto" ] && proto="both"

    protocols=("tcp" "udp")
    [ "$proto" == "tcp" ] && protocols=("tcp")
    [ "$proto" == "udp" ] && protocols=("udp")

    for p in "${protocols[@]}"; do
        exists=$(jq --arg sport "$sport" --arg dport "$dport" --arg proto "$p" \
            '.forwards[]? | select(.sport==$sport and .dport==$dport and .proto==$proto)' "$STATE_FILE" 2>/dev/null)
        if [ -z "$exists" ]; then
            jq --arg sport "$sport" --arg dport "$dport" --arg dip "$dip" \
               --arg proto "$p" --arg dest_port "$dest_port" \
               '.forwards += [{"sport":$sport,"dport":$dport,"dip":$dip,"proto":$proto,"dest_port":$dest_port}]' \
               "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
        fi
    done
    trigger_render
}

del_forward() {
    show_forward
    read -p "❌ 请输入要删除的规则 Index: " idx
    if [ -n "$idx" ]; then
        jq "del(.forwards[$idx])" "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
        trigger_render
    fi
}

show_forward() {
    echo -e "\n=== 📍 当前端口转发规则列表 ==="
    echo -e "Index\t协议\t本地端口\t目标映射"
    echo -e "-----------------------------------------------"
    jq -r '.forwards | to_entries[] | "\(.key)\t\(.value.proto)\t\(.value.sport)-\(.value.dport)\t-> \(.value.dip):\(.value.dest_port)"' "$STATE_FILE" 2>/dev/null
    echo ""
}

add_port() {
    read -p "🔹 请输入放行端口 (1-65535): " port
    read -p "🔹 协议类型 (tcp/udp): " proto
    port_update add "$proto" "$port"
}

del_port() {
    read -p "❌ 请输入要取消放行的端口: " port
    read -p "🔹 协议类型 (tcp/udp): " proto
    port_update remove "$proto" "$port"
}

show_ports() {
    echo -e "\n=== 🔓 开放端口一览 ==="
    echo "TCP 开放: $(jq -r '.open_ports.tcp? | join(", ")' "$STATE_FILE" 2>/dev/null)"
    echo "UDP 开放: $(jq -r '.open_ports.udp? | join(", ")' "$STATE_FILE" 2>/dev/null)"
    echo ""
}

add_blacklist() {
    read -p "🚫 请输入要封禁的 IP 或网段: " ip
    jq --arg ip "$ip" '.blacklist += [$ip] | .blacklist |= unique' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    trigger_render
}

del_blacklist() {
    read -p "🟢 请输入要解封的 IP 或网段: " ip
    jq --arg ip "$ip" '.blacklist -= [$ip]' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    trigger_render
}

show_blacklist() {
    echo -e "\n=== 🚫 恶意 IP 黑名单 ==="
    jq -r '.blacklist[]?' "$STATE_FILE" 2>/dev/null
    echo ""
}

# ── 🔄 纯净循环控制台 ──────────────────────────────────────────
while true; do
    echo "========================="
    echo "   Firewall Manager   "
    echo "========================="
    echo "1. 添加端口转发    2. 删除端口转发    3. 查看端口转发"
    echo "-------------------------------------------------"
    echo "4. 放行端口        5. 删除放行端口    6. 查看放行端口"
    echo "-------------------------------------------------"
    echo "7. 封禁IP          8. 解封IP          9. 查看黑名单"
    echo "-------------------------------------------------"
    echo "10. SSH防爆破 (模版默认常开)"
    echo "11. DDOS防护  (模版默认常开)"
    echo "12. 重载配置  (强制重新编译)"
    echo "0. 退出"
    echo "========================="
    read -p "请选择操作 [0-12]: " opt
    case $opt in
        1) add_forward ;;
        2) del_forward ;;
        3) show_forward ;;
        4) add_port ;;
        5) del_port ;;
        6) show_ports ;;
        7) add_blacklist ;;
        8) del_blacklist ;;
        9) show_blacklist ;;
        10|11) echo "ℹ️ 防护逻辑内嵌于 rules/filter.nft.tpl，无需开关。" ;;
        12) trigger_render ;;
        0) exit 0 ;;
        *) echo "❌ 无效输入" ;;
    esac
done
