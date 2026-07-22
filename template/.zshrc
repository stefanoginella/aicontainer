# Reference copy of the container's .zshrc.
#
# The actual ~/.zshrc inside the container is generated at image build time by
# zsh-in-docker (see template/Dockerfile). Edits here do not propagate into a
# running container unless the image is rebuilt — keep this file in sync with
# the `-a` flags in the Dockerfile so contributors have one source to read.

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git fzf zsh-autosuggestions zsh-syntax-highlighting)
source "$ZSH/oh-my-zsh.sh"

# Shell history → persistent global volume (shared across all aicontainer
# projects on this host).
export HISTFILE=/home/vscode/.shell-history/.zsh_history
export HISTSIZE=50000
export SAVEHIST=50000
setopt SHARE_HISTORY

# fnm (node version manager) — exposes node/npm/npx/codex from the
# fnm-managed Node installed at image build time.
export PATH="$FNM_DIR:$PATH"
eval "$(fnm env --use-on-cd)"

# Personal-config overlay (opt-in). These files are installed root-owned 0444 by
# aic-lock-user-config from the trusted human's config — a project-owned
# .devcontainer/{p10k.zsh,shell-rc.zsh} or the host ~/.config/aicontainer/. They
# are sourced LAST so a personal prompt/aliases win over the managed baseline;
# an in-container agent cannot tamper with them. Raw host shell code is never
# auto-forwarded.
[[ ! -r /etc/aic/user-config/shell/p10k.zsh ]] || source /etc/aic/user-config/shell/p10k.zsh
[[ ! -r /etc/aic/user-config/shell/rc.zsh ]] || source /etc/aic/user-config/shell/rc.zsh
