#!/bin/bash
# vps.sh - ST 脚本面板
# 仓库: https://github.com/eynov/st

REPO_URL="https://raw.githubusercontent.com/eynov/st/main"

WORKDIR="/tmp/st-panel"
mkdir -p "$WORKDIR"

download_script() {
    local script=$1
    local url="$REPO_URL/$script"
    local path="$WORKDIR/$script"

    echo "[*] 下载 $script ..."
    if curl -fsSL "$url" -o "$path"; then
        chmod +x "$path"
        echo "[*] 运行 $script"
        bash "$path"
    else
        echo "[!] 下载失败: $url"
        sleep 2
    fi
}

while true; do
    clear
    echo "==================="
    echo "    VPS 面板工具"
    echo "==================="
    echo "1) 域名管理 (domain.sh)"
    echo "2) DNS 管理 (dns.sh)"
    echo "3) 防火墙管理 (nft.sh)"
    echo "4) Zsh 配置 (zsh.sh)"
    echo "0) 退出"
    echo "==================="
    read -rp "请选择功能: " choice

    case $choice in
        1) download_script "domain.sh" ;;
        2) download_script "dns.sh" ;;
        3) download_script "nft.sh" ;;
        4) download_script "zsh.sh" ;;
        0) echo "退出面板"; exit 0 ;;
        *) echo "无效选择，请重试"; sleep 1 ;;
    esac
done
