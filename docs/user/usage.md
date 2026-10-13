# Use aicontainer in a project

This page shows how to add aicontainer to a project and start the sandbox. It
also explains validation, the diagnostic commands, the tool and shell options,
VS Code, and the Claude Code plugin.

## Start a project

```bash
cd my-project
aic init           # writes a small managed .devcontainer/ that pulls the GHCR image
aic up             # pulls the version-pinned image, validates the config, then starts the sandbox
aic shell          # opens the configured interactive shell (zsh by default)
claude             # runs in bypass mode (permissions skip)
codex              # runs in auto-approve mode (sandbox off)
opencode           # runs with permissions set to allow (guardrail still on)
```

### Pull mode (the default)

`aic init` uses **pull mode** by default. It writes these files:

- `devcontainer.json`
- `docker-compose.yml`
- a managed guide file and a managed ignore file
- a gitignored `.env`

The `.env` file holds the Docker socket to mount, the runtime UID/GID, the
project identity, and the host-owned status-relay mode. `aic initialize`
updates this host-only file automatically. Thus rootless Docker, Docker
Desktop, Colima, and OrbStack need no flags that are special to aicontainer.

The socket to mount is the socket of the selected context. There is one
exception: some daemons run in a VM that cannot mount that host path (Docker
Desktop, Colima, Rancher Desktop, a rootful Lima VM). For these daemons, aic
mounts the `/var/run/docker.sock` of the VM daemon.

`aic up` pulls the prebuilt image from GHCR. This takes approximately 30
seconds on a warm runtime. A build from the start takes several minutes. All
other parts are in the image: the Dockerfile, `post-create.py` and its
`post_create_*.py` modules, the firewall, and the hooks.

### Build mode

Use build mode if you want to control the build. Examples are custom apt
packages, air-gapped environments, and changes to the base image. Run
`aic init --build` instead of `aic init`. This command copies the full template
into `.devcontainer/`: the `Dockerfile`, `post-create.py` and its
`post_create_*.py` modules, the hooks, and the helper scripts. Then `aic up` builds the image locally.

### Other commands

- `aic run CMD ...` runs one command inside the container. It does not open a
  shell.
- `aic down` stops the container. It does not remove the volumes. To continue,
  run `aic up`.

For the full list, run `aic help`.

## Validation and `aic trust`

Each startup that aic starts validates the managed control files. It also
validates the fully resolved Compose model. It does these checks before it
gives the files to Dev Containers. The generated VS Code initializer does the
same checks again before Compose creates anything. A normal generated project
shows no output from these checks.

A project can add one of these items on purpose: a custom image, a host bind,
a device, a capability, or a namespace. If it does:

1. Review the findings.
2. Run `aic trust` one time.

The approval is for the exact config. aic keeps it outside the repository. The
approval expires when the related config changes.

For one reviewed run, use `aic up --allow-unsafe` or
`aic rebuild --allow-unsafe`.

Access to the Docker daemon is a separate opt-in. Use `aic init --docker-read`
or `aic sync --docker-read`, or the related `--docker` form. aic also keeps the
matching consent outside the repository.

### Direct VS Code start: review first

> **Warning:** Do not click **Reopen in Container** on a `.devcontainer/` that
> an unknown repository supplies. Dev Containers must read the
> `devcontainer.json` of the repository and run its host-side
> `initializeCommand` before `aic initialize` can validate it.

Do these steps instead:

1. Run `aic init --force`. For a project that already uses aicontainer, run
   `aic sync`.
2. Examine the diff and the project-owned override files.
3. Use `aic up`, or reopen the project in VS Code.

Some project-owned files run code in the container. These files also need
`aic trust` before any start, so read them during the review:

- `post-create.project.sh`
- `shell-rc.zsh`
- `p10k.zsh`
- `statusline.*`
- VS Code extensions or settings that the project added in
  `devcontainer.json`

aic does not examine the `.vscode/` folder of the repository. Only VS Code
Workspace Trust protects it.

## Diagnostics and review

Three read-only commands let you examine the boundary. They do not start or
change the project:

```bash
aic doctor     # host prerequisites + project wiring, concise OK/WARN/FAIL
aic status     # identity, modes, runtime, credential bridge, and volumes
aic validate   # managed provenance + fully resolved Compose security model
```

Each one also has a JSON form for programs. See
[JSON output](#json-output---json).

### `aic doctor`

You can run `doctor` before `init`. It examines these items:

- Node 18+
- Docker Engine 25+ (it is necessary for volume subpaths)
- Compose 2.35+ (validation needs `config --no-env-resolution`; some distro
  `docker-compose-v2` packages are older)
- the selected local Unix socket
- the Dev Container CLI
- the shape of the Git checkout and the project root
- the integrity of the install
- the safety of the control paths (this includes `.git` and its control files)
- whether a direct start from the editor would use the managed Compose project
  name

A warning gives exit code 0. A blocker gives an exit code that is not zero.

`doctor` finds standard, rootless, Colima, OrbStack, and Docker Desktop
Unix-socket contexts automatically. It reports these cases clearly:

- remote TCP/SSH contexts
- subdirectories below the Git root
- checkouts in the worktree style

Thus you do not get an unclear Compose error later.

`doctor` and `status` also show the Docker runtime that they found. They also
show the socket that the managed mounts use. On macOS, `doctor` gives a warning
when the daemon runs in a VM that aic does not know.

### `aic status`

`status` gives a quick snapshot of facts. This includes the health of the
credential bridge. It also works when the daemon is stopped.

### `aic validate`

You can use `validate` in CI. It never shows a prompt, never records trust, and
never writes `.devcontainer/.env`. It accepts an exact approval that already
exists. It works in every clone of the repository, at any path, with no
`aic sync` first: the committed files hold no path-specific value. It gives an
exit code that is not zero for these problems:

- managed drift (this includes a changed top-level `name:` line in
  `docker-compose.yml`)
- an unsafe `.git` control path
- a `.devcontainer/.env` that Git tracks (in any letter case)
- a top-level `name:` in `docker-compose.override.yml` (the project name is
  managed)
- a boundary expansion that you did not trust
- a `COMPOSE_PROJECT_NAME` (in the root `.env` or in the environment) that a
  direct start would use instead of the managed name
- an `AIC_PROJECT_NAME`, `COMPOSE_ENV_FILES`, or `COMPOSE_DISABLE_ENV_FILE` in
  the environment (each one can replace the project name in
  `.devcontainer/.env`)

### JSON output (`--json`)

To get output that a program can read, add `--json` to `aic doctor`,
`aic status`, `aic validate`, or `aic version`:

```bash
aic doctor --json
aic validate --json
```

- The command does the same checks as without `--json`. The exit code does
  not change.
- stdout holds only one JSON object, on one line. The messages and warnings
  go to stderr. The JSON has no color codes.
- `aic version --json` does the same update check as `aic version`. It uses
  the same 24-hour cache, and `AIC_NO_UPDATE_CHECK` and `CI` stop it.
- A usage error gives no JSON. An unknown flag gives exit code 1 and a message
  on stderr.

Each JSON object has these members:

| Member | Value |
|---|---|
| `schema` | The version of the JSON shape. The value is `1`. Only a change that is not compatible increments it. |
| `command` | `doctor`, `status`, `validate`, or `version`. |
| `ok` | `true` when the exit code is 0, else `false`. |
| `error` | The message that stopped the command, or `null`. A failed check is not an error: a `doctor` blocker gives `"error": null`. In some failures `error` is `null` and only stderr has the message. |

Each command adds these members:

| Command | Members |
|---|---|
| `doctor` | `result` (`ready`, `warnings`, or `blocked`), `warnings` and `failures` (counts), and `checks` (a list of items). |
| `validate` | `findings` (a list of items). |
| `status` | `project`, `mode` (`pull` or `build`), `tools` (a list), `shell`, `docker` (`none`, `ro`, `rw`, or `invalid`), `docker_consent` (`present`, `missing`, or `null`), `relay` (`enabled`, `disabled`, or `invalid`), `relay_applied`, `socket`, `runtime_kind`, `bind_source`, `runtime_uid_gid`, `cli_version`, `image` (`match`, `drift`, `build`, or `unrecognized`), `image_pinned`, `docker_available`, `container`, `container_image`, `auth_bridge`, `auth_volume`, and `sessions_volume`. |
| `version` | `version`, `latest` (the newest version that the update check knows, or `null`), and `update_available`. |

In `status`, a value that aic cannot find is `null`. The Docker states are
lower case. `not-created` and `unavailable` (Docker is not available) replace
the text forms.

An item in `checks` or `findings` has three members: `id`, `level`, and
`message`.

- In `doctor`, `id` is the name of the check, for example `node`,
  `compose-version`, or `git-control-paths`. One check can give more than one
  item. `level` is `ok`, `warn`, or `fail`.
- In `validate`, `id` is the type of the finding. `managed`, `compose`, and
  `name` (a direct-start project name problem) have the level `fail`.
  `unsafe`, `docker`, and `volatile` (a host-access expansion that needs
  trust) have the level `warn`. With an exact approval, `validate` gives exit
  code 0 and still lists the `warn` items.

Example:

```json
{"schema":1,"command":"validate","ok":false,"findings":[{"id":"compose","level":"fail","message":"Docker Compose 2.29.7 is too old; aic needs Compose 2.35+ (run aic doctor)"}],"error":"configuration cannot be validated: upgrade Docker Compose to 2.35+ (see 'aic doctor')"}
```

> **Note:** In a program, use the exit code, `ok`, `id`, and `level`. The
> text of `message` and `error` can change in a new version.

### The project name and teammates

Each checkout gets a path-unique Compose project name. Thus two checkouts never
share containers or session volumes. aic writes the name as `AIC_PROJECT_NAME`
into `.devcontainer/.env`. That file is host state, and Git ignores it. The
committed `docker-compose.yml` has only this fixed line:

```yaml
name: ${AIC_PROJECT_NAME:?run aic up or aic sync}
```

Thus a teammate's `aic sync` in a clone at another path does not change a
committed file. Do not edit that line, and do not commit `.devcontainer/.env`.

A project from an earlier aic version has the path-specific name in that line.
Run `aic sync` one time and commit the result. Until then, `aic up`, the editor
start, and `aic validate` refuse the project.

## Select the tools for a project

By default, `aic init` enables Claude Code, Codex, and OpenCode. To select a
subset, use one of these methods:

- Answer the interactive checkbox prompt. Use ↑/↓ to move, space to toggle,
  and enter to confirm.
- Use `--with`:

```bash
aic init --with claude-code                  # claude only
aic init --with codex                        # codex only
aic init --with opencode                     # opencode only
aic init --with claude-code,codex,opencode   # all three (same as the default)
```

aic keeps the selection as `containerEnv.AIC_TOOLS` in
`.devcontainer/devcontainer.json`. `post-create.py` reads it to decide the
settings to seed for each tool. aic also filters the VS Code extensions list to
match. It removes the `anthropic.claude-code`, `openai.chatgpt`, and
`sst-dev.opencode` extensions when you do not select their tool.

The image always contains all three CLIs. To enable a tool again later, run
`aic sync --with claude-code,codex,opencode`. When stdin is not a TTY (CI,
piped installers), aic does not show the prompt and enables all tools.

## Select the shell for a project

`aic init` also asks for the interactive shell. You can also use `--shell`.
The image contains all three shells:

```bash
aic init --shell zsh                # default: oh-my-zsh + powerlevel10k + MesloLGS NF
aic init --shell bash               # barebones bash, history + fnm
aic init --shell fish               # barebones fish, fnm
```

aic keeps the choice as `containerEnv.AIC_SHELL` in
`.devcontainer/devcontainer.json`. `aic shell` starts that shell. aic also
changes the default profile and the font family of the VS Code terminal to
match:

- zsh keeps `'MesloLGS NF', monospace` for the p10k icons.
- bash and fish use plain `monospace`, so you do not need a nerd font on the
  host.

To change the shell later, run `aic sync --shell bash`. When stdin is not a
TTY, aic does not show the prompt and uses `zsh`.

## Use VS Code

If you use VS Code, you do not need `aic up` and `aic shell` after aic makes
the control files. The editor does both:

1. Install the **Dev Containers** extension
   `ms-vscode-remote.remote-containers`.
2. Run `aic init` in your project (one time).
3. Open the project folder in the editor.
4. Push `Cmd+Shift+P` and select **Dev Containers: Reopen in Container**.

The generated initializer does these steps:

- It does the same host validation and volume migration as `aic up`.
- It sanitizes the host preference seeds in a one-shot service that has no
  network.
- It starts the devcontainer and the socket-proxy.
- It opens an integrated terminal.

`claude`, `codex`, and `opencode` are available immediately.

The initializer needs the host `aic` CLI. It looks in the usual npm and Node
manager paths. These include the nvm, fnm, Volta, asdf, and mise shims. An
editor that you start from the GUI sometimes cannot find the CLI. Then the
initializer shows one install command.

Step 2 is the boundary of the host control plane.

> **Warning:** Do not directly reopen a devcontainer that an untrusted
> repository supplies. First let aic replace it, then review it.

### `COMPOSE_PROJECT_NAME` in the root `.env`

App repositories often have a `.env` in the repository root that sets
`COMPOSE_PROJECT_NAME`. Dev Containers uses that name instead of the
path-unique name of the project. Then the project shares containers and
session volumes with all stacks that have that name. The initializer refuses
that start. Do one of these:

- Remove the line. An app stack can set a top-level `name:` in its own Compose
  file.
- Start from a terminal with `aic up`. It gives the managed name to Dev
  Containers.

The initializer also refuses a `COMPOSE_PROJECT_NAME` that the environment of
the editor exports. For the same reason, it refuses these variables in the
environment of the editor: an `AIC_PROJECT_NAME` that is not the managed name,
`COMPOSE_ENV_FILES`, and `COMPOSE_DISABLE_ENV_FILE`.

### Use `aic` and VS Code together

You can use `aic` from a separate terminal at the same time. `aic rebuild`,
`aic destroy`, and the other commands operate on the same Compose project as
the editor. Thus the two paths do not conflict.

## Claude Code plugin

To connect aicontainer to a project, you add some project-owned files.
Examples:

- an LSP server on `PATH`
- a writable `.venv` volume
- a `Dockerfile.project` for Playwright
- environment variables for host services

See [Customization](customization.md). The
[Stack reference](stack-reference.md) lists the files for each stack.

The optional **aicontainer** Claude Code plugin does this work in a
conversation:

1. It finds your stack.
2. It checks whether a headless Linux devcontainer is applicable.
3. It proposes the files from the [Stack reference](stack-reference.md) and
   writes them for you.

If the `aic` CLI is missing, the plugin offers to install it first. It can
also set up a project again: it audits an existing `.devcontainer/` and updates
only the parts that are missing, old, or drifted. The plugin makes `aic init`
and `aic sync` easier to use. You do not need it.

Install it from inside Claude Code:

```text
/plugin marketplace add stefanoginella/aicontainer
/plugin install aicontainer@aicontainer
```

Then run it from a Claude Code session **on your host**:

```text
/aicontainer:setup
```

> **Note:** Do not run the plugin inside the sandbox. The sandbox mounts
> `.devcontainer/` read-only.

The plugin shows you the plan. It writes the files after you approve. It stops
*before* it pulls the image, which is multiple gigabytes. You run `aic up` (or
"Reopen in Container") yourself.

To uninstall the plugin and remove the marketplace:

```text
/plugin uninstall aicontainer@aicontainer
/plugin marketplace remove aicontainer
```
