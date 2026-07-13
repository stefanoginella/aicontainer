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

# Host shell startup code is deliberately not forwarded into the sandbox. This
# managed baseline lives under /etc/aic/shell in the built image.
