#!/bin/bash

# 确保以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 权限运行此脚本！"
  exit 1
fi

CONFIG_FILE="/etc/sing-box/config.json"
CERT_DIR="/etc/sing-box/certs"
BINARY_PATH="/usr/local/bin/sing-box"
SYSTEMD_PATH="/etc/systemd/system/sing-box.service"

# 使用路由表获取本机的真实 network 出口内网/公网 IP
get_ip() {
    SERVER_IP=$(curl -4 -s --max-time 3 ifconfig.me || curl -4 -s --max-time 3 api.ipify.org)
    if [ -z "$SERVER_IP" ]; then
        # 终极路由表查询兜底
        SERVER_IP=$(ip route get 1.1.1.1 | awk '{print $7}' | head -1)
    fi
}

# 1. 动态安装官方最新版核心 (含高容错 API 校验与版本自动升级机制)
install_sing_box_core() {
    echo "正在从官方 GitHub 获取最新稳定版..."
    apt-get update && apt-get install -y curl jq tar gzip openssl wget
    
    # 【高容错 API 捕获与字段校验】
    HTTP_CODE=$(curl -s -o /tmp/sb.json -w "%{http_code}" https://api.github.com/repos/SagerNet/sing-box/releases/latest)

    if [ "$HTTP_CODE" != "200" ] || ! jq -e .tag_name /tmp/sb.json >/dev/null 2>&1; then
        echo "⚠️ API 响应异常或内容残缺，使用兜底版本"
        LATEST_VER="1.11.0"
    else
        LATEST_VER=$(jq -r .tag_name /tmp/sb.json | sed 's/^v//')
    fi
    rm -f /tmp/sb.json

    # 核心升级/安装判断逻辑
    if [ -f "$BINARY_PATH" ]; then
        SB_VER=$($BINARY_PATH version | awk '{print $3}' | sed 's/^v//')
        echo "🟢 检测到当前系统已存在 sing-box，版本为: $SB_VER"
        
        # 运用 dpkg 进行语义化版本对比，低于最新版则执行升级
        if dpkg --compare-versions "$SB_VER" ge "$LATEST_VER" 2>/dev/null; then
            echo "🟢 当前核心已是最新版本，跳过安装。"
            return
        else
            echo "🔄 当前版本过低（不支持新版 masquerade_url 字段），正在自动升级核心至 v${LATEST_VER}..."
        fi
    fi
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH="linux-amd64" ;;
        aarch64) ARCH="linux-arm64" ;;
        *) echo "❌ 暂不支持的架构: $ARCH"; exit 1 ;;
    esac

    URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VER}/sing-box-${LATEST_VER}-${ARCH}.tar.gz"
    echo "正在下载 v${LATEST_VER}..."
    
    # 鲁棒性解压逻辑：剔除外层目录包裹，防止官方打包改名导致 mv 失败
    wget -O /tmp/sing-box.tar.gz "$URL"
    mkdir -p /tmp/sb_extracted
    tar -zxvf /tmp/sing-box.tar.gz -C /tmp/sb_extracted --strip-components=1
    mv /tmp/sb_extracted/sing-box $BINARY_PATH
    chmod +x $BINARY_PATH
    rm -rf /tmp/sing-box* /tmp/sb_extracted

    # 写入完美兼容的 systemd 配置文件
    cat << EOF > $SYSTEMD_PATH
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$BINARY_PATH run -c $CONFIG_FILE
Restart=on-failure
RestartSec=18s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    echo "🟢 sing-box 核心及守护进程安装/升级成功！"
}

# 2. 添加/部署功能
add_hy2() {
    echo "========================================="
    echo "  1. 开始部署 sing-box (Hy2) 反代配置"
    echo "========================================="
    
    if [ -f "$CONFIG_FILE" ]; then
        echo "⚠️ 检测到当前已存在配置文件，继续操作将覆盖原有配置！"
        read -p "是否继续？(y/n): " choice
        if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
            return
        fi
    fi

    read -p "请输入你想偷的域名 (默认: www.icloud.com): " SNI_DOMAIN
    SNI_DOMAIN=${SNI_DOMAIN:-www.icloud.com}

    read -p "请输入你远程反代的 CF 真实网站域名 (例如: myblog.com): " PROXY_INPUT
    if [ -z "$PROXY_INPUT" ]; then
        echo "❌ 错误：反代域名不能为空！"
        return
    fi
    PROXY_DOMAIN=$(echo "$PROXY_INPUT" | sed 's|https\?://||' | sed 's|/.*||')

    # 32 位强随机密码
    HY2_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)

    # 触发核心安装或平滑升级
    install_sing_box_core

    mkdir -p $CERT_DIR
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "$CERT_DIR/self_signed.key" \
      -out "$CERT_DIR/self_signed.crt" \
      -subj "/CN=$SNI_DOMAIN"

    mkdir -p $(dirname $CONFIG_FILE)
    
    # 采用新版官方标准的 masquerade_url 字符串字段
    cat << EOF > $CONFIG_FILE
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "password": "$HY2_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI_DOMAIN",
        "certificate_path": "$CERT_DIR/self_signed.crt",
        "key_path": "$CERT_DIR/self_signed.key"
      },
      "masquerade_url": "https://$PROXY_DOMAIN"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    echo "🔍 正在校验 sing-box 配置文件..."
    if ! $BINARY_PATH check -c $CONFIG_FILE; then
        echo "❌ 配置文件校验失败，请检查参数！"
        return
    fi

    systemctl enable sing-box 2>/dev/null
    systemctl restart sing-box

    sleep 1.5
    
    # 【故障即时回溯】
    if ! systemctl is-active --quiet sing-box; then
        echo "❌ sing-box 启动失败，自动输出日志："
        journalctl -u sing-box --no-pager -n 30
        return
    fi

    echo "🟢 部署成功！"
    view_hy2
}

# 3. 查看当前配置功能
view_hy2() {
    echo "========================================="
    echo "  2. 查看当前 Hy2 节点配置与运行状态"
    echo "========================================="
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ 未检测到有效的已部署配置。"
        return
    fi

    # 引入高鲁棒性的 json 解析校验，防止配置文件手动改坏导致报错中断
    if ! jq . $CONFIG_FILE >/dev/null 2>&1; then
        echo "❌ 配置文件 JSON 格式损坏，无法解析！"
        return
    fi

    get_ip
    HY2_PASSWORD=$(jq -r '.inbounds[0].users[0].password' $CONFIG_FILE)
    SNI_DOMAIN=$(jq -r '.inbounds[0].tls.server_name' $CONFIG_FILE)
    PROXY_DOMAIN=$(jq -r '.inbounds[0].masquerade_url' $CONFIG_FILE | sed 's|https\?://||')

    SHARE_LINK="hysteria2://$HY2_PASSWORD@$SERVER_IP:443?sni=$SNI_DOMAIN&insecure=1#AWS_Hy2_iCloud"

    echo "--- 服务器当前状态 ---"
    echo "本机识别 IP:  $SERVER_IP"
    echo "伪装(SNI)域名: $SNI_DOMAIN"
    echo "远程反代地址: $PROXY_DOMAIN"
    echo "节点通讯密码: $HY2_PASSWORD"
    echo "----------------------------------------"
    echo "🔍 运行状态排查："
    
    if command -v ss &> /dev/null; then
        echo "【443 端口占用状况 (Hy2 走 UDP)】"
        ss -tulnp | grep :443 || echo "⚠️ 未检测到 443 端口被监听，请检查服务状态。"
    fi
    
    echo -e "\n【Systemd 服务状态摘要】"
    systemctl status sing-box | grep -E "Active:|Main PID:"
    
    echo "----------------------------------------"
    echo "📱 Shadowrocket (小火箭) 文本配置 (直接复制):"
    echo "$SHARE_LINK"
    echo ""
    echo "🍏 Surge 文本配置 (复制到 [Proxy] 段落):"
    echo "AWS_Hy2_iCloud = hysteria2, $SERVER_IP, 443, password=$HY2_PASSWORD, sni=$SNI_DOMAIN, skip-cert-verify=true"
    echo "----------------------------------------"
    echo "📷 节点二维码 (支持小火箭扫码):"
    curl -s "https://qrenco.de/$SHARE_LINK" || echo "⚠️ 二维码渲染超时，请直接使用上方文本节点。"
    echo "========================================="
}

# 4. 删除功能
delete_hy2() {
    echo "========================================="
    echo "  3. 彻底卸载与删除全部组件"
    echo "========================================="
    
    echo "⚠️ 敏感操作：请输入 'YES' 确认彻底卸载并清理全部组件（输入内容隐藏）："
    read -s -p "确认清除输入: " confirm_code
    echo ""
    
    if [ "$confirm_code" == "YES" ]; then
        echo "正在全面清理系统环境..."
        systemctl stop sing-box 2>/dev/null
        systemctl disable sing-box 2>/dev/null
        rm -f $SYSTEMD_PATH
        systemctl daemon-reload
        rm -f $BINARY_PATH
        rm -rf $CONFIG_FILE
        rm -rf $CERT_DIR
        rm -f /tmp/sing-box*
        echo "🗑️ 核心程序、Systemd 守护进程、自签证书、JSON 配置已全数卸载擦除！"
    else
        echo "❌ 验证未通过，取消删除。"
    fi
}

# 主菜单循环
while true; do
    echo ""
    echo "========================================="
    echo "   AWS sing-box (Hy2) 核心管理菜单"
    echo "========================================="
    echo " 1. 添加/覆盖 部署节点"
    echo " 2. 查看当前 节点配置与状态排查"
    echo " 3. 彻底卸载 节点与核心程序"
    echo " 4. 退出脚本"
    echo "========================================="
    read -p "请选择操作 [1-4]: " num

    case "$num" in
        1) add_hy2 ;;
        2) view_hy2 ;;
        3) delete_hy2 ;;
        4) echo "退出成功。"; exit 0 ;;
        *) echo "❌ 输入错误，请输入正确的数字 [1-4]" ;;
    esac
done
