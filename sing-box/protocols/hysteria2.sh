#!/bin/bash

# 🔥 核心：独立运行时也能动态反向溯源引入 common 基座
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/core/common.sh"

build_hy2() {
    local port=$1
    
    read -p "请输入客户端 TLS 握手 SNI 域名 (默认: www.apple.com): " sni
    sni=${sni:-www.apple.com}
    read -p "请输入未认证网页伪装回落 URL (默认: https://www.apple.com): " masq
    masq=${masq:-https://www.apple.com}
    
    local pwd=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)
    local cert="${CERT_DIR}/cert_${port}.crt"
    local key="${CERT_DIR}/private_${port}.key"
    
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$key" -out "$cert" -subj "/CN=${sni}" >/dev/null 2>&1

    cat > "${INST_DIR}/${port}/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [{
    "type": "hysteria2",
    "listen": "::",
    "listen_port": $port,
    "users": [{"password": "$pwd"}],
    "masquerade": { "type": "proxy", "url": "$masq" },
    "tls": { "enabled": true, "server_name": "$sni", "certificate_path": "$cert", "key_path": "$key" }
  }],
  "outbounds": [{"type": "direct"}]
}
EOF

    cat > "${INST_DIR}/${port}/meta.json" <<EOF
{
  "port": $port,
  "protocol": "HY2",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "password": "$pwd",
  "sni": "$sni"
}
EOF
}
