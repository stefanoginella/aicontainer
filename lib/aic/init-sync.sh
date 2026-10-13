# shellcheck shell=bash
# =============================================================================
# lib/aic/init-sync.sh
# =============================================================================
# The aic init and aic sync commands, and the Dockerfile.project base check of
# sync.
#
# aic sources this file. It only defines functions.
# =============================================================================

cmd_init () {
  local mode="pull" force="" tools="" shell="" docker="$DEFAULT_DOCKER"
  validate_devcontainer_paths optional
  while [ $# -gt 0 ]; do
    case "$1" in
      --build) mode="build" ;;
      --force) force="1" ;;
      --with)  shift; tools="${1:-}" ;;
      --with=*) tools="${1#--with=}" ;;
      --shell) shift; shell="${1:-}" ;;
      --shell=*) shell="${1#--shell=}" ;;
      --docker-read) docker="ro" ;;
      --docker) docker="rw" ;;
      --no-docker) docker="none" ;;
      *) die "unknown init flag: $1 (try --build, --force, --docker-read, --docker, --with claude-code,codex,opencode, or --shell zsh|bash|fish)" ;;
    esac
    shift
  done

  if [ -e .devcontainer ] && [ -z "$force" ]; then
    die ".devcontainer/ already exists. Re-run with --force to overwrite."
  fi

  if [ -z "$tools" ]; then
    tools="$(prompt_tools)"
  fi
  tools="$(validate_tools "$tools")"

  if [ -z "$shell" ]; then
    shell="$(prompt_shell)"
  fi
  shell="$(validate_shell "$shell")"

  resolve_docker_socket >/dev/null || die "cannot initialize aicontainer with the selected Docker context"
  status_relay_mode >/dev/null || die "fix the host status-relay marker before initializing"
  apply_template "$mode" "$TEMPLATE_DIR" ".devcontainer" "$docker"
  patch_devcontainer_json ".devcontainer/devcontainer.json" "$tools" "$shell"
  set_docker_consent "$docker"
  echo "aic: copied $mode-mode template into .devcontainer/ (tools: $tools, shell: $shell, docker: $docker)"
  case "$docker" in
    ro) echo "aic: Docker daemon READ access ENABLED — host Docker APIs may expose container metadata, logs, and files." ;;
    rw) echo "aic: Docker daemon READ-WRITE access ENABLED — the agent can create/build containers on the host daemon." ;;
  esac
  [ -f .devcontainer/docker-compose.override.yml ] && \
    echo "aic: wired existing docker-compose.override.yml into dockerComposeFile"
  if [ "$mode" = "pull" ]; then
    local ver; ver="$(read_aic_version)"
    echo "aic: 'aic up' will pull ghcr.io/stefanoginella/aicontainer:v${ver} (pinned to this aic's version)"
  else
    echo "aic: 'aic up' will build the image locally from .devcontainer/Dockerfile"
  fi
  echo "aic: next: 'aic up' then 'aic shell'"
}

# A project's Dockerfile.project is project-owned, so `aic sync` never rewrites
# it — but if it pins the aicontainer base to an explicit
# `FROM ghcr.io/stefanoginella/aicontainer:vX.Y.Z`, that tag silently lags the
# version this aic pins into docker-compose.yml after `npm update -g
# aicontainer`. And when an override's build: block points at Dockerfile.project,
# that stale FROM is what actually runs (the compose `image:` pin is bypassed),
# so the container can come up on an old base with none of the new behavior.
# Warn on that drift; rewrite it in place only when --bump-base is given, and
# only for a literal version pin — never :latest floats, ARG-templated bases,
# or other repos (those are deliberate, so we leave them alone).
check_dockerfile_project_base () {
  local ver="$1" do_bump="$2"
  local df=".devcontainer/Dockerfile.project"
  [ -f "$df" ] || return 0

  local repo="ghcr.io/stefanoginella/aicontainer"
  local cur_tag
  cur_tag="$(sed -n "s|^[[:space:]]*FROM[[:space:]]\{1,\}${repo}:\([A-Za-z0-9._-]\{1,\}\).*|\1|p" "$df" | head -n1)"
  [ -n "$cur_tag" ] || return 0          # no literal FROM <repo>:tag — templated, other repo, or absent

  local want="v${ver}"
  [ "$cur_tag" = "$want" ] && return 0    # already matches the pinned version

  if [ "$cur_tag" = "latest" ]; then
    echo "aic: note: Dockerfile.project tracks ${repo}:latest (floating base); not pinning it to :${want}" >&2
    return 0
  fi

  # Drift detected. With --bump-base we rewrite in place unconditionally.
  # Otherwise warn (yellow on a TTY) and, when stdin is interactive, offer to
  # bump now (default Yes). Non-interactive callers (CI, piped) are never
  # prompted: they get the command hint and the file is left untouched —
  # preserving the "plain sync only warns" contract the CLI tests guard.
  if [ -z "$do_bump" ]; then
    local y rst
    if [ -t 2 ]; then y=$'\033[33m'; rst=$'\033[0m'; else y=""; rst=""; fi
    printf "%saic: warning: Dockerfile.project pins %s:%s, but this aic pins :%s.%s\n" \
      "$y" "$repo" "$cur_tag" "$want" "$rst" >&2

    if [ -t 0 ]; then
      local reply
      printf "%saic: bump its FROM to :%s now? [Y/n]%s " "$y" "$want" "$rst" >&2
      IFS= read -r reply || reply=""
      case "$reply" in
        n|N|no|NO)
          echo "aic:          left as-is — bump later with 'aic sync --bump-base'." >&2
          return 0
          ;;
      esac
      do_bump=1
    else
      echo "aic:          Bump its FROM to match, or re-run 'aic sync --bump-base' to do it for you." >&2
      return 0
    fi
  fi

  # Escape dots for the sed LHS; anchor on the full repo path so the swap
  # can't hit an unrelated token. Replaces every occurrence (multi-stage
  # FROMs / an ARG default all reference the same base).
  local re_repo="${repo//./\\.}" re_tag="${cur_tag//./\\.}" tmp
  tmp="$(mktemp "${df}.XXXXXX")"
  sed "s|${re_repo}:${re_tag}|${repo}:${want}|g" "$df" > "$tmp" && mv "$tmp" "$df"
  echo "aic: bumped Dockerfile.project base → ${repo}:${want} (was :${cur_tag})"
}

# aic sync. The sync_detect_*, sync_parse_args, and sync_resolve_* helpers
# set the locals of this function (bash dynamic scope), so call them only from
# here. Each helper names the locals that it sets.
cmd_sync () {
  require_in_project
  local mode="" tools="" shell="" bump_base="" docker="" docker_explicit=0 was_legacy=0
  sync_detect_legacy_identity
  sync_parse_args "$@"
  sync_resolve_docker_mode
  sync_resolve_selection
  sync_apply "$mode" "$tools" "$shell" "$docker" "$docker_explicit" "$was_legacy"
  sync_report "$mode" "$tools" "$shell" "$docker"
  check_dockerfile_project_base "$(read_aic_version)" "$bump_base"
}

# Set was_legacy=1 when the managed Compose project name is missing or is not
# this path's current one. Sync overwrites the name, so look at it first.
sync_detect_legacy_identity () {
  local old_name
  # A missing top-level name is the only legacy form. A present but tampered
  # name is simply overwritten from the trusted template; never resolve it as
  # the old basename-scoped identity.
  compose_has_project_name || was_legacy=1
  # A well-formed name that is not this path's current one (a hash taken from a
  # wrong-case spelling, see canonical_root) also moves the sessions volume.
  # Sync overwrites the name below, so look at it now; the copy itself needs a
  # container that proves ownership, never the name alone.
  if [ "$was_legacy" = "0" ] && [ -f .devcontainer/docker-compose.yml ] \
      && [ ! -L .devcontainer/docker-compose.yml ]; then
    old_name="$(sed -n 's/^name[[:space:]]*:[[:space:]]*\(aic-[a-z0-9_-]*-[0-9a-f]\{12\}\)[[:space:]]*$/\1/p' \
      .devcontainer/docker-compose.yml | head -n1)"
    if [ -n "$old_name" ] && [ "$old_name" != "$(expected_project_name)" ]; then
      was_legacy=1
    fi
  fi
}

# Parse the sync flags into mode, tools, shell, bump_base, docker, and
# docker_explicit. Die on an unknown flag.
sync_parse_args () {
  while [ $# -gt 0 ]; do
    case "$1" in
      --pull)  mode="pull" ;;
      --build) mode="build" ;;
      --with)  shift; tools="${1:-}" ;;
      --with=*) tools="${1#--with=}" ;;
      --shell) shift; shell="${1:-}" ;;
      --shell=*) shell="${1#--shell=}" ;;
      --bump-base) bump_base="1" ;;
      --docker-read) docker="ro"; docker_explicit=1 ;;
      --docker) docker="rw"; docker_explicit=1 ;;
      --no-docker) docker="none"; docker_explicit=1 ;;
      *) die "unknown sync flag: $1 (try --pull, --build, --bump-base, --docker-read, --docker, --with claude-code,codex,opencode, or --shell zsh|bash|fish)" ;;
    esac
    shift
  done
}

# Set docker to the Docker exposure mode to write: the explicit flag, else the
# current mode when the host consent for it matches, else 'none'.
sync_resolve_docker_mode () {
  # Preserve the project's Docker daemon exposure mode across syncs (the
  # compose file is regenerated wholesale) unless an explicit mode overrides it.
  # Read it from the CURRENT compose before apply_template overwrites the file.
  if [ -z "$docker" ]; then
    docker="$(read_compose_docker_mode)"
    case "$docker" in
      none|ro|rw) ;;
      invalid) err "existing Docker proxy toggles are inconsistent; resetting them to the secure 'none' mode"; docker="$DEFAULT_DOCKER" ;;
      *) docker="$DEFAULT_DOCKER" ;;
    esac
  fi

  # The repository-encoded mode is not authority by itself. Releases before
  # host-side consent existed also exposed Docker object reads in every project,
  # even when the user never asked for them. Reset any unconsented inherited
  # mode to `none` instead of reproducing it and making the next startup stop
  # for approval; an explicit flag below records fresh consent.
  if [ "$docker_explicit" = "0" ]; then
    case "$docker" in
      ro)
        if ! docker_consent_matches ro; then
          err "existing Docker read access has no matching host consent; resetting to 'none' (re-enable with 'aic sync --docker-read')"
          docker="none"
        fi
        ;;
      rw)
        if ! docker_consent_matches rw; then
          err "existing Docker read-write access has no matching host consent; resetting to 'none' (re-enable with 'aic sync --docker')"
          docker="none"
        fi
        ;;
    esac
  fi
}

# Set mode, tools, and shell: the flag values, else the values of the current
# project, else the defaults. Die on an invalid tool or shell.
sync_resolve_selection () {
  # Auto-detect: presence of .devcontainer/Dockerfile means the project was
  # initialized with --build; otherwise it's the pull-mode 2-file layout.
  if [ -z "$mode" ]; then
    if [ -f .devcontainer/Dockerfile ]; then
      mode="build"
    else
      mode="pull"
    fi
  fi

  # Preserve the existing tool selection across syncs unless overridden with
  # --with. Projects created before AIC_TOOLS existed fall back to all tools.
  if [ -z "$tools" ]; then
    tools="$(read_aic_tools)"
    [ -n "$tools" ] || tools="claude-code,codex,opencode"
  fi
  tools="$(validate_tools "$tools")"

  # Same pattern for shell. Projects created before AIC_SHELL existed get
  # the default (zsh), matching their pre-flag behavior.
  if [ -z "$shell" ]; then
    shell="$(read_aic_shell)"
    [ -n "$shell" ] || shell="$DEFAULT_SHELL"
  fi
  shell="$(validate_shell "$shell")"
}

# Write the template for mode $1, tools $2, shell $3, and Docker mode $4. Then
# record the Docker consent ($5 = 1 for an explicit flag) and, for a legacy
# project ($6 = 1), move the sessions volume.
sync_apply () {
  local mode="$1" tools="$2" shell="$3" docker="$4" docker_explicit="$5" was_legacy="$6"
  resolve_docker_socket >/dev/null || die "cannot sync aicontainer with the selected Docker context"
  status_relay_mode >/dev/null || die "fix the host status-relay marker before syncing"
  apply_template "$mode" "$TEMPLATE_DIR" ".devcontainer" "$docker"
  patch_devcontainer_json ".devcontainer/devcontainer.json" "$tools" "$shell"
  # None is also a revocation: clear stale outside-repo read/write consent even
  # when a plain sync repaired malformed toggles back to the secure default.
  if [ "$docker_explicit" != "0" ] || [ "$docker" = "none" ]; then
    set_docker_consent "$docker"
  fi
  # A legacy or stale project-name migration also changes the implicit
  # per-project sessions volume. Copy it while Docker is available; otherwise
  # first up / VS Code initialize performs the same zero-data-loss migration.
  if [ "$was_legacy" = "1" ]; then
    migrate_legacy_session_volume defer
  fi
}

# Print the sync result for mode $1, tools $2, shell $3, and Docker mode $4,
# and name the project-owned files that the next start uses.
sync_report () {
  local mode="$1" tools="$2" shell="$3" docker="$4"
  echo "aic: synced $mode-mode template → .devcontainer/ (tools: $tools, shell: $shell, docker: $docker)"
  case "$docker" in
    ro)
      echo "aic: Docker daemon READ access encoded — host Docker APIs may expose container metadata, logs, and files."
      docker_consent_matches ro || err "Docker read mode needs explicit host consent: re-run 'aic sync --docker-read'"
      ;;
    rw)
      echo "aic: Docker daemon READ-WRITE access encoded — the agent can create/build containers on the host daemon."
      docker_consent_matches rw || err "Docker write mode needs explicit host consent: re-run 'aic sync --docker'"
      ;;
  esac
  echo "aic: review with 'git diff -- .devcontainer/', then 'aic rebuild'"
  echo "aic: project-owned files (Dockerfile.project, firewall-allowlist, firewall-enable, firewall-presets, chown-paths, post-create.project.sh, docker-compose.override.yml, vscode-extensions, vscode-settings.json, shell-rc.zsh, p10k.zsh, statusline.*) are untouched"
  if [ -f .devcontainer/docker-compose.override.yml ]; then
    echo "aic: wired docker-compose.override.yml into dockerComposeFile"
  fi
  if [ -f .devcontainer/shell-rc.zsh ] || [ -f .devcontainer/p10k.zsh ]; then
    echo "aic: personal shell overlay present (shell-rc.zsh / p10k.zsh): installed root-owned on next 'aic rebuild' and sourced by zsh"
  fi
  local statusline_file
  for statusline_file in statusline.sh statusline.mjs statusline.js statusline.py; do
    if [ -f ".devcontainer/$statusline_file" ]; then
      echo "aic: personal statusline present ($statusline_file): installed root-owned on next 'aic rebuild' and wired into Claude Code"
      break
    fi
  done
  if [ -f .devcontainer/vscode-extensions ]; then
    local extcount; extcount="$(grep -cvE '^[[:space:]]*(#|$)' .devcontainer/vscode-extensions 2>/dev/null)" || extcount=0
    echo "aic: merged vscode-extensions ($extcount listed) into customizations.vscode.extensions"
  fi
  if [ -f .devcontainer/vscode-settings.json ]; then
    echo "aic: merged vscode-settings.json into customizations.vscode.settings"
  fi
  local code_file
  for code_file in $AIC_PROJECT_CODE_FILES vscode-extensions vscode-settings.json; do
    if [ -f ".devcontainer/$code_file" ]; then
      echo "aic: project-owned code runs in the container: review it, then approve it once with 'aic trust' (any edit asks again)"
      break
    fi
  done
}
