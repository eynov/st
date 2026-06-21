#!/bin/bash
# sing-box 核心资产与系统依赖编译维护环境

source /etc/sing-box/core/common.sh

check_and_install_core() {
    echo "🔄 正在核验 sing-box 核心资产与依赖链..."
    apt-get update && apt-get install -y curl jq tar gzip openssl wget qrencode >/dev/null 2>&1
    
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
