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

# ── 5. ⚙️ 高精度自动检测主命令 ─────────────────────────────
# 🌟 策略 A：优先在源码目录中寻找本身就具备可执行权限（-executable）的二进制或核心文件
AUTO_BIN=$(find "$SRC_DIR/$PROJECT" \
    -maxdepth 1 \
    -type f \
    -executable \
    ! -name "*.sh" \
    ! -name "*.py" \
    | sort | head -n1)

# 🌟 策略 B：如果没找到，则降级使用黑名单过滤，锁死所有的配置文件后缀（防止 .json 等篡位）
if [[ -z "$AUTO_BIN" ]]; then
    AUTO_BIN=$(find "$SRC_DIR/$PROJECT" \
        -maxdepth 1 \
        -type f \
        ! -name "*.sh" \
        ! -name "*.py" \
        ! -name "*.json" \
        ! -name "*.conf" \
        ! -name "*.tpl" \
        ! -name "*.base" \
        ! -name "*.txt" \
        ! -name "*.md" \
        ! -name "*.service" \
        ! -name "README*" \
        ! -name "LICENSE*" \
        ! -name ".*" \
        | sort | head -n1)
fi

# 🌟 策略 C：终极兜底，如果项目全是由 .sh 脚本构成，则排除掉安装器和编译器，精准推荐控制台主脚本
if [[ -z "$AUTO_BIN" ]]; then
    AUTO_BIN=$(find "$SRC_DIR/$PROJECT" \
        -maxdepth 1 \
        -type f \
        -name "*.sh" \
        ! -name "render.sh" \
        ! -name "install.sh" \
        | sort | head -n1)
fi

# 提取纯文件名
if [[ -n "$AUTO_BIN" ]]; then
    AUTO_BIN="${AUTO_BIN##*/}"
fi

if [[ -z "$MAIN_BIN" ]]; then
    if [[ -n "$AUTO_BIN" ]]; then
        read -rp "👉 检测到可能的主程序 [$AUTO_BIN]，请输入快捷命令名称（直接回车则默认使用该主程序，输入 - 留空跳过）: " MAIN_BIN
        [[ -z "$MAIN_BIN" ]] && MAIN_BIN="$AUTO_BIN"
    else
        read -rp "👉 未检测到主命令，输入快捷命令名称；留空则不创建命令: " MAIN_BIN
    fi
fi

# 输入 - 表示不创建快捷命令
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
    # 额外兼容：如果用户输入的快捷名没有写 .sh，但实际文件带 .sh，自动帮用户对齐
    if [[ ! "$MAIN_BIN" =~ \.sh$ && -e "$NEW_DIR/${MAIN_BIN}.sh" ]]; then
        MAIN_BIN="${MAIN_BIN}.sh"
    else
        echo "❌ 错误：在安装目录中未找到主程序文件：$MAIN_BIN" >&2
        rm -rf "$NEW_DIR"
        exit 1
    fi
fi

# 替换旧目录
rm -rf "$INSTALL_DIR"
mv "$NEW_DIR" "$INSTALL_DIR"

# ── 7. ⚡ 智能业务初始化向导（核心联动钩子）────────────────
if [[ -f "$INSTALL_DIR/install.sh" ]]; then
    echo "⚙️ 检测到项目 [$PROJECT] 包含专用的业务安装向导，正在激活初始化..."
    chmod +x "$INSTALL_DIR/install.sh"
    # 主动调用项目各自独有的 install.sh，把开启转发、补齐底层依赖、初次编译等工作闭环完成
    bash "$INSTALL_DIR/install.sh"
fi

# ── 8. 创建软链接 ─────────────────────────────────────────
if [[ -n "$MAIN_BIN" ]]; then
    # 让建立的软链接名称更简洁漂亮（如用户期望建立快捷命令为 fw，而不是带后缀的 fw.sh）
    LINK_NAME="${MAIN_BIN%.*}"
    # 如果用户显式输入了带后缀的（或者保留默认），则遵从原名，否则去掉后缀
    [[ "$MAIN_BIN" == "$AUTO_BIN" ]] && read -rp "👉 推荐快捷命令为 [ $LINK_NAME ]，确认请输入新名字（直接回车默认使用 $LINK_NAME）: " USER_CONFIRM_NAME
    
    FINAL_NAME="${USER_CONFIRM_NAME:-$LINK_NAME}"
    [[ -z "$FINAL_NAME" ]] && FINAL_NAME="$LINK_NAME"

    BIN_LINK="/usr/local/bin/$FINAL_NAME"

    echo "🔗 创建快捷命令 $BIN_LINK -> $MAIN_BIN ..."

    rm -f "$BIN_LINK"
    ln -s "$INSTALL_DIR/$MAIN_BIN" "$BIN_LINK"

    hash -r

    echo "🟢 恭喜！$PROJECT 安装成功！"
    echo "💡 现在你可以直接在终端输入 [ $FINAL_NAME ] 来运行它了。"
else
    echo "🟢 恭喜！$PROJECT 安装成功！"
    echo "📁 项目已安装到：$INSTALL_DIR"
    echo "ℹ️ 未创建全局快捷命令。"
fi
