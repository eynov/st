#!/bin/bash

set -e

# ========= Snell 变量配置 =========
SNELL_VERSION="6.0.0b2"
SNELL_DIR="/etc/snell"
SNELL_ZIP="snell-server-v${SNELL_VERSION}-linux-amd64.zip"
SNELL_URL="https://dl.nssurge.com/snell/${SNELL_ZIP}"
SNELL_EXEC="/usr/local/bin/snell-server"

echo "======================================"
echo " Snell v${SNELL_VERSION} Batch Installer"
echo "======================================"

# 检查并自动补齐 OpenSSL 环境
command -v openssl >/dev/null 2>&1 || {
    echo ">> openssl 未安装，正在尝试自动安装..."
    apt update
    apt install -y openssl
}

# ========= 安装 / 升级 =========

mkdir -p ${SNELL_DIR}

echo ">> 下载 Snell v${SNELL_VERSION}..."

cd /tmp
rm -f ${SNELL_ZIP}

wget -q --show-progress ${SNELL_URL}

python3 - <<EOF
import zipfile
zipfile.ZipFile("${SNELL_ZIP}").extractall("/tmp")
EOF

if [ ! -f "/tmp/snell-server" ]; then
    echo "Snell 解压失败"
    exit 1
fi

if [ -f "${SNELL_EXEC}" ]; then
    cp "${SNELL_EXEC}" "${SNELL_EXEC}.bak.$(date +%Y%m%d_%H%M%S)"
fi

mv /tmp/snell-server ${SNELL_EXEC}
chmod +x ${SNELL_EXEC}

echo ">> Snell 主程序已准备就绪"

echo ""
read -p "请输入要创建的端口（空格分隔）: " PORTS
echo ""

CREATED_PORTS=()

for PORT in ${PORTS}; do

    if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
        echo "跳过无效端口: $PORT"
        continue
    fi
    if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo "跳过无效端口: $PORT"
        continue
    fi

    SNELL_CONF="${SNELL_DIR}/snell-server-${PORT}.conf"

    # 1. 避免覆盖已有配置
    if [ -f "${SNELL_CONF}" ]; then
        echo "[警告] 端口 ${PORT} 配置文件已存在，已自动跳过"
        continue
    fi

    # 2. 检查端口是否已被其他程序占用
    if ss -lntup | grep -q ":${PORT}\b"; then
        echo "[错误] 端口 ${PORT} 已被系统其他程序占用，跳过创建"
        continue
    fi

    # 3. 动态检测 IPv6 环境
    if ip -6 addr show scope global | grep -q inet6; then
        LISTEN="0.0.0.0:${PORT},[::]:${PORT}"
        IPV6="true"
    else
        LISTEN="0.0.0.0:${PORT}"
        IPV6="false"
    fi

    PSK=$(openssl rand -hex 32)
    SYSTEMD_SERVICE="/etc/systemd/system/snell-${PORT}.service"
    
    # 4. 生成配置与服务文件
    cat > "${SNELL_CONF}" <<EOF
[snell-server]
listen = ${LISTEN}
psk = ${PSK}
version = 6
dns-ip-preference = prefer-ipv4
mtu = 1350
obfs = disabled
tcp_keepalive = true
ipv6 = ${IPV6}
udp-relay = true
max_conn = 300
EOF

    cat > "${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Snell Proxy Service on Port ${PORT}
After=network.target

[Service]
Type=simple
ExecStart=${SNELL_EXEC} -c ${SNELL_CONF}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    # 5. 立即加载、启动并验证
    echo ">> 正在配置并启动端口: ${PORT}..."
    systemctl daemon-reload
    systemctl enable snell-${PORT} >/dev/null 2>&1
    systemctl restart snell-${PORT}

    # 6. 启动后立即验证（Fail-Fast 机制）
    if ! systemctl is-active --quiet snell-${PORT}; then
        echo "[严重错误] Snell 端口 ${PORT} 启动失败！正在获取实时日志："
        echo "----------------------------------------"
        journalctl -u snell-${PORT} -n 20 --no-pager
        echo "----------------------------------------"
        # 启动失败则清理掉刚生成的残余服务文件，防止污染系统
        rm -f "${SNELL_CONF}" "${SYSTEMD_SERVICE}"
        systemctl daemon-reload
        continue
    fi

    # 只有真正启动成功的端口才会被记录
    CREATED_PORTS+=("${PORT}:${PSK}")

done

# 如果没有任何端口成功启动，直接安全退出
if [ ${#CREATED_PORTS[@]} -eq 0 ]; then
    echo "提示：本次未成功创建或启动任何 Snell 服务。"
    exit 0
fi

echo ""
echo "======================================"
echo " 运行成功 - 凭据列表"
echo "======================================"

for ITEM in "${CREATED_PORTS[@]}"; do
    PORT=$(echo "$ITEM" | cut -d':' -f1)
    PSK=$(echo "$ITEM" | cut -d':' -f2)

    echo ""
    echo "Port : ${PORT}"
    echo "PSK  : ${PSK}"
done

echo ""
echo "======================================"
echo " 实例服务状态简报"
echo "======================================"

for ITEM in "${CREATED_PORTS[@]}"; do
    PORT=$(echo "$ITEM" | cut -d':' -f1)
    systemctl --no-pager --lines=0 status snell-${PORT}
done
