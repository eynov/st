#!/usr/bin/env bash
# vps.sh - 仓库文件面板（支持快捷键 p 启动）

REPO_USER="eynov"
REPO_NAME="st"
BRANCH="main"
REPO_URL="https://github.com/$REPO_USER/$REPO_NAME/tree/$BRANCH"
RAW_BASE="https://raw.githubusercontent.com/$REPO_USER/$REPO_NAME/$BRANCH"

# --- 添加快捷键 p ---
ZSHRC="$HOME/.zshrc"
BASHRC="$HOME/.bashrc"
SHORTCUT="alias p='bash $HOME/vps.sh'"

if ! grep -Fxq "$SHORTCUT" "$ZSHRC" 2>/dev/null; then
    echo "$SHORTCUT" >> "$ZSHRC"
    echo "[*] 已将快捷键 'p' 添加到 ~/.zshrc"
    source "$ZSHRC"  # 立即生效
fi

if [ -f "$BASHRC" ] && ! grep -Fxq "$SHORTCUT" "$BASHRC" 2>/dev/null; then
    echo "$SHORTCUT" >> "$BASHRC"
    echo "[*] 已将快捷键 'p' 添加到 ~/.bashrc"
    source "$BASHRC"  # 立即生效
fi

# --- 获取仓库文件列表（只保留 .sh 和 .py 文件，去重） ---
FILES=($(curl -s "$REPO_URL" \
    | grep -o 'title="[^"]*"' \
    | awk -F'"' '{print $2}' \
    | grep -E '\.(sh|py)$' \
    | sort -u))

if [ ${#FILES[@]} -eq 0 ]; then
    echo "未获取到文件，请检查仓库 URL 或网络"
    exit 1
fi

# --- 面板主循环 ---
while true; do
    echo "======================================"
    echo "      仓库文件面板 (vps.sh)"
    echo "======================================"
    for i in "${!FILES[@]}"; do
        echo "$((i+1))) ${FILES[i]}"
    done
    echo "0) 退出"
    echo "======================================"
    read -rp "输入编号选择文件: " choice

    if [[ "$choice" == "0" ]]; then
        echo "退出面板"
        exit 0
    fi

    ((choice--))
    if [[ "$choice" -lt 0 || "$choice" -ge ${#FILES[@]} ]]; then
        echo "无效编号，请重新选择"
        continue
    fi

    FILE="${FILES[choice]}"
    RAW_URL="$RAW_BASE/$FILE"
    TMP_FILE="/tmp/$FILE"

    echo "正在下载并执行: $FILE ..."
    curl -s "$RAW_URL" -o "$TMP_FILE"
    chmod +x "$TMP_FILE"
    # 判断文件后缀执行方式
EXT="${FILE##*.}"
if [[ "$EXT" == "sh" ]]; then
    bash "$TMP_FILE"
elif [[ "$EXT" == "py" ]]; then
    python3 "$TMP_FILE"
else
    echo "[!] 不支持的文件类型: $EXT"
fi

    echo "======================================"
    read -rp "按回车返回菜单..." _
done
