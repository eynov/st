#!/bin/bash
# ==============================================================================
# Protocol Plugin: Shadowsocks 2022 Blake3 Next-Gen
# ==============================================================================

proto_register "SS2022" "Shadowsocks 2022 (Blake3 Next-Gen)" "build_ss2022" "uri_ss2022" "surge_ss2022"

build_ss2022() {
    local port="$1"
    local method password cipher

    echo -e "\n选择 SS2022 加密机制："
    echo "1) 2022-blake3-aes-128-gcm (默认)"
    echo "2) 2022-blake3-aes-256-gcm"
    echo "3) 2022-blake3-chacha20-poly1305"
    read -rp "请输入 [1-3] (默认1): " cipher
    cipher="${cipher:-1}"

    case "$cipher" in
        2) method="2022-blake3-aes-256-gcm";        password=$(openssl rand -base64 32 | tr -d '\n') ;;
        3) method="2022-blake3-chacha20-poly1305";  password=$(openssl rand -base64 32 | tr -d '\n') ;;
        *) method="2022-blake3-aes-128-gcm";        password=$(openssl rand -base64 16 | tr -d '\n') ;;
    esac

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
  "protocol": "SS2022",
  "method": "${method}",
  "password": "${password}",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "enabled": true
}
JSONEOF

    state_set "$port" "$(cat "${INST_DIR}/${port}/meta.json")"
}

uri_ss2022() {
    local meta_file="$1"
    local current_ip="$2"

    local port method password userinfo tag
    port=$(jq -r '.port' "$meta_file")
    method=$(jq -r '.method' "$meta_file")
    password=$(jq -r '.password' "$meta_file")

    # 保持原有逻辑：ss://method:password@ip:port#name
    # 但对 method:password 做 URL 编码，避免 base64 密码里的 + / = 影响解析。
    userinfo=$(urlencode "${method}:${password}")
    tag=$(urlencode "SS2022_${port}")

    echo "ss://${userinfo}@${current_ip}:${port}#${tag}"
}

surge_ss2022() {
    local meta_file="$1"
    local current_ip="$2"

    local port method password
    port=$(jq -r '.port' "$meta_file")
    method=$(jq -r '.method' "$meta_file")
    password=$(jq -r '.password' "$meta_file")

    echo "🟢 SS2022_${port} = ss, ${current_ip}, ${port}, encrypt-method=${method}, password=${password}"
}