// Tests for the --json mode of aic doctor, status, validate, and version.
//
// --json changes only the output format: the same checks run, the exit status
// is the same, and stdout holds exactly one JSON object. Each command case
// below runs the text mode and the JSON mode and compares them. A fake docker
// stands in for the daemon; the validate cases that need a real Compose model
// use the real Docker CLI and skip when it is not there.
//
// Run: node tests/test-aic-json-output.mjs

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const AIC = path.join(REPO, 'aic');
const VERSION = JSON.parse(fs.readFileSync(path.join(REPO, 'package.json'), 'utf8')).version;
const COMMANDS = ['doctor', 'status', 'validate', 'version'];

// A short path: doctor checks a real Unix socket, and macOS limits socket
// paths to 104 bytes.
const scratch = fs.mkdtempSync(path.join(process.platform === 'win32' ? os.tmpdir() : '/tmp', 'aic-json-'));
after(() => fs.rmSync(scratch, { recursive: true, force: true }));

const fakebin = path.join(scratch, 'bin');
const socket = path.join(scratch, 'd.sock');
const curlLog = path.join(scratch, 'curl.log');
fs.mkdirSync(fakebin);
fs.mkdirSync(path.join(scratch, 'home'));

// AIC_FAKE_COMPOSE_VERSION: the Compose version (unset: no Compose).
// AIC_FAKE_COMPOSE_FLAGS=reject: config rejects --no-env-resolution as an old
// Compose does. The daemon always answers as Docker Desktop on $socket.
fs.writeFileSync(path.join(fakebin, 'docker'), `#!/bin/sh
if [ "\${1:-}" = compose ]; then
  [ -n "\${AIC_FAKE_COMPOSE_VERSION:-}" ] || exit 1
  [ "\${2:-}" = version ] && { printf '%s\\n' "$AIC_FAKE_COMPOSE_VERSION"; exit 0; }
  for arg in "$@"; do
    case "$arg" in
      --no-env-resolution|--no-interpolate)
        [ "\${AIC_FAKE_COMPOSE_FLAGS:-}" = reject ] && { echo "unknown flag: $arg" >&2; exit 1; } ;;
    esac
  done
  case " $* " in *" config "*) printf '{"name":"aic-doctor","subpath":"child"}\\n'; exit 0 ;; esac
  exit 1
fi
case "\${1:-} \${2:-}" in
  "context show") echo default; exit 0 ;;
  "context inspect") printf 'unix://%s\\n' "$AIC_FAKE_SOCKET"; exit 0 ;;
  "-H unix://"*) printf '%s\\n' 'Docker Desktop|docker-desktop|["name=seccomp,profile=builtin"]'; exit 0 ;;
  "info "*) exit 0 ;;
  "version --format") echo 29.0.0; exit 0 ;;
  "ps "*) exit 0 ;;
esac
exit 1
`, { mode: 0o755 });
fs.writeFileSync(path.join(fakebin, 'devcontainer'), '#!/bin/sh\necho 0.80.0\n', { mode: 0o755 });
// The update check must use only the cache or this fake registry.
fs.writeFileSync(path.join(fakebin, 'curl'), `#!/bin/sh
printf '%s\\n' "$*" >> "${curlLog}"
[ -n "\${AIC_FAKE_LATEST:-}" ] || exit 7
printf '{"name":"aicontainer","version":"%s"}\\n' "$AIC_FAKE_LATEST"
`, { mode: 0o755 });
fs.writeFileSync(path.join(fakebin, 'npm'), `#!/bin/sh\nprintf 'npm %s\\n' "$*" >> "${curlLog}"\nexit 1\n`, { mode: 0o755 });

const py = spawnSync('python3', ['-I', '-c',
  'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])', socket]);
assert.equal(py.status, 0, String(py.stderr));

const BASE_ENV = { ...process.env };
for (const name of ['COMPOSE_PROJECT_NAME', 'AIC_PROJECT_NAME', 'COMPOSE_ENV_FILES',
  'COMPOSE_DISABLE_ENV_FILE', 'DOCKER_HOST', 'DOCKER_CONTEXT', 'AIC_DOCKER_SOCKET',
  'AIC_NO_OVERRIDE_SCAN', 'AIC_UNSAFE_ONCE_HASH', 'CI', 'aic_json_dir', 'aic_update_latest']) {
  delete BASE_ENV[name];
}
const ENV = {
  ...BASE_ENV,
  HOME: path.join(scratch, 'home'),
  XDG_STATE_HOME: path.join(scratch, 'state'),
  XDG_CACHE_HOME: path.join(scratch, 'cache'),
  AIC_HOME: REPO,
  AIC_NO_UPDATE_CHECK: '1',
  AIC_FAKE_SOCKET: socket,
  AIC_FAKE_COMPOSE_VERSION: '2.40.0',
  PATH: `${fakebin}${path.delimiter}${process.env.PATH}`,
};

function run(cwd, args, env = {}) {
  const res = spawnSync(AIC, args, { cwd, encoding: 'utf8', env: { ...ENV, ...env }, input: '' });
  assert.equal(res.error, undefined);
  return res;
}

// Check the JSON contract and return the object: stdout is exactly one line
// with one JSON object, no ANSI escape, and the common members.
function parse(res, command) {
  assert.ok(res.stdout.endsWith('\n'), `stdout does not end with a newline: ${res.stdout}`);
  assert.equal(res.stdout.indexOf('\n'), res.stdout.length - 1, `stdout has more than one line: ${res.stdout}`);
  assert.ok(!res.stdout.includes('\x1b'), 'stdout has an ANSI escape');
  const obj = JSON.parse(res.stdout);
  assert.equal(Object.getPrototypeOf(obj), Object.prototype);
  assert.equal(obj.schema, 1);
  assert.equal(obj.command, command);
  assert.equal(obj.ok, res.status === 0);
  assert.ok('error' in obj);
  if (res.status === 0) assert.equal(obj.error, null);
  return obj;
}

// Text and JSON mode of one command with the same environment.
function both(cwd, command, env = {}) {
  const text = run(cwd, [command], env);
  const json = run(cwd, [command, '--json'], env);
  assert.equal(json.status, text.status, `exit status differs: text ${text.status}, json ${json.status}\n${text.stdout}${text.stderr}`);
  return { text, json, obj: parse(json, command) };
}

function newProject(dir) {
  fs.mkdirSync(dir, { recursive: true });
  assert.equal(spawnSync('git', ['-C', dir, 'init', '-q']).status, 0);
  const res = run(dir, ['init', '--with', 'codex', '--shell', 'zsh']);
  assert.equal(res.status, 0, res.stderr);
  return dir;
}

const project = newProject(path.join(scratch, 'p'));

// --- the encoder ------------------------------------------------------------

test('json_string escapes every string into valid JSON', () => {
  const script = `set -euo pipefail
. "$1"
for v in '' plain 'say "hi"' 'back\\slash' $'two\\nlines\\ttab\\rcr' $'\\e[31mred\\e[0m' \\
    $'\\x01\\x02\\x1f\\x7f' 'città ✓ 😀' $'bad\\xff\\xfeutf8' '%s %d -n' "it's" $'end\\n\\n'; do
  json_string "$v"; printf '\\n'
done
json_string_or_null ''; printf '\\n'`;
  const expected = ['', 'plain', 'say "hi"', 'back\\slash', 'two\nlines\ttab\rcr',
    '\x1b[31mred\x1b[0m', '\x01\x02\x1f\x7f', 'città ✓ 😀', 'bad??utf8', '%s %d -n', "it's", 'end\n\n', null];
  for (const locale of [{ LC_ALL: 'C' }, { LANG: 'en_US.UTF-8', LC_ALL: '' }]) {
    const res = spawnSync('bash', ['-c', script, 'bash', path.join(REPO, 'lib/aic/json.sh')],
      { encoding: 'utf8', env: { ...ENV, ...locale } });
    assert.equal(res.status, 0, res.stderr);
    assert.ok(!res.stdout.includes('\x1b'), 'an ESC byte was not escaped');
    const lines = res.stdout.split('\n').slice(0, -1);
    assert.deepEqual(lines.map(line => JSON.parse(line)), expected);
  }
});

// --- doctor -----------------------------------------------------------------

const LEVELS = { OK: 'ok', WARN: 'warn', FAIL: 'fail' };

// The doctor checks of the text mode as [level, message] pairs.
function doctorLines(stdout) {
  return stdout.split('\n').map(line => /^(OK|WARN|FAIL) +(.*)$/.exec(line))
    .filter(Boolean).map(m => [LEVELS[m[1]], m[2]]);
}

function checkDoctor(cwd, env, result) {
  const { text, obj } = both(cwd, 'doctor', env);
  assert.deepEqual(obj.checks.map(c => [c.level, c.message]), doctorLines(text.stdout),
    'the JSON checks differ from the text checks');
  for (const c of obj.checks) {
    assert.deepEqual(Object.keys(c), ['id', 'level', 'message']);
    assert.match(c.id, /^[a-z][a-z-]*$/);
  }
  assert.equal(obj.warnings, obj.checks.filter(c => c.level === 'warn').length);
  assert.equal(obj.failures, obj.checks.filter(c => c.level === 'fail').length);
  assert.equal(obj.result, result);
  return { text, obj };
}

test('doctor --json: ready, warnings, and blockers keep the exit status', () => {
  let { text, obj } = checkDoctor(project, {}, 'ready');
  assert.equal(text.status, 0, text.stdout);
  assert.deepEqual(obj.checks.map(c => c.id).filter((id, i, a) => a.indexOf(id) === i), [
    'node', 'docker-daemon', 'docker-engine', 'docker-socket', 'docker-runtime',
    'compose-version', 'compose-flags', 'compose-subpath', 'devcontainer-cli', 'git-root',
    'git-control-paths', 'install', 'control-paths', 'runtime-env', 'project-identity',
    'devcontainer-name',
  ]);

  const env = path.join(project, '.devcontainer', '.env');
  const saved = fs.readFileSync(env);
  fs.rmSync(env);
  try {
    ({ text, obj } = checkDoctor(project, {}, 'warnings'));
    assert.equal(text.status, 0);
    assert.ok(obj.checks.some(c => c.id === 'runtime-env' && c.level === 'warn'));
  } finally {
    fs.writeFileSync(env, saved);
  }

  ({ text, obj } = checkDoctor(project,
    { AIC_FAKE_COMPOSE_VERSION: '2.29.7', AIC_FAKE_COMPOSE_FLAGS: 'reject' }, 'blocked'));
  assert.equal(text.status, 1);
  assert.equal(obj.error, null);
  assert.ok(obj.checks.some(c => c.id === 'compose-version' && c.level === 'fail'));
});

test('doctor --json escapes a path with quotes, a backslash, a newline, and an ESC', () => {
  const root = path.join(scratch, 'we"ird\\ \nname \x1b[31m');
  fs.mkdirSync(path.join(root, 'sub'), { recursive: true });
  assert.equal(spawnSync('git', ['-C', root, 'init', '-q']).status, 0);
  // The text mode splits this message over two lines, so compare only the item.
  const { json, obj } = both(path.join(root, 'sub'), 'doctor');
  assert.ok(!json.stdout.includes('\x1b['), 'stdout has an ANSI sequence');
  const real = fs.realpathSync(root);
  const item = obj.checks.find(c => c.id === 'git-root');
  assert.equal(item.message, `current directory is below the Git root; run aic from ${real}`);
});

test('doctor --json: a blocker from a caught probe gives no error; a real stop does', () => {
  const dir = path.join(scratch, 'linked');
  fs.mkdirSync(dir);
  assert.equal(spawnSync('git', ['-C', dir, 'init', '-q']).status, 0);
  fs.symlinkSync(path.join(project, '.devcontainer'), path.join(dir, '.devcontainer'));
  // doctor probes the control paths in a subshell and catches the die.
  const { text, obj } = checkDoctor(dir, {}, 'blocked');
  assert.equal(text.status, 1);
  assert.equal(obj.error, null);
  assert.ok(obj.checks.some(c => c.id === 'control-paths' && c.level === 'fail'
    && /symlink/.test(c.message)));
  // status stops on the same path with a die at its top level.
  const status = both(dir, 'status');
  assert.equal(status.text.status, 1);
  assert.match(status.obj.error, /symlink/);
});

// --- status -----------------------------------------------------------------

test('status --json reports the same state as the text', () => {
  const { text, obj } = both(project, 'status');
  assert.equal(text.status, 0, text.stderr);
  const line = key => new RegExp(`^  ${key}: +(.*)$`, 'm').exec(text.stdout)[1];
  assert.equal(obj.project, line('project'));
  assert.equal(line('mode'), `${obj.mode}; tools: ${obj.tools.join(',')}; shell: ${obj.shell}`);
  assert.deepEqual(obj.tools, ['codex']);
  assert.equal(obj.shell, 'zsh');
  assert.equal(obj.mode, 'pull');
  assert.equal(obj.docker, 'none');
  assert.equal(obj.docker_consent, null);
  assert.equal(obj.relay, 'disabled');
  assert.equal(obj.relay_applied, 'disabled');
  assert.equal(obj.socket, socket);
  assert.equal(obj.runtime_kind, 'docker-desktop');
  assert.equal(obj.bind_source, '/var/run/docker.sock');
  assert.match(obj.runtime_uid_gid, /^[0-9]+:[0-9]+$/);
  assert.equal(obj.cli_version, VERSION);
  assert.equal(obj.image, 'match');
  assert.equal(obj.image_pinned, VERSION);
  assert.equal(obj.docker_available, true);
  assert.equal(obj.container, 'not-created');
  assert.equal(obj.container_image, null);
  assert.equal(obj.auth_bridge, 'not-created');
  assert.equal(obj.auth_volume, 'absent');
  assert.equal(obj.sessions_volume, 'absent');
});

test('status --json outside a project fails with an error and the same exit status', () => {
  const dir = path.join(scratch, 'empty');
  fs.mkdirSync(dir, { recursive: true });
  const { text, json, obj } = both(dir, 'status');
  assert.equal(text.status, 1);
  assert.equal(typeof obj.error, 'string');
  assert.match(obj.error, /aic init/);
  assert.match(json.stderr, /aic init/);
});

// --- validate ---------------------------------------------------------------

// The findings that the text mode prints, one '  ! <message>' line each.
const textFindings = stderr => stderr.split('\n').filter(l => l.startsWith('  ! ')).map(l => l.slice(4));

test('validate --json: an old Compose is one compose finding', () => {
  const env = { AIC_FAKE_COMPOSE_VERSION: '2.29.7', AIC_FAKE_COMPOSE_FLAGS: 'reject' };
  const { text, obj } = both(project, 'validate', env);
  assert.equal(text.status, 1);
  assert.deepEqual(obj.findings, [{
    id: 'compose', level: 'fail',
    message: 'Docker Compose 2.29.7 is too old; aic needs Compose 2.35+ (run aic doctor)',
  }]);
  assert.deepEqual(obj.findings.map(f => f.message), textFindings(text.stderr));
  assert.equal(obj.error, "configuration cannot be validated: upgrade Docker Compose to 2.35+ (see 'aic doctor')");
});

test('validate --json: a direct-start name conflict is a name finding', () => {
  const { text, obj } = both(project, 'validate', { COMPOSE_PROJECT_NAME: 'other' });
  assert.equal(text.status, 1);
  assert.equal(obj.findings.length, 1);
  assert.equal(obj.findings[0].id, 'name');
  assert.equal(obj.findings[0].level, 'fail');
  assert.match(obj.findings[0].message, /^COMPOSE_PROJECT_NAME in the environment would replace/);
  assert.equal(obj.error, 'configuration is invalid for a direct Dev Containers start');
});

// The real Docker CLI, for the cases that need a resolved Compose model.
const REAL_PATH = process.env.PATH;
const realCompose = spawnSync('docker', ['compose', 'version', '--short'], { encoding: 'utf8' });
const composeOk = realCompose.status === 0
  && (([a, b]) => a > 2 || (a === 2 && b >= 35))((/(\d+)\.(\d+)/.exec(realCompose.stdout) || [0, 0, 0]).slice(1).map(Number));
const REAL_ENV = {
  PATH: REAL_PATH,
  DOCKER_CONFIG: process.env.DOCKER_CONFIG || path.join(os.homedir(), '.docker'),
};

test('validate --json: clean, untrusted, and trusted configurations', { skip: !composeOk && 'needs Docker Compose 2.35+' }, () => {
  const dir = path.join(scratch, 'real');
  fs.mkdirSync(dir);
  assert.equal(spawnSync('git', ['-C', dir, 'init', '-q']).status, 0);
  let res = run(dir, ['init', '--with', 'codex', '--shell', 'zsh'], REAL_ENV);
  assert.equal(res.status, 0, res.stderr);

  let { text, json, obj } = both(dir, 'validate', REAL_ENV);
  assert.equal(text.status, 0, text.stderr);
  assert.deepEqual(obj.findings, []);
  assert.match(json.stderr, /configuration valid/);

  fs.writeFileSync(path.join(dir, '.devcontainer', 'docker-compose.override.yml'),
    'services:\n  devcontainer:\n    privileged: true\n');
  res = run(dir, ['sync'], REAL_ENV);
  assert.equal(res.status, 0, res.stderr);
  ({ text, obj } = both(dir, 'validate', REAL_ENV));
  assert.equal(text.status, 1);
  assert.ok(obj.findings.length > 0);
  assert.ok(obj.findings.every(f => f.level === 'warn' && ['unsafe', 'docker', 'volatile'].includes(f.id)));
  assert.ok(obj.findings.some(f => /privileged/.test(f.message)));
  assert.deepEqual(obj.findings.map(f => f.message), textFindings(text.stderr));
  assert.equal(obj.error, "unsafe configuration is not trusted; review it, then run 'aic trust' interactively");

  // Trust on a pty, as a person does. validate --json never prompts or trusts.
  const pty = path.join(scratch, 'pty-yes.py');
  fs.writeFileSync(pty, `import os, pty, select, sys, time
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
        os.write(fd, b"y\\n")
        sent = True
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
`);
  const trust = spawnSync('python3', ['-I', pty, AIC, 'trust'],
    { cwd: dir, encoding: 'utf8', env: { ...ENV, ...REAL_ENV } });
  assert.equal(trust.status, 0, trust.stdout + trust.stderr);
  ({ text, obj } = both(dir, 'validate', REAL_ENV));
  assert.equal(text.status, 0, text.stderr);
  assert.ok(obj.findings.some(f => f.id === 'unsafe' && /privileged/.test(f.message)));
  assert.deepEqual(obj.findings.map(f => f.message), textFindings(text.stderr));
});

// --- version ----------------------------------------------------------------

const cacheFile = path.join(scratch, 'cache', 'aicontainer', 'update-check');
const writeCache = (ts, latest) => {
  fs.mkdirSync(path.dirname(cacheFile), { recursive: true });
  fs.writeFileSync(cacheFile, `${ts} ${latest}\n`);
};
const curlCalls = () => (fs.existsSync(curlLog) ? fs.readFileSync(curlLog, 'utf8') : '');

test('version --json without the update check', () => {
  const { text, obj } = both(project, 'version');
  assert.equal(text.status, 0);
  assert.equal(text.stdout, `aic v${VERSION}\n`);
  assert.deepEqual(obj, { schema: 1, command: 'version', ok: true, version: VERSION,
    latest: null, update_available: false, error: null });
});

test('version --json uses the same update check: cache first, then the registry', () => {
  const env = { AIC_NO_UPDATE_CHECK: '' };
  // A fresh cache: no registry call in either mode.
  writeCache(Math.floor(Date.now() / 1000), '99.0.0');
  fs.rmSync(curlLog, { force: true });
  let { text, json, obj } = both(project, 'version', env);
  assert.equal(curlCalls(), '');
  assert.equal(obj.latest, '99.0.0');
  assert.equal(obj.update_available, true);
  assert.match(text.stderr, /newer aicontainer is available: v99\.0\.0/);
  assert.equal(json.stderr, text.stderr);

  // A stale cache: one bounded registry call in each mode.
  for (const args of [['version'], ['version', '--json']]) {
    writeCache(0, '99.0.0');
    fs.rmSync(curlLog, { force: true });
    const res = run(project, args, { ...env, AIC_FAKE_LATEST: VERSION });
    assert.equal(res.status, 0);
    assert.equal(curlCalls(), '-fsS --max-time 3 https://registry.npmjs.org/aicontainer/latest\n');
    if (args[1]) {
      obj = parse(res, 'version');
      assert.equal(obj.latest, VERSION);
      assert.equal(obj.update_available, false);
    }
  }

  // CI skips the check in both modes.
  writeCache(0, '99.0.0');
  fs.rmSync(curlLog, { force: true });
  ({ obj } = both(project, 'version', { ...env, CI: '1' }));
  assert.equal(curlCalls(), '');
  assert.equal(obj.latest, null);
});

// --- flags and environment ----------------------------------------------------

test('unknown flags and extra arguments are refused with no JSON', () => {
  for (const command of COMMANDS) {
    for (const args of [['--jsonx'], ['--json', '--json'], ['--json', 'extra'], ['-j'], ['']]) {
      const res = run(project, [command, ...args]);
      assert.equal(res.status, 2, `${command} ${args.join(' ')}`);
      assert.equal(res.stdout, '');
      assert.equal(res.stderr, `aic: usage: aic ${command} [--json]\n`);
    }
  }
});

test('the environment cannot select JSON mode or seed the latest version', () => {
  const planted = path.join(scratch, 'planted');
  fs.mkdirSync(planted);
  let res = run(project, ['version'], { aic_json_dir: planted });
  assert.equal(res.stdout, `aic v${VERSION}\n`);
  assert.deepEqual(fs.readdirSync(planted), []);
  res = run(project, ['doctor'], { aic_json_dir: planted });
  assert.match(res.stdout, /^aic doctor\n/);
  assert.deepEqual(fs.readdirSync(planted), []);
  res = run(project, ['version', '--json'], { aic_update_latest: '99.0.0' });
  assert.equal(parse(res, 'version').latest, null);
});
