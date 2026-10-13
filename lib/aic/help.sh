# shellcheck shell=bash
# =============================================================================
# lib/aic/help.sh
# =============================================================================
# Usage text (aic help) and shell completion (aic completion).
#
# aic sources this file. It only defines functions.
# =============================================================================

cmd_help () {
  cat <<'EOF'
aic — sandboxed devcontainer for running Claude Code + Codex + OpenCode in bypass mode

Usage:
  aic init [--build] [--force] [--docker-read|--docker|--no-docker] [--with TOOLS] [--shell SHELL]
                       Copy the aicontainer template into ./.devcontainer/.
                       Default: pull ghcr.io/stefanoginella/aicontainer:vX.Y.Z
                       where X.Y.Z is this aic's own version (pinned, not
                       :latest — `npm update -g aicontainer` + `aic sync`
                       is the upgrade path).
                       --build: full local build from template/Dockerfile (slow
                                first run, but you own the image).
                       Docker daemon access defaults to NONE (proxy ping/version
                       only; host containers/images/volumes stay hidden).
                       --docker-read: enable host Docker read APIs; this may
                                expose other containers' metadata, logs, and files.
                       --docker: enable READ-WRITE access (including POST/BUILD).
                                The agent can create privileged host containers
                                and siblings that dodge the firewall; use only
                                for testcontainers / in-container `docker compose`.
                       --no-docker: return to the secure NONE mode.
                       --with:  comma-separated tools to enable for this project
                                (claude-code, codex, opencode — any subset).
                                Defaults to an interactive checkbox prompt; all
                                three are selected by default. The choice is
                                stored as containerEnv.AIC_TOOLS in
                                devcontainer.json.
                       --shell: interactive shell — zsh (default, with oh-my-zsh
                                + powerlevel10k), bash, or fish. Defaults to an
                                interactive radio prompt. Stored as
                                containerEnv.AIC_SHELL; 'aic shell' and the
                                VS Code default terminal profile honor it.
  aic sync [--pull|--build] [--bump-base] [--docker-read|--docker|--no-docker] [--with TOOLS] [--shell SHELL]
                       Re-copy the aicontainer template files into an existing
                       ./.devcontainer/, overwriting them. Auto-detects the
                       mode from whether .devcontainer/Dockerfile exists; pass
                       --pull or --build to force one. Existing AIC_TOOLS /
                       AIC_SHELL selections and the Docker daemon exposure mode are
                       preserved unless overridden (--with / --shell /
                       --docker-read|--docker|--no-docker). Read/read-write modes
                       also require matching consent stored outside the repo, so
                       repository edits cannot grant Docker access themselves.
                       Project-owned files (Dockerfile.project, firewall-
                       allowlist, firewall-enable, firewall-presets,
                       chown-paths, post-create.project.sh,
                       docker-compose.override.yml, vscode-extensions,
                       vscode-settings.json, shell-rc.zsh, p10k.zsh,
                       statusline.{sh,mjs,js,py}) are
                       untouched; an existing
                       docker-compose.override.yml is auto-wired into
                       dockerComposeFile, and vscode-extensions /
                       vscode-settings.json are merged into the editor
                       customizations, so per-project tweaks survive the
                       sync. Useful after
                       editing template/ in a checkout — saves a manual cp -R.
                       Review with 'git diff' afterward.
                       --bump-base: if Dockerfile.project pins an explicit
                                FROM ghcr.io/stefanoginella/aicontainer:vX.Y.Z,
                                rewrite that tag to this aic's version without
                                prompting. (Without the flag, an interactive
                                sync warns about the drift and offers to bump;
                                non-interactive syncs just warn. :latest floats
                                and ARG-templated bases are left alone.)
  aic doctor [--json]  Check host prerequisites and project wiring without
                       creating containers, volumes, trust, or other state.
  aic status [--json]  Show this project's identity, selected tools/shell,
                       Docker exposure, image drift, runtime, and volume state.
  aic validate [--json]
                       Non-interactively validate managed files and the fully
                       resolved Compose model. Existing exact trust is honored;
                       this command never prompts or records trust.
                       --json (doctor, status, validate, version): print one
                                JSON object on stdout instead of the text, with
                                the same checks and exit status. Messages go
                                to stderr.
  aic up [--allow-unsafe]
                       Pull/build and start the devcontainer for this project
                       (prints the trust boundary summary when it comes up)
                       Managed configuration and the fully resolved Compose
                       model are validated first. --allow-unsafe is a one-run
                       escape hatch for a reviewed host-access override.
  aic trust [--revoke] Review and persist approval for this project's exact
                       host-access configuration and project code (post-create
                       hook, shell overlay, statusline, VS Code extensions and
                       settings) outside the repository.
                       Any relevant config change invalidates the approval.
  aic preflight        Print this project's trust boundary: what the agent can
                       read (mounts), what's blocked (.env/secrets), where
                       sessions persist, and whether outbound network is open
                       or firewalled. Read-only; also shown after 'aic up'.
  aic signing [ACTION] Set up commit signing inside the sandbox. The host's
                       signing key is never forwarded, so a host that signs
                       commits can't sign here without this. ACTION is one of:
                         status   (default) show the current signing state
                         auto     generate a sandbox-only ssh signing key
                                  (register its pubkey on GitHub as a Signing
                                  Key). --register adds it via gh for you
                                  (needs the write:ssh_signing_key scope).
                         byok     install a separate signing key you provide
                                  ('aic signing byok < your_key', or drop it in)
                         disable  turn commit signing off inside the sandbox
                       With no ACTION on a TTY, prints status then offers a
                       chooser. Mutating actions need the container up; the
                       choice persists in the aic-auth-global volume and takes
                       effect on the next 'aic rebuild'.
  aic shell            Open the configured interactive shell (AIC_SHELL) inside the devcontainer
  aic run CMD ...      Run CMD inside the devcontainer
  aic rebuild [--allow-unsafe]
                       Recreate the container from a fresh image
  aic down             Stop the container (volumes preserved)
  aic destroy [--yes]  Stop + remove container + per-project volumes
                       (global auth + shell history are preserved). Shows the
                       session-transcript volume size and confirms first (the
                       removal is irreversible); --yes / -y skips the prompt.
  aic upgrade          Update aic itself (git pull or 'npm update -g')
  aic completion SHELL Emit tab-completion script for bash, zsh, or fish.
                       Install (one-shot, recommended):
                         echo 'eval "$(aic completion zsh)"'  >> ~/.zshrc
                         echo 'eval "$(aic completion bash)"' >> ~/.bashrc
                         aic completion fish > ~/.config/fish/completions/aic.fish
  aic version [--json] Print this aic's version (also: --version, -v)
  aic help             Show this help (also: --help, -h)

Env:
  AIC_HOME             Where the aicontainer files live (default: this script's dir)
  AIC_NO_UPDATE_CHECK  Set to silence version notifications: the
                       'up'/'shell'/'rebuild' (and VS Code container-start)
                       drift warning (pinned image vs installed aic) and the
                       'version'/'upgrade' "newer aicontainer available" nudge.
  AIC_NO_OVERRIDE_SCAN Set to silence the legacy print-only raw scan of
                       project-owned docker-compose.override.yml /
                       Dockerfile.project. It does not bypass fail-closed
                       resolved-Compose validation; use aic trust or the
                       explicit one-run --allow-unsafe flag.
EOF
}

# The completion scripts are generated from the command table in
# lib/cli-spec.mjs. Keep this cheap: users eval it from their shell rc file, so
# it runs no update check and touches no project state.
cmd_completion () {
  local shell="${1:-}"
  case "$shell" in
    bash|zsh|fish) ;;
    "")   die "usage: aic completion <bash|zsh|fish>" ;;
    *)    die "unsupported shell: $shell (supported: bash, zsh, fish)" ;;
  esac
  command -v node >/dev/null 2>&1 || die "Node.js 18+ is required for shell completion"
  node "$AIC_HOME/lib/cli-spec.mjs" completion "$shell"
}
