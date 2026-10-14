#!/usr/bin/env bash
# Regenerate the JSON fixtures of tests/test-aic-validate.mjs from the current
# template. Run it after a change to template/devcontainer.json or a Compose
# template, then review the diff. It needs Docker Compose 2.35+ but no daemon.
#
# The models are resolved the way validate_project_security() in
# lib/aic/validation.sh resolves them, for a pull-mode project without an
# override. Host values are fixed so the output does not depend on the
# machine: the project root becomes @ROOT@
# (the test puts its own temporary root there), this checkout becomes
# @AIC_HOME@ (the expected model resolves the template's relative paths from
# it), and the Compose name, HOME, runtime user, Docker socket, status relay,
# and image version get constants.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
OUT="$ROOT/tests/fixtures/validate"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Keep the Docker CLI plugins (Compose) that live under the real home.
export DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" XDG_CACHE_HOME="$TMP/cache"
export XDG_CONFIG_HOME="$TMP/config" CI=1 AIC_NO_UPDATE_CHECK=1 AIC_HOME="$ROOT"
unset COMPOSE_PROJECT_NAME COMPOSE_PROFILES COMPOSE_FILE COMPOSE_ENV_FILES \
  COMPOSE_DISABLE_ENV_FILE TZ AIC_DOCKER_SOCKET AIC_RUNTIME_USER AIC_STATUS_RELAY \
  AIC_STATUS_PROJECT AIC_STATUS_PROJECT_ID AIC_PROJECT_NAME
mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"

NAME=aic-fixture-0123456789ab
project="$TMP/fixture"
mkdir -p "$project"
git -C "$project" init -q
(cd "$project" && "$ROOT/aic" init --with claude-code,codex,opencode --shell zsh >/dev/null)
project=$(cd "$project" && /bin/pwd -P)
generated=$(sed -n 's/^AIC_PROJECT_NAME=//p' "$project/.devcontainer/.env")
[ -n "$generated" ] || { echo "no Compose name in the generated .env" >&2; exit 1; }

# The constant host state that the fixtures encode (see .devcontainer/.env).
cat > "$project/.devcontainer/.env" <<ENV
AIC_DOCKER_SOCKET=/var/run/docker.sock
AIC_RUNTIME_USER=1000:1000
AIC_STATUS_RELAY=0
AIC_STATUS_PROJECT=fixture
AIC_STATUS_PROJECT_ID=$NAME
AIC_PROJECT_NAME=$NAME
ENV

# Like aic, export the name: the installed template has no .env next to it.
compose() {
  (cd "$project" && HOME=/home/fixture AIC_PROJECT_NAME="$NAME" docker compose --profile '*' "$@")
}
compose -f .devcontainer/docker-compose.yml config --format json > "$TMP/base.json"
compose -f "$ROOT/template/docker-compose.pull.yml" config --format json > "$TMP/expected.json"
compose -f .devcontainer/docker-compose.yml config --format json --no-env-resolution > "$TMP/noenv.json"
compose -f .devcontainer/docker-compose.yml config --format json --no-env-resolution --no-interpolate \
  > "$TMP/raw-base.json"
cp "$project/.devcontainer/devcontainer.json" "$TMP/devcontainer.json"

version=$(node -p 'require(process.argv[1]).version' "$ROOT/package.json")
for name in base expected noenv raw-base; do
  node -e '
    const fs = require("fs");
    const [file, root, home, generated, name, version] = process.argv.slice(1);
    const text = fs.readFileSync(file, "utf8")
      .split(root).join("@ROOT@")
      .split(home).join("@AIC_HOME@")
      .split(generated).join(name)
      .split(`aicontainer:v${version}`).join("aicontainer:v0.0.0");
    fs.writeFileSync(file, JSON.stringify(JSON.parse(text), null, 2) + "\n");
  ' "$TMP/$name.json" "$project" "$ROOT" "$generated" "$NAME" "$version"
done
if grep -lF -e "$TMP" -e "$ROOT" "$TMP"/*.json; then
  echo "a fixture still holds a host path (listed above)" >&2
  exit 1
fi
for name in devcontainer base expected noenv raw-base; do
  cat "$TMP/$name.json" > "$OUT/$name.json"
done
echo "OK: regenerated tests/fixtures/validate"
