---
description: "Manual setup of aicontainer (the sandboxed devcontainer for running AI coding agents in bypass/auto-approve mode) in a project."
disable-model-invocation: true
---

# Set up aicontainer in a project

Your job is to take a project from "no sandbox" to "the AI agent runs behind the
aicontainer devcontainer boundary, configured for *this* project's stack." You
detect the stack, sanity-check that a Linux devcontainer is even the right tool,
propose a concrete customization plan, and — once the user approves — apply it.

aicontainer's whole point is letting Claude Code / Codex / OpenCode run with
permissions skipped *without* handing a prompt-injected dependency your real
`$HOME`, `.env`, SSH keys, or `gh` token. Good setup is what makes that sandbox
actually usable for the project — a Python repo needs a writable `.venv`, an
agent that uses go-to-definition needs a language server on `PATH`, a Postgres
app needs the DB reachable. That per-project wiring is the work here.

The other half is the *person*: their tool settings, prompt, aliases, and
statusline. Some of that is seeded automatically, some is deliberately dropped,
and some needs an explicit opt-in they'd never guess at. Step 6 walks them
through it — a sandbox the user can't stand working in doesn't get used.

## Golden rules (read first — they shape everything below)

These come straight from how aicontainer is designed; violating them creates work
that silently gets wiped or breaks `aic sync`.

- **Run `aic` from the host, never from inside the container.** Setup happens
  before (or outside) the sandbox. If you detect you're *inside* an aicontainer
  already (see Step 0), stop and tell the user to run this from a host terminal —
  `.devcontainer/` is mounted read-only in the sandbox by design.
- **Never hand-edit `.devcontainer/devcontainer.json` or
  `.devcontainer/docker-compose.yml`.** They are template-managed: `aic init`
  writes them and `aic sync` overwrites them (only the `AIC_TOOLS` / `AIC_SHELL`
  choices survive). All per-project customization goes in the **project-owned**
  files instead (listed in Step 5). Edits to the managed files get reset on the
  next sync.
- **All customization lives in project-owned files** that `aic sync` never
  touches: `Dockerfile.project`, `docker-compose.override.yml`, `chown-paths`,
  `post-create.project.sh`, `vscode-extensions`, `vscode-settings.json`,
  `firewall-allowlist`, `shell-rc.zsh`, `p10k.zsh`, `statusline.{sh,mjs,js,py}`.
  These are opt-in by presence.
- **`aic rebuild` is the verb that builds — `aic up` is not.** `aic up` runs a
  plain `devcontainer up`, and the managed pull-mode Compose sets
  `pull_policy: missing`: when the resolved image tag is already cached, Compose
  reuses it and **never runs your `Dockerfile.project`**. The stack comes up
  looking healthy on the plain base image, with every baked tool missing and
  every named volume still `root:root`. `aic rebuild` adds
  `--remove-existing-container --build-no-cache`, which is what actually builds.
  So: if the plan writes a `Dockerfile.project`, the first boot is `aic rebuild`,
  and so is every boot after you edit it.
- **Host-boundary trust is the user's to grant — you can't, and shouldn't.** A
  `Dockerfile.project` (or an added mount, a protected env key, Docker socket
  exposure) makes `aic validate` / `up` / `rebuild` fail closed until the human
  runs `aic trust`, which **requires a TTY** and so cannot run from your Bash
  tool. Hand it to them; never route around it with `--allow-unsafe`. Trust
  binds to an exact config hash, so **any** later edit to
  `docker-compose.override.yml` or `Dockerfile.project` revokes it — settle the
  config completely before you ask (Step 8).
- **Show the plan, then apply.** Detect and confirm first, present the full plan,
  get a yes, then write files and run `aic init` / `aic sync`. **Confirm before
  the first boot** — it pulls or builds a multi-gigabyte image and can take
  minutes — but once the user says go, drive it yourself: verify the container
  actually boots and fix what's broken (Step 9). Don't just hand back a command
  and hope.

## Step 0 — Preconditions

Before anything, confirm the ground is solid:

1. **Are we on the host, or already inside an aicontainer?** If `/etc/aic` exists,
   or env vars like `REMOTE_CONTAINERS` / `DEVCONTAINER` / `AIC_TOOLS` are set,
   you're *inside* the sandbox — `.devcontainer/` writes are blocked by the
   PreToolUse hook. Stop and tell the user to run setup from a host terminal.
2. **Is this a git repo?** `aic init` expects a project directory. If there's no
   repo, that's fine, but note it (the sandbox bind-mounts `$PWD` as `/workspace`
   regardless).
3. **Is the `aic` CLI installed?** Check `command -v aic`. If it's missing,
   don't abort — **offer to install it**, since nothing else in this skill works
   without it:
   - **Confirm Node.js 18+ first** (`node --version`) — it's the one
     prerequisite for the npm install (and the bundled `@devcontainers/cli`). If
     Node is too old or absent, say so and point the user at it rather than
     attempting the install.
   - **Offer the install and wait for a yes** — this is a global package
     install, so never run it silently. The default method is
     `npm install -g aicontainer`. If the user prefers a git checkout, the
     alternative is
     `git clone https://github.com/stefanoginella/aicontainer ~/.aicontainer && ~/.aicontainer/install.sh`
     (a checkout also needs `npm install -g @devcontainers/cli` separately).
   - **Verify after installing** — re-run `command -v aic` (or `aic --version`)
     and confirm it's now on `PATH` before continuing. If the install failed or
     `aic` still isn't found, stop and surface the error; don't push ahead into
     the steps below.
4. **Is Docker running?** `docker info` should succeed (Docker Desktop / OrbStack
   / Colima). Setup can still proceed without it, but Step 9's boot verification
   (and `aic up` generally) will need it — note it rather than blocking.
5. **Is there already an aic setup here?** If `.devcontainer/devcontainer.json`
   exists and references aicontainer (the GHCR image or `AIC_TOOLS`), this is a
   *re-setup*, not a fresh install — you're in **update mode**. Don't regenerate
   from scratch and don't re-propose files that already exist and are correct.
   Still read the README (Step 1) and re-detect/confirm the stack (Steps 2–3),
   then follow "Update mode" below instead of the greenfield Step 5. (If no
   `.devcontainer/` exists, it's a fresh setup — continue straight through
   Steps 1–10.) A missing `.devcontainer/` still isn't proof of a clean slate: a
   repo set up under an older aic can leave a stale legacy Docker volume/stack
   that `aic up` migrates automatically (`aic: migrating legacy session
   transcripts …`). That's expected, not an error — don't treat it as a failure.
6. **Is a stale stack still running for this path?** The Compose project name is
   derived from the canonical path (`aic-<basename>-<hash>`), so a *previous*
   setup for this directory — even one whose `.devcontainer/` is long gone — can
   still own containers and volumes in the same namespace. `aic up` deliberately
   does **not** pass `--remove-orphans` (it can't attribute them), so those
   services keep running and resurface later as mystery containers in `docker
   compose ps`. Look now:
   `docker ps -a --filter "name=aic-<basename>-"` and
   `docker volume ls --filter "name=aic-<basename>-"`. The clean sweep is
   `aic down` (which *does* use `--remove-orphans`) once a config exists. Stale
   named volumes may hold real data — surface them and let the user decide;
   never delete a volume unasked.

## Update mode — auditing an existing setup

When Step 0 found an existing aic setup, the job is **not** "generate config." It
is "check whether this project's personalization still fits its stack, and update
only what's missing, stale, or drifted." A project set up months ago may have
gained a language, a service, browser e2e tests, or new build artifacts — or had
the global `aic` upgraded under it. Read the README (Step 1) and refresh the
stack profile (Steps 2–3) first, then:

1. **Inventory what's already there.** List which project-owned files exist and
   **read their contents**: `Dockerfile.project`, `docker-compose.override.yml`,
   `chown-paths`, `post-create.project.sh`, `vscode-extensions`,
   `vscode-settings.json`, `firewall-allowlist`, `shell-rc.zsh`, `p10k.zsh`,
   `statusline.{sh,mjs,js,py}`. Also
   note the current `AIC_TOOLS` / `AIC_SHELL` in `devcontainer.json` (the only
   managed values that survive `aic sync`), and which host-global overlays
   already exist at `~/.config/aicontainer/` (`rc.zsh`, `p10k.zsh`,
   `statusline.*`). This is your baseline — what's already covered.
2. **Compute the delta against the refreshed stack — look for three things:**
   - **Missing coverage** — a stack fact with no matching personalization: a new
     language with no LSP server in `post-create.project.sh` and no editor
     extension; a Python project with no writable `.venv` volume; a newly-added
     Postgres/Redis service not wired in `docker-compose.override.yml`;
     Playwright/Chromium added with no `Dockerfile.project`.
   - **Missing personalization** — the user's environment, not the stack: no
     shell/prompt overlay and no statusline while their host has them (Step 6),
     or a statusline copied into the seed dir that has since drifted from the
     host original. An existing setup predating a slot won't have it; offer it
     rather than assuming they declined.
   - **Stale / incorrect entries** — personalization that no longer matches: a
     `chown-paths` line for a volume that's no longer declared; a
     `vscode-settings.json` interpreter path that no longer exists; an LSP install
     or extension for a language the project dropped; a tool in `AIC_TOOLS` the
     user no longer wants.
   - **Version / base drift** — the tooling flags this one: after
     `npm update -g aicontainer`, a `Dockerfile.project` whose `FROM …:vX.Y.Z`
     lags the tag now pinned in `docker-compose.yml`. `aic sync` **warns**; the
     fix is `aic sync --bump-base` (it rewrites the `FROM` in place — never
     hand-edit a project-owned file's base for this).
3. **If nothing is missing, stale, or drifted, say so and stop.** "Your
   personalization already matches your stack; nothing to update" is a valid,
   useful outcome — don't invent changes to look busy.
4. **Otherwise present only the delta (Step 7) and apply it (Step 8).** Write the
   new/changed project-owned files, leave correct existing ones untouched, then
   run `aic sync` (the re-setup verb) so override wiring and the
   `vscode-extensions` / `vscode-settings.json` merges refresh. Then move to
   Step 9 to confirm the refreshed setup actually boots — an update that
   "should" fix a gap isn't done until you've watched it come up clean.

## Step 1 — Read the current aicontainer README

Fetch the live README so your recipes match the current release (override-file
syntax and the `Dockerfile.project` / LSP recipes occasionally change):

- Primary: WebFetch `https://raw.githubusercontent.com/stefanoginella/aicontainer/main/README.md`
- Human URL (for linking the user): `https://github.com/stefanoginella/aicontainer`

If the fetch fails (offline, firewall), degrade gracefully — don't abort. Use, in
order: (a) the `.devcontainer/README.md` that `aic init` drops into the project
(version-matched, documents the managed-vs-project-owned split), (b) `aic help`,
and (c) `references/stack-and-suitability.md` in this skill. The README is the
source of truth for *recipe syntax*; this skill carries the *judgment* (stack
detection, suitability, LSP-by-language).

## Step 2 — Detect the stack

Build a picture of what this project actually is. Read, don't guess. Cover:

- **Manifests & lockfiles** — `package.json`, `pyproject.toml` / `requirements.txt`
  / `uv.lock`, `go.mod`, `Cargo.toml`, `Gemfile`, `pom.xml` / `build.gradle`,
  `composer.json`, `*.csproj` / `*.sln`, `mix.exs`, `pubspec.yaml`,
  `Package.swift`, `*.xcodeproj`, `CMakeLists.txt`.
- **Runtime/version pins** — `.nvmrc`, `.python-version`, `.tool-versions`,
  `.ruby-version`, `Dockerfile`, existing `docker-compose.yml`.
- **Services the app needs** — scan `docker-compose.yml` services, `.env.example`
  / `.env.sample` keys (`DATABASE_URL`, `REDIS_URL`, …), ORM/migration config.
  These become host-service or sibling-container wiring.
- **Test/automation tooling** — especially browser e2e (`@playwright/test`,
  `cypress`, `puppeteer`) and native build steps, which need a `Dockerfile.project`.
- **`.md` design docs** — `README.md`, `ARCHITECTURE.md`, `docs/`, PRD / spec /
  design files. Lean on these when code signals are thin or the repo is greenfield;
  a spec saying "React + FastAPI + Postgres" is a real signal.

`references/stack-and-suitability.md` has the full signal→inference table. The
goal is a short profile: **language(s) + package manager(s) + runtime versions +
services + test tooling + any GUI/mobile/native/hardware signals.**

## Step 3 — Confirm the stack with the user

Don't proceed on a guess. Present the detected profile compactly and ask the user
to confirm or correct it — use AskUserQuestion when the choice is crisp, plain
prose when it's open. If detection was inconclusive (sparse repo, unfamiliar
layout), **ask the user directly** what the stack is rather than inventing one.
The customization plan is only as good as this profile, so it's worth the round-trip.

## Step 4 — Check devcontainer suitability

aicontainer is a **headless Linux** devcontainer. Most server / web / CLI /
library / data / ML-on-CPU work is a great fit. Some work fundamentally can't run
here — flag it *before* generating config so the user isn't surprised after a
rebuild. Use the matrix in `references/stack-and-suitability.md`. The headline
non-fits, and why:

- **iOS / macOS-native** (Xcode, Swift/AppKit, code-signing/notarization) — the
  toolchain is host-macOS-only; it can't run in a Linux container.
- **Windows-native** (.NET Framework, WPF/WinForms, MSIX) — needs Windows.
- **Native desktop GUI needing a host display** — no X/Wayland bridge by default.
- **Embedded / firmware** needing USB / serial / JTAG passthrough — hardware isn't
  forwarded.
- **Android emulator** — needs nested KVM (painful); *building* APKs is fine,
  *running the emulator* generally isn't.
- **GPU / CUDA** — not wired by default (no `nvidia-container-toolkit`); possible
  but advanced and may not be supported.
- **No Docker runtime available** — nothing runs without one.

When you hit a non-fit, say so plainly, explain what specifically won't work, and
note whether a **partial** setup still helps (e.g. an iOS app with a Node backend
— sandbox the backend, build the app on the host). Then let the user decide
whether to proceed. Don't silently generate a config that can't work.

## Step 5 — Choose tools, shell, and map the stack to customization

First the two `aic init` choices (ask, or take the defaults and say so):

- **AI tools** (`--with`): `claude-code`, `codex`, `opencode`, or a comma-list.
  Default is all three.
- **Shell** (`--shell`): `zsh` (default), `bash`, or `fish`.

Then map the confirmed stack to **project-owned files**. The aim is a sandbox the
project actually builds and runs in. Common mappings (full syntax: the README from
Step 1; rationale and the LSP-by-language table: `references/stack-and-suitability.md`):

- **Named volume + `chown-paths`** — for build artifacts you don't want on the
  bind-mounted workspace: Python `.venv` + uv cache, Node `node_modules`, Rust
  `target`/cargo, Go build cache. Persists across rebuilds and dodges the macOS
  bind-mount perf hit. **Always pair a named volume with a `chown-paths` entry** —
  Docker inits named volumes `root:root` and the mount is otherwise unwritable by
  `vscode`. **`/workspace/…` and `/home/vscode/.cache/…` are the only mount
  targets aic accepts at all** — that's a validator rule on every mount the
  override adds, not merely a `chown-paths` limit. Most tools' default cache dirs
  sit outside it — `~/.cargo`, `~/.m2`, `~/.gradle`, `~/go/pkg`, `~/.pub-cache` —
  and mounting one makes aic reject the *whole config* with `added mount target
  is outside approved project data paths`. Relocate the cache, not the rule: mount
  `/home/vscode/.cache/<tool>` and point the tool at it by setting its home var
  (`CARGO_HOME`, `GOMODCACHE`, `UV_CACHE_DIR`, …) in `Dockerfile.project`, so the
  value is baked into the image rather than an override `environment:` key the
  validator has to re-review.
- **`Dockerfile.project`** — for anything needing `apt` / root or baked-in
  browsers: native build deps, DB clients, Playwright/Chromium (README has the
  exact recipe), extra language runtimes. `FROM` must match the pinned tag in the
  generated `docker-compose.yml` (read it after init). Point at it with a `build:`
  block in `docker-compose.override.yml`, **not** by editing `docker-compose.yml`.
  Two consequences the recipe leaves implicit, and both bite:
  - **Give the build its own `image:` tag in the same override block.** Compose
    tags a build's output with whatever `image:` resolves to, and the managed file
    resolves it to the *shared* `ghcr.io/stefanoginella/aicontainer:vX.Y.Z` — so a
    bare `build:` block silently re-tags the base image locally and hands this
    project's image to **every other aic project on the machine**. aic permits a
    distinct tag whenever a `build:` is present, so always add
    `image: <project>-devcontainer:vX.Y.Z` next to it.
  - **It always costs exactly one `aic trust`, and it makes `aic rebuild` the
    boot verb.** Image builds run as root, so aic treats every project Dockerfile
    as a boundary expansion even when `FROM` is the official base. Both golden
    rules above — plan the sequence around them rather than discovering them.
- **`docker-compose.override.yml`** — env vars, host-service wiring
  (`DATABASE_URL: …@host.docker.internal:5432/…` to reach a DB running on the
  host; add the `extra_hosts` line on Linux), extra ports/mounts, the named-volume
  declarations, and the `Dockerfile.project` `build:` block.
- **`vscode-extensions` + `vscode-settings.json`** — editor IntelliSense: the
  language extension stack (Python → `ms-python.python` + `ms-python.vscode-pylance`
  + `charliermarsh.ruff`; TS → `dbaeumer.vscode-eslint` + `esbenp.prettier-vscode`;
  etc.), interpreter path, format-on-save. Include the **stop-auto-activating-`.venv`**
  settings for Python projects (otherwise VS Code types `source .../activate` into
  the terminal and clobbers the AI CLI you just launched — README has the two keys).
- **`post-create.project.sh`** — runs as `vscode`, cwd `/workspace`, on every
  create. Two jobs: (1) **install the agent's LSP server** binary on `PATH` so
  Claude Code's go-to-def / find-refs tool works — this is *separate* from the
  editor extensions and is the LSP piece people miss (Python → `npm i -g pyright`,
  giving `pyright-langserver`; TS → `npm i -g typescript typescript-language-server`;
  others in the references table); (2) project bootstrap (`uv sync`, `npm ci`,
  DB seed). Three sandbox constraints shape this script — get them wrong and the
  first boot logs a scary `❌` (full recipes: "post-create constraints" in the
  references):
  - **Guard bootstrap on the manifest existing.** Greenfield repos often have no
    `pyproject.toml` / `package.json` yet, so wrap the step
    (`if [ -f pyproject.toml ]; then uv sync; fi`) or it hard-fails on first create.
  - **Never run a git-hook installer unconditionally.** `.git/hooks` is
    bind-mounted **read-only** (sandbox self-protection), so `lefthook install` /
    `husky install` / `pre-commit install` all fail with `read-only file system`.
    The *host* owns hook installation; the container only needs the hook *binary*
    on `PATH` so the host-written shim runs. Gate any install on `[ -w .git/hooks ]`.
  - **`npm i -g` can't install postinstall-binary tools.** The sandbox sets
    `NPM_CONFIG_IGNORE_SCRIPTS`, so tools that fetch a binary in a postinstall
    (lefthook, gitleaks, …) install *nothing*. Fetch the pinned static release
    binary into `~/.local/bin` instead. (Pure-JS LSP servers like `pyright` ship
    their code and are unaffected; add `--no-audit` to real `npm i -g` calls to
    quiet a cosmetic global+audit warning.)
- **`firewall-allowlist`** — only if the user wants the stricter opt-in network
  allowlist (reviewing untrusted code, corporate LAN). Off by default; mention it,
  don't impose it.
- **Personal overlays (`shell-rc.zsh`, `p10k.zsh`, `statusline.*`)** — the user's
  own prompt, aliases, and Claude statusline inside the sandbox. These are
  *personalization*, not stack mapping, and they're the piece users most often
  assume happens automatically. Handle them in **Step 6**, not here.

**LSP is a first-class concern** (the user cares about it). Make explicit that
there are *two* LSP surfaces: the **editor's** IntelliSense (extensions +
settings) and the **agent's** LSP tool (a language-server binary on `PATH`,
installed from `post-create.project.sh`). A project usually wants both. See the
references table for the binary + extension per language.

## Step 6 — Port the user's host config and preferences

A sandbox that builds the project but feels alien to work in is a half-done
setup. This step closes the gap between "the container runs" and "it's *my*
environment." Do it for fresh setups and update-mode runs alike.

Lead with what's already handled — most users assume nothing carries over, and
that's wrong. **Don't re-explain the whole boundary; tell them what to *do*.**

### 6.1 — Already automatic: nothing to do but keep it current

Before every `aic up`/`rebuild`, a root-only, networkless one-shot sanitizer
reads four fixed host files and emits allowlisted JSON the container consumes
read-only. The user edits these **on the host** and re-runs `aic rebuild`:

| Host file | Carries over |
| --- | --- |
| `~/.claude/settings.json` | model, effort, editor mode, theme, plugins/marketplaces, MCP servers, verbosity… |
| `~/.codex/config.toml` | model, reasoning effort, personality, `[mcp_servers.*]`, `[projects.*]` |
| `~/.config/opencode/opencode.json` | provider/model, agents, instructions, theme, keybinds, formatter, lsp, mcp |
| `~/.gitconfig` | identity + non-executable workflow prefs (pull/push/rebase/diff/merge) |

### 6.2 — Deliberately dropped: say so before they hunt for it

Not bugs — the allowlist exists because these either defeat the sandbox or carry
host-only paths/secrets. State the *replacement*, not just the removal:

- **`permissions`, `hooks`, Codex `approval_policy` / `sandbox_mode`** — the
  container enforces its own at root-managed precedence. That's the whole point.
- **`env` blocks, inline MCP `env`/`headers`, API keys/tokens** — never
  forwarded. Replacement: log in **inside** the container once (`claude`,
  `codex`, `opencode auth login`, `gh auth login`, `npm login`); credentials
  persist in a global volume across rebuilds and projects.
- **`statusLine`** — a command string pointing at a host path. Replacement: the
  statusline overlay in 6.3.
- **Git `credential.helper`, aliases, `include`/`includeIf`, `core.hooksPath`,
  signing key paths** — command/path-bearing. Replacement for signing: `aic
  signing` provisions a sandbox-only key (the host key is never forwarded).
- **Host `~/.zshrc` / `~/.p10k.zsh`** — never auto-forwarded. Replacement: 6.3.
- **MCP servers pointing at host-only binaries** will be seeded but fail to
  start in Linux; URL-based and npm-installed ones work. Worth naming if the
  user has any, so a startup error later isn't a mystery.

### 6.3 — The opt-in overlays: offer to set them up

Three independent slots, all **opt-in by file presence**, all surviving `aic
sync`, each available host-globally (once, every project) or per-project:

| What | Host-global seed | Project file |
| --- | --- | --- |
| zsh startup (aliases, functions, exports) | `~/.config/aicontainer/rc.zsh` | `.devcontainer/shell-rc.zsh` |
| powerlevel10k prompt | `~/.config/aicontainer/p10k.zsh` | `.devcontainer/p10k.zsh` |
| Claude Code statusline | `~/.config/aicontainer/statusline.{sh,mjs,js,py}` | `.devcontainer/statusline.{sh,mjs,js,py}` |

Mind the **filename asymmetry**: the shell rc is `rc.zsh` host-side but
`shell-rc.zsh` project-side. `p10k.zsh` and `statusline.*` use the same name in
both places. The project file wins when both exist. All take effect on the next
`aic rebuild`.

The statusline slot is the script only — aicontainer supplies the command
(`/usr/local/bin/aic-statusline`, a fixed launcher) and picks the interpreter
from the **extension**: `.sh`→bash, `.mjs`/`.js`→node, `.py`→python3. So:

- **One self-contained file.** A statusline that `import`s sibling modules
  breaks; vendor it or pick a different one. Its own state under
  `~/.claude/statusline/` is writable and per-project, so caches work.
- Anything it shells out to must exist in the container (`git` does; host-only
  binaries don't).
- **Best host setup:** keep the real script *at* `~/.config/aicontainer/statusline.mjs`
  and point the host `~/.claude/settings.json` there too — one file, no drift.
  Otherwise it's a copy that will go stale; say so.

> ⚠️ All three are **code, not data**: they cross **verbatim** (they can't be
> sanitized) and the in-container agent can read them. **No secrets, ever** — and
> flag that host paths/usernames baked into them become visible in the sandbox.
> They land root-owned `0444`, so once installed the agent can't modify them, and
> they run only as the unprivileged `vscode` user.

### 6.4 — Offer to draft the overlays from their host files (optional)

Users who want "my shell/statusline inside the sandbox" usually already have a
host `~/.p10k.zsh`, `~/.zshrc`, or statusline script and reasonably expect them
to appear. They don't — host dotfiles routinely hold secrets and host-specific
breakage, and this sandbox runs an untrusted agent that can read whatever is
mounted. So *offer to bridge that gap*: **draft** the overlay from their host
files — an assisted, reviewed draft, never a silent transform.

This is safe to do here because *you* run on the **host**, as the user's
permissioned session — a different trust context from the sandboxed
bypass-permissions agent the threat model targets, and you can already read
these files. The trust anchor holds **only if the user stays the approver**: you
move them from author to reviewer, you don't remove them. Do not auto-place a
drafted file.

When the user opts in:

1. **Read the host files** host-side — `~/.p10k.zsh`, `~/.zshrc`, and the script
   named by their host `statusLine.command` (parse the path out of
   `~/.claude/settings.json`; don't guess a location).
2. **`p10k.zsh` — near-verbatim.** Almost always `p10k configure` output:
   declarative `typeset -g POWERLEVEL9K_*`, no secrets. Copy it, but **scan** for
   the unusual — custom segment functions that shell out, hardcoded host paths,
   anything secret-shaped — and flag those.
3. **`rc.zsh` — whitelist-extract, don't blacklist-strip.** Pull only
   clearly-safe categories (aliases, simple functions, `setopt`, keybindings,
   prompt tweaks). Leave everything else behind: `export *_KEY/_TOKEN/_SECRET=…`,
   `source`d secret/env files, plugin managers and `eval "$(tool init)"` for
   tools not in the sandbox, aliases to host-only binaries. **When in doubt,
   leave it out.**
4. **`statusline.*` — copy whole, then audit.** Unlike an rc file you can't
   extract "the safe half" of a program, so it's all-or-nothing: read the whole
   script and report what would break or leak — a hardcoded host path, a
   host-only binary it shells out to, an API token, a network call, a sibling
   `import`. If any of those are present, say so and let the user decide between
   fixing the script, dropping the slot, or accepting it.
5. **Be honest about the two distinct risks when you present it.** You are
   *reliable* at avoiding breakage ("this sources oh-my-zsh at a host path —
   dropped"); you *assist but cannot certify* secret removal. Never say "I
   sanitized your config" — say "here's a lean draft; review it and confirm there
   are no secrets."
6. **Show a kept / dropped-with-reason summary** per file and fold the candidates
   into the Step 7 plan. Require an explicit yes — this is content pulled from the
   user's private files, so it gets its own focused look, not a blanket approval.
7. **On approval, write** to `~/.config/aicontainer/` (host-global — one setup
   for every project) or `.devcontainer/` (this project only), as the user
   prefers, using the filenames in 6.3's table.

If the user declines, or you can't confidently produce a clean draft, fall back
to the manual path: they place the files by hand — no secrets — then `aic
rebuild`. Either way, verify the result in Step 9 (`aic run test -r
/etc/aic/user-config/statusline/statusline.mjs`, `aic run
/usr/local/bin/aic-statusline`, or a login `zsh -lic true`) rather than assuming
it landed.

## Step 7 — Present the plan

Show the user, before touching anything:

1. The confirmed stack and the suitability verdict.
2. The `aic init` invocation (with `--with` / `--shell`).
3. Each project-owned file you'll create, **with its contents**, and one line on
   *why* (which stack fact drives it).
4. **The Step 6 personalization**, called out separately from the stack wiring —
   what carries over untouched, what is deliberately dropped and what replaces
   it, and any overlay file you drafted (kept/dropped summary, its own explicit
   yes). Say plainly where each overlay lands: host-global `~/.config/aicontainer/`
   or this project's `.devcontainer/`.
5. **Whether this plan will need `aic trust`, stated up front** — name the
   finding it will produce (almost always the `Dockerfile.project` root build)
   and that they'll run one command in their own terminal at a known point. A
   user who meets the gate only when the build stops thinks setup broke.
6. That you'll offer to verify the setup boots — `aic rebuild` when there's a
   `Dockerfile.project`, plain `aic up` otherwise — watched to completion and
   fixed if broken, pending their okay since it's a multi-gigabyte pull/build.

Get an explicit yes. If they want changes, fold them in and re-show.

## Step 8 — Apply

Order matters (so the override gets wired into `dockerComposeFile`):

1. **Initialize:** `aic init --with <tools> --shell <shell>` for a fresh project,
   or `aic sync --with <tools> --shell <shell>` if Step 0 found an existing aic
   setup. (Both are non-interactive when you pass the flags.)
2. **Read the pinned tag** from `.devcontainer/docker-compose.yml` if you're
   writing a `Dockerfile.project`, and use it in its `FROM`.
3. **Write the project-owned files** from the approved plan.
4. **Re-wire:** run `aic sync` once more so the freshly-created
   `docker-compose.override.yml` gets appended to `dockerComposeFile` in
   `devcontainer.json` (it's wired only when the file is present). Verify with
   `grep dockerComposeFile .devcontainer/devcontainer.json` — both files should
   appear.
5. **Validate, and stop the hash from moving.** Run `aic validate` — it applies
   the same gate as `up`/`rebuild` but never prompts and never writes trust, so
   it's the one safe way for *you* to read the findings. Fix everything
   mechanical it reports now (rejected mount targets, managed-file drift,
   override syntax). Every fix changes the config hash, and the hash must stop
   moving before the user trusts it.
6. **De-risk the build before spending the user's approval** — only when there's
   a `Dockerfile.project`. A plain `docker build` against it, tagged with the
   same image name the override sets, needs no trust, proves the Dockerfile
   compiles, and warms the layer cache so the post-trust `aic rebuild` is quick:

   ```bash
   docker build -f .devcontainer/Dockerfile.project -t <override's image tag> .devcontainer
   ```

   A Dockerfile bug caught here costs nothing; caught after trust, it costs
   another round-trip through the user.
7. **Hand the trust step to the user.** When `aic validate` ends in `unsafe
   configuration is not trusted`, stop: show the exact `!` finding lines, say in
   one sentence why the plan needs each, and ask them to run `aic trust` in their
   own terminal. Then re-run `aic validate` — `configuration valid — managed
   files and resolved Compose model are accepted.` is the confirmation that it
   landed. Do not pass `--allow-unsafe`, and do not edit any project-owned file
   after they approve without telling them it needs re-approval.

Config is on disk and trusted now, but not yet proven to work. Move to Step 9
before calling this done.

## Step 9 — Verify it boots

Writing the files isn't the job — a sandbox the project can't actually start in
isn't done. Prove it boots and that Step 5's customization took effect before
reporting success.

1. **Pick the verb, then ask before pulling/building.** `aic rebuild` if the plan
   wrote a `Dockerfile.project` — it is the only verb that builds one (golden
   rules); plain `aic up` otherwise. Either can pull a multi-gigabyte GHCR image,
   take minutes, and use real disk, so confirm with the user first. In **update
   mode** the container usually already exists, and `aic up` will happily leave
   it as-is — anything that must re-run (a changed `post-create.project.sh`, a
   new named volume, a rebuilt image) needs `aic rebuild` too. If they'd rather
   run it themselves, or Step 0 flagged Docker isn't running, skip straight to
   Step 10 and hand off the commands instead.
2. **Run it unpiped and read the whole output.** `aic up 2>&1 | tail -60` returns
   `tail`'s exit status, so a config aic *refused* reads as a clean exit-0
   success. Capture the full output (background it if it's long) and actually
   read it — the exit code alone won't distinguish a refusal, a
   `Dockerfile.project` build failure, a bad override key, and a stale pinned
   tag.
3. **If it fails, fix it — don't punt a broken container to the user.** Read the
   actual error, then match it to the likely project-owned file:
   - `unsafe configuration is not trusted` → the config changed since the user
     approved it (or was never approved). Back to Step 8's items 5–7: validate,
     settle, re-ask. Never `--allow-unsafe`.
   - Boots fine but every baked tool is missing and the named volumes aren't
     writable → the build never ran. You used `aic up` where a
     `Dockerfile.project` needs `aic rebuild`.
   - Image build error → check `Dockerfile.project`'s `FROM` matches the pinned
     tag (`grep image: .devcontainer/docker-compose.yml`).
   - Compose parse/validation error → check `docker-compose.override.yml`
     syntax and that it only extends the `devcontainer` service.
   - Container starts but a volume mount is unwritable → confirm the path is
     both declared as a volume in the override **and** listed in
     `chown-paths`, under an allowed prefix (`/workspace/`,
     `/home/vscode/.cache/`).
   - `post-create.project.sh` step didn't take effect (its failures are logged,
     not fatal to boot) → fix the script, then `aic rebuild` (or
     `aic destroy && aic up` if state needs a clean slate) to re-run it.
   After any project-owned-file fix, re-run `aic sync` so wiring stays current,
   then retry `aic up` / `aic rebuild`. Iterate until it's clean — don't stop at
   the first fix without confirming it actually resolved the failure.
4. **Spot-check the plan actually landed**, using `aic run <cmd>` (no need for
   an interactive shell):
   - **The container is running the image you expect** — do this one first
     whenever there's a `Dockerfile.project`; it catches a skipped build in a
     single command:
     `docker compose --env-file .devcontainer/.env -f .devcontainer/docker-compose.yml -f .devcontainer/docker-compose.override.yml ps --format '{{.Service}}\t{{.Image}}'`.
     If `devcontainer` shows the base `ghcr.io/stefanoginella/aicontainer:…` tag,
     your build never ran — `aic rebuild`. It also flags any *unexpected* service
     in the list, which is usually a Step 0.6 orphan from a prior stack.
   - LSP binary on `PATH`: `aic run command -v pyright-langserver` (or whatever
     Step 5 installed).
   - Named volume writable: `aic run test -w /workspace/.venv && echo ok`.
   - Host service reachable: `aic run curl -sS host.docker.internal:5432` (or
     whatever the stack needs).
   - **Step 6 overlays landed** (only for slots the plan actually filled):
     `aic run ls -l /etc/aic/user-config/shell /etc/aic/user-config/statusline`
     should show `root … 444` files. Then prove they *run*: `aic run
     /usr/local/bin/aic-statusline` should print a status line (a silent exit
     means nothing was installed; an error is the script's own), and `aic run
     zsh -lic 'alias'` should show a personal alias. If a slot is empty, the
     usual cause is a filename typo — `rc.zsh` vs `shell-rc.zsh`, or an
     extension outside `{sh,mjs,js,py}`.
   - `aic preflight` to confirm the trust boundary (firewall mode, mounts)
     matches the plan.
   `aic run` proves the **agent** LSP (binary on `PATH`), volumes, and services —
   but **not** the editor side: `vscode-extensions` / `vscode-settings.json` only
   take effect in a VS Code Dev Containers session, so don't report editor
   IntelliSense as "verified." That's the expected limit of a headless boot check,
   not a gap.
5. **Leave it running or tear it down?** Ask the user — `aic down` stops the
   container (volumes persist) if they're not about to start working; leave it
   up if they are.

If verification genuinely isn't possible (no Docker, offline, user declined),
say so plainly and fall back to the Step 10 handoff.

## Step 10 — Hand off

Tell the user what to run next and how to confirm it worked. This differs a
little depending on whether Step 9 ran:

- **If Step 9 verified it:** say so, state whether it's still up or you ran
  `aic down`, and give them the resume path — `aic shell` (or `aic up` again
  if stopped), then `claude` / `codex` / `opencode`.
- **If verification was skipped or declined:** hand off the full CLI path, in
  order — `aic trust` first if `aic validate` is still refusing, then
  `aic rebuild` (or `aic up` when there's no `Dockerfile.project`) to
  pull/build and start the stack, then `aic shell`, then `claude` / `codex` /
  `opencode`.
- **VS Code path** (either case): install the Dev Containers extension, then
  `Cmd+Shift+P → Dev Containers: Reopen in Container`.
- **Mention if relevant:** `aic preflight` to re-print the trust boundary;
  `aic signing` if they sign commits (the host signing key isn't forwarded);
  the firewall opt-in for stricter network containment.
- **If Step 6 left anything for them:** the one-time logins they'll do inside
  the container (`claude` / `codex` / `opencode auth login`, `gh auth login`),
  and — for host-global overlays they placed by hand — that editing
  `~/.config/aicontainer/*` or their host config files takes effect on the next
  `aic rebuild`, in this project and every other one.

Keep the handoff concrete — these are copy-pasteable commands, not prose.

## Reference

- `references/stack-and-suitability.md` — stack-detection signal table, the full
  devcontainer-suitability matrix, and the LSP-server-by-language table (editor
  extension + agent binary). Read it during Steps 2, 4, and 5.
