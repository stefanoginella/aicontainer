# shellcheck shell=bash
# =============================================================================
# lib/aic/versions.sh
# =============================================================================
# Versions: the aic version, version comparison, the drift warning (Tier 1),
# and the update check (Tier 2).
#
# aic sources this file. It only defines functions.
# =============================================================================

# Read this aic's own version from package.json. Used to pin the GHCR image
# tag in generated pull-mode compose files (so `aic@X.Y.Z` always pulls
# `ghcr.io/stefanoginella/aicontainer:vX.Y.Z`, never a floating :latest that
# could drift away from the CLI's filesystem expectations).
read_aic_version () {
  local pkg="$AIC_HOME/package.json"
  [ -f "$pkg" ] || die "package.json not found at $pkg (set AIC_HOME or reinstall aic)"
  local v
  v="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pkg" | head -n1)"
  [ -n "$v" ] || die "could not read version from $pkg"
  echo "$v"
}

# --- Version drift / update notifications --------------------------------------
# Two distinct "am I current?" questions, answered by two cheap checks:
#   Tier 1 (warn_compose_drift): offline, local. Does this project's pinned image
#     tag match the aic CLI that's about to drive it? Catches the onset of the
#     common "npm update -g aicontainer, forgot to re-sync" drift.
#   Tier 2 (check_for_update): is a newer aicontainer published at all? Asks npm
#     (the install/upgrade source of truth — NOT GHCR, whose :latest floats on a
#     weekly cron independent of releases). Cached, fail-silent, opt-out.
# Both are best-effort and must never abort the command the user actually ran:
# every failure path returns 0, and version reads are guarded (read_aic_version
# dies on a broken install — fine off the hot path, fatal on it). Silence both
# with AIC_NO_UPDATE_CHECK=1.

is_semver () { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# 0 (true) iff $1 > $2 as a dotted numeric X.Y.Z. Defensive against junk fields.
version_gt () {
  local a="$1" b="$2" i ai bi
  local -a A B
  IFS=. read -ra A <<< "$a" || true
  IFS=. read -ra B <<< "$b" || true
  for i in 0 1 2; do
    ai="${A[i]:-0}"; ai="${ai//[!0-9]/}"; ai="${ai:-0}"
    bi="${B[i]:-0}"; bi="${bi//[!0-9]/}"; bi="${bi:-0}"
    ai=$((10#$ai)); bi=$((10#$bi))
    [ "$ai" -gt "$bi" ] && return 0
    [ "$ai" -lt "$bi" ] && return 1
  done
  return 1
}

# Echo X.Y.Z pinned into this project's compose image tag, or nothing. Anchored
# on the repo path so comment lines and the socket-proxy image never match, and
# build mode (no GHCR image: line — see docker-compose.build.yml) yields empty,
# which is how Tier 1 skips it: there's no version pin to compare against.
read_pinned_compose_version () {
  local f=".devcontainer/docker-compose.yml"
  [ -f "$f" ] || return 0
  sed -n 's|^[[:space:]]*image:[[:space:]]*ghcr\.io/stefanoginella/aicontainer:v\([0-9][0-9.]*\).*|\1|p' \
    "$f" | head -n1
}

# Tier 1. Warn (to stderr, yellow on a TTY) when the project's pinned image tag
# and the installed aic disagree — the hot-path nudge for `aic up`/`aic shell`.
# Known blind spots, by design (offline + zero-cost beats full coverage here):
#   - It compares CLI-vs-pin, not pin-vs-running-container, so it can't see a
#     project that's synced but not yet rebuilt (pin == CLI, old container still
#     up). The remediation it prints — sync && rebuild — resolves that anyway.
#   - Build-mode projects have no version pin, so they're unguarded.
warn_compose_drift () {
  [ -n "${AIC_NO_UPDATE_CHECK:-}" ] && return 0
  local pinned cur
  pinned="$(read_pinned_compose_version 2>/dev/null)" || return 0
  [ -n "$pinned" ] || return 0
  cur="$(read_aic_version 2>/dev/null)" || return 0
  is_semver "$pinned" || return 0
  is_semver "$cur" || return 0
  [ "$pinned" = "$cur" ] && return 0

  local y rst
  if [ -t 2 ]; then y=$'\033[33m'; rst=$'\033[0m'; else y=""; rst=""; fi
  if version_gt "$cur" "$pinned"; then
    printf '%saic: this project pins the v%s image, but your installed aic is v%s.%s\n' \
      "$y" "$pinned" "$cur" "$rst" >&2
    printf '%saic: re-pin + refresh with: aic sync && aic rebuild%s\n' "$y" "$rst" >&2
  else
    printf '%saic: this project pins the v%s image, but your installed aic is older (v%s).%s\n' \
      "$y" "$pinned" "$cur" "$rst" >&2
    printf '%saic: upgrade aic (npm update -g aicontainer), or re-pin down with: aic sync && aic rebuild%s\n' \
      "$y" "$rst" >&2
  fi
  return 0
}

# Query the latest published version from the npm registry. Bounded + fail-silent
# (a slow/offline/firewalled host must never hang or error a version/upgrade
# call); curl primary so the timeout is portable, npm view as a fallback. The
# strict is_semver gate on the result is also the terminal-escape defense: a
# hostile/garbled registry response can't reach a printf.
fetch_latest_version () {
  local out=""
  if command -v curl >/dev/null 2>&1; then
    out="$(curl -fsS --max-time 3 https://registry.npmjs.org/aicontainer/latest 2>/dev/null \
      | grep -m1 -o '"version"[[:space:]]*:[[:space:]]*"[0-9][0-9.]*"' \
      | grep -m1 -o '[0-9][0-9.]*')" || out=""
  elif command -v npm >/dev/null 2>&1; then
    out="$(npm view aicontainer version 2>/dev/null)" || out=""
  fi
  is_semver "$out" && echo "$out"
}

# Tier 2. Nudge (to stderr) when a newer aicontainer is published. Result cached
# for 24h under $XDG_CACHE_HOME so it hits the network at most once a day; the CI
# skip keeps the workflow CLI tests offline. Confined to `aic version`/`aic
# upgrade` — deliberately off the `up`/`shell` hot path.
check_for_update () {
  [ -n "${AIC_NO_UPDATE_CHECK:-}" ] && return 0
  [ -n "${CI:-}" ] && return 0

  local cur; cur="$(read_aic_version 2>/dev/null)" || return 0
  is_semver "$cur" || return 0

  local now; now="$(date +%s 2>/dev/null)" || return 0
  case "$now" in ''|*[!0-9]*) return 0 ;; esac

  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/aicontainer"
  local cache="$dir/update-check"
  local ts="" latest=""
  if [ -f "$cache" ]; then
    read -r ts latest < "$cache" 2>/dev/null || { ts=""; latest=""; }
  fi
  case "$ts" in ''|*[!0-9]*) ts=0 ;; esac

  if [ $((now - ts)) -ge 86400 ]; then
    local fetched; fetched="$(fetch_latest_version)"
    if is_semver "$fetched"; then
      latest="$fetched"
      mkdir -p "$dir" 2>/dev/null && printf '%s %s\n' "$now" "$latest" > "$cache" 2>/dev/null || true
    fi
    # Fetch failed: fall through on the (possibly stale) cached `latest`.
  fi

  is_semver "$latest" || return 0
  version_gt "$latest" "$cur" || return 0

  local y rst
  if [ -t 2 ]; then y=$'\033[33m'; rst=$'\033[0m'; else y=""; rst=""; fi
  printf '%saic: a newer aicontainer is available: v%s (you have v%s).%s\n' \
    "$y" "$latest" "$cur" "$rst" >&2
  if [ -d "$AIC_HOME/.git" ]; then
    printf '%saic: upgrade with: aic upgrade%s\n' "$y" "$rst" >&2
  else
    printf '%saic: upgrade with: npm update -g aicontainer%s\n' "$y" "$rst" >&2
  fi
  return 0
}
# ------------------------------------------------------------------------------

# Normalize the first dotted numeric version in a command's output. Docker and
# Compose commonly add a leading "v" or a vendor suffix; diagnostics only need
# the numeric compatibility floor.
diagnostic_version () {
  printf '%s\n' "$1" | grep -Eo '[0-9]+(\.[0-9]+){0,2}' | head -n1 || true
}

version_at_least () {
  local actual="$1" minimum="$2" i av mv
  local -a a m
  IFS=. read -ra a <<< "$actual"
  IFS=. read -ra m <<< "$minimum"
  for i in 0 1 2; do
    av="${a[i]:-0}"; mv="${m[i]:-0}"
    case "$av:$mv" in *[!0-9:]*|'':*) return 1 ;; esac
    av=$((10#$av)); mv=$((10#$mv))
    [ "$av" -gt "$mv" ] && return 0
    [ "$av" -lt "$mv" ] && return 1
  done
  return 0
}
