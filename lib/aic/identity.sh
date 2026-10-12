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

# Resolve the name encoded by the current managed Compose file. Only accept the
# exact value aic computes for this path; a repository-controlled arbitrary
# `name:` must never make `aic down` / `destroy` target somebody else's stack.
# Old files without the managed name retain the legacy resolution until sync.
project_name () {
  local expected encoded=""
  expected="$(expected_project_name)"
  if [ -f .devcontainer/docker-compose.yml ] && [ ! -L .devcontainer/docker-compose.yml ]; then
    if ! grep -qE '^name[[:space:]]*:' .devcontainer/docker-compose.yml; then
      legacy_project_name
      return 0
    fi
    encoded="$(sed -n 's/^name[[:space:]]*:[[:space:]]*\([a-z0-9][a-z0-9_-]*\)[[:space:]]*$/\1/p' \
      .devcontainer/docker-compose.yml | head -n1)"
    [ "$encoded" = "$expected" ] || \
      die "managed Compose name is missing, malformed, or belongs to another path — run 'aic sync'"
    [ "$(grep -cE '^name[[:space:]]*:' .devcontainer/docker-compose.yml)" = "1" ] || \
      die "managed Compose file has multiple top-level names — run 'aic sync'"
    printf '%s\n' "$expected"
    return 0
  fi
  legacy_project_name
}

# True when the Compose file declares any top-level project name. A missing
# name identifies a pre-migration project; a present-but-wrong name is handled
# by project_name() and must never fall back to a basename that could target a
# different checkout.
compose_has_project_name () {
  [ -f .devcontainer/docker-compose.yml ] &&
    grep -qE '^name[[:space:]]*:' .devcontainer/docker-compose.yml
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
# never takes effect there.
pin_compose_project_name () {
  COMPOSE_PROJECT_NAME="$(project_name)" || exit 1
  export COMPOSE_PROJECT_NAME
}

# Return 1, with an actionable message, when a direct Dev Containers start
# (the generated VS Code initializer cannot pin the name for its parent) would
# not use this project's managed name. composeNameConflict() in
# lib/project-identity.mjs mirrors the CLI's lookup; it prints only the source
# that conflicts. A helper that cannot run fails the check with its own message.
check_devcontainer_project_name () {
  local expected conflict
  expected="$(project_name)" || return 1
  if ! conflict="$(aic_helper compose-name-conflict "$expected")"; then
    err "could not check COMPOSE_PROJECT_NAME for a direct Dev Containers start"
    return 1
  fi
  case "$conflict" in
    "") return 0 ;;
    environment)
      err "COMPOSE_PROJECT_NAME in the environment would replace this project's Compose name ($expected) — unset it, or start with 'aic up'"
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
AIC_CONTROL_FILES="devcontainer.json README.md docker-compose.yml .env .gitignore Dockerfile post-create.py aic-firewall aic-chown-volumes aic-lock-user-config .zshrc Dockerfile.project firewall-allowlist chown-paths post-create.project.sh docker-compose.override.yml vscode-extensions vscode-settings.json shell-rc.zsh p10k.zsh statusline.sh statusline.mjs statusline.js statusline.py"

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
