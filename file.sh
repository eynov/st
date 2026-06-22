#!/usr/bin/env bash
set -euo pipefail

REPO="eynov/st"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

read -rp "请输入项目名称: " PROJECT

INSTALL_DIR="/opt/$PROJECT"

echo "📦 下载脚本..."
curl -fSL --retry 3 --retry-delay 2 \
  "https://github.com/$REPO/archive/refs/heads/main.tar.gz" \
  -o "$TMP_DIR/archive.tar.gz"

echo "📂 解压..."
tar -xzf "$TMP_DIR/archive.tar.gz" -C "$TMP_DIR"

SRC_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "st-*" | head -n 1)

if [[ -z "${SRC_DIR:-}" || ! -d "$SRC_DIR/$PROJECT" ]]; then
    echo "❌ 项目 '$PROJECT' 不存在或不支持部署"
    exit 1
fi

echo "🚀 安装 $PROJECT..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -a "$SRC_DIR/$PROJECT/." "$INSTALL_DIR/"

echo "🔧 设置权限..."
find "$INSTALL_DIR" -type f -name "*.sh" -exec chmod +x {} \;

echo "🔍 检测可执行文件..."
MAIN_BIN=$(find "$INSTALL_DIR" -maxdepth 1 -type f ! -name "*.sh" ! -name ".*" | head -n 1 | xargs basename 2>/dev/null)

if [[ -z "$MAIN_BIN" ]]; then
    echo "❌ 未找到可执行文件"
    exit 1
fi

chmod +x "$INSTALL_DIR/$MAIN_BIN"
BIN_LINK="/usr/local/bin/$MAIN_BIN"

echo "🔗 创建软链接 $MAIN_BIN..."
ln -sf "$INSTALL_DIR/$MAIN_BIN" "$BIN_LINK"

hash -r

echo "🟢 $PROJECT 安装完成，命令：$MAIN_BIN"
