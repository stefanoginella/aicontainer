# Bring your personal config

This page explains how to use your own zsh prompt, aliases, and Claude Code
statusline inside the sandbox. aic installs these files root-owned, so the
agent cannot change them.

## Personal shell config

Use this section to get your usual zsh prompt and aliases inside the sandbox.

The `~/.zshrc` of the container is root-managed on purpose, so an
in-container agent cannot change the shell startup. So you do not edit it
directly. You supply an **overlay** instead:

- aic installs the overlay root-owned.
- The managed `.zshrc` **sources the overlay last**, so your prompt and
  aliases have priority over the managed baseline.
- The managed setup for history, `fnm`, and `PATH` still runs first.

The overlay is for zsh only.

### Project files

There are two files. Both are opt-in by presence, and `aic sync` never
changes them:

- **`.devcontainer/shell-rc.zsh`**: your personal zsh startup. Use it for
  aliases, functions, exports, and prompt changes.
- **`.devcontainer/p10k.zsh`**: a
  [powerlevel10k](https://github.com/romkatv/powerlevel10k) config. This is
  the output of `p10k configure`. The managed zsh startup turns off p10k
  instant prompt, also when this file turns it on.

```zsh
# .devcontainer/shell-rc.zsh
alias gs='git status'
alias ll='ls -lah'
export EDITOR=nvim
```

### Host seed files

You can use your **host** config instead of a committed file in each
repository. Copy it one time into the seed directory that aic owns. Then every
project uses it:

```bash
mkdir -p ~/.config/aicontainer
cp ~/.p10k.zsh ~/.config/aicontainer/p10k.zsh     # your host p10k prompt
cp ~/.zsh_aliases ~/.config/aicontainer/rc.zsh    # or any personal rc snippet
```

The seed sanitizer reads the host seed **read-only** and copies it without
changes. When a project-owned `.devcontainer/` file and a host seed file both
exist, the project file wins.

To apply the files:

1. Run `aic sync` on the host.
2. Run `aic rebuild`.

To stop using a host seed file, delete it and run `aic rebuild`. aic then
removes the old copy.

### Approval

A project-owned `shell-rc.zsh` or `p10k.zsh` comes from the repository. So it
needs `aic trust`, like `post-create.project.sh` (see
[Customize a project](customization.md)). Your host seed needs no approval.

> **Warning:** Do not put secrets in these files. Do not put tokens or lines
> such as `export API_KEY=…` in them. aic copies the files without changes. It
> cannot sanitize them like the JSON configs, because they are shell *code*.
> The code runs inside a sandbox that an autonomous agent can read. Use the
> files only for prompt and alias appearance. They run only as the
> unprivileged `vscode` user. After installation, they are root-locked, so the
> agent cannot change them.

## Personal Claude Code statusline

aic does **not** copy your host `statusLine` setting. That setting is a
command string that can contain any command. It points at a host path that
does not exist in the container (see the [threat model](security.md)).

You bring your statusline into the container like the shell overlay above.
You give aicontainer the **script**, and aicontainer supplies the command.

### Name the script file

Supply one file. The file name selects the interpreter:

| File | Run as |
| --- | --- |
| `statusline.sh` | `bash` |
| `statusline.mjs` | `node` (ESM) |
| `statusline.js` | `node` (CommonJS) |
| `statusline.py` | `python3` |

### Install the script

For all projects on this machine (host-global):

```bash
mkdir -p ~/.config/aicontainer
cp ~/.claude/statusline/statusline.mjs ~/.config/aicontainer/statusline.mjs
aic rebuild
```

For one project, put the script at `.devcontainer/statusline.mjs`. When both
files exist, the project file wins. The file name is the same in both
locations. This is different from `rc.zsh` and `shell-rc.zsh`.

A project script comes from the repository. So it needs `aic trust`, like
`post-create.project.sh`.

### What post-create does

On the next create, post-create does these steps:

1. It installs the script `root:root 0444` in
   `/etc/aic/user-config/statusline/`.
2. It sets the Claude `statusLine.command` to the fixed managed launcher
   `/usr/local/bin/aic-statusline`.
3. The launcher selects the interpreter from the file name.

aic **never runs a string from your host settings**. Only your script file
goes into the container. The command that aic writes is a constant of aic.

### Practical notes

- **Use one file, not a bundle.** A statusline that uses `import` for modules
  in the same directory does not find them. Put all the code into one file.
  Your script can still read and write its own state under
  `~/.claude/statusline/`. aic creates that directory before the start, and
  each project has its own copy.
- **The container supplies `node` and `python3`.** Each program that your
  script starts must exist in the sandbox. `git` and the usual CLI tools
  exist. Programs that exist only on the host do not.
- **Keep one source for the host and the sandbox.** Keep the real script at
  `~/.config/aicontainer/statusline.mjs` on the host. Point your *host*
  `~/.claude/settings.json` at that same path. Then the host and the sandbox
  always use the same script.
- This feature is for Claude Code only. Codex and OpenCode have no equivalent
  feature.

> **Warning:** Do not put secrets in the statusline script. The rule is the
> same as for the shell overlay: aic copies the file without changes, and the
> agent can read it. The script runs as the unprivileged `vscode` user. After
> installation, it is root-locked, so the agent cannot change it. But the agent
> can see its bytes, including host paths or user names in the script.
