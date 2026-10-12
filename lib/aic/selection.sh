# shellcheck shell=bash
# =============================================================================
# lib/aic/selection.sh
# =============================================================================
# Per-project tool and shell selection: the known values, the checks, the
# interactive prompts, and the reads from devcontainer.json.
#
# aic sources this file. It only defines functions and constants.
# =============================================================================

# ---------------------------------------------------------------------------
# Per-project tool selection (claude-code, codex, opencode).
#
# Stored in .devcontainer/devcontainer.json as containerEnv.AIC_TOOLS, e.g.
# "claude-code,codex,opencode". post-create.py reads it to gate setup_claude /
# setup_codex / setup_opencode; the VSCode extensions array is filtered to match.
#
# Default for old projects without AIC_TOOLS (and for non-TTY init without
# --with) is all tools. Projects pinned with an explicit AIC_TOOLS keep it.
# ---------------------------------------------------------------------------
KNOWN_TOOLS="claude-code codex opencode"

validate_tools () {
  # Normalize a user-supplied list ("codex,claude-code", "claude-code ,codex")
  # to canonical "claude-code,codex,opencode" order. Dies on unknown tools or
  # empty input.
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [ -n "$raw" ] || die "no tools selected (valid: $KNOWN_TOOLS)"
  local has_claude=0 has_codex=0 has_opencode=0
  case ",$raw," in *,claude-code,*) has_claude=1 ;; esac
  case ",$raw," in *,codex,*)       has_codex=1 ;; esac
  case ",$raw," in *,opencode,*)    has_opencode=1 ;; esac
  # Validate by elimination: strip known tokens and separators; anything left
  # is an unknown tool (avoids touching IFS or spawning a subshell).
  local rest="$raw"
  rest="${rest//claude-code/}"
  rest="${rest//codex/}"
  rest="${rest//opencode/}"
  rest="${rest//,/}"
  [ -z "$rest" ] || die "unknown tool(s) in '$1' (valid: $KNOWN_TOOLS)"
  local result=""
  [ "$has_claude" = "1" ]   && result="claude-code"
  [ "$has_codex"  = "1" ]   && result="${result:+$result,}codex"
  [ "$has_opencode" = "1" ] && result="${result:+$result,}opencode"
  [ -n "$result" ] || die "no tools selected (valid: $KNOWN_TOOLS)"
  echo "$result"
}

prompt_tools () {
  # Renders an interactive checkbox menu on /dev/tty and writes the
  # comma-separated selection to stdout. Falls back to both tools when
  # no controlling terminal is available (e.g. CI, piped install).
  # The probe-open is the only reliable check: /dev/tty exists as a device
  # node even in non-interactive contexts, but opening it fails. We probe
  # in a subshell so the test never leaves stale fds in the parent.
  if ! (exec 3</dev/tty 4>/dev/tty) 2>/dev/null; then
    echo "claude-code,codex,opencode"
    return
  fi

  local opts=("claude-code" "codex" "opencode")
  local sel=("1" "1" "1")
  local n=3 cur=0 i mark prefix

  exec 3</dev/tty 4>/dev/tty

  # Restore cursor + close fds on any exit path.
  trap 'printf "\033[?25h" >&4 2>/dev/null; exec 3<&- 4>&- 2>/dev/null; trap - INT TERM EXIT; exit 130' INT TERM

  printf "Which AI tools should this project use?\n" >&4
  printf "(↑/↓ move · space toggles · enter confirms · q cancels)\n\n" >&4
  printf "\033[?25l" >&4

  draw_tools_menu () {
    for ((i=0; i<n; i++)); do
      [ "${sel[$i]}" = "1" ] && mark="[✓]" || mark="[ ]"
      [ "$i" = "$cur" ] && prefix="❯ " || prefix="  "
      printf "\033[K%s%s %s\n" "$prefix" "$mark" "${opts[$i]}" >&4
    done
  }
  draw_tools_menu

  local k c1 c2 any
  while true; do
    IFS= read -rsn1 -u 3 k || k=""
    if [ "$k" = $'\033' ]; then
      IFS= read -rsn1 -u 3 c1 || c1=""
      IFS= read -rsn1 -u 3 c2 || c2=""
      if [ "$c1" = "[" ]; then
        [ "$c2" = "A" ] && cur=$(( (cur - 1 + n) % n ))
        [ "$c2" = "B" ] && cur=$(( (cur + 1) % n ))
      fi
    elif [ "$k" = " " ]; then
      if [ "${sel[$cur]}" = "1" ]; then sel[$cur]="0"; else sel[$cur]="1"; fi
    elif [ -z "$k" ]; then
      any=0
      for ((i=0; i<n; i++)); do [ "${sel[$i]}" = "1" ] && any=1; done
      if [ "$any" = "1" ]; then break; fi
    elif [ "$k" = "q" ] || [ "$k" = "Q" ]; then
      printf "\n\033[?25h" >&4
      exec 3<&- 4>&-
      trap - INT TERM
      die "cancelled by user"
    fi
    printf "\033[%dA" "$n" >&4
    draw_tools_menu
  done

  printf "\033[?25h" >&4
  exec 3<&- 4>&-
  trap - INT TERM

  local result=""
  for ((i=0; i<n; i++)); do
    [ "${sel[$i]}" = "1" ] && result="${result:+$result,}${opts[$i]}"
  done
  echo "$result"
}

read_aic_tools () {
  # Read containerEnv.AIC_TOOLS from .devcontainer/devcontainer.json.
  # Empty output if the field isn't set (older projects).
  local file=".devcontainer/devcontainer.json"
  [ -f "$file" ] || return 0
  sed -n 's/.*"AIC_TOOLS"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n1
}

# ---------------------------------------------------------------------------
# Per-project shell selection (zsh, bash, fish).
#
# Stored in .devcontainer/devcontainer.json as containerEnv.AIC_SHELL. The
# image bakes minimal configs for all three (history persistence + fnm).
# zsh keeps oh-my-zsh + powerlevel10k; bash and fish are barebones. We also
# patch terminal.integrated.defaultProfile.linux + fontFamily so the VS Code
# terminal opens in the chosen shell with a font that fits (MesloLGS NF for
# zsh's p10k icons, plain monospace otherwise).
# ---------------------------------------------------------------------------
KNOWN_SHELLS="zsh bash fish"
DEFAULT_SHELL="zsh"

validate_shell () {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [ -n "$raw" ] || die "no shell specified (valid: $KNOWN_SHELLS)"
  case "$raw" in
    zsh|bash|fish) echo "$raw" ;;
    *) die "unknown shell '$1' (valid: $KNOWN_SHELLS)" ;;
  esac
}

prompt_shell () {
  # Single-select radio menu on /dev/tty. Falls back to the default shell
  # when stdin isn't a TTY (CI, piped install).
  if ! (exec 3</dev/tty 4>/dev/tty) 2>/dev/null; then
    echo "$DEFAULT_SHELL"
    return
  fi

  local opts=("zsh" "bash" "fish")
  local descs=(
    "zsh + oh-my-zsh + powerlevel10k (default)"
    "bash (minimal, history + fnm)"
    "fish (minimal, history + fnm)"
  )
  local n=3 cur=0 i mark prefix

  exec 3</dev/tty 4>/dev/tty

  trap 'printf "\033[?25h" >&4 2>/dev/null; exec 3<&- 4>&- 2>/dev/null; trap - INT TERM EXIT; exit 130' INT TERM

  printf "Which shell should this project use?\n" >&4
  printf "(↑/↓ move · enter confirms · q cancels)\n\n" >&4
  printf "\033[?25l" >&4

  draw_shell_menu () {
    for i in 0 1 2; do
      if [ "$i" = "$cur" ]; then prefix="❯ "; mark="●"; else prefix="  "; mark="○"; fi
      printf "\033[K%s%s %-5s — %s\n" "$prefix" "$mark" "${opts[$i]}" "${descs[$i]}" >&4
    done
  }
  draw_shell_menu

  local k c1 c2
  while true; do
    IFS= read -rsn1 -u 3 k || k=""
    if [ "$k" = $'\033' ]; then
      IFS= read -rsn1 -u 3 c1 || c1=""
      IFS= read -rsn1 -u 3 c2 || c2=""
      if [ "$c1" = "[" ]; then
        [ "$c2" = "A" ] && cur=$(( (cur - 1 + n) % n ))
        [ "$c2" = "B" ] && cur=$(( (cur + 1) % n ))
      fi
    elif [ -z "$k" ]; then
      break
    elif [ "$k" = "q" ] || [ "$k" = "Q" ]; then
      printf "\n\033[?25h" >&4
      exec 3<&- 4>&-
      trap - INT TERM
      die "cancelled by user"
    fi
    printf "\033[%dA" "$n" >&4
    draw_shell_menu
  done

  printf "\033[?25h" >&4
  exec 3<&- 4>&-
  trap - INT TERM

  echo "${opts[$cur]}"
}

read_aic_shell () {
  # Read containerEnv.AIC_SHELL from .devcontainer/devcontainer.json.
  # Empty output if the field isn't set (older projects).
  local file=".devcontainer/devcontainer.json"
  [ -f "$file" ] || return 0
  sed -n 's/.*"AIC_SHELL"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n1
}
