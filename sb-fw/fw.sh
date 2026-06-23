#!/bin/bash
# --- fw.sh ---

# 🔹 动态获取脚本所在目录的绝对路径
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_FILE="$BASE_DIR/state.json"
RENDER_BIN="$BASE_DIR/render.sh"

if [[ $EUID -ne 0 ]]; then
   echo "❌ 请以 root 权限运行此脚本"
   exit 1
fi

# 确保状态文件结构完备
if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
    echo '{"forwards":[],"open_ports":{"tcp":[],"udp":[]},"blacklist":[]}' > "$STATE_FILE"
fi

trigger_render() {
    echo "⚙️ 正在通过模板编译新规则..."
    bash "$RENDER_BIN"
    if [ $? -eq 0 ]; then
        echo "✅ 编译成功，规则已实时应用！"
    else
        echo "❌ 编译失败，内核已安全回滚到上一次可用状态。"
    fi
}

add_forward() {
    read -p "🔹 请输入目标落地 IP 或域名: " dest_addr
    if [[ ! "$dest_addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        dip=$(dig +short "$dest_addr" | tail -n1)
        if [ -z "$dip" ]; then echo "❌ 域名解析失败！"; return; fi
    else
        dip="$dest_addr"
    fi
    
    read -p "🔹 请输入起始端口: " sport
    read -p "🔹 请输入结束端口 (若单端口直接回车): " dport
    [ -z "$dport" ] && dport="$sport"
    read -p "🔹 请输入协议 (tcp/udp/both, 默认 both): " proto
    [ -z "$proto" ] && proto="both"

    protocols=("tcp" "udp")
    [ "$proto" == "tcp" ] && protocols=("tcp")
    [ "$proto" == "udp" ] && protocols=("udp")

    for p in "${protocols[@]}"; do
        exists=$(jq --arg sport "$sport" --arg dport "$dport" --arg proto "$p" \
            '.forwards[] | select(.sport==$sport and .dport==$dport and .proto==$proto)' "$STATE_FILE")
        if [ -z "$exists" ]; then
            jq --arg sport "$sport" --arg dport "$dport" --arg dip "$dip" --arg proto "$p" \
               '.forwards += [{"sport":$sport, "dport":$dport, "dip":$dip, "proto":$proto}]' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
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
    jq -r '.forwards | to_entries[] | "\(.key)\t\(.value.proto)\t\(.value.sport)-\(.value.dport)\t-> \(.value.dip)"' "$STATE_FILE"
    echo ""
}

add_port() {
    read -p "🔹 请输入放行端口或段 (例如 80 或 80-90): " port
    read -p "🔹 协议类型 (tcp/udp/both): " proto
    if [ "$proto" == "tcp" ] || [ "$proto" == "both" ]; then
        jq --arg port "$port" '.open_ports.tcp += [$port] | .open_ports.tcp |= unique' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    if [ "$proto" == "udp" ] || [ "$proto" == "both" ]; then
        jq --arg port "$port" '.open_ports.udp += [$port] | .open_ports.udp |= unique' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    trigger_render
}

del_port() {
    read -p "❌ 请输入要取消放行的端口: " port
    read -p "🔹 协议类型 (tcp/udp/both): " proto
    if [ "$proto" == "tcp" ] || [ "$proto" == "both" ]; then
        jq --arg port "$port" '.open_ports.tcp -= [$port]' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    if [ "$proto" == "udp" ] || [ "$proto" == "both" ]; then
        jq --arg port "$port" '.open_ports.udp -= [$port]' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    trigger_render
}

show_ports() {
    echo -e "\n=== 🔓 开放端口一览 ==="
    echo "TCP 开放: $(jq -r '.open_ports.tcp | join(", ")' "$STATE_FILE")"
    echo "UDP 开放: $(jq -r '.open_ports.udp | join(", ")' "$STATE_FILE")"
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
    jq -r '.blacklist[]' "$STATE_FILE"
    echo ""
}

while true; do
    echo "========================="
    echo "   SB Firewall Manager   "
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
