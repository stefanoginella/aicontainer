# Security review checklist

Read this page before you change `aic`, the modules in `lib/aic/`, `lib/validate.mjs`, `lib/trust-hash.mjs`, `lib/docker-inspect.mjs`, `lib/project-identity.mjs`, `template/Dockerfile`, `template/post-create.py` and the `template/post_create_*.py` modules, `template/aic-firewall`, the files in `template/hooks/`, the privileged helper scripts, or `.github/workflows/*.yml`.

## Security stance

This container sandboxes autonomous AI tools that run in bypass-permissions mode or sandbox-off mode. The "Threat model" section in [Security](../user/security.md) is the source of truth.

When you must choose between two implementations, choose the more restrictive one.

Review every change to the files below for security regressions. Each note is complete, so you can use this page as a checklist. Where another page owns the full rule, the note links to it.

## `aic` and `lib/aic/*.sh`

The host CLI makes every decision before Docker starts a container. The layout is in [Repository layout](architecture.md).

- `aic` loads the modules from an explicit, ordered list. Never use a glob: it would source a file that somebody planted in `lib/aic/`.
- A missing or unreadable module must stop the command before it does anything, with a message that names the file.
- A module only defines functions and constants. A top-level command in a module runs on every `aic` call, `aic __supports` included.
- `aic` sets the bind-source cache of `export_runtime_environment()` at the top. Keep that assignment above the module load list, so that a value from the environment never seeds the cache.
- `lib/aic/validation.sh` holds the pre-Docker gate (`validate_project_security()`), the exact-trust store, and Docker consent. The rules are in [Validation](validation.md).
- The commands in `lifecycle.sh` and `signing.sh` call the gate before they give the project configuration to Dev Containers. The list of commands is in [Validation](validation.md). Do not remove a gate call, and do not move it after a Docker call.
- The other modules hold boundary checks too: the control-path and `.git` checks and the Compose name (`identity.sh`, see [Project identity](project-identity.md)), the socket and the status relay marker (`runtime.sh`, see [Host state](host-state.md)), the volume checks and ownership proofs (`volumes.sh`, see [Project identity](project-identity.md)), the Docker consent reset in `aic sync` (`init-sync.sh`), and the `is_semver()` gate on registry output (`versions.sh`, see [Version drift](version-drift.md)).

Guarded by the broken-install cases in `tests/test-aic-host-security.sh` and the load-list checks in `tests/test-aic-package.sh`.

## `lib/trust-hash.mjs`

This file computes the exact-trust hash. The full rules are in [Validation](validation.md).

- Do not change what goes into the hash or the order. A different digest for the same project makes every stored approval stale.
- A helper that cannot run, or a value that is not a sha256 hex digest, must never store or match an approval.

Guarded by the trust-hash cases in `tests/test-aic-host-security.sh` and `tests/test-aic-host-helpers.mjs`.

## `lib/docker-inspect.mjs` and `lib/project-identity.mjs`

These files hold the Node half of the identity and volume checks. The full rules are in [Project identity](project-identity.md).

- `docker-inspect.mjs` accepts only local volumes with no driver options, and proves container ownership from the inspected labels and mounts.
- `project-identity.mjs` finds a `COMPOSE_PROJECT_NAME` that would replace the managed name, and creates the `.git` control files without following a link.

Guarded by `tests/test-aic-host-helpers.mjs`.

## `lib/validate.mjs`

This file is the structural validator. The full rules are in [Validation](validation.md).

- Keys are allow-lists.
- A removed check opens a host-boundary bypass.
- A key added to `reviewedServiceKeys` without a dedicated check also opens a host-boundary bypass.
- Extend `tests/test-aic-validate.mjs` with every rule.
- Keep the Docker-backed cases in `tests/test-aic-host-security.sh`.

## `template/Dockerfile`

This file sets the sudoers entries, the `USER`, and the capability bits. A new `NOPASSWD` entry is a load-bearing decision.

The Dockerfile also bakes these items:

- The Claude and OpenCode system-managed policy.
- `/etc/codex/requirements.toml`.
- The managed hook directory.
- The root-managed Git and shell destinations. See [Shell startup and overlays](shell-and-overlays.md).
- The neutral tool-home symlinks. See [Host seeds, tool homes, and reusable auth](seeds-and-auth.md).
- The hash-pinned offline Python support.
- The `aic_post_create` package in `/opt/aic-post-create`. The seed sanitizer
  runs it as root. Keep the `COPY` an explicit list of files, keep the package
  `root:root` and read-only, and keep the fixed import path and the bytecode
  setting of `post-create.py`. See
  [The post-create package](architecture.md#the-post-create-package).

Codex and OpenCode install through their standalone installers, not through npm:

- Codex: `chatgpt.com/codex/install.sh`.
- OpenCode: `opencode.ai/install` with `--no-modify-path`, into `~/.opencode/bin`.

This choice is deliberate, so that self-update works. The cost: the two tools are outside the `NPM_CONFIG_MIN_RELEASE_AGE` quarantine. The quarantine still covers npx MCPs.

All three CLIs are a baked floor. `refresh_ai_tools()` updates them to the latest version on each create. See "AI-tool refresh on every create" in [Shell startup and overlays](shell-and-overlays.md).

Every other curl or git download is pinned and checked before use. The pin is a sha256, a signature, a key fingerprint, or an upstream commit. See "Image download integrity" in [Image integrity](image-integrity.md).

## `template/aic-firewall`

This file sets the outbound allowlist and the unconditional metadata chains. The related rules are in [Runtime policy](runtime-policy.md) and [Host state](host-state.md).

- A new host expands reachability.
- The script builds the A/B IPv4 and IPv6 generations while the active DROP generation stays live. Then it switches with one jump replacement.
- A prohibited metadata or link-local resolution aborts the change, and the active policy stays the same.
- A zero-IP result also aborts the change, and the active policy stays the same.
- Never flush a live chain or a metadata chain.
- Never set the policy to ACCEPT.
- Never use `-m set` in a rule. It needs `CAP_NET_RAW`, which the devcontainer drops, so `enable` fails there. `accept_set_members_v4()` writes one exact `-d` rule for each member of the inactive set.
- Never silently ignore configured IPv6 that cannot be filtered.
- The host status relay uses its own ipset and an exact TCP-8787 rule. Never put `host.docker.internal` in the general all-port allowlist.
- A preset host comes only from the fixed `preset_domains()` table. A project file selects names, never hosts. Keep the names equal to `FIREWALL_PRESETS` in `lib/validate.mjs`.
- `auto` only enables, and only when `.devcontainer/firewall-enable` exists. Keep the fail-closed start command in both Compose templates. See "Declarative enable and presets" in [Runtime policy](runtime-policy.md#declarative-enable-and-presets).
- There is no `disable` or `flush` subcommand.

The OUTPUT chains accept `ESTABLISHED,RELATED` only with `--ctdir REPLY`. This matches replies to sessions that started from outside.

> **Warning:** Do not use a blanket `ESTABLISHED,RELATED` accept. It keeps an outbound session alive that the container opened before `enable`, to a host that is not on the list.

Guarded by the static check in `tests/test-aic-host-security.sh`, `tests/test-aic-firewall-presets.sh`, the "allowlist enable cuts a connection opened before it" smoke, and the "declared firewall is on at every start" smoke. The smoke uses throwaway containers, because you cannot undo `enable` in a running container.

## `template/hooks/pre-tool-use.sh`

This hook blocks reads of `.env` and other sensitive paths.

These changes weaken the model:

- Loosening the matchers `is_blocked_env`, `bash_touches_env`, `is_curl_pipe_sh`, or `is_protected_path`.
- Loosening the `Bash|Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Glob` matcher in `claude-settings.json`.

All three tools share this hook:

- Claude gets it through the root-managed `/etc/claude-code/managed-settings.json`.
- Codex gets it through `/etc/codex/requirements.toml` and its `managed_dir`.
- OpenCode gets it through `template/hooks/opencode-guardrail.js` (see below).

Hooks in a user Codex config are non-managed. Codex treats them as untrusted and skips them in autonomous mode. Do not move the hook there.

## `template/hooks/agent-status.py`

This hook sends optional informational callbacks from the Claude and Codex managed lifecycle hooks. The full rules are in [Host state](host-state.md).

- The fixed endpoint and the exhaustive metadata schema are the privacy boundary.
- The hook ignores proxy settings and redirects.
- The hook caps its input.
- The hook returns success on every malformed-input path and every network-error path. So observability cannot become policy.
- Treat receiver events as forgeable.
- Never attach command or macro authority to the ingestion route.

## `template/hooks/opencode-guardrail.js`

This file is the OpenCode part of the same guardrail. It is a plugin with no dependencies. Its `tool.execute.before` does these steps:

1. It maps the OpenCode `{tool, args}` to the JSON that `pre-tool-use.sh` reads on stdin.
2. It runs `pre-tool-use.sh` with `spawnSync`.
3. It `throw`s when the script exits with status 2.

The root-managed `/etc/opencode/opencode.json` wires the plugin by absolute path. There is no trust prompt. The plugin runs even with `permission."*"=allow`.

- Keep the logic in `pre-tool-use.sh`, the single source of truth. The shim only maps and dispatches.
- Do not add a second native `permission` deny. It could diverge from the hook.

Guarded by the "opencode guardrail blocks a .env read" test.

## `template/aic-chown-volumes` and `template/aic-lock-user-config`

These two scripts are the only non-firewall scripts allowed through `NOPASSWD`. Both use these protections:

- Privileged mode or interpreter mode.
- A fixed PATH and environment.
- A fixed umask.
- Hardcoded inputs and destinations.

### `aic-chown-volumes`

The full `chown-paths` rules are in [Project-owned overrides](project-overrides.md).

- It never accepts target argv.
- In addition to the path prefix check, it verifies canonical exact mountpoints against the current container through `/run/aic-host/docker.sock`.
- It uses only GET, with the curl config and proxies disabled.
- It accepts only option-free local named volumes before it runs `chown -h -R`.

### `aic-lock-user-config`

The overlay rules are in "Personal config overlay" in [Shell startup and overlays](shell-and-overlays.md).

- It runs `/usr/bin/python3 -I`.
- It installs a fixed `TARGETS` table, never argv.
- It opens each `vscode`-owned staging inode without following links.
- It atomically creates (never replaces) a `root:root 0444` destination under `/etc/aic/user-config/`.
- The **required** `gitconfig` target is parsed with Git `--no-includes` under a minimal environment. It allows only fixed safe keys and exact aic values. The only `credential.*` keys are the two required GitHub helper keys, each with an exact value list. See "GitHub credential helper" in [Host seeds, tool homes, and reusable auth](seeds-and-auth.md#github-credential-helper).
- The **optional** personal overlay targets are `shell/rc.zsh`, `shell/p10k.zsh`, and `statusline/statusline.{sh,mjs,js,py}`. The helper installs them **without** content validation, because zsh and a statusline script cannot be allowlisted.

The unvalidated install is safe only when all three of these conditions are true:

1. The bytes come from the trusted human and are staged before any agent runs.
2. The file lands root-locked, so an agent cannot tamper with it.
3. The file contents still execute only as `vscode`.

Rules:

- Do not add a content-bearing target without a validator unless all three conditions are true.
- Do not turn either helper into a general copy, chown, or config installer.

Guarded by the dedicated tests plus the runtime smoke.

## `/usr/local/bin/aic-statusline` (baked by `template/Dockerfile`)

The launcher is root-owned `0555`. It is not a sudoers helper. The full rules are in "Personal config overlay" in [Shell startup and overlays](shell-and-overlays.md).

- It is the only thing that the Claude `statusLine` command names.
- It dispatches a hardcoded interpreter at a hardcoded path.
- Never make it read a path from argv or from the environment.
- Never `eval` file content.

## `.github/workflows/*.yml`

The full release rules are in [Releasing](releasing.md).

- GHCR uses the job-scoped `GITHUB_TOKEN` package permission.
- npm uses OIDC trusted publishing and provenance, not a long-lived npm token.
- Publishing jobs run only on push, schedule, or dispatch. They never run on a PR.
- Checkout credentials are never persisted.
- Every `uses:` is pinned to a full commit SHA with a `# vX.Y.Z` comment, never to a tag. The reason: a moved upstream tag would run in a job that holds the OIDC token and package write permission.
- Renovate (`helpers:pinGitHubActionDigests`) bumps the SHA and the comment together.
- A tool that a workflow downloads is pinned by version and sha256, and the step checks the sha256 before it runs the tool. Example: the ShellCheck step in `smoke.yml` (see [Development](development.md)). Never use the copy that the runner image happens to have.

Guarded by the action-pin check in `tests/test-aic-host-security.sh`.
