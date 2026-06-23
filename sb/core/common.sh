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
# PROTO_KEYS   : 有序数组，控制菜单显示顺序
# PROTO_MENU   : key -> 显示名称
# PROTO_BUILD  : key -> build 函数名
# PROTO_URI    : key -> 标准分享链接生成函数名
# PROTO_SURGE  : key -> Surge 格式生成函数名
declare -a PROTO_KEYS=()
declare -A PROTO_MENU
declare -A PROTO_BUILD
declare -A PROTO_URI
declare -A PROTO_SURGE

# 协议注册函数
# 用法:
# proto_register <key> <label> <build_fn> [uri_fn] [surge_fn]
#
# 示例:
# proto_register "SS" "Shadowsocks" "build_ss" "uri_ss" "surge_ss"
proto_register() {
    local key="$1"       # 协议标识，如 SS / SS2022 / HY2
    local label="$2"     # 菜单显示名
    local build_fn="$3"  # build 函数名
    local uri_fn="$4"    # 标准 URI 生成函数名
    local surge_fn="$5"  # Surge 格式生成函数名

    PROTO_KEYS+=("$key")
    PROTO_MENU["$key"]="$label"
    PROTO_BUILD["$key"]="$build_fn"

    [ -n "$uri_fn" ] && PROTO_URI["$key"]="$uri_fn"
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
# 公网 IP 获取（v4 优先，失败回落本地路由，仍失败则警告）
# ------------------------------------------------------------------------------
get_ip() {
    local ip
    ip=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null) \
        || ip=$(curl -4 -s --max-time 3 api.ipify.org 2>/dev/null)

    if [ -z "$ip" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -1)
    fi

    if [ -z "$ip" ]; then
        warn "无法自动获取公网 IP，分享链接中将使用 127.0.0.1，请手动替换！"
        ip="127.0.0.1"
    fi

    echo "$ip"
}

# ------------------------------------------------------------------------------
# URL Encode
# 用于分享链接参数编码，避免 + / = # & 等字符影响 URI 解析
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