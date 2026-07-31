#!/bin/bash
# install.sh —— 安装 fwctl
#
# 命令名自动跟随主脚本文件名，改名不需要改代码。

set -u

if [[ $EUID -ne 0 ]]; then
   echo "❌ 请以 root 权限运行此脚本"
   exit 1
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 自动定位主脚本：排除 install.sh 与 render.sh，取剩下的第一个 .sh。
# core/ 位于第二层，不会被 maxdepth 1 选中。
MAIN_SCRIPT=$(find "$BASE_DIR" -maxdepth 1 -type f -name "*.sh" \
    ! -name "install.sh" ! -name "render.sh" | sort | head -n1)

if [[ -z "$MAIN_SCRIPT" ]]; then
    echo "❌ 错误：未找到主脚本文件（排除 install.sh / render.sh 后没有其他 .sh 文件）"
    exit 1
fi

if [[ ! -d "$BASE_DIR/core" ]]; then
    echo "❌ 错误：缺少 core/ 目录，安装包不完整"
    exit 1
fi

CMD_NAME="$(basename "$MAIN_SCRIPT" .sh)"

echo "⚙️ 正在安装核心依赖组件 (nftables, jq, dnsutils)..."
if ! apt-get update && apt-get install -y nftables jq dnsutils curl > /dev/null; then
    echo "❌ 依赖安装失败"
    exit 1
fi

echo "🔐 正在授予脚本执行权限..."
chmod +x "$MAIN_SCRIPT"
[ -f "$BASE_DIR/render.sh" ] && chmod +x "$BASE_DIR/render.sh"

echo "🚀 正在建立全局系统快捷调用命令 '$CMD_NAME'..."
rm -f "/usr/local/bin/$CMD_NAME"
ln -s "$MAIN_SCRIPT" "/usr/local/bin/$CMD_NAME"
hash -r

echo "⚡ 正在执行初次规则编译..."
# 编译失败必须让安装失败：一次「安装成功但规则没加载」的提示会让人以为防火墙
# 已经生效。
if ! bash "$MAIN_SCRIPT" render; then
    echo "---------------------------------------------"
    echo "❌ 初次编译失败，规则未加载。"
    echo "   命令 '$CMD_NAME' 已安装，可用 '$CMD_NAME doctor' 排查后重试。"
    echo "---------------------------------------------"
    exit 1
fi

echo "---------------------------------------------"
echo "✅ 安装完成"
echo "👉 现在可以在任意路径输入: [ $CMD_NAME ] 唤起面板"
echo "👉 建议先执行一次: $CMD_NAME doctor"
echo "---------------------------------------------"
