# aicontainer

[![npm version](https://img.shields.io/npm/v/aicontainer?logo=npm)](https://www.npmjs.com/package/aicontainer)
[![release](https://github.com/stefanoginella/aicontainer/actions/workflows/release.yml/badge.svg)](https://github.com/stefanoginella/aicontainer/actions/workflows/release.yml)
[![rebuild](https://github.com/stefanoginella/aicontainer/actions/workflows/rebuild.yml/badge.svg)](https://github.com/stefanoginella/aicontainer/actions/workflows/rebuild.yml)
[![License: MIT](https://img.shields.io/npm/l/aicontainer?color=yellow)](LICENSE)
[![Container: GHCR](https://img.shields.io/badge/container-ghcr.io-2188ff?logo=github)](https://github.com/stefanoginella/aicontainer/pkgs/container/aicontainer)
[![Devcontainer spec](https://img.shields.io/badge/devcontainer-spec-blue?logo=visualstudiocode)](https://containers.dev/)

A sandboxed devcontainer for [Claude Code](https://claude.ai/code),
[Codex](https://github.com/openai/codex), and [OpenCode](https://opencode.ai)
in bypass / auto-approve mode, across many projects.

**Why?** These CLIs work best with auto-approve on. But on your real `$HOME`,
a prompt-injected dependency can then read `.env`, copy your shell history,
or push with your `gh` token. aicontainer puts the AI behind a devcontainer
boundary. You keep auto-approve on, and you do not rebuild your machine after
each incident.

## Features

- **Filesystem isolation.** The project directory is the only writable host
  path. Your home, `~/.ssh`, and the SSH agent are not in the container.
- **No Docker object access by default.** A digest-pinned
  [socket proxy](https://github.com/Tecnativa/docker-socket-proxy) allows only
  ping and version. Read or read-write access is an explicit opt-in.
- **Sanitized host config.** Host Git and tool preferences pass through a
  networkless sanitizer. The agent gets allowlisted fields only. Credentials,
  hooks, `statusLine`, and Git credential helpers, aliases, and includes are
  removed.
- **Log in once.** A networkless credential bridge shares only login tokens
  between projects. Transcripts, memory, and settings stay per project.
- **Validated before start.** `aic` checks the managed files and the fully
  resolved Compose model before Docker starts anything.
- **Network controls.** Cloud-metadata and link-local addresses are always
  blocked. An outbound allowlist is available as an opt-in.
- **Shared guardrail hook.** One PreToolUse hook refuses obvious `.env` reads,
  `curl | sh`, and writes to the sandbox control files, in all three tools.

Similar to the
[Trail of Bits devcontainer](https://github.com/trailofbits/claude-code-devcontainer),
with Codex and OpenCode added, three explicit Docker-access modes, and
root-managed shell and config startup.

## Quick start

You need Docker Engine 25+ with Compose 2.35+ (Docker Desktop, OrbStack,
Colima, Rancher Desktop, rootful Lima, or rootless Docker), Node.js 18+, and
a Git checkout. See [Install](docs/user/install.md) for the details.

1. Install the CLI:

   ```bash
   npm install -g aicontainer
   aic doctor            # optional: check the host
   ```

2. Log in once, in a scratch project. The logins work in all projects after
   this step:

   ```bash
   mkdir -p ~/sandbox/scratch && cd ~/sandbox/scratch && git init
   aic init && aic up && aic shell

   # Inside the container:
   claude /login
   codex auth login
   opencode auth login
   gh auth login
   ```

3. Use it in your project:

   ```bash
   cd my-project
   aic init      # writes a small managed .devcontainer/
   aic up        # validates the config, then starts the sandbox
   aic shell     # opens a shell in the container
   claude        # bypass mode, inside the sandbox
   ```

In VS Code, run `aic init` once, then use **Dev Containers: Reopen in
Container**. See [Usage](docs/user/usage.md).

> **Warning:** Do not open an unknown repository's `.devcontainer/` directly
> with **Reopen in Container**. VS Code runs its host-side command before aic
> can validate it. Run `aic init --force`, review the diff, then `aic up`.

## What crosses the boundary

| Surface | In the container? |
|---|---|
| Project directory | **Yes, read-write**, at `/workspace`. `.devcontainer/` and the Git control files are read-only. |
| Host home, `~/.ssh`, SSH agent, host credentials | **No.** You log in once inside the container. |
| Host Git and tool config | **Sanitized copy only.** Safe preference fields, read-only. |
| Host Docker daemon | **No object access** by default. `--docker-read` and `--docker` are opt-ins. |
| `.env*` files in the project | **Best-effort block only.** Keep secrets that you cannot lose out of the project directory. |
| Outbound network | **Mostly open** by default. Metadata endpoints are blocked. Opt in to the [allowlist](docs/user/network-allowlist.md). |

Run `aic preflight` to print this for your actual project. The full table and
the threat model are in [Security](docs/user/security.md).

## Documentation

The [documentation index](docs/README.md) has the full user guide and the
contributor guide. Common pages:

- [Install](docs/user/install.md) — prerequisites, install, first login,
  uninstall.
- [Usage](docs/user/usage.md) — commands, diagnostics, tools, shells, VS Code,
  the Claude Code plugin.
- [Customization](docs/user/customization.md) — project-owned overrides that
  survive `aic sync`.
- [Stack reference](docs/user/stack-reference.md) — the project-owned files
  for each stack, with copy-ready snippets.
- [Installing extra tools](docs/user/extra-tools.md) — `Dockerfile.project`
  and the Playwright recipe.
- [Updating](docs/user/updating.md) — update the AI tools and aicontainer.
- [Security](docs/user/security.md) — what crosses the boundary and the threat
  model.
- [Troubleshooting](docs/user/troubleshooting.md) — FAQ and known problems.
- [Stability contract](docs/user/stability.md) — what tools that build on
  aicontainer can rely on across releases.

## Contributing and security

Bugs, ideas, and pull requests are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md) first: the ground rules, the development
loop, and what we do not merge. By participating, you agree to the
[Code of Conduct](CODE_OF_CONDUCT.md).

Do not open a public issue for a security finding. Use the
[private security advisory flow](https://github.com/stefanoginella/aicontainer/security/advisories/new).

## License

[MIT](./LICENSE) © 2026 Stefano Ginella
