# aicontainer

[![npm version](https://img.shields.io/npm/v/aicontainer?logo=npm)](https://www.npmjs.com/package/aicontainer)
[![release](https://github.com/stefanoginella/aicontainer/actions/workflows/release.yml/badge.svg)](https://github.com/stefanoginella/aicontainer/actions/workflows/release.yml)
[![rebuild](https://github.com/stefanoginella/aicontainer/actions/workflows/rebuild.yml/badge.svg)](https://github.com/stefanoginella/aicontainer/actions/workflows/rebuild.yml)
[![License: MIT](https://img.shields.io/npm/l/aicontainer?color=yellow)](LICENSE)
[![Container: GHCR](https://img.shields.io/badge/container-ghcr.io-2188ff?logo=github)](https://github.com/stefanoginella/aicontainer/pkgs/container/aicontainer)
[![Devcontainer spec](https://img.shields.io/badge/devcontainer-spec-blue?logo=visualstudiocode)](https://containers.dev/)

A sandboxed devcontainer for running [Claude Code](https://claude.ai/code), [Codex](https://github.com/openai/codex), and [OpenCode](https://opencode.ai) in bypass / auto-approve mode safely across multiple projects.

**Why?** Auto-approve is the only way these CLIs actually fly — but pointed at your real `$HOME` it also lets a prompt-injected dependency read `.env`, exfiltrate shell history, or push through your `gh` token. `aicontainer` puts the AI behind a devcontainer boundary so you can keep auto-approve on without rebuilding your machine each time.

**What you get:** filesystem isolation, **no Docker object access by default**
through a digest-pinned [socket proxy](https://github.com/Tecnativa/docker-socket-proxy),
a minimal shared tool hook, an always-on cloud-metadata/link-local block, and an
**opt-in** outbound allowlist. Host preferences are reduced to fixed safe fields
before the agent sees them; logins still carry across projects. Defaults are
listed in [What's in the box](#whats-in-the-box) so you know exactly what you're
adopting.

> Adjacent work: same shape as the [Trail of Bits devcontainer](https://github.com/trailofbits/claude-code-devcontainer), with Codex and OpenCode added, three explicit Docker-access modes, and managed shell/config startup.

## What crosses the boundary

At a glance, what the in-container agent can touch on your host. Run `aic
preflight` in any project to print this for your *actual* config (it's also
shown automatically at the end of every `aic up`).

| Surface | Crosses the boundary? |
|---|---|
| Project directory | **Yes, read-write** (`/workspace`) — the one writable host path. |
| Host Git / Claude / Codex / OpenCode config | The raw files are visible only to a fixed, root-only, networkless one-shot sanitizer. The agent receives root-owned JSON containing allowlisted preferences; executable Git config, inline credentials, MCP env/header secrets, and security-policy fields are removed. See [Config seeding](#config-seeding-from-the-host). |
| Host shell startup files (`.zshrc`, `.bashrc`, fish config, p10k) | **No.** Shells start from root-managed aicontainer profiles, so a previous session cannot plant startup code and host startup scripts never enter the sandbox. |
| Host home, `~/.ssh`, SSH-agent socket | **No** — not mounted, not forwarded. |
| Host credentials (API keys, `gh` token, keychain) | **No** — nothing auto-forwarded; you log in once *inside* the container. |
| Package-manager caches | **No** — container-local volumes, not your host caches. |
| Clipboard / browser | **No** — nothing bridged. |
| `.env*` files | Blocked from the agent by the [PreToolUse hook](#whats-in-the-box). Your project's own `.env` is physically in `/workspace`, but the hook stops the agent from reading it — defense-in-depth at the tool layer, not a missing file. |
| Session transcripts, prompt history, user-level skills/plugins/instructions | Persist in a **path-unique per-project volume**, never written back to your host home or shared with another checkout. See [Multi-project model](#multi-project-model). |
| Host Docker daemon | **Object APIs off by default**: only proxy ping/version remain. `--docker-read` opts into sensitive object/inspect/log/file APIs; `--docker` opts into read-write host-daemon control for testcontainers / in-container Compose. See [Threat model](#threat-model). |
| **Outbound network** | **Mostly open by default.** Reaches the internet and your LAN; IPv4/IPv6 link-local and common cloud-provider metadata endpoints are blocked on every create. Opt in to the [allowlist](#opt-in-network-allowlist) to restrict the rest. |

The full reasoning is in [Threat model](#threat-model); the network row is the
one most worth your attention.

## Prerequisites

- Docker Engine 25+ with Compose 2.24+ (volume-subpath support): [Docker
  Desktop](https://docker.com/products/docker-desktop),
  [OrbStack](https://orbstack.dev/), or
  [Colima](https://github.com/abiosoft/colima), or rootless Docker Engine,
  using a local Unix socket. aic discovers the selected context automatically.
- Node.js 18+ (for npm and the bundled `@devcontainers/cli`).
- A conventional Git checkout opened at its repository root (`.git` must be a
  directory so its config/hooks can be protected with exact read-only mounts).

Run `aic doctor` for an exact, non-mutating compatibility check.

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

Then reopen your shell. You'll get tab-completion for subcommands (`init`,
`sync`, `up`, `trust`, …), Docker modes (`--no-docker`, `--docker-read`,
`--docker`), and the `--with` / `--shell` values.

## First-time auth

Authenticate once. A networkless credential bridge synchronizes only the four
known tool credential JSON files into fixed subpaths of the global
`aic-auth-global` volume; GitHub, npm, signing, and Semgrep use their own fixed
subpaths. Prompt-bearing config, instructions, skills, plugins, and transcripts
stay in the current project's volume, so login convenience does not turn one
project's persistent instructions into another project's.

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
aic init           # writes a small managed .devcontainer/ that pulls the GHCR image
aic up             # pulls the version-pinned image, validates config, then starts the sandbox
aic shell          # opens the configured interactive shell (zsh by default)
claude             # runs in bypass mode (permissions skip)
codex              # runs in auto-approve mode (sandbox off)
opencode           # runs with permissions set to allow (guardrail still on)
```

`aic init` defaults to **pull mode**: it writes `devcontainer.json`,
`docker-compose.yml`, a managed guide/ignore file, and a gitignored `.env` with
the selected host socket and runtime UID/GID. `aic initialize` refreshes that
host-only file automatically, so rootless Docker, Docker Desktop, Colima, and
OrbStack need no aicontainer-specific flags. `aic up` pulls the prebuilt image
from GHCR (≈30s on a warm runtime, vs. several minutes to build from scratch).
Everything else — the Dockerfile, `post-create.py`, firewall, and hooks — is
baked into the image.

If you want to own the build (custom apt packages, air-gapped environments, hacking on the base image), run `aic init --build` instead. That copies the full template — `Dockerfile`, `post-create.py`, hooks, helper scripts — into `.devcontainer/`, and `aic up` builds the image locally.

Other commands: `aic run CMD ...` runs a one-shot inside the container without opening a shell, and `aic down` stops the container without removing its volumes (resume with `aic up`). Full list in `aic help`.

Every aic-launched startup validates the managed control files and fully
resolved Compose model before handing them to Dev Containers. The generated VS
Code initializer repeats the gate before Compose creates anything. Normal
generated projects stay silent. If a project intentionally adds a custom image,
host bind, device, capability, or namespace, review the findings and run `aic
trust` once; the exact-config approval lives outside the repository and expires
when the relevant config changes. For a single reviewed run, use `aic up
--allow-unsafe` or `aic rebuild --allow-unsafe`. Docker daemon visibility is a
separate opt-in: use `aic init --docker-read` / `aic sync --docker-read` or the
corresponding `--docker` form; matching consent also lives outside the
repository.

> **Direct VS Code bootstrap caveat:** Dev Containers must read the repository's
> `devcontainer.json` and execute its host-side `initializeCommand` before `aic
> initialize` can validate it. Never click **Reopen in Container** on an
> arbitrary repository-supplied `.devcontainer/`. Run `aic init --force` (or
> `aic sync` for an existing aicontainer project), inspect the resulting diff
> and project-owned override files, then use `aic up` or reopen in VS Code.

### Diagnostics and review

Three read-only commands make the boundary inspectable without starting or
changing the project:

```bash
aic doctor     # host prerequisites + project wiring, concise OK/WARN/FAIL
aic status     # identity, modes, runtime, credential bridge, and volumes
aic validate   # managed provenance + fully resolved Compose security model
```

`doctor` can run before `init`; it checks Node 18+, Docker Engine 25+ and
Compose 2.24+ (needed for volume subpaths), the selected local Unix socket,
the Dev Container CLI, Git/project-root shape, install integrity, and
control-path safety. Warnings remain exit 0; blockers exit nonzero. Standard,
rootless, Colima, OrbStack, and Docker Desktop Unix-socket contexts are
discovered automatically; remote TCP/SSH contexts, subdirectories below the
Git root, and worktree-style checkouts are reported explicitly rather than
failing later with an opaque Compose error.

`status` is a quick factual snapshot (including credential-bridge health) and
tolerates a stopped daemon. `validate` is suitable for CI: it never prompts or
records trust, honors an existing exact approval, and exits nonzero for managed
drift or an untrusted boundary expansion.

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

If you work in VS Code, you can skip `aic up` and `aic shell` after aic has
generated the control files — the editor handles both:

1. Install the **Dev Containers** extension `ms-vscode-remote.remote-containers`
2. `aic init` in your project (one time).
3. Open the project folder in the editor.
4. `Cmd+Shift+P` → **Dev Containers: Reopen in Container**.

The generated initializer runs the same host validation and volume migration as
`aic up`, sanitizes the host preference seeds in a networkless one-shot service,
brings up the devcontainer and socket-proxy, and drops you into an integrated
terminal. `claude`, `codex`, and `opencode` are available immediately. The host
`aic` CLI is required; the initializer checks common npm/Node-manager paths and
prints one install command if a GUI-launched editor cannot find it. Step 2 is
the host-control-plane boundary: do not directly reopen a devcontainer supplied
by an untrusted repository before aic has replaced and you have reviewed it.

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
- **Root-managed Git and shell startup**: a networkless sanitizer extracts only
  fixed, non-executable preferences (identity, line-ending, pull/push behavior,
  and signing intent) from the host Git config. A narrow helper validates the
  generated config and installs it once at `/etc/aic/user-config/gitconfig` as
  `root:root 0444`; credential helpers, aliases, includes, hooks, remotes, and
  command/path-bearing settings never cross. Zsh, Bash, and fish likewise start
  from root-owned aicontainer profiles, never writable user or host rc files.
- **PreToolUse hook** (Claude, Codex + OpenCode, fires even with bypass/auto-approve/allow on) blocks:
  - reads of `.env*` files — via `Read`/`Edit`/`Write`/`Grep`/`Glob` and in Bash commands (allowing `.env.example|.sample|.template|.defaults`),
  - `curl|sh` / `wget|bash` fetch-and-execute in Bash (including `| sudo bash`, `| tee | sh`, and `bash -c "$(curl …)"` variants),
  - writes to `/etc/aic/`, `/workspace/.devcontainer/`, and the login-shell rc files (`~/.zshrc` / `~/.bashrc` / fish config + their `.local` includes) — defense-in-depth on top of the RO mounts and root-locks above.

  One script (`/etc/aic/hooks/pre-tool-use.sh`) is the single source of truth for all three tools: Claude registers it in `settings.json`, Codex via a managed hook, and OpenCode via a small plugin (`opencode-guardrail.js`) that translates its tool calls and shells out to the same script.
- **Forced AI sandbox settings** — root-managed policy, not writable user
  config, enforces Claude `permissions.defaultMode=bypassPermissions` + hook,
  Codex `approval_policy=never` + `sandbox_mode=danger-full-access` + managed
  hook, and OpenCode `permission."*"=allow` + guardrail plugin. See [Config
  seeding](#config-seeding-from-the-host) for the preference allowlist.
- **Reduced runtime privilege**: the devcontainer starts with every Linux
  capability dropped, then receives only the small set required by UID/GID
  startup, the fixed ownership helper, and its own network firewall. The raw
  Docker socket is hidden behind a root-only path used solely to verify named
  volumes; the agent talks only to the socket proxy.
- **Container global gitignore** covers `.env*`, `.claude/`, `.codex/`, `node_modules/`, `.venv/`, `__pycache__/`, `.DS_Store` — fewer ways to accidentally commit a secret.
- **No host credential forwarding**: no SSH-agent socket, API-key passthrough,
  host `gh` token, or literal secrets from seeded tool/MCP config. You log in
  once *inside* the container; tokens persist in hardened subpaths of
  `aic-auth-global`. Because the SSH agent and `~/.ssh` are absent, use [`aic
  signing`](#commit-signing) for a sandbox-only signing key.

**Developer-experience defaults** (personal taste; override in `Dockerfile.project` if you disagree):

- **Shell**: defaults to `zsh` + `oh-my-zsh` + `powerlevel10k` + `zsh-autosuggestions` + `zsh-syntax-highlighting`. `bash` and `fish` are also baked into the image (barebones, with history + fnm) — pick one at init time via `--shell zsh|bash|fish` (see [Choosing a shell per project](#choosing-a-shell-per-project)). When using zsh, p10k expects [MesloLGS NF](https://github.com/romkatv/powerlevel10k#meslo-nerd-font-patched-for-powerlevel10k) on your terminal (see Troubleshooting); bash/fish use plain `monospace`.
- **Editor**: `$EDITOR=nano`, `$VISUAL=nano`. `vim` is installed but isn't default.
- **Runtimes**: Python 3.13 via [`uv`](https://github.com/astral-sh/uv); Node 24 LTS via [`fnm`](https://github.com/Schniz/fnm) (so projects can override per-`.nvmrc`).
- **CLI utilities**: `ripgrep`, `fd-find`, `fzf`, `tmux`, `jq`, `gh`, `docker` CLI (+ buildx, compose), `semgrep`, [`git-delta`](https://github.com/dandavison/delta) (wired in as `core.pager` and `interactive.diffFilter`).
- **VS Code extensions** auto-installed when you open in the editor: `anthropic.claude-code`, `openai.chatgpt`, `sst-dev.opencode` (each gated by `AIC_TOOLS`), `eamodio.gitlens`, `pflannery.vscode-versionlens`, `BracketPairColorDLW.bracket-pair-color-dlw`, `vincaslt.highlight-matching-tag`, `yzhang.markdown-all-in-one`. Add your own per project (e.g. the Python or TypeScript editor stack) via [`.devcontainer/vscode-extensions` and `vscode-settings.json`](#project-specific-vs-code-extensions--settings).
- **VS Code terminal settings**: default profile + font family follow the project's `AIC_SHELL` (zsh → `MesloLGS NF`; bash/fish → `monospace`), right-click pastes, only `http/https/mailto/vscode` link schemes opened (`file://` OSC 8 links suppressed to dodge [microsoft/vscode#211443](https://github.com/microsoft/vscode/issues/211443)).
- **Misc env**: `PYTHONDONTWRITEBYTECODE=1`,
  `PIP_DISABLE_PIP_VERSION_CHECK=1`, and
  `GIT_CONFIG_GLOBAL=/etc/aic/user-config/gitconfig` (the validated root-managed
  config).

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

> Note: `sudo` inside the container is scoped to three fixed-purpose wrappers
> (`aic-chown-volumes`, `aic-lock-user-config`, `aic-firewall`) — bare
> `apt-get`, `chown`, etc. are denied. To install apt packages, use a reviewed
> project Dockerfile (below) and `aic rebuild`.

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

Point at it from the sync-safe
`.devcontainer/docker-compose.override.yml`; never edit the managed Compose
file:

```yaml
services:
  devcontainer:
    build:
      context: .
      dockerfile: Dockerfile.project
```

Run `aic sync`, inspect the resolved warning, then `aic trust` once and `aic
rebuild`. A project Dockerfile executes as root while the image is built and can
replace any sandbox helper, so aic intentionally treats every custom build as a
host-boundary expansion even when its `FROM` is the official base. The trust is
for the exact relevant config hash; changing the Dockerfile or override asks for
review again. The tools then survive rebuilds and are versioned with the project.

The example's `context: .` is deliberately bounded to `.devcontainer/`, so its
contents fit the persistent trust hash. A build context outside that directory
(for example `context: ..`) can change through arbitrary project files; `aic
trust` therefore refuses to persist it, and each reviewed `aic up`/`rebuild`
must use `--allow-unsafe`.

> If you ran `aic init --build`, use `FROM aicontainer-base:latest` and put only
> `build.dockerfile: Dockerfile.project` in the override; the same explicit
> trust step applies.

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

Use the project-owned override `build:` block shown above, then `aic sync`,
`aic trust`, and `aic rebuild`.

- **If Chromium won't launch, disable its sandbox.** Depending on your Docker runtime's capability/seccomp setup, Chromium's own sandbox may fail to start inside the container. If you hit launch errors, set `chromiumSandbox: false` in `playwright.config.ts` (or pass `--no-sandbox` for ad-hoc launches) — the standard Chromium-in-Docker fix.
- **Testing `localhost` needs no firewall change** — loopback is always allowed, so driving your own dev server works even with the allowlist enabled. Only pointing the browser at the public internet (with the firewall on) means adding hosts to `.devcontainer/firewall-allowlist`.
- **Playwright [MCP](https://github.com/microsoft/playwright-mcp)** (`@playwright/mcp`) reuses the same baked Chromium — just add it to `mcpServers` (it's seeded from your host config like any other MCP). One recipe covers both `playwright test` and MCP-driven browsing.

## Per-project overrides that survive `aic sync`

`devcontainer.json` and `docker-compose.yml` are **template-managed** — `aic
init` writes them and `aic sync` overwrites them. Tool, shell, and explicitly
consented Docker modes are re-applied; hand edits are not.

> `aic` also drops a **`.devcontainer/README.md`** into every project spelling out this exact managed-vs-project-owned split — it's there mostly so an AI agent poking at the devcontainer edits the right files (and learns it can't edit `devcontainer.json`) instead of fighting the sync. That README is itself template-managed, so don't edit it either; the project-owned files below are where customization lives.

Instead, drop a **`.devcontainer/docker-compose.override.yml`**. It's
project-owned: aic never overwrites it, automatically re-wires it on sync, and
validates the fully resolved result before any startup command. Ordinary env
and named-volume data mounts under `/workspace` or `/home/vscode/.cache` remain
frictionless. Host binds, bounded custom images/builds, devices, capabilities,
namespaces, external resources, or non-loopback published ports require an
exact-config `aic trust` approval stored outside the repo. A build context
outside `.devcontainer/` is unbounded and instead requires `--allow-unsafe` on
each reviewed `up`/`rebuild`.

Literal application environment values remain prompt-free. Active Compose
`$HOST_VAR` / `${HOST_VAR}` expressions and bare pass-through entries such as
`environment: [HOST_TOKEN]` require the same one-time trust because they forward
data from the host shell; validation names the variable but never prints its
resolved value. Use `$${VAR}` when the container should receive literal template
text. Overrides of managed startup variables (`PATH`, tool homes, Git/shell
config, loader variables, or `DOCKER_HOST`) also require review because they can
bypass the sandbox's startup and isolation wiring.

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

Run `aic sync` after first creating the override, inspect `git diff`, then `aic
rebuild`. If the validator reports a deliberate boundary expansion, run `aic
trust` after reviewing it.

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

Like `firewall-allowlist`, this file is opt-in, survives sync, and is read-only
inside the container. The privileged helper accepts only canonical, exact
Docker named-volume mountpoints under `/workspace/` or
`/home/vscode/.cache/`; it asks the daemon through a root-only socket for the
current container's mount metadata and rejects host binds, symlinks, nested
binds, external/custom drivers, and `local` volumes with bind-capable options.
Keep tool caches under `~/.cache/` so they fit this boundary.

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

### Personal shell config

Want your familiar zsh prompt and aliases inside the sandbox? The container's `~/.zshrc` is deliberately root-managed (so an in-container agent can't tamper with shell startup), so you don't edit it directly — you drop an **overlay** that's installed root-owned and **sourced last**, so your prompt/aliases win over the managed baseline (history, `fnm`, `PATH` still run first). zsh only.

Two files, both opt-in by presence, both never touched by `aic sync`:

- **`.devcontainer/shell-rc.zsh`** — personal zsh startup: aliases, functions, exports, prompt tweaks.
- **`.devcontainer/p10k.zsh`** — a [powerlevel10k](https://github.com/romkatv/powerlevel10k) config (the output of `p10k configure`).

```zsh
# .devcontainer/shell-rc.zsh
alias gs='git status'
alias ll='ls -lah'
export EDITOR=nvim
```

Prefer your **host** config instead of committing one per repo? Copy it into the aic-owned seed dir once and every project picks it up:

```bash
mkdir -p ~/.config/aicontainer
cp ~/.p10k.zsh ~/.config/aicontainer/p10k.zsh     # your host p10k prompt
cp ~/.zsh_aliases ~/.config/aicontainer/rc.zsh    # or any personal rc snippet
```

The host seed is read **read-only** by the seed sanitizer and copied verbatim; a project-owned `.devcontainer/` file wins over it when both exist. Run `aic sync` (host-side) then `aic rebuild`.

> ⚠️ **These files are copied verbatim — they can't be sanitized like the JSON configs.** They're shell *code*, executed inside a sandbox an autonomous agent can read. **Don't put secrets in them** (no tokens, no `export API_KEY=…`). Keep them to prompt/alias cosmetics. They run only as the unprivileged `vscode` user and, once installed, are root-locked so the agent can't modify them.

### Project-specific VS Code extensions & settings

`devcontainer.json` is the only place that auto-installs editor extensions and applies machine-scope settings, but it's **regenerated wholesale on every `aic init`/`aic sync`** — so hand-editing its `customizations.vscode` block doesn't survive (and an in-container agent can't edit anything under `.devcontainer/` at all). Two project-owned files are merged in instead, both opt-in by presence and never touched by sync:

- **`.devcontainer/vscode-extensions`** — one [extension id](https://marketplace.visualstudio.com/) (`publisher.name`) per line, `#` comments allowed. Merged into `customizations.vscode.extensions`, so they auto-install when you reopen in the container.
- **`.devcontainer/vscode-settings.json`** — a strict JSON object, parsed and
  re-serialized before merging. Invalid input is warned and skipped, and keys
  owned by aic are ignored with a warning; put intentional overrides in the repo's
  `.vscode/settings.json`, whose workspace scope wins.

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
reruns Codex's official unattended installer, and runs `opencode upgrade` each
time the container is (re)created. The pinned image is just the baseline they're
layered on.

```bash
aic rebuild   # in a project: recreate the container → all enabled CLIs update to latest
```

The refresh is fail-soft — with no network it keeps the version baked into the image
and the container still comes up. For a fully reproducible sandbox, pin the tools too
by setting `AIC_FREEZE_TOOLS=1` in `.devcontainer/docker-compose.override.yml`.

> Codex and OpenCode install via their official standalone installers (not npm),
> mirroring Claude's native installer. Codex refreshes by rerunning its installer
> noninteractively; OpenCode uses `opencode upgrade`. Neither CLI is subject to
> the `NPM_CONFIG_MIN_RELEASE_AGE` npm quarantine (which still governs npx-based
> MCP servers).

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
- **VS Code "Reopen / Rebuild in Container"** uses the aic-generated host-side
  initializer for the same drift check, fail-closed config validation, seed
  preparation, and legacy-session migration. Output lands in the **Dev
  Containers output channel**. A missing host CLI stops with an actionable
  install command because silently skipping it would also skip the security
  boundary. The direct-bootstrap caveat above still applies to repo-supplied
  control files.
- **`aic version` / `aic upgrade`** tell you when a newer `aicontainer` has been published to npm. This check is cached for a day, fails silently when offline, and is skipped in CI.

Set `AIC_NO_UPDATE_CHECK=1` to silence both.

`:vX.Y.Z` tags are immutable once published — they capture the exact image
built at release time. CI separately rebuilds the floating `:latest` and a
weekly tag with refreshed base layers and no stale build cache; managed
projects stay on immutable version tags. If you consciously prefer the floating
track, use a reviewed `Dockerfile.project` based on `:latest` rather than
editing the managed Compose file. In `--build` mode `aic rebuild` performs a
no-cache local build too.

The managed files under `.devcontainer/` are not refreshed by `aic rebuild`
alone. After upgrading, run `aic sync` and review the diff, then rebuild. Sync
preserves tool/shell selections and a previously consented Docker mode, leaves
all project-owned files untouched, and switches modes cleanly without stale
build artifacts.

The same sync migrates old basename-scoped projects to a deterministic Compose
name derived from the canonical project path. On the next sync/up/VS Code open,
aic automatically copies the legacy transcript volume only when an existing
container's exact workspace/project labels and session mount prove ownership,
with no differently owned container also mounting it; it likewise stops only a
legacy stack with an exact owned primary and no conflicting owner or unknown
service (known unlabeled aic sidecars are allowed; arbitrary orphans are never
removed). If no container remains to disambiguate a historically shared
basename volume, sync leaves it untouched and the next interactive `aic up`
asks once whether to import it (default no starts fresh and preserves the old
volume). A direct VS Code or other non-interactive start stops with that same
`aic up` hint rather than risking cross-project transcript disclosure.
Ownership-proven upgrades need no re-login or manual volume command, and two
checkouts with the same folder name no longer collide. The legacy container-side
`~/.claude-sessions` layout is likewise migrated to the tool-neutral
`~/.aic-sessions` volume path.

> **Upgrade friction:** for an ordinary or ownership-proven project the whole
> migration is still
> `npm update -g aicontainer && aic sync && aic rebuild`. Existing logins,
> transcripts, and tool/shell choices carry forward. Older releases had no
> outside-repository Docker consent record, so their inherited Docker exposure
> resets once to `none`; only users who need it re-enable it with `aic sync
> --docker-read` or `aic sync --docker`. An ambiguous historical basename
> volume adds the other one-time decision; clean generated projects add no
> prompt.

## Multi-project model

> **Your work survives without crossing projects.** Claude/Codex transcripts and
> prompt history, OpenCode's database/checkpoints, and user-level instruction,
> skill, command, rule, prompt, and plugin surfaces live in a path-unique
> **per-project named volume** (`aic-<folder>-<path-hash>_aic-sessions`). They
> survive `up`/`rebuild`, are never written into the host home, and are removed
> only by the explicitly confirmed `aic destroy`.

| Data | Scope | Storage |
|---|---|---|
| Claude/Codex/OpenCode login state; `gh`, npm and Semgrep login; sandbox signing key | **Global** | Fixed subpaths of `aic-auth-global` |
| Shell command history entered inside aicontainer | **Global** | `aic-shell-history` (host history is never mounted) |
| Claude/Codex transcripts and prompt history | **Per-project** | `<path-unique-project>_aic-sessions` |
| Claude/Codex user config, memory, skills, agents/commands, rules/prompts, plugins | **Per-project** | Whole tool homes below the same sessions volume |
| OpenCode config/instructions, session db, storage, and snapshots | **Per-project** | Same sessions volume; its two credential files are synchronized globally |
| Sanitized host preferences | **Per-project, regenerated** | `<path-unique-project>_aic-sanitized-seed`, read-only to the agent |
| Project source | Host bind | The current canonical project root at `/workspace` |

The unrestricted devcontainer never mounts the global Claude, Codex, or
OpenCode directories. Instead, each canonical tool home is a symlink into
`~/.aic-sessions/tool-homes/` in the current project's volume. A dedicated
networkless, capability-free sidecar is the only service that sees both those
homes and the three global tool-auth subpaths. It continuously reconciles four
exact files — Claude `.credentials.json`, Codex `auth.json`, and OpenCode
`auth.json` / `account.json` — so login, logout, and token refresh propagate
without sharing any other filename.

The bridge accepts only owner-matched, single-link, bounded JSON objects,
copies them atomically as mode `0600`, and ignores unsafe/malformed paths. Its
initial newer-wins reconciliation completes before the devcontainer starts.
GitHub/npm/signing/Semgrep use their own fixed global subpath mounts; the broad
auth-volume root is never exposed.

This preserves the easy part — log in once, work on twenty projects — while
removing cross-project prompt and transcript bleed. The deliberate remaining
trade-off is credentials: a compromised session in any project can use the
shared tokens you logged into inside aicontainer. Prefer least-privilege OAuth
grants and a fine-grained `gh` PAT. Global shell history is also readable by
every project; do not type secrets into shell commands.

### Config seeding from the host

Raw host config is never mounted into the unrestricted devcontainer. Before it
starts, a fixed root-only service with no network, no workspace, a read-only
root filesystem, and no auth/session mounts reads exactly four files:
`~/.gitconfig`, `~/.claude/settings.json`, `~/.codex/config.toml`, and
`~/.config/opencode/opencode.json`. It emits four root-owned JSON objects into a
per-project volume; the long-running agent receives that volume read-only.

The sanitizer copies only known preference fields and recursively removes
literal credential-bearing keys such as `env`, `headers`, `authorization`, API
keys, tokens, secrets, and passwords. Security-critical behavior is enforced
separately at root-managed precedence:

| Field | Container always sets |
|---|---|
| Claude `permissions.defaultMode` | `bypassPermissions` |
| Claude hook/policy | `/etc/claude-code/managed-settings.json` |
| Codex `approval_policy` | `never` |
| Codex `sandbox_mode` | `danger-full-access` |
| OpenCode `permission` | `{ "*": "allow" }` |
| OpenCode policy/plugin | `/etc/opencode/opencode.json` + the shared guardrail |

Codex's hook lives in `/etc/codex/requirements.toml` with a root-managed hook
directory; a user hook would be trust-gated and skipped in autonomous mode.
Claude and OpenCode use their supported system-managed configuration. All three
dispatch to the same root-owned guardrail script.

Seeded preferences include Claude model/theme/editor/effort and MCP/plugin
metadata; Codex model/personality plus `[features]`, `[notice]`, `[projects.*]`,
and `[mcp_servers.*]`; OpenCode provider/model/MCP/agent/instruction/theme/
keybind/formatter/LSP definitions; and a fixed non-executable set of Git
identity/workflow preferences.

Dropped fields include Claude permissions/hooks/auth helpers; Codex approval,
sandbox, and hooks; OpenCode permission/plugin and inline provider secrets; MCP
literal env/header credentials across all three; and every executable or
path-bearing Git key (`include`, aliases, credential helpers, hooks paths,
SSH commands, remotes, pagers/editors, signing-key paths). Git identity and safe
preferences are validated again before a fixed helper installs them once as
`root:root 0444`.

**MCPs:** metadata is seeded for all three tools. Host-only binaries will not
exist in Linux; URL-based and npm-installed servers generally work. Literal MCP
env/header credentials are deliberately removed, so authenticate inside the
sandbox or reference an in-container environment variable. Claude, Codex, and
OpenCode user config is project-scoped and reconciled from the sanitized seed
on recreate; root-managed policy remains separate from those writable homes.

**Providers (OpenCode):** custom provider/model definitions carry over, but
secret-looking provider keys are stripped recursively. Run `opencode auth
login` inside once; that credential persists globally.

**Host paths not exposed to the agent:** none of the raw config files above,
host tool history/transcripts/credentials, host statusline scripts, shell rc
files, `~/.ssh`, or the SSH agent. The container creates its own login state and
project data in Docker volumes.

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

The key lives only in the `aic-auth-global` volume (never on your host), is
shared across all your projects (register once), and survives rebuilds. The
choice is applied on the next `aic rebuild`, when
`/etc/aic/user-config/gitconfig` is validated and created as root-owned 0444 —
there is no live unlock/update primitive.

> **What this means for "Verified".** The signing key lives where the AI runs, so commits the agent makes will show as **Verified** on GitHub. That's exactly right if your goal is satisfying a branch-protection *"require signed commits"* rule — but it is *not* a statement that a human reviewed the commit. If you want sandbox commits to stay distinguishable and independently revocable, use a distinct signing key (and optionally a distinct committer identity) for it.

## Threat model

**Sandboxed:**
- **Filesystem**: the project is the only writable host path. Raw host tool/Git
  config appears only in the isolated one-shot sanitizer; the agent sees its
  fixed allowlisted JSON output read-only. Host home, shell startup files,
  `~/.ssh`, agent sockets, package caches, and tool history are absent.
- **Process namespace**: container processes don't see host processes.
- **Runaway limit**: the devcontainer runs with `pids_limit: 4096` so a fork bomb or a stuck agent loop can't exhaust host PIDs. Raise it (or add `mem_limit` / `cpus`) in `docker-compose.override.yml` if a workload needs more.
- **Docker daemon**: by default the digest-pinned proxy exposes only ping and
  version — no container/image/network/volume list, inspect, logs, archive
  reads, create, or build. `--docker-read` deliberately exposes object read
  APIs (which can reveal unrelated container metadata, logs, and files);
  `--docker` adds write/build and therefore permits host escape through a
  privileged sibling. Both opt-ins require matching consent stored outside the
  repository and survive sync until `--no-docker` revokes them.
- **Runtime privilege**: all Linux capabilities are dropped before adding the
  narrow helper/firewall set; `NET_RAW` stays absent. The raw Docker socket is
  reachable only below a root-owned `0700` directory and is used by the fixed
  ownership helper for bounded GET-only mount/volume inspection. The
  unrestricted user uses the proxy, never that socket.
- **Control plane**: `.devcontainer/`, `.git/config`, and `.git/hooks` are
  read-only inside. Managed hooks, tool policy, Git config, and shell startup
  live under root-owned system paths. Scoped sudo exposes only fixed-purpose
  wrappers with hardcoded destinations; the volume helper additionally proves
  each target is an ordinary named volume on the current container.
- **Cloud metadata / link-local**: every create adds strengthen-only drops for
  IPv4 link-local (`169.254.0.0/16`), Alibaba metadata
  (`100.100.100.200`), IPv6 link-local (`fe80::/10`), and AWS IMDSv6
  (`fd00:ec2::254`). These apply independently of the optional full allowlist.
- **Untrusted-repo guard**: aic-launched paths reject symlinked control inputs,
  verify every managed artifact, resolve all Compose layers without trusting a
  grep, and check services, mounts, builds, capabilities, namespaces, devices,
  ports, networks/volumes, includes/providers, configs/secrets, and protected
  path overlays before invoking Dev Containers. The generated initializer
  repeats this gate before Compose creation. Managed drift requires `aic sync`;
  an intentional boundary expansion needs `aic trust` or one-run
  `--allow-unsafe`, and repository edits cannot write either approval.

**Not sandboxed (unless you opt in):**
- **Direct VS Code bootstrap**: Dev Containers parses the repository's
  `devcontainer.json` and executes its `initializeCommand` on the host before
  `aic initialize` can run. aic cannot prevalidate an arbitrary repo-supplied
  initializer. Generate/review the managed files first; for an untrusted clone,
  start with `aic init --force`, inspect overrides, and prefer `aic up` for the
  first launch.
- **Network**: outbound is otherwise open by default — anything inside the container can reach `api.openai.com`, `api.anthropic.com`, and your LAN (cloud metadata excepted, see above). To restrict the rest, opt in to the [iptables allowlist](#opt-in-network-allowlist) below.
- **Git identity**: safe identity/workflow preferences are copied from the host,
  so the agent can commit as that identity and push with credentials you log
  into inside. Host credential helpers and signing keys are not forwarded; use
  [`aic signing`](#commit-signing) for a sandbox-only key.
- **Host credentials**: nothing is auto-forwarded. The AI only has access to what you explicitly `claude /login`, `codex auth login`, `opencode auth login`, `gh auth login` for inside the container. Note these tokens live in the shared `aic-auth-global` volume, so a compromised session in **any** project can use every token you've logged in with — prefer a fine-grained `gh` PAT.

Don't run this on a network where reaching internal services is a concern — or enable the allowlist below.

### Hardening the host daemon

The container's isolation is only as strong as the Docker daemon underneath it.
Two choices raise the floor, especially if you enable Docker write access for a
project:

- **Rootless Docker** ([docs](https://docs.docker.com/engine/security/rootless/)) or **`userns-remap`** ([docs](https://docs.docker.com/engine/security/userns-remap/)) make container-`root` map to an unprivileged host user, so even a `--privileged`/host-mount escape (the thing opt-in Docker write access would expose) doesn't land as real host root. OrbStack and Colima already run the daemon in a VM, which gives you a similar boundary on macOS.
- Keep Docker access at **none** (the default) for untrusted or prompt-injectable
  work. Opt into reads only when host object visibility is acceptable, and
  write mode only where testcontainers or host-daemon Compose is essential.

## Opt-in network allowlist

For projects where you want stricter containment (reviewing untrusted code, working on a corporate LAN, paranoid about exfiltration), enable the bundled iptables allowlist from inside the container:

```bash
aic shell
sudo aic-firewall enable          # apply DROP-default policy with curated allowlist
sudo aic-firewall status          # inspect rules + resolved IPs
```

The default allowlist covers Anthropic / OpenAI / OpenCode (`opencode.ai`,
`models.dev`) / GitHub / npm / PyPI / Docker registries. Per-project extras go
in `.devcontainer/firewall-allowlist` (one validated domain per line, `#`
comments allowed). Re-run `sudo aic-firewall enable` after editing.

Design notes:
- The script is **enable-only**. Re-enabling builds inactive IPv4/IPv6 rule
  generations, rejects zero-result or prohibited metadata resolutions, and
  atomically switches them into use; the prior DROP policy remains active on
  any failure. Metadata chains are never flushed.
- To turn the firewall off, `aic rebuild` from the host (this script doesn't survive container recreation).
- Only `NET_ADMIN` is needed for the firewall; `NET_RAW` remains dropped. If
  IPv6 is configured but cannot be filtered, `enable` refuses an
  IPv6-bypassable policy.

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

**Powerlevel10k asks to run `p10k configure`.** Shell startup is deliberately
root-managed and never imports the host's `.p10k.zsh`. The image suppresses the
interactive setup wizard and uses the bundled theme defaults. For a custom
prompt, choose Bash/fish or bake a reviewed config into `Dockerfile.project`;
do not add a writable home rc include.

**Claude Code pre-fills `source /workspace/.venv/bin/activate`.** Harmless —
Claude spotted a project venv and suggested (but did not run) activation. If
you want to suppress the suggestion without sourcing a tool-writable script on
every shell start, set `VIRTUAL_ENV: /workspace/.venv` in the project-owned
Compose override. This stays project-scoped and survives sync.

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

`release.yml` then fires on the tag and completes a restartable release flow:
- `ghcr.io/stefanoginella/aicontainer:vX.Y.Z` (immutable)
- `aicontainer@X.Y.Z` on npm with provenance attestation
- a GitHub Release for the tag, with notes pulled from `CHANGELOG.md`

All releases are globally serialized and never cancelled mid-publish. The
GHCR-writing jobs in the release and security-refresh workflows also share one
non-cancelling registry lock, while their workflow-level scheduling remains
independent. This closes the check-then-publish race around mutable tags.

A rerun verifies an existing npm tarball's integrity and accepts an existing
GHCR version only when its index annotations match the release commit, version,
and channel. A legacy unannotated version is preserved only when the matching
immutable npm tarball exists, and is never promoted to `:latest`; otherwise CI
fails rather than guessing. Missing sides can be published independently. npm
`latest` never moves backward (pre-releases use `next`; recovery runs use a
version-specific tag). GHCR `:latest` is promoted from the already-published
immutable manifest only when this version is npm latest and doing so would not
replace a newer security-refresh image.

Guard steps reject a tag whose commit is not on the default branch, whose name
doesn't match `package.json`, or whose changelog section is missing.

`CHANGELOG.md` is **hand-maintained** ([Keep a Changelog](https://keepachangelog.com/) format) — you write the prose; nothing is auto-generated from commits. Add notes under `## [Unreleased]` as you work. At release time `npm version` does the mechanical promotion for you: a `version` lifecycle script (`scripts/promote-changelog.mjs`) relabels `## [Unreleased]` to `## [X.Y.Z] - <date>`, opens a fresh empty `[Unreleased]`, and fixes the compare links — all from notes you authored. A `preversion` check aborts the bump if `[Unreleased]` is empty, so you can't release nothing. The GitHub Release notes are the resulting `## [X.Y.Z]` section, pulled verbatim, and `release.yml` greps for that section before any publish as a backstop. The `.githooks/pre-push` hook enforces the same check locally; enable it once per clone with `git config core.hooksPath .githooks`.

### Day-to-day pushes vs. releases

|              | What triggers it                                  | What ships                                              |
| ---          | ---                                               | ---                                                     |
| Runtime/CLI PR | merge to `main`, touches template, CLI, tests, package/scripts | Validate + refresh `:latest` / weekly tag. Nothing on npm. |
| Docs-only PR | merge to `main`                                   | Nothing published.                                      |
| Release      | `npm version <bump> && git push --follow-tags`    | Immutable `:vX.Y.Z`, npm, GitHub Release; conservative `:latest` promotion. |
| Weekly cron  | Mondays 06:00 UTC                                 | Pulled/no-cache `:latest` + `:weekly-YYYY-VV`; no npm.  |

Because `aic init` pins users to `:v{installed-aic-version}`, **only a release
reaches pinned users**. Runtime/CLI merges refresh the floating security track,
not anyone's version pin. Lean toward small, frequent patch releases when a fix
should reach ordinary users.

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
