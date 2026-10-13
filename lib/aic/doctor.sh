# shellcheck shell=bash
# =============================================================================
# lib/aic/doctor.sh
# =============================================================================
# Read-only host diagnostics (aic doctor).
#
# aic sources this file. It only defines functions.
# =============================================================================

# The check helpers below report through these three functions: <id> is the
# stable id of the check (the "id" of a --json item), and the rest is the
# message. They count into the doctor_failures and doctor_warnings locals of
# cmd_doctor_run (bash dynamic scope), so call them only from cmd_doctor_run
# and its helpers.
doctor_ok ()   { doctor_report ok 'OK    ' "$@"; }
doctor_warn () {
  doctor_report warn 'WARN  ' "$@"
  doctor_warnings=$((doctor_warnings + 1))
}
doctor_fail () {
  doctor_report fail 'FAIL  ' "$@"
  doctor_failures=$((doctor_failures + 1))
}
# doctor_report <level> <text prefix> <id> <message...>
doctor_report () {
  local level="$1" prefix="$2" id="$3"
  shift 3
  if json_mode; then
    json_item "$id" "$level" "$*"
  else
    printf '%s%s\n' "$prefix" "$*"
  fi
}

# Read-only host diagnostics. This intentionally does not call `initialize` or
# create a probe volume: minimum versions plus Compose's stdin-only schema
# parse establish volume.subpath support without changing Docker state.
# Each check group is a helper below, called in this fixed order. --json runs
# the same checks and prints them as one JSON object (lib/aic/json.sh).
cmd_doctor () {
  if [ "$#" -eq 0 ]; then
    cmd_doctor_run
  elif [ "$#" -eq 1 ] && [ "$1" = --json ]; then
    json_run doctor checks cmd_doctor_run
  else
    die "usage: aic doctor [--json]"
  fi
}

cmd_doctor_run () {
  local doctor_failures=0 doctor_warnings=0

  json_mode || printf 'aic doctor\n'

  doctor_check_node
  doctor_check_docker
  doctor_check_devcontainer_cli
  doctor_check_git
  doctor_check_install
  doctor_check_project

  json_field warnings "$doctor_warnings"
  json_field failures "$doctor_failures"
  if [ "$doctor_failures" -eq 0 ]; then
    if [ "$doctor_warnings" -gt 0 ]; then
      json_field_string result warnings
      json_mode || printf 'Result: ready with %s warning(s)\n' "$doctor_warnings"
    else
      json_field_string result ready
      json_mode || printf 'Result: ready\n'
    fi
    return 0
  fi
  json_field_string result blocked
  json_mode || printf 'Result: %s blocker(s) found\n' "$doctor_failures"
  return 1
}

# Check the host Node.js version.
doctor_check_node () {
  local node_raw node_version
  if ! command -v node >/dev/null 2>&1; then
    doctor_fail node "Node.js 18+ is required — install a current Node.js LTS release"
  else
    node_raw="$(node --version 2>/dev/null)" || node_raw=""
    node_version="$(diagnostic_version "$node_raw")"
    if [ -n "$node_version" ] && version_at_least "$node_version" 18.0.0; then
      doctor_ok node "Node.js $node_version (minimum 18)"
    else
      doctor_fail node "Node.js ${node_version:-unknown} is too old — install Node.js 18+"
    fi
  fi
}

# Check the Docker CLI, then the daemon, the context socket, and Compose.
doctor_check_docker () {
  local context endpoint
  if ! command -v docker >/dev/null 2>&1; then
    doctor_fail docker-cli "Docker CLI not found — install Docker Engine/Desktop"
    return 0
  fi
  context="$(docker context show 2>/dev/null)" || context="${DOCKER_CONTEXT:-default}"
  [ -n "$context" ] || context="default"
  endpoint=""
  # The Docker CLI's order, as in resolve_docker_socket().
  if [ -n "${DOCKER_HOST:-}" ]; then
    endpoint="$DOCKER_HOST"
  elif [ -n "${DOCKER_CONTEXT:-}" ]; then
    endpoint="$(docker context inspect "$DOCKER_CONTEXT" --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null)" || endpoint=""
  else
    endpoint="$(docker context inspect "$context" --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null)" || endpoint=""
  fi

  doctor_check_docker_daemon "$context"
  doctor_check_docker_socket "$endpoint"
  doctor_check_compose
}

# Check that the daemon of context $1 answers, and its Engine version.
doctor_check_docker_daemon () {
  local context="$1" server_raw server_version
  if docker info >/dev/null 2>&1; then
    doctor_ok docker-daemon "Docker daemon reachable (context: $context)"
    server_raw="$(docker version --format '{{.Server.Version}}' 2>/dev/null)" || server_raw=""
    server_version="$(diagnostic_version "$server_raw")"
    if [ -n "$server_version" ] && version_at_least "$server_version" 25.0.0; then
      doctor_ok docker-engine "Docker Engine $server_version (volume subpath minimum 25)"
    else
      doctor_fail docker-engine "Docker Engine ${server_version:-unknown} lacks required volume subpath support — upgrade to 25+"
    fi
  else
    doctor_fail docker-daemon "Docker daemon is unreachable in context '$context' — start Docker or select a working context"
  fi
}

# Check that the context endpoint $1 is a local Unix socket, and name the
# socket that the managed helpers will bind for its runtime.
doctor_check_docker_socket () {
  local endpoint="$1" endpoint_path runtime_kind bind_source
  case "$endpoint" in
    unix://*)
      endpoint_path="${endpoint#unix://}"
      if [ -S "$endpoint_path" ]; then
        doctor_ok docker-socket "Docker context socket is available ($endpoint_path)"
        runtime_kind="$(docker_runtime_kind "$endpoint_path")"
        bind_source="$(docker_socket_bind_source "$endpoint_path" "$runtime_kind")"
        if [ "$bind_source" != "$endpoint_path" ]; then
          doctor_ok docker-runtime "Docker runtime $runtime_kind: managed helpers will bind the VM daemon socket $bind_source"
        elif [ "$(uname -s 2>/dev/null || true)" = Darwin ] \
            && { [ "$runtime_kind" = other ] || [ "$runtime_kind" = rootless ]; }; then
          # macOS has no native daemon, so this daemon runs in a VM that aic
          # cannot map. Its daemon cannot bind the macOS socket path.
          doctor_warn docker-runtime "Docker runtime $runtime_kind runs in a VM that aic does not recognize; the managed socket mount may fail — use Docker Desktop, OrbStack, Colima, Rancher Desktop, or a rootful Lima VM"
        else
          doctor_ok docker-runtime "Docker runtime $runtime_kind: managed helpers will bind the selected local socket"
        fi
      else
        doctor_fail docker-socket "Docker context socket is missing ($endpoint_path) — fix the selected context"
      fi
      ;;
    '')
      doctor_warn docker-socket "could not inspect the Docker context endpoint"
      [ -S /var/run/docker.sock ] \
        && doctor_ok docker-socket "default managed helper socket /var/run/docker.sock is available" \
        || doctor_fail docker-socket "no bind-mountable local Docker socket was found"
      ;;
    *)
      doctor_fail docker-socket "selected Docker context is remote; aicontainer requires a local Unix-socket daemon for workspace and helper mounts"
      ;;
  esac
}

# Check the Compose version and the two Compose features that validation
# needs, with stdin-only parses that create no Docker objects.
doctor_check_compose () {
  local compose_raw compose_version compose_probe
  compose_raw="$(docker compose version --short 2>/dev/null)" || compose_raw=""
  compose_version="$(diagnostic_version "$compose_raw")"
  if [ -n "$compose_version" ] && version_at_least "$compose_version" "$AIC_MIN_COMPOSE_VERSION"; then
    doctor_ok compose-version "Docker Compose $compose_version (minimum $AIC_MIN_COMPOSE_LABEL)"
  else
    doctor_fail compose-version "Docker Compose ${compose_version:-missing} is too old — install the Compose plugin $AIC_MIN_COMPOSE_LABEL+ (validation needs config --no-env-resolution)"
  fi
  # Validation needs these two flags; the version alone can hide an old
  # build. Stdin-only parse, like the subpath probe below.
  compose_probe="$(docker compose -f - config --format json --no-env-resolution --no-interpolate 2>/dev/null <<'YAML'
name: aic-doctor
services:
  probe:
    image: busybox
YAML
)" || compose_probe=""
  if [ -n "$compose_probe" ] && grep -q '"aic-doctor"' <<< "$compose_probe"; then
    doctor_ok compose-flags "Compose accepts config --no-env-resolution --no-interpolate (no Docker objects created)"
  else
    doctor_fail compose-flags "Compose rejects config --no-env-resolution/--no-interpolate — upgrade Docker Compose to $AIC_MIN_COMPOSE_LABEL+"
  fi
  compose_probe="$(docker compose -f - config --format json 2>/dev/null <<'YAML'
name: aic-doctor
services:
  probe:
    image: busybox
    volumes:
      - type: volume
        source: probe
        target: /probe
        volume:
          subpath: child
volumes:
  probe: {}
YAML
)" || compose_probe=""
  if [ -n "$compose_probe" ] && grep -q '"subpath"' <<< "$compose_probe"; then
    doctor_ok compose-subpath "Compose accepts volume.subpath (no Docker objects created)"
  else
    doctor_fail compose-subpath "Compose cannot resolve volume.subpath — upgrade Docker Compose to $AIC_MIN_COMPOSE_LABEL+"
  fi
}

# Check that the Dev Container CLI is installed: the bundled copy first, then
# PATH.
doctor_check_devcontainer_cli () {
  local devcontainer_path devcontainer_version
  if [ -x "$AIC_HOME/node_modules/.bin/devcontainer" ]; then
    devcontainer_path="$AIC_HOME/node_modules/.bin/devcontainer"
  elif command -v devcontainer >/dev/null 2>&1; then
    devcontainer_path="$(command -v devcontainer)"
  else
    devcontainer_path=""
  fi
  if [ -n "$devcontainer_path" ]; then
    devcontainer_version="$("$devcontainer_path" --version 2>/dev/null | head -n1)" || devcontainer_version="unknown"
    doctor_ok devcontainer-cli "Dev Container CLI ${devcontainer_version:-unknown} ($devcontainer_path)"
  else
    doctor_fail devcontainer-cli "Dev Container CLI not found — install with: npm install -g @devcontainers/cli"
  fi
}

# Check Git, the Git-root shape, and, in an initialized project, the Git
# control paths. The control paths are checked first: host Git reads the
# config that a planted .git/commondir names, so Git runs only when they pass.
doctor_check_git () {
  local git_root git_problems="" line
  if [ -d .devcontainer ]; then
    git_problems="$(git_control_path_problems)"
  fi
  if ! command -v git >/dev/null 2>&1; then
    doctor_fail git "Git not found — install Git before creating an aicontainer project"
  elif [ -n "$git_problems" ]; then
    doctor_warn git-root "Git project root not checked: the Git control paths below are unsafe"
  elif git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    git_root="$(cd "$git_root" && canonical_root)"
    if [ "$git_root" = "$(canonical_root)" ]; then
      doctor_ok git-root "Git project root is the current directory"
    else
      doctor_warn git-root "current directory is below the Git root; run aic from $git_root"
    fi
  else
    doctor_warn git-root "not in a Git project; cd to a project root before 'aic init'"
  fi
  if [ -d .devcontainer ]; then
    if [ -n "$git_problems" ]; then
      while IFS= read -r line; do
        doctor_fail git-control-paths "$line"
      done <<< "$git_problems"
    else
      doctor_ok git-control-paths "Git control paths are real files and directories in this checkout"
    fi
  fi
}

# Check that the aic install has its package metadata and template.
doctor_check_install () {
  if [ ! -f "$AIC_HOME/package.json" ] || [ ! -f "$TEMPLATE_DIR/devcontainer.json" ]; then
    doctor_fail install "aic installation is incomplete at $AIC_HOME — reinstall aicontainer"
  else
    doctor_ok install "aic installation and managed template are present"
  fi
}

# Check the .devcontainer/ control paths of this directory, then its runtime
# environment and project identity.
doctor_check_project () {
  local path_error
  if [ ! -e .devcontainer ] && [ ! -L .devcontainer ]; then
    doctor_warn project "this directory is not initialized; run 'aic init' from a Git project root"
  else
    path_error="$( (validate_devcontainer_paths optional) 2>&1)" || true
    if [ -n "$path_error" ]; then
      path_error="${path_error#aic: }"
      doctor_fail control-paths "managed path safety check failed: $path_error"
    elif [ ! -f .devcontainer/devcontainer.json ] || [ ! -f .devcontainer/docker-compose.yml ]; then
      doctor_fail control-paths ".devcontainer is incomplete — run 'aic init --force' after reviewing its contents"
    else
      doctor_ok control-paths "managed control paths are regular files/directories (no symlinks)"
      doctor_check_runtime_environment
      doctor_check_project_identity
    fi
  fi
}

# Check that .devcontainer/.env matches the Docker context and the relay mode.
doctor_check_runtime_environment () {
  local relay_error tracked=0
  if export_runtime_environment >/dev/null 2>&1; then
    if [ ! -e .devcontainer/.env ]; then
      doctor_warn runtime-env ".devcontainer/.env is absent; aic initialize will generate it before startup"
    elif validate_runtime_environment_file; then
      doctor_ok runtime-env "managed host runtime environment matches the Docker context and relay mode"
    else
      doctor_fail runtime-env ".devcontainer/.env is stale or modified — run 'aic sync' or 'aic initialize'"
    fi
    # Host Git runs only on safe control paths (a planted .git/commondir would
    # make it read the config of another directory). The Git check of doctor
    # already reports a problem there.
    if [ -z "$(git_control_path_problems)" ]; then
      runtime_environment_file_tracked || tracked=$?
      case "$tracked" in
        0) doctor_fail env-tracked ".devcontainer/.env is tracked by Git, but it is host state — run 'git rm --cached .devcontainer/.env'" ;;
        1) ;;
        *) doctor_fail env-tracked "could not check with Git whether .devcontainer/.env is tracked — fix the Git checkout" ;;
      esac
    fi
  else
    # A refused status-relay marker blocks init/sync/up/initialize but has
    # no check of its own, so without this branch doctor reports ready for a
    # state every mutating command rejects. The Docker context is already
    # covered by its own check above.
    relay_error="$( (status_relay_mode >/dev/null) 2>&1)" || true
    if [ -n "$relay_error" ]; then
      relay_error="${relay_error#aic: }"
      doctor_fail runtime-env "host status-relay marker is invalid: $relay_error"
    else
      doctor_fail runtime-env "could not generate the managed host runtime environment from the selected Docker context"
    fi
  fi
}

# Check the managed Compose project name, and the name that a direct Dev
# Containers start would use.
doctor_check_project_identity () {
  local identity_error name_error line_problem
  if ! compose_has_project_name; then
    doctor_fail project-identity "legacy project identity blocks verified startup — run 'aic sync', then review the diff"
  elif command -v node >/dev/null 2>&1; then
    identity_error="$( (project_name >/dev/null) 2>&1)" || true
    line_problem="$(compose_name_line_problem)"
    if [ -n "$identity_error" ]; then
      identity_error="${identity_error#aic: }"
      doctor_fail project-identity "managed project identity is invalid: $identity_error"
    elif [ -n "$line_problem" ]; then
      # The earlier path-specific literal still resolves this checkout, but
      # every start refuses it until sync writes the managed line.
      doctor_fail project-identity "managed project identity blocks verified startup: $line_problem"
    else
      doctor_ok project-identity "managed project identity matches this canonical path"
      name_error="$( (check_devcontainer_project_name) 2>&1)" || true
      if [ -n "$name_error" ]; then
        name_error="${name_error#aic: }"
        doctor_fail devcontainer-name "a direct Dev Containers start (VS Code) would be refused: $name_error"
      else
        doctor_ok devcontainer-name "Dev Containers will use the managed Compose project name"
      fi
    fi
  fi
}
