# =============================================================================
# aicontainer — base image for Claude Code + Codex + OpenCode in bypass mode
# =============================================================================
# Build inside a project's .devcontainer/ via `aic up` (which runs `devcontainer
# up` and reads docker-compose.yml). Image is rebuilt by CI weekly so AI CLI
# versions stay current.
# =============================================================================

FROM ghcr.io/astral-sh/uv:0.13@sha256:4a1f3666816dafadd20ceb71eac9a7d56d7ef30279f7d64048519ab901ada336 AS uv
FROM mcr.microsoft.com/devcontainers/base:ubuntu24.04@sha256:d7c468679f45a52ad3673d06656b5bf16e488990b17216a1fa295d9e1f89d724

# OCI labels: lets GitHub auto-link the GHCR package back to this repo.
LABEL org.opencontainers.image.source="https://github.com/stefanoginella/aicontainer" \
      org.opencontainers.image.description="Sandboxed devcontainer for running Claude Code, Codex, and OpenCode in bypass / auto-approve mode." \
      org.opencontainers.image.licenses="MIT"

ARG TZ
ENV TZ="$TZ"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---------------------------------------------------------------------------
# Downloads (docs/contributing/image-integrity.md)
# ---------------------------------------------------------------------------
# Every curl or git fetch runs under `set -eu` (no `||`, no `set +e`) and
# writes to a file first:
#   curl -fsSL --proto '=https' --tlsv1.2 -o FILE URL
# Nothing is piped into a shell or into tar/dpkg/gpg. Before a file is
# installed or run, it is checked: a release asset with
# `echo "$SHA256  FILE" | sha256sum -c -` against a pinned *_SHA256 ARG, an apt
# repository key against an allow-list of reviewed fingerprints, and Node
# against a SHASUMS256.txt signed by a pinned releaser keyring. A git source is
# pinned by a commit that must be on its upstream branch. Renovate bumps
# *_VERSION ARGs but never *_SHA256 ARGs, so a version bump fails the build
# until the checksums are updated by hand. The official Claude/Codex/OpenCode
# installers float on purpose (self-updating baked floor), but are downloaded
# completely first.
#
# BuildKit (required anyway for the RUN heredocs below) sets TARGETARCH for the
# platform being built. Each per-architecture download selects its asset and
# checksum with it; any value other than amd64 or arm64 fails the build.
ARG TARGETARCH

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

# git-delta (a .deb that dpkg installs as root)
# renovate: datasource=github-releases depName=dandavison/delta
ARG GIT_DELTA_VERSION=0.20.1
ARG GIT_DELTA_SHA256_AMD64=0683067a4cbbcc19b9fd2841253131d1b37ccfa724725098d811d4d0d9fcc25b
ARG GIT_DELTA_SHA256_ARM64=6e08b734d611037eb9eb5db883cab7ac0a089216a9efdc1d2caac44319029c28
RUN set -eu; \
    arch="$TARGETARCH"; \
    case "$arch" in \
      amd64) sha256="$GIT_DELTA_SHA256_AMD64" ;; \
      arm64) sha256="$GIT_DELTA_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    tmp=$(mktemp -d); \
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/git-delta.deb" \
      "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${arch}.deb"; \
    echo "$sha256  $tmp/git-delta.deb" | sha256sum -c -; \
    dpkg -i "$tmp/git-delta.deb"; \
    rm -rf "$tmp"

# uv (Python package manager)
COPY --from=uv /uv /usr/local/bin/uv

# fzf (GitHub release is newer than apt and includes shell integration). Only
# the fzf binary is installed, root-owned: the archive's own owner is not kept.
# renovate: datasource=github-releases depName=junegunn/fzf
ARG FZF_VERSION=0.74.4
ARG FZF_SHA256_AMD64=05e6813a337cc722c3ed07e54a764b75cc5d671e2e60459db0ba696ee5fa7504
ARG FZF_SHA256_ARM64=5d673b849f494f0d64ec471d8640b153ca8849e3846a31da17abdcfce8df6b46
RUN set -eu; \
    arch="$TARGETARCH"; \
    case "$arch" in \
      amd64) sha256="$FZF_SHA256_AMD64" ;; \
      arm64) sha256="$FZF_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    tmp=$(mktemp -d); \
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/fzf.tar.gz" \
      "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-linux_${arch}.tar.gz"; \
    echo "$sha256  $tmp/fzf.tar.gz" | sha256sum -c -; \
    tar -xzf "$tmp/fzf.tar.gz" -C "$tmp" --no-same-owner fzf; \
    install -o root -g root -m 0755 "$tmp/fzf" /usr/local/bin/fzf; \
    rm -rf "$tmp"

# GitHub CLI (used by AI for PR/issue work; user logs in inside the container).
# The repository keyring may hold only these reviewed primary keys
# (`gpg --show-keys` fingerprints); apt then checks the floating gh package
# with it. A key that is dropped or gets a new expiry date still passes; a new
# key fails the build until it is reviewed and added here.
#   2C6106201985B60E6C7AC87323F3D4EA75716059  GitHub CLI (expired 2026-09-05)
#   7F38BBB59D064DBCB3D84D725612B36462313325  GitHub CLI (since 2026-04-07)
ARG GH_KEYRING_FINGERPRINTS=2C6106201985B60E6C7AC87323F3D4EA75716059,7F38BBB59D064DBCB3D84D725612B36462313325
RUN set -eu; \
    tmp=$(mktemp -d); \
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/githubcli-archive-keyring.gpg" \
      https://cli.github.com/packages/githubcli-archive-keyring.gpg; \
    keys=$(gpg --batch --show-keys --with-colons "$tmp/githubcli-archive-keyring.gpg" \
      | awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10; p = 0 }'); \
    test -n "$keys"; \
    for key in $keys; do \
      case ",$GH_KEYRING_FINGERPRINTS," in \
        *",$key,"*) ;; \
        *) echo "unreviewed GitHub CLI repository key: $key" >&2; exit 1 ;; \
      esac; \
    done; \
    install -o root -g root -m 0644 "$tmp/githubcli-archive-keyring.gpg" \
      /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    rm -rf "$tmp"; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*

# Docker CLI (talks to socket-proxy via DOCKER_HOST=tcp://socket-proxy:2375).
# Same reviewed-key rule as the gh keyring above.
#   9DC858229FC7DD38854AE2D88D81803C0EBFCD88  Docker Release (CE deb)
ARG DOCKER_KEYRING_FINGERPRINTS=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
RUN set -eu; \
    tmp=$(mktemp -d); \
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/docker.asc" \
      https://download.docker.com/linux/debian/gpg; \
    keys=$(gpg --batch --show-keys --with-colons "$tmp/docker.asc" \
      | awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10; p = 0 }'); \
    test -n "$keys"; \
    for key in $keys; do \
      case ",$DOCKER_KEYRING_FINGERPRINTS," in \
        *",$key,"*) ;; \
        *) echo "unreviewed Docker repository key: $key" >&2; exit 1 ;; \
      esac; \
    done; \
    gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg "$tmp/docker.asc"; \
    rm -rf "$tmp"; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu noble stable" \
      > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      docker-ce-cli docker-buildx-plugin docker-compose-plugin; \
    rm -rf /var/lib/apt/lists/*

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
# Name each hook file: AIC_HOOK_FILES in lib/aic/identity.sh is the list
# (tests/test-aic-hook-files.py checks it). A stray file never gets in.
COPY hooks/agent-status.py hooks/claude-settings.json \
     hooks/opencode-guardrail.js hooks/pre-tool-use.sh /etc/aic/hooks/
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
# post-create.py is the fixed entry point. It imports its code only from the
# aic_post_create package in /opt/aic-post-create, a root-owned, read-only
# directory that holds nothing else. Name every module here, never a glob or a
# directory: an extra file in .devcontainer/ must not reach the import
# directory. Keep this list equal to AIC_POST_CREATE_MODULES in
# lib/aic/identity.sh (tests/test-aic-post-create-package.py checks it).
COPY post-create.py /opt/post-create.py
COPY post_create_common.py post_create_claude_reset.py post_create_tools.py \
     post_create_seeds.py post_create_auth_logins.py post_create_auth_sync.py \
     post_create_container.py post_create_git.py post_create_overlays.py \
     post_create_main.py /opt/aic-post-create/aic_post_create/
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
    && : > /opt/aic-post-create/aic_post_create/__init__.py \
    && chown -R root:root /opt/aic-python /opt/post-create.py /opt/aic-post-create \
    && chmod 0755 /opt/post-create.py \
    && find /opt/aic-post-create -type d -exec chmod 0555 {} + \
    && find /opt/aic-post-create -type f -exec chmod 0444 {} +

USER vscode

ENV PATH="/home/vscode/.local/bin:/home/vscode/.opencode/bin:$PATH"
# Build-time mirror of devcontainer.json's containerEnv: skip npm lifecycle
# scripts for any `npm install`/`npx` (MCP servers, a downstream
# Dockerfile.project). Codex is no longer an npm package — it installs via the
# official standalone installer below, alongside Claude Code.
ENV NPM_CONFIG_IGNORE_SCRIPTS=true

# Claude Code + Codex + OpenCode: official standalone installers. Claude/Codex
# land in ~/.local/bin, OpenCode in ~/.opencode/bin (both already on PATH above).
# These are the baseline "floor" baked into the image; post-create's
# refresh_ai_tools() (post_create_tools.py) floats all three to the latest
# release on every container (re)create, so `aic rebuild` always lands current
# AI CLIs. The Claude/Codex
# installers skip editing login-shell rc files because ~/.local/bin is already
# on PATH; OpenCode's installer is told not to touch them with
# --no-modify-path (the managed rc files below set PATH explicitly).
# These three installers float on purpose (no pinned checksum): they are the
# vendors' supported way to install a CLI that updates itself. Each is still
# downloaded completely to a file over HTTPS first, so a failed or cut-off
# download fails the build instead of running a partial script.
# `claude --version` may create one-time migration state. Do not bake that
# machine identity into every project; runtime state belongs in the
# per-project CLAUDE_CONFIG_DIR.
RUN set -eu; \
    tmp=$(mktemp -d); \
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/install.sh" https://claude.ai/install.sh; \
    bash "$tmp/install.sh"; \
    rm -rf "$tmp"; \
    claude --version; \
    rm -f /home/vscode/.claude.json; \
    rm -rf /home/vscode/.aic-sessions/tool-homes/claude/backups
# Keep the standalone package separate from CODEX_HOME: ~/.codex is a
# per-project config/session home, while this rootfs path is the refreshable
# executable floor. `refresh_ai_tools()` supplies the same installer variables.
RUN set -eu; \
    tmp=$(mktemp -d); \
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/install.sh" https://chatgpt.com/codex/install.sh; \
    CODEX_NON_INTERACTIVE=1 \
      CODEX_HOME=/home/vscode/.local/share/aic-tools/codex \
      CODEX_INSTALL_DIR=/home/vscode/.local/bin \
      sh "$tmp/install.sh"; \
    rm -rf "$tmp"; \
    codex --version
RUN set -eu; \
    tmp=$(mktemp -d); \
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/install" https://opencode.ai/install; \
    bash "$tmp/install" --no-modify-path; \
    rm -rf "$tmp"; \
    opencode --version

# Python toolchain (per-user; survives image rebuilds via base layer caching).
# uv checks each Python download against the sha256 built into this
# digest-pinned uv release.
RUN uv python install 3.13 --default

# Node LTS via fnm (per-user; lets projects override with their own version).
# The root stage below moves the fnm binary to a root-owned /usr/local/bin/fnm;
# Node versions stay in the vscode-owned $FNM_DIR.
# fnm is a pinned release binary. Node floats inside its major line on
# purpose, so the weekly rebuild picks up Node security releases, but only to
# a release that a pinned Node releaser key signed:
# - The keyring is gpg-only-active-keys/pubring.kbx of nodejs/release-keys at
#   a pinned commit, checked by sha256. A release signed by any other key
#   fails the build until the keyring pin is reviewed and updated.
# - gpgv writes the signed text of SHASUMS256.txt.asc to a separate file
#   (not "SHASUMS256.txt": gpgv would take that name as detached data), and
#   only that verified text is parsed. gpgv writes the file even when the
#   signature is bad, so its exit status must stop the build (no `||` here).
# - The release must not be older than NODE_MIN_VERSION (rollback guard); the
#   major of NODE_MIN_VERSION is the Node line that floats.
# - `fnm install` does not check downloads, so the tarball is checked against
#   the signed sha256 and unpacked into fnm's own layout
#   (node-versions/vX.Y.Z/installation). `fnm default` fails the build if fnm
#   does not see it.
# renovate: datasource=github-releases depName=Schniz/fnm
ARG FNM_VERSION=1.39.0
ARG FNM_SHA256_AMD64=7807664f39d39fc518da1c35ba0181e4b3267603c4b1dedeb4b5fc6ae440a224
ARG FNM_SHA256_ARM64=4eaff58b2c5bf30d0934027572dd0b5bbb60d2a1af309230b53662d4b1d45599
# renovate: datasource=git-refs depName=https://github.com/nodejs/release-keys branch=main
ARG NODE_RELEASE_KEYS_COMMIT=481637f813e912c4aa3622d7964ab426c97b8e8d
ARG NODE_RELEASE_KEYS_SHA256=140f2ad5260fd62773b6243ce8e1d3009645d558f121b8262c55e383dc285932
# renovate: datasource=node-version depName=node
ARG NODE_MIN_VERSION=24.21.0
ENV FNM_DIR="/home/vscode/.fnm"
RUN set -eu; \
    arch="$TARGETARCH"; \
    case "$arch" in \
      amd64) fnm_asset=fnm-linux; fnm_sha256="$FNM_SHA256_AMD64"; node_arch=x64 ;; \
      arm64) fnm_asset=fnm-arm64; fnm_sha256="$FNM_SHA256_ARM64"; node_arch=arm64 ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    tmp=$(mktemp -d); \
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/fnm.zip" \
      "https://github.com/Schniz/fnm/releases/download/v${FNM_VERSION}/${fnm_asset}.zip"; \
    echo "$fnm_sha256  $tmp/fnm.zip" | sha256sum -c -; \
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/node-release-keys.kbx" \
      "https://raw.githubusercontent.com/nodejs/release-keys/${NODE_RELEASE_KEYS_COMMIT}/gpg-only-active-keys/pubring.kbx"; \
    echo "$NODE_RELEASE_KEYS_SHA256  $tmp/node-release-keys.kbx" | sha256sum -c -; \
    node_major="${NODE_MIN_VERSION%%.*}"; \
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/SHASUMS256.txt.asc" \
      "https://nodejs.org/dist/latest-v${node_major}.x/SHASUMS256.txt.asc"; \
    gpgv --keyring "$tmp/node-release-keys.kbx" --output "$tmp/node-shasums.verified" "$tmp/SHASUMS256.txt.asc"; \
    node_entry=$(grep -E "^[0-9a-f]{64}  node-v${node_major}\.[0-9]+\.[0-9]+-linux-${node_arch}\.tar\.xz\$" "$tmp/node-shasums.verified"); \
    if [ "$(printf '%s\n' "$node_entry" | wc -l)" -ne 1 ]; then \
      echo "expected one signed Node ${node_major}.x tarball for linux-${node_arch}" >&2; exit 1; \
    fi; \
    node_sha256="${node_entry%%  *}"; \
    node_version="${node_entry#*  node-v}"; \
    node_version="${node_version%%-linux-*}"; \
    if ! printf '%s\n' "$NODE_MIN_VERSION" "$node_version" | sort -C -V; then \
      echo "signed Node $node_version is older than NODE_MIN_VERSION $NODE_MIN_VERSION" >&2; exit 1; \
    fi; \
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/node.tar.xz" \
      "https://nodejs.org/dist/v${node_version}/node-v${node_version}-linux-${node_arch}.tar.xz"; \
    echo "$node_sha256  $tmp/node.tar.xz" | sha256sum -c -; \
    unzip -q "$tmp/fnm.zip" fnm -d "$tmp"; \
    install -d "$FNM_DIR" "$FNM_DIR/node-versions/v${node_version}/installation"; \
    install -m 0755 "$tmp/fnm" "$FNM_DIR/fnm"; \
    tar -xJf "$tmp/node.tar.xz" --no-same-owner --strip-components=1 \
      -C "$FNM_DIR/node-versions/v${node_version}/installation"; \
    rm -rf "$tmp"; \
    "$FNM_DIR/fnm" default "$node_version"; \
    test "$("$FNM_DIR/aliases/default/bin/node" --version)" = "v${node_version}"
# A process that no managed shell starts (Claude Code hooks, MCP servers, the
# VS Code server, `docker exec`) never runs `fnm env`. Put the fnm default
# Node (node, npm, npx) LAST on the image PATH: it never shadows a system
# binary, and `fnm env` in a managed shell still puts the per-directory Node
# first. Do not link this vscode-owned Node into a system directory: the
# startup PATH of the managed shells and the PATH of root processes search
# those directories (docs/contributing/shell-and-overlays.md).
ENV PATH="$PATH:/home/vscode/.fnm/aliases/default/bin"

# Semgrep (used by Claude Code's semgrep plugin; installed into ~/.local/bin
# via uv tool so the binary is on PATH for the vscode user). Its settings path
# is configured directly inside the persistent global auth volume. It floats
# on PyPI on purpose (no hash lock); uv fails the build on any error.
RUN uv tool install semgrep \
    && semgrep --version

# oh-my-zsh + powerlevel10k + plugins. The root stage below moves the whole
# tree to a root-owned path; the managed rc is template/.zshrc.
# oh-my-zsh itself comes from the digest-pinned base image (the Dev Containers
# common-utils feature installs it for vscode). The build fails if it is
# missing, so it is never fetched unpinned. The theme and the two plugins are
# fetched at pinned commits: git checks every object against its id, and the
# checkout must be exactly the pinned commit. GitHub also serves commits that
# exist only in a fork through the upstream URL, so the pinned commit must
# also be an ancestor of the upstream branch named in its renovate comment
# (checked in a throwaway commits-only clone, so the checkout stays as-is).
# The theme commit also pins gitstatusd: its installer (root stage below)
# checks the download against the sha256 in that commit's install.info.
# renovate: datasource=git-refs depName=https://github.com/romkatv/powerlevel10k branch=master
ARG POWERLEVEL10K_COMMIT=d05a1b00f9a61f9578bf9dc19b8451942dde8734
# renovate: datasource=git-refs depName=https://github.com/zsh-users/zsh-autosuggestions branch=master
ARG ZSH_AUTOSUGGESTIONS_COMMIT=85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5
# renovate: datasource=git-refs depName=https://github.com/zsh-users/zsh-syntax-highlighting branch=master
ARG ZSH_SYNTAX_HIGHLIGHTING_COMMIT=e6683f20e5c38d3e5447f45845d04ddda75d0f23
RUN set -eu; \
    test -f /home/vscode/.oh-my-zsh/oh-my-zsh.sh; \
    fetch_commit() { \
      git init -q "$3"; \
      git -C "$3" remote add origin "$1"; \
      git -C "$3" fetch -q --depth 1 origin "$2"; \
      git -C "$3" -c advice.detachedHead=false checkout -q FETCH_HEAD; \
      test "$(git -C "$3" rev-parse HEAD)" = "$2"; \
      upstream=$(mktemp -d); \
      git init -q --bare "$upstream"; \
      git -C "$upstream" fetch -q --filter=tree:0 "$1" "refs/heads/$4"; \
      if ! git -C "$upstream" merge-base --is-ancestor "$2" FETCH_HEAD; then \
        echo "$2 is not on the $4 branch of $1" >&2; exit 1; \
      fi; \
      rm -rf "$upstream"; \
    }; \
    custom=/home/vscode/.oh-my-zsh/custom; \
    fetch_commit https://github.com/romkatv/powerlevel10k \
      "$POWERLEVEL10K_COMMIT" "$custom/themes/powerlevel10k" master; \
    fetch_commit https://github.com/zsh-users/zsh-autosuggestions \
      "$ZSH_AUTOSUGGESTIONS_COMMIT" "$custom/plugins/zsh-autosuggestions" master; \
    fetch_commit https://github.com/zsh-users/zsh-syntax-highlighting \
      "$ZSH_SYNTAX_HIGHLIGHTING_COMMIT" "$custom/plugins/zsh-syntax-highlighting" master

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
# (post-create's STATUSLINE_* constants; docs/contributing/shell-and-overlays.md).
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
