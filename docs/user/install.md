# Install aicontainer

This page tells you what your host needs and how to install the `aic` CLI. It
also shows how to log in to the AI tools one time, and how to remove
aicontainer.

## Prerequisites

- Docker Engine 25+ with Compose 2.35+. Docker Engine 25+ gives volume-subpath
  support. Validation uses `config --no-env-resolution`, so it needs Compose
  2.35+. Use one of these runtimes with a local Unix socket:
  - [Docker Desktop](https://docker.com/products/docker-desktop)
  - [OrbStack](https://orbstack.dev/)
  - [Colima](https://github.com/abiosoft/colima)
  - [Rancher Desktop](https://rancherdesktop.io/)
  - a rootful [Lima](https://lima-vm.io/) VM
  - rootless Docker Engine

  aic finds the selected context automatically. As in the Docker CLI,
  `DOCKER_HOST` wins over `DOCKER_CONTEXT`.

  A rootless daemon inside a VM does not work (for example, Lima's default
  `docker` template). aic does not know the location of its socket in the VM.
  Use Lima's `docker-rootful` template instead. On Linux, aic does not detect
  Colima when you start it with `--hostname`. Keep the default Colima hostname.
- Node.js 18+. npm and the bundled `@devcontainers/cli` need it.
- A conventional Git checkout, opened at its repository root. `.git` must be a
  real directory. It must not be a symlink. It must not be the `.git` file of a
  linked worktree or of a submodule checkout. aic protects the control files in
  `.git` with exact read-only mounts, and these mounts need a real directory.

Run `aic doctor` for an exact compatibility check. It does not change
anything.

## Install the CLI

```bash
npm install -g aicontainer
```

This command puts `aic` on your PATH. It also installs `@devcontainers/cli` as
a dependency. To upgrade later, run `npm update -g aicontainer`.

### Try aicontainer without an install

You can also run `npx aicontainer init`. But you use `aic up`, `aic shell`, and
the other commands many times. Install the CLI globally one time, so that npx
does not download the package each time.

### Install from a Git checkout

```bash
git clone https://github.com/stefanoginella/aicontainer ~/.aicontainer && ~/.aicontainer/install.sh
```

This method also works. `aic` finds its templates relative to its own
location, so the two layouts operate the same. With a Git checkout:

- Install `@devcontainers/cli` separately: `npm install -g @devcontainers/cli`.
- `aic upgrade` does the `git pull`.

## Shell completion

Shell completion is optional, but we recommend it. `aic completion <shell>`
writes a completion script for **bash**, **zsh**, or **fish**. Use the line for
your shell:

```bash
echo 'eval "$(aic completion bash)"' >> ~/.bashrc
echo 'eval "$(aic completion zsh)"'  >> ~/.zshrc
aic completion fish > ~/.config/fish/completions/aic.fish
```

Then open your shell again. Tab completion then works for:

- subcommands (`init`, `sync`, `up`, `trust`, …)
- Docker modes (`--no-docker`, `--docker-read`, `--docker`)
- the `--with` and `--shell` values

## Log in one time

Log in to each tool one time. Then every project uses the same logins.

A credential bridge without network access synchronizes only these files into
fixed subpaths of the global `aic-auth-global` volume:

- the four known credential JSON files of the tools
- the login entries of `gh`'s `hosts.yml`
- the login entries of npm's `npmrc`

Signing and Semgrep use their own fixed subpaths. These items stay in the
volume of the current project:

- config that contains prompts
- instructions, skills, and plugins
- transcripts
- `gh` and npm settings

Thus the shared logins do not move the persistent instructions or settings of
one project into a different project.

```bash
mkdir -p ~/sandbox/scratch && cd ~/sandbox/scratch
git init
aic init
aic up
aic shell

# Inside the container:
claude /login           # OAuth flow in your host browser
codex auth login        # OpenAI auth
opencode auth login     # select a provider (Anthropic, OpenAI, OpenCode Zen, …)
gh auth login           # GitHub (use a fine-grained PAT if you can)
npm login               # only if you publish packages — the token persists too
```

After this, every `aic up` in each project uses the same credentials. You do
not have to log in again.

For the full data model, see [Multi-project model](multi-project.md).

## Uninstall aicontainer

```bash
# In each project:
aic destroy          # shows the size of the session-transcript volume and asks
                     # you to confirm first (you cannot undo it); add --yes to
                     # skip the prompt

# Globally:
docker volume rm aic-auth-global aic-shell-history
npm uninstall -g aicontainer        # or, for a git checkout:
                                    #   rm -rf ~/.aicontainer ~/.local/bin/aic
```

> **Warning:** Do not run `aic destroy` if you want to keep the session
> transcripts. You cannot undo the removal of the transcript volume.
