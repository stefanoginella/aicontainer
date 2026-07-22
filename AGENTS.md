# AGENTS.md

Guidance for AI coding agents (and humans) working **on** aicontainer itself.
Users running aicontainer in their projects start at `README.md`.

`CLAUDE.md` is a thin pointer to this file — keep that arrangement; new
agent-facing notes go here.

Convention: "guarded by the '…' test" below names a CLI/smoke test present in
both workflows. When you change the behavior, extend the test — never weaken
it.

## Repository layout

- `aic` — the host-side bash CLI, single file. Exposed as npm bin (`aic`,
  `aicontainer`) and `~/.aicontainer/aic` for git installs. Finds its template
  via `$AIC_HOME` (defaults to the script's directory after
  symlink-following).
- `template/` — copied into a project's `.devcontainer/` by `aic init`/`aic
  sync`; the source of truth for what lands in user repos.
  - `Dockerfile`, `post-create.py`, `hooks/`, `aic-firewall`,
    `aic-chown-volumes`, `aic-lock-user-config`, `.zshrc`, `.gitignore`
  - `hooks/`: the shared guardrail `pre-tool-use.sh` plus
    `opencode-guardrail.js`, the thin OpenCode adapter — all copied root-owned
    to `/etc/aic/hooks/` and enforced for Claude, Codex, and OpenCode.
  - `docker-compose.pull.yml` (default mode), `docker-compose.build.yml`
    (`--build` mode)
  - `README.md` — copied into every project's `.devcontainer/` in **both**
    modes; a managed guide to the do-not-edit vs project-owned split. Keep its
    two lists in sync with `apply_template()` and the project-owned files.
  - `.gitignore` — copied in both modes and contains only `.env`.
    `.devcontainer/.env` itself is atomically generated per host/context; it is
    a managed control file, not a template asset or project-owned override.
- `.github/workflows/`
  - `rebuild.yml` — **security-refresh track**: relevant template/CLI/test/
    package pushes to `main`, weekly cron, `workflow_dispatch`. Publishes GHCR
    `:latest` + `:weekly-YYYY-VV`; never npm.
  - `release.yml` — **release track**: `v*` tag push (or `workflow_dispatch`
    on a tag ref) only. Ensures immutable `:vX.Y.Z` + npm artifacts exist,
    then conservatively promotes mutable latest channels.
- `tests/` — host CLI and privileged-helper regression tests run before both
  real-devcontainer workflow smoke suites. Security fixes normally add a fast
  host fixture here and a runtime assertion in both workflows.
- `package.json` — its `version` is the source of truth for the GHCR tag `aic
  init` pins. Never bump it by hand; use `npm version` (see "Releasing").
- `CHANGELOG.md` — hand-maintained ([Keep a Changelog](https://keepachangelog.com/)
  format); source of the GitHub Release notes and a release precondition.
- `scripts/promote-changelog.mjs` — zero-dep helper run by `npm version`:
  promotes `## [Unreleased]` to the new version (date + compare links). Never
  generates content.
- `.githooks/pre-push` — local mirror of the CI changelog gate; opt-in via
  `git config core.hooksPath .githooks`.

## Image tag pinning (read before editing the CLI)

In pull mode, `aic init`/`aic sync` write
`ghcr.io/stefanoginella/aicontainer:vX.Y.Z` into the generated compose file
(`X.Y.Z` = installed `package.json` version via `read_aic_version()`).
`template/docker-compose.pull.yml` ships the literal placeholder `:latest`
(five occurrences: two comments + three managed `image:` lines); `apply_template()`
sed-rewrites each to `:vX.Y.Z`. **Never pin the template itself** — `:latest`
is the placeholder that keeps the rewrite idempotent so `aic sync` can re-pin
cleanly.

If you change the GHCR repo path, update **all of**: the template, the sed
pattern in `apply_template()`, the README's GHCR references, the
`aic-firewall` allowlist's `ghcr.io` entry, and both workflows' image tags.

## Version drift / update notifications

Two best-effort checks live next to `read_aic_version()` in `aic`. Both fail
soft (every error path `return 0` — they must never abort the user's command)
and both silence with `AIC_NO_UPDATE_CHECK=1`.

**Tier 1 — `warn_compose_drift()` (offline, hot path).** On `aic
up`/`shell`/`rebuild`, compares the project's pinned `:vX.Y.Z`
(`read_pinned_compose_version()`, anchored on the repo path so
comments/socket-proxy don't match) against the CLI version; warns either
direction with a `sync && rebuild` hint. On `rebuild` it fires **before** the
`docker pull` — `rebuild` re-pulls the currently pinned tag and never re-pins,
so warning first lets the user abort and `aic sync`.

It also fires on VS Code "Reopen/Rebuild in Container" (which drives
`devcontainer up` directly, never `aic`) through the only host-side lifecycle
hook. New templates run the trusted `aic initialize` entry point, which first
locates the CLI on PATH, git-install, common npm/Homebrew locations, and
nvm/fnm/mise/asdf/Volta shims. A missing CLI is now an actionable hard failure:
silently skipping it would also skip managed validation, seed preparation,
project migration, and safe volume bootstrap. `initialize` performs all of
those fail-closed tasks, then calls the still-best-effort drift warning.

Load-bearing bootstrap limit: Dev Containers must parse the repository's
`devcontainer.json` and execute its host-side `initializeCommand` before the
managed `aic initialize` code can validate that file. The initializer is
"trusted" only after `aic init`/`sync` generated it and the host reviewed the
control files; it cannot sanitize an arbitrary repo-supplied initializer before
execution. Never claim direct VS Code Reopen prevalidates unknown repository
control code. For untrusted clones, document `aic init --force`, review, then
`aic up` as the first-launch path.

`cmd_check_drift` remains only for older generated templates. It is lenient,
warn-only, always exits zero, and must not be confused with the new trusted
initializer. Visibility for both is the Dev Containers output channel.

Deliberate blind spots (offline + zero-cost beats full coverage): it compares
CLI-vs-pin, not pin-vs-*running container*, so a synced-but-not-rebuilt
project is silent (the hint resolves it anyway); and build-mode projects have
no pin, so they're unchecked. `aic status` reports running state separately;
don't turn the hot-path warning into a Docker inspection.

**Tier 2 — `check_for_update()` (network, off hot path).** Only on `aic
version`/`upgrade`. Asks **npm** for the latest published version — not GHCR,
whose `:latest` floats on the weekly cron and would mis-report "behind."
`fetch_latest_version()` is bounded (`curl --max-time`, npm-view fallback)
and gated through `is_semver()` before any `printf` — that validation is the
terminal-escape defense against a hostile registry; keep it. Cached 24h under
`$XDG_CACHE_HOME/aicontainer/update-check`, and skipped when `CI` is set —
that guard is what keeps the workflow CLI tests offline; don't remove it.

## Project identity and host-side validation

Generated Compose projects are path-unique:
`aic-<sanitized-basename>-<12-char-sha256(canonical-path)>`. The name is
written as the top-level Compose `name:` and must exactly match
`expected_project_name()`. Never accept a repository-provided name or fall
back to the old basename when a top-level name is present but malformed —
`down`/`destroy` could otherwise target another checkout's resources.

Projects created before this scheme have no top-level name. `aic sync`, the
next `up`, or VS Code's generated `initializeCommand` copies their transcript
volume automatically only when a container has exact canonical-workspace and
legacy-project labels and actually mounts that volume at the managed session
root, with no differently labeled container also mounting it. A label candidate
with the wrong mount or a conflicting owner is not proof. Project-wide legacy
cleanup must inspect every container with that Compose project label. It needs
at least one exact workspace owner; a missing workspace label is accepted only
on the fixed managed sidecars (`socket-proxy`, `aic-auth-sync`, and
`aic-seed-sanitizer`). Different owners, unknown unlabeled services, or
unreadable containers preserve the whole stack. Cleanup must not use
`--remove-orphans`, because the trusted template cannot attribute them. If no
container can disambiguate a historically
shared basename volume, sync preserves it without copying; interactive `aic
up` asks once (declining creates a fresh path-unique volume and preserves the
source), while non-interactive/direct VS Code startup fails with an `aic up`
hint. Migration uses the digest-pinned BusyBox helper and validates both
source/destination volumes as ordinary local-driver volumes with no driver
options before mounting them. The same metadata check applies to every
pre-existing managed volume: a same-named `local` volume with
`type=none,o=bind` is a host bind, not a safe volume. Keep the prompt-free
ownership-proven migration, data preservation, and exact ownership proof.

The host CLI treats `.devcontainer/` as a control boundary:

- `.devcontainer`, every known control file, and the managed hooks tree must
  be real files/directories, never symlinks or special files.
- Managed copies are staged next to their destination and renamed atomically.
  Switching build → pull removes every old managed build artifact.
- `vscode-settings.json` is parsed and re-serialized as a strict JSON object.
  Invalid input is warned/skipped; a key owned by the template is ignored so
  managed settings win.
- `project_name()` never evaluates untrusted Compose. `down`/`destroy` parse an
  installed trusted template with the exact `-p` name and `--remove-orphans`,
  so providers/includes in a repository override cannot execute during
  cleanup. Non-interactive `destroy` requires `--yes`.

`validate_project_security()` is the real pre-Docker gate. It verifies managed
file provenance, resolves the base and merged Compose models to JSON, and
checks every service plus volumes, networks, mounts, builds, ports,
capabilities, namespaces, devices, configs/secrets, include/extends/provider,
environment-file indirections, and protected managed mount targets. Any
managed mismatch is untrustable and requires `aic sync`. An intentional
host-boundary expansion requires one of:

- `aic trust`: interactive approval stored under
  `$XDG_STATE_HOME/aicontainer/trust` for the exact relevant hash; any change
  invalidates it.
- `aic up|rebuild --allow-unsafe`: one-run hash passed through to the trusted
  initialize child, never a reusable boolean.

Docker read/write consent is separate state outside the repository; a Compose
edit cannot grant itself daemon visibility. `AIC_NO_OVERRIDE_SCAN=1` silences
only the old readable grep warning — it must never bypass structural
validation. `aic shell`, `run`, `up`, `rebuild`, and mutating `signing` actions
validate before handing project configuration to Dev Containers; `preflight`
validates before reporting. The generated VS Code initializer validates before
Compose creation, subject to the bootstrap limit above. Guarded by
`tests/test-aic-host-security.sh` and the matching workflow smoke tests; extend
them when the model changes.

**Diagnostics stay read-only.** `aic doctor` checks host versions, the selected
local Unix-socket Docker context, Compose subpath schema support (stdin-only
parse; no probe volume), Dev Container CLI, conventional Git-root shape,
install completeness, control-path types, and project identity.
Warnings exit 0; blockers exit nonzero. `aic status` reports identity/mode/
tools/shell/Docker consent/image/runtime, credential-bridge health, and volume
metadata without mutating it.
`aic validate` runs the full gate noninteractively, honors existing exact
trust, never prompts, and never writes trust. Keep help/completions/tests in
sync and do not turn diagnostics into implicit repair.

**The selected local Docker socket is generated host state.** `aic init`,
`aic sync`, and each generated `aic initialize` invocation resolve the active
context's `unix://` endpoint, derive the Dev Containers runtime UID:GID, and
atomically rewrite `.devcontainer/.env`. The managed `template/.gitignore`
excludes that file, so rootless Docker, Docker Desktop, Colima, and OrbStack
work without flags or machine-specific diffs. Never trust `AIC_DOCKER_SOCKET`
from the environment or repository, accept a remote TCP/SSH endpoint, broaden
the dotenv grammar, or remove `.env`/`.gitignore` from the control-path checks
and template copies.

## Host seeds, tool homes, and reusable auth

The unrestricted container must never see raw host Git/tool config. The
`aic-seed-sanitizer` one-shot is the only service with fixed raw mounts: the
four config inputs (`~/.gitconfig`, Claude settings, Codex config, OpenCode
config) plus the opt-in personal-overlay dir `~/.config/aicontainer` (see
"Personal config overlay"). It runs as root solely for foreign-UID `0600`
reads, with no network/workspace/auth/sessions, read-only rootfs,
`no-new-privileges`, `cap_drop: ALL` plus only `DAC_OVERRIDE`, a small PID
limit, and fixed system-Python command. It writes four root-owned allowlisted
JSON objects into the per-project sanitized volume, which the main container
mounts RO. Sanitization recursively removes literal
env/header/auth/key/token/secret/password fields. Git uses a fixed safe-key
list and `/usr/bin/git --no-includes`. The personal overlay is the one
exception to JSON sanitization: `rc.zsh`/`p10k.zsh` are **code**, copied
verbatim (bounded, root-owned `0444`) into that same volume — never
field-stripped, never merged into main's config, and only ever *sourced*
(never executed by the sanitizer). Do not mount a raw input into main, add a
non-JSON output beyond that overlay, or make sanitizer failure soft.

All Claude/Codex/OpenCode config, memory, skills/plugins, prompt history, and
sessions live in one path-unique `aic-sessions` volume below
`~/.aic-sessions/tool-homes/{claude,codex,opencode-config,opencode-data}`.
Canonical tool paths are image-baked symlinks into those whole per-project
homes. There are no symlinks stored in the global auth volume and no global
tool parent mounted in main.

`setup_claude()` and `setup_codex()` precreate every known writable prompt/code
root (skills, agents/commands, rules/prompts, plugins) inside those project
homes. Keep the lists aligned with the "prompt/code persistence is
project-isolated" smoke test: an empty new project must expose the same
inspectable isolated surface as one where a CLI has already used the feature.

Login-once behavior comes from `aic-auth-sync`, not shared tool homes. It is the
only service that sees both the per-project sessions root and the three global
tool-auth subpaths. It runs continuously as the exact runtime UID:GID
interpolated through the generated gitignored `.env`; tracked Compose remains
byte-identical across hosts. The sidecar is networkless, has a read-only rootfs
and `no-new-privileges`, drops all capabilities, and has PID 32. Its credential
volume mounts remain writable by design. It synchronizes only:

- Claude `.credentials.json`
- Codex `auth.json`
- OpenCode `auth.json` and `account.json`

Files must be same-owner, single-link regular JSON objects, 1 byte–1 MiB, inside
canonical `0700` dirs; reads use no-follow/inode checks and writes are atomic
`0600`. Initial reconciliation is newer-wins and its healthcheck gates main;
subsequent login/logout/token-refresh changes flow both ways. Never add a glob,
unknown filename, config, prompt, plugin, or directory sync. GitHub, npm,
signing, and Semgrep retain separate fixed global subpath mounts in main; the
broad auth root is absent.

`initialize_managed_volumes()` must precreate every volume/subpath/file safely
and validate all existing volume metadata before Compose subpath resolution.
`prepare_host_seed_paths()` creates missing fixed host seed files so Docker
never turns a missing file bind into a root-owned directory. The legacy
container path `.claude-sessions` migrates to neutral `.aic-sessions` without
data loss. `postCreateCommand` uses `/usr/bin/python3 -I` and hash-pinned offline
`tomli-w` under `/opt/aic-python`; don't reintroduce runtime dependency
resolution before policy/config setup.

## Project-owned override files (don't break the auto-wire)

`apply_template()` overwrites `devcontainer.json` and `docker-compose.yml`
wholesale on every `init`/`sync`; only `AIC_TOOLS`/`AIC_SHELL` survive
(re-derived from the old file and re-injected by `patch_devcontainer_json`).
Users must not hand-edit those two files — per-project tweaks go in the
project-owned files `apply_template()` never touches: `Dockerfile.project`,
`firewall-allowlist`, `chown-paths`, `post-create.project.sh`,
`docker-compose.override.yml`, `vscode-extensions`, `vscode-settings.json`,
`shell-rc.zsh`, `p10k.zsh`. All share one contract: **opt-in by file presence,
survive sync, read-only inside the container.**

**`docker-compose.override.yml`** — sync-safe home for anything that would
otherwise live in `containerEnv` or the compose service (env, `extra_hosts`,
mounts, a `build:` block for `Dockerfile.project`). The template's
`devcontainer.json` ships `"dockerComposeFile": ["docker-compose.yml"]`
(single entry); `patch_devcontainer_json()` appends the override **only when
the file exists**, guarded against double-wiring so it stays idempotent. Keep
the template array single-entry — pre-listing the override makes
`devcontainer up` fail on projects without the file (a missing
`dockerComposeFile` entry is a hard error).

Because the override and `Dockerfile.project` ride along in an untrusted repo,
`scan_project_overrides()` still prints an early human-readable warning for
obvious grants. It is deliberately not the security boundary: YAML merging,
interpolation, short/long syntax, aliases, and service replacement make raw
text incomplete. `validate_project_security()` always follows it and fails
closed in TTY and automation alike. Keep the raw scan useful and its test, but
never treat adding a regex or `AIC_NO_OVERRIDE_SCAN` as equivalent to changing
the structural validator.

Host-shell interpolation is also a boundary. When an override exists, validate
the merged model with `--no-interpolate` and require exact trust for every
active `$VAR` / `${VAR}` expression not already present in the managed base.
Also detect bare environment/build-arg pass-through (`environment: [TOKEN]` or
a null map value); otherwise a repository can silently forward an exported
host token. Compose's escaped `$${VAR}` and ordinary literal values must remain
frictionless. Diagnostics may name the variable but must never print its
resolved value.

Keep both managed `AIC_DOCKER_SOCKET` mounts in long Compose syntax. Compose
2.38.x supports `--no-interpolate` but misparses the `:-` default and mount
separators when that expression appears in short `source:target:ro` syntax;
the long form preserves raw interpolation inspection on supported Linux CI
runners without changing the resolved bind.

Compose environment outranks both devcontainer `containerEnv` and image `ENV`.
Changes to the managed keys plus `HOME`, `PATH`, shell startup variables,
tool-home/XDG paths, `GIT_CONFIG_*`, `LD_*`, and Docker endpoint/config variables
are trust findings: they can run project code before metadata hardening, bypass
root-managed Git/shell startup, cross project-home boundaries, or dodge the
socket proxy. Keep the protected-key list and host-security test aligned.

Every project-owned Dockerfile build is unsafe by definition, even when its
final `FROM` is aicontainer: build steps execute as root and can replace
helpers, policy, hooks, or the runtime user. It therefore requires exact-config
trust; checking only the base image is insufficient. Additional mounts on the
devcontainer are frictionless only at `/workspace/**` (excluding `.git` and
`.devcontainer`) or `/home/vscode/.cache/**`; other targets and any masking of
`/run`, `/etc`, `/usr`, `/bin`, `/sbin`, `/lib*`, or `/opt` are findings.

Normalization is never approval. Before replacing installation-specific
Compose values for comparison, prove managed build contexts resolve to
`.devcontainer/`, managed project bind sources resolve to this canonical
checkout, and per-project network/volume names retain the path-hashed Compose
name. Unmanaged Dev Container features/lifecycle hooks/environment and changes
to the main service command/entrypoint/healthcheck are pre-post-create code
execution surfaces and must fail or require explicit trust. Keep the matching
host tests; these checks close real validator bypasses.

**`chown-paths`** — companion to override-declared named volumes. Docker
inits a fresh named volume `root:root` and `updateRemoteUserUID` doesn't
change that, so e.g. a `myproject-venv:/workspace/.venv` mount lands
unwritable by `vscode`. The project lists such mountpoints one per line;
`post-create.py`'s `fix_volume_ownership()` re-owns them via
`aic-chown-volumes` on create. **The prefix allowlist (`/workspace/`,
`/home/vscode/.cache/`) is only the first boundary.** The privileged helper
uses a root-hidden raw socket to GET the current container/volume metadata and
requires an exact canonical mountpoint backed by an option-free `local`
named volume. It rejects host binds, nested non-volume mounts, symlinks,
custom/external drivers, and `local type=none,o=bind` aliases before `chown
-h -R`. Keep `DAC_READ_SEARCH`: without it root cannot recurse through an old
UID's `0700` tree; `vscode` itself still receives no capabilities. Guarded by
`tests/test-aic-chown-volume-validation.sh` and the workflow runtime smoke.

**`post-create.project.sh`** — project extension point for `post-create.py`.
`run_project_hook()` runs it **last** in `main()` (via `bash <file>`, cwd
`/workspace`, as `vscode`), so a project's `lefthook install`/`npm ci` sees a
fully wired environment. It's the only way to extend post-create in pull
mode, where `post-create.py` is baked into the image (`apply_template()`
copies it only in `--build` mode). Lower-stakes than it looks: it runs
unprivileged, and the PreToolUse hook keeps `.devcontainer/`
host-only-editable. Non-zero exit is logged, not fatal — keep that; a flaky
project step shouldn't block the devcontainer from coming up.

**`vscode-extensions` / `vscode-settings.json`** — sync-safe per-project
editor customization (`apply_template()` rewrites `customizations.vscode`
wholesale every sync). `patch_devcontainer_json()` merges them at two JSONC
marker comments in `template/devcontainer.json` (`// aic:vscode-extensions`
in the extensions array, `// aic:vscode-settings` in the settings object) —
`build_vscode_ext_block`/`build_vscode_settings_block` emit leading-comma
blocks so the result is valid JSON however the template array/object ends (a
JSONC trailing comma is tolerated). Load-bearing, don't undo:

1. **Keep the markers** — they're the injection anchors; removing them
   silently drops the merge.
2. The merge re-reads from the pristine template every run, so it's
   idempotent across syncs — don't "optimize" it into editing in place.
3. Extension lines are validated against the `publisher.name` grammar and
   warn+skipped otherwise. Settings must be strict JSON and a non-array object;
   Node parses + serializes them so user text is never spliced into JSONC. Keep
   both validations: these files are host-side control input.
4. On a key collision, aic's own settings win inside `devcontainer.json`:
   `build_vscode_settings_block()` derives managed keys from the pristine
   template and warns+drops collisions before serialization. The documented
   escape hatch is the user's
   `.vscode/settings.json`, which beats devcontainer machine-scope settings.
   Don't reverse this precedence without updating the README and threat model.

Guarded by the "aic sync merges project-owned vscode-extensions /
vscode-settings.json" test.

**Personal config overlay** (`shell-rc.zsh`, `p10k.zsh`) — lets the trusted
human bring a familiar zsh prompt/aliases into the sandbox. Two sources feed
one overlay, project file winning: a project-owned `.devcontainer/shell-rc.zsh`
/ `.devcontainer/p10k.zsh`, and the opt-in host seed `~/.config/aicontainer/{rc,
p10k}.zsh` routed **verbatim** through `aic-seed-sanitizer` (the only place a
raw host file is allowed; never mounted into main). `setup_personal_shell()`
stages the winner; `aic-lock-user-config` installs it `root:root 0444` under
`/etc/aic/user-config/shell/`; the baked `.zshrc` sources `p10k.zsh` then
`rc.zsh` **after** the managed baseline, so a personal prompt wins while the
managed history/fnm/PATH setup still runs first. Load-bearing, don't undo:

1. **It is code, not data — it cannot be sanitized.** The bytes cross verbatim
   into a sandbox the agent can read, so it is opt-in (by file presence) and
   documented as "no secrets in these files." Never try to allowlist-"sanitize"
   zsh; never widen this to auto-vacuum arbitrary host dotfiles (`~/.zshrc`,
   `~/.p10k.zsh`) — only the aic-namespaced seed dir and the project files.
2. **Root-locked, not a privilege grant.** It lands `root:root 0444` + create-
   once so an agent can't tamper with it (preserving the "shell startup is
   root-managed" guarantee), but its contents still execute only as `vscode`
   when sourced — the same authority the agent already has, and the same risk
   class as the already-accepted `post-create.project.sh`. Keep the install on
   the shared `aic-lock-user-config` path; don't add a writable-in-`$HOME` rc.
3. **zsh only.** p10k and the `source` lines live in the managed `.zshrc`;
   bash/fish keep the managed baseline unchanged. Don't source zsh syntax from
   the bash/fish startup files.
4. The files are control-boundary paths (in `AIC_CONTROL_FILES`): real files,
   never symlinks. Keep them out of `apply_template()`'s copy/rewrite/remove
   lists so sync never clobbers them.

Guarded by the personal-shell-overlay assertions in the host-security test (and
the runtime shell-lock smoke).

**AI-tool refresh on every create.** `refresh_ai_tools()` runs early in
`main()` and floats Claude Code + Codex + OpenCode to latest on every
container (re)create, so a plain `aic rebuild` lands current CLIs without a
new image. The Dockerfile bakes each as an offline *floor*; updates run via
`claude update`, Codex's official `install.sh` with
`CODEX_NON_INTERACTIVE=1`, and `opencode upgrade`. `AIC_TOOLS`-gated,
fail-soft (an offline/failed update keeps the baked version — don't make it
fatal), opt-out via `AIC_FREEZE_TOOLS=1` for a reproducible sandbox. Codex's
installer is downloaded completely before execution, HTTPS-only and bounded;
keep `CODEX_HOME` on its separate rootfs package cache and
`CODEX_INSTALL_DIR=~/.local/bin` so project state remains isolated and no shell
startup file is edited. OpenCode installs with `--no-modify-path` and upgrades
in place, never touching rc files. Guarded by the "tool self-update works with
rc files root-locked" test.

**Dockerfile.project base-tag drift.** `aic sync` re-pins
`docker-compose.yml` but never touches a `FROM
ghcr.io/stefanoginella/aicontainer:vX.Y.Z` inside project-owned
`Dockerfile.project` — and when an override's `build:` points at it, that
stale `FROM` is what actually runs (the compose `image:` pin is bypassed).
`check_dockerfile_project_base()` (end of `cmd_sync`) warns on the drift;
`aic sync --bump-base` rewrites the tag. It acts only on a literal version
pin — `:latest`, `ARG`-templated bases, and other repos are deliberately left
alone. Keep the warn/opt-in split: silently editing a project-owned file
would break the ownership contract above. Guarded by the "aic sync warns on /
bumps a stale Dockerfile.project base" test.

**Docker daemon exposure has three modes.** Both templates default to `none`:
`PING/VERSION=1`, all object reads and `POST/BUILD=0`. `--docker-read` selects
`ro` (six object list/inspect groups on, writes off); `--docker` selects `rw`
(reads plus writes); `--no-docker` returns to `none`. Read APIs are not benign:
container inspect/log/archive endpoints can expose unrelated host workloads.

The mode is encoded in Compose and preserved across sync, but `ro`/`rw` also
need matching host consent under `$XDG_STATE_HOME/aicontainer/docker-write`.
Repository edits therefore cannot opt themselves in. Keep all toggles coherent
in `read_compose_docker_mode()`/`apply_docker_mode()` and the structural
normalizer; malformed sets reset/fail safe. `--no-docker` revokes stale
consent. Unless the user passes an explicit Docker flag (or matching consent
already exists), sync must reset any inherited `ro`/`rw` mode to `none`; this
keeps ordinary legacy upgrades and checkouts on a new host prompt-free without
trusting the repository value. The boundary summary, help,
completions, tests, README, and both
templates must change together. The socket-proxy image itself is pinned to a
verified multi-architecture digest because it holds the raw host socket.

**Always-on metadata block.** `block_metadata()` runs on every create and adds
unconditional, never-flushed drops for `169.254.0.0/16`,
`100.100.100.200/32`, `fe80::/10`, and `fd00:ec2::254`. It is independent of
the opt-in full allowlist and strengthen-only. The full `enable` path builds
inactive A/B IPv4/IPv6 chains/ipsets, rejects prohibited or zero-IP DNS
results, then swaps one jump; never set policy ACCEPT or flush a live/
metadata chain. If IPv6 exists but cannot be filtered, fail rather than expose
an IPv6 bypass. A write-enabled sibling has another netns and is not covered.

**Runaway limit.** Both compose templates set `pids_limit: 4096` on the
devcontainer (fork-bomb / stuck-loop backstop). Deliberately *not* a
`mem_limit` — a fixed memory ceiling would OOM-kill legitimate heavy builds;
memory/CPU caps are documented as an override instead. The Docker-mode test
also asserts `pids_limit` is present.

## Releasing

README's "Releasing" section has the user-visible flow. **When asked to cut a
release, do exactly this:**

1. Clean, current `main`: `git checkout main && git pull`; working tree
   clean.
2. Ensure this release's notes are under `## [Unreleased]` in CHANGELOG.md
   (they should already be there, added as changes landed). If empty/stale,
   write them **by hand** from `git log <last-tag>..HEAD` under
   Keep-a-Changelog headings, and commit. Don't rename the heading or add a
   date — `npm version` does that. Never auto-generate the prose from commits
   (tried, reverted, disliked).
3. Pick the bump (patch/minor/major) per README's "Picking the bump".
4. If `template/` changed since the last release, sync the dogfood
   devcontainer: run `aic sync` **from the host** (never in-container — the
   PreToolUse hook blocks `.devcontainer/` writes) and commit the result. The
   dogfood is build-mode, so `.devcontainer/` holds copies of `template/`;
   skipping this leaves it drifted.
5. `npm version <bump> && git push --follow-tags`.

> **Gotcha — `ignore-scripts=true` silently skips changelog promotion.** The
> sandbox image sets `npm config set ignore-scripts true` (hardening), which
> also suppresses `npm version`'s `preversion`/`version` hooks — the bump
> commit then ships without a `## [X.Y.Z]` section and fails the pre-push and
> CI gates. Check `npm config get ignore-scripts`; if `true`, use `npm
> version <bump> --ignore-scripts=false` for that one command (don't flip the
> global config — it weakens the image default). If a plain `npm version`
> already ran and the bump commit is still **local**: run `node
> scripts/promote-changelog.mjs` by hand, `git commit --amend` to fold in the
> promoted CHANGELOG, `git tag -f -a vX.Y.Z -m X.Y.Z`, then push.

The two lifecycle scripts (unless suppressed — see gotcha):

- `preversion` → `promote-changelog.mjs --check`: aborts the bump before
  package.json is touched if `[Unreleased]` is empty — you can't release
  nothing, and a failed attempt leaves the tree clean.
- `version` → `promote-changelog.mjs`: renames `[Unreleased]` to `## [X.Y.Z]
  - <date>`, opens a fresh `[Unreleased]`, fixes the compare links, and `git
  add`s CHANGELOG.md into the bump commit.

`release.yml` then fires on the tag: it ensures immutable GHCR `:vX.Y.Z` and
npm artifacts exist, conservatively promotes mutable channels, and creates the
GitHub Release from the tag's `## [X.Y.Z]` section.

Internal notes:

- `rebuild.yml` validates changes to template, CLI, tests, package metadata,
  and lifecycle scripts. Its publish-capable main/schedule/manual runs share a
  cancel-in-progress group; PR validation is ref-scoped. Before mutable-tag
  publication it proves the template matches current default-branch HEAD.
  Scheduled/manual builds use `pull: true` + `no-cache: true`; a security
  refresh must not quietly reuse a stale apt/tool layer.
- Every release shares one global `aicontainer-release` concurrency group,
  `cancel-in-progress: false`, `queue: max`. Never serialize per tag or cancel
  a partial publisher; up to 100 pending runs may queue and each run is
  restartable.
- Keep the workflow-level release and security-refresh concurrency groups
  distinct: their cancellation semantics differ. Their GHCR-mutating `publish`
  jobs additionally share the job-level `aicontainer-registry-publish` lock
  with `cancel-in-progress: false` and `queue: max`; this serializes the
  inspect/build/promote critical section across both workflows and closes the
  mutable-tag TOCTOU race.
- A release tag commit must be an ancestor of the default branch and its name
  must match `package.json`. Existing GHCR version indexes are accepted only
  when their revision/version/channel annotations identify this release;
  mismatches fail. A legacy unannotated version is preserved only when the
  matching immutable npm tarball exists and is never promoted to `:latest`.
  Existing npm versions are accepted only when their integrity matches the
  local pack. If either artifact is absent, publish only the missing side so a
  partial run can recover.
- npm pre-releases use `next`; an older recovered version uses a
  version-specific `recovery-*` dist-tag instead of rolling `latest` back.
  GHCR `:latest` is copied from the immutable manifest only when that version
  is npm latest and the current GHCR latest is not a newer security-refresh
  image. If recency cannot be proven, leave it alone.
- Don't run `npm publish` locally — CI uses `--provenance`; a manual publish
  skips the supply-chain attestation users can verify.
- CHANGELOG content is hand-written, never generated;
  `promote-changelog.mjs` only relabels it. The CI gate (`release.yml`
  "Verify CHANGELOG.md has an entry") greps for `^## [X.Y.Z]` before any
  publish; `.githooks/pre-push` mirrors it locally (opt-in, bypassable — CI
  is the real gate; don't weaken that step). The hook materializes `git show`
  before `grep -q`: a producer pipeline under `pipefail` falsely rejects a
  large valid changelog when the early match gives `git show` SIGPIPE. Keep the
  `## [X.Y.Z]` heading format: the gate, the promotion script, and the
  release-notes extraction all key on it.
- The GitHub Release is automatic after publish, idempotent, and marked latest
  only when npm says the version is latest. It falls back to generated notes.
  Only that job has `contents: write`; only publish has `packages: write` and
  OIDC `id-token: write`. Every checkout uses `persist-credentials: false`.

## CHANGELOG entry style

`[Unreleased]` bullets are written to be skimmed:

- One change = one bullet under one heading. Never bundle.
- Bold headline first, ≤ ~12 words, stating the user-visible effect, not the
  internal mechanism.
- At most ~2 sentences of detail after the headline. No debugging narrative —
  the *how* lives in this file, the README, and the commit body.
- No inline file-touch lists; at most one terse trailing parenthetical
  (`(aic, post-create.py)`).
- Released `## [X.Y.Z]` sections are immutable — never rewrite a shipped
  section (the GitHub Release renders from it).

## Workflow split rationale (so future edits don't undo it)

The npm CLI is tightly coupled to the container's filesystem (hooks, sudoers,
helper-script paths); floating `:latest` would let CLI and image drift. The
two tracks serve different audiences:

- `:vX.Y.Z` (immutable, `release.yml`) — what `aic init` pins. Users on a
  given aic version always pull the exact image built at release time.
- `:latest` (floating, `rebuild.yml` weekly cron + relevant runtime/CLI pushes)
  — base-layer security freshness over reproducibility. Not referenced by
  managed `aic init` output; release promotion must not overwrite a newer
  security-refresh image.

Before "simplifying" the two workflows into one or re-pointing `aic init` at
`:latest`, re-read this tradeoff. Supabase CLI and Dagger use the same pinned
model; Earthly's floating-with-coupling is the documented anti-pattern.

## Don't do

- **Don't weaken smoke/CLI tests** in either workflow. They cover real
  security guarantees: object-read toggles plus `POST/BUILD=0` (Docker default
  `none`), external read/write consent, resolved-config validation, path-unique
  identity/migration, metadata drops on IPv4+IPv6, the `.env` guardrail,
  sanitized seeds/auth sync, scoped volume ownership, the root-managed Git and
  shell files, dropped capabilities, and the npm-quarantine sanity check
  (`NPM_CONFIG_MIN_RELEASE_AGE` ≤ 30 days so npx-based MCPs stay installable).
  If a test fails legitimately, fix the regression, not the assertion.
- **Don't put untrusted GitHub event fields in `run:` blocks** (issue/PR
  titles, commit messages, branch refs) — route through `env:` with proper
  quoting, as both workflows already do. See the GitHub Security Lab guide on
  workflow injection.
- **Don't add files to `template/`** the user shouldn't get a copy of —
  everything there is copied into every project's `.devcontainer/`.
- **Don't edit `.devcontainer/` from inside the container.** The PreToolUse
  hook blocks it — part of the sandbox boundary (an AI that can rewrite its
  own devcontainer config can disable every other protection). Edit
  `template/` instead; users pick it up via `aic sync`, and the dogfood
  `.devcontainer/` regenerates the same way.
- **Don't bump `package.json` in a feature PR.** Version bumps are their own
  `npm version` commit so the tag points at a clean release commit.
- **Don't land a user-facing change without a CHANGELOG note** — a bullet
  under `## [Unreleased]`, right Keep-a-Changelog heading, in the *same*
  commit/PR. Keeping `[Unreleased]` current makes release time just "rename
  the heading," and CI blocks a release with no section.
- **Don't force-push `main` or rewrite tags.** GHCR already has whatever the
  tag was bound to; ghost tags confuse users on pinned versions.
- **Don't use `git rebase -i`** or other interactive git commands from a
  non-interactive environment — they hang silently.

## Security stance

This container sandboxes autonomous AI tools running in bypass-permissions /
sandbox-off mode. README's "Threat model" section is the source of truth.
When choosing between two implementations, prefer the more restrictive one.
Review any change to these files for security regressions:

- `template/Dockerfile` — sudoers, USER, and capability bits; a new
  `NOPASSWD` entry is a load-bearing decision. Also bakes
  Claude/OpenCode system-managed policy, `/etc/codex/requirements.toml`, the
  managed hook directory, root-managed Git/shell destinations, neutral tool
  home symlinks, and hash-pinned offline Python support. Codex and OpenCode install via
  their standalone installers (`chatgpt.com/codex/install.sh`;
  `opencode.ai/install` with `--no-modify-path` into `~/.opencode/bin`), not
  npm — deliberate, so self-update works — at the cost of leaving them
  outside the `NPM_CONFIG_MIN_RELEASE_AGE` quarantine (which still covers npx
  MCPs). All three CLIs are a baked floor that `refresh_ai_tools()` floats to
  latest on each create.
- `template/aic-firewall` — outbound allowlist plus unconditional metadata
  chains. New hosts expand reachability. A/B IPv4 and IPv6 generations are
  built while the active DROP generation remains live, then switched with one
  jump replacement. Prohibited metadata/link-local resolutions and a zero-IP
  result abort without changing active policy. Never flush a live/metadata
  chain, set policy ACCEPT, or silently ignore unfilterable configured IPv6.
- `template/hooks/pre-tool-use.sh` — blocks reads of `.env` and other
  sensitive paths. Loosening the matchers (`is_blocked_env`,
  `bash_touches_env`, `is_curl_pipe_sh`, `is_protected_path`, or the
  `Bash|Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Glob` matcher in
  `claude-settings.json`) weakens the model. Shared by all three tools:
  Claude receives it through root-managed
  `/etc/claude-code/managed-settings.json`; Codex through
  `/etc/codex/requirements.toml` + its `managed_dir`. Hooks in a user Codex
  config are non-managed → untrusted → skipped in autonomous mode; don't move
  it there.
- `template/hooks/opencode-guardrail.js` — OpenCode's slice of that same
  guardrail: a dependency-free plugin whose `tool.execute.before` maps
  OpenCode's `{tool, args}` to the JSON `pre-tool-use.sh` reads on stdin,
  `spawnSync`s it, and `throw`s on exit 2. Root-managed
  `/etc/opencode/opencode.json` wires it by absolute path — no trust prompt,
  and it fires even with `permission."*"=allow`. Keep the logic in `pre-tool-use.sh`
  (single source of truth); the shim only maps + dispatches. Don't add a
  second native `permission` deny that could diverge. Guarded by the
  "opencode guardrail blocks a .env read" test.
- `template/aic-chown-volumes`, `template/aic-lock-user-config` — the only
  non-firewall scripts allowed via `NOPASSWD`; both use privileged/interpreter
  modes, fixed PATH/env, umask, and hardcoded inputs/destinations.
  `aic-chown-volumes` never accepts target argv. Besides the path prefix, it
  verifies canonical exact mountpoints against the current container through
  `/run/aic-host/docker.sock`, uses GET only with curl config/proxies disabled,
  and accepts only option-free local named volumes before `chown -h -R`.
  `aic-lock-user-config` runs `/usr/bin/python3 -I` and installs a fixed
  `TARGETS` table, never argv: it opens each `vscode`-owned staging inode
  without following links and atomically creates (never replaces) a
  `root:root 0444` destination under `/etc/aic/user-config/`. The **required**
  `gitconfig` target is parsed with Git `--no-includes` under a minimal env and
  allows only fixed safe keys/exact aic values. The **optional** personal-shell
  targets (`shell/rc.zsh`, `shell/p10k.zsh`) are installed **without** content
  validation — zsh can't be allowlisted — which is safe only because the bytes
  come from the trusted human staged before any agent runs, the file lands
  root-locked so an agent can't tamper with it, and its contents still execute
  only as `vscode`. Do not add a content-bearing target without a validator
  unless all three hold, and do not turn either helper into a general
  copy/chown/config installer. Guarded by the dedicated tests plus runtime
  smoke. See "Personal config overlay".
- `.github/workflows/*.yml` — GHCR uses job-scoped `GITHUB_TOKEN` package
  permission; npm uses OIDC trusted publishing + provenance, not a long-lived
  npm token. Publishing jobs run only on push/schedule/dispatch, never PR;
  checkout credentials are never persisted.

## Commit signing (`aic signing`)

The host signing key is never forwarded (the no-`~/.ssh`/no-agent guarantee),
so `aic signing` provisions a *sandbox-only* ed25519 key in the
`aic-auth-global` volume under `~/.config/aic-auth/signing/` (key + a `mode`
marker: `auto`/`byok`/`disabled`). Load-bearing choices, don't undo them:

- Signing config is appended to the fixed staging config *after* sanitized host
  signing intent, then validated/installed at
  `/etc/aic/user-config/gitconfig`. It may use only the hardcoded sandbox key
  and allowed-signers paths; host key paths/includes never enter the config.
- Applied on (re)create only, never live: the root-managed destination is
  created once and cannot be replaced in that container. A mode change lands
  on the next `aic rebuild`; do not add an unlock/update primitive.
- The mutating actions are unprivileged: `devcontainer exec` as `vscode`
  (container must be up; no sudoers entry). Generating the key in-container
  is what keeps owner + 0600 correct across the Linux UID-remap. `status`
  reads the volume host-side and works anytime.
- `--register` writes to the user's GitHub account (`gh api POST
  /user/ssh_signing_keys`) — opt-in only, never auto-register.
- Guarded by the signing smoke, which stages a key, recreates, and asserts
  signing is wired and `/etc/aic/user-config/gitconfig` is still `root 444`.

## Verifying changes locally

The CI smoke tests run inside a real devcontainer. Approximate that locally
to avoid pushing broken changes:

```bash
for test in tests/*.sh; do bash "$test"; done
for test in tests/*.py; do PYTHONDONTWRITEBYTECODE=1 python3 -I "$test"; done
```

Then exercise the real container path:

```bash
mkdir -p /tmp/aic-test && cd /tmp/aic-test
git init -q
AIC_HOME=/path/to/aicontainer-checkout /path/to/aicontainer-checkout/aic init --build
AIC_HOME=/path/to/aicontainer-checkout /path/to/aicontainer-checkout/aic up
devcontainer exec --workspace-folder . claude --version
devcontainer exec --workspace-folder . curl -fsS http://socket-proxy:2375/_ping
# npm quarantine sanity (must be ≤ 30 days or npx-based MCPs fail to install)
devcontainer exec --workspace-folder . bash -lc 'echo "$NPM_CONFIG_MIN_RELEASE_AGE"'
```

For CLI-only changes, `aic init` against a temp directory is usually enough:

```bash
TMP=$(mktemp -d) && cd "$TMP" && git init -q
AIC_HOME=/path/to/aicontainer-checkout /path/to/aicontainer-checkout/aic init
grep "image:" .devcontainer/docker-compose.yml   # should show :vX.Y.Z, not :latest
```

## Quick reference

| Want to                                       | Do                                                           |
| ---                                           | ---                                                          |
| Land a fix/feature                            | merge PR to `main`                                           |
| Cut a release                                 | `npm version patch && git push --follow-tags`                |
| Hotfix a bad release                          | another patch (revert or fix-forward); old `:vX.Y.Z` stays   |
| Manually refresh `:latest`                    | `gh workflow run rebuild.yml`                                |
| Manually re-run a release                     | `gh workflow run release.yml --ref refs/tags/vX.Y.Z`         |
| Pin downstream users to an older version      | (they do) `npm i -g aicontainer@<old> && aic sync && aic rebuild` |
