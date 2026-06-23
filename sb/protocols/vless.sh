#!/bin/bash
# ==============================================================================
# Protocol Plugin: VLESS Reality (Pure sing-box Edition)
# ==============================================================================

# 格式：
# proto_register <协议KEY> <菜单显示名称> <build函数> <标准URI函数> <Surge函数> <Outbound函数>
proto_register "VLESS" "VLESS Reality" "build_vless" "uri_vless" "surge_vless" "outbound_vless"

build_vless() {
    local port="$1"
    # 支持自定义 server_name，如果没传则默认使用 www.microsoft.com
    local server_name="${2:-www.microsoft.com}"

    if ! command -v sing-box &> /dev/null; then
        echo "Error: sing-box is not installed or not in PATH." >&2
        return 1
    fi

    # ==========================================================
    # 1. 生成协议所需参数 (动态生成 Reality 密钥对)
    # ==========================================================
    local uuid keypair private_key public_key short_id

    uuid=$(cat /proc/sys/kernel/random/uuid)
    
    # 动态生成真实的 Reality 密钥
    keypair="$(sing-box generate reality-keypair)"
    private_key="$(echo "$keypair" | sed -n 's/^PrivateKey:[[:space:]]*//p')"
    public_key="$(echo "$keypair" | sed -n 's/^PublicKey:[[:space:]]*//p')"
    short_id="$(openssl rand -hex 8)"

    # 核心安全保障：确保实例目录存在，彻底根治 "No such file or directory" 报错
    mkdir -p "${INST_DIR}/${port}"

    # ==========================================================
    # 2. 生成 sing-box config.json (纯服务端格式，剔除 Vision)
    # ==========================================================
    cat > "${INST_DIR}/${port}/config.json" <<JSONEOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [{
    "type": "vless",
    "listen": "::",
    "listen_port": ${port},
    "users": [{
      "uuid": "${uuid}"
    }],
    "tls": {
      "enabled": true,
      "server_name": "${server_name}",
      "reality": {
        "enabled": true,
        "handshake": {
          "server": "${server_name}",
          "server_port": 443
        },
        "private_key": "${private_key}",
        "short_id": [
          "${short_id}"
        ]
      }
    }
  }],
  "outbounds": [{
    "type": "direct"
  }]
}
JSONEOF

    # ==========================================================
    # 3. 生成 meta.json (保存所有必要参数)
    # ==========================================================
    cat > "${INST_DIR}/${port}/meta.json" <<JSONEOF
{
  "port": ${port},
  "protocol": "VLESS",
  "uuid": "${uuid}",
  "server_name": "${server_name}",
  "public_key": "${public_key}",
  "short_id": "${short_id}",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "enabled": true
}
JSONEOF

    # ==========================================================
    # 4. 写入 State Store
    # ==========================================================
    state_set "$port" "$(cat "${INST_DIR}/${port}/meta.json")"
}

uri_vless() {
    local meta_file="$1"
    local current_ip="$2"

    local port uuid server_name public_key short_id tag host

    port=$(jq -r '.port' "$meta_file")
    uuid=$(jq -r '.uuid' "$meta_file")
    server_name=$(jq -r '.server_name // empty' "$meta_file")
    public_key=$(jq -r '.public_key // empty' "$meta_file")
    short_id=$(jq -r '.short_id // empty' "$meta_file")

    tag=$(urlencode "VLESS_${port}")
    
    # IPv6 兼容处理
    host="$current_ip"
    if [[ "$host" == *:* ]]; then
        host="[$host]"
    fi

    # 通用 VLESS Reality 链接 (纯 sing-box 规范，不包含 flow 字段)
    echo "vless://${uuid}@${host}:${port}?encryption=none&security=reality&sni=${server_name}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#${tag}"
}

surge_vless() {
    local meta_file="$1"
    local current_ip="$2"

    local port uuid server_name public_key short_id

    port=$(jq -r '.port' "$meta_file")
    uuid=$(jq -r '.uuid' "$meta_file")
    server_name=$(jq -r '.server_name // empty' "$meta_file")
    public_key=$(jq -r '.public_key // empty' "$meta_file")
    short_id=$(jq -r '.short_id // empty' "$meta_file")

    echo "🟣 VLESS_${port} = vless, ${current_ip}, ${port}, username=${uuid}, tls=true, reality=true, reality-public-key=${public_key}, reality-short-id=${short_id}, sni=${server_name}, client-fingerprint=chrome"
}

# ==========================================================
# 新增：生成纯 sing-box 客户端所需的 outbounds JSON 配置
# ==========================================================
outbound_vless() {
    local meta_file="$1"
    local current_ip="$2"

    local port uuid server_name public_key short_id

    port=$(jq -r '.port' "$meta_file")
    uuid=$(jq -r '.uuid' "$meta_file")
    server_name=$(jq -r '.server_name // empty' "$meta_file")
    public_key=$(jq -r '.public_key // empty' "$meta_file")
    short_id=$(jq -r '.short_id // empty' "$meta_file")

    cat <<JSONEOF
{
  "type": "vless",
  "tag": "VLESS-Reality-${port}",
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
JSONEOF
}
