# shellcheck shell=bash
# =============================================================================
# lib/aic/doctor.sh
# =============================================================================
# Read-only host diagnostics (aic doctor).
#
# aic sources this file. It only defines functions.
# =============================================================================

doctor_ok ()   { printf 'OK    %s\n' "$*"; }
doctor_warn () {
  printf 'WARN  %s\n' "$*"
  doctor_warnings=$((doctor_warnings + 1))
}
doctor_fail () {
  printf 'FAIL  %s\n' "$*"
  doctor_failures=$((doctor_failures + 1))
}

# Read-only host diagnostics. This intentionally does not call `initialize` or
# create a probe volume: minimum versions plus Compose's stdin-only schema
# parse establish volume.subpath support without changing Docker state.
cmd_doctor () {
  [ "$#" -eq 0 ] || die "usage: aic doctor"
  local doctor_failures=0 doctor_warnings=0 node_raw node_version
  local context endpoint endpoint_path runtime_kind bind_source server_raw server_version
  local compose_raw compose_version compose_probe devcontainer_path devcontainer_version
  local git_root git_problems line path_error identity_error name_error relay_error

  printf 'aic doctor\n'

  if ! command -v node >/dev/null 2>&1; then
    doctor_fail "Node.js 18+ is required — install a current Node.js LTS release"
  else
    node_raw="$(node --version 2>/dev/null)" || node_raw=""
    node_version="$(diagnostic_version "$node_raw")"
    if [ -n "$node_version" ] && version_at_least "$node_version" 18.0.0; then
      doctor_ok "Node.js $node_version (minimum 18)"
    else
      doctor_fail "Node.js ${node_version:-unknown} is too old — install Node.js 18+"
    fi
  fi

  if ! command -v docker >/dev/null 2>&1; then
    doctor_fail "Docker CLI not found — install Docker Engine/Desktop"
  else
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

    if docker info >/dev/null 2>&1; then
      doctor_ok "Docker daemon reachable (context: $context)"
      server_raw="$(docker version --format '{{.Server.Version}}' 2>/dev/null)" || server_raw=""
      server_version="$(diagnostic_version "$server_raw")"
      if [ -n "$server_version" ] && version_at_least "$server_version" 25.0.0; then
        doctor_ok "Docker Engine $server_version (volume subpath minimum 25)"
      else
        doctor_fail "Docker Engine ${server_version:-unknown} lacks required volume subpath support — upgrade to 25+"
      fi
    else
      doctor_fail "Docker daemon is unreachable in context '$context' — start Docker or select a working context"
    fi

    case "$endpoint" in
      unix://*)
        endpoint_path="${endpoint#unix://}"
        if [ -S "$endpoint_path" ]; then
          doctor_ok "Docker context socket is available ($endpoint_path)"
          runtime_kind="$(docker_runtime_kind "$endpoint_path")"
          bind_source="$(docker_socket_bind_source "$endpoint_path" "$runtime_kind")"
          if [ "$bind_source" != "$endpoint_path" ]; then
            doctor_ok "Docker runtime $runtime_kind: managed helpers will bind the VM daemon socket $bind_source"
          elif [ "$(uname -s 2>/dev/null || true)" = Darwin ] \
              && { [ "$runtime_kind" = other ] || [ "$runtime_kind" = rootless ]; }; then
            # macOS has no native daemon, so this daemon runs in a VM that aic
            # cannot map. Its daemon cannot bind the macOS socket path.
            doctor_warn "Docker runtime $runtime_kind runs in a VM that aic does not recognize; the managed socket mount may fail — use Docker Desktop, OrbStack, Colima, Rancher Desktop, or a rootful Lima VM"
          else
            doctor_ok "Docker runtime $runtime_kind: managed helpers will bind the selected local socket"
          fi
        else
          doctor_fail "Docker context socket is missing ($endpoint_path) — fix the selected context"
        fi
        ;;
      '')
        doctor_warn "could not inspect the Docker context endpoint"
        [ -S /var/run/docker.sock ] \
          && doctor_ok "default managed helper socket /var/run/docker.sock is available" \
          || doctor_fail "no bind-mountable local Docker socket was found"
        ;;
      *)
        doctor_fail "selected Docker context is remote; aicontainer requires a local Unix-socket daemon for workspace and helper mounts"
        ;;
    esac

    compose_raw="$(docker compose version --short 2>/dev/null)" || compose_raw=""
    compose_version="$(diagnostic_version "$compose_raw")"
    if [ -n "$compose_version" ] && version_at_least "$compose_version" "$AIC_MIN_COMPOSE_VERSION"; then
      doctor_ok "Docker Compose $compose_version (minimum $AIC_MIN_COMPOSE_LABEL)"
    else
      doctor_fail "Docker Compose ${compose_version:-missing} is too old — install the Compose plugin $AIC_MIN_COMPOSE_LABEL+ (validation needs config --no-env-resolution)"
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
      doctor_ok "Compose accepts config --no-env-resolution --no-interpolate (no Docker objects created)"
    else
      doctor_fail "Compose rejects config --no-env-resolution/--no-interpolate — upgrade Docker Compose to $AIC_MIN_COMPOSE_LABEL+"
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
      doctor_ok "Compose accepts volume.subpath (no Docker objects created)"
    else
      doctor_fail "Compose cannot resolve volume.subpath — upgrade Docker Compose to $AIC_MIN_COMPOSE_LABEL+"
    fi
  fi

  if [ -x "$AIC_HOME/node_modules/.bin/devcontainer" ]; then
    devcontainer_path="$AIC_HOME/node_modules/.bin/devcontainer"
  elif command -v devcontainer >/dev/null 2>&1; then
    devcontainer_path="$(command -v devcontainer)"
  else
    devcontainer_path=""
  fi
  if [ -n "$devcontainer_path" ]; then
    devcontainer_version="$("$devcontainer_path" --version 2>/dev/null | head -n1)" || devcontainer_version="unknown"
    doctor_ok "Dev Container CLI ${devcontainer_version:-unknown} ($devcontainer_path)"
  else
    doctor_fail "Dev Container CLI not found — install with: npm install -g @devcontainers/cli"
  fi

  if ! command -v git >/dev/null 2>&1; then
    doctor_fail "Git not found — install Git before creating an aicontainer project"
  elif git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    git_root="$(cd "$git_root" && canonical_root)"
    if [ "$git_root" = "$(canonical_root)" ]; then
      doctor_ok "Git project root is the current directory"
    else
      doctor_warn "current directory is below the Git root; run aic from $git_root"
    fi
  else
    doctor_warn "not in a Git project; cd to a project root before 'aic init'"
  fi
  if [ -d .devcontainer ]; then
    git_problems="$(git_control_path_problems)"
    if [ -n "$git_problems" ]; then
      while IFS= read -r line; do
        doctor_fail "$line"
      done <<< "$git_problems"
    else
      doctor_ok "Git control paths are real files and directories in this checkout"
    fi
  fi

  if [ ! -f "$AIC_HOME/package.json" ] || [ ! -f "$TEMPLATE_DIR/devcontainer.json" ]; then
    doctor_fail "aic installation is incomplete at $AIC_HOME — reinstall aicontainer"
  else
    doctor_ok "aic installation and managed template are present"
  fi

  if [ ! -e .devcontainer ] && [ ! -L .devcontainer ]; then
    doctor_warn "this directory is not initialized; run 'aic init' from a Git project root"
  else
    path_error="$( (validate_devcontainer_paths optional) 2>&1)" || true
    if [ -n "$path_error" ]; then
      path_error="${path_error#aic: }"
      doctor_fail "managed path safety check failed: $path_error"
    elif [ ! -f .devcontainer/devcontainer.json ] || [ ! -f .devcontainer/docker-compose.yml ]; then
      doctor_fail ".devcontainer is incomplete — run 'aic init --force' after reviewing its contents"
    else
      doctor_ok "managed control paths are regular files/directories (no symlinks)"
      if export_runtime_environment >/dev/null 2>&1; then
        if [ ! -e .devcontainer/.env ]; then
          doctor_warn ".devcontainer/.env is absent; aic initialize will generate it before startup"
        elif validate_runtime_environment_file; then
          doctor_ok "managed host runtime environment matches the Docker context and relay mode"
        else
          doctor_fail ".devcontainer/.env is stale or modified — run 'aic sync' or 'aic initialize'"
        fi
      else
        # A refused status-relay marker blocks init/sync/up/initialize but has
        # no check of its own, so without this branch doctor reports ready for a
        # state every mutating command rejects. The Docker context is already
        # covered by its own check above.
        relay_error="$( (status_relay_mode >/dev/null) 2>&1)" || true
        if [ -n "$relay_error" ]; then
          relay_error="${relay_error#aic: }"
          doctor_fail "host status-relay marker is invalid: $relay_error"
        else
          doctor_fail "could not generate the managed host runtime environment from the selected Docker context"
        fi
      fi
      if ! compose_has_project_name; then
        doctor_fail "legacy project identity blocks verified startup — run 'aic sync', then review the diff"
      elif command -v node >/dev/null 2>&1; then
        identity_error="$( (project_name >/dev/null) 2>&1)" || true
        if [ -n "$identity_error" ]; then
          identity_error="${identity_error#aic: }"
          doctor_fail "managed project identity is invalid: $identity_error"
        else
          doctor_ok "managed project identity matches this canonical path"
          name_error="$( (check_devcontainer_project_name) 2>&1)" || true
          if [ -n "$name_error" ]; then
            name_error="${name_error#aic: }"
            doctor_fail "a direct Dev Containers start (VS Code) would be refused: $name_error"
          else
            doctor_ok "Dev Containers will use the managed Compose project name"
          fi
        fi
      fi
    fi
  fi

  if [ "$doctor_failures" -eq 0 ]; then
    if [ "$doctor_warnings" -gt 0 ]; then
      printf 'Result: ready with %s warning(s)\n' "$doctor_warnings"
    else
      printf 'Result: ready\n'
    fi
    return 0
  fi
  printf 'Result: %s blocker(s) found\n' "$doctor_failures"
  return 1
}
