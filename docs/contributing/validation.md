# Host-side validation

Read this page before you change `validate_project_security()` (in `lib/aic/validation.sh`), `lib/validate.mjs`, `lib/validate-cli.mjs`, `lib/trust-hash.mjs`, the trust flow (`aic trust`, `--allow-unsafe`), or the diagnostic commands (`doctor`, `status`, `validate`).

This page continues [Project identity and the host control boundary](project-identity.md). The generated `.env` and the status relay consent are in [Generated host state](host-state.md).

## The pre-Docker gate

`validate_project_security()` is the real pre-Docker gate. It does these steps:

1. It verifies the provenance of the managed files.
2. It resolves the base Compose model and the merged Compose model to JSON.
3. It checks every service, and also:
   - volumes, networks, mounts, builds, and ports,
   - capabilities, namespaces, and devices,
   - configs/secrets,
   - include/extends/provider,
   - lifecycle hooks,
   - environment-file indirections,
   - protected managed mount targets.

Any managed mismatch is untrustable and requires `aic sync`.

### Split between `aic` and `lib/`

- The Compose calls and the trust decision stay in the shell code, in `lib/aic/validation.sh`.
- The structural checks are in `lib/validate.mjs`. `aic` runs them through `lib/validate-cli.mjs`.
- The exact-trust hash is in `lib/trust-hash.mjs`. `aic` runs it through `lib/cli.mjs`. Do not change its output: stored approvals hold it.

Keep that split. The module reads only files under the project root and never runs Docker. Thus its rules stay testable from fixtures.

> **Warning:** Do not ignore the exit status of the validator. A validator that fails to run is a MANAGED finding.

Guarded by the missing/failing-validator case in `tests/test-aic-host-security.sh`.

## Compose minimum version

The gate needs Compose 2.35+ for `config --no-env-resolution`. `AIC_MIN_COMPOSE_VERSION` holds this minimum, and `doctor` uses the same value.

- An older Compose gives one COMPOSE finding with an upgrade hint. It never gives the `aic sync` hint.
- An older Compose still fails closed.

`validation_compose_config()` captures the Compose stderr only to find an "unknown flag" error.

> **Warning:** Do not print that stderr. It can contain resolved host values.

Guarded by the Compose-minimum cases in `tests/test-aic-docker-runtime.sh`.

## Trust for project code files

Project-owned files that run code in the container need exact trust too. `validate_project_code_files()` checks these files:

- `post-create.project.sh`
- `shell-rc.zsh`
- `p10k.zsh`
- `statusline.{sh,mjs,js,py}`

A clone supplies these files. They run before any prompt, with open egress and the tool logins. So "it runs as `vscode`" is not a reason to let a repository opt itself in.

### VS Code extensions and settings

The validator judges VS Code extensions and settings from the merged `devcontainer.json`. It does not judge them from `vscode-extensions` / `vscode-settings.json`. The reasons: VS Code reads the merged file, and a repository can commit that file directly.

- An addition beyond the template is a trust finding.
- A changed template setting is managed drift. The per-shell rewrite in `patch_devcontainer_json()` is the only accepted change.
- A committed `.vscode/` is out of scope. The user guide names it as a residual risk that only Workspace Trust guards (see [Threat model](../user/security.md)).

The trust hash covers the whole `.devcontainer/` tree. So any edit asks for trust again.

Keep the file list aligned with `AIC_CONTROL_FILES` and with the post-create and lock-helper tables.

Guarded by the project-code cases in `tests/test-aic-host-security.sh` and the "Bring up the devcontainer" step in `smoke.yml` (a direct start is refused, then trusted).

## Rules that keep the validated model equal to the started model

These rules keep the validated model equal to the model that Dev Containers can start:

1. Every validation `docker compose config` runs with `--profile '*'`. A plain `config` omits profiled services. But `up` still starts a profiled service when `runServices` names it or `COMPOSE_PROFILES` enables it.
2. Keys are allow-lists, never deny-lists.
   - `devcontainer.json` can contain only the top-level keys of the template. Anchors must be equal to the template.
   - `name`, `dockerComposeFile`, `containerEnv`, and `customizations` are the only merge targets. Thus `runServices` and future spec keys fail.
   - Compose top-level keys and service keys outside `reviewedTopLevelKeys`/`reviewedServiceKeys` must be equal to the managed base. Otherwise they are trust findings.
   - Add a key to those sets only together with a dedicated check, or when the key cannot reach past its own container.
3. `parseJsonc()` must read `devcontainer.json` exactly as the Dev Containers CLI reads it. The CLI scanner also ends a `//` comment at a bare `\r`. So the validator refuses a bare `\r` and U+2028/U+2029 and does not parse them. Otherwise, keys after one of these characters are live for the CLI but hidden from validation.

## Approve a host-boundary expansion

An intentional expansion of the host boundary requires one of these:

- `aic trust`: an interactive approval for the exact relevant hash. `aic` stores it under `$XDG_STATE_HOME/aicontainer/trust`. Any change makes it invalid.
- `aic up|rebuild --allow-unsafe`: a one-run hash that `aic` passes to the trusted initialize child. It is never a reusable boolean.

A build context outside `.devcontainer/` cannot get persistent trust. Only `--allow-unsafe` or a "yes" at the `aic up` prompt starts it, for one run.

Guarded by the gate decision cases in `tests/test-aic-host-security.sh`. A pseudo-terminal answers the prompts there.

## Docker consent and the override scan

Docker read/write consent is separate state outside the repository. A Compose edit cannot give itself daemon visibility.

`AIC_NO_OVERRIDE_SCAN=1` silences only the old readable grep warning.

> **Warning:** Do not let `AIC_NO_OVERRIDE_SCAN` bypass structural validation.

## Where validation runs

- `aic shell`, `run`, `up`, `rebuild`, and the mutating `signing` actions validate before they give the project configuration to Dev Containers.
- `preflight` validates before it reports.
- The generated VS Code initializer validates before Compose creation. The bootstrap limit applies (see [Version drift and update notifications](version-drift.md)).

Guarded by `tests/test-aic-host-security.sh` and the matching workflow smoke tests. Extend them when the model changes.

## Diagnostics stay read-only

`aic doctor` checks these items:

- host versions,
- the selected local Unix-socket Docker context, and its runtime and bind source (it warns on an unrecognized macOS VM),
- Compose 2.35+ with subpath schema and `config --no-env-resolution --no-interpolate` support (stdin-only parses; no probe volume),
- the Dev Container CLI,
- the conventional Git-root shape,
- install completeness,
- control-path types,
- project identity,
- the source of the Dev Containers project name.

Warnings exit 0. Blockers exit nonzero.

`cmd_doctor()` runs one helper for each check group, in the order above. Guarded by the doctor cases in `tests/test-aic-docker-runtime.sh`: they check the order of the groups and the missing-tool, endpoint, and project-state reports.

`aic status` reports these items and does not change them:

- identity, mode, tools, and shell,
- Docker consent,
- status-relay mode,
- socket bind source,
- image and runtime,
- credential-bridge health,
- volume metadata.

`aic validate` runs the full gate noninteractively. It honors existing exact trust. It never prompts and never writes trust.

Keep help, completions, and tests in sync. Do not turn diagnostics into implicit repair.

## JSON output

`doctor`, `status`, `validate`, and `version` take `--json`. The user shape is in [Use aicontainer in a project](../user/usage.md#json-output---json). `lib/aic/json.sh` holds the code.

- `json_run()` runs the same command function in a subshell with errexit on. The subshell is not in an `&&` or `||` list, because bash turns errexit off there. Its stdout goes to stderr. Only the JSON object goes to stdout.
- `error` holds the message of a `die` at the level of that subshell only. A `die` in a nested subshell (a probe in `$(...)` that the caller catches) must not set it. Thus a `doctor` blocker gives `"error": null`.
- `--json` changes only the output. The checks, the gate decision, and the exit status stay the same. Never skip or weaken a check in JSON mode.
- The record helpers (`json_item`, `json_findings`, `json_field`) do nothing outside JSON mode. `validate_project_security()` calls `json_findings` next to the text output of its findings. Do not move the call after a `die`.
- `json_string()` encodes every string. It escapes quotes, backslashes, and control characters. A value that is not valid UTF-8 gets `?` for each byte above 0x7f. Never build JSON from a raw value.
- The encoder is pure bash, so `doctor --json` works on a host with no Node.js.
- `aic` sets `aic_json_dir` to `""` before it loads the modules. Thus a value in the environment never selects JSON mode.
- The doctor `id`, the validate finding types, and the member names are an interface. Keep them stable. A change that is not compatible increments `AIC_JSON_SCHEMA`.

Guarded by `tests/test-aic-json-output.mjs`. It compares the text mode and the JSON mode of each command: the exit status, the doctor checks, and the validate findings.
