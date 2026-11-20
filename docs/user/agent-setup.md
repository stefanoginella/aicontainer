# Set up aicontainer with an AI agent

This page is for an AI coding agent: Claude Code, Codex, OpenCode, or any
other agent that can read files and run shell commands. A person can read it
too, but the [Quick start](../../README.md#quick-start) and
[Usage](usage.md) are shorter.

To use it, open an agent session **on your host**, in the project directory,
and send:

```text
Set up aicontainer in this project. Follow
https://github.com/stefanoginella/aicontainer/blob/main/docs/user/agent-setup.md
```

> **Warning:** Run this agent session in its normal approval mode, not in
> bypass or auto-approve mode. The agent runs on the host, outside the
> sandbox, so it can read your home directory. You approve the plan, the
> global install, the first boot, and `aic trust` yourself.

The rest of this page is the procedure for the agent.

---

## Your task

Take the project from "no sandbox" to "the AI agent runs behind the
aicontainer devcontainer boundary, set up for the stack of this project."
Detect the stack. Check that a Linux devcontainer can run the project.
Propose a concrete plan. When the user approves it, apply it, and verify that
the container boots.

aicontainer lets Claude Code, Codex, and OpenCode run with permissions
skipped. A prompt-injected dependency then cannot get the real `$HOME`,
`.env`, SSH keys, or `gh` token of the user. A good setup makes the sandbox
usable for the project: a Python repository needs a writable `.venv`, an agent
that uses go-to-definition needs a language server on `PATH`, and a Postgres
app needs the database. This per-project wiring is your work.

The other half is the *person*: their tool settings, prompt, aliases, and
statusline. aicontainer seeds some of them automatically. It drops some on
purpose. Some need an opt-in that the user does not know about. Step 6 covers
this. Users do not use a sandbox that they cannot work in.

When this page tells you to ask the user, use a question tool if your agent
has one. Otherwise ask in plain text and wait for the answer.

## Rules

These rules come from the design of aicontainer. If you break them, your work
is deleted silently or `aic sync` breaks.

- **Run `aic` on the host, never in the container.** Setup happens before or
  outside the sandbox. If you are *in* an aicontainer already (Step 0), stop
  and tell the user to start you from a host terminal. The sandbox mounts
  `.devcontainer/` read-only on purpose.
- **Never edit `.devcontainer/devcontainer.json` or
  `.devcontainer/docker-compose.yml`.** They are managed files: `aic init`
  writes them and `aic sync` overwrites them. Only the `AIC_TOOLS` and
  `AIC_SHELL` choices survive a sync. Put every customization in the
  project-owned files (next rule). `aic sync` resets edits to managed files.
- **Put every customization in project-owned files.** `aic sync` never
  changes them: `Dockerfile.project`, `docker-compose.override.yml`,
  `chown-paths`, `post-create.project.sh`, `vscode-extensions`,
  `vscode-settings.json`, `firewall-allowlist`, `firewall-enable`,
  `firewall-presets`, `shell-rc.zsh`, `p10k.zsh`, `statusline.{sh,mjs,js,py}`.
  Each one is active only when it exists.
- **`aic rebuild` rebuilds. `aic up` reuses.** aic builds the devcontainer
  image itself. The Dev Containers CLI never builds it
  (`docker-compose.prebuilt.yml` removes the build from the model that it
  starts). Each start, also `aic up` and VS Code **Reopen in Container**, runs
  a **cached** build. But `aic up` can keep a container that exists, so an
  edited `Dockerfile.project` can miss it. `aic rebuild` builds **without**
  the cache and recreates the container. Thus, when the plan writes a
  `Dockerfile.project`, the first boot is `aic rebuild`. Each boot after an
  edit to it is also `aic rebuild`. A failed build stops the start.
- **Only the user can grant trust.** A `Dockerfile.project`, an added mount, a
  protected environment key, or Docker socket access makes `aic validate`,
  `aic up`, and `aic rebuild` fail closed until the user runs `aic trust`.
  `aic trust` **needs a TTY**, so you cannot run it from a tool call. Give it
  to the user. Never use `--allow-unsafe` to get around it. Trust binds to an
  exact config hash, so **each** later edit to `docker-compose.override.yml`
  or `Dockerfile.project` revokes it. Complete the config before you ask
  (Step 8).
- **Show the plan, then apply it.** Detect and confirm first. Show the full
  plan and get a yes. Then write files and run `aic init` or `aic sync`.
  **Ask before the first boot**: it pulls or builds an image of multiple
  gigabytes and can take minutes. When the user says yes, do the boot
  yourself. Verify that the container boots and fix what is broken (Step 9).
  Do not only give back a command.

## Step 0 — Preconditions

1. **Are you on the host or in an aicontainer?** If `/etc/aic` exists, or the
   variables `REMOTE_CONTAINERS`, `DEVCONTAINER`, or `AIC_TOOLS` are set, you
   are *in* the sandbox. The PreToolUse hook blocks `.devcontainer/` writes.
   Stop and tell the user to start you from a host terminal.
2. **Is this a Git repository?** `aic init` expects a project directory. A
   directory without a repository works too, but say so. The sandbox
   bind-mounts `$PWD` as `/workspace` in both cases.
3. **Is the `aic` CLI installed?** Run `command -v aic`. If it is missing, do
   not stop. **Offer to install it**, because no other step works without it:
   - **First check Node.js 18+** (`node --version`). The npm install and the
     bundled `@devcontainers/cli` need it. If Node.js is missing or too old,
     tell the user and stop the install.
   - **Offer the install and wait for a yes.** It is a global package install,
     so never run it silently. The default is `npm install -g aicontainer`.
     If the user wants a Git checkout instead:
     `git clone https://github.com/stefanoginella/aicontainer ~/.aicontainer && ~/.aicontainer/install.sh`.
     A checkout also needs `npm install -g @devcontainers/cli`.
   - **Verify the install.** Run `command -v aic` and `aic --version` again.
     If the install failed or `aic` is still not on `PATH`, stop and show the
     error.
4. **Is Docker running?** `docker info` must succeed (Docker Desktop,
   OrbStack, Colima, …). You can continue without Docker, but Step 9 needs it.
   Tell the user; do not stop.
5. **Does the project have an aic setup already?** If
   `.devcontainer/devcontainer.json` exists and refers to aicontainer (the
   GHCR image or `AIC_TOOLS`), this is a *re-setup*: use **update mode**. Do
   not generate the config again, and do not propose files that exist and are
   correct. Do Steps 1 to 3, then follow "Update mode" below instead of the
   new-setup part of Step 5. If `.devcontainer/` does not exist, do Steps 1
   to 10 in sequence. A missing `.devcontainer/` does not prove a clean
   project: an older aic can leave a legacy Docker volume or stack that
   `aic up` migrates (`aic: migrating legacy session transcripts …`). This is
   expected, not an error.
6. **Is an old stack still running for this path?** The Compose project name
   comes from the canonical path (`aic-<basename>-<hash>`). A *previous* setup
   for this directory can still own containers and volumes, also when its
   `.devcontainer/` is gone. `aic up` does **not** pass `--remove-orphans`, so
   those services keep running and appear later in `docker compose ps`. Look
   now: `docker ps -a --filter "name=aic-<basename>-"` and
   `docker volume ls --filter "name=aic-<basename>-"`. When a config exists,
   `aic down` removes the orphans (it uses `--remove-orphans`). Old named
   volumes can hold real data. Tell the user about them and let them decide.
   Never delete a volume that the user did not tell you to delete.

## Update mode — audit an existing setup

If Step 0 found an aic setup, your task is **not** "generate a config." Your
task is "check that the personalization of the project still fits its stack,
and update only what is missing, old, or drifted." The project can have a new
language, a new service, browser end-to-end tests, or new build artifacts.
The user can also have updated the global `aic`. Do Steps 1 to 3 first, then:

1. **List what exists.** Find the project-owned files that exist and **read
   them**: `Dockerfile.project`, `docker-compose.override.yml`, `chown-paths`,
   `post-create.project.sh`, `vscode-extensions`, `vscode-settings.json`,
   `firewall-allowlist`, `firewall-enable`, `firewall-presets`,
   `shell-rc.zsh`, `p10k.zsh`, `statusline.{sh,mjs,js,py}`. Also note the
   `AIC_TOOLS` and `AIC_SHELL` values in `devcontainer.json`, and the
   host-global overlays in `~/.config/aicontainer/` (`rc.zsh`, `p10k.zsh`,
   `statusline.*`). This is the baseline.
2. **Compare the baseline with the stack.** Look for:
   - **Missing coverage.** A stack fact with no matching file: a new language
     with no LSP server in `post-create.project.sh` and no editor extension; a
     Python project with no writable `.venv` volume; a new Postgres or Redis
     service with no wiring in `docker-compose.override.yml`; Playwright or
     Chromium with no `Dockerfile.project`. Compare each confirmed stack with
     its `## Stack:` section in the stack reference (Step 1). That section
     lists all that the stack needs.
   - **Missing personalization.** The environment of the user, not the stack:
     no shell or prompt overlay and no statusline while the host has them
     (Step 6), or a statusline copy that differs from the host original now.
     A setup that is older than a slot does not have it. Offer it; do not
     think that the user declined it.
   - **Old or incorrect entries.** A `chown-paths` line for a volume that the
     override no longer declares; a `vscode-settings.json` interpreter path
     that does not exist; an LSP install or extension for a language that the
     project removed; a tool in `AIC_TOOLS` that the user no longer wants.
   - **Version or base drift.** After `npm update -g aicontainer`, the
     `FROM …:vX.Y.Z` of `Dockerfile.project` can be older than the tag in
     `docker-compose.yml`. `aic sync` **warns**. The fix is
     `aic sync --bump-base`, which writes the new `FROM`. Do not edit the
     base of a project-owned file by hand for this.
3. **If nothing is missing, old, or drifted, say so and stop.** "Your setup
   already matches your stack; there is nothing to update" is a valid result.
   Do not make changes only to show work.
4. **Otherwise show only the changes (Step 7) and apply them (Step 8).** Write
   the new or changed project-owned files. Do not touch correct files. Then
   run `aic sync` to refresh the override wiring and the `vscode-extensions`
   and `vscode-settings.json` merges. Then do Step 9: an update is not
   complete until you see the container boot without errors.

## Step 1 — Read the docs of the installed aic

Read the user-guide pages of the **installed** aic version, not the pages on
`main`. `main` can describe features that the installed aic does not have.
For example, an older aic ignores a `firewall-presets` file, and the user then
thinks that the firewall allows hosts, or is on, when it is not.

1. **Find the installed copy.** The npm package and a Git checkout both have
   the user guide in `docs/user/`. Find the package root:

   ```bash
   aic --version   # prints aic vX.Y.Z
   node -p 'require("path").dirname(require("fs").realpathSync(process.argv[1]))' "$(command -v aic)"
   ```

   Use `<root>/docs/user/` when `<root>/docs/user/stack-reference.md` exists
   and the `version` in `<root>/package.json` is the version that
   `aic --version` prints.
2. **Follow the installed copy of this page.** If you did not read this page
   from `<root>/docs/user/agent-setup.md`, read that file now and follow it
   instead of this copy. It matches the installed aic.
3. **Read these pages:**
   - `stack-reference.md`: **the stack-to-files mapping. Always read it.** For
     each stack (Node.js, Python, Go, Rust, Ruby, PHP, Java, C and C++): marker
     files, `Dockerfile.project` toolchain lines, named volumes and
     `chown-paths`, `post-create.project.sh` steps (with the LSP server of the
     agent), editor extensions and settings, firewall presets, and trust
     notes. It also has the shared files, how to combine stacks, the volume
     reset, and the fit list. Steps 2, 4, and 5 use it.
   - `customization.md`: `docker-compose.override.yml`, named volumes and
     `chown-paths`, `post-create.project.sh`, VS Code extensions and settings,
     LSP and `.venv` recipes. Always read it.
   - `extra-tools.md`: `Dockerfile.project` and the Playwright recipe. Read it
     when the project needs OS packages or a browser.
   - `personal-config.md`: the shell overlay and the statusline. Read it when
     the user asks about their prompt or statusline.
   - Human URL, to give links to the user:
     `https://github.com/stefanoginella/aicontainer/tree/vX.Y.Z/docs`

**If the installed aic has no `docs/user/`** (an aic older than this page),
get the pages from the release tag of the installed aic:
`https://raw.githubusercontent.com/stefanoginella/aicontainer/vX.Y.Z/docs/user/`.
Tags are never rewritten, so a tag fetch is fixed content. Keep following the
copy of this page that you have. **Never use `main` silently:**

- **Unknown version** (`aic --version` fails or prints no `vX.Y.Z`): read no
  stack page. Repair the install first (Step 0.3). Without a known version,
  generate only what the user asks for explicitly.
- **The tag has no `stack-reference.md`** (HTTP 404: the aic is older than the
  page): tell the user, and recommend `npm update -g aicontainer` (then
  `aic sync` in an existing project). Then read the pages of the new version.
  If the user does not update:
  - aic **v0.11.0 or later** (the baseline of the page): you can use the page
    from `main`, but say so first. Remove each item whose `(since …)` marker
    is `Unreleased` or a version newer than the installed one. Tell the user
    the name of each item that you removed.
  - aic **older than v0.11.0**: do not use the page. Tell the user, and
    generate only what they ask for explicitly.
- **Offline, or the fetch failed:** for the split between managed and
  project-owned files, `.devcontainer/README.md` (written by `aic init`) and
  `aic help` match the installed version. Without a usable
  `stack-reference.md`, do not write stack snippets from memory. Tell the
  user, and generate only what they ask for explicitly.

The docs tell you *what to generate*: `stack-reference.md` for the stack
mapping, the other pages for the syntax of each recipe. This page gives the
*procedure and judgment*: read the repository, confirm with the user, choose
the optional parts, and put trust and boot in the correct sequence.

## Step 2 — Detect the stack

Make a profile of the project. Read; do not guess. Look at:

- **Manifests and lockfiles:** `package.json`, `pyproject.toml`,
  `requirements.txt`, `uv.lock`, `go.mod`, `Cargo.toml`, `Gemfile`, `pom.xml`,
  `build.gradle`, `composer.json`, `*.csproj`, `*.sln`, `mix.exs`,
  `pubspec.yaml`, `Package.swift`, `*.xcodeproj`, `CMakeLists.txt`.
- **Runtime version pins:** `.nvmrc`, `.python-version`, `.tool-versions`,
  `.ruby-version`, `Dockerfile`, an existing `docker-compose.yml`.
- **Services that the app needs:** the services in `docker-compose.yml`, the
  keys in `.env.example` or `.env.sample` (`DATABASE_URL`, `REDIS_URL`, …),
  ORM and migration config. They become host-service or sibling-container
  wiring.
- **Test and automation tools:** especially browser end-to-end tests
  (`@playwright/test`, `cypress`, `puppeteer`) and native build steps. They
  need a `Dockerfile.project`.
- **Design docs in `.md`:** `README.md`, `ARCHITECTURE.md`, `docs/`, PRD,
  spec, or design files. Use them when the code gives few signals or the
  repository is new. A spec that says "React + FastAPI + Postgres" is a real
  signal.

The "Detect a stack" table in `stack-reference.md` maps marker files to stack
sections. The table below adds the signals that a marker table does not
cover:

| Signal | Inference |
|---|---|
| `docker-compose.yml` services (postgres, redis, mysql, mongo, …) | The app needs those services. Wire them as host services (`host.docker.internal` in the override) or as sibling containers. |
| `.env.example` / `.env.sample` keys (`DATABASE_URL`, `REDIS_URL`, `*_HOST`) | The same. Wire the service in the override with **literal** development values. Never pass a host variable through. |
| ORM or migration config (Alembic, Prisma, Rails `db/`, Django `migrations/`) | The project needs a database during development. Ask if it runs on the host. |
| `@playwright/test`, `cypress`, or `puppeteer` in the dependencies | Browser end-to-end tests need a `Dockerfile.project`. The stack reference links the Playwright recipe. |
| Design docs (ARCHITECTURE, PRD, TECH-STACK, DESIGN, specs, `docs/`, `.specify/`, …) | They are the main source when the code is sparse. A spec that names the stack is a real signal. |
| `*.csproj`, `*.sln`, `mix.exs`, `pubspec.yaml`, `Package.swift`, `*.xcodeproj` | A stack that the stack reference does not cover, or a possible non-fit. See Step 4. |

When no manifest exists (a new repository, before the first commit), the
design docs are the *main* signal, not an addition. An approved spec, an ADR,
or a pinned TECH-STACK can give the full stack with versions. Read them before
you ask the user. Ask only when the docs give no answer. In a new repository,
each post-create step must also check that its manifest exists. The steps in
the stack reference already do this; keep that check.

The result is a short profile: **languages, package managers, runtime
versions, services, test tools, and GUI, mobile, native, or hardware
signals.**

## Step 3 — Confirm the stack with the user

Do not continue on a guess. Show the profile in a short form and ask the user
to confirm or correct it. If detection was not clear (a sparse repository, an
unusual layout), **ask the user** for the stack. Do not invent one. The plan
is only as good as this profile.

## Step 4 — Check that a devcontainer fits

aicontainer is a **headless Linux** devcontainer. Most server, web, CLI,
library, data, and ML-on-CPU work fits well. Some work cannot run in it. Find
it *before* you generate config, so that the user does not find it after a
rebuild. The fit list (iOS or macOS native, Windows native, GUI on the host
display, hardware passthrough, Android emulator, GPU or CUDA) is in the
"Check the fit" section of `stack-reference.md`. Classify the project against
it. A host with no Docker runtime (Step 0) is also a non-fit: nothing runs
without one.

- **A non-fit:** say so clearly and name what does not work. Look for a
  **partial** setup that still helps. A repository is often a non-fit
  frontend and a backend that fits. For example, for an iOS app with a
  Node.js backend, sandbox the backend and build the app on the host. Then let
  the user decide. Never generate a config that cannot work.
- **A stack that the page does not cover** (.NET 5+, Elixir, Dart, Swift on
  Linux): it can fit, but nothing on the page is tested for it. Propose only
  the common files and the pattern of the stack sections. Say that the
  toolchain lines are not tested, and get an explicit yes before you write
  them.
- **A version pin that the page cannot meet.** Most toolchains on the page
  come from the base image or the Ubuntu packages (Ruby 3.2, PHP 8.3, JDK 21
  or 17). Go is the exception: you set `GO_VERSION` to the `go.mod` version. A
  `.ruby-version` that asks for Ruby 3.3 is outside them. Say so. Do not add a
  version manager to `Dockerfile.project` silently.

## Step 5 — Choose the tools and the shell, and map the stack to files

First, the two `aic init` choices. Ask, or use the defaults and say so:

- **AI tools** (`--with`): `claude-code`, `codex`, `opencode`, or a
  comma-separated list. The default is all three.
- **Shell** (`--shell`): `zsh` (default), `bash`, or `fish`.

Then map the confirmed stack to **project-owned files** with
`stack-reference.md` (Step 1). That page is the only source for the mapping.
Take the snippets from it. Do not keep or invent a private copy:

- **One `## Stack: <name>` section for each confirmed stack.** Each section
  has the same subheadings in the same sequence: Detect, Toolchain, Named
  volumes and chown-paths, Post-create, Editor, Firewall presets, Trust and
  caveats. Read each one and put its snippets in the plan.
- **Two or more stacks: use the "Combine stacks" section.** One file of each
  kind: one `FROM`, one `services.devcontainer` block in the override, one
  `post-create` header, and merged `chown-paths`, `vscode-extensions`, and
  `vscode-settings.json`.
- **Shared parts: use the "Common files" section.** The `FROM` line of
  `Dockerfile.project` and the `build:` block of the override with its own
  `image:` tag, the header of `post-create.project.sh`, and the post-create
  constraints (check the manifest, read-only `.git/hooks`,
  `NPM_CONFIG_IGNORE_SCRIPTS`).
- **Host services and browser end-to-end tests** are add-ons, not stacks. The
  "Detect a stack" table links to the override example and the Playwright
  recipe.

Judgment that stays with you:

- **The user decides about optional parts.** The page marks some entries
  optional (a `node_modules` volume, a C or C++ build-directory volume, the
  Poetry variant). Offer them; do not add them without a yes.
- **The firewall files are opt-in.** `firewall-enable`, `firewall-presets`,
  and `firewall-allowlist` are for stricter containment (a review of
  untrusted code, a corporate LAN). They are off by default. Tell the user
  about them; do not add them without a yes. If the user wants them, take the
  preset names and extra hosts from the stack sections.
- **Each `Dockerfile.project` costs one `aic trust` and makes `aic rebuild`
  the boot command** (see Rules). Plan the sequence for this.
- **Personal overlays (`shell-rc.zsh`, `p10k.zsh`, `statusline.*`)** are
  personalization, not stack mapping. Users often think that they come
  automatically. Do them in **Step 6**, not here.

**LSP is important to users.** There are *two* LSP surfaces. Tell the user
about both:

- The **editor** IntelliSense: extensions and settings.
- The **agent** LSP tool: a language-server binary on `PATH`, installed from
  `Dockerfile.project` or `post-create.project.sh`.

A project usually needs both. Each stack section of `stack-reference.md` has
both: the Editor subsection, and the server in Toolchain or Post-create.

## Step 6 — Bring the host config and preferences of the user

A sandbox that builds the project but feels strange to work in is half done.
This step closes the gap between "the container runs" and "it is *my*
environment." Do it for new setups and in update mode.

Start with what aicontainer does already. Most users think that nothing
carries over, and that is wrong. **Do not explain the whole boundary again.
Tell the user what to *do*.**

### 6.1 — Automatic: keep it current

Before each `aic up` or `aic rebuild`, a root-only sanitizer without network
reads four fixed host files. It writes allowlisted JSON that the container
reads read-only. The user edits these files **on the host** and runs
`aic rebuild` again:

| Host file | What carries over |
| --- | --- |
| `~/.claude/settings.json` | Model, effort, editor mode, theme, plugins and marketplaces, MCP servers, verbosity, … |
| `~/.codex/config.toml` | Model, reasoning effort, personality, `[mcp_servers.*]`, `[projects.*]` |
| `~/.config/opencode/opencode.json` | Provider and model, agents, instructions, theme, keybinds, formatter, LSP, MCP |
| `~/.gitconfig` | Identity and workflow preferences that run no command (pull, push, rebase, diff, merge) |

### 6.2 — Dropped on purpose: say so before the user looks for it

These are not bugs. The allowlist drops them because they defeat the sandbox
or carry host-only paths or secrets. Tell the user the *replacement*, not only
the removal:

- **`permissions`, `hooks`, Codex `approval_policy` and `sandbox_mode`:** the
  container sets its own at root-managed precedence. That is the purpose of
  the sandbox.
- **`env` blocks, inline MCP `env` and `headers`, API keys and tokens:** never
  forwarded. Replacement: log in **in** the container once (`claude`,
  `codex`, `opencode auth login`, `gh auth login`, `npm login`). The
  credentials stay in a global volume across rebuilds and projects.
- **`statusLine`:** a command string with a host path. Replacement: the
  statusline overlay in 6.3.
- **Git `credential.helper`, aliases, `include` and `includeIf`,
  `core.hooksPath`, signing key paths:** they carry commands or paths.
  Replacement for signing: `aic signing` makes a sandbox-only key. The host
  key is never forwarded.
- **Host `~/.zshrc` and `~/.p10k.zsh`:** never forwarded automatically.
  Replacement: 6.3.
- **MCP servers that point at host-only binaries:** aicontainer seeds them,
  but they cannot start in Linux. MCP servers with a URL or from npm work.
  Tell the user if they have such servers, so that a later startup error is
  not a surprise.

### 6.3 — The opt-in overlays: offer to set them up

There are three independent slots. Each one is active only when its file
exists, and `aic sync` does not change it. Each one can be host-global (once,
for all projects) or for one project:

| What | Host-global file | Project file |
| --- | --- | --- |
| zsh startup (aliases, functions, exports) | `~/.config/aicontainer/rc.zsh` | `.devcontainer/shell-rc.zsh` |
| powerlevel10k prompt | `~/.config/aicontainer/p10k.zsh` | `.devcontainer/p10k.zsh` |
| Claude Code statusline | `~/.config/aicontainer/statusline.{sh,mjs,js,py}` | `.devcontainer/statusline.{sh,mjs,js,py}` |

Note the **different file names**: the shell file is `rc.zsh` on the host but
`shell-rc.zsh` in the project. `p10k.zsh` and `statusline.*` have the same
name in both places. The project file wins when both exist. Each change takes
effect on the next `aic rebuild`.

The statusline slot holds only the script. aicontainer supplies the command
(`/usr/local/bin/aic-statusline`, a fixed launcher) and selects the
interpreter from the **extension**: `.sh` uses bash, `.mjs` and `.js` use
node, `.py` uses python3. Thus:

- **Use one self-contained file.** A statusline that imports sibling modules
  breaks. Bundle the modules or use a different statusline. Its own state in
  `~/.claude/statusline/` is writable and per project, so caches work.
- Each command that it runs must exist in the container. `git` exists;
  host-only binaries do not.
- **Best host setup:** keep the real script *at*
  `~/.config/aicontainer/statusline.mjs`, and point the host
  `~/.claude/settings.json` to it too. Then there is one file and no drift.
  Otherwise the overlay is a copy that becomes old. Tell the user.

> **Warning:** All three slots are **code, not data**. They cross the
> boundary **unchanged** (aicontainer cannot sanitize code), and the agent in
> the container can read them. **Never put secrets in them.** Host paths and
> user names in them become visible in the sandbox; tell the user. They are
> installed root-owned with mode `0444`, so the agent cannot change them, and
> they run only as the unprivileged `vscode` user.

### 6.4 — Offer to draft the overlays from the host files (optional)

Users who want "my shell and statusline in the sandbox" usually have a host
`~/.p10k.zsh`, `~/.zshrc`, or statusline script, and they expect it to
appear. It does not: host dotfiles often hold secrets and host-specific
parts, and the sandbox runs an untrusted agent that can read all that is
mounted. So *offer to close that gap*: **draft** the overlay from the host
files. It is a draft that the user reviews, never a silent transform.

You can do this here because *you* run on the **host**, in a session with the
permissions of the user. That is a different trust context from the sandboxed
agent in bypass mode that the threat model is about, and you can read these
files already. This is safe **only while the user approves each file**: you
change the user from author to reviewer, but you do not remove them. Do not
write a drafted file without approval.

When the user wants this:

1. **Read the host files** on the host: `~/.p10k.zsh`, `~/.zshrc`, and the
   script that the host `statusLine.command` names. Get its path from
   `~/.claude/settings.json`; do not guess a location.
2. **`p10k.zsh`: copy it almost unchanged.** It is almost always output of
   `p10k configure`: declarative `typeset -g POWERLEVEL9K_*` lines with no
   secrets. Copy it, but **scan** it for unusual content: custom segment
   functions that run commands, host paths, and all that looks like a secret.
   Tell the user about each one.
3. **`rc.zsh`: extract what is safe; do not remove what is unsafe.** Take only
   categories that are clearly safe: aliases, simple functions, `setopt`, key
   bindings, prompt changes. Leave all other content: `export *_KEY`,
   `*_TOKEN`, `*_SECRET=…`, `source` lines for secret or env files, plugin
   managers and `eval "$(tool init)"` for tools that the sandbox does not have,
   aliases to host-only binaries. **When you are not sure, leave it out.**
4. **`statusline.*`: copy it whole, then audit it.** You cannot extract "the
   safe half" of a program, so the decision is all or nothing. Read the whole
   script and report what can break or leak: a host path, a host-only binary
   that it runs, an API token, a network call, a sibling import. If you find
   one, tell the user and let them decide: fix the script, drop the slot, or
   accept it.
5. **Be honest about the two risks.** You are *reliable* at preventing
   breakage ("this sources oh-my-zsh from a host path, so I removed it"). You
   *help with, but cannot guarantee,* the removal of secrets. Never say "I
   sanitized your config." Say "Here is a short draft. Review it and confirm
   that it has no secrets."
6. **For each file, show what you kept and what you removed, with the
   reason,** and put the drafts in the Step 7 plan. Get an explicit yes for
   them. This content comes from private files of the user, so it needs its
   own review, not a general approval.
7. **After approval, write the files** to `~/.config/aicontainer/`
   (host-global, for all projects) or `.devcontainer/` (this project only), as
   the user wants. Use the file names in the 6.3 table.

If the user does not want a draft, or you cannot make a clean one, use the
manual path: the user puts the files in place (with no secrets) and runs
`aic rebuild`. In both cases, verify the result in Step 9
(`aic run test -r /etc/aic/user-config/statusline/statusline.mjs`,
`aic run /usr/local/bin/aic-statusline`, or a login `zsh -lic true`). Do not
assume that it worked.

## Step 7 — Show the plan

Before you change anything, show the user:

1. The confirmed stack and the fit result.
2. The `aic init` command (with `--with` and `--shell`).
3. Each project-owned file that you will write, **with its content**, and one
   line on *why* (the stack fact that needs it).
4. **The Step 6 personalization**, separate from the stack wiring: what
   carries over unchanged, what aicontainer drops and what replaces it, and
   each overlay that you drafted (with the kept and removed summary and its
   own explicit yes). Say where each overlay goes: host-global
   `~/.config/aicontainer/` or `.devcontainer/` of this project.
5. **If the plan needs `aic trust`, say so now.** Name the finding that it
   will cause (almost always the root build of `Dockerfile.project`), and say
   that the user runs one command in their own terminal at a known point. A
   user who sees the trust gate only when the build stops thinks that setup
   failed.
6. That you will offer to verify the boot: `aic rebuild` when there is a
   `Dockerfile.project`, else `aic up`. You will watch it to the end and fix
   problems. You will ask first, because it pulls or builds multiple
   gigabytes.

Get an explicit yes. If the user wants changes, apply them to the plan and
show it again.

## Step 8 — Apply the plan

The sequence is important, because `aic sync` adds the override to
`dockerComposeFile`:

1. **Initialize:** `aic init --with <tools> --shell <shell>` for a new
   project, or `aic sync --with <tools> --shell <shell>` if Step 0 found an aic
   setup. With these flags, both commands are non-interactive.
2. **Read the pinned tag** from `.devcontainer/docker-compose.yml` if you
   write a `Dockerfile.project`. Use it in the `FROM` line.
3. **Write the project-owned files** of the approved plan.
4. **Wire the override:** run `aic sync` again. It adds a new
   `docker-compose.override.yml` to `dockerComposeFile` in
   `devcontainer.json` (only when the file exists). Verify with
   `grep dockerComposeFile .devcontainer/devcontainer.json`. With an override,
   it lists exactly three files in this sequence: `docker-compose.yml`,
   `docker-compose.override.yml`, `docker-compose.prebuilt.yml`. Without an
   override, it lists exactly two: `docker-compose.yml`,
   `docker-compose.prebuilt.yml`. The managed prebuilt file is always last.
   Never edit it or move it.
5. **Validate, and stop the hash from changing.** Run `aic validate`. It
   applies the same gate as `aic up` and `aic rebuild`, but it never prompts
   and never writes trust. It is the safe way for *you* to read the findings.
   Fix all mechanical findings now (rejected mount targets, drift in managed
   files, override syntax). Each fix changes the config hash, and the hash
   must stop changing before the user trusts it.
6. **Test the build before you use the approval of the user.** Do this only
   when there is a `Dockerfile.project`. A plain `docker build` with the same
   image tag as the override needs no trust. It proves that the Dockerfile
   builds, and it fills the layer cache, so the `aic rebuild` after trust is
   fast:

   ```bash
   docker build -f .devcontainer/Dockerfile.project -t <image tag of the override> .devcontainer
   ```

   A Dockerfile bug that you find here costs nothing. After trust, it costs
   one more round with the user.
7. **Give the trust step to the user.** When `aic validate` ends with
   `unsafe configuration is not trusted`, stop. Show the exact `!` finding
   lines, say in one sentence why the plan needs each one, and ask the user to
   run `aic trust` in their own terminal. Then run `aic validate` again.
   `configuration valid — managed files and resolved Compose model are
   accepted.` confirms the trust. Do not use `--allow-unsafe`. If you edit a
   project-owned file after the approval, tell the user that it needs a new
   approval.

The config is on disk and trusted now, but it is not proven to work. Do
Step 9 before you say that the setup is complete.

## Step 9 — Verify that it boots

The task is not only to write files. A sandbox that the project cannot start
in is not complete. Prove that it boots and that the Step 5 customization
works before you report success.

1. **Select the command, then ask before the pull or build.** Use
   `aic rebuild` if the plan wrote a `Dockerfile.project`; it is the only
   command that builds it (see Rules). Else use `aic up`. Both can pull a GHCR
   image of multiple gigabytes, take minutes, and use disk space, so ask the
   user first. In **update mode** the container usually exists, and `aic up`
   keeps it unchanged. A change that must run again (a changed
   `post-create.project.sh`, a new named volume, a new image) also needs
   `aic rebuild`. If the user wants to run it themselves, or Step 0 found that
   Docker is not running, go to Step 10 and give the commands.
2. **Run it without a pipe and read all of the output.**
   `aic up 2>&1 | tail -60` returns the exit status of `tail`, so a config that
   aic *refused* looks like a success with exit 0. Capture the full output
   (run it in the background if it is long) and read it. The exit code alone
   does not tell a refusal, a `Dockerfile.project` build failure, a bad
   override key, and an old pinned tag apart.
3. **If it fails, fix it. Do not give a broken container to the user.** Read
   the error, and find the project-owned file that probably causes it:
   - `unsafe configuration is not trusted`: the config changed after the
     approval of the user, or the user never approved it. Go back to Step 8,
     items 5 to 7: validate, stop the changes, and ask again. Never use
     `--allow-unsafe`.
   - The container boots, but each tool from the build is missing and the
     named volumes are not writable: the build did not run. You used `aic up`
     where a `Dockerfile.project` needs `aic rebuild`.
   - An image build error: check that the `FROM` of `Dockerfile.project` is
     the pinned tag (`grep image: .devcontainer/docker-compose.yml`).
   - A Compose parse or validation error: check the syntax of
     `docker-compose.override.yml`, and check that it extends only the
     `devcontainer` service.
   - The container starts, but a volume mount is not writable: check that the
     override declares the path as a volume **and** that `chown-paths` lists
     it, under an allowed prefix (`/workspace/`, `/home/vscode/.cache/`).
   - A `post-create.project.sh` step had no effect (aic logs its failures but
     continues the boot): fix the script, then run `aic rebuild` (or
     `aic destroy && aic up` if the state must be clean) to run it again.

   After each fix to a project-owned file, run `aic sync` again so the wiring
   stays current. Then run `aic up` or `aic rebuild` again. Continue until the
   boot has no errors. After each fix, confirm that it solved the failure.
4. **Check that the plan took effect.** Use `aic run <cmd>`; you do not need
   an interactive shell:
   - **The container runs the expected image.** Do this check first when
     there is a `Dockerfile.project`; it finds a skipped build with one
     command:
     `docker compose --env-file .devcontainer/.env -f .devcontainer/docker-compose.yml -f .devcontainer/docker-compose.override.yml ps --format '{{.Service}}\t{{.Image}}'`.
     If `devcontainer` shows the base `ghcr.io/stefanoginella/aicontainer:…`
     tag, the build did not run: use `aic rebuild`. The list also shows each
     *unexpected* service, usually an orphan from an old stack (Step 0.6).
   - The LSP binary is on `PATH`: `aic run command -v pyright-langserver` (or
     the server that Step 5 installed).
   - A named volume is writable: `aic run test -w /workspace/.venv && echo ok`.
   - A host service is available: `aic run curl -sS host.docker.internal:5432`
     (or the service that the stack needs).
   - **The Step 6 overlays are installed** (only the slots that the plan
     filled): `aic run ls -l /etc/aic/user-config/shell /etc/aic/user-config/statusline`
     shows `root … 444` files. Then prove that they *run*:
     `aic run /usr/local/bin/aic-statusline` prints a status line (no output
     means that nothing is installed; an error comes from the script), and
     `aic run zsh -lic 'alias'` shows a personal alias. If a slot is empty,
     the usual cause is a wrong file name: `rc.zsh` and `shell-rc.zsh`, or an
     extension other than `sh`, `mjs`, `js`, or `py`.
   - `aic preflight` confirms that the trust boundary (firewall mode, mounts)
     matches the plan.

   `aic run` proves the **agent** LSP (a binary on `PATH`), the volumes, and
   the services, but **not** the editor. `vscode-extensions` and
   `vscode-settings.json` take effect only in a VS Code Dev Containers
   session. Do not report the editor IntelliSense as verified. This is the
   expected limit of a headless boot check, not a gap.
5. **Keep it running or stop it?** Ask the user. `aic down` stops the
   container (the volumes stay) if the user will not work now. Keep it running
   if they will.

If you cannot verify (no Docker, offline, the user said no), say so clearly
and do the Step 10 handoff.

## Step 10 — Hand off

Tell the user what to run next and how to confirm that it works. The handoff
depends on Step 9:

- **Step 9 verified the boot:** say so. Say if the container is still running
  or if you ran `aic down`. Give the commands to continue: `aic shell` (or
  `aic up` again if it is stopped), then `claude`, `codex`, or `opencode`.
- **Step 9 did not run:** give the full CLI sequence: first `aic trust` if
  `aic validate` still refuses the config, then `aic rebuild` (or `aic up`
  when there is no `Dockerfile.project`) to pull or build and start the
  stack, then `aic shell`, then `claude`, `codex`, or `opencode`.
- **VS Code (in both cases):** install the Dev Containers extension, then run
  **Dev Containers: Reopen in Container** from the command palette.
- **If it applies, tell the user about:** `aic preflight` to show the trust
  boundary again; `aic signing` if they sign commits (aicontainer does not
  forward the host signing key); the firewall opt-in for stricter network
  containment.
- **If Step 6 left work for the user:** the one-time logins in the container
  (`claude`, `codex`, `opencode auth login`, `gh auth login`). For host-global
  overlays that they put in place by hand: a change to
  `~/.config/aicontainer/*` or to their host config files takes effect on the
  next `aic rebuild`, in this project and in all others.

Give commands that the user can copy, not prose.
