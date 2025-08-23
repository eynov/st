#!/bin/bash

# ========== 安装 Shadowsocks-Rust ==========
SS_DIR="/etc/shadowsocks"
SS_EXEC="/usr/local/bin/ss-server"
SS_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v1.22.0/shadowsocks-v1.22.0.x86_64-unknown-linux-gnu.tar.xz"
SS_ZIP="shadowsocks-v1.22.0.x86_64-unknown-linux-gnu.tar.xz"

if [ ! -f "$SS_EXEC" ]; then
  echo ">> 安装 Shadowsocks-Rust..."
  sudo mkdir -p ${SS_DIR}
  cd ${SS_DIR}
  wget -O ${SS_ZIP} ${SS_URL} || { echo "下载失败"; exit 1; }
  python3 -c "import tarfile; tarfile.open('${SS_ZIP}', 'r:xz').extractall('${SS_DIR}')" || { echo "解压失败"; exit 1; }
  sudo mv ${SS_DIR}/ssserver ${SS_EXEC}
  sudo chmod +x ${SS_EXEC}
  echo ">> Shadowsocks-Rust 安装完成"
else
  echo ">> Shadowsocks-Rust 已存在，跳过安装"
fi

# ========== 安装 qrencode ==========
if ! command -v qrencode >/dev/null 2>&1; then
  echo ">> 安装 qrencode..."
  sudo apt update && sudo apt install -y qrencode
fi

# 获取公网 IP 或输入域名
read -p "请输入你的域名（留空则自动获取公网 IP）: " SERVER_DOMAIN
if [ -z "$SERVER_DOMAIN" ]; then
  SERVER_IP=$(curl -4 ifconfig.me)
else
  SERVER_IP=$SERVER_DOMAIN
fi
echo ">> 使用的地址: $SERVER_IP"
# ========== 选择协议 ==========
echo "请选择协议："
echo "  1) Shadowsocks (SS)"
echo "  2) Shadowsocks 2022 (SS2022)"
read -p "输入选项 (1-2，默认 1): " PROTO_OPT

if [ "$PROTO_OPT" = "2" ]; then
  PROTO="ss2022"
else
  PROTO="ss"
fi

# ========== 输入端口 ==========
read -p "请输入批量端口号（空格分隔，例如 1234 5678）: " PORTS

SURGE_FILE="${SS_DIR}/surge_nodes.conf"
QR_DIR="${SS_DIR}/qrcodes"
mkdir -p $QR_DIR
echo "# Surge 节点配置" > $SURGE_FILE

for PORT in $PORTS; do
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo ">> 跳过无效端口：$PORT"
    continue
  fi

  SS_CONF="${SS_DIR}/config${PORT}.json"
  SYSTEMD_SERVICE="/etc/systemd/system/ss${PORT}.service"

  if [ "$PROTO" = "ss" ]; then
    # SS 可选 none / AEAD
    echo "请选择端口 ${PORT} 的加密方式："
    echo "  1) none"
    echo "  2) aes-128-gcm"
    echo "  3) aes-256-gcm"
    echo "  4) chacha20-ietf-poly1305"
    read -p "输入选项 (1-4，默认 1): " METHOD_OPT
    case "$METHOD_OPT" in
      2) METHOD="aes-128-gcm" ;;
      3) METHOD="aes-256-gcm" ;;
      4) METHOD="chacha20-ietf-poly1305" ;;
      *) METHOD="none" ;;
    esac
    PASSWORD=$(openssl rand -hex 16)

    sudo tee ${SS_CONF} > /dev/null << EOL
{
  "server": "0.0.0.0",
  "server_port": ${PORT},
  "password": "${PASSWORD}",
  "method": "${METHOD}",
  "timeout": 300,
  "mode": "tcp_and_udp"
}
EOL

     # 生成 Surge Proxy 配置行
    LINK="SS_${PORT} = ss, ${SERVER_IP}, ${PORT}, encrypt-method=${METHOD}, password=${PASSWORD}, udp-relay=true"

  else
    # SS2022
    echo "请选择端口 ${PORT} 的加密方式："
    echo "  1) 2022-blake3-aes-128-gcm"
    echo "  2) 2022-blake3-aes-256-gcm"
    echo "  3) 2022-blake3-chacha20-poly1305"
    read -p "输入选项 (1-3，默认 1): " METHOD_OPT
    case "$METHOD_OPT" in
      2) METHOD="2022-blake3-aes-256-gcm" ;;
      3) METHOD="2022-blake3-chacha20-poly1305" ;;
      *) METHOD="2022-blake3-aes-128-gcm" ;;
    esac
    MASTER_KEY=$(openssl rand -base64 16)
    SUB_KEY=$(openssl rand -base64 16)

    sudo tee ${SS_CONF} > /dev/null << EOL
{
  "server": "0.0.0.0",
  "server_port": ${PORT},
  "method": "${METHOD}",
  "password": "${MASTER_KEY}",
  "users": [
    {
      "name": "user1",
      "password": "${SUB_KEY}"
    }
  ]
}
EOL

      # 生成 Surge Proxy 配置行
    LINK="SS2022_${PORT} = ss, ${SERVER_IP}, ${PORT}, encrypt-method=${METHOD}, password=${SUB_KEY}, udp-relay=true"
  fi

  # systemd 服务
  sudo tee ${SYSTEMD_SERVICE} > /dev/null << EOL
[Unit]
Description=Shadowsocks Service on port ${PORT}
After=network.target

[Service]
ExecStart=${SS_EXEC} -c ${SS_CONF}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL

  # 启动服务
  sudo systemctl daemon-reload
  sudo systemctl enable ss${PORT}
  sudo systemctl restart ss${PORT}
  sudo systemctl is-active --quiet ss${PORT} && echo "Shadowsocks ${PORT} 已启动成功"
  echo ">> 节点已启动，端口: ${PORT}，加密: ${METHOD}"

  # 写入 Surge 文件
  echo "$LINK" >> $SURGE_FILE
  echo ">> Surge 配置行: $LINK"
  # 生成二维码
  QR_FILE="${QR_DIR}/${PORT}.png"
  qrencode -o $QR_FILE -t PNG "$LINK"
  echo ">> 二维码生成完成：$QR_FILE"
  qrencode -t UTF8 "$LINK"

done

echo ">> 所有 Surge 节点已保存到：$SURGE_FILE"
echo ">> 所有二维码 PNG 文件已保存到：$QR_DIR"
