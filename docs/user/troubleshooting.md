# FAQ and troubleshooting

This page answers a frequent question about Claude Code auto mode. It also
gives solutions for common problems.

## FAQ

### Is aicontainer necessary when I use Claude Code auto mode?

Yes. Auto mode and aicontainer work together.

- Claude Code
  [auto mode](https://www.anthropic.com/engineering/claude-code-auto-mode)
  runs a classifier. The classifier examines each action before the action
  runs, and blocks the obviously destructive ones. This is very useful.
- But Anthropic recommends that you run auto mode *in an isolated
  environment*, because it "reduces risk but doesn't eliminate it."
  aicontainer gives you that isolated environment.
- Auto mode is not available on every plan yet.
- Auto mode does not cover `--dangerously-skip-permissions` or the Codex
  `--full-auto` / sandbox-off modes. These modes have no classifier.

The sandbox is the boundary. Auto mode is a smarter agent *inside* the
boundary. Use both.

## Troubleshooting

### Docker is not running

Start Docker Desktop, OrbStack, or Colima. `aic up` does not start if Docker
does not run.

### `error while creating mount source path …docker.sock`

The daemon runs in a VM and cannot mount the host path of the Docker socket.

1. Run `aic doctor`. It shows the runtime that it found and the socket that
   the managed mounts use.
2. Docker Desktop, Colima, Rancher Desktop, and rootful Lima VMs get
   `/var/run/docker.sock` automatically on the next `aic up` or VS Code
   start.

A runtime that `doctor` does not recognize keeps the socket path of the
context.

### `devcontainer: command not found`

`npm install -g aicontainer` usually includes the `devcontainer` CLI. If you
installed aicontainer from a git checkout, run
`npm install -g @devcontainers/cli`.

### Powerlevel10k glyphs look wrong

Install the
[Meslo Nerd Font](https://github.com/romkatv/powerlevel10k#meslo-nerd-font-patched-for-powerlevel10k)
and set it as your terminal font.

### Powerlevel10k asks you to run `p10k configure`

Shell startup is root-managed on purpose. It never imports the host
`.p10k.zsh` automatically. So the image stops the wizard and uses the bundled
theme defaults. To get your own prompt, do these steps:

1. Copy your prompt into the opt-in seed directory:
   `cp ~/.p10k.zsh ~/.config/aicontainer/p10k.zsh`.
2. Run `aic rebuild`.

See [Personal shell config](personal-config.md).

> **Warning:** Do not add an include of a writable rc file in the home
> directory. Use the opt-in seed directory instead.

### Your statusline is missing inside the container

This is expected: aic never seeds the host `statusLine` command. To get your
statusline, do these steps:

1. Copy the *script* to `~/.config/aicontainer/statusline.<ext>`.
2. Run `aic rebuild`.

See [Personal Claude Code statusline](personal-config.md). If the statusline
is installed but shows nothing, run `/usr/local/bin/aic-statusline` inside the
container to see the error.

### Claude Code pre-fills `source /workspace/.venv/bin/activate`

This causes no problem. Claude found a project venv and suggested the
activation, but it did not run it. To stop the suggestion, set
`VIRTUAL_ENV: /workspace/.venv` in the project-owned Compose override. This
does not source a tool-writable script on every shell start. The setting
stays project-scoped and stays after sync.

If the same line is *typed and run* in the terminal, the cause is the VS Code
Python extension, not Claude. This can overwrite a `claude`/`opencode` that
you just started. See
[Recipe: Stop VS Code auto-activating a `.venv` in the terminal](customization.md).

### `aic shell` succeeds, but `claude` shows permission errors

`post-create.py` runs during `aic up`, not when you open a shell.

1. Look in the `aic up` output for `[post-create]` warnings (volume
   ownership, hook setup, settings write).
2. Run `aic rebuild` to run `post-create.py` again cleanly.

### Tools installed ad-hoc disappeared

This is expected. See [Installing extra tools](extra-tools.md). Move the
tools to `Dockerfile.project`.

### Codex asks for approval, but auto-approve is set

Make sure that `~/.codex/config.toml` exists. `post-create.py` writes this
file. If the file is missing, run `aic rebuild` again.

### Codex asks for approval or cannot create a namespace

This applies when the Codex VS Code sidebar asks for approval, or a command
fails with `bwrap: No permissions to create a new namespace` / "The sandbox
cannot create a namespace here".

`post-create.py` already forces `~/.codex/config.toml` to
`sandbox_mode = danger-full-access` + `approval_policy = never`. Thus the
**main** Codex agent runs without prompts. To verify, run
`cat ~/.codex/config.toml`. Two things can still show a prompt:

- **Sidebar mode.** The built-in *Full access* preset of the extension tries
  to start the Codex sandbox. In the mode menu, select
  **Custom (config.toml)**. Then the sidebar uses the forced
  `danger-full-access`. Only this mode skips the inner sandbox.
- **Review / sub-agent workflows.** The built-in Codex *Code Review* feature
  (and spawned sub-agents) currently do not inherit `danger-full-access`.
  They fall back to `workspace-write`
  ([openai/codex#15305](https://github.com/openai/codex/issues/15305),
  [#5090](https://github.com/openai/codex/issues/5090)). Inside the container,
  that sandbox cannot create a namespace. So Codex asks to run the command
  *outside the sandbox*.
  - **It is safe to allow this here.** "Outside the [inner] sandbox" means
    "normally inside the container". aicontainer already gives that isolation.
    So click **Yes** (or *Yes, and don't ask again…*).
  - Workaround: run the review as a **normal turn**. For example, start the
    review skill/command directly in the chat. Do not use the Codex
    *Code Review* entry point. A main-loop turn inherits
    `danger-full-access` and does not show a prompt.
  - This is an upstream Codex bug, not an aicontainer configuration error.

> **Warning:** Do not "fix" bwrap with `SYS_ADMIN`, `seccomp=unconfined`, or
> unprivileged user namespaces. These let the AI nest a sandbox, but they make
> the boundary of the container weaker. That boundary is the reason to run
> the AI here.
