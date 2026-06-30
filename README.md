# aicontainer

[![npm version](https://img.shields.io/npm/v/aicontainer?logo=npm)](https://www.npmjs.com/package/aicontainer)
[![release](https://github.com/stefanoginella/aicontainer/actions/workflows/release.yml/badge.svg)](https://github.com/stefanoginella/aicontainer/actions/workflows/release.yml)
[![rebuild](https://github.com/stefanoginella/aicontainer/actions/workflows/rebuild.yml/badge.svg)](https://github.com/stefanoginella/aicontainer/actions/workflows/rebuild.yml)
[![License: MIT](https://img.shields.io/npm/l/aicontainer?color=yellow)](LICENSE)
[![Container: GHCR](https://img.shields.io/badge/container-ghcr.io-2188ff?logo=github)](https://github.com/stefanoginella/aicontainer/pkgs/container/aicontainer)
[![Devcontainer spec](https://img.shields.io/badge/devcontainer-spec-blue?logo=visualstudiocode)](https://containers.dev/)

A sandboxed devcontainer for running [Claude Code](https://claude.ai/code), [Codex](https://github.com/openai/codex), and [OpenCode](https://opencode.ai) in bypass / auto-approve mode safely across multiple projects.

**Why?** Auto-approve is the only way these CLIs actually fly — but pointed at your real `$HOME` it also lets a prompt-injected dependency read `.env`, exfiltrate shell history, or push through your `gh` token. `aicontainer` puts the AI behind a devcontainer boundary so you can keep auto-approve on without rebuilding your machine each time.

**What you get:** filesystem isolation, a filtered Docker socket via [Tecnativa's docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy), a minimal PreToolUse hook, and an **opt-in** iptables outbound allowlist. No AI-generated config, no per-project re-login. Defaults are listed in [What's in the box](#whats-in-the-box) so you know exactly what you're adopting.

> Adjacent work: same shape as the [Trail of Bits devcontainer](https://github.com/trailofbits/claude-code-devcontainer), with Codex and OpenCode added, Docker access turned on by default, and host shell look-and-feel preserved.

## What crosses the boundary

At a glance, what the in-container agent can touch on your host. Run `aic
preflight` in any project to print this for your *actual* config (it's also
shown automatically at the end of every `aic up`).

| Surface | Crosses the boundary? |
|---|---|
| Project directory | **Yes, read-write** (`/workspace`) — the one writable host path. |
| `~/.gitconfig`, `~/.p10k.zsh`, `~/.zshrc.local` | Read-only (shell look-and-feel). |
| `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.config/opencode/opencode.json` | Read-only **seed** — an allowlisted subset of fields; security-critical ones are force-overridden (and inline provider API keys are stripped from the OpenCode seed). See [Config seeding](#config-seeding-from-the-host). |
| Host home, `~/.ssh`, SSH-agent socket | **No** — not mounted, not forwarded. |
| Host credentials (API keys, `gh` token, keychain) | **No** — nothing auto-forwarded; you log in once *inside* the container. |
| Package-manager caches | **No** — container-local volumes, not your host caches. |
| Clipboard / browser | **No** — nothing bridged. |
| `.env*` files | Blocked from the agent by the [PreToolUse hook](#whats-in-the-box). Your project's own `.env` is physically in `/workspace`, but the hook stops the agent from reading it — defense-in-depth at the tool layer, not a missing file. |
| Session transcripts | Persist in a **per-project named volume**, never written back to your host home. See [Multi-project model](#multi-project-model). |
| **Outbound network** | **Yes — fully open by default.** Reaches the internet, your LAN, and cloud metadata (`169.254.169.254`). Opt in to the [iptables allowlist](#opt-in-network-allowlist) to restrict it. |

The full reasoning is in [Threat model](#threat-model); the network row is the
one most worth your attention.

## Prerequisites

- Docker runtime: [Docker Desktop](https://docker.com/products/docker-desktop), [OrbStack](https://orbstack.dev/), or [Colima](https://github.com/abiosoft/colima).
- Node.js 18+ (for npm and the bundled `@devcontainers/cli`).

## One-time install

```bash
npm install -g aicontainer
```

That puts `aic` on your PATH and pulls `@devcontainers/cli` in as a dependency. To upgrade later: `npm update -g aicontainer`.

**Try-before-install:** `npx aicontainer init` works too, but `aic up` / `aic shell` / etc. are repeated commands — install globally once and you won't pay the npx download tax every time.

Prefer a git checkout? `git clone https://github.com/stefanoginella/aicontainer ~/.aicontainer && ~/.aicontainer/install.sh` still works — `aic` resolves its templates relative to its own location, so both layouts behave the same. With a checkout you'll also need `npm install -g @devcontainers/cli` separately, and `aic upgrade` does the `git pull`.

### Shell completion

Optional but recommended. `aic completion <shell>` emits a completion script for **bash**, **zsh**, or **fish** — pick the line for your shell:

```bash
echo 'eval "$(aic completion bash)"' >> ~/.bashrc
echo 'eval "$(aic completion zsh)"'  >> ~/.zshrc
aic completion fish > ~/.config/fish/completions/aic.fish
```

Then reopen your shell. You'll get tab-completion for subcommands (`init`, `sync`, `up`, …), their flags (`--build`, `--force`, `--with`, `--pull`, `--shell`), and the `--with` / `--shell` values (`claude-code`, `codex`, `opencode`, `claude-code,codex,opencode` and `zsh`, `bash`, `fish`).

## First-time auth

Authenticate once. Tokens land in the global `aic-auth-global` volume and are reused across every project.

```bash
mkdir -p ~/sandbox/scratch && cd ~/sandbox/scratch
aic init
aic up
aic shell

# Inside the container:
claude /login           # OAuth flow in your host browser
codex auth login        # OpenAI auth
opencode auth login     # pick a provider (Anthropic, OpenAI, OpenCode Zen, …)
gh auth login           # GitHub (use a fine-grained PAT if you can)
npm login               # only if you publish packages — token persists too
```

After this, every `aic up` in any project picks up the same credentials. You do not need to re-log in.

## Per-project usage

```bash
cd my-project
aic init           # writes a 2-file .devcontainer/ that pulls the GHCR image
aic up             # pulls ghcr.io/stefanoginella/aicontainer:vX.Y.Z (pinned to your aic version), starts container + socket-proxy
aic shell          # opens the configured interactive shell (zsh by default)
claude             # runs in bypass mode (permissions skip)
codex              # runs in auto-approve mode (sandbox off)
opencode           # runs with permissions set to allow (guardrail still on)
```

`aic init` defaults to **pull mode**: it drops in only `devcontainer.json` and `docker-compose.yml`, and `aic up` pulls the prebuilt image from GHCR (≈30s on a warm runtime, vs. several minutes to build from scratch). Everything else — the Dockerfile, `post-create.py`, the firewall script, hooks — is baked into the image.

If you want to own the build (custom apt packages, air-gapped environments, hacking on the base image), run `aic init --build` instead. That copies the full template — `Dockerfile`, `post-create.py`, hooks, helper scripts — into `.devcontainer/`, and `aic up` builds the image locally.

Other commands: `aic run CMD ...` runs a one-shot inside the container without opening a shell, and `aic down` stops the container without removing its volumes (resume with `aic up`). Full list in `aic help`.

### Choosing tools per project

By default `aic init` enables Claude Code, Codex, and OpenCode. To pick a subset, either answer the interactive checkbox prompt (↑/↓ move, space toggles, enter confirms) or pass `--with`:

```bash
aic init --with claude-code                  # claude only
aic init --with codex                        # codex only
aic init --with opencode                     # opencode only
aic init --with claude-code,codex,opencode   # all three (same as the default)
```

The selection is persisted as `containerEnv.AIC_TOOLS` in `.devcontainer/devcontainer.json`. `post-create.py` reads it to decide which tool's settings to seed, and the VS Code extensions list is filtered to match (the `anthropic.claude-code`, `openai.chatgpt`, and `sst-dev.opencode` extensions are dropped when their tool isn't selected). All three CLIs are still present in the image either way — you can re-enable a tool later with `aic sync --with claude-code,codex,opencode`. When stdin isn't a TTY (CI, piped installers), the prompt is skipped and all tools default to on.

### Choosing a shell per project

`aic init` also asks which interactive shell to use (or pass `--shell`). All three are pre-installed in the image:

```bash
aic init --shell zsh                # default: oh-my-zsh + powerlevel10k + MesloLGS NF
aic init --shell bash               # barebones bash, history + fnm
aic init --shell fish               # barebones fish, fnm
```

The choice is stored as `containerEnv.AIC_SHELL` in `.devcontainer/devcontainer.json`. `aic shell` launches that shell, and the VS Code terminal's default profile + font family are patched to match (zsh keeps `'MesloLGS NF', monospace` for p10k icons; bash/fish use plain `monospace` so you don't need a nerd font on the host). Change it later with `aic sync --shell bash`. When stdin isn't a TTY, the prompt is skipped and `zsh` is used.

### VS Code

If you work in VS Code, you can skip `aic up` and `aic shell` entirely — the editor handles both:

1. Install the **Dev Containers** extension `ms-vscode-remote.remote-containers`
2. `aic init` in your project (one time).
3. Open the project folder in the editor.
4. `Cmd+Shift+P` → **Dev Containers: Reopen in Container**.

The editor builds the image, brings up the compose stack (devcontainer + socket-proxy), runs `postCreateCommand`, and drops you into an integrated terminal that's already inside the container. `claude`, `codex`, and `opencode` are available immediately.

You can still use `aic` from a separate terminal at the same time — `aic rebuild`, `aic destroy`, etc. operate on the same compose project as the editor, so the two paths don't conflict.

## Claude Code plugin

Wiring aicontainer to a specific project is a handful of project-owned files — an
LSP server on `PATH`, a writable `.venv` volume, a `Dockerfile.project` for
Playwright, host-service env (see [Per-project overrides](#per-project-overrides-that-survive-aic-sync)).
The optional **aicontainer-setup** Claude Code plugin does that conversationally:
it detects your stack, checks whether a headless Linux devcontainer even fits,
then proposes and writes those files for you — and offers to install the `aic`
CLI first if it's missing. It also handles re-setup, auditing an existing
`.devcontainer/` and updating only what's missing, stale, or drifted. It's a
convenience layer over `aic init` / `aic sync`, not a requirement.

Install it from inside Claude Code:

```text
/plugin marketplace add stefanoginella/claude-code-plugins
/plugin install aicontainer-setup@stefanoginella-plugins
```

Then run it from a Claude Code session **on your host** — not inside the sandbox,
which mounts `.devcontainer/` read-only:

```text
/aicontainer-setup
```

It shows you the plan, writes the files once you approve, and stops *before*
pulling the multi-gigabyte image — you run `aic up` (or "Reopen in Container")
yourself.

Uninstall the plugin and drop the marketplace:

```text
/plugin uninstall aicontainer-setup@stefanoginella-plugins
/plugin marketplace remove stefanoginella-plugins
```

## What's in the box

`aic init` ships an opinionated image. Knowing the defaults up front beats discovering them by surprise.

**Security-driven defaults** (don't change casually — many are the actual sandbox boundary):

- **npm hardening**: `NPM_CONFIG_IGNORE_SCRIPTS=true` blocks `postinstall` RCE, the most common supply-chain vector. `NPM_CONFIG_MIN_RELEASE_AGE=1` rejects any package published in the last 24h (mitigates fast-moving malicious releases — npm interprets the value in days). `audit=true`, `fund=false`.
- **Locked config + shell rc**: `~/.gitconfig.local` is chowned `root:root 0444` after first run, so a compromised AI session can't inject `credential.helper` or `core.sshCommand` to capture tokens during in-container `git push` / `gh` flows. The baked login-shell rc files (`~/.zshrc`, `~/.bashrc`, fish config) are root-locked the same way, so a session can't plant a payload that runs on the next `aic shell`. Host `~/.gitconfig` is included read-only.
- **PreToolUse hook** (Claude, Codex + OpenCode, fires even with bypass/auto-approve/allow on) blocks:
  - reads of `.env*` files — via `Read`/`Edit`/`Write`/`Grep`/`Glob` and in Bash commands (allowing `.env.example|.sample|.template|.defaults`),
  - `curl|sh` / `wget|bash` fetch-and-execute in Bash (including `| sudo bash`, `| tee | sh`, and `bash -c "$(curl …)"` variants),
  - writes to `/etc/aic/`, `/workspace/.devcontainer/`, and the login-shell rc files (`~/.zshrc` / `~/.bashrc` / fish config + their `.local` includes) — defense-in-depth on top of the RO mounts and root-locks above.

  One script (`/etc/aic/hooks/pre-tool-use.sh`) is the single source of truth for all three tools: Claude registers it in `settings.json`, Codex via a managed hook, and OpenCode via a small plugin (`opencode-guardrail.js`) that translates its tool calls and shells out to the same script.
- **Forced AI sandbox settings** — host config can't loosen these: Claude `permissions.defaultMode=bypassPermissions` + hook registration, Codex `approval_policy=never` + `sandbox_mode=danger-full-access` + hook registration, OpenCode `permission."*"=allow` + the guardrail plugin. See [Config seeding from the host](#config-seeding-from-the-host) for the full allowlist/dropped fields.
- **Container global gitignore** covers `.env*`, `.claude/`, `.codex/`, `node_modules/`, `.venv/`, `__pycache__/`, `.DS_Store` — fewer ways to accidentally commit a secret.
- **No host credential forwarding**: no SSH-agent socket, no `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` passthrough, no host `gh` token. You log in once *inside* the container; tokens persist in `aic-auth-global`. Because the SSH agent and `~/.ssh` aren't forwarded, host **commit signing** can't work in here either — use [`aic signing`](#commit-signing) for the sandbox-key alternative.

**Developer-experience defaults** (personal taste; override in `Dockerfile.project` if you disagree):

- **Shell**: defaults to `zsh` + `oh-my-zsh` + `powerlevel10k` + `zsh-autosuggestions` + `zsh-syntax-highlighting`. `bash` and `fish` are also baked into the image (barebones, with history + fnm) — pick one at init time via `--shell zsh|bash|fish` (see [Choosing a shell per project](#choosing-a-shell-per-project)). When using zsh, p10k expects [MesloLGS NF](https://github.com/romkatv/powerlevel10k#meslo-nerd-font-patched-for-powerlevel10k) on your terminal (see Troubleshooting); bash/fish use plain `monospace`.
- **Editor**: `$EDITOR=nano`, `$VISUAL=nano`. `vim` is installed but isn't default.
- **Runtimes**: Python 3.13 via [`uv`](https://github.com/astral-sh/uv); Node 24 LTS via [`fnm`](https://github.com/Schniz/fnm) (so projects can override per-`.nvmrc`).
- **CLI utilities**: `ripgrep`, `fd-find`, `fzf`, `tmux`, `jq`, `gh`, `docker` CLI (+ buildx, compose), `semgrep`, [`git-delta`](https://github.com/dandavison/delta) (wired in as `core.pager` and `interactive.diffFilter`).
- **VS Code extensions** auto-installed when you open in the editor: `anthropic.claude-code`, `openai.chatgpt`, `sst-dev.opencode` (each gated by `AIC_TOOLS`), `eamodio.gitlens`, `pflannery.vscode-versionlens`, `BracketPairColorDLW.bracket-pair-color-dlw`, `vincaslt.highlight-matching-tag`, `yzhang.markdown-all-in-one`. Add your own per project (e.g. the Python or TypeScript editor stack) via [`.devcontainer/vscode-extensions` and `vscode-settings.json`](#project-specific-vs-code-extensions--settings).
- **VS Code terminal settings**: default profile + font family follow the project's `AIC_SHELL` (zsh → `MesloLGS NF`; bash/fish → `monospace`), right-click pastes, only `http/https/mailto/vscode` link schemes opened (`file://` OSC 8 links suppressed to dodge [microsoft/vscode#211443](https://github.com/microsoft/vscode/issues/211443)).
- **Misc env**: `PYTHONDONTWRITEBYTECODE=1`, `PIP_DISABLE_PIP_VERSION_CHECK=1`, `GIT_CONFIG_GLOBAL=/home/vscode/.gitconfig.local` (so the host gitconfig stays read-only).

If you want a different baseline, see [Installing extra tools](#installing-extra-tools) for the project-Dockerfile pattern — most of the dev-experience choices can be flipped in 2-3 lines there.

## Installing extra tools

Two ways, depending on whether the tool is throwaway or part of the project.

### (a) Ad-hoc inside the running container

For things you'll need for an hour:

```bash
aic shell
uv tool install <python-cli>      # ruff, semgrep, ...
npm install -g <node-cli>
```

These are **wiped on `aic destroy` or `aic rebuild`**. Fine for exploration; not for things your project depends on.

> Note: `sudo` inside the container is scoped to three security wrappers (`aic-chown-volumes`, `aic-lock-gitconfig`, `aic-firewall`) — bare `apt-get`, `chown`, etc. are denied (this is what blocks an in-container AI from escalating to root). To install apt packages, put them in a project Dockerfile (below) and `aic rebuild`.

### (b) Persistent, in a project Dockerfile

For tools your project depends on — language runtimes, DB clients, linters teammates need too.

Create `.devcontainer/Dockerfile.project`:

```dockerfile
# Match the tag your .devcontainer/docker-compose.yml pins (set by `aic init`
# to your installed aic version). This tag is project-owned, so `aic sync`
# never rewrites it — after `npm update -g aicontainer`, sync re-pins
# docker-compose.yml and WARNS that this FROM has drifted; run
# `aic sync --bump-base` to rewrite it to match. (If it drifts and an override
# build: points here, the stale base is what actually runs — see below.)
FROM ghcr.io/stefanoginella/aicontainer:vX.Y.Z

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql-client redis-tools terraform \
    && rm -rf /var/lib/apt/lists/*

USER vscode
RUN uv tool install ruff \
    && uv tool install pre-commit
```

Edit `.devcontainer/docker-compose.yml` and swap the `image:` line for a build block pointing at the new file:

```yaml
services:
  devcontainer:
    # image: ghcr.io/stefanoginella/aicontainer:vX.Y.Z   # was this
    build:
      context: .
      dockerfile: Dockerfile.project
```

Then `aic rebuild`. The tools survive `aic destroy` and are versioned with the project — teammates get the same environment.

> If you ran `aic init --build` instead of the default, your `Dockerfile.project` should use `FROM aicontainer-base:latest` (the locally-built tag) and the compose file already has a `build:` block — just change `dockerfile: Dockerfile` to `dockerfile: Dockerfile.project`.

**Rule of thumb:** if you'd be annoyed to reinstall it after every container rebuild, put it in `Dockerfile.project`. If you're just trying something, install ad-hoc.

#### Recipe: Playwright (browser tests / automation / MCP)

A browser is the one tool you *can't* add ad-hoc here: Chromium needs apt system libraries (and runtime `sudo apt` is blocked), and if you've enabled the [firewall](#opt-in-network-allowlist) the browser-download CDN isn't on the allowlist. `Dockerfile.project` sidesteps both — image builds run with full network, so Chromium is baked into the image and works offline afterward, even with the firewall on.

```dockerfile
# .devcontainer/Dockerfile.project
FROM ghcr.io/stefanoginella/aicontainer:vX.Y.Z   # match your pinned tag

# Pin to the Playwright version your project uses (the @playwright/test in
# package.json), so the baked browser revision matches what resolves at runtime.
ARG PLAYWRIGHT_VERSION=1.50.0

USER root
# Chromium's system libraries. apt is root-only and runtime `sudo apt` is
# blocked, so this step has to live in the image.
RUN export PATH="$FNM_DIR:$PATH" && eval "$(fnm env)" \
    && npx --yes playwright@${PLAYWRIGHT_VERSION} install-deps chromium

USER vscode
# Download Chromium into ~/.cache/ms-playwright, baked into the image layer.
# This explicit step is REQUIRED: the base image sets NPM_CONFIG_IGNORE_SCRIPTS
# =true, so `npm i @playwright/test` won't auto-download the browser via its
# postinstall — you have to run `playwright install` yourself.
RUN export PATH="$FNM_DIR:$PATH" && eval "$(fnm env)" \
    && npx --yes playwright@${PLAYWRIGHT_VERSION} install chromium
```

Swap the compose `image:` line for the `build:` block shown above, then `aic rebuild`.

- **If Chromium won't launch, disable its sandbox.** Depending on your Docker runtime's capability/seccomp setup, Chromium's own sandbox may fail to start inside the container. If you hit launch errors, set `chromiumSandbox: false` in `playwright.config.ts` (or pass `--no-sandbox` for ad-hoc launches) — the standard Chromium-in-Docker fix.
- **Testing `localhost` needs no firewall change** — loopback is always allowed, so driving your own dev server works even with the allowlist enabled. Only pointing the browser at the public internet (with the firewall on) means adding hosts to `.devcontainer/firewall-allowlist`.
- **Playwright [MCP](https://github.com/microsoft/playwright-mcp)** (`@playwright/mcp`) reuses the same baked Chromium — just add it to `mcpServers` (it's seeded from your host config like any other MCP). One recipe covers both `playwright test` and MCP-driven browsing.

## Per-project overrides that survive `aic sync`

`devcontainer.json` and `docker-compose.yml` are **template-managed** — `aic init` writes them and `aic sync` overwrites them (only your `AIC_TOOLS` / `AIC_SHELL` choices are carried across). So don't hand-edit those two files for project-specific tweaks; your edits get reset on the next sync/upgrade.

> `aic` also drops a **`.devcontainer/README.md`** into every project spelling out this exact managed-vs-project-owned split — it's there mostly so an AI agent poking at the devcontainer edits the right files (and learns it can't edit `devcontainer.json`) instead of fighting the sync. That README is itself template-managed, so don't edit it either; the project-owned files below are where customization lives.

Instead, drop a **`.devcontainer/docker-compose.override.yml`**. It's project-owned: `aic` never copies over it, and `aic init` / `aic sync` auto-append it to `dockerComposeFile` in `devcontainer.json`, so the wiring is re-applied every sync. Docker Compose merges it on top of the base file (override wins).

This is the right home for anything you'd otherwise have put in `containerEnv` or the compose service — env vars, `extra_hosts`, extra mounts, ports:

```yaml
# .devcontainer/docker-compose.override.yml
services:
  devcontainer:
    environment:
      # Reach a dev stack running on the HOST (Compose env outranks the mounted
      # .env for libraries like pydantic-settings, so these win in-container
      # while the host keeps using .env's localhost).
      DATABASE_URL: postgresql://user:pass@host.docker.internal:5432/mydb
      VALKEY_URL: redis://host.docker.internal:6379/0
    # Docker Desktop (macOS/Windows) resolves host.docker.internal automatically.
    # On a Linux host, add it explicitly:
    # extra_hosts:
    #   - "host.docker.internal:host-gateway"
```

Run `aic rebuild` after editing. Verify the wiring landed with `grep dockerComposeFile .devcontainer/devcontainer.json` (you should see both files in the array).

> The same file is also the sync-safe place to point at a [`Dockerfile.project`](#b-persistent-in-a-project-dockerfile): put the `build:` block in the override instead of editing `docker-compose.yml`. Compose merges `build:` onto the base service; `aic rebuild` refreshes the base image, then rebuilds your layer on top.

### Persisting a named volume (and fixing its ownership)

A common override is a **named volume** over a build artifact you don't want on the bind-mounted workspace — a Python `.venv`, `node_modules`, a language cache — so it persists across rebuilds and dodges the macOS bind-mount performance hit:

```yaml
# .devcontainer/docker-compose.override.yml
services:
  devcontainer:
    volumes:
      - myproject-venv:/workspace/.venv
      - myproject-uv-cache:/home/vscode/.cache/uv
volumes:
  myproject-venv:
  myproject-uv-cache:
```

There's a catch: Docker initializes a **fresh named volume as `root:root`**, and `updateRemoteUserUID` only remaps the user *inside* the container, not the daemon's volume-init UID. So `vscode` can't write into the mount and your `uv` / `npm` install fails. (You can't fix this with `sudo chown` from inside — in-container sudo is scoped to three aic helper scripts, not general `chown`.)

The sync-safe fix is a project-owned **`.devcontainer/chown-paths`** — one mountpoint per line; `aic-chown-volumes` re-owns each to `vscode` on container creation:

```
# .devcontainer/chown-paths — re-owned to vscode on container create.
# Only paths under /workspace/ or /home/vscode/.cache/ are honored.
/workspace/.venv
/home/vscode/.cache/uv
```

Like `firewall-allowlist`, this file is opt-in (read only if present), never touched by `aic sync`, and read-only inside the container (an in-container tool can't edit it). The prefix allowlist is a hard security boundary baked into the image — paths outside `/workspace/` and `/home/vscode/.cache/` are refused, so the re-own can't be pointed at sudoers, the hooks, or `~/.gitconfig.local`. Keep tool caches under `~/.cache/` (e.g. `CARGO_HOME=/home/vscode/.cache/cargo` in the override) so they fall inside the allowlist.

> Already created the volume root-owned from an earlier run? `aic-chown-volumes` fixes it on the next `aic rebuild`. If it was populated by a partial install, `docker volume rm <name>` once and let it re-init clean.

### Project-specific post-create steps

Need to run something on every container creation — `lefthook install`, `pre-commit install`, `npm ci`, seeding a local DB? Don't edit `devcontainer.json`'s `postCreateCommand` (clobbered every sync) or `post-create.py` (it's baked into the image and isn't even in your repo in pull mode). Drop a **`.devcontainer/post-create.project.sh`**:

```bash
# .devcontainer/post-create.project.sh — runs as `vscode`, cwd /workspace,
# after all aic setup, on every container create. Opt-in by presence.
#!/usr/bin/env bash
set -euo pipefail
lefthook install
```

The base `post-create.py` runs it last, after the AI tools, git config, and volume ownership are all wired up, so your steps see a fully configured environment. Like `firewall-allowlist` and `chown-paths`, it's opt-in (run only if present), never touched by `aic sync`, and read-only inside the container — the [PreToolUse hook](#threat-model) blocks an in-container tool from editing anything under `.devcontainer/`, so the script stays host-only-editable. It's invoked via `bash <file>` (no executable bit needed), runs with no privilege the in-container agent doesn't already have, and a non-zero exit is logged as a warning during `aic up` without failing container creation — its output streams through so you can see what happened.

### Project-specific VS Code extensions & settings

`devcontainer.json` is the only place that auto-installs editor extensions and applies machine-scope settings, but it's **regenerated wholesale on every `aic init`/`aic sync`** — so hand-editing its `customizations.vscode` block doesn't survive (and an in-container agent can't edit anything under `.devcontainer/` at all). Two project-owned files are merged in instead, both opt-in by presence and never touched by sync:

- **`.devcontainer/vscode-extensions`** — one [extension id](https://marketplace.visualstudio.com/) (`publisher.name`) per line, `#` comments allowed. Merged into `customizations.vscode.extensions`, so they auto-install when you reopen in the container.
- **`.devcontainer/vscode-settings.json`** — a JSON object, merged into `customizations.vscode.settings`.

```
# .devcontainer/vscode-extensions
ms-python.python
ms-python.vscode-pylance
```

```jsonc
// .devcontainer/vscode-settings.json
{
  "python.defaultInterpreterPath": "/workspace/.venv/bin/python"
}
```

Run `aic sync` (host-side) then `aic rebuild`; verify with `grep ms-python .devcontainer/devcontainer.json`. Invalid extension lines (anything that isn't a `publisher.name` id) are warned about and skipped, so a stray line can't smuggle JSON into `devcontainer.json`.

> **Conflict rule:** the merge lands your entries *before* aic's own, so on a key collision aic's default wins *inside `devcontainer.json`*. The common case (adding new keys like `python.*`) never collides. To override a key aic sets (e.g. a `terminal.integrated.*` value), use a standard workspace **`.vscode/settings.json`** — workspace settings beat devcontainer machine-scope settings, survive sync on their own, and aren't aic-managed.

#### Recipe: Python LSP (editor **and** agent)

There are two LSP surfaces. The **editor's** IntelliSense comes from the extensions + settings below. The **agent's** LSP tool (Claude Code's go-to-def / find-refs) is separate: it needs the `pyright-langserver` binary on `PATH`, which you install from [`post-create.project.sh`](#project-specific-post-create-steps) so it survives rebuilds:

```
# .devcontainer/vscode-extensions
ms-python.python
ms-python.vscode-pylance      # editor IntelliSense / LSP
charliermarsh.ruff            # if the project uses ruff
ms-python.mypy-type-checker   # if mypy is your type gate
```

```jsonc
// .devcontainer/vscode-settings.json
{
  "python.defaultInterpreterPath": "/workspace/.venv/bin/python",
  "ruff.importStrategy": "fromEnvironment",
  "mypy-type-checker.importStrategy": "fromEnvironment",
  "python.analysis.typeCheckingMode": "off"  // mypy is the type gate; Pylance for nav only
}
```

```bash
# .devcontainer/post-create.project.sh — give the agent's LSP tool a Python server
command -v pyright-langserver >/dev/null || npm i -g pyright || echo "[post-create] pyright install failed"
```

> Install `pyright`, **not** `basedpyright` — Claude Code's LSP tool looks for the `pyright-langserver` binary, which the `pyright` package provides (`basedpyright` ships `basedpyright-langserver`).

#### Recipe: Stop VS Code auto-activating a `.venv` in the terminal

With the Python extension installed (e.g. from the recipe above) **and** a project `.venv`, VS Code auto-activates it by *typing and running* `source /workspace/.venv/bin/activate` in every new integrated terminal. In this container the terminal mostly exists to launch AI CLIs, so that injected line lands at the prompt and clobbers the command you're starting (`claude`, `opencode`, `codex`). Turn it off — the first key covers the classic `ms-python.python`, the second the newer **Python Environments** extension (whose default `command` mode is the usual culprit):

```jsonc
// .devcontainer/vscode-settings.json
{
  "python.terminal.activateEnvironment": false,
  "python-envs.terminal.autoActivationType": "off"
}
```

Then `aic sync` (host-side) and `aic rebuild`. This is the editor injecting *and running* the line — distinct from the harmless Claude Code prompt *pre-fill* covered in [Troubleshooting](#troubleshooting), which never executes.

#### Recipe: TypeScript / JavaScript LSP (editor **and** agent)

VS Code bundles the TypeScript language service with the editor, so the editor half is mostly lint/format extensions. The agent's LSP tool wants the `typescript-language-server` binary on `PATH`:

```
# .devcontainer/vscode-extensions
dbaeumer.vscode-eslint
esbenp.prettier-vscode
```

```jsonc
// .devcontainer/vscode-settings.json
{
  "editor.defaultFormatter": "esbenp.prettier-vscode",
  "editor.formatOnSave": true,
  "eslint.format.enable": true
}
```

```bash
# .devcontainer/post-create.project.sh — give the agent's LSP tool a TS server
command -v typescript-language-server >/dev/null || npm i -g typescript typescript-language-server || echo "[post-create] ts language server install failed"
```

> Claude Code's built-in LSP tool reads the binary off `PATH` (on older Claude releases it's gated behind `ENABLE_LSP_TOOL=1`). The baked Node toolchain plus a global `npm i -g` is enough — no Dockerfile change needed.

## Updating AI tools

Claude Code, Codex and OpenCode refresh to their latest release **on every `aic
rebuild`**, in both pull and build mode: `post-create.py` runs `claude update`,
`codex update` and `opencode upgrade` each time the container is (re)created. The
pinned image is just the baseline they're layered on.

```bash
aic rebuild   # in a project: recreate the container → all enabled CLIs update to latest
```

The refresh is fail-soft — with no network it keeps the version baked into the image
and the container still comes up. For a fully reproducible sandbox, pin the tools too
by setting `AIC_FREEZE_TOOLS=1` in `.devcontainer/docker-compose.override.yml`.

> Codex and OpenCode install via their official standalone installers (not npm),
> mirroring Claude's native installer — so `codex update` / `opencode upgrade` work
> and neither CLI is subject to the `NPM_CONFIG_MIN_RELEASE_AGE` npm quarantine
> (which still governs npx-based MCP servers).

To update **aicontainer itself** — the `aic` CLI, the template, and the pinned base
image (base OS, Node, semgrep, hooks, …):

```bash
npm update -g aicontainer   # latest aic + template
aic sync                    # in each project: re-pin compose to the new aic version
aic rebuild                 # in each project: pull the new image
```

The pull-mode compose file pins `ghcr.io/stefanoginella/aicontainer:vX.Y.Z` to whatever aic version did `aic init` (or the last `aic sync`) — not `:latest`. This keeps the CLI and the in-container filesystem layout (hooks, sudoers, helper scripts) from drifting apart. To pick up a new image, bump aic and `aic sync` first; `aic rebuild` alone won't change the pinned tag.

aic nudges you when those versions drift, so a stale container doesn't go unnoticed:

- **`aic up` / `aic shell` / `aic rebuild`** print a warning (offline, no network) when this project's pinned image tag and your installed `aic` disagree — exactly the state you land in after `npm update -g aicontainer` before you've re-synced. The fix it points at is `aic sync && aic rebuild`. On `aic rebuild` it fires *before* the pull — handy, because `rebuild` re-pulls the currently pinned tag, so you can abort and `aic sync` first instead of re-fetching the stale image. (Build-mode projects have no pinned tag, so they aren't checked.)
- **VS Code "Reopen / Rebuild in Container"** runs the same check (via the devcontainer's `initializeCommand`, host-side), since that path drives `devcontainer up` directly and never the `aic` CLI. The warning lands in the **Dev Containers output channel** (View → Output → "Dev Containers"), not a notification — so it's there if you go looking, but less in-your-face than the terminal warning above. It's best-effort: if `aic` isn't on the PATH VS Code launched with, the check is silently skipped and never blocks the container from coming up.
- **`aic version` / `aic upgrade`** tell you when a newer `aicontainer` has been published to npm. This check is cached for a day, fails silently when offline, and is skipped in CI.

Set `AIC_NO_UPDATE_CHECK=1` to silence both.

`:vX.Y.Z` tags are immutable once published — they capture the exact image built at release time. CI separately rebuilds and pushes a floating `ghcr.io/stefanoginella/aicontainer:latest` on a weekly schedule and on every template change merged to main, for users who prefer base-layer freshness over reproducibility; that tag isn't referenced by default, but you can opt in by editing `.devcontainer/docker-compose.yml`. In `--build` mode `aic rebuild` also does a no-cache local rebuild of the baked image layers (base OS, Node, semgrep, and the Claude/Codex/OpenCode floor); the post-create refresh above then floats all three CLIs to latest regardless of mode.

The 2 files (pull mode) or full set (build mode) under `.devcontainer/` are not refreshed by `aic rebuild` on their own — they're created once by `aic init`. If a new template version changes them (e.g. a docker-compose mount), run `aic sync` to re-copy from the installed template into `./.devcontainer/`, then `aic rebuild`. `aic sync` auto-detects pull vs. build mode, preserves the project's `AIC_TOOLS` and `AIC_SHELL` selections (pass `--with` / `--shell` to change them), and leaves project-owned files (`Dockerfile.project`, `firewall-allowlist`, `chown-paths`, `post-create.project.sh`, `docker-compose.override.yml`) untouched — re-wiring an existing [`docker-compose.override.yml`](#per-project-overrides-that-survive-aic-sync) into `dockerComposeFile` so per-project compose tweaks survive the sync.

## Multi-project model

> **Your transcripts survive.** Session history is a first-class part of the
> model, not an afterthought. `~/.claude/projects/`, `~/.codex/sessions/`, and
> OpenCode's session db live in a **per-project named volume**
> (`<proj>_aic-sessions`), so they survive container recreation (`aic rebuild`,
> `aic up`) without ever being written back to your host home — the host's
> `~/.claude/projects/` is *not* mounted. The only thing that clears them is
> `aic destroy` (which says so before it does). So you get isolation *and*
> durable decision history.

What's shared across all aicontainer projects on your host vs. what's per-project:

| | Scope | Volume |
|---|---|---|
| `~/.claude`, `~/.codex`, `~/.local/share/opencode`, `~/.config/gh`, `~/.config/npm` (auth + plugins + recent-session metadata), `semgrep` login token | **Global** | `aic-auth-global` (subpath mounts + `SEMGREP_SETTINGS_FILE`) |
| Shell history (`.zsh_history`) | **Global** | `aic-shell-history` |
| Claude session JSONLs (`~/.claude/projects/`) | **Per-project** | `<proj>_aic-sessions` |
| Codex session history (`~/.codex/sessions/`, `history.jsonl`) | **Per-project** | `<proj>_aic-sessions` |
| OpenCode session db (`OPENCODE_DB`) + storage | **Per-project** | `<proj>_aic-sessions` |
| Project source code | Bind mount | `${PWD}` |
| p10k theme, host gitconfig | Bind mount RO | host `~/.p10k.zsh`, host `~/.gitconfig` |
| Claude / Codex / OpenCode global config (seed) | Bind mount RO | host `~/.claude/settings.json`, `~/.claude/statusline/`, `~/.codex/config.toml`, `~/.config/opencode/opencode.json` |

The Claude/Codex per-project rows are dir-level symlinks pointing out of `aic-auth-global` into `<proj>_aic-sessions`, so atomic-rename writes to files *inside* those directories stay project-scoped. OpenCode keeps its sessions in a sqlite db, which is relocated into the same per-project volume via the `OPENCODE_DB` env var (with its `storage/` and `snapshot/` dirs symlinked there too, so working-tree checkpoints stay project-scoped).

Two consequences:
- Log in once, work on twenty projects.
- Per-project chat history (`~/.claude/projects/`, `~/.codex/sessions/`, OpenCode's db) is isolated — a compromised AI in project A can't read project B's transcripts. **But** anything else under `~/.claude` / `~/.codex` / `~/.local/share/opencode` — recent-session metadata, plugins, caches, `history.jsonl` — is shared across projects via `aic-auth-global`, alongside the auth tokens. Accept this trade-off knowingly.

### Config seeding from the host

On first container creation, `post-create.py` reads `~/.claude/settings.json`, `~/.codex/config.toml` and `~/.config/opencode/opencode.json` from the read-only seed mounts above and copies an **allowlisted subset** of fields into the container's config. Security-critical fields are then force-overwritten:

| Field | Container always sets |
|---|---|
| Claude `permissions.defaultMode` | `bypassPermissions` |
| Claude `hooks` | the aicontainer PreToolUse hook |
| Codex `approval_policy` | `never` |
| Codex `sandbox_mode` | `danger-full-access` |
| OpenCode `permission` | `{ "*": "allow" }` |
| OpenCode `plugin` | the aicontainer guardrail plugin |

Claude's PreToolUse hook is forced into `~/.claude/settings.json`. Codex's isn't seeded into `config.toml` (a hook there is *untrusted* and skipped in autonomous mode) — it's baked as a **managed** hook in `/etc/codex/requirements.toml`, which Codex auto-trusts and the in-container user can't disable. OpenCode's guardrail is forced in as a `plugin` entry pointing at the root-owned `opencode-guardrail.js`, which calls the same shared script.

Seeded (when present on the host): Claude `env`, `statusLine`, `enabledPlugins`, `mcpServers` / `enabledMcpjsonServers`, `theme`, `model`, `effortLevel`, `editorMode`, `verbose`, `fileCheckpointingEnabled`, `outputStyle`, plus a handful of other preference fields. Codex `model`, `model_reasoning_effort`, `personality`, `[features]`, `[notice]`, `[projects.*]`, `[mcp_servers.*]`. OpenCode `provider`, `model`, `small_model`, `mcp`, `agent`, `instructions`, `theme`, `keybinds`, `formatter`, `lsp`.

**Dropped from the host (never seeded):** Claude `permissions.allow/deny/ask`, Claude `hooks`, Claude `apiKeyHelper` / `awsAuthRefresh` / `awsCredentialExpiration`, Codex top-level `approval_policy` / `sandbox_mode`, Codex `[hooks.*]`, OpenCode `permission` / `plugin` (we force them) **and any inline provider API key** (`provider.*.options.apiKey` and similar — scrubbed recursively). These either defeat the in-container sandbox or carry host-specific auth secrets.

**MCPs:** seeded for all three tools. An MCP that references a host-only binary (e.g. `/Applications/Foo.app/...`) won't start in the container — the agent logs the failure and continues. URL-based MCPs (`context7`, `openaiDeveloperDocs`, etc.) and npm-installed MCPs work as on the host. MCP server secrets carried in env/headers ride along with the seed (same accepted trade-off across all three tools). If you want a different MCP set in the container than on the host, edit `~/.claude/settings.json`, `~/.codex/config.toml`, or `~/.config/opencode/opencode.json` inside the container (all writable by the dev user).

**Providers (OpenCode):** custom provider/model definitions in your host `opencode.json` (e.g. a DeepSeek endpoint or a local model list) carry over so they're available as options — but **provider API keys are never forwarded** (the inline `apiKey` is stripped from the seed). Run `opencode auth login` inside the container once; the credential persists across rebuilds in `aic-auth-global`.

**Statusline:** if your host `statusLine.command` references a script under `~/.claude/`, the path is rewritten to `/host-seed/claude/...` and the script is run from the RO mount. Scripts that live elsewhere on the host need a custom bind mount added to `.devcontainer/docker-compose.yml`.

**Host paths NOT mounted:** `~/.claude/projects/`, `~/.claude/.credentials.json`, `~/.claude.json`, `~/.codex/sessions/`, `~/.codex/auth.json`, `~/.codex/history.jsonl`, `~/.local/share/opencode/auth.json`. Chat history and auth tokens stay on the host; the container builds its own via `claude /login`, `opencode auth login`, etc. on first run.

## Commit signing

If you sign commits on your host (`commit.gpgsign=true`, SSH or GPG), that won't work inside the sandbox out of the box: your signing key lives on the host, and aicontainer deliberately does **not** forward `~/.ssh` or the SSH agent (see the [threat model](#threat-model)). Git would otherwise fail every commit with `Couldn't find key in agent`.

So when a signing host has no sandbox key set up, aicontainer turns signing **off inside the container** (commits succeed, unsigned) and prints a one-line notice — rather than letting `git commit` fail cryptically.

To get signed commits *without* weakening the boundary, provision a **sandbox-only signing key** with `aic signing`:

```bash
aic up                 # the container must be running
aic signing auto       # mint an ed25519 signing key in the aic-auth-global volume
                       #   (add --register to push its pubkey to GitHub via gh)
aic rebuild            # apply — post-create wires the key into the container gitconfig
```

`aic signing auto` prints the public key; register it on GitHub as a **Signing Key** (Settings → SSH and GPG keys → New → *Signing Key*, **not** Authentication), or pass `--register` to have `gh` do it (needs the `write:ssh_signing_key` scope). Other modes:

- `aic signing byok` — install a *separate* signing key you provide (`aic signing byok < your_key`, or drop it at `~/.config/aic-auth/signing/id_ed25519`).
- `aic signing disable` — keep commits unsigned in the sandbox (silences the notice).
- `aic signing status` — show the current state.

The key lives only in the `aic-auth-global` volume (never on your host), is shared across all your projects (register once), and survives rebuilds. The choice is applied on the next `aic rebuild`, because the container gitconfig is regenerated and root-locked at create time — there's no live edit (and so no privileged unlock an in-container process could abuse).

> **What this means for "Verified".** The signing key lives where the AI runs, so commits the agent makes will show as **Verified** on GitHub. That's exactly right if your goal is satisfying a branch-protection *"require signed commits"* rule — but it is *not* a statement that a human reviewed the commit. If you want sandbox commits to stay distinguishable and independently revocable, use a distinct signing key (and optionally a distinct committer identity) for it.

## Threat model

**Sandboxed:**
- **Filesystem**: host is inaccessible except for the project directory (RW) and a handful of read-only mounts: shell look-and-feel (`~/.gitconfig`, `~/.p10k.zsh`, `~/.zshrc.local`) and the AI-config seeds (`~/.claude/settings.json`, `~/.claude/statusline/`, `~/.codex/config.toml`, `~/.config/opencode/opencode.json`) covered in [Config seeding from the host](#config-seeding-from-the-host).
- **Process namespace**: container processes don't see host processes.
- **Docker daemon**: API surface reduced via socket-proxy. `EXEC`, `AUTH`, `SECRETS`, `SWARM`, `SYSTEM` (and friends) are blocked. `POST` to `/containers` and `/build` is **enabled** so testcontainers, `docker compose up`, and sibling-container tooling work from inside the devcontainer — but this also means anyone with shell access here can `docker run --privileged -v /:/host` against the host daemon. Treat the proxy as a footgun reducer, not a host-isolation boundary; don't run untrusted code inside.
- **AI guardrails**: `.devcontainer/`, `.git/config`, `.git/hooks` are mounted **read-only** so the AI cannot rewrite its own configuration. The PreToolUse hook lives at `/etc/aic/hooks/` and is root-owned, not writable by the dev user. The scoped sudoers entry only exposes hardcoded-target wrappers (`aic-chown-volumes`, `aic-lock-gitconfig`, `aic-firewall`) — no bare `chown`, so AI cannot take ownership of `/etc/sudoers.d/` or `/etc/aic/` to escalate.

**Not sandboxed (unless you opt in):**
- **Network**: full outbound access by default. Anything inside the container can reach `api.openai.com`, `api.anthropic.com`, your LAN, and cloud metadata services (`169.254.169.254`). To restrict this, opt in to the [iptables allowlist](#opt-in-network-allowlist) below.
- **Git identity**: your `~/.gitconfig` is read-only mounted, so the AI can commit and push as you (via `gh auth` or stored credentials). Your signing key is **not** forwarded; if you need signed commits in here, set up a sandbox-only key with [`aic signing`](#commit-signing) — note that this makes agent-authored commits show as Verified.
- **Host credentials**: nothing is auto-forwarded. The AI only has access to what you explicitly `claude /login`, `codex auth login`, `opencode auth login`, `gh auth login` for inside the container.

Don't run this on a network where reaching internal services or cloud metadata is a concern — or enable the allowlist below.

## Opt-in network allowlist

For projects where you want stricter containment (reviewing untrusted code, working on a corporate LAN, paranoid about exfiltration), enable the bundled iptables allowlist from inside the container:

```bash
aic shell
sudo aic-firewall enable          # apply DROP-default policy with curated allowlist
sudo aic-firewall status          # inspect rules + resolved IPs
```

The default allowlist covers Anthropic / OpenAI / OpenCode (`opencode.ai`, `models.dev`) / GitHub / npm / PyPI / Docker registries. Per-project extras go in `.devcontainer/firewall-allowlist` (one domain per line, `#` comments allowed). Re-run `sudo aic-firewall enable` after editing.

Design notes:
- The script is **enable-only**. There is no `disable` or `pause` subcommand and the scoped sudoers entry only allows this single script — so an AI that gets shell access can call it, but only to *strengthen* the policy, never to remove it.
- To turn the firewall off, `aic rebuild` from the host (this script doesn't survive container recreation).
- `NET_ADMIN` and `NET_RAW` are granted to the container so the script can manage iptables. The caps are confined to the container's network namespace — they do not affect the host's networking.

## FAQ

**Doesn't Claude Code's new auto mode make this unnecessary?** No — they're
complementary. Claude Code's [auto mode](https://www.anthropic.com/engineering/claude-code-auto-mode)
runs a classifier that reviews each action before it executes and blocks the
obviously destructive ones, which is great, but Anthropic themselves recommend
running it *in an isolated environment* because it "reduces risk but doesn't
eliminate it." That isolated environment is exactly what aicontainer provides.
Auto mode also isn't available on every plan yet, and it doesn't cover
`--dangerously-skip-permissions` or Codex's `--full-auto` / sandbox-off, which
have no classifier at all. The sandbox is the boundary; auto mode is a smarter
agent *inside* it. Run both.

## Troubleshooting

**Docker not running.** Start Docker Desktop / OrbStack / Colima. `aic up` won't even try without it.

**`devcontainer: command not found`.** Normally bundled with `npm install -g aicontainer`. If you installed via git checkout, run `npm install -g @devcontainers/cli`.

**Powerlevel10k glyphs look wrong.** Install the [Meslo Nerd Font](https://github.com/romkatv/powerlevel10k#meslo-nerd-font-patched-for-powerlevel10k) and set it as your terminal font.

**Powerlevel10k prints "Type `p10k configure` to customize" on every shell.** Your host doesn't have a `~/.p10k.zsh` yet. The container bind-mounts that file **read-only**, so configuration has to happen on the host:

```bash
# On the host (outside the container):
p10k configure        # if you have p10k installed on the host
# or, install p10k briefly to generate the config:
brew install powerlevel10k && p10k configure
```

After `~/.p10k.zsh` exists on the host, the next `aic shell` picks it up automatically. Running `p10k configure` *inside* the container won't work — the mount is read-only by design (so AI can't rewrite your shell).

**Claude Code pre-fills `source /workspace/.venv/bin/activate` in the prompt on startup.** Harmless — Claude spots a project `.venv/` that isn't active and *suggests* (never runs) activating it. It shows up because aicontainer deliberately keeps `VIRTUAL_ENV` unset, so `uv` always resolves the project environment cleanly. To suppress it, mark the venv active for interactive shells from your host `~/.zshrc.local` — bind-mounted **read-only**, so it survives rebuilds/syncs and an in-container tool can't edit it:

```bash
# On the host, in ~/.zshrc.local (sourced on every `aic shell`):
if [[ -d /workspace/.venv ]]; then
  export VIRTUAL_ENV=/workspace/.venv
  export PATH="/workspace/.venv/bin:$PATH"
fi
```

Setting the vars directly — rather than `source`-ing `/workspace/.venv/bin/activate` — is deliberate: it gives Claude the signal it checks for without executing a script out of the tool-writable workspace on every shell start. The `[[ -d … ]]` guard keeps it a no-op in projects with no root `.venv` (the file is shared across all your projects on this host). zsh only — bash/fish have no host `.local` include.

If instead the same line is being *typed and run* into the terminal (clobbering a `claude`/`opencode` you just launched), that's the VS Code Python extension, not Claude — see [Recipe: Stop VS Code auto-activating a `.venv` in the terminal](#recipe-stop-vs-code-auto-activating-a-venv-in-the-terminal).

**`aic shell` succeeds but `claude` errors with permission issues.** `post-create.py` runs during `aic up`, not on shell entry — scroll the `aic up` output for `[post-create]` warnings (volume ownership, hook setup, settings write). `aic rebuild` re-runs it cleanly.

**Tools installed ad-hoc disappeared.** That's expected — see "Installing extra tools" above. Move them to `Dockerfile.project`.

**Codex prompts for approval despite auto-approve.** Make sure `~/.codex/config.toml` exists (it's written by `post-create.py`). Re-run `aic rebuild` if the file is missing.

**Codex VS Code sidebar asks for approval, or a command fails with `bwrap: No permissions to create a new namespace` / "The sandbox cannot create a namespace here".** `post-create.py` already forces `~/.codex/config.toml` to `sandbox_mode = danger-full-access` + `approval_policy = never`, so the **main** Codex agent runs without prompts (verify with `cat ~/.codex/config.toml`). Two things can still surface a prompt:

- **Sidebar mode.** The extension's built-in *Full access* preset tries to start Codex's own sandbox. Pick **Custom (config.toml)** in the mode menu so the sidebar uses the forced `danger-full-access` — the only mode that skips the inner sandbox.
- **Review / sub-agent workflows.** Codex's built-in *Code Review* feature (and spawned sub-agents) currently don't inherit `danger-full-access` and fall back to `workspace-write` ([openai/codex#15305](https://github.com/openai/codex/issues/15305), [#5090](https://github.com/openai/codex/issues/5090)). Inside the container that sandbox can't create a namespace, so Codex asks to run the command *outside the sandbox*. **That's safe to allow here** — "outside the [inner] sandbox" just means "normally inside the container," which is the isolation aicontainer already provides — so click **Yes** (or *Yes, and don't ask again…*). Workaround: run the review as a **normal turn** (e.g. invoke the review skill/command directly in the chat) instead of via Codex's *Code Review* entry point — a main-loop turn inherits `danger-full-access` and won't prompt. It's an upstream Codex bug, not an aicontainer misconfiguration.

Either way, don't "fix" bwrap by granting `SYS_ADMIN` / `seccomp=unconfined` / unprivileged user namespaces — that lets the AI nest a sandbox by weakening the container's own boundary, which is the whole point of running here.

## Uninstall

```bash
# In each project:
aic destroy          # shows the session-transcript volume size and confirms
                     # first (irreversible); add --yes to skip the prompt

# Globally:
docker volume rm aic-auth-global aic-shell-history
npm uninstall -g aicontainer        # or, for a git checkout:
                                    #   rm -rf ~/.aicontainer ~/.local/bin/aic
```

## Releasing

For maintainers. Releases are tag-driven — pushing a `v*` git tag is the only thing that publishes a new `:vX.Y.Z` image to GHCR or a new version to npm.

From a clean `main`:

```bash
git checkout main && git pull
# Release notes should already be under ## [Unreleased] in CHANGELOG.md (add
# them as you work). `npm version` promotes that section to the new version.
npm version patch         # or: minor / major. Promotes the changelog, bumps,
                          # commits, and creates the v* tag.
git push --follow-tags    # pushes both the commit and the tag
```

`release.yml` then fires on the tag and ships, in one atomic flow:
- `ghcr.io/stefanoginella/aicontainer:vX.Y.Z` (immutable)
- `ghcr.io/stefanoginella/aicontainer:latest` (floats forward)
- `aicontainer@X.Y.Z` on npm with provenance attestation
- a GitHub Release for the tag, with notes pulled from `CHANGELOG.md`

A guard step rejects the run if the `v*` tag doesn't match `package.json`'s `version` — so `npm version` is the only sane way to mint a release tag.

`CHANGELOG.md` is **hand-maintained** ([Keep a Changelog](https://keepachangelog.com/) format) — you write the prose; nothing is auto-generated from commits. Add notes under `## [Unreleased]` as you work. At release time `npm version` does the mechanical promotion for you: a `version` lifecycle script (`scripts/promote-changelog.mjs`) relabels `## [Unreleased]` to `## [X.Y.Z] - <date>`, opens a fresh empty `[Unreleased]`, and fixes the compare links — all from notes you authored. A `preversion` check aborts the bump if `[Unreleased]` is empty, so you can't release nothing. The GitHub Release notes are the resulting `## [X.Y.Z]` section, pulled verbatim, and `release.yml` greps for that section before any publish as a backstop. The `.githooks/pre-push` hook enforces the same check locally; enable it once per clone with `git config core.hooksPath .githooks`.

### Day-to-day pushes vs. releases

|              | What triggers it                                  | What ships                                              |
| ---          | ---                                               | ---                                                     |
| Feature PR   | merge to `main`, touches `template/**`            | `:latest` + weekly tag refresh. Nothing on npm.         |
| Feature PR   | merge to `main`, only touches `aic`/README        | Nothing.                                                |
| Release      | `npm version <bump> && git push --follow-tags`    | `:vX.Y.Z` (immutable) + `:latest` + npm publish + GitHub Release. |
| Weekly cron  | Mondays 06:00 UTC                                 | `:latest` + `:weekly-YYYY-VV` refresh. No npm activity. |

Because `aic init` pins users to `:v{installed-aic-version}`, **only a release reaches pinned users**. Template-only merges to `main` refresh `:latest` (an opt-in track), not anyone's pinned image. Lean toward small, frequent patch releases when you fix something users should pick up — there is no "hidden" template change for pinned users.

### Picking the bump

- **patch**: security/freshness rebuild, internal Dockerfile cleanup, hook fix that doesn't change behavior, docs important enough to ship. Most releases.
- **minor**: added an `aic` command/flag, added a tool, added a template field. Backwards-compatible.
- **major**: removed a flag, changed default behavior, restructured `.devcontainer/` files in a way that breaks `aic sync` for existing projects.

### Hotfix / rollback

`:vX.Y.Z` is immutable; you cannot republish under the same tag. To fix a bad release, ship another patch (revert or fix-forward, your choice):

```bash
git revert <bad-commit>   # or just fix forward
npm version patch
git push --follow-tags
```

Users on a bad version can pin to a known-good earlier release:

```bash
npm install -g aicontainer@<previous>
cd my-project && aic sync && aic rebuild
```

### Things not to do

- **Don't `npm publish` from your laptop.** CI uses `--provenance`; manual publishes skip the supply-chain attestation users get to verify.
- **Don't push a `v*` tag without bumping `package.json` first.** Use `npm version`, which keeps the two in lockstep. The CI guard will fail the release otherwise.
- **Don't bump `package.json` as part of a feature PR.** Version bumps are their own commit (created by `npm version`) so the tag points at a clean release commit, not a multi-purpose merge.
- **Don't force-push or rewrite tags on `main`.** GHCR already received whatever the tag was bound to; rewriting history creates ghost tags and confused users.
- **Don't tag a release without a `CHANGELOG.md` entry for it.** CI refuses to publish a version that has no `## [X.Y.Z]` section, so you'd just burn a tag. Update the changelog *before* `npm version`.

## Contributing & security

Bugs, ideas, and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for ground rules, the development loop, and what won't be merged. By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

Security findings: please **don't** open a public issue. Use GitHub's [private security advisory flow](https://github.com/stefanoginella/aicontainer/security/advisories/new) instead.

## License

[MIT](./LICENSE) © 2026 Stefano Ginella
