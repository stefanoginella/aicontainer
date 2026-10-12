// Unit tests for the host-side helpers that aic runs through lib/cli.mjs:
// lib/project-identity.mjs, lib/vscode-settings.mjs, lib/trust-hash.mjs, and
// lib/docker-inspect.mjs. No Docker: the inspect cases use hand-written JSON.
// The aic call sites stay covered by test-aic-host-security.sh.
//
// Run: node tests/test-aic-host-helpers.mjs

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  containerIsOwned, isAuxiliaryContainer, ownsSessionVolume, volumeIsSafe, volumeUserIsOwner,
} from '../lib/docker-inspect.mjs';
import { composeNameConflict, createGitControlFiles } from '../lib/project-identity.mjs';
import { hashValidationInputs } from '../lib/trust-hash.mjs';
import { vscodeSettingsBlock } from '../lib/vscode-settings.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CLI = path.join(REPO, 'lib', 'cli.mjs');
const TEMPLATE = path.join(REPO, 'template', 'devcontainer.json');

const scratch = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'aic-helpers-')));
after(() => fs.rmSync(scratch, { recursive: true, force: true }));
let dirs = 0;
const newDir = () => {
  const dir = path.join(scratch, `case-${++dirs}`);
  fs.mkdirSync(dir);
  return dir;
};

// The helpers read paths relative to the current directory, as aic runs them
// from the project root.
function inDir(dir, fn) {
  const cwd = process.cwd();
  process.chdir(dir);
  try { return fn(); } finally { process.chdir(cwd); }
}

const runCli = (args, options = {}) =>
  spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8', ...options });

// --- project-identity.mjs --------------------------------------------------

test('composeNameConflict: the environment wins, after normalization', () => {
  const dir = newDir();
  fs.writeFileSync(path.join(dir, '.env'), 'COMPOSE_PROJECT_NAME=other\n');
  inDir(dir, () => {
    assert.equal(composeNameConflict('aic-api-0123', { COMPOSE_PROJECT_NAME: 'AIC-api-0123' }), '');
    assert.equal(composeNameConflict('aic-api-0123', { COMPOSE_PROJECT_NAME: ' AIC-api-0123.!' }), '');
    assert.equal(composeNameConflict('aic-api-0123', { COMPOSE_PROJECT_NAME: 'aic api 0123' }), 'environment');
    assert.equal(composeNameConflict('aic-api-0123', { COMPOSE_PROJECT_NAME: 'other' }), 'environment');
    // A value that normalizes to nothing falls through to .env.
    assert.equal(composeNameConflict('aic-api-0123', { COMPOSE_PROJECT_NAME: '!!' }), 'dotenv');
  });
});

test('composeNameConflict: the first COMPOSE_PROJECT_NAME line of .env', () => {
  const dir = newDir();
  const env = path.join(dir, '.env');
  inDir(dir, () => {
    assert.equal(composeNameConflict('aic-api-0123', {}), '', 'no .env');
    fs.writeFileSync(env, 'FOO=1\n# COMPOSE_PROJECT_NAME=x\n');
    assert.equal(composeNameConflict('aic-api-0123', {}), '', 'no name line');
    fs.writeFileSync(env, 'COMPOSE_PROJECT_NAME= AIC-API-0123 \nCOMPOSE_PROJECT_NAME=other\n');
    assert.equal(composeNameConflict('aic-api-0123', {}), '', 'first line matches');
    fs.writeFileSync(env, 'FOO=1\nCOMPOSE_PROJECT_NAME=app\n');
    assert.equal(composeNameConflict('aic-api-0123', {}), 'dotenv');
  });
});

test('composeNameConflict: a .env that is not a plausible file is unreadable', () => {
  const dir = newDir();
  const env = path.join(dir, '.env');
  inDir(dir, () => {
    fs.mkdirSync(env);
    assert.equal(composeNameConflict('aic-api-0123', {}), '', 'a directory is ignored');
    fs.rmdirSync(env);
    fs.writeFileSync(env, 'COMPOSE_PROJECT_NAME=aic-api-0123\n' + 'x'.repeat(1048576));
    assert.equal(composeNameConflict('aic-api-0123', {}), 'unreadable', 'too large');
    fs.rmSync(env);
    if (spawnSync('mkfifo', [env]).status === 0) {
      assert.equal(composeNameConflict('aic-api-0123', {}), 'unreadable', 'a FIFO');
    }
  });
});

test('createGitControlFiles: creates missing files, never follows or replaces', () => {
  const dir = newDir();
  fs.mkdirSync(path.join(dir, '.git'));
  inDir(dir, () => createGitControlFiles());
  assert.equal(fs.readFileSync(path.join(dir, '.git', 'commondir'), 'utf8'), '.\n');
  assert.equal(fs.readFileSync(path.join(dir, '.git', 'config.worktree'), 'utf8'), '');

  fs.writeFileSync(path.join(dir, '.git', 'commondir'), '../other\n');
  inDir(dir, () => createGitControlFiles());
  assert.equal(fs.readFileSync(path.join(dir, '.git', 'commondir'), 'utf8'), '../other\n');

  const planted = newDir();
  fs.mkdirSync(path.join(planted, '.git'));
  const target = path.join(scratch, `outside-${dirs}`);
  fs.symlinkSync(target, path.join(planted, '.git', 'commondir'));
  inDir(planted, () => createGitControlFiles());
  assert.equal(fs.existsSync(target), false, 'followed a planted symlink');
  assert.equal(fs.lstatSync(path.join(planted, '.git', 'commondir')).isSymbolicLink(), true);

  const noGit = newDir();
  assert.throws(() => inDir(noGit, () => createGitControlFiles()), { code: 'ENOENT' });
});

// --- vscode-settings.mjs -----------------------------------------------------

test('vscodeSettingsBlock: re-serializes a strict JSON object as leading-comma lines', () => {
  const dir = newDir();
  const file = path.join(dir, 'vscode-settings.json');
  fs.writeFileSync(file, '{"editor.tabSize": 2, "files.exclude": {"dist": true}}');
  const result = vscodeSettingsBlock(file, TEMPLATE);
  assert.equal(result.status, 0);
  assert.deepEqual(result.ignored, []);
  assert.equal(result.block, [
    '        ,"editor.tabSize": 2,',
    '          "files.exclude": {',
    '            "dist": true',
    '          }',
  ].join('\n'));
  // Spliced after the last managed setting, the block keeps the object valid.
  assert.deepEqual(JSON.parse(`{"a": 1\n${result.block}}`),
    { a: 1, 'editor.tabSize': 2, 'files.exclude': { dist: true } });
});

test('vscodeSettingsBlock: drops the keys that the template manages', () => {
  const dir = newDir();
  const file = path.join(dir, 'vscode-settings.json');
  fs.writeFileSync(file, '{"terminal.integrated.defaultProfile.linux": "bash", "editor.tabSize": 2}');
  const result = vscodeSettingsBlock(file, TEMPLATE);
  assert.equal(result.status, 0);
  assert.deepEqual(result.ignored, ['terminal.integrated.defaultProfile.linux']);
  assert.equal(result.block, '        ,"editor.tabSize": 2');

  fs.writeFileSync(file, '{"terminal.integrated.defaultProfile.linux": "bash"}');
  assert.deepEqual(vscodeSettingsBlock(file, TEMPLATE),
    { status: 0, block: '', ignored: ['terminal.integrated.defaultProfile.linux'] });
  fs.writeFileSync(file, '{}');
  assert.deepEqual(vscodeSettingsBlock(file, TEMPLATE), { status: 0, block: '', ignored: [] });
});

test('vscodeSettingsBlock: refuses what is not a strict JSON object', () => {
  const dir = newDir();
  const file = path.join(dir, 'vscode-settings.json');
  assert.equal(vscodeSettingsBlock(file, TEMPLATE).status, 2, 'missing file');
  for (const text of ['{"a": 1,}', '// c\n{}', '{"a": 1}}, "x": {']) {
    fs.writeFileSync(file, text);
    assert.equal(vscodeSettingsBlock(file, TEMPLATE).status, 2, text);
  }
  for (const text of ['[]', 'null', '"x"', '1']) {
    fs.writeFileSync(file, text);
    assert.equal(vscodeSettingsBlock(file, TEMPLATE).status, 3, text);
  }
  fs.writeFileSync(file, '{"a": 1}');
  const template = path.join(dir, 'template.json');
  fs.writeFileSync(template, '{"settings": {}}');
  assert.equal(vscodeSettingsBlock(file, template).status, 4, 'no marker');
  assert.throws(() => vscodeSettingsBlock(file, path.join(dir, 'missing.json')), { code: 'ENOENT' });
});

// --- trust-hash.mjs ----------------------------------------------------------

const sha256 = (...parts) => {
  const h = crypto.createHash('sha256');
  for (const part of parts) h.update(part);
  return h.digest('hex');
};

// A fixed project. Modes are set explicitly, so the digest does not depend on
// the umask. No symlink: its lstat mode differs between Linux and macOS.
function fixedProject() {
  const dir = newDir();
  const dev = path.join(dir, '.devcontainer');
  fs.mkdirSync(path.join(dev, 'hooks'), { recursive: true });
  fs.writeFileSync(path.join(dev, 'devcontainer.json'), '{"name": "x"}\n');
  fs.writeFileSync(path.join(dev, 'b.txt'), 'b');
  fs.writeFileSync(path.join(dev, 'hooks', 'run.sh'), '#!/bin/sh\n');
  fs.chmodSync(path.join(dev, 'devcontainer.json'), 0o644);
  fs.chmodSync(path.join(dev, 'b.txt'), 0o600);
  fs.chmodSync(path.join(dev, 'hooks', 'run.sh'), 0o755);
  fs.chmodSync(path.join(dev, 'hooks'), 0o755);
  fs.chmodSync(dev, 0o755);
  const resolved = path.join(dir, 'final.json');
  fs.writeFileSync(resolved, JSON.stringify({
    name: 'aic-x-0123456789ab',
    'x-aic-build': { args: { TZ: 'Europe/Rome' } },
    services: { app: { build: { args: { TZ: 'Europe/Rome', X: '1' } } }, sidecar: null },
  }));
  return { dir, resolved };
}

// Stored approvals hold this digest. The original inline `node -e` in aic
// produced it for the same project, so a change here invalidates every
// stored trust. Do not update the value to make the test pass.
const FIXED_PROJECT_DIGEST = {
  'Europe/Rome': '0f53c85590a796887035cd2af47e4bec760c3005d5c5fce5ce800f3507bef6ce',
  UTC: '39b67583423a537a7e914ff772e9a124b7677e4a38e3e6e3d7f717946a2a2118',
};

test('hashValidationInputs: the digest of a fixed project does not change', () => {
  const { dir, resolved } = fixedProject();
  for (const [tz, digest] of Object.entries(FIXED_PROJECT_DIGEST)) {
    assert.equal(inDir(dir, () => hashValidationInputs(resolved, { TZ: tz })), digest, tz);
  }
  // No TZ in the environment reads as UTC.
  assert.equal(inDir(dir, () => hashValidationInputs(resolved, {})), FIXED_PROJECT_DIGEST.UTC);
});

test('hashValidationInputs: raw bytes when nothing is pinned, framing without a tree', () => {
  const dir = newDir();
  const resolved = path.join(dir, 'final.json');
  inDir(dir, () => {
    assert.equal(hashValidationInputs(resolved, {}), sha256('<resolved-compose>\0', '\0<devcontainer-tree>\0'));
    const raw = '{ "services": { "app": { "image": "x" } } }';
    fs.writeFileSync(resolved, raw);
    assert.equal(hashValidationInputs(resolved, {}), sha256('<resolved-compose>\0', raw, '\0<devcontainer-tree>\0'));
    fs.writeFileSync(resolved, 'not json');
    assert.equal(hashValidationInputs(resolved, {}), sha256('<resolved-compose>\0', 'not json', '\0<devcontainer-tree>\0'));
  });
});

test('hashValidationInputs: only a TZ equal to the host value is pinned', () => {
  const { dir, resolved } = fixedProject();
  const rome = inDir(dir, () => hashValidationInputs(resolved, { TZ: 'Europe/Rome' }));
  const model = JSON.parse(fs.readFileSync(resolved, 'utf8'));
  model['x-aic-build'].args.TZ = 'UTC';
  model.services.app.build.args.TZ = 'UTC';
  fs.writeFileSync(resolved, JSON.stringify(model));
  assert.equal(inDir(dir, () => hashValidationInputs(resolved, {})), rome, 'host TZ is a fixed token');
  assert.notEqual(inDir(dir, () => hashValidationInputs(resolved, { TZ: 'Europe/Rome' })), rome,
    'a repository literal that differs from the host TZ stays in the hash');
});

test('hashValidationInputs: content, mode, names, and link targets change the digest', () => {
  const { dir, resolved } = fixedProject();
  const dev = path.join(dir, '.devcontainer');
  const digest = () => inDir(dir, () => hashValidationInputs(resolved, { TZ: 'UTC' }));
  const seen = new Set([digest()]);
  const changed = label => {
    const value = digest();
    assert.equal(seen.has(value), false, label);
    seen.add(value);
  };
  fs.writeFileSync(path.join(dev, 'b.txt'), 'c');
  changed('content');
  fs.chmodSync(path.join(dev, 'b.txt'), 0o644);
  changed('mode');
  fs.renameSync(path.join(dev, 'b.txt'), path.join(dev, 'c.txt'));
  changed('name');
  fs.symlinkSync('/etc/passwd', path.join(dev, 'link'));
  changed('symlink');
  fs.rmSync(path.join(dev, 'link'));
  fs.symlinkSync('/etc/hosts', path.join(dev, 'link'));
  changed('symlink target');
  // The link is hashed, not followed: the digest does not read the target.
  assert.equal(digest(), digest());
});

test('the trust-hash subcommand prints the digest with no newline', () => {
  const { dir, resolved } = fixedProject();
  const result = runCli(['trust-hash', resolved], { cwd: dir, env: { ...process.env, TZ: 'UTC' } });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, FIXED_PROJECT_DIGEST.UTC);
});

// --- docker-inspect.mjs ------------------------------------------------------

test('volumeIsSafe: only a local volume with no driver options', () => {
  assert.equal(volumeIsSafe({ Driver: 'local', Options: null }), true);
  assert.equal(volumeIsSafe({ Driver: 'local' }), true);
  assert.equal(volumeIsSafe({ Driver: 'local', Options: {} }), true);
  assert.equal(volumeIsSafe({ Driver: 'local', Options: { type: 'none', o: 'bind', device: '/' } }), false);
  assert.equal(volumeIsSafe({ Driver: 'local', Options: [] }), false);
  assert.equal(volumeIsSafe({ Driver: 'local', Options: 'x' }), false);
  assert.equal(volumeIsSafe({ Driver: 'nfs', Options: null }), false);
  assert.equal(volumeIsSafe(null), false);
});

const WS = '/Users/me/api';
const PROJECT = 'api';
const VOL = 'api_aic-sessions';
const container = (labels, mounts) => ({ Config: { Labels: labels }, Mounts: mounts });
const owner = { 'devcontainer.local_folder': WS, 'com.docker.compose.project': PROJECT };
const sessionMount = (destination = '/home/vscode/.aic-sessions', name = VOL, type = 'volume') =>
  ({ Type: type, Name: name, Destination: destination });

test('ownsSessionVolume: exact labels and the volume at a session root', () => {
  assert.equal(ownsSessionVolume(container(owner, [sessionMount()]), WS, PROJECT, VOL), true);
  assert.equal(ownsSessionVolume(container(owner, [sessionMount('/home/vscode/.claude-sessions')]), WS, PROJECT, VOL), true);
  assert.equal(ownsSessionVolume(container(owner, [sessionMount('/tmp')]), WS, PROJECT, VOL), false);
  assert.equal(ownsSessionVolume(container(owner, [sessionMount(undefined, 'other')]), WS, PROJECT, VOL), false);
  assert.equal(ownsSessionVolume(container(owner, [sessionMount(undefined, VOL, 'bind')]), WS, PROJECT, VOL), false);
  assert.equal(ownsSessionVolume(container(owner, {}), WS, PROJECT, VOL), false);
  assert.equal(ownsSessionVolume(container({ ...owner, 'devcontainer.local_folder': '/Users/me/API' },
    [sessionMount()]), WS, PROJECT, VOL), false);
  assert.equal(ownsSessionVolume(container({ ...owner, 'com.docker.compose.project': 'api2' },
    [sessionMount()]), WS, PROJECT, VOL), false);
  assert.equal(ownsSessionVolume(container(null, [sessionMount()]), WS, PROJECT, VOL), false);
  assert.equal(ownsSessionVolume(null, WS, PROJECT, VOL), false);
});

test('volumeUserIsOwner: a user of the volume must carry the exact labels', () => {
  assert.equal(volumeUserIsOwner(container(owner, [sessionMount('/anywhere')]), WS, PROJECT, VOL), true);
  assert.equal(volumeUserIsOwner(container(owner, [sessionMount(undefined, 'other')]), WS, PROJECT, VOL), false);
  assert.equal(volumeUserIsOwner(container({ ...owner, 'devcontainer.local_folder': '/Users/you/api' },
    [sessionMount()]), WS, PROJECT, VOL), false);
  assert.equal(volumeUserIsOwner(container({}, [sessionMount()]), WS, PROJECT, VOL), false);
  assert.equal(volumeUserIsOwner(null, WS, PROJECT, VOL), false);
});

test('containerIsOwned and isAuxiliaryContainer: the legacy stack proof', () => {
  assert.equal(containerIsOwned(container(owner, []), WS, PROJECT), true);
  assert.equal(containerIsOwned(container({ 'com.docker.compose.project': PROJECT }, []), WS, PROJECT), false);
  assert.equal(containerIsOwned(container({ ...owner, 'com.docker.compose.project': 'x' }, []), WS, PROJECT), false);
  assert.equal(containerIsOwned({}, WS, PROJECT), false);

  const sidecar = service => container({ 'com.docker.compose.project': PROJECT, 'com.docker.compose.service': service }, []);
  for (const service of ['socket-proxy', 'aic-auth-sync', 'aic-seed-sanitizer']) {
    assert.equal(isAuxiliaryContainer(sidecar(service), PROJECT), true, service);
  }
  assert.equal(isAuxiliaryContainer(sidecar('app'), PROJECT), false);
  assert.equal(isAuxiliaryContainer(sidecar('socket-proxy'), 'other'), false);
  assert.equal(isAuxiliaryContainer(container({ ...owner, 'com.docker.compose.service': 'socket-proxy' }, []), PROJECT),
    false, 'a sidecar with a workspace label is not auxiliary');
  assert.equal(isAuxiliaryContainer(null, PROJECT), false);
});

// --- cli.mjs -----------------------------------------------------------------

test('the CLI keeps the exit-status contract of each aic caller', () => {
  const safe = JSON.stringify({ Driver: 'local', Options: null });
  assert.equal(runCli(['volume-safe', safe]).status, 0);
  assert.equal(runCli(['volume-safe', JSON.stringify({ Driver: 'local', Options: { o: 'bind' } })]).status, 1);
  assert.equal(runCli(['volume-safe', 'not json']).status, 2);
  assert.equal(runCli(['volume-safe', '']).status, 2);
  const owned = JSON.stringify(container(owner, [sessionMount()]));
  assert.equal(runCli(['owns-session-volume', owned, WS, PROJECT, VOL]).status, 0);
  assert.equal(runCli(['owns-session-volume', owned, WS, PROJECT, 'other']).status, 1);
  assert.equal(runCli(['volume-user-is-owner', owned, WS, PROJECT, VOL]).status, 0);
  assert.equal(runCli(['volume-user-is-owner', owned, '/x', PROJECT, VOL]).status, 1);
  assert.equal(runCli(['container-owned', owned, WS, PROJECT]).status, 0);
  assert.equal(runCli(['container-owned', owned, WS, 'x']).status, 1);
  assert.equal(runCli(['auxiliary-container', owned, PROJECT]).status, 1);
});

test('the CLI fails closed on an unknown subcommand or a wrong argument count', () => {
  for (const args of [[], ['nope'], ['__proto__'], ['volume-safe'], ['volume-safe', '{}', 'extra'],
    ['container-owned', '{}', WS], ['trust-hash'], ['git-control-files', 'x']]) {
    const result = runCli(args);
    assert.equal(result.status, 2, args.join(' '));
    assert.equal(result.stdout, '');
  }
});

test('the compose-name-conflict and vscode-settings subcommands print what aic reads', () => {
  const dir = newDir();
  fs.writeFileSync(path.join(dir, '.env'), 'COMPOSE_PROJECT_NAME=app\n');
  const env = { ...process.env };
  delete env.COMPOSE_PROJECT_NAME;
  let result = runCli(['compose-name-conflict', 'aic-api-0123'], { cwd: dir, env });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'dotenv');
  result = runCli(['compose-name-conflict', 'aic-api-0123'], { cwd: dir, env: { ...env, COMPOSE_PROJECT_NAME: 'x' } });
  assert.equal(result.stdout, 'environment');

  const file = path.join(dir, 'vscode-settings.json');
  fs.writeFileSync(file, '{"terminal.integrated.defaultProfile.linux": "bash", "a": 1}');
  result = runCli(['vscode-settings', file, TEMPLATE]);
  assert.equal(result.status, 0);
  assert.equal(result.stdout, '        ,"a": 1');
  assert.equal(result.stderr,
    'aic: ignoring vscode-settings.json key managed by aic: terminal.integrated.defaultProfile.linux\n');
  fs.writeFileSync(file, '[]');
  result = runCli(['vscode-settings', file, TEMPLATE]);
  assert.equal(result.status, 3);
  assert.equal(result.stdout, '');
});
