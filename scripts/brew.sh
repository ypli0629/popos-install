#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/utils.sh"

check_sudo

log_section "Homebrew"

if command -v brew &>/dev/null; then
    log_info "Homebrew 已安装，跳过"
else
    NONINTERACTIVE=1 /bin/bash -c "$(gh_curl https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# /etc/profile.d/：login shell 通用（终端、SSH 等）
if [[ ! -f /etc/profile.d/linuxbrew.sh ]]; then
    echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' \
        | sudo tee /etc/profile.d/linuxbrew.sh > /dev/null
    sudo chmod +x /etc/profile.d/linuxbrew.sh
    log_success "已写入 /etc/profile.d/linuxbrew.sh"
else
    log_info "/etc/profile.d/linuxbrew.sh 已存在，跳过"
fi

# ~/.zshrc：non-login interactive shell（GNOME Terminal 默认不是 login shell）
append_zshrc_once '# linuxbrew shellenv' '# linuxbrew shellenv
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'

BREW_BIN="/home/linuxbrew/.linuxbrew/bin/brew"
if [[ -x "$BREW_BIN" ]]; then
    eval "$($BREW_BIN shellenv)"
else
    log_error "brew 可执行文件未找到：$BREW_BIN" fatal
fi

log_section "Homebrew 软件包"
# 字体 cask 失败不应阻断后续开发工具安装
brew install --cask font-sauce-code-pro-nerd-font \
    || record_failure "SauceCodePro Nerd Font"
brew install gcc go rustup node pnpm yarn neovim bear fzf mycli \
    lazydocker jq mkcert xh \
    || record_failure "brew 软件包（部分失败，可手动重试）"

log_success "brew 完成"
