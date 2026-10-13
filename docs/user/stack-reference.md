# Stack reference

This page maps the stack of a project (Node.js, Python, Go, Rust, Ruby, PHP,
Java, C and C++) to the project-owned files that the stack needs in
`.devcontainer/`. Use it to set up a project by hand. Tools and AI agents can
also read it to set up a project without the
[Claude Code plugin](usage.md#claude-code-plugin). The plugin reads this page
too.

The page gives the *what*. The rules for each file are on
[Customization](customization.md), [Installing extra tools](extra-tools.md),
and [Network allowlist](network-allowlist.md).

## Read this page as a tool

The structure of this page is stable. A tool can find a stack by its heading:

- Each stack has one level-2 heading: `## Stack: <name>`.
- Each stack section has these level-3 headings, in this order:
  1. `### Detect`: the marker files that identify the stack.
  2. `### Toolchain`: the `Dockerfile.project` lines, or "None".
  3. `### Named volumes and chown-paths`: the `docker-compose.override.yml`
     and `chown-paths` lines.
  4. `### Post-create`: the `post-create.project.sh` steps.
  5. `### Editor`: the `vscode-extensions` and `vscode-settings.json` lines.
  6. `### Firewall presets`: the `firewall-presets` lines (since Unreleased).
  7. `### Trust and caveats`: what needs `aic trust`, the boot command, and
     the risks.
- The line before each code block names the target file, for example
  `.devcontainer/chown-paths:`.
- A snippet is a part of the file. To combine stacks, follow
  [Combine stacks](#combine-stacks).

### Read the page for your aic version

The page on `main` can describe features that your installed aic does not
have. Read the page from the release tag of your installed version:

```
https://raw.githubusercontent.com/stefanoginella/aicontainer/v<version>/docs/user/stack-reference.md
```

`aic --version` prints the version (`aic v<version>`). Release tags never
change. A tag before this page does not have it: update aic with
`npm update -g aicontainer`, then read the page from the new tag.

### Version markers

An item that needs a newer aic than the page baseline has a marker:
`(since vX.Y.Z)`, or `(since Unreleased)` before a release. The release
writes the version into each `(since Unreleased)` marker.

- The baseline is aic v0.11.0. An item with no marker works in v0.11.0 and
  later.
- The page at the tag of your version has only items that your version
  supports.
- If you must read the page from `main`, compare each marker with your
  version. Do not use an item with a newer version or with `Unreleased`.

| Item | Marker |
|---|---|
| `.devcontainer/firewall-presets` | (since Unreleased) |
| `.devcontainer/firewall-enable` | (since Unreleased) |

## Rules for every stack

- **Edit only project-owned files.** `aic sync` overwrites
  `devcontainer.json` and `docker-compose.yml`. See
  [Customization](customization.md#managed-files-and-project-owned-files).
- **Run `aic` on the host.** Inside the container, `.devcontainer/` is
  read-only.
- **Do not add `--docker` to `aic init` or `aic sync`.** No stack on this page
  needs write access to the Docker daemon.
- **Do not add host bind mounts.** Do not mount host directories such as
  `~/.cargo`, `~/.m2`, `~/go`, or `~/.npm`. Use a named volume under
  `/workspace/` or `/home/vscode/.cache/`. aic reports each other mount
  target as a finding, and the start stops until the user runs `aic trust`.
  Do not add such a mount to get past a finding.
- **Do not forward host secrets.** Do not write `$VAR` or `${VAR}`, and do not
  write a bare key in `environment:`. Log in inside the container instead.
- **Do not set protected variables in the override.** `PATH`, `HOME`, the
  `XDG_*` paths, and the other startup variables are trust findings in
  `environment:`. Set a tool home and `PATH` with `ENV` in
  `Dockerfile.project`.
- **Do not use `--allow-unsafe`** to skip a finding. Fix the finding, or let
  the user review it and run `aic trust`.
- **Do not put a volume directory on `PATH`.** The agent can write to every
  named volume, and the volumes keep their data after `aic rebuild` and
  `aic destroy`. A program that the agent puts there would run again after
  each rebuild.

### Reset the named volumes

A named volume keeps what the agent wrote in it: dependencies, caches, and
the programs in them. `aic rebuild` and `aic destroy` keep the volumes that the
override declares. After a possible compromise, run `aic destroy`, then remove
each volume of the override by name:

```bash
project=$(sed -n 's/^AIC_PROJECT_NAME=//p' .devcontainer/.env)
docker volume rm "${project}_<volume>"   # one name for each volume, for example "${project}_venv"
```

### What needs `aic trust`

| File or entry | Needs `aic trust` |
|---|---|
| `docker-compose.override.yml`: named volumes under `/workspace/` or `/home/vscode/.cache/`, literal environment values | No |
| `docker-compose.override.yml`: the `build:` block for `Dockerfile.project` | Yes |
| `Dockerfile.project` | Yes, through the `build:` block |
| `post-create.project.sh` | Yes |
| `vscode-extensions`, `vscode-settings.json` | Yes, for each entry |
| `chown-paths` | No |
| `firewall-allowlist` | No |
| `firewall-enable`, `firewall-presets` (since Unreleased) | No |

`aic trust` needs a terminal (TTY). Only the user can run it. Trust is for the
exact config: each later edit of a file in this table that needs trust asks
for approval again. So write all files first, run `aic validate`, and then ask
the user to run `aic trust` one time.

## Common files

The stack sections refer to these shared parts.

### Wire `Dockerfile.project`

A stack that has lines under `### Toolchain` needs a `Dockerfile.project`.
Start it with the `FROM` line. Use the tag that
`.devcontainer/docker-compose.yml` pins:

`.devcontainer/Dockerfile.project`:

```dockerfile
FROM ghcr.io/stefanoginella/aicontainer:vX.Y.Z
```

Then add the toolchain lines of each stack below the `FROM` line. Each
toolchain block ends with `USER vscode`.

Point the override at the file. The `image:` line is mandatory: without it,
the build replaces the shared base image on the machine. Use a name that is
special to the project:

`.devcontainer/docker-compose.override.yml`:

```yaml
services:
  devcontainer:
    image: myproject-devcontainer:vX.Y.Z
    build:
      context: .
      dockerfile: Dockerfile.project
```

Keep `context: .`. See
[Installing extra tools](extra-tools.md#install-a-tool-persistently-in-a-project-dockerfile)
for the reasons.

With a `Dockerfile.project`, start the container with `aic rebuild`, not with
`aic up`. `aic up` uses the cached base image and does not build.

### Start `post-create.project.sh`

`.devcontainer/post-create.project.sh`:

```bash
#!/usr/bin/env bash
# Runs as vscode, in /workspace, on every container create.
set -euo pipefail
```

Then add the post-create steps of each stack. Follow these rules:

- **Make sure that the manifest exists before a step uses it.** A new
  repository often has no `package.json` or `pyproject.toml` yet. The steps on
  this page use `if [ -f <manifest> ]`.
- **End each step with `|| echo "[post-create] …"`.** Then one failed step
  does not stop the steps after it. A failed script does not stop the
  container start, but aic logs it.
- **Do not run a Git hook installer unconditionally.** `.git/hooks` is
  read-only in the container, so `lefthook install`, `husky install`, and
  `pre-commit install` fail. The host installs the hooks. The container only
  needs the hook tool on `PATH`. Use this form:

  ```bash
  if ! command -v lefthook >/dev/null 2>&1; then
    echo "[post-create] lefthook is not on PATH; skipped"
  elif [ -w .git/hooks ]; then
    lefthook install || echo "[post-create] lefthook install failed"
  else
    echo "[post-create] .git/hooks is read-only; the host installs the hooks"
  fi
  ```

- **Do not use `npm i -g` for a tool that downloads a binary in an install
  script** (for example lefthook or gitleaks). The container sets
  `NPM_CONFIG_IGNORE_SCRIPTS=true`, so these packages install nothing. Get the
  pinned release binary into `~/.local/bin`, or install the tool in
  `Dockerfile.project`. Language servers that are plain JavaScript (`pyright`,
  `typescript-language-server`, `intelephense`) install correctly with
  `npm i -g`.

### Two LSP surfaces

Most stacks need two language servers:

- The **editor** language server comes from the `vscode-extensions` and
  `vscode-settings.json` lines. It works only in a VS Code Dev Containers
  session.
- The **agent** LSP tool (go-to-definition and find-references in Claude
  Code) needs a language-server binary on `PATH`. The `### Toolchain` or
  `### Post-create` lines of each stack install it.

## Detect a stack

Look for these files in the project root (and in the package directories of a
monorepo). Presence is the signal. One project can have more than one stack.

| Marker files | Section |
|---|---|
| `package.json`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `tsconfig.json`, `.nvmrc`, `.node-version` | [Stack: Node.js](#stack-nodejs) |
| `pyproject.toml`, `uv.lock`, `poetry.lock`, `requirements.txt`, `setup.py`, `.python-version` | [Stack: Python](#stack-python) |
| `go.mod`, `go.work` | [Stack: Go](#stack-go) |
| `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `rust-toolchain` | [Stack: Rust](#stack-rust) |
| `Gemfile`, `Gemfile.lock`, `*.gemspec`, `.ruby-version` | [Stack: Ruby](#stack-ruby) |
| `composer.json`, `composer.lock` | [Stack: PHP](#stack-php) |
| `pom.xml`, `mvnw`, `build.gradle`, `build.gradle.kts`, `settings.gradle`, `gradlew` | [Stack: Java](#stack-java) |
| `CMakeLists.txt`, `meson.build`, `Makefile` with `*.c` or `*.cpp` files, `compile_commands.json` | [Stack: C and C++](#stack-c-and-c) |
| `@playwright/test`, `playwright`, `cypress`, or `puppeteer` in `package.json` | [Playwright recipe](extra-tools.md#recipe-playwright-browser-tests-automation-mcp) |
| Database or cache services in a `docker-compose.yml`, or `DATABASE_URL`-style keys in `.env.example` | [Example override](customization.md#example-override) (host services) |

## Stack: Node.js

### Detect

- `package.json`.
- The lockfile names the package manager: `package-lock.json` (npm),
  `pnpm-lock.yaml` (pnpm), `yarn.lock` (Yarn).
- `tsconfig.json` or `*.ts` files: TypeScript.
- `.nvmrc`, `.node-version`, or `engines.node` in `package.json`: the Node.js
  version.

### Toolchain

None. The image has Node.js LTS and npm (through fnm). The post-create steps
install a pinned Node.js version, pnpm, or Yarn.

### Named volumes and chown-paths

Optional. A named volume over `node_modules` makes installs faster on macOS
and keeps them across rebuilds. The host then does not see the files in
`node_modules`. In a monorepo, add one volume for each `node_modules`
directory.

`.devcontainer/docker-compose.override.yml`:

```yaml
services:
  devcontainer:
    volumes:
      - node-modules:/workspace/node_modules
volumes:
  node-modules:
```

`.devcontainer/chown-paths`:

```
/workspace/node_modules
```

### Post-create

`.devcontainer/post-create.project.sh`:

```bash
# Node.js: install and select the version that .nvmrc or .node-version pins
if [ -f .nvmrc ] || [ -f .node-version ]; then
  eval "$(fnm env --shell bash)"
  fnm use --install-if-missing || echo "[post-create] fnm could not install the pinned Node.js version"
fi
# Node.js: install the dependencies
if [ -f package-lock.json ]; then
  npm ci --no-audit || echo "[post-create] npm ci failed"
elif [ -f pnpm-lock.yaml ]; then
  { command -v pnpm >/dev/null || npm i -g --no-audit pnpm; } && pnpm install --frozen-lockfile || echo "[post-create] pnpm install failed"
elif [ -f yarn.lock ]; then
  { command -v yarn >/dev/null || npm i -g --no-audit yarn; } && yarn install || echo "[post-create] yarn install failed"
elif [ -f package.json ]; then
  npm install --no-audit || echo "[post-create] npm install failed"
fi
# Node.js: the language server for the agent LSP tool
command -v typescript-language-server >/dev/null || npm i -g --no-audit typescript typescript-language-server || echo "[post-create] TypeScript language server install failed"
```

### Editor

`.devcontainer/vscode-extensions`:

```
dbaeumer.vscode-eslint
esbenp.prettier-vscode
```

`.devcontainer/vscode-settings.json`:

```json
{
  "editor.defaultFormatter": "esbenp.prettier-vscode",
  "editor.formatOnSave": true,
  "eslint.format.enable": true
}
```

See [Recipe: TypeScript and JavaScript LSP](customization.md#recipe-typescript-and-javascript-lsp-for-the-editor-and-the-agent).

### Firewall presets

The default allowlist has the npm registry. Add `nodejs` to `firewall-presets`
(since Unreleased) only when the project pins a Node.js version (`.nvmrc` or
`.node-version`): fnm downloads it from `nodejs.org`.

`.devcontainer/firewall-presets`:

```
nodejs
```

### Trust and caveats

- `post-create.project.sh`, `vscode-extensions`, and `vscode-settings.json`
  need `aic trust`. Start with `aic up`.
- npm install scripts do not run (`NPM_CONFIG_IGNORE_SCRIPTS=true`). A
  dependency that builds a native addon in an install script stays unbuilt.
  Do not turn the setting off for all packages. Review the package, then run
  its build one time, for example `npm rebuild <package> --ignore-scripts=false`.
- fnm does not check a checksum when it downloads Node.js. The download uses
  HTTPS from `nodejs.org`.
- Bun is not on this page. Its npm package needs an install script.

## Stack: Python

### Detect

- `pyproject.toml`, `requirements.txt`, or `setup.py`.
- The lockfile names the package manager: `uv.lock` (uv), `poetry.lock`
  (Poetry). Without a lockfile, use uv.
- `.python-version` or `requires-python` in `pyproject.toml`: the Python
  version.

### Toolchain

None. The image has uv and Python 3.13. When the project asks for a different
Python version, `uv sync` downloads it from GitHub.

### Named volumes and chown-paths

Put `.venv` and the uv cache on named volumes. `UV_LINK_MODE: copy` stops a
warning: uv cannot make hard links between two volumes.

`.devcontainer/docker-compose.override.yml`:

```yaml
services:
  devcontainer:
    environment:
      UV_LINK_MODE: copy
    volumes:
      - venv:/workspace/.venv
      - uv-cache:/home/vscode/.cache/uv
volumes:
  venv:
  uv-cache:
```

For Poetry, also add `POETRY_VIRTUALENVS_IN_PROJECT: "true"` under
`environment:`. Poetry then uses `/workspace/.venv`.

`.devcontainer/chown-paths`:

```
/workspace/.venv
/home/vscode/.cache/uv
```

### Post-create

`.devcontainer/post-create.project.sh`:

```bash
# Python: create .venv and install the dependencies
if [ -f poetry.lock ]; then
  { command -v poetry >/dev/null || uv tool install poetry; } && poetry install || echo "[post-create] poetry install failed"
elif [ -f pyproject.toml ]; then
  uv sync || echo "[post-create] uv sync failed"
elif [ -f requirements.txt ]; then
  { uv venv --allow-existing && uv pip install -r requirements.txt; } || echo "[post-create] pip install failed"
fi
# Python: the language server for the agent LSP tool
command -v pyright-langserver >/dev/null || npm i -g --no-audit pyright || echo "[post-create] pyright install failed"
```

Install `pyright`, not `basedpyright`. The Claude Code LSP tool looks for
`pyright-langserver`.

### Editor

`.devcontainer/vscode-extensions`:

```
ms-python.python
ms-python.vscode-pylance
```

Add `charliermarsh.ruff` when the project uses ruff. Add
`ms-python.mypy-type-checker` when the project uses mypy.

`.devcontainer/vscode-settings.json`:

```json
{
  "python.defaultInterpreterPath": "/workspace/.venv/bin/python",
  "python.terminal.activateEnvironment": false,
  "python-envs.terminal.autoActivationType": "off"
}
```

The last two keys stop VS Code from typing `source .venv/bin/activate` into
the terminal of the AI tool. See
[Recipe: Python LSP](customization.md#recipe-python-lsp-for-the-editor-and-the-agent)
and
[Recipe: Stop VS Code from activating a `.venv`](customization.md#recipe-stop-vs-code-from-activating-a-venv-in-the-terminal).

### Firewall presets

None. The default allowlist has PyPI and GitHub.

### Trust and caveats

- `post-create.project.sh`, `vscode-extensions`, and `vscode-settings.json`
  need `aic trust`. Start with `aic up`.
- Pipenv is not on this page.

## Stack: Go

### Detect

- `go.mod` or `go.work`.
- The `go` and `toolchain` lines in `go.mod`: the Go version.

### Toolchain

The image has no Go. Install the official release, pinned by version and
checksum, into the root-owned `/usr/local/go`. Set `GO_VERSION` to the `go`
line of `go.mod` (or newer), and copy both checksums from
[go.dev/dl](https://go.dev/dl/). `GOTOOLCHAIN=local` stops Go from
downloading a different toolchain at runtime. The module and build caches go
under `/home/vscode/.cache/`, so they can be named volumes. The image also
gets `gopls` for the agent LSP tool.

`.devcontainer/Dockerfile.project`:

```dockerfile
USER root
ARG GO_VERSION=1.27.2
ARG GO_SHA256_AMD64=ecbadb99091a3f46e31f5f934b068b1864eafa7995211b39eaddf76996045fe5
ARG GO_SHA256_ARM64=94f3e30b8e374bc285e7dadc11e0865726b9bc6e85b841ccceaabc0214c6b7c8
ARG TARGETARCH
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) sha="$GO_SHA256_AMD64" ;; \
      arm64) sha="$GO_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/go.tgz \
      "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz"; \
    echo "$sha  /tmp/go.tgz" | sha256sum -c -; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz
USER vscode
ENV GOPATH=/home/vscode/go \
    GOMODCACHE=/home/vscode/.cache/go-mod \
    GOCACHE=/home/vscode/.cache/go-build \
    GOTOOLCHAIN=local
ENV PATH="/usr/local/go/bin:/home/vscode/go/bin:$PATH"
RUN go install golang.org/x/tools/gopls@latest
```

### Named volumes and chown-paths

`.devcontainer/docker-compose.override.yml`:

```yaml
services:
  devcontainer:
    volumes:
      - go-mod:/home/vscode/.cache/go-mod
      - go-build:/home/vscode/.cache/go-build
volumes:
  go-mod:
  go-build:
```

`.devcontainer/chown-paths`:

```
/home/vscode/.cache/go-mod
/home/vscode/.cache/go-build
```

### Post-create

`.devcontainer/post-create.project.sh`:

```bash
# Go: download the modules
if [ -f go.mod ]; then
  go mod download || echo "[post-create] go mod download failed"
fi
```

### Editor

`.devcontainer/vscode-extensions`:

```
golang.go
```

No `vscode-settings.json` lines.

### Firewall presets

Add the preset to `firewall-presets` (since Unreleased).

`.devcontainer/firewall-presets`:

```
go
```

A module that the proxy does not have comes from its source host. Add that
host to `firewall-allowlist`.

### Trust and caveats

- `Dockerfile.project`, `post-create.project.sh`, and `vscode-extensions` need
  `aic trust`. Start with `aic rebuild`.
- With the `go` preset, the agent can make `proxy.golang.org` send requests to
  other hosts. See
  [What the allowlist does not stop](network-allowlist.md#what-the-allowlist-does-not-stop).
- Private modules (`GOPRIVATE`) need credentials. Do not forward host
  credentials. Log in inside the container.
- When `go.mod` asks for a newer Go, the build fails with a clear error.
  Increase `GO_VERSION` and the two checksums, then run `aic rebuild`. Do not
  change `GOTOOLCHAIN` to `auto`: Go would then keep downloaded toolchains in
  the `go-mod` volume, which the agent can write.
- The `go-mod` and `go-build` volumes keep their data after `aic rebuild`. See
  [Reset the named volumes](#reset-the-named-volumes).

## Stack: Rust

### Detect

- `Cargo.toml` or `Cargo.lock`.
- `rust-toolchain.toml` or `rust-toolchain`: the Rust toolchain.

### Toolchain

The image has no Rust. Install `rustup` from Ubuntu. Its proxies (`cargo`,
`rustc`, `rust-analyzer`) are in the root-owned `/usr/bin`. `CARGO_HOME` goes
under `/home/vscode/.cache/`, so the crate cache can be a named volume. The
image also gets `rust-analyzer` for the agent LSP tool.

`$CARGO_HOME/bin` is not on `PATH`, on purpose: it is in a volume that the
agent can write. Install a cargo tool in the image instead, for example
`RUN cargo install --locked --root /home/vscode/.local <tool>`.

`.devcontainer/Dockerfile.project`:

```dockerfile
USER root
RUN apt-get update && apt-get install -y --no-install-recommends rustup \
    && rm -rf /var/lib/apt/lists/*
USER vscode
ENV RUSTUP_HOME=/home/vscode/.rustup \
    CARGO_HOME=/home/vscode/.cache/cargo
RUN rustup default stable \
    && rustup component add rust-analyzer clippy rustfmt
```

### Named volumes and chown-paths

`.devcontainer/docker-compose.override.yml`:

```yaml
services:
  devcontainer:
    volumes:
      - cargo-home:/home/vscode/.cache/cargo
      - cargo-target:/workspace/target
volumes:
  cargo-home:
  cargo-target:
```

`.devcontainer/chown-paths`:

```
/home/vscode/.cache/cargo
/workspace/target
```

### Post-create

`.devcontainer/post-create.project.sh`:

```bash
# Rust: download the crates (and the toolchain that rust-toolchain.toml names)
if [ -f Cargo.toml ]; then
  cargo fetch || echo "[post-create] cargo fetch failed"
fi
```

### Editor

`.devcontainer/vscode-extensions`:

```
rust-lang.rust-analyzer
```

No `vscode-settings.json` lines.

### Firewall presets

Add the preset to `firewall-presets` (since Unreleased).

`.devcontainer/firewall-presets`:

```
crates
```

When `rust-toolchain.toml` names a toolchain that the image does not have,
rustup downloads it at runtime. Then add `static.rust-lang.org` to
`firewall-allowlist`.

### Trust and caveats

- `Dockerfile.project`, `post-create.project.sh`, and `vscode-extensions` need
  `aic trust`. Start with `aic rebuild`.
- A toolchain that rustup downloads at runtime is not in the image. It
  downloads again after each `aic rebuild`.
- The `cargo-home` and `cargo-target` volumes keep their data after
  `aic rebuild`. Cargo also looks for `cargo-<name>` subcommands in
  `$CARGO_HOME/bin`. After a possible compromise, see
  [Reset the named volumes](#reset-the-named-volumes).
- A crate that links a system library (for example OpenSSL through
  `openssl-sys`) needs its `-dev` package and `pkg-config`. Add them to the
  `apt-get install` line.

## Stack: Ruby

### Detect

- `Gemfile`, `Gemfile.lock`, or `*.gemspec`.
- `.ruby-version` or a `ruby` line in `Gemfile`: the Ruby version.

### Toolchain

The image has no Ruby. Install Ruby 3.2 and Bundler from Ubuntu. Bundler
installs the gems under `/home/vscode/.cache/`, so they can be a named volume.
The image also gets `ruby-lsp` for the agent LSP tool.

`.devcontainer/Dockerfile.project`:

```dockerfile
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      ruby-full ruby-bundler libyaml-dev \
    && rm -rf /var/lib/apt/lists/* \
    && gem install --no-document ruby-lsp
USER vscode
ENV BUNDLE_PATH=/home/vscode/.cache/bundle
```

### Named volumes and chown-paths

`.devcontainer/docker-compose.override.yml`:

```yaml
services:
  devcontainer:
    volumes:
      - bundle:/home/vscode/.cache/bundle
volumes:
  bundle:
```

`.devcontainer/chown-paths`:

```
/home/vscode/.cache/bundle
```

### Post-create

`.devcontainer/post-create.project.sh`:

```bash
# Ruby: install the gems
if [ -f Gemfile ]; then
  bundle install || echo "[post-create] bundle install failed"
fi
```

### Editor

`.devcontainer/vscode-extensions`:

```
Shopify.ruby-lsp
```

No `vscode-settings.json` lines.

### Firewall presets

Add the preset to `firewall-presets` (since Unreleased).

`.devcontainer/firewall-presets`:

```
rubygems
```

### Trust and caveats

- `Dockerfile.project`, `post-create.project.sh`, and `vscode-extensions` need
  `aic trust`. Start with `aic rebuild`.
- The Ruby version is the Ubuntu version (3.2). A project that needs a
  different version is not on this page.
- With the `rubygems` preset, an agent with its own API key can push a gem.

## Stack: PHP

### Detect

- `composer.json` or `composer.lock`.

### Toolchain

The image has no PHP. Install PHP 8.3, the common extensions, and Composer
from Ubuntu. Add other `php-*` extension packages that `composer.json` asks
for (`ext-*`).

`.devcontainer/Dockerfile.project`:

```dockerfile
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      php-cli php-mbstring php-xml php-curl php-zip composer \
    && rm -rf /var/lib/apt/lists/*
USER vscode
ENV COMPOSER_CACHE_DIR=/home/vscode/.cache/composer
```

### Named volumes and chown-paths

`.devcontainer/docker-compose.override.yml`:

```yaml
services:
  devcontainer:
    volumes:
      - vendor:/workspace/vendor
      - composer-cache:/home/vscode/.cache/composer
volumes:
  vendor:
  composer-cache:
```

`.devcontainer/chown-paths`:

```
/workspace/vendor
/home/vscode/.cache/composer
```

### Post-create

`.devcontainer/post-create.project.sh`:

```bash
# PHP: install the packages
if [ -f composer.json ]; then
  composer install --no-interaction || echo "[post-create] composer install failed"
fi
# PHP: the language server for the agent LSP tool
command -v intelephense >/dev/null || npm i -g --no-audit intelephense || echo "[post-create] intelephense install failed"
```

### Editor

`.devcontainer/vscode-extensions`:

```
bmewburn.vscode-intelephense-client
```

No `vscode-settings.json` lines.

### Firewall presets

Add the preset to `firewall-presets` (since Unreleased).

`.devcontainer/firewall-presets`:

```
packagist
```

Composer downloads most packages from GitHub, which the default allowlist
has. Add other download hosts (for example GitLab) to `firewall-allowlist`.

### Trust and caveats

- `Dockerfile.project`, `post-create.project.sh`, and `vscode-extensions` need
  `aic trust`. Start with `aic rebuild`.
- `composer install` runs the scripts and plugins in `composer.json`. They
  are project code, like the rest of `post-create.project.sh`.

## Stack: Java

### Detect

- Maven: `pom.xml` or `mvnw`.
- Gradle: `build.gradle`, `build.gradle.kts`, `settings.gradle`, or
  `gradlew`.
- The `maven.compiler.release` property, or the Gradle toolchain: the Java
  version.

### Toolchain

The image has no Java. Install JDK 21 and Maven from Ubuntu. Use
`openjdk-17-jdk-headless` instead when the project needs Java 17. For Gradle,
use the `gradlew` wrapper of the project. The Maven repository and the Gradle
home go under `/home/vscode/.cache/`, so they can be named volumes.

`.devcontainer/Dockerfile.project`:

```dockerfile
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      openjdk-21-jdk-headless maven \
    && rm -rf /var/lib/apt/lists/*
USER vscode
ENV GRADLE_USER_HOME=/home/vscode/.cache/gradle
RUN mkdir -p /home/vscode/.m2 \
    && printf '%s\n' '<settings>' \
         '  <localRepository>/home/vscode/.cache/m2/repository</localRepository>' \
         '</settings>' > /home/vscode/.m2/settings.xml
```

### Named volumes and chown-paths

`.devcontainer/docker-compose.override.yml`:

```yaml
services:
  devcontainer:
    volumes:
      - m2:/home/vscode/.cache/m2
      - gradle:/home/vscode/.cache/gradle
volumes:
  m2:
  gradle:
```

`.devcontainer/chown-paths`:

```
/home/vscode/.cache/m2
/home/vscode/.cache/gradle
```

### Post-create

None. Maven and Gradle download the dependencies on the first build.

### Editor

`.devcontainer/vscode-extensions`:

```
redhat.java
```

No `vscode-settings.json` lines. The extension has its own Java language
server.

### Firewall presets

Add the preset to `firewall-presets` (since Unreleased).

`.devcontainer/firewall-presets`:

```
maven
```

For Gradle, add `services.gradle.org` (the wrapper) and `plugins.gradle.org`
(the plugins) to `firewall-allowlist`.

### Trust and caveats

- `Dockerfile.project` and `vscode-extensions` need `aic trust`. Start with
  `aic rebuild`.
- This page has no recipe for `jdtls`, the language server for the agent LSP
  tool.
- Android builds need the Android SDK. They are not on this page.

## Stack: C and C++

### Detect

- `CMakeLists.txt`, `meson.build`, or a `Makefile` with `*.c` or `*.cpp`
  files.
- `compile_commands.json`: the compile flags for the language server.

### Toolchain

The image has `build-essential` (gcc, g++, make). Install `clangd` for the
language server, and `cmake` if the project uses it. Add the `-dev` packages
of the system libraries that the project links.

`.devcontainer/Dockerfile.project`:

```dockerfile
USER root
RUN apt-get update && apt-get install -y --no-install-recommends clangd cmake \
    && rm -rf /var/lib/apt/lists/*
USER vscode
```

### Named volumes and chown-paths

Optional. A named volume over the build directory keeps it across rebuilds.

`.devcontainer/docker-compose.override.yml`:

```yaml
services:
  devcontainer:
    volumes:
      - cpp-build:/workspace/build
volumes:
  cpp-build:
```

`.devcontainer/chown-paths`:

```
/workspace/build
```

### Post-create

`.devcontainer/post-create.project.sh`:

```bash
# C and C++: write compile_commands.json for clangd
if [ -f CMakeLists.txt ]; then
  cmake -S . -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON || echo "[post-create] cmake configure failed"
fi
```

### Editor

`.devcontainer/vscode-extensions`:

```
llvm-vs-code-extensions.vscode-clangd
```

No `vscode-settings.json` lines.

### Firewall presets

None.

### Trust and caveats

- `Dockerfile.project`, `post-create.project.sh`, and `vscode-extensions` need
  `aic trust`. Start with `aic rebuild`.
- clangd finds `build/compile_commands.json` without a setting.

## Combine stacks

Each file exists one time. To combine two or more stacks:

- **`Dockerfile.project`**: write one `FROM` line. Then add the toolchain
  blocks one after the other. Merge the `apt-get install` lines into one when
  you can. Keep each `ENV PATH=` line: each one adds to the `PATH` before it.
- **`docker-compose.override.yml`**: write one `services.devcontainer` key and
  one top-level `volumes:` key. Put all `volumes:` entries in one list and all
  `environment:` entries in one map. Write `image:` and `build:` one time.
- **`chown-paths`, `firewall-presets` (since Unreleased), `vscode-extensions`**: put all lines in
  one file. Remove duplicate lines.
- **`vscode-settings.json`**: merge the objects into one JSON object.
- **`post-create.project.sh`**: write the header one time. Then add the steps
  of each stack.

For example, a Python API with a TypeScript frontend gets the Python and the
Node.js entries in each file. It needs no `Dockerfile.project`.

## Check the fit

aicontainer is a headless Linux container. Check the project before you
generate files.

**These projects fit:**

- Web, API, and backend services on Linux.
- CLIs, libraries, packages, and SDKs.
- Frontend web apps. The build and the tests run headless. The dev server is
  available on a forwarded port.
- Data and ML work on the CPU, notebooks, scripts, ETL.
- Anything that already runs in Linux CI.

**These projects fit with extra files:**

- Browser end-to-end tests: see the
  [Playwright recipe](extra-tools.md#recipe-playwright-browser-tests-automation-mcp).
- Databases and caches on the host: see the
  [example override](customization.md#example-override).
- Native build dependencies, database clients, extra runtimes: add them to
  `Dockerfile.project`.

**These projects do not fit:**

- iOS and macOS apps (Xcode, Swift with AppKit or UIKit, code signing,
  notarization). The toolchain runs only on macOS.
- Windows apps (.NET Framework, WPF, WinForms, MSIX, COM). They need Windows.
- Desktop GUI apps that must show on the host display. There is no X11 or
  Wayland bridge.
- Embedded and firmware work that needs USB, serial, JTAG, or GPIO. The
  container gets no hardware.
- The Android emulator. It needs nested KVM. Building an APK or AAB works.
- GPU and CUDA work. The container has no GPU access.

A project that does not fit often has a part that fits, for example a backend
service. Set up that part, and build the rest on the host.

Other stacks (.NET 5 and later, Elixir, Dart, Swift on Linux) can fit, but this
page has no tested files for them. Use the [common files](#common-files) and
the pattern of the stack sections.

## Apply the files

1. Run `aic init --with <tools> --shell <shell>` (or `aic sync` in a project
   that has aicontainer).
2. If you write a `Dockerfile.project`, read the pinned tag:
   `grep image: .devcontainer/docker-compose.yml`. Use it in the `FROM` line
   and in the override `image:` tag.
3. Write the project-owned files.
4. Run `aic sync`. It connects the override and merges the VS Code files.
5. Run `aic validate`. Fix each finding that this page does not expect.
6. The user runs `aic trust` in a terminal, if `aic validate` asks for it.
7. Run `aic rebuild` with a `Dockerfile.project`, or `aic up` without one.

See [Usage](usage.md) for the commands.
