#!/bin/bash

# =============================================================================
# Nginx 子域名管理
# =============================================================================

# ========== 统一目录变量（避免硬编码） ==========
NGINX_DIR="/etc/nginx"
AVAILABLE_DIR="${NGINX_DIR}/sites-available"
ENABLED_DIR="${NGINX_DIR}/sites-enabled"
SSL_DIR="/etc/ssl"
CONFIG_FILE="${NGINX_DIR}/.ssl_config"
ROOT_CA_URL="https://developers.cloudflare.com/ssl/static/origin_ca_ecc_root.pem"

# ========== 统一彩色日志输出 ==========
COLOR_RESET="\033[0m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_RED="\033[31m"
COLOR_BLUE="\033[36m"

# 普通信息
function log_info() {
    echo -e "${COLOR_BLUE}ℹ️  $*${COLOR_RESET}"
}

# 成功信息
function log_ok() {
    echo -e "${COLOR_GREEN}✅ $*${COLOR_RESET}"
}

# 警告信息
function log_warn() {
    echo -e "${COLOR_YELLOW}⚠️  $*${COLOR_RESET}"
}

# 错误信息
function log_error() {
    echo -e "${COLOR_RED}❌ $*${COLOR_RESET}"
}

# ========== 安全与校验相关公共函数 ==========

# 去掉字符串首尾空格
function trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    echo "$s"
}

# 校验域名格式是否合法（仅提示，不阻断，避免破坏原有兼容性）
function validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

# 校验 IP 地址格式，第二个参数指定版本 4 或 6，默认 4
function validate_ip() {
    local ip="$1"
    local version="${2:-4}"

    if [[ "$version" == "4" ]]; then
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
        local IFS='.'
        local octet
        for octet in $ip; do
            (( octet >= 0 && octet <= 255 )) || return 1
        done
        return 0
    else
        [[ "$ip" == *:* ]] && [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] && return 0
        return 1
    fi
}

# 校验端口范围 1~65535
function validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

# ========== 基础环境函数 ==========

# 统一加载 /etc/variable 环境变量并校验 Cloudflare 必需变量
function load_env() {
    if [[ -f /etc/variable ]]; then
        set -a
        source /etc/variable
        set +a
    else
        log_error "无法找到 /etc/variable 文件，请确保它存在并包含 Cloudflare 相关变量"
        exit 1
    fi

    if [[ -z "$CF_API_TOKEN" || -z "$CF_ZONE_ID" ]]; then
        log_error "Cloudflare 环境变量未设置（CF_API_TOKEN 或 CF_ZONE_ID 缺失）"
        exit 1
    fi
}

# 检测是否以 root 身份运行，非 root 直接退出
function check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "请使用 root 身份运行本脚本。"
        exit 1
    fi
}

# 统一检测依赖工具，缺失立即退出
function check_dependencies() {
    local cmd
    for cmd in curl jq nginx ss; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "系统未安装必要工具 '${cmd}'，请先安装 (例如: apt install ${cmd})"
            exit 1
        fi
    done
}

# 统一 Nginx 检测+重载：失败直接输出 nginx -t 错误，不静默；reload 失败同样输出错误，不默认成功
function reload_nginx() {
    local test_output
    if ! test_output=$(nginx -t 2>&1); then
        log_error "Nginx 配置检查失败："
        echo "$test_output"
        return 1
    fi

    local reload_output
    if ! reload_output=$(systemctl reload nginx 2>&1); then
        log_error "Nginx reload 失败："
        echo "$reload_output"
        return 1
    fi

    log_ok "Nginx 已重新加载"
    return 0
}

# 依次尝试多个来源获取公网 IPv4，并校验格式
function get_public_ipv4() {
    local url ip
    for url in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip"; do
        ip=$(curl -4 -f -s -S -L --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]')
        if validate_ip "$ip" "4"; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 依次尝试多个来源获取公网 IPv6，并校验格式
function get_public_ipv6() {
    local url ip
    for url in "https://api64.ipify.org" "https://ifconfig.me/ip"; do
        ip=$(curl -6 -f -s -S -L --max-time 3 "$url" 2>/dev/null | tr -d '[:space:]')
        if validate_ip "$ip" "6"; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 检测 nginx 是否编译了 http_v3_module（QUIC/HTTP3 支持）
function detect_http3() {
    if nginx -V 2>&1 | grep -qw "http_v3_module"; then
        echo "true"
    else
        echo "false"
    fi
}

# 检测 Nginx 版本以兼容新的 HTTP/2 语法（保留原有兼容逻辑，不删除）
function detect_http2() {
    local ver main sub
    ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    main=$(echo "$ver" | cut -d. -f1)
    sub=$(echo "$ver" | cut -d. -f2)
    if [[ "$main" -gt 1 ]] || { [[ "$main" -eq 1 ]] && [[ "$sub" -ge 25 ]]; }; then
        echo "true"
    else
        echo "false"
    fi
}

# 优先读取 /etc/resolv.conf 中的 nameserver，若为空则回退默认值
function detect_resolver() {
    local servers=()
    local line
    if [[ -f /etc/resolv.conf ]]; then
        while read -r line; do
            if [[ "$line" =~ ^nameserver[[:space:]]+([0-9A-Fa-f:.]+) ]]; then
                servers+=("${BASH_REMATCH[1]}")
            fi
        done < /etc/resolv.conf
    fi
    if [[ ${#servers[@]} -eq 0 ]]; then
        servers=("1.1.1.1" "8.8.8.8")
    fi
    echo "${servers[*]}"
}

# ========== Cloudflare API 统一封装 ==========

# 统一发起 Cloudflare API 请求：method endpoint [data]
function cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    local url="https://api.cloudflare.com/client/v4${endpoint}"

    if [[ -n "$data" ]]; then
        curl --fail --silent --show-error -X "$method" "$url" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "$data"
    else
        curl --fail --silent --show-error -X "$method" "$url" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json"
    fi
}

# ========== 证书配置（路径仍询问，缺失即终止；根证书可选+自动下载） ==========
function setup_ssl_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log_ok "已加载证书配置："
        echo "CERT_PATH=$CERT_PATH"
        echo "KEY_PATH=$KEY_PATH"
        if [[ -n "$TRUSTED_CERT" ]]; then
            echo "TRUSTED_CERT=$TRUSTED_CERT（已启用 OCSP Stapling）"
        else
            echo "TRUSTED_CERT=（未启用 OCSP Stapling）"
        fi

        # 缓存加载后仍需确认证书/私钥物理文件还在，防止路径失效导致后续启用域名时才报错
        if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
            log_error "证书或私钥文件缺失！"
            echo "   CERT_PATH=$CERT_PATH  存在: $( [[ -f "$CERT_PATH" ]] && echo 是 || echo 否 )"
            echo "   KEY_PATH=$KEY_PATH   存在: $( [[ -f "$KEY_PATH" ]] && echo 是 || echo 否 )"
            log_error "请将证书/私钥放置到上述路径后重新运行脚本，或删除 $CONFIG_FILE 重新配置路径。"
            exit 1
        fi
    else
        read -p "请输入证书路径（默认 ${SSL_DIR}/certs/eyes.pem）: " CERT_PATH
        CERT_PATH=${CERT_PATH:-${SSL_DIR}/certs/eyes.pem}

        read -p "请输入私钥路径（默认 ${SSL_DIR}/private/eyes.key）: " KEY_PATH
        KEY_PATH=${KEY_PATH:-${SSL_DIR}/private/eyes.key}

        # 首次配置时，证书/私钥必须已经真实存在，否则直接停止，不允许继续往下走
        if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
            log_error "检测到证书或私钥文件不存在！"
            echo "   CERT_PATH=$CERT_PATH  存在: $( [[ -f "$CERT_PATH" ]] && echo 是 || echo 否 )"
            echo "   KEY_PATH=$KEY_PATH   存在: $( [[ -f "$KEY_PATH" ]] && echo 是 || echo 否 )"
            log_error "请先将证书和私钥文件放置到以上路径，再重新运行本脚本。"
            exit 1
        fi

        read -p "是否启用 OCSP Stapling（需要 CA 根证书，仅公网信任证书 + 不经过 CDN 代理时才有意义）？[y/N]: " ENABLE_STAPLING
        if [[ "$ENABLE_STAPLING" == "y" || "$ENABLE_STAPLING" == "Y" ]]; then
            read -p "请输入根证书路径（默认 ${SSL_DIR}/certs/origin_ca_ecc_root.pem）: " TRUSTED_CERT
            TRUSTED_CERT=${TRUSTED_CERT:-${SSL_DIR}/certs/origin_ca_ecc_root.pem}

            if [[ -f "$TRUSTED_CERT" ]]; then
                log_ok "检测到根证书已存在，直接使用：$TRUSTED_CERT"
            else
                log_info "根证书不存在，正在从官方地址自动下载..."
                mkdir -p -- "$(dirname "$TRUSTED_CERT")"
                if curl -fsSL "$ROOT_CA_URL" -o "$TRUSTED_CERT"; then
                    chmod 644 "$TRUSTED_CERT"
                    log_ok "根证书下载完成：$TRUSTED_CERT"
                else
                    log_error "根证书下载失败（可能无网络出口），本次将跳过 OCSP Stapling。"
                    TRUSTED_CERT=""
                fi
            fi
        else
            TRUSTED_CERT=""
            log_warn "已跳过 OCSP Stapling 配置"
        fi

        echo "CERT_PATH=\"$CERT_PATH\"" > "$CONFIG_FILE"
        echo "KEY_PATH=\"$KEY_PATH\"" >> "$CONFIG_FILE"
        echo "TRUSTED_CERT=\"$TRUSTED_CERT\"" >> "$CONFIG_FILE"
        log_ok "证书路径已保存到 $CONFIG_FILE"
    fi
}

# ========== 安全安全的死链清理函数 ==========
function safe_clear_broken_links() {
    # 逐个检查 sites-enabled 下的软链接，确保绝不误删
    local link
    for link in "$ENABLED_DIR"/*.conf; do
        if [[ -L "$link" ]]; then
            # 如果是软链接，但指向的目标文件不存在，则是死链，安全删除
            if [[ ! -e "$link" ]]; then
                rm -f -- "$link"
            fi
        fi
    done
}

# ========== 修改 OCSP Stapling 配置（单独调整，不影响证书/私钥路径，也不回溯已存在的域名） ==========
function modify_stapling() {
    source "$CONFIG_FILE" 2>/dev/null

    echo "当前 CERT_PATH=$CERT_PATH"
    echo "当前 KEY_PATH=$KEY_PATH"
    if [[ -n "$TRUSTED_CERT" ]]; then
        echo "当前状态：已启用 OCSP Stapling（TRUSTED_CERT=$TRUSTED_CERT）"
    else
        echo "当前状态：未启用 OCSP Stapling"
    fi

    read -p "是否启用 OCSP Stapling？[y/N]: " ENABLE_STAPLING
    if [[ "$ENABLE_STAPLING" == "y" || "$ENABLE_STAPLING" == "Y" ]]; then
        read -p "请输入根证书路径（默认 ${SSL_DIR}/certs/origin_ca_ecc_root.pem）: " NEW_TRUSTED_CERT
        NEW_TRUSTED_CERT=${NEW_TRUSTED_CERT:-${SSL_DIR}/certs/origin_ca_ecc_root.pem}

        if [[ -f "$NEW_TRUSTED_CERT" ]]; then
            log_ok "检测到根证书已存在，直接使用：$NEW_TRUSTED_CERT"
        else
            log_info "根证书不存在，正在自动下载..."
            mkdir -p -- "$(dirname "$NEW_TRUSTED_CERT")"
            if curl -fsSL "$ROOT_CA_URL" -o "$NEW_TRUSTED_CERT"; then
                chmod 644 "$NEW_TRUSTED_CERT"
                log_ok "下载完成：$NEW_TRUSTED_CERT"
            else
                log_error "下载失败，未启用。"
                NEW_TRUSTED_CERT=""
            fi
        fi
        TRUSTED_CERT="$NEW_TRUSTED_CERT"
    else
        TRUSTED_CERT=""
        log_warn "已关闭 OCSP Stapling"
    fi

    # 重写配置文件（保留 CERT_PATH/KEY_PATH，只更新 TRUSTED_CERT）
    echo "CERT_PATH=\"$CERT_PATH\"" > "$CONFIG_FILE"
    echo "KEY_PATH=\"$KEY_PATH\"" >> "$CONFIG_FILE"
    echo "TRUSTED_CERT=\"$TRUSTED_CERT\"" >> "$CONFIG_FILE"
    log_ok "配置已更新到 $CONFIG_FILE"
    log_warn "注意：此项修改只影响【之后新增】的域名配置，已存在的域名配置不受影响。"
}

# ========== Cloudflare 同步（统一 cf_api 封装，PATCH 替代 PUT，支持 A / AAAA） ==========
# 参数：domain ip proxied [record_type，默认 A]
function sync_to_cloudflare() {
    local domain="$1"
    local ip="$2"
    local proxied="$3"
    local rtype="${4:-A}"

    log_info "正在同步 ${domain} (${rtype}) 到 Cloudflare..."

    local query_result record_id payload response success errors
    query_result=$(cf_api "GET" "/zones/${CF_ZONE_ID}/dns_records?type=${rtype}&name=${domain}")
    record_id=$(echo "$query_result" | jq -r '.result[0].id // empty')

    payload=$(jq -n --arg type "$rtype" --arg name "$domain" --arg content "$ip" \
        --argjson ttl 120 --argjson proxied "$proxied" \
        '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')

    if [[ -z "$record_id" ]]; then
        response=$(cf_api "POST" "/zones/${CF_ZONE_ID}/dns_records" "$payload")
    else
        response=$(cf_api "PATCH" "/zones/${CF_ZONE_ID}/dns_records/${record_id}" "$payload")
    fi

    success=$(echo "$response" | jq -r '.success')
    if [[ "$success" == "true" ]]; then
        log_ok "${domain} (${rtype}) 同步成功"
    else
        errors=$(echo "$response" | jq -c '.errors')
        log_error "${domain} (${rtype}) 同步失败: ${errors}"
    fi
}

# ========== 添加域名 ==========
function add_domain() {
    local SUBDOMAIN BACKEND USE_HTTPS_BACKEND BACKEND_SCHEME EMBY_OPT PROXY_CHOICE PROXIED
    local SYNC_CHOICE SERVER_IPV4 SERVER_IPV6 IP PORT ENABLE_CHOICE
    local CONF_PATH EXTRA_PROXY_SSL EXTRA_PROXY_OPT STAPLING_BLOCK LISTEN_LINE HTTP3_BLOCK RESOLVER_LIST
    local LOCAL_STATIC_CONF

    read -p "请输入域名 : " SUBDOMAIN
    SUBDOMAIN=$(trim "$SUBDOMAIN")
    if [[ -z "$SUBDOMAIN" ]]; then
        log_error "域名不能为空"
        return 1
    fi
    if ! validate_domain "$SUBDOMAIN"; then
        log_warn "域名格式看起来不太规范，请确认无误（不会阻断流程）"
    fi

    read -p "请输入后端地址 (域名或IP:端口，例如 127.0.0.1:8080) : " BACKEND
    BACKEND=$(trim "$BACKEND")
    if [[ ! "$BACKEND" =~ ^[a-zA-Z0-9.-]+:[0-9]+$ ]]; then
        log_error "格式不正确，应为 域名或IP:端口"
        return 1
    fi

    IP=$(echo "$BACKEND" | cut -d':' -f1)
    PORT=$(echo "$BACKEND" | cut -d':' -f2)
    if ! validate_port "$PORT"; then
        log_error "端口号不合法：${PORT}（应为 1-65535）"
        return 1
    fi

    read -p "后端是否为 HTTPS 服务？ [y/N]: " USE_HTTPS_BACKEND
    [[ "$USE_HTTPS_BACKEND" == "y" || "$USE_HTTPS_BACKEND" == "Y" ]] && BACKEND_SCHEME="https" || BACKEND_SCHEME="http"

    read -p "是否为 Emby 站点，需要启用视频流优化？ [y/N]: " EMBY_OPT
    read -p "是否启用 Cloudflare CDN？[y/N]: " PROXY_CHOICE
    [[ "$PROXY_CHOICE" == "y" || "$PROXY_CHOICE" == "Y" ]] && PROXIED=true || PROXIED=false

    read -p "请选择要同步的 DNS 记录类型 [1] 仅 IPv4(A)  [2] 仅 IPv6(AAAA)  [3] 同时同步(A+AAAA)（默认 1）: " SYNC_CHOICE
    SYNC_CHOICE=${SYNC_CHOICE:-1}

    SERVER_IPV4=""
    SERVER_IPV6=""

    if [[ "$SYNC_CHOICE" == "1" || "$SYNC_CHOICE" == "3" ]]; then
        SERVER_IPV4=$(get_public_ipv4)
        if [[ -z "$SERVER_IPV4" ]]; then
            log_error "无法获取服务器 IPv4 公网地址"
            [[ "$SYNC_CHOICE" == "1" ]] && return 1
        fi
    fi

    if [[ "$SYNC_CHOICE" == "2" || "$SYNC_CHOICE" == "3" ]]; then
        SERVER_IPV6=$(get_public_ipv6)
        if [[ -z "$SERVER_IPV6" ]]; then
            log_warn "未检测到服务器 IPv6 公网地址，自动跳过 AAAA 同步"
        fi
    fi

    if [[ -z "$SERVER_IPV4" && -z "$SERVER_IPV6" ]]; then
        log_error "未能获取任何可用公网 IP，中断 Cloudflare 同步"
        return 1
    fi

    if [[ "$IP" == "127.0.0.1" ]]; then
        if ss -tuln | grep -q ":${PORT} "; then
            log_info "检测到本地端口 ${PORT} 已经有其他服务在运行，跳过自建本地静态服务。"
        else
            LOCAL_STATIC_CONF="${AVAILABLE_DIR}/local_static_${PORT}.conf"
            if [[ ! -f "$LOCAL_STATIC_CONF" ]]; then
                log_info "正在自动托管本地静态目录服务（监听 127.0.0.1:${PORT}）..."
                mkdir -p -- /srv
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
                ln -sf -- "$LOCAL_STATIC_CONF" "${ENABLED_DIR}/local_static_${PORT}.conf"
                log_ok "已拉起并启用本地基础静态服务 (127.0.0.1:${PORT})"
            fi
        fi
    fi

    CONF_PATH="${AVAILABLE_DIR}/${SUBDOMAIN}.conf"

    EXTRA_PROXY_SSL=""
    if [[ "$BACKEND_SCHEME" == "https" ]]; then
        EXTRA_PROXY_SSL=$(cat <<'EOT'
        proxy_ssl_server_name on;
        proxy_ssl_verify off;
EOT
)
    fi

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

    # 根据当前 TRUSTED_CERT 是否启用，动态生成 OCSP Stapling 配置块（未启用则为空，不写入这三行）
    STAPLING_BLOCK=""
    if [[ -n "$TRUSTED_CERT" && -f "$TRUSTED_CERT" ]]; then
        STAPLING_BLOCK=$(cat <<EOT
    ssl_trusted_certificate $TRUSTED_CERT;
    ssl_stapling on;
    ssl_stapling_verify on;
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

    # 新增：HTTP/3（QUIC）支持，仅当 nginx -V 检测到 http_v3_module 时生效，不影响旧版本 nginx
    HTTP3_BLOCK=""
    if [[ "$(detect_http3)" == "true" ]]; then
        HTTP3_BLOCK=$(cat <<'EOT'
    listen 443 quic reuseport;
    http3 on;
    add_header Alt-Svc 'h3=":443"; ma=86400' always;
EOT
)
    fi

    # 【修复2】引入 Resolver 保证动态/域名型 proxy_pass 能够正常解析（新增：自动读取 /etc/resolv.conf）
    RESOLVER_LIST=$(detect_resolver)

    cat > "$CONF_PATH" <<EOF
server {
$LISTEN_LINE
$HTTP3_BLOCK
    server_name ${SUBDOMAIN};

    client_max_body_size 100m;

    resolver ${RESOLVER_LIST} valid=300s;
    resolver_timeout 5s;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
$STAPLING_BLOCK

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

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

    log_ok "已生成主配置文件：${CONF_PATH}"

    read -p "是否现在启用该域名？[y/N]: " ENABLE_CHOICE
    if [[ "$ENABLE_CHOICE" == "y" || "$ENABLE_CHOICE" == "Y" ]]; then
        ln -sf -- "$CONF_PATH" "${ENABLED_DIR}/${SUBDOMAIN}.conf"
        ln -sf -- "${AVAILABLE_DIR}/${SUBDOMAIN}_redirect.conf" "${ENABLED_DIR}/${SUBDOMAIN}_redirect.conf"
        if reload_nginx; then
            log_ok "已启用：${SUBDOMAIN}"
        fi
    else
        log_warn "已跳过本地启用，可稍后在菜单中手动启用"
    fi

    if [[ -n "$SERVER_IPV4" ]]; then
        sync_to_cloudflare "$SUBDOMAIN" "$SERVER_IPV4" "$PROXIED" "A"
    fi
    if [[ -n "$SERVER_IPV6" ]]; then
        sync_to_cloudflare "$SUBDOMAIN" "$SERVER_IPV6" "$PROXIED" "AAAA"
    fi
}

# ========== 删除域名 ==========
function delete_domain() {
    local SUBDOMAIN CONF_FILE LOCAL_SERVICE_DELETED BACKEND_LINE PORT
    read -p "请输入要删除的域名 : " SUBDOMAIN
    SUBDOMAIN=$(trim "$SUBDOMAIN")
    if [[ -z "$SUBDOMAIN" ]]; then
        log_error "域名不能为空"
        return 1
    fi

    CONF_FILE="${AVAILABLE_DIR}/${SUBDOMAIN}.conf"
    LOCAL_SERVICE_DELETED=false

    if [[ -f "$CONF_FILE" ]]; then
        BACKEND_LINE=$(grep -E "proxy_pass https?://127.0.0.1:[0-9]+" "$CONF_FILE")
        if [[ "$BACKEND_LINE" =~ 127.0.0.1:([0-9]+) ]]; then
            PORT="${BASH_REMATCH[1]}"
            log_info "检测到该域名绑定了本地服务端口：$PORT，正在深度清理相关静态服务文件..."
            rm -f -- "${AVAILABLE_DIR}/local_static_${PORT}.conf"
            rm -f -- "${ENABLED_DIR}/local_static_${PORT}.conf"
            LOCAL_SERVICE_DELETED=true
        fi
    fi

    rm -f -- "${ENABLED_DIR}/${SUBDOMAIN}.conf"
    rm -f -- "${ENABLED_DIR}/${SUBDOMAIN}_redirect.conf"
    rm -f -- "${AVAILABLE_DIR}/${SUBDOMAIN}.conf"
    rm -f -- "${AVAILABLE_DIR}/${SUBDOMAIN}_redirect.conf"

    # 【修复3】替换掉可能发生误删的高风险 find -delete，改用安全的手动检查逻辑
    safe_clear_broken_links

    if reload_nginx; then
        log_ok "本地配置与软链接已完全深度清除：${SUBDOMAIN}"
        [[ "$LOCAL_SERVICE_DELETED" == true ]] && log_ok "同步深度清理了本地静态服务：local_static_${PORT}.conf"
    else
        log_warn "配置文件已删，但 Nginx 存在其他冲突组件，请运行 nginx -t 检查"
    fi
}

# ========== 批量推送 (Cloudflare) ==========
# 兼容旧格式：子域名 IP
# 新增支持：子域名 IP proxied（第三列缺省则沿用交互式全局选择）
# 新增支持：IPv4/IPv6 自动识别，分别写入 A / AAAA 记录
function batch_add() {
    local FILE PROXY_CHOICE DEFAULT_PROXIED
    local line sub ip proxied_field proxied rtype

    read -p "请输入批量配置文件路径（格式: 子域名 IP [proxied]）: " FILE
    FILE=$(trim "$FILE")
    if [[ ! -f "$FILE" ]]; then
        log_error "文件不存在"
        return
    fi

    read -p "是否启用 Cloudflare CDN（橙色云，用于未在文件中指定第三列的行）？[y/N]: " PROXY_CHOICE
    [[ "$PROXY_CHOICE" == "y" || "$PROXY_CHOICE" == "Y" ]] && DEFAULT_PROXIED=true || DEFAULT_PROXIED=false

    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        sub=$(echo "$line" | awk '{print $1}')
        ip=$(echo "$line" | awk '{print $2}')
        proxied_field=$(echo "$line" | awk '{print $3}')
        [[ -z "$sub" || -z "$ip" ]] && continue

        if [[ -n "$proxied_field" ]]; then
            [[ "$proxied_field" == "true" || "$proxied_field" == "True" ]] && proxied=true || proxied=false
        else
            proxied=$DEFAULT_PROXIED
        fi

        if validate_ip "$ip" "4"; then
            rtype="A"
        elif validate_ip "$ip" "6"; then
            rtype="AAAA"
        else
            log_warn "跳过无效 IP：${sub} ${ip}"
            continue
        fi

        log_info "➡️ 推送 ${sub} -> ${ip} (${rtype}) 到 Cloudflare"
        sync_to_cloudflare "$sub" "$ip" "$proxied" "$rtype"
    done < "$FILE"

    log_ok "批量 DNS 推送完成"
}

# ========== 启用应用 ==========
function enable_site() {
    local DOMAIN
    read -p "输入要启用的域名 : " DOMAIN
    DOMAIN=$(trim "$DOMAIN")
    if [[ -f "${AVAILABLE_DIR}/${DOMAIN}.conf" ]]; then
        ln -sf -- "${AVAILABLE_DIR}/${DOMAIN}.conf" "${ENABLED_DIR}/${DOMAIN}.conf"
        [[ -f "${AVAILABLE_DIR}/${DOMAIN}_redirect.conf" ]] && \
        ln -sf -- "${AVAILABLE_DIR}/${DOMAIN}_redirect.conf" "${ENABLED_DIR}/${DOMAIN}_redirect.conf"

        if reload_nginx; then
            log_ok "已成功启用：$DOMAIN"
        else
            log_error "启用失败，Nginx 语法检测未通过，请检查组件依赖。"
        fi
    else
        log_error "未找到该域名的配置文件：${DOMAIN}.conf"
    fi
}

# ========== 禁用应用 ==========
function disable_site() {
    local DOMAIN
    read -p "输入要禁用的域名 : " DOMAIN
    DOMAIN=$(trim "$DOMAIN")
    rm -f -- "${ENABLED_DIR}/${DOMAIN}.conf" "${ENABLED_DIR}/${DOMAIN}_redirect.conf"

    # 【修复3】安全清除可能产生的死链
    safe_clear_broken_links

    if reload_nginx; then
        log_ok "已安全禁用（断开软链）：$DOMAIN"
    else
        log_warn "软链已断开，但 Nginx 整体配置仍存在潜在错误，请留意。"
    fi
}

# ========== 列出应用 ==========
function list_domains() {
    echo "📄 当前已启用的域名列表："
    local count=0
    local file domain
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

# =============================================================================
# 主流程初始化：Root 权限检测、依赖检查、环境变量加载、证书配置、HTTP2 兼容性检测
# =============================================================================
check_root
check_dependencies
load_env
setup_ssl_config
USE_NEW_HTTP2=$(detect_http2)

# ========== 主菜单 ==========
while true; do
    echo -e "\n====== Nginx 子域名管理 ======"
    echo "1. 添加域名"
    echo "2. 批量添加子域名到"
    echo "3. 删除域名"
    echo "4. 启用已配置但未启用的域名"
    echo "5. 禁用正在启用的域名"
    echo "6. 列出已启用域名"
    echo "7. 修改证书 / OCSP Stapling 配置"
    echo "0. 退出"
    echo "==========================================="
    read -p "请选择操作 [0-7]: " CHOICE

    case $CHOICE in
        1) add_domain ;;
        2) batch_add ;;
        3) delete_domain ;;
        4) enable_site ;;
        5) disable_site ;;
        6) list_domains ;;
        7) modify_stapling ;;
        0) exit 0 ;;
        *) echo "❌ 无效选择，请重新输入。" ;;
    esac
done
