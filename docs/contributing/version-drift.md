# Version drift and update notifications

Read this page before you change `warn_compose_drift()`, `check_for_update()`, `aic initialize`, `cmd_check_drift`, or the CLI lookup of the generated initializer.

Two best-effort checks live next to `read_aic_version()` in `lib/aic/versions.sh`.

- Both fail soft. Every error path does `return 0`. They must never stop the
  command of the user.
- `AIC_NO_UPDATE_CHECK=1` silences both.

## Tier 1: `warn_compose_drift()` (offline, hot path)

The check runs on `aic up`, `aic shell`, and `aic rebuild`.

- It compares the pinned `:vX.Y.Z` of the project with the CLI version.
  `read_pinned_compose_version()` reads the pin. It is anchored on the
  repository path, so comments and the socket-proxy do not match.
- It warns in both directions, with a `sync && rebuild` hint.
- On `rebuild`, the warning comes **before** the `docker pull`. `rebuild`
  pulls the currently pinned tag again and never pins again. Thus the early
  warning lets the user stop and run `aic sync`.

### VS Code "Reopen/Rebuild in Container"

The check also runs on VS Code "Reopen/Rebuild in Container". That action
starts `devcontainer up` directly and never runs `aic`. The check runs through
the only host-side lifecycle hook.

New templates run the trusted `aic initialize` entry point.

1. It finds the CLI first. It looks on PATH, in the git install, in common
   npm/Homebrew locations, and in nvm/fnm/mise/asdf/Volta shims.
2. A missing CLI is now a hard failure with an actionable message. If the
   initializer skipped it silently, it would also skip managed validation,
   seed preparation, project migration, and safe volume bootstrap.
3. `initialize` does all of those fail-closed tasks.
4. Then it calls the drift warning, which is still best-effort.

### Rules for the CLI probe (do not change)

1. A candidate is capable when `aic __supports initialize` exits 0.
2. Do not go back to a check that only reads the file. A Volta shim is a
   binary, and an asdf/mise shim is a wrapper. Neither contains the text of
   the CLI.
3. The probe is internal. It is not in help or completions.
4. The probe prints nothing. It makes no Docker call and no network call. It
   writes no file.
5. The probe accepts only that exact capability name. An older CLI treats it
   as an unknown command and fails it.
6. A `grep` for `initialize)` stays as the second check. Thus a plain-script
   CLI that has `initialize`, but is older than the probe, is not reported as
   "too old".
7. The dispatcher stays in the `aic` file, not in a module. Thus when a
   module in `lib/aic/` is missing, the probe fails but the `grep` still
   finds the CLI. `aic initialize` then stops and names the missing module.

Guarded by the initializer cases in `tests/test-aic-host-security.sh` (nvm,
fnm, Volta, asdf, mise, pre-probe CLI; `/bin/sh`, and dash when installed).

### Bootstrap limit (do not change)

Dev Containers must parse the `devcontainer.json` of the repository first.
It must also execute the host-side `initializeCommand` first. Only after that
can the managed `aic initialize` code validate that file.

- The initializer is "trusted" only after `aic init`/`sync` generated it and
  the host reviewed the control files.
- It cannot sanitize an arbitrary initializer from the repository before that
  initializer executes.
- Never claim that a direct VS Code Reopen validates unknown repository
  control code before it runs.
- For untrusted clones, document this first-launch path: `aic init --force`,
  review, then `aic up`.

### Legacy `cmd_check_drift`

`cmd_check_drift` remains only for older generated templates.

- It is lenient and only warns. It always exits zero.
- Do not confuse it with the new trusted initializer.
- The output of both is visible in the Dev Containers output channel.

### Blind spots (on purpose)

An offline check with zero cost is better than full coverage.

- The check compares the CLI with the pin. It does not compare the pin with
  the *running container*. Thus a project that is synced but not rebuilt
  stays silent. The hint resolves this case anyway.
- Build-mode projects have no pin. Thus the check does not cover them.
- `aic status` reports the running state separately. Do not turn the hot-path
  warning into a Docker inspection.

## Tier 2: `check_for_update()` (network, off the hot path)

The check runs only on `aic version` and `aic upgrade`.

- It asks **npm** for the latest published version. It does not ask GHCR,
  because GHCR `:latest` floats on the weekly cron and would report "behind"
  incorrectly.
- `fetch_latest_version()` is bounded (`curl --max-time`, with an `npm view`
  fallback).
- The result goes through `is_semver()` before any `printf`. That validation
  is the defense against terminal escapes from a hostile registry. Keep it.
- The result is cached for 24h under
  `$XDG_CACHE_HOME/aicontainer/update-check`.
- The check is skipped when `CI` is set. That guard keeps the workflow CLI
  tests offline. Do not remove it.
