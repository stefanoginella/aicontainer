# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> Maintainers: add notes under **[Unreleased]** as you go. At release time,
> rename that heading to the new version with today's date and add a compare
> link at the bottom. A release is **blocked** unless this file has a matching
> `## [X.Y.Z]` section — see AGENTS.md → "Releasing". Entry style lives in
> AGENTS.md → "CHANGELOG entry style".

## [Unreleased]

### Added

- **Local rootless Docker contexts work without extra flags.** aic discovers
  the selected Unix socket and regenerates a gitignored host-only environment
  file, while remote Docker contexts still fail closed.
- **Host readiness can be checked before startup.** `aic doctor` reports
  prerequisites and project wiring as concise `OK`/`WARN`/`FAIL` results.
- **Project state is visible without mutation.** `aic status` summarizes the
  project identity, modes, image/runtime, credential-bridge health, and
  managed volumes.
- **Resolved validation is available for CI.** `aic validate` applies the full
  gate noninteractively without prompting or recording trust.
- **aic startup validates resolved project config before handoff.** CLI starts
  check managed files plus the fully merged Compose model; the generated VS
  Code initializer repeats the gate before Compose creation.
- **Reviewed host access can be trusted without repository state.** `aic trust`
  records approval for the exact relevant config hash outside the checkout;
  changes automatically invalidate it.
- **Unsafe access can be approved for one run.** `--allow-unsafe` carries an
  exact configuration hash through `up`/`rebuild` without persisting approval;
  unbounded build contexts require this per-run review.
- **Docker inspection is now a separate opt-in mode.** `--docker-read` enables
  host object list/inspect APIs without writes, while `--docker` remains the
  explicit read-write choice and `--no-docker` revokes either.
- **Shell completions cover every aic command.** `aic completion` emits
  ready-to-install Bash, Zsh, or fish completions for commands and flags.

### Changed

- **Docker object access is off by default.** The proxy exposes only ping and
  version until the host user explicitly consents, hiding unrelated container,
  image, network, volume, log, and file metadata.
- **Projects receive path-unique runtime identities.** Compose resources and
  session volumes include a canonical-path hash; existing transcript data is
  migrated automatically without another login.
- **The shared session root has a tool-neutral name.** Container state now lives
  below `~/.aic-sessions`; legacy `.claude-sessions` data is carried forward.
- **Host preferences pass through an isolated sanitizer.** A fixed networkless
  service sees the raw Git/tool files and gives the agent only root-owned,
  allowlisted JSON output.
- **Tool homes are isolated while logins remain reusable.** Credentials sync
  through a fixed networkless helper, while config, instructions, plugins,
  prompt history, and transcripts stay in each project's volume.
- **Git config is installed behind a root boundary.** Only fixed safe host
  preferences survive parsing, and the validated result is created once as
  `root:root 0444` with executable/path-bearing keys refused.
- **Shell startup ignores writable home profiles.** Zsh, Bash, and fish launch
  from root-managed system config, preventing next-session persistence without
  importing host rc code.
- **AI safety policy uses managed system precedence.** Claude, Codex, and
  OpenCode autonomous settings plus the shared guardrail cannot be disabled by
  user-level tool config.
- **Container creation no longer resolves Python dependencies.** Post-create,
  seed sanitization, and credential sync use system Python plus a hash-pinned
  baked TOML writer, improving offline startup and removing a pre-policy fetch.
- **Weekly images refresh their base layers reliably.** Scheduled/manual image
  builds pull current bases and bypass stale caches while pinned release tags
  remain reproducible.
- **Package metadata now names all supported agents.** The npm description and
  keywords include OpenCode.
- **Packed artifacts exclude development debris.** Python caches/bytecode and
  operating-system metadata no longer enter the npm tarball.

### Fixed

- **Sync does not inherit unconsented Docker access.** Repository-only proxy
  modes reset to `none`; users who need Docker opt in once and record host
  consent explicitly.
- **VS Code selects a compatible host CLI.** Direct editor starts skip old
  aic installs that lack managed initialization, scan every supported
  Node-manager fallback, and print an actionable upgrade command when needed.
- **Same-named checkouts no longer share containers or transcripts.** Legacy
  cleanup requires an exact owned primary, permits only fixed unlabeled
  sidecars, and never removes arbitrary orphans. Transcript import verifies the
  actual session mount and absence of a conflicting owner; ambiguity is
  preserved rather than guessed.
- **Symlinked control paths are rejected.** Host-side init/sync refuses links or
  special files at managed and project-owned control inputs instead of
  following them outside the repository.
- **Managed template replacement is atomic.** Files and hooks are staged beside
  their destination before rename.
- **Mode switches remove stale managed artifacts.** Switching to pull mode
  removes every build-only file so later syncs cannot flip modes accidentally.
- **VS Code settings cannot escape their merge point.** Project settings are
  parsed and re-serialized as strict JSON; invalid input and managed-key
  collisions are warned and skipped.
- **Non-interactive destroy requires explicit confirmation.** `aic destroy`
  now needs `--yes` when no terminal is present instead of treating closed
  input as permission to delete history.
- **Release retries preserve immutable artifacts.** Reruns reuse verified
  version images and matching npm publications, advancing `:latest` only from
  the current npm release to prevent accidental overwrite or rollback.
- **Legacy image recovery cannot widen an unknown artifact.** Unannotated GHCR
  versions require a matching immutable npm tarball and are never promoted to
  `:latest`.

### Security

- **Seeded config no longer carries literal credentials.** Inline provider and
  MCP environment/header secrets are stripped recursively across Claude,
  Codex, and OpenCode.
- **Cross-project prompt persistence is blocked.** Auto-loaded memory, skills,
  commands, rules, prompts, plugins, histories, and transcripts are scoped to
  the path-unique project rather than the reusable credential store.
- **Privileged volume ownership verifies daemon metadata.** The fixed helper
  accepts only canonical mountpoints backed by ordinary option-free Docker
  named volumes and rejects binds, symlinks, nesting, and custom drivers.
- **The runtime drops unnecessary Linux capabilities.** The devcontainer starts
  from `cap_drop: ALL`; `NET_RAW` remains absent and only fixed helper/firewall
  capabilities return.
- **Raw Docker access is hidden from the agent.** The fixed helper socket sits
  behind a root-only directory that `vscode` cannot traverse.
- **The Docker proxy image is digest-pinned.** Its verified multi-architecture
  digest prevents a mutable dependency from replacing the raw-socket holder.
- **Metadata blocking covers IPv4 and IPv6 providers.** Always-on drops include
  IPv4/IPv6 link-local plus AWS and Alibaba metadata endpoints, independent of
  the optional full allowlist.
- **Firewall refreshes stay fail-closed.** IPv4/IPv6 rules are built off-path
  and switched atomically; failed or prohibited DNS resolution leaves the
  active restrictive policy untouched.
- **CI publishing uses narrower credentials.** Checkout credentials are not
  persisted and package-write permission exists only in the publishing job.
- **Registry publication is serialized across workflows.** Release and
  security-refresh GHCR jobs share a non-cancelling lock, closing mutable-tag
  check-then-publish races without changing their workflow cancellation rules.
- **Managed path normalization cannot hide host aliases.** Build contexts,
  workspace/control binds, project volumes, and networks are verified against
  the canonical checkout before installation-specific paths are normalized.
- **Unmanaged Dev Container startup hooks are rejected.** Features and
  lifecycle commands fail validation before aic hands configuration off.
- **Compose startup behavior cannot be replaced silently.** Command,
  entrypoint, healthcheck, and related service changes require review.
- **Managed Python ignores environment module injection.** Post-create,
  sanitization, and credential sync run isolated from `PYTHONPATH`/`PYTHONHOME`.
- **Host variables cannot be forwarded silently.** Active Compose interpolation
  or bare environment/build-arg pass-through requires exact-config trust without
  exposing the resolved value; literals and escaped templates remain prompt-free.
- **Managed startup environment cannot be shadowed silently.** Overrides of
  tool homes, shell/Git startup, loader paths, or the Docker proxy endpoint now
  require explicit review before creation.
- **Validation output cannot inject terminal controls.** Repository-controlled
  names, paths, and values are rendered safely in host-side findings.

## [0.5.0] - 2026-07-06

### Changed

- **Docker socket write access is now off by default.** The bundled
  socket-proxy ships read-only (`POST`/`BUILD` blocked), so an in-container
  agent can no longer `docker run --privileged -v /:/host` to escape or spawn
  firewall-dodging sibling containers. Opt in per project with `aic init
  --docker` (or `aic sync --docker`); `--no-docker` reverts.

### Added

- **Cloud metadata / link-local egress is blocked on every container create.**
  `post-create` drops `169.254.0.0/16` (including the `169.254.169.254` cloud
  metadata endpoint) via `aic-firewall block-metadata`, independent of the
  opt-in allowlist — closing the cloud-credential-theft path by default.
- **`aic up` / `aic rebuild` scan project-owned override files before starting.**
  Flags host-access grants (`privileged`, `cap_add`, host mounts, the Docker
  socket, a non-aicontainer `Dockerfile.project` base) that ride along in an
  untrusted repo; prompts on a TTY. Silence with `AIC_NO_OVERRIDE_SCAN=1`.
- **The devcontainer runs with `pids_limit: 4096`.** A fork-bomb / runaway-agent
  backstop so it can't exhaust host PIDs; raise it (or add `mem_limit` / `cpus`)
  in `docker-compose.override.yml`.
- **`aic preflight` reports the Docker socket state.** The trust-boundary
  summary now shows whether the socket-proxy is read-only or read-write and
  notes the always-on metadata block.

## [0.4.3] - 2026-06-30

### Changed

- **Devcontainer name flipped back to the `<folder>-aicontainer` suffix.** Was
  `aicontainer-<folder>`; leads each label with the project name so it reads
  first in VS Code's remote indicator. Re-derived on every `aic init`/`aic sync`
  and not hand-editable.

## [0.4.2] - 2026-06-09

### Added

- **Starting the container from VS Code now runs the image/CLI drift check too.**
  "Reopen/Rebuild in Container" drives `devcontainer up` directly (never the
  `aic` CLI), so the warning previously only appeared on `aic up`/`shell`/`rebuild`;
  it's now wired into the devcontainer's `initializeCommand` and logged to the
  Dev Containers output channel. Best-effort and never blocks the container from
  starting.

## [0.4.1] - 2026-06-09

### Added

- **`aic up` / `aic shell` / `aic rebuild` warn when the pinned image lags your `aic`.**
  An offline check compares the `:vX.Y.Z` pinned in `docker-compose.yml` against
  the installed CLI and points at `aic sync && aic rebuild` to reconcile; on
  `rebuild` it fires before the pull, so you can abort and re-pin first.
  (Build-mode projects have no pin and are not checked.)
- **`aic version` / `aic upgrade` flag a newer published `aicontainer`.** Queried
  from npm (the upgrade source of truth), cached for 24h, fail-silent, and
  skipped in CI. Silence both notifications with `AIC_NO_UPDATE_CHECK=1`.

## [0.4.0] - 2026-06-09

### Added

- **OpenCode joins Claude Code and Codex as a first-class tool.** Baked into the
  image and auto-updated on every `aic rebuild`, with persistent login,
  per-project transcripts, and the shared `.env`/`curl|sh` guardrail wired in as
  an OpenCode plugin. Host `~/.config/opencode/opencode.json` provider/model
  definitions are seeded read-only (inline API keys stripped — log in inside with
  `opencode auth login`); it's on by default, or choose it with
  `aic init --with …,opencode`. (aic, template/)

## [0.3.1] - 2026-06-09

### Changed

- **Refreshed bundled tools and base image.** uv 0.11, fzf 0.73.1, and
  git-delta 0.19.2, plus a current Ubuntu 24.04 base-image digest.
  (template/Dockerfile)

## [0.3.0] - 2026-06-03

### Added

- **Per-project VS Code extensions survive `aic sync`.** A project-owned
  `.devcontainer/vscode-extensions` (one `publisher.name` id per line) is merged
  into `customizations.vscode.extensions` on every init/sync; invalid lines are
  warned about and skipped. (aic, template/devcontainer.json)
- **Per-project VS Code settings survive `aic sync`.** A project-owned
  `.devcontainer/vscode-settings.json` object is merged into
  `customizations.vscode.settings`. README adds Python and TypeScript editor +
  agent-LSP recipes. (aic, README.md)
- **`.devcontainer/README.md` explains what to edit and what not to.** Shipped
  into every project (both modes) to steer humans and AI agents away from
  hand-editing the sync-overwritten `devcontainer.json` toward the project-owned
  files. (template/README.md, aic)

## [0.2.3] - 2026-06-03

### Added

- **`post-create.py` warns loudly when no git identity is configured.** The
  sandbox inherits `user.name`/`user.email` from the read-only host
  `~/.gitconfig`; if that was empty/broken at build time, `git commit` failed
  mid-session with a cryptic "Author identity unknown" and couldn't be fixed
  from inside. Container creation now flags it last with the host-side fix.
  (post-create.py)

## [0.2.2] - 2026-06-01

### Added

- **Agents are told the read-only git internals are by design.** `post-create.py`
  writes a managed note into `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` so a
  tool stops burning tokens "fixing" the expected `git config … Device or resource
  busy` failure (and blocked `.git/hooks` installs). (post-create.py)

## [0.2.1] - 2026-06-01

### Changed

- **`aic rebuild` now refreshes Claude Code and Codex to the latest release.** The
  two CLIs self-update on every container create (both pull and build mode) via
  `post-create.py`; the pinned image only fixes the baseline. Fail-soft when
  offline; set `AIC_FREEZE_TOOLS=1` to keep the baked versions. (post-create.py)
- **Codex now installs via OpenAI's official standalone installer, not npm.**
  Mirrors Claude's native installer and enables `codex update`. Codex is no longer
  subject to the `NPM_CONFIG_MIN_RELEASE_AGE` npm quarantine (still in force for
  npx-based MCPs). (Dockerfile)

## [0.2.0] - 2026-05-31

### Added

- **`aic signing` sets up commit signing inside the sandbox.** Your host's
  signing key is never forwarded, so `aic signing auto` mints a sandbox-only
  SSH signing key (`--register` adds its pubkey to GitHub via `gh`), `byok`
  installs one you provide, and `disable` turns signing off. The choice persists
  in the `aic-auth-global` volume and applies on the next `aic rebuild`.

### Fixed

- **A signing host no longer hits failing commits inside the sandbox.** When the
  host signs commits but no sandbox key is configured, signing is turned off
  in-container with a notice — so `git commit` doesn't die with "Couldn't find
  key in agent"; run `aic signing` to enable real signing instead.

## [0.1.4] - 2026-05-30

### Fixed

- **`post-create.project.sh` no longer inherits a leaked `VIRTUAL_ENV`.** The
  env `uv run` activates for post-create itself (and its `PATH` entry) is
  stripped before the project hook runs, ending the `uv sync`/`uv run` mismatch
  warning.

## [0.1.3] - 2026-05-27

### Changed

- **`aic sync` now offers to fix a stale `Dockerfile.project` base
  interactively.** The drift warning prints in yellow and, on a TTY, prompts
  `[Y/n]` to bump the `FROM` tag in place; declining or running
  non-interactively leaves the file untouched and points at `aic sync
  --bump-base`.

## [0.1.2] - 2026-05-27

### Security

- **PreToolUse hook now also guards the `Grep` and `Glob` tools.** A `Grep` with
  `output_mode=content` aimed at `.env` could previously dump the file without
  the `.env` block firing, since the hook wasn't invoked for those tools.
- **`.env`-read detection in Bash now handles quotes and globs.** Treating quote
  and glob characters as filename boundaries closes bypasses like `cat ".env"`,
  `cat .env*`, and `cat *.env`.
- **`curl|sh` detection now catches wrappers, extra pipes, and substitutions.**
  It covers interposed wrappers (`| sudo bash`, `| xargs`), intermediate pipes
  (`| tee … | sh`), more shells (`dash`, `ash`, `ksh`), and command/process
  substitution (`bash -c "$(curl …)"`, `. <(curl …)`).
- **Login-shell rc files are now root-locked.** `~/.zshrc`, `~/.bashrc`, and the
  fish config shipped writable by `vscode`, letting a tool session plant a
  payload that runs on the next `aic shell`. They're now locked to `root:root
  0444` (their `.local` includes stay user-writable); pick up the change with
  `aic sync`, then rebuild.
- **The PreToolUse guardrail now actually runs for Codex.** It was wired in
  `~/.codex/config.toml` with the wrong schema and as a non-managed hook (left
  untrusted, skipped in autonomous mode); it's now a managed hook in
  `/etc/codex/requirements.toml` matching `Bash`, so the `.env`-read and
  `curl|sh` checks apply to Codex too.

### Changed

- **PreToolUse hook parses its event JSON in a single `jq` pass.** Replaces 2–3
  `jq` forks plus a `basename` fork on every tool call; no behavior change, with
  NUL-separated fields preserving multi-line command text.

### Fixed

- **`aic down`, `aic destroy`, and `aic preflight` now target the right Compose
  project.** `project_name()` produced `<folder>_` instead of the
  `<folder>_devcontainer` stack that `devcontainer up` creates, so `aic down`
  left the container running and `aic destroy` reported success while leaving it
  (and its transcript volume) intact.
- **`rebuild.yml` no longer skips compose-template changes.** Its `paths:`
  filter referenced a nonexistent `template/docker-compose.yml`, so edits to
  `docker-compose.{pull,build}.yml` never triggered the rebuild or PR smoke
  tests; it now globs `template/**`.
- **`sudo aic-firewall enable` no longer drops the firewall open while
  re-applying.** It used to flush rules to `policy ACCEPT` and re-resolve the
  allowlist wide-open (a transient 0-IP resolution left it fully open); it now
  resolves into a staging ipset and swaps it in without ever setting `policy
  ACCEPT`, so re-enabling can only strengthen, never weaken.

## [0.1.1] - 2026-05-26

### Fixed

- **No more spurious Compose volume warnings with multiple projects on one
  host.** The two host-global volumes are now declared `external: true` so
  Compose adopts them by name instead of claiming per-project ownership, and
  `initializeCommand` creates `aic-shell-history` (external volumes aren't
  auto-created). Existing volumes and their contents are reused — run `aic sync`
  to pick up the change.

## [0.1.0] - 2026-05-26

### Added

- **`aic preflight`: prints the project's trust boundary in one screen.** Shows
  what the agent can read (RW/RO mounts), what's blocked (`.env`, host
  credentials, SSH), where transcripts persist, and whether outbound network is
  open or firewalled (live-detected when running). The same read-only summary
  now prints at the end of `aic up` with a loud "full outbound by default"
  warning.

### Changed

- **`aic destroy` now confirms before deleting.** It prints the per-project
  session volume and its on-disk size, notes the removal is irreversible (`aic
  down` keeps history), and prompts `[y/N]`. Non-interactive callers still
  proceed; `--yes` / `-y` skips the prompt.
- **README: clearer boundary and session-survival docs.** Adds a "What crosses
  the boundary" at-a-glance table, an explicit session-survival guarantee in
  "Multi-project model", and a FAQ on how the sandbox relates to Claude Code's
  auto mode.

## [0.0.11] - 2026-05-25

### Changed

- **Devcontainer name flipped to the `aicontainer-<folder>` prefix.** Was
  `<folder>-aicontainer`; the prefix sorts all aicontainer devcontainers
  together in VS Code's remote indicator. Re-derived on every `aic init`/`aic
  sync` and not hand-editable.

## [0.0.10] - 2026-05-25

### Changed

- **README: explain Codex approval / `bwrap` prompts in the VS Code extension.**
  Two causes — the sidebar's built-in *Full access* preset (fix: pick **Custom
  (config.toml)**) and an upstream bug where review mode / sub-agents fall back
  to `workspace-write`
  ([openai/codex#15305](https://github.com/openai/codex/issues/15305)) — both
  safe to allow. Also warns against "fixing" bwrap by granting `SYS_ADMIN` /
  userns.

### Fixed

- **Claude `/resume` and Codex history now persist in every project, not just
  the first.** Session symlinks in the shared `aic-auth-global` volume pointed
  into a per-project target that `link()` failed to create after the first
  project, leaving a dangling symlink and unwritten transcripts. `link()` now
  creates the target whenever it's missing, healing existing containers on the
  next `aic rebuild`.
- **Claude's prompt history (up-arrow recall) is now scoped per project.** It
  lived in the shared `aic-auth-global` volume, and since every container's cwd
  is `/workspace`, recall bled across all aicontainer projects; it's now
  symlinked into the per-project `aic-sessions` volume.

## [0.0.9] - 2026-05-25

### Added

- **`aic sync --bump-base`: re-pin a stale `Dockerfile.project` base tag.** When
  `Dockerfile.project` pins an explicit `FROM …:vX.Y.Z`, it rewrites the tag to
  the installed aic version; plain `aic sync` now warns on the drift. Catches a
  `docker-compose.override.yml` `build:` block silently running a stale base
  after `npm update -g aicontainer`.

### Fixed

- **semgrep's login token now persists across rebuilds.** Pointing semgrep at
  `~/.config/aic-auth/semgrep/settings.yml` via `SEMGREP_SETTINGS_FILE` replaces
  a leaf-file symlink that semgrep's atomic-rename writes clobbered, which had
  left the token on the throwaway container rootfs.

## [0.0.8] - 2026-05-25

### Added

- **Project-owned `post-create.project.sh` hook.** Drop a script at
  `.devcontainer/post-create.project.sh` to run your own steps (`lefthook
  install`, `npm ci`, …) on every container creation. Runs last as `vscode` in
  `/workspace`, is opt-in by presence, survives `aic sync`, and a non-zero exit
  is logged without failing creation.

### Changed

- **Devcontainer named `<folder>-aicontainer` instead of static `aicontainer`.**
  Each project gets a distinct label in VS Code's remote indicator, re-derived
  on every run and not hand-editable.

### Fixed

- **`aic sync` now exits `0` on success.** It previously returned its last
  check's status, exiting `1` when a project had no
  `docker-compose.override.yml` despite a clean sync.

## [0.0.7] - 2026-05-25

### Added

- **Project-owned `chown-paths` for named-volume ownership.** List mountpoints
  (one per line) in `.devcontainer/chown-paths` to have them re-owned to
  `vscode` on creation, fixing the `root:root` named-volume problem. Read-only
  inside the container and survives `aic sync`.

### Changed

- **CI: bump GitHub Actions to Node 24 majors.**

## [0.0.6] - 2026-05-25

### Added

- **Auto-wire `docker-compose.override.yml` into `dockerComposeFile`.** The
  sync-safe home for per-project env, mounts, and `extra_hosts`, opt-in by
  presence and surviving `aic sync`.
- **README: Playwright recipe for browser tests and automation.**

## [0.0.5] - 2026-05-22

### Added

- **`aic version` (also `--version`, `-v`).**

### Fixed

- **Bundled image bumped to v0.0.4; `NPM_CONFIG_MIN_RELEASE_AGE` set to 1 day.**

## [0.0.4] - 2026-05-22

### Added

- **Dogfood `.devcontainer/` at the repo root.** aicontainer is now developed
  inside aicontainer.

### Changed

- **Reduce `NPM_CONFIG_MIN_RELEASE_AGE` from 1440 to 1 day** so npx-based MCPs
  stay installable inside the container.
- **CI: run the release workflow on Node 24** and drop the npm upgrade step.
- **README: refresh badges** — add npm/release, make the license badge dynamic,
  drop the downloads badge.

## [0.0.3] - 2026-05-22

### Changed

- **CI publishes to npm via Trusted Publishers (OIDC).** No `NPM_TOKEN` secret
  needed.

## [0.0.2] - 2026-05-22

### Changed

- **CI: publish to npm via OIDC Trusted Publishers**, dropping `NODE_AUTH_TOKEN`.

## [0.0.1] - 2026-05-22

### Added

- **Initial release: a sandboxed devcontainer for Claude Code and Codex.** Runs
  them in bypass / auto-approve mode.

[Unreleased]: https://github.com/stefanoginella/aicontainer/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/stefanoginella/aicontainer/compare/v0.4.3...v0.5.0
[0.4.3]: https://github.com/stefanoginella/aicontainer/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/stefanoginella/aicontainer/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/stefanoginella/aicontainer/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/stefanoginella/aicontainer/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/stefanoginella/aicontainer/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/stefanoginella/aicontainer/compare/v0.2.3...v0.3.0
[0.2.3]: https://github.com/stefanoginella/aicontainer/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/stefanoginella/aicontainer/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/stefanoginella/aicontainer/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/stefanoginella/aicontainer/compare/v0.1.4...v0.2.0
[0.1.4]: https://github.com/stefanoginella/aicontainer/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/stefanoginella/aicontainer/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/stefanoginella/aicontainer/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/stefanoginella/aicontainer/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/stefanoginella/aicontainer/compare/v0.0.11...v0.1.0
[0.0.11]: https://github.com/stefanoginella/aicontainer/compare/v0.0.10...v0.0.11
[0.0.10]: https://github.com/stefanoginella/aicontainer/compare/v0.0.9...v0.0.10
[0.0.9]: https://github.com/stefanoginella/aicontainer/compare/v0.0.8...v0.0.9
[0.0.8]: https://github.com/stefanoginella/aicontainer/compare/v0.0.7...v0.0.8
[0.0.7]: https://github.com/stefanoginella/aicontainer/compare/v0.0.6...v0.0.7
[0.0.6]: https://github.com/stefanoginella/aicontainer/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/stefanoginella/aicontainer/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/stefanoginella/aicontainer/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/stefanoginella/aicontainer/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/stefanoginella/aicontainer/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/stefanoginella/aicontainer/releases/tag/v0.0.1
