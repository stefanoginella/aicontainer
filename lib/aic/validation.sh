# shellcheck shell=bash
# =============================================================================
# lib/aic/validation.sh
# =============================================================================
# Security boundary: resolved-config validation (validate_project_security),
# the exact-trust store, Docker consent, the early override scan, and aic
# trust. Read docs/contributing/security-review.md before you change this file.
#
# aic sources this file. It only defines functions and constants.
# =============================================================================

# Project-owned files that run code in the container; each needs exact trust.
AIC_PROJECT_CODE_FILES="post-create.project.sh shell-rc.zsh p10k.zsh statusline.sh statusline.mjs statusline.js statusline.py"

# Scan project-owned, sync-preserved devcontainer files that can hand the
# container extra privilege or host access, BEFORE the stack comes up. These
# ride along inside an untrusted repo and are honored on `aic up`: a
# docker-compose.override.yml is auto-wired into dockerComposeFile (so its
# mounts/caps/namespaces apply), and a Dockerfile.project's FROM is what an
# override `build:` actually builds on. The aic-managed files can't express
# these (they're regenerated), so this scan reads only the project-owned ones.
#
# mode=gate (aic up / rebuild): print findings; on a TTY, prompt and abort on
# anything but yes. Non-interactive callers can't be blocked (automation), so
# they get the loud warning and proceed. mode=warn (check-drift / VS Code
# initializeCommand): print only, never prompt. Silence with AIC_NO_OVERRIDE_SCAN=1.
scan_project_overrides () {
  local mode="${1:-gate}"
  [ -n "${AIC_NO_OVERRIDE_SCAN:-}" ] && return 0
  local ov=".devcontainer/docker-compose.override.yml"
  local df=".devcontainer/Dockerfile.project"
  # An array. ShellCheck tracks a name across the whole file, so this name
  # must differ from the findings file paths of the gate below.
  local override_findings=()

  if [ -f "$ov" ]; then
    if grep -qE '^[[:space:]]*privileged:[[:space:]]*(true|yes)([[:space:]]|$)' "$ov"; then
      override_findings+=("override: privileged: true — full host device access")
    fi
    if grep -qE '^[[:space:]]*cap_add:' "$ov"; then
      override_findings+=("override: cap_add — adds Linux capabilities (e.g. SYS_ADMIN)")
    fi
    if grep -qE '^[[:space:]]*(network_mode|pid|ipc|userns_mode):[[:space:]]*["'"'"']?host' "$ov"; then
      override_findings+=("override: shares a host namespace (network/pid/ipc/userns: host)")
    fi
    if grep -qE '^[[:space:]]*security_opt:' "$ov"; then
      override_findings+=("override: security_opt — may disable seccomp/apparmor")
    fi
    if grep -qE '/(var/)?run/docker\.sock' "$ov"; then
      override_findings+=("override: mounts the Docker socket — full host daemon control")
    fi
    if grep -qE '^[[:space:]]*-[[:space:]]*"?/(:|etc|root|home|var|usr|boot|sys|proc)([/:]|$)' "$ov" \
       || grep -qE '^[[:space:]]*source:[[:space:]]*"?/(etc|root|home|var|usr|boot|sys|proc)?([/:]|$)' "$ov"; then
      override_findings+=("override: binds a sensitive host path into the container")
    fi
    if grep -qE '^[[:space:]]*(POST|BUILD):[[:space:]]*1[[:space:]]*$' "$ov"; then
      override_findings+=("override: re-enables socket-proxy POST/BUILD — host container control (prefer 'aic sync --docker')")
    fi
    if grep -qE '^[[:space:]]*devices:' "$ov"; then
      override_findings+=("override: devices — maps host devices into the container")
    fi
    if grep -qE '^[[:space:]]*(post_start|pre_stop):' "$ov"; then
      override_findings+=("override: post_start/pre_stop — lifecycle hooks can run commands as privileged root")
    fi
  fi

  if [ -f "$df" ]; then
    if grep -qE '^[[:space:]]*FROM[[:space:]]' "$df" \
       && ! grep -qE '^[[:space:]]*FROM[[:space:]]+(ghcr\.io/stefanoginella/aicontainer|aicontainer-base)([:@[:space:]]|$)' "$df"; then
      override_findings+=("Dockerfile.project: FROM is not the aicontainer base — sandbox hardening may be absent")
    fi
  fi

  [ "${#override_findings[@]}" -eq 0 ] && return 0

  local y r rst
  if [ -t 2 ]; then y=$'\033[33m'; r=$'\033[31m'; rst=$'\033[0m'; else y=""; r=""; rst=""; fi
  printf '%saic: project-owned devcontainer files request extra host access:%s\n' "$r" "$rst" >&2
  local f
  for f in "${override_findings[@]}"; do printf '  %s!%s %s\n' "$y" "$rst" "$f" >&2; done
  printf '%saic: these take effect when the container comes up. Review them if this repo is not fully trusted.%s\n' "$y" "$rst" >&2
  printf 'aic: (silence this scan with AIC_NO_OVERRIDE_SCAN=1)\n' >&2

  if [ "$mode" = "gate" ] && [ -t 0 ]; then
    local reply
    printf '%saic: bring the container up anyway? [y/N]%s ' "$y" "$rst" >&2
    IFS= read -r reply || reply=""
    case "$reply" in
      y|Y|yes|YES) return 0 ;;
      *) die "aborted — review the files above, or set AIC_NO_OVERRIDE_SCAN=1 to bypass." ;;
    esac
  fi
  return 0
}

# Resolve and validate every host-facing configuration layer before Docker is
# allowed to create containers. The raw grep scan above remains a useful early
# warning (including for an override that has not been synced/wired yet), but it
# is not a security boundary: YAML merging, interpolation, relative paths, and
# service replacement are judged from `docker compose config --format json`.

trust_state_dir () {
  printf '%s/aicontainer/trust\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

trust_state_file () {
  printf '%s/%s.sha256\n' "$(trust_state_dir)" "$(expected_project_name)"
}

docker_consent_file () {
  printf '%s/aicontainer/docker-write/%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$(expected_project_name)"
}

set_docker_consent () {
  local mode="$1" file dir tmp
  file="$(docker_consent_file)"; dir="$(dirname "$file")"
  if [ "$mode" = "ro" ] || [ "$mode" = "rw" ]; then
    mkdir -p "$dir" || die "could not create Docker-consent state directory: $dir"
    chmod 700 "$dir" 2>/dev/null || true
    tmp="$(mktemp "$dir/.consent.XXXXXX")"
    printf '%s\n' "$mode" > "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file"
  else
    rm -f "$file"
  fi
}

docker_consent_matches () {
  local mode="$1" file value=""
  [ "$mode" = "ro" ] || [ "$mode" = "rw" ] || return 1
  file="$(docker_consent_file)"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  IFS= read -r value < "$file" || return 1
  # Backward-compatible with the previous write-only consent marker.
  [ "$value" != "enabled" ] || value="rw"
  [ "$value" = "$mode" ]
}

# The exact-trust hash of the resolved Compose model and the .devcontainer
# tree (lib/trust-hash.mjs). Stored approvals hold it, so its output must not
# change. Anything but a sha256 hex digest fails, so a helper that could not
# run never stores or matches an empty approval.
hash_validation_inputs () {
  local final_json="$1" hash
  hash="$(aic_helper trust-hash "$final_json")" || return 1
  case "$hash" in
    *[!0-9a-f]*|"") return 1 ;;
  esac
  [ "${#hash}" -eq 64 ] || return 1
  printf '%s\n' "$hash"
}

store_project_trust () {
  local hash="$1" dir file tmp
  dir="$(trust_state_dir)"; file="$(trust_state_file)"
  mkdir -p "$dir" || die "could not create trust state directory: $dir"
  chmod 700 "$dir" 2>/dev/null || true
  tmp="$(mktemp "$dir/.trust.XXXXXX")"
  printf '%s\n' "$hash" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
}

project_trust_matches () {
  local hash="$1" file saved=""
  file="$(trust_state_file)"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  IFS= read -r saved < "$file" || return 1
  [ "$saved" = "$hash" ]
}

# Append managed build-mode file provenance failures to $1. These artifacts are
# copied wholesale by aic and execute as root while the image is built; unlike
# project-owned Dockerfile.project, hand-editing them is unsupported.
validate_managed_build_files () {
  local out="$1" name src
  for name in README.md .gitignore; do
    # The template's gitignore has no dot (see apply_template).
    case "$name" in
      .gitignore) src=gitignore ;;
      *) src="$name" ;;
    esac
    if [ ! -f "$TEMPLATE_DIR/$src" ] || ! cmp -s "$TEMPLATE_DIR/$src" ".devcontainer/$name"; then
      printf 'MANAGED\t.devcontainer/%s differs from the managed template; run aic sync\n' "$name" >> "$out"
    fi
  done
  [ -f .devcontainer/Dockerfile ] || return 0
  for name in Dockerfile post-create.py $AIC_POST_CREATE_MODULES aic-firewall aic-chown-volumes aic-lock-user-config .zshrc; do
    if [ ! -f "$TEMPLATE_DIR/$name" ] || ! cmp -s "$TEMPLATE_DIR/$name" ".devcontainer/$name"; then
      printf 'MANAGED\t.devcontainer/%s differs from the managed build template; run aic sync\n' "$name" >> "$out"
    fi
  done
  if ! managed_hooks_match; then
    printf 'MANAGED\t.devcontainer/hooks differs from the managed build template; run aic sync\n' >> "$out"
  fi
}

# .devcontainer/hooks holds exactly the files in AIC_HOOK_FILES, each a regular
# file equal to the template. Any other entry (a file, a directory, a link)
# fails, even though the Dockerfile copies only the listed names. The entry
# count is one character per entry, so no file name can fake a match.
managed_hooks_match () {
  local name listed=0 found
  [ -d .devcontainer/hooks ] && [ ! -L .devcontainer/hooks ] || return 1
  for name in $AIC_HOOK_FILES; do
    [ -f "$TEMPLATE_DIR/hooks/$name" ] && [ -f ".devcontainer/hooks/$name" ] \
      && [ ! -L ".devcontainer/hooks/$name" ] \
      && cmp -s "$TEMPLATE_DIR/hooks/$name" ".devcontainer/hooks/$name" || return 1
    listed=$((listed + 1))
  done
  found="$(find .devcontainer/hooks -mindepth 1 -maxdepth 1 -exec printf x \; 2>/dev/null)" || return 1
  [ "${#found}" -eq "$listed" ]
}

# Append UNSAFE findings for project-owned files that run code in the
# container. They ride along in a cloned repository and run with no prompt:
# post-create.project.sh at create time, the shell overlay in every zsh, and the
# statusline on every Claude Code render. Each run has open egress and the
# tool logins, so a repository must not opt itself in. Exact trust hashes the
# whole .devcontainer tree, so any edit to these files asks again.
# vscode-extensions and vscode-settings.json are judged from their merged
# result in devcontainer.json (analyze_resolved_config), because that is what
# VS Code reads and a repository can commit it directly.
validate_project_code_files () {
  local out="$1" name
  for name in $AIC_PROJECT_CODE_FILES; do
    [ -e ".devcontainer/$name" ] || [ -L ".devcontainer/$name" ] || continue
    case "$name" in
      post-create.project.sh) printf 'UNSAFE\t.devcontainer/%s runs project code on every container create\n' "$name" >> "$out" ;;
      shell-rc.zsh|p10k.zsh) printf 'UNSAFE\t.devcontainer/%s runs project code in every zsh shell\n' "$name" >> "$out" ;;
      *) printf 'UNSAFE\t.devcontainer/%s runs project code on every Claude Code status line render\n' "$name" >> "$out" ;;
    esac
  done
}

# Append the structural findings of lib/validate.mjs to <out>: MANAGED<TAB>...
# for an untrustable managed-config violation, UNSAFE<TAB>... for an
# intentional host-boundary expansion that may be explicitly approved. The
# validator is a file in the aic install, never one from the project. A
# validator that cannot run prints no findings, so a non-zero exit is itself a
# MANAGED finding: validation fails closed.
analyze_resolved_config () {
  local base_json="$1" expected_json="$2" final_json="$3" noenv_json="$4"
  local raw_base_json="$5" raw_final_json="$6" out="$7"
  local has_override=0 rc=0
  [ -f .devcontainer/docker-compose.override.yml ] && has_override=1
  node "$AIC_HOME/lib/validate-cli.mjs" \
    .devcontainer/devcontainer.json "$TEMPLATE_DIR/devcontainer.json" \
    "$base_json" "$expected_json" "$final_json" "$noenv_json" \
    "$raw_base_json" "$raw_final_json" "$(canonical_root)" \
    "$(expected_project_name)" "$has_override" "$(runtime_user_id)" \
    "${AIC_STATUS_RELAY:-0}" "${AIC_STATUS_PROJECT:-$(expected_project_label)}" \
    "${AIC_STATUS_PROJECT_ID:-$(expected_project_name)}" >> "$out" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'MANAGED\t%s\n' 'the aic validator (lib/validate-cli.mjs) failed to run; reinstall aic' >> "$out"
  fi
}

# Validation runs `docker compose config --no-env-resolution`, which first
# shipped in Compose 2.35.0. Older Compose fails those calls with an
# "unknown flag" error; doctor checks the same minimum.
AIC_MIN_COMPOSE_VERSION=2.35.0
AIC_MIN_COMPOSE_LABEL=2.35

# Print the numeric Compose version, or nothing when it cannot be read.
compose_cli_version () {
  local raw
  raw="$(docker compose version --short 2>/dev/null)" || raw=""
  diagnostic_version "$raw"
}

# COMPOSE findings. A version is numeric (diagnostic_version), never raw
# Compose output.
compose_too_old_finding () {
  printf 'COMPOSE\tDocker Compose %s is too old; aic needs Compose %s+ (run aic doctor)\n' \
    "$1" "$AIC_MIN_COMPOSE_LABEL"
}
compose_flag_finding () {
  printf 'COMPOSE\tDocker Compose%s rejects config --no-env-resolution/--no-interpolate; aic needs Compose %s+ (run aic doctor)\n' \
    "${1:+ $1}" "$AIC_MIN_COMPOSE_LABEL"
}

# Run one validation `docker compose ... config` call into <out>. On failure,
# add <message> as a MANAGED finding. Compose's stderr is never printed: with
# interpolation it can hold resolved host environment values. It is only
# searched for Cobra's "unknown flag" error on the flags that need a newer
# Compose (a version string can hide the age, e.g. an unstamped build), which
# becomes one COMPOSE finding instead of a misleading 'aic sync' hint.
validation_compose_config () {
  local out="$1" findings="$2" version="$3" message="$4" err rc=0
  shift 4
  err="$(mktemp "${TMPDIR:-/tmp}/aic-compose-err.XXXXXX")"
  docker compose "$@" > "$out" 2> "$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if grep -Eq 'unknown flag: --no-(env-resolution|interpolate)' "$err"; then
      grep -q '^COMPOSE' "$findings" || compose_flag_finding "$version" >> "$findings"
    else
      printf 'MANAGED\t%s\n' "$message" >> "$findings"
    fi
  fi
  rm -f "$err"
}

# mode=gate: fail closed unless exact config is trusted or --allow-unsafe was
# supplied. mode=warn: print findings for VS Code's legacy check-drift wiring,
# but never abort startup. mode=trust: explicitly store approval for this exact
# resolved configuration after confirmation. mode=validate: apply the same
# managed/resolved gate non-interactively; an existing exact trust record is
# honored, but the command never prompts or writes trust state.
#
# The phases run in this order: host-state checks
# (validation_check_host_state), the Compose models
# (validation_resolve_compose_models), the structural checks
# (analyze_resolved_config), the classification of the findings, then the
# decision. Every phase appends to the one findings file. The decision paths
# remove the temporary files before they return or die.
validate_project_security () {
  local mode="${1:-gate}" allow_once="${2:-0}"
  local base_json expected_json final_json noenv_json raw_base_json raw_final_json
  local findings managed compose_problem unsafe volatile docker_unsafe docker_mode hash
  base_json="$(mktemp "${TMPDIR:-/tmp}/aic-base.XXXXXX")"
  expected_json="$(mktemp "${TMPDIR:-/tmp}/aic-expected.XXXXXX")"
  final_json="$(mktemp "${TMPDIR:-/tmp}/aic-final.XXXXXX")"
  noenv_json="$(mktemp "${TMPDIR:-/tmp}/aic-noenv.XXXXXX")"
  raw_base_json="$(mktemp "${TMPDIR:-/tmp}/aic-raw-base.XXXXXX")"
  raw_final_json="$(mktemp "${TMPDIR:-/tmp}/aic-raw-final.XXXXXX")"
  findings="$(mktemp "${TMPDIR:-/tmp}/aic-findings.XXXXXX")"

  validation_check_host_state "$findings"
  validation_resolve_compose_models "$findings" "$base_json" "$expected_json" \
    "$final_json" "$noenv_json" "$raw_base_json" "$raw_final_json"

  if [ -s "$base_json" ] && [ -s "$expected_json" ] && [ -s "$final_json" ] \
     && [ -s "$noenv_json" ] && [ -s "$raw_base_json" ] && [ -s "$raw_final_json" ]; then
    analyze_resolved_config "$base_json" "$expected_json" "$final_json" "$noenv_json" \
      "$raw_base_json" "$raw_final_json" "$findings"
  fi

  managed="$(grep '^MANAGED' "$findings" 2>/dev/null || true)"
  compose_problem="$(grep '^COMPOSE' "$findings" 2>/dev/null || true)"
  unsafe="$(grep '^UNSAFE' "$findings" 2>/dev/null || true)"
  volatile="$(grep '^VOLATILE' "$findings" 2>/dev/null || true)"
  docker_unsafe="$(grep '^DOCKER' "$findings" 2>/dev/null || true)"
  docker_mode="$(read_compose_docker_mode)"
  if [ -n "$docker_unsafe" ] && ! docker_consent_matches "$docker_mode"; then
    unsafe="${unsafe}${unsafe:+
}${docker_unsafe}"
  fi
  if ! hash="$(hash_validation_inputs "$final_json")"; then
    hash=""
    managed="${managed}${managed:+
}MANAGED could not compute the trust hash (is the aicontainer install complete?)"
  fi
  rm -f "$base_json" "$expected_json" "$final_json" "$noenv_json" \
    "$raw_base_json" "$raw_final_json"

  if [ -n "$managed" ] || [ -n "$compose_problem" ]; then
    printf 'aic: managed devcontainer validation failed:\n' >&2
    printf '%s\n%s\n' "$compose_problem" "$managed" | sed -e '/^$/d' \
      -e 's/^COMPOSE[[:space:]]*/  ! /' -e 's/^MANAGED[[:space:]]*/  ! /' >&2
    rm -f "$findings"
    [ "$mode" = "warn" ] && return 1
    validation_refuse_managed "$mode" "$compose_problem"
  fi

  if [ -z "$unsafe" ] && [ -z "$volatile" ]; then
    rm -f "$findings"
    if [ "$mode" = "trust" ]; then
      echo "aic: no unsafe host-boundary expansions found; no trust exception is needed."
    fi
    return 0
  fi

  printf 'aic: resolved project configuration requests extra host access or runs project code:\n' >&2
  printf '%s\n%s\n' "$unsafe" "$volatile" | sed -e '/^$/d' -e 's/^UNSAFE[[:space:]]*/  ! /' \
    -e 's/^DOCKER[[:space:]]*/  ! /' -e 's/^VOLATILE[[:space:]]*/  ! /' >&2
  rm -f "$findings"

  if [ "$mode" = "warn" ]; then
    return 1
  fi
  validation_accept_unsafe "$mode" "$allow_once" "$hash" "$volatile"
}

# Phase 1 of the gate: append to findings file $1 the host-state findings. They
# are the runtime environment and .devcontainer/.env, the managed build files,
# the project code files, and the Git control paths.
validation_check_host_state () {
  local findings="$1"
  if ! export_runtime_environment; then
    printf 'MANAGED\t%s\n' 'could not resolve the managed host runtime environment (Docker context or status-relay marker)' >> "$findings"
    AIC_DOCKER_SOCKET=/var/run/docker.sock
    AIC_STATUS_RELAY=0
    AIC_STATUS_PROJECT="$(expected_project_label)"
    AIC_STATUS_PROJECT_ID="$(expected_project_name)"
    export AIC_DOCKER_SOCKET AIC_STATUS_RELAY AIC_STATUS_PROJECT AIC_STATUS_PROJECT_ID
  elif ! validate_runtime_environment_file; then
    printf 'MANAGED\t%s\n' '.devcontainer/.env does not match this host runtime state; run aic sync or aic initialize' >> "$findings"
  fi
  validate_managed_build_files "$findings"
  validate_project_code_files "$findings"
  # Startup paths create a missing commondir/config.worktree/hooks first, so
  # only a path that cannot be mounted safely is a finding here.
  git_control_path_problems | while IFS= read -r line; do
    printf 'MANAGED\t%s\n' "$line"
  done >> "$findings"
}

# Phase 2 of the gate: resolve the Compose models into the six JSON files
# $2..$7 (base, expected, final, noenv, raw base, raw final). Append to
# findings file $1 a finding for each model that cannot be resolved.
validation_resolve_compose_models () {
  local findings="$1" base_json="$2" expected_json="$3" final_json="$4"
  local noenv_json="$5" raw_base_json="$6" raw_final_json="$7"
  local expected_compose compose_ver
  if [ -f .devcontainer/Dockerfile ]; then
    expected_compose="$TEMPLATE_DIR/docker-compose.build.yml"
  else
    expected_compose="$TEMPLATE_DIR/docker-compose.pull.yml"
  fi

  # Resolve every model with all profiles active. Plain `config` omits a
  # profiled service, but `up` still starts one that devcontainer.json
  # runServices names or COMPOSE_PROFILES enables, so the gate must see every
  # service any startup path can create.
  # A Compose older than the minimum cannot run the --no-env-resolution calls
  # below. Report that once, and skip every call: their failures would only
  # add findings that 'aic sync' cannot fix. The gate still fails closed.
  compose_ver="$(compose_cli_version)"
  if [ -n "$compose_ver" ] && ! version_at_least "$compose_ver" "$AIC_MIN_COMPOSE_VERSION"; then
    compose_too_old_finding "$compose_ver" >> "$findings"
  else
    validation_compose_config "$base_json" "$findings" "$compose_ver" \
      'docker-compose.yml could not be resolved; run docker compose config for details' \
      --profile '*' -f .devcontainer/docker-compose.yml config --format json
    validation_compose_config "$expected_json" "$findings" "$compose_ver" \
      'installed aic Compose template could not be resolved; reinstall aic' \
      --profile '*' -f "$expected_compose" config --format json
    if [ -f .devcontainer/docker-compose.override.yml ]; then
      validation_compose_config "$final_json" "$findings" "$compose_ver" \
        'managed + override Compose configuration could not be resolved' \
        --profile '*' -f .devcontainer/docker-compose.yml -f .devcontainer/docker-compose.override.yml \
        config --format json
      validation_compose_config "$noenv_json" "$findings" "$compose_ver" \
        'Compose configuration could not be inspected without env-file resolution' \
        --profile '*' -f .devcontainer/docker-compose.yml -f .devcontainer/docker-compose.override.yml \
        config --format json --no-env-resolution
      # Resolve a second pair without interpolation only when an override exists.
      # Normal generated projects pay no extra Compose-process cost.
      validation_compose_config "$raw_base_json" "$findings" "$compose_ver" \
        'managed Compose interpolation model could not be inspected' \
        --profile '*' -f .devcontainer/docker-compose.yml \
        config --format json --no-env-resolution --no-interpolate
      validation_compose_config "$raw_final_json" "$findings" "$compose_ver" \
        'merged Compose interpolation model could not be inspected' \
        --profile '*' -f .devcontainer/docker-compose.yml -f .devcontainer/docker-compose.override.yml \
        config --format json --no-env-resolution --no-interpolate
    else
      cp "$base_json" "$final_json"
      validation_compose_config "$noenv_json" "$findings" "$compose_ver" \
        'Compose configuration could not be inspected without env-file resolution' \
        --profile '*' -f .devcontainer/docker-compose.yml config --format json --no-env-resolution
      printf '{}\n' > "$raw_base_json"
      printf '{}\n' > "$raw_final_json"
    fi
  fi
}

# The gate found a MANAGED or COMPOSE finding in mode $1 (not warn). Die with
# the fix: $2 holds the COMPOSE findings. This function never returns.
validation_refuse_managed () {
  local mode="$1" compose_problem="$2"
  # 'aic sync' cannot fix the host's Compose, so name the real fix instead.
  if [ -n "$compose_problem" ]; then
    [ "$mode" = "validate" ] \
      && die "configuration cannot be validated: upgrade Docker Compose to $AIC_MIN_COMPOSE_LABEL+ (see 'aic doctor')"
    die "refusing to start unverified configuration: upgrade Docker Compose to $AIC_MIN_COMPOSE_LABEL+ (see 'aic doctor')"
  fi
  [ "$mode" = "validate" ] && die "configuration is invalid (run 'aic sync', then review the diff)"
  die "refusing to start unverified managed configuration (run 'aic sync', then review the diff)"
}

# The gate found UNSAFE or VOLATILE findings ($4 holds the VOLATILE ones) in
# mode $1 (gate, validate, or trust). Accept the configuration with hash $3
# through exact trust, the one-run hash, --allow-unsafe ($2 = 1), or a prompt,
# and return 0. Every other path dies.
validation_accept_unsafe () {
  local mode="$1" allow_once="$2" hash="$3" volatile="$4"
  if [ -z "$volatile" ] && { [ "$mode" = "gate" ] || [ "$mode" = "validate" ]; } && project_trust_matches "$hash"; then
    return 0
  fi
  if [ "$mode" = "validate" ]; then
    [ -z "$volatile" ] || die "configuration includes an unbounded build context; use --allow-unsafe on each up/rebuild after reviewing it"
    die "unsafe configuration is not trusted; review it, then run 'aic trust' interactively"
  fi
  # Internal hand-off for `aic up/rebuild --allow-unsafe`: initializeCommand is
  # a child process and revalidates the exact same config before Compose starts.
  # A hash (not a boolean) prevents the repository changing configuration in
  # between the two checks and inheriting the one-run exception.
  if [ "$mode" = "gate" ] && [ "${AIC_UNSAFE_ONCE_HASH:-}" = "$hash" ]; then
    return 0
  fi
  if [ "$allow_once" = "1" ]; then
    export AIC_UNSAFE_ONCE_HASH="$hash"
    echo "aic: proceeding once because --allow-unsafe was explicitly supplied." >&2
    return 0
  fi

  if [ "$mode" = "trust" ] && [ -n "$volatile" ]; then
    die "persistent trust is unavailable for build contexts outside .devcontainer; use --allow-unsafe per run"
  fi
  if [ "$mode" = "trust" ] || [ -t 0 ]; then
    validation_prompt_trust "$mode" "$hash" "$volatile"
    return 0
  fi
  die "unsafe configuration is not trusted; run 'aic trust' interactively or pass --allow-unsafe for one run"
}

# Ask the user to trust the configuration with hash $2 in mode $1 (trust, or
# gate on a TTY). On yes, store exact trust, or, with VOLATILE findings ($3),
# allow one run. Return 0 on yes; die on anything else.
validation_prompt_trust () {
  local mode="$1" hash="$2" volatile="$3" reply
  printf "aic: trust this exact configuration%s? [y/N] " "$([ "$mode" = "trust" ] && printf '' || printf ' and continue')" >&2
  IFS= read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES)
      if [ -n "$volatile" ]; then
        export AIC_UNSAFE_ONCE_HASH="$hash"
        echo "aic: proceeding once; persistent trust is unavailable for this build context."
      else
        store_project_trust "$hash"
        echo "aic: trusted this exact configuration; any relevant change invalidates the approval."
      fi
      return 0
      ;;
    *) die "aborted — configuration was not trusted" ;;
  esac
}

cmd_trust () {
  require_in_project
  local revoke=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --revoke) revoke=1 ;;
      *) die "unknown trust flag: $1 (try --revoke)" ;;
    esac
    shift
  done
  if [ "$revoke" = "1" ]; then
    rm -f "$(trust_state_file)"
    echo "aic: revoked this project's host-access trust."
    return 0
  fi
  [ -t 0 ] || die "'aic trust' requires an interactive confirmation"
  validate_project_security trust 0
}
