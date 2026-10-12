# Multi-project model

This page explains which data aicontainer shares between projects and which
data stays in one project. It also explains how aicontainer copies your host
preferences into the container without your raw host config.

## Data scopes

> **Note:** Your work stays, and it does not cross into other projects. A
> path-unique **per-project named volume**
> (`aic-<folder>-<path-hash>_aic-sessions`) holds these items:
>
> - Claude and Codex transcripts and prompt history
> - the OpenCode database and checkpoints
> - Claude auto memory
> - user-level skill, agent, command, prompt, and plugin surfaces
>
> This data stays after `up` and `rebuild`. aicontainer never writes it into
> the host home. Only `aic destroy`, after you confirm it, removes the data.
>
> Each create resets the parts that load before your first prompt:
>
> - user-level `CLAUDE.md`/`AGENTS.md`
> - tool settings
> - Claude rules
> - Claude MCP servers
>
> See [Config seeding from the host](#config-seeding-from-the-host).

| Data | Scope | Storage |
|---|---|---|
| Claude/Codex/OpenCode login state; `gh` and npm login entries; Semgrep login; sandbox signing key | **Global** | Fixed subpaths of `aic-auth-global` |
| Shell command history entered inside aicontainer | **Global** | `aic-shell-history` (host history is never mounted) |
| Claude/Codex transcripts and prompt history | **Per-project** | `<path-unique-project>_aic-sessions` |
| Claude/Codex user config, memory, skills, agents/commands, rules/prompts, plugins | **Per-project** | Whole tool homes below the same sessions volume. Reset on each create: `CLAUDE.md`/`AGENTS.md`, settings, Claude `rules/`, and Claude MCP servers. Kept: auto memory (`MEMORY.md`), skills, agents/commands, plugins, Codex rules/prompts |
| OpenCode config/instructions, session db, storage, and snapshots | **Per-project** | Same sessions volume; its two credential files are synchronized globally |
| `gh` config (`config.yml`: aliases, pager, editor, …) and npm settings (`npmrc`: registry, `script-shell`, …) | **Per-project** | Same sessions volume; only the login entries are synchronized globally |
| Sanitized host preferences | **Per-project, regenerated** | `<path-unique-project>_aic-sanitized-seed`, read-only to the agent |
| Project source | Host bind | The current canonical project root at `/workspace` |

## Tool homes

The unrestricted devcontainer never mounts the global Claude, Codex, OpenCode,
`gh`, or npm directories. Instead, each canonical tool home is a symlink into
`~/.aic-sessions/tool-homes/` in the volume of the current project. These are
the canonical tool homes:

- `~/.claude`
- `~/.codex`
- the two OpenCode homes
- `~/.config/gh`
- `~/.config/npm`

## Credential bridge

One dedicated sidecar is the only service that sees both these tool homes and
the five global tool-auth subpaths. The sidecar has no network and no
capabilities. It continuously reconciles four exact files:

- Claude `.credentials.json`
- Codex `auth.json`
- OpenCode `auth.json`
- OpenCode `account.json`

So login, logout, and token refresh go to all projects. The bridge shares no
other filename.

### `gh` and npm login entries

The `gh` file `hosts.yml` and the npm file `npmrc` contain login state. They
also contain settings that run code, for example:

- a per-host `gh` pager, editor, or browser
- an npm `registry`, `script-shell`, or `node-options`

For these two files, the bridge copies only the login entries:

- **`gh`:** per host, the token, the user, the account tokens, and
  `git_protocol`.
- **npm:** the `//registry/:_authToken`, `_auth`, `username`, and `_password`
  lines. The bridge accepts only literal values (no `${VAR}` expansion).

The global copy holds nothing else. A project copy keeps its own settings, with
one exception: a login change from another project rewrites `hosts.yml` with
login entries only. If the bridge cannot parse a file safely, it never
overwrites the file and never shares it.

### Rules for the credential bridge

- The bridge accepts only files with these properties: the owner matches, the
  file has a single link, and the file size is bounded.
- It copies the files atomically with mode `0600`.
- It ignores unsafe or malformed paths.
- Its initial reconciliation uses the newer file ("newer wins"). This
  reconciliation completes before the devcontainer starts.
- Signing and Semgrep use their own fixed global subpath mounts.
- The root of the auth volume is never exposed.

### What this model gives and what it costs

This model keeps the easy part: you log in one time and work on twenty
projects. It also removes the prompt and transcript bleed between projects.

The trade-off that remains is the credentials. A compromised session in any
project can use the shared tokens that you logged into inside aicontainer.

- Use OAuth grants with the least privilege.
- Use a fine-grained `gh` PAT.

Every project can also read the global shell history.

> **Warning:** Do not type secrets into shell commands. Every project can read
> the global shell history.

## Config seeding from the host

aicontainer never mounts raw host config into the unrestricted devcontainer.
Before the devcontainer starts, a fixed service reads exactly four files:

- `~/.gitconfig`
- `~/.claude/settings.json`
- `~/.codex/config.toml`
- `~/.config/opencode/opencode.json`

This service runs as root only. It has no network, no workspace, a read-only
root filesystem, and no auth or session mounts. It writes four root-owned JSON
objects into a per-project volume. The long-running agent gets that volume
read-only.

### The personal overlay directory

The service also reads the opt-in directory `~/.config/aicontainer/`. This
directory has fixed filenames:

- `rc.zsh`
- `p10k.zsh`
- `statusline.{sh,mjs,js,py}`

These files are *code*. So the service copies them verbatim and does not
filter them with an allowlist. They exist only because you put them there.
They land root-owned and read-only.

The host `aic` CLI also recognizes the exact `status-relay` enable marker in
that directory. aic does not copy the bytes of this marker into the container.
The sanitizer reads no other filename.

### What the sanitizer keeps and what it removes

The sanitizer copies only known preference fields. It recursively removes
literal keys that can hold credentials, such as these:

- `env`
- `headers`
- `authorization`
- API keys
- tokens
- secrets
- passwords

aicontainer enforces the security-critical behavior separately, at a
root-managed precedence:

| Field | Container always sets |
|---|---|
| Claude `permissions.defaultMode` | `bypassPermissions` |
| Claude hook/policy | `/etc/claude-code/managed-settings.json` |
| Codex `approval_policy` | `never` |
| Codex `sandbox_mode` | `danger-full-access` |
| OpenCode `permission` | `{ "*": "allow" }` |
| OpenCode policy/plugin | `/etc/opencode/opencode.json` + the shared guardrail |

The Codex guardrail and lifecycle hooks are in `/etc/codex/requirements.toml`,
with a root-managed hook directory. Codex gates a user hook on trust, so it
skips a user hook in autonomous mode. Claude and OpenCode use their supported
system-managed configuration.

All three tools send guardrail events to the same root-owned policy script.
Claude and Codex also send their opt-in status events to the metadata-only
relay. See [Agent status relay](status-relay.md).

**Seeded preferences** include these items:

- **Claude:** model, theme, editor, effort, and MCP/plugin metadata.
- **Codex:** model and personality, plus `[features]`, `[notice]`,
  `[projects.*]`, and `[mcp_servers.*]`.
- **OpenCode:** provider, model, MCP, agent, instruction, theme, keybind,
  formatter, and LSP definitions.
- **Git:** a fixed set of identity and workflow preferences that cannot run
  code.

**Dropped fields** include these items:

- **Claude:** permissions, hooks, and auth helpers.
- **Codex:** approval, sandbox, and hooks.
- **OpenCode:** permission, plugin, and inline provider secrets.
- **All three tools:** literal MCP env/header credentials.
- **Git:** every key that runs code or holds a path (`include`, aliases,
  credential helpers, hooks paths, SSH commands, remotes, pagers/editors,
  signing-key paths).

aicontainer validates the Git identity and the safe preferences again. Then a
fixed helper installs them one time as `root:root 0444`.

### MCP servers

aicontainer seeds MCP metadata for all three tools.

- Binaries that exist only on the host will not exist in Linux.
- URL-based servers and npm-installed servers usually work.
- aicontainer removes literal MCP env/header credentials on purpose. So
  authenticate inside the sandbox, or reference an environment variable in the
  container.

Claude, Codex, and OpenCode user config is per project. aicontainer reconciles
it from the sanitized seed when it recreates the container. Root-managed
policy stays separate from those writable homes.

### What each create resets

Each create does these steps:

- It replaces the user-level `CLAUDE.md`/`AGENTS.md` with the aic sandbox
  note. It also does this when an earlier session made the file a link.
- It removes Codex `AGENTS.override.md` from the tool homes.
- It removes OpenCode `opencode.jsonc`/`config.json` from the tool homes.
- It empties the Claude user `rules/` directory.
- It removes MCP servers, MCP approvals, and `env` from the Claude state file
  (`.claude.json`). Onboarding, workspace trust, and the other state stay.

Your host MCP servers come back from the sanitized seed.

Auto memory (`MEMORY.md`), skills, agents/commands, and plugins stay, because
they are the working state of the project. Keep lasting instructions in the
`CLAUDE.md`/`AGENTS.md` of the repository.

VS Code opens a terminal only after this setup is complete. The setup includes
the AI-tool update. So the first open after a rebuild can take one minute or
more.

### OpenCode providers

Custom provider and model definitions carry over. The sanitizer removes
provider keys that look like secrets, recursively. Run `opencode auth login`
inside the container one time. That credential stays, and all projects use it.

### Config that runs commands is never seeded

The sanitizer drops these fields. It does not rewrite them:

- the Claude `statusLine`
- tool `hooks`
- `apiKeyHelper`
- the gitconfig `credential.helper`, aliases, and includes

The reason: an allowlist that accepts one arbitrary command string is not an
allowlist.

A personal statusline comes in through the opt-in verbatim overlay instead.
You supply the script. aic installs it root-locked and supplies its own fixed
command. See [Personal Claude Code statusline](personal-config.md).

### Host paths that the agent does not see

These host paths are not exposed to the agent:

- the raw config files on this page
- host tool history, transcripts, and credentials
- shell rc files
- `~/.ssh`
- the SSH agent

The container creates its own login state and project data in Docker volumes.
Only one set of host files crosses verbatim: the files that you put in
`~/.config/aicontainer/` on purpose (`rc.zsh`, `p10k.zsh`, `statusline.*`).
These files land root-owned and read-only.
