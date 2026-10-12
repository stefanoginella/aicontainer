# Host seeds, tool homes, and reusable auth

Read this page before you change the seed sanitizer, the tool homes, the `setup_*` resets in `post-create.py`, the `aic-auth-sync` credential bridge, managed volume initialization, or `aic signing`.

For the user view of these features, see [Multi-project model](../user/multi-project.md) and [Commit signing](../user/signing.md).

## Seed sanitizer

The unrestricted container must never see raw host Git or tool config.

The `aic-seed-sanitizer` one-shot service is the only service with fixed raw mounts. It mounts these inputs:

- The four config inputs: `~/.gitconfig`, Claude settings, Codex config, and OpenCode config.
- The opt-in personal-overlay directory `~/.config/aicontainer`. See "Personal config overlay" in [Shell startup and overlays](shell-and-overlays.md).

The sanitizer runs as root only to read foreign-UID `0600` files. It has these limits:

- No network, no workspace, no auth, and no sessions.
- A read-only rootfs.
- `no-new-privileges`.
- `cap_drop: ALL`, plus only `DAC_OVERRIDE`.
- A small PID limit.
- A fixed system-Python command.

The sanitizer writes four root-owned, allowlisted JSON objects into the per-project sanitized volume. The main container mounts that volume read-only.

Sanitization recursively removes literal env, header, auth, key, token, secret, and password fields. Git uses a fixed list of safe keys and `/usr/bin/git --no-includes`.

### Personal overlay files

The personal overlay is the one exception to JSON sanitization. The files `rc.zsh`, `p10k.zsh`, and `statusline.{sh,mjs,js,py}` are **code**. The sanitizer copies them verbatim (bounded, root-owned `0444`) into the same sanitized volume. The sanitizer does not do these things to the overlay files:

- It never strips fields from them.
- It never merges them into the config of the main container.
- It never executes them.

Every one of those file names is a literal in `sanitize_seeds()`. The sanitizer never globs the seed directory.

The sanitized volume outlives the container. So each run removes an overlay output when its source is absent, empty, or rejected. If the sanitizer cannot remove an output, the run fails. Without this rule, a file that the human deleted (for example, because it held a token) stays installed and sourced.

### Rules for the sanitizer

- Do not mount a raw input into the main container.
- Do not add a non-JSON output other than the overlay files.
- Do not make a sanitizer failure soft. Keep it fatal.

## Per-project tool homes

One path-unique `aic-sessions` volume holds all Claude, Codex, OpenCode, gh, and npm data:

- config
- memory
- skills and plugins
- prompt history
- sessions

The data is below `~/.aic-sessions/tool-homes/{claude,codex,opencode-config,opencode-data,gh,npm}`.

The canonical tool paths are image-baked symlinks into those whole per-project homes. This includes `~/.config/gh` and `~/.config/npm` (`NPM_CONFIG_USERCONFIG` points into the npm home). The global auth volume stores no symlinks. The main container mounts no global tool parent.

### Precreated prompt and code roots

`setup_claude()` and `setup_codex()` precreate every known writable prompt or code root inside the project homes:

- skills
- agents and commands
- rules and prompts
- plugins

Keep these lists aligned with the "prompt/code persistence is project-isolated" smoke test. An empty new project must show the same isolated surface for inspection as a project where a CLI already used the feature.

### Managed memory and config files

`_replace_managed_file()` rewrites these managed memory and config files on every create:

- `CLAUDE.md`
- `AGENTS.md`
- Claude `settings.json`
- Codex `config.toml`
- `opencode.json`

The function creates a new `O_EXCL` file and renames it over the entry. It opens the parent one path component at a time, and it does not follow links. If a directory has the managed name, the function first moves that directory aside.

> **Warning:** Do not change this into an in-place write. A previous session owns these homes, so a symlink or hard link at the name would keep its planted text.

The setup removes names that load in place of a managed file or over a managed file:

- Codex `AGENTS.override.md`
- Claude `.config.json`
- OpenCode `config.json` and `opencode.jsonc`

`_ensure_tool_home()` replaces a tool home (or `tool-homes/`) that is a link. It never replaces the target of the link. It also restores the write bit of the owner.

## Claude rules and state-file resets

Two more Claude surfaces load before any prompt. So `setup_claude()` resets them too.

### User rules

User rules are `~/.claude/rules/**/*.md`. Claude loads them like `CLAUDE.md`. `reset_claude_rules()` does these steps:

1. It removes a link at `rules` (never its target), or it renames a real directory aside.
2. It creates a new empty `rules` directory.
3. It deletes the old tree with fd-relative calls. These calls unlink every link inside the tree and never follow a link.

If the function cannot delete a tree, the tree stays under the dot-named aside name. Claude does not load that name. The next create tries the delete again.

### State file

The state file is `$CLAUDE_CONFIG_DIR/.claude.json`, plus its suffixed variants in `CLAUDE_STATE_FILES`. `reset_claude_state()` removes these entries at the top level and in every `projects.<path>`:

- MCP servers.
- The grants that start a server: `enabledMcpjsonServers`, `enableAllProjectMcpServers`, and `enabledMcpServers`.
- `mcpContextUris`.

It also removes these top-level entries:

- `env`, because Claude applies it to its own process.
- `apiKeyHelper`.

All other state stays (onboarding, workspace trust, caches). The denials (`disabledMcpjsonServers`, `disabledMcpServers`) also stay, because they can only stop a server.

The function reads the file with no-follow, inode-checked, bounded reads. It replaces these files with the new-project seed, and it never keeps or merges them:

- a link
- a hard link
- a special file
- an oversized file
- content that does not parse as a JSON object

Only a failed write is a step error. The MCP choices of the host come back through `settings.json` from the sanitized seed.

## Surfaces kept on purpose

The setup keeps these surfaces on purpose:

- Claude auto memory (`projects/<path>/memory/MEMORY.md`)
- skills
- agents and commands
- plugins (with their hooks)
- Codex skills and prompts

These surfaces are the working state of the project. A reset would delete user work. The [Threat model](../user/security.md) states that they can carry planted text.

The setup also keeps Codex `rules/`. It holds command-approval policy (`prefix_rule`), not instructions. Also, `approval_policy = "never"` is always forced.

Workspace `.mcp.json` servers are repository content. In the managed bypass mode, Claude can approve them without a prompt unless they are denied. Newer Claude versions keep the approvals in the workspace `.claude/settings.local.json`. Neither file is in a tool home.

## Post-create order

### Rules (do not change)

1. In each `setup_*`, `_reset_managed_files()` tries every reset, also when one reset fails. So a blocked config file cannot skip the memory reset.
2. The `setup_*` resets run before `refresh_ai_tools()`. The updaters start the tools, and the tools must not load the settings, memory, rules, or MCP servers of a previous session. `lock_config()` also runs before `refresh_ai_tools()`, so a slow network cannot delay the Git identity and the root-locked config. See "AI-tool refresh on every create" in [Shell startup and overlays](shell-and-overlays.md).
3. `main()` runs every step through `_run_step()`. So one failure cannot skip the lock step or the project-hook step. Any failure still makes the exit status nonzero.
4. The template sets `"waitFor": "postCreateCommand"`, so VS Code opens no terminal before the reset.

Guarded by `tests/test-aic-post-create-reset.py`, the `waitFor` case in `tests/test-aic-host-security.sh`, and the "prompt/code persistence is project-isolated" smoke.

## Credential bridge (`aic-auth-sync`)

Login-once behavior comes from `aic-auth-sync`, not from shared tool homes. It is the only service that sees both of these:

- the per-project sessions root
- the five global tool-auth subpaths: `claude`, `codex`, `opencode`, `gh`, and `npm`

The sidecar runs continuously as the exact runtime UID:GID. Compose interpolates that value from the generated, gitignored `.env`. So the tracked Compose file stays byte-identical on all hosts.

The sidecar has these limits:

- No network.
- A read-only rootfs.
- `no-new-privileges`.
- All capabilities dropped.
- A PID limit of 32.

Its credential volume mounts stay writable by design.

### Synchronized files

The sidecar synchronizes only these files:

- Claude `.credentials.json`
- Codex `auth.json`
- OpenCode `auth.json` and `account.json`
- the login entries of gh `hosts.yml` and npm `npmrc` (see [Rules for gh and npm login entries](#rules-for-gh-and-npm-login-entries))

### File checks and sync direction

Each synchronized file must obey these rules:

- It is a regular file with a single link and the same owner.
- It is at most 1 MiB.
- It is inside a canonical `0700` directory.
- A JSON file is a non-empty object.

Reads use no-follow and inode checks. Writes are atomic, with mode `0600`.

The initial reconciliation is newer-wins. Its healthcheck gates the main container. After that, login, logout, and token-refresh changes go in both directions.

Do not add a glob, an unknown file name, or a config, prompt, plugin, or directory sync.

Signing and Semgrep keep separate fixed global subpath mounts in the main container. The broad auth root, `gh`, and `npm` are not mounted in the main container.

### Rules for gh and npm login entries

gh `hosts.yml` and npm `npmrc` mix login state with settings that run code:

- gh per-host settings: `pager`, `editor`, `browser`, `http_unix_socket`, `api_host`.
- npm settings: `registry`, `script-shell`, `node-options`, `git`, `prefix`, and more.

So the sidecar never copies these files whole.

#### Rules (do not change)

1. **Only strict-grammar login entries cross.**
   - gh: per host, `oauth_token`, `user`, `git_protocol` (`https` or `ssh`), and `users.<name>.oauth_token`.
   - npm: top-level entries (before any `[section]`) with the key `//host[:port][/path]/:` plus `_authToken`, `_auth`, `username`, or `_password`, and a literal value. The value has no `$`, no quotes (except the npm `"…"` around a value with `=`), no `;`, no `#`, and no `\`. The reason: npm expands `${VAR}` in keys and values.
   - Widen a grammar only for a value that the tool itself writes. Never widen it for a setting.
2. **The global copy holds only canonical login entries** (`_canonical_login()`). The gh writer quotes every value. So project B never receives a byte that project A wrote outside those grammars.
3. **The project copy keeps its own settings.** A project npmrc write replaces only its login lines and puts them first, so no `[section]` captures them. A gh write replaces `hosts.yml` with login entries. The sidecar never touches gh `config.yml`.
4. **The sidecar never "repairs" a project gh or npm file.** gh and npm rewrite these files in place, and the npmrc holds project settings. So the sidecar leaves an unparsable, oversized, or symlinked project file alone and does not share it (`_CredentialPair.repairs_project`). JSON files keep their repair-from-peer rule.
5. **Let the files settle before a read.** Both tools truncate a file, then write it. The sidecar skips a gh or npm pair while either file is younger than `AUTH_SYNC_SETTLE_NS`. So it never reads a half-written file as a logout or a cut-off token.
6. The gh YAML reader accepts only plain block mappings. Lists, anchors, flow values, multi-line values, tabs, and duplicate keys make the file unreadable. Do not replace the reader with a general YAML parser. The image has no YAML parser, and wider input means wider ambiguity.

Guarded by `tests/test-aic-auth-sync.py`, the template and Dockerfile assertions in `tests/test-aic-host-security.sh`, and the "prompt/code persistence is project-isolated" smoke in `smoke.yml`.

## Managed volume initialization

`initialize_managed_volumes()` must do these steps before Compose resolves the subpaths:

- Safely precreate every volume, subpath, and file.
- Validate the metadata of all existing volumes.

`prepare_host_seed_paths()` creates the missing fixed host seed files. So Docker never turns a missing file bind into a root-owned directory.

The legacy container path `.claude-sessions` migrates to the neutral `.aic-sessions` with no data loss.

`postCreateCommand` uses `/usr/bin/python3 -I` and the hash-pinned offline `tomli-w` under `/opt/aic-python`. Do not add runtime dependency resolution back before the policy and config setup.

### BusyBox helpers

The two BusyBox helpers in `initialize_managed_volumes()` stay separate runs.

> **Warning:** Do not merge the two helpers to save a container start. The sessions volume is agent-writable. If one helper mounted all volumes, a planted `tool-homes` symlink would send the `mv` or `cp` of the migration into the global auth volume or the shell-history volume.

Both helpers re-own only the entries with the wrong owner or group (`find … -exec chown -h {} +`). They never re-own the whole tree with `chown -R`.

Guarded by the initialize case in `tests/test-aic-host-security.sh`.

## Commit signing (`aic signing`)

The host signing key is never forwarded. This is the no-`~/.ssh` and no-agent guarantee. So `aic signing` provisions a *sandbox-only* ed25519 key in the `aic-auth-global` volume, under `~/.config/aic-auth/signing/`. The directory holds the key and a `mode` marker: `auto`, `byok`, or `disabled`.

### Rules (do not change)

1. The signing config is appended to the fixed staging config *after* the sanitized host signing intent. Then the config is validated and installed at `/etc/aic/user-config/gitconfig`. It can use only the hardcoded sandbox key path and the hardcoded allowed-signers path. Host key paths and includes never enter the config.
2. The signing config applies only on (re)create, never live. The root-managed destination is created once, and it cannot be replaced in that container. A mode change applies on the next `aic rebuild`. Do not add an unlock or update primitive.
3. The mutating actions are unprivileged. They run through `devcontainer exec` as `vscode`, so the container must be up. There is no sudoers entry. The key is generated in the container, and this keeps the owner and `0600` correct across the Linux UID remap. `status` reads the volume on the host side, so it works at all times.
4. `--register` writes to the GitHub account of the user (`gh api POST /user/ssh_signing_keys`). It is opt-in only. Never register a key automatically.

Guarded by the signing smoke. The smoke stages a key, recreates the container, and asserts two things: signing is wired, and `/etc/aic/user-config/gitconfig` is still `root 444`.
