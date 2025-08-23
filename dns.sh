#!/bin/bash
set -e

echo "=== 自定义 DNS 管理脚本 ==="
read -p "请输入自定义 DNS（空格分隔）: " USER_DNS

if [ -z "$USER_DNS" ]; then
    echo "自定义 DNS 不能为空，退出！"
    exit 1
fi

# 转换为 nameserver 格式
DNS_CONTENT=""
for d in $USER_DNS; do
    DNS_CONTENT="$DNS_CONTENT\nnameserver $d"
done
DNS_CONTENT=${DNS_CONTENT#\\n}

# systemd-resolved 部分
if systemctl is-active --quiet systemd-resolved; then
    echo "[*] systemd-resolved 管理中，设置接口和全局 DNS..."

    # 1️⃣ 修改全局 DNS
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/custom-dns.conf <<EOF
[Resolve]
DNS=$USER_DNS
FallbackDNS=
EOF

    # 2️⃣ 获取所有活动接口，排除 lo 和虚拟接口
    INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -Ev '^(lo|wg|docker|virbr|br-)')

    for IFACE in $INTERFACES; do
        echo "[*] 设置接口 $IFACE 的 DNS（保留原有 DNS 并追加用户输入 DNS）"
        
        # 获取接口原有 DNS，只取 IP
        OLD_DNS=$(resolvectl dns "$IFACE" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')

        # 合并原有 DNS 和用户输入 DNS
        if [ -n "$OLD_DNS" ]; then
            COMBINED_DNS="$OLD_DNS $USER_DNS"
        else
            COMBINED_DNS="$USER_DNS"
        fi

        # 设置接口 DNS
        resolvectl dns "$IFACE" $COMBINED_DNS
        resolvectl domain "$IFACE" "~."  # 使用全局搜索域
    done

    systemctl restart systemd-resolved
    echo "[*] systemd-resolved 配置完成。"
fi

# NetworkManager 部分
if systemctl is-active --quiet NetworkManager; then
    echo "[*] NetworkManager 管理中，修改活动连接 DNS..."
    ACTIVE_CONN=$(nmcli -t -f NAME c show --active | head -n1)
    nmcli connection modify "$ACTIVE_CONN" ipv4.dns "$USER_DNS" ipv4.ignore-auto-dns yes
    nmcli connection up "$ACTIVE_CONN" >/dev/null
    echo "[*] NetworkManager 配置完成。"
fi

# dhcpcd 部分
if pgrep -x dhcpcd >/dev/null 2>&1; then
    echo "[*] dhcpcd 管理中，写入 /etc/resolv.conf.head ..."
    echo -e "$DNS_CONTENT" > /etc/resolv.conf.head
    dhcpcd -n
    echo "[*] dhcpcd 配置完成。"
fi

# 传统静态 /etc/resolv.conf
if ! systemctl is-active --quiet systemd-resolved \
   && ! systemctl is-active --quiet NetworkManager \
   && ! pgrep -x dhcpcd >/dev/null 2>&1; then
    echo "[*] 使用传统方式，直接覆盖 /etc/resolv.conf ..."
    echo -e "$DNS_CONTENT" > /etc/resolv.conf
fi

echo "[*] 当前 DNS 状态："
cat /etc/resolv.conf



# systemd 自动启动服务
SERVICE_FILE="/etc/systemd/system/custom-dns.service"
if [ ! -f "$SERVICE_FILE" ]; then
    echo "[*] 创建 systemd 服务 custom-dns.service ..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Apply custom DNS at startup
After=network.target

[Service]
Type=oneshot
ExecStart=$(realpath $0)
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable custom-dns.service
    echo "[*] systemd 服务已启用，开机自动应用 DNS"
fi

echo "[*] 正在刷新 apt 缓存 ..."
apt-get update --fix-missing
