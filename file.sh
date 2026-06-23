#!/usr/bin/env bash
set -euo pipefail

# ── 1. 权限检查 ──────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "❌ 错误：此脚本需要 root 权限，请使用 sudo 运行。" >&2
    exit 1
fi

REPO="eynov/st"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── 2. 下载解压 ──────────────────────────────────────────
echo "📦 正在从 GitHub 下载最新源码..."
curl -fSsL --retry 3 --retry-delay 2 \
  "https://github.com/$REPO/archive/refs/heads/main.tar.gz" \
  -o "$TMP_DIR/archive.tar.gz"

tar -xzf "$TMP_DIR/archive.tar.gz" -C "$TMP_DIR"

SRC_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "st-*" | head -n 1)

if [[ -z "$SRC_DIR" ]]; then
    echo "❌ 错误：未找到解压后的源码目录" >&2
    exit 1
fi

# ── 3. 列出可安装项目 ────────────────────────────────────
printf '\n📋 可安装项目列表：\n'
echo "------------------------"
find "$SRC_DIR" \
  -mindepth 1 -maxdepth 1 \
  -type d \
  ! -name "docs" \
  ! -name ".github" \
  -exec basename {} \;
echo "------------------------"

# ── 4. 参数或交互输入 ────────────────────────────────────
PROJECT="${1:-}"
MAIN_BIN="${2:-}"

[[ -n "$PROJECT" ]] || read -rp "👉 请输入项目名称: " PROJECT
[[ -z "$PROJECT" ]] && { echo "❌ 错误：项目名称不能为空"; exit 1; }

if [[ ! -d "$SRC_DIR/$PROJECT" ]]; then
    echo "❌ 错误：项目 '$PROJECT' 不存在或不支持部署" >&2
    exit 1
fi

# ── 5. 自动检测主命令，可留空表示不创建快捷命令 ─────────────
AUTO_BIN=$(find "$SRC_DIR/$PROJECT" \
    -maxdepth 1 \
    -type f \
    ! -name "*.sh" \
    ! -name "*.py" \
    ! -name "*.txt" \
    ! -name "*.md" \
    ! -name "*.service" \
    ! -name "README*" \
    ! -name "LICENSE*" \
    ! -name ".*" \
    | sort | head -n1)

AUTO_BIN="${AUTO_BIN##*/}"

if [[ -z "$MAIN_BIN" ]]; then
    if [[ -n "$AUTO_BIN" ]]; then
        read -rp "👉 检测到可能的主程序 [$AUTO_BIN]，请输入快捷命令名称；留空则不创建命令: " MAIN_BIN
    else
        read -rp "👉 未检测到主命令，输入快捷命令名称；留空则不创建命令: " MAIN_BIN
    fi
fi

# 输入 - 也表示不创建快捷命令
if [[ "$MAIN_BIN" == "-" ]]; then
    MAIN_BIN=""
fi

# ── 6. 安装（安全原子替换）───────────────────────────────
INSTALL_DIR="/opt/$PROJECT"
NEW_DIR="${INSTALL_DIR}.new"

echo "🚀 开始安装 $PROJECT 到 $INSTALL_DIR ..."
rm -rf "$NEW_DIR"
mkdir -p "$NEW_DIR"

# 复制文件并保持属性
cp -a "$SRC_DIR/$PROJECT/." "$NEW_DIR/"

# 确保常规文件具有执行权限
find "$NEW_DIR" -type f -exec chmod +x {} \;

# 如果指定了快捷命令，则验证主程序文件是否存在
if [[ -n "$MAIN_BIN" && ! -e "$NEW_DIR/$MAIN_BIN" ]]; then
    echo "❌ 错误：在安装目录中未找到主程序文件：$MAIN_BIN" >&2
    rm -rf "$NEW_DIR"
    exit 1
fi

# 替换旧目录
rm -rf "$INSTALL_DIR"
mv "$NEW_DIR" "$INSTALL_DIR"

# ── 7. 创建软链接，可跳过 ─────────────────────────────────
if [[ -n "$MAIN_BIN" ]]; then
    BIN_LINK="/usr/local/bin/$MAIN_BIN"

    echo "🔗 创建快捷命令 $BIN_LINK ..."

    # 防御性规避 ln -sf 遇到“历史遗留目录”的边缘坑：先 rm -rf 再 ln -s
    rm -rf "$BIN_LINK"
    ln -s "$INSTALL_DIR/$MAIN_BIN" "$BIN_LINK"

    # 刷新 Bash 命令哈希表
    hash -r

    echo "🟢 恭喜！$PROJECT 安装成功！"
    echo "💡 现在你可以直接在终端输入 [ $MAIN_BIN ] 来运行它了。"
else
    echo "🟢 恭喜！$PROJECT 安装成功！"
    echo "📁 项目已安装到：$INSTALL_DIR"
    echo "ℹ️ 未创建快捷命令。"
fi