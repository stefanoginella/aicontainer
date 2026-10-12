# Customize a project

This page explains how to customize the devcontainer of one project with
project-owned files. These files survive `aic sync`.

## Managed files and project-owned files

`aic init` writes `devcontainer.json` and `docker-compose.yml`, and `aic sync`
overwrites them. These two files are **template-managed**. `aic sync` applies
the tool mode, the shell mode, and a Docker mode that you gave consent for
again. It does not keep your manual edits.

> **Note:** `aic` also writes a **`.devcontainer/README.md`** into every
> project. That file shows the same split between managed files and
> project-owned files. Its main purpose is to help an AI agent that looks at
> the devcontainer. The agent then edits the correct files and does not try to
> fight the sync. The agent also learns that it cannot edit
> `devcontainer.json`. That README is template-managed too, so do not edit it.
> Put your customization in the project-owned files on this page.

## Use `docker-compose.override.yml`

Put your changes in a **`.devcontainer/docker-compose.override.yml`** file.
This file is project-owned:

- aic never overwrites it.
- `aic sync` connects it to the devcontainer again automatically.
- aic validates the fully resolved result before each startup command.

### Changes that need no approval

These changes stay frictionless:

- Ordinary environment values.
- Named-volume data mounts under `/workspace` or `/home/vscode/.cache`.
- Extra services that use an image.
- Resource limits.
- `extra_hosts`.

### Changes that need `aic trust`

These changes need an exact-config `aic trust` approval. aic stores the
approval outside the repository.

- Host binds.
- Bounded custom images.
- Project builds on any service.
- Devices.
- Capabilities.
- Namespaces.
- External resources.
- Published ports that are not on loopback.
- `post_start`/`pre_stop` lifecycle hooks.
- A Compose key that the validator does not review. Examples are
  `cgroup_parent`, a network logging driver, or `sysctls` on the devcontainer.

aic also validates services that have a Compose `profiles:` entry.

A build context outside `.devcontainer/` is unbounded. It does not use
`aic trust`. It needs `--allow-unsafe` on each `up` or `rebuild` that you
reviewed.

### Environment values and host variables

Literal application environment values need no approval. These entries need
the same one-time trust, because they send data from the host shell:

- Active Compose `$HOST_VAR` or `${HOST_VAR}` expressions.
- Bare pass-through entries, for example `environment: [HOST_TOKEN]`.

The validation shows the name of the variable. It never shows the resolved
value. Use `$${VAR}` when the container must get the literal template text.

Changes to managed startup variables also need a review. These variables are
`PATH`, the tool homes, Git and shell config, loader variables, and
`DOCKER_HOST`. A change to them can bypass the startup and isolation setup of
the sandbox.

### Example override

Use this file for all items that you would otherwise put in `containerEnv` or
in the compose service. Examples are environment variables, `extra_hosts`,
extra mounts, and ports:

```yaml
# .devcontainer/docker-compose.override.yml
services:
  devcontainer:
    environment:
      # Connect to a development stack that runs on the HOST. Compose
      # environment values have priority over the mounted .env for libraries
      # such as pydantic-settings. So these values apply in the container, and
      # the host continues to use the localhost values from .env.
      DATABASE_URL: postgresql://user:pass@host.docker.internal:5432/mydb
      VALKEY_URL: redis://host.docker.internal:6379/0
    # Docker Desktop (macOS/Windows) resolves host.docker.internal automatically.
    # On a Linux host, add it explicitly:
    # extra_hosts:
    #   - "host.docker.internal:host-gateway"
```

### Apply the override

1. Create the override file.
2. Run `aic sync`.
3. Examine the result with `git diff`.
4. Run `aic rebuild`.

If the validator reports a boundary expansion that you want, review it. Then
run `aic trust`.

> **Warning:** Point `host.docker.internal` only at development data. It is a
> path to your host for the agent too, not only for your code. Without the
> [network allowlist](network-allowlist.md), the agent can connect to every
> service on your host. This includes services bound to `127.0.0.1`, for
> example databases, admin panels, and local model servers.

> **Note:** Use the same file to point at a
> [`Dockerfile.project`](extra-tools.md). Put the `build:` block in the
> override. Do not edit `docker-compose.yml`. Compose merges `build:` onto the
> base service. `aic rebuild` refreshes the base image, and then it builds your
> layer on top of it again.

## Keep a named volume and set its owner

A common override is a **named volume** over a build artifact that you do not
want on the bind-mounted workspace. Examples are a Python `.venv`,
`node_modules`, or a language cache. The volume persists across rebuilds. It
also prevents the slow performance of bind mounts on macOS.

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

### The ownership problem

Docker creates a **new named volume as `root:root`**. `updateRemoteUserUID`
changes the user only *inside* the container. It does not change the UID that
the daemon uses to create the volume. So `vscode` cannot write into the mount,
and your `uv` or `npm` install fails.

You cannot fix this with `sudo chown` from inside the container. In-container
sudo is limited to three aic helper scripts. It does not allow general
`chown`.

### Use `chown-paths`

Use a project-owned **`.devcontainer/chown-paths`** file. This fix is safe
across sync. Write one mountpoint on each line. `aic-chown-volumes` changes
the owner of each mountpoint to `vscode` when the container is created.

```
# .devcontainer/chown-paths — aic gives these paths to vscode on container create.
# aic uses only paths under /workspace/ or /home/vscode/.cache/.
/workspace/.venv
/home/vscode/.cache/uv
```

This file works like `firewall-allowlist`:

- It is opt-in.
- It survives sync.
- It is read-only inside the container.

The privileged helper accepts only canonical, exact Docker named-volume
mountpoints under `/workspace/` or `/home/vscode/.cache/`. It asks the daemon
for the mount metadata of the current container. It uses a socket that only
root can use. It rejects these items:

- Host binds.
- Symlinks.
- Nested binds.
- External or custom drivers.
- `local` volumes with options that can create a bind.

Keep tool caches under `~/.cache/` so that they fit this boundary.

> **Note:** An earlier run possibly created the volume with the root owner.
> `aic-chown-volumes` fixes this on the next `aic rebuild`. If a partial
> install put data into the volume, run `docker volume rm <name>` one time.
> Then let Docker create the volume again from a clean state.

## Add project steps after create

Use this section to run a step on every container creation. Examples are
`lefthook install`, `pre-commit install`, `npm ci`, or data for a local
database. Do not edit these files:

- The `postCreateCommand` in `devcontainer.json`. Each sync overwrites it.
- `post-create.py`. It is in the image. In pull mode, it is not in your
  repository.

Use a **`.devcontainer/post-create.project.sh`** file:

```bash
#!/usr/bin/env bash
# .devcontainer/post-create.project.sh — runs as `vscode`, cwd /workspace,
# after all aic setup, on every container create. Opt-in by presence.
set -euo pipefail
lefthook install
```

The base `post-create.py` runs this script last. At that time, the AI tools,
the Git config, and the volume ownership are ready. So your steps see a fully
configured environment.

The script has these properties. The first three are the same as for
`firewall-allowlist` and `chown-paths`.

- It is opt-in. aic runs it only if it is present.
- `aic sync` never changes it.
- It is read-only inside the container. The
  [PreToolUse hook](security.md) blocks an in-container tool that tries to
  edit a file under `.devcontainer/`. So only the host can edit the script.
- aic starts it with `bash <file>`. It does not need the executable bit.
- It runs as `vscode`.
- A non-zero exit does not stop the container creation. `aic up` logs it as a
  warning. The output of the script shows during `aic up`, so you can see what
  occurred.

> **Warning:** Approve `post-create.project.sh` with `aic trust`. The hook
> runs before any agent prompt, with open network access and the tool logins.
> A cloned repository can supply it. So aic treats it as project code:
>
> - `aic up` asks you to approve the exact file. You can also use
>   `--allow-unsafe` for one run.
> - A direct VS Code start refuses to continue until you run `aic trust`.
> - Each edit of the file asks for approval again.

## Add VS Code extensions and settings for a project

`devcontainer.json` is the only file that installs editor extensions
automatically and applies machine-scope settings. But **`aic init` and
`aic sync` write all of it again each time**. So a manual edit of its
`customizations.vscode` block does not survive. Also, an in-container agent
cannot edit any file under `.devcontainer/`.

aic merges two project-owned files into `devcontainer.json` instead. Both are
opt-in by presence, and sync never changes them:

- **`.devcontainer/vscode-extensions`**: one
  [extension id](https://marketplace.visualstudio.com/) (`publisher.name`) on
  each line. A line that starts with `#` is a comment. Put a comment on its
  own line: aic skips an id line with text after the id. aic merges the ids into
  `customizations.vscode.extensions`. VS Code installs them automatically when
  you reopen the folder in the container.
- **`.devcontainer/vscode-settings.json`**: a strict JSON object. aic parses
  it and serializes it again before the merge. Comments are not permitted.
  aic shows a warning for
  invalid input and skips it. aic ignores keys that aic owns, and shows a
  warning. Put intentional overrides in the `.vscode/settings.json` of the
  repository. Its workspace scope has priority.

```
# .devcontainer/vscode-extensions
ms-python.python
ms-python.vscode-pylance
```

`.devcontainer/vscode-settings.json`:

```json
{
  "python.defaultInterpreterPath": "/workspace/.venv/bin/python"
}
```

### Apply the extensions and settings

1. Run `aic sync` on the host.
2. Approve the result with `aic trust`.
3. Run `aic rebuild`.
4. Make sure that the merge worked:
   `grep ms-python .devcontainer/devcontainer.json`.

An extension runs code in the container. Some settings start programs, for
example interpreter paths or terminal paths. So each extension or setting in
`devcontainer.json` that aic does not own needs `aic trust`. This is also true
when a repository commits the entry directly into `devcontainer.json`. A
changed setting that aic owns is drift, and `aic sync` repairs it.

This check does not cover a committed `.vscode/` folder. See the
[threat model](security.md).

aic shows a warning for an invalid extension line and skips it. An invalid
line is a line that is not a `publisher.name` id. So a stray line cannot put
JSON into `devcontainer.json`.

> **Note:** On a key conflict, the aic value wins inside `devcontainer.json`:
> aic drops your key and shows a warning. Usually you add new
> keys, for example `python.*`, and no conflict occurs. To override a key that
> aic sets, use a standard workspace **`.vscode/settings.json`**. An example
> is a `terminal.integrated.*` value. Workspace settings have priority over
> devcontainer machine-scope settings. They survive sync, and aic does not
> manage them.

### Recipe: Python LSP for the editor and the agent

There are two LSP surfaces:

- The **editor** IntelliSense comes from the extensions and settings below.
- The **agent** LSP tool is separate. It gives go-to-definition and
  find-references in Claude Code. It needs the `pyright-langserver` binary on
  `PATH`. Install it from
  [`post-create.project.sh`](#add-project-steps-after-create), so that it
  survives rebuilds.

```
# .devcontainer/vscode-extensions
ms-python.python
# editor IntelliSense / LSP
ms-python.vscode-pylance
# if the project uses ruff
charliermarsh.ruff
# if mypy is your type gate
ms-python.mypy-type-checker
```

`.devcontainer/vscode-settings.json` (`typeCheckingMode` is `off` because mypy
is the type gate; Pylance is for navigation only):

```json
{
  "python.defaultInterpreterPath": "/workspace/.venv/bin/python",
  "ruff.importStrategy": "fromEnvironment",
  "mypy-type-checker.importStrategy": "fromEnvironment",
  "python.analysis.typeCheckingMode": "off"
}
```

```bash
# .devcontainer/post-create.project.sh — give the agent's LSP tool a Python server
command -v pyright-langserver >/dev/null || npm i -g pyright || echo "[post-create] pyright install failed"
```

> **Note:** Install `pyright`, **not** `basedpyright`. The Claude Code LSP tool
> looks for the `pyright-langserver` binary. The `pyright` package supplies
> this binary. `basedpyright` supplies `basedpyright-langserver`.

### Recipe: Stop VS Code from activating a `.venv` in the terminal

This problem occurs when the Python extension is installed (for example, from
the recipe above) **and** the project has a `.venv`. VS Code then activates
the `.venv` automatically. It *types and runs*
`source /workspace/.venv/bin/activate` in each new integrated terminal.

In this container, you use the terminal mostly to start AI CLIs. So the
injected line goes to the prompt and replaces the command that you start, for
example `claude`, `opencode`, or `codex`.

Disable the activation with these two keys:

- The first key is for the classic `ms-python.python` extension.
- The second key is for the newer **Python Environments** extension. Its
  default `command` mode is usually the cause.

`.devcontainer/vscode-settings.json`:

```json
{
  "python.terminal.activateEnvironment": false,
  "python-envs.terminal.autoActivationType": "off"
}
```

Then run `aic sync` on the host and run `aic rebuild`.

Here, the editor injects the line *and runs it*. This is a different problem
from the Claude Code prompt *pre-fill*. The pre-fill is harmless and never
runs. See [Troubleshooting](troubleshooting.md).

### Recipe: TypeScript and JavaScript LSP for the editor and the agent

VS Code includes the TypeScript language service in the editor. So for the
editor, you add mostly lint and format extensions. The agent LSP tool needs
the `typescript-language-server` binary on `PATH`.

```
# .devcontainer/vscode-extensions
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

```bash
# .devcontainer/post-create.project.sh — give the agent's LSP tool a TS server
command -v typescript-language-server >/dev/null || npm i -g typescript typescript-language-server || echo "[post-create] ts language server install failed"
```

> **Note:** The built-in LSP tool of Claude Code finds the binary on `PATH`.
> On older Claude releases, the tool needs `ENABLE_LSP_TOOL=1`. The baked Node
> toolchain and a global `npm i -g` are sufficient. You do not need to change
> the Dockerfile.
