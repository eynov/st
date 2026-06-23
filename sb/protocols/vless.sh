#!/bin/bash
# ==============================================================================
# Protocol Plugin: VLESS Reality (Full Custom Edition)
# ==============================================================================

proto_register "VLESS" "VLESS Reality" "build_vless" "uri_vless" "surge_vless" "outbound_vless"

build_vless() {
    local port="$1"
    # 参数 2：伪装域名（默认：www.microsoft.com）
    local server_name="${2:-www.microsoft.com}"
    # 参数 3：节点别名（默认：VLESS_端口）
    local custom_tag="${3:-VLESS_${port}}"
    # 参数 4：自定义 UUID（默认：自动随机生成）
    local uuid="${4:-$(cat /proc/sys/kernel/random/uuid)}"
    # 参数 5：自定义 Short ID（默认：自动随机生成 8 字节）
    local short_id="${5:-$(openssl rand -hex 8)}"

    if ! command -v sing-box &> /dev/null; then
        echo "Error: sing-box is not installed or not in PATH." >&2
        return 1
    fi

    # 动态生成真实的 Reality 密钥对
    local keypair private_key public_key
    keypair="$(sing-box generate reality-keypair)"
    private_key="$(echo "$keypair" | sed -n 's/^PrivateKey:[[:space:]]*//p')"
    public_key="$(echo "$keypair" | sed -n 's/^PublicKey:[[:space:]]*//p')"

    mkdir -p "${INST_DIR}/${port}"

    # 服务端配置
    cat > "${INST_DIR}/${port}/config.json" <<JSONEOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [{
    "type": "vless",
    "listen": "::",
    "listen_port": ${port},
    "users": [{ "uuid": "${uuid}" }],
    "tls": {
      "enabled": true,
      "server_name": "${server_name}",
      "reality": {
        "enabled": true,
        "handshake": { "server": "${server_name}", "server_port": 443 },
        "private_key": "${private_key}",
        "short_id": [ "${short_id}" ]
      }
    }
  }],
  "outbounds": [{ "type": "direct" }]
}
JSONEOF

    # 元数据保存（新增了 custom_tag 别名保存）
    cat > "${INST_DIR}/${port}/meta.json" <<JSONEOF
{
  "port": ${port},
  "protocol": "VLESS",
  "uuid": "${uuid}",
  "server_name": "${server_name}",
  "public_key": "${public_key}",
  "short_id": "${short_id}",
  "node_tag": "${custom_tag}",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "enabled": true
}
JSONEOF

    state_set "$port" "$(cat "${INST_DIR}/${port}/meta.json")"
}

uri_vless() {
    local meta_file="$1"
    local current_ip="$2"
    local port uuid server_name public_key short_id node_tag tag host

    port=$(jq -r '.port' "$meta_file")
    uuid=$(jq -r '.uuid' "$meta_file")
    server_name=$(jq -r '.server_name // empty' "$meta_file")
    public_key=$(jq -r '.public_key // empty' "$meta_file")
    short_id=$(jq -r '.short_id // empty' "$meta_file")
    node_tag=$(jq -r '.node_tag // empty' "$meta_file")

    # 如果元数据里有自定义别名就用别名，没有就用默认的
    [[ -n "$node_tag" ]] && tag=$(urlencode "$node_tag") || tag=$(urlencode "VLESS_${port}")
    
    host="$current_ip"
    if [[ "$host" == *:* ]]; then host="[$host]"; fi

    echo "vless://${uuid}@${host}:${port}?encryption=none&security=reality&sni=${server_name}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#${tag}"
}

surge_vless() {
    local meta_file="$1"
    local current_ip="$2"
    local port uuid server_name public_key short_id node_tag display_name

    port=$(jq -r '.port' "$meta_file")
    uuid=$(jq -r '.uuid' "$meta_file")
    server_name=$(jq -r '.server_name // empty' "$meta_file")
    public_key=$(jq -r '.public_key // empty' "$meta_file")
    short_id=$(jq -r '.short_id // empty' "$meta_file")
    node_tag=$(jq -r '.node_tag // empty' "$meta_file")

    display_name="${node_tag:-VLESS_${port}}"

    echo "🟣 ${display_name} = vless, ${current_ip}, ${port}, username=${uuid}, tls=true, reality=true, reality-public-key=${public_key}, reality-short-id=${short_id}, sni=${server_name}, client-fingerprint=chrome"
}

outbound_vless() {
    local meta_file="$1"
    local current_ip="$2"
    local port uuid server_name public_key short_id node_tag display_name

    port=$(jq -r '.port' "$meta_file")
    uuid=$(jq -r '.uuid' "$meta_file")
    server_name=$(jq -r '.server_name // empty' "$meta_file")
    public_key=$(jq -r '.public_key // empty' "$meta_file")
    short_id=$(jq -r '.short_id // empty' "$meta_file")
    node_tag=$(jq -r '.node_tag // empty' "$meta_file")

    display_name="${node_tag:-VLESS-Reality-${port}}"

    cat <<JSONEOF
{
  "type": "vless",
  "tag": "${display_name}",
  "server": "${current_ip}",
  "server_port": ${port},
  "uuid": "${uuid}",
  "packet_encoding": "xpro",
  "tls": {
    "enabled": true,
    "server_name": "${server_name}",
    "utls": { "enabled": true, "fingerprint": "chrome" },
    "reality": { "enabled": true, "public_key": "${public_key}", "short_id": "${short_id}" }
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
