# AGENTS.md

Guidance for AI coding agents (and humans) working **on** aicontainer itself.
For users running aicontainer in their projects, the entry point is `README.md`.

`CLAUDE.md` is a thin pointer to this file — keep that arrangement. New
agent-facing notes go here, not in `CLAUDE.md`.

## Repository layout

- `aic` — the host-side bash CLI. Single file. Sourced from npm bin (`aic`,
  `aicontainer`) and from `~/.aicontainer/aic` for git installs. Resolves its
  template via `$AIC_HOME` (defaults to the script's directory after
  symlink-following).
- `template/` — files copied into a project's `.devcontainer/` by `aic init`
  and `aic sync`. The canonical source of truth for what ends up in a user's
  repo.
  - `Dockerfile`, `post-create.py`, `hooks/`, `aic-firewall`,
    `aic-chown-volumes`, `aic-lock-gitconfig`, `.zshrc`
  - `docker-compose.pull.yml` — default (pull) mode
  - `docker-compose.build.yml` — `--build` mode
- `.github/workflows/`
  - `rebuild.yml` — **security-refresh track.** Runs on template-touching
    pushes to `main`, the weekly cron, and `workflow_dispatch`. Publishes
    `ghcr.io/stefanoginella/aicontainer:latest` and `:weekly-YYYY-VV`.
    Does not publish to npm.
  - `release.yml` — **release track.** Runs only on `v*` tag push (or
    `workflow_dispatch` against a tag ref). Publishes immutable
    `:vX.Y.Z` + `:latest` to GHCR and `aicontainer@X.Y.Z` to npm with
    provenance attestation.
- `package.json` — npm metadata. Its `version` field is the source of truth
  for the GHCR image tag pinned by `aic init`. Do not edit it by hand for a
  release; use `npm version`.
- `CHANGELOG.md` — hand-maintained ([Keep a Changelog](https://keepachangelog.com/)
  format). Source of the GitHub Release notes, and a release precondition (see
  "Releasing").
- `.githooks/pre-push` — local mirror of the CI changelog gate; opt-in via
  `git config core.hooksPath .githooks`.

## How image tag pinning works (read before editing the CLI)

`aic init` (pull mode) and `aic sync` (pull mode) write
`ghcr.io/stefanoginella/aicontainer:vX.Y.Z` into the generated
`.devcontainer/docker-compose.yml`, where `X.Y.Z` is the installed aic's
`package.json` version, read via `read_aic_version()` in the `aic` script.

The mechanism:

1. `template/docker-compose.pull.yml` ships with the literal placeholder
   `ghcr.io/stefanoginella/aicontainer:latest` (three occurrences: two
   comments + the actual `image:` line).
2. `apply_template()` copies the file, then sed-rewrites every occurrence to
   `:vX.Y.Z`.
3. The user's resulting compose file is pinned; the template stays canonical
   with `:latest`.

**Do not** hand-edit `template/docker-compose.pull.yml` to use a pinned tag —
keep `:latest` as the placeholder so the rewrite remains idempotent and `aic
sync` can re-pin to a new version cleanly.

If you change the GHCR repo path (`stefanoginella/aicontainer`), update **all
of**: the template (`docker-compose.pull.yml`), the sed pattern in
`apply_template()` inside `aic`, the README's GHCR references, the
`aic-firewall` allowlist's `ghcr.io` entry, and both workflows' image tags.

## Project-owned override files (don't break the auto-wire)

`apply_template()` overwrites `devcontainer.json` and `docker-compose.yml`
wholesale on every `init`/`sync`; only `AIC_TOOLS` / `AIC_SHELL` survive (they
are re-derived from the old file and re-injected by `patch_devcontainer_json`).
So users must **not** hand-edit those two files — per-project tweaks go in
project-owned files that `apply_template()` never touches: `Dockerfile.project`,
`firewall-allowlist`, `chown-paths`, `post-create.project.sh`, and
`docker-compose.override.yml`.

The override is the sync-safe home for anything that would otherwise live in
`containerEnv` or the compose service (env, `extra_hosts`, mounts, a
`build:` block for `Dockerfile.project`). The mechanism:

1. The template's `devcontainer.json` ships `"dockerComposeFile":
   ["docker-compose.yml"]` (single entry — the canonical placeholder).
2. `patch_devcontainer_json()` appends `"docker-compose.override.yml"` to that
   array **only when `.devcontainer/docker-compose.override.yml` exists**. The
   append is guarded against double-wiring, so it stays idempotent across syncs.

Keep the template's array single-entry — do not pre-list the override there, or
`devcontainer up` fails on projects that don't have the file (a missing
`dockerComposeFile` entry is a hard error). The wiring is opt-in by file
presence, mirroring how `firewall-allowlist` is read only if present.

`chown-paths` is the companion to override-declared **named volumes**. Docker
inits a fresh named volume `root:root` and `updateRemoteUserUID` doesn't touch
the daemon's init UID, so a `myproject-venv:/workspace/.venv` mount lands
unwritable by `vscode`. A project lists such mountpoints (one per line) in
`.devcontainer/chown-paths`; `post-create.py`'s `fix_volume_ownership()` then
re-owns them via `aic-chown-volumes` on container creation. Same opt-in-by-
presence, read-only-inside-container, survives-sync contract as
`firewall-allowlist`. **The prefix allowlist (`/workspace/`,
`/home/vscode/.cache/`) is the security boundary — see "Security stance"
before widening it.**

`post-create.project.sh` is the project-owned extension point for
`post-create.py` itself. `run_project_hook()` runs
`.devcontainer/post-create.project.sh` (via `bash <file>`, cwd `/workspace`,
as `vscode`) **last** in `main()`, after every aic-managed step, so a
project's `lefthook install` / `npm ci` sees a fully wired environment. Same
opt-in-by-presence / survives-sync / read-only-inside-container contract as
the files above. It's the only way to extend post-create in **pull mode**,
where `post-create.py` is baked into the image and absent from the repo —
`apply_template()` only copies it in `--build` mode. Security-wise it's lower
stakes than it looks: it runs unprivileged (no grant the in-container agent
lacks) and the PreToolUse hook blocks in-container writes to `.devcontainer/`,
so it stays host-only-editable. Non-zero exit is logged, not fatal — keep that
defensive degradation; a flaky project step shouldn't block the devcontainer
from coming up.

## Releasing

See README.md's "Releasing" section for the user-visible flow. Internal notes:

```bash
# From a clean main:
# 0. Update CHANGELOG.md: rename ## [Unreleased] -> ## [X.Y.Z] - <date> + link
npm version patch        # or minor / major
git push --follow-tags   # pushes the bump commit AND the v* tag
```

- **Sync the dogfood devcontainer from the host before releasing.** Run `aic
  sync` from the host (not from inside the container — the PreToolUse hook
  blocks writes to `.devcontainer/`) so the repo's own `.devcontainer/`
  reflects the latest `template/` and gets committed alongside any
  template-affecting changes. Releasing without syncing leaves the dogfood
  config drifted from what users will get via `aic init`.
- The bump commit on `main` touches only `package.json`, which is **not** in
  `rebuild.yml`'s `paths:` filter — so `rebuild.yml` does **not** fire on
  release commits. Only `release.yml` runs.
- `release.yml`'s "Verify tag matches package.json" step fails fast if you
  mint a tag manually that doesn't match. Use `npm version`.
- Do not run `npm publish` locally. CI uses `--provenance`; manual publishes
  skip the supply-chain attestation users can verify.
- **`CHANGELOG.md` is hand-maintained, and updating it is a release
  precondition.** Edit the file before bumping: rename `## [Unreleased]` to
  `## [X.Y.Z] - <date>` and add the compare link at the bottom. `release.yml`'s
  "Verify CHANGELOG.md has an entry" step greps for `^## [X.Y.Z]` *before* any
  GHCR/npm push and fails the whole release if it's missing — so a forgotten
  changelog burns a tag, it doesn't ship. `.githooks/pre-push` runs the same
  check locally (opt-in: `git config core.hooksPath .githooks`); it's
  convenience only — bypassable with `--no-verify` and per-clone, so **CI is
  the real gate; don't weaken that step.** Keep the `## [X.Y.Z]` heading format:
  both the gate's grep and the release-notes extraction key on it.
- **The GitHub Release is automatic.** `release.yml`'s `github-release` job
  (`needs: [publish]`, so it only runs after GHCR + npm succeed) extracts the
  tag's `## [X.Y.Z]` section from `CHANGELOG.md` and creates the Release via
  `gh`. It's idempotent (skips if the Release exists) and falls back to
  `--generate-notes` if no section is found. This is why the job needs
  `contents: write` while `publish` stays `contents: read`. Releases v0.0.1–
  v0.0.7 were created by hand before this existed; v0.0.8+ are automatic.

## Workflow split rationale (so future edits don't undo it)

The split exists because the npm CLI (`aic`) is tightly coupled to the
container's filesystem (hooks, sudoers, helper-script paths). Floating
`:latest` would let the CLI and image drift out of sync. The two workflows
serve different audiences:

- `:vX.Y.Z` (immutable, from `release.yml`): what `aic init` pins by default.
  Users on a given aic version always pull the exact image that was built at
  release time. Reproducibility wins.
- `:latest` (floating, from `rebuild.yml`'s weekly cron + template pushes):
  opt-in for users who want base-layer security freshness over
  reproducibility. Not referenced by `aic init` output.

If you find yourself tempted to "simplify" by collapsing the two workflows or
re-pointing `aic init` at `:latest`, re-read the design tradeoff first.
Comparable projects (Supabase CLI, Dagger) use the same pinned model;
Earthly's floating-with-coupling model is the documented anti-pattern.

## Don't do

- **Don't weaken smoke tests** in either workflow's `smoke` job. They cover
  real security guarantees: `EXEC=0` on the socket-proxy, the `.env`
  PreToolUse hook block, scoped sudo (no arbitrary `chown`), the
  `gitconfig.local` root-444 lock, and the npm-quarantine sanity check
  (`NPM_CONFIG_MIN_RELEASE_AGE` ≤ 30 days, so npx-based MCPs stay
  installable). If a test fails legitimately, fix the regression, not the
  assertion.
- **Don't add untrusted GitHub event fields directly into `run:` blocks**
  (issue titles, PR titles, commit messages, branch refs). Use `env:` with
  proper quoting. See the GitHub Security Lab guide on workflow injection.
  Both current workflows route any ref/version through `env:` for this
  reason.
- **Don't add files to `template/`** that the user shouldn't get a copy of.
  `apply_template()` is the gatekeeper; anything that lands there gets
  copied into every project's `.devcontainer/`.
- **Don't try to edit `.devcontainer/` from inside the container.** The
  PreToolUse hook (`template/hooks/pre-tool-use.sh`) blocks writes there —
  it's part of the sandbox boundary, since an AI that can rewrite its own
  devcontainer config can disable every other protection. Edit
  `template/devcontainer.json` (and the rest of `template/`) instead; users
  pick up changes via `aic sync`. The dogfood `.devcontainer/` at the repo
  root regenerates the same way.
- **Don't bump `package.json` in a feature PR.** Version bumps are their own
  commit (created by `npm version`) so the tag points at a clean release
  commit.
- **Don't land a user-facing change without a `CHANGELOG.md` note.** When you
  add, change, fix, or remove something a user would notice (an `aic`
  flag/command, a `template/` behavior, a security fix, a default), add a bullet
  under `## [Unreleased]` in `CHANGELOG.md` in the *same* commit/PR — under the
  right Keep-a-Changelog heading (`Added`/`Changed`/`Fixed`/`Removed`). Keep
  `[Unreleased]` current so release time is just "rename the heading," not
  "reconstruct history." The changelog is hand-maintained and is a release
  precondition (CI blocks a version with no section) — see "Releasing".
- **Don't force-push to `main` or rewrite tags.** GHCR has already received
  whatever the tag was bound to; ghost tags confuse users on pinned versions.
- **Don't use `git rebase -i` or other interactive git commands** from a
  non-interactive environment — they hang silently.

## Security stance

This container is a sandbox for autonomous AI tools running in
bypass-permissions / sandbox-off mode. The README's "Threat model" section is
the source of truth. When choosing between two implementations, prefer the
more restrictive one. The following files warrant extra care — any change
should be reviewed for security regressions:

- `template/Dockerfile` — particularly the sudoers, USER, and capability
  bits. Adding a new `NOPASSWD` entry is a load-bearing decision.
- `template/aic-firewall` — outbound iptables allowlist. Adding hosts here
  expands what an in-container AI can reach.
- `template/hooks/pre-tool-use.sh` — blocks reads of `.env` and other
  sensitive paths. Loosening the deny list weakens the model.
- `template/aic-chown-volumes`, `template/aic-lock-gitconfig` — the only
  scripts allowed via `NOPASSWD` sudo. Touching them changes the privileged
  surface. `aic-chown-volumes` reads project-supplied targets from
  `.devcontainer/chown-paths`, **never from argv** — that's what stops the
  `NOPASSWD` grant from becoming an arbitrary `sudo aic-chown-volumes
  /etc/sudoers.d`. The hardcoded prefix allowlist (`/workspace/`,
  `/home/vscode/.cache/`) plus `-h`/non-traversing `-R` is the boundary;
  widening it to broader `$HOME` would expose `~/.gitconfig.local` (the
  root-locked gitconfig) and is a load-bearing decision. The "scoped sudo
  cannot chown arbitrary paths" smoke test guards this — extend it, don't
  weaken it.
- `.github/workflows/*.yml` — CI secrets (`NPM_TOKEN`, GHCR via
  `GITHUB_TOKEN`). The `publish` jobs only run on push/schedule/dispatch,
  never on `pull_request`, to keep fork PRs from triggering publishes.

## Verifying changes locally

The CI smoke tests run inside a real devcontainer. Approximate that locally
to avoid pushing broken changes:

```bash
mkdir -p /tmp/aic-test && cd /tmp/aic-test
git init -q
AIC_HOME=/path/to/aicontainer-checkout /path/to/aicontainer-checkout/aic init --build
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . claude --version
devcontainer exec --workspace-folder . curl -fsS http://socket-proxy:2375/_ping
# npm quarantine sanity (must be ≤ 30 days or npx-based MCPs fail to install)
devcontainer exec --workspace-folder . bash -lc 'echo "$NPM_CONFIG_MIN_RELEASE_AGE"'
```

For CLI-only changes, exercising `aic init` against a temp directory and
inspecting the generated `.devcontainer/` is usually enough:

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
