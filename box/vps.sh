#!/usr/bin/env bash
# vps.sh - 仓库文件面板（支持快捷键 p 启动）

REPO_USER="eynov"
REPO_NAME="st"
BRANCH="main"
DIR_PATH="box"

# 使用 GitHub 官方 API 接口，规避网页改版风险
API_URL="https://api.github.com/repos/$REPO_USER/$REPO_NAME/contents/$DIR_PATH?ref=$BRANCH"
RAW_BASE="https://raw.githubusercontent.com/$REPO_USER/$REPO_NAME/$BRANCH/$DIR_PATH"

# --- 添加快捷键 p ---
ZSHRC="$HOME/.zshrc"
BASHRC="$HOME/.bashrc"
SHORTCUT="alias p='bash $HOME/vps.sh'"
NEED_RELOAD=0

if ! grep -Fxq "$SHORTCUT" "$ZSHRC" 2>/dev/null; then
    echo "$SHORTCUT" >> "$ZSHRC"
    echo "[*] 已将快捷键 'p' 添加到 ~/.zshrc"
    NEED_RELOAD=1
fi

if [ -f "$BASHRC" ] && ! grep -Fxq "$SHORTCUT" "$BASHRC" 2>/dev/null; then
    echo "$SHORTCUT" >> "$BASHRC"
    echo "[*] 已将快捷键 'p' 添加到 ~/.bashrc"
    NEED_RELOAD=1
fi

# 优雅提示用户手动 reload
if [ "$NEED_RELOAD" -eq 1 ]; then
    echo -e "\n\033[33m[*] 快捷键 'p' 已写入配置，请执行以下命令使其在当前终端立即生效：\033[0m"
    echo -e "\033[32msource ~/.zshrc 2>/dev/null || source ~/.bashrc\033[0m\n"
fi

# --- 获取仓库文件列表（通过 API 解析 JSON 里的 name） ---
echo "正在从云端获取脚本列表..."
FILES=($(curl -s "$API_URL" \
    | grep -o '"name": "[^"]*"' \
    | awk -F'"' '{print $4}' \
    | grep -E '\.(sh|py)$' \
    | sort -u))

if [ ${#FILES[@]} -eq 0 ]; then
    echo "[!] 未获取到文件。请检查仓库路径是否正确，或是否触发了 GitHub API 的请求频率限制。"
    exit 1
fi

# --- 面板主循环 ---
while true; do
    clear # 每次返回菜单时清屏，让界面更整洁
    echo "======================================"
    echo "      仓库文件面板 (vps.sh)"
    echo "======================================"
    for i in "${!FILES[@]}"; do
        # 使用 printf 让编号对齐（比如 9) 和 10) 对齐）
        printf "%2d) %s\n" "$((i+1))" "${FILES[i]}"
    done
    echo " 0) 退出"
    echo "======================================"
    read -rp "输入编号选择文件: " choice

    if [[ "$choice" == "0" ]]; then
        echo "退出面板"
        exit 0
    fi

    ((choice--))
    if [[ "$choice" -lt 0 || "$choice" -ge ${#FILES[@]} ]]; then
        echo "无效编号，请重新选择"
        read -rp "按回车继续..." _
        continue
    fi

    FILE="${FILES[choice]}"
    RAW_URL="$RAW_BASE/$FILE"
    TMP_FILE="/tmp/$FILE"

    echo "--------------------------------------"
    echo "正在下载并执行: $FILE ..."
    
    if curl -s "$RAW_URL" -o "$TMP_FILE"; then
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
        
        # 执行完毕后，及时删除临时文件
        rm -f "$TMP_FILE"
    else
        echo "[!] 下载失败，请检查网络连接。"
    fi

    echo "======================================"
    read -rp "按回车返回菜单..." _
done
