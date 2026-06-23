#!/usr/bin/env bash

# 注册协议
proto_register \
    "VLESS" \
    "VLESS Reality" \
    "build_vless" \
    "uri_vless" \
    "surge_vless" \
    "outbound_vless"

build_vless() {
    local port="$1"
    # 自定义 server_name，默认使用 www.cloudflare.com
    local server_name="${2:-www.cloudflare.com}"

    if ! command -v sing-box &> /dev/null; then
        echo "Error: sing-box is not installed or not in PATH." >&2
        return 1
    fi

    local keypair
    keypair="$(sing-box generate reality-keypair)"

    local private_key
    private_key="$(echo "$keypair" | sed -n 's/^PrivateKey:[[:space:]]*//p')"
    local public_key
    public_key="$(echo "$keypair" | sed -n 's/^PublicKey:[[:space:]]*//p')"

    local uuid
    if [[ -f /proc/sys/kernel/random/uuid ]]; then
        uuid="$(cat /proc/sys/kernel/random/uuid)"
    else
        uuid="$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')"
    fi

    local short_id
    short_id="$(openssl rand -hex 8)"

    mkdir -p "$(dirname "$CONFIG_FILE")" "$(dirname "$META_FILE")"

    # config.json (纯 sing-box 服务端格式)
    # 彻底移除 "flow": "xtls-rprx-vision"
    cat > "$CONFIG_FILE" <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$server_name",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$server_name",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": [
            "$short_id"
          ]
        }
      }
    }
  ]
}
EOF

    # meta.json
    cat > "$META_FILE" <<EOF
{
  "type": "vless",
  "port": $port,
  "uuid": "$uuid",
  "public_key": "$public_key",
  "short_id": "$short_id",
  "server_name": "$server_name"
}
EOF

    state_set "protocol" "VLESS"
    state_set "port" "$port"
}

uri_vless() {
    local meta_file="$1"
    local current_ip="$2"

    if [[ ! -f "$meta_file" ]]; then
        echo "Error: Meta file $meta_file not found." >&2
        return 1
    fi

    local uuid port public_key short_id server_name
    uuid="$(jq -r '.uuid // empty' "$meta_file")"
    port="$(jq -r '.port // empty' "$meta_file")"
    public_key="$(jq -r '.public_key // empty' "$meta_file")"
    short_id="$(jq -r '.short_id // empty' "$meta_file")"
    server_name="$(jq -r '.server_name // "www.cloudflare.com"' "$meta_file")"

    local host="$current_ip"
    if [[ "$host" == *:* ]]; then
        host="[$host]"
    fi

    # 纯 sing-box 客户端通常通过订阅/JSON导入，但通用通用链接格式中去掉 flow 字段
    echo "vless://${uuid}@${host}:${port}?encryption=none&security=reality&sni=${server_name}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#VLESS-Reality"
}

surge_vless() {
    local meta_file="$1"
    local current_ip="$2"

    if [[ ! -f "$meta_file" ]]; then
        echo "Error: Meta file $meta_file not found." >&2
        return 1
    fi

    local uuid port public_key short_id server_name
    uuid="$(jq -r '.uuid // empty' "$meta_file")"
    port="$(jq -r '.port // empty' "$meta_file")"
    public_key="$(jq -r '.public_key // empty' "$meta_file")"
    short_id="$(jq -r '.short_id // empty' "$meta_file")"
    server_name="$(jq -r '.server_name // "www.cloudflare.com"' "$meta_file")"

    # Surge 的 VLESS 同样去掉 flow 字段
    cat <<EOF
VLESS-Reality = vless, ${current_ip}, ${port}, username=${uuid}, tls=true, reality=true, reality-public-key=${public_key}, reality-short-id=${short_id}, sni=${server_name}, client-fingerprint=chrome
EOF
}

# 纯 sing-box 客户端 outbounds 配置 (重点在 multiplex 和 packet_encoding)
outbound_vless() {
    local meta_file="$1"
    local current_ip="$2"

    if [[ ! -f "$meta_file" ]]; then
        echo "Error: Meta file $meta_file not found." >&2
        return 1
    fi

    local uuid port public_key short_id server_name
    uuid="$(jq -r '.uuid // empty' "$meta_file")"
    port="$(jq -r '.port // empty' "$meta_file")"
    public_key="$(jq -r '.public_key // empty' "$meta_file")"
    short_id="$(jq -r '.short_id // empty' "$meta_file")"
    server_name="$(jq -r '.server_name // "www.cloudflare.com"' "$meta_file")"

    # sing-box 规范的 VLESS 客户端配置
    cat <<EOF
{
  "type": "vless",
  "tag": "VLESS-Reality-Out",
  "server": "${current_ip}",
  "server_port": ${port},
  "uuid": "${uuid}",
  "packet_encoding": "xpro",
  "tls": {
    "enabled": true,
    "server_name": "${server_name}",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "${public_key}",
      "short_id": "${short_id}"
    }
  },
  "multiplex": {
    "enabled": true,
    "protocol": "h2mux",
    "max_connections": 4,
    "min_streams": 4,
    "max_streams": 0
  }
}
EOF
}
