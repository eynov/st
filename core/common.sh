#!/bin/bash
# 核心公共底座：变量定义、状态监控、网络拓扑嗅探与格式化输出

SB_DIR="/etc/sing-box"
INST_DIR="${SB_DIR}/instances"
SB_BIN="/usr/local/bin/sing-box"
CERT_DIR="${SB_DIR}/certs"

# 统一输出格式
ok() { echo -e "🟢 $*"; }
err() { echo -e "❌ $*"; }
warn() { echo -e "⚠️ $*"; }

# 端口占用严格校验
port_used() {
    ss -lntu | awk '{print $5}' | grep -qE ":$1$"
}

# 动态双栈公网 IP 嗅探
get_ip() {
    local ip=$(curl -4 -s --max-time 3 ifconfig.me || curl -4 -s --max-time 3 api.ipify.org)
    if [ -z "$ip" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -1)
    fi
    echo "${ip:-127.0.0.1}"
}

# 统一本地离线安全二维码渲染
show_qr() {
    local data="$1"
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "\n📷 扫描下方二维码快捷添加节点:"
        qrencode -t ansiutf8 "$data"
    else
        warn "提示：系统未检测到 qrencode。建议执行 'apt install qrencode' 以开启终端二维码支持。"
    fi
}
