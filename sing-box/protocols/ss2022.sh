#!/bin/bash
source /etc/sing-box/core/common.sh

build_ss2022() {
    local port=$1
    local cipher method pwd

    echo -e "\n选择 SS 2022 加密机制："
    echo "1) 2022-blake3-aes-128-gcm (默认)"
    echo "2) 2022-blake3-aes-256-gcm"
    echo "3) 2022-blake3-chacha20-poly1305"
    read -rp "请输入 [1-3] (默认1): " cipher
    cipher=${cipher:-1}

    case "$cipher" in
        2) method="2022-blake3-aes-256-gcm"; pwd=$(openssl rand -base64 32 | tr -d '\n') ;;
        3) method="2022-blake3-chacha20-poly1305"; pwd=$(openssl rand -base64 32 | tr -d '\n') ;;
        1|*) method="2022-blake3-aes-128-gcm"; pwd=$(openssl rand -base64 16 | tr -d '\n') ;;
    esac

    cat > "${INST_DIR}/${port}/config.json" <<EOF
{ "inbounds": [{ "type": "shadowsocks", "listen": "::", "listen_port": $port, "method": "$method", "password": "$pwd" }] }
EOF
    cat > "${INST_DIR}/${port}/meta.json" <<EOF
{
  "port": $port,
  "protocol": "SS2022",
  "method": "$method",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "password": "$pwd"
}
EOF
}
