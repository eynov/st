#!/bin/bash
# --- install.sh (命令名自动跟随主脚本文件名，改名无需改代码) ---

if [[ $EUID -ne 0 ]]; then
   echo "❌ 请以 root 权限运行此脚本"
   exit 1
fi

# 🔹 动态获取安装脚本当前所在的绝对路径
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 🔹 自动定位主脚本（排除 install.sh 和 render.sh，取剩下的第一个 .sh 文件）
MAIN_SCRIPT=$(find "$BASE_DIR" -maxdepth 1 -type f -name "*.sh" \
    ! -name "install.sh" ! -name "render.sh" | sort | head -n1)

if [[ -z "$MAIN_SCRIPT" ]]; then
    echo "❌ 错误：未找到主脚本文件（排除 install.sh / render.sh 后没有其他 .sh 文件）"
    exit 1
fi

# 🔹 命令名 = 主脚本文件名去掉 .sh 后缀，完全跟随文件/项目命名，无需手动指定
CMD_NAME="$(basename "$MAIN_SCRIPT" .sh)"

echo "⚙️ 正在安装核心依赖组件 (nftables, jq, dnsutils)..."
apt-get update && apt-get install -y nftables jq dnsutils curl > /dev/null

echo "🔐 正在授予脚本执行权限..."
chmod +x "$MAIN_SCRIPT"
[ -f "$BASE_DIR/render.sh" ] && chmod +x "$BASE_DIR/render.sh"

echo "🚀 正在建立全局系统快捷调用命令 '$CMD_NAME'..."
rm -f "/usr/local/bin/$CMD_NAME"
ln -s "$MAIN_SCRIPT" "/usr/local/bin/$CMD_NAME"
hash -r

echo "⚡ 正在执行初次规则编译..."
bash "$BASE_DIR/render.sh"

echo "---------------------------------------------"
echo "✅ 架构动态初始化已全部完成！"
echo "👉 现在你可以在系统的任意路径下输入: [ $CMD_NAME ] 唤起面板"
echo "---------------------------------------------"
