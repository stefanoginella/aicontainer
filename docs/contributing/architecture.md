# Repository layout

Read this page before you add, move, or remove a top-level file or directory, or a file in `template/`.

This page tells you what each part of the repository does. The guidance is for
AI coding agents and for humans who work **on** aicontainer itself. Users who
run aicontainer in their projects start at the [user guide](../user/install.md).

Convention: "Guarded by the '…' test" names a CLI test or a smoke test in
`.github/workflows/smoke.yml`. When you change the behavior, extend the test.
Do not weaken the test.

## The `aic` CLI

`aic` is the host-side bash CLI. It is a single file.

- npm exposes it as the bins `aic` and `aicontainer`.
- Git installs expose it as `~/.aicontainer/aic`.
- It finds its template and `lib/` through `$AIC_HOME`. The default is the
  directory of the script, after `aic` follows symlinks.

## `lib/`

`lib/` holds the host-side Node modules that `aic` runs. The npm package
ships them. They use only `node:` built-ins and have no dependencies.

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

- `Dockerfile`, `post-create.py`, `hooks/`, `aic-firewall`,
  `aic-chown-volumes`, `aic-lock-user-config`, `.zshrc`, `gitignore`.
- `hooks/` holds three files. All three are copied root-owned to
  `/etc/aic/hooks/`:
  - `pre-tool-use.sh`, the shared guardrail.
  - `opencode-guardrail.js`, the thin OpenCode adapter.
  - `agent-status.py`, the opt-in, metadata-only Claude/Codex lifecycle relay.
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
