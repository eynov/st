#!/bin/bash
# ============================================================
#  VPS Ultra Pro — 三合一代理管理器 v3.0 最终版
#  hy2 (sing-box) + SS/SS2022 + Snell v4/v6
#  支持: IPv4+IPv6 双栈 / 自动检测最新版 / 一键升级
#  整合自: eyanov/st/main/box/{hy2,ss2022,snell}.sh
# ============================================================
set -euo pipefail
[[ "${BASH_VERSINFO:-0}" -ge 4 ]] || { echo "需要 Bash 4+"; exit 1; }
(( EUID == 0 )) || { echo "请使用 root 运行"; exit 1; }

# ── 颜色 ──
R='\e[0;31m'; G='\e[0;32m'; Y='\e[1;33m'; C='\e[0;36m'; N='\e[0m'
ok()   { echo -e "${G}✓${N} $*"; }
warn() { echo -e "${Y}⚠${N} $*"; }
err()  { echo -e "${R}✗${N} $*" >&2; }
info() { echo -e "${C}ℹ${N} $*"; }

# ── 路径 ──
SB_DIR="/etc/sing-box"; SB_BIN="/usr/local/bin/sing-box"
SB_CONF="$SB_DIR/config.json"; SB_SVC="/etc/systemd/system/sing-box.service"
CERT_DIR="$SB_DIR/certs"

SS_DIR="/etc/shadowsocks"; SS_BIN="/usr/local/bin/ss-server"
QR_DIR="$SS_DIR/qrcodes"; SS_SURGE="$SS_DIR/surge_nodes.conf"

SNELL_DIR="/etc/snell"; SNELL_BIN="/usr/local/bin/snell-server"

SELF="/usr/local/bin/vps-ultra-pro"
LOG_FILE="/var/log/vps-ultra-pro.log"

# ── 工具 ──
rand_hex()  { openssl rand -hex 16; }
rand_char() { head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 32; }
rand_b64()  { openssl rand -base64 $1; }

# ── 依赖安装 ──
install_deps() {
    local missing=()
    for pkg in curl wget jq unzip openssl qrencode python3 iproute2 tar gzip xz-utils ca-certificates; do
        dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
    done
    (( ${#missing[@]} )) && { apt-get update -qq && apt-get install -y -qq "${missing[@]}"; }
}

# ── 公网 IP (v4优先, 支持IPv6双栈) ──
get_ip() {
    SERVER_IP=""; SERVER_IP6=""
    SERVER_IP=$(curl -4fsSL --max-time 5 --retry 2 https://api.ipify.org 2>/dev/null) || true
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl -4fsSL --max-time 5 https://ifconfig.me 2>/dev/null) || true
    fi
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1) || true
    fi
    SERVER_IP6=$(curl -6fsSL --max-time 5 https://api6.ipify.org 2>/dev/null) || true
    [[ -n "$SERVER_IP" ]] || { err "无法获取公网 IPv4"; return 1; }
}

has_ipv6() {
    ip -6 route show default 2>/dev/null | grep -q default
}

get_ip_for_conf() {
    local ipv6="${1:-false}"
    if [[ "$ipv6" == "true" ]] && has_ipv6 && [[ -n "$SERVER_IP6" ]]; then
        echo "$SERVER_IP6"
    else
        echo "$SERVER_IP"
    fi
}

# ── 端口检查（兼容IPv4+IPv6）──
port_check() {
    local port="$1"
    if ss -Hlntu "( sport = :${port} )" 2>/dev/null | grep -q .; then
        err "端口 ${port} 已被占用"
        return 1
    fi
}

# ── 备份 ──
backup_file() {
    local d="/root/vps_backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$d"
    cp -a "$1" "$d/" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════
#  1. Hysteria 2 (sing-box)
# ═══════════════════════════════════════════════════════════

install_singbox() {
    install_deps
    mkdir -p "$SB_DIR" "$CERT_DIR"

    if [[ ! -x "$SB_BIN" ]]; then
        local ver arch
        local http_code
        http_code=$(curl -fsSL -o /tmp/sb_latest.json -w "%{http_code}" \
            "https://api.github.com/repos/SagerNet/sing-box/releases/latest") || http_code="000"
        if [[ "$http_code" != "200" ]] || ! jq -e .tag_name /tmp/sb_latest.json &>/dev/null; then
            warn "GitHub API 异常，使用兜底版本 1.11.0"
            ver="1.11.0"
        else
            ver=$(jq -r .tag_name /tmp/sb_latest.json | sed 's/^v//')
        fi
        rm -f /tmp/sb_latest.json
        arch=$(uname -m)
        case "$arch" in x86_64) arch="linux-amd64" ;; aarch64) arch="linux-arm64" ;; *) err "不支持的架构: $arch"; exit 1 ;; esac
        local url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-${arch}.tar.gz"
        info "下载 sing-box v${ver} ..."
        wget -q -O /tmp/sb.tar.gz "$url"
        tar xf /tmp/sb.tar.gz -C /tmp
        mv "/tmp/sing-box-${ver}-${arch}/sing-box" "$SB_BIN"
        chmod 755 "$SB_BIN"
        rm -rf "/tmp/sing-box-${ver}-${arch}" /tmp/sb.tar.gz
        echo "v${ver}" > "$SB_DIR/.version"
        ok "sing-box v${ver} 安装完成"
    fi

    # 保留 hy2.sh 原 systemd 能力：无论二进制是否已存在，都确保 service 存在
    cat > "$SB_SVC" <<SVC
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$SB_BIN run -c $SB_CONF
Restart=on-failure
RestartSec=18s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
}

add_hy2() {
    install_singbox
    local sni proxy_pass="" hy2_port="443"

    if [[ -f "$SB_CONF" ]]; then
        warn "当前已有 Hy2 配置，继续将覆盖"
        read -rp "是否继续? [y/N]: " ck
        [[ "$ck" =~ ^[Yy]$ ]] || { info "已取消"; return; }
    fi

    read -rp "SNI 域名 [默认 www.icloud.com]: " sni
    sni="${sni:-www.icloud.com}"

    read -rp "Hy2 监听端口 [默认 443]: " hy2_port
    hy2_port="${hy2_port:-443}"
    if ! [[ "$hy2_port" =~ ^[0-9]+$ ]] || (( hy2_port < 1 || hy2_port > 65535 )); then
        err "端口无效: $hy2_port"
        return 1
    fi

    while [[ -z "$proxy_pass" ]]; do
        read -rp "伪装/反代目标URL (可填其他VPS nginx，如 http://1.2.3.4:8080；只填域名则默认https): " proxy_pass
    done
    # 保留原 hy2.sh 的远程反代能力：支持反代其他 VPS 的 nginx、IP:端口、http/https、路径。
    # 只输入裸域名/IP时才自动补 https://，不要强制去掉端口和路径。
    if [[ ! "$proxy_pass" =~ ^https?:// ]]; then
        proxy_pass="https://${proxy_pass}"
    fi

    port_check "$hy2_port" || return 1
    local pass; pass=$(rand_char)
    mkdir -p "$CERT_DIR"

    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
        -subj "/CN=$sni" 2>/dev/null

    cat > "$SB_CONF" <<JSON
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [{
    "type": "hysteria2",
    "listen": "::",
    "listen_port": $hy2_port,
    "users": [{"password": "$pass"}],
    "tls": {
      "enabled": true,
      "server_name": "$sni",
      "certificate_path": "$CERT_DIR/cert.pem",
      "key_path": "$CERT_DIR/key.pem"
    },
    "masquerade": {
      "type": "http",
      "url": "$proxy_pass"
    }
  }],
  "outbounds": [{"type": "direct"}]
}
JSON
    chmod 600 "$SB_CONF"

    "$SB_BIN" check -c "$SB_CONF" || { err "配置校验失败"; return 1; }
    systemctl enable --now sing-box 2>/dev/null || systemctl restart sing-box
    sleep 1
    systemctl is-active --quiet sing-box || {
        err "sing-box 启动失败，错误日志:"
        journalctl -u sing-box --no-pager -n 20
        return 1
    }
    get_ip
    echo -e "\n${G}══════ Hy2 节点 ══════${N}"
    echo "hysteria2://${pass}@${SERVER_IP}:${hy2_port}?sni=${sni}&insecure=1#Hy2-${SERVER_IP}-${hy2_port}"
    echo -e "\n${Y}Surge:${N} Hy2 = hysteria2, ${SERVER_IP}, ${hy2_port}, password=${pass}, sni=${sni}, skip-cert-verify=true"
}

del_hy2() {
    read -rp "输入 YES 确认卸载 Hy2 (大小写敏感): " ck
    [[ "$ck" == "YES" ]] || { info "已取消"; return; }
    systemctl disable --now sing-box 2>/dev/null || true
    rm -f "$SB_BIN" "$SB_CONF" "$SB_SVC"
    rm -rf "$SB_DIR" "$CERT_DIR"
    systemctl daemon-reload
    ok "Hy2 已完全卸载"
}

view_hy2() {
    [[ -f "$SB_CONF" ]] || { err "未找到 Hy2 配置"; return; }
    local pass sni proxy port
    pass=$(jq -r '.inbounds[0].users[0].password' "$SB_CONF")
    sni=$(jq -r '.inbounds[0].tls.server_name' "$SB_CONF")
    proxy=$(jq -r '.inbounds[0].masquerade.url' "$SB_CONF")
    port=$(jq -r '.inbounds[0].listen_port // 443' "$SB_CONF")
    get_ip 2>/dev/null || true
    echo -e "${C}══ Hy2 状态 ══${N}"
    systemctl status sing-box | grep -E "Active:|Main PID:" || echo "未运行"
    echo -e "\nIP: ${SERVER_IP:-未知}"
    echo "SNI: $sni  |  反代: $proxy  |  密码: $pass"
    echo -e "\n链接: hysteria2://${pass}@${SERVER_IP}:${port}?sni=${sni}&insecure=1"
}

# ═══════════════════════════════════════════════════════════
#  2. Shadowsocks / SS2022
# ═══════════════════════════════════════════════════════════

install_ss() {
    install_deps
    mkdir -p "$SS_DIR" "$QR_DIR"
    [[ -x "$SS_BIN" ]] && return 0

    local ver arch
    ver=$(curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | jq -r .tag_name)
    arch=$(uname -m)
    case "$arch" in x86_64) arch="x86_64-unknown-linux-gnu" ;; aarch64) arch="aarch64-unknown-linux-gnu" ;; *) err "不支持的架构"; exit 1 ;; esac
    local dl="shadowsocks-${ver}.${arch}.tar.xz"
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${ver}/${dl}"
    info "下载 shadowsocks-rust ${ver} ..."
    wget -q -O "/tmp/${dl}" "$url"
    rm -rf /tmp/ss_unpack
    mkdir -p /tmp/ss_unpack
    tar xf "/tmp/${dl}" -C /tmp/ss_unpack
    mv /tmp/ss_unpack/ssserver "$SS_BIN"
    chmod 755 "$SS_BIN"
    rm -rf "/tmp/${dl}" /tmp/ss_unpack
    echo "$ver" > "$SS_DIR/.version"
    ok "shadowsocks-rust ${ver} 安装完成"
}

add_ss() {
    install_ss
    mkdir -p "$SS_DIR" "$QR_DIR"
    get_ip

    echo "协议选择:"
    echo "  1) 传统 SS (none / aes-128-gcm / aes-256-gcm / chacha20)"
    echo "  2) SS2022 (2022-blake3-aes-128/256-gcm / chacha20)"
    read -rp "选择 [1-2, 默认1]: " proto_opt
    local proto="ss"
    [[ "$proto_opt" == "2" ]] && proto="ss2022"

    local domain_input
    read -rp "域名 (留空自动获取IP): " domain_input
    [[ -n "$domain_input" ]] && SERVER_IP="$domain_input"

    read -rp "端口列表 (空格分隔, 如 8388 8389): " -a PORTS
    (( ${#PORTS[@]} )) || { err "至少输入一个端口"; return 1; }

    : > "$SS_SURGE" 2>/dev/null || true

    for port in "${PORTS[@]}"; do
        port_check "$port" || continue

        local method pass
        if [[ "$proto" == "ss" ]]; then
            echo "端口 ${port} 加密方式:"
            echo "  1) none (不加密)"
            echo "  2) aes-128-gcm"
            echo "  3) aes-256-gcm"
            echo "  4) chacha20-ietf-poly1305"
            read -rp "选择 [1-4, 默认1]: " mopt
            case "${mopt:-1}" in
                2) method="aes-128-gcm" ;;
                3) method="aes-256-gcm" ;;
                4) method="chacha20-ietf-poly1305" ;;
                *) method="none" ;;
            esac
            pass=$(rand_hex)
        else
            echo "端口 ${port} SS2022 加密方式:"
            echo "  1) 2022-blake3-aes-128-gcm"
            echo "  2) 2022-blake3-aes-256-gcm"
            echo "  3) 2022-blake3-chacha20-poly1305"
            read -rp "选择 [1-3, 默认1]: " mopt
            case "${mopt:-1}" in
                2) method="2022-blake3-aes-256-gcm"; pass=$(rand_b64 32) ;;
                3) method="2022-blake3-chacha20-poly1305"; pass=$(rand_b64 32) ;;
                *) method="2022-blake3-aes-128-gcm"; pass=$(rand_b64 16) ;;
            esac
        fi

        local conf="$SS_DIR/config${port}.json"
        cat > "$conf" <<JSON
{
    "server": "0.0.0.0",
    "server_port": $port,
    "password": "$pass",
    "method": "$method",
    "mode": "tcp_and_udp",
    "fast_open": true
}
JSON
        chmod 600 "$conf"

        local svc="/etc/systemd/system/ss${port}.service"
        cat > "$svc" <<SVC
[Unit]
Description=Shadowsocks-$port
After=network.target

[Service]
ExecStart=$SS_BIN -c $conf
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVC
        systemctl daemon-reload
        systemctl enable --now "ss${port}"

        if [[ "$proto" == "ss2022" ]]; then
            local ss_url="ss://$(echo -n "${method}:${pass}" | base64 -w0)@${SERVER_IP}:${port}#SS-${port}"
            echo "ss-${port} = ss, ${SERVER_IP}, ${port}, encrypt-method=${method}, password=${pass}, udp-relay=true" >> "$SS_SURGE"
        else
            local ss_url="ss://$(echo -n "${method}:${pass}" | base64 -w0)@${SERVER_IP}:${port}#SS-${port}"
            echo "ss-${port} = ss, ${SERVER_IP}, ${port}, encrypt-method=${method}, password=${pass}, udp-relay=true" >> "$SS_SURGE"
        fi

        qrencode -t ANSIUTF8 "$ss_url" 2>/dev/null || true
        echo -e "${G}SS-${port}${N} ${method} | ${SERVER_IP}:${port} | 密码: $pass"
    done
    ok "Surge 配置已保存至 $SS_SURGE"
}

del_ss() {
    read -rp "输入要删除的端口 (空格分隔): " -a PORTS
    for port in "${PORTS[@]}"; do
        systemctl disable --now "ss${port}" 2>/dev/null || true
        rm -f "/etc/systemd/system/ss${port}.service" "$SS_DIR/config${port}.json"
        ok "SS 端口 ${port} 已删除"
    done
    systemctl daemon-reload
}

list_ss() {
    echo -e "${C}══ Shadowsocks 节点列表 ══${N}"
    local count=0
    for f in "$SS_DIR"/config*.json; do
        [[ -f "$f" ]] || continue
        local port pass method
        port=$(grep -oP '"server_port":\s*\K\d+' "$f")
        pass=$(grep -oP '"password":\s*"\K[^"]+' "$f" | head -1)
        method=$(grep -oP '"method":\s*"\K[^"]+' "$f")
        local st="🟢"
        systemctl is-active --quiet "ss${port}" 2>/dev/null || st="🔴"
        echo "  $st 端口:$port | $method"
        echo "      密码: $pass"
        ((count++))
    done
    ((count == 0)) && echo "  无 SS 实例"
}

exit_ss_menu() { exit 0; }

# ═══════════════════════════════════════════════════════════
#  3. Snell v6
# ═══════════════════════════════════════════════════════════

valid_snell_version() {
    # 支持: v6.0.0 / v6.0.0b3 / v6.0.0-rc1 / v6.0.0rc1 / v4.1.1
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([._-]?(b|beta|rc)[0-9]+)?$ ]]
}

snell_url_ok() {
    local version="$1" arch="$2"
    [[ "$version" == v* ]] || version="v${version}"
    local code
    code=$(curl -fsSL -o /dev/null -w "%{http_code}" --max-time 6 \
        "https://dl.nssurge.com/snell/snell-server-${version}-linux-${arch}.zip" 2>/dev/null) || code="000"
    [[ "$code" == "200" ]]
}

get_latest_snell() {
    local arch; arch=$(uname -m)
    case "$arch" in x86_64) arch="amd64" ;; aarch64) arch="aarch64" ;; *) echo "未知"; return 1 ;; esac

    local fallback="v6.0.0b3"
    local candidates=()

    # 方法一：从 Surge KB 提取候选 zip 名；不直接信任解析结果，必须做版本校验 + URL 校验
    local page
    page=$(curl -fsSL -m 10 -A "Mozilla/5.0" \
        "https://kb.nssurge.com/surge-knowledge-base/release-notes/snell" 2>/dev/null) || true
    if [[ -n "$page" ]]; then
        # 兼容未来 6.0.0 正式版 / rc / beta / b 命名；只提取 linux-amd64 作为版本发现参考
        mapfile -t candidates < <(echo "$page" \
            | grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+([._-]?(b|beta|rc)[0-9]+)?-linux-amd64\.zip' 2>/dev/null \
            | sed -E 's/^snell-server-(v[^-]+)-linux-amd64\.zip$/\1/' \
            | sort -Vu \
            | tac)
        for v in "${candidates[@]}"; do
            if valid_snell_version "$v" && snell_url_ok "$v" "$arch"; then
                echo "$v"
                return 0
            fi
        done
    fi

    # 方法二：固定白名单探测。保留稳定兜底 v6.0.0b3，避免 KB 正则失效导致不可用。
    for v in "v6.0.0" "v6.0.0rc1" "v6.0.0-rc1" "v6.0.0b3" "v6.0.0b2" "v6.0.0b1" "v4.1.1" "v4.1.0"; do
        if valid_snell_version "$v" && snell_url_ok "$v" "$arch"; then
            echo "$v"
            return 0
        fi
    done

    # 方法三：固定兜底也校验；只有连 fallback 都不可下载才返回未知。
    if snell_url_ok "$fallback" "$arch"; then
        warn "Snell 版本发现失败，使用固定兜底 ${fallback}" >&2
        echo "$fallback"
        return 0
    fi

    echo "未知"
    return 1
}

download_snell() {
    local version="$1"
    local arch; arch=$(uname -m)
    case "$arch" in x86_64) arch="amd64" ;; aarch64) arch="aarch64" ;; *) err "不支持的架构"; return 1 ;; esac
    local url="https://dl.nssurge.com/snell/snell-server-${version}-linux-${arch}.zip"
    local dl="/tmp/snell_${version}.zip"
    info "下载 Snell ${version} ..."
    wget -q --tries=3 --timeout=20 -O "$dl" "$url" || { err "下载失败"; return 1; }
    rm -rf /tmp/snell_extract
    python3 -c "import zipfile; zipfile.ZipFile('${dl}').extractall('/tmp/snell_extract')" 2>/dev/null
    local found; found=$(find /tmp/snell_extract -type f -name 'snell-server' 2>/dev/null | head -1)
    [[ -n "$found" ]] || { err "解压失败，未找到 snell-server"; rm -f "$dl"; return 1; }
    [[ -f "$SNELL_BIN" ]] && cp "$SNELL_BIN" "$SNELL_BIN.bak.$(date +%Y%m%d_%H%M%S)"
    mv "$found" "$SNELL_BIN"
    chmod 755 "$SNELL_BIN"
    echo "$version" > "$SNELL_DIR/.version"
    rm -f "$dl"
    ok "Snell ${version} 安装完成"
}

install_snell() {
    [[ -x "$SNELL_BIN" ]] && return 0
    install_deps
    mkdir -p "$SNELL_DIR"
    local ver; ver=$(get_latest_snell)
    [[ "$ver" == "未知" ]] && { err "无法获取 Snell 最新版本"; return 1; }
    download_snell "$ver"
}

add_snell() {
    install_snell || return 1
    read -rp "端口列表 (空格分隔): " -a PORTS
    (( ${#PORTS[@]} )) || { err "至少一个端口"; return 1; }

    local mem_mb; mem_mb=$(free -m | awk '/Mem:/ {print $2}')
    local max_conn=$((mem_mb * 2))
    (( max_conn < 300 )) && max_conn=300
    (( max_conn > 10000 )) && max_conn=10000

    for port in "${PORTS[@]}"; do
        port_check "$port" || continue
        local psk; psk=$(openssl rand -hex 32)
        local conf="${SNELL_DIR}/snell-server-${port}.conf"

        # IPv6 自动检测
        local listen_ip
        if has_ipv6; then
            listen_ip="0.0.0.0:${port},[::]:${port}"
        else
            listen_ip="0.0.0.0:${port}"
        fi

        cat > "$conf" <<CONF
[snell-server]
listen = ${listen_ip}
psk = ${psk}
version = 6
dns-ip-preference = prefer-ipv4
ipv6 = $(has_ipv6 && echo true || echo false)
udp-relay = true
max_conn = ${max_conn}
tfo = true
CONF
        chmod 600 "$conf"

        local svc="/etc/systemd/system/snell-${port}.service"
        cat > "$svc" <<SVC
[Unit]
Description=Snell-$port
After=network-online.target

[Service]
Type=simple
ExecStart=$SNELL_BIN -c $conf
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
SVC
        systemctl daemon-reload
        systemctl enable --now "snell-${port}"
        sleep 0.5
        if systemctl is-active --quiet "snell-${port}"; then
            get_ip
            echo -e "${G}Snell-${port}${N} | $(get_ip_for_conf "$(has_ipv6 && echo true || echo false)"):${port} | v6"
            echo "       PSK: $psk"
        else
            err "Snell-$port 启动失败"
            journalctl -u "snell-$port" -n 15 --no-pager
        fi
    done
}

del_snell() {
    read -rp "端口列表 (空格分隔): " -a PORTS
    for port in "${PORTS[@]}"; do
        systemctl disable --now "snell-${port}" 2>/dev/null || true
        rm -f "/etc/systemd/system/snell-${port}.service" "$SNELL_DIR/snell-server-${port}.conf"
        ok "Snell 端口 $port 已删除"
    done
    systemctl daemon-reload
}

view_snell() {
    local count=0
    for f in "$SNELL_DIR"/snell-server-*.conf; do
        [[ -f "$f" ]] || continue
        local port psk
        port=$(echo "$f" | sed -E 's/.*snell-server-(.*)\.conf/\1/')
        psk=$(grep -oP '(?<=^psk = ).*' "$f" | tr -d ' ')
        local st="🟢"
        systemctl is-active --quiet "snell-${port}" 2>/dev/null || st="🔴"
        echo "  $st Snell-$port | PSK: $psk"
        ((count++))
    done
    ((count == 0)) && echo "  无 Snell 实例"
}

# ═══════════════════════════════════════════════════════════
#  4. Dashboard / 版本检测 / 更新
# ═══════════════════════════════════════════════════════════

dashboard() {
    clear
    echo "════════════════════════════════════════════"
    echo "     VPS Ultra Pro v3.0  Dashboard"
    echo "════════════════════════════════════════════"
    get_ip 2>/dev/null && echo "  IPv4: ${SERVER_IP:-—}  IPv6: ${SERVER_IP6:-—}" || echo "  IP: 未知"
    echo

    # sing-box
    echo -e "── ${C}sing-box (Hy2)${N} ──"
    if systemctl list-units sing-box.service 2>/dev/null | grep -q sing-box; then
        local v; v=$(cat "$SB_DIR/.version" 2>/dev/null || echo "?")
        systemctl is-active --quiet sing-box 2>/dev/null \
            && echo "  ${G}🟢 sing-box ${v} 运行中${N}" \
            || echo "  ${R}🔴 sing-box ${v} 已停止${N}"
    else
        echo "  未安装"
    fi

    # SS
    echo -e "\n── ${C}Shadowsocks${N} ──"
    local ss_count=0
    for f in /etc/systemd/system/ss*.service; do
        [[ -f "$f" ]] || continue
        ((ss_count++))
        local n; n=$(basename "$f" .service)
        systemctl is-active --quiet "$n" 2>/dev/null \
            && echo "  ${G}🟢 $n${N}" \
            || echo "  ${R}🔴 $n${N}"
    done
    ((ss_count == 0)) && echo "  无 SS 实例"

    # Snell
    echo -e "\n── ${C}Snell${N} ──"
    local sn_count=0
    for f in /etc/systemd/system/snell-*.service; do
        [[ -f "$f" ]] || continue
        ((sn_count++))
        local n; n=$(basename "$f" .service)
        systemctl is-active --quiet "$n" 2>/dev/null \
            && echo "  ${G}🟢 $n${N}" \
            || echo "  ${R}🔴 $n${N}"
    done
    ((sn_count == 0)) && echo "  无 Snell 实例"

    echo -e "\n── ${C}端口监听${N} ──"
    ss -Hlntu 2>/dev/null | awk '{print $1, $5}' | sort -t: -k2 -n | head -20
    if command -v ufw &>/dev/null && ufw status | grep -qi inactive; then
        echo -e "\n${Y}⚠ ufw 未启用${N}"
    fi
}

check_and_update() {
    echo -e "${C}══════ 版本检查与更新 ══════${N}"
    local updated=0

    # sing-box
    if [[ -x "$SB_BIN" ]]; then
        local cur latest_s
        cur=$(cat "$SB_DIR/.version" 2>/dev/null || echo "v0")
        latest_s=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/^v//')
        echo -n "  sing-box  ${cur} → v${latest_s}  "
        if [[ "$cur" == "v${latest_s}" ]]; then
            echo -e "${G}✓${N}"
        else
            echo -e "${Y}可升级${N}"
            read -rp "  升级? [Y/n]: " ans
            if [[ "${ans:-y}" =~ ^[Yy]$ ]]; then
                systemctl stop sing-box 2>/dev/null || true
                backup_file "$SB_BIN"
                local sb_bak="/tmp/sing-box.bak.$$"
                cp "$SB_BIN" "$sb_bak"
                local arch; arch=$(uname -m)
                case "$arch" in x86_64) arch="linux-amd64" ;; aarch64) arch="linux-arm64" ;; *) err "不支持的架构: $arch"; return 1 ;; esac
                wget -q -O /tmp/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${latest_s}/sing-box-${latest_s}-${arch}.tar.gz"
                tar xf /tmp/sb.tar.gz -C /tmp
                mv "/tmp/sing-box-${latest_s}-${arch}/sing-box" "$SB_BIN"
                chmod 755 "$SB_BIN"
                if "$SB_BIN" check -c "$SB_CONF"; then
                    systemctl start sing-box
                    echo "v${latest_s}" > "$SB_DIR/.version"
                    ok "sing-box 升级至 v${latest_s}"
                    updated=1
                    rm -f "$sb_bak"
                else
                    err "sing-box 新版本配置校验失败，正在回滚旧版本"
                    mv "$sb_bak" "$SB_BIN"
                    chmod 755 "$SB_BIN"
                    systemctl start sing-box 2>/dev/null || true
                    rm -rf /tmp/sing-box* /tmp/sb.tar.gz
                    return 1
                fi
                rm -rf /tmp/sing-box* /tmp/sb.tar.gz
            fi
        fi
    fi

    # SS
    if [[ -x "$SS_BIN" ]]; then
        local cur_ss latest_ss
        cur_ss=$(cat "$SS_DIR/.version" 2>/dev/null || echo "")
        latest_ss=$(curl -fsSL https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | jq -r .tag_name)
        echo -n "  SS-rust   ${cur_ss:-?} → ${latest_ss}  "
        if [[ "$cur_ss" == "$latest_ss" ]]; then
            echo -e "${G}✓${N}"
        else
            echo -e "${Y}可升级${N}"
            read -rp "  升级? [Y/n]: " ans
            if [[ "${ans:-y}" =~ ^[Yy]$ ]]; then
                local arch; arch=$(uname -m);
                case "$arch" in x86_64) arch="x86_64-unknown-linux-gnu" ;; aarch64) arch="aarch64-unknown-linux-gnu" ;; esac
                for s in /etc/systemd/system/ss*.service; do systemctl stop "$(basename "$s")" 2>/dev/null || true; done
                backup_file "$SS_BIN"
                wget -q -O /tmp/ss.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest_ss}/shadowsocks-${latest_ss}.${arch}.tar.xz"
                tar xf /tmp/ss.tar.xz -C /tmp/ss_unpack; mv /tmp/ss_unpack/ssserver "$SS_BIN"; chmod 755 "$SS_BIN"
                echo "$latest_ss" > "$SS_DIR/.version"
                for s in /etc/systemd/system/ss*.service; do systemctl start "$(basename "$s")" 2>/dev/null || true; done
                ok "SS-rust 升级至 ${latest_ss}"; updated=1
                rm -rf /tmp/ss.tar.xz /tmp/ss_unpack
            fi
        fi
    fi

    # Snell
    if [[ -x "$SNELL_BIN" ]]; then
        local cur_sn latest_sn
        cur_sn=$(cat "$SNELL_DIR/.version" 2>/dev/null || echo "")
        latest_sn=$(get_latest_snell)
        echo -n "  Snell     ${cur_sn:-?} → ${latest_sn}  "
        if [[ "$cur_sn" == "$latest_sn" ]]; then
            echo -e "${G}✓${N}"
        elif [[ "$latest_sn" != "未知" ]]; then
            echo -e "${Y}可升级${N}"
            read -rp "  升级? [Y/n]: " ans
            if [[ "${ans:-y}" =~ ^[Yy]$ ]]; then
                for s in /etc/systemd/system/snell-*.service; do systemctl stop "$(basename "$s")" 2>/dev/null || true; done
                backup_file "$SNELL_BIN"
                download_snell "$latest_sn"
                for s in /etc/systemd/system/snell-*.service; do systemctl start "$(basename "$s")" 2>/dev/null || true; done
                updated=1
            fi
        else
            echo -e "${Y}无法检测${N}"
        fi
    fi

    ((updated == 0)) && info "所有组件已是最新或无需更新"
    systemctl daemon-reload
}

# ═══════════════════════════════════════════════════════════
#  5. 子菜单
# ═══════════════════════════════════════════════════════════

ss_menu() {
    while true; do
        echo -e "\n${C}══ Shadowsocks 管理 ══${N}"
        echo "  1) 添加节点 (批量)"
        echo "  2) 删除节点"
        echo "  3) 查看节点"
        echo "  0) 返回主菜单"
        read -rp "选择: " s
        case "$s" in
            1) add_ss ;;
            2) del_ss ;;
            3) list_ss ;;
            0) return ;;
            *) err "无效" ;;
        esac
    done
}

snell_menu() {
    while true; do
        echo -e "\n${C}══ Snell 管理 ══${N}"
        echo "  1) 添加端口"
        echo "  2) 删除端口"
        echo "  3) 查看节点"
        echo "  0) 返回主菜单"
        read -rp "选择: " s
        case "$s" in
            1) add_snell ;;
            2) del_snell ;;
            3) view_snell ;;
            0) return ;;
            *) err "无效" ;;
        esac
    done
}

hy2_menu() {
    while true; do
        echo -e "\n${C}══ Hysteria 2 管理 ══${N}"
        echo "  1) 部署/覆盖 Hy2"
        echo "  2) 查看 Hy2 配置"
        echo "  3) 卸载 Hy2"
        echo "  0) 返回主菜单"
        read -rp "选择: " s
        case "$s" in
            1) add_hy2 ;;
            2) view_hy2 ;;
            3) del_hy2 ;;
            0) return ;;
            *) err "无效" ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════
#  主菜单
# ═══════════════════════════════════════════════════════════
main_menu() {
    echo -e "
  ${C}═══════════════════════════════════${N}
  ${C}  VPS Ultra Pro Manager v3.0${N}
  ${C}  HY2 + SS/SS2022 + Snell v4/v6${N}
  ${C}═══════════════════════════════════${N}
   1) Hysteria 2 (sing-box)
   2) Shadowsocks / SS2022
   3) Snell v4/v6
   4) Dashboard
   5) 检查更新 (自动升级)
   0) 退出
  ${C}───────────────────────────────────${N}"
}

while true; do
    main_menu
    read -rp "选择 [0-5]: " opt
    case "${opt:-}" in
        1) hy2_menu   ;;
        2) ss_menu    ;;
        3) snell_menu ;;
        4) dashboard  ;;
        5) check_and_update ;;
        0) echo "再见。"; exit 0 ;;
        *) err "无效" ;;
    esac
    echo; read -rp "按回车继续..." _
done