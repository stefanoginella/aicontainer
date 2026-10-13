# Project-owned override files

Read this page before you change `apply_template()`, `patch_devcontainer_json()`, `scan_project_overrides()`, the override and trust checks in `lib/validate.mjs`, `chown-paths` handling, `post-create.project.sh` handling, or the VS Code merge.

Do not break the auto-wire of these files.

## The shared contract

`apply_template()` overwrites `devcontainer.json` and `docker-compose.yml`
completely on every `init` and `sync`. Only `AIC_TOOLS` and `AIC_SHELL`
survive. `apply_template()` derives them again from the old file, and
`patch_devcontainer_json` injects them again.

Users must not edit those two files by hand. Per-project changes go in the
project-owned files. `apply_template()` never touches these files:

- `Dockerfile.project`
- `firewall-allowlist`
- `firewall-enable`
- `firewall-presets`
- `chown-paths`
- `post-create.project.sh`
- `docker-compose.override.yml`
- `vscode-extensions`
- `vscode-settings.json`
- `shell-rc.zsh`
- `p10k.zsh`
- `statusline.{sh,mjs,js,py}`

All of these files share one contract:

- **Opt-in by file presence.**
- **Survive sync.**
- **Read-only inside the container.**

## `docker-compose.override.yml`

`docker-compose.override.yml` is the sync-safe location for all settings that
would otherwise go in `containerEnv` or in the Compose service. Examples are
environment variables, `extra_hosts`, mounts, and a `build:` block for
`Dockerfile.project`.

The template `devcontainer.json` contains
`"dockerComposeFile": ["docker-compose.yml"]` (one entry).
`patch_devcontainer_json()` adds the override to that array **only when the
file exists**. A guard prevents a second entry, so the operation is
idempotent.

Keep one entry in the template array. If the template lists the override
before the file exists, `devcontainer up` fails on projects without the file.
A missing `dockerComposeFile` entry is a hard error.

## The raw scan is not the security boundary

The override and `Dockerfile.project` come with an untrusted repository. For
this reason, `scan_project_overrides()` prints an early warning for obvious
grants. The warning is easy for a human to read.

The raw scan is deliberately not the security boundary. YAML merges,
interpolation, short and long syntax, aliases, and service replacement make
the raw text incomplete. `validate_project_security()` always runs after the
scan. It fails closed in a TTY and in automation.

Keep the raw scan useful, and keep its test. A new regex or
`AIC_NO_OVERRIDE_SCAN` is never equal to a change in the structural validator.

## Host-shell interpolation

Host-shell interpolation is also a boundary. When an override exists, follow
these rules:

- Validate the merged model with `--no-interpolate`.
- Require exact trust for each active `$VAR` or `${VAR}` expression that is
  not already in the managed base.
- Also find bare environment or build-arg pass-through
  (`environment: [TOKEN]`, or a map value that is null). Without this check, a
  repository can silently forward an exported host token.
- Keep the Compose escape `$${VAR}` and ordinary literal values frictionless.
- A diagnostic can name the variable. It must never print the resolved value.

## Long syntax for the `AIC_DOCKER_SOCKET` mounts

Keep both managed `AIC_DOCKER_SOCKET` mounts in long Compose syntax. Compose
2.38.x supports `--no-interpolate`. But it parses the `:-` default and the
mount separators incorrectly when that expression is in short
`source:target:ro` syntax.

The long form keeps the raw interpolation inspection on the supported Linux CI
runners. It does not change the resolved bind.

## Protected environment keys

The Compose environment has a higher priority than the devcontainer
`containerEnv` and the image `ENV`. A change to one of these keys is a trust
finding:

- the managed keys
- `HOME`
- `PATH`
- shell startup variables
- tool-home and XDG paths
- `GIT_CONFIG_*`
- `LD_*`
- Docker endpoint and Docker config variables

The reasons are:

- These keys can run project code before the metadata hardening.
- They can bypass the root-managed Git and shell startup.
- They can cross project-home boundaries.
- They can avoid the socket proxy.

Keep the protected-key list and the host-security test aligned.

## Project Dockerfile builds

Every project-owned Dockerfile build is unsafe by definition. This is also
true when its final `FROM` is aicontainer. Build steps execute as root. They
can replace helpers, policy, hooks, or the runtime user.

For this reason, a project Dockerfile build requires exact-config trust on any
service, not only on the devcontainer. A check of only the base image is not
sufficient.

### Build tags

The validator refuses a build tag outright when one of these conditions is
true:

- The tag names an image that another managed service runs.
- The tag is any `ghcr.io/stefanoginella/aicontainer` tag.

A build tag is the service `image:`, the `<project>-<service>` default, or
`build.tags`. With `pull_policy: missing`, such a tag would replace the image
of the sanitizer, the credential bridge, or other projects.

## Devcontainer mount targets

Additional mounts on the devcontainer are frictionless only at these targets:

- `/workspace/**`, but not `.git` and not `.devcontainer`
- `/home/vscode/.cache/**`

All other targets are findings. A mount that masks one of these paths is also
a finding: `/run`, `/etc`, `/usr`, `/bin`, `/sbin`, `/lib*`, or `/opt`.

## Normalization is never approval

The validator replaces installation-specific Compose values before it compares
them. Before it does this, it must prove these facts:

- Managed build contexts resolve to `.devcontainer/`.
- Managed project bind sources resolve to this canonical checkout.
- Per-project network and volume names keep the path-hashed Compose name.

These surfaces execute code before post-create. They must fail or require
explicit trust:

- Unmanaged Dev Container features, lifecycle hooks, and environment.
- Changes to the main service command, entrypoint, or healthcheck.
- Compose `post_start` and `pre_stop` hooks on any service.
- Compose `develop.watch` `exec` hooks on any service.

Each Compose hook entry can set its own `user` and `privileged`.

Reserved `devcontainer.*` and `com.docker.compose.*` labels are trust
findings. Dev Containers and the legacy ownership checks read them.

Keep the matching host tests. These checks close real validator bypasses.

## `chown-paths`

`chown-paths` is the companion to named volumes that the override declares.
Docker initializes a new named volume as `root:root`. `updateRemoteUserUID`
does not change that. For example, a `myproject-venv:/workspace/.venv` mount
is not writable by `vscode`.

The project lists such mountpoints, one on each line. On create,
`fix_volume_ownership()` in `post_create_container.py` changes their owner through
`aic-chown-volumes`.

**The prefix allowlist (`/workspace/`, `/home/vscode/.cache/`) is only the
first boundary.** The privileged helper does these checks:

1. It uses a root-hidden raw socket to GET the current container and volume
   metadata.
2. It requires an exact canonical mountpoint. A named volume with the `local`
   driver and no options must back that mountpoint.
3. Before `chown -h -R`, it rejects:
   - host binds
   - nested mounts that are not volumes
   - symlinks
   - custom or external drivers
   - `local type=none,o=bind` aliases

Keep `DAC_READ_SEARCH`. Without it, root cannot recurse through the `0700`
tree of an old UID. `vscode` itself still gets no capabilities.

Guarded by `tests/test-aic-chown-volume-validation.sh` and the workflow
runtime smoke.

## `post-create.project.sh`

`post-create.project.sh` is the project extension point for `post-create.py`.
`run_project_hook()` runs it **last** in `main()`:

- through `bash <file>`
- with the working directory `/workspace`
- as `vscode`

Thus a project `lefthook install` or `npm ci` sees a fully configured
environment.

This file is the only way to extend post-create in pull mode. In pull mode,
`post-create.py` and its `post_create_*.py` modules are baked into the image.
`apply_template()` copies them only in `--build` mode.

The hook runs without privileges. The `.devcontainer/` mount makes sure that
only the host can edit it. But the hook runs before any prompt, with open
egress and the tool logins. So it needs exact `aic trust` (see
[Validation](validation.md)). In a trusted repository, this is one prompt for
each edit.

A non-zero exit is logged, not fatal. Keep that behavior. A project step that
fails sometimes must not stop the devcontainer start.

## `vscode-extensions` and `vscode-settings.json`

These files give sync-safe editor customization for each project.
`apply_template()` writes `customizations.vscode` again completely on every
sync.

`patch_devcontainer_json()` merges the two files at two JSONC marker comments
in `template/devcontainer.json`:

- `// aic:vscode-extensions` in the extensions array
- `// aic:vscode-settings` in the settings object

`build_vscode_ext_block` and `build_vscode_settings_block` write blocks that
start with a comma. Thus the result is valid JSON, independent of how the
template array or object ends. A JSONC trailing comma is tolerated.

### Rules (do not change)

1. **Keep the markers.** They are the injection anchors. If you remove them,
   the merge stops silently.
2. The merge reads the pristine template again on every run. Thus it is
   idempotent across syncs. Do not change it to edit the file in place.
3. The merge validates each extension line against the `publisher.name`
   grammar. It shows a warning and skips a line that does not match. Settings
   must be strict JSON and an object that is not an array. Node parses and
   serializes the settings, so user text never goes directly into JSONC. Keep
   both validations. These files are host-side control input.
4. On a key collision, the aic settings win inside `devcontainer.json`.
   `build_vscode_settings_block()` gets the managed keys from the pristine
   template. It shows a warning and drops each collision before
   serialization. The documented escape hatch is the user
   `.vscode/settings.json`, which has priority over devcontainer machine-scope
   settings. Do not reverse this priority unless you also update the user
   guide and the [Threat model](../user/security.md).
5. **Merged entries need exact trust.** An extension runs code in the
   container, and settings start programs. So the validator reports each
   extension or setting that is not in the template as a trust finding. The
   grammar checks keep the JSON well-formed. They do not make the content
   safe.

Guarded by the "aic sync merges project-owned vscode-extensions /
vscode-settings.json" test and the project-code cases in
`tests/test-aic-host-security.sh`.

## `Dockerfile.project` base-tag drift

`aic sync` pins `docker-compose.yml` again. But it never touches a
`FROM ghcr.io/stefanoginella/aicontainer:vX.Y.Z` line inside the project-owned
`Dockerfile.project`. When the `build:` of an override points at that file,
the old `FROM` is what actually runs. The Compose `image:` pin is then
bypassed.

- `check_dockerfile_project_base()` (at the end of `cmd_sync`) shows a warning
  about the drift.
- `aic sync --bump-base` writes the new tag.

The check acts only on a literal version pin. It deliberately ignores
`:latest`, `ARG`-templated bases, and other repositories.

Keep the split between the warning and the opt-in change. A silent edit of a
project-owned file would break [the shared contract](#the-shared-contract).

Guarded by the "aic sync warns on / bumps a stale Dockerfile.project base"
test.
