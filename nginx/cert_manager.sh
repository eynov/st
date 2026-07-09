#!/bin/bash

# =============================================================================
# 证书管理模块 (cert_manager.sh)
# 与 nginx-manager.sh 配套使用：
#   nginx-manager.sh  负责 管理域名 / 生成 Nginx 配置 / 引用证书
#   cert_manager.sh   负责 Let's Encrypt / Cloudflare Origin CA 证书的
#                      申请、查看、续期、更新 Nginx 引用、reload Nginx
#
# 两者通过同一份证书路径配置文件 /etc/nginx/.ssl_config 交互：
#   CERT_PATH / KEY_PATH / TRUSTED_CERT
# nginx-manager.sh 在“添加域名”时读取该文件把路径写死进每个域名的 conf；
# 因此本脚本更新证书后，除了更新该配置文件本身（影响之后新增的域名），
# 还会同步改写 sites-available 下已存在域名的 conf 文件（影响已存在的域名）。
# =============================================================================

# ========== 统一目录变量（避免硬编码，与 nginx-manager.sh 保持一致） ==========
NGINX_DIR="/etc/nginx"
AVAILABLE_DIR="${NGINX_DIR}/sites-available"
ENABLED_DIR="${NGINX_DIR}/sites-enabled"
SSL_DIR="/etc/ssl"
CONFIG_FILE="${NGINX_DIR}/.ssl_config"

LE_DIR="/etc/letsencrypt"
LE_LIVE_DIR="${LE_DIR}/live"
LE_HOOK_DIR="${LE_DIR}/renewal-hooks/deploy"
LE_HOOK_SCRIPT="${LE_HOOK_DIR}/cert_manager_sync.sh"
CF_CREDENTIALS_FILE="${NGINX_DIR}/.cf_dns_credentials.ini"

CF_ORIGIN_DIR="${SSL_DIR}/cloudflare-origin"
CERT_META_FILE="${NGINX_DIR}/.cert_manager_meta"

SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# ========== 统一彩色日志输出（与 nginx-manager.sh 保持一致风格） ==========
COLOR_RESET="\033[0m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_RED="\033[31m"
COLOR_BLUE="\033[36m"

function log_info() { echo -e "${COLOR_BLUE}ℹ️  $*${COLOR_RESET}"; }
function log_ok()   { echo -e "${COLOR_GREEN}✅ $*${COLOR_RESET}"; }
function log_warn() { echo -e "${COLOR_YELLOW}⚠️  $*${COLOR_RESET}"; }
function log_error(){ echo -e "${COLOR_RED}❌ $*${COLOR_RESET}"; }

# ========== 公共小工具 ==========
function trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    echo "$s"
}

function validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

function check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "请使用 root 身份运行本脚本。"
        exit 1
    fi
}

# 依赖检测：本模块必需的基础工具（certbot 单独检测，只有用 Let's Encrypt 时才强制要求）
function check_dependencies() {
    local cmd
    for cmd in curl jq openssl nginx sed; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "系统未安装必要工具 '${cmd}'，请先安装 (例如: apt install ${cmd})"
            exit 1
        fi
    done
}

# 统一加载 /etc/variable 环境变量（与 nginx-manager.sh 共用同一份变量文件）
function load_env() {
    if [[ -f /etc/variable ]]; then
        set -a
        if ! source /etc/variable 2>/dev/null; then
            set +a
            log_error "/etc/variable 文件损坏或无法加载，请检查后重试"
            exit 1
        fi
        set +a
    else
        log_error "无法找到 /etc/variable 文件，请确保它存在并包含 Cloudflare 相关变量"
        exit 1
    fi

    if [[ -z "$CF_API_TOKEN" ]]; then
        log_error "Cloudflare 环境变量未设置（CF_API_TOKEN 缺失）"
        exit 1
    fi
    # 说明：CF_ORIGIN_CA_KEY 仅在使用「Cloudflare Origin CA」签发时才强制要求，
    # 这里不做强制校验，避免影响只使用 Let's Encrypt 的用户。
}

# ========== 1. 检查 certbot ==========
function check_certbot() {
    if ! command -v certbot &> /dev/null; then
        log_error "未检测到 certbot，Let's Encrypt 证书签发/续期依赖 certbot"
        read -p "是否现在尝试自动安装 certbot 及 Cloudflare DNS 插件？[y/N]: " INSTALL_CERTBOT
        if [[ "$INSTALL_CERTBOT" == "y" || "$INSTALL_CERTBOT" == "Y" ]]; then
            if command -v apt &> /dev/null; then
                apt update && apt install -y certbot python3-certbot-dns-cloudflare
            else
                log_error "未检测到 apt，请手动安装 certbot 及 certbot-dns-cloudflare 插件后重试"
                return 1
            fi
        else
            return 1
        fi
    fi

    if ! command -v certbot &> /dev/null; then
        log_error "certbot 仍不可用，请手动安装后重试"
        return 1
    fi

    if ! certbot plugins 2>/dev/null | grep -qi "dns-cloudflare"; then
        log_warn "未检测到 certbot-dns-cloudflare 插件（申请泛域名证书必需）"
        read -p "是否现在尝试自动安装该插件？[y/N]: " INSTALL_PLUGIN
        if [[ "$INSTALL_PLUGIN" == "y" || "$INSTALL_PLUGIN" == "Y" ]]; then
            if command -v apt &> /dev/null; then
                apt update && apt install -y python3-certbot-dns-cloudflare
            else
                log_error "未检测到 apt，请手动安装 certbot-dns-cloudflare 插件后重试"
                return 1
            fi
        else
            log_error "缺少 dns-cloudflare 插件，无法申请泛域名证书"
            return 1
        fi
    fi

    log_ok "certbot 及 dns-cloudflare 插件检测通过"
    return 0
}

# ========== 统一 Nginx 检测+reload（与 nginx-manager.sh 中的健壮版本保持一致） ==========
function reload_nginx() {
    local test_output
    if ! test_output=$(nginx -t 2>&1); then
        log_error "Nginx 配置检查失败："
        echo "$test_output"
        return 1
    fi

    local reload_output
    if systemctl is-active --quiet nginx; then
        if ! reload_output=$(systemctl reload nginx 2>&1); then
            log_error "Nginx reload 失败："
            echo "$reload_output"
            return 1
        fi
    else
        log_warn "检测到 Nginx 当前未处于运行状态，将改为启动 Nginx"
        if ! reload_output=$(systemctl start nginx 2>&1); then
            log_error "Nginx start 失败："
            echo "$reload_output"
            return 1
        fi
    fi

    log_ok "Nginx 已重新加载"
    return 0
}

# ========== Cloudflare 通用 API 封装（用于 DNS-01 之外的场景，如 Origin CA） ==========
# 注意：Cloudflare Origin CA 接口使用专用的 X-Auth-User-Service-Key 鉴权，
# 与 nginx-manager.sh 里管理 DNS / 源规则所用的 Bearer Token（CF_API_TOKEN）是两套完全不同的凭证。
function cf_origin_ca_api() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    local url="https://api.cloudflare.com/client/v4${endpoint}"

    if [[ -z "$CF_ORIGIN_CA_KEY" ]]; then
        log_error "CF_ORIGIN_CA_KEY 未设置，请在 /etc/variable 中配置 Cloudflare Origin CA Key"
        return 1
    fi

    if [[ -n "$data" ]]; then
        curl --fail --silent --show-error --connect-timeout 5 --max-time 30 -X "$method" "$url" \
            -H "X-Auth-User-Service-Key: ${CF_ORIGIN_CA_KEY}" \
            -H "Content-Type: application/json" \
            --data "$data"
    else
        curl --fail --silent --show-error --connect-timeout 5 --max-time 30 -X "$method" "$url" \
            -H "X-Auth-User-Service-Key: ${CF_ORIGIN_CA_KEY}" \
            -H "Content-Type: application/json"
    fi
}

# ========== 记录证书元数据（类型/域名/路径/时间），便于「查看证书」统一展示 ==========
function record_cert_meta() {
    local ctype="$1"     # letsencrypt / origin_ca
    local domain="$2"
    local cert_path="$3"
    local key_path="$4"

    touch "$CERT_META_FILE"
    # 同一域名重复签发时先清掉旧记录，避免重复行
    sed -i "\|^${ctype}|${domain}|d" "$CERT_META_FILE" 2>/dev/null
    echo "${ctype}|${domain}|${cert_path}|${key_path}|$(date '+%Y-%m-%d %H:%M:%S')" >> "$CERT_META_FILE"
}

# ========== 将证书路径写入共享配置文件 $CONFIG_FILE（影响之后新增的域名） ==========
function write_shared_config() {
    local cert_path="$1"
    local key_path="$2"
    local trusted_cert="$3"

    echo "CERT_PATH=\"$cert_path\"" > "$CONFIG_FILE"
    echo "KEY_PATH=\"$key_path\"" >> "$CONFIG_FILE"
    echo "TRUSTED_CERT=\"$trusted_cert\"" >> "$CONFIG_FILE"
    log_ok "共享证书配置已更新：$CONFIG_FILE"
}

# ========== 同步改写已存在域名的 conf 文件（影响已经生成过的域名） ==========
# 说明：nginx-manager.sh 生成域名配置时，是把证书路径「字面量」写死进每个
# server 块（并非引用 nginx 变量），因此仅更新 $CONFIG_FILE 无法让已存在
# 的域名自动生效，必须对 sites-available 下现有 conf 文件做定向替换。
function sync_cert_paths_to_sites() {
    local new_cert="$1"
    local new_key="$2"
    local new_trusted="$3"   # 允许为空字符串（表示不启用 OCSP Stapling）
    local conf base

    [[ -d "$AVAILABLE_DIR" ]] || return 0

    for conf in "${AVAILABLE_DIR}"/*.conf; do
        [[ -f "$conf" ]] || continue
        base="$(basename "$conf")"
        # 跳过本地静态托管、80 端口跳转配置，这些文件里没有证书配置
        [[ "$base" == local_static_* ]] && continue
        [[ "$base" == *_redirect.conf ]] && continue
        grep -q "ssl_certificate " "$conf" || continue

        sed -i -E "s|^([[:space:]]*ssl_certificate )[^;]+;|\1${new_cert};|" "$conf"
        sed -i -E "s|^([[:space:]]*ssl_certificate_key )[^;]+;|\1${new_key};|" "$conf"

        if [[ -n "$new_trusted" ]]; then
            if grep -q "ssl_trusted_certificate " "$conf"; then
                sed -i -E "s|^([[:space:]]*ssl_trusted_certificate )[^;]+;|\1${new_trusted};|" "$conf"
            fi
            # 若该域名原本未启用 stapling，这里不做自动插入，避免破坏其原有结构，
            # 如需为老域名启用 stapling，建议通过 nginx-manager.sh 重新生成该域名配置。
        else
            sed -i "/^[[:space:]]*ssl_trusted_certificate /d;/^[[:space:]]*ssl_stapling on;$/d;/^[[:space:]]*ssl_stapling_verify on;$/d" "$conf"
        fi

        log_info "已同步证书路径到：$conf"
    done
}

# 组合动作：写共享配置 + 同步已存在域名 + reload nginx（供签发/续期/手动更新复用）
function push_cert_and_reload() {
    local cert_path="$1"
    local key_path="$2"
    local trusted_cert="$3"

    if [[ ! -f "$cert_path" || ! -f "$key_path" ]]; then
        log_error "证书或私钥文件不存在，已中止更新：$cert_path / $key_path"
        return 1
    fi

    write_shared_config "$cert_path" "$key_path" "$trusted_cert"
    sync_cert_paths_to_sites "$cert_path" "$key_path" "$trusted_cert"

    if reload_nginx; then
        log_ok "Nginx 证书引用已更新并重新加载完成"
    else
        log_warn "证书文件已更新，但 Nginx reload/检查未通过，请手动运行 nginx -t 排查"
        return 1
    fi
}

# =============================================================================
# 2. 申请证书：选项 1 Let's Encrypt（支持泛域名） / 选项 2 Cloudflare Origin CA
# =============================================================================
function issue_cert() {
    echo "请选择证书类型："
    echo "  1. Let's Encrypt（通过 Cloudflare DNS-01，支持泛域名 *.example.com）"
    echo "  2. Cloudflare Origin CA（仅在流量经过 Cloudflare 代理时可信，有效期最长 15 年）"
    read -p "请输入选项 [1-2]: " CERT_TYPE_CHOICE

    case "$CERT_TYPE_CHOICE" in
        1) issue_letsencrypt ;;
        2) issue_origin_ca ;;
        *) log_error "无效选项" ;;
    esac
}

function issue_letsencrypt() {
    local BASE_DOMAIN INCLUDE_WILDCARD EMAIL STAGING_CHOICE STAGING_FLAG
    local ENABLE_STAPLING TRUSTED_CERT_NEW DOMAIN_ARGS LINEAGE_DIR

    if ! check_certbot; then
        log_error "certbot 环境检测未通过，已中止 Let's Encrypt 证书签发"
        return 1
    fi

    read -p "请输入根域名（例如 example.com，将同时签发该域名及其泛域名）: " BASE_DOMAIN
    BASE_DOMAIN=$(trim "$BASE_DOMAIN")
    if [[ -z "$BASE_DOMAIN" ]]; then
        log_error "域名不能为空"
        return 1
    fi
    if ! validate_domain "$BASE_DOMAIN"; then
        log_warn "域名格式看起来不太规范，请确认无误（不会阻断流程）"
    fi

    read -p "是否同时包含泛域名 *.${BASE_DOMAIN}？[Y/n]: " INCLUDE_WILDCARD
    INCLUDE_WILDCARD=${INCLUDE_WILDCARD:-Y}

    read -p "请输入证书注册邮箱（用于到期提醒，留空则不注册邮箱）: " EMAIL
    EMAIL=$(trim "$EMAIL")

    read -p "是否使用 Let's Encrypt Staging 测试环境（避免频繁申请触发速率限制）？[y/N]: " STAGING_CHOICE
    if [[ "$STAGING_CHOICE" == "y" || "$STAGING_CHOICE" == "Y" ]]; then
        STAGING_FLAG="--staging"
        log_warn "已启用 Staging 测试环境，签发的证书不受浏览器信任，仅用于流程验证"
    else
        STAGING_FLAG=""
    fi

    # 生成/复用 Cloudflare DNS-01 凭据文件（仅本机 root 可读）
    umask 077
    echo "dns_cloudflare_api_token = ${CF_API_TOKEN}" > "$CF_CREDENTIALS_FILE"
    chmod 600 "$CF_CREDENTIALS_FILE"

    DOMAIN_ARGS=(-d "$BASE_DOMAIN")
    if [[ "$INCLUDE_WILDCARD" == "y" || "$INCLUDE_WILDCARD" == "Y" ]]; then
        DOMAIN_ARGS+=(-d "*.${BASE_DOMAIN}")
    fi

    log_info "正在通过 certbot + Cloudflare DNS-01 申请证书，请耐心等待 DNS 验证..."

    local CERTBOT_EMAIL_ARGS
    if [[ -n "$EMAIL" ]]; then
        CERTBOT_EMAIL_ARGS=(-m "$EMAIL")
    else
        CERTBOT_EMAIL_ARGS=(--register-unsafely-without-email)
    fi

    if ! certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials "$CF_CREDENTIALS_FILE" \
        --dns-cloudflare-propagation-seconds 30 \
        "${DOMAIN_ARGS[@]}" \
        --agree-tos \
        --non-interactive \
        $STAGING_FLAG \
        "${CERTBOT_EMAIL_ARGS[@]}"; then
        log_error "证书签发失败，请检查上方 certbot 输出日志"
        return 1
    fi

    LINEAGE_DIR="${LE_LIVE_DIR}/${BASE_DOMAIN}"
    if [[ ! -f "${LINEAGE_DIR}/fullchain.pem" || ! -f "${LINEAGE_DIR}/privkey.pem" ]]; then
        log_error "未在预期路径找到签发结果：${LINEAGE_DIR}"
        return 1
    fi

    log_ok "Let's Encrypt 证书签发成功，证书路径由 certbot 自动生成："
    echo "  CERT_PATH（证书）：${LINEAGE_DIR}/fullchain.pem"
    echo "  KEY_PATH（私钥）：${LINEAGE_DIR}/privkey.pem"

    read -p "是否启用 OCSP Stapling（使用 certbot 生成的 chain.pem）？[y/N]: " ENABLE_STAPLING
    if [[ "$ENABLE_STAPLING" == "y" || "$ENABLE_STAPLING" == "Y" ]]; then
        TRUSTED_CERT_NEW="${LINEAGE_DIR}/chain.pem"
    else
        TRUSTED_CERT_NEW=""
    fi

    record_cert_meta "letsencrypt" "$BASE_DOMAIN" "${LINEAGE_DIR}/fullchain.pem" "${LINEAGE_DIR}/privkey.pem"
    push_cert_and_reload "${LINEAGE_DIR}/fullchain.pem" "${LINEAGE_DIR}/privkey.pem" "$TRUSTED_CERT_NEW"

    read -p "是否现在配置自动续期（certbot 续期成功后自动更新 Nginx 并 reload）？[y/N]: " AUTO_RENEW_CHOICE
    if [[ "$AUTO_RENEW_CHOICE" == "y" || "$AUTO_RENEW_CHOICE" == "Y" ]]; then
        setup_auto_renew
    fi
}

function issue_origin_ca() {
    local BASE_DOMAIN INCLUDE_WILDCARD KEY_TYPE VALIDITY_DAYS
    local CSR_KEY_PATH CSR_FILE CSR_CONTENT SAN_LIST
    local REQUEST_TYPE PAYLOAD RESPONSE SUCCESS CERT_CONTENT CERT_ID ERRORS
    local CERT_OUT_DIR CERT_OUT_PATH KEY_OUT_PATH

    if [[ -z "$CF_ORIGIN_CA_KEY" ]]; then
        read -p "请输入 Cloudflare Origin CA Key（在 Cloudflare 控制台 -> Origin Server 中获取）: " CF_ORIGIN_CA_KEY
        CF_ORIGIN_CA_KEY=$(trim "$CF_ORIGIN_CA_KEY")
        if [[ -z "$CF_ORIGIN_CA_KEY" ]]; then
            log_error "Origin CA Key 不能为空"
            return 1
        fi
    fi

    read -p "请输入根域名（例如 example.com）: " BASE_DOMAIN
    BASE_DOMAIN=$(trim "$BASE_DOMAIN")
    if [[ -z "$BASE_DOMAIN" ]]; then
        log_error "域名不能为空"
        return 1
    fi
    if ! validate_domain "$BASE_DOMAIN"; then
        log_warn "域名格式看起来不太规范，请确认无误（不会阻断流程）"
    fi

    read -p "是否同时包含泛域名 *.${BASE_DOMAIN}？[Y/n]: " INCLUDE_WILDCARD
    INCLUDE_WILDCARD=${INCLUDE_WILDCARD:-Y}

    echo "请选择密钥类型： 1. RSA（兼容性最好）  2. ECDSA（体积更小）"
    read -p "请输入选项（默认 1）: " KEY_TYPE
    KEY_TYPE=${KEY_TYPE:-1}

    echo "请选择证书有效期（天）： 1. 90  2. 365  3. 1095  4. 5475（15年，默认）"
    read -p "请输入选项（默认 4）: " VALIDITY_CHOICE
    case "$VALIDITY_CHOICE" in
        1) VALIDITY_DAYS=90 ;;
        2) VALIDITY_DAYS=365 ;;
        3) VALIDITY_DAYS=1095 ;;
        *) VALIDITY_DAYS=5475 ;;
    esac

    # 与 Let's Encrypt（自动生成路径）不同，Origin CA 的证书/私钥存放路径由用户自行指定
    read -p "请输入证书存放路径（例如 ${SSL_DIR}/cloudflare-origin/${BASE_DOMAIN}/cert.pem）: " CERT_OUT_PATH
    CERT_OUT_PATH=$(trim "$CERT_OUT_PATH")
    if [[ -z "$CERT_OUT_PATH" ]]; then
        log_error "证书存放路径不能为空"
        return 1
    fi

    read -p "请输入私钥存放路径（例如 ${SSL_DIR}/cloudflare-origin/${BASE_DOMAIN}/key.pem）: " KEY_OUT_PATH
    KEY_OUT_PATH=$(trim "$KEY_OUT_PATH")
    if [[ -z "$KEY_OUT_PATH" ]]; then
        log_error "私钥存放路径不能为空"
        return 1
    fi

    CERT_OUT_DIR="$(dirname "$CERT_OUT_PATH")"
    mkdir -p -- "$CERT_OUT_DIR"
    mkdir -p -- "$(dirname "$KEY_OUT_PATH")"
    CSR_KEY_PATH="$KEY_OUT_PATH"
    CSR_FILE="${CERT_OUT_DIR}/$(basename "$CERT_OUT_PATH" .pem).csr"

    SAN_LIST="DNS:${BASE_DOMAIN}"
    if [[ "$INCLUDE_WILDCARD" == "y" || "$INCLUDE_WILDCARD" == "Y" ]]; then
        SAN_LIST="${SAN_LIST},DNS:*.${BASE_DOMAIN}"
    fi

    umask 077
    if [[ "$KEY_TYPE" == "2" ]]; then
        REQUEST_TYPE="origin-ecc"
        openssl ecparam -name prime256v1 -genkey -noout -out "$CSR_KEY_PATH"
    else
        REQUEST_TYPE="origin-rsa"
        openssl genrsa -out "$CSR_KEY_PATH" 2048 2>/dev/null
    fi

    if ! openssl req -new -key "$CSR_KEY_PATH" -out "$CSR_FILE" \
        -subj "/CN=${BASE_DOMAIN}" \
        -addext "subjectAltName=${SAN_LIST}" 2>/dev/null; then
        log_error "CSR 生成失败"
        return 1
    fi

    CSR_CONTENT=$(cat "$CSR_FILE")

    log_info "正在向 Cloudflare Origin CA 申请证书..."

    PAYLOAD=$(jq -n \
        --arg csr "$CSR_CONTENT" \
        --arg h1 "$BASE_DOMAIN" \
        --arg h2 "*.${BASE_DOMAIN}" \
        --arg rtype "$REQUEST_TYPE" \
        --argjson validity "$VALIDITY_DAYS" \
        --argjson include_wildcard "$([[ "$INCLUDE_WILDCARD" == "y" || "$INCLUDE_WILDCARD" == "Y" ]] && echo true || echo false)" \
        '{
            hostnames: (if $include_wildcard then [$h1, $h2] else [$h1] end),
            requested_validity: $validity,
            request_type: $rtype,
            csr: $csr
        }')

    RESPONSE=$(cf_origin_ca_api "POST" "/certificates" "$PAYLOAD")
    if [[ -z "$RESPONSE" ]]; then
        log_error "Cloudflare API 请求失败（网络超时或连接失败）"
        return 1
    fi

    SUCCESS=$(echo "$RESPONSE" | jq -r '.success' 2>/dev/null)
    if [[ "$SUCCESS" != "true" ]]; then
        ERRORS=$(echo "$RESPONSE" | jq -c '.errors' 2>/dev/null)
        log_error "Origin CA 证书申请失败: ${ERRORS}"
        return 1
    fi

    CERT_CONTENT=$(echo "$RESPONSE" | jq -r '.result.certificate')
    CERT_ID=$(echo "$RESPONSE" | jq -r '.result.id')
    echo "$CERT_CONTENT" > "$CERT_OUT_PATH"
    chmod 644 "$CERT_OUT_PATH"

    log_ok "Cloudflare Origin CA 证书申请成功（Cert ID: ${CERT_ID}）"
    echo "  CERT_PATH（证书，用户指定）：${CERT_OUT_PATH}"
    echo "  KEY_PATH（私钥，用户指定）：${KEY_OUT_PATH}"
    log_warn "提示：Origin CA 证书仅在流量经过 Cloudflare 代理（橙色云）时才被信任，请确认该域名已启用 Cloudflare CDN，且不建议启用 OCSP Stapling"

    record_cert_meta "origin_ca" "$BASE_DOMAIN" "$CERT_OUT_PATH" "$KEY_OUT_PATH"
    echo "${CERT_ID}" > "${CERT_OUT_DIR}/.cert_id"

    # Origin CA 证书不被公网信任，OCSP Stapling 无意义，这里固定不启用（TRUSTED_CERT 置空）
    push_cert_and_reload "$CERT_OUT_PATH" "$KEY_OUT_PATH" ""
}

# =============================================================================
# 3. 查看证书
# =============================================================================
function view_certs() {
    echo "📄 Let's Encrypt 证书："
    if command -v certbot &> /dev/null && [[ -d "$LE_LIVE_DIR" ]]; then
        certbot certificates 2>/dev/null | grep -E "Certificate Name:|Domains:|Expiry Date:" || echo "  (暂无)"
    else
        echo "  (未检测到 certbot 或尚无证书)"
    fi

    echo ""
    echo "📄 Cloudflare Origin CA 证书："
    local meta_line ctype domain cert_file key_file ts enddate count=0
    if [[ -f "$CERT_META_FILE" ]]; then
        while IFS='|' read -r ctype domain cert_file key_file ts; do
            [[ "$ctype" == "origin_ca" ]] || continue
            [[ -f "$cert_file" ]] || continue
            enddate=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
            echo "  - ${domain}  证书: ${cert_file}  到期时间: ${enddate:-未知}"
            ((count++))
        done < "$CERT_META_FILE"
    fi
    [[ $count -eq 0 ]] && echo "  (暂无)"

    echo ""
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE" 2>/dev/null
        echo "📄 当前 Nginx 引用的证书（共享配置 $CONFIG_FILE）："
        echo "  CERT_PATH=$CERT_PATH"
        echo "  KEY_PATH=$KEY_PATH"
        echo "  TRUSTED_CERT=${TRUSTED_CERT:-（未启用 OCSP Stapling）}"
    fi
}

# =============================================================================
# 4. 续期
# =============================================================================
function renew_certs() {
    echo "请选择要续期的证书类型："
    echo "  1. Let's Encrypt（调用 certbot renew）"
    echo "  2. Cloudflare Origin CA（重新签发，Origin CA 无原生续期接口）"
    read -p "请输入选项 [1-2]: " RENEW_CHOICE

    case "$RENEW_CHOICE" in
        1)
            if ! command -v certbot &> /dev/null; then
                log_error "未检测到 certbot，无法执行续期"
                return 1
            fi
            log_info "正在执行 certbot renew..."
            local renew_output
            if ! renew_output=$(certbot renew --non-interactive 2>&1); then
                log_error "certbot renew 执行失败："
                echo "$renew_output"
                return 1
            fi
            echo "$renew_output"
            log_ok "certbot renew 执行完成"
            log_warn "如证书内容发生更新，请选择菜单「5. 更新 Nginx 引用的证书路径并 reload」使其生效"
            log_warn "（若已配置自动续期钩子，则已自动完成更新与 reload，无需手动操作）"
            ;;
        2)
            log_warn "Cloudflare Origin CA 证书有效期最长可达 15 年，通常无需频繁续期"
            log_info "如需续期，请直接使用菜单「1. 申请证书」重新签发同一域名的 Origin CA 证书"
            ;;
        *)
            log_error "无效选项"
            ;;
    esac
}

# 配置自动续期：写入 certbot deploy-hook，续期成功后自动同步证书+reload nginx
function setup_auto_renew() {
    mkdir -p -- "$LE_HOOK_DIR"

    cat > "$LE_HOOK_SCRIPT" <<EOF
#!/bin/bash
# 由 cert_manager.sh 自动生成：certbot 续期成功后触发，同步证书路径并 reload nginx
"$SELF_PATH" --post-renew-hook "\$RENEWED_LINEAGE"
EOF
    chmod 700 "$LE_HOOK_SCRIPT"
    log_ok "已写入续期钩子：$LE_HOOK_SCRIPT"

    if systemctl list-unit-files 2>/dev/null | grep -q "certbot.timer"; then
        if systemctl is-enabled --quiet certbot.timer 2>/dev/null; then
            log_ok "系统 certbot.timer 已启用，自动续期检测已生效"
        else
            log_info "正在启用系统 certbot.timer ..."
            systemctl enable --now certbot.timer 2>/dev/null && \
                log_ok "certbot.timer 已启用" || \
                log_warn "certbot.timer 启用失败，请手动执行: systemctl enable --now certbot.timer"
        fi
    else
        log_warn "未检测到 certbot.timer，请确认系统的 certbot 是否已随包安装自动续期任务（例如 /etc/cron.d/certbot）"
    fi
}

# 供 certbot deploy-hook 调用：证书续期成功后自动同步 + reload（不进入交互菜单）
function post_renew_hook() {
    local lineage_dir="$1"
    local domain trusted_cert=""

    if [[ -z "$lineage_dir" || ! -d "$lineage_dir" ]]; then
        log_error "post-renew-hook 未收到有效的 RENEWED_LINEAGE 路径：${lineage_dir}"
        return 1
    fi

    domain="$(basename "$lineage_dir")"
    log_info "检测到证书续期：${domain}，正在同步到 Nginx..."

    # 保留原有是否启用 stapling 的选择：若共享配置里已经指向 chain.pem，则继续沿用
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE" 2>/dev/null
        [[ "$TRUSTED_CERT" == *"${domain}"*"chain.pem" ]] && trusted_cert="${lineage_dir}/chain.pem"
    fi

    record_cert_meta "letsencrypt" "$domain" "${lineage_dir}/fullchain.pem" "${lineage_dir}/privkey.pem"
    push_cert_and_reload "${lineage_dir}/fullchain.pem" "${lineage_dir}/privkey.pem" "$trusted_cert"
}

# =============================================================================
# 5. 手动更新 Nginx 引用的证书路径并 reload（不改变证书本身，仅重新下发/reload）
# =============================================================================
function manual_update_nginx() {
    local CERT_PATH_IN KEY_PATH_IN TRUSTED_IN

    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE" 2>/dev/null
        echo "当前 CERT_PATH=$CERT_PATH"
        echo "当前 KEY_PATH=$KEY_PATH"
        echo "当前 TRUSTED_CERT=${TRUSTED_CERT:-（未启用）}"
    fi

    read -p "请输入证书路径（回车沿用当前 CERT_PATH）: " CERT_PATH_IN
    CERT_PATH_IN=${CERT_PATH_IN:-$CERT_PATH}
    read -p "请输入私钥路径（回车沿用当前 KEY_PATH）: " KEY_PATH_IN
    KEY_PATH_IN=${KEY_PATH_IN:-$KEY_PATH}
    read -p "请输入根证书路径（不启用 OCSP Stapling 请留空，回车沿用当前 TRUSTED_CERT）: " TRUSTED_IN
    TRUSTED_IN=${TRUSTED_IN:-$TRUSTED_CERT}

    push_cert_and_reload "$CERT_PATH_IN" "$KEY_PATH_IN" "$TRUSTED_IN"
}

# =============================================================================
# 供 certbot deploy-hook 静默调用的入口（不进入菜单）
# =============================================================================
if [[ "$1" == "--post-renew-hook" ]]; then
    check_root
    load_env
    post_renew_hook "$2"
    exit $?
fi

# =============================================================================
# 主流程初始化
# =============================================================================
check_root
check_dependencies
load_env

# ========== 主菜单 ==========
while true; do
    echo -e "\n====== 证书管理 (cert_manager.sh) ======"
    echo "1. 申请证书（Let's Encrypt / Cloudflare Origin CA）"
    echo "2. 查看证书"
    echo "3. 续期证书"
    echo "4. 配置自动续期（Let's Encrypt）"
    echo "5. 手动更新 Nginx 引用的证书路径并 reload"
    echo "0. 退出"
    echo "==========================================="
    read -p "请选择操作 [0-5]: " CHOICE

    case $CHOICE in
        1) issue_cert ;;
        2) view_certs ;;
        3) renew_certs ;;
        4) setup_auto_renew ;;
        5) manual_update_nginx ;;
        0) exit 0 ;;
        *) echo "❌ 无效选择，请重新输入。" ;;
    esac
done
