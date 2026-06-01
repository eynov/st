#!/bin/bash

# ====== 1. 基础环境与依赖检查 ======
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

for cmd in curl jq nginx ss; do
    if ! command -v $cmd &> /dev/null; then
        echo "❌ 错误: 系统未安装必要工具 '$cmd'，请先安装 (例如: apt install $cmd)"
        exit 1
    fi
done

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

# 检测 Nginx 版本以兼容新的 HTTP/2 语法
NGINX_VER=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
NGINX_MAIN=$(echo "$NGINX_VER" | cut -d. -f1)
NGINX_SUB=$(echo "$NGINX_VER" | cut -d. -f2)
USE_NEW_HTTP2=false
if [[ "$NGINX_MAIN" -gt 1 ]] || { [[ "$NGINX_MAIN" -eq 1 ]] && [[ "$NGINX_SUB" -ge 25 ]]; }; then
    USE_NEW_HTTP2=true
fi

# ========== 安全安全的死链清理函数 ==========
function safe_clear_broken_links() {
    # 逐个检查 sites-enabled 下的软链接，确保绝不误删
    for link in "$ENABLED_DIR"/*.conf; do
        if [[ -L "$link" ]]; then
            # 如果是软链接，但指向的目标文件不存在，则是死链，安全删除
            if [[ ! -e "$link" ]]; then
                rm -f "$link"
            fi
        fi
    done
}

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
    if [[ -z "$SUBDOMAIN" ]]; then
        echo "❌ 域名不能为空"
        return 1
    fi

    read -p "请输入后端地址 (域名或IP:端口，例如 127.0.0.1:8080) : " BACKEND
    if [[ ! "$BACKEND" =~ ^[a-zA-Z0-9.-]+:[0-9]+$ ]]; then
        echo "❌ 格式不正确，应为 域名或IP:端口"
        return 1
    fi

    read -p "后端是否为 HTTPS 服务？ [y/N]: " USE_HTTPS_BACKEND
    [[ "$USE_HTTPS_BACKEND" == "y" || "$USE_HTTPS_BACKEND" == "Y" ]] && BACKEND_SCHEME="https" || BACKEND_SCHEME="http"

    read -p "是否为 Emby 站点，需要启用视频流优化？ [y/N]: " EMBY_OPT
    read -p "是否启用 Cloudflare CDN？[y/N]: " PROXY_CHOICE
    [[ "$PROXY_CHOICE" == "y" || "$PROXY_CHOICE" == "Y" ]] && PROXIED=true || PROXIED=false
    
    SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org || curl -s --max-time 5 https://ifconfig.me || curl -s --max-time 5 https://icanhazip.com)
    if [[ -z "$SERVER_IP" ]]; then
        echo "❌ 错误：无法获取服务器外部公网 IP，中断 Cloudflare 同步。"
        return 1
    fi

    IP=$(echo "$BACKEND" | cut -d':' -f1)
    PORT=$(echo "$BACKEND" | cut -d':' -f2)

    if [[ "$IP" == "127.0.0.1" ]]; then
        if ss -tuln | grep -q ":${PORT} "; then
            echo "ℹ️ 检测到本地端口 ${PORT} 已经有其他服务在运行，跳过自建本地静态服务。"
        else
            LOCAL_STATIC_CONF="${AVAILABLE_DIR}/local_static_${PORT}.conf"
            if [[ ! -f "$LOCAL_STATIC_CONF" ]]; then
                echo "🔧 正在自动托管本地静态目录服务（监听 127.0.0.1:${PORT}）..."
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
                ln -sf "$LOCAL_STATIC_CONF" "${ENABLED_DIR}/local_static_${PORT}.conf"
                echo "✅ 已拉起并启用本地基础静态服务 (127.0.0.1:${PORT})"
            fi
        fi
    fi

    CONF_PATH="${AVAILABLE_DIR}/${SUBDOMAIN}.conf"

    EXTRA_PROXY_SSL=""
    [[ "$BACKEND_SCHEME" == "https" ]] && EXTRA_PROXY_SSL="        proxy_ssl_verify off;"

    EXTRA_PROXY_OPT=""
    if [[ "$EMBY_OPT" == "y" || "$EMBY_OPT" == "Y" ]]; then
        EXTRA_PROXY_OPT=$(cat <<'EOT'
        # Emby 优化参数
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
EOT
)
    fi

    # 【修复1】完美解决 LISTEN_LINE 换行配置生成错误的问题
    if [[ "$USE_NEW_HTTP2" == true ]]; then
        LISTEN_LINE=$(cat << 'EOF'
    listen 443 ssl;
    http2 on;
EOF
)
    else
        LISTEN_LINE="    listen 443 ssl http2;"
    fi

    cat > "$CONF_PATH" <<EOF
server {
$LISTEN_LINE
    server_name ${SUBDOMAIN};

    client_max_body_size 100m;

    # 【修复2】引入 Resolver 保证动态/域名型 proxy_pass 能够正常解析
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

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
        proxy_pass ${BACKEND_SCHEME}://${BACKEND};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        $EXTRA_PROXY_SSL
        $EXTRA_PROXY_OPT
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

    echo "✅ 已生成主配置文件：${CONF_PATH}"

    read -p "是否现在启用该域名？[y/N]: " ENABLE_CHOICE
    if [[ "$ENABLE_CHOICE" == "y" || "$ENABLE_CHOICE" == "Y" ]]; then
        ln -sf "$CONF_PATH" "${ENABLED_DIR}/${SUBDOMAIN}.conf"
        ln -sf "${AVAILABLE_DIR}/${SUBDOMAIN}_redirect.conf" "${ENABLED_DIR}/${SUBDOMAIN}_redirect.conf"
        if nginx -t &>/dev/null; then
            systemctl reload nginx && echo "✅ Nginx 重新加载成功，已启用：${SUBDOMAIN}"
        else
            echo "❌ Nginx 配置检查失败！请运行 nginx -t 排查。"
        fi
    else
        echo "⏸️ 已跳过本地启用，可稍后在菜单中手动启用"
    fi

    sync_to_cloudflare "$SUBDOMAIN" "$SERVER_IP" "$PROXIED"
}

# ========== 删除域名 ==========
function delete_domain() {
    read -p "请输入要删除的域名 : " SUBDOMAIN
    if [[ -z "$SUBDOMAIN" ]]; then
        echo "❌ 域名不能为空"
        return 1
    fi

    CONF_FILE="${AVAILABLE_DIR}/${SUBDOMAIN}.conf"
    LOCAL_SERVICE_DELETED=false

    if [[ -f "$CONF_FILE" ]]; then
        BACKEND_LINE=$(grep -E "proxy_pass https?://127.0.0.1:[0-9]+" "$CONF_FILE")
        if [[ "$BACKEND_LINE" =~ 127.0.0.1:([0-9]+) ]]; then
            PORT="${BASH_REMATCH[1]}"
            echo "🔍 检测到该域名绑定了本地服务端口：$PORT，正在深度清理相关静态服务文件..."
            rm -f "${AVAILABLE_DIR}/local_static_${PORT}.conf"
            rm -f "${ENABLED_DIR}/local_static_${PORT}.conf"
            LOCAL_SERVICE_DELETED=true
        fi
    fi

    rm -f "${ENABLED_DIR}/${SUBDOMAIN}.conf"
    rm -f "${ENABLED_DIR}/${SUBDOMAIN}_redirect.conf"
    rm -f "${AVAILABLE_DIR}/${SUBDOMAIN}.conf"
    rm -f "${AVAILABLE_DIR}/${SUBDOMAIN}_redirect.conf"

    # 【修复3】替换掉可能发生误删的高风险 find -delete，改用安全的手动检查逻辑
    safe_clear_broken_links

    if nginx -t &>/dev/null; then
        systemctl reload nginx
        echo "🗑️ 本地配置与软链接已完全深度清除：${SUBDOMAIN}"
        [[ "$LOCAL_SERVICE_DELETED" == true ]] && echo "✅ 同步深度清理了本地静态服务：local_static_${PORT}.conf"
    else
        echo "⚠️ 配置文件已删，但 Nginx 存在其他冲突组件，请运行 nginx -t 检查"
    fi
}

# ========== 批量推送 (Cloudflare) ==========
function batch_add() {
    read -p "请输入批量配置文件路径（格式: 子域名 IP）: " FILE
    [[ ! -f "$FILE" ]] && echo "❌ 文件不存在" && return

    read -p "是否启用 Cloudflare CDN（橙色云）？[y/N]: " PROXY_CHOICE
    [[ "$PROXY_CHOICE" == "y" || "$PROXY_CHOICE" == "Y" ]] && PROXIED=true || PROXIED=false

    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        SUBDOMAIN=$(echo "$line" | awk '{print $1}')
        IP=$(echo "$line" | awk '{print $2}')
        [[ -z "$SUBDOMAIN" || -z "$IP" ]] && continue
        echo "➡️ 推送 $SUBDOMAIN -> $IP 到 Cloudflare"
        sync_to_cloudflare "$SUBDOMAIN" "$IP" "$PROXIED"
    done < "$FILE"

    echo "✅ 批量 DNS 推送完成"
}

# ========== 启用应用 ==========
function enable_site() {
    read -p "输入要启用的域名 : " DOMAIN
    if [[ -f "${AVAILABLE_DIR}/${DOMAIN}.conf" ]]; then
        ln -sf "${AVAILABLE_DIR}/${DOMAIN}.conf" "${ENABLED_DIR}/${DOMAIN}.conf"
        [[ -f "${AVAILABLE_DIR}/${DOMAIN}_redirect.conf" ]] && \
        ln -sf "${AVAILABLE_DIR}/${DOMAIN}_redirect.conf" "${ENABLED_DIR}/${DOMAIN}_redirect.conf"
        
        if nginx -t &>/dev/null; then
            systemctl reload nginx && echo "✅ 已成功启用：$DOMAIN"
        else
            echo "❌ 启用失败，Nginx 语法检测未通过，请检查组件依赖。"
        fi
    else
        echo "❌ 未找到该域名的配置文件：${DOMAIN}.conf"
    fi
}

# ========== 禁用应用 ==========
function disable_site() {
    read -p "输入要禁用的域名 : " DOMAIN
    rm -f "${ENABLED_DIR}/${DOMAIN}.conf" "${ENABLED_DIR}/${DOMAIN}_redirect.conf"
    
    # 【修复3】安全清除可能产生的死链
    safe_clear_broken_links
    
    if nginx -t &>/dev/null; then
        systemctl reload nginx && echo "✅ 已安全禁用（断开软链）：$DOMAIN"
    else
        echo "⚠️ 软链已断开，但 Nginx 整体配置仍存在潜在错误，请留意。"
    fi
}

# ========== 列出应用 ==========
function list_domains() {
    echo "📄 当前已启用的域名列表："
    local count=0
    for file in "$ENABLED_DIR"/*.conf; do
        [[ -f "$file" ]] || continue
        if [[ "$(basename "$file")" =~ ^local_static_ ]]; then
            continue
        fi
        domain=$(basename "$file" .conf)
        if [[ "$domain" =~ _redirect$ ]]; then
            continue
        fi
        echo "  - $domain"
        ((count++))
    done
    [[ $count -eq 0 ]] && echo "  (暂无启用的域名)"
}

# ========== 主菜单 ==========
while true; do
    echo -e "\n====== Nginx 子域名  ======"
    echo "1. 添加域名 ”
    echo "2. 批量添加子域名到 Cloudflare”
    echo "3. 删除域名 "
    echo "4. 启用已配置但未启用的域名"
    echo "5. 禁用正在启用的域名"
    echo "6. 列出已启用域名"
    echo "0. 退出"
    echo "==========================================="
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
