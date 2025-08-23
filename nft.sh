#!/bin/bash
# nftables 持久化端口转发脚本
# 功能：
# 1. 支持域名/IP
# 2. 支持端口范围
# 3. 自动获取本机公网IP
# 4. 立即生效并写入 /etc/nftables.conf

NFT_BIN="/usr/sbin/nft"
NFT_CONF="/etc/nftables.conf"

# 读取落地IP或域名
read -p "请输入落地服务器IP或域名: " DST_ADDR
read -p "请输入端口范围 (如 25831-25900): " PORT_RANGE

# 解析域名为IP
if [[ "$DST_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    DST_IP="$DST_ADDR"
else
    DST_IP=$(getent ahosts "$DST_ADDR" | awk '/STREAM/ {print $1; exit}')
    if [ -z "$DST_IP" ]; then
        echo "❌ 域名解析失败，请检查：$DST_ADDR"
        exit 1
    fi
fi

# 自动获取本机公网IP
SRC_IP=$(curl -s ipv4.ip.sb)
if [ -z "$SRC_IP" ]; then
    SRC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)
fi
if [ -z "$SRC_IP" ]; then
    echo "❌ 无法获取本机公网IP，请手动输入"
    read -p "请输入本机出口IP: " SRC_IP
fi

echo "✅ 配置参数："
echo "  落地输入值 : $DST_ADDR"
echo "  落地IP     : $DST_IP"
echo "  端口范围   : $PORT_RANGE"
echo "  本机出口IP : $SRC_IP"

# 清空现有 nftables 规则
$NFT_BIN flush ruleset

# 写入 /etc/nftables.conf
cat > "$NFT_CONF" << EOF
flush ruleset

table ip nat {
    chain PREROUTING {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport $PORT_RANGE dnat to $DST_IP
        udp dport $PORT_RANGE dnat to $DST_IP
    }

    chain POSTROUTING {
        type nat hook postrouting priority srcnat; policy accept;
        ip daddr $DST_IP tcp dport $PORT_RANGE snat to $SRC_IP
        ip daddr $DST_IP udp dport $PORT_RANGE snat to $SRC_IP
    }
}
EOF

# 立即加载规则
$NFT_BIN -f "$NFT_CONF"

echo "✅ nftables 转发规则已应用并持久化到 $NFT_CONF"