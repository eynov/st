#!/bin/bash
# --- render.sh (绝对路径加固版) ---

REAL_SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
BASE_DIR="$(cd "$(dirname "$REAL_SCRIPT_PATH")" && pwd)"

STATE_FILE="$BASE_DIR/state.json"
BUILD_DIR="$BASE_DIR/build"
BUILD_CONF="$BUILD_DIR/nft.conf"
SYSTEM_CONF="/etc/nftables.conf"

mkdir -p "$BUILD_DIR"
if [[ $EUID -ne 0 ]]; then
   echo "❌ 编译器必须以 root 权限运行"
   exit 1
fi

if ! command -v jq &> /dev/null || ! command -v dig &> /dev/null; then
    apt-get update && apt-get install -y jq dnsutils curl nftables > /dev/null
fi

sysctl -w net.ipv4.ip_forward=1 > /dev/null
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf

SRC_IP=$(curl -s4 -m 3 https://api.ip.sb/ip || curl -s4 -m 3 https://ifconfig.me)
if [ -z "$SRC_IP" ]; then
    echo "❌ 无法获取本机公网 IP，中断编译。"
    exit 1
fi

SSH_PORT=$(ss -tlnp | grep -E 'sshd|listen' | grep -oP '(?<=:)\d+(?=\s)' | head -n1)
[ -z "$SSH_PORT" ] && SSH_PORT=$(awk '/^Port/ {print $2}' /etc/ssh/sshd_config | head -n1)
[ -z "$SSH_PORT" ] && SSH_PORT="22" 

BLACKLIST=$(jq -r '.blacklist | join(", ")' "$STATE_FILE" 2>/dev/null)
[ -z "$BLACKLIST" ] && BLACKLIST="127.0.0.2"

TCP_PORTS=$(jq -r '.open_ports.tcp | join(", ")' "$STATE_FILE" 2>/dev/null)
[ -z "$TCP_PORTS" ] && TCP_PORTS="65535"

UDP_PORTS=$(jq -r '.open_ports.udp | join(", ")' "$STATE_FILE" 2>/dev/null)
[ -z "$UDP_PORTS" ] && UDP_PORTS="65535"

DNAT_RULES=""
SNAT_RULES=""

while read -r row; do
    [ -z "$row" ] && continue
    sport=$(echo "$row" | jq -r '.sport')
    dport=$(echo "$row" | jq -r '.dport')
    dip=$(echo "$row" | jq -r '.dip')
    proto=$(echo "$row" | jq -r '.proto')

    port_range="$sport"
    [ "$sport" != "$dport" ] && port_range="$sport-$dport"

    DNAT_RULES="${DNAT_RULES}        $proto dport $port_range dnat to $dip\n"
    SNAT_RULES="${SNAT_RULES}        ip daddr $dip $proto dport $port_range snat to $SRC_IP\n"
done < <(jq -c '.forwards[]' "$STATE_FILE" 2>/dev/null)

echo "flush ruleset" > "$BUILD_CONF"

cat "$BASE_DIR/rules/filter.nft.tpl" >> "$BUILD_CONF"
sed -i "s/#BLACKLIST#/$BLACKLIST/g" "$BUILD_CONF"
sed -i "s/#TCP_PORTS#/$TCP_PORTS/g" "$BUILD_CONF"
sed -i "s/#UDP_PORTS#/$UDP_PORTS/g" "$BUILD_CONF"
sed -i "s/#SSH_PORT#/$SSH_PORT/g" "$BUILD_CONF"

cat "$BASE_DIR/rules/nat.nft.tpl" >> "$BUILD_CONF"
sed -i "s@#DNAT_RULES#@$DNAT_RULES@g" "$BUILD_CONF"
sed -i "s@#SNAT_RULES#@$SNAT_RULES@g" "$BUILD_CONF"

nft -f "$BUILD_CONF"
if [ $? -eq 0 ]; then
    cp "$BUILD_CONF" "$SYSTEM_CONF"
    systemctl enable nftables &>/dev/null
    systemctl restart nftables &>/dev/null
    exit 0
else
    echo "❌ 动态生成的 nft.conf 存在语法错误，拒绝写入内核！"
    exit 1
fi
