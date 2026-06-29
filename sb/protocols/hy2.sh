#!/bin/bash
# ==============================================================================
# Protocol Plugin: Hysteria2
# ==============================================================================

proto_register "HY2" "Hysteria2 (UDP-Based Brute)" "build_hy2" "uri_hy2" "surge_hy2" "outbound_hy2"

build_hy2() {
   local port="$1"

   read -p "请输入客户端 SNI 域名 (默认: www.apple.com): " sni
   sni="${sni:-www.apple.com}"
   sni="${sni#https://}"
   sni="${sni#http://}"
   sni="${sni%%/*}"
   sni="${sni%/}"

   read -p "请输入伪装回落域名 (直接回车默认与 SNI 相同): " masq_input
   if [ -z "$masq_input" ]; then
       masq="https://${sni}"
   else
       masq_input="${masq_input#https://}"
       masq_input="${masq_input#http://}"
       masq="https://${masq_input}"
       masq="${masq%/}"
   fi

   read -p "请输入端口跳跃范围 (如 20000-29999，直接回车不启用跳跃): " hop_ports
   hop_ports="${hop_ports:-}"

   local hop_interval=""
   if [ -n "$hop_ports" ]; then
       while [[ ! "$hop_ports" =~ ^[0-9]+(-[0-9]+)?$ ]]; do
           read -p "格式有误，请输入如 20000-29999 或 20000: " hop_ports
       done
       read -p "请输入端口跳跃间隔秒数 (直接回车默认 30): " hop_interval
       hop_interval="${hop_interval:-30}"
       while [[ ! "$hop_interval" =~ ^[0-9]+$ ]] || (( hop_interval < 5 )); do
           read -p "间隔须为 ≥5 的整数，请重新输入: " hop_interval
           hop_interval="${hop_interval:-30}"
       done
   fi

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

   local hop_ports_json hop_interval_json
   [ -n "$hop_ports" ] && hop_ports_json="\"${hop_ports}\"" || hop_ports_json="null"
   [ -n "$hop_interval" ] && hop_interval_json="${hop_interval}" || hop_interval_json="null"

   cat > "${INST_DIR}/${port}/meta.json" <<JSONEOF
{
 "port": ${port},
 "protocol": "HY2",
 "password": "${password}",
 "sni": "${sni}",
 "masq": "${masq}",
 "hop_ports": ${hop_ports_json},
 "hop_interval": ${hop_interval_json},
 "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
 "enabled": true
}
JSONEOF

   state_set "$port" "$(cat "${INST_DIR}/${port}/meta.json")"
}

uri_hy2() {
   local meta_file="$1"
   local current_ip="$2"

   local port password sni hop_ports
   port=$(jq -r '.port' "$meta_file")
   password=$(jq -r '.password' "$meta_file")
   sni=$(jq -r '.sni' "$meta_file")
   hop_ports=$(jq -r '.hop_ports // empty' "$meta_file")

   local password_enc sni_enc tag_enc
   password_enc=$(urlencode "$password")
   sni_enc=$(urlencode "$sni")
   tag_enc=$(urlencode "HY2_${port}")

   if [ -n "$hop_ports" ]; then
       echo "hysteria2://${password_enc}@${current_ip}:${port}?sni=${sni_enc}&insecure=1&mport=${hop_ports}#${tag_enc}"
   else
       echo "hysteria2://${password_enc}@${current_ip}:${port}?sni=${sni_enc}&insecure=1#${tag_enc}"
   fi
}

surge_hy2() {
   local meta_file="$1"
   local current_ip="$2"

   local port password sni hop_ports hop_interval
   port=$(jq -r '.port' "$meta_file")
   password=$(jq -r '.password' "$meta_file")
   sni=$(jq -r '.sni' "$meta_file")
   hop_ports=$(jq -r '.hop_ports // empty' "$meta_file")
   hop_interval=$(jq -r '.hop_interval // 30' "$meta_file")

   if [ -n "$hop_ports" ]; then
       echo "🔵 HY2_${port} = hysteria2, ${current_ip}, ${port}, password=${password}, sni=${sni}, skip-cert-verify=true, port-hopping=${hop_ports}, port-hopping-interval=${hop_interval}"
   else
       echo "🔵 HY2_${port} = hysteria2, ${current_ip}, ${port}, password=${password}, sni=${sni}, skip-cert-verify=true"
   fi
}

outbound_hy2() {
   local meta_file="$1"
   local current_ip="$2"

   local port password sni hop_ports hop_interval display_name
   port=$(jq -r '.port' "$meta_file")
   password=$(jq -r '.password' "$meta_file")
   sni=$(jq -r '.sni' "$meta_file")
   hop_ports=$(jq -r '.hop_ports // empty' "$meta_file")
   hop_interval=$(jq -r '.hop_interval // 30' "$meta_file")
   display_name="HY2-${port}"

   if [ -n "$hop_ports" ]; then
       cat <<JSONEOF
{
 "type": "hysteria2",
 "tag": "${display_name}",
 "server": "${current_ip}",
 "server_port": ${port},
 "server_ports": ["${hop_ports}"],
 "hop_interval": "${hop_interval}s",
 "password": "${password}",
 "tls": {
   "enabled": true,
   "server_name": "${sni}",
   "insecure": true
 }
}
JSONEOF
   else
       cat <<JSONEOF
{
 "type": "hysteria2",
 "tag": "${display_name}",
 "server": "${current_ip}",
 "server_port": ${port},
 "password": "${password}",
 "tls": {
   "enabled": true,
   "server_name": "${sni}",
   "insecure": true
 }
}
JSONEOF
   fi
}
