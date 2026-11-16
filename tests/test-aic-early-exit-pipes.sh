#!/usr/bin/env bash
# No command pipes its output into a reader that exits early: a quiet grep
# (`grep -q`, `grep -l`, `grep -L`), `grep -m N`, `head`, `awk` with an
# `exit` or `nextfile` outside `END`, or `sed` with a `q` command.
#
# With pipefail, the pipe is racy: the reader exits before the end of the
# input, the command gets SIGPIPE, and the pipeline returns non-zero. A
# positive check (`cmd | grep -q x || fail`) then fails on a real match. A
# negative check (`if cmd | grep -q x; then fail`) hides a real match. A
# lookup (`x=$(cmd | head -n1) || x=""`) silently gives the fallback. These
# broke CI and a release. Read the output first, then match it:
#
#   out=$(cmd); grep -q 'text' <<<"$out"
#   out=$(cmd); first=${out%%$'\n'*}
#
# Capture the output in a variable for a negative check: then a failed command
# stops the test. A `grep -q x <(cmd)` ignores the status of cmd, so use it
# only in a positive check. A reader on a file (`head -n1 file`,
# `awk '{print; exit}' file`) has no pipe and is fine.
#
# The check reads the scripts in SCRIPTS of tests/test-aic-shellcheck.sh (that
# test makes sure that the list holds every tracked shell script), the
# workflows, and the Dockerfile (its RUN lines use pipefail). It reads a line
# that ends in `\`, `|`, `&&` or `||` (or `| # comment`) together with the
# next line, and an awk or sed program in a pipe up to its closing quote. It
# skips full-line comments. The self-test below proves that it finds the
# pattern and accepts the fixes.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Print "file:line: text" for each reader that exits early on a pipe.
find_early_exit_pipes() {
  awk -v sq="'" '
    BEGIN {
      # One argument: plain text, or a quoted string (a quoted "-eq" in a
      # pattern is not an option).
      arg = "([^|;&[:space:]\"" sq "]|" sq "[^" sq "]*" sq "|\"[^\"]*\")+"
      word = "[^|;&[:space:]]"
      # Words before the reader: VAR=value, or sudo, env, xargs ... and their
      # options (with a value: sudo -u vscode) and number arguments.
      prefix = "([A-Za-z_][A-Za-z0-9_]*=" word "*[[:space:]]+|(sudo|env|command|exec|nice|xargs|timeout|stdbuf|time)" \
        "([[:space:]]+(-" word "*([[:space:]]+[^-|;&[:space:]]" word "*)?|[0-9]" word "*))*[[:space:]]+)*"
      # `|` or `|&`, not `||`, then a reader (with any path). early_exit()
      # then reads its arguments up to the next pipe or list operator.
      pipe = "(^|[^|])[|]&?[[:space:]]*" prefix "(" word "*/)?"
      cmd = pipe "(head|[ef]?grep|rg|[gmn]?awk|g?sed)"
      # An awk or sed program in a pipe can go on over more lines.
      program_pipe = pipe "([gmn]?awk|g?sed)[[:space:]]"
      next_arg = "^[[:space:]]+" arg
      # grep: short options that stop at the first match, and short options
      # that take a value (the rest of the cluster, or the next argument).
      grep_early = "qmlL"
      grep_value = "efABCdD"
      # A `q` (or `Q`) sed command: after an address, `;`, `{` or a space.
      # `$q` reads all the input. `s/a/q/` is not a command.
      sed_quit = "(^|[;{}!/0-9[:space:]])[qQ]([[:space:]]*[0-9]+)?[[:space:]]*(;|[}]|$)"
      # A pipe at the end of a line, then a comment.
      pipe_comment = "(^|[^|])[|][[:space:]]+#[^\"" sq "]*$"
      # A YAML block scalar (`run: |`) is not a pipe.
      block_scalar = "^[[:space:]]*(-[[:space:]]+)?[A-Za-z0-9_.-]+:[[:space:]]*[|>][-+0-9]*[[:space:]]*$"
    }
    # Read the arguments at the start of s into args[1..n], without quotes:
    # the shell removes them, so a quoted "-q" is an option too. Stop at the
    # next pipe or list operator.
    function read_args(s,   n, tok) {
      n = 0
      while (match(s, next_arg)) {
        tok = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        sub(/^[[:space:]]+/, "", tok)
        gsub("[\"" sq "]", "", tok)
        args[++n] = tok
      }
      return n
    }
    # grep -q, -m N, -l, -L (or a long form) stops at the first match. A value
    # (-e PATTERN, -eq) and every argument after -- is not an option.
    function grep_stops(n, rg,   k, tok, skip, i, c) {
      skip = 0
      for (k = 1; k <= n; k++) {
        tok = args[k]
        if (skip) { skip = 0; continue }
        if (tok == "--") return 0
        if (tok ~ /^--(quiet|silent|max-count|files-with(out)?-match(es)?)(=|$)/) return 1
        if (tok == "--regexp" || tok == "--file") { skip = 1; continue }
        if (tok !~ /^-[A-Za-z]/) continue
        for (i = 2; i <= length(tok); i++) {
          c = substr(tok, i, 1)
          # rg -L follows links.
          if (index(grep_early, c) && !(rg && c == "L")) return 1
          if (index(grep_value, c)) { if (i == length(tok)) skip = 1; break }
        }
      }
      return 0
    }
    # An awk program with `exit` or `nextfile` outside END (in BEGIN too)
    # stops reading.
    # A program from a file (-f) is not checked.
    function awk_stops(n,   k, tok, p, out, i, depth, c) {
      for (k = 1; k <= n; k++) {
        tok = args[k]
        if (tok == "-f" || tok ~ /^-f/ || tok ~ /^--file/) return 0
        if (tok == "-F" || tok == "-v" || tok == "--assign" || tok == "--field-separator") { k++; continue }
        if (tok == "--") { k++; break }
        if (tok !~ /^-/) break
      }
      if (k > n) return 0
      # Drop each END { ... } block.
      p = " " args[k]
      out = ""
      while (match(p, /[^A-Za-z0-9_]END[[:space:]]*[{]/)) {
        out = out substr(p, 1, RSTART)
        i = RSTART + RLENGTH
        depth = 1
        while (i <= length(p) && depth > 0) {
          c = substr(p, i, 1)
          if (c == "{") depth++
          else if (c == "}") depth--
          i++
        }
        p = substr(p, i)
      }
      out = out p
      return out ~ /(^|[^A-Za-z0-9_])(exit|nextfile)([^A-Za-z0-9_]|$)/
    }
    # A sed script (each -e value, or the first operand) with a q command.
    function sed_stops(n,   k, tok, scripts, found) {
      scripts = 0
      for (k = 1; k <= n; k++) {
        tok = args[k]
        if (tok == "-e" || tok == "--expression") {
          scripts++
          if (k < n && args[++k] ~ sed_quit) return 1
          continue
        }
        if (tok ~ /^--expression=/) { scripts++; sub(/^--expression=/, "", tok); if (tok ~ sed_quit) return 1; continue }
        if (tok == "-f" || tok ~ /^--file/) { scripts++; continue }
        if (tok == "--") continue
        if (tok ~ /^-/) continue
        if (!scripts) return tok ~ sed_quit
      }
      return 0
    }
    # True when a reader in s reads a pipe and exits early.
    function early_exit(s,   m, reader, rest, n) {
      while (match(s, cmd)) {
        m = substr(s, RSTART, RLENGTH)
        rest = substr(s, RSTART + RLENGTH)
        s = rest
        # The whole command name: not `headers` or `sedx`.
        if (rest != "" && rest !~ /^[[:space:]);`]/) continue
        match(m, /[A-Za-z]+$/)
        reader = substr(m, RSTART)
        n = read_args(rest)
        if (reader == "head") return 1
        if (reader ~ /grep$/ || reader == "rg") { if (grep_stops(n, reader == "rg")) return 1; continue }
        if (reader ~ /awk$/) { if (awk_stops(n)) return 1; continue }
        if (sed_stops(n)) return 1
      }
      return 0
    }
    function flush() {
      if (early_exit(buf)) print name ":" start ": " buf
      buf = ""
    }
    # True when s opens a quote for an awk or sed program in a pipe and does
    # not close it.
    function open_program(s,   t) {
      t = s
      return gsub(sq, "", t) % 2 == 1 && s ~ program_pipe
    }
    FNR == 1 { flush() }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      if (buf == "") { name = FILENAME; start = FNR }
      if (FILENAME ~ /\.ya?ml$/ && line ~ block_scalar && !open_program(buf)) { buf = buf line; flush(); next }
      if (open_program(buf line)) { buf = buf line " "; next }
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
  # A quiet grep.
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
  "x $bar grep -qe y"
  "x $bar grep -e y -q"
  "x $bar grep -A1 -F a $bar grep -Fq b"
  "x $bar cut -d: $bar
  grep -q y || fail"
  "x $bar # note
  grep -q y || fail"
  # grep -m and grep -l.
  "v=\$(x $bar grep -m1 y)"
  "x $bar grep -m 1 y"
  "x $bar grep -n -m1 -- y $bar cut -d: -f1"
  "x $bar grep -m1 -o y $bar grep -m1 -o z"
  "x $bar grep --max-count=1 y"
  "x $bar grep --max-count 1 y"
  "x $bar grep -om1 y"
  "x $bar grep -l y"
  "x $bar grep -L y"
  "x $bar grep --files-without-match y"
  "x $bar sudo -u vscode grep -q y"
  "x $bar env -u VAR head -n1"
  "x $bar time head -n1"
  "x $bar sudo -n -u vscode /usr/bin/head -n1"
  "x $bar egrep -m1 y"
  # head, with any options.
  "cid=\$(docker ps -q $bar head -n1)"
  "x $bar head -n 1 $bar cut -d: -f1"
  "x $bar head -1"
  "x $bar head"
  "x $bar head -c 16"
  "v=\$(x $bar head)"
  "x \\
  $bar head -n1"
  "sed -n 's/a/b/p' \"\$f\" $bar head -n1"
  "x $bar /usr/bin/head -n1"
  # awk with exit outside END.
  "x $bar awk '/y/ {print; exit}'"
  "x $bar awk -F: '\$1 == \"a\" { print \$2; exit }'"
  "x $bar awk -v k=\"\$k\" '\$1 == k {print; exit 0}'"
  "x $bar awk 'NR == 1 {print} {exit}'"
  "x $bar awk 'BEGIN { exit }'"
  "x $bar awk '{print} END {print n} NR > 2 {exit}'"
  "x $bar mawk '{exit}'"
  "x $bar awk --assign k=v '{print; exit}'"
  "x $bar awk --field-separator : '{print; exit}'"
  "x $bar awk '{nextfile}'"
  "x $bar awk '
    /y/ { print; exit }
  '"
  # sed with q.
  "x $bar sed q"
  "x $bar sed 1q"
  "x $bar sed -n '/y/{p;q;}'"
  "x $bar sed -n 's/a/b/p;q'"
  "x $bar sed -n -e 's/a/b/p' -e q"
  "x $bar sed '/y/q'"
  "x $bar sed --expression=5q"
)
good=(
  "grep -q 'x' <<<\"\$out\" || fail"
  "a || grep -q x file"
  "a ||
  grep -q x file"
  "# echo \"\$out\" $bar grep -q 'x'"
  "cmd $bar grep -c x"
  "grep -Fq x <(grep y file) && fail"
  "printf '%s\\n' \"\$b\" $bar grep -n 'if [ \"\$r\" -eq 1 ]; then' $bar cut -d: -f1"
  "x $bar grep -e '-q' $bar wc -l"
  "x $bar grep -- '-q' $bar wc -l"
  "x $bar grep -e -q $bar wc -l"
  "x $bar grep -eq $bar wc -l"
  "x $bar grep --regexp -q $bar wc -l"
  "x $bar grep -e -m1 $bar wc -l"
  "x $bar grep -- -m1"
  "x $bar grep -v -e '-l' y"
  "x $bar rg -L y"
  "x $bar sudo -u vscode grep -c y"
  "x $bar sudo -u vscode tail -n1"
  # A reader on a file has no pipe.
  "head -n1 \"\$f\""
  "grep -m1 x file"
  "a || grep -m1 x file"
  "grep -nm1 x file $bar cut -d: -f1"
  "sed -n '1q' file"
  "awk '/x/ {print; exit}' file"
  "v=\$(x); v=\${v%%\$'\\n'*}"
  # Readers that read all the input.
  "x $bar tail -n1"
  "x $bar headers"
  "x $bar sedx q"
  "x $bar awk '\$2 != \"lo\" {found=1} END {exit !found}'"
  "x $bar awk '!found && /y/ {print; found = 1}'"
  "x $bar awk '{n++} END { if (n) exit 0; exit 1 }'"
  "x $bar awk '{ exit_code = 1 }'"
  "x $bar awk -f prog.awk"
  "x $bar awk '
    \$0 == begin { skip = 1; next }
    !skip { print }
  ' $bar sort"
  "x $bar sed 's/q/r/'"
  "x $bar sed 's/a/q/g'"
  "x $bar sed -n 's/x/\\1/p'"
  "x $bar sed '\$q'"
  "x $bar sed -e 's/a/b/' -e 's/q/r/'"
  "x $bar sed 'y/abc/xyq/'"
)
# Only in a YAML file.
good_yaml=(
  "      run: $bar
        grep -qF 'x' file"
  "- run: $bar-
    head -n1 file"
)
i=0
for case in "${bad[@]}"; do
  i=$((i + 1))
  for ext in sh yml; do
    printf '%s\n' "$case" > "$TMP/bad-$i.$ext"
    [ -n "$(find_early_exit_pipes "$TMP/bad-$i.$ext")" ] \
      || fail "self-test: the check did not find an early-exit reader on a pipe in a .$ext file: $case"
  done
done
i=0
for case in "${good[@]}" "${good_yaml[@]}"; do
  i=$((i + 1))
  printf '%s\n' "$case" > "$TMP/good-$i.yml"
  found=$(find_early_exit_pipes "$TMP/good-$i.yml")
  [ -z "$found" ] || fail "self-test: the check flagged a safe line: $found"
done
for case in "${good[@]}"; do
  i=$((i + 1))
  printf '%s\n' "$case" > "$TMP/good-$i.sh"
  found=$(find_early_exit_pipes "$TMP/good-$i.sh")
  [ -z "$found" ] || fail "self-test: the check flagged a safe line: $found"
done
# In a shell script, `name: |` is a pipe.
printf '%s\n' "${good_yaml[0]}" > "$TMP/yaml-in-shell.sh"
[ -n "$(find_early_exit_pipes "$TMP/yaml-in-shell.sh")" ] \
  || fail "self-test: the check skipped a pipe that looks like a YAML block scalar in a shell script"
# A multi-line awk program ends at its closing quote: the next line is a new
# command.
printf '%s\n' "x $bar awk '" "  { print }" "'" "head -n1 file" > "$TMP/program-end.sh"
found=$(find_early_exit_pipes "$TMP/program-end.sh")
[ -z "$found" ] || fail "self-test: the check read past the end of an awk program: $found"
# Each finding names its file and its first line.
printf '%s\n' "ok" "x $bar head -n1" > "$TMP/where.sh"
found=$(find_early_exit_pipes "$TMP/where.sh")
[ "${found%%: *}" = "$TMP/where.sh:2" ] || fail "self-test: the check gave a wrong location: $found"

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
  lib/aic/status.sh template/Dockerfile tests/test-aic-early-exit-pipes.sh; do
  grep -Fxq "$need" <(printf '%s\n' "${files[@]}") || fail "the check does not read $need"
done

found=$(find_early_exit_pipes "${files[@]}")
[ -z "$found" ] || fail "a command pipes into a reader that exits early (racy under pipefail; capture the output first):
$found"

echo "OK: no reader that exits early reads a pipe (${#files[@]} files)"
