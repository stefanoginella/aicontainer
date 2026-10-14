# Image tag pinning and download integrity

Read this page before you change the image tag logic in the `aic` CLI, the Compose templates, or any download in `template/Dockerfile`.

## Image tag pinning

Read this section before you edit the CLI.

In pull mode, `aic init` and `aic sync` write
`ghcr.io/stefanoginella/aicontainer:vX.Y.Z` into the generated compose file.
`X.Y.Z` is the installed `package.json` version, which `read_aic_version()`
reads.

- `template/docker-compose.pull.yml` ships the literal placeholder `:latest`.
  It occurs five times: two comments and three managed `image:` lines.
- `apply_template()` uses `sed` to rewrite each occurrence to `:vX.Y.Z`.

> **Warning:** Do not pin the template itself. The `:latest` placeholder keeps
> the rewrite idempotent, so `aic sync` can pin the tag again cleanly.

If you change the GHCR repository path, update **all** of these:

1. the template,
2. the `sed` pattern in `apply_template()`,
3. the GHCR references in `README.md` and in the user guide (`docs/user/`),
4. the `ghcr.io` entry in the `aic-firewall` allowlist,
5. the image tags in both workflows.

## Image download integrity

A download that fails without failing the build ships in `:latest` and in
`:vX.Y.Z`. The old `sh -c "$(curl …)"` zsh setup did exactly that: when curl
failed, `sh -c ""` exited 0.

Thus every curl or git fetch in `template/Dockerfile` obeys these rules:

- The step starts with `set -eu;`.
- The step has no `||` and no `set +e`.
- Each download writes to a file first:
  `curl -fsSL --proto '=https' --tlsv1.2 -o FILE URL`.
- Nothing is piped into a shell, `tar`, `dpkg`, or `gpg`.
- The first use of each file is its check.

These rules do not cover apt steps and uv steps.

### Rules (do not change)

1. **Release assets are pinned by sha256.**
   - git-delta, fzf, and fnm each have a `*_VERSION` ARG and the ARGs
     `*_SHA256_AMD64`/`*_SHA256_ARM64`.
   - `TARGETARCH` selects the ARG. Any other architecture fails.
   - The check is exactly the plain statement
     `echo "$SHA256  FILE" | sha256sum -c -;`. Thus no `||`, `&&`, `if`, or
     `!` can hide a mismatch.
2. **Renovate bumps only `*_VERSION`, never `*_SHA256`.**
   - Thus a bump PR fails the image build until a maintainer adds the new
     checksums. That is the fail-closed design.
   - Do not add a manager that rewrites the checksums.
   - Do not read a checksum from the same release at build time.
3. **Node floats inside its major line, but only to a signed release.**
   - This keeps the weekly refresh of `:latest` for Node security releases.
   - The keyring is `gpg-only-active-keys/pubring.kbx` of
     nodejs/release-keys at `NODE_RELEASE_KEYS_COMMIT`. `NODE_RELEASE_KEYS_SHA256`
     pins it. Thus a release signed by any other key fails the build.
   - `gpgv --output` writes the signed text of
     `latest-vN.x/SHASUMS256.txt.asc`. The build parses only that text, never
     the `.asc`.
   - gpgv writes the output file also when the signature is bad. Thus its exit
     status must stop the build. This is one more reason for no `||`.
   - Keep the output name different from the `.asc` name without its
     extension. Otherwise gpgv treats that file as detached data.
   - The release must not be older than `NODE_MIN_VERSION` (rollback guard,
     `sort -C -V`). The major of `NODE_MIN_VERSION` is the line that floats.
     Renovate raises it.
   - The build checks the tarball against the signed sha256. It unpacks the
     tarball into the layout of fnm
     (`$FNM_DIR/node-versions/vX.Y.Z/installation`), because `fnm install`
     does not verify what it downloads.
   - `fnm default` fails the build if fnm does not see the Node version. Check
     this layout when Renovate bumps fnm.
4. **apt repository keys are pinned by fingerprint.**
   - `gpg --show-keys` lists the primary keys of the downloaded gh and Docker
     keyrings. Every key must be in `GH_KEYRING_FINGERPRINTS` /
     `DOCKER_KEYRING_FINGERPRINTS`.
   - A key that the vendor drops, or signs again with a new expiry date, still
     passes.
   - A new key fails the build until a maintainer reviews it and adds it.
   - apt then uses those keys to check the floating `gh`/`docker-*` packages.
5. **The zsh theme and plugins are pinned by commit.**
   - The build fetches powerlevel10k, zsh-autosuggestions, and
     zsh-syntax-highlighting with `git fetch --depth 1 origin <commit>`. The
     checkout must equal the `*_COMMIT` ARG.
   - A commit id proves the content, not where it comes from. GitHub serves a
     commit that exists only in a fork through the upstream URL.
   - Thus the commit must also be an ancestor of the upstream branch in the
     renovate comment of the ARG. The build checks this with
     `merge-base --is-ancestor` in a throwaway clone that holds only commits.
   - The Renovate `git-refs` manager proposes new commits on that branch.
   - oh-my-zsh is not fetched. It comes from the digest-pinned base image. The
     build fails if it is missing. Thus nothing falls back to an unpinned
     clone.
   - The pinned theme commit also pins gitstatusd. The p10k installer checks
     gitstatusd against the sha256 in the `install.info` of that commit.
6. **Some downloads float on purpose:**
   - the official Claude, Codex, and OpenCode installers. They are a baked
     floor that updates itself. The build still downloads each installer
     completely before it runs.
   - apt packages (signed repositories).
   - `uv tool install semgrep` (PyPI, no hash lock).
   - `uv python install`. uv checks the sha256 that is built into the
     digest-pinned uv image.

## Why Renovate, not Dependabot

`renovate.json` keeps the pins current. Dependabot cannot do these tasks:

- **Bump an `ARG *_VERSION` pin.** In a Dockerfile, Dependabot updates only
  `FROM` lines. A custom regex manager reads the `# renovate:` comment above
  each `ARG` (git-delta, fzf, fnm, Node).
- **Bump an `ARG *_COMMIT` pin.** The `git-refs` datasource proposes the next
  commit on the upstream branch of the zsh theme, the zsh plugins, and the
  Node release keyring. Dependabot has no datasource for a commit on a branch.
- **Bump a digest in a file that is not a manifest.** `smoke.yml` asserts the
  exact digest-pinned `docker-socket-proxy` image. A regex manager keeps it
  equal to the Compose files. Without it, each proxy bump fails the smoke test.
- **Bump both Dockerfiles in one PR.** `template/Dockerfile` and
  `.devcontainer/Dockerfile` change together, so the dogfood copy does not
  drift.
- **Tell the reviewer what to do by hand.** `prBodyNotes` asks for the new
  `*_SHA256` checksums or a keyring review. The build fails closed until the
  maintainer does this (rule 2).
- **Pin a GitHub Action to a SHA.** `helpers:pinGitHubActionDigests` changes a
  tag to a full commit SHA and writes the `# vX.Y.Z` comment. Dependabot bumps
  an action that is already pinned, but it does not pin a tag.

Do not add a Dependabot version-update config next to Renovate. Two bots open
conflicting PRs for the same pins.

## Update a pin

### A release checksum

Do this when Renovate bumped a `*_VERSION`.

1. Download the asset for **both** amd64 and arm64 into an empty scratch
   directory. Use the exact URL that the Dockerfile builds.
2. Run `shasum -a 256` (macOS) or `sha256sum`.
3. Compare each value with upstream. Upstream is the release asset digest on
   GitHub, or `fzf_<version>_checksums.txt` for fzf.
4. Put the values in the `*_SHA256_*` ARGs in the same PR.
5. Let CI build both architectures.

### The Node keyring

Do this when Renovate bumped `NODE_RELEASE_KEYS_COMMIT`.

1. Find out if the commit changed `gpg-only-active-keys/pubring.kbx`.
2. If it did, review the added or removed releaser keys against the releaser
   list in the nodejs/node README.
3. Put the sha256 of the file in `NODE_RELEASE_KEYS_SHA256`.

### An apt key

Do this when the build fails with "unreviewed … repository key".

1. Compare the new fingerprint with the fingerprint that the vendor publishes.
   For gh, use the GitHub CLI Linux install docs. For Docker, use the Docker
   install docs.
2. Add the fingerprint to the `*_FINGERPRINTS` ARG and to the comment above
   it.

Remove a fingerprint only when the vendor has retired the key.

## Tests

Guarded by the download-integrity check in `tests/test-aic-host-security.sh`
and the "managed zsh loads the pinned theme, plugins, and tools" smoke in
`smoke.yml`.

- Every `curl` URL must match the table of pinned downloads in the check, or
  its short list of floating installers.
- A new download extends one of the two lists, together with a pin.
- The `--self-test` run of the check changes the real Dockerfile in known
  ways. Examples: `|| true` after a check, `set +e`, a heredoc `RUN <<'SH'`
  script with an unpinned download, a fork-only commit without the ancestry
  check, … . The run fails if the check does not report one of them.
- Extend the self-test with every new rule.
