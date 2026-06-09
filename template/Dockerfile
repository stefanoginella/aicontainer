# =============================================================================
# aicontainer — base image for Claude Code + Codex in bypass mode
# =============================================================================
# Build inside a project's .devcontainer/ via `aic up` (which runs `devcontainer
# up` and reads docker-compose.yml). Image is rebuilt by CI weekly so AI CLI
# versions stay current.
# =============================================================================

FROM ghcr.io/astral-sh/uv:0.11@sha256:b46b03ddfcfbf8f547af7e9eaefdf8a39c8cebcba7c98858d3162bd28cf536f6 AS uv
FROM mcr.microsoft.com/devcontainers/base:ubuntu24.04@sha256:405175cbb232701dc27c47a2f178da555ea3ad20f85ea4142ad6a24f877af399

# OCI labels: lets GitHub auto-link the GHCR package back to this repo.
LABEL org.opencontainers.image.source="https://github.com/stefanoginella/aicontainer" \
      org.opencontainers.image.description="Sandboxed devcontainer for running Claude Code and Codex in bypass / auto-approve mode." \
      org.opencontainers.image.licenses="MIT"

ARG TZ
ENV TZ="$TZ"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---------------------------------------------------------------------------
# System packages (base image already ships git, curl, sudo, etc.)
# ---------------------------------------------------------------------------
# openssh-client provides ssh-keygen, which Git invokes for SSH commit signing
# (gpg.format=ssh: sign via `ssh-keygen -Y sign`, verify via `-Y verify`) and
# which `aic signing` uses to mint the sandbox signing key. Required even just
# to *sign*, not only to generate — so make the dependency explicit here rather
# than relying on the base image happening to include it.
RUN apt-get update && apt-get install -y --no-install-recommends \
      fd-find \
      ripgrep \
      tmux \
      zsh \
      bash \
      fish \
      build-essential \
      jq \
      nano \
      unzip \
      vim \
      dnsutils \
      iproute2 \
      iptables \
      ipset \
      openssh-client \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# git-delta
# renovate: datasource=github-releases depName=dandavison/delta
ARG GIT_DELTA_VERSION=0.19.2
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" -o /tmp/git-delta.deb && \
    dpkg -i /tmp/git-delta.deb && \
    rm /tmp/git-delta.deb

# uv (Python package manager)
COPY --from=uv /uv /usr/local/bin/uv

# fzf (GitHub release is newer than apt and includes shell integration)
# renovate: datasource=github-releases depName=junegunn/fzf
ARG FZF_VERSION=0.73.1
RUN ARCH=$(dpkg --print-architecture) && \
    case "${ARCH}" in \
      amd64) FZF_ARCH="linux_amd64" ;; \
      arm64) FZF_ARCH="linux_arm64" ;; \
      *) echo "Unsupported architecture: ${ARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-${FZF_ARCH}.tar.gz" | tar -xz -C /usr/local/bin

# GitHub CLI (used by AI for PR/issue work; user logs in inside the container)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI (talks to socket-proxy via DOCKER_HOST=tcp://socket-proxy:2375)
RUN curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu noble stable" \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Persistent directories and ownership
# ---------------------------------------------------------------------------
RUN mkdir -p /workspace \
             /home/vscode/.claude \
             /home/vscode/.codex \
             /home/vscode/.config/opencode \
             /home/vscode/.local/share/opencode \
             /home/vscode/.semgrep \
             /home/vscode/.config/gh \
             /home/vscode/.config/npm \
             /home/vscode/.config/aic-auth \
             /home/vscode/.claude-sessions \
             /home/vscode/.shell-history \
             /opt \
    && chown -R vscode:vscode /workspace /home/vscode/.claude /home/vscode/.codex /home/vscode/.config/opencode /home/vscode/.local /home/vscode/.semgrep /home/vscode/.config /home/vscode/.config/aic-auth /home/vscode/.claude-sessions /home/vscode/.shell-history /opt

ENV DEVCONTAINER=true
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

WORKDIR /workspace

# Scoped sudoers: every entry is a wrapper with hardcoded targets, so the
# grant cannot be turned into arbitrary chown / file write. aic-firewall is
# enable-only; aic-chown-volumes touches three known volume paths;
# aic-lock-gitconfig locks one known file. A bare `chown` here would let AI
# `chown vscode /etc/sudoers.d/vscode` and escalate to root.
RUN echo 'vscode ALL=(ALL) NOPASSWD: /usr/local/bin/aic-chown-volumes, /usr/local/bin/aic-lock-gitconfig, /usr/local/bin/aic-firewall' > /etc/sudoers.d/vscode \
    && chmod 0440 /etc/sudoers.d/vscode

# Privileged helper scripts. All root-owned and only callable via the scoped
# sudoers entry above. aic-firewall is enable-only; aic-chown-volumes and
# aic-lock-gitconfig operate on hardcoded paths.
COPY aic-firewall aic-chown-volumes aic-lock-gitconfig /usr/local/bin/
RUN chmod 0755 /usr/local/bin/aic-firewall \
                /usr/local/bin/aic-chown-volumes \
                /usr/local/bin/aic-lock-gitconfig \
    && chown root:root /usr/local/bin/aic-firewall \
                       /usr/local/bin/aic-chown-volumes \
                       /usr/local/bin/aic-lock-gitconfig

# ---------------------------------------------------------------------------
# Hooks: root-owned, not writable by vscode (self-defense)
# ---------------------------------------------------------------------------
COPY hooks/ /etc/aic/hooks/
RUN chmod 755 /etc/aic/hooks /etc/aic /etc/aic/hooks/*.sh \
    && chmod 644 /etc/aic/hooks/*.json /etc/aic/hooks/*.js \
    && chown -R root:root /etc/aic

# ---------------------------------------------------------------------------
# Codex managed hook (wires the shared PreToolUse guardrail into Codex)
# ---------------------------------------------------------------------------
# Codex command hooks are trust-gated: a hook defined in ~/.codex/config.toml is
# "non-managed", starts untrusted, and is SKIPPED until reviewed via `/hooks` —
# which never happens in autonomous bypass mode. The only way the hook actually
# fires for Codex is as a "managed" hook in the system requirements.toml
# (/etc/codex/requirements.toml), which is auto-trusted and can't be disabled by
# the in-container user. `[features].hooks = true` enforces the hook capability.
# Codex's event JSON (.tool_name / .tool_input.command, exit 2 = block) matches
# what pre-tool-use.sh already parses; we match the Bash tool, through which
# Codex runs shell and reads files (`cat`), so the .env-read and curl|sh checks
# apply. Root-owned + 0644 so the agent can't edit or disable it.
# (NOTE: a prior version wrote a `[hooks] pre_tool_use = "..."` scalar into
# config.toml — wrong schema AND non-managed, so it never ran for Codex.)
RUN mkdir -p /etc/codex && cat > /etc/codex/requirements.toml <<'CODEX_REQ_EOF'
# Managed by aicontainer — baked into the image, do not edit. Forces the shared
# PreToolUse guardrail to run for Codex without an interactive trust prompt.
[features]
hooks = true

[[hooks.PreToolUse]]
matcher = "^Bash$"

[[hooks.PreToolUse.hooks]]
type = "command"
command = "/etc/aic/hooks/pre-tool-use.sh"
timeout = 30
statusMessage = "aicontainer guardrail"
CODEX_REQ_EOF
RUN chmod 0644 /etc/codex/requirements.toml \
    && chown root:root /etc/codex/requirements.toml

# ---------------------------------------------------------------------------
# Lifecycle script
# ---------------------------------------------------------------------------
COPY post-create.py /opt/post-create.py
RUN chmod 0755 /opt/post-create.py

USER vscode

ENV PATH="/home/vscode/.local/bin:/home/vscode/.opencode/bin:$PATH"
# Build-time mirror of devcontainer.json's containerEnv: skip npm lifecycle
# scripts for any `npm install`/`npx` (MCP servers, a downstream
# Dockerfile.project). Codex is no longer an npm package — it installs via the
# official standalone installer below, alongside Claude Code.
ENV NPM_CONFIG_IGNORE_SCRIPTS=true

# Claude Code + Codex + OpenCode: official standalone installers. Claude/Codex
# land in ~/.local/bin, OpenCode in ~/.opencode/bin (both already on PATH above).
# These are the baseline "floor" baked into the image; post-create.py's
# refresh_ai_tools() floats all three to the latest release on every container
# (re)create, so `aic rebuild` always lands current AI CLIs. The Claude/Codex
# installers skip editing the login-shell rc files (root-locked at runtime by
# aic-lock-gitconfig) because ~/.local/bin is already on PATH; OpenCode's
# installer is told not to touch them with --no-modify-path (zsh-in-docker owns
# the rc files and we set PATH explicitly above + in each rc below).
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && claude --version
RUN curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh \
    && codex --version
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path \
    && opencode --version

# Python toolchain (per-user; survives image rebuilds via base layer caching)
RUN uv python install 3.13 --default

# Node LTS via fnm (per-user; lets projects override with their own version)
# renovate: datasource=node-version depName=node
ARG NODE_VERSION=24
ENV FNM_DIR="/home/vscode/.fnm"
RUN curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$FNM_DIR" --skip-shell \
    && export PATH="$FNM_DIR:$PATH" \
    && eval "$(fnm env)" \
    && fnm install ${NODE_VERSION} \
    && fnm default ${NODE_VERSION}

# Semgrep (used by Claude Code's semgrep plugin; installed into ~/.local/bin
# via uv tool so the binary is on PATH for the vscode user). Auth (settings.yml)
# is symlinked to the global aic-auth volume by post-create.py.
RUN uv tool install semgrep \
    && semgrep --version

# oh-my-zsh + powerlevel10k + plugins
# renovate: datasource=github-releases depName=deluan/zsh-in-docker
ARG ZSH_IN_DOCKER_VERSION=1.2.1
RUN sh -c "$(curl -fsSL https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
      -t https://github.com/romkatv/powerlevel10k \
      -p git \
      -p fzf \
      -p https://github.com/zsh-users/zsh-autosuggestions \
      -p https://github.com/zsh-users/zsh-syntax-highlighting \
      -a 'export HISTFILE=/home/vscode/.shell-history/.zsh_history' \
      -a 'export HISTSIZE=50000' \
      -a 'export SAVEHIST=50000' \
      -a 'setopt SHARE_HISTORY' \
      -a 'export PATH="$FNM_DIR:$PATH"' \
      -a 'eval "$(fnm env --use-on-cd)"' \
      -a '[[ -s ~/.p10k.zsh ]] && source ~/.p10k.zsh' \
      -a '[[ -s ~/.zshrc.local ]] && source ~/.zshrc.local' \
      -x

# Container-tailored zshrc additions are baked into ~/.zshrc above by
# zsh-in-docker's `-a` flag. We keep template/.zshrc in the repo for reference
# and as a single source of truth that contributors can edit.
COPY --chown=vscode:vscode .zshrc /home/vscode/.zshrc.aic

# ---------------------------------------------------------------------------
# Bash + fish: minimal parity with the zsh setup for users who pick
# AIC_SHELL=bash|fish via `aic init`. Bash gets persistent history (shared
# volume with zsh) and fnm on PATH; fish gets fnm on PATH. Theming
# (oh-my-zsh + powerlevel10k) is zsh-only — bash/fish stay barebones, with a
# ~/.bashrc.local / ~/.config/fish/config.local.fish opt-in so users can layer
# their own config without rebuilding the image.
# ---------------------------------------------------------------------------
RUN cat >> /home/vscode/.bashrc <<'BASHRC_EOF'

# aicontainer additions
export HISTFILE=/home/vscode/.shell-history/.bash_history
export HISTSIZE=50000
export HISTFILESIZE=50000
shopt -s histappend
export PATH="$FNM_DIR:$PATH"
eval "$(fnm env --use-on-cd)"
[ -f ~/.bashrc.local ] && . ~/.bashrc.local
BASHRC_EOF

RUN mkdir -p /home/vscode/.config/fish \
    && cat > /home/vscode/.config/fish/config.fish <<'FISH_EOF'
# aicontainer fish config (baked at image build; see template/Dockerfile)
set -gx FNM_DIR /home/vscode/.fnm
fish_add_path $FNM_DIR
fnm env --use-on-cd | source
if test -f ~/.config/fish/config.local.fish
    source ~/.config/fish/config.local.fish
end
FISH_EOF
