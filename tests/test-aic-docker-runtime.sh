#!/usr/bin/env bash
# The managed socket mounts must bind the socket as the daemon sees it. A
# rootful daemon in a VM (Docker Desktop, Colima, Lima, Rancher Desktop) cannot
# bind the context's host path, so aic binds its VM socket /var/run/docker.sock.
# OrbStack, native Linux, rootless, and unrecognized daemons keep the host path.
# A fake docker answers `context` and `info` like each runtime does.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Short path: doctor checks a real Unix socket below $HOME, and macOS limits
# socket paths to 104 bytes.
TMP=$(mktemp -d /tmp/aic-rt.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/h" XDG_STATE_HOME="$TMP/state" XDG_CACHE_HOME="$TMP/cache"
export CI=1 AIC_NO_UPDATE_CHECK=1 AIC_HOME="$ROOT"
unset DOCKER_HOST DOCKER_CONTEXT COMPOSE_PROJECT_NAME AIC_DOCKER_SOCKET
mkdir -p "$HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }

fakebin="$TMP/bin"
linuxbin="$TMP/linux-bin"
darwinbin="$TMP/darwin-bin"
mkdir -p "$fakebin" "$linuxbin" "$darwinbin"
# AIC_FAKE_ENDPOINT is the selected endpoint (the context's, unless
# AIC_FAKE_CONTEXT_ENDPOINT gives the context another one). AIC_FAKE_INFO is
# the `docker info` answer of the daemon on that endpoint; empty means the
# daemon does not answer. Only the selected socket answers, so a detection that
# asks another daemon fails the expectation. AIC_FAKE_INFO_MODE=starts answers
# only from the second query on (a daemon that starts during the command);
# AIC_FAKE_INFO_MODE=null prints the empty template and exits 0.
# AIC_FAKE_COMPOSE_VERSION makes `docker compose` answer as that version (unset:
# no Compose). AIC_FAKE_COMPOSE_FLAGS=reject makes `config` reject
# --no-env-resolution/--no-interpolate the way Cobra does in Compose < 2.35,
# with a fake resolved secret on stderr that aic must never print.
cat > "$fakebin/docker" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$AIC_FAKE_LOG"
if [ "${1:-}" = compose ]; then
  [ -n "${AIC_FAKE_COMPOSE_VERSION:-}" ] || exit 1
  [ "${2:-}" = version ] && { printf '%s\n' "$AIC_FAKE_COMPOSE_VERSION"; exit 0; }
  for arg in "$@"; do
    case "$arg" in
      --no-env-resolution|--no-interpolate)
        if [ "${AIC_FAKE_COMPOSE_FLAGS:-}" = reject ]; then
          echo "environment: AIC_FAKE_SECRET=fake-resolved-secret" >&2
          echo "unknown flag: $arg" >&2
          exit 1
        fi
        ;;
    esac
  done
  case " $* " in
    *" config "*) printf '{"name":"aic-doctor","subpath":"child"}\n'; exit 0 ;;
  esac
  exit 1
fi
case "${1:-} ${2:-}" in
  "context show") echo default; exit 0 ;;
  "context inspect") printf '%s\n' "${AIC_FAKE_CONTEXT_ENDPOINT:-$AIC_FAKE_ENDPOINT}"; exit 0 ;;
  "-H unix://"*)
    [ "$2" = "$AIC_FAKE_ENDPOINT" ] && [ "${3:-}" = info ] || exit 1
    case "${AIC_FAKE_INFO_MODE:-}" in
      null) printf '||null\n'; exit 0 ;;
      starts)
        [ -e "$AIC_FAKE_LOG.started" ] || { : > "$AIC_FAKE_LOG.started"; exit 1; }
        ;;
    esac
    [ -n "${AIC_FAKE_INFO:-}" ] || exit 1
    printf '%s\n' "$AIC_FAKE_INFO"
    exit 0
    ;;
esac
exit 1
SH
chmod +x "$fakebin/docker"
# Fake the host OS: macOS has no native daemon, and a Linux host can carry a
# Lima-style hostname that detection must not trust.
printf '#!/bin/sh\necho Linux\n' > "$linuxbin/uname"
printf '#!/bin/sh\necho Darwin\n' > "$darwinbin/uname"
chmod +x "$linuxbin/uname" "$darwinbin/uname"

project="$TMP/p"
mkdir -p "$project"
git -C "$project" init -q
export AIC_FAKE_LOG="$TMP/docker.log"

# Print the AIC_DOCKER_SOCKET that `aic init` writes for this daemon.
bind_source() {
  local endpoint="$1" info="$2" path_prefix="${3:-$darwinbin}"
  (cd "$project" && PATH="$path_prefix:$fakebin:$PATH" AIC_FAKE_ENDPOINT="$endpoint" \
    AIC_FAKE_INFO="$info" "$ROOT/aic" init --force --with codex --shell zsh >/dev/null)
  sed -n 's/^AIC_DOCKER_SOCKET=//p' "$project/.devcontainer/.env"
}

expect() {
  local label="$1" endpoint="$2" info="$3" want="$4" path_prefix="${5:-$darwinbin}" got
  got=$(bind_source "$endpoint" "$info" "$path_prefix") || fail "$label: aic init failed"
  [ "$got" = "$want" ] || fail "$label: bound '$got', expected '$want'"
}

rootful='["name=seccomp,profile=builtin","name=cgroupns"]'
rootless='["name=seccomp,profile=builtin","name=rootless","name=cgroupns"]'
vm=/var/run/docker.sock

# Rootful daemons in a VM: bind the VM daemon's own socket.
expect "Docker Desktop (macOS)" "unix://$HOME/.docker/run/docker.sock" \
  "Docker Desktop|docker-desktop|$rootful" "$vm"
expect "Docker Desktop (Linux)" "unix://$HOME/.docker/desktop/docker.sock" \
  "Docker Desktop|docker-desktop|$rootful" "$vm" "$linuxbin"
expect "Docker Desktop on a custom context path" "unix://$HOME/custom/dd.sock" \
  "Docker Desktop|docker-desktop|$rootful" "$vm" "$linuxbin"
expect "Colima default profile" "unix://$HOME/.colima/default/docker.sock" \
  "Ubuntu 24.04.2 LTS|colima|$rootful" "$vm"
expect "Colima named profile" "unix://$HOME/.colima/work/docker.sock" \
  "Ubuntu 24.04.2 LTS|colima-work|$rootful" "$vm"
expect "Colima XDG config dir" "unix://$HOME/.config/colima/default/docker.sock" \
  "Ubuntu 24.04.2 LTS|colima|$rootful" "$vm" "$linuxbin"
expect "Rancher Desktop" "unix://$HOME/.rd/docker.sock" \
  "Alpine Linux v3.20|lima-rancher-desktop|$rootful" "$vm"
expect "Lima rootful" "unix://$HOME/.lima/docker-rootful/sock/docker.sock" \
  "Ubuntu 24.04.2 LTS|lima-docker-rootful|$rootful" "$vm"
expect "Colima on a custom macOS path" "unix://$HOME/elsewhere/colima.sock" \
  "Ubuntu 24.04.2 LTS|colima|$rootful" "$vm"
expect "Colima --hostname on macOS" "unix://$HOME/.colima/default/docker.sock" \
  "Ubuntu 24.04.2 LTS|devbox|$rootful" "$vm"

# Everything else keeps the context's host path.
expect "OrbStack" "unix://$HOME/.orbstack/run/docker.sock" \
  "OrbStack|orbstack|$rootful" "$HOME/.orbstack/run/docker.sock"
expect "native Linux rootful" "unix:///var/run/docker.sock" \
  "Ubuntu 24.04.2 LTS|ci-runner|$rootful" /var/run/docker.sock "$linuxbin"
expect "native Linux rootless" "unix:///run/user/1000/docker.sock" \
  "Ubuntu 24.04.2 LTS|ci-runner|$rootless" /run/user/1000/docker.sock "$linuxbin"
# A rootless daemon's /var/run/docker.sock can be another, rootful daemon.
expect "rootless daemon named like a VM" "unix:///run/user/1000/docker.sock" \
  "Ubuntu 24.04.2 LTS|colima|$rootless" /run/user/1000/docker.sock
expect "Lima rootless" "unix://$HOME/.lima/docker/sock/docker.sock" \
  "Ubuntu 24.04.2 LTS|lima-docker|$rootless" "$HOME/.lima/docker/sock/docker.sock"
expect "Linux host named colima" "unix:///srv/docker/docker.sock" \
  "Ubuntu 24.04.2 LTS|colima|$rootful" /srv/docker/docker.sock "$linuxbin"
expect "Linux host named lima-*" "unix:///srv/docker/docker.sock" \
  "Ubuntu 24.04.2 LTS|lima-build|$rootful" /srv/docker/docker.sock "$linuxbin"
# On Linux the path alone is not enough while the daemon can answer.
expect "Colima path, other hostname, Linux" "unix://$HOME/.colima/default/docker.sock" \
  "Ubuntu 24.04.2 LTS|devbox|$rootful" "$HOME/.colima/default/docker.sock" "$linuxbin"
# Only the exact Docker Desktop OS name counts, not a look-alike.
expect "look-alike Docker Desktop OS" "unix:///var/lib/dd/docker.sock" \
  "Docker Desktop Clone|docker-desktop|$rootful" /var/lib/dd/docker.sock "$linuxbin"
expect "unknown macOS VM (Podman)" "unix://$HOME/.local/share/containers/podman.sock" \
  "fedora|localhost.localdomain|$rootful" "$HOME/.local/share/containers/podman.sock"

# Daemon stopped (aic init/sync before Docker starts): the runtime's default
# path decides, so the file matches what the next start writes.
expect "stopped Docker Desktop" "unix://$HOME/.docker/run/docker.sock" "" "$vm"
expect "stopped Colima" "unix://$HOME/.colima/default/docker.sock" "" "$vm"
expect "stopped Rancher Desktop" "unix://$HOME/.rd/docker.sock" "" "$vm"
expect "stopped OrbStack" "unix://$HOME/.orbstack/run/docker.sock" "" \
  "$HOME/.orbstack/run/docker.sock"
# Lima's default template is rootless, so a stopped Lima keeps the host path.
expect "stopped Lima" "unix://$HOME/.lima/docker/sock/docker.sock" "" \
  "$HOME/.lima/docker/sock/docker.sock"
expect "stopped unknown daemon" "unix:///opt/docker/docker.sock" "" /opt/docker/docker.sock

# A CLI that prints the empty template with exit 0 is no answer: a stopped
# Docker Desktop keeps the VM path, and a stopped Lima stays unmapped.
AIC_FAKE_INFO_MODE=null expect "empty answer, Docker Desktop" \
  "unix://$HOME/.docker/run/docker.sock" "" "$vm"
AIC_FAKE_INFO_MODE=null expect "empty answer, Lima" \
  "unix://$HOME/.lima/docker/sock/docker.sock" "" "$HOME/.lima/docker/sock/docker.sock"
# An answer without the security options cannot prove the daemon is rootful.
expect "answer without security options, Lima" "unix://$HOME/.lima/docker/sock/docker.sock" \
  "Ubuntu 24.04.2 LTS|lima-docker" "$HOME/.lima/docker/sock/docker.sock"
# Rootless wins over a runtime's default path on Linux too.
expect "rootless daemon on a Colima path, Linux" "unix://$HOME/.colima/default/docker.sock" \
  "Ubuntu 24.04.2 LTS|colima|$rootless" "$HOME/.colima/default/docker.sock" "$linuxbin"

# Like the Docker CLI and Compose, DOCKER_HOST beats DOCKER_CONTEXT, so
# detection asks the daemon that Compose will use.
got=$(cd "$project" && PATH="$linuxbin:$fakebin:$PATH" DOCKER_CONTEXT=colima \
  DOCKER_HOST=unix:///run/user/1000/docker.sock \
  AIC_FAKE_CONTEXT_ENDPOINT="unix://$HOME/.colima/default/docker.sock" \
  AIC_FAKE_ENDPOINT=unix:///run/user/1000/docker.sock \
  AIC_FAKE_INFO="Ubuntu 24.04.2 LTS|ci-runner|$rootless" \
  "$ROOT/aic" init --force --with codex --shell zsh >/dev/null \
  && sed -n 's/^AIC_DOCKER_SOCKET=//p' .devcontainer/.env)
[ "$got" = /run/user/1000/docker.sock ] || fail "DOCKER_CONTEXT beat DOCKER_HOST: bound '$got'"

# One process asks the daemon once. Here the daemon starts between the .env
# write and the validation in `aic initialize`; the validation must see the
# value that was written, not report the file as stale.
lima="unix://$HOME/.lima/docker-rootful/sock/docker.sock"
bind_source "$lima" "" >/dev/null
: > "$AIC_FAKE_LOG"; rm -f "$AIC_FAKE_LOG.started"
out=$(cd "$project" && PATH="$darwinbin:$fakebin:$PATH" AIC_FAKE_ENDPOINT="$lima" \
  AIC_FAKE_INFO_MODE=starts AIC_FAKE_INFO="Ubuntu 24.04.2 LTS|lima-docker-rootful|$rootful" \
  "$ROOT/aic" initialize 2>&1 || true)
[ "$(grep -c -- '^-H ' "$AIC_FAKE_LOG")" = 1 ] || fail "initialize asked the daemon more than once"
printf '%s\n' "$out" | grep -Fq '.env does not match' && fail "initialize flipped the bind source: $out"
rm -f "$AIC_FAKE_LOG.started"

# Detection asks the selected socket itself, never the ambient context.
: > "$AIC_FAKE_LOG"
bind_source "unix://$HOME/.docker/run/docker.sock" "Docker Desktop|docker-desktop|$rootful" >/dev/null
grep -Fqx -- "-H unix://$HOME/.docker/run/docker.sock info --format {{.OperatingSystem}}|{{.Name}}|{{json .SecurityOptions}}" \
  "$AIC_FAKE_LOG" || fail "runtime detection did not query the selected socket"

# The environment can never choose the bind source.
got=$(cd "$project" && PATH="$fakebin:$PATH" AIC_DOCKER_SOCKET=/etc/shadow \
  AIC_FAKE_ENDPOINT="unix://$HOME/.orbstack/run/docker.sock" AIC_FAKE_INFO="OrbStack|orbstack|$rootful" \
  "$ROOT/aic" init --force --with codex --shell zsh >/dev/null \
  && sed -n 's/^AIC_DOCKER_SOCKET=//p' .devcontainer/.env)
[ "$got" = "$HOME/.orbstack/run/docker.sock" ] || fail "an exported AIC_DOCKER_SOCKET changed the bind source"

# A remote context still fails, and no runtime detection runs for it.
: > "$AIC_FAKE_LOG"
if (cd "$project" && PATH="$fakebin:$PATH" AIC_FAKE_ENDPOINT="tcp://10.0.0.1:2375" AIC_FAKE_INFO="" \
    "$ROOT/aic" init --force --with codex --shell zsh >/dev/null 2>&1); then
  fail "init accepted a remote Docker context"
fi
grep -q -- '^-H ' "$AIC_FAKE_LOG" && fail "runtime detection contacted a remote context"
# The start paths refuse it as well, and leave the generated .env alone.
bind_source "unix://$HOME/.orbstack/run/docker.sock" "OrbStack|orbstack|$rootful" >/dev/null
before=$(cat "$project/.devcontainer/.env")
: > "$AIC_FAKE_LOG"
for cmd in initialize up validate; do
  if (cd "$project" && PATH="$fakebin:$PATH" AIC_FAKE_ENDPOINT="tcp://10.0.0.1:2375" AIC_FAKE_INFO="" \
      "$ROOT/aic" "$cmd" </dev/null >/dev/null 2>&1); then
    fail "aic $cmd accepted a remote Docker context"
  fi
  [ "$(cat "$project/.devcontainer/.env")" = "$before" ] || fail "aic $cmd rewrote .env for a remote context"
done
grep -q -- '^-H ' "$AIC_FAKE_LOG" && fail "runtime detection contacted a remote context"

# doctor and status name the runtime and the bind source.
socket="$HOME/.docker/run/docker.sock"
mkdir -p "$(dirname "$socket")"
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$socket"
bind_source "unix://$socket" "Docker Desktop|docker-desktop|$rootful" >/dev/null
out=$(cd "$project" && PATH="$fakebin:$PATH" AIC_FAKE_ENDPOINT="unix://$socket" \
  AIC_FAKE_INFO="Docker Desktop|docker-desktop|$rootful" "$ROOT/aic" doctor 2>&1 || true)
printf '%s\n' "$out" | grep -Fq "Docker runtime docker-desktop: managed helpers will bind the VM daemon socket /var/run/docker.sock" \
  || fail "doctor did not report the Docker Desktop bind source: $out"
out=$(cd "$project" && PATH="$darwinbin:$fakebin:$PATH" AIC_FAKE_ENDPOINT="unix://$socket" \
  AIC_FAKE_INFO="fedora|localhost.localdomain|$rootful" "$ROOT/aic" doctor 2>&1 || true)
printf '%s\n' "$out" | grep -Fq "Docker runtime other runs in a VM that aic does not recognize" \
  || fail "doctor did not warn about an unrecognized macOS VM: $out"
out=$(cd "$project" && PATH="$linuxbin:$fakebin:$PATH" AIC_FAKE_ENDPOINT="unix://$socket" \
  AIC_FAKE_INFO="Ubuntu 24.04.2 LTS|ci-runner|$rootful" "$ROOT/aic" doctor 2>&1 || true)
printf '%s\n' "$out" | grep -Fq "Docker runtime other: managed helpers will bind the selected local socket" \
  || fail "doctor did not keep the host socket for a native Linux daemon: $out"
out=$(cd "$project" && PATH="$fakebin:$PATH" AIC_FAKE_ENDPOINT="unix://$socket" \
  AIC_FAKE_INFO="Docker Desktop|docker-desktop|$rootful" "$ROOT/aic" status 2>&1)
printf '%s\n' "$out" | grep -Fq "socket $socket (docker-desktop; mounts bind /var/run/docker.sock)" \
  || fail "status did not report the Docker Desktop bind source: $out"

# Validation needs `config --no-env-resolution` (Compose 2.35+). An older
# Compose must fail doctor and fail validation with an upgrade hint, not the
# 'aic sync' hint, which cannot fix the host's Compose.
desktop_info="Docker Desktop|docker-desktop|$rootful"
# Fake the same host OS as the `aic init` that wrote .env (bind_source's
# default). The real uname would make .env stale on a Linux runner, and that
# extra finding would hide whether the Compose finding stands alone.
run_aic() {
  (cd "$project" && PATH="$darwinbin:$fakebin:$PATH" AIC_FAKE_ENDPOINT="unix://$socket" \
    AIC_FAKE_INFO="$desktop_info" "$ROOT/aic" "$@" </dev/null 2>&1)
}
for good in 2.35.0 v2.40.3 5.1.2; do
  out=$(AIC_FAKE_COMPOSE_VERSION="$good" run_aic doctor || true)
  printf '%s\n' "$out" | grep -q "^OK    Docker Compose ${good#v} (minimum 2.35)$" \
    || fail "doctor rejected Compose $good: $out"
  printf '%s\n' "$out" | grep -q '^OK    Compose accepts config --no-env-resolution --no-interpolate' \
    || fail "doctor did not probe config --no-env-resolution on Compose $good: $out"
  printf '%s\n' "$out" | grep -q '^FAIL  .*Compose' && fail "doctor failed a Compose check on $good: $out"
done

: > "$AIC_FAKE_LOG"
doctor_rc=0
out=$(AIC_FAKE_COMPOSE_VERSION=2.29.7 AIC_FAKE_COMPOSE_FLAGS=reject run_aic doctor) || doctor_rc=$?
[ "$doctor_rc" -ne 0 ] || fail "doctor exited zero with Compose 2.29.7: $out"
printf '%s\n' "$out" | grep -q '^FAIL  Docker Compose 2.29.7 is too old — install the Compose plugin 2.35+' \
  || fail "doctor did not fail Compose 2.29.7: $out"
printf '%s\n' "$out" | grep -q '^FAIL  Compose rejects config --no-env-resolution' \
  || fail "doctor did not report the missing config flag: $out"
printf '%s\n' "$out" | grep -q '^Result: ready' && fail "doctor reported ready with Compose 2.29.7: $out"
grep -q -- '^compose -f - config .*--no-env-resolution' "$AIC_FAKE_LOG" \
  || fail "doctor did not probe the flag with a stdin-only config"
grep -- '^compose ' "$AIC_FAKE_LOG" | grep -v -e '^compose -f - config ' -e '^compose version --short$' \
  | grep -q . && fail "doctor ran a Compose command that is not a stdin-only parse"
printf '%s\n' "$out" | grep -q 'fake-resolved-secret' && fail "doctor printed Compose stderr: $out"

# Too old by version: one finding, no Compose config call, no 'aic sync' hint.
: > "$AIC_FAKE_LOG"
rc=0
out=$(AIC_FAKE_COMPOSE_VERSION=2.29.7 AIC_FAKE_COMPOSE_FLAGS=reject run_aic validate) || rc=$?
[ "$rc" -ne 0 ] || fail "validate passed with Compose 2.29.7: $out"
printf '%s\n' "$out" | grep -Fxq '  ! Docker Compose 2.29.7 is too old; aic needs Compose 2.35+ (run aic doctor)' \
  || fail "validate did not name the too-old Compose: $out"
printf '%s\n' "$out" | grep -Fxq "aic: configuration cannot be validated: upgrade Docker Compose to 2.35+ (see 'aic doctor')" \
  || fail "validate did not give the Compose upgrade hint: $out"
printf '%s\n' "$out" | grep -q 'aic sync' && fail "validate told the user to run aic sync for an old Compose: $out"
printf '%s\n' "$out" | grep -q 'could not be inspected' && fail "validate kept the misleading Compose findings: $out"
grep -q -- '^compose .* config' "$AIC_FAKE_LOG" && fail "validate ran Compose config on a too-old Compose"
[ "$(printf '%s\n' "$out" | grep -c '^  ! ')" = 1 ] || fail "validate reported more than the Compose finding: $out"

# The start gate (VS Code's initializer) refuses the same way, before any
# Docker state changes, also without the sync hint.
: > "$AIC_FAKE_LOG"
rc=0
out=$(AIC_FAKE_COMPOSE_VERSION=2.29.7 AIC_FAKE_COMPOSE_FLAGS=reject run_aic initialize) || rc=$?
[ "$rc" -ne 0 ] || fail "initialize started a configuration it could not validate: $out"
printf '%s\n' "$out" | grep -Fxq "aic: refusing to start unverified configuration: upgrade Docker Compose to 2.35+ (see 'aic doctor')" \
  || fail "initialize did not give the Compose upgrade hint: $out"
printf '%s\n' "$out" | grep -q 'aic sync' && fail "initialize told the user to run aic sync for an old Compose: $out"
grep -q -e '^volume ' -e '^run ' -e '^compose .* up' "$AIC_FAKE_LOG" \
  && fail "initialize changed Docker state after a failed validation"

# A version string that hides the age (an unstamped build): the rejected flag
# itself is detected, and Compose's stderr is never printed.
rc=0
out=$(AIC_FAKE_COMPOSE_VERSION=2.35.0 AIC_FAKE_COMPOSE_FLAGS=reject run_aic validate) || rc=$?
[ "$rc" -ne 0 ] || fail "validate passed although Compose rejected --no-env-resolution: $out"
printf '%s\n' "$out" | grep -Fxq '  ! Docker Compose 2.35.0 rejects config --no-env-resolution/--no-interpolate; aic needs Compose 2.35+ (run aic doctor)' \
  || fail "validate did not report the rejected Compose flag: $out"
printf '%s\n' "$out" | grep -q 'aic sync' && fail "validate told the user to run aic sync for a rejected flag: $out"
printf '%s\n' "$out" | grep -q 'fake-resolved-secret' && fail "validate printed Compose stderr: $out"
printf '%s\n' "$out" | grep -q 'unknown flag' && fail "validate printed raw Compose stderr: $out"

echo "docker runtime bind-source tests passed"
