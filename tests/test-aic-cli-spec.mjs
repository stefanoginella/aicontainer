// Drift tests for lib/cli-spec.mjs, the one table of aic's commands and flags.
//
// The completion scripts are generated from the table. `aic help` and the
// `case "${1:-help}"` dispatcher at the end of `aic` are hand-written, so these
// tests check them against the table in both directions.
//
// Run: node tests/test-aic-cli-spec.mjs

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { COMMANDS, checkSpec, completionScript, publicCommands } from '../lib/cli-spec.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const AIC = path.join(REPO, 'aic');
const SPEC = path.join(REPO, 'lib', 'cli-spec.mjs');
const SHELLS = ['bash', 'zsh', 'fish'];

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'aic-cli-spec-'));
after(() => fs.rmSync(scratch, { recursive: true, force: true }));

const ENV = {
  ...process.env,
  HOME: path.join(scratch, 'home'),
  XDG_STATE_HOME: path.join(scratch, 'state'),
  XDG_CACHE_HOME: path.join(scratch, 'cache'),
  AIC_NO_UPDATE_CHECK: '1',
};
fs.mkdirSync(ENV.HOME, { recursive: true });

function run(cmd, args, options = {}) {
  return spawnSync(cmd, args, { encoding: 'utf8', env: ENV, cwd: scratch, ...options });
}

function aic(...args) {
  return run(AIC, args);
}

const hasCommand = name => run('sh', ['-c', `command -v ${name}`]).status === 0;
const escapeRe = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const hasWord = (text, w) => new RegExp(`(^|[^A-Za-z0-9_-])${escapeRe(w)}($|[^A-Za-z0-9_-])`).test(text);

// `aic help` split into one block for each `  aic <command>` usage line.
function helpBlocks() {
  const res = aic('help');
  assert.equal(res.status, 0, res.stderr);
  const blocks = new Map();
  let current = null;
  for (const line of res.stdout.split('\n')) {
    const m = /^ {2}aic ([^\s[]+)/.exec(line);
    if (m) {
      assert.ok(!blocks.has(m[1]), `help has two usage lines for aic ${m[1]}`);
      current = m[1];
      blocks.set(current, '');
    } else if (/^\S/.test(line)) {
      current = null; // a new section, for example "Env:"
    }
    if (current) blocks.set(current, `${blocks.get(current)}${line}\n`);
  }
  return { text: res.stdout, blocks };
}

// The patterns of the top-level dispatcher, one array for each case arm.
function dispatcherArms() {
  const source = fs.readFileSync(AIC, 'utf8');
  const start = source.indexOf('\ncase "${1:-help}" in\n');
  assert.ok(start >= 0, 'aic has no case "${1:-help}" dispatcher');
  const end = source.indexOf('\nesac', start);
  assert.ok(end > start, 'the aic dispatcher has no esac');
  const arms = [];
  for (const line of source.slice(start, end).split('\n').slice(2)) {
    const m = /^ {2}([^\s)][^)]*)\)/.exec(line);
    assert.ok(m, `unexpected dispatcher line: ${line}`);
    if (m[1] === '*') continue;
    arms.push(m[1].split('|'));
  }
  return arms;
}

test('the command table is well formed', () => {
  assert.deepEqual(checkSpec(), []);
  const internal = COMMANDS.filter(c => c.internal).map(c => c.name).sort();
  assert.deepEqual(internal, ['__supports', 'check-drift', 'initialize']);
});

test('checkSpec rejects data that would break a generated script', () => {
  const bad = [
    { name: 'x', description: 'a [bracket]' },
    { name: 'y', description: 'ok', flags: [{ long: '--z', description: 'ok', valueName: 'v', values: ['a b'] }] },
    { name: 'x', description: 'duplicate' },
    { name: 'w', description: 'ok', internal: true, flags: [{ long: '--q', description: 'ok' }] },
  ];
  assert.equal(checkSpec(bad).length, 4);
});

test('help lists every public command, flag, and choice of the table', () => {
  const { text, blocks } = helpBlocks();
  for (const cmd of publicCommands()) {
    assert.ok(blocks.has(cmd.name), `aic help has no usage line for aic ${cmd.name}`);
    const block = blocks.get(cmd.name);
    for (const flag of cmd.flags || []) {
      for (const f of [flag.long, flag.short].filter(Boolean)) {
        assert.ok(hasWord(block, f), `aic help for ${cmd.name} does not name ${f}`);
      }
      // Flags that two commands share, such as --with, are explained once.
      for (const value of (flag.values || []).flatMap(v => v.split(','))) {
        assert.ok(hasWord(text, value), `aic help does not name ${value}, a value of ${cmd.name} ${flag.long}`);
      }
    }
    for (const choice of cmd.positional?.choices || []) {
      assert.ok(hasWord(block, choice), `aic help for ${cmd.name} does not name ${choice}`);
    }
    for (const alias of cmd.aliases || []) {
      assert.ok(hasWord(block, alias), `aic help for ${cmd.name} does not name ${alias}`);
    }
  }
});

test('help names no command that the table does not have', () => {
  const { text, blocks } = helpBlocks();
  const known = new Set(publicCommands().map(c => c.name));
  for (const name of blocks.keys()) {
    assert.ok(known.has(name), `aic help lists aic ${name}, which is not in lib/cli-spec.mjs`);
  }
  // Quoted references in the prose, for example 'aic sync' or `aic rebuild`.
  for (const m of text.matchAll(/['`(]aic ([a-z_][a-z_-]*)/g)) {
    assert.ok(known.has(m[1]), `aic help mentions aic ${m[1]}, which is not in lib/cli-spec.mjs`);
  }
  for (const cmd of COMMANDS.filter(c => c.internal)) {
    assert.ok(!hasWord(text, cmd.name), `aic help names the internal command ${cmd.name}`);
  }
});

test('the dispatcher has exactly the commands of the table', () => {
  const arms = dispatcherArms();
  const table = new Map(COMMANDS.map(c => [c.name, [c.name, ...(c.aliases || [])]]));
  const seen = new Set();
  for (const patterns of arms) {
    const [name] = patterns;
    assert.ok(table.has(name), `the aic dispatcher has ${name}, which is not in lib/cli-spec.mjs`);
    assert.deepEqual(patterns, table.get(name), `the dispatcher spellings of ${name} differ from the table`);
    seen.add(name);
  }
  for (const name of table.keys()) {
    assert.ok(seen.has(name), `lib/cli-spec.mjs has ${name}, which the aic dispatcher does not`);
  }
});

for (const shell of SHELLS) {
  test(`${shell} completion: aic prints the generated script`, () => {
    const res = aic('completion', shell);
    assert.equal(res.status, 0, res.stderr);
    assert.equal(res.stdout, completionScript(shell));
    const direct = run(process.execPath, [SPEC, 'completion', shell]);
    assert.equal(direct.status, 0, direct.stderr);
    assert.equal(direct.stdout, res.stdout);
  });

  test(`${shell} completion: names every public command, flag, and choice`, () => {
    const script = completionScript(shell);
    for (const cmd of publicCommands()) {
      assert.ok(hasWord(script, cmd.name), `${shell} completion omits ${cmd.name}`);
      for (const flag of cmd.flags || []) {
        if (shell === 'fish') {
          assert.match(script, new RegExp(`from ${cmd.name}" -l ${escapeRe(flag.long.slice(2))} `));
          if (flag.short) {
            assert.match(script, new RegExp(`from ${cmd.name}" -l ${escapeRe(flag.long.slice(2))} -s ${flag.short.slice(1)} `));
          }
        } else {
          for (const f of [flag.long, flag.short].filter(Boolean)) {
            assert.ok(hasWord(script, f), `${shell} completion omits ${cmd.name} ${f}`);
          }
        }
        for (const value of flag.values || []) {
          assert.ok(hasWord(script, value), `${shell} completion omits ${flag.long} value ${value}`);
        }
      }
      for (const choice of cmd.positional?.choices || []) {
        assert.ok(hasWord(script, choice), `${shell} completion omits ${cmd.name} ${choice}`);
      }
    }
    for (const cmd of COMMANDS.filter(c => c.internal)) {
      assert.ok(!script.includes(cmd.name), `${shell} completion lists the internal ${cmd.name}`);
    }
    for (const cmd of COMMANDS) {
      for (const alias of cmd.aliases || []) {
        assert.ok(!hasWord(script, alias), `${shell} completion lists the alias ${alias}`);
      }
    }
  });

  test(`${shell} completion: the script is valid ${shell}`, t => {
    if (!hasCommand(shell)) {
      t.skip(`${shell} is not installed`);
      return;
    }
    const file = path.join(scratch, `completion.${shell}`);
    fs.writeFileSync(file, completionScript(shell));
    const res = run(shell, ['-n', file]);
    assert.equal(res.status, 0, `${shell} -n failed:\n${res.stderr}`);
  });
}

test('completion binds both aic and aicontainer', () => {
  assert.match(completionScript('bash'), /^complete -F _aic_complete aic aicontainer$/m);
  assert.match(completionScript('zsh'), /^#compdef aic aicontainer$/m);
  assert.match(completionScript('zsh'), /^compdef _aic aic aicontainer 2>\/dev\/null$/m);
  assert.match(completionScript('fish'), /^for cmd in aic aicontainer$/m);
});

test('bash completion offers the right words', () => {
  const file = path.join(scratch, 'completion-run.bash');
  fs.writeFileSync(file, completionScript('bash'));
  const complete = line => {
    const words = line.split(' ');
    const script = `source "$1"; shift; COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 ));
      _aic_complete; printf '%s\\n' "\${COMPREPLY[@]}"`;
    const res = run('bash', ['--norc', '--noprofile', '-c', script, 'bash', file, ...words]);
    assert.equal(res.status, 0, res.stderr);
    return res.stdout.split('\n').filter(Boolean).sort();
  };
  assert.deepEqual(complete('aic destroy -'), ['--yes', '-y']);
  assert.deepEqual(complete('aic up --'), ['--allow-unsafe']);
  assert.deepEqual(complete('aic rebuild --'), ['--allow-unsafe']);
  assert.deepEqual(complete('aic trust --'), ['--revoke']);
  assert.deepEqual(complete('aic init --with '), ['claude-code', 'claude-code,codex,opencode', 'codex', 'opencode']);
  assert.deepEqual(complete('aic sync --shell '), ['bash', 'fish', 'zsh']);
  assert.deepEqual(complete('aic init --docker'), ['--docker', '--docker-read']);
  assert.deepEqual(complete('aic completion '), ['bash', 'fish', 'zsh']);
  assert.deepEqual(complete('aic completion zsh '), []);
  assert.deepEqual(complete('aic signing '), ['--register', 'auto', 'byok', 'disable', 'status']);
  assert.deepEqual(complete('aic signing --register '), ['--register', 'auto', 'byok', 'disable', 'status']);
  assert.deepEqual(complete('aic signing auto '), ['--register']);
  assert.deepEqual(complete('aic doctor '), ['--json']);
  assert.deepEqual(complete('aic status --'), ['--json']);
  assert.deepEqual(complete('aic validate --'), ['--json']);
  assert.deepEqual(complete('aic version --'), ['--json']);
  assert.deepEqual(complete('aic __'), []);
  assert.deepEqual(complete('aic va'), ['validate']);
});

test('completion keeps its errors for a missing or unknown shell', () => {
  let res = aic('completion');
  assert.equal(res.status, 1);
  assert.equal(res.stdout, '');
  assert.equal(res.stderr, 'aic: usage: aic completion <bash|zsh|fish>\n');
  res = aic('completion', 'tcsh');
  assert.equal(res.status, 1);
  assert.equal(res.stdout, '');
  assert.equal(res.stderr, 'aic: unsupported shell: tcsh (supported: bash, zsh, fish)\n');
  res = run(process.execPath, [SPEC, 'completion', 'tcsh']);
  assert.notEqual(res.status, 0);
  assert.equal(res.stdout, '');
  assert.throws(() => completionScript('tcsh'), /unsupported shell/);
  assert.throws(() => completionScript('constructor'), /unsupported shell/);
});

test('importing the table prints nothing', () => {
  const res = run(process.execPath, ['--input-type=module', '-e', `await import(${JSON.stringify(SPEC)});`]);
  assert.equal(res.status, 0, res.stderr);
  assert.equal(res.stdout, '');
  assert.equal(res.stderr, '');
});
