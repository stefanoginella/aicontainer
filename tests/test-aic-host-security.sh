#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REAL_DOCKER=$(command -v docker)
REAL_DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

help=$(AIC_NO_UPDATE_CHECK=1 "$ROOT/aic" help)
[ "$(printf '%s\n' "$help" | grep -c '^  AIC_NO_OVERRIDE_SCAN')" = "1" ] \
  || fail "help duplicated or dropped AIC_NO_OVERRIDE_SCAN"
for shell in bash zsh fish; do
  completion=$("$ROOT/aic" completion "$shell")
  for command in doctor status validate; do
    case "$completion" in
      *"$command"*) ;;
      *) fail "$shell completion omitted $command" ;;
    esac
  done
  if [ "$shell" = "fish" ]; then
    case "$completion" in
      *'-l docker-read'*) ;;
      *) fail "fish completion omitted --docker-read" ;;
    esac
  else
    case "$completion" in
      *--docker-read*) ;;
      *) fail "$shell completion omitted --docker-read" ;;
    esac
  fi
done

# GUI-launched editors often have a trimmed PATH, so initializeCommand scans
# common Node-manager installs. It must skip an old/incompatible aic and choose
# the last supported nvm/fnm fallback rather than stopping at the first match
# glob match. Execute the actual JSON-encoded command with fixed system paths
# redirected to this isolated fixture so a developer's own global install
# cannot influence the result.
initializer_home="$TMP/initializer-home"
initializer_bin="$TMP/initializer-bin"
initializer_log="$TMP/initializer.log"
mkdir -p "$initializer_home/.nvm/versions/node/v18.20.0/bin" \
  "$initializer_home/.nvm/versions/node/v22.22.0/bin" "$initializer_bin"
cat > "$initializer_bin/aic" <<'SH'
#!/bin/sh
case "${1:-}" in
  version) echo "aic v0.4.0" ;;
  *) exit 1 ;;
esac
SH
cat > "$initializer_home/.nvm/versions/node/v18.20.0/bin/aic" <<'SH'
#!/bin/sh
case "${1:-}" in
  initialize) printf '%s\n' v18 >> "$AIC_INITIALIZER_TEST_LOG" ;;
  *) exit 1 ;;
esac
SH
cat > "$initializer_home/.nvm/versions/node/v22.22.0/bin/aic" <<'SH'
#!/bin/sh
case "${1:-}" in
  initialize) printf '%s\n' v22 >> "$AIC_INITIALIZER_TEST_LOG" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$initializer_bin/aic" \
  "$initializer_home/.nvm/versions/node/v18.20.0/bin/aic" \
  "$initializer_home/.nvm/versions/node/v22.22.0/bin/aic"
initializer_cmd=$(node -e '
  const fs = require("fs");
  const source = fs.readFileSync(process.argv[1], "utf8");
  const match = source.match(/"initializeCommand"\s*:\s*("(?:\\.|[^"\\])*")/);
  if (!match) process.exit(2);
  let command = JSON.parse(match[1]);
  const missing = process.argv[2] + "/missing";
  for (const candidate of ["/opt/homebrew/bin/aic", "/usr/local/bin/aic", "/usr/bin/aic"]) {
    command = command.split(candidate).join(missing + candidate.replaceAll("/", "_"));
  }
  process.stdout.write(command);
' "$ROOT/template/devcontainer.json" "$initializer_home")
: > "$initializer_log"
HOME="$initializer_home" PATH="$initializer_bin:/usr/bin:/bin" \
  AIC_INITIALIZER_TEST_LOG="$initializer_log" /bin/sh -c "$initializer_cmd"
[ "$(cat "$initializer_log")" = "v22" ] \
  || fail "initializeCommand did not skip the old PATH CLI and scan every supported nvm fallback"

chmod -x "$initializer_home/.nvm/versions/node/v18.20.0/bin/aic" \
  "$initializer_home/.nvm/versions/node/v22.22.0/bin/aic"
set +e
out=$(HOME="$initializer_home" PATH="$initializer_bin:/usr/bin:/bin" \
  AIC_INITIALIZER_TEST_LOG="$initializer_log" /bin/sh -c "$initializer_cmd" 2>&1)
initializer_rc=$?
set -e
[ "$initializer_rc" -ne 0 ] || fail "initializeCommand accepted an incompatible host CLI"
echo "$out" | grep -q 'installed host CLI is too old' \
  || fail "initializeCommand omitted the actionable incompatible-CLI diagnosis"
echo "$out" | grep -q 'npm update -g aicontainer' \
  || fail "initializeCommand omitted the CLI upgrade command"

new_project() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  (cd "$dir" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
    "$ROOT/aic" init --with codex --shell zsh >/dev/null)
}

# The managed project name is path-unique even for equal basenames.
new_project "$TMP/one/api"
new_project "$TMP/two/api"
name1=$(sed -n 's/^name:[[:space:]]*//p' "$TMP/one/api/.devcontainer/docker-compose.yml")
name2=$(sed -n 's/^name:[[:space:]]*//p' "$TMP/two/api/.devcontainer/docker-compose.yml")
[ -n "$name1" ] && [ -n "$name2" ] && [ "$name1" != "$name2" ] \
  || fail "same-basename projects did not get unique Compose names"
version=$(node -p 'require(process.argv[1]).version' "$ROOT/package.json")
[ "$(grep -c "^[[:space:]]*image: ghcr.io/stefanoginella/aicontainer:v$version" \
    "$TMP/one/api/.devcontainer/docker-compose.yml")" = "3" ] \
  || fail "pull-mode compose did not pin all three managed image services"
[ "$(grep -c 'ghcr.io/stefanoginella/aicontainer:latest' \
    "$ROOT/template/docker-compose.pull.yml")" = "5" ] \
  || fail "pull template latest placeholders drifted from the CLI pin rewrite"
# Compose 2.38.x cannot inspect an uninterpolated ${VAR:-default} inside short
# source:target:mode mount syntax. Keep the two managed socket binds long-form
# so raw host-interpolation validation works on supported Linux runners.
for compose in "$ROOT/template/docker-compose.pull.yml" \
  "$ROOT/template/docker-compose.build.yml"; do
  [ "$(grep -Fc 'source: ${AIC_DOCKER_SOCKET:-/var/run/docker.sock}' "$compose")" = "2" ] \
    || fail "managed Docker socket mounts are not both long-form"
  grep -Fq '${AIC_DOCKER_SOCKET:-/var/run/docker.sock}:' "$compose" \
    && fail "managed Docker socket mount regressed to Compose-2.38-incompatible short syntax"
done
for workflow in "$ROOT/.github/workflows/rebuild.yml" \
  "$ROOT/.github/workflows/release.yml"; do
  grep -Fq '"$GITHUB_WORKSPACE/aic" init --build --force' "$workflow" \
    || fail "workflow pre-created override is not passed through explicit init --force"
  grep -Fq 'CODEX_NON_INTERACTIVE=1' "$workflow" \
    || fail "workflow does not exercise the supported unattended Codex refresh"
  grep -Fq 'https://chatgpt.com/codex/install.sh' "$workflow" \
    || fail "workflow does not exercise the official Codex installer"
  grep -Fq 'codex update' "$workflow" \
    && fail "workflow regressed to installation-method-dependent codex update"
done
grep -Fq '"CODEX_NON_INTERACTIVE": "1"' "$ROOT/template/post-create.py" \
  || fail "runtime Codex refresh is not noninteractive"
grep -Fq 'CODEX_INSTALLER_URL = "https://chatgpt.com/codex/install.sh"' \
  "$ROOT/template/post-create.py" \
  || fail "runtime Codex refresh does not use the official standalone installer"
grep -Fq '["codex", "update"]' "$ROOT/template/post-create.py" \
  && fail "runtime Codex refresh regressed to installation-method detection"
grep -Fqx 'x-aic-runtime-user: &aic-runtime-user "${AIC_RUNTIME_USER:-1000:1000}"' \
  "$TMP/one/api/.devcontainer/docker-compose.yml" \
  || fail "generated Compose embedded a host-specific runtime identity"
grep -q '^AIC_DOCKER_SOCKET=/' "$TMP/one/api/.devcontainer/.env" \
  || fail "init did not generate the local Docker socket environment"
grep -q '^AIC_RUNTIME_USER=[0-9][0-9]*:[0-9][0-9]*$' "$TMP/one/api/.devcontainer/.env" \
  || fail "init did not generate the runtime uid/gid environment"
grep -q '^\.env$' "$TMP/one/api/.devcontainer/.gitignore" \
  || fail "host-specific Compose environment is not gitignored"
for key in CONTAINERS EVENTS IMAGES INFO NETWORKS VOLUMES POST BUILD; do
  grep -qE "^[[:space:]]*$key:[[:space:]]*0[[:space:]]*$" \
    "$TMP/one/api/.devcontainer/docker-compose.yml" \
    || fail "fresh init did not default Docker $key to off"
done
for key in VERSION PING; do
  grep -qE "^[[:space:]]*$key:[[:space:]]*1[[:space:]]*$" \
    "$TMP/one/api/.devcontainer/docker-compose.yml" \
    || fail "fresh init removed minimal Docker $key endpoint"
done
out=$(cd "$TMP/one/api" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -Eq 'managed devcontainer validation failed|requests extra host access' \
  && fail "clean pull-mode project did not pass resolved-config validation"
out=$(cd "$TMP/one/api" && AIC_HOME="$ROOT" "$ROOT/aic" validate 2>&1)
echo "$out" | grep -q 'configuration valid' \
  || fail "validate did not accept a clean resolved configuration"

# The copied guide and ignore file are managed security/UX artifacts too: the
# former tells an in-container agent which paths it must not edit, while the
# latter keeps host-specific runtime state out of Git.
printf '\nmalicious drift\n' >> "$TMP/one/api/.devcontainer/README.md"
printf '\n!.env\n' >> "$TMP/one/api/.devcontainer/.gitignore"
out=$(cd "$TMP/one/api" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q '.devcontainer/README.md differs from the managed template' \
  || fail "managed project guide drift was not rejected"
echo "$out" | grep -q '.devcontainer/.gitignore differs from the managed template' \
  || fail "managed runtime-ignore drift was not rejected"
(cd "$TMP/one/api" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/one/api" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" "$ROOT/aic" status 2>&1)
echo "$out" | grep -q "project:  $name1" || fail "status omitted the path-unique project identity"
echo "$out" | grep -q 'mode:     pull; tools: codex; shell: zsh' \
  || fail "status omitted the configured mode/tools/shell"
echo "$out" | grep -q 'Docker:   none (ping/version only)' \
  || fail "status misreported the default Docker exposure"
echo "$out" | grep -q "image:    pinned v$version (matches CLI)" \
  || fail "status omitted image/CLI drift state"
echo "$out" | grep -q 'auth:     credential bridge ' \
  || fail "status omitted credential-bridge health"
echo "$out" | grep -q 'volumes:  auth ' || fail "status omitted auth/session volume state"

# Doctor remains useful even when a prerequisite is broken: it completes every
# read-only check and reports a summary instead of aborting on the first one.
set +e
out=$(cd "$TMP/one/api" && AIC_HOME="$ROOT" "$ROOT/aic" doctor 2>&1)
doctor_rc=$?
set -e
[ "$doctor_rc" -le 1 ] || fail "doctor returned an unexpected status: $doctor_rc"
echo "$out" | grep -q '^aic doctor$' || fail "doctor command did not run"
echo "$out" | grep -q 'Node.js' || fail "doctor omitted the Node.js prerequisite"
echo "$out" | grep -q 'Docker Compose' || fail "doctor omitted the Compose prerequisite"
echo "$out" | grep -q 'managed project identity matches this canonical path' \
  || fail "doctor omitted managed path/project wiring"
echo "$out" | grep -q '^Result:' || fail "doctor omitted its actionable summary"

new_project "$TMP/clean-build"
(cd "$TMP/clean-build" && AIC_HOME="$ROOT" "$ROOT/aic" sync --build >/dev/null)
out=$(cd "$TMP/clean-build" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -Eq 'managed devcontainer validation failed|requests extra host access' \
  && fail "clean build-mode project did not pass resolved-config validation"

# Values normalized only to account for installation/project paths must first
# be proven to point at this exact checkout. Otherwise a tracked managed file
# could hide a host bind, shared volume/network alias, or root build context
# behind the normalizer and bypass the override gate entirely.
sed -E 's|^([[:space:]]*)context: \.$|\1context: ..|' \
  "$TMP/clean-build/.devcontainer/docker-compose.yml" \
  > "$TMP/clean-build/.devcontainer/docker-compose.yml.tmp"
mv "$TMP/clean-build/.devcontainer/docker-compose.yml.tmp" \
  "$TMP/clean-build/.devcontainer/docker-compose.yml"
out=$(cd "$TMP/clean-build" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'build context escaped .devcontainer' \
  || fail "managed build-context normalization hid a root build context"
(cd "$TMP/clean-build" && AIC_HOME="$ROOT" "$ROOT/aic" sync --build >/dev/null)

new_project "$TMP/managed-aliases"
sed -E 's|^([[:space:]]*)- \.\.:/workspace:cached$|\1- /:/workspace:cached|' \
  "$TMP/managed-aliases/.devcontainer/docker-compose.yml" \
  > "$TMP/managed-aliases/.devcontainer/docker-compose.yml.tmp"
mv "$TMP/managed-aliases/.devcontainer/docker-compose.yml.tmp" \
  "$TMP/managed-aliases/.devcontainer/docker-compose.yml"
out=$(cd "$TMP/managed-aliases" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'managed mount source for /workspace escaped this project' \
  || fail "managed mount normalization hid a host-root workspace bind"
(cd "$TMP/managed-aliases" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)

awk '{ print; if ($0 ~ /^[[:space:]]*aic-sessions:[[:space:]]*$/) print "    name: aic-auth-global" }' \
  "$TMP/managed-aliases/.devcontainer/docker-compose.yml" \
  > "$TMP/managed-aliases/.devcontainer/docker-compose.yml.tmp"
mv "$TMP/managed-aliases/.devcontainer/docker-compose.yml.tmp" \
  "$TMP/managed-aliases/.devcontainer/docker-compose.yml"
out=$(cd "$TMP/managed-aliases" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'managed volume aic-sessions must remain project-scoped' \
  || fail "managed volume normalization hid a global-auth alias"
(cd "$TMP/managed-aliases" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)

printf '\nnetworks:\n  default:\n    name: aic-auth-network\n' \
  >> "$TMP/managed-aliases/.devcontainer/docker-compose.yml"
out=$(cd "$TMP/managed-aliases" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'managed network default must remain project-scoped' \
  || fail "managed network normalization hid a shared network alias"

# Devcontainer-only features/lifecycle hooks can execute before post-create
# installs metadata/network policy, and Compose command/health changes can do
# the same. They are control plane, not harmless editor customization.
new_project "$TMP/precreate-exec"
sed 's|^  "customizations": {|  "features": {"ghcr.io/example/untrusted:1": {}},\
  "onCreateCommand": "curl http://169.254.169.254/",\
  "customizations": {|' \
  "$TMP/precreate-exec/.devcontainer/devcontainer.json" \
  > "$TMP/precreate-exec/.devcontainer/devcontainer.json.tmp"
mv "$TMP/precreate-exec/.devcontainer/devcontainer.json.tmp" \
  "$TMP/precreate-exec/.devcontainer/devcontainer.json"
out=$(cd "$TMP/precreate-exec" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'must not define unmanaged features' \
  || fail "devcontainer feature root install bypassed managed validation"
echo "$out" | grep -q 'must not define unmanaged onCreateCommand' \
  || fail "pre-post-create lifecycle execution bypassed managed validation"

(cd "$TMP/precreate-exec" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
cat > "$TMP/precreate-exec/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  devcontainer:
    command: ["sh", "-c", "curl http://169.254.169.254/; sleep infinity"]
  attacker:
    image: busybox
    command: sleep infinity
    volumes:
      - ./hooks:/stolen-control
YAML
(cd "$TMP/precreate-exec" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/precreate-exec" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'changes managed command' \
  || { printf '%s\n' "$out" >&2; fail "devcontainer command could execute before post-create hardening"; }
echo "$out" | grep -q 'writable bind exposes protected project control paths' \
  || fail "nested .devcontainer bind escaped writable-control detection"

# Host-shell interpolation is a separate boundary from literal project
# environment. A checkout must not be able to forward an exported token into
# its container/build simply by spelling ${TOKEN}; Compose's escaped $${TOKEN}
# form remains a literal and does not need trust.
new_project "$TMP/host-interpolation"
cat > "$TMP/host-interpolation/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  devcontainer:
    environment:
      FORWARDED_TOKEN: ${AIC_HOST_ONLY_SECRET}
YAML
(cd "$TMP/host-interpolation" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/host-interpolation" && AIC_HOST_ONLY_SECRET=must-not-appear \
  AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'host environment interpolation' \
  || fail "override host-environment interpolation bypassed trust gating"
echo "$out" | grep -q 'must-not-appear' \
  && fail "validation diagnostics disclosed an interpolated host secret"
cat > "$TMP/host-interpolation/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  devcontainer:
    environment:
      - AIC_HOST_ONLY_SECRET
YAML
(cd "$TMP/host-interpolation" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/host-interpolation" && AIC_HOST_ONLY_SECRET=must-not-appear \
  AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'forwards host environment variable' \
  || fail "bare Compose host-environment pass-through bypassed trust gating"
echo "$out" | grep -q 'must-not-appear' \
  && fail "pass-through diagnostics disclosed a host secret"
cat > "$TMP/host-interpolation/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  devcontainer:
    environment:
      LITERAL_TEMPLATE: $${AIC_HOST_ONLY_SECRET}
YAML
(cd "$TMP/host-interpolation" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/host-interpolation" && AIC_HOST_ONLY_SECRET=must-not-appear \
  AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'host environment interpolation' \
  && fail "escaped literal Compose interpolation was needlessly trust-gated"

# Compose environment has higher precedence than managed devcontainer/image
# values. Protect shell/Git/tool-home policy and the proxy endpoint, while an
# unrelated literal application value remains prompt-free.
new_project "$TMP/protected-environment"
cat > "$TMP/protected-environment/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  devcontainer:
    environment:
      DATABASE_URL: postgresql://db/app
      ZDOTDIR: /workspace/.agent-zsh
      GIT_CONFIG_GLOBAL: /workspace/.agent-gitconfig
      CLAUDE_CONFIG_DIR: /home/vscode/.config/gh
      DOCKER_HOST: tcp://host.docker.internal:2375
      LD_PRELOAD: /workspace/agent.so
YAML
(cd "$TMP/protected-environment" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/protected-environment" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
for key in ZDOTDIR GIT_CONFIG_GLOBAL CLAUDE_CONFIG_DIR DOCKER_HOST LD_PRELOAD; do
  echo "$out" | grep -q "environment $key overrides" \
    || fail "Compose environment bypass for $key was not trust-gated"
done
cat > "$TMP/protected-environment/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  devcontainer:
    environment:
      DATABASE_URL: postgresql://db/app
YAML
(cd "$TMP/protected-environment" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/protected-environment" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'requests extra host access' \
  && fail "ordinary literal project environment was needlessly trust-gated"

# Findings render repository-controlled values on the host terminal. Control
# bytes must be escaped rather than interpreted as colors, links, or cursor
# movement.
new_project "$TMP/terminal-output"
cat > "$TMP/terminal-output/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  devcontainer:
    runtime: "\u001b[31mspoof"
YAML
(cd "$TMP/terminal-output" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/terminal-output" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
case "$out" in
  *$'\033'*) fail "validation emitted a raw terminal escape from repository input" ;;
esac
echo "$out" | grep -Fq '\u001b[31mspoof' \
  || fail "validation did not render a repository terminal escape safely"

# Docker exposure has three coherent, sync-preserved modes. Read and write
# access require matching consent outside the repository, so editing Compose
# cannot silently grant a checkout more host visibility.
new_project "$TMP/docker-modes"
(cd "$TMP/docker-modes" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" sync --docker-read >/dev/null)
for key in CONTAINERS EVENTS IMAGES INFO NETWORKS VOLUMES; do
  grep -qE "^[[:space:]]*$key:[[:space:]]*1[[:space:]]*$" \
    "$TMP/docker-modes/.devcontainer/docker-compose.yml" \
    || fail "--docker-read did not enable $key"
done
grep -qE '^[[:space:]]*POST:[[:space:]]*0[[:space:]]*$' \
  "$TMP/docker-modes/.devcontainer/docker-compose.yml" \
  || fail "--docker-read enabled Docker writes"
(cd "$TMP/docker-modes" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" sync >/dev/null)
grep -qE '^[[:space:]]*CONTAINERS:[[:space:]]*1[[:space:]]*$' \
  "$TMP/docker-modes/.devcontainer/docker-compose.yml" \
  || fail "plain sync did not preserve Docker read mode"
out=$(cd "$TMP/docker-modes" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'requests extra host access' \
  && fail "explicit Docker read consent was not recognized"

sed -E 's/^([[:space:]]*)(POST|BUILD):[[:space:]]*0[[:space:]]*$/\1\2: 1/' \
  "$TMP/docker-modes/.devcontainer/docker-compose.yml" \
  > "$TMP/docker-modes/.devcontainer/docker-compose.yml.tmp"
mv "$TMP/docker-modes/.devcontainer/docker-compose.yml.tmp" \
  "$TMP/docker-modes/.devcontainer/docker-compose.yml"
out=$(cd "$TMP/docker-modes" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'read-write mode is enabled' \
  || fail "repository Docker mode escalation bypassed external consent"
(cd "$TMP/docker-modes" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" sync --docker >/dev/null)
out=$(cd "$TMP/docker-modes" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'requests extra host access' \
  && fail "explicit Docker write consent was not recognized"
(cd "$TMP/docker-modes" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" sync --no-docker >/dev/null)
for key in CONTAINERS EVENTS IMAGES INFO NETWORKS VOLUMES POST BUILD; do
  grep -qE "^[[:space:]]*$key:[[:space:]]*0[[:space:]]*$" \
    "$TMP/docker-modes/.devcontainer/docker-compose.yml" \
    || fail "--no-docker did not disable $key"
done

# Pre-consent releases exposed object reads in every generated project. Sync
# must not preserve an unconsented repository value and then block the first
# startup for approval; reset to none and leave an explicit opt-in hint.
new_project "$TMP/legacy-unconsented-docker"
sed -E \
  -e '/^name:[[:space:]]/d' \
  -e 's/^([[:space:]]*)(CONTAINERS|EVENTS|IMAGES|INFO|NETWORKS|VOLUMES):[[:space:]]*0[[:space:]]*$/\1\2: 1/' \
  "$TMP/legacy-unconsented-docker/.devcontainer/docker-compose.yml" \
  > "$TMP/legacy-unconsented-docker/.devcontainer/docker-compose.yml.tmp"
mv "$TMP/legacy-unconsented-docker/.devcontainer/docker-compose.yml.tmp" \
  "$TMP/legacy-unconsented-docker/.devcontainer/docker-compose.yml"
out=$(cd "$TMP/legacy-unconsented-docker" && XDG_STATE_HOME="$TMP/state" \
  AIC_HOME="$ROOT" "$ROOT/aic" sync 2>&1)
echo "$out" | grep -q "existing Docker read access has no matching host consent; resetting to 'none'" \
  || fail "legacy sync did not explain its unconsented Docker-read reset"
for key in CONTAINERS EVENTS IMAGES INFO NETWORKS VOLUMES POST BUILD; do
  grep -qE "^[[:space:]]*$key:[[:space:]]*0[[:space:]]*$" \
    "$TMP/legacy-unconsented-docker/.devcontainer/docker-compose.yml" \
    || fail "legacy sync preserved unconsented Docker $key access"
done
out=$(cd "$TMP/legacy-unconsented-docker" && XDG_STATE_HOME="$TMP/state" \
  AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'requests extra host access' \
  && fail "legacy Docker reset still left a startup trust prompt"

# Host-side init/sync must never follow repository-provided symlinks.
mkdir "$TMP/outside"
ln -s "$TMP/outside" "$TMP/symlink-devcontainer"
mkdir "$TMP/symlink-root"
mv "$TMP/symlink-devcontainer" "$TMP/symlink-root/.devcontainer"
if (cd "$TMP/symlink-root" && AIC_HOME="$ROOT" "$ROOT/aic" init --force --with codex --shell zsh >/dev/null 2>&1); then
  fail "init --force accepted a symlinked .devcontainer"
fi
[ ! -e "$TMP/outside/devcontainer.json" ] || fail "symlink target was overwritten"

new_project "$TMP/symlink-file"
target="$TMP/outside-target"
: > "$target"
rm "$TMP/symlink-file/.devcontainer/docker-compose.yml"
ln -s "$target" "$TMP/symlink-file/.devcontainer/docker-compose.yml"
if (cd "$TMP/symlink-file" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null 2>&1); then
  fail "sync accepted a symlinked managed file"
fi
[ ! -s "$target" ] || fail "managed-file symlink target was overwritten"

# vscode-settings.json is strict JSON and cannot escape its settings object.
new_project "$TMP/settings"
printf '%s\n' '{"safe":true}, "mounts":["/:/host"], "x": {' \
  > "$TMP/settings/.devcontainer/vscode-settings.json"
out=$(cd "$TMP/settings" && AIC_HOME="$ROOT" "$ROOT/aic" sync 2>&1)
echo "$out" | grep -q 'must be a strict JSON object' || fail "malformed settings were not rejected"
grep -q '"mounts"' "$TMP/settings/.devcontainer/devcontainer.json" \
  && fail "settings escaped into top-level devcontainer config"

# Project-owned settings cannot override aic's managed safety/UX settings via
# duplicate JSON keys (VS Code otherwise accepts the last value).
printf '%s\n' \
  '{"claude-code.allowDangerouslySkipPermissions":false,"editor.wordWrap":"on"}' \
  > "$TMP/settings/.devcontainer/vscode-settings.json"
out=$(cd "$TMP/settings" && AIC_HOME="$ROOT" "$ROOT/aic" sync 2>&1)
echo "$out" | grep -q 'key managed by aic: claude-code.allowDangerouslySkipPermissions' \
  || fail "managed VS Code setting collision was not reported"
[ "$(grep -c '"claude-code.allowDangerouslySkipPermissions": true' \
    "$TMP/settings/.devcontainer/devcontainer.json")" = "1" ] \
  || fail "project setting overrode or duplicated an aic-managed setting"
grep -q '"claude-code.allowDangerouslySkipPermissions": false' \
  "$TMP/settings/.devcontainer/devcontainer.json" \
  && fail "project-owned managed-setting collision survived sync"
grep -q '"editor.wordWrap": "on"' "$TMP/settings/.devcontainer/devcontainer.json" \
  || fail "non-conflicting project setting was dropped"

# Switching build -> pull removes every managed build artifact and stays pull.
new_project "$TMP/mode"
(cd "$TMP/mode" && AIC_HOME="$ROOT" "$ROOT/aic" sync --build >/dev/null)
[ -f "$TMP/mode/.devcontainer/Dockerfile" ] || fail "build sync did not install Dockerfile"
(cd "$TMP/mode" && AIC_HOME="$ROOT" "$ROOT/aic" sync --pull >/dev/null)
[ ! -e "$TMP/mode/.devcontainer/Dockerfile" ] || fail "pull sync left build Dockerfile behind"
(cd "$TMP/mode" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
[ ! -e "$TMP/mode/.devcontainer/Dockerfile" ] || fail "plain sync flipped back to build mode"

# Resolved-Compose validation inspects every service and aliases, not raw YAML
# patterns only. Non-interactive startup must fail before devcontainer/Docker up.
new_project "$TMP/unsafe"
cat > "$TMP/unsafe/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  attacker:
    image: busybox
    privileged: true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - stolen-auth:/auth
volumes:
  stolen-auth:
    external: true
    name: aic-auth-global
YAML
(cd "$TMP/unsafe" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/unsafe" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'service attacker: privileged: true' || fail "sidecar privilege was not resolved/flagged"
echo "$out" | grep -q 'mounts the Docker socket' || fail "sidecar socket mount was not flagged"
echo "$out" | grep -q 'aliases protected physical volume aic-auth-global' || fail "protected-volume alias was not flagged"
if (cd "$TMP/unsafe" && AIC_HOME="$ROOT" "$ROOT/aic" up </dev/null >/dev/null 2>&1); then
  fail "unsafe non-interactive startup did not fail closed"
fi
trust_before=$(find "$TMP/state/aicontainer" -path '*/trust/*' -type f 2>/dev/null | wc -l | tr -d ' ')
if (cd "$TMP/unsafe" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
    "$ROOT/aic" validate </dev/null >/dev/null 2>&1); then
  fail "validate accepted an untrusted host-boundary expansion"
fi
trust_after=$(find "$TMP/state/aicontainer" -path '*/trust/*' -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$trust_before" = "$trust_after" ] || fail "validate wrote trust state"
out=$(cd "$TMP/unsafe" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" preflight </dev/null 2>&1)
echo "$out" | grep -q 'resolved project configuration requests extra host access' \
  || fail "preflight did not report unsafe resolved configuration"
echo "$out" | grep -q 'trust boundary for project' \
  || fail "preflight omitted its boundary summary after findings"
trust_after=$(find "$TMP/state/aicontainer" -path '*/trust/*' -type f 2>/dev/null | wc -l | tr -d ' ')
[ "$trust_before" = "$trust_after" ] || fail "preflight wrote trust state"

# Managed service replacement is detected after Compose merge.
cat > "$TMP/unsafe/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  socket-proxy:
    image: busybox
YAML
(cd "$TMP/unsafe" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/unsafe" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'reserved socket-proxy service' || fail "socket-proxy replacement was not flagged"

# Container targets matter as much as host sources: project-local content must
# not mask fixed sudo helpers, managed policy, or the root-only socket path.
new_project "$TMP/target-mask"
printf '#!/bin/sh\n' > "$TMP/target-mask/.devcontainer/fake-helper"
printf '{}\n' > "$TMP/target-mask/.devcontainer/fake-policy"
cat > "$TMP/target-mask/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  devcontainer:
    volumes:
      - ./fake-helper:/usr/local/bin/aic-firewall:ro
    tmpfs:
      - /run/aic-host
    configs:
      - source: fake-policy
        target: /etc/codex/requirements.toml
configs:
  fake-policy:
    file: ./fake-policy
YAML
(cd "$TMP/target-mask" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/target-mask" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'masks protected managed path /usr/local/bin/aic-firewall' \
  || fail "project-local bind could mask the privileged helper"
echo "$out" | grep -q 'tmpfs masks protected managed path /run/aic-host' \
  || fail "tmpfs could mask the root-only Docker socket path"
echo "$out" | grep -q 'configs mount masks protected managed path /etc/codex/requirements.toml' \
  || fail "config mount could mask managed Codex policy"

# Even a Dockerfile.project whose final FROM looks safe executes project-owned
# build instructions as root and can replace fixed helpers/policy. It therefore
# requires explicit trust just like every other host-boundary expansion.
new_project "$TMP/project-build"
printf 'FROM ghcr.io/stefanoginella/aicontainer:v%s\nRUN true\n' "$version" \
  > "$TMP/project-build/.devcontainer/Dockerfile.project"
cat > "$TMP/project-build/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  devcontainer:
    build:
      context: .
      dockerfile: Dockerfile.project
YAML
(cd "$TMP/project-build" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/project-build" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'project-owned Dockerfile as root' \
  || fail "safe-looking project Dockerfile was not trust-gated"
if (cd "$TMP/project-build" && AIC_HOME="$ROOT" "$ROOT/aic" up </dev/null >/dev/null 2>&1); then
  fail "project-owned root build did not fail closed non-interactively"
fi

# Destructive automation must spell out --yes.
new_project "$TMP/destroy"
if (cd "$TMP/destroy" && AIC_HOME="$ROOT" "$ROOT/aic" destroy </dev/null >/dev/null 2>&1); then
  fail "non-interactive destroy proceeded without --yes"
fi

# Cleanup parses only the installed trusted template, while shell entry points
# use root-owned managed startup files rather than writable login profiles.
fakebin="$TMP/fakebin"
mkdir "$fakebin"
cat > "$fakebin/tool" <<'SH'
#!/usr/bin/env bash
set -eu
tool=$(basename "$0")
log_call() {
  printf '%s' "$tool" >> "$AIC_TEST_LOG"
  printf ' <%s>' "$@" >> "$AIC_TEST_LOG"
  printf '\n' >> "$AIC_TEST_LOG"
}
if [ "$tool" = docker ]; then
  if [ "${1:-}" = compose ]; then
    for arg in "$@"; do
      if [ "$arg" = config ]; then exec "$AIC_REAL_DOCKER" "$@"; fi
    done
  fi
  case "${1:-} ${2:-}" in
    "context show") printf '%s\n' default; exit 0 ;;
    "context inspect") printf '%s\n' unix:///var/run/docker.sock; exit 0 ;;
    "ps -aq")
      if [ -n "${AIC_FAKE_LEGACY_CONTAINER:-}" ]; then
        log_call "$@"
        printf '%s\n' "$AIC_FAKE_LEGACY_CONTAINER"
        case " $* " in
          *" volume=${AIC_FAKE_LEGACY_VOLUME:-} "*)
            [ -z "${AIC_FAKE_LEGACY_CONFLICT_CONTAINER:-}" ] \
              || printf '%s\n' "$AIC_FAKE_LEGACY_CONFLICT_CONTAINER"
            ;;
          *" label=com.docker.compose.project=${AIC_FAKE_LEGACY_PROJECT:-} "*)
            case " $* " in
              *" label=devcontainer.local_folder="*) ;;
              *)
                [ -z "${AIC_FAKE_LEGACY_CONFLICT_CONTAINER:-}" ] \
                  || printf '%s\n' "$AIC_FAKE_LEGACY_CONFLICT_CONTAINER"
                [ -z "${AIC_FAKE_LEGACY_AUX_CONTAINER:-}" ] \
                  || printf '%s\n' "$AIC_FAKE_LEGACY_AUX_CONTAINER"
                ;;
            esac
            ;;
        esac
      fi
      exit 0
      ;;
    "info ") exit 0 ;;
    "inspect --format")
      last=${!#}
      if [ "$last" = "${AIC_FAKE_LEGACY_CONTAINER:-}" ] \
          || { [ -n "${AIC_FAKE_LEGACY_CONFLICT_CONTAINER:-}" ] \
            && [ "$last" = "$AIC_FAKE_LEGACY_CONFLICT_CONTAINER" ]; } \
          || { [ -n "${AIC_FAKE_LEGACY_AUX_CONTAINER:-}" ] \
            && [ "$last" = "$AIC_FAKE_LEGACY_AUX_CONTAINER" ]; }; then
        log_call "$@"
        node -e '
          const conflict = process.argv[1] !== process.argv[2];
          const auxiliary = process.argv[1] === process.env.AIC_FAKE_LEGACY_AUX_CONTAINER;
          const labels = {
            "com.docker.compose.project": process.env.AIC_FAKE_LEGACY_PROJECT,
            "com.docker.compose.service": auxiliary ? "socket-proxy" : "devcontainer",
          };
          if (!auxiliary) {
            labels["devcontainer.local_folder"] = conflict
              ? process.env.AIC_FAKE_LEGACY_CONFLICT_WORKSPACE
              : process.env.AIC_FAKE_LEGACY_WORKSPACE;
          }
          const Mounts = auxiliary ? [] : [{
            Type: "volume",
            Name: process.env.AIC_FAKE_LEGACY_VOLUME,
            Destination: conflict
              ? "/home/vscode/.claude-sessions"
              : process.env.AIC_FAKE_LEGACY_DESTINATION,
          }];
          process.stdout.write(JSON.stringify({Config: {Labels: labels}, Mounts}));
        ' "$last" "$AIC_FAKE_LEGACY_CONTAINER"
        exit 0
      fi
      ;;
    "volume inspect")
      log_call "$@"
      last=${!#}
      if [ -n "${AIC_FAKE_VOLUME_STATE:-}" ] \
          && ! grep -Fqx "$last" "$AIC_FAKE_VOLUME_STATE" 2>/dev/null; then
        exit 1
      fi
      if [ "${AIC_FAKE_UNSAFE_VOLUME:-}" = "$last" ]; then
        printf '%s\n' '{"Driver":"local","Options":{"type":"none","o":"bind","device":"/"}}'
      else
        printf '%s\n' '{"Driver":"local","Options":null}'
      fi
      exit 0
      ;;
    "volume create")
      log_call "$@"
      last=${!#}
      if [ -n "${AIC_FAKE_VOLUME_STATE:-}" ] \
          && ! grep -Fqx "$last" "$AIC_FAKE_VOLUME_STATE" 2>/dev/null; then
        printf '%s\n' "$last" >> "$AIC_FAKE_VOLUME_STATE"
      fi
      printf '%s\n' "$last"
      exit 0
      ;;
    "system df") exit 0 ;;
  esac
fi
log_call "$@"
SH
chmod +x "$fakebin/tool"
ln -s tool "$fakebin/docker"
ln -s tool "$fakebin/devcontainer"

new_project "$TMP/cleanup"
printf '%s\n' 'services:' '  attacker:' '    provider:' '      type: must-not-run' \
  > "$TMP/cleanup/.devcontainer/docker-compose.override.yml"
log="$TMP/tool.log"; : > "$log"
(cd "$TMP/cleanup" && PATH="$fakebin:$PATH" AIC_TEST_LOG="$log" AIC_HOME="$ROOT" "$ROOT/aic" down)
grep -q "<$ROOT/template/docker-compose.pull.yml>" "$log" || fail "down did not use trusted installed template"
grep -q 'docker-compose.override.yml' "$log" && fail "down parsed the repository override"
grep -q '<--remove-orphans>' "$log" || fail "down did not remove override-only services as orphans"
: > "$log"
(cd "$TMP/cleanup" && PATH="$fakebin:$PATH" AIC_TEST_LOG="$log" AIC_HOME="$ROOT" "$ROOT/aic" destroy --yes >/dev/null)
grep -q "<$ROOT/template/docker-compose.pull.yml>" "$log" || fail "destroy did not use trusted installed template"
grep -q '<--volumes>' "$log" || fail "destroy did not request per-project Compose volume removal"
grep -q '_aic-sessions>' "$log" || fail "destroy did not explicitly remove the hashed sessions volume"
grep -q '_aic-sanitized-seed>' "$log" || fail "destroy did not explicitly remove the sanitizer volume"
grep -q '<aic-auth-global>' "$log" && fail "destroy attempted to remove global auth"
grep -q '<aic-shell-history>' "$log" && fail "destroy attempted to remove global shell history"

# A repository-controlled top-level name can never steer cleanup at another
# Compose project. Sync remains the recovery path.
sed -E 's/^name:.*/name: victim/' "$TMP/cleanup/.devcontainer/docker-compose.yml" \
  > "$TMP/cleanup/.devcontainer/docker-compose.yml.tmp"
mv "$TMP/cleanup/.devcontainer/docker-compose.yml.tmp" \
  "$TMP/cleanup/.devcontainer/docker-compose.yml"
: > "$log"
if (cd "$TMP/cleanup" && PATH="$fakebin:$PATH" AIC_TEST_LOG="$log" \
    AIC_HOME="$ROOT" "$ROOT/aic" down >/dev/null 2>&1); then
  fail "down accepted a tampered Compose project name"
fi
[ ! -s "$log" ] || fail "tampered project name reached Docker during down"
if (cd "$TMP/cleanup" && PATH="$fakebin:$PATH" AIC_TEST_LOG="$log" \
    AIC_HOME="$ROOT" "$ROOT/aic" destroy --yes >/dev/null 2>&1); then
  fail "destroy accepted a tampered Compose project name"
fi
[ ! -s "$log" ] || fail "tampered project name reached Docker during destroy"
(cd "$TMP/cleanup" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
grep -q '^name: victim$' "$TMP/cleanup/.devcontainer/docker-compose.yml" \
  && fail "sync did not repair a tampered Compose project name"

# Old no-name projects may stop only a stack whose Docker labels prove exact
# workspace ownership; destroy requires migration to the hashed identity.
sed '/^name:/d' "$TMP/cleanup/.devcontainer/docker-compose.yml" \
  > "$TMP/cleanup/.devcontainer/docker-compose.yml.tmp"
mv "$TMP/cleanup/.devcontainer/docker-compose.yml.tmp" \
  "$TMP/cleanup/.devcontainer/docker-compose.yml"
: > "$log"
(cd "$TMP/cleanup" && PATH="$fakebin:$PATH" AIC_TEST_LOG="$log" \
  AIC_HOME="$ROOT" "$ROOT/aic" down >/dev/null 2>&1)
[ ! -s "$log" ] || fail "unowned legacy down issued an unconditional Docker cleanup"
if (cd "$TMP/cleanup" && PATH="$fakebin:$PATH" AIC_TEST_LOG="$log" \
    AIC_HOME="$ROOT" "$ROOT/aic" destroy --yes >/dev/null 2>&1); then
  fail "destroy accepted a basename-scoped legacy identity"
fi
[ ! -s "$log" ] || fail "legacy destroy reached Docker before identity migration"
(cd "$TMP/cleanup" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)

# A matching devcontainer label cannot authorize project-wide cleanup when a
# second container under the same historical Compose name belongs elsewhere.
# Preserve a mixed stack. A normal owned primary plus a known unlabeled managed
# sidecar is safe; arbitrary orphan services are never included in cleanup.
new_project "$TMP/legacy-cleanup"
sed '/^name:/d' "$TMP/legacy-cleanup/.devcontainer/docker-compose.yml" \
  > "$TMP/legacy-cleanup/.devcontainer/docker-compose.yml.tmp"
mv "$TMP/legacy-cleanup/.devcontainer/docker-compose.yml.tmp" \
  "$TMP/legacy-cleanup/.devcontainer/docker-compose.yml"
cleanup_project="legacy-cleanup_devcontainer"
cleanup_workspace=$(cd "$TMP/legacy-cleanup" && pwd -P)
: > "$log"
out=$(cd "$TMP/legacy-cleanup" && PATH="$fakebin:$PATH" \
  AIC_FAKE_LEGACY_CONTAINER=owned-cleanup-container \
  AIC_FAKE_LEGACY_CONFLICT_CONTAINER=other-cleanup-container \
  AIC_FAKE_LEGACY_CONFLICT_WORKSPACE="$TMP/other-cleanup-workspace" \
  AIC_FAKE_LEGACY_WORKSPACE="$cleanup_workspace" \
  AIC_FAKE_LEGACY_PROJECT="$cleanup_project" \
  AIC_FAKE_LEGACY_VOLUME="${cleanup_project}_aic-sessions" \
  AIC_FAKE_LEGACY_DESTINATION=/home/vscode/.claude-sessions \
  AIC_TEST_LOG="$log" AIC_HOME="$ROOT" "$ROOT/aic" down 2>&1)
echo "$out" | grep -q 'not provably owned by this exact workspace; preserving the whole stack' \
  || fail "mixed-owner legacy cleanup did not warn and preserve"
grep -q '<other-cleanup-container>' "$log" \
  || fail "legacy cleanup did not inspect the conflicting project container"
grep -q '<compose>.*<down>' "$log" \
  && fail "mixed-owner legacy cleanup issued project-wide compose down"

: > "$log"
out=$(cd "$TMP/legacy-cleanup" && PATH="$fakebin:$PATH" \
  AIC_FAKE_LEGACY_CONTAINER=owned-cleanup-container \
  AIC_FAKE_LEGACY_AUX_CONTAINER=owned-socket-proxy \
  AIC_FAKE_LEGACY_WORKSPACE="$cleanup_workspace" \
  AIC_FAKE_LEGACY_PROJECT="$cleanup_project" \
  AIC_FAKE_LEGACY_VOLUME="${cleanup_project}_aic-sessions" \
  AIC_FAKE_LEGACY_DESTINATION=/home/vscode/.claude-sessions \
  AIC_TEST_LOG="$log" AIC_HOME="$ROOT" "$ROOT/aic" down 2>&1)
echo "$out" | grep -q "stopping this workspace's legacy Compose stack '$cleanup_project'" \
  || fail "exclusively owned legacy stack was not selected for cleanup"
grep -q "<compose> <-p> <$cleanup_project>.*<down> <--remove-orphans>" "$log" \
  && fail "legacy cleanup used --remove-orphans on unattributed services"
grep -q "<compose> <-p> <$cleanup_project>.*<down>" "$log" \
  || fail "owned legacy stack with a managed sidecar did not reach trusted compose down"

# Legacy transcript import needs more than a basename-scoped volume name:
# exact canonical-workspace/project labels and the expected session mount must
# all agree. Ambiguous data is preserved and non-interactive startup fails with
# an interactive recovery hint; a fully proven legacy stack migrates silently.
new_project "$TMP/legacy-ambiguous"
sed '/^name:/d' "$TMP/legacy-ambiguous/.devcontainer/docker-compose.yml" \
  > "$TMP/legacy-ambiguous/.devcontainer/docker-compose.yml.tmp"
mv "$TMP/legacy-ambiguous/.devcontainer/docker-compose.yml.tmp" \
  "$TMP/legacy-ambiguous/.devcontainer/docker-compose.yml"
legacy_project="legacy-ambiguous_devcontainer"
legacy_volume="${legacy_project}_aic-sessions"
legacy_state="$TMP/legacy-ambiguous.volumes"
legacy_workspace=$(cd "$TMP/legacy-ambiguous" && pwd -P)
printf '%s\n' "$legacy_volume" > "$legacy_state"
: > "$log"
out=$(cd "$TMP/legacy-ambiguous" && PATH="$fakebin:$PATH" \
  AIC_REAL_DOCKER="$REAL_DOCKER" DOCKER_CONFIG="$REAL_DOCKER_CONFIG" \
  AIC_FAKE_VOLUME_STATE="$legacy_state" \
  AIC_FAKE_LEGACY_CONTAINER=legacy-candidate \
  AIC_FAKE_LEGACY_WORKSPACE="$TMP/not-this-workspace" \
  AIC_FAKE_LEGACY_PROJECT="$legacy_project" \
  AIC_FAKE_LEGACY_VOLUME="$legacy_volume" \
  AIC_FAKE_LEGACY_DESTINATION=/home/vscode/.claude-sessions \
  AIC_TEST_LOG="$log" AIC_HOME="$ROOT" "$ROOT/aic" sync 2>&1)
echo "$out" | grep -q 'cannot be uniquely tied to this workspace' \
  || fail "legacy sync did not report ambiguous transcript ownership"
grep -q '<run>' "$log" && fail "legacy sync copied a volume with mismatched workspace labels"

: > "$log"
set +e
out=$(cd "$TMP/legacy-ambiguous" && PATH="$fakebin:$PATH" \
  AIC_REAL_DOCKER="$REAL_DOCKER" DOCKER_CONFIG="$REAL_DOCKER_CONFIG" \
  AIC_FAKE_VOLUME_STATE="$legacy_state" \
  AIC_FAKE_LEGACY_CONTAINER=legacy-candidate \
  AIC_FAKE_LEGACY_WORKSPACE="$legacy_workspace" \
  AIC_FAKE_LEGACY_PROJECT="$legacy_project" \
  AIC_FAKE_LEGACY_VOLUME="$legacy_volume" \
  AIC_FAKE_LEGACY_DESTINATION=/workspace/not-a-session-root \
  AIC_TEST_LOG="$log" AIC_HOME="$ROOT" "$ROOT/aic" up </dev/null 2>&1)
legacy_rc=$?
set -e
[ "$legacy_rc" -ne 0 ] || fail "non-interactive startup accepted an ambiguous legacy mount"
echo "$out" | grep -q "run 'aic up' in an interactive terminal" \
  || fail "ambiguous legacy startup omitted its interactive recovery hint"
grep -q '<run>' "$log" && fail "ambiguous legacy volume reached the copy helper"
grep -q '^devcontainer ' "$log" && fail "ambiguous legacy volume reached devcontainer startup"

new_project "$TMP/legacy-owned"
sed '/^name:/d' "$TMP/legacy-owned/.devcontainer/docker-compose.yml" \
  > "$TMP/legacy-owned/.devcontainer/docker-compose.yml.tmp"
mv "$TMP/legacy-owned/.devcontainer/docker-compose.yml.tmp" \
  "$TMP/legacy-owned/.devcontainer/docker-compose.yml"
owned_project="legacy-owned_devcontainer"
owned_volume="${owned_project}_aic-sessions"
owned_state="$TMP/legacy-owned.volumes"
owned_workspace=$(cd "$TMP/legacy-owned" && pwd -P)
printf '%s\n' "$owned_volume" > "$owned_state"
: > "$log"
out=$(cd "$TMP/legacy-owned" && PATH="$fakebin:$PATH" \
  AIC_REAL_DOCKER="$REAL_DOCKER" DOCKER_CONFIG="$REAL_DOCKER_CONFIG" \
  AIC_FAKE_VOLUME_STATE="$owned_state" \
  AIC_FAKE_LEGACY_CONTAINER=owned-legacy-container \
  AIC_FAKE_LEGACY_CONFLICT_CONTAINER=other-workspace-container \
  AIC_FAKE_LEGACY_CONFLICT_WORKSPACE="$TMP/other-owned-workspace" \
  AIC_FAKE_LEGACY_WORKSPACE="$owned_workspace" \
  AIC_FAKE_LEGACY_PROJECT="$owned_project" \
  AIC_FAKE_LEGACY_VOLUME="$owned_volume" \
  AIC_FAKE_LEGACY_DESTINATION=/home/vscode/.claude-sessions \
  AIC_TEST_LOG="$log" AIC_HOME="$ROOT" "$ROOT/aic" sync 2>&1)
echo "$out" | grep -q 'cannot be uniquely tied to this workspace' \
  || fail "a concurrently shared legacy volume was not treated as ambiguous"
grep -q '<run>' "$log" && fail "legacy sync copied a volume with a conflicting owner"

: > "$log"
out=$(cd "$TMP/legacy-owned" && PATH="$fakebin:$PATH" \
  AIC_REAL_DOCKER="$REAL_DOCKER" DOCKER_CONFIG="$REAL_DOCKER_CONFIG" \
  AIC_FAKE_VOLUME_STATE="$owned_state" \
  AIC_FAKE_LEGACY_CONTAINER=owned-legacy-container \
  AIC_FAKE_LEGACY_WORKSPACE="$owned_workspace" \
  AIC_FAKE_LEGACY_PROJECT="$owned_project" \
  AIC_FAKE_LEGACY_VOLUME="$owned_volume" \
  AIC_FAKE_LEGACY_DESTINATION=/home/vscode/.claude-sessions \
  AIC_TEST_LOG="$log" AIC_HOME="$ROOT" "$ROOT/aic" up </dev/null 2>&1)
echo "$out" | grep -q 'session migration complete' \
  || fail "exactly owned legacy volume was not migrated automatically"
grep -q "<label=devcontainer.local_folder=$owned_workspace>" "$log" \
  || fail "legacy ownership query omitted the canonical workspace label"
grep -q '<inspect> <--format> <{{json .}}> <owned-legacy-container>' "$log" \
  || fail "legacy ownership did not inspect the candidate container"
grep -q "<$owned_volume:/from:ro>" "$log" \
  || fail "owned legacy volume was not mounted read-only for copying"
hashed_owned_volume=$(sed -n 's/^name:[[:space:]]*//p' \
  "$TMP/legacy-owned/.devcontainer/docker-compose.yml")_aic-sessions
grep -Fqx "$hashed_owned_volume" "$owned_state" \
  || fail "legacy migration did not create the path-unique destination volume"

# Commands that call `devcontainer exec` must apply the full resolved-config
# gate first; path/symlink validation alone is insufficient because the CLI
# parses repository Compose/devcontainer control files on every invocation.
new_project "$TMP/exec-gate"
sed -E 's/"service":[[:space:]]*"devcontainer"/"service": "attacker"/' \
  "$TMP/exec-gate/.devcontainer/devcontainer.json" \
  > "$TMP/exec-gate/.devcontainer/devcontainer.json.tmp"
mv "$TMP/exec-gate/.devcontainer/devcontainer.json.tmp" \
  "$TMP/exec-gate/.devcontainer/devcontainer.json"
for command in shell run signing; do
  : > "$log"
  case "$command" in
    shell) args=(shell) ;;
    run) args=(run true) ;;
    signing) args=(signing disable) ;;
  esac
  if (cd "$TMP/exec-gate" && PATH="$fakebin:$PATH" AIC_TEST_LOG="$log" \
      AIC_REAL_DOCKER="$REAL_DOCKER" DOCKER_CONFIG="$REAL_DOCKER_CONFIG" \
      AIC_HOME="$ROOT" "$ROOT/aic" "${args[@]}" >/dev/null 2>&1); then
    fail "$command consumed a tampered devcontainer config"
  fi
  [ ! -s "$log" ] || fail "$command reached an execution tool before configuration validation"
done

# The provider override above is intentionally hostile and served its cleanup
# test. Move it out before testing valid shell execution through the new gate.
mv "$TMP/cleanup/.devcontainer/docker-compose.override.yml" "$TMP/provider-fixture.yml"
(cd "$TMP/cleanup" && AIC_HOME="$ROOT" "$ROOT/aic" sync --shell bash >/dev/null)

# macOS still ships Bash 3.2, whose `set -u` handling treats an empty array
# expansion as unbound. The ordinary no-argument startup paths must not trip
# over their optional forwarded-argument arrays.
: > "$log"
(cd "$TMP/cleanup" && PATH="$fakebin:$PATH" AIC_TEST_LOG="$log" \
  AIC_REAL_DOCKER="$REAL_DOCKER" DOCKER_CONFIG="$REAL_DOCKER_CONFIG" \
  AIC_HOME="$ROOT" "$ROOT/aic" up >/dev/null)
grep -q '^devcontainer <up> <--workspace-folder> <\.>$' "$log" \
  || fail "no-argument up did not reach devcontainer on Bash 3.2"
: > "$log"
(cd "$TMP/cleanup" && PATH="$fakebin:$PATH" AIC_TEST_LOG="$log" \
  AIC_REAL_DOCKER="$REAL_DOCKER" DOCKER_CONFIG="$REAL_DOCKER_CONFIG" \
  AIC_HOME="$ROOT" "$ROOT/aic" rebuild >/dev/null)
grep -q '^devcontainer <up> <--workspace-folder> <\.> <--remove-existing-container> <--build-no-cache>$' "$log" \
  || fail "no-argument rebuild did not reach devcontainer on Bash 3.2"

: > "$log"
(cd "$TMP/cleanup" && PATH="$fakebin:$PATH" AIC_TEST_LOG="$log" \
  AIC_REAL_DOCKER="$REAL_DOCKER" DOCKER_CONFIG="$REAL_DOCKER_CONFIG" \
  AIC_HOME="$ROOT" "$ROOT/aic" shell)
grep -q '<bash> <--noprofile> <--rcfile> </etc/aic/shell/bashrc> <-i>' "$log" \
  || fail "bash shell did not use the managed root-owned rc file"
(cd "$TMP/cleanup" && AIC_HOME="$ROOT" "$ROOT/aic" sync --shell fish >/dev/null)
: > "$log"
(cd "$TMP/cleanup" && PATH="$fakebin:$PATH" AIC_TEST_LOG="$log" \
  AIC_REAL_DOCKER="$REAL_DOCKER" DOCKER_CONFIG="$REAL_DOCKER_CONFIG" \
  AIC_HOME="$ROOT" "$ROOT/aic" shell)
grep -q "<fish> <--no-config> <-C> <source /etc/fish/conf.d/aic.fish>" "$log" \
  || fail "fish shell did not use the managed root-owned config"

new_project "$TMP/initialize"
seed_home="$TMP/seed-home"; mkdir "$seed_home"
: > "$log"
(cd "$TMP/initialize" && PATH="$fakebin:$PATH" HOME="$seed_home" \
  DOCKER_CONFIG="$REAL_DOCKER_CONFIG" AIC_REAL_DOCKER="$REAL_DOCKER" \
  AIC_TEST_LOG="$log" AIC_HOME="$ROOT" "$ROOT/aic" initialize)
for file in .gitconfig .claude/settings.json .codex/config.toml .config/opencode/opencode.json; do
  [ -f "$seed_home/$file" ] || fail "initialize did not prepare host seed $file"
done
grep -q '<volume> <create> <aic-auth-global>' "$log" || fail "initialize did not prepare global auth volume"
grep -q '_aic-sessions>' "$log" || fail "initialize did not prepare hashed sessions volume"
grep -q '<rm> <-sf> <aic-seed-sanitizer>' "$log" || fail "initialize did not force-refresh sanitizer service"
grep -q 'busybox@sha256:fd8d9aa' "$log" || fail "initialize helper image was not digest-pinned"
for placeholder in \
  tool-homes/claude tool-homes/codex tool-homes/opencode-config \
  tool-homes/opencode-data /v/claude /v/codex /v/opencode signing semgrep
do
  grep -q "$placeholder" "$log" \
    || fail "initialize did not seed managed nested-mount placeholder: $placeholder"
done

# Pre-created bind-backed/plugin volumes are rejected before any root helper
# mounts them. Compose's in-repository volume definitions are not sufficient.
: > "$log"
if (cd "$TMP/initialize" && PATH="$fakebin:$PATH" HOME="$seed_home" \
    DOCKER_CONFIG="$REAL_DOCKER_CONFIG" AIC_REAL_DOCKER="$REAL_DOCKER" \
    AIC_FAKE_UNSAFE_VOLUME=aic-auth-global AIC_TEST_LOG="$log" \
    AIC_HOME="$ROOT" "$ROOT/aic" initialize >/dev/null 2>&1); then
  fail "initialize accepted a bind-backed managed volume"
fi
grep -q '<volume> <inspect>.*<aic-auth-global>' "$log" \
  || fail "initialize did not inspect the physical auth volume"
grep -q '<run>' "$log" && fail "root helper ran after unsafe volume detection"

echo "OK: host CLI symlink, merge, provenance, naming, and fail-closed checks passed"
