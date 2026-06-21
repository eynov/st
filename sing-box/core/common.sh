#!/bin/bash
# 核心公共底座：基于当前执行文件的相对路径动态延伸资产空间

# 动态反查出当前 core/ 目录的上一级，即项目根目录
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INST_DIR="${BASE_DIR}/instances"
CERT_DIR="${BASE_DIR}/certs"
SB_BIN="/usr/local/bin/sing-box"

ok() { echo -e "🟢 $*"; }
err() { echo -e "❌ $*"; }
warn() { echo -e "⚠️ $*"; }

port_used() {
    ss -lntu | awk '{print $5}' | grep -qE ":$1$"
}

get_ip() {
    local ip=$(curl -4 -s --max-time 3 ifconfig.me || curl -4 -s --max-time 3 api.ipify.org)
    if [ -z "$ip" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -1)
    fi
    echo "${ip:-127.0.0.1}"
}

show_qr() {
    local data="$1"
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "\n📷 扫描下方二维码快捷添加节点:"
        qrencode -t ansiutf8 "$data"
    else
        warn "提示：系统未检测到 qrencode。建议执行 'apt install qrencode' 以开启终端二维码支持。"
    fi
}
