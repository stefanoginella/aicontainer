# aicontainer documentation

This folder has two guides. The user guide explains how to use aicontainer
in your projects. The contributor guide explains how aicontainer works inside
and which rules a change must keep.

## User guide

Start here if you run aicontainer in your projects.

| Page | Content |
|---|---|
| [Install](user/install.md) | Prerequisites, install, shell completion, first login, uninstall |
| [Usage](user/usage.md) | Per-project commands, pull and build mode, validation and `aic trust`, diagnostics, tools, shells, VS Code, the Claude Code plugin |
| [What's in the box](user/whats-in-the-box.md) | The security defaults and developer defaults of the image |
| [Installing extra tools](user/extra-tools.md) | Ad-hoc installs, `Dockerfile.project`, the Playwright recipe |
| [Customization](user/customization.md) | `docker-compose.override.yml`, named volumes and `chown-paths`, `post-create.project.sh`, VS Code extensions and settings, LSP recipes |
| [Stack reference](user/stack-reference.md) | The project-owned files for each stack (Node.js, Python, Go, Rust, Ruby, PHP, Java, C and C++), with copy-ready snippets |
| [Personal config](user/personal-config.md) | Your zsh config, p10k prompt, and Claude Code statusline in the sandbox |
| [Agent status relay](user/status-relay.md) | Opt-in lifecycle events for a host dashboard |
| [Updating](user/updating.md) | Update the AI tools and aicontainer, drift warnings, migration |
| [Multi-project model](user/multi-project.md) | What is global and what is per project, the credential bridge, config seeding from the host |
| [Commit signing](user/signing.md) | A sandbox-only signing key with `aic signing` |
| [Security](user/security.md) | What crosses the boundary, the threat model, host daemon hardening |
| [Network allowlist](user/network-allowlist.md) | The opt-in outbound firewall |
| [Troubleshooting](user/troubleshooting.md) | FAQ and known problems |
| [Stability contract](user/stability.md) | For tools: the stable commands, exit codes, JSON ids, files, and paths, and the release policy |

## Contributor guide

Start with [CONTRIBUTING.md](../CONTRIBUTING.md) and
[Development](contributing/development.md). AI coding agents start at
[AGENTS.md](../AGENTS.md), which tells them which page to read for each area.

| Page | Content |
|---|---|
| [Development](contributing/development.md) | Dev setup, coding conventions, pull requests, local verification |
| [Architecture](contributing/architecture.md) | Repository layout and what each part does |
| [Image integrity](contributing/image-integrity.md) | GHCR tag pinning, pinned downloads, how to update a pin |
| [Version drift](contributing/version-drift.md) | Offline drift warnings and the npm update check |
| [Project identity](contributing/project-identity.md) | Path-unique project names, migration, `.devcontainer/` and Git control paths |
| [Validation](contributing/validation.md) | The pre-Docker security gate, `aic trust`, diagnostics |
| [Host state](contributing/host-state.md) | The generated Docker socket setting and the status-relay consent |
| [Seeds and auth](contributing/seeds-and-auth.md) | Seed sanitizer, tool homes, post-create resets, credential bridge, signing |
| [Project overrides](contributing/project-overrides.md) | Rules for the project-owned override files |
| [Shell and overlays](contributing/shell-and-overlays.md) | Root-managed shell startup, personal overlay, AI-tool refresh |
| [Runtime policy](contributing/runtime-policy.md) | Docker access modes, metadata block, PID limit |
| [Security review](contributing/security-review.md) | Review notes for each security-sensitive file |
| [Releasing](contributing/releasing.md) | Release steps, CHANGELOG style, the two workflow tracks |
