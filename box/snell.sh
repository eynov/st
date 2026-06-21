#!/bin/bash

set -e

SNELL_DIR="/etc/snell"
SNELL_EXEC="/usr/local/bin/snell-server"

# ======================================
# 核心初始化与环境自愈
# ======================================

# 1. Root 权限检查
if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 用户运行此脚本"
    exit 1
fi

# 2. 自动化依赖自愈检查 (精准映射二进制命令与包名)
MISSING_PKGS=()
command -v wget >/dev/null 2>&1 || MISSING_PKGS+=("wget")
command -v python3 >/dev/null 2>&1 || MISSING_PKGS+=("python3")
command -v openssl >/dev/null 2>&1 || MISSING_PKGS+=("openssl")
command -v unzip >/dev/null 2>&1 || MISSING_PKGS+=("unzip")
command -v curl >/dev/null 2>&1 || MISSING_PKGS+=("curl")
command -v ip >/dev/null 2>&1 || MISSING_PKGS+=("iproute2")

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo ">> 检测到系统缺失必要依赖，正在自动安装更新: ${MISSING_PKGS[*]}..."
    apt update -y
    apt install -y "${MISSING_PKGS[@]}"
fi

# ======================================
# 安全与网络工具函数
# ======================================

# 带严谨超时控制的公网 IP 获取函数
get_public_ip() {
    local ip
    ip=$(curl -s4 -m 3 --connect-timeout 2 icanhazip.com || \
         curl -s -m 3 --connect-timeout 2 https://api.ipify.org || \
         curl -s -m 3 --connect-timeout 2 ipinfo.io/ip)
    if [ -z "$ip" ]; then
        ip="你的服务器公网IP"
    fi
    echo "$ip"
}

get_latest_version() {
    local fallback_version="6.0.0b3"
    local fallback_zip="snell-server-v6.0.0b3-linux-amd64.zip"

    local url="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"

    local page
    page=$(curl -fsSL -m 10 \
        -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
        "$url")

    if [ -z "$page" ]; then
        echo ">> KB不可访问" >&2
        echo "${fallback_version}|${fallback_zip}"
        return
    fi

    local latest_zip
    latest_zip=$(
        echo "$page" | \
        grep -oE 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+[a-z0-9.-]*-linux-amd64\.zip' | \
        sort -Vu | \
        tail -n 1
    )

    if [ -z "$latest_zip" ]; then
        echo ">> 解析失败" >&2
        echo "${fallback_version}|${fallback_zip}"
        return
    fi

    # 使用你写的高性能原生 Shell 字符串切片
    local version
    version=${latest_zip#snell-server-v}
    version=${version%-linux-amd64.zip}

    echo "${version}|${latest_zip}"
}


# 部署或更新主程序二进制
install_or_upgrade_binary() {
    local force_upgrade=$1
    if [ -f "$SNELL_EXEC" ] && [ "$force_upgrade" != "true" ]; then
        return
    fi

    echo ">> 正在从官方获取最新 Snell 版本信息..."
    local version_info
    version_info=$(get_latest_version)
    local version=$(echo "$version_info" | cut -d'|' -f1)
    local zip_name=$(echo "$version_info" | cut -d'|' -f2)
    local url="https://dl.nssurge.com/snell/${zip_name}"

    mkdir -p "${SNELL_DIR}"
    cd /tmp
    rm -f "${zip_name}"

    echo ">> 正在安全下载 Snell v${version}..."
    wget --tries=3 --timeout=20 -q --show-progress -O "${zip_name}" "${url}"

    if [ ! -s "${zip_name}" ]; then
        echo "[严重错误] Snell 下载 file 为空或下载失败，请检查网络！"
        exit 1
    fi

    python3 - <<EOF
import zipfile
zipfile.ZipFile("${zip_name}").extractall("/tmp")
EOF

    if [ ! -f "/tmp/snell-server" ]; then
        echo "[严重错误] Snell 解压验证失败"
        exit 1
    fi

    if [ -f "${SNELL_EXEC}" ]; then
        cp "${SNELL_EXEC}" "${SNELL_EXEC}.bak.$(date +%Y%m%d_%H%M%S)"
    fi

    mv /tmp/snell-server ${SNELL_EXEC}
    chmod +x ${SNELL_EXEC}
    rm -f "${zip_name}"
    echo ">> Snell 主程序核心部署/升级成功 (v${version})"
}

# 打印标准客户端配置模版
print_proxy_config() {
    local ip=$1
    local port=$2
    local psk=$3
    echo "Server : ${ip}"
    echo "Port   : ${port}"
    echo "PSK    : ${psk}"
    echo ""
    echo "[Proxy]"
    echo "node = snell,${ip},${port},psk=${psk},version=6,reuse=true"

    echo "------------------------------------------------"
}

# ======================================
# 菜单业务逻辑实现
# ======================================

# 1. 新增端口
add_ports() {
    install_or_upgrade_binary "false"
    
    echo ""
    read -p "请输入要创建的端口（多个请用空格分隔）: " PORTS
    echo ""

    local mem_mb
    mem_mb=$(free -m | awk '/Mem:/ {print $2}')
    local max_conn=$((mem_mb * 2))
    if [ "$max_conn" -lt 300 ]; then max_conn=300; fi
    if [ "$max_conn" -gt 10000 ]; then max_conn=10000; fi

    local valid_ports=()

    for PORT in ${PORTS}; do
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            echo "跳过无效端口: $PORT"
            continue
        fi

        local conf_file="${SNELL_DIR}/snell-server-${PORT}.conf"
        if [ -f "${conf_file}" ]; then
            echo "端口 ${PORT} 配置文件已存在，已自动跳过"
            continue
        fi

        if ss -lntup | grep -q ":${PORT}\b"; then
            echo "端口 ${PORT} 已被系统其他程序占用，自动跳过"
            continue
        fi

        local listen_ip ipv6_flag
        if ip -6 route show default 2>/dev/null | grep -q default; then
            listen_ip="0.0.0.0:${PORT},[::]:${PORT}"
            ipv6_flag="true"
        else
            listen_ip="0.0.0.0:${PORT}"
            ipv6_flag="false"
        fi

        local psk
        psk=$(openssl rand -hex 32)
        local service_file="/etc/systemd/system/snell-${PORT}.service"

        cat > "${conf_file}" <<EOF
[snell-server]
listen = ${listen_ip}
psk = ${psk}
version = 6
dns-ip-preference = auto
ipv6 = ${ipv6_flag}
udp-relay = true
max_conn = ${max_conn}
EOF

        cat > "${service_file}" <<EOF
[Unit]
Description=Snell Proxy Service on Port ${PORT}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SNELL_EXEC} -c ${conf_file}
Restart=always
RestartSec=3
LimitNOFILE=1048576

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF

        valid_ports+=("${PORT}")
    done

    if [ ${#valid_ports[@]} -eq 0 ]; then
        echo "没有合法的端口被创建。"
        return
    fi

    echo ">> 正在向系统提交重载并拉起实例服务..."
    systemctl daemon-reload

    local server_ip
    server_ip=$(get_public_ip)
    local success_count=0

    for PORT in "${valid_ports[@]}"; do
        systemctl enable snell-${PORT} >/dev/null 2>&1
        systemctl restart snell-${PORT}

        if ! systemctl is-active --quiet snell-${PORT}; then
            echo "----------------------------------------"
            echo "[严重错误] Snell 端口 ${PORT} 启动失败！已触发全自动回滚。"
            echo ">> 正在捕获实时错误堆栈日志 (journalctl):"
            echo "----------------------------------------"
            journalctl -u snell-${PORT} -n 20 --no-pager
            echo "----------------------------------------"
            
            rm -f "${SNELL_DIR}/snell-server-${PORT}.conf" "/etc/systemd/system/snell-${PORT}.service"
            systemctl daemon-reload
            continue
        fi
        
        local cur_psk
        cur_psk=$(grep -E '^psk =' "${SNELL_DIR}/snell-server-${PORT}.conf" | awk -F'= ' '{print $2}' | tr -d ' ')
        
        if [ $success_count -eq 0 ]; then
            echo -e "\n======================================\n 最终输出托管配置凭据\n======================================\n"
        fi
        print_proxy_config "${server_ip}" "${PORT}" "${cur_psk}"
        success_count=$((success_count + 1))
    done
    echo ">> 批量部署流程结束，成功拉起 ${success_count} 个实例。"
}

# 2. 删除端口
delete_ports() {
    local files=()
    for f in "${SNELL_DIR}"/snell-server-*.conf; do
        [ -e "$f" ] && files+=("$f")
    done

    if [ ${#files[@]} -eq 0 ]; then
        echo ">> 系统中未发现任何正在运行的 Snell 端口实例。"
        return
    fi

    echo "当前检测到已启用的 Snell 端口有:"
    for f in "${files[@]}"; do
        local p
        p=$(echo "$f" | sed -E 's/.*snell-server-(.*)\.conf/\1/')
        echo " - 端口: $p"
    done
    
    echo ""
    read -p "请输入你想彻底注销删除的端口（多个请用空格分隔）: " DEL_PORTS
    echo ""

    local count=0
    for PORT in ${DEL_PORTS}; do
        if [ -f "${SNELL_DIR}/snell-server-${PORT}.conf" ]; then
            systemctl stop snell-${PORT} >/dev/null 2>&1 || true
            systemctl disable snell-${PORT} >/dev/null 2>&1 || true
            rm -f "${SNELL_DIR}/snell-server-${PORT}.conf"
            rm -f "/etc/systemd/system/snell-${PORT}.service"
            systemctl reset-failed snell-${PORT} 2>/dev/null || true
            echo ">> 已彻底移除清理端口 ${PORT} 及其关联系统配置。"
            count=$((count + 1))
        else
            echo "跳过未注册的端口: ${PORT}"
        fi
    done

    if [ $count -gt 0 ]; then
        systemctl daemon-reload
    fi
}

# 3. 查看配置明细
view_config() {
    local files=()
    for f in "${SNELL_DIR}"/snell-server-*.conf; do
        [ -e "$f" ] && files+=("$f")
    done

    if [ ${#files[@]} -eq 0 ]; then
        echo ">> 系统中未发现任何 Snell 实例配置。"
        return
    fi

    for f in "${files[@]}"; do
        echo "======================================"
        echo " 配置文件明细: $f"
        echo "======================================"
        cat "$f"
        echo ""
    done
}

# 4. 查看托管凭据
view_credentials() {
    local files=()
    for f in "${SNELL_DIR}"/snell-server-*.conf; do
        [ -e "$f" ] && files+=("$f")
    done

    if [ ${#files[@]} -eq 0 ]; then
        echo ">> 系统中没有正在运行的 Snell 实例。"
        return
    fi

    local server_ip
    server_ip=$(get_public_ip)

    echo "======================================"
    echo " 运行中实例服务凭据（Surge/Rocket）"
    echo "======================================"
    echo ""
    for f in "${files[@]}"; do
        local port psk
        port=$(echo "$f" | sed -E 's/.*snell-server-(.*)\.conf/\1/')
        psk=$(grep -E '^psk =' "$f" | awk -F'= ' '{print $2}' | tr -d ' ')
        print_proxy_config "${server_ip}" "${port}" "${psk}"
    done
}

# 5. 重启实例
restart_instances() {
    local files=()
    for f in "${SNELL_DIR}"/snell-server-*.conf; do
        [ -e "$f" ] && files+=("$f")
    done

    if [ ${#files[@]} -eq 0 ]; then
        echo ">> 没有任何服务可供重启。"
        return
    fi

    echo "1. 重启所有运行中的 Snell 实例"
    echo "2. 精准重启某个特定端口实例"
    read -p "请选择操作 [1-2]: " choice
    if [ "$choice" = "1" ]; then
        for f in "${files[@]}"; do
            local port
            port=$(echo "$f" | sed -E 's/.*snell-server-(.*)\.conf/\1/')
            systemctl restart snell-${port}
            echo ">> 端口 ${port} 重启完成"
        done
    elif [ "$choice" = "2" ]; then
        read -p "请输入要重启的端口号: " r_port
        if [ -f "${SNELL_DIR}/snell-server-${r_port}.conf" ]; then
            systemctl restart snell-${r_port}
            echo ">> 端口 ${r_port} 重启成功。"
        else
            echo ">> 该端口实例不存在。"
        fi
    fi
}

# 6. 升级 Snell 核心二进制
upgrade_snell_binary() {
    if [ ! -f "$SNELL_EXEC" ]; then
        echo ">> 检测到系统尚未初装 Snell，正执行初次安装流程..."
        install_or_upgrade_binary "false"
        return
    fi
    
    echo ">> 正在强行检索并覆盖更新最新 Snell Core 二进制程序..."
    install_or_upgrade_binary "true"

    local files=()
    for f in "${SNELL_DIR}"/snell-server-*.conf; do
        [ -e "$f" ] && files+=("$f")
    done

    if [ ${#files[@]} -gt 0 ]; then
        echo ">> 正在滚动热重载唤醒系统所有存量 proxy 实例..."
        for f in "${files[@]}"; do
            local port
            port=$(echo "$f" | sed -E 's/.*snell-server-(.*)\.conf/\1/')
            systemctl restart snell-${port}
            
            if ! systemctl is-active --quiet snell-${port}; then
                echo "[错误] 升级后实例 ${port} 启动失败，请后续手动排查该实例日志！"
            else
                echo ">> 端口 ${port} 升级并恢复成功。"
            fi
        done
        echo ">> 存量实例滚动更新流程处理完毕。"
    fi
}

# 7. 实时巡检服务运行状态
view_service_status() {
    local files=()
    for f in "${SNELL_DIR}"/snell-server-*.conf; do
        [ -e "$f" ] && files+=("$f")
    done

    if [ ${#files[@]} -eq 0 ]; then
        echo ">> 系统中未发现任何活跃的 Snell 服务实例。"
        return
    fi

    echo "=================================================="
    echo "            Snell 实例运行状态全局仪表盘"
    echo "=================================================="
    printf "%-10s %-18s %-15s\n" "端口" "Systemd服务名" "当前运行状态"
    echo "--------------------------------------------------"
    
    for f in "${files[@]}"; do
        local port
        port=$(echo "$f" | sed -E 's/.*snell-server-(.*)\.conf/\1/')
        local status_str
        
        if systemctl is-active --quiet snell-${port}; then
            status_str="🟢 运行中 (Active)"
        else
            status_str="🔴 已停止 (Inactive)"
        fi
        printf "%-10s %-18s %-15s\n" "${port}" "snell-${port}" "${status_str}"
    done
    echo "=================================================="
    
    echo ""
    read -p "是否需要直接追溯某端口的实时底层日志？(输入端口号/直接回车跳过): " check_port
    if [[ "$check_port" =~ ^[0-9]+$ ]] && [ -f "${SNELL_DIR}/snell-server-${check_port}.conf" ]; then
        echo -e "\n---------------- [ 端口 ${check_port} 最近 20 行日志 ] ----------------"
        journalctl -u snell-${check_port} -n 20 --no-pager
        echo "------------------------------------------------------------------"
    fi
}

# ======================================
# 交互主循环菜单
# ======================================
while true; do
    echo "======================================"
    echo "   Snell v6 生产级多功能运维看板"
    echo "======================================"
    echo "  1. 新增端口实例"
    echo "  2. 删除端口实例"
    echo "  3. 查看底层配置明细"
    echo "  4. 查看客户端代理凭据 (PSK / Surge 格式)"
    echo "  5. 重启特定或全量实例"
    echo "  6. 检查并强制升级 Snell 主程序"
    echo "  7. 实时巡检服务运行状态 (Status)"
    echo "  0. 安全退出"
    echo "======================================"
    read -p "请输入您要执行的操作选项 [0-7]: " OPT
    case $OPT in
        1) add_ports ;;
        2) delete_ports ;;
        3) view_config ;;
        4) view_credentials ;;
        5) restart_instances ;;
        6) upgrade_snell_binary ;;
        7) view_service_status ;;
        0) echo "脚本安全退出。"; exit 0 ;;
        *) echo "无效指令，请在 0 到 7 之间重新输入！" ;;
    esac
    echo ""
done
