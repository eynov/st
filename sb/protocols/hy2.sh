#!/bin/bash
# ==============================================================================
# Protocol Plugin: Hysteria2
# ==============================================================================

proto_register "HY2" "Hysteria2 (UDP-Based Brute)" "build_hy2" "uri_hy2" "surge_hy2"

build_hy2() {
    local port="$1"

    read -p "请输入客户端 TLS 握手 SNI 域名 (默认: www.apple.com): " sni
    sni="${sni:-www.apple.com}"

    read -p "请输入未认证网页伪装回落 URL (默认: https://www.apple.com): " masq
    masq="${masq:-https://www.apple.com}"

    local password cert key
    password=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)
    cert="${CERT_DIR}/cert_${port}.crt"
    key="${CERT_DIR}/private_${port}.key"

    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$key" -out "$cert" \
        -subj "/CN=${sni}" >/dev/null 2>&1

    cat > "${INST_DIR}/${port}/config.json" <<JSONEOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [{
    "type": "hysteria2",
    "listen": "::",
    "listen_port": ${port},
    "users": [{"password": "${password}"}],
    "masquerade": { "type": "proxy", "url": "${masq}" },
    "tls": {
      "enabled": true,
      "server_name": "${sni}",
      "certificate_path": "${cert}",
      "key_path": "${key}"
    }
  }],
  "outbounds": [{"type": "direct"}]
}
JSONEOF

    cat > "${INST_DIR}/${port}/meta.json" <<JSONEOF
{
  "port": ${port},
  "protocol": "HY2",
  "password": "${password}",
  "sni": "${sni}",
  "masq": "${masq}",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "enabled": true
}
JSONEOF

    state_set "$port" "$(cat "${INST_DIR}/${port}/meta.json")"
}

uri_hy2() {
    local meta_file="$1"
    local current_ip="$2"

    local port password sni tag
    port=$(jq -r '.port' "$meta_file")
    password=$(jq -r '.password' "$meta_file")
    sni=$(jq -r '.sni' "$meta_file")

    password=$(urlencode "$password")
    sni=$(urlencode "$sni")
    tag=$(urlencode "HY2_${port}")

    echo "hysteria2://${password}@${current_ip}:${port}?sni=${sni}&insecure=1#${tag}"
}

surge_hy2() {
    local meta_file="$1"
    local current_ip="$2"

    local port password sni
    port=$(jq -r '.port' "$meta_file")
    password=$(jq -r '.password' "$meta_file")
    sni=$(jq -r '.sni' "$meta_file")

    echo "🔵 HY2_${port} = hysteria2, ${current_ip}, ${port}, password=${password}, sni=${sni}, skip-cert-verify=true"
}