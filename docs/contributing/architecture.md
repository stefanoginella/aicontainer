# Repository layout

Read this page before you add, move, or remove a top-level file or directory, or a file in `template/`.

This page tells you what each part of the repository does. The guidance is for
AI coding agents and for humans who work **on** aicontainer itself. Users who
run aicontainer in their projects start at the [user guide](../user/install.md).

Convention: "Guarded by the '…' test" names a CLI test or a smoke test in
`.github/workflows/smoke.yml`. When you change the behavior, extend the test.
Do not weaken the test.

## The `aic` CLI

`aic` is the host-side bash CLI. The `aic` file is the entry script. The
code of the commands is in the bash modules in `lib/aic/`.

- npm exposes it as the bins `aic` and `aicontainer`.
- Git installs expose it as `~/.aicontainer/aic`.
- It finds its template, its modules, and `lib/` through `$AIC_HOME`. The
  default is the directory of the script, after `aic` follows symlinks. Thus
  a symlink to `aic` (npm, `install.sh`, the VS Code initializer lookup)
  still finds the modules.
- The `aic` file keeps only these items:
  - `set -euo pipefail` and the `$AIC_HOME` resolution,
  - the globals that must overwrite a value from the environment (the
    bind-source cache of `export_runtime_environment()`, the JSON mode
    `aic_json_dir`, and `aic_update_latest`),
  - `err()`, `die()`, and `aic_helper()`,
  - the module load list,
  - the `case "${1:-help}"` dispatcher at the end. `tests/test-aic-cli-spec.mjs`
    reads the dispatcher from the `aic` file.

## `lib/aic/`

`lib/aic/` holds the bash modules of the CLI. `aic` sources them. Each module
holds one concern. A module only defines functions and constants: it has no
other top-level command.

The rules for the load list in `aic`:

- The list is explicit and ordered. Never load the modules with a glob. A
  glob would also source a file that somebody planted in `lib/aic/`.
- A missing or unreadable module fails closed before the command starts. The
  message names the file:
  `incomplete aicontainer install: lib/aic/<name>.sh is missing in $AIC_HOME`.
- When you add a module, add it to the list. `tests/test-aic-package.sh`
  fails when the files in `lib/aic/` and the list differ, or when the
  package does not have a listed module.
- Keep the modules compatible with macOS `/bin/bash` 3.2 and with bash 5.

The modules, in load order:

| Module | Contents |
|---|---|
| `json.sh` | The `--json` output of `doctor`, `status`, `validate`, and `version`: the bash JSON string encoder and `json_run()`. See [Validation](validation.md#json-output). |
| `runtime.sh` | The Dev Containers CLI lookup, the Docker context socket, the runtime kind and bind source, the runtime user, the status relay marker, and the managed `.devcontainer/.env`. See [Host state](host-state.md). |
| `identity.sh` | The path-unique Compose project name, `canonical_root()`, the `.devcontainer/` control-path checks, and the `.git` control paths. See [Project identity](project-identity.md). |
| `selection.sh` | The tool and shell selection: the known values, the checks, the prompts, and the reads from `devcontainer.json`. |
| `versions.sh` | The `aic` version, the version comparison, the drift warning, and the update check. See [Version drift](version-drift.md). |
| `template.sh` | The Docker exposure toggles, the `devcontainer.json` patch (tools, shell, VS Code merge), the atomic copies, `apply_template()`, and the trusted Compose template path. See [Project-owned overrides](project-overrides.md). |
| `init-sync.sh` | `aic init`, `aic sync`, and the `Dockerfile.project` base check. |
| `validation.sh` | The pre-Docker gate (`validate_project_security()`), the exact-trust store, Docker consent, the early override scan, and `aic trust`. See [Validation](validation.md). |
| `status.sh` | `aic status`, and the trust-boundary summary of `aic up` and `aic preflight`. |
| `signing.sh` | `aic signing`. See [Host seeds, tool homes, and reusable auth](seeds-and-auth.md). |
| `volumes.sh` | The managed-volume checks, the legacy session-volume migration, the host seed paths, the volume bootstrap, and the stop of an owned legacy stack. |
| `lifecycle.sh` | `up`, `preflight`, `check-drift`, `__supports`, `initialize`, `rebuild`, `shell`, `run`, `down`, `destroy`, `validate`, `upgrade`, and `version`. |
| `doctor.sh` | `aic doctor`. |
| `help.sh` | `aic help` and `aic completion`. |

## `lib/`

`lib/` holds the host-side Node modules that `aic` runs, and the bash
modules in `lib/aic/` (see above). The npm package ships them. The Node
modules use only `node:` built-ins and have no dependencies.

- `validate.mjs` is the structural validator (`analyzeResolvedConfig()`). It
  takes file contents and returns findings.
  - `tests/test-aic-validate.mjs` unit-tests it without Docker. The test uses
    the JSON fixtures in `tests/fixtures/validate/`.
  - After a change to `template/devcontainer.json` or to a Compose template,
    run `tests/fixtures/validate/regenerate.sh` and review the diff.
  - The unit tests read the live template `devcontainer.json`. Thus a stale
    fixture fails there first.
- `validate-cli.mjs` is the entry point that `analyze_resolved_config()` runs.
  - It exits non-zero when it cannot run.
  - `aic` turns that exit status into a MANAGED finding.
  - An empty output must never read as "no findings".
- `cli.mjs` is the entry point for the other helpers. `aic` runs
  `node "$AIC_HOME/lib/cli.mjs" <subcommand> args...`.
  - Each subcommand keeps the stdout, stderr, and exit status of the `aic`
    function that calls it.
  - An unknown subcommand or a wrong argument count exits 2. Thus a helper
    that does not run never reads as a pass.
  - `aic` calls it only through `aic_helper()`. When `cli.mjs` or a module
    that it imports is missing, `aic_helper()` names the missing file and
    returns non-zero.
- The helper modules:
  - `project-identity.mjs`: the `COMPOSE_PROJECT_NAME` conflict check for a
    direct Dev Containers start, and the creation of the `.git` control
    files. See [Project identity](project-identity.md).
  - `trust-hash.mjs`: the exact-trust hash of the resolved Compose model and
    the `.devcontainer/` tree. See [Validation](validation.md).
  - `docker-inspect.mjs`: the managed-volume check and the ownership proofs
    of the legacy migration, on `docker inspect` JSON.
  - `vscode-settings.mjs`: the injected block of project-owned VS Code
    settings. See [Project-owned overrides](project-overrides.md).
- `tests/test-aic-host-helpers.mjs` unit-tests the helper modules and
  `cli.mjs` without Docker.
- `cli-spec.mjs` holds the one table of `aic` commands (`COMMANDS`). Each
  command has a description, its flags, its positional choices, and its
  dispatcher aliases. Internal commands (`check-drift`, `initialize`,
  `__supports`) are marked `internal`. They are not in help or completions.
  - `aic completion <shell>` runs `node lib/cli-spec.mjs completion <shell>`.
    The bash, zsh, and fish scripts come only from the table. To change a
    completion, change the table.
  - `passthrough` lists the `devcontainer up` options that `aic up` and
    `aic rebuild` pass after `--`. It must equal `AIC_UP_PASSTHROUGH` in
    `lib/aic/lifecycle.sh`. See [Security review](security-review.md).
  - `aic help` is hand-written prose. `tests/test-aic-cli-spec.mjs` checks
    that the help, the `case "${1:-help}"` dispatcher at the end of `aic`,
    and the table name the same commands and flags. When you add a command
    or a flag, change all three.
  - Users run `eval "$(aic completion zsh)"` at each shell start. Keep the
    module free of I/O other than stdout, and keep update checks out of
    `cmd_completion`.

> **Warning:** Do not change the output of `trust-hash.mjs`. Stored approvals
> hold its digest, so a different digest makes every user trust the project
> again. The fixed-digest case in `tests/test-aic-host-helpers.mjs` guards it.

## `template/`

`aic init` and `aic sync` copy `template/` into the `.devcontainer/` of a
project. It is the source of truth for what lands in user repositories.

- `Dockerfile`, `post-create.py`, the `post_create_*.py` modules, `hooks/`,
  `aic-firewall`, `aic-chown-volumes`, `aic-lock-user-config`, `.zshrc`,
  `gitignore`.
- `post-create.py` and the `post_create_*.py` modules hold the container
  setup, the seed sanitizer, and the credential bridge. See
  [The post-create package](#the-post-create-package).
- `hooks/` holds four files. The image copies all four root-owned to
  `/etc/aic/hooks/`:
  - `pre-tool-use.sh`, the shared guardrail.
  - `opencode-guardrail.js`, the thin OpenCode adapter.
  - `agent-status.py`, the opt-in, metadata-only Claude/Codex lifecycle relay.
  - `claude-settings.json`, the base of the Claude managed settings.
- `AIC_HOOK_FILES` in `lib/aic/identity.sh` is the only list of these files.
  - `aic` copies only the listed files from `template/hooks/`. A stray file
    there, such as a `__pycache__` from a test run, never reaches a project.
  - In build mode, `.devcontainer/hooks/` must hold exactly the listed files.
    Any other entry is a MANAGED finding.
  - The Dockerfile `COPY` names each file. `tests/test-aic-hook-files.py`
    fails when the list, the `COPY`, and the files in `template/hooks/`
    disagree.
- `docker-compose.pull.yml` is for the default mode.
  `docker-compose.build.yml` is for the `--build` mode.
- `README.md` is copied into the `.devcontainer/` of every project in **both**
  modes. It is a managed guide to the split between do-not-edit files and
  project-owned files. Keep its two lists in sync with `apply_template()` and
  with the project-owned files.
- `gitignore` is copied in both modes as `.devcontainer/.gitignore`. It
  contains only `.env`.
  - The name has no dot on purpose. npm 12 leaves a `.gitignore` out of the
    package, also when `files` names it. A missing managed template file makes
    every `aic init`/`aic sync` fail.
  - `tests/test-aic-package.sh` packs the repository and runs `aic init`/`aic
    sync` from the tarball. It fails on a missing template file.
- `.env` itself is not in `template/`. `aic` generates it atomically for each
  host or context. It holds:
  - the socket,
  - the runtime user,
  - the path-free project identity,
  - the host-owned status relay mode.

  `.env` is a managed control file. It is not a template asset and not a
  project-owned override.

> **Warning:** Do not put a file that npm drops (`.gitignore`, `.npmignore`,
> `.npmrc`, …) in `template/`. npm leaves it out of the package, and every
> `aic init`/`aic sync` then fails.

### The post-create package

`post-create.py` is the fixed entry point. `devcontainer.json` and both
Compose files run `/usr/bin/python3 -I /opt/post-create.py` with one of these
arguments:

- no argument: the post-create steps, as `vscode`,
- `sanitize-seeds`: the seed sanitizer, as root,
- `auth-sync`: the credential bridge, as the runtime user.

The code is in the `aic_post_create` package, with one module for each
concern:

| Module | Contents |
|---|---|
| `post_create_common.py` | The shared paths, the tool selection (`ENABLED_TOOLS`), `log()`, and the safe file helpers (`_safe_write_text()`, `_replace_managed_file()`, `_remove_tree_at()`, …). |
| `post_create_claude_reset.py` | `reset_claude_rules()` and `reset_claude_state()`. |
| `post_create_tools.py` | `setup_claude()`, `setup_codex()`, `setup_opencode()`, `setup_cli_homes()`, and `refresh_ai_tools()`. |
| `post_create_seeds.py` | The seed sanitizer (`sanitize_seeds()`) and its allowlists. |
| `post_create_auth_logins.py` | The gh and npm login-entry grammars (`_canonical_login()`). |
| `post_create_auth_sync.py` | The credential bridge (`auth_sync_main()`). |
| `post_create_container.py` | `fix_volume_ownership()`, `block_metadata()`, `verify_socket_proxy()`, and `run_project_hook()`. |
| `post_create_git.py` | `setup_gitconfig()`, `setup_commit_signing()`, `lock_config()`, and `verify_git_identity()`. |
| `post_create_overlays.py` | The personal overlay: `setup_personal_shell()`, `setup_statusline()`, and `apply_statusline()`. |
| `post_create_main.py` | `main()`: the post-create steps in their fixed order. |

#### Rules (do not change)

1. **One list.** `AIC_POST_CREATE_MODULES` in `lib/aic/identity.sh` is the
   only list of the modules in `aic`. The control-path checks
   (`AIC_CONTROL_FILES`), `apply_template()`, and the build-file provenance
   check read it. The `COPY` in `template/Dockerfile` names the same files.
2. **Flat in `.devcontainer/`.** The modules are managed build-mode files
   next to `post-create.py`, not a subdirectory. Thus the per-name symlink and
   real-file checks of the control boundary cover each module.
3. **An explicit `COPY`, never a glob or a directory.** The image installs
   only the listed files in `/opt/aic-post-create/aic_post_create/`, plus an
   empty `__init__.py` that the build creates. Thus a file that somebody plants
   in `.devcontainer/` cannot get into the import directory.
4. **Root-owned and read-only.** The build makes `/opt/aic-post-create` and
   everything in it `root:root`: directories `0555`, files `0444`. The parent
   directory holds only the package.
5. **One import path.** `-I` keeps the script directory and the working
   directory off `sys.path`. The entry appends `/opt/aic-post-create` to
   `sys.path`, so a module there cannot shadow the standard library. Before
   the package runs, `find_spec()` must resolve `aic_post_create` to that
   directory. Otherwise the entry exits 1.
6. **No bytecode.** The entry sets `sys.dont_write_bytecode = True` before it
   imports the package. `-I` ignores `PYTHONDONTWRITEBYTECODE`, and the
   sanitizer runs as root.
7. **Relative imports, standard library only.** A module imports another
   module with `from .post_create_<name> import <name>`. The only other
   dependency is `tomli_w` from `/opt/aic-python`, which `setup_codex()`
   imports when it runs.
8. **Patch a name where it is read.** Each module imports the shared
   constants by name. Thus a test patches a name on the module whose function
   reads it. Example: patch `CLAUDE_HOME` on `post_create_tools` for
   `setup_claude()`, and on `post_create_overlays` for `apply_statusline()`.
   No code changes a module global at run time.

To add a module, add the file to `template/`, to `AIC_POST_CREATE_MODULES`,
and to the Dockerfile `COPY` in the same commit. An existing build-mode
project gets the new file with `aic sync`.

Guarded by `tests/test-aic-post-create-package.py` (the three lists, the
import graph, and the entry), the mode and symlink cases in
`tests/test-aic-host-security.sh`, `tests/test-aic-package.sh`, and the
"post-create package is root-owned and read-only" smoke in `smoke.yml`.

## `.github/workflows/`

- `rebuild.yml` is the **security-refresh track**.
  - Triggers: relevant template/CLI/test/package pushes to `main`, a weekly
    cron, and `workflow_dispatch`.
  - It publishes GHCR `:latest` and `:weekly-YYYY-VV`. It never publishes to
    npm.
- `release.yml` is the **release track**.
  - Triggers: a `v*` tag push only, or `workflow_dispatch` on a tag ref.
  - It makes sure that the immutable `:vX.Y.Z` and npm artifacts exist. Then
    it promotes the mutable latest channels conservatively.
- `smoke.yml` is the real-devcontainer smoke suite. Its only trigger is
  `on: workflow_call`.
  - `rebuild.yml` and `release.yml` both call it after their `build` job
    (`needs: build`). Thus you write a runtime assertion once, here.
  - Do not copy the job back into a caller. Do not add another trigger.

## `tests/`

`tests/` holds the regression tests for the host CLI and for the privileged
helpers. They run before the real-devcontainer smoke suite.

- A security fix normally adds a fast host fixture here and a runtime
  assertion in `smoke.yml`.
- A validator rule also gets a case in `tests/test-aic-validate.mjs`.

## Release files

- `package.json`: its `version` is the source of truth for the GHCR tag that
  `aic init` pins. Do not bump it by hand. Use `npm version` (see
  [Releasing](releasing.md)).
- `CHANGELOG.md` is maintained by hand, in
  [Keep a Changelog](https://keepachangelog.com/) format. It is the source of
  the GitHub Release notes and a release precondition.
- `scripts/promote-changelog.mjs` is a helper with zero dependencies.
  `npm version` runs it. It promotes `## [Unreleased]` to the new version
  (date and compare links). It never generates content.
- `.githooks/pre-push` is a local mirror of the CI changelog gate. It is
  opt-in: run `git config core.hooksPath .githooks`.

## Claude Code plugin

- `.claude-plugin/marketplace.json` is the Claude Code marketplace
  (`aicontainer`).
  - It must stay at the repository root, because `/plugin marketplace add
    stefanoginella/aicontainer` reads it from there.
  - It lists the one plugin by the relative source `./tools/claude-plugin`.
  - The npm package does not ship it.
- `tools/claude-plugin/` is the `aicontainer` Claude Code plugin. It holds
  the host-side `/aicontainer:setup` skill.
  - Bump the `version` in its `plugin.json` when the skill changes.
  - Validate both with `claude plugin validate .` and `claude plugin validate
    tools/claude-plugin`.
  - The skill gets the stack-to-files mapping from
    `docs/user/stack-reference.md`. Do not copy the mapping into the skill.
- `docs/user/stack-reference.md` is also a contract for other tools. Keep
  its structure: one `## Stack: <name>` section for each stack, with the same
  seven level-3 headings in the same order, and a target-file line before
  each code block. When a change to a preset, a mount rule, or the image
  affects a snippet, update the page. Mark an item that needs a new aic
  feature `(since Unreleased)`; the release fills in the version (see
  [Releasing](releasing.md)). The skill reads the page from the tag of the
  installed aic. Guarded by
  `tests/test-aic-stack-reference.mjs`. With Docker Compose, it runs the
  merged snippets through `aic validate`.
