#!/usr/bin/env bash
# The npm package must carry every template file that apply_template() reads.
# A missing managed template file makes every `aic init`/`aic sync` fail, and
# the smoke tests run from a git checkout, so only this test sees the package.
#
# npm 12 leaves a file named .gitignore out of the package even when
# package.json "files" names it (npm 11 kept it). The template therefore ships
# it as template/gitignore. The rule below fails on a dotfile that npm
# excludes, so this test catches the problem with any npm version.
#
# Offline: `npm pack` reads only the staged tree. Lifecycle scripts are off.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export XDG_STATE_HOME="$TMP/state"
export XDG_CACHE_HOME="$TMP/cache"
export XDG_CONFIG_HOME="$TMP/config"
export npm_config_cache="$TMP/npm-cache"
export npm_config_update_notifier=false
export npm_config_fund=false
export npm_config_audit=false
export CI=1 AIC_NO_UPDATE_CHECK=1
unset COMPOSE_PROJECT_NAME
mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v npm >/dev/null 2>&1 || fail "npm is required for the package test"
command -v git >/dev/null 2>&1 || fail "git is required for the package test"

# Stage the tracked and untracked-but-not-ignored files of the working tree,
# so the test packs the current change and not a local .DS_Store or cache.
stage="$TMP/stage"
mkdir -p "$stage"
git -C "$ROOT" ls-files -z --cached --others --exclude-standard \
  | while IFS= read -r -d '' path; do
      if [ -f "$ROOT/$path" ]; then printf '%s\0' "$path"; fi
    done > "$TMP/stage.list"
(cd "$ROOT" && tar -c -f - --null -T "$TMP/stage.list") | (cd "$stage" && tar -x -f -)

# Files the template needs, from the repository, before any junk is planted.
(cd "$stage" && find template -type f -print | LC_ALL=C sort) > "$TMP/template.list"
[ -s "$TMP/template.list" ] || fail "staged tree has no template files"

# npm drops these names from a package however "files" lists them.
while IFS= read -r path; do
  case "${path##*/}" in
    .gitignore|.npmignore|.npmrc|package-lock.json|.git|CVS|.svn|.hg|.lock-wscript|.wafpickle-*|config.gypi|npm-debug.log|.DS_Store|._*)
      fail "$path: npm leaves this file out of the package; ship it without the leading dot (see apply_template)" ;;
  esac
done < "$TMP/template.list"

# Junk that package.json "files" must exclude.
mkdir -p "$stage/template/hooks/__pycache__"
: > "$stage/template/.DS_Store"
: > "$stage/template/Thumbs.db"
: > "$stage/template/hooks/__pycache__/agent-status.cpython-312.pyc"
: > "$stage/template/post-create.pyc"

# Print the packed paths from `npm pack --json`. npm <= 11 prints an array
# with one entry; npm 12 prints an object keyed by the package name. Any other
# shape fails.
pack_paths() {
  node -e '
    const fs = require("fs");
    const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const name = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).name;
    let entry;
    if (Array.isArray(j)) {
      if (j.length === 1) entry = j[0];
    } else if (j && typeof j === "object") {
      const keys = Object.keys(j);
      if (keys.length === 1 && keys[0] === name) entry = j[name];
    }
    if (!entry || entry.name !== name || !Array.isArray(entry.files)) {
      console.error("unexpected npm pack --json shape");
      process.exit(1);
    }
    if (process.argv[3] === "filename") {
      process.stdout.write(entry.filename + "\n");
    } else {
      for (const f of entry.files) process.stdout.write(f.path + "\n");
    }
  ' "$1" "$stage/package.json" "${2:-files}"
}

(cd "$stage" && npm pack --dry-run --json --ignore-scripts 2>/dev/null) > "$TMP/dry.json" \
  || fail "npm pack --dry-run failed"
pack_paths "$TMP/dry.json" | LC_ALL=C sort > "$TMP/packed.list" \
  || fail "could not parse npm pack --dry-run --json"

has() { grep -Fxq "$1" "$TMP/packed.list"; }

for path in aic package.json LICENSE README.md CHANGELOG.md; do
  has "$path" || fail "package is missing $path"
done

# Every lib/ module that aic runs, and every module they import. The validator
# fails closed without them, so a package without lib/ refuses every project.
(cd "$stage" && find lib -type f -print | LC_ALL=C sort) > "$TMP/lib.list"
grep -Fxq lib/validate-cli.mjs "$TMP/lib.list" || fail "repository has no lib/validate-cli.mjs"
while IFS= read -r path; do
  has "$path" || fail "package is missing $path"
done < "$TMP/lib.list"

# aic sources the CLI modules in its explicit load list. Every listed module
# is in the package, and lib/aic/ holds no file that the list leaves out (an
# unlisted module never loads, so its functions would be missing at run time).
sed -n '/^for aic_module in /,/; do$/p' "$ROOT/aic" \
  | sed -e 's/^for aic_module in //' -e 's/; do$//' -e 's/\\$//' \
  | tr -s ' ' '\n' | sed '/^$/d' > "$TMP/aic-load.list"
[ -s "$TMP/aic-load.list" ] || fail "aic has no module load list"
while IFS= read -r name; do
  case "$name" in
    *[!a-z0-9-]*) fail "unexpected aic module name in the load list: $name" ;;
  esac
  has "lib/aic/$name.sh" || fail "package is missing lib/aic/$name.sh, which aic loads"
done < "$TMP/aic-load.list"
sed 's|.*|lib/aic/&.sh|' "$TMP/aic-load.list" | LC_ALL=C sort > "$TMP/aic-modules.list"
grep '^lib/aic/' "$TMP/lib.list" > "$TMP/aic-module-files.list" || true
cmp -s "$TMP/aic-modules.list" "$TMP/aic-module-files.list" \
  || fail "the files in lib/aic/ and the module load list in aic differ"

# The code of aic is in aic and its modules; read all of them below.
aic_sources=("$ROOT/aic" "$ROOT"/lib/aic/*.sh)

grep -oh '\$AIC_HOME/lib/[A-Za-z0-9._-]*' "${aic_sources[@]}" | sed 's|^\$AIC_HOME/||' \
  | LC_ALL=C sort -u > "$TMP/aic-runs.list"
# The two helpers that every install needs; an empty list means the scan broke.
for path in lib/cli.mjs lib/validate-cli.mjs; do
  grep -Fxq "$path" "$TMP/aic-runs.list" || fail "aic no longer runs $path; update this test"
done
while IFS= read -r path; do
  # lib/aic is the module directory of the load loop; the checks above cover it.
  [ "$path" != lib/aic ] || continue
  has "$path" || fail "package is missing $path, which aic runs"
done < "$TMP/aic-runs.list"

# Every template file in the repository is in the package.
while IFS= read -r path; do
  has "$path" || fail "package is missing $path"
done < "$TMP/template.list"

# Every literal template path that aic reads, and the names the review named.
grep -oh '"\$src/[A-Za-z0-9._-]*"\|\$TEMPLATE_DIR/[A-Za-z0-9._-]*' "${aic_sources[@]}" \
  | sed -e 's/^"//' -e 's/"$//' -e 's|^\$src/||' -e 's|^\$TEMPLATE_DIR/||' \
  | LC_ALL=C sort -u > "$TMP/aic-reads.list"
grep -Fxq gitignore "$TMP/aic-reads.list" \
  || fail "aic no longer reads template/gitignore; update this test"
while IFS= read -r name; do
  case "$name" in ''|.) continue ;; esac
  if [ "$name" = hooks ]; then
    grep -q '^template/hooks/.' "$TMP/packed.list" || fail "package has no template/hooks files"
    continue
  fi
  has "template/$name" || fail "package is missing template/$name, which aic reads"
done < "$TMP/aic-reads.list"
for path in template/gitignore template/devcontainer.json template/docker-compose.pull.yml \
  template/docker-compose.build.yml template/README.md template/.zshrc template/post-create.py \
  template/Dockerfile template/aic-firewall template/aic-chown-volumes template/aic-lock-user-config \
  template/hooks/pre-tool-use.sh template/hooks/opencode-guardrail.js \
  template/hooks/agent-status.py template/hooks/claude-settings.json; do
  has "$path" || fail "package is missing $path"
done

if grep -E '(^|/)(__pycache__/|\.DS_Store$|Thumbs\.db$|[^/]*\.py[cod]$)' "$TMP/packed.list"; then
  fail "package contains cache or OS junk (listed above)"
fi

# Pack for real, unpack the tarball, and run `aic init` from it in both modes.
mkdir -p "$TMP/tarball" "$TMP/unpacked"
(cd "$stage" && npm pack --json --ignore-scripts --pack-destination "$TMP/tarball" 2>/dev/null) \
  > "$TMP/pack.json" || fail "npm pack failed"
tarball=$(pack_paths "$TMP/pack.json" filename) || fail "could not parse npm pack --json"
case "$tarball" in
  */*|''|.*) fail "unexpected tarball name: $tarball" ;;
esac
[ -f "$TMP/tarball/$tarball" ] || fail "npm pack wrote no $tarball"
tar -xzf "$TMP/tarball/$tarball" -C "$TMP/unpacked"
pkg="$TMP/unpacked/package"
[ -x "$pkg/aic" ] || fail "packed aic is not executable"

for mode in pull build; do
  project="$TMP/project-$mode"
  mkdir -p "$project"
  git -C "$project" init -q
  flag=""
  [ "$mode" = build ] && flag="--build"
  (cd "$project" && AIC_HOME="$pkg" "$pkg/aic" init $flag --with codex --shell zsh >"$TMP/init-$mode.log" 2>&1) \
    || { cat "$TMP/init-$mode.log" >&2; fail "aic init ($mode) from the packed tarball failed"; }
  [ -f "$project/.devcontainer/.gitignore" ] \
    || fail "aic init ($mode) from the packed tarball wrote no .devcontainer/.gitignore"
  cmp -s "$ROOT/template/gitignore" "$project/.devcontainer/.gitignore" \
    || fail "aic init ($mode) wrote a .devcontainer/.gitignore that differs from template/gitignore"
  grep -q '^\.env$' "$project/.devcontainer/.gitignore" \
    || fail "aic init ($mode) .devcontainer/.gitignore does not ignore .env"
  [ ! -e "$project/.devcontainer/gitignore" ] \
    || fail "aic init ($mode) left the template name .devcontainer/gitignore"
  for name in devcontainer.json docker-compose.yml README.md .env; do
    [ -f "$project/.devcontainer/$name" ] || fail "aic init ($mode) wrote no .devcontainer/$name"
  done
  if [ "$mode" = build ]; then
    for name in Dockerfile post-create.py aic-firewall aic-chown-volumes aic-lock-user-config \
      .zshrc hooks/pre-tool-use.sh hooks/opencode-guardrail.js hooks/agent-status.py \
      hooks/claude-settings.json; do
      [ -f "$project/.devcontainer/$name" ] || fail "aic init --build wrote no .devcontainer/$name"
    done
  fi
  # The validator runs from the package (no Docker: it reads the files only).
  node "$pkg/lib/validate-cli.mjs" >/dev/null 2>&1 \
    && fail "packed validator accepted a call without arguments"
  node -e 'import(process.argv[1]).then(m => { if (typeof m.analyzeResolvedConfig !== "function") process.exit(1); })' \
    "$pkg/lib/validate.mjs" || fail "packed lib/validate.mjs does not export analyzeResolvedConfig"
  # A second sync from the package is idempotent and keeps the file.
  (cd "$project" && AIC_HOME="$pkg" "$pkg/aic" sync >"$TMP/sync-$mode.log" 2>&1) \
    || { cat "$TMP/sync-$mode.log" >&2; fail "aic sync ($mode) from the packed tarball failed"; }
  cmp -s "$ROOT/template/gitignore" "$project/.devcontainer/.gitignore" \
    || fail "aic sync ($mode) changed .devcontainer/.gitignore"
done

echo "OK: npm package carries every managed template file; aic init/sync work from the tarball"
