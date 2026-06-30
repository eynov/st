#!/bin/bash
# ==============================================================================
# 安装器：sing-box 核心安装 / 升级 + 目录初始化
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/core/common.sh"

check_and_install_core() {
    echo "🔄 正在核验 sing-box 核心资产与依赖链..."
    apt-get update -qq
    apt-get install -y curl jq tar gzip openssl wget qrencode >/dev/null 2>&1

    # 初始化目录结构
    ensure_dirs

    # 注册快捷命令 sb
    if [ ! -L "/usr/local/bin/sb" ]; then
        chmod +x "${BASE_DIR}/sb"
        ln -sf "${BASE_DIR}/sb" /usr/local/bin/sb
        ok "快捷命令 'sb' 已注册至 /usr/local/bin/sb"
    fi

    # 获取上游最新版本
    local http_code latest_ver
    http_code=$(curl -s -o /tmp/sb_release.json -w "%{http_code}" \
        https://api.github.com/repos/SagerNet/sing-box/releases/latest)
    latest_ver="1.11.0"  # 离线 fallback

    if [ "$http_code" = "200" ] && jq -e .tag_name /tmp/sb_release.json >/dev/null 2>&1; then
        latest_ver=$(jq -r .tag_name /tmp/sb_release.json | sed 's/^v//')
    fi
    rm -f /tmp/sb_release.json

    # 版本比对
    if [ -f "$SB_BIN" ]; then
        local current_ver
        current_ver=$($SB_BIN version 2>/dev/null | awk '{print $3}' | sed 's/^v//')
        if dpkg --compare-versions "$current_ver" ge "$latest_ver" 2>/dev/null; then
            ok "sing-box 已是最新版本 v${current_ver}，跳过安装。"
            return
        fi
        echo "🔄 检测到上游新版本 v${latest_ver}，正在升级..."
    fi

    # 架构映射
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="linux-amd64" ;;
        aarch64) arch="linux-arm64" ;;
        *)
            err "不支持的 CPU 架构: ${arch}"
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
