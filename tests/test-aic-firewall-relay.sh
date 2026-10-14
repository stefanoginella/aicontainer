#!/usr/bin/env bash
# The status-relay rule of aic-firewall reads the relay mode from the
# generated .devcontainer/.env on the read-only mount.
#
# - AIC_STATUS_RELAY=1 (the last such line, as Compose reads it) turns the
#   relay rule on. Every other value, a missing file, a symlink, or a
#   directory leaves it off.
# - The mode never comes from the environment or from /proc/1/environ: sudo
#   resets the environment, and /proc/1/environ needs CAP_SYS_PTRACE.
# - The file selects on or off only. The host and the port stay fixed in the
#   helper.
#
# The parser runs on the host: this test sources the helper (its main() runs
# only when it is executed).
# shellcheck disable=SC2016 # the patterns match literal helper text
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIREWALL="$ROOT/template/aic-firewall"
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP=$(mktemp -d)
TMP=$(cd -P "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

# --- Static checks ------------------------------------------------------------
grep -q '/proc/1/environ' <(grep -v '^[[:space:]]*#' "$FIREWALL") \
  && fail "aic-firewall reads /proc/1/environ; it needs CAP_SYS_PTRACE, so the relay rule is never added"
grep -qx 'RUNTIME_ENV_FILE="/workspace/.devcontainer/.env"' "$FIREWALL" \
  || fail "aic-firewall does not read the relay mode from the read-only /workspace/.devcontainer/.env"
grep -qx 'STATUS_RELAY_HOST="host.docker.internal"' "$FIREWALL" \
  || fail "the relay host is not fixed in aic-firewall"
grep -qx 'STATUS_RELAY_PORT=8787' "$FIREWALL" \
  || fail "the relay port is not fixed in aic-firewall"
enable_body=$(sed -n '/^enable_policy() {/,/^}/p' "$FIREWALL")
printf '%s\n' "$enable_body" | grep -q 'status_relay_enabled && relay=1' \
  || fail "enable does not take the relay mode from status_relay_enabled"
rule=$(printf '%s\n' "$enable_body" | grep -n 'accept_set_members_v4 "$out_chain" "$status_set"' || true)
[ "$(printf '%s\n' "$rule" | grep -c .)" = 1 ] \
  || fail "enable must add exactly one status-relay rule"
guard=$(printf '%s\n' "$enable_body" | grep -n 'if \[ "$relay" -eq 1 \]; then' | tail -n1 | cut -d: -f1)
[ -n "$guard" ] && [ "$guard" -eq $(( ${rule%%:*} - 1 )) ] \
  || fail "the status-relay rule is not directly inside the relay=1 check"
case "$rule" in
  *'-p tcp --dport "$STATUS_RELAY_PORT"'*) ;;
  *) fail "the status-relay rule is not TCP 8787 only: $rule" ;;
esac
echo "OK: the relay rule is one fixed TCP rule, gated on the read-only .env"

# shellcheck source=../template/aic-firewall
# shellcheck disable=SC1091
source "$FIREWALL"
set -euo pipefail

# macOS realpath has no -e. Only the checks below use this stand-in; the helper
# runs with GNU realpath in the image.
if ! realpath -e -- / >/dev/null 2>&1; then
  realpath() {
    while [ "$#" -gt 1 ]; do shift; done
    local file="$1" dir
    [ -e "$file" ] || return 1
    dir=$(cd -P -- "$(dirname -- "$file")" && pwd -P) || return 1
    if [ -L "$file" ]; then
      printf '%s/%s\n' "$dir" "$(readlink -- "$file")"
    else
      printf '%s/%s\n' "$dir" "$(basename -- "$file")"
    fi
  }
fi

RUNTIME_ENV_FILE="$TMP/.env"
expect() {
  local want="$1" label="$2"
  if status_relay_enabled 2>/dev/null; then got=on; else got=off; fi
  [ "$got" = "$want" ] || fail "$label: the relay rule is $got, expected $want"
}

# A missing file: no rule. The environment never turns it on.
AIC_STATUS_RELAY=1 expect off "a missing .env with AIC_STATUS_RELAY=1 in the environment"

# The file that aic writes.
printf 'AIC_DOCKER_SOCKET=/var/run/docker.sock\nAIC_RUNTIME_USER=1000:1000\nAIC_STATUS_RELAY=1\nAIC_STATUS_PROJECT=p\nAIC_STATUS_PROJECT_ID=aic-p-1\nAIC_PROJECT_NAME=aic-p-1\n' \
  > "$RUNTIME_ENV_FILE"
expect on "the generated .env with the relay on"
sed 's/^AIC_STATUS_RELAY=1$/AIC_STATUS_RELAY=0/' "$RUNTIME_ENV_FILE" > "$TMP/off" \
  && mv "$TMP/off" "$RUNTIME_ENV_FILE"
AIC_STATUS_RELAY=1 expect off "the generated .env with the relay off"

# Only the exact value 1 counts, and the last line wins (as in Compose).
for value in '' 0 10 ' 1' '1 ' "1"$'\r' '"1"' true yes; do
  printf 'AIC_STATUS_RELAY=%s\n' "$value" > "$RUNTIME_ENV_FILE"
  expect off "AIC_STATUS_RELAY='$value'"
done
printf 'AIC_STATUS_RELAY=1\nAIC_STATUS_RELAY=0\n' > "$RUNTIME_ENV_FILE"
expect off "a later AIC_STATUS_RELAY=0 line"
printf 'AIC_STATUS_RELAY=0\nAIC_STATUS_RELAY=1\n' > "$RUNTIME_ENV_FILE"
expect on "a later AIC_STATUS_RELAY=1 line"
printf '# AIC_STATUS_RELAY=1\nX_AIC_STATUS_RELAY=1\n export AIC_STATUS_RELAY=1\n' > "$RUNTIME_ENV_FILE"
expect off "a comment or another key"

# Not a regular file at the exact path: no rule.
printf 'AIC_STATUS_RELAY=1\n' > "$TMP/real.env"
rm -f "$RUNTIME_ENV_FILE"
ln -s "$TMP/real.env" "$RUNTIME_ENV_FILE"
expect off "a symlinked .env"
rm -f "$RUNTIME_ENV_FILE"
mkdir "$RUNTIME_ENV_FILE"
expect off "a .env directory"
rmdir "$RUNTIME_ENV_FILE"
mkdir "$TMP/real-dir"
printf 'AIC_STATUS_RELAY=1\n' > "$TMP/real-dir/.env"
ln -s "$TMP/real-dir" "$TMP/link-dir"
RUNTIME_ENV_FILE="$TMP/link-dir/.env"
expect off "a .env below a symlinked directory"

echo "OK: only AIC_STATUS_RELAY=1 in the regular read-only .env turns the relay rule on"
