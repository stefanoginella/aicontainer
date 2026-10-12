# Releasing

Read this page before you cut a release, or before you change `release.yml`, `rebuild.yml`, `CHANGELOG.md`, `scripts/promote-changelog.mjs`, or `.githooks/pre-push`.

This page is for maintainers. Releases are tag-driven. A push of a `v*` git tag
is the only thing that publishes a new `:vX.Y.Z` image to GHCR or a new
version to npm.

## Day-to-day pushes and releases

|                | What triggers it                                                | What ships                                                                  |
| ---            | ---                                                             | ---                                                                         |
| Runtime/CLI PR | merge to `main` that touches template, CLI, tests, package/scripts | Validate and refresh `:latest` / weekly tag. Nothing on npm.             |
| Docs-only PR   | merge to `main`                                                 | Nothing is published.                                                       |
| Release        | `npm version <bump> && git push --follow-tags`                  | Immutable `:vX.Y.Z`, npm, GitHub Release; conservative `:latest` promotion. |
| Weekly cron    | Mondays 06:00 UTC                                               | Pulled/no-cache `:latest` + `:weekly-YYYY-VV`; no npm.                      |

`aic init` pins users to `:v{installed-aic-version}`. Thus **only a release
reaches pinned users**. Runtime/CLI merges refresh the floating security
track. They do not change the version pin of any user. When a fix must reach
ordinary users, prefer small, frequent patch releases.

## Cut a release

When you are asked to cut a release, do exactly these steps:

1. Start from a clean, current `main`. Run `git checkout main && git pull`.
   Make sure that the working tree is clean.
2. Make sure that the notes for this release are under `## [Unreleased]` in
   `CHANGELOG.md`. They should already be there, because contributors add them
   when changes land.
   - If the section is empty or stale, write the notes **by hand** from
     `git log <last-tag>..HEAD`. Use Keep-a-Changelog headings. Commit them.
   - Do not rename the heading and do not add a date. `npm version` does that.
   - Never generate the text automatically from commits. The project tried
     it, reverted it, and did not like it.
3. Pick the bump (patch, minor, or major). See [Pick the bump](#pick-the-bump).
4. If `template/` changed since the last release, sync the dogfood
   devcontainer:
   - Run `aic sync` **from the host**. Do not run it in the container, because
     the PreToolUse hook blocks writes to `.devcontainer/`.
   - Commit the result.
   - The dogfood devcontainer is in build mode. Thus `.devcontainer/` holds
     copies of `template/`. If you skip this step, it drifts.
5. Run `npm version <bump> && git push --follow-tags`.

The same flow as commands:

```bash
git checkout main && git pull
# The release notes should already be under ## [Unreleased] in CHANGELOG.md.
# Add them while you work. `npm version` promotes that section to the new version.
npm version patch         # or: minor / major. Promotes the changelog, bumps,
                          # commits, and creates the v* tag.
git push --follow-tags    # pushes both the commit and the tag
```

> **Warning:** Check `npm config get ignore-scripts` before you run
> `npm version`. If the value is `true`, `npm version` silently skips the
> changelog promotion.

The sandbox image sets `npm config set ignore-scripts true` as hardening. This
setting also stops the `preversion`/`version` hooks of `npm version`. The bump
commit then ships without a `## [X.Y.Z]` section, and the pre-push and CI
gates fail it.

- If the value is `true`, use `npm version <bump> --ignore-scripts=false` for
  that one command.
- Do not change the global config. That weakens the image default.
- If a plain `npm version` already ran and the bump commit is still
  **local**, do these steps:
  1. Run `node scripts/promote-changelog.mjs` by hand.
  2. Run `git commit --amend` to add the promoted `CHANGELOG.md` to the commit.
  3. Run `git tag -f -a vX.Y.Z -m X.Y.Z`.
  4. Push.

## Pick the bump

- **patch**: a security or freshness rebuild, an internal Dockerfile cleanup,
  a hook fix that does not change behavior, or docs that are important enough
  to ship. Most releases are patch releases.
- **minor**: you added an `aic` command or flag, a tool, or a template field.
  The change is backwards-compatible.
- **major**: you removed a flag, changed the default behavior, or changed the
  structure of the `.devcontainer/` files so that `aic sync` breaks for
  existing projects.

## The changelog and its lifecycle scripts

`CHANGELOG.md` is **maintained by hand**, in
[Keep a Changelog](https://keepachangelog.com/) format. You write the text.
Nothing is generated automatically from commits. Add notes under
`## [Unreleased]` while you work.

At release time, `npm version` does the mechanical promotion. It runs two
lifecycle scripts, unless they are suppressed (see the warning above):

- `preversion` runs `promote-changelog.mjs --check`. If `[Unreleased]` is
  empty, it stops the bump before it changes `package.json`. You cannot
  release nothing, and a failed attempt leaves the tree clean.
- `version` runs `promote-changelog.mjs`. It:
  - renames `[Unreleased]` to `## [X.Y.Z] - <date>`,
  - opens a new, empty `[Unreleased]`,
  - fixes the compare links,
  - runs `git add` on `CHANGELOG.md`, so it goes into the bump commit.

`promote-changelog.mjs` only relabels the notes that you wrote. It never
generates content.

The GitHub Release notes are the resulting `## [X.Y.Z]` section, copied
without change.

### Changelog gates

- The CI gate is the `release.yml` step "Verify CHANGELOG.md has an entry".
  It greps for `^## [X.Y.Z]` before any publish. Do not weaken that step.
- `.githooks/pre-push` does the same check locally. It is opt-in and you can
  bypass it. CI is the real gate. Enable the hook once per clone with
  `git config core.hooksPath .githooks`.
- The hook stores the `git show` output before it runs `grep -q`. A producer
  pipeline under `pipefail` rejects a large, valid changelog incorrectly: the
  early match sends SIGPIPE to `git show`.
- Keep the `## [X.Y.Z]` heading format. The gate, the promotion script, and
  the release-notes extraction all depend on it.

## What `release.yml` does

`release.yml` starts on the tag. It runs a release flow that you can restart.
It makes sure that these artifacts exist:

- `ghcr.io/stefanoginella/aicontainer:vX.Y.Z` (immutable),
- `aicontainer@X.Y.Z` on npm, with a provenance attestation,
- a GitHub Release for the tag, with notes from the `## [X.Y.Z]` section of
  `CHANGELOG.md`.

Then it promotes the mutable channels conservatively.

### Guard steps

The guard steps reject a tag when:

- the tag commit is not an ancestor of the default branch,
- the tag name does not match `package.json`,
- the changelog section for the version is missing.

### Reruns and partial releases

- A rerun accepts an existing GHCR version index only when its
  index annotations identify this release: the revision (release commit), the
  version, and the channel. A mismatch fails.
- A legacy version without annotations is kept only when the matching
  immutable npm tarball exists. It is never promoted to `:latest`. Otherwise
  CI fails, so that it does not guess.
- A rerun accepts an existing npm version only when its integrity matches the
  local pack.
- If one of the two artifacts is absent, CI publishes only the missing side.
  Thus a partial run can recover.

### Channels

- npm `latest` never moves backward.
  - npm pre-releases use `next`.
  - An older recovered version uses a version-specific `recovery-*` dist-tag,
    so `latest` does not roll back.
- CI copies GHCR `:latest` from the already-published immutable manifest only
  when both conditions are true:
  - the version is npm latest,
  - the current GHCR latest is not a newer security-refresh image.
- If CI cannot prove which image is more recent, it does not change
  `:latest`.

### The GitHub Release

- CI creates the GitHub Release automatically after publish. The step is
  idempotent.
- The release is marked latest only when npm says that the version is latest.
- If the changelog notes are not available, the step uses generated notes.

### Permissions

- Only the GitHub Release job has `contents: write`.
- Only the publish job has `packages: write` and OIDC `id-token: write`.
- Every checkout uses `persist-credentials: false`.

## Concurrency (internal)

- All releases are serialized globally. CI never cancels a release during
  publish.
  - Every release shares one global `aicontainer-release` concurrency group,
    with `cancel-in-progress: false` and `queue: max`.
  - Do not serialize per tag. Do not cancel a partial publisher.
  - Up to 100 pending runs can queue. You can restart each run.
- Keep the workflow-level concurrency groups of the release and
  security-refresh workflows separate. Their cancellation semantics are
  different.
- The GHCR-mutating `publish` jobs of both workflows also share the job-level
  `aicontainer-registry-publish` lock, with `cancel-in-progress: false` and
  `queue: max`.
  - The lock serializes the inspect/build/promote critical section across
    both workflows.
  - It closes the check-then-publish (TOCTOU) race around mutable tags.

## `rebuild.yml` (internal)

- `rebuild.yml` validates changes to the template, the CLI, the tests, the
  package metadata, the lifecycle scripts, and `smoke.yml`.
- Its main/schedule/manual runs can publish. They share a cancel-in-progress
  group. PR validation is scoped to the ref.
- Before it publishes a mutable tag, it proves that the template matches the
  current HEAD of the default branch.
- Scheduled and manual builds use `pull: true` and `no-cache: true`. A
  security refresh must not silently use a stale apt or tool layer again.

## CHANGELOG entry style

Write `[Unreleased]` bullets so that a reader can scan them quickly:

- Write one bullet for one change, under one heading. Do not put two changes
  in one bullet.
- Start with a bold headline of approximately 12 words or fewer. State the
  effect that the user sees, not the internal mechanism.
- Add a maximum of approximately 2 sentences of detail after the headline.
  Do not tell the debugging story. The *how* goes in the contributor guide
  (`docs/contributing/`), the user guide, and the commit body.
- Do not list the changed files inline. Add a maximum of one short
  parenthetical at the end, for example `(aic, post-create.py)`.
- Released `## [X.Y.Z]` sections are immutable. Do not rewrite a shipped
  section, because the GitHub Release renders from it.

## Fix a bad release

`:vX.Y.Z` is immutable. You cannot publish again under the same tag. To fix a
bad release, ship another patch. You can revert or fix forward:

```bash
git revert <bad-commit>   # or fix forward
npm version patch
git push --follow-tags
```

The old `:vX.Y.Z` stays. Users on a bad version can pin to a known-good
earlier release:

```bash
npm install -g aicontainer@<previous>
cd my-project && aic sync && aic rebuild
```

## Things not to do

- **Do not run `npm publish` locally.** CI uses `--provenance`. A manual
  publish skips the supply-chain attestation that users can verify.
- **Do not push a `v*` tag before you bump `package.json`.** Use
  `npm version`, which keeps the two in lockstep. Otherwise the CI guard fails
  the release.
- **Do not bump `package.json` in a feature PR.** A version bump is its own
  commit, which `npm version` creates. Thus the tag points at a clean release
  commit, not at a merge with many purposes.
- **Do not force-push `main` and do not rewrite tags.** GHCR already received
  the content that the tag pointed to. Rewritten history creates ghost tags
  and confuses users on pinned versions.
- **Do not tag a release without a `CHANGELOG.md` entry for it.** CI does not
  publish a version that has no `## [X.Y.Z]` section, so the tag is lost.
  Update the changelog *before* you run `npm version`.

## Why there are two workflows

Read this section before you merge the two workflows into one, or point
`aic init` at `:latest`.

The npm CLI is tightly coupled to the filesystem of the container (hooks,
sudoers, helper-script paths). A floating `:latest` would let the CLI and the
image drift apart. The two tracks serve different audiences:

- `:vX.Y.Z` is immutable and comes from `release.yml`. `aic init` pins it.
  Users on a given aic version always pull the exact image that CI built at
  release time.
- `:latest` floats. It comes from `rebuild.yml` (the weekly cron and relevant
  runtime/CLI pushes). It puts base-layer security freshness before
  reproducibility.
  - Managed `aic init` output does not reference it.
  - Release promotion must not overwrite a newer security-refresh image.

Supabase CLI and Dagger use the same pinned model. The floating model with
coupling of Earthly is the documented anti-pattern.

## Quick reference

| To do this                               | Do this                                                            |
| ---                                      | ---                                                                |
| Land a fix or feature                    | Merge a PR to `main`.                                              |
| Cut a release                            | `npm version patch && git push --follow-tags`                      |
| Fix a bad release                        | Ship another patch (revert or fix forward). The old `:vX.Y.Z` stays. |
| Refresh `:latest` manually               | `gh workflow run rebuild.yml`                                      |
| Run a release again manually             | `gh workflow run release.yml --ref refs/tags/vX.Y.Z`               |
| Pin downstream users to an older version | (Users do this) `npm i -g aicontainer@<old> && aic sync && aic rebuild` |
