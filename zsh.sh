#!/usr/bin/env bash
set -e

log() {
    local msg=$1
    local level=$2
    echo "[$level] $msg"
}

ZSHRC="$HOME/.zshrc"
CUSTOM_PLUGINS="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"
P10K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"

log "开始安装 Zsh 和插件..." "info"

# 1️⃣ 安装 Zsh
if ! command -v zsh &>/dev/null; then
    log "检测到系统未安装 zsh，正在安装..." "info"
    if [ -f /etc/debian_version ]; then
        sudo apt update && sudo apt install -y zsh git curl
    elif [ -f /etc/redhat-release ]; then
        sudo yum install -y zsh git curl
    elif command -v brew &>/dev/null; then
        brew install zsh git curl
    else
        log "请手动安装 zsh" "error"
        exit 1
    fi
else
    log "zsh 已安装" "warn"
fi

# 2️⃣ 设置默认 shell
if [ "$SHELL" != "$(which zsh)" ]; then
    log "将默认 shell 设置为 zsh..." "info"
    chsh -s "$(which zsh)" || log "请手动执行 chsh -s $(which zsh)" "warn"
fi

# 3️⃣ 安装 Oh My Zsh
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    log "安装 Oh My Zsh..." "info"
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
else
    log "Oh My Zsh 已存在" "warn"
fi

mkdir -p "$CUSTOM_PLUGINS"

# 4️⃣ 安装 Zsh 插件
declare -A plugins=(
    ["zsh-autosuggestions"]="https://github.com/zsh-users/zsh-autosuggestions"
    ["zsh-completions"]="https://github.com/zsh-users/zsh-completions"
    ["fast-syntax-highlighting"]="https://github.com/zdharma-continuum/fast-syntax-highlighting"
)

for plugin in "${!plugins[@]}"; do
    if [ ! -d "$CUSTOM_PLUGINS/$plugin" ]; then
        git clone --depth=1 "${plugins[$plugin]}" "$CUSTOM_PLUGINS/$plugin"
        log "插件 $plugin 安装完成" "info"
    else
        log "插件 $plugin 已存在，跳过安装" "warn"
    fi
done

# 5️⃣ 安装 fzf
if ! command -v fzf &>/dev/null; then
    log "安装 fzf..." "info"
    git clone --depth=1 https://github.com/junegunn/fzf.git ~/.fzf
    ~/.fzf/install --all
else
    log "fzf 已安装" "warn"
fi

# 6️⃣ 安装 zoxide
if ! command -v zoxide &>/dev/null; then
    log "安装 zoxide..." "info"
    if [ -f /etc/debian_version ]; then
        sudo apt install -y zoxide
    elif [ -f /etc/redhat-release ]; then
        sudo yum install -y zoxide
    elif command -v brew &>/dev/null; then
        brew install zoxide
    else
        log "请手动安装 zoxide: https://github.com/ajeetdsouza/zoxide" "error"
    fi
else
    log "zoxide 已安装" "warn"
fi

# 7️⃣ 安装 Powerlevel10k 主题
if [ ! -d "$P10K_DIR" ]; then
    log "安装 powerlevel10k 主题..." "info"
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
else
    log "powerlevel10k 已存在，跳过安装" "warn"
fi

# 8️⃣ 配置 .zshrc
log "配置 .zshrc..." "info"

# 设置主题
if grep -q '^ZSH_THEME=' "$ZSHRC"; then
    sed -i.bak 's/^ZSH_THEME=.*/ZSH_THEME="powerlevel10k\/powerlevel10k"/' "$ZSHRC"
else
    echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> "$ZSHRC"
fi

# 设置插件
PLUGINS_LINE='plugins=(git zsh-autosuggestions zsh-completions fast-syntax-highlighting fzf)'
if grep -q '^plugins=' "$ZSHRC"; then
    sed -i.bak "s/^plugins=.*/$PLUGINS_LINE/" "$ZSHRC"
else
    echo "$PLUGINS_LINE" >> "$ZSHRC"
fi

# zoxide 初始化
if ! grep -q "eval \"\$(zoxide init zsh)\"" "$ZSHRC"; then
    echo 'eval "$(zoxide init zsh)"' >> "$ZSHRC"
fi

# 加载 Powerlevel10k instant prompt
if ! grep -q "p10k-instant-prompt" "$ZSHRC"; then
    echo 'if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then' >> "$ZSHRC"
    echo '  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"' >> "$ZSHRC"
    echo 'fi' >> "$ZSHRC"
fi

# 加载 Oh My Zsh
if ! grep -q "oh-my-zsh.sh" "$ZSHRC"; then
    echo 'export ZSH="$HOME/.oh-my-zsh"' >> "$ZSHRC"
    echo 'source $ZSH/oh-my-zsh.sh' >> "$ZSHRC"
fi

# fast-syntax-highlighting 必须最后加载
if ! grep -q "fast-syntax-highlighting.plugin.zsh" "$ZSHRC"; then
    echo "source ${ZSH_CUSTOM:-\$HOME/.oh-my-zsh/custom}/plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh" >> "$ZSHRC"
fi

# fzf 加载
if ! grep -q "\~/.fzf.zsh" "$ZSHRC"; then
    echo '[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh' >> "$ZSHRC"
fi

# Powerlevel10k 配置文件
if [ -f "$HOME/.p10k.zsh" ]; then
    if ! grep -q ".p10k.zsh" "$ZSHRC"; then
        echo '[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh' >> "$ZSHRC"
    fi
fi

log "安装完成，请重新登录或执行: zsh" "success"