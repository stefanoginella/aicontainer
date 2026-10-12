#!/usr/bin/env bash
# ShellCheck every shell script that this repository owns.
#
# SCRIPTS below is the one list of these scripts. smoke.yml installs a pinned
# ShellCheck and runs this file with --require, so CI never skips the check.
# Locally, the check skips with a message when shellcheck is not installed.
#
#   bash tests/test-aic-shellcheck.sh            # skip when shellcheck is absent
#   bash tests/test-aic-shellcheck.sh --require  # fail when shellcheck is absent
#
# To add a script, add it to SCRIPTS. The check fails when a listed file is
# missing, and when a tracked shell script is not in the list. The generated
# dogfood copy in .devcontainer/ is not checked: template/ is its source.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SHELLCHECK="${SHELLCHECK:-shellcheck}"

fail() { echo "FAIL: $*" >&2; exit 1; }

require=0
case "$#:${1:-}" in
  0:) ;;
  1:--require) require=1 ;;
  *) echo "usage: bash tests/test-aic-shellcheck.sh [--require]" >&2; exit 2 ;;
esac

SCRIPTS=(
  aic
  install.sh
  .githooks/pre-push
  lib/aic/runtime.sh
  lib/aic/identity.sh
  lib/aic/selection.sh
  lib/aic/versions.sh
  lib/aic/template.sh
  lib/aic/init-sync.sh
  lib/aic/validation.sh
  lib/aic/status.sh
  lib/aic/signing.sh
  lib/aic/volumes.sh
  lib/aic/lifecycle.sh
  lib/aic/doctor.sh
  lib/aic/help.sh
  template/aic-chown-volumes
  template/aic-firewall
  template/hooks/pre-tool-use.sh
  tests/fixtures/validate/regenerate.sh
  tests/test-aic-chown-volume-validation.sh
  tests/test-aic-docker-runtime.sh
  tests/test-aic-host-security.sh
  tests/test-aic-package.sh
  tests/test-aic-shellcheck.sh
)

cd "$ROOT"
for script in "${SCRIPTS[@]}"; do
  [ -f "$script" ] || fail "listed shell script is missing: $script"
done

# A tracked file is a shell script when its name ends in .sh, or its first
# line is a sh/bash/dash/ksh shebang or a '# shellcheck shell=' directive.
# Without Git (an exported tree), only the listed files are checked.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  unlisted=""
  while IFS= read -r file; do
    case "$file" in .devcontainer/*) continue ;; esac
    [ -f "$file" ] || continue
    case "$file" in
      *.sh) ;;
      *)
        head -n1 "$file" 2>/dev/null \
          | grep -Eq '^(#!.*[/ ]((ba|da|k)?sh)([[:space:]]|$)|# shellcheck shell=)' || continue
        ;;
    esac
    listed=0
    for script in "${SCRIPTS[@]}"; do
      [ "$script" = "$file" ] && { listed=1; break; }
    done
    [ "$listed" = 1 ] || unlisted="$unlisted $file"
  done < <(git -C "$ROOT" ls-files)
  [ -z "$unlisted" ] || fail "shell scripts missing from SCRIPTS in tests/test-aic-shellcheck.sh:$unlisted"
fi

if ! command -v "$SHELLCHECK" >/dev/null 2>&1; then
  [ "$require" = 0 ] || fail "shellcheck is not installed, and --require forbids a skip"
  echo "SKIP: shellcheck is not installed; install it to lint the shell scripts (CI runs a pinned version)"
  exit 0
fi

"$SHELLCHECK" --version | sed -n 's/^version: /shellcheck /p'
"$SHELLCHECK" -x -S warning "${SCRIPTS[@]}" || fail "shellcheck found warnings (see above)"
echo "shellcheck: ${#SCRIPTS[@]} scripts passed"
