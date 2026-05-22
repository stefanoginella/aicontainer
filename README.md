# aicontainer

[![npm version](https://img.shields.io/npm/v/aicontainer?logo=npm)](https://www.npmjs.com/package/aicontainer)
[![release](https://github.com/stefanoginella/aicontainer/actions/workflows/release.yml/badge.svg)](https://github.com/stefanoginella/aicontainer/actions/workflows/release.yml)
[![rebuild](https://github.com/stefanoginella/aicontainer/actions/workflows/rebuild.yml/badge.svg)](https://github.com/stefanoginella/aicontainer/actions/workflows/rebuild.yml)
[![License: MIT](https://img.shields.io/npm/l/aicontainer?color=yellow)](LICENSE)
[![Container: GHCR](https://img.shields.io/badge/container-ghcr.io-2188ff?logo=github)](https://github.com/stefanoginella/aicontainer/pkgs/container/aicontainer)
[![Devcontainer spec](https://img.shields.io/badge/devcontainer-spec-blue?logo=visualstudiocode)](https://containers.dev/)

A sandboxed devcontainer for running [Claude Code](https://claude.ai/code) and [Codex](https://github.com/openai/codex) in bypass / auto-approve mode safely across multiple projects.

**Why?** Auto-approve is the only way these CLIs actually fly — but pointed at your real `$HOME` it also lets a prompt-injected dependency read `.env`, exfiltrate shell history, or push through your `gh` token. `aicontainer` puts the AI behind a devcontainer boundary so you can keep auto-approve on without rebuilding your machine each time.

**What you get:** filesystem isolation, a filtered Docker socket via [Tecnativa's docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy), a minimal PreToolUse hook, and an **opt-in** iptables outbound allowlist. No AI-generated config, no per-project re-login. Defaults are listed in [What's in the box](#whats-in-the-box) so you know exactly what you're adopting.

> Adjacent work: same shape as the [Trail of Bits devcontainer](https://github.com/trailofbits/claude-code-devcontainer), with Codex added, Docker access turned on by default, and host shell look-and-feel preserved.

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

Then reopen your shell. You'll get tab-completion for subcommands (`init`, `sync`, `up`, …), their flags (`--build`, `--force`, `--with`, `--pull`, `--shell`), and the `--with` / `--shell` values (`claude-code`, `codex`, `claude-code,codex` and `zsh`, `bash`, `fish`).

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
```

`aic init` defaults to **pull mode**: it drops in only `devcontainer.json` and `docker-compose.yml`, and `aic up` pulls the prebuilt image from GHCR (≈30s on a warm runtime, vs. several minutes to build from scratch). Everything else — the Dockerfile, `post-create.py`, the firewall script, hooks — is baked into the image.

If you want to own the build (custom apt packages, air-gapped environments, hacking on the base image), run `aic init --build` instead. That copies the full template — `Dockerfile`, `post-create.py`, hooks, helper scripts — into `.devcontainer/`, and `aic up` builds the image locally.

Other commands: `aic run CMD ...` runs a one-shot inside the container without opening a shell, and `aic down` stops the container without removing its volumes (resume with `aic up`). Full list in `aic help`.

### Choosing tools per project

By default `aic init` enables both Claude Code and Codex. To pick a subset, either answer the interactive checkbox prompt (↑/↓ move, space toggles, enter confirms) or pass `--with`:

```bash
aic init --with claude-code         # claude only
aic init --with codex               # codex only
aic init --with claude-code,codex   # both (same as the default)
```

The selection is persisted as `containerEnv.AIC_TOOLS` in `.devcontainer/devcontainer.json`. `post-create.py` reads it to decide which tool's settings to seed, and the VS Code extensions list is filtered to match (the `anthropic.claude-code` and `openai.chatgpt` extensions are dropped when their tool isn't selected). Both CLIs are still present in the image either way — you can re-enable a tool later with `aic sync --with claude-code,codex`. When stdin isn't a TTY (CI, piped installers), the prompt is skipped and both tools default to on.

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

The editor builds the image, brings up the compose stack (devcontainer + socket-proxy), runs `postCreateCommand`, and drops you into an integrated terminal that's already inside the container. `claude` and `codex` are available immediately.

You can still use `aic` from a separate terminal at the same time — `aic rebuild`, `aic destroy`, etc. operate on the same compose project as the editor, so the two paths don't conflict.

## What's in the box

`aic init` ships an opinionated image. Knowing the defaults up front beats discovering them by surprise.

**Security-driven defaults** (don't change casually — many are the actual sandbox boundary):

- **npm hardening**: `NPM_CONFIG_IGNORE_SCRIPTS=true` blocks `postinstall` RCE, the most common supply-chain vector. `NPM_CONFIG_MIN_RELEASE_AGE=1440` rejects any package published in the last 24h (mitigates fast-moving malicious releases). `audit=true`, `fund=false`.
- **Locked git config**: `~/.gitconfig.local` is chowned `root:root 0444` after first run, so a compromised AI session can't inject `credential.helper` or `core.sshCommand` to capture tokens during in-container `git push` / `gh` flows. Host `~/.gitconfig` is included read-only.
- **PreToolUse hook** (Claude + Codex, fires even with bypass/auto-approve on) blocks:
  - reads/writes of `.env*` files (allowing `.env.example|.sample|.template|.defaults`),
  - `curl|sh` / `wget|bash` patterns in Bash,
  - writes to `/etc/aic/`, `~/.zshrc`, `/workspace/.devcontainer/` (defense-in-depth on top of the RO mounts).
- **Forced AI sandbox settings** — host config can't loosen these: Claude `permissions.defaultMode=bypassPermissions` + hook registration, Codex `approval_policy=never` + `sandbox_mode=danger-full-access` + hook registration. See [Config seeding from the host](#config-seeding-from-the-host) for the full allowlist/dropped fields.
- **Container global gitignore** covers `.env*`, `.claude/`, `.codex/`, `node_modules/`, `.venv/`, `__pycache__/`, `.DS_Store` — fewer ways to accidentally commit a secret.
- **No host credential forwarding**: no SSH-agent socket, no `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` passthrough, no host `gh` token. You log in once *inside* the container; tokens persist in `aic-auth-global`.

**Developer-experience defaults** (personal taste; override in `Dockerfile.project` if you disagree):

- **Shell**: defaults to `zsh` + `oh-my-zsh` + `powerlevel10k` + `zsh-autosuggestions` + `zsh-syntax-highlighting`. `bash` and `fish` are also baked into the image (barebones, with history + fnm) — pick one at init time via `--shell zsh|bash|fish` (see [Choosing a shell per project](#choosing-a-shell-per-project)). When using zsh, p10k expects [MesloLGS NF](https://github.com/romkatv/powerlevel10k#meslo-nerd-font-patched-for-powerlevel10k) on your terminal (see Troubleshooting); bash/fish use plain `monospace`.
- **Editor**: `$EDITOR=nano`, `$VISUAL=nano`. `vim` is installed but isn't default.
- **Runtimes**: Python 3.13 via [`uv`](https://github.com/astral-sh/uv); Node 24 LTS via [`fnm`](https://github.com/Schniz/fnm) (so projects can override per-`.nvmrc`).
- **CLI utilities**: `ripgrep`, `fd-find`, `fzf`, `tmux`, `jq`, `gh`, `docker` CLI (+ buildx, compose), `semgrep`, [`git-delta`](https://github.com/dandavison/delta) (wired in as `core.pager` and `interactive.diffFilter`).
- **VS Code extensions** auto-installed when you open in the editor: `anthropic.claude-code`, `openai.chatgpt` (each gated by `AIC_TOOLS`), `eamodio.gitlens`, `pflannery.vscode-versionlens`, `BracketPairColorDLW.bracket-pair-color-dlw`, `vincaslt.highlight-matching-tag`, `yzhang.markdown-all-in-one`.
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
# to your installed aic version). Use `aic sync` after `npm update -g
# aicontainer` to bump both at once.
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

## Updating AI tools

```bash
npm update -g aicontainer   # latest aic + template
aic sync                    # in each project: re-pin compose to the new aic version
aic rebuild                 # in each project: pull the new image
```

The pull-mode compose file pins `ghcr.io/stefanoginella/aicontainer:vX.Y.Z` to whatever aic version did `aic init` (or the last `aic sync`) — not `:latest`. This keeps the CLI and the in-container filesystem layout (hooks, sudoers, helper scripts) from drifting apart. To pick up a new image, bump aic and `aic sync` first; `aic rebuild` alone won't change the pinned tag.

`:vX.Y.Z` tags are immutable once published — they capture the exact image built at release time. CI separately rebuilds and pushes a floating `ghcr.io/stefanoginella/aicontainer:latest` on a weekly schedule and on every template change merged to main, for users who prefer base-layer freshness over reproducibility; that tag isn't referenced by default, but you can opt in by editing `.devcontainer/docker-compose.yml`. In `--build` mode `aic rebuild` does a no-cache local build that re-runs the `claude` and `codex` installers.

The 2 files (pull mode) or full set (build mode) under `.devcontainer/` are not refreshed by `aic rebuild` on their own — they're created once by `aic init`. If a new template version changes them (e.g. a docker-compose mount), run `aic sync` to re-copy from the installed template into `./.devcontainer/`, then `aic rebuild`. `aic sync` auto-detects pull vs. build mode, preserves the project's `AIC_TOOLS` and `AIC_SHELL` selections (pass `--with` / `--shell` to change them), and leaves project-owned files (`Dockerfile.project`, `firewall-allowlist`) untouched.

## Multi-project model

What's shared across all aicontainer projects on your host vs. what's per-project:

| | Scope | Volume |
|---|---|---|
| `~/.claude`, `~/.codex`, `~/.config/gh`, `~/.config/npm` (auth + plugins + recent-session metadata) | **Global** | `aic-auth-global` (subpath mounts) |
| Shell history (`.zsh_history`) | **Global** | `aic-shell-history` |
| Claude session JSONLs (`~/.claude/projects/`) | **Per-project** | `<proj>_aic-sessions` |
| Codex session history (`~/.codex/sessions/`, `history.jsonl`) | **Per-project** | `<proj>_aic-sessions` |
| Project source code | Bind mount | `${PWD}` |
| p10k theme, host gitconfig | Bind mount RO | host `~/.p10k.zsh`, host `~/.gitconfig` |
| Claude / Codex global config (seed) | Bind mount RO | host `~/.claude/settings.json`, `~/.claude/statusline/`, `~/.codex/config.toml` |

The per-project rows are dir-level symlinks pointing out of `aic-auth-global` into `<proj>_aic-sessions`, so atomic-rename writes to files *inside* those directories stay project-scoped.

Two consequences:
- Log in once, work on twenty projects.
- Per-project chat history (`~/.claude/projects/`, `~/.codex/sessions/`) is isolated — a compromised AI in project A can't read project B's transcripts. **But** anything else under `~/.claude` / `~/.codex` — recent-session metadata, plugins, caches, `history.jsonl` — is shared across projects via `aic-auth-global`, alongside the auth tokens. Accept this trade-off knowingly.

### Config seeding from the host

On first container creation, `post-create.py` reads `~/.claude/settings.json` and `~/.codex/config.toml` from the read-only seed mounts above and copies an **allowlisted subset** of fields into the container's config. Security-critical fields are then force-overwritten:

| Field | Container always sets |
|---|---|
| Claude `permissions.defaultMode` | `bypassPermissions` |
| Claude `hooks` | the aicontainer PreToolUse hook |
| Codex `approval_policy` | `never` |
| Codex `sandbox_mode` | `danger-full-access` |
| Codex `[hooks]` | the aicontainer pre_tool_use hook |

Seeded (when present on the host): Claude `env`, `statusLine`, `enabledPlugins`, `mcpServers` / `enabledMcpjsonServers`, `theme`, `model`, `effortLevel`, `editorMode`, `verbose`, `fileCheckpointingEnabled`, `outputStyle`, plus a handful of other preference fields. Codex `model`, `model_reasoning_effort`, `personality`, `[features]`, `[notice]`, `[projects.*]`, `[mcp_servers.*]`.

**Dropped from the host (never seeded):** Claude `permissions.allow/deny/ask`, Claude `hooks`, Claude `apiKeyHelper` / `awsAuthRefresh` / `awsCredentialExpiration`, Codex top-level `approval_policy` / `sandbox_mode`, Codex `[hooks.*]`. These either defeat the in-container sandbox or carry host-specific auth secrets.

**MCPs:** seeded for both Claude and Codex. An MCP that references a host-only binary (e.g. `/Applications/Foo.app/...`) won't start in the container — the agent logs the failure and continues. URL-based MCPs (`context7`, `openaiDeveloperDocs`, etc.) and npm-installed MCPs work as on the host. If you want a different MCP set in the container than on the host, edit `~/.claude/settings.json` or `~/.codex/config.toml` inside the container (both are writable by the dev user).

**Statusline:** if your host `statusLine.command` references a script under `~/.claude/`, the path is rewritten to `/host-seed/claude/...` and the script is run from the RO mount. Scripts that live elsewhere on the host need a custom bind mount added to `.devcontainer/docker-compose.yml`.

**Host paths NOT mounted:** `~/.claude/projects/`, `~/.claude/.credentials.json`, `~/.claude.json`, `~/.codex/sessions/`, `~/.codex/auth.json`, `~/.codex/history.jsonl`. Chat history and auth tokens stay on the host; the container builds its own via `claude /login` etc. on first run.

## Threat model

**Sandboxed:**
- **Filesystem**: host is inaccessible except for the project directory (RW) and a handful of read-only mounts: shell look-and-feel (`~/.gitconfig`, `~/.p10k.zsh`, `~/.zshrc.local`) and the AI-config seeds (`~/.claude/settings.json`, `~/.claude/statusline/`, `~/.codex/config.toml`) covered in [Config seeding from the host](#config-seeding-from-the-host).
- **Process namespace**: container processes don't see host processes.
- **Docker daemon**: API surface reduced via socket-proxy. `EXEC`, `AUTH`, `SECRETS`, `SWARM`, `SYSTEM` (and friends) are blocked. `POST` to `/containers` and `/build` is **enabled** so testcontainers, `docker compose up`, and sibling-container tooling work from inside the devcontainer — but this also means anyone with shell access here can `docker run --privileged -v /:/host` against the host daemon. Treat the proxy as a footgun reducer, not a host-isolation boundary; don't run untrusted code inside.
- **AI guardrails**: `.devcontainer/`, `.git/config`, `.git/hooks` are mounted **read-only** so the AI cannot rewrite its own configuration. The PreToolUse hook lives at `/etc/aic/hooks/` and is root-owned, not writable by the dev user. The scoped sudoers entry only exposes hardcoded-target wrappers (`aic-chown-volumes`, `aic-lock-gitconfig`, `aic-firewall`) — no bare `chown`, so AI cannot take ownership of `/etc/sudoers.d/` or `/etc/aic/` to escalate.

**Not sandboxed (unless you opt in):**
- **Network**: full outbound access by default. Anything inside the container can reach `api.openai.com`, `api.anthropic.com`, your LAN, and cloud metadata services (`169.254.169.254`). To restrict this, opt in to the [iptables allowlist](#opt-in-network-allowlist) below.
- **Git identity**: your `~/.gitconfig` is read-only mounted, so the AI can commit and push as you (via `gh auth` or stored credentials).
- **Host credentials**: nothing is auto-forwarded. The AI only has access to what you explicitly `claude /login`, `codex auth`, `gh auth login` for inside the container.

Don't run this on a network where reaching internal services or cloud metadata is a concern — or enable the allowlist below.

## Opt-in network allowlist

For projects where you want stricter containment (reviewing untrusted code, working on a corporate LAN, paranoid about exfiltration), enable the bundled iptables allowlist from inside the container:

```bash
aic shell
sudo aic-firewall enable          # apply DROP-default policy with curated allowlist
sudo aic-firewall status          # inspect rules + resolved IPs
```

The default allowlist covers Anthropic / OpenAI / GitHub / npm / PyPI / Docker registries. Per-project extras go in `.devcontainer/firewall-allowlist` (one domain per line, `#` comments allowed). Re-run `sudo aic-firewall enable` after editing.

Design notes:
- The script is **enable-only**. There is no `disable` or `pause` subcommand and the scoped sudoers entry only allows this single script — so an AI that gets shell access can call it, but only to *strengthen* the policy, never to remove it.
- To turn the firewall off, `aic rebuild` from the host (this script doesn't survive container recreation).
- `NET_ADMIN` and `NET_RAW` are granted to the container so the script can manage iptables. The caps are confined to the container's network namespace — they do not affect the host's networking.

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

**`aic shell` succeeds but `claude` errors with permission issues.** `post-create.py` runs during `aic up`, not on shell entry — scroll the `aic up` output for `[post-create]` warnings (volume ownership, hook setup, settings write). `aic rebuild` re-runs it cleanly.

**Tools installed ad-hoc disappeared.** That's expected — see "Installing extra tools" above. Move them to `Dockerfile.project`.

**Codex prompts for approval despite auto-approve.** Make sure `~/.codex/config.toml` exists (it's written by `post-create.py`). Re-run `aic rebuild` if the file is missing.

## Uninstall

```bash
# In each project:
aic destroy

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
npm version patch         # or: minor / major. Creates the bump commit + v* tag.
git push --follow-tags    # pushes both the commit and the tag
```

`release.yml` then fires on the tag and ships, in one atomic flow:
- `ghcr.io/stefanoginella/aicontainer:vX.Y.Z` (immutable)
- `ghcr.io/stefanoginella/aicontainer:latest` (floats forward)
- `aicontainer@X.Y.Z` on npm with provenance attestation

A guard step rejects the run if the `v*` tag doesn't match `package.json`'s `version` — so `npm version` is the only sane way to mint a release tag.

### Day-to-day pushes vs. releases

|              | What triggers it                                  | What ships                                              |
| ---          | ---                                               | ---                                                     |
| Feature PR   | merge to `main`, touches `template/**`            | `:latest` + weekly tag refresh. Nothing on npm.         |
| Feature PR   | merge to `main`, only touches `aic`/README        | Nothing.                                                |
| Release      | `npm version <bump> && git push --follow-tags`    | `:vX.Y.Z` (immutable) + `:latest` + npm publish.        |
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

## Contributing & security

Bugs, ideas, and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for ground rules, the development loop, and what won't be merged. By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

Security findings: please **don't** open a public issue. Use GitHub's [private security advisory flow](https://github.com/stefanoginella/aicontainer/security/advisories/new) instead.

## License

[MIT](./LICENSE).
