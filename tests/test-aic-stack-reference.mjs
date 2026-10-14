// Tests for docs/user/stack-reference.md, the stack-to-files reference.
//
// Tools and the /aicontainer:setup skill find a stack by its heading and copy
// its snippets into .devcontainer/. So this test guards two things:
//   - the structure: each `## Stack: <name>` section has the same level-3
//     headings in the same order, and each code block names its target file;
//   - the content: the presets, chown-paths, and override snippets pass the
//     same rules as aic. With Docker Compose 2.35+, the merged snippets of all
//     stacks also go through a real `aic validate`.
//
// Run: node tests/test-aic-stack-reference.mjs

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FIREWALL_PRESETS, firewallPresetsProblems } from '../lib/validate.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const AIC = path.join(REPO, 'aic');
const PAGE = fs.readFileSync(path.join(REPO, 'docs', 'user', 'stack-reference.md'), 'utf8');
const SKILL = fs.readFileSync(path.join(REPO, 'tools', 'claude-plugin', 'skills', 'setup', 'SKILL.md'), 'utf8');

const SUBHEADINGS = [
  'Detect',
  'Toolchain',
  'Named volumes and chown-paths',
  'Post-create',
  'Editor',
  'Firewall presets',
  'Trust and caveats',
];
// Tool caches that a toolchain block moves under ~/.cache for a named volume.
const CACHE_KEYS = new Set(['GOMODCACHE', 'GOCACHE', 'CARGO_HOME', 'BUNDLE_PATH', 'COMPOSER_CACHE_DIR', 'GRADLE_USER_HOME']);
const TARGET_FILES = new Set([
  'Dockerfile.project', 'docker-compose.override.yml', 'chown-paths', 'post-create.project.sh',
  'vscode-extensions', 'vscode-settings.json', 'firewall-presets', 'firewall-allowlist',
]);

// Split the page into level-2 sections: [{ title, lines }].
function sections(text) {
  const out = [];
  let fence = false;
  for (const line of text.split('\n')) {
    if (/^```/.test(line)) fence = !fence;
    if (!fence && /^## /.test(line)) out.push({ title: line.slice(3).trim(), lines: [] });
    else if (out.length) out[out.length - 1].lines.push(line);
  }
  return out;
}

// The code blocks of a section: [{ target, lang, body, sub }]. `target` is the
// file that the closest non-blank line before the block names, or ''.
function blocks(lines) {
  const out = [];
  let sub = '';
  for (let i = 0; i < lines.length; i++) {
    const open = /^```(\S*)\s*$/.exec(lines[i]);
    if (!open) {
      if (/^### /.test(lines[i])) sub = lines[i].slice(4).trim();
      continue;
    }
    let j = i - 1;
    while (j >= 0 && lines[j].trim() === '') j--;
    const named = j >= 0 ? /^`\.devcontainer\/([^`]+)`:$/.exec(lines[j].trim()) : null;
    const body = [];
    for (i++; i < lines.length && !/^```\s*$/.test(lines[i]); i++) body.push(lines[i]);
    out.push({ target: named ? named[1] : '', lang: open[1], body: body.join('\n'), sub });
  }
  return out;
}

// GitHub heading anchor.
const slug = title => title.toLowerCase().replace(/[^\p{L}\p{N} _-]/gu, '').replace(/ /g, '-');

const all = sections(PAGE);
const stacks = all.filter(s => s.title.startsWith('Stack: '));
const stackBlocks = stacks.flatMap(s => blocks(s.lines).map(b => ({ ...b, stack: s.title })));
const byTarget = name => stackBlocks.filter(b => b.target === name);

test('the page has the stacks that the skill and tools look for', () => {
  const names = stacks.map(s => s.title.slice('Stack: '.length));
  for (const name of ['Node.js', 'Python', 'Go', 'Rust', 'Ruby', 'PHP', 'Java', 'C and C++']) {
    assert.ok(names.includes(name), `missing ## Stack: ${name}`);
  }
  assert.equal(new Set(names).size, names.length, 'a stack heading is duplicated');
});

test('each stack section has the same level-3 headings in the same order', () => {
  for (const stack of stacks) {
    let fence = false;
    const subs = [];
    for (const line of stack.lines) {
      if (/^```/.test(line)) fence = !fence;
      if (!fence && /^### /.test(line)) subs.push(line.slice(4).trim());
      assert.ok(fence || !/^#### /.test(line), `${stack.title}: use only level-3 subheadings`);
    }
    assert.deepEqual(subs, SUBHEADINGS, `${stack.title}: subheadings differ`);
  }
});

test('the detect table links to each stack section', () => {
  const anchors = new Set(PAGE.split('\n').filter(l => /^#{2,3} /.test(l)).map(l => slug(l.replace(/^#+ /, ''))));
  for (const stack of stacks) {
    assert.ok(PAGE.includes(`(#${slug(stack.title)})`), `no link to ${stack.title}`);
  }
  for (const [, anchor] of PAGE.matchAll(/\]\(#([^)]+)\)/g)) {
    assert.ok(anchors.has(anchor), `link to a missing section: #${anchor}`);
  }
});

test('each code block in a stack section names a project-owned target file', () => {
  for (const block of stackBlocks) {
    assert.ok(TARGET_FILES.has(block.target), `${block.stack} / ${block.sub}: block has no target line (${block.body.split('\n')[0]})`);
  }
});

test('the firewall-presets snippets name only known presets', () => {
  const presets = byTarget('firewall-presets');
  assert.ok(presets.length > 0);
  for (const block of presets) {
    assert.deepEqual(firewallPresetsProblems(block.body), [], `${block.stack}`);
  }
  // Each preset that aic knows has a stack that uses it, except semgrep (in the image).
  const used = new Set(presets.flatMap(b => b.body.split('\n').map(l => l.trim()).filter(Boolean)));
  for (const name of FIREWALL_PRESETS.filter(n => n !== 'semgrep')) {
    assert.ok(used.has(name), `no stack uses the ${name} preset`);
  }
});

test('the chown-paths snippets use only approved, canonical mountpoints', () => {
  for (const block of byTarget('chown-paths')) {
    for (const line of block.body.split('\n').filter(l => l.trim() && !l.startsWith('#'))) {
      assert.match(line, /^(\/workspace|\/home\/vscode\/\.cache)\/[A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+)*$/, `${block.stack}: ${line}`);
      assert.equal(path.posix.normalize(line), line, `${block.stack}: ${line} is not canonical`);
      assert.doesNotMatch(line, /^\/workspace\/\.(git|devcontainer)(\/|$)/, `${block.stack}: ${line}`);
    }
  }
});

// The named volumes, environment entries, and chown-paths of every stack
// override snippet, merged as the "Combine stacks" section says.
function mergedOverride() {
  const env = new Map(), mounts = [], names = new Set(), chown = new Set();
  for (const block of byTarget('docker-compose.override.yml')) {
    let where = '';
    for (const line of block.body.split('\n')) {
      if (/^\S/.test(line)) { where = line.trim(); continue; }
      if (/^    \S/.test(line)) { where = line.trim(); continue; }
      let m;
      if (where === 'environment:' && (m = /^      ([A-Z0-9_]+): (.+)$/.exec(line))) env.set(m[1], m[2]);
      else if (where === 'volumes:' && (m = /^      - ([a-z0-9-]+):(\/\S+)$/.exec(line))) mounts.push([m[1], m[2]]);
      else if (where === 'volumes:' && (m = /^  ([a-z0-9-]+):$/.exec(line))) names.add(m[1]);
      else if (line.trim() && !/^  devcontainer:$/.test(line)) assert.fail(`${block.stack}: unexpected override line: ${line}`);
    }
  }
  for (const block of byTarget('chown-paths')) {
    for (const line of block.body.split('\n')) if (line.trim()) chown.add(line.trim());
  }
  return { env, mounts, names, chown };
}

test('the override snippets add only named volumes and plain literal values', () => {
  const { env, mounts, names, chown } = mergedOverride();
  assert.ok(mounts.length > 0);
  for (const [key, value] of env) {
    assert.doesNotMatch(value, /\$/, `${key} reads a host variable`);
    assert.doesNotMatch(key, /^(PATH|HOME|ZDOTDIR|BASH_ENV|ENV|LD_.*|XDG_.*|GIT_CONFIG_.*|DOCKER_.*|CODEX_HOME|OPENCODE_.*|CLAUDE_CONFIG_DIR|NPM_CONFIG_.*)$/, `${key} is a protected key`);
  }
  for (const [name, target] of mounts) {
    assert.ok(names.has(name), `volume ${name} is not declared`);
    assert.ok(chown.has(target), `${target} has a named volume but no chown-paths line`);
    assert.ok(!name.startsWith('aic-'), `${name} uses the reserved aic- prefix`);
  }
  assert.equal(new Set(mounts.map(([n]) => n)).size, mounts.length, 'two stacks use the same volume name');
  for (const target of chown) {
    assert.ok(mounts.some(([, t]) => t === target), `chown-paths line ${target} has no named volume`);
  }
});

test('the toolchain snippets start as root and end as vscode', () => {
  const docker = byTarget('Dockerfile.project').filter(b => b.sub === 'Toolchain');
  assert.ok(docker.length > 0);
  for (const block of docker) {
    const lines = block.body.split('\n').filter(l => /^[A-Z]+ /.test(l));
    assert.doesNotMatch(block.body, /^FROM /m, `${block.stack}: a toolchain block must not have its own FROM`);
    assert.equal(lines[0], 'USER root', `${block.stack}`);
    assert.equal(lines.filter(l => l.startsWith('USER ')).at(-1), 'USER vscode', `${block.stack}`);
    // The agent can write each named volume, and the volumes survive a
    // rebuild: no volume directory goes on PATH, and Go must not keep
    // downloaded toolchains in its module cache.
    for (const [, value] of block.body.matchAll(/^ENV PATH="([^"]+)"/gm)) {
      for (const dir of value.split(':')) {
        assert.doesNotMatch(dir, /^\/(workspace|home\/vscode\/\.cache)(\/|$)/, `${block.stack}: volume directory ${dir} on PATH`);
      }
    }
    assert.doesNotMatch(block.body, /GOTOOLCHAIN=(?!local\b)/, `${block.stack}: GOTOOLCHAIN must be local`);
    // A cache that the image moves for a named volume must be under ~/.cache,
    // and the same stack must mount a named volume there.
    const targets = stackBlocks.filter(b => b.stack === block.stack && b.target === 'docker-compose.override.yml')
      .flatMap(b => [...b.body.matchAll(/^      - [a-z0-9-]+:(\/\S+)$/gm)].map(m => m[1]));
    for (const [, key, value] of block.body.matchAll(/\b([A-Z_]+)=(\/\S+)/g)) {
      if (!CACHE_KEYS.has(key)) continue;
      assert.match(value, /^\/home\/vscode\/\.cache\//, `${block.stack}: ${key} is outside ~/.cache`);
      assert.ok(targets.includes(value), `${block.stack}: ${key}=${value} has no named volume`);
    }
  }
});

test('the setup skill reads this page from the tag of the installed aic', () => {
  assert.match(SKILL, /stack-reference\.md/);
  assert.match(SKILL, /raw\.githubusercontent\.com\/stefanoginella\/aicontainer\/vX\.Y\.Z\/docs\/user\//);
  assert.doesNotMatch(SKILL, /aicontainer\/main\/docs/, 'the skill must not fetch the docs from main');
  assert.match(SKILL, /\(since …\)/, 'the skill must apply the version markers when it reads main');
});

// --- version markers ----------------------------------------------------------

const MARKER = /\(since (Unreleased|v(\d+)\.(\d+)\.(\d+))\)/g;
const HAS_MARKER = new RegExp(MARKER.source);
const GATED = ['firewall-presets', 'firewall-enable'];
const VERSION = JSON.parse(fs.readFileSync(path.join(REPO, 'package.json'), 'utf8')).version;
const CHANGELOG = fs.readFileSync(path.join(REPO, 'CHANGELOG.md'), 'utf8');

test('each version marker names Unreleased or a released version', () => {
  const markers = [...PAGE.matchAll(MARKER)];
  assert.ok(markers.length > 0);
  for (const [text, label, ...parts] of markers) {
    if (label === 'Unreleased') continue;
    const version = parts.slice(0, 3).join('.');
    assert.ok(CHANGELOG.includes(`## [${version}]`), `${text}: no such release in CHANGELOG.md`);
    const cmp = (a, b) => a.split('.').map(Number).reduce((r, n, i) => r || n - b.split('.').map(Number)[i], 0);
    assert.ok(cmp(version, VERSION) <= 0, `${text} is newer than package.json ${VERSION}`);
  }
  // The explanation of the form is inline code; every other "(since " is a marker.
  assert.doesNotMatch(PAGE.replace(MARKER, '').replace(/`[^`\n]*`/g, ''), /\(since /, 'a version marker has the wrong form');
});

test('each mention of a version-gated item carries a marker', () => {
  // Prose paragraphs, list items, and table rows; code blocks and the target
  // lines before them are exempt.
  const units = [];
  let fence = false, para = [];
  const flush = () => { if (para.length) units.push(para.join(' ')); para = []; };
  for (const line of PAGE.split('\n')) {
    if (/^```/.test(line)) { flush(); fence = !fence; continue; }
    if (fence) continue;
    if (/^\s*$/.test(line) || /^#/.test(line)) { flush(); if (/^#/.test(line)) units.push(line); continue; }
    if (/^\|/.test(line)) { flush(); units.push(line); continue; }
    if (/^\s*(-|\d+\.) /.test(line)) flush();
    para.push(line.trim());
  }
  flush();
  let mentions = 0;
  for (const unit of units) {
    if (/^`\.devcontainer\/[^`]+`:$/.test(unit)) continue;
    if (!GATED.some(item => unit.includes(item))) continue;
    if (/^### Firewall presets$/.test(unit)) continue;
    mentions++;
    assert.match(unit, HAS_MARKER, `no version marker: ${unit}`);
  }
  assert.ok(mentions > 0);
  for (const item of GATED) {
    assert.match(PAGE, new RegExp(`^\\| \`\\.devcontainer/${item}\` \\| \\(since `, 'm'), `${item} is missing in the marker table`);
  }
});

test('the release writes its version into the Unreleased markers', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'aic-stackref-promote-'));
  after(() => fs.rmSync(dir, { recursive: true, force: true }));
  fs.mkdirSync(path.join(dir, 'scripts'));
  fs.mkdirSync(path.join(dir, 'docs', 'user'), { recursive: true });
  fs.copyFileSync(path.join(REPO, 'scripts', 'promote-changelog.mjs'), path.join(dir, 'scripts', 'promote-changelog.mjs'));
  const pkg = JSON.parse(fs.readFileSync(path.join(REPO, 'package.json'), 'utf8'));
  assert.match(pkg.scripts.version, /git add [^&|;]*docs\/user\/stack-reference\.md/, 'the version script must stage the page');
  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({ ...pkg, version: '99.0.0' }));
  const changelog = CHANGELOG.includes('## [Unreleased]\n\n## [')
    ? CHANGELOG.replace('## [Unreleased]\n', '## [Unreleased]\n\n### Added\n\n- **Test entry.**\n')
    : CHANGELOG;
  fs.writeFileSync(path.join(dir, 'CHANGELOG.md'), changelog);
  const page = PAGE.includes('(since Unreleased)') ? PAGE : `${PAGE}\n(since Unreleased)\n`;
  fs.writeFileSync(path.join(dir, 'docs', 'user', 'stack-reference.md'), page);
  const res = spawnSync(process.execPath, [path.join(dir, 'scripts', 'promote-changelog.mjs')], { encoding: 'utf8' });
  assert.equal(res.status, 0, res.stderr);
  const promoted = fs.readFileSync(path.join(dir, 'docs', 'user', 'stack-reference.md'), 'utf8');
  assert.doesNotMatch(promoted, /\(since Unreleased\)/);
  assert.equal(promoted.split('(since v99.0.0)').length, page.split('(since Unreleased)').length);
});

// --- a real aic validate of the merged snippets -----------------------------

const compose = spawnSync('docker', ['compose', 'version', '--short'], { encoding: 'utf8' });
const composeOk = compose.status === 0
  && (([a, b]) => a > 2 || (a === 2 && b >= 35))((/(\d+)\.(\d+)/.exec(compose.stdout) || [0, 0, 0]).slice(1).map(Number));

test('aic validate accepts the merged snippets, and the build is the only trust finding', { skip: !composeOk && 'needs Docker Compose 2.35+' }, () => {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'aic-stackref-'));
  after(() => fs.rmSync(scratch, { recursive: true, force: true }));
  const env = { ...process.env };
  for (const name of ['COMPOSE_PROJECT_NAME', 'AIC_PROJECT_NAME', 'COMPOSE_ENV_FILES', 'COMPOSE_DISABLE_ENV_FILE',
    'AIC_NO_OVERRIDE_SCAN', 'AIC_UNSAFE_ONCE_HASH', 'CI']) delete env[name];
  Object.assign(env, {
    HOME: path.join(scratch, 'home'),
    XDG_STATE_HOME: path.join(scratch, 'state'),
    XDG_CACHE_HOME: path.join(scratch, 'cache'),
    AIC_HOME: REPO,
    AIC_NO_UPDATE_CHECK: '1',
    DOCKER_CONFIG: process.env.DOCKER_CONFIG || path.join(os.homedir(), '.docker'),
  });
  fs.mkdirSync(env.HOME);
  const dir = path.join(scratch, 'project');
  fs.mkdirSync(dir);
  assert.equal(spawnSync('git', ['-C', dir, 'init', '-q']).status, 0);
  const aic = args => spawnSync(AIC, args, { cwd: dir, encoding: 'utf8', env, input: '' });
  let res = aic(['init', '--with', 'claude-code', '--shell', 'zsh']);
  assert.equal(res.status, 0, res.stderr);
  const dc = path.join(dir, '.devcontainer');
  const tag = /ghcr\.io\/stefanoginella\/aicontainer:(v[0-9.]+)/.exec(fs.readFileSync(path.join(dc, 'docker-compose.yml'), 'utf8'))[1];

  const { env: values, mounts, names, chown } = mergedOverride();
  const override = build => [
    'services:',
    '  devcontainer:',
    ...(build ? [`    image: myproject-devcontainer:${tag}`, '    build:', '      context: .', '      dockerfile: Dockerfile.project'] : []),
    '    environment:',
    ...[...values].map(([k, v]) => `      ${k}: ${v}`),
    '    volumes:',
    ...mounts.map(([n, t]) => `      - ${n}:${t}`),
    'volumes:',
    ...[...names].map(n => `  ${n}:`),
    '',
  ].join('\n');
  const presets = new Set(byTarget('firewall-presets').flatMap(b => b.body.split('\n').filter(Boolean)));
  fs.writeFileSync(path.join(dc, 'docker-compose.override.yml'), override(false));
  fs.writeFileSync(path.join(dc, 'chown-paths'), [...chown, ''].join('\n'));
  fs.writeFileSync(path.join(dc, 'firewall-presets'), [...presets, ''].join('\n'));
  fs.writeFileSync(path.join(dc, 'firewall-enable'), '');
  res = aic(['sync']);
  assert.equal(res.status, 0, res.stderr);
  res = aic(['validate']);
  assert.equal(res.status, 0, `${res.stdout}${res.stderr}`);
  assert.match(res.stdout + res.stderr, /configuration valid/);

  const toolchains = byTarget('Dockerfile.project').filter(b => b.sub === 'Toolchain').map(b => b.body);
  fs.writeFileSync(path.join(dc, 'Dockerfile.project'), [`FROM ghcr.io/stefanoginella/aicontainer:${tag}`, ...toolchains, ''].join('\n'));
  fs.writeFileSync(path.join(dc, 'docker-compose.override.yml'), override(true));
  res = aic(['validate']);
  assert.equal(res.status, 1, `${res.stdout}${res.stderr}`);
  const findings = (res.stdout + res.stderr).split('\n').filter(l => /^\s+! /.test(l));
  assert.equal(findings.length, 1, res.stdout + res.stderr);
  assert.match(findings[0], /override build executes a project-owned Dockerfile as root/);
});
