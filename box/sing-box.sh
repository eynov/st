#!/bin/bash

# ==============================================================================
# sing-box Multi-Instance Control Panel v3 (Dynamic Architecture)
# ==============================================================================

set -e

# 权限硬性校验
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误：请以 root 权限运行此脚本！"
  exit 1
fi

# 基础全局骨架路径
SB_DIR="/etc/sing-box"
INST_DIR="${SB_DIR}/instances"
SB_BIN="/usr/local/bin/sing-box"
CERT_DIR="${SB_DIR}/certs"

mkdir -p "$INST_DIR" "$CERT_DIR"

# =========================
# 系统底层核心工具箱
# =========================
ok(){ echo -e "🟢 $*"; }
err(){ echo -e "❌ $*"; }
warn(){ echo -e "⚠️ $*"; }

# 1. 严格无缝端口占用校验 (基于 awk 精确锚定行尾端口，彻底规避 443 模糊匹配 4433 缺陷)
port_used(){
    ss -lntu | awk '{print $5}' | grep -qE ":$1$"
}

# 2. 动态双栈路由拓扑公网 IP 嗅探
get_ip() {
    local ip=$(curl -4 -s --max-time 3 ifconfig.me || curl -4 -s --max-time 3 api.ipify.org)
    if [ -z "$ip" ]; then
        # 兜底查询本地默认网关物理路由出口
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -1)
    fi
    echo "${ip:-127.0.0.1}"
}

# 3. 统一本地离线安全二维码渲染引擎
show_qr() {
    local data="$1"
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "\n📷 扫描下方二维码快捷添加节点:"
        qrencode -t ansiutf8 "$data"
    else
        warn "提示：系统未检测到 qrencode。若需在终端内直接高精度渲染二维码，请执行 'apt install qrencode'。"
    fi
}

# ==========================================================
# 语义化版本平滑升级与编译环境维护
# ==========================================================
check_and_install_core() {
    echo "🔄 正在核验 sing-box 核心资产与依赖链..."
    apt-get update && apt-get install -y curl jq tar gzip openssl wget qrencode >/dev/null 2>&1
    
    # 异步GitHub安全流捕获
    local http_code=$(curl -s -o /tmp/sb.json -w "%{http_code}" https://api.github.com/repos/SagerNet/sing-box/releases/latest)
    local latest_ver="1.11.0"
    if [ "$http_code" == "200" ] && jq -e .tag_name /tmp/sb.json >/dev/null 2>&1; then
        latest_ver=$(jq -r .tag_name /tmp/sb.json | sed 's/^v//')
    fi
    rm -f /tmp/sb.json

    if [ -f "$SB_BIN" ]; then
        local current_ver=$($SB_BIN version | awk '{print $3}' | sed 's/^v//')
        if dpkg --compare-versions "$current_ver" ge "$latest_ver" 2>/dev/null; then
            return
        fi
        echo "🔄 检测到上游新版本 v$latest_ver，正在下发平滑升级流..."
    fi
    
    local arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="linux-amd64" ;;
        aarch64) arch="linux-arm64" ;;
        *) err "架构不兼容：不支持的 CPU 架构 $arch"; exit 1 ;;
    esac

    wget -O /tmp/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box-${latest_ver}-${arch}.tar.gz"
    mkdir -p /tmp/sb_extracted
    tar -zxvf /tmp/sing-box.tar.gz -C /tmp/sb_extracted --strip-components=1 >/dev/null
    mv /tmp/sb_extracted/sing-box $SB_BIN
    chmod +x $SB_BIN
    rm -rf /tmp/sing-box* /tmp/sb_extracted
    ok "sing-box 核心引擎已成功同步至 v${latest_ver}"
}

# ==========================================================
# 标准化 Systemd 多实例模版引擎 (强制绑定 WorkingDirectory)
# ==========================================================
gen_service(){
    local port=$1
    cat > /etc/systemd/system/sb-${port}.service <<EOF
[Unit]
Description=sing-box multi-instance routing service (Port: ${port})
After=network.target nss-lookup.target

[Service]
WorkingDirectory=${INST_DIR}/${port}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${SB_BIN} run -c ${INST_DIR}/${port}/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

# ==========================================================
# 协议解耦工厂模块 (输出: 隔离运行配置 + 纯净资产元数据)
# ==========================================================

# 1. 经典 Shadowsocks 工厂
build_ss() {
    local port=$1
    local pwd=$(openssl rand -hex 16)
    
    # 注入双栈监听运行配置 (::)
    cat > "${INST_DIR}/${port}/config.json" <<EOF
{ "inbounds": [{ "type": "shadowsocks", "listen": "::", "listen_port": $port, "method": "aes-256-gcm", "password": "$pwd" }] }
EOF
    # 隔离写入轻量元数据库
    cat > "${INST_DIR}/${port}/meta.json" <<EOF
{
  "port": $port,
  "protocol": "SS",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "password": "$pwd"
}
EOF
}

# 2. Shadowsocks 2022 工厂
build_ss2022() {
    local port=$1
    local pwd=$(openssl rand -base64 24)
    
    cat > "${INST_DIR}/${port}/config.json" <<EOF
{ "inbounds": [{ "type": "shadowsocks", "listen": "::", "listen_port": $port, "method": "2022-blake3-aes-256-gcm", "password": "$pwd" }] }
EOF
    cat > "${INST_DIR}/${port}/meta.json" <<EOF
{
  "port": $port,
  "protocol": "SS2022",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "password": "$pwd"
}
EOF
}

# 3. Hysteria2 工厂 (网页原生反代伪装回落版)
build_hy2() {
    local port=$1
    
    read -p "请输入客户端 TLS 握手 SNI 域名 (默认: www.apple.com): " sni
    sni=${sni:-www.apple.com}
    read -p "请输入未认证网页伪装回落 URL (默认: https://www.apple.com): " masq
    masq=${masq:-https://www.apple.com}
    
    local pwd=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)
    local cert="${CERT_DIR}/cert_${port}.crt"
    local key="${CERT_DIR}/private_${port}.key"
    
    # 构建高容错长效期假证书流
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$key" -out "$cert" -subj "/CN=${sni}" >/dev/null 2>&1

    # 完美修正：将 masquerade_url 替换为标准的 masquerade 对象，指定 type 为 proxy
    cat > "${INST_DIR}/${port}/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [{
    "type": "hysteria2",
    "listen": "::",
    "listen_port": $port,
    "users": [{"password": "$pwd"}],
    "masquerade": {
      "type": "proxy",
      "url": "$masq"
    },
    "tls": { 
      "enabled": true, 
      "server_name": "$sni", 
      "certificate_path": "$cert", 
      "key_path": "$key" 
    }
  }],
  "outbounds": [{"type": "direct"}]
}
EOF

    cat > "${INST_DIR}/${port}/meta.json" <<EOF
{
  "port": $port,
  "protocol": "HY2",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "password": "$pwd",
  "sni": "$sni"
}
EOF
}


# ==========================================================
# 算力收拢引擎：统一多协议动态网络层 URI 生成器
# ==========================================================
generate_dynamic_uri() {
    local target_dir="$1"
    local meta_file="${target_dir}/meta.json"
    
    if [ ! -f "$meta_file" ]; then return; fi
    
    local current_ip=$(get_ip)
    local proto=$(jq -r '.protocol' "$meta_file")
    local port=$(jq -r '.port' "$meta_file")
    local pwd=$(jq -r '.password' "$meta_file")
    
    case "$proto" in
        "SS")
            local b64=$(echo -n "aes-256-gcm:${pwd}" | base64 | tr -d '\n')
            echo "ss://${b64}@${current_ip}:${port}#SS_${port}"
            ;;
        "SS2022")
            local b64=$(echo -n "2022-blake3-aes-256-gcm:${pwd}" | base64 | tr -d '\n')
            echo "ss://${b64}@${current_ip}:${port}#SS2022_${port}"
            ;;
        "HY2")
            local sni=$(jq -r '.sni' "$meta_file")
            echo "hysteria2://${pwd}@${current_ip}:${port}?sni=${sni}&insecure=1#HY2_${port}"
            ;;
    esac
}

# =========================
# 控制层业务逻辑段
# =========================

# 1. 实例容器化添加
add_instance(){
    check_and_install_core

    echo "=========================="
    echo " 🚀 选择服务协议"
    echo " 1) Shadowsocks (AES-256-GCM)"
    echo " 2) Shadowsocks 2022 (Blake3)"
    echo " 3) Hysteria2 (方案B: 完美反代伪装版)"
    echo "=========================="
    read -p ">> " proto_choice

    read -p "输入挂载端口: " port
    if port_used "$port"; then err "端口已被内核套接字占用！"; return; fi

    mkdir -p "${INST_DIR}/${port}"

    case $proto_choice in
      1) build_ss "$port" ;;
      2) build_ss2022 "$port" ;;
      3) build_hy2 "$port" ;;
      *) err "非法输入"; rm -rf "${INST_DIR}/${port}"; return ;;
    esac

    # 稳定性断言校验
    if ! $SB_BIN check -c "${INST_DIR}/${port}/config.json"; then
        err "核心配置文件合规性校验失败！"
        rm -rf "${INST_DIR}/${port}"
        return
    fi

    gen_service "$port"
    systemctl daemon-reload
    systemctl enable sb-${port} >/dev/null 2>&1
    systemctl restart sb-${port}

    sleep 1.2
    if systemctl is-active --quiet sb-${port}; then
        ok "实例 [${port}] 部署挂载上线成功！"
        # 实时通过动态引擎合成 URI
        local dynamic_uri=$(generate_dynamic_uri "${INST_DIR}/${port}")
        echo -e "\n📋 当前最新动态节点订阅凭证:"
        echo -e "\033[36m${dynamic_uri}\033[0m"
        show_qr "$dynamic_uri"
    else
        err "内核进程调配失败！实时错误流追溯："
        journalctl -u sb-${port} -n 15 --no-pager
    fi
}

# 2. 联动级安全擦除
delete_instance(){
    read -p "请输入欲卸载删除的端口实例: " port
    if [ ! -d "${INST_DIR}/${port}" ]; then err "指定的实例在数据库中不存在"; return; fi

    read -p "⚠️ 警告：彻底清除该实例（端口 ${port}）吗？请强键入 YES 确认: " confirm
    if [ "$confirm" != "YES" ]; then echo "安全退出，未做改动"; return; fi

    systemctl stop sb-${port} 2>/dev/null || true
    systemctl disable sb-${port} 2>/dev/null || true
    rm -f /etc/systemd/system/sb-${port}.service
    rm -rf "${INST_DIR}/${port}"
    rm -f "${CERT_DIR}/cert_${port}.crt" "${CERT_DIR}/private_${port}.key"
    
    systemctl daemon-reload
    systemctl reset-failed sb-${port} 2>/dev/null || true
    ok "端口 [${port}] 所有的进程单元、伪装证书、元数据资产已被强力抹除清洁。"
}

# 3. 统一全局状态树与凭证查看入口
show_instance_detail(){
    echo "=========================================================="
    echo " 🔍 全局实例状态拓扑树"
    echo "=========================================================="
    local list=( "${INST_DIR}"/* )
    if [ ! -e "${list[0]}" ]; then
        warn "当前系统内核中无任何运行或终止的单项实例。"
        return
    fi

    printf "%-10s | %-12s | %-22s | %-12s\n" "监听端口" "协议安全机制" "实例部署时间" "Systemd 状态"
    echo "----------------------------------------------------------"
    for d in "${INST_DIR}"/*; do
        [ -d "$d" ] || continue
        local p=$(basename "$d")
        local meta="${d}/meta.json"
        
        local proto="Unknown" local ctime="Unknown"
        if [ -f "$meta" ]; then
            proto=$(jq -r '.protocol' "$meta")
            ctime=$(jq -r '.created_at' "$meta")
        fi

        local status="🔴 Stopped"
        if systemctl is-active --quiet sb-${p}; then status="🟢 Running"; fi
        printf "%-10s | %-12s | %-22s | %-12s\n" "$p" "$proto" "$ctime" "$status"
    done
    echo "=========================================================="
    
    read -p "请输入要提取高精细凭证与本地二维码的端口 (回车安全返回): " sel_port
    if [ -z "$sel_port" ]; then return; fi
    
    local target_dir="${INST_DIR}/${sel_port}"
    if [ ! -d "$target_dir" ] || [ ! -f "${target_dir}/meta.json" ]; then err "该端口元数据严重损毁或不存在！"; return; fi

    echo -e "\n=================================================="
    echo "       sing-box 端口 [${sel_port}] 动态运行期资产明细"
    echo "=================================================="
    # 调用收拢引擎实时计算 IP
    local active_uri=$(generate_dynamic_uri "$target_dir")
    
    echo -e "📌 协议家族: $(jq -r '.protocol' "${target_dir}/meta.json")"
    echo -e "📌 资产创建期: $(jq -r '.created_at' "${target_dir}/meta.json")"
    echo -e "📌 底层核心密匙: $(jq -r '.password' "${target_dir}/meta.json")"
    if [ "$(jq -r '.protocol' "${target_dir}/meta.json")" == "HY2" ]; then
        echo -e "📌 握手 SNI 伪装: $(jq -r '.sni' "${target_dir}/meta.json")"
    fi
    echo -e "📌 算力引擎动态组装 URI: \033[36m${active_uri}\033[0m"
    
    show_qr "$active_uri"

    echo -e "\n⚙️ 套接字硬件网络监听映射树:"
    ss -tulnp | grep -E ":${sel_port}\s" || warn "警告：内核当前未对该端口开放任何有效的物理套接字监听！"
    echo "=================================================="
}

# 4. 强壮性全局调度重构
restart_all(){
    local has_any=false
    for d in "${INST_DIR}"/*; do
        [ -e "$d" ] || break
        [ -d "$d" ] || continue
        local p=$(basename "$d")
        
        # 严格控制流：只有当系统真实注册了单元文件时才进行拉起，防错断
        if [ -f "/etc/systemd/system/sb-${p}.service" ]; then
            has_any=true
            systemctl restart sb-${p}
            echo "🔄 实例 [${p}] 的套接字及守护进程已被重新强制构建"
        fi
    done
    $has_any && ok "所有的运行期活跃实例已平滑热重载。" || warn "任务终止：未检索到有效的物理调度实体。"
}

# =========================
# 循环主控制控制面板
# =========================
while true; do
    echo ""
    echo "========================================="
    echo "   sing-box 容器化多实例智能管理面板 v3"
    echo "========================================="
    echo " 1. 新增 端口协议实例 (统一接口工厂)"
    echo " 2. 删除 指定端口实例 (联动彻底擦除)"
    echo " 3. 查看 实例全局状态及凭证详情 (统一入口)"
    echo " 4. 重启 全部运行中的端口实例 (健壮性调度)"
    echo " 0. 退出管理面板"
    echo "========================================="
    read -p "请输入调度指令 >> " opt

    case $opt in
      1) add_instance ;;
      2) delete_instance ;;
      3) show_instance_detail ;;
      4) restart_all ;;
      0) echo "服务安全挂起，安全退出。"; exit 0 ;;
      *) echo "❌ 非法输入，请在限定指令域内输入" ;;
    esac
done
