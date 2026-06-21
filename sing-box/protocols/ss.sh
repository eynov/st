#!/bin/bash
# 🔥 核心：独立运行时也能动态反向溯源引入 common 基座
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/core/common.sh"

build_ss() {
    local port=$1
    local pwd=$(openssl rand -hex 16)
    
    cat > "${INST_DIR}/${port}/config.json" <<EOF
{ "inbounds": [{ "type": "shadowsocks", "listen": "::", "listen_port": $port, "method": "aes-256-gcm", "password": "$pwd" }] }
EOF
    cat > "${INST_DIR}/${port}/meta.json" <<EOF
{
  "port": $port,
  "protocol": "SS",
  "method": "aes-256-gcm",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "password": "$pwd"
}
EOF
}
