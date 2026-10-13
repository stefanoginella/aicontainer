# Security

This page shows what the in-container agent can touch on your host. It also
explains the threat model (what is sandboxed and what is not) and how to make
the host Docker daemon stronger.

## What crosses the boundary

This table shows, at a glance, what the in-container agent can touch on your
host. To print this table for your *actual* configuration, run `aic preflight`
in a project. `aic up` also shows it automatically at the end of every run.

| Surface | Crosses the boundary? |
|---|---|
| Project directory | **Yes, read-write** (`/workspace`). This is the one writable host path. `.devcontainer/` and the Git control files of the repository (config, hooks) are read-only. Submodules and nested repositories are not read-only: see [Threat model](#threat-model). |
| Host Git / Claude / Codex / OpenCode config | Only a fixed, root-only, networkless one-shot sanitizer can see the raw files. The agent receives root-owned JSON that contains allowlisted preferences. The sanitizer removes executable Git config, inline credentials, MCP env/header secrets, and security-policy fields. See [Config seeding from the host](multi-project.md). |
| Host shell startup files (`.zshrc`, `.bashrc`, fish config, p10k) and Claude `statusLine` | **Not automatically.** Shells start from root-managed aicontainer profiles, and aic drops the host `statusLine` command. Thus nothing on the host side plants startup code. You can opt in for each file: copy it into `~/.config/aicontainer/` (`rc.zsh`, `p10k.zsh`, `statusline.*`). These files cross verbatim and are root-locked in the container. See [Personal shell config and statusline](personal-config.md). |
| Host home, `~/.ssh`, SSH-agent socket | **No.** aic does not mount or forward them. |
| Host credentials (API keys, `gh` token, keychain) | **No.** aic forwards nothing automatically. You log in one time *inside* the container. |
| Host agent-status receiver | **No by default.** A host-global marker opts all projects into metadata-only Claude/Codex lifecycle callbacks at one fixed local URL. Repositories cannot enable or redirect it. See [Agent status relay](status-relay.md). |
| Package-manager caches | **No.** They are container-local volumes, not your host caches. |
| Clipboard / browser | **No.** aic bridges nothing. |
| `.env*` files | **Best-effort only.** The `.env` file of your project is physically in `/workspace`. The [PreToolUse hook](whats-in-the-box.md) refuses the obvious reads. But the hook matches file names in the tool call, so it is not a boundary. Keep secrets that you cannot lose out of the project directory. |
| Session transcripts, prompt history, auto memory, user-level skills/plugins | They persist in a **path-unique per-project volume**. aic never writes them back to your host home or shares them with another checkout. aic resets user-level instructions, settings, Claude rules, and Claude MCP servers on each create. See [Multi-project model](multi-project.md). |
| Host Docker daemon | **Object APIs are off by default.** Only proxy ping/version stay available. `--docker-read` opts into sensitive object/inspect/log/file APIs. `--docker` opts into read-write control of the host daemon for testcontainers / in-container Compose. See [Threat model](#threat-model). |
| **Outbound network** | **Mostly open by default.** The container can reach the internet, your LAN, and services on your host machine. This includes services bound to `127.0.0.1`, through `host.docker.internal` on Docker Desktop and OrbStack. aic blocks IPv4/IPv6 link-local and common cloud-provider metadata endpoints on every create. To restrict the rest, opt in to the [network allowlist](network-allowlist.md). A committed `.devcontainer/firewall-enable` turns it on at every start. |

The full reasons are in [Threat model](#threat-model). Give the most attention
to the network row.

## Threat model

### Sandboxed

- **Filesystem.** The project is the only writable host path. Raw host
  tool/Git config is visible only in the isolated one-shot sanitizer. The agent
  sees the fixed, allowlisted JSON output of the sanitizer, read-only. Host
  home, shell startup files, `~/.ssh`, agent sockets, package caches, and tool
  history are not in the container.
- **Process namespace.** Container processes do not see host processes.
- **Runaway limit.** The devcontainer runs with `pids_limit: 4096`. Thus a fork
  bomb or a stuck agent loop cannot use all host PIDs. If a workload needs
  more, raise the limit (or add `mem_limit` / `cpus`) in
  `docker-compose.override.yml`.
- **Docker daemon.** By default, the digest-pinned proxy exposes only ping and
  version. It does not expose container/image/network/volume list, inspect,
  logs, archive reads, create, or build.
  - `--docker-read` intentionally exposes the object read APIs. These APIs can
    show metadata, logs, and files of unrelated containers.
  - `--docker` adds write/build. Thus it permits a host escape through a
    privileged sibling container.
  - Both opt-ins need matching consent that aic stores outside the repository.
    The consent stays across sync until `--no-docker` revokes it.
- **Runtime privilege.** aic drops all Linux capabilities, then adds only the
  narrow helper/firewall set. `NET_RAW` stays absent. The raw Docker socket is
  available only below a root-owned `0700` directory. Only the fixed ownership
  helper uses it, for bounded GET-only mount/volume inspection. The
  unrestricted user uses the proxy, never that socket.
- **Control plane.**
  - `.devcontainer/` and the Git control files of the repository
    (`.git/config`, `.git/config.worktree`, `.git/commondir`, `.git/hooks`)
    are read-only inside the container.
  - aic mounts `.git` onto itself, so the agent cannot rename it and plant a
    new one.
  - aic creates `.git/commondir` (content `.`) and an empty
    `.git/config.worktree` for these mounts. aic refuses a symlink at any of
    these paths.
  - One side effect: `git rev-parse --git-common-dir` prints an absolute path.
  - Managed hooks, tool policy, Git config, and shell startup are in
    root-owned system paths.
  - Scoped sudo exposes only fixed-purpose wrappers with hardcoded
    destinations. The volume helper also proves that each target is an
    ordinary named volume on the current container.
- **Cloud metadata / link-local.** Every create adds strengthen-only drops for:
  - IPv4 link-local (`169.254.0.0/16`)
  - Alibaba metadata (`100.100.100.200`)
  - IPv6 link-local (`fe80::/10`)
  - AWS IMDSv6 (`fd00:ec2::254`)

  These drops apply independently of the optional full allowlist.
- **Untrusted-repo guard.** Before aic-launched paths start Dev Containers,
  they do these steps:
  - Reject symlinked control inputs.
  - Verify every managed artifact.
  - Resolve all Compose layers. aic does not trust a grep for this.
  - Check services, mounts, builds, capabilities, namespaces, devices, ports,
    networks/volumes, includes/providers, configs/secrets, lifecycle hooks,
    and protected path overlays.
  - Pass the managed Compose project name, so a `.env` file at the repository
    root cannot redirect the stack.

  More rules of the guard:
  - Validation enables every Compose profile, so a profile-gated service
    cannot hide.
  - `devcontainer.json` keys and Compose keys are allow-lists. A key that aic
    does not review is a finding, not a silent pass.
  - The generated initializer repeats this gate before Compose creates the
    stack.
  - Project-owned code files (`post-create.project.sh`, `shell-rc.zsh`,
    `p10k.zsh`, `statusline.*`) are boundary expansions too. VS Code
    extensions or settings in `devcontainer.json` beyond the ones of aic are
    also boundary expansions. A clone supplies them, and they run before any
    prompt, with open network and the tool logins.
  - Managed drift needs `aic sync`.
  - An intentional boundary expansion needs `aic trust` or the one-run flag
    `--allow-unsafe`. Repository edits cannot write either approval.

### Not sandboxed (unless you opt in)

- **Direct VS Code bootstrap.** Dev Containers parses the `devcontainer.json`
  of the repository. It runs its `initializeCommand` on the host before
  `aic initialize` can run. aic cannot validate an arbitrary initializer from a
  repository before it runs. So generate and review the managed files first.
  For an untrusted clone, do these steps:
  1. Run `aic init --force`.
  2. Examine the overrides and the project code files.
  3. Use `aic up` for the first launch (preferred).
- **The `.vscode/` folder of the repository.** aic validates only
  `.devcontainer/`. These files run in the container when VS Code opens the
  folder, and only VS Code Workspace Trust guards them:
  - a committed `.vscode/settings.json` (terminal profiles, interpreter paths)
  - a `.vscode/tasks.json` task with `runOn: folderOpen`

  Read the folder before you trust an unknown clone. VS Code does not install
  the recommended extensions in `.vscode/extensions.json` automatically.
- **Host Git in a checkout that an agent changed.** Only the Git control files
  of the top-level repository are read-only. These paths still run files that
  the agent can write. So use host Git in such a checkout as you use it in a
  new untrusted clone:
  - *Submodules and nested repositories.* The agent can change the Git
    directory of a submodule (`.git/modules/…`). It can also create a nested
    repository and add it to the index. Host `git status`, `git diff`, and
    `git commit` go into each populated submodule and load its config. Thus a
    planted `core.fsmonitor` or hook runs on the host. Editors that open
    nested repositories do the same (the VS Code Git extension does this by
    default). `git ls-files --stage | grep '^160000'` lists them and does not
    go into them. If there are any, add `--ignore-submodules=all` to host
    `git status` and `git diff`, or use Git inside the container.
  - *Hook scripts kept in the repository.* Some hooks run project files:
    husky's `.husky/`, `lefthook.yml`, `.pre-commit-config.yaml`, or a
    `core.hooksPath` inside the worktree. Such a hook runs what the agent
    wrote on your next host commit. See
    [Git hooks on the host](#git-hooks-on-the-host).
  - *Earlier versions.* Up to 0.9.1, the agent could replace `.git` fully and
    write `.git/config.worktree`. If an agent in a checkout possibly was
    compromised, review `.git/config` and `.git/config.worktree` on the host
    one time.
- **Planted text in project tool state.** Each create resets the parts of the
  tool homes that load before your first prompt:
  - user-level `CLAUDE.md`/`AGENTS.md`
  - tool settings
  - Claude `rules/`
  - MCP servers, MCP approvals, and `env` in the Claude state file

  The rest persists in the volume of the project. It can carry text or code
  that an earlier session planted:
  - Claude auto memory (`~/.claude/projects/*/memory/MEMORY.md`)
  - skills, agents/commands, and plugins (with their hooks)
  - Codex skills/prompts

  This state never gets to another project. If an agent in a project possibly
  was compromised, read these files before you continue there. Or start
  again with `aic destroy`. A workspace `.mcp.json` is repository content. In
  bypass mode, Claude can start its servers and not ask you. So review it as
  you review all other code in the checkout.
- **Commands you run in a container shell.** Shell startup runs only
  root-owned code. But after startup, `PATH` starts with tool directories that
  the agent can write (`~/.local/bin`, the Node versions of fnm). This is
  because the AI CLIs update themselves there. A command that you type, or a
  prompt helper, can run a binary that the agent replaced. VS Code terminals
  also run through the VS Code server in the container, which the agent can
  change. The image `PATH` also ends with the default Node of fnm, so a
  process that does not start from a shell can run that Node too. Think of a
  shell in the container as a shell with the authority of the agent. Do not
  type secrets there that the agent must not see.
- **Network.** All other outbound traffic is open by default. Anything inside
  the container can reach `api.openai.com`, `api.anthropic.com`, and your LAN
  (cloud metadata is blocked, see above).
  - *Host services.* On Docker Desktop and OrbStack, `host.docker.internal`
    also reaches services on your host machine, **including services bound to
    `127.0.0.1`**. Examples are local databases, admin panels, model servers,
    and all other programs that listen on a port. (This was verified on
    OrbStack with a listener bound to `127.0.0.1`.) When the agent status
    receiver on port 8787 runs, it is one of these services.
  - On Linux Docker Engine, the name exists only if you add
    `extra_hosts: host.docker.internal:host-gateway`. But in both cases, the
    container can reach services that listen on all host interfaces through
    the bridge gateway address.
  - To restrict the rest, opt in to the
    [iptables allowlist](network-allowlist.md). When the allowlist is on, the
    container can reach the host only on TCP 8787, and only when the
    [status relay](status-relay.md) is enabled.
  - To keep the allowlist on, commit `.devcontainer/firewall-enable`. Then
    every start enables it before post-create and before a shell opens, or
    the container stops. Registry presets
    (`.devcontainer/firewall-presets`) add fixed hosts from the image, never
    hosts from the repository. The agent cannot change these files, because
    `.devcontainer/` is read-only in the container. They need no `aic trust`:
    with them, egress is never wider than the open default.
- **Git identity.** aic copies safe identity/workflow preferences from the
  host. Thus the agent can commit as that identity. aic does not forward
  host credential helpers and signing keys. For a sandbox-only key, use
  [`aic signing`](signing.md).
- **Git push to GitHub.** The managed Git config sets one credential helper:
  the root-owned `/usr/bin/gh`, for `https://github.com` and
  `https://gist.github.com` only. Thus the agent can push over HTTPS with the
  `gh` login that you make inside the container. This gives the agent no new
  power: it can already read the `gh` token in `~/.config/gh/hosts.yml`.
  Other hosts (GitHub Enterprise, GitLab, and others) get no helper, and the
  container has no SSH key. See
  [Push to GitHub from the container](install.md#push-to-github-from-the-container).
- **Sandbox signing key.** The agent in every project can read the key that
  `aic signing` creates. See [Commit signing](signing.md).
- **Secrets in the project directory.** The `.env*` check is a best-effort
  hook. It is not a mount or a permission. Think of all content in
  `/workspace` as readable by the agent.
- **Host credentials.** aic forwards nothing automatically. The AI can use
  only what you explicitly log in to inside the container: `claude /login`,
  `codex auth login`, `opencode auth login`, `gh auth login`.

  > **Warning:** Prefer a fine-grained `gh` PAT. These tokens are in the shared
  > `aic-auth-global` volume, so a compromised session in **any** project can
  > use every token that you logged in with.
- **Image build inputs.** The build fails if one of these pins does not match:
  - git-delta, fzf, and fnm are pinned by sha256.
  - The GitHub CLI and Docker apt keys are pinned by fingerprint.
  - The zsh theme and plugins are pinned by a commit on their upstream branch.
  - Node takes the newest release of its major line that a pinned Node
    releaser key signed.

  The build still trusts these inputs:
  - the official Claude Code, Codex, and OpenCode installers (they float so
    that the CLIs can update themselves)
  - the signed Ubuntu, GitHub CLI, and Docker apt repositories
  - PyPI for `semgrep`

> **Warning:** Do not use aicontainer on a network where access to internal
> services is a concern, or enable the
> [network allowlist](network-allowlist.md) there.

### Git hooks on the host

The container mounts `.git/hooks` and `.git/config` read-only, so the agent
cannot install a Git hook. But you run Git on the host. When a hook, or a
program that Git runs, is in the worktree, the agent can change it. Your next
host `git commit` or `git push` then runs that code on the host.

Use this pattern:

1. Keep the hooks in a host folder that no container mounts, for example
   `~/.config/aic-hooks/<project>`.
2. Set `core.hooksPath` to that folder on the host.
3. Make each hook call only tools that you installed outside all projects.
4. Run the checks of the repository in the container with `aic run -- <cmd>`.

```bash
mkdir -p ~/.config/aic-hooks/myapp
cat > ~/.config/aic-hooks/myapp/pre-commit <<'SH'
#!/bin/sh
exec aic run -- npm test
SH
chmod +x ~/.config/aic-hooks/myapp/pre-commit
git config core.hooksPath ~/.config/aic-hooks/myapp
```

`aic doctor` (check `git-hooks`), `aic up`, and `aic rebuild` warn when one of
these is in the worktree:

- the hooks folder (`core.hooksPath`, or `.git/hooks` when it is not set),
  other than `.git/hooks`
- a hook that is a symlink into the worktree
- the program of `core.fsmonitor` or `core.sshCommand`, or a relative path
  there

The warning never stops a start. aic checks where hooks live, not what they
do. A hook in a safe folder that runs a project file (for example
`npx lefthook`) still runs code that the agent can change. Read each hook
before you trust it, or commit with `--no-verify`.

## Hardening the host daemon

The isolation of the container is only as strong as the Docker daemon below
it. Two choices make the minimum protection higher. This is most important if
you enable Docker write access for a project:

- **Rootless Docker**
  ([docs](https://docs.docker.com/engine/security/rootless/)) or
  **`userns-remap`**
  ([docs](https://docs.docker.com/engine/security/userns-remap/)). These map
  container-`root` to an unprivileged host user. Thus even a
  `--privileged`/host-mount escape does not become real host root. (Opt-in
  Docker write access exposes this type of escape.) OrbStack and Colima
  already run the daemon in a VM, which gives you a similar boundary on macOS.
- **Docker access at none.** Keep Docker access at **none** (the default) for
  untrusted or prompt-injectable work. Opt into reads only when host object
  visibility is acceptable. Use write mode only where testcontainers or
  host-daemon Compose is necessary.
