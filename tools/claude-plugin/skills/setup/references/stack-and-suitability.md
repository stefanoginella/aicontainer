# Stack detection, suitability, and LSP wiring

This file carries the skill's own judgment — the parts that aren't in the
aicontainer README. The README (fetched live in Step 1) remains the source of
truth for override-file *syntax*; this file is for *deciding what to generate*.

## 1. Stack detection signals

Read these files to infer the profile. Presence is the signal; versions refine it.

| Signal file(s) | Inference |
|---|---|
| `package.json` (+ `package-lock.json` / `pnpm-lock.yaml` / `yarn.lock` / `bun.lockb`) | Node/JS or TS; note the package manager from the lockfile, and `engines`/`.nvmrc` for the Node version |
| `tsconfig.json`, `*.ts` | TypeScript — wants the TS language server + eslint/prettier |
| `pyproject.toml`, `uv.lock`, `requirements*.txt`, `Pipfile`, `setup.py` | Python; `uv.lock` → uv, else pip/poetry/pipenv. `.python-version` pins the version |
| `go.mod` | Go — gopls, Go build cache as a named volume |
| `Cargo.toml` | Rust — rust-analyzer, `target/` as a named volume |
| `Gemfile` | Ruby — ruby-lsp / solargraph |
| `pom.xml`, `build.gradle(.kts)` | Java/Kotlin/JVM — jdtls (heavy); check for Android (see suitability) |
| `composer.json` | PHP — intelephense |
| `*.csproj`, `*.sln`, `global.json` | .NET — Linux-only for .NET (Core) 5+; **.NET Framework is Windows-native** (non-fit) |
| `mix.exs` | Elixir — elixir-ls |
| `Package.swift`, `*.xcodeproj`, `*.xcworkspace` | Swift / Apple platforms — **likely non-fit**, see suitability |
| `pubspec.yaml` | Dart/Flutter — Flutter web/CLI OK; mobile/desktop targets are non-fits |
| `CMakeLists.txt`, `Makefile`, `*.c`/`*.cpp` | C/C++ — clangd; native build deps likely need `Dockerfile.project` |
| `docker-compose.yml` services (postgres, redis, mysql, mongo, …) | App depends on those services → host-service wiring or sibling containers |
| `.env.example` keys (`DATABASE_URL`, `REDIS_URL`, `*_HOST`) | Same — needs the service reachable; wire via the override |
| `@playwright/test` / `cypress` / `puppeteer` in deps | Browser e2e → `Dockerfile.project` (baked Chromium); README has the Playwright recipe |
| `.md` design docs (ARCHITECTURE, PRD, TECH-STACK, DESIGN, specs, `docs/`, `_bmad-output`, `.specstral`, `.specify/`) | Authoritative when code is sparse/greenfield — a spec naming the stack is a real signal |

When the entire manifest glob comes back **empty** (greenfield / pre-first-commit
repos — e.g. a repo holding only `.git` and `.specstral/`), the design-doc row
above stops being a supplement and becomes the *primary* signal: a ratified spec
(`.specstral/architecture.md`, an ADR, a pinned TECH-STACK) can carry the full
version-pinned stack. Read it before falling back to asking the user; only ask
when even the docs are silent.

Output of this step: **language(s) + package manager(s) + runtime versions +
services + test tooling + GUI/mobile/native/hardware flags.**

## 2. Devcontainer suitability matrix

aicontainer is a **headless Linux** container. Classify the project before
generating config.

### Great fit (proceed normally)
- Web / API / backend services (Node, Python, Go, Rust, Ruby, Java, PHP,
  .NET Core/5+, Elixir) on Linux.
- CLIs, libraries, packages, SDKs.
- Frontend web apps — build and test run headless; the dev server is reachable on
  a forwarded port.
- Data / ML on **CPU**, notebooks, scripts, ETL.
- Anything that already runs in Linux CI — that's essentially the same environment.

### Doable with a documented recipe (proceed, add config)
- **Browser e2e** (Playwright/Cypress/Puppeteer) → `Dockerfile.project` bakes
  Chromium + its apt deps (runtime `sudo apt` is blocked, so it must be in the
  image). README has the exact Playwright recipe, including `--no-sandbox`.
- **Databases / caches** → run them on the host and reach via
  `host.docker.internal` (override env + `extra_hosts` on Linux), or as sibling
  containers through the socket-proxy (`docker compose up` works inside).
- **Native / apt build deps, DB clients, extra runtimes** → `Dockerfile.project`.

### Poor fit / non-fit (warn before generating anything)
- **iOS / macOS-native** — Xcode, Swift + AppKit/UIKit, code-signing,
  notarization. Host-macOS toolchain; cannot run in Linux.
- **Windows-native** — .NET Framework, WPF/WinForms, MSIX, COM. Needs Windows.
- **Native desktop GUI needing a host display** — Electron *builds* fine, but an
  app that must render on the host screen has no X/Wayland bridge by default.
- **Embedded / firmware / hardware** — needs USB / serial / JTAG / GPIO
  passthrough; hardware isn't forwarded into the container.
- **Android emulator** — needs nested KVM (painful, often unavailable). Building
  APKs/AABs is fine; running the emulator generally isn't. Use a host emulator or
  a physical device.
- **GPU / CUDA / ML on GPU** — no `nvidia-container-toolkit` wired by default;
  advanced to add and may not be supported on the user's runtime.
- **No Docker runtime** — Docker Desktop / OrbStack / Colima is a hard prerequisite.

**When you hit a non-fit:** state it plainly, name what specifically won't work,
and check for a **partial** win — a repo is often a non-fit *frontend* plus a
perfectly-sandboxable *backend/service*. Sandbox what you can; tell the user to do
the rest on the host. Never silently emit a config that can't work.

## 3. LSP wiring by language

There are **two** LSP surfaces, and they're configured in different files:

1. **Editor IntelliSense** — VS Code extensions + settings, via
   `.devcontainer/vscode-extensions` and `.devcontainer/vscode-settings.json`.
2. **The agent's LSP tool** — Claude Code's go-to-def / find-refs needs the
   language-server **binary on `PATH`**, installed from
   `.devcontainer/post-create.project.sh` so it survives rebuilds. This is the
   half people forget.

A project usually wants both. The README documents Python and TypeScript in full;
generalize the same pattern to other languages with this table.

| Language | Agent LSP binary (install in `post-create.project.sh`) | Editor extensions (`vscode-extensions`) |
|---|---|---|
| Python | `npm i -g pyright` → `pyright-langserver` (use **pyright**, not basedpyright — Claude Code looks for `pyright-langserver`) | `ms-python.python`, `ms-python.vscode-pylance`, `charliermarsh.ruff` (if ruff), `ms-python.mypy-type-checker` (if mypy) |
| TypeScript / JS | `npm i -g typescript typescript-language-server` | `dbaeumer.vscode-eslint`, `esbenp.prettier-vscode` |
| Go | `go install golang.org/x/tools/gopls@latest` (ensure `GOBIN`/`~/go/bin` on `PATH`) | `golang.go` |
| Rust | `rust-analyzer` (rustup component or release binary on `PATH`) | `rust-lang.rust-analyzer` |
| Ruby | `gem install ruby-lsp` (or `solargraph`) | `Shopify.ruby-lsp` |
| PHP | `intelephense` binary on `PATH` (`npm i -g intelephense`) | `bmewburn.vscode-intelephense-client` |
| C / C++ | `clangd` (apt, via `Dockerfile.project`) | `llvm-vs-code-extensions.vscode-clangd` |
| Java | `jdtls` (heavy; via `Dockerfile.project`) | `redhat.java` |

Python-specific gotcha to always include: VS Code auto-activates a project
`.venv` by *typing and running* `source .../activate` in every new terminal,
which clobbers the AI CLI you just launched. Add the two suppression keys
(`python.terminal.activateEnvironment: false` and
`python-envs.terminal.autoActivationType: "off"`) to `vscode-settings.json`.
README's "Stop VS Code auto-activating a `.venv`" recipe is the source.

## 4. Quick stack → files cheatsheet

| Stack | Likely files to generate |
|---|---|
| Python + uv web app w/ Postgres | named volume for `.venv` + uv cache (+ `chown-paths`); override env `DATABASE_URL`→`host.docker.internal`; `post-create.project.sh` (`uv sync`, `npm i -g pyright`); `vscode-extensions`/`-settings` (pylance, interpreter path, venv-activate-off) |
| Node/TS service | named volume for `node_modules`; `post-create.project.sh` (`npm ci`, `npm i -g typescript typescript-language-server`); `vscode-extensions`/`-settings` (eslint, prettier, format-on-save) |
| Anything with browser e2e | `Dockerfile.project` (Playwright/Chromium recipe) + `build:` block in the override |
| Go service | named volume for build cache; `post-create.project.sh` (`go install gopls`); `golang.go` |
| Rust crate | named volume for `target`/cargo (+ `chown-paths`); `rust-analyzer` + `rust-lang.rust-analyzer` |

## 5. post-create.project.sh: sandbox constraints and recipes

`post-create.project.sh` runs unprivileged as `vscode`, cwd `/workspace`, on every
create. Three sandbox realities trip up otherwise-normal bootstrap scripts —
encode them so the first boot is clean instead of logging `❌`.

### Guard bootstrap on the manifest actually existing

Greenfield / spec-driven repos are frequently sandboxed *before* the first
manifest exists. An unconditional `uv sync` / `npm ci` hard-fails there. Guard it:

```sh
if [ -f pyproject.toml ]; then uv sync; else echo "post-create: no pyproject.toml yet — skipping uv sync"; fi
```

### `.git/hooks` is read-only — never run a hook installer unconditionally

aicontainer bind-mounts the host's hooks read-only
(`../.git/hooks:/workspace/.git/hooks:ro`) so a sandboxed agent can't rewrite
hooks that then execute on the *host*. Every hook manager's `install` verb
rewrites `.git/hooks/*`, so it fails in-container:

```
Error: could not replace the hook: remove /workspace/.git/hooks/pre-commit: read-only file system
```

This hits `lefthook install`, `husky install`, `pre-commit install`, and
`simple-git-hooks`. The **host** owns hook installation; the container only needs
the hook *binary* on `PATH` so the host-written shim runs. Gate the install on
writability and split the cases — don't use `cmd && install || echo`, which prints
"not on PATH" even when the *install* is what failed:

```sh
if ! command -v lefthook >/dev/null 2>&1; then
  echo "post-create: lefthook not on PATH — skipping"
elif [ -w .git/hooks ]; then
  lefthook install || echo "post-create: 'lefthook install' failed"
else
  echo "post-create: .git/hooks is read-only (sandbox self-protection) — skipping install"
fi
```

(A truly fresh clone whose *host* never ran `lefthook install` has no hook at all,
and the container can't create one through the RO mount. The durable fix is
declaring the tool in the project toolchain + a CI install step, not the sandbox.)

### `npm i -g` can't install postinstall-binary tools

The sandbox sets `NPM_CONFIG_IGNORE_SCRIPTS` (supply-chain hardening), which
suppresses postinstall scripts. Tools that *download a binary* in a postinstall
(lefthook, gitleaks, …) therefore install **nothing** via `npm i -g`. Fetch the
pinned static release binary into `~/.local/bin` (no sudo, survives rebuild) —
watch the per-project arch strings, they differ:

```sh
# lefthook assets use x86_64 / arm64; gitleaks uses x64 / arm64
arch=$(uname -m)  # -> x86_64 | aarch64
curl -fsSL -o ~/.local/bin/lefthook \
  "https://github.com/evilmartians/lefthook/releases/download/v2.1.10/lefthook_2.1.10_Linux_${arch}"
chmod +x ~/.local/bin/lefthook
```

Pure-JS language servers (`pyright`, `typescript-language-server`) ship their
code rather than fetching a binary, so `npm i -g` is still correct for the LSP
table above. Add `--no-audit` to quiet a cosmetic `--global` + `--audit` warning.
