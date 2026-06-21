set -euo pipefail

INSTALL_DIR="/etc/sing-box"
BIN_LINK="/usr/local/bin/sb"
TMP_DIR="$(mktemp -d)"

trap 'rm -rf "$TMP_DIR"' EXIT

echo "📦 下载 sing-box 脚本..."

curl -fsSL \
  https://github.com/eynov/st/archive/refs/heads/main.tar.gz \
  -o "$TMP_DIR/st.tar.gz"

echo "📂 解压..."

tar -xzf "$TMP_DIR/st.tar.gz" -C "$TMP_DIR"

echo "🚀 安装文件..."

mkdir -p "$INSTALL_DIR"

cp -a "$TMP_DIR/st-main/sing-box/." "$INSTALL_DIR/"

echo "🔧 设置权限..."

find "$INSTALL_DIR" -type f -name "*.sh" -exec chmod +x {} \;
chmod +x "$INSTALL_DIR/sb"

echo "🔗 创建软链接..."

ln -sf "$INSTALL_DIR/sb" "$BIN_LINK"

hash -r

echo "🟢 sing-box 安装完成：sb"