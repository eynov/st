#!/bin/bash
# ==============================================================================
# 核心公共底座：路径常量 + 工具函数 + 协议注册表声明
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 路径常量
INST_DIR="${BASE_DIR}/instances"
CERT_DIR="${BASE_DIR}/certs"
SB_BIN="/usr/local/bin/sing-box"
STATE_FILE="${BASE_DIR}/instances.json"

# 🔥 协议注册表（由各 protocols/*.sh 自注册）
declare -a PROTO_KEYS=()
declare -A PROTO_MENU
declare -A PROTO_BUILD
declare -A PROTO_URI
declare -A PROTO_SURGE

# 协议注册函数
proto_register() {
    local key="$1"
    local label="$2"
    local build_fn="$3"
    local uri_fn="$4"
    local surge_fn="$5"

    PROTO_KEYS+=("$key")
    PROTO_MENU["$key"]="$label"
    PROTO_BUILD["$key"]="$build_fn"

    [ -n "$uri_fn" ]   && PROTO_URI["$key"]="$uri_fn"
    [ -n "$surge_fn" ] && PROTO_SURGE["$key"]="$surge_fn"
}

# ------------------------------------------------------------------------------
# 输出格式化
# ------------------------------------------------------------------------------
ok()   { echo -e "🟢 $*"; }
err()  { echo -e "❌ $*"; }
warn() { echo -e "⚠️  $*"; }

# ------------------------------------------------------------------------------
# 端口占用检测
# ------------------------------------------------------------------------------
port_used() {
    ss -lntu | awk '{print $5}' | grep -qE "(^|:)${1}$"
}

# ------------------------------------------------------------------------------
# 公网 IPv4 获取
# ------------------------------------------------------------------------------
get_ipv4() {
    local ip
    ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    [ -z "$ip" ] && ip=$(curl -4 -s --max-time 5 api.ipify.org 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    [ -z "$ip" ] && ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -1)
    echo "$ip"
}

# ------------------------------------------------------------------------------
# 公网 IPv6 获取
# ------------------------------------------------------------------------------
get_ipv6() {
    local ip
    ip=$(curl -6 -s --max-time 5 ifconfig.me 2>/dev/null | grep -Eo '([0-9a-fA-F:]+:+[0-9a-fA-F]+)' | head -1)
    [ -z "$ip" ] && ip=$(curl -6 -s --max-time 5 api6.ipify.org 2>/dev/null | grep -Eo '([0-9a-fA-F:]+:+[0-9a-fA-F]+)' | head -1)
    [ -z "$ip" ] && ip=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{print $7}' | head -1)
    echo "$ip"
}

# ------------------------------------------------------------------------------
# URL Encode
# ------------------------------------------------------------------------------
urlencode() {
    local raw="$1"
    local length="${#raw}"
    local i c

    for (( i = 0; i < length; i++ )); do
        c="${raw:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 终端二维码渲染
# ------------------------------------------------------------------------------
show_qr() {
    local data="$1"
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "\n📷 扫描下方二维码快捷添加节点:"
        qrencode -t ansiutf8 "$data"
    else
        warn "未检测到 qrencode，执行 'apt install qrencode' 可开启二维码支持。"
    fi
}
