# shellcheck shell=bash
# =============================================================================
# lib/aic/json.sh
# =============================================================================
# The --json output of doctor, status, validate, and version: one JSON object
# on stdout. The encoder is pure bash, so doctor --json works on a host that
# has no Node.js.
#
# aic sources this file. It only defines functions and constants.
# =============================================================================

# The version of the JSON shape. Change it only for an incompatible change.
AIC_JSON_SCHEMA=1

# Print $1 as a JSON string literal. Escape the quote, the backslash, and every
# control character. Valid UTF-8 passes through. A value that is not valid
# UTF-8 gets '?' for each byte above 0x7f, so the output is always valid JSON.
json_string () {
  local s="$1" LC_ALL=C out="" c i hex
  case "$s" in
    *[$'\200'-$'\377']*)
      if ! printf '%s' "$s" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
        # The x keeps the trailing newlines that $(...) would remove.
        s="$(printf '%s' "$s" | LC_ALL=C tr '\200-\377' '?'; printf x)"
        s="${s%x}"
      fi
      ;;
  esac
  case "$s" in
    *[\\\"$'\001'-$'\037']*)
      for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
          \\) out="$out\\\\" ;;
          \") out="$out\\\"" ;;
          $'\n') out="$out\\n" ;;
          $'\t') out="$out\\t" ;;
          $'\r') out="$out\\r" ;;
          [$'\001'-$'\037']) printf -v hex '%04x' "'$c"; out="$out\\u$hex" ;;
          *) out="$out$c" ;;
        esac
      done
      ;;
    *) out="$s" ;;
  esac
  printf '"%s"' "$out"
}

# Print $1 as a JSON string, or null when it is empty.
json_string_or_null () {
  if [ -n "$1" ]; then json_string "$1"; else printf 'null'; fi
}

# The record helpers below write to the directory in aic_json_dir. aic sets it
# to "" at startup, so a value from the environment never selects JSON mode.
# json_run sets it only in the subshell that runs the command.

# True in JSON mode.
json_mode () { [ -n "${aic_json_dir:-}" ]; }

# Add the member "<key>": <json> to the result object. <key> is a constant of
# the caller. <json> must come from json_string, json_string_or_null, or be a
# JSON literal (true, false, null, a number).
json_field () {
  json_mode || return 0
  printf '"%s":%s\n' "$1" "$2" >> "$aic_json_dir/fields"
}

# Add the string member "<key>": "<value>" (null when <value> is empty).
json_field_string () {
  json_mode || return 0
  json_field "$1" "$(json_string_or_null "$2")"
}

# Add one item {"id", "level", "message"} to the list of the command.
json_item () {
  json_mode || return 0
  printf '{"id":%s,"level":%s,"message":%s}\n' \
    "$(json_string "$1")" "$(json_string "$2")" "$(json_string "$3")" >> "$aic_json_dir/items"
}

# Add each line of $2 as an item with level $1. A line is "<CATEGORY> <message>"
# with a tab or spaces after the category, as validate_project_security()
# collects them. The id is the category in lower case.
json_findings () {
  json_mode || return 0
  local level="$1" line category message
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    category="${line%%[[:space:]]*}"
    message="${line#"$category"}"
    message="${message#"${message%%[![:space:]]*}"}"
    json_item "$(printf '%s' "$category" | tr '[:upper:]' '[:lower:]')" "$level" "$message"
  done <<< "$2"
}

# json_run <command> <list> <function> [args...]
# Run <function> [args...] in JSON mode and print one JSON object on stdout:
#   {"schema":1,"command":<command>,"ok":<exit status is 0>,<fields>,
#    "<list>":[<items>],"error":<message of die, or null>}
# <list> is "" for a command with no list. Return the exit status of
# <function>, so --json keeps the exit codes of the text mode.
#
# The function runs in a subshell with its stdout sent to stderr, so only the
# JSON object reaches stdout. It runs with errexit on, as in the text mode;
# the subshell is not part of an && or || list, because there bash turns
# errexit off. die prints and exits as before. It records its message for
# "error" only when it runs at the level of that subshell, so it really stops
# the command. A die in a nested subshell, such as a probe in $(...) that the
# caller catches with || true, records nothing. When a nested die stops the
# command through errexit, "error" is null and stderr has the message.
json_run () {
  local command="$1" list="$2" dir rc=0 ok=false item sep error
  shift 2
  dir="$(mktemp -d "${TMPDIR:-/tmp}/aic-json.XXXXXX")" || die "could not create a temporary directory"
  : > "$dir/fields"; : > "$dir/items"; : > "$dir/error"
  set +e
  (
    set -e
    aic_json_dir="$dir"
    aic_json_level="$BASH_SUBSHELL"
    die () {
      if [ "$BASH_SUBSHELL" = "$aic_json_level" ]; then
        printf '%s' "$*" > "$aic_json_dir/error"
      fi
      err "$*"
      exit 1
    }
    exec 1>&2
    "$@"
  )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || ok=true
  error="$(cat "$dir/error")"
  [ "$rc" -ne 0 ] || error=""
  {
    printf '{"schema":%s,"command":%s,"ok":%s' "$AIC_JSON_SCHEMA" "$(json_string "$command")" "$ok"
    while IFS= read -r item; do printf ',%s' "$item"; done < "$dir/fields"
    if [ -n "$list" ]; then
      printf ',"%s":[' "$list"
      sep=""
      while IFS= read -r item; do printf '%s%s' "$sep" "$item"; sep=","; done < "$dir/items"
      printf ']'
    fi
    printf ',"error":%s}\n' "$(json_string_or_null "$error")"
  }
  rm -rf "$dir"
  return "$rc"
}
