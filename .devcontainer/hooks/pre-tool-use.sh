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
#   1. .env files: block Read/Edit/Write/Grep/Glob of .env, .env.local,
#      .env.production, etc. Allow .env.example / .env.sample / .env.template /
#      .env.defaults. Grep/Glob are covered too — Grep with output_mode=content
#      can otherwise dump a file the Read block would have stopped.
#   2. curl|sh patterns in Bash: block fetch-and-execute, the main remaining
#      drive-by attack now that the firewall is gone. Catches interposed
#      sudo/env/xargs wrappers, intermediate pipes (| tee | sh), and
#      command/process substitution (sh -c "$(curl ...)", . <(curl ...)).
#   3. Self-protection paths: block writes to /etc/aic/, /workspace/.devcontainer/,
#      and the login-shell rc files (~/.zshrc, ~/.bashrc, fish config + their
#      .local includes). /etc/aic and the RO .devcontainer mount are enforced by
#      the filesystem; the baked rc files are root-locked by aic-lock-gitconfig
#      (post-create), so this hook is the clearer-error / belt-and-suspenders
#      layer (and the only guard for the user-writable .local includes).
# =============================================================================
set -euo pipefail

INPUT="$(cat)"

# Pull every field the rules below might need in a SINGLE jq pass — the hook
# fires on every tool call, so this forks jq once instead of once per field.
# Fields are NUL-separated so embedded newlines in a value (e.g. a multi-line
# Bash heredoc) survive intact for the grep matchers below. Order must match
# the jq array. Schema is shared by Claude Code and Codex (.tool_name /
# .tool_input.{command,file_path,notebook_path,path}).
tool="" cmd="" fpath="" npath="" gpath=""
{
  IFS= read -r -d '' tool  || true
  IFS= read -r -d '' cmd   || true
  IFS= read -r -d '' fpath || true
  IFS= read -r -d '' npath || true
  IFS= read -r -d '' gpath || true
} < <(jq -j '[.tool_name, .tool_input.command, .tool_input.file_path, .tool_input.notebook_path, .tool_input.path] | map(. // "") | .[] + "\u0000"' <<<"$INPUT" 2>/dev/null) || true

block() {
  echo "BLOCKED by aicontainer: $1" >&2
  exit 2
}

[ -z "$tool" ] && exit 0

# ---------------------------------------------------------------------------
# Rule 1: .env file protection
# ---------------------------------------------------------------------------
is_blocked_env() {
  local base="${1##*/}"   # basename, in-process (no fork on the hot path)
  case "$base" in
    .env.example|.env.sample|.env.template|.env.defaults) return 1 ;;
    .env|.env.*)                                          return 0 ;;
  esac
  return 1
}

bash_touches_env() {
  # crude but effective: look for a ".env" / ".env.<x>" filename token in the
  # command text, excluding the explicit-allow filenames above. Token boundaries
  # are "anything that isn't a filename char [A-Za-z0-9_-]", so quotes, globs and
  # redirections around the name are caught too — `cat ".env"`, `cat .env*`,
  # `cat *.env` were all evading the older fixed-character class.
  local cmd="$1"
  if grep -qE '(^|[^[:alnum:]_-])\.env([^[:alnum:]_-]|$)' <<<"$cmd"; then
    if grep -qE '\.env\.(example|sample|template|defaults)' <<<"$cmd"; then
      # mixed reference — bail conservatively if a bare .env (not .env.<x>) is
      # also present (boundary class here excludes '.' so .env.example alone
      # doesn't trip it).
      grep -qE '(^|[^[:alnum:]_-])\.env([^[:alnum:]_.-]|$)' <<<"$cmd" && return 0
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
  # A: curl/wget piped into a shell, allowing intermediate pipes (| tee | sh)
  #    and interposed sudo/env/xargs-style wrappers (| sudo bash, | env X=1 bash).
  #    Interpreters are limited to actual shells — piping into jq/python/node is
  #    almost always data processing, not fetch-and-execute, so excluding them
  #    avoids false positives (e.g. `curl api | python -m json.tool`).
  grep -qE '(curl|wget)[[:space:]][^|]*(\|[^|]*)*\|[[:space:]]*((sudo|doas|env|xargs|command|nice|stdbuf|setsid|nohup|time)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*)*(/(usr/)?bin/)?(sh|bash|zsh|dash|ash|ksh|fish)([[:space:]]|$)' <<<"$cmd" && return 0
  # B: command/process substitution feeding a shell or eval — sh -c "$(curl ...)",
  #    eval "$(wget ...)", source <(curl ...), . <(curl ...).
  grep -qE '(^|[^[:alnum:]_-])(eval|source|\.|sh|bash|zsh|dash|ash|ksh|fish)[[:space:]].*(\$\(|<\()[[:space:]]*(curl|wget)[[:space:]]' <<<"$cmd" && return 0
  return 1
}

# ---------------------------------------------------------------------------
# Rule 3: self-protection paths
# ---------------------------------------------------------------------------
is_protected_path() {
  case "$1" in
    /etc/aic/*|/workspace/.devcontainer/*) return 0 ;;
    # Login-shell rc files executed on `aic shell`, and their opt-in .local
    # includes. The baked rc files are root-locked too (aic-lock-gitconfig); the
    # .local includes stay user-writable, so this is their only guard.
    /home/vscode/.zshrc|/home/vscode/.zshrc.local) return 0 ;;
    /home/vscode/.bashrc|/home/vscode/.bashrc.local) return 0 ;;
    /home/vscode/.config/fish/config.fish|/home/vscode/.config/fish/config.local.fish) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$tool" in
  Read|Edit|Write|MultiEdit|NotebookEdit)
    path="$fpath"
    [ -z "$path" ] && path="$npath"
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
    if [ -n "$cmd" ]; then
      bash_touches_env "$cmd" && \
        block ".env files contain secrets. Use .env.example / .env.sample / .env.template / .env.defaults instead."
      is_curl_pipe_sh "$cmd" && \
        block "curl|sh / wget|bash is unsafe. Download the script, inspect it, then run it explicitly."
    fi
    ;;
  Grep|Glob)
    # Reads: a Grep with output_mode=content (or a Glob) pointed straight at a
    # secret file would otherwise dump it without the Read block firing. A bare
    # directory search still respects the global gitignore (which lists .env*).
    if [ -n "$gpath" ]; then
      is_blocked_env "$gpath" && \
        block ".env files contain secrets. Use .env.example / .env.sample / .env.template / .env.defaults instead."
    fi
    ;;
esac

exit 0
