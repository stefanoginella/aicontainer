# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> Maintainers: add notes under **[Unreleased]** as you go. At release time,
> rename that heading to the new version with today's date and add a compare
> link at the bottom. A release is **blocked** unless this file has a matching
> `## [X.Y.Z]` section — see AGENTS.md → "Releasing".

## [Unreleased]

## [0.1.4] - 2026-05-30

### Fixed

- `post-create.project.sh` no longer inherits the ephemeral `VIRTUAL_ENV` that
  `uv run --no-project /opt/post-create.py` activates for post-create itself.
  Previously a project hook running `uv sync`/`uv run` warned that
  `VIRTUAL_ENV=…/uv/environments-v2/post-create-*` "does not match the project
  environment path `.venv` and will be ignored"; the leaked activation (and its
  `PATH` bin entry) is now stripped before the hook runs.

## [0.1.3] - 2026-05-27

### Changed

- `aic sync`'s stale-`Dockerfile.project`-base warning is now printed in yellow
  (on a TTY) and, when run interactively, offers to bump the `FROM` tag in place
  with a `[Y/n]` prompt (default Yes). Declining — or running non-interactively
  (CI, piped) — leaves the file untouched and points at `aic sync --bump-base`,
  preserving the previous behavior.

## [0.1.2] - 2026-05-27

### Security

- PreToolUse hook now also matches the **`Grep` and `Glob` tools**. A `Grep`
  with `output_mode=content` aimed at `.env` could previously dump the file
  without the Read/Edit/Write `.env` block ever firing, because the hook wasn't
  invoked for those tools.
- PreToolUse hook **`.env` detection in Bash commands** now treats quotes and
  glob characters as filename boundaries, closing bypasses like `cat ".env"`,
  `cat .env*`, and `cat *.env` that evaded the secret-read block.
- PreToolUse hook **`curl|sh` detection** now catches interposed wrappers
  (`| sudo bash`, `| env X=1 bash`, `| xargs`), intermediate pipes
  (`| tee … | sh`), more shells (`dash`, `ash`, `ksh`, `/usr/bin/sh`), and
  command/process substitution (`bash -c "$(curl …)"`, `. <(curl …)`).
- **Login-shell rc files are now root-locked.** `~/.zshrc`, `~/.bashrc`, and the
  fish config shipped writable by `vscode`, so a tool session could append a
  payload that runs on the next `aic shell`. `aic-lock-gitconfig` (run by
  post-create) now locks them to `root:root 0444` alongside `~/.gitconfig.local`,
  and the hook's self-protection list covers them plus their `.local` includes
  (which stay user-writable for layering your own config). Pick up the change
  with `aic sync` (then rebuild).
- **The PreToolUse guardrail now actually runs for Codex.** It was wired via a
  `[hooks] pre_tool_use = "…"` entry in `~/.codex/config.toml` — the wrong schema
  (Codex expects `[[hooks.PreToolUse]]` tables) *and* a non-managed hook, which
  Codex leaves untrusted and skips until reviewed via `/hooks` (never, in
  autonomous mode). It is now baked as a **managed** hook in
  `/etc/codex/requirements.toml` (auto-trusted, not user-disablable) matching the
  `Bash` tool, so the `.env`-read and `curl|sh` checks apply to Codex too.

### Changed

- The PreToolUse hook parses its event JSON in a single `jq` pass (was 2–3 `jq`
  forks plus a `basename` fork per call) — it runs on every tool call. No
  behavior change; NUL-separated fields preserve multi-line command text.

### Fixed

- `aic down`, `aic destroy`, and `aic preflight` targeted the wrong Docker
  Compose project. `project_name()` produced `<folder>_` (a stray trailing
  underscore, and no `_devcontainer` suffix) instead of the
  `<folder>_devcontainer` name that `devcontainer up` / VS Code actually create
  — so `aic down` left the container running and `aic destroy` printed success
  while leaving the container and its `*_aic-sessions` transcript volume intact.
  The computed name now matches the real stack.
- `rebuild.yml` no longer skips compose-template changes: its push/PR `paths:`
  filter referenced a nonexistent `template/docker-compose.yml`, so edits to
  `docker-compose.{pull,build}.yml` (and `template/.zshrc`) never triggered the
  weekly-track image rebuild or the PR smoke tests. It now globs `template/**`.
- `sudo aic-firewall enable` no longer drops the firewall open while
  (re-)applying. It used to flush the rules to `policy ACCEPT` and re-resolve the
  ~17 allowlist domains wide-open on every run, and a transient 0-IP resolution
  left the firewall fully open (the `exit 1` ran with the policy already
  lowered). It now resolves into a staging ipset and swaps it in without ever
  setting `policy ACCEPT`, so re-enabling can only re-apply or strengthen — never
  transiently or permanently weaken — matching the documented invariant.

## [0.1.1] - 2026-05-26

### Fixed

- Spurious Docker Compose warnings on `aic up` when more than one aicontainer
  project runs on the same host (`volume "aic-shell-history" already exists but
  was created for project X` / `volume "aic-auth-global" ... was not created by
  Docker Compose`). The two host-global volumes are now declared `external: true`
  in the generated `docker-compose.yml`, so Compose adopts them by name instead
  of claiming per-project ownership. `initializeCommand` now also creates
  `aic-shell-history` (alongside `aic-auth-global`), since external volumes are
  never auto-created by Compose. Existing volumes and their contents are reused
  as-is — run `aic sync` to pick up the change.

## [0.1.0] - 2026-05-26

### Added

- `aic preflight`: prints the project's trust boundary in one screen — what the
  agent can read (RW/RO mounts), what's blocked (`.env`/secrets, host
  credentials, SSH), where session transcripts persist, and whether outbound
  network is open or firewalled. Read-only; live-detects the firewall state
  when the container is running, reports it as open otherwise. The same summary
  now prints automatically at the end of `aic up`, including a loud "full
  outbound by default" network warning (the allowlist is opt-in and resets on
  rebuild). It also flags a present `docker-compose.override.yml` (which can add
  mounts/env/hosts) and counts a `firewall-allowlist`. Surfaces protections
  that were real but previously only discoverable by reading the README.

### Changed

- `aic destroy` now confirms before deleting. It prints the per-project session
  volume and its on-disk size (best-effort, via `docker system df`), notes the
  removal is irreversible (and that `aic down` keeps history), and prompts
  `[y/N]` — months of Claude/Codex transcripts no longer vanish on a single
  command. Non-interactive callers (CI, piped) still proceed unprompted;
  `--yes` / `-y` skips the prompt explicitly.
- README: new "What crosses the boundary" at-a-glance table near the top, an
  explicit session-survival guarantee in "Multi-project model", and a short FAQ
  on how the sandbox relates to Claude Code's new auto mode.

## [0.0.11] - 2026-05-25

### Changed

- The per-project devcontainer name is now `aicontainer-<project folder>`
  (prefix), flipped from the previous `<project folder>-aicontainer` (suffix),
  so all aicontainer devcontainers sort together under a common `aicontainer-`
  prefix in VS Code's remote indicator. Re-derived on every `aic init` / `aic
  sync`; not hand-editable (overwritten on sync).

## [0.0.10] - 2026-05-25

### Changed

- README Troubleshooting: document why Codex still surfaces approval / `bwrap:
  No permissions to create a new namespace` prompts in the VS Code extension
  even though `~/.codex/config.toml` is forced to `sandbox_mode =
  danger-full-access`. Two causes: the sidebar's built-in *Full access* preset
  (fix: pick **Custom (config.toml)**), and an upstream bug where Codex review
  mode / sub-agents don't inherit `danger-full-access` and fall back to
  `workspace-write` ([openai/codex#15305](https://github.com/openai/codex/issues/15305)) —
  safe to allow ("outside the sandbox" = normally inside the container). Also
  warns against "fixing" bwrap by granting `SYS_ADMIN` / userns.

### Fixed

- Claude `/resume` and Codex session history now persist in **every** project,
  not just the first one initialized on a host. The session symlinks
  (`~/.claude/projects`, `~/.codex/sessions`, `~/.codex/history.jsonl`) live in
  the shared `aic-auth-global` volume but point into the per-project
  `aic-sessions` volume; `post-create.py`'s `link()` early-returned when the
  inherited symlink already resolved correctly, so the first project created
  its target dir but later projects were left with a **dangling symlink** —
  `mkdir` of the transcript dir failed with `File exists` and transcripts were
  never written. `link()` now creates the per-project target whenever it's
  missing, healing existing containers on the next `aic rebuild`.
- Claude's prompt history (`~/.claude/history.jsonl`, the up-arrow recall) is now
  scoped per project, matching Codex. It previously lived in the shared
  `aic-auth-global` volume; since every container's cwd is `/workspace`, Claude's
  per-cwd history filter matched *every* project's entries, so up-arrow recall
  bled across all aicontainer projects. It's now symlinked into the per-project
  `aic-sessions` volume. (Normal writes are appends and follow the symlink; only
  the explicit, confirmation-gated "delete project data" command rewrites via
  atomic rename, which harmlessly reverts to shared scope until the next rebuild.)

## [0.0.9] - 2026-05-25

### Added

- `aic sync --bump-base`: when a project-owned `Dockerfile.project` pins an
  explicit `FROM ghcr.io/stefanoginella/aicontainer:vX.Y.Z`, rewrite that tag to
  the installed aic's version. Plain `aic sync` now also **warns** on such drift
  (it still never edits the file on its own; `:latest` floats and `ARG`-templated
  bases are left alone). Catches the case where a `docker-compose.override.yml`
  `build:` block silently runs a stale base image after `npm update -g aicontainer`.

### Fixed

- semgrep's login token now persists reliably across rebuilds. semgrep is pointed
  at `~/.config/aic-auth/semgrep/settings.yml` (inside the global auth volume) via
  `SEMGREP_SETTINGS_FILE`, replacing a leaf-file symlink that semgrep's
  atomic-rename writes clobbered — which produced a recurring `[post-create]
  warning: both … settings.yml exist` on every container create and left the token
  on the throwaway container rootfs.

## [0.0.8] - 2026-05-25

### Added

- Project-owned `post-create.project.sh`: drop a script at
  `.devcontainer/post-create.project.sh` to run your own steps (`lefthook
  install`, `npm ci`, DB seeding, …) on every container creation. Runs last —
  as `vscode`, in `/workspace`, after all aic setup — is opt-in by presence,
  survives `aic sync`, and its non-zero exit is logged without failing
  container creation.

### Changed

- `aic init` / `aic sync` now name the devcontainer `<project folder>-aicontainer`
  (derived from the project directory) instead of the static `aicontainer`, so
  each project shows a distinct label in VS Code's remote indicator. Re-derived
  on every run; the name is not hand-editable (it's overwritten on sync).

### Fixed

- `aic sync` now exits `0` on success. It previously returned the status of its
  last check, exiting `1` when a project had no `docker-compose.override.yml`
  even though the sync completed correctly.

## [0.0.7] - 2026-05-25

### Added

- Project-owned `chown-paths`: list named-volume mountpoints (one per line) in
  `.devcontainer/chown-paths` to have them re-owned to `vscode` on container
  creation, fixing the `root:root` named-volume ownership problem. Read-only
  inside the container and survives `aic sync`.

### Changed

- CI: bump GitHub Actions to Node 24 majors.

## [0.0.6] - 2026-05-25

### Added

- Auto-wire a project's `docker-compose.override.yml` into `dockerComposeFile` —
  the sync-safe home for per-project env, mounts, and `extra_hosts` that
  survives `aic sync`.
- README: Playwright recipe for browser tests and automation.

## [0.0.5] - 2026-05-22

### Added

- `aic version` (also `--version`, `-v`).

### Fixed

- Bump the bundled image to v0.0.4 and set `NPM_CONFIG_MIN_RELEASE_AGE` to 1 day.

## [0.0.4] - 2026-05-22

### Added

- Dogfood `.devcontainer/` at the repo root, so aicontainer is developed inside
  aicontainer.

### Changed

- Reduce `NPM_CONFIG_MIN_RELEASE_AGE` from 1440 to 1 day so npx-based MCPs stay
  installable inside the container.
- CI: run the release workflow on Node 24; drop the npm upgrade step.
- README: add npm/release badges; switch the license badge to dynamic; drop the
  downloads badge.

## [0.0.3] - 2026-05-22

### Changed

- CI now publishes to npm via Trusted Publishers (OIDC). No `NPM_TOKEN` secret
  needed.

## [0.0.2] - 2026-05-22

### Changed

- CI: publish to npm via OIDC Trusted Publishers; drop `NODE_AUTH_TOKEN`.

## [0.0.1] - 2026-05-22

### Added

- Initial release: a sandboxed devcontainer for running Claude Code and Codex in
  bypass / auto-approve mode.

[Unreleased]: https://github.com/stefanoginella/aicontainer/compare/v0.1.4...HEAD
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
