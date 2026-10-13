# shellcheck shell=bash
# =============================================================================
# lib/aic/lifecycle.sh
# =============================================================================
# Lifecycle commands: up, preflight, check-drift, __supports, initialize,
# rebuild, shell, run, down, destroy, validate, upgrade, version.
#
# aic sources this file. It only defines functions.
# =============================================================================

# The pass-through options of aic up and aic rebuild, after `--`. Only these
# devcontainer up options pass: they change only the log output. Every other
# option can change the mounts, the configuration, the environment, the
# container, the Docker binary, or skip post-create, so aic refuses it.
AIC_UP_PASSTHROUGH="--log-level --log-format --terminal-columns --terminal-rows"

# up_parse_args <command> [args...]: set allow_unsafe and passthrough, locals
# of cmd_up and cmd_rebuild (bash dynamic scope). Before `--`, only
# --allow-unsafe. After `--`, only the AIC_UP_PASSTHROUGH options, each with a
# checked value. An unknown argument or a bad value exits 2. An option after
# `--` that is not on the list is a security refusal: it exits 1.
up_parse_args () {
  local command="$1" option value
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --allow-unsafe) allow_unsafe=1 ;;
      --) shift; break ;;
      *) usage_die "unknown $command argument: $1 (try --allow-unsafe, or -- followed by $AIC_UP_PASSTHROUGH)" ;;
    esac
    shift
  done
  while [ $# -gt 0 ]; do
    case "$1" in
      --log-level=*|--log-format=*|--terminal-columns=*|--terminal-rows=*)
        option="${1%%=*}"; value="${1#*=}" ;;
      --log-level|--log-format|--terminal-columns|--terminal-rows)
        flag_value "$@"; option="$1"; shift; value="$1" ;;
      *) die "refusing to pass '$1' to devcontainer up: aic passes only $AIC_UP_PASSTHROUGH; other options can weaken the sandbox" ;;
    esac
    # A value that is an option is a refused option, not a bad value.
    case "$value" in
      -*) die "refusing to pass '$value' to devcontainer up: aic passes only $AIC_UP_PASSTHROUGH; other options can weaken the sandbox" ;;
    esac
    case "$option:$value" in
      --log-level:info|--log-level:debug|--log-level:trace) ;;
      --log-format:text|--log-format:json) ;;
      --terminal-columns:[1-9]|--terminal-columns:[1-9][0-9]|--terminal-columns:[1-9][0-9][0-9]) ;;
      --terminal-rows:[1-9]|--terminal-rows:[1-9][0-9]|--terminal-rows:[1-9][0-9][0-9]) ;;
      *) usage_die "bad value for $option: '$value' (--log-level: info, debug, trace; --log-format: text, json; --terminal-columns and --terminal-rows: 1-999)" ;;
    esac
    passthrough+=("$option" "$value")
    shift
  done
}

cmd_up () {
  local allow_unsafe=0
  local -a passthrough=()
  # Parse first: a bad call exits 2 before aic reads or changes anything.
  up_parse_args up "$@"
  require_in_project
  pin_compose_project_name
  ensure_git_control_paths strict
  write_runtime_environment_file
  # Keep the readable raw warning, then enforce structural + resolved-Compose
  # validation. Ordinary generated projects produce no prompt or extra output.
  scan_project_overrides warn
  validate_project_security gate "$allow_unsafe"
  migrate_legacy_session_volume strict
  stop_owned_legacy_stack
  local devcontainer; devcontainer="$(resolve_devcontainer)"
  # Bash 3.2 (still the system Bash on macOS) treats expansion of an empty
  # array as an unbound variable under `set -u`, even when it was declared.
  # A failure of devcontainer up is a failure of aic up: exit 1, never the
  # code of the Dev Container CLI, so 2 stays the code of a usage error.
  if [ "${#passthrough[@]}" -gt 0 ]; then
    "$devcontainer" up --workspace-folder . "${passthrough[@]}" || die "devcontainer up failed (exit $?)"
  else
    "$devcontainer" up --workspace-folder . || die "devcontainer up failed (exit $?)"
  fi
  print_boundary_summary up
  warn_compose_drift
}

cmd_preflight () {
  require_no_args preflight "$@"
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
  require_no_args initialize "$@"
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
  local allow_unsafe=0
  local -a passthrough=()
  # Parse first: a bad call exits 2 before aic reads or changes anything.
  up_parse_args rebuild "$@"
  require_in_project
  pin_compose_project_name
  ensure_git_control_paths strict
  write_runtime_environment_file
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
  # Bash 3.2 treats expansion of an empty array as unbound (see cmd_up).
  if [ "${#passthrough[@]}" -gt 0 ]; then
    "$devcontainer" up --workspace-folder . --remove-existing-container --build-no-cache "${passthrough[@]}" \
      || die "devcontainer up failed (exit $?)"
  else
    "$devcontainer" up --workspace-folder . --remove-existing-container --build-no-cache \
      || die "devcontainer up failed (exit $?)"
  fi
}

# With .devcontainer/firewall-enable, no agent session may start before the
# firewall is on. `devcontainer exec` does not run postStartCommand, so after a
# plain `docker start` the start-time `aic-firewall auto` can still resolve DNS.
# `auto` waits for that run (or enables the firewall itself). A failure stops
# the command, so the session never starts with open egress.
ensure_declared_firewall () {
  local devcontainer="$1"
  [ -e .devcontainer/firewall-enable ] || [ -L .devcontainer/firewall-enable ] || return 0
  "$devcontainer" exec --workspace-folder . /usr/bin/sudo -n /usr/local/bin/aic-firewall auto >/dev/null \
    || die ".devcontainer/firewall-enable is set, but the firewall is not on in the container; run 'aic up' (or 'aic rebuild') and read 'docker logs' for the cause"
}

cmd_shell () {
  [ "$#" -eq 0 ] || usage_die "aic shell takes no arguments (got: $1); to run a command, use 'aic run CMD ...'"
  require_in_project
  pin_compose_project_name
  write_runtime_environment_file
  # devcontainer exec parses repository control files even for an already-
  # running container. Revalidate them before handing them to the CLI.
  validate_project_security gate 0
  warn_compose_drift
  local devcontainer shell
  devcontainer="$(resolve_devcontainer)"
  ensure_declared_firewall "$devcontainer"
  # Honor the per-project shell choice (AIC_SHELL in devcontainer.json).
  # Older projects without the field fall back to zsh — that's what they had
  # baked in pre-flag.
  shell="$(read_aic_shell)"
  [ -n "$shell" ] || shell="$DEFAULT_SHELL"
  shell="$(validate_shell "$shell")"
  case "$shell" in
    zsh)
      "$devcontainer" exec --workspace-folder . zsh -l
      ;;
    bash)
      # A login bash reads writable ~/.bash_profile before ~/.bashrc. Start
      # from the root-owned managed rc directly so a prior unrestricted session
      # cannot plant persistence for the next shell.
      "$devcontainer" exec --workspace-folder . bash --noprofile --rcfile /etc/aic/shell/bashrc -i
      ;;
    fish)
      "$devcontainer" exec --workspace-folder . fish --no-config \
        -C 'source /etc/fish/conf.d/aic.fish'
      ;;
  esac
}

# aic run [--] CMD [ARGS...]. devcontainer exec reads its own options up to
# the first argument that is not an option, so CMD must not start with '-':
# else `aic run --container-id X ...` or `aic run --remote-env ...` would set
# devcontainer exec options. Every argument from CMD on goes to the command.
cmd_run () {
  [ "${1:-}" != "--" ] || shift
  [ "$#" -gt 0 ] || usage_die "usage: aic run [--] CMD [ARGS...]"
  case "$1" in
    -*) usage_die "aic run: the command must come first, not an option: $1" ;;
  esac
  require_in_project
  pin_compose_project_name
  write_runtime_environment_file
  validate_project_security gate 0
  local devcontainer; devcontainer="$(resolve_devcontainer)"
  ensure_declared_firewall "$devcontainer"
  "$devcontainer" exec --workspace-folder . "$@"
}

cmd_down () {
  require_no_args down "$@"
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
  trusted_template_compose -p "$project" -f "$template" down --remove-orphans \
    || die "docker compose down failed (exit $?)"
}

cmd_destroy () {
  local project template assume_yes=0
  # Parse first: a bad call exits 2 before aic reads or changes anything.
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) assume_yes=1 ;;
      *) usage_die "unknown destroy flag: $1 (try --yes)" ;;
    esac
    shift
  done
  require_in_project
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
  # pipeline is never implicit consent to delete persistent transcripts. This
  # is a refused confirmation, not a bad call: exit 1, not 2.
  if [ "$assume_yes" -ne 1 ] && [ ! -t 0 ]; then
    die "refusing non-interactive destroy without --yes: stdin is not a terminal, so nothing was removed; pass --yes to confirm"
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
  trusted_template_compose -p "$project" -f "$template" down --volumes --remove-orphans \
    || die "docker compose down failed (exit $?)"
  docker volume rm "$vol" 2>/dev/null || true
  docker volume rm "$seed_vol" 2>/dev/null || true
  echo "aic: destroyed '$project' (container + per-project volumes removed)."
}

# aic validate [--json]. --json runs the same gate and adds its findings to
# one JSON object (lib/aic/json.sh).
cmd_validate () {
  if [ "$#" -eq 0 ]; then
    cmd_validate_run
  elif [ "$#" -eq 1 ] && [ "$1" = --json ]; then
    json_run validate findings cmd_validate_run
  else
    usage_die "usage: aic validate [--json]"
  fi
}

cmd_validate_run () {
  local name_error line
  require_in_project
  # Same refusal as the VS Code initializer, so CI predicts a direct start.
  if json_mode; then
    # The same check. Its messages also go to stderr, and each one is a
    # finding with the id "name".
    if ! name_error="$( (check_devcontainer_project_name) 2>&1)"; then
      [ -z "$name_error" ] || printf '%s\n' "$name_error" >&2
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        json_item name fail "${line#aic: }"
      done <<< "$name_error"
      die "configuration is invalid for a direct Dev Containers start"
    fi
  else
    check_devcontainer_project_name \
      || die "configuration is invalid for a direct Dev Containers start"
  fi
  validate_project_security validate 0
  echo "aic: configuration valid — managed files and resolved Compose model are accepted."
}

cmd_upgrade () {
  require_no_args upgrade "$@"
  check_for_update
  if [ -d "$AIC_HOME/.git" ]; then
    echo "aic: pulling latest aicontainer from $AIC_HOME"
    git -C "$AIC_HOME" pull --ff-only || die "git pull failed (exit $?)"
  else
    echo "aic: installed via npm. Upgrade with:"
    echo "    npm update -g aicontainer"
    echo "aic: then in each project: 'aic sync' (re-pin compose to new version)"
    echo "aic: followed by 'aic rebuild' (pull the new image and recreate the container)"
  fi
}

cmd_version () {
  if [ "$#" -eq 0 ]; then
    echo "aic v$(read_aic_version)"
    check_for_update
  elif [ "$#" -eq 1 ] && [ "$1" = --json ]; then
    json_run version "" cmd_version_json
  else
    usage_die "usage: aic version [--json]"
  fi
}

# The --json body of cmd_version. Like the text mode, a version that cannot be
# read does not change the exit status; "version" is then null. The update
# check is the same call, so its network and cache behavior do not change.
cmd_version_json () {
  local version
  version="$(read_aic_version)" || version=""
  check_for_update
  json_field_string version "$version"
  json_field_string latest "$aic_update_latest"
  if [ -n "$version" ] && [ -n "$aic_update_latest" ] && version_gt "$aic_update_latest" "$version"; then
    json_field update_available true
  else
    json_field update_available false
  fi
}
