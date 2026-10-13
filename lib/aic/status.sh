# shellcheck shell=bash
# =============================================================================
# lib/aic/status.sh
# =============================================================================
# Read-only reports: aic status, and the trust-boundary summary that aic up and
# aic preflight print.
#
# aic sources this file. It only defines functions.
# =============================================================================

# Best-effort detection of whether the opt-in outbound firewall is currently
# active inside the running container. Echoes on|off|unknown and never fails.
# The firewall is enable-only and does not survive a restart. Only a project
# with .devcontainer/firewall-enable gets it on every start, so "off"/"unknown"
# is the safe (network-open) default.
# `sudo aic-firewall status` is one of the three scoped-sudo scripts, so this
# read is allowed; when enabled the OUTPUT chain shows `policy DROP`.
firewall_live_state () {
  local project template cid devcontainer out
  project="$(project_name)"
  template="$(trusted_compose_template)"
  cid="$(trusted_template_compose -p "$project" -f "$template" ps -q devcontainer 2>/dev/null)" || { echo unknown; return; }
  [ -n "$cid" ] || { echo unknown; return; }
  [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" = "true" ] || { echo unknown; return; }
  devcontainer="$(resolve_devcontainer 2>/dev/null)" || { echo unknown; return; }
  out="$(COMPOSE_PROJECT_NAME="$project" AIC_PROJECT_NAME="$(expected_project_name)" "$devcontainer" exec --workspace-folder . sudo aic-firewall status 2>/dev/null)" || { echo unknown; return; }
  if grep -q 'policy DROP' <<<"$out"; then echo on; else echo off; fi
}

# Print the trust boundary for the current project: what the agent can read,
# write, and reach. Folded into `aic up` (mode=up reports network OPEN without
# .devcontainer/firewall-enable, since a freshly (re)created container then
# never has the opt-in firewall applied; with the marker it live-detects) and
# exposed standalone as `aic preflight` (live-detects the firewall state).
# The protections are real but otherwise invisible — this makes them auditable.
# See docs/user/security.md "What crosses the boundary" for the canonical table.
print_boundary_summary () {
  local mode="${1:-preflight}" project net declared=0
  project="$(project_name)"
  [ -f .devcontainer/firewall-enable ] && declared=1
  if [ "$mode" = "up" ] && [ "$declared" -eq 0 ]; then net="open"; else net="$(firewall_live_state)"; fi

  local b r y dim rst
  if [ -t 1 ]; then
    b=$'\033[1m'; r=$'\033[31m'; y=$'\033[33m'; dim=$'\033[2m'; rst=$'\033[0m'
  else
    b=""; r=""; y=""; dim=""; rst=""
  fi

  printf "\n%saic: trust boundary for project '%s'%s\n\n" "$b" "$project" "$rst"

  printf "  %sFilesystem%s\n" "$b" "$rst"
  printf "    rw   /workspace                               your project (the only writable host path)\n"
  printf "    ro   /host-seed/*.json                        root-sanitized, allowlisted preferences\n"
  printf "    ro   .devcontainer/, top-level .git controls  AI cannot rewrite its sandbox or this repo's Git config/hooks\n"
  printf "    %s! host Git here can still run agent-written files%s: submodules, nested repos, hook scripts kept in the repo\n" "$y" "$rst"
  printf "    %s--   raw host config, host home, ~/.ssh, host credentials: NOT mounted%s\n" "$dim" "$rst"

  printf "\n  %sSecrets%s\n" "$b" "$rst"
  printf "    .env* reads/writes blocked by the PreToolUse hook (fires even in bypass mode)\n"
  printf "    %syour project's own .env still lives in /workspace: the hook gates the agent, not the file%s\n" "$dim" "$rst"
  printf "    tool login: only four validated JSON credential files and gh/npm login entries cross projects via a networkless sidecar\n"
  printf "    git credentials: none forwarded (you auth fresh inside); global Git config is root-owned under /etc\n"

  # Commit signing: the host signing key is never forwarded, so signing only
  # works here via a sandbox key set up with `aic signing`. Surface the state
  # so a host that signs commits doesn't hit a cryptic failure (or silently
  # push unsigned commits) without warning.
  local sg_st sg_mode sg_key sg_host
  sg_st="$(signing_state 2>/dev/null)" || sg_st="mode= key=0"
  sg_mode="${sg_st#mode=}"; sg_mode="${sg_mode%% key=*}"
  sg_key="${sg_st##*key=}"
  sg_host="$(git config --global --get commit.gpgsign 2>/dev/null || true)"
  if [ "$sg_mode" = "disabled" ]; then
    printf "    commit signing: disabled in sandbox (via 'aic signing')\n"
  elif [ "$sg_key" = "1" ]; then
    printf "    commit signing: sandbox ssh key (register its pubkey on GitHub to verify)\n"
  elif [ "$sg_host" = "true" ]; then
    printf "    %s! commit signing: host signs, but its key isn't here%s — commits unsigned; run 'aic signing'\n" "$y" "$rst"
  fi

  printf "\n  %sSessions%s\n" "$b" "$rst"
  if docker volume inspect "${project}_aic-sessions" >/dev/null 2>&1; then
    printf "    full tool homes -> volume %s_aic-sessions  (project-only; survives rebuild)\n" "$project"
  else
    printf "    full tool homes -> volume %s_aic-sessions  (created on first 'aic up')\n" "$project"
  fi
  printf "    shared globally: tool login JSON, gh/npm auth, signing key, shell history\n"

  printf "\n  %sDocker daemon%s\n" "$b" "$rst"
  case "$(read_compose_docker_mode)" in
    rw)
      printf "    %s! READ-WRITE socket-proxy%s: the agent can create/build containers on the HOST\n" "$r" "$rst"
      printf "      daemon (a container-escape vector, and sibling containers dodge the firewall).\n"
      printf "    %sreduce to reads: aic sync --docker-read; disable: aic sync --no-docker%s\n" "$dim" "$rst"
      ;;
    ro)
      printf "    %s! READ socket-proxy%s: host Docker APIs can expose containers' metadata, logs, and files\n" "$y" "$rst"
      printf "      to the agent; it cannot create or build containers.\n"
      printf "    %sdisable with: aic sync --no-docker && aic rebuild%s\n" "$dim" "$rst"
      ;;
    none)
      printf "    object APIs disabled: ping/version only; host containers/images/volumes are hidden\n"
      printf "    %senable only if needed: --docker-read (inspect) or --docker (read-write)%s\n" "$dim" "$rst"
      ;;
    *)
      printf "    %s! invalid managed proxy toggle set — run 'aic sync --no-docker'%s\n" "$r" "$rst"
      ;;
  esac

  printf "\n  %sNetwork%s\n" "$b" "$rst"
  printf "    %scloud metadata / link-local (169.254.0.0/16) blocked by default on every create%s\n" "$dim" "$rst"
  if [ "$declared" -eq 1 ]; then
    printf "    firewall declared by .devcontainer/firewall-enable: enabled on every container start\n"
  fi
  case "$net" in
    on)
      printf "    %s* firewall ENABLED%s  (default DROP + curated allowlist active)\n" "$b" "$rst"
      ;;
    unknown)
      printf "    %s! full outbound by default%s: internet and your LAN (metadata excepted, see above)\n" "$y" "$rst"
      printf "    %s(container not running: live firewall state unknown)%s\n" "$dim" "$rst"
      printf "    lock down:  aic shell  ->  sudo aic-firewall enable\n"
      ;;
    *)
      printf "    %s! FULL OUTBOUND%s: reaches the internet and your LAN (metadata excepted, see above)\n" "$r" "$rst"
      printf "    lock down per-project:  aic shell  ->  sudo aic-firewall enable\n"
      printf "    or on every start:      touch .devcontainer/firewall-enable && aic rebuild\n"
      ;;
  esac

  if [ -f .devcontainer/docker-compose.override.yml ] || [ -f .devcontainer/firewall-allowlist ] \
      || [ -f .devcontainer/firewall-presets ]; then
    printf "\n  %sProject overrides%s\n" "$b" "$rst"
    if [ -f .devcontainer/docker-compose.override.yml ]; then
      printf "    %s! docker-compose.override.yml present%s: may add mounts/env/hosts; review it.\n" "$y" "$rst"
    fi
    if [ -f .devcontainer/firewall-allowlist ]; then
      local fwcount; fwcount="$(grep -cvE '^[[:space:]]*(#|$)' .devcontainer/firewall-allowlist 2>/dev/null)" || fwcount=0
      printf "    firewall-allowlist present (%s domains): applied when you enable the firewall.\n" "$fwcount"
    fi
    if [ -f .devcontainer/firewall-presets ]; then
      local presets
      presets="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' .devcontainer/firewall-presets 2>/dev/null \
        | LC_ALL=C tr -cd 'a-z0-9-\n' | paste -sd ' ' -)" || presets=""
      printf "    firewall-presets present (%s): applied when the firewall is enabled.\n" "${presets:-none}"
    fi
  fi

  printf "\n  %sFull model:%s docs/user/security.md (\"What crosses the boundary\", \"Threat model\").\n\n" "$dim" "$rst"
}

status_volume_state () {
  local name="$1"
  if ! docker volume inspect "$name" >/dev/null 2>&1; then
    printf 'absent'
  elif docker_volume_metadata_is_safe "$name"; then
    printf 'present'
  else
    printf 'UNSAFE metadata'
  fi
}

# aic status [--json]. --json reports the same reads as one JSON object
# (lib/aic/json.sh); the reads do not change.
cmd_status () {
  if [ "$#" -eq 0 ]; then
    cmd_status_run
  elif [ "$#" -eq 1 ] && [ "$1" = --json ]; then
    json_run status "" cmd_status_run
  else
    die "usage: aic status [--json]"
  fi
}

cmd_status_run () {
  require_in_project
  local project mode tools shell docker_mode docker_raw relay_mode relay_raw relay_applied=""
  local image_state
  local consent="n/a" cli_version pinned image_summary
  local daemon=0 cid="" auth_cid="" runtime_state="unavailable" running_image=""
  local auth_state sessions_state bridge_state="unknown (Docker unavailable)" bridge_health=""
  local host_socket="unavailable" host_runtime="" bind_source="" runtime_identity
  project="$(project_name)"
  mode="pull"; [ -f .devcontainer/Dockerfile ] && mode="build"
  tools="$(read_aic_tools)"; [ -n "$tools" ] || tools="claude-code,codex,opencode"
  shell="$(read_aic_shell)"; [ -n "$shell" ] || shell="$DEFAULT_SHELL"
  runtime_identity="$(runtime_user_id)"
  if host_socket="$(resolve_docker_socket 2>/dev/null)"; then
    host_runtime="$(docker_runtime_kind "$host_socket")"
    bind_source="$(docker_socket_bind_source "$host_socket" "$host_runtime")"
  else
    host_socket="unavailable"
  fi
  docker_mode="$(read_compose_docker_mode)"
  docker_raw="$docker_mode"
  case "$docker_mode" in
    none) docker_mode="none (ping/version only)" ;;
    ro) docker_consent_matches ro && consent="present" || consent="missing"; docker_mode="read-only (consent: $consent)" ;;
    rw) docker_consent_matches rw && consent="present" || consent="missing"; docker_mode="read-write (consent: $consent)" ;;
    *) docker_mode="invalid — run aic sync --no-docker" ;;
  esac
  if relay_mode="$(status_relay_mode 2>/dev/null)"; then
    relay_raw="$relay_mode"
    # The marker is host consent; the generated .env is what this project runs
    # with. Report both, so the line never claims a relay that only starts
    # after the next rebuild (which rewrites .env and recreates the container).
    relay_applied="$(read_applied_status_relay)"
    if [ "$relay_mode" != "$relay_applied" ]; then
      [ "$relay_mode" = 1 ] \
        && relay_mode="enabled on host; pending aic rebuild" \
        || relay_mode="disabled on host; pending aic rebuild"
    elif [ "$relay_mode" = 1 ]; then
      relay_mode="enabled (host.docker.internal:8787)"
    else
      relay_mode="disabled"
    fi
  else
    relay_raw=invalid
    relay_mode="invalid host marker"
  fi

  cli_version="$(read_aic_version)"
  pinned="$(read_pinned_compose_version)"
  if [ "$mode" = "build" ]; then
    image_state="build"
    image_summary="local build (CLI v$cli_version)"
  elif [ -z "$pinned" ]; then
    image_state="unrecognized"
    image_summary="unrecognized pull image (CLI v$cli_version; run aic sync)"
  elif [ "$pinned" = "$cli_version" ]; then
    image_state="match"
    image_summary="pinned v$pinned (matches CLI)"
  else
    image_state="drift"
    image_summary="pinned v$pinned (CLI v$cli_version; run aic sync && aic rebuild)"
  fi

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    daemon=1
    cid="$(docker ps -aq \
      --filter "label=com.docker.compose.project=$project" \
      --filter 'label=com.docker.compose.service=devcontainer' 2>/dev/null | head -n1)" || cid=""
    if [ -n "$cid" ]; then
      runtime_state="$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null)" || runtime_state="unknown"
      running_image="$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null)" || running_image=""
    else
      runtime_state="not created"
    fi
    auth_cid="$(docker ps -aq \
      --filter "label=com.docker.compose.project=$project" \
      --filter 'label=com.docker.compose.service=aic-auth-sync' 2>/dev/null | head -n1)" || auth_cid=""
    if [ -z "$auth_cid" ]; then
      bridge_state="not created"
    else
      bridge_state="$(docker inspect --format '{{.State.Status}}' "$auth_cid" 2>/dev/null)" || bridge_state="unknown"
      bridge_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$auth_cid" 2>/dev/null)" || bridge_health=""
      case "$bridge_health" in
        healthy) bridge_state="healthy" ;;
        starting) bridge_state="starting" ;;
        unhealthy) bridge_state="UNHEALTHY" ;;
      esac
    fi
    auth_state="$(status_volume_state aic-auth-global)"
    sessions_state="$(status_volume_state "${project}_aic-sessions")"
  else
    auth_state="unknown (Docker unavailable)"
    sessions_state="unknown (Docker unavailable)"
  fi

  if json_mode; then
    status_json_fields
    return 0
  fi
  printf 'aic status\n'
  printf '  project:  %s\n' "$project"
  printf '  mode:     %s; tools: %s; shell: %s\n' "$mode" "$tools" "$shell"
  printf '  Docker:   %s\n' "$docker_mode"
  printf '  relay:    %s\n' "$relay_mode"
  printf '  host:     socket %s' "$host_socket"
  [ -n "$host_runtime" ] && printf ' (%s; mounts bind %s)' "$host_runtime" "$bind_source"
  printf '; runtime uid:gid %s\n' "$runtime_identity"
  printf '  image:    %s\n' "$image_summary"
  printf '  runtime:  %s' "$runtime_state"
  [ -n "$running_image" ] && printf ' (%s)' "$running_image"
  printf '\n'
  printf '  auth:     credential bridge %s\n' "$bridge_state"
  printf '  volumes:  auth %s; project sessions %s\n' "$auth_state" "$sessions_state"
  [ "$daemon" = "1" ] || printf '  hint:     start Docker to inspect runtime and volume state\n'
}

# Record the values of cmd_status_run as JSON fields. It reads the locals of
# cmd_status_run (bash dynamic scope), so call it only from there. Each text
# value maps to one fixed token; the paths and names are strings.
status_json_fields () {
  local tool rest="$tools," tools_json="" sep=""
  # Split on commas without word splitting or globbing: the value comes from
  # devcontainer.json.
  while [ -n "$rest" ]; do
    tool="${rest%%,*}"
    rest="${rest#*,}"
    [ -n "$tool" ] || continue
    tools_json="$tools_json$sep$(json_string "$tool")"
    sep=","
  done
  json_field_string project "$project"
  json_field_string mode "$mode"
  json_field tools "[$tools_json]"
  json_field_string shell "$shell"
  case "$docker_raw" in none|ro|rw) ;; *) docker_raw=invalid ;; esac
  json_field_string docker "$docker_raw"
  case "$docker_raw" in ro|rw) json_field_string docker_consent "$consent" ;; *) json_field docker_consent null ;; esac
  case "$relay_raw" in 1) relay_raw=enabled ;; 0) relay_raw=disabled ;; *) relay_raw=invalid ;; esac
  json_field_string relay "$relay_raw"
  case "$relay_applied" in 1) relay_applied=enabled ;; 0) relay_applied=disabled ;; *) relay_applied="" ;; esac
  json_field_string relay_applied "$relay_applied"
  [ "$host_socket" != unavailable ] || host_socket=""
  json_field_string socket "$host_socket"
  json_field_string runtime_kind "$host_runtime"
  json_field_string bind_source "$bind_source"
  json_field_string runtime_uid_gid "$runtime_identity"
  json_field_string cli_version "$cli_version"
  json_field_string image "$image_state"
  json_field_string image_pinned "$pinned"
  if [ "$daemon" = 1 ]; then json_field docker_available true; else json_field docker_available false; fi
  json_field_string container "$(status_json_token "$runtime_state")"
  json_field_string container_image "$running_image"
  json_field_string auth_bridge "$(status_json_token "$bridge_state")"
  json_field_string auth_volume "$(status_json_token "$auth_state")"
  json_field_string sessions_volume "$(status_json_token "$sessions_state")"
}

# Map a text state of cmd_status_run to its JSON token: lower case, and one
# fixed word for each text with spaces.
status_json_token () {
  case "$1" in
    "not created") printf 'not-created' ;;
    "UNSAFE metadata") printf 'unsafe' ;;
    "unknown (Docker unavailable)") printf 'unavailable' ;;
    *) printf '%s' "$1" | tr '[:upper:]' '[:lower:]' ;;
  esac
}
