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

[Unreleased]: https://github.com/stefanoginella/aicontainer/compare/v0.2.2...HEAD
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
