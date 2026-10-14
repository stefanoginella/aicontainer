# Shell startup, personal overlays, and tool refresh

Read this page before you change the managed shell startup files (`template/.zshrc`, the bash and fish startup), the personal config overlay (`shell-rc.zsh`, `p10k.zsh`, `statusline.*`), `aic-lock-user-config`, `aic-statusline`, or `refresh_ai_tools()`.

## Root-managed shell startup

The managed launch paths are `aic shell` and the VS Code terminal profiles.
They start zsh, bash, and fish from root-owned files only. Thus an agent
cannot plant code that runs in the next human shell.

- `template/.zshrc` is the real managed zsh rc. The image copies it to
  `/etc/aic/shell/zsh/.zshrc`.
- oh-my-zsh comes from the base image.
- The image fetches the theme and the plugins at pinned commits.

### Rules (do not change)

1. **Everything that startup sources or runs is root-owned.**
   - oh-my-zsh, with the theme and the plugins, is in
     `/usr/local/share/oh-my-zsh`.
   - fnm is `/usr/local/bin/fnm`. Node versions stay in the vscode-owned
     `$FNM_DIR`, so `fnm install` works.
   - Each rc defines an `fnm` function that calls the absolute binary. This is
     necessary because the fnm cd hook calls `fnm` through PATH.
2. **Startup PATH lookups use only system directories.** oh-my-zsh and its
   plugins run `git`, `rm`, `tee`, and `eval "$(fzf --zsh)"`. The skel bashrc
   evals `lesspipe` and `dircolors`. The zsh rc and the bash rc set a PATH
   with only system directories while they load. At the end, they restore the
   full PATH.
3. **Caches that startup sources again are root-owned.**
   - p10k sources `$XDG_CACHE_HOME/p10k-dump-*.zsh` when the theme loads.
   - oh-my-zsh adds its cache to `fpath`.
   - While the framework loads, the `.zshrc` sets the non-exported
     `XDG_CACHE_HOME` to the root-owned `/usr/local/share/aic/zsh-cache`.
   - gitstatusd is baked into the `usrbin/` of the theme. p10k checks that
     directory before `~/.cache/gitstatus`.
   - A writable cache directory is not a fix. The agent can rename a
     root-owned child of its own `~/.cache`.
   - p10k instant prompt writes a cache that a later startup sources. The
     `.zshrc` sets `POWERLEVEL9K_INSTANT_PROMPT=off` after the personal
     overlay, so a `p10k configure` config cannot turn it on.
4. **No global rc runs first.** The distro and base-image `/etc/zsh/zshrc`
   and `/etc/bash.bashrc` run commands that they find through PATH. The
   managed `ZDOTDIR/.zshenv` sets `unsetopt GLOBAL_RCS`. Bash has no flag
   that skips only `/etc/bash.bashrc`, so the image replaces that file.
5. **No startup file comes from `$HOME`.**
   - The bashrc removes the skel reads of `~/.bash_aliases` and
     `~/.dircolors`.
   - The bashrc points the bash-completion user file and directory away from
     `$HOME`.
   - The bashrc sets `INPUTRC=/etc/inputrc`.
   - The image build fails if a read from the home directory is left.
   - Bash runs with `--noprofile --rcfile`. Fish runs with `--no-config`.

### Node outside a managed shell

A process that no managed shell starts does not run `fnm env`. Examples are
Claude Code hooks, MCP servers, the VS Code server, and `docker exec`. Thus
the image `ENV PATH` ends with `/home/vscode/.fnm/aliases/default/bin`. This
directory holds the default Node of fnm: `node`, `npm`, and `npx`.

Rules (do not change):

1. **The entry is the last one on the image PATH.** It comes after the system
   directories, so it never shadows a system binary. In a managed shell,
   `fnm env` puts the per-directory Node first, so `.nvmrc` still selects the
   version.
2. **No system directory holds a `node`.** Do not link the fnm Node into
   `/usr/local/bin` or into another system directory. The startup PATH of the
   managed shells (rule 2 above) and the PATH of root processes search these
   directories. A link there lets them run a binary that the agent can
   replace. Thus `env -i /bin/sh -c 'node -v'` finds no `node`. A caller that
   clears the environment must use the full path.
3. `aic-statusline` keeps its fixed list of `node` paths. Claude Code can
   start it with a reduced PATH.

Guarded by the "a process without shell startup finds the fnm default Node"
smoke in `smoke.yml` and the image PATH assertions in
`tests/test-aic-host-security.sh`.

### Residual risk

The [Threat model](../user/security.md) documents this residual risk:

- After startup, PATH starts with vscode-owned tool directories
  (`~/.local/bin`, the Node of fnm). Thus a typed command or a prompt helper
  can run a binary that the agent replaced.
- The image PATH ends with the vscode-owned default Node of fnm. Thus a
  process without shell startup that runs `node` can also run a binary that
  the agent replaced.
- VS Code terminals run through the vscode-owned VS Code server.

Startup hardening does not make a container shell more trusted than the
agent.

Guarded by the "self-protection files are root-owned 0444" smoke in
`smoke.yml` and the shell-startup assertions in
`tests/test-aic-host-security.sh`.

## Personal config overlay

The personal config overlay (`shell-rc.zsh`, `p10k.zsh`, `statusline.*`) lets
the trusted human bring a familiar zsh prompt, aliases, and a Claude
statusline into the sandbox.

Two sources feed one overlay. The project file wins.

- **Project-owned files:** `.devcontainer/shell-rc.zsh`,
  `.devcontainer/p10k.zsh`, and `.devcontainer/statusline.{sh,mjs,js,py}`.
- **The opt-in host seed:** `~/.config/aicontainer/{rc,p10k}.zsh` and
  `~/.config/aicontainer/statusline.*`. These files go **verbatim** through
  `aic-seed-sanitizer`. That is the only place where a raw host file is
  allowed. The host seed is never mounted into main.

The install has these steps:

1. `setup_personal_shell()` and `setup_statusline()` stage the winning file.
2. `aic-lock-user-config` installs it as `root:root 0444` under
   `/etc/aic/user-config/{shell,statusline}/`.
3. The baked `.zshrc` sources `p10k.zsh`, then `rc.zsh`, **after** the managed
   baseline.

Thus a personal prompt wins, but the managed history, fnm, and PATH setup
still runs first.

### Rules (do not change)

1. **The overlay is code, not data. It cannot be sanitized.** The bytes go
   verbatim into a sandbox that the agent can read. So the overlay is opt-in
   (by file presence), and the documentation says "no secrets in these
   files."
   - Never try to "sanitize" zsh with an allowlist.
   - Never widen the overlay to copy arbitrary host dotfiles automatically
     (`~/.zshrc`, `~/.p10k.zsh`). Use only the aic-namespaced seed directory
     and the project files.
2. **The root lock is not a privilege grant.** The file lands as
   `root:root 0444` and is created once. Thus an agent cannot change it, and
   the "shell startup is root-managed" guarantee stays true. But when zsh
   sources the file, its contents execute only as `vscode`. That is the same
   authority that the agent already has. It is the same risk class as
   `post-create.project.sh`.
   - Like that hook, the project-owned copies need exact `aic trust`.
   - The host seed is the file of the trusted human. It needs no trust.
   - Keep the install on the shared `aic-lock-user-config` path. Do not add an
     rc that is writable in `$HOME`.
3. **The shell overlay is for zsh only.** p10k and the `source` lines are in
   the managed `.zshrc`. Bash and fish keep the managed baseline unchanged. Do
   not source zsh syntax from the bash or fish startup files.
4. The overlay files are control-boundary paths (in `AIC_CONTROL_FILES`).
   They must be real files, never symlinks. Keep them out of the copy,
   rewrite, and remove lists of `apply_template()`, so sync never overwrites
   them.
5. **The statusline overlay carries the script, never a command string.**
   - `statusLine` stays out of `CLAUDE_ALLOWED_FIELDS`. Before 0.6.0, aic
     rewrote the host `statusLine.command`. That was a heuristic on a trust
     boundary. Do not bring it back.
   - `apply_statusline()` writes the constant `/usr/local/bin/aic-statusline`
     into the per-project `settings.json`. This is a baked, root-owned `0555`
     launcher. It maps the *installed file name* to a hardcoded interpreter.
   - Keep three fixed tables aligned: `STATUSLINE_VARIANTS`
     (`post_create_overlays.py`), the
     `statusline/` `TARGETS` (`aic-lock-user-config`), and the dispatch list
     of the launcher. A new extension is a deliberate edit to all three, never
     a discovery at runtime. Never glob the seed directory. Never let the
     launcher take the script path from argv or env.
   - `apply_statusline()` runs *after* `lock_config()` on purpose. Thus it
     uses the root-owned file that actually landed. If the install is
     refused, `settings.json` must have no `statusLine`. A command that points
     to no file is not acceptable.
   - The interpreter itself (the `node` of fnm) is in a `vscode`-owned tree.
     It is not part of the tamper-proof guarantee. This is acceptable only
     because the statusline already runs with `vscode` authority. It is *not*
     a reason to relax the root lock on the script.

Guarded by `tests/test-aic-statusline-overlay.py`, the personal-overlay
assertions in the host-security test, and the runtime shell-lock and
statusline smokes.

## AI-tool refresh on every create

`refresh_ai_tools()` runs after `lock_config()` and before the project hook.
On every container create or recreate, it updates Claude Code, Codex, and
OpenCode to the latest version. Thus a plain `aic rebuild` gets current CLIs
without a new image.

The Dockerfile bakes each tool as an offline *floor*. The updates run through
these commands:

- Claude Code: `claude update`
- Codex: the official `install.sh` of Codex, with `CODEX_NON_INTERACTIVE=1`
- OpenCode: `opencode upgrade`

The refresh has these properties:

- `AIC_TOOLS` controls which tools it updates.
- It is fail-soft. An update that is offline or fails keeps the baked version.
  Do not make a failure fatal.
- Set `AIC_FREEZE_TOOLS=1` to disable it and get a reproducible sandbox.
- With `.devcontainer/firewall-enable`, Claude Code and Codex keep the baked
  version and log one line. `claude update` needs `downloads.claude.ai`, and
  `chatgpt.com/codex/install.sh` redirects to `releases.openai.com`. The
  default allowlist does not hold these update-only hosts, so each updater
  waited about 90 s and failed. Do not add them to the default allowlist for
  an update. OpenCode still upgrades: it uses `opencode.ai` (which it needs to
  run) and the GitHub hosts of the default allowlist. Guarded by the
  "declared firewall keeps baked Claude and Codex" test in
  `tests/test-aic-auth-sync.py`.

Rules for each updater:

- **Codex:** The refresh downloads the installer completely before it runs
  it. The download uses only HTTPS and has limits. Keep `CODEX_HOME` on its
  separate rootfs package cache. Keep `CODEX_INSTALL_DIR=~/.local/bin`. Thus
  the project state stays isolated, and no shell startup file changes.
- **OpenCode:** It installs with `--no-modify-path` and upgrades in place. It
  never touches rc files.
- The three updaters run in parallel. Each updater writes only its own binary
  and package directory.

Guarded by the "tool self-update works with rc files root-locked" test and the
parallel-updater case in `tests/test-aic-auth-sync.py`.
