#!/bin/bash
# ==============================================================================
# Protocol Plugin: Shadowsocks AEAD Legacy
# ==============================================================================

proto_register "SS" "Shadowsocks (AEAD Legacy)" "build_ss" "uri_ss" "surge_ss"

build_ss() {
    local port="$1"
    local password
    password=$(openssl rand -hex 16)
    local method="aes-256-gcm"

    cat > "${INST_DIR}/${port}/config.json" <<JSONEOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [{
    "type": "shadowsocks",
    "listen": "::",
    "listen_port": ${port},
    "method": "${method}",
    "password": "${password}"
  }],
  "outbounds": [{"type": "direct"}]
}
JSONEOF

    cat > "${INST_DIR}/${port}/meta.json" <<JSONEOF
{
  "port": ${port},
  "protocol": "SS",
  "method": "${method}",
  "password": "${password}",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "enabled": true
}
JSONEOF

    state_set "$port" "$(cat "${INST_DIR}/${port}/meta.json")"
}

uri_ss() {
    local meta_file="$1"
    local current_ip="$2"

    local port method password b64
    port=$(jq -r '.port' "$meta_file")
    method=$(jq -r '.method' "$meta_file")
    password=$(jq -r '.password' "$meta_file")

    b64=$(echo -n "${method}:${password}" | base64 | tr -d '\n')
    echo "ss://${b64}@${current_ip}:${port}#SS_${port}"
}

surge_ss() {
    local meta_file="$1"
    local current_ip="$2"

    local port method password
    port=$(jq -r '.port' "$meta_file")
    method=$(jq -r '.method' "$meta_file")
    password=$(jq -r '.password' "$meta_file")

    echo "🟢 SS_${port} = ss, ${current_ip}, ${port}, encrypt-method=${method}, password=${password}"
}