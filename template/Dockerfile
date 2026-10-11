# =============================================================================
# aicontainer — base image for Claude Code + Codex + OpenCode in bypass mode
# =============================================================================
# Build inside a project's .devcontainer/ via `aic up` (which runs `devcontainer
# up` and reads docker-compose.yml). Image is rebuilt by CI weekly so AI CLI
# versions stay current.
# =============================================================================

FROM ghcr.io/astral-sh/uv:0.12@sha256:61d393e44e249f2e4b526b6c7ddcecce245946826e608e11c93ad4f5bba55b21 AS uv
FROM mcr.microsoft.com/devcontainers/base:ubuntu24.04@sha256:d7c468679f45a52ad3673d06656b5bf16e488990b17216a1fa295d9e1f89d724

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
ARG GIT_DELTA_VERSION=0.20.1
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" -o /tmp/git-delta.deb && \
    dpkg -i /tmp/git-delta.deb && \
    rm /tmp/git-delta.deb

# uv (Python package manager)
COPY --from=uv /uv /usr/local/bin/uv

# fzf (GitHub release is newer than apt and includes shell integration)
# renovate: datasource=github-releases depName=junegunn/fzf
ARG FZF_VERSION=0.74.4
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
# the four explicitly allowlisted credential JSON files and the login entries
# of gh's hosts.yml and npm's npmrc between projects.
RUN mkdir -p /workspace \
             /project-sessions \
             /home/vscode/.aic-sessions/tool-homes/claude \
             /home/vscode/.aic-sessions/tool-homes/codex \
             /home/vscode/.aic-sessions/tool-homes/opencode-config \
             /home/vscode/.aic-sessions/tool-homes/opencode-data \
             /home/vscode/.aic-sessions/tool-homes/gh \
             /home/vscode/.aic-sessions/tool-homes/npm \
             /home/vscode/.semgrep \
             /home/vscode/.config/aic-auth/signing \
             /home/vscode/.config/aic-auth/semgrep \
             /home/vscode/.local/share \
             /home/vscode/.shell-history \
             /opt \
    && ln -s /home/vscode/.aic-sessions/tool-homes/claude /home/vscode/.claude \
    && ln -s /home/vscode/.aic-sessions/tool-homes/codex /home/vscode/.codex \
    && ln -s /home/vscode/.aic-sessions/tool-homes/opencode-config /home/vscode/.config/opencode \
    && ln -s /home/vscode/.aic-sessions/tool-homes/opencode-data /home/vscode/.local/share/opencode \
    && ln -s /home/vscode/.aic-sessions/tool-homes/gh /home/vscode/.config/gh \
    && ln -s /home/vscode/.aic-sessions/tool-homes/npm /home/vscode/.config/npm \
    && chown -R vscode:vscode /workspace /project-sessions /home/vscode/.local /home/vscode/.semgrep /home/vscode/.config /home/vscode/.config/aic-auth /home/vscode/.aic-sessions /home/vscode/.shell-history /opt \
    && chmod 0700 /project-sessions /home/vscode/.aic-sessions /home/vscode/.aic-sessions/tool-homes /home/vscode/.aic-sessions/tool-homes/* \
    && chown -h vscode:vscode /home/vscode/.claude /home/vscode/.codex /home/vscode/.config/opencode /home/vscode/.local/share/opencode /home/vscode/.config/gh /home/vscode/.config/npm

# Reserved root-helper namespace. The host Docker socket is mounted read-only at
# the nested path by Compose; vscode cannot traverse this directory, while the
# fixed aic-chown-volumes helper can perform narrowly scoped GET validation.
RUN install -d -o root -g root -m 0700 /run/aic-host

ENV DEVCONTAINER=true
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano
# Host shell config is never auto-forwarded; only an explicit, opt-in personal
# overlay installed root-owned at /etc/aic/user-config/shell is sourced (see the
# personal-config overlay). Disable the interactive first-shell wizard while
# keeping the managed theme defaults when no overlay p10k config is present.
ENV POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true

WORKDIR /workspace

# Scoped sudoers: every entry is a wrapper with hardcoded targets, so the
# grant cannot be turned into arbitrary chown / file write. aic-firewall is
# strengthen-only; aic-chown-volumes validates exact named-volume mountpoints;
# aic-lock-user-config installs a fixed table of root-owned config files (the
# validated gitconfig plus optional verbatim personal shell). A bare `chown`
# here would let AI `chown vscode /etc/sudoers.d/vscode` and escalate to root.
RUN echo 'vscode ALL=(ALL) NOPASSWD: /usr/local/bin/aic-chown-volumes, /usr/local/bin/aic-lock-user-config, /usr/local/bin/aic-firewall' > /etc/sudoers.d/vscode \
    && chmod 0440 /etc/sudoers.d/vscode

# Privileged helper scripts. All root-owned and only callable via the scoped
# sudoers entry above. aic-firewall is enable-only; aic-chown-volumes and
# aic-lock-user-config operate on hardcoded paths.
COPY aic-firewall aic-chown-volumes aic-lock-user-config /usr/local/bin/
RUN chmod 0755 /usr/local/bin/aic-firewall \
                /usr/local/bin/aic-chown-volumes \
                /usr/local/bin/aic-lock-user-config \
    && chown root:root /usr/local/bin/aic-firewall \
                       /usr/local/bin/aic-chown-volumes \
                       /usr/local/bin/aic-lock-user-config

# ---------------------------------------------------------------------------
# Hooks: root-owned, not writable by vscode (self-defense)
# ---------------------------------------------------------------------------
COPY hooks/ /etc/aic/hooks/
RUN chmod 755 /etc/aic/hooks /etc/aic /etc/aic/hooks/*.sh \
    && chmod 644 /etc/aic/hooks/*.json /etc/aic/hooks/*.js /etc/aic/hooks/*.py \
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
# Codex managed hooks (shared guardrail + optional lifecycle status relay)
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
# apply. The lifecycle handlers are metadata-only, backgrounded where the event
# permits it, and fail-open; SessionEnd is synchronous by Codex contract. The
# requirements file and both scripts are root-owned so the agent can't edit or
# disable either registration.
# (NOTE: a prior version wrote a `[hooks] pre_tool_use = "..."` scalar into
# config.toml — wrong schema AND non-managed, so it never ran for Codex.)
RUN mkdir -p /etc/codex && cat > /etc/codex/requirements.toml <<'CODEX_REQ_EOF'
# Managed by aicontainer — baked into the image, do not edit. Forces the shared
# PreToolUse guardrail and wires the optional lifecycle status relay without an
# interactive trust prompt.
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

[[hooks.SessionStart]]

[[hooks.SessionStart.hooks]]
type = "command"
command = "/usr/bin/python3 -I /etc/aic/hooks/agent-status.py codex"
timeout = 2
async = true

[[hooks.UserPromptSubmit]]

[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "/usr/bin/python3 -I /etc/aic/hooks/agent-status.py codex"
timeout = 2
async = true

[[hooks.PermissionRequest]]

[[hooks.PermissionRequest.hooks]]
type = "command"
command = "/usr/bin/python3 -I /etc/aic/hooks/agent-status.py codex"
timeout = 2
async = true

[[hooks.Stop]]

[[hooks.Stop.hooks]]
type = "command"
command = "/usr/bin/python3 -I /etc/aic/hooks/agent-status.py codex"
timeout = 2
async = true

[[hooks.SessionEnd]]

[[hooks.SessionEnd.hooks]]
type = "command"
command = "/usr/bin/python3 -I /etc/aic/hooks/agent-status.py codex"
timeout = 2
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

# Node LTS via fnm (per-user; lets projects override with their own version).
# The root stage below moves the fnm binary to a root-owned /usr/local/bin/fnm;
# Node versions stay in the vscode-owned $FNM_DIR.
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

# oh-my-zsh + powerlevel10k + plugins. zsh-in-docker only fetches them; the
# .zshrc it generates is discarded for the managed template/.zshrc, and the
# root stage below moves the whole tree to a root-owned path.
# renovate: datasource=github-releases depName=deluan/zsh-in-docker
ARG ZSH_IN_DOCKER_VERSION=1.2.1
RUN sh -c "$(curl -fsSL https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
      -t https://github.com/romkatv/powerlevel10k \
      -p git \
      -p fzf \
      -p https://github.com/zsh-users/zsh-autosuggestions \
      -p https://github.com/zsh-users/zsh-syntax-highlighting \
      -x

# ---------------------------------------------------------------------------
# Root-managed shell startup (zsh, bash, fish). Every file a managed shell
# reads or runs at startup is root-owned: the rc files, oh-my-zsh with the
# theme and plugins, gitstatusd, and the fnm binary. Startup PATH lookups use
# system directories only, and no startup file comes from the vscode-owned
# $HOME, so an agent cannot plant code for the next human shell. Bash and fish
# keep minimal parity with zsh: persistent history (shared volume) and fnm.
# Raw host rc/p10k code is never auto-forwarded; only the opt-in personal
# overlay (root-owned /etc/aic/user-config/shell, zsh only) is sourced after
# this managed baseline.
# ---------------------------------------------------------------------------
USER root

# oh-my-zsh tree -> root-owned /usr/local/share/oh-my-zsh. Prefetch the
# gitstatusd that powerlevel10k runs into the theme's own usrbin/ (its
# installer checks the pinned sha256 from install.info), so p10k never looks
# for one in the vscode-owned ~/.cache/gitstatus. The base image ships a
# theme symlink into the old home path; drop links that leave the tree.
RUN mv /home/vscode/.oh-my-zsh /usr/local/share/oh-my-zsh \
    && p10k=/usr/local/share/oh-my-zsh/custom/themes/powerlevel10k \
    && GITSTATUS_CACHE_DIR="$p10k/gitstatus/usrbin" sh "$p10k/gitstatus/install" -f \
    && ls "$p10k"/gitstatus/usrbin/gitstatusd-linux-* \
    && find /usr/local/share/oh-my-zsh -type l -lname '/home/*' -delete \
    && chown -R root:root /usr/local/share/oh-my-zsh \
    && chmod -R go-w /usr/local/share/oh-my-zsh \
    && install -d -o root -g root -m 0755 \
      /usr/local/share/aic /usr/local/share/aic/zsh-cache \
      /usr/local/share/aic/zsh-cache/oh-my-zsh \
      /usr/local/share/aic/zsh-cache/oh-my-zsh/completions \
    && install -o root -g root -m 0444 /dev/null \
      /usr/local/share/aic/zsh-cache/oh-my-zsh/.zsh-update \
    && install -o root -g root -m 0755 /home/vscode/.fnm/fnm /usr/local/bin/fnm \
    && rm -f /home/vscode/.fnm/fnm /home/vscode/.zshrc

RUN install -d -o root -g root -m 0755 \
      /etc/aic/shell/zsh /etc/aic/shell /etc/aic/user-config /etc/aic/user-config/shell \
      /etc/aic/user-config/statusline
COPY .zshrc /etc/aic/shell/zsh/.zshrc

# zsh reads ZDOTDIR/.zshenv before the global rc files. The global zshrc (the
# distro's plus the base image's additions) runs PATH-resolved commands (git,
# whoami, mkdir) before the managed .zshrc can set a system-only PATH; its
# keymaps and compinit come from oh-my-zsh anyway.
RUN cat > /etc/aic/shell/zsh/.zshenv <<'ZSHENV_EOF'
# Managed aicontainer zsh environment (root-owned). Skip the global
# /etc/zsh/{zprofile,zshrc,zlogin,zlogout}: they run before the managed .zshrc.
unsetopt GLOBAL_RCS
ZSHENV_EOF

# Interactive Bash reads /etc/bash.bashrc before --rcfile, and no flag skips
# only that file. The distro and base-image version runs PATH-resolved
# commands (groups, git) and reads files in $HOME, so replace it.
RUN cat > /etc/bash.bashrc <<'BASHBASHRC_EOF'
# Managed by aicontainer (root-owned). Interactive Bash reads this before
# /etc/aic/shell/bashrc: run no PATH-resolved command and read no $HOME file.
[ -z "${PS1-}" ] && return
shopt -s checkwinsize
if [ -x /usr/lib/command-not-found ]; then
  command_not_found_handle() {
    /usr/lib/command-not-found -- "$1"
    return $?
  }
fi
BASHBASHRC_EOF

# Managed bashrc: the Ubuntu skel file between a system-only PATH prologue and
# the aicontainer additions. Its ~/.bash_aliases and ~/.dircolors reads are
# removed, bash-completion's user file/dir are pointed away from $HOME, and
# readline ignores ~/.inputrc. The build fails if a home read is left.
RUN { printf '%s\n' \
        '# Managed aicontainer Bash startup (root-owned). Startup uses a system-only' \
        '# PATH and reads no file in the vscode-owned home; the end of this file' \
        '# restores the full PATH.' \
        '_aic_path=$PATH' \
        'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
        'BASH_COMPLETION_USER_FILE=/dev/null' \
        'BASH_COMPLETION_USER_DIR=/usr/local/share/aic/no-bash-completion' \
        'INPUTRC=/etc/inputrc' \
        ''; \
      sed -e '/^if \[ -f ~\/\.bash_aliases \]; then$/,/^fi$/d' \
          -e 's#test -r ~/\.dircolors && eval "\$(dircolors -b ~/\.dircolors)" || ##' \
          /home/vscode/.bashrc; \
    } > /etc/aic/shell/bashrc \
    && rm -f /home/vscode/.bashrc \
    && cat >> /etc/aic/shell/bashrc <<'BASHRC_EOF'

# aicontainer additions
export HISTFILE=/home/vscode/.shell-history/.bash_history
export HISTSIZE=50000
export HISTFILESIZE=50000
shopt -s histappend
PATH=$_aic_path
unset _aic_path
# fnm: root-owned binary; the function keeps fnm's cd hook on it.
fnm() { /usr/local/bin/fnm "$@"; }
eval "$(/usr/local/bin/fnm env --use-on-cd --shell bash)"
# VS Code terminals open commit messages in the editor (replaces the base
# image's /etc/bash.bashrc snippet).
if [ -z "${GIT_EDITOR-}" ] && [ "${TERM_PROGRAM-}" = vscode ] \
    && [ -z "$(/usr/bin/git config --get core.editor 2>/dev/null)" ]; then
  if command -v code >/dev/null 2>&1; then
    export GIT_EDITOR='code --wait'
  elif command -v code-insiders >/dev/null 2>&1; then
    export GIT_EDITOR='code-insiders --wait'
  fi
fi
BASHRC_EOF
RUN if grep -hEv '^[[:space:]]*#' /etc/aic/shell/bashrc /etc/bash.bashrc \
        | grep -E '~/|\$HOME|\$\{HOME'; then \
      echo "managed Bash startup still reads a file in \$HOME" >&2; exit 1; \
    fi

RUN cat > /etc/profile.d/aic-bash.sh <<'PROFILE_EOF'
# Managed aicontainer Bash startup for login shells.
if [ -n "${BASH_VERSION:-}" ] && [[ $- == *i* ]]; then
  . /etc/aic/shell/bashrc
fi
PROFILE_EOF

RUN mkdir -p /etc/fish/conf.d \
    && cat > /etc/fish/conf.d/aic.fish <<'FISH_EOF'
# Managed aicontainer fish config (baked at image build). fnm is root-owned;
# the function keeps fnm's cd hook on it.
set -gx FNM_DIR /home/vscode/.fnm
function fnm
    /usr/local/bin/fnm $argv
end
/usr/local/bin/fnm env --use-on-cd --shell fish | source
FISH_EOF

# Managed launcher for the opt-in personal Claude Code statusline overlay
# (post-create's STATUSLINE_* constants; AGENTS.md "personal config overlay").
# This fixed path is the ONLY thing written into settings.json's statusLine
# command, so no host-provided command string is ever executed and there is no
# command-line rewriting heuristic. The interpreter comes from the installed
# file's extension, chosen from this hardcoded list — the scripts themselves are
# root:root 0444 in a root-owned directory, so an in-container agent cannot add
# or replace one. No overlay installed -> render nothing and exit clean.
RUN cat > /usr/local/bin/aic-statusline <<'STATUSLINE_EOF'
#!/bin/sh
# aicontainer managed statusline launcher — do not edit (root-owned).
set -u
dir=/etc/aic/user-config/statusline

run_node() {
  # fnm keeps the default toolchain behind a stable alias path; Claude may
  # invoke this with a PATH that never sourced a shell rc. Fall back to PATH.
  for node in /home/vscode/.fnm/aliases/default/bin/node /usr/local/bin/node /usr/bin/node; do
    [ -x "$node" ] && exec "$node" "$1"
  done
  exec node "$1"
}

[ -r "$dir/statusline.sh" ]  && exec /bin/bash "$dir/statusline.sh"
[ -r "$dir/statusline.mjs" ] && run_node "$dir/statusline.mjs"
[ -r "$dir/statusline.js" ]  && run_node "$dir/statusline.js"
[ -r "$dir/statusline.py" ]  && exec /usr/bin/python3 "$dir/statusline.py"
exit 0
STATUSLINE_EOF

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
                       /etc/bash.bashrc /etc/aic/gitignore /usr/local/bin/aic-statusline \
    && chmod 0755 /etc/aic/shell /etc/aic/shell/zsh /etc/aic/user-config \
                  /etc/aic/user-config/shell /etc/aic/user-config/statusline \
    && chmod 0444 /etc/aic/shell/zsh/.zshrc /etc/aic/shell/zsh/.zshenv \
                  /etc/aic/shell/bashrc /etc/bash.bashrc /etc/profile.d/aic-bash.sh \
                  /etc/fish/conf.d/aic.fish /etc/aic/gitignore \
    && chmod 0555 /usr/local/bin/aic-statusline

ENV ZDOTDIR=/etc/aic/shell/zsh

USER vscode
