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
    # 如果配置文件存在，读取路径
    source "$CONFIG_FILE"
    echo "✅ 已加载之前的证书配置："
    echo "CERT_PATH=$CERT_PATH"
    echo "KEY_PATH=$KEY_PATH"
    echo "TRUSTED_CERT=$TRUSTED_CERT"
else
    # 第一次运行：询问路径并保存
    read -p "请输入证书路径（默认 /etc/ssl/certs/eyes.pem）: " CERT_PATH
    CERT_PATH=${CERT_PATH:-/etc/ssl/certs/eyes.pem}

    read -p "请输入私钥路径（默认 /etc/ssl/private/eyes.key）: " KEY_PATH
    KEY_PATH=${KEY_PATH:-/etc/ssl/private/eyes.key}

    read -p "请输入 Cloudflare 根证书路径（默认 /etc/ssl/certs/origin_ca_ecc_root.pem）: " TRUSTED_CERT
    TRUSTED_CERT=${TRUSTED_CERT:-/etc/ssl/certs/origin_ca_ecc_root.pem}

    echo "CERT_PATH=\"$CERT_PATH\"" > "$CONFIG_FILE"
    echo "KEY_PATH=\"$KEY_PATH\"" >> "$CONFIG_FILE"
    echo "TRUSTED_CERT=\"$TRUSTED_CERT\"" >> "$CONFIG_FILE"
    echo "✅ 证书路径配置已保存到 $CONFIG_FILE"
fi

# ========== Cloudflare 同步函数 ==========
CONF_DIR="/etc/nginx/conf.d"
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
    read -p "是否启用 Cloudflare CDN？[y/N]: " PROXY_CHOICE

    [[ "$PROXY_CHOICE" == "y" || "$PROXY_CHOICE" == "Y" ]] && PROXIED=true || PROXIED=false
    SERVER_IP=$(curl -s https://api.ipify.org)

    CONF_PATH="${CONF_DIR}/${SUBDOMAIN}.conf"

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

    cat > "${CONF_DIR}/${SUBDOMAIN}_redirect.conf" <<EOF
server {
    listen 80;
    server_name ${SUBDOMAIN};

    return 301 https://\$host\$request_uri;
}
EOF

    nginx -t && systemctl reload nginx && echo "✅ 添加成功：${SUBDOMAIN}"

    sync_to_cloudflare "$SUBDOMAIN" "$SERVER_IP" "$PROXIED"
}

# ========== 删除 ==========
function delete_domain() {
    read -p "请输入要删除的域名 : " SUBDOMAIN
    rm -f "${CONF_DIR}/${SUBDOMAIN}.conf" "${CONF_DIR}/${SUBDOMAIN}_redirect.conf"
    nginx -t && systemctl reload nginx && echo "🗑️ 删除成功：${SUBDOMAIN}"
}

# ========== 批量推送子域名到 Cloudflare（无 Nginx） ==========
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

# ========== 列出 ==========
function list_domains() {
    echo "📄 已添加的域名："
    for file in "$CONF_DIR"/*.conf; do
        [[ -f "$file" ]] || continue
        domain=$(basename "$file" .conf)
        echo "- $domain"
    done
}

# ========== 添加主域名 ==========
function add_main_domain_204() {
    read -p "请输入主域名（如 eynov.com）: " ROOT_DOMAIN
    read -p "是否启用 Cloudflare CDN（橙色云）？[y/N]: " PROXY_CHOICE
    [[ "$PROXY_CHOICE" == "y" || "$PROXY_CHOICE" == "Y" ]] && PROXIED=true || PROXIED=false
    SERVER_IP=$(curl -s https://api.ipify.org)

    cat > "${CONF_DIR}/${ROOT_DOMAIN}.conf" <<EOF
server {
    listen 443 ssl;
    server_name ${ROOT_DOMAIN} www.${ROOT_DOMAIN};

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

    add_header Strict-Transport-Security "max-age=31536000" always;

    location / {
        return 204;
    }
}
EOF

    cat > "${CONF_DIR}/${ROOT_DOMAIN}_redirect.conf" <<EOF
server {
    listen 80;
    server_name ${ROOT_DOMAIN} www.${ROOT_DOMAIN};

    return 301 https://\$host\$request_uri;
}
EOF

    nginx -t && systemctl reload nginx && echo "✅ 主域名配置完成"

    sync_to_cloudflare "$ROOT_DOMAIN" "$SERVER_IP" "$PROXIED"
}

# ========== 主菜单 ==========
while true; do
    echo -e "\n====== Nginx 子域名管理工具 v2.0 ======"
    echo "1. 添加域名"
    echo "2. 批量添加子域名"
    echo "3. 删除域名"
    echo "4. 列出已添加域名"
    echo "5. 添加主域名并返回 204 空响应"
    echo "0. 退出"
    read -p "请选择操作 [0-5]: " CHOICE

    case $CHOICE in
        1) add_domain ;;
        2) batch_add ;;
        3) delete_domain ;;
        4) list_domains ;;
        5) add_main_domain_204 ;;
        0) exit 0 ;;
        *) echo "❌ 无效选择，请重新输入。" ;;
    esac
done
