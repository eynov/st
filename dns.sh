#!/bin/bash
set -e

echo "=== 自定义 DNS 管理脚本 ==="
echo "输入自定义 DNS（多个用空格分开，例如 8.8.8.8 1.1.1.1）"
read -p "请输入自定义 DNS: " USER_DNS

if [ -z "$USER_DNS" ]; then
    echo "自定义 DNS 不能为空，退出！"
    exit 1
fi

# 将用户输入的 DNS 转换为 nameserver 格式
DNS_CONTENT=""
for d in $USER_DNS; do
    DNS_CONTENT="$DNS_CONTENT\nnameserver $d"
done
DNS_CONTENT=${DNS_CONTENT#\\n}  # 去掉开头的换行

echo "[*] 检测当前 DNS 管理方式..."

# 1️⃣ systemd-resolved
if systemctl is-active --quiet systemd-resolved; then
    echo "[*] systemd-resolved 管理中，写入 /etc/systemd/resolved.conf.d/custom-dns.conf ..."
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/custom-dns.conf <<EOF
[Resolve]
DNS=$USER_DNS
FallbackDNS=
EOF
    systemctl restart systemd-resolved
    echo "[*] systemd-resolved 配置完成。"
fi

# 2️⃣ NetworkManager
if systemctl is-active --quiet NetworkManager; then
    echo "[*] NetworkManager 管理中，设置全局 DNS ..."
    ACTIVE_CONN=$(nmcli -t -f NAME c show --active | head -n1)
    nmcli connection modify "$ACTIVE_CONN" ipv4.dns "$USER_DNS" ipv4.ignore-auto-dns yes
    nmcli connection up "$ACTIVE_CONN" >/dev/null
    echo "[*] NetworkManager 配置完成。"
fi

# 3️⃣ dhcpcd
if pgrep -x dhcpcd >/dev/null 2>&1; then
    echo "[*] dhcpcd 管理中，写入 /etc/resolv.conf.head ..."
    echo -e "$DNS_CONTENT" > /etc/resolv.conf.head
    dhcpcd -n
    echo "[*] dhcpcd 配置完成。"
fi

# 4️⃣ 传统静态配置
if ! systemctl is-active --quiet systemd-resolved && ! systemctl is-active --quiet NetworkManager && ! pgrep -x dhcpcd >/dev/null 2>&1; then
    echo "[*] 使用传统方式，直接覆盖 /etc/resolv.conf ..."
    echo -e "$DNS_CONTENT" > /etc/resolv.conf
    echo "[*] 配置完成。"
fi

# 显示当前 /etc/resolv.conf
echo "[*] 当前 /etc/resolv.conf 内容："
cat /etc/resolv.conf

# ====== systemd 自动启动逻辑 ======
SERVICE_FILE="/etc/systemd/system/custom-dns.service"

if [ ! -f "$SERVICE_FILE" ]; then
    echo "[*] 创建 systemd 服务 custom-dns.service ..."
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
    echo "[*] systemd 服务已创建并启用，开机将自动应用 DNS。"
else
    echo "[*] systemd 服务 custom-dns.service 已存在。"
fi