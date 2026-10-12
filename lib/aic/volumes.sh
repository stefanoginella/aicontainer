# shellcheck shell=bash
# =============================================================================
# lib/aic/volumes.sh
# =============================================================================
# Managed Docker volumes: metadata safety, the legacy session-volume migration,
# host seed paths, the volume bootstrap, the stop of an owned legacy stack, and
# the volume size.
#
# aic sources this file. It only defines functions.
# =============================================================================

# Copy the legacy basename-scoped transcript volume into the new path-hashed
# volume exactly once. The source stays intact because another same-basename
# checkout may have shared it under the historical naming scheme. The helper
# image is digest-pinned and runs without network, with only the narrow file
# ownership capabilities required by the copy; it is the same bootstrap image
# used by the managed initializeCommand.

# A Compose declaration cannot make a pre-created physical Docker volume safe:
# the same name may already point at a local-driver bind mount (or a volume
# plugin). Inspect the daemon object itself before any fixed helper mounts or
# chowns it. Only ordinary local volumes with no driver options are accepted.
docker_volume_metadata_is_safe () {
  local name="$1" metadata
  metadata="$(docker volume inspect --format '{{json .}}' "$name" 2>/dev/null)" || return 1
  aic_helper volume-safe "$metadata" >/dev/null 2>&1
}

assert_safe_docker_volume () {
  local name="$1"
  docker volume inspect "$name" >/dev/null 2>&1 || \
    die "managed Docker volume is missing or cannot be inspected: $name"
  docker_volume_metadata_is_safe "$name" || \
    die "refusing unsafe managed volume '$name' (requires Driver=local with no driver options)"
}

assert_safe_docker_volume_if_present () {
  local name="$1"
  docker volume inspect "$name" >/dev/null 2>&1 || return 0
  assert_safe_docker_volume "$name"
}

ensure_safe_docker_volume () {
  local name="$1"
  docker volume create "$name" >/dev/null || die "could not create managed Docker volume: $name"
  assert_safe_docker_volume "$name"
}

# Basename-scoped projects could collide historically, so the old volume name
# alone is never ownership evidence. Require a container whose inspected labels
# identify this exact canonical workspace and legacy Compose project, and whose
# actual mount table attaches this exact volume at one of the two session-root
# paths used by aicontainer. Docker filters narrow the candidates; the explicit
# inspect comparison is the security check.
legacy_session_volume_owned_by_workspace () {
  local old_vol="$1" legacy="$2" workspace candidates users cid inspected proved=0
  workspace="$(canonical_root)"
  candidates="$(docker ps -aq \
    --filter "label=devcontainer.local_folder=$workspace" \
    --filter "label=com.docker.compose.project=$legacy" 2>/dev/null)" || return 1
  [ -n "$candidates" ] || return 1

  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    inspected="$(docker inspect --format '{{json .}}' "$cid" 2>/dev/null)" || continue
    if aic_helper owns-session-volume \
        "$inspected" "$workspace" "$legacy" "$old_vol" >/dev/null 2>&1; then
      proved=1
      break
    fi
  done <<< "$candidates"
  [ "$proved" = "1" ] || return 1

  # If a second checkout still has this basename-colliding volume attached,
  # even the exact container above cannot prove the data is workspace-private.
  # Treat every other label owner as ambiguity; sidecars from the same exact
  # workspace/project are harmless and may legitimately share the volume.
  users="$(docker ps -aq --filter "volume=$old_vol" 2>/dev/null)" || return 1
  [ -n "$users" ] || return 1
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    inspected="$(docker inspect --format '{{json .}}' "$cid" 2>/dev/null)" || return 1
    aic_helper volume-user-is-owner \
      "$inspected" "$workspace" "$legacy" "$old_vol" >/dev/null 2>&1 || return 1
  done <<< "$users"
  return 0
}

# Project names this exact workspace ran under before the current one, other
# than the basename-scoped legacy name: Compose names whose hash came from
# another spelling of the path. Before canonical_root() existed, a project set
# up from a wrong-case path on a case-insensitive volume got the hash of that
# spelling, while VS Code and the Dev Containers CLI use the stored one.
# Only containers that carry this exact canonical workspace label count, and
# only a name with this project's label and a 12-hex hash. A name read from the
# Compose file would not do: sync overwrites it before the copy can run.
previous_project_names () {
  local workspace label expected names name
  workspace="$(canonical_root)"; label="$(expected_project_label)"
  expected="$(expected_project_name)"
  names="$(docker ps -a --filter "label=devcontainer.local_folder=$workspace" \
    --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null)" || return 0
  while IFS= read -r name; do
    [[ "$name" =~ ^aic-${label}-[0-9a-f]{12}$ ]] || continue
    [ "$name" != "$expected" ] || continue
    printf '%s\n' "$name"
  done <<< "$names" | sort -u
}

# Copy the old session transcripts into this workspace's current volume: from
# the basename-scoped legacy name, then from every earlier spelling of the path.
migrate_legacy_session_volume () {
  local mode="${1:-strict}" old
  migrate_session_volume_from "$mode" "$(legacy_project_name)"
  while IFS= read -r old; do
    [ -z "$old" ] || migrate_session_volume_from "$mode" "$old"
  done <<< "$(previous_project_names)"
}

migrate_session_volume_from () {
  local mode="$1" legacy="$2" expected old_vol new_vol image reply
  expected="$(expected_project_name)"
  [ "$legacy" != "$expected" ] || return 0
  old_vol="${legacy}_aic-sessions"
  new_vol="${expected}_aic-sessions"
  image="busybox@sha256:fd8d9aa63ba2f0982b5304e1ee8d3b90a210bc1ffb5314d980eb6962f1a9715d"

  if ! docker info >/dev/null 2>&1; then
    [ "$mode" = "defer" ] && return 0
    die "Docker is unavailable; cannot check/migrate the legacy sessions volume"
  fi
  docker volume inspect "$old_vol" >/dev/null 2>&1 || return 0
  if docker volume inspect "$new_vol" >/dev/null 2>&1; then
    assert_safe_docker_volume "$new_vol"
    return 0
  fi

  if ! legacy_session_volume_owned_by_workspace "$old_vol" "$legacy"; then
    err "legacy session volume '$old_vol' cannot be uniquely tied to this workspace."
    if [ "$mode" = "defer" ]; then
      err "leaving it untouched; run 'aic up' in an interactive terminal to choose whether to import it."
      return 0
    fi
    if [ ! -t 0 ]; then
      die "the legacy volume was preserved; run 'aic up' in an interactive terminal to choose import or a fresh isolated session volume"
    fi
    printf "aic: import this ambiguous legacy volume into this workspace? [y/N] " >&2
    IFS= read -r reply || reply=""
    case "$reply" in
      y|Y|yes|YES) ;;
      *)
        ensure_safe_docker_volume "$new_vol"
        echo "aic: legacy volume preserved and not imported; this workspace will use a fresh isolated session volume."
        return 0
        ;;
    esac
  fi

  assert_safe_docker_volume "$old_vol"
  echo "aic: migrating legacy session transcripts: $old_vol → $new_vol"
  ensure_safe_docker_volume "$new_vol"
  if ! docker run --rm --network none --read-only --cap-drop ALL \
      --cap-add CHOWN --cap-add FOWNER --cap-add DAC_OVERRIDE \
      --security-opt no-new-privileges:true \
      -v "$old_vol:/from:ro" -v "$new_vol:/to" \
      "$image" sh -c 'cp -a /from/. /to/'; then
    docker volume rm "$new_vol" >/dev/null 2>&1 || true
    [ "$mode" = "defer" ] && { err "session migration deferred after the copy failed"; return 0; }
    die "could not copy the legacy sessions volume; the original remains untouched"
  fi
  echo "aic: session migration complete (the legacy source volume was preserved)."
}

# Host-side volume/bootstrap work shared by `aic up` and direct VS Code starts.
# Fixed paths only: repository input never becomes a helper command argument.
prepare_host_seed_paths () {
  local dir file
  [ -n "${HOME:-}" ] || die "HOME is not set; cannot prepare host configuration seeds"
  # ~/.config/aicontainer is the opt-in personal-overlay seed dir, mounted
  # read-only into the sanitizer. Ensure it exists so the bind source is a
  # user-owned directory (not a root-owned dir Docker would create); it stays
  # empty until the user drops rc.zsh / p10k.zsh / statusline.<ext> in it
  # (opt-in by presence).
  for dir in "$HOME/.claude" "$HOME/.codex" "$HOME/.config" "$HOME/.config/opencode" "$HOME/.config/aicontainer"; do
    if [ -e "$dir" ] || [ -L "$dir" ]; then
      [ -d "$dir" ] || die "host seed parent exists but is not a directory: $dir"
    else
      mkdir -p "$dir" || die "could not create host seed parent: $dir"
    fi
  done
  for file in "$HOME/.gitconfig" "$HOME/.claude/settings.json" \
    "$HOME/.codex/config.toml" "$HOME/.config/opencode/opencode.json"; do
    if [ -e "$file" ] || [ -L "$file" ]; then
      [ -f "$file" ] || die "host seed path exists but is not a regular file: $file"
    else
      touch "$file" || die "could not create host seed file: $file"
    fi
  done
}

initialize_managed_volumes () {
  local project sessions seed image identity uid gid
  project="$(project_name)"
  sessions="${project}_aic-sessions"
  seed="${project}_aic-sanitized-seed"
  image="busybox@sha256:fd8d9aa63ba2f0982b5304e1ee8d3b90a210bc1ffb5314d980eb6962f1a9715d"
  identity="$(runtime_user_id)"; uid="${identity%%:*}"; gid="${identity##*:}"

  ensure_safe_docker_volume aic-auth-global
  ensure_safe_docker_volume aic-shell-history
  ensure_safe_docker_volume "$sessions"
  # Compose creates this per-project output volume when absent. If it was
  # pre-created, validate its physical backing before the root sanitizer gets
  # a chance to write through it.
  assert_safe_docker_volume_if_present "$seed"

  # Only exact credential directories remain global. Whole Claude/Codex/
  # OpenCode/gh/npm homes now live in the per-project sessions volume; a
  # networkless sidecar reconciles four validated credential files and the
  # login entries of gh hosts.yml and npm npmrc between the two. Create the
  # volume.subpath roots before Compose resolves them, and align ownership
  # with Dev Containers' host-UID mapping. Both helpers re-own only entries
  # with the wrong owner or group: a full `chown -R` rewrote every inode of
  # the growing transcript tree on each start. `find` does not follow links
  # and `chown -h` changes a link itself, as `chown -h -R` did.
  if ! docker run --rm --network none --read-only --cap-drop ALL \
    --cap-add CHOWN --cap-add FOWNER --cap-add DAC_OVERRIDE \
    --security-opt no-new-privileges:true \
    -e AIC_UID="$uid" -e AIC_GID="$gid" \
    -v aic-auth-global:/v -v aic-shell-history:/history "$image" sh -c '
      set -eu
      ensure_dir() {
        p=$1
        if [ -L "$p" ] || { [ -e "$p" ] && [ ! -d "$p" ]; }; then rm -rf "$p"; fi
        mkdir -p "$p"
        chmod 0700 "$p"
      }
      for p in /v/claude /v/codex /v/opencode /v/gh /v/npm /v/signing /v/semgrep /history
      do
        ensure_dir "$p"
      done
      find /v/claude /v/codex /v/opencode /v/gh /v/npm /v/signing /v/semgrep /history \
        \( ! -user "$AIC_UID" -o ! -group "$AIC_GID" \) \
        -exec chown -h "$AIC_UID:$AIC_GID" {} +
    '; then
    die "could not prepare managed auth-volume subpaths"
  fi

  # Transparently migrate the old ~/.claude-sessions layout inside the same
  # physical per-project volume. A clean destination is renamed atomically;
  # after a partial prior migration, copy only missing entries and preserve the
  # legacy source so recovery never destroys the sole copy.
  #
  # Keep this a separate helper run from the one above. This volume is
  # agent-writable: a planted `tool-homes` symlink would send the `mv`/`cp`
  # below into any volume that the same helper also mounts. Here it can only
  # point into the helper's read-only rootfs.
  if ! docker run --rm --network none --read-only --cap-drop ALL \
    --cap-add CHOWN --cap-add FOWNER --cap-add DAC_OVERRIDE \
    --security-opt no-new-privileges:true \
    -e AIC_UID="$uid" -e AIC_GID="$gid" -v "$sessions:/v" "$image" sh -c '
      set -eu
      ensure_dir() {
        p=$1
        if [ -L "$p" ] || { [ -e "$p" ] && [ ! -d "$p" ]; }; then rm -rf "$p"; fi
        mkdir -p "$p"
        chmod 0700 "$p"
      }
      migrate() {
        src=$1; dst=$2
        [ -e "$src" ] || [ -L "$src" ] || return 0
        # Never follow an agent-planted link while this fixed root helper owns
        # the volume. A link is not valid session data in either layout.
        if [ -L "$src" ]; then rm -f "$src"; return 0; fi
        mkdir -p "$(dirname "$dst")"
        if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
          mv "$src" "$dst"
        elif [ -d "$src" ] && [ -d "$dst" ] && [ ! -L "$dst" ]; then
          cp -a -n "$src"/. "$dst"/ 2>/dev/null || true
        fi
      }

      migrate /v/claude-projects       /v/tool-homes/claude/projects
      migrate /v/claude-history.jsonl  /v/tool-homes/claude/history.jsonl
      migrate /v/claude-settings.json  /v/tool-homes/claude/settings.json
      migrate /v/claude-memory.md       /v/tool-homes/claude/CLAUDE.md
      migrate /v/claude-skills          /v/tool-homes/claude/skills
      migrate /v/claude-agents          /v/tool-homes/claude/agents
      migrate /v/claude-commands        /v/tool-homes/claude/commands
      migrate /v/claude-plugins         /v/tool-homes/claude/plugins

      migrate /v/codex-sessions         /v/tool-homes/codex/sessions
      migrate /v/codex-history.jsonl    /v/tool-homes/codex/history.jsonl
      migrate /v/codex-config.toml       /v/tool-homes/codex/config.toml
      migrate /v/codex-memory.md        /v/tool-homes/codex/AGENTS.md
      migrate /v/codex-skills           /v/tool-homes/codex/skills
      migrate /v/codex-rules            /v/tool-homes/codex/rules
      migrate /v/codex-prompts          /v/tool-homes/codex/prompts
      migrate /v/codex-plugins          /v/tool-homes/codex/plugins

      migrate /v/opencode               /v/tool-homes/opencode-data
      migrate /v/opencode-storage       /v/tool-homes/opencode-data/storage
      migrate /v/opencode-snapshot      /v/tool-homes/opencode-data/snapshot

      for p in \
        /v/tool-homes /v/tool-homes/claude /v/tool-homes/codex \
        /v/tool-homes/opencode-config /v/tool-homes/opencode-data \
        /v/tool-homes/gh /v/tool-homes/npm
      do
        ensure_dir "$p"
      done
      find /v \( ! -user "$AIC_UID" -o ! -group "$AIC_GID" \) \
        -exec chown -h "$AIC_UID:$AIC_GID" {} +
    '; then
    die "could not migrate/prepare the per-project tool homes"
  fi

  # The sanitizer is a one-shot service. Remove its exited container so every
  # create re-runs it and refreshes allowlisted host preferences.
  docker compose -p "$project" -f "$(trusted_compose_template)" rm -sf aic-seed-sanitizer >/dev/null 2>&1 || true
}

# After sync, an old devcontainer stack may still be running under the legacy
# name. `compose down` acts on the whole project, so one owned devcontainer is
# insufficient evidence: inspect every legacy-project container. At least one
# must carry this exact canonical workspace label; only fixed aic sidecars may
# omit it (Dev Containers labels the primary service, not necessarily Compose
# dependencies). A different owner, unknown unlabeled service, or unreadable
# container preserves the stack rather than risking collateral damage to
# another same-basename checkout. Never use --remove-orphans here: those are
# precisely the services the trusted managed template cannot attribute.
stop_owned_legacy_stack () {
  local old
  stop_owned_stack_named "$(legacy_project_name)"
  while IFS= read -r old; do
    [ -z "$old" ] || stop_owned_stack_named "$old"
  done <<< "$(previous_project_names)"
}

stop_owned_stack_named () {
  local legacy="$1" expected workspace containers cid inspected template proved=0
  expected="$(expected_project_name)"
  [ "$legacy" != "$expected" ] || return 0
  workspace="$(canonical_root)"
  if ! containers="$(docker ps -aq \
      --filter "label=com.docker.compose.project=$legacy" 2>/dev/null)"; then
    err "could not verify ownership of legacy Compose stack '$legacy'; preserving it."
    return 0
  fi
  [ -n "$containers" ] || return 0

  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    if ! inspected="$(docker inspect --format '{{json .}}' "$cid" 2>/dev/null)"; then
      err "legacy Compose stack '$legacy' has an unreadable container owner; preserving the whole stack."
      return 0
    fi
    if aic_helper container-owned \
        "$inspected" "$workspace" "$legacy" >/dev/null 2>&1; then
      proved=1
      continue
    fi
    if aic_helper auxiliary-container \
        "$inspected" "$legacy" >/dev/null 2>&1; then
      continue
    fi
    err "legacy Compose stack '$legacy' includes a container not provably owned by this exact workspace; preserving the whole stack."
    return 0
  done <<< "$containers"
  if [ "$proved" != "1" ]; then
    err "legacy Compose stack '$legacy' has no container proving ownership by this workspace; preserving the whole stack."
    return 0
  fi

  echo "aic: stopping this workspace's legacy Compose stack '$legacy' (current managed name: '$expected')"
  template="$(trusted_compose_template)"
  docker compose -p "$legacy" -f "$template" down \
    || err "could not stop legacy stack '$legacy'; continuing with the isolated project name"
}

# Best-effort on-disk size of a named volume, e.g. "123.4MB". Echoes "" if the
# volume doesn't exist or docker can't tell us. Uses `docker system df -v`
# (docker's own accounting — no helper container, works on a stopped container),
# matching the volume by exact name. Never blocks the caller.
volume_size () {
  local vol="$1"
  command -v docker >/dev/null 2>&1 || { echo ""; return; }
  docker volume inspect "$vol" >/dev/null 2>&1 || { echo ""; return; }
  docker system df -v 2>/dev/null | awk -v v="$vol" '$1==v {print $NF; found=1} END{if(!found) print ""}'
}
