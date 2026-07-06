# Contributing to aicontainer

Thanks for considering a contribution. This project is deliberately small — the goal is a lean, auditable devcontainer for running `claude` and `codex` in bypass / auto-approve mode. Please keep that in mind when proposing changes.

## Ground rules

- **Read the [threat model](README.md#threat-model) first.** Any change to the `template/` files needs to be evaluated against it. If a change weakens isolation (granting capabilities, opening a sudoers entry, mounting host paths, widening the socket-proxy allowlist, or turning socket-proxy `POST`/`BUILD` on by default), call it out explicitly in the PR description.
- **Keep the surface small.** If you can solve a problem in 20 lines or in a new helper script, pick the 20 lines. The `docker-utils` predecessor was retired specifically because it grew too many scripts.
- **No new AI tools in the base image.** Claude Code + Codex is the chosen surface. If you use OpenCode / Copilot CLI / something else, ship it in your project's `Dockerfile.project`.
- **Pin versions.** New external downloads in `template/Dockerfile` need a pinned version with a `# renovate:` annotation so Renovate can keep them current.

## Development setup

```bash
git clone https://github.com/stefanoginella/aicontainer ~/aicontainer
~/aicontainer/install.sh                 # symlinks `aic` into ~/.local/bin
npm install -g @devcontainers/cli        # not bundled with a checkout install

# Smoke-test the template in a throwaway project (this is what CI runs)
mkdir -p /tmp/aic-test && cd /tmp/aic-test && git init -q
aic init --build                          # copies template/* into .devcontainer/
aic up
aic shell
```

If you'd rather not symlink `aic` onto your PATH, invoke it directly: `AIC_HOME=~/aicontainer ~/aicontainer/aic init --build`. The CI smoke job (`.github/workflows/rebuild.yml`) uses exactly that form and is the bar a PR has to clear.

> Don't `cp -R template /tmp/test/.devcontainer` directly — the template ships `docker-compose.pull.yml` and `docker-compose.build.yml` (no `docker-compose.yml`), so `devcontainer up` won't find a compose file. `aic init` is what picks the right variant and renames it.

## Coding conventions

- **Bash scripts**: `set -euo pipefail`, run `bash -n` to syntax-check, no `eval`, no unquoted variable expansions in conditions.
- **Python (`post-create.py`)**: stdlib by default; any third-party deps go in the PEP 723 inline header so `uv run` installs them on the fly (currently just `tomli-w` for emitting Codex `config.toml`). Type-hinted where it doesn't add noise.
- **Dockerfile**: combine related `RUN` commands to keep layer count down; `apt-get clean && rm -rf /var/lib/apt/lists/*` at the end of every `apt-get install` layer.
- **YAML**: 2-space indent, no anchors unless the duplication is genuinely painful.

## Submitting changes

1. Open an issue first if the change is more than a couple of lines — easier to align before code is written.
2. Branch off `main`. Keep PRs focused — one logical change per PR.
3. CI must be green. The `smoke` job verifies `claude`, `codex`, `gh`, `uv` resolve, the socket-proxy is reachable but read-only by default (`EXEC`/`POST`/`BUILD` all return 403), cloud-metadata/link-local egress (`169.254.0.0/16`) is blocked, the pre-`up` scan flags host-access grants in project-owned override files, the PreToolUse hook blocks `.env`, the scoped sudoers entry can't be turned into an arbitrary `chown`, and the self-protection files (`~/.gitconfig.local` + the baked shell rc files) are root-owned `0444`.
4. Update the README if you change observable behavior (commands, defaults, mounted paths, capabilities, allowlist).

## What we will not merge

- Changes that auto-import host credentials (SSH agent, `ANTHROPIC_API_KEY`, host `gh` token). These are deliberately not forwarded.
- Granting blanket `NOPASSWD: ALL` sudo to the `vscode` user.
- Adding `--privileged`, `SYS_ADMIN`, or raw Docker socket mounts.
- Making Docker socket write access (socket-proxy `POST`/`BUILD`) the default. It's opt-in per project via `aic init --docker` for a reason — see the threat model.
- Per-project AI-generated `.devcontainer/` configs (the `docker-utils` model). The template is copied verbatim by design.

## Reporting security issues

Please **do not** open a public issue for security findings. Use **GitHub's private security advisory** flow on this repository (Security → Advisories → "Report a vulnerability") — it's only visible to the maintainer. Reports are acknowledged within 72 hours.

## Code of conduct

By participating in this project you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).
