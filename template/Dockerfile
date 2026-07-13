# =============================================================================
# aicontainer — base image for Claude Code + Codex + OpenCode in bypass mode
# =============================================================================
# Build inside a project's .devcontainer/ via `aic up` (which runs `devcontainer
# up` and reads docker-compose.yml). Image is rebuilt by CI weekly so AI CLI
# versions stay current.
# =============================================================================

FROM ghcr.io/astral-sh/uv:0.11@sha256:0f36cb9361a3346885ca3677e3767016687b5a170c1a6b88465ec14aefec90aa AS uv
FROM mcr.microsoft.com/devcontainers/base:ubuntu24.04@sha256:c5cc2b45afe06a1df3aba17e58ba0dc4a02b999493198dab37dd0ccd4e2b0705

# OCI labels: lets GitHub auto-link the GHCR package back to this repo.
LABEL org.opencontainers.image.source="https://github.com/stefanoginella/aicontainer" \
      org.opencontainers.image.description="Sandboxed devcontainer for running Claude Code, Codex, and OpenCode in bypass / auto-approve mode." \
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
      python3-minimal \
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
ARG FZF_VERSION=0.74.0
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
# `.aic-sessions` is the tool-neutral, per-project state root. Each tool keeps
# its complete home below `tool-homes/`; the separate auth bridge shares only
# the four explicitly allowlisted credential JSON files between projects.
RUN mkdir -p /workspace \
             /project-sessions \
             /home/vscode/.aic-sessions/tool-homes/claude \
             /home/vscode/.aic-sessions/tool-homes/codex \
             /home/vscode/.aic-sessions/tool-homes/opencode-config \
             /home/vscode/.aic-sessions/tool-homes/opencode-data \
             /home/vscode/.semgrep \
             /home/vscode/.config/gh \
             /home/vscode/.config/npm \
             /home/vscode/.config/aic-auth/signing \
             /home/vscode/.config/aic-auth/semgrep \
             /home/vscode/.local/share \
             /home/vscode/.shell-history \
             /opt \
    && ln -s /home/vscode/.aic-sessions/tool-homes/claude /home/vscode/.claude \
    && ln -s /home/vscode/.aic-sessions/tool-homes/codex /home/vscode/.codex \
    && ln -s /home/vscode/.aic-sessions/tool-homes/opencode-config /home/vscode/.config/opencode \
    && ln -s /home/vscode/.aic-sessions/tool-homes/opencode-data /home/vscode/.local/share/opencode \
    && chown -R vscode:vscode /workspace /project-sessions /home/vscode/.local /home/vscode/.semgrep /home/vscode/.config /home/vscode/.config/aic-auth /home/vscode/.aic-sessions /home/vscode/.shell-history /opt \
    && chmod 0700 /project-sessions /home/vscode/.aic-sessions /home/vscode/.aic-sessions/tool-homes /home/vscode/.aic-sessions/tool-homes/* \
    && chown -h vscode:vscode /home/vscode/.claude /home/vscode/.codex /home/vscode/.config/opencode /home/vscode/.local/share/opencode

# Reserved root-helper namespace. The host Docker socket is mounted read-only at
# the nested path by Compose; vscode cannot traverse this directory, while the
# fixed aic-chown-volumes helper can perform narrowly scoped GET validation.
RUN install -d -o root -g root -m 0700 /run/aic-host

ENV DEVCONTAINER=true
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano
# The host p10k config is intentionally not sourced inside the sandbox. Avoid
# an interactive first-shell wizard while keeping the managed theme defaults.
ENV POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true

WORKDIR /workspace

# Scoped sudoers: every entry is a wrapper with hardcoded targets, so the
# grant cannot be turned into arbitrary chown / file write. aic-firewall is
# strengthen-only; aic-chown-volumes validates exact named-volume mountpoints;
# aic-lock-gitconfig installs one fixed config. A bare `chown` here would let AI
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

# Claude Code and OpenCode both support root-owned managed settings on Linux.
# Put the autonomous-mode defaults and the shared guardrail registration there,
# at higher precedence than user/project config. post-create still writes the
# allowlisted user preferences for compatibility, but an unrestricted process
# can no longer persistently remove either tool's guardrail by editing $HOME.
RUN mkdir -p /etc/claude-code /etc/opencode \
    && jq '. + {"permissions":{"defaultMode":"bypassPermissions"},"skipDangerousModePermissionPrompt":true}' /etc/aic/hooks/claude-settings.json > /etc/claude-code/managed-settings.json \
    && jq -n '{"$schema":"https://opencode.ai/config.json","permission":{"*":"allow"},"plugin":["/etc/aic/hooks/opencode-guardrail.js"]}' > /etc/opencode/opencode.json \
    && chmod 0644 /etc/claude-code/managed-settings.json /etc/opencode/opencode.json \
    && chown -R root:root /etc/claude-code /etc/opencode

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
allow_managed_hooks_only = true
allowed_approval_policies = ["never"]
# Codex 0.144+ requires `read-only` to be present whenever any permission
# profile is allowed. The generated user config still selects
# `danger-full-access`; including the inert fallback here satisfies the managed
# requirements schema without adding a prompt or changing the default mode.
allowed_sandbox_modes = ["read-only", "danger-full-access"]

[features]
hooks = true

[hooks]
managed_dir = "/etc/aic/hooks"

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
# tomli-w is a hash-pinned, image-baked dependency. post-create adds this fixed
# root-owned target to sys.path, so container creation never resolves or fetches
# Python packages at runtime (and still works offline from the baked floor).
RUN printf '%s\n' \
      'tomli-w==1.2.0 --hash=sha256:188306098d013b691fcadc011abd66727d3c414c571bb01b1a174ba8c983cf90' \
      > /tmp/aic-python-requirements.txt \
    && uv pip install --target /opt/aic-python \
      --python-version 3.13 \
      --require-hashes \
      --only-binary :all: \
      --requirement /tmp/aic-python-requirements.txt \
    && rm -f /tmp/aic-python-requirements.txt \
    && chmod -R a-w /opt/aic-python \
    && chown -R root:root /opt/aic-python /opt/post-create.py \
    && chmod 0755 /opt/post-create.py

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
# installers skip editing login-shell rc files because ~/.local/bin is already
# on PATH; OpenCode's
# installer is told not to touch them with --no-modify-path (zsh-in-docker owns
# the rc files and we set PATH explicitly above + in each rc below).
# `claude --version` may create one-time migration state. Do not bake that
# machine identity into every project; runtime state belongs in the
# per-project CLAUDE_CONFIG_DIR.
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && claude --version \
    && rm -f /home/vscode/.claude.json \
    && rm -rf /home/vscode/.aic-sessions/tool-homes/claude/backups
# Keep the standalone package separate from CODEX_HOME: ~/.codex is a
# per-project config/session home, while this rootfs path is the refreshable
# executable floor. `refresh_ai_tools()` supplies the same installer variables.
RUN curl -fsSL https://chatgpt.com/codex/install.sh \
      | CODEX_NON_INTERACTIVE=1 \
        CODEX_HOME=/home/vscode/.local/share/aic-tools/codex \
        CODEX_INSTALL_DIR=/home/vscode/.local/bin sh \
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
# via uv tool so the binary is on PATH for the vscode user). Its settings path
# is configured directly inside the persistent global auth volume.
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
      -x

# Keep a root-owned reference copy alongside the generated managed startup file.
COPY .zshrc /etc/aic/shell/zshrc.reference

# ---------------------------------------------------------------------------
# Bash + fish: minimal parity with the zsh setup for users who pick
# AIC_SHELL=bash|fish via `aic init`. Bash gets persistent history (shared
# volume with zsh) and fnm on PATH; fish gets fnm on PATH. Managed startup
# files live under root-owned system directories, not replaceable files in a
# vscode-owned $HOME. Host rc/p10k code is deliberately never sourced.
# ---------------------------------------------------------------------------
USER root

RUN install -d -o root -g root -m 0755 \
      /etc/aic/shell/zsh /etc/aic/shell /etc/aic/user-config \
    && mv /home/vscode/.zshrc /etc/aic/shell/zsh/.zshrc \
    && cp /home/vscode/.bashrc /etc/aic/shell/bashrc \
    && rm -f /home/vscode/.bashrc \
    && cat >> /etc/aic/shell/bashrc <<'BASHRC_EOF'

# aicontainer additions
export HISTFILE=/home/vscode/.shell-history/.bash_history
export HISTSIZE=50000
export HISTFILESIZE=50000
shopt -s histappend
export PATH="$FNM_DIR:$PATH"
eval "$(fnm env --use-on-cd)"
BASHRC_EOF

RUN cat > /etc/profile.d/aic-bash.sh <<'PROFILE_EOF'
# Managed aicontainer Bash startup for login shells.
if [ -n "${BASH_VERSION:-}" ] && [[ $- == *i* ]]; then
  . /etc/aic/shell/bashrc
fi
PROFILE_EOF

RUN mkdir -p /etc/fish/conf.d \
    && cat > /etc/fish/conf.d/aic.fish <<'FISH_EOF'
# Managed aicontainer fish config (baked at image build)
set -gx FNM_DIR /home/vscode/.fnm
set -gx PATH $FNM_DIR $PATH
fnm env --use-on-cd | source
FISH_EOF

RUN cat > /etc/aic/gitignore <<'GITIGNORE_EOF'
# aicontainer global excludes
.claude/
.codex/
node_modules/
.venv/
__pycache__/
.DS_Store
*.pyc
.env
.env.local
.env.*.local
GITIGNORE_EOF

RUN chown -R root:root /etc/aic/shell /etc/aic/user-config \
                       /etc/profile.d/aic-bash.sh /etc/fish/conf.d/aic.fish \
                       /etc/aic/gitignore \
    && chmod 0755 /etc/aic/shell /etc/aic/shell/zsh /etc/aic/user-config \
    && chmod 0444 /etc/aic/shell/zsh/.zshrc /etc/aic/shell/zshrc.reference \
                  /etc/aic/shell/bashrc /etc/profile.d/aic-bash.sh \
                  /etc/fish/conf.d/aic.fish /etc/aic/gitignore

ENV ZDOTDIR=/etc/aic/shell/zsh

USER vscode
