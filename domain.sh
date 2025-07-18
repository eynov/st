#!/bin/bash

# ========== 加载 Cloudflare API 环境变量 ==========
if [ -f /etc/variable ]; then
    export $(grep -v '^#' /etc/variable | xargs)
else
    echo "❌ 无法找到 /etc/variable 文件，请确保它存在并包含 Cloudflare 相关变量"
    exit 1
fi

if [[ -z "$CF_API_TOKEN" || -z "$CF_ZONE_ID" ]]; then
    echo "❌ Cloudflare 环境变量未设置（CF_API_TOKEN 或 CF_ZONE_ID 缺失）"
    exit 1
fi

CONFIG_FILE="/etc/nginx/.ssl_config"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    echo "✅ 已加载证书配置："
    echo "CERT_PATH=$CERT_PATH"
    echo "KEY_PATH=$KEY_PATH"
    echo "TRUSTED_CERT=$TRUSTED_CERT"
else
    read -p "请输入证书路径（默认 /etc/ssl/certs/eyes.pem）: " CERT_PATH
    CERT_PATH=${CERT_PATH:-/etc/ssl/certs/eyes.pem}

    read -p "请输入私钥路径（默认 /etc/ssl/private/eyes.key）: " KEY_PATH
    KEY_PATH=${KEY_PATH:-/etc/ssl/private/eyes.key}

    read -p "请输入 Cloudflare 根证书路径（默认 /etc/ssl/certs/origin_ca_ecc_root.pem）: " TRUSTED_CERT
    TRUSTED_CERT=${TRUSTED_CERT:-/etc/ssl/certs/origin_ca_ecc_root.pem}

    echo "CERT_PATH=\"$CERT_PATH\"" > "$CONFIG_FILE"
    echo "KEY_PATH=\"$KEY_PATH\"" >> "$CONFIG_FILE"
    echo "TRUSTED_CERT=\"$TRUSTED_CERT\"" >> "$CONFIG_FILE"
    echo "✅ 证书路径已保存到 $CONFIG_FILE"
fi

# ========== 配置目录 ==========
AVAILABLE_DIR="/etc/nginx/sites-available"
ENABLED_DIR="/etc/nginx/sites-enabled"

# ========== Cloudflare 同步 ==========
function sync_to_cloudflare() {
    local DOMAIN=$1
    local IP=$2
    local PROXIED=$3
    echo "🔄 正在同步 $DOMAIN 到 Cloudflare..."

    RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=A&name=$DOMAIN" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')

    if [[ "$RECORD_ID" == "null" || -z "$RECORD_ID" ]]; then
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$IP\",\"ttl\":120,\"proxied\":$PROXIED}" \
            | grep -q '"success":true' && echo "✅ 添加成功" || echo "❌ 添加失败"
    else
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$RECORD_ID" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$IP\",\"ttl\":120,\"proxied\":$PROXIED}" \
            | grep -q '"success":true' && echo "✅ 更新成功" || echo "❌ 更新失败"
    fi
}

# ========== 添加域名 ==========
function add_domain() {
    read -p "请输入域名 : " SUBDOMAIN

    read -p "请输入后端地址 : " BACKEND
    if [[ ! "$BACKEND" =~ ^[a-zA-Z0-9.-]+:[0-9]+$ ]]; then
        echo "❌ 格式不正确，应为 域名或IP:端口，例如 example.com:8080 或 127.0.0.1:8080"
        return 1
    fi

    read -p "是否启用 Cloudflare CDN？[y/N]: " PROXY_CHOICE
    [[ "$PROXY_CHOICE" == "y" || "$PROXY_CHOICE" == "Y" ]] && PROXIED=true || PROXIED=false
    SERVER_IP=$(curl -s https://api.ipify.org)

    # 解析IP和端口
    IP=$(echo "$BACKEND" | cut -d':' -f1)
    PORT=$(echo "$BACKEND" | cut -d':' -f2)

    # 仅当后端IP是127.0.0.1时，创建本地静态服务配置
    if [[ "$IP" == "127.0.0.1" ]]; then
        LOCAL_STATIC_CONF="/etc/nginx/sites-available/local_static_${PORT}.conf"
        if [[ ! -f "$LOCAL_STATIC_CONF" ]]; then
            echo "🔧 正在创建本地静态目录服务（监听 127.0.0.1:${PORT}）..."

            mkdir -p /srv

            cat > "$LOCAL_STATIC_CONF" <<EOF
server {
    listen 127.0.0.1:${PORT};
    server_name localhost;

    location / {
        root /srv;
        autoindex on;
        default_type text/plain;
    }
}
EOF

            ln -sf "$LOCAL_STATIC_CONF" "/etc/nginx/sites-enabled/local_static_${PORT}.conf"
            echo "✅ 已启用本地静态目录服务 (127.0.0.1:${PORT})"
        else
            echo "ℹ️ 本地静态服务 (127.0.0.1:${PORT}) 已存在，跳过创建"
        fi
    fi

    CONF_PATH="${AVAILABLE_DIR}/${SUBDOMAIN}.conf"

    cat > "$CONF_PATH" <<EOF
server {
    listen 443 ssl http2;
    server_name ${SUBDOMAIN};

    client_max_body_size 100m;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    ssl_trusted_certificate $TRUSTED_CERT;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    ssl_stapling on;
    ssl_stapling_verify on;

    add_header Strict-Transport-Security "max-age=31536000" always;

    location / {
        proxy_pass http://${BACKEND};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    cat > "${AVAILABLE_DIR}/${SUBDOMAIN}_redirect.conf" <<EOF
server {
    listen 80;
    server_name ${SUBDOMAIN};

    return 301 https://\$host\$request_uri;
}
EOF

    echo "✅ 已生成配置文件：${AVAILABLE_DIR}/${SUBDOMAIN}.conf"

    read -p "是否现在启用该域名？[y/N]: " ENABLE_CHOICE
    if [[ "$ENABLE_CHOICE" == "y" || "$ENABLE_CHOICE" == "Y" ]]; then
        ln -sf "${AVAILABLE_DIR}/${SUBDOMAIN}.conf" "${ENABLED_DIR}/${SUBDOMAIN}.conf"
        ln -sf "${AVAILABLE_DIR}/${SUBDOMAIN}_redirect.conf" "${ENABLED_DIR}/${SUBDOMAIN}_redirect.conf"
        nginx -t && systemctl reload nginx && echo "✅ 已启用：${SUBDOMAIN}"
    else
        echo "⏸️ 已跳过启用，可稍后在菜单中手动启用"
    fi

    sync_to_cloudflare "$SUBDOMAIN" "$SERVER_IP" "$PROXIED"
}
# ========== 删除 ==========
function delete_domain() {
    read -p "请输入要删除的域名 : " SUBDOMAIN
    rm -f "${AVAILABLE_DIR}/${SUBDOMAIN}.conf" "${AVAILABLE_DIR}/${SUBDOMAIN}_redirect.conf"
    rm -f "${ENABLED_DIR}/${SUBDOMAIN}.conf" "${ENABLED_DIR}/${SUBDOMAIN}_redirect.conf"
    nginx -t && systemctl reload nginx && echo "🗑️ 删除成功：${SUBDOMAIN}"
}

# ========== 批量推送 ==========
function batch_add() {
    read -p "请输入批量配置文件路径（格式: 子域名 IP）: " FILE
    [[ ! -f "$FILE" ]] && echo "❌ 文件不存在" && return

    read -p "是否启用 Cloudflare CDN（橙色云）？[y/N]: " PROXY_CHOICE
    [[ "$PROXY_CHOICE" == "y" || "$PROXY_CHOICE" == "Y" ]] && PROXIED=true || PROXIED=false

    while read -r line; do
        SUBDOMAIN=$(echo "$line" | awk '{print $1}')
        IP=$(echo "$line" | awk '{print $2}')
        [[ -z "$SUBDOMAIN" || -z "$IP" ]] && continue
        echo "➡️ 推送 $SUBDOMAIN -> $IP 到 Cloudflare"
        sync_to_cloudflare "$SUBDOMAIN" "$IP" "$PROXIED"
    done < "$FILE"

    echo "✅ 批量 DNS 推送完成"
}

# ========== 启用 ==========
function enable_site() {
    read -p "输入要启用的域名 : " DOMAIN
    if [[ -f "${AVAILABLE_DIR}/${DOMAIN}.conf" ]]; then
        ln -sf "${AVAILABLE_DIR}/${DOMAIN}.conf" "${ENABLED_DIR}/${DOMAIN}.conf"
        [[ -f "${AVAILABLE_DIR}/${DOMAIN}_redirect.conf" ]] && \
        ln -sf "${AVAILABLE_DIR}/${DOMAIN}_redirect.conf" "${ENABLED_DIR}/${DOMAIN}_redirect.conf"
        nginx -t && systemctl reload nginx && echo "✅ 已启用：$DOMAIN"
    else
        echo "❌ 未找到配置文件：${DOMAIN}.conf"
    fi
}

# ========== 禁用 ==========
function disable_site() {
    read -p "输入要禁用的域名 : " DOMAIN
    rm -f "${ENABLED_DIR}/${DOMAIN}.conf" "${ENABLED_DIR}/${DOMAIN}_redirect.conf"
    nginx -t && systemctl reload nginx && echo "✅ 已禁用：$DOMAIN"
}

# ========== 列出 ==========
function list_domains() {
    echo "📄 已启用的域名："
    for file in "$ENABLED_DIR"/*.conf; do
        [[ -f "$file" ]] || continue
        domain=$(basename "$file" .conf)
        echo "- $domain"
    done
}

# ========== 主菜单 ==========
while true; do
    echo -e "\n====== Nginx 子域名管理工具 v2.2 ======"
    echo "1. 添加域名"
    echo "2. 批量添加子域名"
    echo "3. 删除域名（配置+软链）"
    echo "4. 启用已配置但未启用的域名"
    echo "5. 禁用正在启用的域名"
    echo "6. 列出已启用域名"
    echo "0. 退出"
    read -p "请选择操作 [0-6]: " CHOICE

    case $CHOICE in
        1) add_domain ;;
        2) batch_add ;;
        3) delete_domain ;;
        4) enable_site ;;
        5) disable_site ;;
        6) list_domains ;;
        0) exit 0 ;;
        *) echo "❌ 无效选择，请重新输入。" ;;
    esac
done