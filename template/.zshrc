# Managed aicontainer zsh startup. The image installs this file root-owned at
# /etc/aic/shell/zsh/.zshrc (ZDOTDIR), so an in-container agent cannot edit it.
#
# Startup runs only root-owned code. oh-my-zsh, powerlevel10k, the plugins and
# fnm are root-owned; the framework loads with a system-only PATH and a
# root-owned cache directory; the managed .zshenv beside this file skips the
# global zshrc, which runs PATH-resolved commands. Commands typed after startup
# resolve through the full PATH, which starts with vscode-owned tool
# directories (README "Threat model").

export LANG='en_US.UTF-8'
export LANGUAGE='en_US:en'
export LC_ALL='en_US.UTF-8'
[[ -n ${TERM-} ]] || export TERM=xterm

typeset -g _aic_path=$PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# oh-my-zsh and powerlevel10k keep caches under XDG_CACHE_HOME and source some
# of them again at startup (the p10k dump, the oh-my-zsh completions dir).
# While they load, XDG_CACHE_HOME names a root-owned directory; it is a shell
# variable only (not exported unless it already was), restored below.
(( ! ${+XDG_CACHE_HOME} )) || typeset -g _aic_xdg_cache=$XDG_CACHE_HOME
XDG_CACHE_HOME=/usr/local/share/aic/zsh-cache

export ZSH=/usr/local/share/oh-my-zsh
ZSH_CUSTOM=$ZSH/custom
ZSH_CACHE_DIR=$XDG_CACHE_HOME/oh-my-zsh
DISABLE_AUTO_UPDATE=true
zstyle ':omz:update' mode disabled
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git fzf zsh-autosuggestions zsh-syntax-highlighting)
source "$ZSH/oh-my-zsh.sh"

PATH=$_aic_path
if (( ${+_aic_xdg_cache} )); then
  XDG_CACHE_HOME=$_aic_xdg_cache
else
  unset XDG_CACHE_HOME
fi
unset _aic_path _aic_xdg_cache

# Shell history → persistent global volume (shared across all aicontainer
# projects on this host).
export HISTFILE=/home/vscode/.shell-history/.zsh_history
export HISTSIZE=50000
export SAVEHIST=50000
setopt SHARE_HISTORY

# fnm (node version manager). The binary is root-owned; Node versions stay in
# the vscode-owned $FNM_DIR so `fnm install` works. The function keeps fnm's
# cd hook on the root-owned binary, not on an fnm earlier in PATH.
fnm() { /usr/local/bin/fnm "$@" }
eval "$(/usr/local/bin/fnm env --use-on-cd --shell zsh)"

# VS Code terminals open commit messages in the editor. This replaces the base
# image's global zshrc snippet, which this shell does not read.
if [[ -z ${GIT_EDITOR-} && ${TERM_PROGRAM-} == vscode ]] \
    && [[ -z "$(/usr/bin/git config --get core.editor 2>/dev/null)" ]]; then
  if (( ${+commands[code]} )); then
    export GIT_EDITOR='code --wait'
  elif (( ${+commands[code-insiders]} )); then
    export GIT_EDITOR='code-insiders --wait'
  fi
fi

# Personal-config overlay (opt-in). These files are installed root-owned 0444 by
# aic-lock-user-config from the trusted human's config — a project-owned
# .devcontainer/{p10k.zsh,shell-rc.zsh} or the host ~/.config/aicontainer/. They
# are sourced LAST so a personal prompt/aliases win over the managed baseline;
# an in-container agent cannot tamper with them. Raw host shell code is never
# auto-forwarded.
[[ ! -r /etc/aic/user-config/shell/p10k.zsh ]] || source /etc/aic/user-config/shell/p10k.zsh
[[ ! -r /etc/aic/user-config/shell/rc.zsh ]] || source /etc/aic/user-config/shell/rc.zsh
