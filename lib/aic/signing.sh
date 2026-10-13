# shellcheck shell=bash
# =============================================================================
# lib/aic/signing.sh
# =============================================================================
# Commit signing inside the sandbox (aic signing).
#
# aic sources this file. It only defines functions.
# =============================================================================

# ---------------------------------------------------------------------------
# Commit signing inside the sandbox.
#
# The host's signing key never enters the container — ~/.ssh and the SSH agent
# are deliberately NOT forwarded (see the threat model). So a host configured
# for SSH/GPG commit signing can't sign here: every `git commit` would fail
# with "Couldn't find key in agent". `aic signing` fixes that without weakening
# the boundary, by provisioning a *sandbox-only* ed25519 signing key inside the
# aic-auth-global volume (register its pubkey on GitHub once, as a Signing Key).
# post-create wires it into the container-local gitconfig on the next (re)create
# — nothing is forwarded and the host gitconfig stays read-only.
#
# Mode is persisted as ~/.config/aic-auth/signing/mode in the volume:
#   auto     generate a sandbox signing key (recommended)
#   byok     install a separate signing key you provide
#   disable  turn commit signing off inside the sandbox
# `status` reports the current state. Mutating actions run as `vscode` inside
# the running container (so the key lands with correct owner + 0600 perms), so
# they need the container up; `status` reads the volume directly and works
# anytime. Because the wiring is compiled into the root-owned global config
# only at create time, a mode change takes effect on the next rebuild — no live
# edit, hence no privileged unlock primitive to abuse.
# ---------------------------------------------------------------------------

# Read the persisted signing state from the aic-auth-global volume without
# requiring a running container (or auto-creating the volume). Echoes
# "mode=<m> key=<0|1>"; always succeeds.
signing_state () {
  docker volume inspect aic-auth-global >/dev/null 2>&1 || { printf "mode= key=0"; return; }
  if ! docker_volume_metadata_is_safe aic-auth-global; then
    err "refusing to inspect aic-auth-global: managed volumes must use Docker's local driver with no driver options"
    printf "mode= key=0"
    return
  fi
  # DAC_READ_SEARCH is load-bearing: `aic signing` creates signing/ as vscode
  # (0700, owned by the runtime UID), so a plain root probe with all caps
  # dropped cannot traverse it and would always report key=0 — a false
  # "unsigned" even when signing works. This read-only bypass (no write bypass,
  # weaker than DAC_OVERRIDE) lets the probe stat the key; the :ro mount,
  # dropped network, and no-new-privileges keep it locked down. Mirrors
  # aic-chown-volumes, which keeps DAC_READ_SEARCH for the same 0700-tree reason.
  docker run --rm --network none --read-only --cap-drop ALL --cap-add DAC_READ_SEARCH \
    --security-opt no-new-privileges:true -v aic-auth-global:/v:ro \
    busybox@sha256:fd8d9aa63ba2f0982b5304e1ee8d3b90a210bc1ffb5314d980eb6962f1a9715d sh -c \
    'printf "mode=%s key=%s" "$(cat /v/signing/mode 2>/dev/null)" "$(test -f /v/signing/id_ed25519 && echo 1 || echo 0)"' \
    2>/dev/null || printf "mode= key=0"
}

# True when this project's devcontainer is up (mutating signing actions exec
# into it). Mirrors firewall_live_state's running-container probe.
signing_container_running () {
  local project template cid
  project="$(project_name)"
  template="$(trusted_compose_template)"
  cid="$(trusted_template_compose -p "$project" -f "$template" ps -q devcontainer 2>/dev/null)" || return 1
  [ -n "$cid" ] || return 1
  [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" = "true" ]
}

signing_print_status () {
  local st mode key host_sign
  st="$(signing_state)"
  mode="${st#mode=}"; mode="${mode%% key=*}"
  key="${st##*key=}"
  host_sign="$(git config --global --get commit.gpgsign 2>/dev/null || true)"
  printf "aic: commit signing (sandbox-only, shared across projects)\n"
  if [ "$mode" = "disabled" ]; then
    printf "  mode: disabled — commits are unsigned inside the sandbox\n"
  elif [ "$key" = "1" ]; then
    printf "  mode: %s — sandbox ssh signing key present\n" "${mode:-auto}"
    printf "  note: register its pubkey on GitHub as a Signing Key if you haven't (else commits show Unverified)\n"
  elif [ "$host_sign" = "true" ]; then
    printf "  mode: unconfigured — your host signs commits, but that key isn't in the sandbox\n"
    printf "  note: commits are UNSIGNED here; run 'aic signing auto' to provision a sandbox key\n"
  else
    printf "  mode: unconfigured — host doesn't sign commits, nothing to set up\n"
  fi
}

# Simple numbered chooser (host TTY). Echoes the chosen action; returns 1 on
# cancel. Kept deliberately plain — no raw-mode arrow UI needed for 3 options.
signing_menu () {
  local reply
  printf "\nSet up sandbox commit signing:\n" >&2
  printf "  1) auto     generate a sandbox signing key (recommended)\n" >&2
  printf "  2) byok     install a signing key you provide\n" >&2
  printf "  3) disable  turn commit signing off in the sandbox\n" >&2
  printf "  q) cancel\n" >&2
  printf "choice [1]: " >&2
  IFS= read -r reply || reply=""
  case "$reply" in
    ""|1) echo auto ;;
    2)    echo byok ;;
    3)    echo disable ;;
    q|Q)  return 1 ;;
    *)    die "invalid choice: $reply" ;;
  esac
}

signing_do_auto () {
  local devcontainer="$1" register="$2" pub
  # Generate (or reuse) the key as vscode inside the container; emit only the
  # public key on stdout so we can capture it, diagnostics on stderr.
  pub="$("$devcontainer" exec --workspace-folder . bash -lc '
    set -euo pipefail
    dir="$HOME/.config/aic-auth/signing"; key="$dir/id_ed25519"
    mkdir -p "$dir"
    if [ ! -f "$key" ]; then
      ssh-keygen -t ed25519 -N "" -C "aicontainer sandbox signing key" -f "$key" >/dev/null
      echo "aic: generated sandbox signing key" >&2
    else
      echo "aic: reusing existing sandbox signing key" >&2
    fi
    chmod 600 "$key"
    printf auto > "$dir/mode"
    cat "$key.pub"
  ')" || die "failed to set up the signing key inside the container"

  printf "\naic: sandbox signing key ready:\n\n  %s\n\n" "$pub"
  if [ "$register" = "1" ]; then
    signing_register "$devcontainer"
  else
    printf "aic: register it on GitHub as a *Signing Key* (not Authentication):\n"
    printf "       https://github.com/settings/ssh/new\n"
    printf "aic: until then, commits sign locally but show \"Unverified\" on GitHub.\n"
    printf "aic: (or re-run 'aic signing auto --register' to add it via gh.)\n"
  fi
  printf "aic: then 'aic rebuild' (or VS Code: Rebuild Container) to activate signing.\n"
}

signing_register () {
  local devcontainer="$1"
  printf "aic: registering the signing key on GitHub via gh...\n"
  if "$devcontainer" exec --workspace-folder . bash -lc '
    set -euo pipefail
    gh api --method POST /user/ssh_signing_keys \
      -f "title=aicontainer ($(hostname))" \
      -f "key=$(cat "$HOME/.config/aic-auth/signing/id_ed25519.pub")" >/dev/null
  '; then
    printf "aic: registered as a signing key on your GitHub account.\n"
  else
    printf "aic: gh registration failed — most likely the gh token lacks the\n"
    printf "     'write:ssh_signing_key' scope. Grant it and retry:\n"
    printf "       aic shell  ->  gh auth refresh -h github.com -s write:ssh_signing_key\n"
    printf "     then re-run 'aic signing auto --register', or add the key by hand:\n"
    printf "       https://github.com/settings/ssh/new\n"
  fi
}

signing_do_byok () {
  local devcontainer="$1"
  if [ ! -t 0 ]; then
    # A private key is piped on stdin — install it (and derive the pubkey).
    "$devcontainer" exec --workspace-folder . bash -lc '
      set -euo pipefail
      dir="$HOME/.config/aic-auth/signing"; key="$dir/id_ed25519"
      mkdir -p "$dir"
      cat > "$key"
      chmod 600 "$key"
      ssh-keygen -y -f "$key" > "$key.pub"
      printf byok > "$dir/mode"
      echo "aic: installed your signing key:" >&2
      ssh-keygen -lf "$key.pub" >&2
    ' || die "failed to install the provided key (must be an unencrypted private key)"
    printf "aic: register the pubkey on GitHub as a Signing Key: https://github.com/settings/ssh/new\n"
    printf "aic: then 'aic rebuild' to activate signing.\n"
    return
  fi
  # No piped key — record the mode and explain how to drop one in.
  "$devcontainer" exec --workspace-folder . bash -lc '
    set -euo pipefail
    dir="$HOME/.config/aic-auth/signing"; mkdir -p "$dir"; printf byok > "$dir/mode"
  ' || die "failed to set signing mode in the container"
  cat <<'BYOK_EOF'
aic: bring-your-own-key mode set. Provide a *separate* signing key (not your
     host key) one of two ways:
       1) pipe it:   aic signing byok < /path/to/your_signing_key
       2) or place it in the container at
            ~/.config/aic-auth/signing/id_ed25519   (chmod 600)
          e.g. via 'aic shell'; aic derives the .pub if it's absent.
aic: register the pubkey on GitHub as a Signing Key, then 'aic rebuild'.
BYOK_EOF
}

signing_do_disable () {
  local devcontainer="$1"
  "$devcontainer" exec --workspace-folder . bash -lc '
    set -euo pipefail
    dir="$HOME/.config/aic-auth/signing"; mkdir -p "$dir"; printf disabled > "$dir/mode"
  ' || die "failed to set signing mode in the container"
  printf "aic: commit signing will be DISABLED inside the sandbox.\n"
  printf "aic: run 'aic rebuild' (or VS Code: Rebuild Container) to apply.\n"
}

cmd_signing () {
  require_in_project
  local action="" register=0
  while [ $# -gt 0 ]; do
    case "$1" in
      auto|byok|disable|status) action="$1" ;;
      --register) register=1 ;;
      *) die "unknown signing argument: $1 (try: auto, byok, disable, status [--register])" ;;
    esac
    shift
  done

  # No explicit action: print status, then offer the chooser on a TTY.
  if [ -z "$action" ]; then
    signing_print_status
    if [ -t 0 ] && [ -t 1 ]; then
      action="$(signing_menu)" || { echo "aic: cancelled."; return 0; }
    else
      return 0
    fi
  fi

  if [ "$action" = "status" ]; then
    signing_print_status
    return 0
  fi

  # Mutating actions run inside the container (as vscode) — needs it up.
  # devcontainer exec consumes the repository configuration, so gate it before
  # the running-container probe or any key operation.
  pin_compose_project_name
  write_runtime_environment_file
  validate_project_security gate 0
  if ! signing_container_running; then
    die "container not running — run 'aic up' first, then 'aic signing $action'"
  fi
  local devcontainer; devcontainer="$(resolve_devcontainer)"
  case "$action" in
    auto)    signing_do_auto "$devcontainer" "$register" ;;
    byok)    signing_do_byok "$devcontainer" ;;
    disable) signing_do_disable "$devcontainer" ;;
  esac
}
