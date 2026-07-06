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
    `aic-chown-volumes`, `aic-lock-gitconfig`, `.zshrc`
  - `hooks/`: the shared guardrail `pre-tool-use.sh` (Claude + Codex) plus
    `opencode-guardrail.js`, the thin OpenCode plugin that shells out to it —
    all copied root-owned to `/etc/aic/hooks/`.
  - `docker-compose.pull.yml` (default mode), `docker-compose.build.yml`
    (`--build` mode)
  - `README.md` — copied into every project's `.devcontainer/` in **both**
    modes; a managed guide to the do-not-edit vs project-owned split. Keep its
    two lists in sync with `apply_template()` and the project-owned files.
- `.github/workflows/`
  - `rebuild.yml` — **security-refresh track**: template-touching pushes to
    `main`, weekly cron, `workflow_dispatch`. Publishes GHCR `:latest` +
    `:weekly-YYYY-VV`; never npm.
  - `release.yml` — **release track**: `v*` tag push (or `workflow_dispatch`
    on a tag ref) only. Publishes immutable `:vX.Y.Z` + `:latest` to GHCR and
    `aicontainer@X.Y.Z` to npm with provenance attestation.
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
(three occurrences: two comments + the `image:` line); `apply_template()`
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
`devcontainer up` directly, never `aic`): the template's `initializeCommand`
(the only host-side lifecycle hook) ends with `&& { command -v aic … && aic
check-drift >/dev/null; true; }`. `cmd_check_drift` is a lenient internal
entry point (no `require_in_project`, always exits 0) that just calls
`warn_compose_drift`. Load-bearing details:

- The suffix is `&&`-chained **after** the bootstrap (a bootstrap failure
  still surfaces to VS Code), and the trailing `; true` means a
  missing/old/erroring `aic` can never abort container startup.
- `>/dev/null` keeps an *old* global `aic` (no `check-drift` command → would
  dump `cmd_help`) quiet; the real warning is stderr-only.
- Visibility is the Dev Containers output channel, not a popup or terminal
  (the only way to force a popup is to fail init, which we refuse to do) —
  strictly additive over the `aic`-CLI path. Needs `aic` on
  `initializeCommand`'s PATH (GUI-launched VS Code may trim it); a miss is a
  silent no-op, never a break.

Deliberate blind spots (offline + zero-cost beats full coverage): it compares
CLI-vs-pin, not pin-vs-*running container*, so a synced-but-not-rebuilt
project is silent (the hint resolves it anyway); and build-mode projects have
no pin, so they're unchecked — including the dogfood repo, where the
`check-drift` wiring is mirrored into `.devcontainer/devcontainer.json` only
to avoid template drift. Don't "fix" these with a `docker inspect` on the hot
path without re-reading this tradeoff.

**Tier 2 — `check_for_update()` (network, off hot path).** Only on `aic
version`/`upgrade`. Asks **npm** for the latest published version — not GHCR,
whose `:latest` floats on the weekly cron and would mis-report "behind."
`fetch_latest_version()` is bounded (`curl --max-time`, npm-view fallback)
and gated through `is_semver()` before any `printf` — that validation is the
terminal-escape defense against a hostile registry; keep it. Cached 24h under
`$XDG_CACHE_HOME/aicontainer/update-check`, and skipped when `CI` is set —
that guard is what keeps the workflow CLI tests offline; don't remove it.

## Project-owned override files (don't break the auto-wire)

`apply_template()` overwrites `devcontainer.json` and `docker-compose.yml`
wholesale on every `init`/`sync`; only `AIC_TOOLS`/`AIC_SHELL` survive
(re-derived from the old file and re-injected by `patch_devcontainer_json`).
Users must not hand-edit those two files — per-project tweaks go in the
project-owned files `apply_template()` never touches: `Dockerfile.project`,
`firewall-allowlist`, `chown-paths`, `post-create.project.sh`,
`docker-compose.override.yml`, `vscode-extensions`, `vscode-settings.json`.
All share one contract: **opt-in by file presence, survive sync, read-only
inside the container.**

**`docker-compose.override.yml`** — sync-safe home for anything that would
otherwise live in `containerEnv` or the compose service (env, `extra_hosts`,
mounts, a `build:` block for `Dockerfile.project`). The template's
`devcontainer.json` ships `"dockerComposeFile": ["docker-compose.yml"]`
(single entry); `patch_devcontainer_json()` appends the override **only when
the file exists**, guarded against double-wiring so it stays idempotent. Keep
the template array single-entry — pre-listing the override makes
`devcontainer up` fail on projects without the file (a missing
`dockerComposeFile` entry is a hard error).

Because the override (and `Dockerfile.project`'s `FROM`) is honored on `aic
up` and rides along inside an untrusted repo, `scan_project_overrides()` reads
both files **before** `devcontainer up` (from `cmd_up`/`cmd_rebuild` in gate
mode — prompts on a TTY; and `cmd_check_drift` in warn mode — the VS Code
`initializeCommand` path) and flags host-access grants (`privileged`,
`cap_add`, host namespaces, host bind mounts, the Docker socket, socket-proxy
`POST/BUILD: 1`, a non-aicontainer `FROM`). Print-only + opt-out
(`AIC_NO_OVERRIDE_SCAN=1`) so it never blocks automation. Guarded by the
"project override scan flags host-access grants before up" test — extend the
pattern list and the test together.

**`chown-paths`** — companion to override-declared named volumes. Docker
inits a fresh named volume `root:root` and `updateRemoteUserUID` doesn't
change that, so e.g. a `myproject-venv:/workspace/.venv` mount lands
unwritable by `vscode`. The project lists such mountpoints one per line;
`post-create.py`'s `fix_volume_ownership()` re-owns them via
`aic-chown-volumes` on create. **The prefix allowlist (`/workspace/`,
`/home/vscode/.cache/`) is the security boundary — see "Security stance"
before widening it.**

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
   warn+skipped otherwise; the settings file must be a JSON object, injected
   verbatim. Both land only in the host-side `devcontainer.json` the user
   reviews via `git diff` (never the container), so it's not a sandbox-escape
   surface — but keep the id validation so a stray line can't smuggle JSON.
4. On a key collision, aic's own settings win inside `devcontainer.json`
   (injected first); the documented escape hatch is the user's
   `.vscode/settings.json`, which beats devcontainer machine-scope settings.
   Don't reorder to "make project win" without updating the README.

Guarded by the "aic sync merges project-owned vscode-extensions /
vscode-settings.json" test.

**AI-tool refresh on every create.** `refresh_ai_tools()` runs early in
`main()` and floats Claude Code + Codex + OpenCode to latest on every
container (re)create, so a plain `aic rebuild` lands current CLIs without a
new image. The Dockerfile bakes each as an offline *floor*; updates run via
`claude update`/`codex update`/`opencode upgrade`. `AIC_TOOLS`-gated,
fail-soft (an offline/failed update keeps the baked version — don't make it
fatal), opt-out via `AIC_FREEZE_TOOLS=1` for a reproducible sandbox. The
updaters MUST run with their bin dir on `PATH` (`~/.local/bin` for
Claude/Codex, `~/.opencode/bin` for OpenCode — both prepended in
`refresh_ai_tools()`): `codex update` re-runs the official installer, which
otherwise tries to edit a login-shell rc file (root-locked by
`aic-lock-gitconfig`) and fails; with the bin dir already on PATH it skips
that step. OpenCode installs with `--no-modify-path` and upgrades in place,
never touching rc files. Guarded by the "tool self-update works with rc files
root-locked" test.

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

**Docker socket write access (opt-in).** The socket-proxy ships **read-only**
in both compose templates (`POST: 0`, `BUILD: 0`) — this is the change that
makes the proxy an actual host-isolation boundary, since `POST` lets an agent
`docker run --privileged -v /:/host` (host escape) and spawn firewall-dodging
sibling containers. `--docker` (init/sync) opts in; the mode is a third
sync-preserved choice alongside `AIC_TOOLS`/`AIC_SHELL`, but it lives in the
**compose file itself**, not `containerEnv`: `read_compose_docker_mode()`
reads it from the old file before `apply_template()` overwrites, and
`apply_docker_mode()` flips the two toggle lines in the fresh copy (matched on
the bare `KEY: <0|1>` form so nothing else moves). `print_boundary_summary`
reports the live state from the same read. **Keep the template at
`POST/BUILD: 0`** — that's the secure default the opt-in flips, and the
"Docker socket write access is opt-in" test asserts it (plus that `--docker`
persists across a plain `sync` and `--no-docker` reverts). The override scan
above also flags a hand-written `POST/BUILD: 1` in the override, since that's
the un-blessed way to re-enable it.

**Always-on metadata block.** `post-create.py`'s `block_metadata()` runs `sudo
aic-firewall block-metadata` on every create (fail-soft), dropping egress to
`169.254.0.0/16` — cloud metadata + link-local — independent of the opt-in
allowlist, to close the cloud-credential-theft path even when the full
firewall is never enabled. It's a third `aic-firewall` subcommand and needs no
new sudoers entry (the wrapper is already `NOPASSWD`). Strengthen-only like
`enable`: it only ever adds a DROP (a dedicated `AIC_METADATA` chain, re-flushed
each run, jumped from `OUTPUT` once), so it composes with the full firewall
(whose default-DROP already covers the range). Guarded by the "cloud metadata
/ link-local egress is blocked" test. Known gap: a sibling container spawned
via opt-in Docker write access has its own netns and isn't covered — another
reason the read-only default matters.

**Runaway limit.** Both compose templates set `pids_limit: 4096` on the
devcontainer (fork-bomb / stuck-loop backstop). Deliberately *not* a
`mem_limit` — a fixed memory ceiling would OOM-kill legitimate heavy builds;
memory/CPU caps are documented as an override instead. The "Docker socket
write access is opt-in" test also asserts `pids_limit` is present.

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

`release.yml` then fires on the tag: GHCR `:vX.Y.Z`/`:latest`, npm with
provenance, and the `github-release` job creates the GitHub Release from the
tag's `## [X.Y.Z]` section.

Internal notes:

- The bump commit touches only `package.json` + `CHANGELOG.md` (neither in
  `rebuild.yml`'s `paths:` filter), so a bump-only push fires `release.yml`
  alone. But GitHub evaluates `paths:` across *every* commit in a push —
  pushing a template-touching feature and the bump together fires
  `rebuild.yml` too, and both race to push `:latest` (harmless: identical
  content, last-writer-wins; ~7 min wasted). Separate the pushes: land the
  feature via PR first, then `npm version && git push --follow-tags` on its
  own.
- Concurrency guards: `rebuild.yml` uses `cancel-in-progress: true` (a newer
  push supersedes; `:latest`/`:weekly` are mutable and get re-pushed).
  `release.yml` uses `cancel-in-progress: false`, grouped per tag —
  serialize, **never** cancel mid-publish (a kill between the GHCR push and
  `npm publish` could leave a partial release). Don't "simplify" the two into
  one shared group.
- `release.yml`'s "Verify tag matches package.json" step fails fast on a
  hand-minted mismatched tag. Use `npm version`.
- Don't run `npm publish` locally — CI uses `--provenance`; a manual publish
  skips the supply-chain attestation users can verify.
- CHANGELOG content is hand-written, never generated;
  `promote-changelog.mjs` only relabels it. The CI gate (`release.yml`
  "Verify CHANGELOG.md has an entry") greps for `^## [X.Y.Z]` before any
  publish; `.githooks/pre-push` mirrors it locally (opt-in, bypassable — CI
  is the real gate; don't weaken that step). Keep the `## [X.Y.Z]` heading
  format: the gate, the promotion script, and the release-notes extraction
  all key on it.
- The GitHub Release is automatic: the `github-release` job (`needs:
  [publish]`, so only after GHCR + npm succeed) extracts the tag's section
  and creates the Release via `gh` — idempotent, falls back to
  `--generate-notes`. That's why it needs `contents: write` while `publish`
  stays `contents: read`.

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
- `:latest` (floating, `rebuild.yml` weekly cron + template pushes) — opt-in
  base-layer security freshness over reproducibility. Not referenced by `aic
  init` output.

Before "simplifying" the two workflows into one or re-pointing `aic init` at
`:latest`, re-read this tradeoff. Supabase CLI and Dagger use the same pinned
model; Earthly's floating-with-coupling is the documented anti-pattern.

## Don't do

- **Don't weaken smoke/CLI tests** in either workflow. They cover real
  security guarantees: `EXEC=0` **plus `POST/BUILD=0`** (read-only socket-proxy
  by default), the always-on `169.254.0.0/16` metadata block, the pre-`up`
  override scan, the `.env` PreToolUse block, scoped sudo (no arbitrary
  `chown`), the self-protection root-444 lock (`gitconfig.local` + the baked
  shell rc files), and the npm-quarantine sanity check
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
  `/etc/codex/requirements.toml` (root-owned), the **managed** Codex hook
  wiring for `pre-tool-use.sh` (see below). Codex and OpenCode install via
  their standalone installers (`chatgpt.com/codex/install.sh`;
  `opencode.ai/install` with `--no-modify-path` into `~/.opencode/bin`), not
  npm — deliberate, so self-update works — at the cost of leaving them
  outside the `NPM_CONFIG_MIN_RELEASE_AGE` quarantine (which still covers npx
  MCPs). All three CLIs are a baked floor that `refresh_ai_tools()` floats to
  latest on each create.
- `template/aic-firewall` — outbound iptables allowlist; new hosts expand
  what an in-container AI can reach. `cmd_enable` resolves into a staging
  ipset and `ipset swap`s it in, and **never sets `policy ACCEPT`** — that's
  what keeps re-enabling strengthen-only (no open window, no fail-open on a
  0-IP resolution). Don't reintroduce a flush-to-ACCEPT. The
  `block-metadata` subcommand (auto-run by post-create) is strengthen-only for
  the same reason — it only adds a `169.254.0.0/16` DROP, never opens anything;
  keep both invariants if you touch this script.
- `template/hooks/pre-tool-use.sh` — blocks reads of `.env` and other
  sensitive paths. Loosening the matchers (`is_blocked_env`,
  `bash_touches_env`, `is_curl_pipe_sh`, `is_protected_path`, or the
  `Bash|Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Glob` matcher in
  `claude-settings.json`) weakens the model. Shared by all three tools:
  Claude registers it via `~/.claude/settings.json` (post-create), Codex via
  the managed `/etc/codex/requirements.toml`. Hooks in `~/.codex/config.toml`
  are non-managed → untrusted → silently skipped in autonomous mode; **don't
  move it back there** (a prior version did, and the hook never ran for
  Codex).
- `template/hooks/opencode-guardrail.js` — OpenCode's slice of that same
  guardrail: a dependency-free plugin whose `tool.execute.before` maps
  OpenCode's `{tool, args}` to the JSON `pre-tool-use.sh` reads on stdin,
  `spawnSync`s it, and `throw`s on exit 2. `setup_opencode()` wires it by
  absolute path (`"plugin": ["/etc/aic/hooks/opencode-guardrail.js"]`) in the
  generated `~/.config/opencode/opencode.json` — no trust prompt, and it
  fires even with `permission."*"=allow`. Keep the logic in `pre-tool-use.sh`
  (single source of truth); the shim only maps + dispatches. Don't add a
  second native `permission` deny that could diverge. Guarded by the
  "opencode guardrail blocks a .env read" test.
- `template/aic-chown-volumes`, `template/aic-lock-gitconfig` — the only
  scripts allowed via `NOPASSWD` sudo; touching them changes the privileged
  surface. `aic-lock-gitconfig` locks a hardcoded list to `root:root 0444` —
  `~/.gitconfig.local` plus the baked login-shell rc files (`~/.zshrc`,
  `~/.bashrc`, fish config) — so a tool session can't plant persistence for
  the next `aic shell`; keep the list hardcoded, never argv.
  `aic-chown-volumes` reads targets from `.devcontainer/chown-paths`, **never
  argv** — that's what stops the grant from becoming `sudo aic-chown-volumes
  /etc/sudoers.d`. The prefix allowlist (`/workspace/`,
  `/home/vscode/.cache/`) plus `-h`/non-traversing `-R` is the boundary;
  widening to broader `$HOME` would expose the root-locked
  `~/.gitconfig.local` and is a load-bearing decision. Guarded by the "scoped
  sudo cannot chown arbitrary paths" test.
- `.github/workflows/*.yml` — CI secrets (`NPM_TOKEN`, GHCR via
  `GITHUB_TOKEN`). `publish` jobs run only on push/schedule/dispatch, never
  `pull_request`, so fork PRs can't trigger publishes.

## Commit signing (`aic signing`)

The host signing key is never forwarded (the no-`~/.ssh`/no-agent guarantee),
so `aic signing` provisions a *sandbox-only* ed25519 key in the
`aic-auth-global` volume under `~/.config/aic-auth/signing/` (key + a `mode`
marker: `auto`/`byok`/`disabled`). Load-bearing choices, don't undo them:

- The signing config lives inside the root-locked `~/.gitconfig.local`,
  appended by `setup_commit_signing()` *after* the host `[include]` so it
  overrides host signing — container-only; the host gitconfig stays RO. Keep
  it in that one file: the root-444 smoke test then still covers it, and an
  in-session tool can't inject `credential.helper` via a separate unlocked
  include.
- Applied on (re)create only, never live: `~/.gitconfig.local` is rewritten
  and re-locked each creation; a `mode` change lands on the next `aic
  rebuild`. A live edit would need a privileged *unlock* a compromised
  session could abuse before the re-lock — don't add one to "make it
  instant".
- The mutating actions are unprivileged: `devcontainer exec` as `vscode`
  (container must be up; no sudoers entry). Generating the key in-container
  is what keeps owner + 0600 correct across the Linux UID-remap. `status`
  reads the volume host-side and works anytime.
- `--register` writes to the user's GitHub account (`gh api POST
  /user/ssh_signing_keys`) — opt-in only, never auto-register.
- Guarded by the "aic signing wires a sandbox signing key" test, which stages
  a key, recreates, and asserts signing is wired *and* `~/.gitconfig.local`
  is still `root 444` — don't weaken the root-lock assertion.

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
