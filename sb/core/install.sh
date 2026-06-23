#!/bin/bash
# ==============================================================================
# sing-box 核心资产安装 / 升级 + 快捷命令 sb 软链接注册
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/core/common.sh"

check_and_install_core() {
    echo "🔄 正在核验 sing-box 核心资产与依赖链..."
    apt-get update -qq && apt-get install -y curl jq tar gzip openssl wget qrencode >/dev/null 2>&1

    # 注册快捷命令 sb（软链接到 main.sh）
    if [ ! -L "/usr/local/bin/sb" ]; then
        chmod +x "${BASE_DIR}/main"
        ln -sf "${BASE_DIR}/main" /usr/local/bin/sb
        ok "快捷命令 'sb' 已注册至 /usr/local/bin/sb"
    fi

    # 获取上游最新版本
    local http_code latest_ver
    http_code=$(curl -s -o /tmp/sb.json -w "%{http_code}" \
        https://api.github.com/repos/SagerNet/sing-box/releases/latest)
    latest_ver="1.11.0"  # 离线 fallback

    if [ "$http_code" == "200" ] && jq -e .tag_name /tmp/sb.json >/dev/null 2>&1; then
        latest_ver=$(jq -r .tag_name /tmp/sb.json | sed 's/^v//')
    fi
    rm -f /tmp/sb.json

    # 版本比对
    if [ -f "$SB_BIN" ]; then
        local current_ver
        current_ver=$($SB_BIN version 2>/dev/null | awk '{print $3}' | sed 's/^v//')
        if command -v dpkg >/dev/null 2>&1; then
            if dpkg --compare-versions "$current_ver" ge "$latest_ver" 2>/dev/null; then
                ok "sing-box 已是最新版本 v${current_ver}，跳过安装。"
                return
            fi
        else
            # 非 Debian 系：直接用字符串比对
            if [ "$current_ver" == "$latest_ver" ]; then
                ok "sing-box 已是最新版本 v${current_ver}，跳过安装。"
                return
            fi
        fi
        echo "🔄 检测到上游新版本 v${latest_ver}，正在下发平滑升级..."
    fi

    # 架构映射
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="linux-amd64" ;;
        aarch64) arch="linux-arm64" ;;
        *)
            err "架构不兼容：不支持的 CPU 架构 ${arch}"
            exit 1
            ;;
    esac

    wget -q -O /tmp/sing-box.tar.gz \
        "https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box-${latest_ver}-${arch}.tar.gz"
    mkdir -p /tmp/sb_extracted
    tar -zxf /tmp/sing-box.tar.gz -C /tmp/sb_extracted --strip-components=1
    mv /tmp/sb_extracted/sing-box "$SB_BIN"
    chmod +x "$SB_BIN"
    rm -rf /tmp/sing-box* /tmp/sb_extracted

    ok "sing-box 核心引擎已同步至 v${latest_ver}"
}
