---
name: aicontainer-setup
description: "Manual setup of aicontainer (the sandboxed devcontainer for running AI coding agents in bypass/auto-approve mode) in a project: detect and confirm the stack, check devcontainer suitability, then apply project-level customization. User-invoked via its slash command; not intended for automatic use."
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
  `firewall-allowlist`. These are opt-in by presence.
- **Show the plan, then apply.** Detect and confirm first, present the full plan,
  get a yes, then write files and run `aic init` / `aic sync`. **Stop before
  `aic up`** — it pulls a multi-gigabyte image; hand that command to the user.

## Step 0 — Preconditions

Before anything, confirm the ground is solid:

1. **Are we on the host, or already inside an aicontainer?** If `/etc/aic` exists,
   or env vars like `REMOTE_CONTAINERS` / `DEVCONTAINER` / `AIC_TOOLS` are set,
   you're *inside* the sandbox — `.devcontainer/` writes are blocked by the
   PreToolUse hook. Stop and tell the user to run setup from a host terminal.
2. **Is this a git repo?** `aic init` expects a project directory. If there's no
   repo, that's fine, but note it (the sandbox bind-mounts `$PWD` as `/workspace`
   regardless).
3. **Is the `aic` CLI installed?** Check `command -v aic`. If missing, offer to
   run `npm install -g aicontainer` (needs Node 18+). Don't install silently —
   it's a global package install; confirm first.
4. **Is Docker running?** `docker info` should succeed (Docker Desktop / OrbStack
   / Colima). Setup can still proceed without it, but `aic up` later will need it
   — note it rather than blocking.
5. **Is there already an aic setup here?** If `.devcontainer/devcontainer.json`
   exists and references aicontainer (the GHCR image or `AIC_TOOLS`), this is a
   *re-setup*: prefer `aic sync` over `aic init` in Step 7, and focus on
   adding/adjusting the project-owned override files rather than regenerating from
   scratch.

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
  `vscode`. Keep caches under `/workspace/` or `/home/vscode/.cache/` (the only
  paths `chown-paths` honors).
- **`Dockerfile.project`** — for anything needing `apt` / root or baked-in
  browsers: native build deps, DB clients, Playwright/Chromium (README has the
  exact recipe), extra language runtimes. `FROM` must match the pinned tag in the
  generated `docker-compose.yml` (read it after init). Point at it with a `build:`
  block in `docker-compose.override.yml`, **not** by editing `docker-compose.yml`.
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
  `lefthook install`, `pre-commit install`, DB seed).
- **`firewall-allowlist`** — only if the user wants the stricter opt-in network
  allowlist (reviewing untrusted code, corporate LAN). Off by default; mention it,
  don't impose it.

**LSP is a first-class concern** (the user cares about it). Make explicit that
there are *two* LSP surfaces: the **editor's** IntelliSense (extensions +
settings) and the **agent's** LSP tool (a language-server binary on `PATH`,
installed from `post-create.project.sh`). A project usually wants both. See the
references table for the binary + extension per language.

## Step 6 — Present the plan

Show the user, before touching anything:

1. The confirmed stack and the suitability verdict.
2. The `aic init` invocation (with `--with` / `--shell`).
3. Each project-owned file you'll create, **with its contents**, and one line on
   *why* (which stack fact drives it).
4. The exact next commands they'll run after you're done (`aic up` or VS Code
   "Reopen in Container", then how to verify).

Get an explicit yes. If they want changes, fold them in and re-show.

## Step 7 — Apply

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

Do **not** run `aic up` / `aic rebuild` (large image pull) — that's the user's
call.

## Step 8 — Hand off

Tell the user exactly what to run next and how to confirm it worked:

- **CLI path:** `aic up` (pulls the image, starts the stack), then `aic shell`,
  then `claude` / `codex` / `opencode`.
- **VS Code path:** install the Dev Containers extension, then
  `Cmd+Shift+P → Dev Containers: Reopen in Container`.
- **Verify:** `aic preflight` prints exactly what crosses the boundary for this
  config. After the container is up, check LSP servers are on `PATH`
  (`command -v pyright-langserver`), the named volume is writable, and host
  services resolve.
- **Mention if relevant:** `aic signing` if they sign commits (the host signing
  key isn't forwarded); the firewall opt-in for stricter network containment.

Keep the handoff concrete — these are copy-pasteable commands, not prose.

## Reference

- `references/stack-and-suitability.md` — stack-detection signal table, the full
  devcontainer-suitability matrix, and the LSP-server-by-language table (editor
  extension + agent binary). Read it during Steps 2, 4, and 5.
