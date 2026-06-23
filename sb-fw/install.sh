#!/bin/bash
# --- install.sh ---

if [[ $EUID -ne 0 ]]; then
   echo "❌ 请以 root 权限运行此脚本"
   exit 1
fi

# 🔹 动态获取安装脚本当前所在的绝对路径
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "⚙️ 正在安装核心依赖组件 (nftables, jq, dnsutils)..."
apt-get update && apt-get install -y nftables jq dnsutils curl > /dev/null

echo "🔐 正在授予脚本执行权限..."
chmod +x "$BASE_DIR/fw.sh"
chmod +x "$BASE_DIR/render.sh"

echo "🚀 正在建立全局系统快捷调用命令 'fw'..."
rm -f /usr/local/bin/fw
ln -s "$BASE_DIR/fw.sh" /usr/local/bin/fw

echo "⚡ 正在执行初次规则编译..."
bash "$BASE_DIR/render.sh"

echo "---------------------------------------------"
echo "✅ SB-FW 架构动态初始化已全部完成！"
echo "👉 现在你可以在系统的任意路径下输入: [ fw ] 唤起面板"
echo "---------------------------------------------"
