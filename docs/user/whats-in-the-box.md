# What is in the box

`aic init` gives you an image with fixed defaults. This page lists them, so
you know them before you start. It has two groups: security defaults and
developer-experience defaults.

## Security defaults

> **Warning:** Do not change these defaults without a good reason. Many of
> them are the real sandbox boundary.

### npm hardening

- `NPM_CONFIG_IGNORE_SCRIPTS=true` blocks `postinstall` RCE. This is the most
  common supply-chain vector.
- `NPM_CONFIG_MIN_RELEASE_AGE=1` rejects each package that was published in
  the last 24h. npm reads the value in days. This decreases the risk from
  malicious releases that move fast.
- `audit=true`, `fund=false`.

### Root-managed Git and shell startup

- A sanitizer without network access takes only fixed preferences from the
  host Git config. These preferences cannot run code: identity, line-ending,
  pull/push behavior, and signing intent.
- A narrow helper validates the generated config. It installs the config one
  time at `/etc/aic/user-config/gitconfig` as `root:root 0444`.
- These items never cross: credential helpers, aliases, includes, hooks,
  remotes, and settings that contain a command or a path.
- aic adds one credential helper of its own: `/usr/bin/gh auth git-credential`
  for `https://github.com` and `https://gist.github.com`. Thus `git push` over
  HTTPS uses your container `gh` login. See
  [Push to GitHub from the container](install.md#push-to-github-from-the-container).
- Zsh, Bash, and fish also start from root-owned aicontainer profiles. They
  never start from user rc files or host rc files that are writable.
- The code that these profiles load is also root-owned: oh-my-zsh,
  powerlevel10k, the plugins, and fnm.
- At startup, the shells find commands only in system directories.

Thus an agent cannot plant code that runs when you open a shell.

### PreToolUse hook

The PreToolUse hook is a best-effort check at the tool layer. It operates for
Claude, Codex, and OpenCode. It operates also when bypass, auto-approve, or
allow is on. It refuses these actions:

- **Reads of `.env*` files.** It refuses them through
  `Read`/`Edit`/`Write`/`Grep`/`Glob` and in Bash commands. It allows
  `.env.example|.sample|.template|.defaults`.
- **Fetch-and-execute in Bash** with `curl|sh` / `wget|bash`. This includes
  the `| sudo bash`, `| tee | sh`, and `bash -c "$(curl …)"` variants.
- **Writes to protected paths:** `/etc/aic/`, `/workspace/.devcontainer/`, and
  the login-shell rc files (`~/.zshrc` / `~/.bashrc` / fish config and their
  `.local` includes). This is defense-in-depth on top of the read-only mounts
  and the root-locks above.

> **Warning:** Keep secrets out of `/workspace` for real protection. The
> `.env*` check is **not a boundary**. The hook matches the literal `.env` name
> in the file path that a tool names. It also matches it in the text of a Bash
> command. These methods get around it:
>
> - an obfuscated name
> - a shell glob
> - an interpreter one-liner
> - a symlink that the agent made first
> - a `Grep` that names a directory and filters with `glob`

One script (`/etc/aic/hooks/pre-tool-use.sh`) is the single source of truth
for all three tools:

- Claude gets it from the root-managed `/etc/claude-code/managed-settings.json`.
- Codex uses it through a managed hook.
- OpenCode uses a small plugin (`opencode-guardrail.js`). The plugin
  translates the OpenCode tool calls and runs the same script.

### Forced AI sandbox settings

Root-managed policy enforces these settings. They are not in user config that
the agent can write.

- Claude: `permissions.defaultMode=bypassPermissions` and the hook.
- Codex: `approval_policy=never`, `sandbox_mode=danger-full-access`, and the
  managed hook.
- OpenCode: `permission."*"=allow` and the guardrail plugin.

For the preference allowlist, see
[Config seeding from the host](multi-project.md).

### Reduced runtime privilege

- The devcontainer starts with all Linux capabilities dropped.
- Then it gets only a small set. UID/GID startup, the fixed ownership helper,
  and the network firewall of the container need this set.
- The raw Docker socket is at a path that only root can see. aic uses it only
  to verify named volumes.
- The agent talks only to the socket proxy.

### Container global gitignore

The global gitignore of the container covers `.env*`, `.claude/`, `.codex/`,
`node_modules/`, `.venv/`, `__pycache__/`, and `.DS_Store`. Thus it is more
difficult to commit a secret by accident.

### No host credential forwarding

aic does not forward these items:

- the SSH-agent socket
- API keys
- the host `gh` token
- literal secrets from seeded tool or MCP config

You log in one time *inside* the container. The tokens persist in hardened
subpaths of `aic-auth-global`. The SSH agent and `~/.ssh` are not in the
container. Thus, use [`aic signing`](signing.md) for a signing key that only
the sandbox uses.

## Developer-experience defaults

These defaults are personal choices. If you do not agree with one, change it
in `Dockerfile.project`.

- **Shell:** the default is `zsh` + `oh-my-zsh` + `powerlevel10k` +
  `zsh-autosuggestions` + `zsh-syntax-highlighting`. The image also contains
  `bash` and `fish` (barebones, with history + fnm). Select one at init time
  with `--shell zsh|bash|fish`. See
  [Select the shell for a project](usage.md). With zsh, p10k expects
  [MesloLGS NF](https://github.com/romkatv/powerlevel10k#meslo-nerd-font-patched-for-powerlevel10k)
  on your terminal (see [Troubleshooting](troubleshooting.md)). bash and fish
  use plain `monospace`.
- **Editor:** `$EDITOR=nano`, `$VISUAL=nano`. `vim` is installed, but it is
  not the default.
- **Runtimes:**
  - Python 3.13 through [`uv`](https://github.com/astral-sh/uv).
  - Node 24 LTS through [`fnm`](https://github.com/Schniz/fnm). Thus a project
    can override the version with `.nvmrc`.
- **CLI utilities:** `ripgrep`, `fd-find`, `fzf`, `tmux`, `jq`, `gh`, the
  `docker` CLI (+ buildx, compose), `semgrep`, and
  [`git-delta`](https://github.com/dandavison/delta). `git-delta` is set as
  `core.pager` and `interactive.diffFilter`.
- **VS Code extensions:** VS Code installs these automatically when you open
  the project in the editor:
  - `anthropic.claude-code`, `openai.chatgpt`, `sst-dev.opencode` (`AIC_TOOLS`
    controls each one)
  - `eamodio.gitlens`
  - `pflannery.vscode-versionlens`
  - `BracketPairColorDLW.bracket-pair-color-dlw`
  - `vincaslt.highlight-matching-tag`
  - `yzhang.markdown-all-in-one`

  To add your own for a project (for example, the Python or TypeScript editor
  stack), use `.devcontainer/vscode-extensions` and `vscode-settings.json`.
  See [Customization](customization.md).
- **VS Code terminal settings:**
  - The default profile and the font family follow the `AIC_SHELL` of the
    project (zsh → `MesloLGS NF`; bash/fish → `monospace`).
  - A right-click pastes.
  - The terminal opens only the `http/https/mailto/vscode` link schemes. It
    suppresses `file://` OSC 8 links to prevent
    [microsoft/vscode#211443](https://github.com/microsoft/vscode/issues/211443).
- **Other environment variables:**
  - `PYTHONDONTWRITEBYTECODE=1`
  - `PIP_DISABLE_PIP_VERSION_CHECK=1`
  - `GIT_CONFIG_GLOBAL=/etc/aic/user-config/gitconfig` (the validated
    root-managed config)

For a different baseline, see [Install extra tools](extra-tools.md). It shows
the project Dockerfile pattern. You can change most of the
developer-experience choices with 2-3 lines there.
