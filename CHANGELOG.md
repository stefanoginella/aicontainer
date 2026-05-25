# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> Maintainers: add notes under **[Unreleased]** as you go. At release time,
> rename that heading to the new version with today's date and add a compare
> link at the bottom. A release is **blocked** unless this file has a matching
> `## [X.Y.Z]` section — see AGENTS.md → "Releasing".

## [Unreleased]

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

[Unreleased]: https://github.com/stefanoginella/aicontainer/compare/v0.0.10...HEAD
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
