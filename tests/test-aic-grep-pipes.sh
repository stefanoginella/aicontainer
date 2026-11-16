#!/usr/bin/env bash
# No command pipes its output into a quiet grep (`cmd | grep -q PATTERN`).
#
# With pipefail, the pipe is racy: `grep -q` exits at the first match, the
# command gets SIGPIPE, and the pipeline returns non-zero. A positive check
# (`cmd | grep -q x || fail`) then fails on a real match. A negative check
# (`if cmd | grep -q x; then fail`) hides a real match. Both broke CI and a
# release. Read the output first, then match it:
#
#   out=$(cmd); grep -q 'text' <<<"$out"
#
# Capture the output in a variable for a negative check: then a failed command
# stops the test. A `grep -q x <(cmd)` ignores the status of cmd, so use it
# only in a positive check. Other readers that exit early (`head -n1`,
# `grep -m1`, `awk '{...; exit}'`) have the same problem; this test does not
# find them.
#
# The check reads the scripts in SCRIPTS of tests/test-aic-shellcheck.sh (that
# test makes sure that the list holds every tracked shell script), the
# workflows, and the Dockerfile (its RUN lines use pipefail). It reads a line
# that ends in `\`, `|`, `&&` or `||` (or `| # comment`) together with the
# next line, and it skips full-line comments. The self-test below proves that
# it finds the pattern and accepts the fixes.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Print "file:line: text" for each quiet grep that reads a pipe.
find_quiet_grep_pipes() {
  awk -v sq="'" '
    BEGIN {
      # One grep argument: plain text, or a quoted string (a quoted "-eq"
      # in a pattern is not an option).
      arg = "([^|;&[:space:]\"" sq "]|" sq "[^" sq "]*" sq "|\"[^\"]*\")+"
      word = "[^|;&[:space:]]"
      # Words before grep: VAR=value, or sudo, env, xargs ... and their
      # options and number arguments.
      prefix = "([A-Za-z_][A-Za-z0-9_]*=" word "*[[:space:]]+|(sudo|env|command|exec|nice|xargs|timeout|stdbuf)" \
        "([[:space:]]+(-" word "*|[0-9]" word "*))*[[:space:]]+)*"
      # `|` or `|&`, not `||`, then grep (with any path) or rg with -q in an
      # option cluster, or --quiet / --silent, before the next pipe or list
      # operator.
      # The shell removes quotes, so a quoted '-q' is an option too.
      quiet = "(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)"
      re = "(^|[^|])[|]&?[[:space:]]*" prefix "(" word "*/)?([ef]?grep|rg)([[:space:]]+" arg ")*" \
        "[[:space:]]+(" quiet "|" sq quiet sq "|\"" quiet "\")([[:space:];)|&]|$)"
      # A pipe at the end of a line, then a comment.
      pipe_comment = "(^|[^|])[|][[:space:]]+#[^\"" sq "]*$"
      # A YAML block scalar (`run: |`) is not a pipe.
      block_scalar = "^[[:space:]]*(-[[:space:]]+)?[A-Za-z0-9_.-]+:[[:space:]]*[|>][-+0-9]*[[:space:]]*$"
    }
    function flush() {
      if (buf ~ re) print name ":" start ": " buf
      buf = ""
    }
    FNR == 1 { flush() }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      if (buf == "") { name = FILENAME; start = FNR }
      if (FILENAME ~ /\.ya?ml$/ && line ~ block_scalar) { buf = buf line; flush(); next }
      if (line ~ pipe_comment) { match(line, /[|][[:space:]]+#/); line = substr(line, 1, RSTART) }
      if (line ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, " ", line); buf = buf line; next }
      if (line ~ /(\||&&)[[:space:]]*$/) { buf = buf line " "; next }
      buf = buf line
      flush()
    }
    END { flush() }
  ' "$@"
}

# --- Self-test: the check finds the old pattern and accepts the fixes ----------
bar='|'
bad=(
  "echo \"\$out\" $bar grep -q 'x' || fail"
  "if printf '%s\\n' \"\$v\" $bar grep -Fqx \"\$a\"; then"
  "docker logs \"\$cid\" 2>&1 $bar grep --quiet 'x'"
  "x $bar& grep -q y"
  "out=1; echo \"\$out\" $bar grep -q 'x' && { echo FAIL; exit 1; }"
  "cmd \\
  $bar grep -Eq 'x' || fail"
  "cmd $bar
  grep -qx 'x' || fail"
  "grep -v '^#' f $bar grep -vqF y && fail"
  "x $bar sudo grep -q y"
  "x $bar LC_ALL=C grep -q y"
  "x $bar xargs -r grep -q y"
  "x $bar timeout 5 grep -q y"
  "x $bar /usr/bin/grep -q y"
  "x $bar rg -q y"
  "x $bar grep '-q' y"
  "x $bar grep \"-Fq\" y"
  "x $bar cut -d: $bar
  grep -q y || fail"
  "x $bar # note
  grep -q y || fail"
)
good=(
  "grep -q 'x' <<<\"\$out\" || fail"
  "a || grep -q x file"
  "a ||
  grep -q x file"
  "# echo \"\$out\" $bar grep -q 'x'"
  "cmd $bar grep -c x"
  "grep -Fq x <(grep y file) && fail"
  "printf '%s\\n' \"\$v\" $bar grep -n -m1 -- x $bar cut -d: -f1"
  "printf '%s\\n' \"\$b\" $bar grep -n 'if [ \"\$r\" -eq 1 ]; then' $bar cut -d: -f1"
)
# Only in a YAML file.
good_yaml=(
  "      run: $bar
        grep -qF 'x' file"
  "- run: $bar-
    grep -qF 'x' file"
)
i=0
for case in "${bad[@]}"; do
  i=$((i + 1))
  for ext in sh yml; do
    printf '%s\n' "$case" > "$TMP/bad-$i.$ext"
    [ -n "$(find_quiet_grep_pipes "$TMP/bad-$i.$ext")" ] \
      || fail "self-test: the check did not find a quiet grep pipe in a .$ext file: $case"
  done
done
i=0
for case in "${good[@]}" "${good_yaml[@]}"; do
  i=$((i + 1))
  printf '%s\n' "$case" > "$TMP/good-$i.yml"
  found=$(find_quiet_grep_pipes "$TMP/good-$i.yml")
  [ -z "$found" ] || fail "self-test: the check flagged a safe line: $found"
done
for case in "${good[@]}"; do
  i=$((i + 1))
  printf '%s\n' "$case" > "$TMP/good-$i.sh"
  found=$(find_quiet_grep_pipes "$TMP/good-$i.sh")
  [ -z "$found" ] || fail "self-test: the check flagged a safe line: $found"
done
# In a shell script, `name: |` is a pipe.
printf '%s\n' "${good_yaml[0]}" > "$TMP/yaml-in-shell.sh"
[ -n "$(find_quiet_grep_pipes "$TMP/yaml-in-shell.sh")" ] \
  || fail "self-test: the check skipped a pipe that looks like a YAML block scalar in a shell script"

# --- The repository files -----------------------------------------------------
cd "$ROOT"
scripts=$(awk '/^SCRIPTS=\(/ { on = 1; next } on && /^\)/ { on = 0 } on && NF { print $1 }' \
  tests/test-aic-shellcheck.sh)
files=()
while IFS= read -r file; do
  [ -f "$file" ] || fail "a script in SCRIPTS of tests/test-aic-shellcheck.sh is missing: $file"
  files+=("$file")
done <<<"$scripts"
files+=(.github/workflows/*.yml template/Dockerfile)
[ "${#files[@]}" -gt 20 ] || fail "the check found only ${#files[@]} files to read"
for need in .github/workflows/smoke.yml .github/workflows/release.yml template/aic-firewall aic \
  template/Dockerfile tests/test-aic-grep-pipes.sh; do
  grep -Fxq "$need" <(printf '%s\n' "${files[@]}") || fail "the check does not read $need"
done

found=$(find_quiet_grep_pipes "${files[@]}")
[ -z "$found" ] || fail "a command pipes into a quiet grep (racy under pipefail; use a here-string):
$found"

echo "OK: no quiet grep reads a pipe (${#files[@]} files)"
