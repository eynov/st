#!/bin/bash
# ==============================================================================
# Protocol Plugin: VLESS Reality 
# ==============================================================================

proto_register "VLESS" "VLESS Reality" "build_vless" "uri_vless" "surge_vless" "outbound_vless"

build_vless() {
   local port="$1"
   local server_name custom_tag uuid short_id

   if [[ "$port" == *" "* ]]; then
       port=$(echo "$port" | awk '{print $1}')
   fi

   while [[ ! "$port" =~ ^[0-9]+$ ]]; do
       read -p "请输入挂载端口 (纯数字): " port
   done

   # 端口范围校验
   while (( port < 1 || port > 65535 )); do
       read -p "端口范围须在 1-65535 之间，请重新输入: " port
   done

   echo "--------------------------------------------------"
   read -p "请输入伪装域名 [直接回车默认: www.microsoft.com]: " server_name
   server_name="${server_name:-www.microsoft.com}"
   # 过滤非法字符
   server_name=$(echo "$server_name" | tr -cd 'a-zA-Z0-9.-')

   read -p "请输入节点别名 [直接回车默认: VLESS_${port}]: " custom_tag
   custom_tag="${custom_tag:-VLESS_${port}}"
   # 过滤非法字符
   custom_tag=$(echo "$custom_tag" | tr -cd 'a-zA-Z0-9_-')
   echo "--------------------------------------------------"

   uuid="$(cat /proc/sys/kernel/random/uuid)"
   short_id="$(openssl rand -hex 4)"

   if ! command -v sing-box &> /dev/null; then
       echo "Error: sing-box is not installed or not in PATH." >&2
       return 1
   fi

   local keypair private_key public_key
   keypair="$(sing-box generate reality-keypair)"
   private_key="$(echo "$keypair" | sed -n 's/^PrivateKey:[[:space:]]*//p')"
   public_key="$(echo "$keypair" | sed -n 's/^PublicKey:[[:space:]]*//p')"

   # 密钥对校验
   if [[ -z "$private_key" || -z "$public_key" ]]; then
       echo "Error: 密钥对生成失败，请检查 sing-box 是否正常。" >&2
       return 1
   fi

   mkdir -p "${INST_DIR}/${port}"

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
   local mode

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
 "packet_encoding": "xudp",
 "tls": {
   "enabled": true,
   "server_name": "${server_name}",
   "utls": { "enabled": true, "fingerprint": "chrome" },
   "reality": { "enabled": true, "public_key": "${public_key}", "short_id": "${short_id}" }
 }
}
JSONEOF
}
