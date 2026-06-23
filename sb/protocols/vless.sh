#!/bin/bash
# ==============================================================================
# Protocol Plugin: VLESS Reality (Interactive Step-by-Step Edition)
# ==============================================================================

proto_register "VLESS" "VLESS Reality" "build_vless" "uri_vless" "surge_vless" "outbound_vless"

build_vless() {
    # ==========================================================
    # 🌟 核心修复：改为分步回车交互输入
    # ==========================================================
    local port="$1"
    local server_name custom_tag uuid short_id

    # 1. 如果主脚本传进来的 $1 包含了空格，说明用户习惯性连着输了，我们帮其清理掉，只留第一个纯数字
    if [[ "$port" == *" "* ]]; then
        port=$(echo "$port" | awk '{print $1}')
    fi

    # 如果清洗后的端口不是纯数字，或者为空，则提示重新输入
    while [[ ! "$port" =~ ^[0-9]+$ ]]; do
        read -p "请输入挂载端口 (纯数字): " port
    done

    # 2. 交互式输入域名
    echo "--------------------------------------------------"
    read -p "请输入伪装域名 [直接回车默认: www.microsoft.com]: " server_name
    server_name="${server_name:-www.microsoft.com}"

    # 3. 交互式输入节点别名
    read -p "请输入节点别名 [直接回车默认: VLESS_${port}]: " custom_tag
    custom_tag="${custom_tag:-VLESS_${port}}"
    echo "--------------------------------------------------"

    # 自动生成其余安全参数
    uuid="$(cat /proc/sys/kernel/random/uuid)"
    short_id="$(openssl rand -hex 8)"

    if ! command -v sing-box &> /dev/null; then
        echo "Error: sing-box is not installed or not in PATH." >&2
        return 1
    fi

    # 动态生成真实的 Reality 密钥对
    local keypair private_key public_key
    keypair="$(sing-box generate reality-keypair)"
    private_key="$(echo "$keypair" | sed -n 's/^PrivateKey:[[:space:]]*//p')"
    public_key="$(echo "$keypair" | sed -n 's/^PublicKey:[[:space:]]*//p')"

    # 确保目录存在
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

    # 元数据保存
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

    # 精准写入，此时的 $port 绝对是纯数字
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
