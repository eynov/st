#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/etc/sing-box"
BIN_LINK="/usr/local/bin/sb"
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "$TMP_DIR"' EXIT

echo "📦 下载 sing-box 脚本..."
curl -fSL --retry 3 --retry-delay 2 \
  https://github.com/eynov/st/archive/refs/heads/main.tar.gz \
  -o "$TMP_DIR/st.tar.gz"

echo "📂 解压..."
tar -xzf "$TMP_DIR/st.tar.gz" -C "$TMP_DIR"

echo "🚀 安装文件..."

SRC_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "st-*" | head -n 1)

if [[ -z "${SRC_DIR:-}" || ! -d "$SRC_DIR/sing-box" ]]; then
    echo "❌ 解压结构异常：未找到 sing-box 目录"
    exit 1
fi

rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

cp -a "$SRC_DIR/sing-box/." "$INSTALL_DIR/"

echo "🔧 设置权限..."
chmod +x "$INSTALL_DIR/sb"
find "$INSTALL_DIR" -type f -name "*.sh" -exec chmod +x {} \;

echo "🔗 创建软链接..."
ln -sf "$INSTALL_DIR/sb" "$BIN_LINK"

hash -r

echo "🟢 sing-box 安装完成：sb"