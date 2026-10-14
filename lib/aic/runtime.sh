# shellcheck shell=bash
# =============================================================================
# lib/aic/runtime.sh
# =============================================================================
# Host runtime: the Dev Containers CLI, the Docker context socket, the runtime
# kind and bind source, the runtime user, the host status relay, and the
# managed .devcontainer/.env file.
#
# aic sources this file. It only defines functions.
# =============================================================================

# Prefer a devcontainer CLI bundled into our node_modules (when installed via
# `npm install -g aicontainer`), fall back to one on PATH (manual install).
resolve_devcontainer () {
  if [ -x "$AIC_HOME/node_modules/.bin/devcontainer" ]; then
    echo "$AIC_HOME/node_modules/.bin/devcontainer"
  elif command -v devcontainer >/dev/null 2>&1; then
    command -v devcontainer
  else
    die "devcontainer CLI not found. Install with: npm install -g @devcontainers/cli"
  fi
}

# The Dev Containers CLI remaps the vscode user to the host UID/GID on native
# Linux. Docker Desktop keeps the image's 1000:1000 identity. Sidecars that
# write the same named volumes must use that identity too, otherwise auth and
# session files become root-owned (or unwritable) after the first sync.
runtime_user_id () {
  local uid=1000 gid=1000
  if [ "$(uname -s 2>/dev/null || true)" = "Linux" ]; then
    local host_uid host_gid
    host_uid="$(id -u 2>/dev/null || true)"
    host_gid="$(id -g 2>/dev/null || true)"
    # Dev Containers deliberately does not remap vscode to root. Keep the image
    # identity when a Linux CI/host command itself runs as uid 0.
    if [[ "$host_uid" =~ ^[0-9]+$ ]] && [[ "$host_gid" =~ ^[0-9]+$ ]] \
       && [ "$host_uid" -gt 0 ]; then
      uid="$host_uid"; gid="$host_gid"
    fi
  fi
  printf '%s:%s\n' "$uid" "$gid"
}

# Return the active Docker context's local Unix socket. aicontainer needs a
# bind-mountable socket for its fixed ownership helper and socket proxy, so
# remote tcp/ssh contexts cannot provide the same boundary. AIC_DOCKER_SOCKET
# itself is never trusted from the environment or a repository .env file; it
# is always derived from Docker's selected context here.
resolve_docker_socket () {
  local endpoint="" context="" socket
  # Same order as the Docker CLI and Compose: DOCKER_HOST beats DOCKER_CONTEXT.
  # Otherwise aic would inspect one daemon while Compose starts on another.
  if [ -n "${DOCKER_HOST:-}" ]; then
    endpoint="$DOCKER_HOST"
  elif [ -n "${DOCKER_CONTEXT:-}" ] && command -v docker >/dev/null 2>&1; then
    endpoint="$(docker context inspect "$DOCKER_CONTEXT" --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || true)"
  elif command -v docker >/dev/null 2>&1; then
    context="$(docker context show 2>/dev/null || true)"
    [ -n "$context" ] || context="default"
    endpoint="$(docker context inspect "$context" --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || true)"
  fi
  [ -n "$endpoint" ] || endpoint="unix:///var/run/docker.sock"

  case "$endpoint" in
    unix:///*) socket="${endpoint#unix://}" ;;
    *) err "Docker context endpoint '$endpoint' is remote; aicontainer requires a local Unix-socket context"; return 1 ;;
  esac
  case "$socket" in
    /*) ;;
    *) err "Docker context returned a non-absolute Unix socket path: $socket"; return 1 ;;
  esac
  # Keep the generated dotenv line unambiguous and non-executable. These cover
  # standard Docker, Colima, OrbStack, rootless Docker, and Docker Desktop
  # paths; an exotic path gets an actionable failure rather than interpolation.
  case "$socket" in
    *[!A-Za-z0-9_./@%+-]*)
      err "Docker socket path contains unsupported characters: $socket"
      return 1
      ;;
  esac
  printf '%s\n' "$socket"
}

# The daemon resolves a bind source in its own filesystem, not the host's. A
# VM-based runtime runs the daemon in a Linux VM, where the context's host path
# (for example ~/.docker/run/docker.sock) is a forwarded socket the daemon
# cannot bind: Docker Desktop refuses it, and in a Colima/Lima VM it is not the
# daemon's socket. Their daemon's own socket in the VM is /var/run/docker.sock.
# Print the runtime that serves the host socket $1:
#   docker-desktop, colima, lima, rancher-desktop
#             rootful daemon in a VM: bind /var/run/docker.sock
#   orbstack  maps the host path into its VM itself
#   rootless  rootless daemon: /var/run/docker.sock in its namespace can be a
#             different, rootful daemon, so the host path is kept
#   other     any other daemon that answered (native Linux, unknown runtimes)
#   unknown   no answer and no runtime's default path
# The daemon's own `docker info` answer decides. The default paths are used
# only while it cannot answer (aic init/sync with Docker stopped), so that
# state matches what the next start writes. aic never reads the bind source
# from the environment or from `docker info`: it is the host path or the one
# fixed VM path.
docker_runtime_kind () {
  local socket="$1" info os="" name="" security="" kind="" path_kind
  if info="$(docker -H "unix://$socket" info \
        --format '{{.OperatingSystem}}|{{.Name}}|{{json .SecurityOptions}}' 2>/dev/null)" \
      && [ -n "$info" ]; then
    os="${info%%|*}"; info="${info#*|}"
    name="${info%%|*}"; security="${info#*|}"
  fi
  # A CLI that cannot connect can still print the empty template ("||null"),
  # and an answer without the security options cannot prove a rootful daemon.
  # Only a complete answer counts; anything else is "no answer".
  case "$security" in '['*']'|null) ;; *) os="" ;; esac
  if [ -n "$os" ] && [ -n "$name" ]; then
    case "$security" in *'"name=rootless"'*) printf 'rootless\n'; return 0 ;; esac
    case "$os" in
      "Docker Desktop") printf 'docker-desktop\n'; return 0 ;;
      OrbStack) printf 'orbstack\n'; return 0 ;;
    esac
    # Lima-based VMs report their VM hostname.
    case "$name" in
      lima-rancher-desktop) kind="rancher-desktop" ;;
      colima|colima-*) kind="colima" ;;
      lima-*) kind="lima" ;;
    esac
    path_kind="$(docker_default_socket_runtime "$socket")"
    if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
      # macOS has no native daemon, so this one runs in a VM. `colima
      # --hostname` changes the name but not the default socket path.
      if [ -z "$kind" ]; then
        case "$path_kind" in colima|lima|rancher-desktop) kind="$path_kind" ;; esac
      fi
    elif [ "$path_kind" != "$kind" ]; then
      # A Linux host can have a Lima-style hostname, so on Linux the socket
      # must also be that runtime's default path.
      kind=""
    fi
    printf '%s\n' "${kind:-other}"
    return 0
  fi
  kind="$(docker_default_socket_runtime "$socket")"
  case "$kind" in
    # Lima's default docker template is rootless; only the daemon can tell.
    ''|lima) printf 'unknown\n' ;;
    *) printf '%s\n' "$kind" ;;
  esac
}

# The runtime that creates this host socket path by default, or nothing.
docker_default_socket_runtime () {
  case "$1" in
    "$HOME/.docker/run/docker.sock"|"$HOME/.docker/desktop/docker.sock") printf 'docker-desktop\n' ;;
    "$HOME/.orbstack/run/docker.sock") printf 'orbstack\n' ;;
    "$HOME/.colima/"*/docker.sock|"$HOME/.config/colima/"*/docker.sock) printf 'colima\n' ;;
    "$HOME/.rd/docker.sock") printf 'rancher-desktop\n' ;;
    "$HOME/.lima/"*/sock/docker.sock) printf 'lima\n' ;;
  esac
}

# The bind source for the managed socket mounts: the VM daemon's socket for a
# rootful VM runtime, the host socket $1 otherwise. $2 is a kind that the
# caller already detected.
docker_socket_bind_source () {
  local kind="${2:-}"
  [ -n "$kind" ] || kind="$(docker_runtime_kind "$1")"
  case "$kind" in
    docker-desktop|colima|lima|rancher-desktop) printf '/var/run/docker.sock\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# AIC_DOCKER_SOCKET is the bind source for the daemon, not the host socket that
# the Docker CLI talks to. AIC_PROJECT_NAME is the value of the managed Compose
# name line (AIC_COMPOSE_NAME_LINE). aic exports it here, so the value that the
# environment or a stale .env holds never wins for an aic command.
export_runtime_environment () {
  local socket
  socket="$(resolve_docker_socket)" || return 1
  # Ask the daemon once per process. A daemon that starts between the .env
  # write and the validation would otherwise flip the answer and fail the gate.
  if [ "$aic_bind_source_for" != "$socket" ]; then
    aic_bind_source="$(docker_socket_bind_source "$socket")"
    aic_bind_source_for="$socket"
  fi
  AIC_DOCKER_SOCKET="$aic_bind_source"
  AIC_RUNTIME_USER="$(runtime_user_id)"
  AIC_STATUS_RELAY="$(status_relay_mode)" || return 1
  AIC_STATUS_PROJECT="$(expected_project_label)"
  AIC_STATUS_PROJECT_ID="$(expected_project_name)"
  AIC_PROJECT_NAME="$AIC_STATUS_PROJECT_ID"
  export AIC_DOCKER_SOCKET AIC_RUNTIME_USER AIC_STATUS_RELAY \
    AIC_STATUS_PROJECT AIC_STATUS_PROJECT_ID AIC_PROJECT_NAME
}

# Run the Dev Containers CLI without the .devcontainer/.env values that
# export_runtime_environment() exported for aic's own Compose calls. Compose in
# the CLI then reads them from .devcontainer/.env, and its initializeCommand
# child (`aic initialize`) inherits none of them: that child refuses each one
# it inherits (check_devcontainer_project_name()). AIC_PROJECT_NAME stays
# pinned (pin_compose_project_name()).
# shellcheck disable=SC2154 # aic_runtime_env_keys is set in aic
without_runtime_environment () {
  # shellcheck disable=SC2086 # the key list is split on purpose
  ( unset $aic_runtime_env_keys; exec "$@" )
}

# A repository must not be able to opt itself into a host callback. The host
# user does that globally with one exact, non-symlinked marker file:
#   ~/.config/aicontainer/status-relay  (contents: "enabled\n")
# Its contents never enter the container; only the generated 0/1 mode does.
# XDG_CONFIG_HOME is deliberately not honored: the personal-overlay seed dir
# is fixed at $HOME/.config/aicontainer in both Compose templates and in
# prepare_host_seed_paths(), so a second root here would read a directory the
# rest of the project never touches — a silently ignored marker, not an error.
status_relay_mode () {
  local root file bytes value
  root="$HOME/.config"
  file="$root/aicontainer/status-relay"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '0\n'
    return 0
  fi
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    err "$file must be a regular file, not a symlink"
    return 1
  fi
  bytes="$(wc -c < "$file" | tr -d '[:space:]')"
  value="$(cat "$file" 2>/dev/null || true)"
  if [ "$bytes" != 8 ] || [ "$value" != enabled ]; then
    err "$file must contain exactly 'enabled' followed by a newline"
    return 1
  fi
  printf '1\n'
}

# The 0/1 mode the project will actually run with. write_runtime_environment_file()
# owns the file, so this is generated state, never repository input: a missing or
# unreadable file means "not applied yet", which is exactly the disabled default.
read_applied_status_relay () {
  local file=".devcontainer/.env" value
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    value="$(sed -n 's/^AIC_STATUS_RELAY=\(.*\)$/\1/p' "$file" | tail -n1)"
  fi
  if [ "${value:-0}" = 1 ]; then printf '1\n'; else printf '0\n'; fi
}

# .devcontainer/.env is generated host state: write_runtime_environment_file()
# writes it, and validate_runtime_environment_file() compares its exact content.
# It holds AIC_PROJECT_NAME, the path-unique name that the committed Compose
# name line reads, so a clone at another path writes its own value.
write_runtime_environment_file () {
  local file=".devcontainer/.env" tmp
  export_runtime_environment || die "could not generate the managed host runtime environment"
  [ -d .devcontainer ] || return 0
  if [ -L "$file" ] || { [ -e "$file" ] && [ ! -f "$file" ]; }; then
    die "$file must be a regular file, not a symlink"
  fi
  tmp="$(mktemp ".devcontainer/.aic-env.XXXXXX")"
  printf 'AIC_DOCKER_SOCKET=%s\nAIC_RUNTIME_USER=%s\nAIC_STATUS_RELAY=%s\nAIC_STATUS_PROJECT=%s\nAIC_STATUS_PROJECT_ID=%s\nAIC_PROJECT_NAME=%s\n' \
    "$AIC_DOCKER_SOCKET" "$AIC_RUNTIME_USER" "$AIC_STATUS_RELAY" \
    "$AIC_STATUS_PROJECT" "$AIC_STATUS_PROJECT_ID" "$AIC_PROJECT_NAME" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
}

validate_runtime_environment_file () {
  local file=".devcontainer/.env" expected actual
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  expected="AIC_DOCKER_SOCKET=$AIC_DOCKER_SOCKET
AIC_RUNTIME_USER=$AIC_RUNTIME_USER
AIC_STATUS_RELAY=$AIC_STATUS_RELAY
AIC_STATUS_PROJECT=$AIC_STATUS_PROJECT
AIC_STATUS_PROJECT_ID=$AIC_STATUS_PROJECT_ID
AIC_PROJECT_NAME=$AIC_PROJECT_NAME"
  actual="$(cat "$file" 2>/dev/null || true)"
  [ "$actual" = "$expected" ]
}

# Return 0 when Git tracks .devcontainer/.env, 1 when it does not, and 2 when
# the check cannot run. The file is host state, and the managed .gitignore
# excludes it; a committed copy gives every other clone the host values and
# the project name of this checkout. The pathspec ignores case: on a
# case-insensitive volume, .devcontainer/.ENV is the same file. Without Git,
# or without a .git directory, nothing is tracked. Any Git error is 2, so the
# callers fail closed. ls-files exits 0 whether or not the pathspec matches
# (only --error-unmatch makes no-match an error, and then a no-match and a
# real error cannot be told apart), so the output decides. core.fsmonitor is
# off, so the query cannot run a program that the Git config names. Call this
# only when git_control_path_problems() is empty: a planted .git/commondir
# would make Git read the config of another directory.
runtime_environment_file_tracked () {
  local out
  command -v git >/dev/null 2>&1 || return 1
  [ -e .git ] || [ -L .git ] || return 1
  out="$(git --git-dir=.git --work-tree=. -c core.fsmonitor=false \
      ls-files -z -- ':(icase).devcontainer/.env' 2>/dev/null | tr '\0' '\n'
    exit "${PIPESTATUS[0]}")" || return 2
  [ -n "$out" ] || return 1
  return 0
}
