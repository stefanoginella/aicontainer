#!/usr/bin/env bash
# =============================================================================
# aicontainer PreToolUse hook
# =============================================================================
# Shared by Claude Code and Codex CLI. Fires even with bypass / auto-approve
# enabled. Defense-in-depth — the real boundaries are filesystem isolation,
# the socket-proxy, and read-only mounts of .devcontainer/.git/{config,hooks}.
#
# Receives a JSON event on stdin. Exit 0 = allow. Exit 2 = block (the AI sees
# the message on stderr and surfaces it to the user).
#
# Three rules:
#   1. .env files: block Read/Edit/Write of .env, .env.local, .env.production,
#      etc. Allow .env.example / .env.sample / .env.template / .env.defaults.
#   2. curl|sh patterns in Bash: block fetch-and-execute, the main remaining
#      drive-by attack now that the firewall is gone.
#   3. Self-protection paths: block writes to /etc/aic/, /home/vscode/.zshrc,
#      and /workspace/.devcontainer/. The first two are already root-owned and
#      the third is mounted RO, but the hook gives a clearer error and catches
#      anyone trying to edit-in-place via sudo.
# =============================================================================
set -euo pipefail

INPUT="$(cat)"

tool_name() { jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null; }
field()     { jq -r --arg k "$1" '.tool_input[$k] // empty' <<<"$INPUT" 2>/dev/null; }

block() {
  echo "BLOCKED by aicontainer: $1" >&2
  exit 2
}

tool="$(tool_name)"
[ -z "$tool" ] && exit 0

# ---------------------------------------------------------------------------
# Rule 1: .env file protection
# ---------------------------------------------------------------------------
is_blocked_env() {
  local base
  base="$(basename "$1")"
  case "$base" in
    .env.example|.env.sample|.env.template|.env.defaults) return 1 ;;
    .env|.env.*)                                          return 0 ;;
  esac
  return 1
}

bash_touches_env() {
  # crude but effective: look for ".env" word boundary in the command text,
  # excluding the explicit-allow filenames above
  local cmd="$1"
  if grep -qE '(^|[[:space:]/<>"'"'"'])\.env([[:space:]]|$|[\.\;\|\&\)>])' <<<"$cmd"; then
    if grep -qE '\.env\.(example|sample|template|defaults)' <<<"$cmd"; then
      # mixed reference — bail conservatively if we also see the plain .env
      grep -qE '(^|[[:space:]/<>"'"'"'])\.env([[:space:]]|$)' <<<"$cmd" && return 0
      return 1
    fi
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Rule 2: curl|sh / wget|bash
# ---------------------------------------------------------------------------
is_curl_pipe_sh() {
  local cmd="$1"
  grep -qE '(curl|wget)[[:space:]][^|]*\|[[:space:]]*(sh|bash|zsh|/bin/(sh|bash))([[:space:]]|$)' <<<"$cmd"
}

# ---------------------------------------------------------------------------
# Rule 3: self-protection paths
# ---------------------------------------------------------------------------
is_protected_path() {
  case "$1" in
    /etc/aic/*|/home/vscode/.zshrc|/workspace/.devcontainer/*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$tool" in
  Read|Edit|Write|MultiEdit|NotebookEdit)
    path="$(field file_path)"
    [ -z "$path" ] && path="$(field notebook_path)"
    if [ -n "$path" ]; then
      is_blocked_env "$path" && \
        block ".env files contain secrets. Use .env.example / .env.sample / .env.template / .env.defaults instead."
      if [ "$tool" != "Read" ]; then
        is_protected_path "$path" && \
          block "this path is part of the container's security infrastructure and must not be modified."
      fi
    fi
    ;;
  Bash)
    cmd="$(field command)"
    if [ -n "$cmd" ]; then
      bash_touches_env "$cmd" && \
        block ".env files contain secrets. Use .env.example / .env.sample / .env.template / .env.defaults instead."
      is_curl_pipe_sh "$cmd" && \
        block "curl|sh / wget|bash is unsafe. Download the script, inspect it, then run it explicitly."
    fi
    ;;
esac

exit 0
