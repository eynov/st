#!/bin/bash

# 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "❌ 请以 root 权限运行此脚本"
   exit 1
fi

NFT_BIN=$(which nft)
NFT_CONF="/etc/nftables.conf"

# 检查 nftables 是否安装
if [ -z "$NFT_BIN" ]; then
    echo "⚙️  正在安装 nftables..."
    apt update && apt install -y nftables curl dnsutils
fi

# --- 参数输入 ---
read -p "请输入落地服务器 IP 或域名: " DST_ADDR
read -p "请输入起始端口 (如 25831): " START_PORT
read -p "请输入结束端口 (如 25900, 若单端口则填一样): " END_PORT

PORT_RANGE="${START_PORT}-${END_PORT}"

# --- 核心逻辑 ---

# 1. 解析目标 IP
if [[ "$DST_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    DST_IP="$DST_ADDR"
else
    DST_IP=$(dig +short "$DST_ADDR" | tail -n1)
    if [ -z "$DST_IP" ]; then
        echo "❌ 域名解析失败: $DST_ADDR"
        exit 1
    fi
fi

# 2. 获取本机公网 IP (用于 SNAT)
SRC_IP=$(curl -s4 -m 5 https://api.ip.sb/ip || curl -s4 -m 5 https://ifconfig.me)
if [ -z "$SRC_IP" ]; then
    echo "❌ 无法自动获取公网 IP，请手动输入本机公网 IP:"
    read -p "本机 IP: " SRC_IP
fi

# 3. 开启系统内核转发
echo "🔓 开启内核转发..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf

# 4. 生成 nftables 配置文件
cat > "$NFT_CONF" << EOF
flush ruleset

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport $PORT_RANGE dnat to $DST_IP
        udp dport $PORT_RANGE dnat to $DST_IP
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip daddr $DST_IP tcp dport $PORT_RANGE snat to $SRC_IP
        ip daddr $DST_IP udp dport $PORT_RANGE snat to $SRC_IP
    }
}
EOF

# 5. 应用并设置自启
$NFT_BIN -f "$NFT_CONF"
systemctl enable nftables
systemctl restart nftables

echo "---"
echo "✅ 转发配置成功！"
echo "📍 本机 ($SRC_IP) : $PORT_RANGE -> 目标 ($DST_IP) : $PORT_RANGE"
echo "📄 配置文件已保存至: $NFT_CONF"
