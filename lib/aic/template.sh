# shellcheck shell=bash
# =============================================================================
# lib/aic/template.sh
# =============================================================================
# Managed template: the Docker exposure toggles, the devcontainer.json patch
# (tools, shell, VS Code extensions and settings), the atomic copies,
# apply_template(), and the trusted Compose template path.
#
# aic sources this file. It only defines functions and constants.
# =============================================================================

# ---------------------------------------------------------------------------
# Docker daemon exposure (opt-in). The socket-proxy ships with object reads and
# writes disabled (only PING/VERSION remain available). `--docker-read` enables
# list/inspect APIs; `--docker` additionally enables POST/BUILD for projects
# that genuinely need testcontainers / in-container `docker compose`. The
# encoded choice survives sync, while matching consent lives outside the repo
# so a checkout cannot grant itself Docker visibility by editing Compose.
# ---------------------------------------------------------------------------
DEFAULT_DOCKER="none"

# Echo none|ro|rw for a coherent managed toggle set, "invalid" for a partial or
# malformed set, and nothing when there is no existing Compose file.
read_compose_docker_mode () {
  local f=".devcontainer/docker-compose.yml" key value reads=0 post build
  [ -f "$f" ] || return 0
  for key in CONTAINERS EVENTS IMAGES INFO NETWORKS VOLUMES; do
    value="$(sed -n "s/^[[:space:]]*${key}:[[:space:]]*\([01]\)[[:space:]]*\$/\1/p" "$f")"
    case "$value" in
      0) ;;
      1) reads=$((reads + 1)) ;;
      *) echo invalid; return 0 ;;
    esac
  done
  post="$(sed -n 's/^[[:space:]]*POST:[[:space:]]*\([01]\)[[:space:]]*$/\1/p' "$f")"
  build="$(sed -n 's/^[[:space:]]*BUILD:[[:space:]]*\([01]\)[[:space:]]*$/\1/p' "$f")"
  [ "$post" = "$build" ] || { echo invalid; return 0; }
  case "$reads:$post" in
    0:0) echo none ;;
    6:0) echo ro ;;
    6:1) echo rw ;;
    *)   echo invalid ;;
  esac
}

# Build the injection block for project-owned VS Code extensions. Reads the
# given file (if present): skips blank/# lines, trims surrounding whitespace,
# validates each remaining line against the publisher.extension id grammar and
# warns+skips anything else (so a stray line can't smuggle arbitrary JSON into
# devcontainer.json), dedups, and emits one leading-comma line per id. Leading
# commas keep the result valid JSON no matter how the template array ends.
# Echoes the (possibly empty) block; warnings go to stderr.
build_vscode_ext_block () {
  local file="$1" line id block="" seen=","
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    id="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$id" in ''|\#*) continue ;; esac
    if ! printf '%s' "$id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9._-]+$'; then
      printf 'aic: ignoring invalid vscode-extensions entry: %s\n' "$id" >&2
      continue
    fi
    case "$seen" in *",$id,"*) continue ;; esac
    seen="$seen$id,"
    block="$block        ,\"$id\"
"
  done < "$file"
  printf '%s' "$block"
}

# Build the injection block for project-owned VS Code settings. The input is
# strict JSON (not JSONC), must be a non-array object, and is parsed then
# serialized by lib/vscode-settings.mjs, which also drops the keys that the
# template manages. Never splice user-controlled text between braces: a
# malformed object could otherwise escape customizations.vscode.settings and
# inject host-facing top-level devcontainer properties.
build_vscode_settings_block () {
  local file="$1" output
  [ -f "$file" ] || return 0
  if ! output="$(aic_helper vscode-settings \
      "$file" "$TEMPLATE_DIR/devcontainer.json")"; then
    printf 'aic: ignoring vscode-settings.json (must be a strict JSON object)\n' >&2
    return 0
  fi
  printf '%s' "$output"
}

patch_devcontainer_json () {
  # Patch the freshly-copied devcontainer.json:
  #   1. Inject "AIC_TOOLS" and "AIC_SHELL" inside containerEnv.
  #   2. Drop "anthropic.claude-code" extension when claude-code not selected.
  #   3. Drop "openai.chatgpt" extension when codex not selected.
  #      (and "sst-dev.opencode" when opencode not selected.)
  #   4. Patch terminal.integrated.defaultProfile.linux to the chosen shell.
  #   5. Patch terminal.integrated.fontFamily — MesloLGS NF for zsh (p10k icons),
  #      plain monospace for bash/fish (no nerd font required on the host).
  #   6. Wire a project-owned docker-compose.override.yml into dockerComposeFile
  #      when one exists, so per-project compose tweaks (containerEnv-equivalent
  #      `environment:`, extra_hosts, build.dockerfile) survive `aic sync`. The
  #      override file itself is never copied or overwritten by apply_template;
  #      this only re-applies the reference, which the template ships without.
  #   7. Rewrite "name" to "<project folder>-aicontainer" so each project shows a
  #      distinct label in VS Code's remote indicator. Re-derived from $PWD every
  #      run (like AIC_TOOLS/AIC_SHELL), so it's recomputed on each init/sync and
  #      the template can keep the bare "aicontainer" placeholder.
  #   8. Merge project-owned .devcontainer/vscode-extensions (one extension id
  #      per line) into customizations.vscode.extensions at the
  #      "// aic:vscode-extensions" marker.
  #   9. Merge project-owned .devcontainer/vscode-settings.json (a JSON object)
  #      into customizations.vscode.settings at the "// aic:vscode-settings"
  #      marker.
  #      Both (8) and (9) are opt-in by file presence, never copied/overwritten
  #      by apply_template, and RO inside the container — same contract as
  #      firewall-allowlist / chown-paths. Injected blocks are leading-comma
  #      so they stay valid JSON regardless of how the template array/object
  #      ends; the source files are read fresh each run from the pristine
  #      template, so re-injection is idempotent across syncs.
  # Operates line-wise so JSONC comments don't trip us up.
  local file="$1" tools="$2" shell="$3"
  local hc=0 hx=0 hoc=0 ov=0 tmp font dir pname cname
  local ext_block="" settings_block=""
  case ",$tools," in *,claude-code,*) hc=1 ;; esac
  case ",$tools," in *,codex,*)       hx=1 ;; esac
  case ",$tools," in *,opencode,*)    hoc=1 ;; esac

  dir="$(dirname "$file")"
  [ -f "$dir/docker-compose.override.yml" ] && ov=1
  ext_block="$(build_vscode_ext_block "$dir/vscode-extensions")"
  settings_block="$(build_vscode_settings_block "$dir/vscode-settings.json")"

  # Project label from the cwd (project root for both init and sync). JSON-escape
  # backslashes and double-quotes so an odd folder name still yields valid JSON.
  pname="$(basename "$PWD")"
  pname="${pname//\\/\\\\}"
  pname="${pname//\"/\\\"}"
  cname="$pname-aicontainer"

  case "$shell" in
    zsh) font="'MesloLGS NF', monospace" ;;
    *)   font="monospace" ;;
  esac

  tmp="$(mktemp "${file}.XXXXXX")"
  AIC_DEVCONTAINER_NAME="$cname" \
  AIC_VSCODE_EXT_BLOCK="$ext_block" \
  AIC_VSCODE_SETTINGS_BLOCK="$settings_block" \
  awk -v tools="$tools" -v shell="$shell" -v font="$font" -v hc="$hc" -v hx="$hx" -v hoc="$hoc" -v ov="$ov" '
    {
      # Rewrite the top-level "name" to the per-project label. Read from ENVIRON
      # (not -v) so awk does not re-interpret backslashes in the folder name.
      if ($0 ~ /^[[:space:]]*"name"[[:space:]]*:/) {
        print "  \"name\": \"" ENVIRON["AIC_DEVCONTAINER_NAME"] "\","
        next
      }

      # Merge project-owned extensions / settings just before their markers.
      # The blocks are built leading-comma (ENVIRON, so backslashes/quotes in
      # settings values survive) and empty when the source file is absent.
      if ($0 ~ /aic:vscode-extensions/) {
        if (ENVIRON["AIC_VSCODE_EXT_BLOCK"] != "") printf "%s\n", ENVIRON["AIC_VSCODE_EXT_BLOCK"]
        print
        next
      }
      if ($0 ~ /aic:vscode-settings/) {
        if (ENVIRON["AIC_VSCODE_SETTINGS_BLOCK"] != "") printf "%s\n", ENVIRON["AIC_VSCODE_SETTINGS_BLOCK"]
        print
        next
      }

      if ($0 ~ /^[[:space:]]*"anthropic\.claude-code",[[:space:]]*$/ && hc == 0) next
      if ($0 ~ /^[[:space:]]*"openai\.chatgpt",[[:space:]]*$/        && hx == 0) next
      if ($0 ~ /^[[:space:]]*"sst-dev\.opencode",[[:space:]]*$/      && hoc == 0) next

      # Per-shell terminal defaults (only act on the relevant lines so
      # generic "zsh" tokens elsewhere in the file are untouched).
      if ($0 ~ /"terminal\.integrated\.defaultProfile\.linux"/) {
        sub(/"zsh"/, "\"" shell "\"")
      }
      if ($0 ~ /"terminal\.integrated\.fontFamily"/) {
        sub(/:[[:space:]]*"[^"]*"/, ": \"" font "\"")
      }

      # Append the override to the dockerComposeFile array. Docker Compose
      # merges files left-to-right, so the override wins. Guarded so a file
      # that already lists it (or a hand-edited multi-entry array) is a no-op.
      if (ov == 1 && $0 ~ /"dockerComposeFile"/ && $0 !~ /docker-compose\.override\.yml/) {
        sub(/\]/, ", \"docker-compose.override.yml\"]")
      }

      print
      if ($0 ~ /^[[:space:]]*"containerEnv":[[:space:]]*\{[[:space:]]*$/) {
        print "    \"AIC_TOOLS\": \"" tools "\","
        print "    \"AIC_SHELL\": \"" shell "\","
      }
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Apply all socket-proxy read/write toggles in the freshly-copied Compose file.
# none=ping/version only, ro=list/inspect, rw=list/inspect + POST/BUILD.
apply_docker_mode () {
  local file="$1" docker="$2" read write tmp
  [ -f "$file" ] || return 0
  case "$docker" in
    none) read=0; write=0 ;;
    ro)   read=1; write=0 ;;
    rw)   read=1; write=1 ;;
    *)    die "internal error: unknown Docker exposure mode '$docker'" ;;
  esac
  tmp="$(mktemp "${file}.XXXXXX")"
  sed -E "s/^([[:space:]]*)(CONTAINERS|EVENTS|IMAGES|INFO|NETWORKS|VOLUMES):[[:space:]]*[01][[:space:]]*\$/\1\2: ${read}/; \
          s/^([[:space:]]*)POST:[[:space:]]*[01][[:space:]]*\$/\1POST: ${write}/; \
          s/^([[:space:]]*)BUILD:[[:space:]]*[01][[:space:]]*\$/\1BUILD: ${write}/" \
    "$file" > "$tmp" && mv "$tmp" "$file"
}

# Copy a managed file through a sibling temporary and rename it into place.
# The final rename replaces a destination symlink itself instead of following
# it; validate_devcontainer_paths rejects such links first as a clearer error.
atomic_copy_file () {
  local src="$1" dst="$2" tmp
  [ -f "$src" ] && [ ! -L "$src" ] || die "managed template file is missing or unsafe: $src"
  tmp="$(mktemp "$(dirname "$dst")/.aic-$(basename "$dst").XXXXXX")"
  if cp -p "$src" "$tmp" && mv -f "$tmp" "$dst"; then
    return 0
  fi
  rm -f "$tmp"
  die "could not install managed file: $dst"
}

# Stage the managed hook files before replacing the hooks directory, so a
# partial copy can never become the live tree. Only the files in
# AIC_HOOK_FILES are copied; anything else in the template directory stays
# out. Symlinks are forbidden in both source and destination because hooks
# execute security-sensitive host/container logic. The directory is 0755, the
# mode a normal checkout or npm install gives template/hooks, so the trust
# hash of an existing project does not change.
atomic_copy_hooks () {
  local src="$1" dst="$2" parent tmp name
  [ -d "$src" ] && [ ! -L "$src" ] || die "managed hooks template is missing or unsafe: $src"
  for name in $AIC_HOOK_FILES; do
    [ -f "$src/$name" ] && [ ! -L "$src/$name" ] \
      || die "managed hook template is missing or unsafe: $src/$name"
  done
  parent="$(dirname "$dst")"
  tmp="$(mktemp -d "$parent/.aic-hooks.XXXXXX")"
  for name in $AIC_HOOK_FILES; do
    if ! cp -p "$src/$name" "$tmp/$name"; then
      rm -rf "$tmp"
      die "could not stage managed hooks"
    fi
  done
  if ! chmod 0755 "$tmp"; then
    rm -rf "$tmp"
    die "could not stage managed hooks"
  fi
  rm -rf "$dst"
  if ! mv "$tmp" "$dst"; then
    rm -rf "$tmp"
    die "could not install managed hooks"
  fi
}

# Verify the managed Compose name line. The template holds the exact line
# AIC_COMPOSE_NAME_LINE, and aic copies it unchanged: the path-unique value is
# in the gitignored .devcontainer/.env, not in this tracked file. So a
# teammate's sync at another path does not change the committed file. A
# template with any other name line is an incomplete or modified install.
check_project_name_line () {
  local file="$1"
  [ "$(grep -cE '^name[[:space:]]*:' "$file")" = "1" ] \
    && grep -Fqx -- "$AIC_COMPOSE_NAME_LINE" "$file" \
    || die "managed compose template is missing the top-level line '$AIC_COMPOSE_NAME_LINE'"
}

# Verify the managed Compose identity anchor. Its value is interpolated from
# the gitignored host runtime file instead of rewriting tracked Compose on each
# machine; that keeps mixed macOS/Linux teams free of UID-only diffs.
apply_runtime_user () {
  local file="$1"
  grep -Fqx 'x-aic-runtime-user: &aic-runtime-user "${AIC_RUNTIME_USER:-1000:1000}"' "$file" \
    || die "managed compose template is missing x-aic-runtime-user interpolation"
}

# Copy template files into .devcontainer/, picking the right compose variant
# for $mode (pull or build) and only the files that mode needs. Idempotent:
# overwrites any existing target files; safe to call from init or sync.
apply_template () {
  local mode="$1" src="$2" dst="$3" docker="${4:-$DEFAULT_DOCKER}" name
  [ -d "$src" ] || die "template not found at $src (set AIC_HOME or reinstall aic)"
  validate_devcontainer_paths optional
  ensure_git_control_paths lenient
  mkdir -p "$dst"

  atomic_copy_file "$src/devcontainer.json" "$dst/devcontainer.json"
  # Copied in both modes: an in-repo guide to which .devcontainer/ files are
  # aic-managed (overwritten on sync) vs project-owned (survive). Steers humans
  # and AI agents away from hand-editing devcontainer.json. Itself aic-managed.
  atomic_copy_file "$src/README.md" "$dst/README.md"
  # The template ships it without the dot: npm 12 leaves a .gitignore out of
  # the package even when package.json "files" names it.
  atomic_copy_file "$src/gitignore" "$dst/.gitignore"
  case "$mode" in
    pull)
      atomic_copy_file "$src/docker-compose.pull.yml" "$dst/docker-compose.yml"
      # Pin the image tag to this aic's version so the CLI and the container
      # FS layout (hooks, sudoers, helper scripts) can't drift apart. Template
      # ships `:latest` as the canonical placeholder; we rewrite at copy time.
      local ver tmp
      ver="$(read_aic_version)"
      tmp="$(mktemp "$dst/docker-compose.yml.XXXXXX")"
      sed "s|ghcr.io/stefanoginella/aicontainer:latest|ghcr.io/stefanoginella/aicontainer:v${ver}|g" \
        "$dst/docker-compose.yml" > "$tmp" && mv "$tmp" "$dst/docker-compose.yml"
      # Pull mode must remove every managed build-mode artifact. Leaving the
      # old Dockerfile behind makes the next plain `aic sync` auto-detect build
      # mode and silently flip the project back.
      rm -f "$dst/Dockerfile" "$dst/post-create.py" "$dst/aic-firewall" \
        "$dst/aic-chown-volumes" "$dst/aic-lock-user-config" \
        "$dst/aic-lock-gitconfig" "$dst/.zshrc"
      for name in $AIC_POST_CREATE_MODULES; do
        rm -f "$dst/$name"
      done
      rm -rf "$dst/hooks"
      ;;
    build)
      atomic_copy_file "$src/docker-compose.build.yml" "$dst/docker-compose.yml"
      atomic_copy_file "$src/Dockerfile"         "$dst/Dockerfile"
      atomic_copy_file "$src/post-create.py"     "$dst/post-create.py"
      for name in $AIC_POST_CREATE_MODULES; do
        atomic_copy_file "$src/$name" "$dst/$name"
      done
      atomic_copy_file "$src/aic-firewall"       "$dst/aic-firewall"
      atomic_copy_file "$src/aic-chown-volumes"  "$dst/aic-chown-volumes"
      atomic_copy_file "$src/aic-lock-user-config" "$dst/aic-lock-user-config"
      atomic_copy_file "$src/.zshrc"             "$dst/.zshrc"
      atomic_copy_hooks "$src/hooks"              "$dst/hooks"
      ;;
    *) die "internal error: unknown mode '$mode'" ;;
  esac
  check_project_name_line "$dst/docker-compose.yml"
  apply_runtime_user "$dst/docker-compose.yml"
  # Apply the project's Docker daemon exposure mode to the copied compose file.
  apply_docker_mode "$dst/docker-compose.yml" "$docker"
  # Direct VS Code starts do not inherit exports from the host initialize hook,
  # so leave Compose a tiny gitignored file containing the selected local
  # Docker context's socket path and the project name. `aic initialize`
  # refreshes it on every start.
  write_runtime_environment_file
}

trusted_compose_template () {
  if [ -f .devcontainer/Dockerfile ]; then
    printf '%s/docker-compose.build.yml\n' "$TEMPLATE_DIR"
  else
    printf '%s/docker-compose.pull.yml\n' "$TEMPLATE_DIR"
  fi
}
