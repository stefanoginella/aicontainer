# AGENTS.md

Guidance for AI coding agents (and humans) who work **on** aicontainer.
Users who run aicontainer in their projects start at [README.md](README.md).

aicontainer is a sandbox for autonomous AI tools (Claude Code, Codex,
OpenCode) that run in bypass / auto-approve mode. Most code in this
repository is a security boundary. The threat model is
[docs/user/security.md](docs/user/security.md).

## Repository map

- `aic` — the entry script of the host-side bash CLI. npm bin `aic` /
  `aicontainer`. It loads the modules in `lib/aic/` from an explicit list,
  then dispatches the command.
- `lib/aic/` — the bash modules of the CLI, one file for each concern. They
  only define functions and constants.
- `lib/` — host-side Node modules that `aic` runs. Only `node:` built-ins.
  `validate.mjs` is the structural validator; `validate-cli.mjs` runs it.
- `template/` — copied into every user project's `.devcontainer/` by
  `aic init` / `aic sync`. The source of truth for what lands in user repos.
- `tests/` — host CLI and privileged-helper regression tests.
- `.github/workflows/` — `rebuild.yml` (security-refresh track, `:latest`),
  `release.yml` (release track, `v*` tags), `smoke.yml` (shared smoke suite,
  `workflow_call` only).
- `tools/claude-plugin/` — the `/aicontainer:setup` Claude Code plugin.
- `docs/user/` — the user guide. `docs/contributing/` — the contributor guide.

Full layout: [docs/contributing/architecture.md](docs/contributing/architecture.md).

## Read before you change

Load the page for the area before you edit it. Each page holds the rules for
its area and the tests that guard them.

| When you touch | Read |
|---|---|
| Dev setup, conventions, local test runs | [development.md](docs/contributing/development.md) |
| Repository layout, the `aic` module list and `lib/aic/`, `template/` file list, package contents | [architecture.md](docs/contributing/architecture.md) |
| `template/Dockerfile` downloads, pins, checksums, GHCR tag pinning | [image-integrity.md](docs/contributing/image-integrity.md) |
| Drift warnings, update checks, `aic initialize` CLI lookup | [version-drift.md](docs/contributing/version-drift.md) |
| Project name, `COMPOSE_PROJECT_NAME`, path spelling, migration, `.devcontainer/` and `.git` control paths | [project-identity.md](docs/contributing/project-identity.md) |
| `validate_project_security()` (`lib/aic/validation.sh`), `lib/validate.mjs`, `lib/trust-hash.mjs`, `aic trust`, diagnostics | [validation.md](docs/contributing/validation.md) |
| Docker socket in `.env`, runtime detection, agent-status relay | [host-state.md](docs/contributing/host-state.md) |
| Seed sanitizer, tool homes, post-create resets, `aic-auth-sync`, volumes, `aic signing` | [seeds-and-auth.md](docs/contributing/seeds-and-auth.md) |
| Project-owned override files, `docker-compose.override.yml`, `chown-paths`, `post-create.project.sh`, VS Code files | [project-overrides.md](docs/contributing/project-overrides.md) |
| Shell startup, personal overlay (`rc.zsh`, `p10k.zsh`, `statusline.*`), AI-tool refresh | [shell-and-overlays.md](docs/contributing/shell-and-overlays.md) |
| Docker access modes, metadata block, `pids_limit` | [runtime-policy.md](docs/contributing/runtime-policy.md) |
| `template/aic-firewall`, hooks, privileged helpers, workflows (the security list below) | [security-review.md](docs/contributing/security-review.md) |
| A release, the CHANGELOG, the two workflow tracks | [releasing.md](docs/contributing/releasing.md) |

## Security review triggers

Review a change to these files for security regressions. Read
[security-review.md](docs/contributing/security-review.md) first:

- `aic` and `lib/aic/*.sh` (`lib/aic/validation.sh` holds the pre-Docker
  gate and the trust store)
- `lib/validate.mjs`, `lib/trust-hash.mjs`, `lib/docker-inspect.mjs`,
  `lib/project-identity.mjs`
- `template/Dockerfile`
- `template/post-create.py` and `template/post_create_*.py` (the seed
  sanitizer runs this code as root)
- `template/aic-firewall`
- `template/hooks/pre-tool-use.sh`, `template/hooks/opencode-guardrail.js`,
  `template/hooks/agent-status.py`
- `template/aic-chown-volumes`, `template/aic-lock-user-config`
- `.github/workflows/*.yml`

When two implementations are possible, choose the more restrictive one.

## Rules for every change

Tests:

- Keep every test in `tests/` and `smoke.yml` at its current strength. They
  guard real security guarantees. If a test fails legitimately, fix the
  regression, not the assertion.
- "Guarded by the '…' test" in the docs names a CLI test or a smoke test in
  `.github/workflows/smoke.yml`. When you change the behavior, extend that
  test.
- A security fix normally adds a fast host fixture in `tests/` and a runtime
  assertion in `smoke.yml`. A validator rule also adds a case in
  `tests/test-aic-validate.mjs`.
- After a change to `template/devcontainer.json` or a Compose template, run
  `tests/fixtures/validate/regenerate.sh` and review the diff.

Template and container:

- Edit `template/`, never `.devcontainer/`. Inside the container the
  PreToolUse hook blocks `.devcontainer/` writes. This is part of the sandbox
  boundary: an AI that can change its own devcontainer config can disable
  every other protection. Users get `template/` changes with `aic sync`. The
  dogfood `.devcontainer/` regenerates the same way, on the host.
- Add a file to `template/` only when every user project must get a copy.
- Keep npm-dropped names (`.gitignore`, `.npmignore`, `.npmrc`, …) out of
  `template/`. `tests/test-aic-package.sh` checks the packed tarball.
- Keep the `:latest` placeholder in `template/docker-compose.pull.yml`.
  `apply_template()` rewrites it to `:vX.Y.Z`.

Versions and changelog:

- Leave `package.json` `version` alone. Only `npm version` changes it, in its
  own release commit.
- Add a `CHANGELOG.md` bullet under `## [Unreleased]`, below the right Keep a
  Changelog heading, in the same commit or PR as each user-facing change. Then
  a release only renames the heading, and CI blocks a release with no
  section. Style: [releasing.md](docs/contributing/releasing.md).
- A change to a command, flag, exit code, `--json` member or id, control
  file, in-container path, or public variable also updates
  [docs/user/stability.md](docs/user/stability.md). A breaking change goes
  under `### Changed` with a `Breaking:` headline and the migration step.
  `tests/test-aic-stability-contract.mjs` checks the page against the code.
- Bump `tools/claude-plugin/.claude-plugin/plugin.json` `version` when the
  plugin skill changes. Validate with `claude plugin validate .` and
  `claude plugin validate tools/claude-plugin`.

Workflows and git:

- Route untrusted GitHub event fields (issue/PR titles, commit messages,
  branch refs) through `env:` with quotes, as both workflows already do.
  Never put them in a `run:` block. See the GitHub Security Lab guide on
  workflow injection.
- Pin every `uses:` to a full commit SHA with a `# vX.Y.Z` comment.
- Keep `smoke.yml` on `workflow_call` only. Write each runtime assertion
  there once.
- Never force-push `main` or rewrite tags. GHCR already holds what a tag
  pointed at.
- Do not use `git rebase -i` or other interactive git commands from a
  non-interactive environment. They hang silently.
- Write Conventional Commit messages.

Docs:

- When a change alters user-visible behavior (commands, defaults, mounts,
  capabilities, allowlist), update the matching page in `docs/user/`.
- When the managed vs project-owned file split changes, update
  `template/README.md` too.
- Write docs in ASD-STE100 Simplified Technical English: short sentences,
  active voice, imperative instructions, one term for one thing.
- Keep a rule in one place. Link to it from other pages.

## Verify locally

```bash
for test in tests/*.sh; do bash "$test"; done
for test in tests/*.py; do PYTHONDONTWRITEBYTECODE=1 python3 -I "$test"; done
for test in tests/*.mjs; do node "$test"; done
bash tests/test-aic-shellcheck.sh --require   # needs a local shellcheck
```

When you add a shell script, add it to `SCRIPTS` in
`tests/test-aic-shellcheck.sh`. See
[development.md](docs/contributing/development.md#lint-the-shell-scripts).

For a real container run, follow
[development.md](docs/contributing/development.md).

## Cut a release

When you are asked to cut a release, follow
[releasing.md](docs/contributing/releasing.md) step by step. Check
`npm config get ignore-scripts` first: the sandbox image sets it to `true`,
and that skips the changelog promotion.
