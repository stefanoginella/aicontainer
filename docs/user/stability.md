# Stability contract

This page is for tools and scripts that use aicontainer. Examples are a CLI
that runs `aic init` and reads `aic doctor --json`, or a setup assistant that
writes project-owned files in `.devcontainer/`.

The page tells you which items you can use across releases, and which items
can change in any release. An item that this page does not name is not part
of the contract.

`tests/test-aic-stability-contract.mjs` compares this page with the code. When
a command, a flag, a JSON id, or a control file changes, the test fails until
the page changes too.

## Versions and releases

The `aic` CLI and the sandbox image have one version. `aic init` and
`aic sync` pin the image `ghcr.io/stefanoginella/aicontainer:vX.Y.Z` to the
version of the installed CLI. Only a release changes that pin. See
[Updating](updating.md).

The version is 0.x. While the version is 0.x, these rules apply:

- **Patch release** (for example 0.11.0 to 0.11.1): fixes, security fixes,
  refreshed tools and base images, and documentation. A patch release does
  not remove or rename a stable item on this page.
- **Minor release** (for example 0.11.0 to 0.12.0): new commands, flags,
  files, JSON members, and ids. A minor release can also include a breaking
  change to a stable item. Earlier breaking changes came in minor releases
  (0.5.0, 0.6.0, 0.11.0).
- **Security fixes**: a security fix can make validation stricter in any
  release. Then a configuration that passed before can give a finding.

### How a breaking change is announced

- The [CHANGELOG](../../CHANGELOG.md) has one bullet for each breaking change,
  under `### Changed`. A breaking security fix can be under `### Security`.
- The bold headline of the bullet starts with `Breaking:`.
- The bullet tells you the step to do, for example "Run `aic sync` one time
  and commit the result."
- This page changes in the same release.

### Deprecation

0.x has no fixed deprecation period. A stable item can change in the next
minor release. When aic keeps an old form working for a time (for example, a
legacy file that `aic sync` migrates), the CHANGELOG bullet says so.

### Version 1.0

aicontainer goes to 1.0 when the set of control files in `.devcontainer/` is
stable. There is no date. After 1.0, a breaking change to a stable item needs
a major release.

## Commands and flags

[`lib/cli-spec.mjs`](../../lib/cli-spec.mjs) is the one table of commands and
flags. `aic help` and the shell completions come from the same set.

### Stable commands

These commands and flags are stable:

| Command | Stable flags and arguments |
|---|---|
| `aic init` | `--build`, `--force`, `--docker-read`, `--docker`, `--no-docker`, `--with <tools>`, `--shell <shell>` |
| `aic sync` | `--pull`, `--build`, `--bump-base`, `--docker-read`, `--docker`, `--no-docker`, `--with <tools>`, `--shell <shell>` |
| `aic doctor` | `--json` |
| `aic status` | `--json` |
| `aic validate` | `--json` |
| `aic up` | `--allow-unsafe`; after `--`: `--log-level <level>`, `--log-format <format>`, `--terminal-columns <n>`, `--terminal-rows <n>` |
| `aic trust` | `--revoke` |
| `aic preflight` | none |
| `aic signing` | `auto`, `byok`, `disable`, `status`, `--register` |
| `aic shell` | none |
| `aic run` | `[--] CMD [ARGS...]`: the command to run in the container |
| `aic rebuild` | `--allow-unsafe`; after `--`: `--log-level <level>`, `--log-format <format>`, `--terminal-columns <n>`, `--terminal-rows <n>` |
| `aic down` | none |
| `aic destroy` | `--yes`, `-y` |
| `aic upgrade` | none |
| `aic completion` | `bash`, `zsh`, `fish` |
| `aic version`, `aic -v`, `aic --version` | `--json` |
| `aic help`, `aic -h`, `aic --help` | none |

- `<tools>` is a comma-separated list of `claude-code`, `codex`, and
  `opencode`.
- `<shell>` is `zsh`, `bash`, or `fish`.
- After `--`, `aic up` and `aic rebuild` give only these options to
  `devcontainer up`. `<level>` is `info`, `debug`, or `trace`. `<format>` is
  `text` or `json`. `<n>` is a number from 1 to 999.

What each command does is in [Usage](usage.md) and in `aic help`.

Rules for a program:

- Give `--with` and `--shell` to `aic init`. Then aic shows no prompt. When
  stdin is not a terminal, aic shows no prompt and uses all tools and `zsh`.
- Give `--yes` to `aic destroy`. Without it, `aic destroy` asks for
  confirmation. When stdin is not a terminal, it removes nothing and gives
  exit code 1 (a refused confirmation).
- `aic trust` needs a person at a terminal. A program cannot approve a
  configuration. This is part of the security boundary.
- Each command refuses an argument that the table does not name, with exit
  code 2.
- After `--`, `aic up` and `aic rebuild` refuse every other `devcontainer up`
  option with exit code 1. Such an option can change the mounts, the
  configuration, the environment, or the container, or skip post-create.
- In `aic run`, the command comes first. A command that starts with `-` is a
  usage error, so an argument cannot set an option of `devcontainer exec`.

### Internal commands

Do not run these commands. They can change or go away in any release:

| Command | Who runs it |
|---|---|
| `aic initialize` | The `initializeCommand` of the generated `devcontainer.json`, before each start. |
| `aic check-drift` | The `initializeCommand` of old templates. It always exits 0, so that it never stops a start. |
| `aic __supports` | The capability probe of the generated `initializeCommand`. It exits 0 for a known capability, else 1. |

## Exit codes

| Result | Exit code | When |
|---|---|---|
| Pass | 0 | The command did its work. |
| Warning | 0 | `aic doctor` found warnings and no blockers (`"result": "warnings"`). `aic validate` found `warn` findings that an exact `aic trust` approval covers. |
| Blocker | 1 | `aic doctor` found a blocker (`"result": "blocked"`). `aic validate` found a `fail` finding, or a `warn` finding with no approval. Another command refused to continue. |
| Usage error | 2 | An unknown command, an unknown flag, an argument that the command does not take, or a missing or bad value. |

- aic finds a usage error before it reads or changes anything. A usage error
  gives no JSON on stdout, also with `--json`.
- A security refusal is never a usage error. For example, a refused option
  after `--` in `aic up` gives 1.
- When `devcontainer up` or `docker compose down` fails, `aic up`,
  `aic rebuild`, `aic down`, and `aic destroy` give 1.
- `aic run` gives the exit code of the command in the container, and
  `aic shell` gives the exit code of the shell. There, 2 can come from the
  command.
- Ctrl-C at an interactive prompt gives 130.
- In a program, treat 0 as success and any other code as failure.

## JSON output

`aic doctor`, `aic status`, `aic validate`, and `aic version` take `--json`.
[Usage](usage.md#json-output---json) tells what each member means. This
section tells what is stable.

### The schema rule

- Each object has `"schema": 1`. The value is the version of the JSON shape.
- aic increments `schema` only for a change that is not compatible: a removed
  or renamed member, a changed type, a changed meaning, or a removed id.
- An additive change does not increment `schema`: a new member, a new id, or
  a new value of a member (for example a new `image` state in `status`).
- Ignore members that you do not know. Accept ids and values that you do not
  know.
- The text of `message` and `error` is not stable. Use the exit code, `ok`,
  `id`, and `level`.
- The order of the items is not stable. One id can give more than one item.

### Members

Each object has `schema`, `command`, `ok`, and `error`. Each command adds
these members:

| Command | Members |
|---|---|
| `doctor` | `warnings`, `failures`, `result`, `checks` |
| `status` | `project`, `mode`, `tools`, `shell`, `docker`, `docker_consent`, `relay`, `relay_applied`, `socket`, `runtime_kind`, `bind_source`, `runtime_uid_gid`, `cli_version`, `image`, `image_pinned`, `docker_available`, `container`, `container_image`, `auth_bridge`, `auth_volume`, `sessions_volume` |
| `validate` | `findings` |
| `version` | `version`, `latest`, `update_available` |

An item in `checks` or `findings` has three members: `id`, `level`, and
`message`. `level` is `ok`, `warn`, or `fail`.

### Doctor check ids

| Id | What it checks |
|---|---|
| `node` | Node.js 18 or later on the host |
| `docker-cli` | The Docker CLI is installed |
| `docker-daemon` | The daemon of the selected context answers |
| `docker-engine` | Docker Engine 25 or later |
| `docker-socket` | The selected context uses a local Unix socket |
| `docker-runtime` | The runtime (Docker Desktop, OrbStack, Colima, …) and the socket that the managed mounts use |
| `compose-version` | Docker Compose 2.35 or later |
| `compose-flags` | Compose accepts `config --no-env-resolution --no-interpolate` |
| `compose-subpath` | Compose accepts `volume.subpath` |
| `devcontainer-cli` | The Dev Container CLI is installed |
| `git` | Git is installed |
| `git-root` | The current directory is the Git project root |
| `git-control-paths` | The `.git` control paths are real files and directories |
| `git-hooks` | Host Git hooks and hook programs are outside the worktree (`warn` only) |
| `install` | The aic install is complete |
| `project` | The directory has a `.devcontainer/` |
| `control-paths` | The managed paths in `.devcontainer/` are safe and complete |
| `runtime-env` | `.devcontainer/.env` matches the Docker context and the relay mode |
| `env-tracked` | Git does not track `.devcontainer/.env` |
| `project-identity` | The managed Compose project name is correct for this path |
| `devcontainer-name` | A direct Dev Containers start uses the managed project name |

### Validate finding ids

| Id | Level | What it means |
|---|---|---|
| `managed` | `fail` | A managed file or path changed, or the host state is wrong. Run `aic sync`, then review the diff. |
| `compose` | `fail` | Docker Compose cannot validate the project (for example, it is too old). |
| `name` | `fail` | A direct Dev Containers start would use another project name. |
| `unsafe` | `warn` | The configuration asks for more host access or runs project code. It needs `aic trust`. |
| `docker` | `warn` | The Docker access mode needs host consent that is not there. |
| `volatile` | `warn` | An expansion that a stored approval cannot cover, for example a build context outside `.devcontainer/`. It needs `--allow-unsafe` on each run. |

## Files in `.devcontainer/`

The split between managed and project-owned files is in the
[template README](../../template/README.md), which `aic init` also writes into
each project.

### Project-owned files

A tool can create and edit these files. aic never writes them. Each file is
optional: aic reads it only when it is there.

| File | Format | Guide |
|---|---|---|
| `Dockerfile.project` | A Dockerfile. Its last `FROM` is `ghcr.io/stefanoginella/aicontainer:vX.Y.Z`. A `build:` in `docker-compose.override.yml` uses it. | [Installing extra tools](extra-tools.md) |
| `docker-compose.override.yml` | A Compose file for the `devcontainer` service. It must not set a top-level `name:`. | [Customization](customization.md) |
| `firewall-allowlist` | One host name on each line. `#` comments. | [Network allowlist](network-allowlist.md) |
| `firewall-enable` | An empty marker. aic reads only its presence. | [Network allowlist](network-allowlist.md) |
| `firewall-presets` | One preset name on each line. `#` comments. | [Network allowlist](network-allowlist.md) |
| `chown-paths` | One mountpoint on each line, under `/workspace/` or `/home/vscode/.cache/`. `#` comments. | [Customization](customization.md) |
| `post-create.project.sh` | A bash script. It runs last on each container create, as `vscode`, in `/workspace`. | [Customization](customization.md) |
| `vscode-extensions` | One `publisher.name` id on each line. `#` comments on their own line. | [Customization](customization.md) |
| `vscode-settings.json` | One strict JSON object. No comments. | [Customization](customization.md) |
| `shell-rc.zsh` | A zsh script. | [Personal config](personal-config.md) |
| `p10k.zsh` | The output of `p10k configure`. | [Personal config](personal-config.md) |
| `statusline.{sh,mjs,js,py}` | One Claude Code statusline script. | [Personal config](personal-config.md) |

The [Stack reference](stack-reference.md) has copy-ready content for each
stack. Its structure is also a contract for tools.

Rules for a tool that writes these files:

- Write them on the host. Inside the container, `.devcontainer/` is
  read-only.
- After a change, run `aic sync`, then `aic validate`. `aic sync` connects
  `docker-compose.override.yml` and merges the two VS Code files. Then the
  user runs `aic rebuild`.
- Some content needs `aic trust` before the next start: files that run code
  in the container, a `build:`, and host access. See
  [Validation and `aic trust`](usage.md#validation-and-aic-trust).

### Managed files

Do not create, edit, or delete these files. `aic init` and `aic sync` write
them again:

- `devcontainer.json`
- `docker-compose.yml`
- `.gitignore`
- `.env` (host state: do not read it, edit it, or commit it)
- `README.md`
- in build mode only: `Dockerfile`, `post-create.py`, `post_create_*.py`,
  `hooks/`, `aic-firewall`, `aic-chown-volumes`, `aic-lock-user-config`, and
  `.zshrc`

The content of the managed files is not stable. To read the tools, the shell,
the mode, or the image pin of a project, use `aic status --json`.

## Paths inside the container

| Path | What you can rely on |
|---|---|
| `/etc/aic/` | A root-owned directory in every aicontainer image. Use it to find out that a process runs in the sandbox. The files in it are internal. |
| `/workspace` | The project checkout. |
| `/workspace/.devcontainer/` | The `.devcontainer/` of the project, mounted read-only. |

Other paths in the image can change in any release.

## Environment variables

These variables are a public interface:

| Variable | Where | Effect |
|---|---|---|
| `AIC_HOME` | host | The directory of the aicontainer files. The default is the directory of the `aic` script. |
| `AIC_NO_UPDATE_CHECK` | host | Set it to stop the drift warning and the update check. |
| `AIC_NO_OVERRIDE_SCAN` | host | Set it to stop the early text scan of the override files. Validation still runs. |
| `CI` | host | Set it to stop the update check. |
| `AIC_TOOLS` | container | The selected tools, for example `claude-code,codex`. Read it only. |
| `AIC_SHELL` | container | The selected shell. Read it only. |
| `AIC_FREEZE_TOOLS` | container | Set it to `1` in `docker-compose.override.yml` to keep the AI-tool versions of the image. See [Updating](updating.md). |

All other `AIC_*` variables are internal. Examples are `AIC_PROJECT_NAME`,
`AIC_DOCKER_SOCKET`, `AIC_RUNTIME_USER`, and `AIC_STATUS_*`. Do not set them.
aic refuses some of them in the environment.

## Not part of the contract

These items can change in any release:

- the text output of each command, and the text of `message` and `error`
- the internal commands
- the content of the managed files and of `.devcontainer/.env`
- the tools, packages, and versions in the image, and the default network
  allowlist
- the Compose service names other than `devcontainer`, and the volume names
- the host state that aic keeps outside the repository (trust approvals,
  Docker consent, caches)
