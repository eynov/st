#!/usr/bin/env bash
#
# zsh.sh - 一键安装 / 配置 Zsh + Oh My Zsh + Powerlevel10k 开发环境
#
# 特性:
#   - 幂等: 可重复执行，不会产生重复配置或重复 clone
#   - 跨平台: 兼容 Debian/Ubuntu、RedHat 系(dnf/yum)、macOS (Homebrew)
#   - 安全: set -Eeuo pipefail + 错误陷阱，出错立即定位
#
set -Eeuo pipefail

# ------------------------------------------------------------------
# 全局控制参数
# ------------------------------------------------------------------
# 是否开启插件/主题的自动更新（默认关闭，保持安装速度）
UPDATE_PLUGINS=${UPDATE_PLUGINS:-false}

# ------------------------------------------------------------------
# 全局变量
# ------------------------------------------------------------------
ZSHRC="$HOME/.zshrc"
ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
CUSTOM_PLUGINS="$ZSH_CUSTOM_DIR/plugins"
P10K_DIR="$ZSH_CUSTOM_DIR/themes/powerlevel10k"

# 需要合并进 plugins=(...) 的基础 Oh My Zsh 插件
# 移除 fzf-tab 与 fast-syntax-highlighting，它们改为在末尾手动严格顺序加载
REQUIRED_OMZ_PLUGINS=(zsh-autosuggestions zsh-completions)

# 需要 git clone 的插件与主题仓库
declare -A PLUGIN_REPOS=(
    [zsh-autosuggestions]="https://github.com/zsh-users/zsh-autosuggestions"
    [zsh-completions]="https://github.com/zsh-users/zsh-completions"
    [fast-syntax-highlighting]="https://github.com/zdharma-continuum/fast-syntax-highlighting"
    [fzf-tab]="https://github.com/Aloxaf/fzf-tab"
)

# 配置块标记（用于幂等地写入/更新 .zshrc）
INSTANT_PROMPT_BEGIN="# >>> zsh.sh instant-prompt begin >>>"
INSTANT_PROMPT_END="# <<< zsh.sh instant-prompt end <<<"
MAIN_BLOCK_BEGIN="# >>> zsh.sh begin >>>"
MAIN_BLOCK_END="# <<< zsh.sh end <<<"

# ------------------------------------------------------------------
# 基础工具函数
# ------------------------------------------------------------------
log() {
    local msg=$1
    local level=${2:-info}
    echo "[$level] $msg"
}

on_error() {
    local exit_code=$?
    log "脚本在第 $BASH_LINENO 行执行 \`$BASH_COMMAND\` 时失败 (exit=$exit_code)" "error"
    exit "$exit_code"
}
trap on_error ERR

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# 跨平台 sed -i 封装 (GNU sed / BSD sed 均可用)
sed_inplace() {
    local file=$1
    local expr=$2
    if sed --version >/dev/null 2>&1; then
        sed -i -e "$expr" "$file"
    else
        sed -i '' -e "$expr" "$file"
    fi
}

# 幂等克隆或更新仓库
sync_repo() {
    local dir=$1 url=$2 name=$3
    if [ -d "$dir" ]; then
        if [ "$UPDATE_PLUGINS" = "true" ]; then
            log "正在更新 $name..." "info"
            # 使用 || true 确保更新失败时不阻塞/中断整个安装流程
            git -C "$dir" pull --ff-only || log "$name 更新失败，跳过" "warn"
        else
            log "$name 已存在，跳过安装" "warn"
        fi
    else
        git clone --depth=1 "$url" "$dir"
        log "$name 安装完成" "info"
    fi
}

# ------------------------------------------------------------------
# 1. 安装 Zsh (增加 dnf 优先检测)
# ------------------------------------------------------------------
install_zsh() {
    if has_cmd zsh; then
        log "zsh 已安装" "warn"
        return
    fi
    log "检测到系统未安装 zsh，正在安装..." "info"
    
    if [ -f /etc/debian_version ]; then
        sudo apt-get update && sudo apt-get install -y zsh git curl
    elif has_cmd dnf; then
        log "检测到 dnf 包管理器，正在安装..." "info"
        sudo dnf install -y zsh git curl
    elif has_cmd yum; then
        log "检测到 yum 包管理器，正在安装..." "info"
        sudo yum install -y zsh git curl
    elif has_cmd brew; then
        brew install zsh git curl
    else
        log "无法识别包管理器，请手动安装 zsh、git、curl" "error"
        exit 1
    fi
}

# ------------------------------------------------------------------
# 2. 设置默认 Shell (防止 chsh 交互式失败中断脚本)
# ------------------------------------------------------------------
set_default_shell() {
    local zsh_bin
    zsh_bin="$(command -v zsh)"
    if [ "${SHELL:-}" != "$zsh_bin" ]; then
        log "将默认 shell 设置为 zsh..." "info"
        # 使用 if 包裹 chsh，防止用户在中途取消或权限拒绝时导致 set -e 直接中断脚本
        if ! chsh -s "$zsh_bin"; then
            log "请手动执行修改默认 Shell: chsh -s $zsh_bin" "warn"
        fi
    else
        log "默认 shell 已是 zsh" "warn"
    fi
}

# ------------------------------------------------------------------
# 3. 安装 Oh My Zsh，并确保 .zshrc 存在
# ------------------------------------------------------------------
ensure_zshrc_exists() {
    if [ -f "$ZSHRC" ]; then
        return
    fi
    if [ -f "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" ]; then
        log ".zshrc 不存在，从 Oh My Zsh 模板复制..." "info"
        cp "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" "$ZSHRC"
    else
        log ".zshrc 与模板均不存在，创建空文件" "warn"
        touch "$ZSHRC"
    fi
}

install_oh_my_zsh() {
    if [ -d "$HOME/.oh-my-zsh" ]; then
        log "Oh My Zsh 已存在" "warn"
        if [ "$UPDATE_PLUGINS" = "true" ]; then
            log "正在更新 Oh My Zsh..." "info"
            OMZ="$HOME/.oh-my-zsh" sh "$HOME/.oh-my-zsh/tools/upgrade.sh" --unattended || log "Oh My Zsh 更新失败，跳过" "warn"
        fi
    else
        log "安装 Oh My Zsh..." "info"
        RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    fi
    ensure_zshrc_exists
}

# ------------------------------------------------------------------
# 4. 安装 Zsh 插件 与 Powerlevel10k 主题
# ------------------------------------------------------------------
install_plugins() {
    mkdir -p "$CUSTOM_PLUGINS"
    for name in "${!PLUGIN_REPOS[@]}"; do
        sync_repo "$CUSTOM_PLUGINS/$name" "${PLUGIN_REPOS[$name]}" "$name"
    done
}

install_powerlevel10k() {
    sync_repo "$P10K_DIR" "https://github.com/romkatv/powerlevel10k.git" "powerlevel10k"
}

# ------------------------------------------------------------------
# 5. 安装 fzf
# ------------------------------------------------------------------
install_fzf() {
    if [ ! -d "$HOME/.fzf" ]; then
        log "安装 fzf..." "info"
        git clone --depth=1 https://github.com/junegunn/fzf.git "$HOME/.fzf"
    else
        if [ "$UPDATE_PLUGINS" = "true" ]; then
            log "正在更新 fzf..." "info"
            git -C "$HOME/.fzf" pull --ff-only || log "fzf 更新失败，跳过" "warn"
        else
            log "fzf 仓库已存在，跳过 clone" "warn"
        fi
    fi

    if [ -f "$HOME/.fzf.zsh" ] && [ "$UPDATE_PLUGINS" != "true" ]; then
        log "fzf 已配置 (~/.fzf.zsh 已存在)，跳过安装脚本" "warn"
        return
    fi

    "$HOME/.fzf/install" --key-bindings --completion --no-update-rc
}

# ------------------------------------------------------------------
# 6. 安装 zoxide (立刻将路径引入当前脚本的 PATH)
# ------------------------------------------------------------------
install_zoxide() {
    if has_cmd zoxide; then
        log "zoxide 已安装" "warn"
        return
    fi
    log "安装 zoxide..." "info"
    if has_cmd brew; then
        brew install zoxide
    else
        curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
    fi

    # 核心优化：确保当前脚本上下文环境能立即找到 zoxide
    if [ -d "$HOME/.local/bin" ]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
}

# ------------------------------------------------------------------
# 7. 配置 .zshrc (全量使用 awk/sed 增强健壮性)
# ------------------------------------------------------------------

strip_block() {
    local file=$1 begin=$2 end=$3
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { skip = 1; next }
        $0 == end   { skip = 0; next }
        skip == 0   { print }
    ' "$file"
}

upsert_block() {
    local file=$1 begin=$2 end=$3 content=$4 position=$5
    touch "$file"

    local stripped
    stripped=$(strip_block "$file" "$begin" "$end")

    local tmp
    tmp=$(mktemp)
    if [ "$position" = "top" ]; then
        {
            printf '%s\n' "$begin"
            printf '%s\n' "$content"
            printf '%s\n' "$end"
            printf '%s\n' "$stripped"
        } > "$tmp"
    else
        {
            printf '%s\n' "$stripped"
            printf '%s\n' "$begin"
            printf '%s\n' "$content"
            printf '%s\n' "$end"
        } > "$tmp"
    fi
    mv "$tmp" "$file"
}

# 7.1 精准设置主题 (使用 awk 精确匹配未注释的 ZSH_THEME)
configure_theme() {
    if awk '/^[[:space:]]*ZSH_THEME=/' "$ZSHRC" | grep -q .; then
        # 仅替换首个未被注释的有效配置行
        sed_inplace "$ZSHRC" '0,/^[[:space:]]*ZSH_THEME=.*/s//ZSH_THEME="powerlevel10k\/powerlevel10k"/'
    else
        echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> "$ZSHRC"
    fi
}

# 7.2 精准合并 plugins=(...) (剔除多余/被弃用的手动加载项)
configure_plugins() {
    # 核心优化：如果用户误把 fzf-tab 或 fast-syntax-highlighting 写进了原 plugins 中，将其剥离
    if awk '/^[[:space:]]*plugins=\(/' "$ZSHRC" | grep -q .; then
        # 提取当前有效的首个 plugins 行
        local existing_line existing_plugins merged=""
        existing_line=$(awk '/^[[:space:]]*plugins=\(/{print; exit}' "$ZSHRC")
        
        # 提取括号内部的值并剔除 fzf-tab / fast-syntax-highlighting 以防止多重复合加载
        existing_plugins=$(printf '%s' "$existing_line" | sed -e 's/^[[:space:]]*plugins=(//' -e 's/)[[:space:]]*$//' -e 's/fzf-tab//g' -e 's/fast-syntax-highlighting//g')
        merged="$existing_plugins"

        local p
        for p in "${REQUIRED_OMZ_PLUGINS[@]}"; do
            if [[ " $existing_plugins " != *" $p "* ]]; then
                merged="$merged $p"
            fi
        done
        # 清理连续多余空格
        merged=$(printf '%s' "$merged" | tr -s '[:space:]' ' ' | sed -e 's/^ *//' -e 's/ *$//')

        sed_inplace "$ZSHRC" "0,/^[[:space:]]*plugins=.*/s//plugins=($merged)/"
    else
        echo "plugins=(git ${REQUIRED_OMZ_PLUGINS[*]})" >> "$ZSHRC"
    fi
}

# 7.3 Powerlevel10k Instant Prompt
configure_instant_prompt() {
    local content
    content=$(cat <<'EOF'
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi
EOF
)
    upsert_block "$ZSHRC" "$INSTANT_PROMPT_BEGIN" "$INSTANT_PROMPT_END" "$content" "top"
}

# 7.4 尾部主配置块 (官方推荐的 2026 Zsh 最佳实践严格顺序加载)
configure_main_block() {
    local content
    content=$(cat <<'EOF'
# 确保 zoxide / fzf 等用户级安装 (~/.local/bin) 在 PATH 中
export PATH="$HOME/.local/bin:$PATH"

# 1. zoxide 初始化（在 compinit 之后、但在 fzf-tab 和高亮之前）
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh)"
fi

# 2. fzf 基础补全与快捷键绑定
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# 3. fzf-tab 插件加载（必须在 Oh My Zsh / compinit 之后，以及语法高亮之前）
if [ -f "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/fzf-tab/fzf-tab.plugin.zsh" ]; then
  source "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/fzf-tab/fzf-tab.plugin.zsh"
fi

# 4. Powerlevel10k 用户自定义配置
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# 5. fast-syntax-highlighting 必须在整个 `.zshrc` 的最后一行加载
if [ -f "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh" ]; then
  source "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh"
fi
EOF
)
    upsert_block "$ZSHRC" "$MAIN_BLOCK_BEGIN" "$MAIN_BLOCK_END" "$content" "bottom"
}

configure_zshrc() {
    log "配置 .zshrc..." "info"
    configure_theme
    configure_plugins
    configure_instant_prompt
    configure_main_block
}

# ------------------------------------------------------------------
# 主流程
# ------------------------------------------------------------------
main() {
    log "开始安装 Zsh 开发环境..." "info"

    install_zsh
    set_default_shell
    install_oh_my_zsh
    install_plugins
    install_powerlevel10k
    install_fzf
    install_zoxide
    configure_zshrc

    log "核心组件安装及配置完成！" "success"

    # 核心优化：检查 p10k 配置文件，若不存在则进行引导提示
    if [ ! -f "$HOME/.p10k.zsh" ]; then
        echo "--------------------------------------------------------"
        log "【提示】检测到尚未进行 Powerlevel10k 样式配置。" "warn"
        log "首次进入 Zsh 环境后，请手动执行以下命令以开始个性化配置：" "info"
        echo -e "\033[1;32m    p10k configure\033[0m"
        echo "--------------------------------------------------------"
    fi

    log "请重新登录终端或执行: zsh" "success"
}

main "$@"
