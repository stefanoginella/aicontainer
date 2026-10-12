# shellcheck shell=bash
# =============================================================================
# lib/aic/lifecycle.sh
# =============================================================================
# Lifecycle commands: up, preflight, check-drift, __supports, initialize,
# rebuild, shell, run, down, destroy, validate, upgrade, version.
#
# aic sources this file. It only defines functions.
# =============================================================================

cmd_up () {
  require_in_project
  pin_compose_project_name
  ensure_git_control_paths strict
  write_runtime_environment_file
  local allow_unsafe=0 arg
  local -a args=()
  for arg in "$@"; do
    case "$arg" in
      --allow-unsafe) allow_unsafe=1 ;;
      *) args+=("$arg") ;;
    esac
  done
  # Keep the readable raw warning, then enforce structural + resolved-Compose
  # validation. Ordinary generated projects produce no prompt or extra output.
  scan_project_overrides warn
  validate_project_security gate "$allow_unsafe"
  migrate_legacy_session_volume strict
  stop_owned_legacy_stack
  local devcontainer; devcontainer="$(resolve_devcontainer)"
  if [ "${#args[@]}" -gt 0 ]; then
    "$devcontainer" up --workspace-folder . "${args[@]}"
  else
    "$devcontainer" up --workspace-folder .
  fi
  print_boundary_summary up
  warn_compose_drift
}

cmd_preflight () {
  require_in_project
  # Review-only: surface all findings without prompting, persisting trust, or
  # failing before the boundary summary. `aic validate` is the strict CI gate.
  check_devcontainer_project_name || true
  validate_project_security warn 0 || true
  print_boundary_summary preflight
}

# Internal. Surface the Tier-1 drift warning from a non-aic entry point: the
# template's devcontainer.json `initializeCommand` calls this so a VS Code
# "Reopen/Rebuild in Container" — which drives `devcontainer up` directly and
# never the aic CLI — still gets the nudge that `aic up`/`shell`/`rebuild` print.
# Deliberately lenient and undocumented (no require_in_project, always exits 0):
# it runs inside the host-side initializeCommand chain, where a non-zero exit
# would abort container startup, and outside a project it must simply no-op.
# warn_compose_drift already covers both (empty pin / broken read → return 0).
# Output lands in VS Code's Dev Containers output channel, not the terminal.
cmd_check_drift () {
  # Run path validation in a subshell so the internal entry point can preserve
  # its always-zero contract while refusing to read any symlinked control file.
  (validate_devcontainer_paths optional) || return 0
  warn_compose_drift
  # Old templates cannot refuse a startup; warn that the root .env or an
  # inherited COMPOSE_PROJECT_NAME moves this checkout to another project.
  (check_devcontainer_project_name) || true
  # Same host-side entry point surfaces the override scan (print-only) so a
  # VS Code "Reopen/Rebuild in Container" gets it in the Dev Containers output
  # channel. Never prompts, always exits 0 (initializeCommand must not abort).
  scan_project_overrides warn
  # Reusable full validation, warn-only until every generated template has the
  # trusted `aic initialize` hook. Never let the legacy check-drift entry point
  # abort VS Code startup.
  if [ -z "${AIC_NO_OVERRIDE_SCAN:-}" ]; then
    validate_project_security warn 0 || true
  fi
}

# Internal capability probe for the generated initializeCommand. A Node-manager
# shim hides the CLI text (Volta's shim is a binary; asdf/mise shims are
# wrappers that exec the real tool), so the initializer runs the candidate with
# `__supports initialize` instead of reading it. Keep this cheap and free of
# side effects: no output, no Docker, no network, no file writes. Exit 0 only
# for one exact, known capability name. Older CLIs treat the name as an
# unknown command and exit nonzero, so the probe fails closed.
cmd_supports () {
  [ "$#" -eq 1 ] || return 1
  case "$1" in
    initialize) return 0 ;;
    *) return 1 ;;
  esac
}

# Internal managed initialize entry point for VS Code / devcontainer CLI. Once
# the generated initializer is invoked, it applies the same fail-closed gate
# and migration as `aic up` before Compose starts. Dev Containers necessarily
# reads the repository command first, so unknown repo-supplied configuration
# still has to be regenerated/reviewed before a direct editor bootstrap.
cmd_initialize () {
  require_in_project
  # The parent Dev Containers process has already chosen where it reads the
  # project name, and this child cannot change its environment. Refuse before
  # any Docker state changes if that name is not this project's managed one.
  check_devcontainer_project_name \
    || die "refusing to start this checkout under another Compose project name"
  ensure_git_control_paths strict
  # Refresh the host-specific, gitignored socket path before either our own
  # resolved-Compose validation or the parent Dev Containers process uses it.
  write_runtime_environment_file
  # Never prompt here. Dev Containers can give this child a pty (VS Code ships
  # node-pty), and a prompt in its log terminal would hang Reopen. Approval
  # comes from `aic trust` or from the parent `aic up` (exact trust or the
  # one-run hash).
  validate_project_security gate 0 </dev/null
  prepare_host_seed_paths
  migrate_legacy_session_volume strict
  stop_owned_legacy_stack
  initialize_managed_volumes
  warn_compose_drift
}

cmd_rebuild () {
  require_in_project
  pin_compose_project_name
  ensure_git_control_paths strict
  write_runtime_environment_file
  local allow_unsafe=0 arg
  local -a args=()
  for arg in "$@"; do
    case "$arg" in
      --allow-unsafe) allow_unsafe=1 ;;
      *) args+=("$arg") ;;
    esac
  done
  scan_project_overrides warn
  validate_project_security gate "$allow_unsafe"
  migrate_legacy_session_volume strict
  stop_owned_legacy_stack
  # Warn *before* the pull below: `aic rebuild` re-pulls the *currently pinned*
  # tag (it never re-pins), so on post-`npm update` drift this would otherwise
  # silently re-fetch the stale image. Surfacing it here lets the user abort and
  # `aic sync` first instead of waiting through a pull they'll discard.
  warn_compose_drift
  # Pull-mode compose pins `pull_policy: missing`, so `devcontainer up` reuses
  # the cached image even with --remove-existing-container — meaning newer
  # GHCR releases would be silently ignored. Force a pull so `aic rebuild`
  # actually refreshes the image. In --build mode the devcontainer service
  # has a `build:` block (no top-level `image:` on it), so we skip the pull
  # branch entirely; --build-no-cache below does the refresh for that path.
  # Detect mode via presence of Dockerfile, which apply_template only copies
  # in --build mode.
  if [ ! -f .devcontainer/Dockerfile ]; then
    local image
    image="$(awk '/^[[:space:]]*image:/ {sub(/^[[:space:]]*image:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); sub(/[[:space:]]+$/, ""); print; exit}' .devcontainer/docker-compose.yml 2>/dev/null || true)"
    if [ -n "$image" ]; then
      echo "aic: pulling $image"
      docker pull "$image" || echo "aic: docker pull failed; continuing with cached image" >&2
    fi
  fi
  local devcontainer; devcontainer="$(resolve_devcontainer)"
  # Bash 3.2 (still the system Bash on macOS) treats expansion of an empty
  # array as an unbound variable under `set -u`, even when it was declared.
  if [ "${#args[@]}" -gt 0 ]; then
    "$devcontainer" up --workspace-folder . --remove-existing-container --build-no-cache "${args[@]}"
  else
    "$devcontainer" up --workspace-folder . --remove-existing-container --build-no-cache
  fi
}

cmd_shell () {
  require_in_project
  pin_compose_project_name
  write_runtime_environment_file
  # devcontainer exec parses repository control files even for an already-
  # running container. Revalidate them before handing them to the CLI.
  validate_project_security gate 0
  warn_compose_drift
  local devcontainer shell
  devcontainer="$(resolve_devcontainer)"
  # Honor the per-project shell choice (AIC_SHELL in devcontainer.json).
  # Older projects without the field fall back to zsh — that's what they had
  # baked in pre-flag.
  shell="$(read_aic_shell)"
  [ -n "$shell" ] || shell="$DEFAULT_SHELL"
  shell="$(validate_shell "$shell")"
  case "$shell" in
    zsh)
      "$devcontainer" exec --workspace-folder . zsh -l "$@"
      ;;
    bash)
      # A login bash reads writable ~/.bash_profile before ~/.bashrc. Start
      # from the root-owned managed rc directly so a prior unrestricted session
      # cannot plant persistence for the next shell.
      "$devcontainer" exec --workspace-folder . bash --noprofile --rcfile /etc/aic/shell/bashrc -i "$@"
      ;;
    fish)
      "$devcontainer" exec --workspace-folder . fish --no-config \
        -C 'source /etc/fish/conf.d/aic.fish' "$@"
      ;;
  esac
}

cmd_run () {
  require_in_project
  pin_compose_project_name
  write_runtime_environment_file
  validate_project_security gate 0
  local devcontainer; devcontainer="$(resolve_devcontainer)"
  "$devcontainer" exec --workspace-folder . "$@"
}

cmd_down () {
  require_in_project
  local project template
  if ! compose_has_project_name; then
    # Pre-migration cleanup is allowed only when Docker labels prove that the
    # legacy stack belongs to this exact canonical workspace. Never issue a
    # basename-scoped unconditional `compose down`.
    stop_owned_legacy_stack
    err "legacy project identity detected; run 'aic sync' before the next start"
    return 0
  fi
  project="$(project_name)"; template="$(trusted_compose_template)"
  # Cleanup deliberately parses only aic's installed trusted template. The
  # repository override may contain Compose providers/includes that execute
  # host-side code; --remove-orphans still removes every project-labelled
  # override service without evaluating that untrusted file.
  stop_owned_legacy_stack
  docker compose -p "$project" -f "$template" down --remove-orphans
}

cmd_destroy () {
  require_in_project
  local project template assume_yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) assume_yes=1 ;;
      *) die "unknown destroy flag: $1 (try --yes)" ;;
    esac
    shift
  done
  compose_has_project_name || \
    die "refusing to destroy a basename-scoped legacy project; run 'aic sync' first"
  project="$(project_name)"
  template="$(trusted_compose_template)"
  local vol="${project}_aic-sessions" seed_vol="${project}_aic-sanitized-seed" size
  size="$(volume_size "$vol")"

  echo "aic: 'aic destroy' will remove the container and these PER-PROJECT volumes for '$project':"
  if [ -n "$size" ]; then
    echo "       $vol  ($size of Claude/Codex/OpenCode session transcripts)"
  else
    echo "       $vol  (Claude/Codex/OpenCode session transcripts)"
  fi
  echo "       $seed_vol  (sanitized host configuration seed)"
  echo "aic: global volumes aic-auth-global and aic-shell-history are PRESERVED."
  echo "aic: this is irreversible. To stop the container but KEEP history, use 'aic down' instead."

  # Destructive non-interactive calls must be explicit. A closed stdin / CI
  # pipeline is never implicit consent to delete persistent transcripts.
  if [ "$assume_yes" -ne 1 ] && [ ! -t 0 ]; then
    die "refusing non-interactive destroy without --yes"
  fi
  if [ "$assume_yes" -ne 1 ]; then
    local reply
    printf "aic: destroy '%s' and delete the above? [y/N] " "$project"
    IFS= read -r reply || reply=""
    case "$reply" in
      y|Y|yes|YES) ;;
      *) echo "aic: aborted — nothing removed."; return 0 ;;
    esac
  fi

  stop_owned_legacy_stack
  docker compose -p "$project" -f "$template" down --volumes --remove-orphans
  docker volume rm "$vol" 2>/dev/null || true
  docker volume rm "$seed_vol" 2>/dev/null || true
  echo "aic: destroyed '$project' (container + per-project volumes removed)."
}

cmd_validate () {
  [ "$#" -eq 0 ] || die "usage: aic validate"
  require_in_project
  # Same refusal as the VS Code initializer, so CI predicts a direct start.
  check_devcontainer_project_name \
    || die "configuration is invalid for a direct Dev Containers start"
  validate_project_security validate 0
  echo "aic: configuration valid — managed files and resolved Compose model are accepted."
}

cmd_upgrade () {
  check_for_update
  if [ -d "$AIC_HOME/.git" ]; then
    echo "aic: pulling latest aicontainer from $AIC_HOME"
    git -C "$AIC_HOME" pull --ff-only
  else
    echo "aic: installed via npm. Upgrade with:"
    echo "    npm update -g aicontainer"
    echo "aic: then in each project: 'aic sync' (re-pin compose to new version)"
    echo "aic: followed by 'aic rebuild' (pull the new image and recreate the container)"
  fi
}

cmd_version () {
  echo "aic v$(read_aic_version)"
  check_for_update
}
