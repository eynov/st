#!/bin/bash
# --- render.sh ---

# 🔹 动态获取脚本所在目录的绝对路径
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_FILE="$BASE_DIR/state.json"
BUILD_DIR="$BASE_DIR/build"
BUILD_CONF="$BUILD_DIR/nft.conf"
SYSTEM_CONF="/etc/nftables.conf"

# 自动化环境检查
mkdir -p "$BUILD_DIR"
if [[ $EUID -ne 0 ]]; then
   echo "❌ 编译器必须以 root 权限运行"
   exit 1
fi

# 检查基础依赖
if ! command -v jq &> /dev/null || ! command -v dig &> /dev/null; then
    apt-get update && apt-get install -y jq dnsutils curl nftables > /dev/null
fi

# 确保系统内核转发开启
sysctl -w net.ipv4.ip_forward=1 > /dev/null
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf

# 获取本机公网 IP (用于 SNAT 分流)
SRC_IP=$(curl -s4 -m 3 https://api.ip.sb/ip || curl -s4 -m 3 https://ifconfig.me)
if [ -z "$SRC_IP" ]; then
    echo "❌ 无法获取本机公网 IP，中断编译。"
    exit 1
fi

# --- 数据清洗与安全边界处理 ---
BLACKLIST=$(jq -r '.blacklist | join(", ")' "$STATE_FILE" 2>/dev/null)
[ -z "$BLACKLIST" ] && BLACKLIST="127.0.0.2"

TCP_PORTS=$(jq -r '.open_ports.tcp | join(", ")' "$STATE_FILE" 2>/dev/null)
[ -z "$TCP_PORTS" ] && TCP_PORTS="65535"

UDP_PORTS=$(jq -r '.open_ports.udp | join(", ")' "$STATE_FILE" 2>/dev/null)
[ -z "$UDP_PORTS" ] && UDP_PORTS="65535"

# --- 动态组装转发规则 ---
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

# --- 模板渲染逻辑 ---
echo "flush ruleset" > "$BUILD_CONF"

# 1. 渲染 filter 表
cat "$BASE_DIR/rules/filter.nft.tpl" >> "$BUILD_CONF"
sed -i "s/#BLACKLIST#/$BLACKLIST/g" "$BUILD_CONF"
sed -i "s/#TCP_PORTS#/$TCP_PORTS/g" "$BUILD_CONF"
sed -i "s/#UDP_PORTS#/$UDP_PORTS/g" "$BUILD_CONF"

# 2. 渲染 nat 表
cat "$BASE_DIR/rules/nat.nft.tpl" >> "$BUILD_CONF"
sed -i "s@#DNAT_RULES#@$DNAT_RULES@g" "$BUILD_CONF"
sed -i "s@#SNAT_RULES#@$SNAT_RULES@g" "$BUILD_CONF"

# --- 规则热加载与事务合并 ---
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
