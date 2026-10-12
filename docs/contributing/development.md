# Development

Read this page before you set up a development checkout, write code for aicontainer, or open a pull request.

This project is small on purpose. The goal is a lean devcontainer that you can
audit, for `claude`, `codex`, and `opencode` in bypass or auto-approve mode.
Keep this goal in mind when you propose a change.

## Ground rules

- **Read the [threat model](../user/security.md) first.** Evaluate every
  change to the `template/` files against it.
  - Some changes weaken isolation. Examples: a new capability, a new sudoers
    entry, a host path mount, a wider socket-proxy allowlist, or socket-proxy
    `POST`/`BUILD` on by default.
  - Tell the reviewer about such a change explicitly in the PR description.
- **Keep the surface small.** If you can solve a problem in 20 lines or in a
  new helper script, use the 20 lines. The project retired its predecessor,
  `docker-utils`, because it had too many scripts.
- **Do not add new AI tools to the base image.** Claude Code, Codex, and
  OpenCode are the chosen set. If you use Copilot CLI or another tool, install
  it in the `Dockerfile.project` of your project.
- **Pin versions.** A new external download in `template/Dockerfile` needs a
  pinned version with a `# renovate:` annotation, so Renovate can keep it
  current. The download must also match the table of pinned downloads or the
  short list of deliberately floating installers. The rules are in
  [Image tag pinning and download integrity](image-integrity.md).

## Set up a development checkout

```bash
git clone https://github.com/stefanoginella/aicontainer ~/aicontainer
~/aicontainer/install.sh                 # symlinks `aic` into ~/.local/bin
npm install -g @devcontainers/cli        # a checkout install does not include it

# Smoke-test the template in a throwaway project (CI runs the same path)
mkdir -p /tmp/aic-test && cd /tmp/aic-test && git init -q
aic init --build                          # copies template/* into .devcontainer/
aic up
aic shell
```

You can also run `aic` directly, without a symlink on your PATH:

```bash
AIC_HOME=~/aicontainer ~/aicontainer/aic init --build
```

The CI smoke suite (`.github/workflows/smoke.yml`) uses exactly that form. A
PR must pass it.

> **Note:** Do not copy the template directly with
> `cp -R template /tmp/test/.devcontainer`. Use `aic init`. The template ships
> `docker-compose.pull.yml` and `docker-compose.build.yml`, and no
> `docker-compose.yml`. Thus `devcontainer up` does not find a compose file.
> `aic init` selects the correct variant and renames it.

## Coding conventions

- **Bash scripts**:
  - Use `set -euo pipefail`.
  - Run `bash -n` to check the syntax.
  - Do not use `eval`.
  - A module in `lib/aic/` gets these options from `aic`. Start it with
    `# shellcheck shell=bash`. The rules for the modules are in
    [Repository layout](architecture.md).
  - Every shell script must pass ShellCheck with no warnings. See
    [Lint the shell scripts](#lint-the-shell-scripts).
  - Quote every variable expansion in a condition.
- **Python (`post-create.py` and the `post_create_*.py` modules)**:
  - Follow [The post-create package](architecture.md#the-post-create-package):
    one list of modules, relative imports, and no bytecode.
  - Use only the standard library by default.
  - `postCreateCommand` runs the script with `/usr/bin/python3 -I`. The only
    third-party dependency is `tomli-w`, which writes the Codex
    `config.toml`. The image installs it hash-pinned and offline under
    `/opt/aic-python`.
  - Do not add dependency resolution at runtime before the policy and config
    setup.
  - Add type hints where they do not add noise.
- **Dockerfile**:
  - Combine related `RUN` commands to keep the layer count low.
  - End every `apt-get install` layer with
    `apt-get clean && rm -rf /var/lib/apt/lists/*`.
  - Follow the download rules in
    [Image tag pinning and download integrity](image-integrity.md).
- **YAML**:
  - Use a 2-space indent.
  - Do not use anchors, unless the duplication is a real problem.

## Lint the shell scripts

`tests/test-aic-shellcheck.sh` runs `shellcheck -x -S warning` on every shell
script that the repository owns. Its `SCRIPTS` list is the only list of
these scripts.

- Run it locally:

  ```bash
  bash tests/test-aic-shellcheck.sh            # skips when shellcheck is not installed
  bash tests/test-aic-shellcheck.sh --require  # fails when shellcheck is not installed
  ```

  The `for test in tests/*.sh` loop also runs it. Install ShellCheck
  (`brew install shellcheck`, `apt-get install shellcheck`) to lint locally.
  CI uses version 0.11.0.
- When you add a shell script, add its path to `SCRIPTS`. The test fails
  when a tracked shell script is not in the list, and when a listed file is
  missing. A tracked file is a shell script when its name ends in `.sh`, or
  when its first line is a `sh`/`bash` shebang or `# shellcheck shell=`.
- Do not list `.devcontainer/`. It is the generated copy of `template/`.
- Fix a warning. In `template/` (a security review trigger), change the code
  only when the fix cannot change the behavior. Otherwise, add a line-level
  `# shellcheck disable=SCxxxx # <reason>` comment.

The "Static test - shell scripts pass a pinned ShellCheck" step in
`smoke.yml` downloads a pinned ShellCheck release and checks its sha256
before it runs the test with `--require`. Thus CI never skips the check and
never uses the ShellCheck of the runner. To change the version:

1. Download `shellcheck-<version>.linux.x86_64.tar.xz` from the
   koalaman/shellcheck GitHub release into an empty scratch directory.
2. Run `shasum -a 256` (macOS) or `sha256sum`, and compare the value with the
   asset digest on the GitHub release page.
3. Change `SHELLCHECK_VERSION` and `SHELLCHECK_SHA256` in the same commit.

## Submit a change

1. Open an issue first if the change is more than a few lines. It is easier
   to agree on the approach before you write the code.
2. Make a branch from `main`. Keep each PR focused: one logical change per PR.
3. Make sure that CI passes.
   - The pinned ShellCheck and the host CLI and privileged-helper tests in
     `tests/` run first.
   - Then `rebuild.yml` and `release.yml` call the real-devcontainer smoke
     suite in `smoke.yml` after their `build` job.
   - The tests make sure that `claude`, `codex`, `gh`, and `uv` resolve, and
     that the socket-proxy is reachable.
   - The tests also cover real security guarantees:
     - the Docker object-read toggles plus `POST/BUILD=0` (the Docker default
       is `none`),
     - external read/write consent for Docker,
     - resolved-config validation, and the early pre-`up` scan that warns
       about host-access grants in project-owned override files,
     - path-unique project identity and migration,
     - metadata drops on IPv4 and IPv6,
     - the `.env` guardrail in the PreToolUse hook,
     - sanitized seeds and the credential bridge (auth sync),
     - scoped volume ownership: the scoped sudoers entry for
       `aic-chown-volumes` cannot become an arbitrary `chown`,
     - the root-managed Git and shell files
       (`/etc/aic/user-config/gitconfig` and the baked shell rc files are
       root-owned `0444`),
     - the read-only `.git` control paths,
     - dropped capabilities,
     - the npm-quarantine check (`NPM_CONFIG_MIN_RELEASE_AGE` ≤ 30 days).
4. Update the user guide (`docs/user/`) if you change observable behavior.
   Examples: commands, defaults, mounted paths, capabilities, or the
   allowlist.

> **Warning:** Do not weaken a test in `tests/` or `smoke.yml`. If a test
> fails for a valid reason, fix the regression, not the assertion.

## Changes that we do not merge

- Changes that import host credentials automatically: the SSH agent,
  `ANTHROPIC_API_KEY`, or the host `gh` token. aicontainer does not forward
  these on purpose.
- Blanket `NOPASSWD: ALL` sudo for the `vscode` user.
- `--privileged`, `SYS_ADMIN`, or raw Docker socket mounts.
- Docker socket write access (socket-proxy `POST`/`BUILD`) as the default.
  Write access is opt-in per project through `aic init --docker` for a reason.
  See the [threat model](../user/security.md).
- `.devcontainer/` configs that an AI generates for each project (the
  `docker-utils` model). By design, every project gets its `.devcontainer/`
  from the same template.

## Verify changes locally

The CI smoke tests run in a real devcontainer. Do these steps locally to get
close to CI, so you do not push broken changes.

1. Run the host tests:

   ```bash
   for test in tests/*.sh; do bash "$test"; done
   for test in tests/*.py; do PYTHONDONTWRITEBYTECODE=1 python3 -I "$test"; done
   for test in tests/*.mjs; do node "$test"; done
   ```

2. Test the real container path:

   ```bash
   mkdir -p /tmp/aic-test && cd /tmp/aic-test
   git init -q
   AIC_HOME=/path/to/aicontainer-checkout /path/to/aicontainer-checkout/aic init --build
   AIC_HOME=/path/to/aicontainer-checkout /path/to/aicontainer-checkout/aic up
   devcontainer exec --workspace-folder . claude --version
   devcontainer exec --workspace-folder . curl -fsS http://socket-proxy:2375/_ping
   # npm quarantine check (must be ≤ 30 days, or npx-based MCPs fail to install)
   devcontainer exec --workspace-folder . bash -lc 'echo "$NPM_CONFIG_MIN_RELEASE_AGE"'
   ```

For a change to the CLI only, `aic init` in a temporary directory is usually
enough:

```bash
TMP=$(mktemp -d) && cd "$TMP" && git init -q
AIC_HOME=/path/to/aicontainer-checkout /path/to/aicontainer-checkout/aic init
grep "image:" .devcontainer/docker-compose.yml   # must show :vX.Y.Z, not :latest
```
