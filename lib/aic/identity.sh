# shellcheck shell=bash
# =============================================================================
# lib/aic/identity.sh
# =============================================================================
# Project identity: the path-unique Compose project name and the canonical path
# spelling. Also the .devcontainer/ control-path checks and the read-only .git
# control paths.
#
# aic sources this file. It only defines functions and constants.
# =============================================================================

# Historical project name used before generated Compose files gained an
# explicit, path-unique top-level name. Keep it available so commands can still
# target projects that have not been synced yet.
legacy_project_name () {
  local base
  base="$(basename -- "$PWD")"
  base="$(printf '%s' "$base" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -dc 'a-z0-9_-')"
  printf '%s_devcontainer\n' "$base"
}

# Physical path of the current directory, spelled the way the filesystem stores
# it. Bash's builtin `pwd -P` resolves symlinks but keeps the letter case the
# user typed, and macOS volumes are case-insensitive by default. Node and the
# Dev Containers CLI take the stored spelling from getcwd(), as does VS Code, so
# the identity hash and every devcontainer.local_folder comparison must too:
# /bin/pwd asks the kernel. Never call the builtin `pwd -P` for identity; a
# test fails on it. Only a host with no /bin/pwd falls back to the builtin.
canonical_root () {
  if [ -x /bin/pwd ]; then /bin/pwd -P; else pwd -P; fi
}

# Deterministic Compose project name for newly generated configuration. The
# readable basename is suffixed with a hash of the canonical absolute project
# path, so two checkouts with the same basename never share containers or
# per-project session volumes.
expected_project_name () {
  local base root hash
  root="$(canonical_root)"
  base="$(expected_project_label)"
  hash="$(node -e 'process.stdout.write(require("crypto").createHash("sha256").update(process.argv[1]).digest("hex").slice(0,12))' "$root")" \
    || die "Node.js 18+ is required to compute the project identity"
  printf 'aic-%s-%s\n' "$base" "$hash"
}

# Human-readable, dotenv-safe half of the project identity. This is deliberately
# path-free: the host status relay may expose it to a local dashboard, while the
# hash in expected_project_name() remains the collision-resistant identifier.
expected_project_label () {
  local base
  base="$(basename -- "$(canonical_root)")"
  # toLowerCase().replace(/[^a-z0-9_-]/g, '') — strip, don't substitute. Keep
  # the readable portion bounded so Docker object names remain manageable.
  base="$(printf '%s' "$base" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -dc 'a-z0-9_-')"
  base="${base:0:32}"
  [ -n "$base" ] || base="project"
  printf '%s\n' "$base"
}

# The one top-level name line of the managed Compose file, byte for byte. The
# committed file holds no path-specific value: Compose interpolates the name
# from AIC_PROJECT_NAME, which aic exports itself and writes into the
# gitignored .devcontainer/.env (write_runtime_environment_file). A missing
# value fails, never falls back. Both templates must contain this exact line.
# shellcheck disable=SC2016 # the line is literal Compose text, not shell
AIC_COMPOSE_NAME_LINE='name: ${AIC_PROJECT_NAME:?run aic up or aic sync}'

# Resolve the project name of the current managed Compose file. Never take a
# name from the repository: return expected_project_name() only when the file
# has the exact managed line, or the exact earlier literal `name: <expected>`
# that aic wrote before the line existed ('aic sync' migrates it). A
# repository-controlled `name:` must never make `aic down` / `destroy` target
# somebody else's stack. Old files without a top-level name keep the legacy
# resolution until sync. Every other form fails.
project_name () {
  local expected file=.devcontainer/docker-compose.yml
  expected="$(expected_project_name)"
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    if ! grep -qE '^name[[:space:]]*:' "$file"; then
      legacy_project_name
      return 0
    fi
    [ "$(grep -cE '^name[[:space:]]*:' "$file")" = "1" ] || \
      die "managed Compose file has multiple top-level names — run 'aic sync'"
    if grep -Fqx -- "$AIC_COMPOSE_NAME_LINE" "$file" \
        || grep -Fqx -- "name: $expected" "$file"; then
      printf '%s\n' "$expected"
      return 0
    fi
    die "managed Compose name is missing, malformed, or belongs to another path — run 'aic sync'"
  fi
  legacy_project_name
}

# Print why the managed Compose file is not in the managed name form, or
# nothing. The gate (validate_project_security) and doctor run it, so validate,
# initialize, and every start require the form:
#   - the first line that is not blank or a comment is a plain key at
#     column 0, so the root mapping starts at column 0 and every top-level
#     key is at column 0;
#   - exactly one line at column 0 starts with `name:` (spaces before the
#     colon count too), and it equals AIC_COMPOSE_NAME_LINE;
#   - every other line at column 0 is blank, a comment, or a plain key.
# The first rule stops an indented root mapping, where the real name key is
# indented and the fixed line hides inside a multi-line quoted scalar. With
# the root at column 0, a real name key is at column 0 too, so the hidden copy
# makes the count go above one. The third rule closes the YAML spellings that
# a line check cannot read as the name: a quoted or escaped key, an explicit
# `?` key, a merge key, a flow mapping, a tag, or a second document (`---`).
# The resolved name check in lib/validate.mjs cannot see these, because with
# AIC_PROJECT_NAME set, `${AIC_PROJECT_NAME:-x}` resolves to the same name.
compose_name_line_problem () {
  local file=.devcontainer/docker-compose.yml first
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  # sed stops at the first line itself. A `grep | head` pipe here wrote
  # "grep: write error: Broken pipe" where SIGPIPE is ignored (CI runners).
  first="$(sed -n -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' -e p -e q "$file")"
  if ! printf '%s\n' "$first" | grep -qE '^[A-Za-z][A-Za-z0-9_-]*:'; then
    printf '%s\n' ".devcontainer/docker-compose.yml must start its top-level mapping with a plain key at column 0; run aic sync"
  elif [ "$(grep -cE '^name[[:space:]]*:' "$file")" != "1" ] \
      || ! grep -Fqx -- "$AIC_COMPOSE_NAME_LINE" "$file"; then
    printf '%s\n' ".devcontainer/docker-compose.yml must have exactly one top-level name line, '$AIC_COMPOSE_NAME_LINE'; run aic sync"
  elif grep -qvE '^([[:space:]]|#|$|[A-Za-z][A-Za-z0-9_-]*:)' "$file"; then
    printf '%s\n' ".devcontainer/docker-compose.yml has top-level YAML that is not a plain key; run aic sync"
  fi
}

# True when the Compose file declares any top-level project name. A missing
# name identifies a pre-migration project; a present-but-wrong name is handled
# by project_name() and must never fall back to a basename that could target a
# different checkout.
compose_has_project_name () {
  [ -f .devcontainer/docker-compose.yml ] &&
    grep -qE '^name[[:space:]]*:' .devcontainer/docker-compose.yml
}

# Run Docker Compose on aic's installed trusted template ($TEMPLATE_DIR). The
# caller passes -p. The template's name line still needs AIC_PROJECT_NAME: -p
# sets the project, but Compose interpolates the name first and fails when the
# variable is missing. The value comes from aic, never from the environment.
trusted_template_compose () {
  local name
  name="$(expected_project_name)" || return 1
  AIC_PROJECT_NAME="$name" docker compose "$@"
}

# The Dev Containers CLI does not always use the Compose `name:` validated
# above. It takes the first non-empty name from:
#   1. COMPOSE_PROJECT_NAME in its own environment;
#   2. the first `COMPOSE_PROJECT_NAME=` line of the repository-root .env
#      (<workspace>/.env, which app stacks often commit);
#   3. the Compose `name:`.
# Sources 1 and 2 would move this checkout into another Compose project: the
# containers and session volumes of another checkout, or the user's own app
# stack. aic's own CLI calls pin the managed name (source 1), so the root .env
# never takes effect there. They also pin AIC_PROJECT_NAME, the value of the
# managed name line, so an inherited value cannot win over .devcontainer/.env.
pin_compose_project_name () {
  COMPOSE_PROJECT_NAME="$(project_name)" || exit 1
  AIC_PROJECT_NAME="$(expected_project_name)" || exit 1
  export COMPOSE_PROJECT_NAME AIC_PROJECT_NAME
}

# Return 1, with an actionable message, when a direct Dev Containers start
# (the generated VS Code initializer cannot pin the name for its parent) would
# not use this project's managed name. composeNameConflict() in
# lib/project-identity.mjs mirrors the CLI's lookup; it prints only the source
# that conflicts. A helper that cannot run fails the check with its own message.
# The helper sees the AIC_PROJECT_NAME that this process inherited (saved at
# the top of aic), not the value that aic exports itself, because a direct
# start has only the inherited one.
# shellcheck disable=SC2154 # aic_inherited_project_name{,_set} are set in aic
check_devcontainer_project_name () {
  local expected managed conflict
  expected="$(project_name)" || return 1
  managed="$(expected_project_name)" || return 1
  if ! conflict="$(
      if [ "$aic_inherited_project_name_set" = 1 ]; then
        AIC_PROJECT_NAME="$aic_inherited_project_name"; export AIC_PROJECT_NAME
      else
        unset AIC_PROJECT_NAME
      fi
      aic_helper compose-name-conflict "$expected" "$managed")"; then
    err "could not check COMPOSE_PROJECT_NAME for a direct Dev Containers start"
    return 1
  fi
  case "$conflict" in
    "") return 0 ;;
    environment)
      err "COMPOSE_PROJECT_NAME in the environment would replace this project's Compose name ($expected) — unset it, or start with 'aic up'"
      ;;
    managed-environment)
      err "AIC_PROJECT_NAME in the environment would replace this project's Compose name ($managed) — unset it, or start with 'aic up'"
      ;;
    env-files)
      err "COMPOSE_ENV_FILES in the environment would make Compose skip .devcontainer/.env, which holds this project's Compose name — unset it"
      ;;
    env-disabled)
      err "COMPOSE_DISABLE_ENV_FILE in the environment would make Compose skip .devcontainer/.env, which holds this project's Compose name — unset it"
      ;;
    dotenv)
      err "the repository-root .env sets COMPOSE_PROJECT_NAME, which would replace this project's Compose name ($expected) — remove that line (an app stack can set a top-level 'name:' in its own Compose file), or start with 'aic up'"
      ;;
    *)
      err "the repository-root .env is not a readable regular file, and the Dev Containers CLI reads it to choose the Compose project name — fix or remove it, or start with 'aic up'"
      ;;
  esac
  return 1
}

# Paths under .devcontainer are either aic-managed outputs or project-owned
# control inputs. Never follow a repository-provided symlink at this boundary:
# `aic init --force` / `aic sync` run as the host user, so following one could
# overwrite or read an arbitrary host file outside the repository.
#
# AIC_POST_CREATE_MODULES is the only list in aic of the modules that
# post-create.py imports. They are managed build-mode files, flat in
# .devcontainer/, and the image installs them as the aic_post_create package.
# The control-path checks, apply_template(), and the build-file provenance
# check read this list. It must equal the COPY list in template/Dockerfile and
# the post_create_*.py files in template/: tests/test-aic-post-create-package.py
# checks this.
AIC_POST_CREATE_MODULES="post_create_common.py post_create_claude_reset.py post_create_tools.py post_create_seeds.py post_create_auth_logins.py post_create_auth_sync.py post_create_container.py post_create_git.py post_create_overlays.py post_create_main.py"
# AIC_HOOK_FILES is the only list in aic of the managed hook files. aic copies
# only these from template/hooks/, so a stray file there (a __pycache__ from a
# test run in a git checkout) never reaches a project. In build mode,
# .devcontainer/hooks/ must hold exactly these files. It must equal the hooks
# COPY list in template/Dockerfile and the files in template/hooks/:
# tests/test-aic-hook-files.py checks this. template.sh and validation.sh read it.
# shellcheck disable=SC2034
AIC_HOOK_FILES="agent-status.py claude-settings.json opencode-guardrail.js pre-tool-use.sh"
AIC_CONTROL_FILES="devcontainer.json README.md docker-compose.yml .env .gitignore Dockerfile post-create.py $AIC_POST_CREATE_MODULES aic-firewall aic-chown-volumes aic-lock-user-config .zshrc Dockerfile.project firewall-allowlist firewall-enable firewall-presets chown-paths post-create.project.sh docker-compose.override.yml vscode-extensions vscode-settings.json shell-rc.zsh p10k.zsh statusline.sh statusline.mjs statusline.js statusline.py"

validate_devcontainer_paths () {
  local require_dir="${1:-optional}" path name linked
  if [ -L .devcontainer ]; then
    die ".devcontainer must be a real directory, not a symlink"
  fi
  if [ -e .devcontainer ] && [ ! -d .devcontainer ]; then
    die ".devcontainer exists but is not a directory"
  fi
  if [ "$require_dir" = "required" ] && [ ! -d .devcontainer ]; then
    die "no .devcontainer/ here — run 'aic init' first"
  fi
  [ -d .devcontainer ] || return 0

  for name in $AIC_CONTROL_FILES; do
    path=".devcontainer/$name"
    if [ -L "$path" ]; then
      die "$path must be a regular file, not a symlink"
    fi
    if [ -e "$path" ] && [ ! -f "$path" ]; then
      die "$path exists but is not a regular file"
    fi
  done

  path=".devcontainer/hooks"
  if [ -L "$path" ]; then
    die "$path must be a real directory, not a symlink"
  fi
  if [ -e "$path" ] && [ ! -d "$path" ]; then
    die "$path exists but is not a directory"
  fi
  if [ -d "$path" ]; then
    linked="$(find "$path" -type l -print -quit 2>/dev/null)"
    [ -z "$linked" ] || die "$linked is a symlink inside the managed hooks directory"
  fi
}

require_in_project () {
  validate_devcontainer_paths required
  [ -f .devcontainer/devcontainer.json ] || die "no .devcontainer/devcontainer.json here — run 'aic init' first"
}

# The devcontainer mounts the checkout read-write at /workspace and these Git
# control paths over it. Host Git runs code that they name (core.fsmonitor,
# filters, hooks), so the agent must not change them:
#   .git                  bound onto itself; a mount point cannot be renamed or
#                         removed, so the agent cannot swap in another .git
#   .git/config           read-only
#   .git/config.worktree  read-only; Git reads it as config when
#                         extensions.worktreeConfig is set (sparse-checkout)
#   .git/commondir        read-only "."; Git loads config, hooks, refs, and
#                         objects from the directory that this file names
#   .git/hooks            read-only
# Docker resolves each bind source on the host. A symlink here would mount a
# host file from outside the checkout, and a missing source becomes a
# root-owned directory. Print one problem per line. "--with-missing" also
# prints the paths that ensure_git_control_paths() creates.
git_control_path_problems () {
  local with_missing="${1:-}" path bytes
  if [ -L .git ]; then
    printf '%s\n' ".git must be a real directory, not a symlink"
    return 0
  fi
  if [ ! -e .git ]; then
    printf '%s\n' "there is no .git directory here — run aic from the repository root, or 'git init' a new project (aicontainer mounts its Git control files read-only)"
    return 0
  fi
  if [ ! -d .git ]; then
    printf '%s\n' ".git is not a directory — aicontainer needs a conventional checkout at the repository root (linked worktrees and submodule checkouts are not supported)"
    return 0
  fi
  for path in .git/config .git/config.worktree .git/commondir; do
    if [ -L "$path" ]; then
      printf '%s must be a regular file, not a symlink\n' "$path"
    elif [ -e "$path" ] && [ ! -f "$path" ]; then
      printf '%s exists but is not a regular file\n' "$path"
    elif [ ! -e "$path" ] && [ "$path" = .git/config ]; then
      printf '%s\n' ".git/config is missing — this is not a complete Git repository"
    elif [ ! -e "$path" ] && [ "$with_missing" = --with-missing ]; then
      printf '%s is missing — aic sync, aic up, and the VS Code initializer create it\n' "$path"
    fi
  done
  path=.git/hooks
  if [ -L "$path" ]; then
    printf '%s must be a real directory, not a symlink\n' "$path"
  elif [ -e "$path" ] && [ ! -d "$path" ]; then
    printf '%s exists but is not a directory\n' "$path"
  elif [ ! -e "$path" ] && [ "$with_missing" = --with-missing ]; then
    printf '%s is missing — aic sync, aic up, and the VS Code initializer create it\n' "$path"
  fi
  # A main checkout never has commondir; aic writes "." so that Git keeps
  # using this .git. Any other value is planted, not repaired: host Git
  # already reads config and hooks from the directory it names.
  path=.git/commondir
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    bytes="$(wc -c < "$path" | tr -d '[:space:]')"
    case "$bytes" in 1|2) ;; *) bytes=bad ;; esac
    if [ "$bytes" = bad ] || [ "$(cat "$path")" != "." ]; then
      printf '%s\n' ".git/commondir must contain only '.' — Git takes this checkout's config and hooks from the directory it names; inspect it before you run Git here, then remove it"
    fi
  fi
}

# Print the physical path of the absolute path $1. Follow every symlink, also
# in a missing tail, and read nothing but link targets. Return 1 after 40
# links or when a directory cannot be entered. $2 counts the links so far.
git_hooks_resolve () {
  local path="$1" links="${2:-0}" dir link
  while :; do
    if [ -d "$path" ]; then
      (cd -P -- "$path" 2>/dev/null && canonical_root)
      return
    fi
    if [ -L "$path" ]; then
      links=$((links + 1))
      [ "$links" -le 40 ] || return 1
      link="$(readlink -- "$path")" || return 1
      case "$link" in /*) path="$link" ;; *) path="$(dirname -- "$path")/$link" ;; esac
      continue
    fi
    dir="$(git_hooks_resolve "$(dirname -- "$path")" "$((links + 1))")" || return 1
    printf '%s/%s\n' "${dir%/}" "$(basename -- "$path")"
    return 0
  done
}

# The container mounts .git/hooks and .git/config read-only, but host Git also
# runs hooks from core.hooksPath, through hook symlinks, and the programs that
# core.fsmonitor and core.sshCommand name. When one of these lives in the
# worktree, the agent can change it, and the next host commit or push runs
# agent code. Print one problem per line. This checks only where these files
# live, never what they do, and it never runs a hook. Call it only when
# git_control_path_problems() is empty: a planted .git/commondir would make
# Git read the config of another directory.
git_hooks_problems () {
  local root dir resolved="" hook target key value word rc
  command -v git >/dev/null 2>&1 || return 0
  root="$(canonical_root)"
  rc=0
  value="$(git --git-dir=.git config --type=path --get core.hooksPath 2>/dev/null)" || rc=$?
  case "$rc" in
    0) case "$value" in /*) dir="$value" ;; *) dir="$root/$value" ;; esac ;;
    1) dir="$root/.git/hooks" ;;
    *) printf '%s\n' "could not read core.hooksPath with Git"; dir="" ;;
  esac
  if [ -n "$dir" ] && ! resolved="$(git_hooks_resolve "$dir")"; then
    printf 'could not resolve the Git hooks directory %s\n' "$dir"
  elif [ -n "$dir" ] && [ "$resolved" != "$root/.git/hooks" ] \
      && case "$resolved/" in "$root/"*) true ;; *) false ;; esac; then
    printf 'core.hooksPath is in the worktree (%s): the agent can change the hooks that host Git runs\n' "$value"
  elif [ -d "$resolved" ] && { [ ! -r "$resolved" ] || [ ! -x "$resolved" ]; }; then
    printf 'could not read the Git hooks directory %s\n' "$resolved"
  elif [ -d "$resolved" ]; then
    for hook in "$resolved"/*; do
      [ -L "$hook" ] || continue
      case "$hook" in *.sample) continue ;; esac
      if ! target="$(git_hooks_resolve "$hook")"; then
        printf 'could not resolve the Git hook symlink %s\n' "${hook#"$root/"}"
      else
        case "$target/" in
          "$root/.git/hooks/"*) ;;
          "$root/"*) printf 'the Git hook %s is a symlink into the worktree: the agent can change it\n' "${hook#"$root/"}" ;;
        esac
      fi
    done
  fi
  for key in core.fsmonitor core.sshCommand; do
    rc=0
    value="$(git --git-dir=.git config --get "$key" 2>/dev/null)" || rc=$?
    case "$rc" in
      0) ;;
      1) continue ;;
      *) printf 'could not read %s with Git\n' "$key"; continue ;;
    esac
    if [ "$key" = core.fsmonitor ]; then
      case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
        true|false|yes|no|on|off|1|0|'') continue ;;
      esac
    fi
    # Only the first word: aic checks where the program is, not what it does.
    word="${value#"${value%%[![:space:]]*}"}"
    word="${word%%[[:space:]]*}"
    case "$word" in \~/*) word="$HOME/${word#\~/}" ;; esac
    case "$word" in
      /*) ;;
      */*) printf '%s runs a relative path (%s): host Git runs it from the worktree\n' "$key" "$word"; continue ;;
      *) continue ;;
    esac
    if ! target="$(git_hooks_resolve "$word")"; then
      printf 'could not resolve the %s program %s\n' "$key" "$word"
    else
      case "$target/" in
        "$root/"*) printf '%s runs a program in the worktree (%s): the agent can change it\n' "$key" "$word" ;;
      esac
    fi
  done
  return 0
}

# aic up and aic rebuild: print the git_hooks_problems() lines as one warning.
# It never blocks a start.
warn_git_hooks () {
  local problems
  problems="$(git_hooks_problems | tr '\n' '\t')"
  problems="${problems%$'\t'}"
  [ -z "$problems" ] \
    || err "warning: host Git can run code that the agent changes: ${problems//$'\t'/; } — see 'Git hooks on the host' in docs/user/security.md"
}

# Create the control files that Git does not make for a main checkout, so the
# read-only mounts have a regular-file source, then refuse every remaining
# problem. Startup paths call this before Compose. "init"/"sync" only warn
# when there is no .git yet, so 'git init' can still follow 'aic init'.
ensure_git_control_paths () {
  local mode="${1:-strict}" problems line
  if [ -d .git ] && [ ! -L .git ]; then
    if [ ! -e .git/hooks ] && [ ! -L .git/hooks ]; then
      mkdir .git/hooks 2>/dev/null || true
    fi
    # The helper never follows or replaces a path that already exists; the
    # check below reports what it found instead.
    aic_helper git-control-files \
      2>/dev/null || die "could not create the managed Git control files in .git"
  fi
  problems="$(git_control_path_problems --with-missing)"
  [ -n "$problems" ] || return 0
  if [ "$mode" = "lenient" ] && [ ! -e .git ] && [ ! -L .git ]; then
    err "warning: there is no .git directory here — run aic from the repository root, or 'git init' before 'aic up'"
    return 0
  fi
  while IFS= read -r line; do
    err "$line"
  done <<< "$problems"
  die "refusing to mount this checkout's Git control paths"
}
