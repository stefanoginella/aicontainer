// Unit tests for lib/validate.mjs, the structural half of the pre-Docker gate.
// No Docker: the resolved Compose models come from tests/fixtures/validate
// (made by its regenerate.sh), and each case changes one thing in a copy.
// Real `docker compose` runs stay in test-aic-host-security.sh.
//
// Run: node tests/test-aic-validate.mjs

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  activeInterpolations, analyzeResolvedConfig, FIREWALL_PRESETS, firewallPresetsProblems,
  formatFindings, parseJsonc, safeDiagnostic,
} from '../lib/validate.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FIXTURES = path.join(REPO, 'tests', 'fixtures', 'validate');
const CLI = path.join(REPO, 'lib', 'validate-cli.mjs');
const NAME = 'aic-fixture-0123456789ab';

const scratch = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'aic-validate-')));
after(() => fs.rmSync(scratch, { recursive: true, force: true }));
let roots = 0;

// A project root with the paths that the managed mounts name.
function makeRoot() {
  const root = path.join(scratch, `project-${++roots}`);
  fs.mkdirSync(path.join(root, '.devcontainer'), { recursive: true });
  fs.mkdirSync(path.join(root, '.git', 'hooks'), { recursive: true });
  fs.writeFileSync(path.join(root, '.git', 'config'), '');
  fs.writeFileSync(path.join(root, '.git', 'config.worktree'), '');
  fs.writeFileSync(path.join(root, '.git', 'commondir'), '.\n');
  return root;
}

const fixtureText = name => fs.readFileSync(path.join(FIXTURES, name), 'utf8');
const loadModel = (name, root) => JSON.parse(
  fixtureText(name).split('@ROOT@').join(root).split('@AIC_HOME@').join(REPO));

// The inputs of a generated pull-mode project without an override. A case
// changes them in `edit`; one that changes `final` is an override and sets
// hasOverride, and devcontainer.json then lists the override as aic sync
// writes it (unless the case sets wireOverride = false). Like aic, a project
// without an override gets `{}` raw models.
function scenario(edit = () => {}) {
  const root = makeRoot();
  const ctx = {
    root,
    devcontainer: fixtureText('devcontainer.json'),
    templateDevcontainer: fs.readFileSync(path.join(REPO, 'template', 'devcontainer.json'), 'utf8'),
    base: loadModel('base.json', root),
    expected: loadModel('expected.json', root),
    noenv: loadModel('noenv.json', root),
    rawBase: loadModel('raw-base.json', root),
    hasOverride: false,
    runtimeUser: '1000:1000',
    statusRelay: '0',
    statusProject: 'fixture',
    statusProjectId: NAME,
    // The text of docker-compose.override.yml when a case sets hasOverride.
    overrideText: 'services:\n  devcontainer: {}\n',
  };
  ctx.final = structuredClone(ctx.base);
  ctx.rawFinal = structuredClone(ctx.rawBase);
  edit(ctx);
  if (ctx.hasOverride && ctx.wireOverride !== false) {
    const single = '"dockerComposeFile": ["docker-compose.yml"]';
    assert.ok(ctx.devcontainer.includes(single), 'fixture devcontainer.json has no single dockerComposeFile');
    ctx.devcontainer = ctx.devcontainer.replace(single,
      '"dockerComposeFile": ["docker-compose.yml", "docker-compose.override.yml"]');
  }
  return ctx;
}

const toInput = ctx => ({
  devcontainer: ctx.devcontainer,
  templateDevcontainer: ctx.templateDevcontainer,
  compose: {
    base: JSON.stringify(ctx.base),
    expected: JSON.stringify(ctx.expected),
    final: JSON.stringify(ctx.final),
    noenv: JSON.stringify(ctx.noenv),
    rawBase: ctx.hasOverride ? JSON.stringify(ctx.rawBase) : '{}',
    rawFinal: ctx.hasOverride ? JSON.stringify(ctx.rawFinal) : '{}',
  },
  root: ctx.root,
  expectedName: NAME,
  hasOverride: ctx.hasOverride,
  runtimeUser: ctx.runtimeUser,
  statusRelay: ctx.statusRelay,
  statusProject: ctx.statusProject,
  statusProjectId: ctx.statusProjectId,
  overrideText: ctx.hasOverride ? ctx.overrideText : undefined,
  firewallPresetsText: ctx.firewallPresetsText,
});

const analyze = edit => analyzeResolvedConfig(toInput(scenario(edit)));

// An override change to the devcontainer service, in the resolved and the
// no-env-resolution models alike.
const overrideDev = change => ctx => {
  ctx.hasOverride = true;
  change(ctx.final.services.devcontainer, ctx);
  change(ctx.noenv.services.devcontainer, ctx);
};
const addService = (name, service) => ctx => {
  ctx.hasOverride = true;
  ctx.final.services[name] = structuredClone(service);
  ctx.noenv.services[name] = structuredClone(service);
};
const editDevcontainer = (from, to) => ctx => {
  assert.ok(ctx.devcontainer.includes(from), `fixture devcontainer.json has no ${from}`);
  ctx.devcontainer = ctx.devcontainer.replace(from, to);
};

function expectFinding(findings, kind, pattern) {
  assert.ok(
    findings.some(f => f.kind === kind && pattern.test(f.message)),
    `expected ${kind} ${pattern}, got:\n${formatFindings(findings) || '(no findings)'}`,
  );
}
function expectOnly(findings, kind, pattern) {
  expectFinding(findings, kind, pattern);
  assert.equal(findings.length, 1, `expected one finding, got:\n${formatFindings(findings)}`);
}
function expectNone(findings) {
  assert.deepEqual(findings, [], `expected no findings, got:\n${formatFindings(findings)}`);
}

test('the generated project has no findings', () => {
  expectNone(analyze());
});

test('fixture devcontainer.json still matches the template (else run regenerate.sh)', () => {
  // The template is read live, so a template change without new fixtures
  // fails here first instead of in every case below.
  const findings = analyze().filter(f => /devcontainer\.json|containerEnv/.test(f.message));
  expectNone(findings);
});

test('an override that only adds project data paths has no findings', () => {
  expectNone(analyze(overrideDev(dev => {
    dev.volumes.push({ type: 'volume', source: 'node-modules', target: '/workspace/node_modules' });
    dev.volumes.push({ type: 'bind', source: path.join(dev.volumes[0].source, 'data'), target: '/workspace/data' });
    dev.ports = [{ target: 3000, published: '3000', host_ip: '127.0.0.1', protocol: 'tcp' }];
    dev.environment.APP_MODE = 'dev';
  })));
});

// --- parseJsonc ---------------------------------------------------------------

test('parseJsonc strips comments and trailing commas outside strings', () => {
  const { value } = parseJsonc('{\n  // c\n  "a": "x // y", /* b */ "b": [1, 2,],\n}\n');
  assert.deepEqual(value, { a: 'x // y', b: [1, 2] });
});

test('parseJsonc refuses line breaks that parsers disagree on', () => {
  assert.throws(() => parseJsonc('{ // c\r "runServices": [] }'), /bare carriage return/);
  assert.throws(() => parseJsonc('{ // c  "a": 1 }'), /Unicode line separator/);
  assert.throws(() => parseJsonc('{ /* open "a": 1 }'), /unterminated block comment/);
  assert.deepEqual(parseJsonc('{\r\n  "a": 1\r\n}').value, { a: 1 });
});

// --- devcontainer.json ------------------------------------------------------

test('devcontainer.json: runServices is an unmanaged key', () => {
  expectOnly(analyze(editDevcontainer('"service": "devcontainer",',
    '"service": "devcontainer",\n  "runServices": ["devcontainer", "evil"],')),
  'MANAGED', /unmanaged runServices/);
});

test('devcontainer.json: a bare carriage return is not valid JSONC', () => {
  expectFinding(analyze(editDevcontainer('"service": "devcontainer",',
    '"service": "devcontainer", // c\r "runServices": ["evil"],')),
  'MANAGED', /not valid JSONC/);
});

test('devcontainer.json: a changed managed anchor is drift', () => {
  expectOnly(analyze(editDevcontainer('"remoteUser": "vscode"', '"remoteUser": "root"')),
    'MANAGED', /managed anchor remoteUser/);
});

test('devcontainer.json: an added extension or setting needs trust', () => {
  expectOnly(analyze(editDevcontainer('"anthropic.claude-code",', '"anthropic.claude-code", "evil.extension",')),
    'UNSAFE', /extension evil\.extension/);
  expectOnly(analyze(editDevcontainer('"files.trimFinalNewlines": true,',
    '"files.trimFinalNewlines": true, "python.defaultInterpreterPath": "/tmp/x",')),
  'UNSAFE', /setting python\.defaultInterpreterPath/);
});

test('devcontainer.json: a changed managed setting is drift', () => {
  expectOnly(analyze(editDevcontainer('"terminal.integrated.rightClickBehavior": "paste"',
    '"terminal.integrated.rightClickBehavior": "default"')),
  'MANAGED', /setting terminal\.integrated\.rightClickBehavior differs/);
});

test('devcontainer.json: containerEnv may hold only managed keys', () => {
  expectOnly(analyze(editDevcontainer('"AIC_SHELL": "zsh",', '"AIC_SHELL": "zsh", "LD_PRELOAD": "/x.so",')),
    'MANAGED', /unmanaged containerEnv\.LD_PRELOAD/);
  expectFinding(analyze(editDevcontainer('"AIC_SHELL": "zsh"', '"AIC_SHELL": "ksh"')),
    'MANAGED', /AIC_SHELL is missing or invalid/);
});

test('devcontainer.json: an existing override must be wired', () => {
  expectOnly(analyze(ctx => { ctx.hasOverride = true; ctx.wireOverride = false; }),
    'MANAGED', /dockerComposeFile must be exactly/);
  expectNone(analyze(ctx => { ctx.hasOverride = true; }));
});

// --- resolved Compose: managed invariants -----------------------------------

test('unparsable Compose JSON is one finding and stops the analysis', () => {
  const input = toInput(scenario());
  input.compose.final = '{';
  expectOnly(analyzeResolvedConfig(input), 'MANAGED', /could not parse resolved Compose/);
});

test('a resolved Compose name other than the expected one is refused', () => {
  expectFinding(analyze(ctx => { ctx.final.name = 'other-project'; }), 'MANAGED', /Compose name must be/);
});

test('an override that changes the uninterpolated Compose name is refused', () => {
  // The fixture keeps the managed spelling, normalized by Compose.
  expectNone(analyze(ctx => { ctx.hasOverride = true; }));
  // name: ${AIC_PROJECT_NAME:-other} resolves to the expected name while aic
  // sets the variable, so only the uninterpolated model shows it.
  for (const raw of ['aic_project_name-other', 'aic_project_name', NAME]) {
    expectOnly(analyze(ctx => { ctx.hasOverride = true; ctx.rawFinal.name = raw; }),
      'MANAGED', /override\.yml must not change the top-level Compose name/);
  }
});

test('an override that sets a top-level name in any spelling is refused', () => {
  // Compose normalizes the uninterpolated name, so this spelling has the same
  // raw name as the managed line. Only the text shows it.
  const sneaky = 'name: ${AIC_PROJECT_NAME?run}${AIC:+}${UP:+}${OR:+}${AIC:+}${SYNC:+}\nservices: {}\n';
  for (const text of [sneaky, 'name: ${AIC_PROJECT_NAME:?run aic up or aic sync}\n',
    'services: {}\nname : x\n', 'services: {}\nname:\n  x\n']) {
    expectOnly(analyze(ctx => { ctx.hasOverride = true; ctx.overrideText = text; }),
      'MANAGED', /override\.yml must not set a top-level Compose name/);
  }
  // Spellings that a line check cannot read as the key, and an indented root
  // mapping whose name key hides below column 0.
  for (const text of ['"name": x\nservices: {}\n', 'services: {}\n? name\n: x\n',
    'services: {}\n---\n"n\\u0061me": x\n', 'services: {}\n<<: *a\n', '{name: x}\n']) {
    expectFinding(analyze(ctx => { ctx.hasOverride = true; ctx.overrideText = text; }),
      'MANAGED', /override\.yml (has top-level YAML that is not a plain key|must start its top-level mapping)/);
  }
  expectOnly(analyze(ctx => {
    ctx.hasOverride = true;
    ctx.overrideText = '# comment\n services: {}\n name: ${AIC_PROJECT_NAME:-x}\n';
  }), 'MANAGED', /override\.yml must start its top-level mapping with a plain key at column 0/);
  // Comments, blank lines, indented content, and plain keys are fine.
  expectNone(analyze(ctx => {
    ctx.hasOverride = true;
    ctx.overrideText = '# x\n\nservices:\n  devcontainer:\n    environment:\n      name: ok\nvolumes: {}\n';
  }));
  // The validator CLI reads the override file itself and fails closed without it.
  const ctx = scenario(c => { c.hasOverride = true; c.overrideText = sneaky; });
  const result = runCli(ctx);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^MANAGED\tdocker-compose\.override\.yml must not set a top-level Compose name$/m);
  fs.rmSync(path.join(ctx.root, '.devcontainer', 'docker-compose.override.yml'));
  const args = runCli.lastArgs;
  assert.ok(args, 'runCli did not record its arguments');
  const missing = spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8' });
  assert.notEqual(missing.status, 0, 'the validator ran without the override file');
  assert.equal(missing.stdout, '');
});

test('a docker-compose.yml that differs from the template is drift', () => {
  expectFinding(analyze(ctx => { ctx.base.services.devcontainer.cap_drop = []; }),
    'MANAGED', /does not match the managed template/);
  expectFinding(analyze(ctx => { ctx.base['x-aic-runtime-user'] = '0:0'; }),
    'MANAGED', /runtime user must be 1000:1000/);
  expectFinding(analyze(ctx => { ctx.base.services.devcontainer.image = 'ghcr.io/stefanoginella/aicontainer:latest'; }),
    'MANAGED', /must use the same pinned image tag/);
});

test('missing managed services stop the analysis', () => {
  expectFinding(analyze(ctx => { ctx.hasOverride = true; delete ctx.final.services['socket-proxy']; }),
    'MANAGED', /must contain devcontainer, aic-auth-sync, and socket-proxy/);
});

test('a symlinked .git makes the managed mount source escape the project', () => {
  const findings = analyze(ctx => {
    const outside = path.join(scratch, `outside-${roots}`);
    fs.mkdirSync(outside);
    fs.rmSync(path.join(ctx.root, '.git'), { recursive: true });
    fs.symlinkSync(outside, path.join(ctx.root, '.git'));
  });
  expectFinding(findings, 'MANAGED', /mount source for \/workspace\/\.git escaped this project/);
});

test('Docker read and read-write modes are reported for host consent', () => {
  const setMode = (reads, writes) => ctx => {
    for (const model of [ctx.base, ctx.final, ctx.noenv]) {
      const env = model.services['socket-proxy'].environment;
      for (const key of ['CONTAINERS', 'EVENTS', 'IMAGES', 'INFO', 'NETWORKS', 'VOLUMES']) env[key] = reads;
      env.POST = writes; env.BUILD = writes;
    }
  };
  expectOnly(analyze(setMode('1', '0')), 'DOCKER', /read mode is enabled/);
  expectOnly(analyze(setMode('1', '1')), 'DOCKER', /read-write mode is enabled/);
  expectFinding(analyze(setMode('0', '1')), 'MANAGED', /one managed none\/read\/read-write mode/);
});

// --- resolved Compose: override expansions ----------------------------------

test('a privileged service with the host root mounted needs trust', () => {
  const findings = analyze(addService('evil', {
    image: 'alpine', privileged: true, pid: 'host', profiles: ['x'],
    volumes: [{ type: 'bind', source: '/', target: '/host' }],
  }));
  expectFinding(findings, 'UNSAFE', /service evil: privileged: true/);
  expectFinding(findings, 'UNSAFE', /service evil: pid: host/);
  expectFinding(findings, 'UNSAFE', /service evil: binds a sensitive host path outside the project: \//);
});

test('lifecycle hooks need trust, and say when they are privileged', () => {
  expectOnly(analyze(overrideDev(dev => {
    dev.post_start = [{ command: ['sh', '-c', 'id'], user: 'root', privileged: true }];
  })), 'UNSAFE', /post_start lifecycle hook runs commands with privileged: true/);
  expectOnly(analyze(overrideDev(dev => { dev.pre_stop = [{ command: ['true'] }]; })),
    'UNSAFE', /pre_stop lifecycle hook runs commands outside/);
});

test('host Docker socket and host path binds need trust', () => {
  expectFinding(analyze(overrideDev(dev => {
    dev.volumes.push({ type: 'bind', source: '/var/run/docker.sock', target: '/workspace/docker.sock' });
  })), 'UNSAFE', /mounts the Docker socket/);
  expectFinding(analyze(overrideDev(dev => {
    dev.volumes.push({ type: 'bind', source: '/etc', target: '/workspace/etc' });
  })), 'UNSAFE', /binds a sensitive host path outside the project: (\/private)?\/etc$/);
});

test('a writable bind of a control path or a mount over a managed path needs trust', () => {
  expectFinding(analyze(overrideDev((dev, ctx) => {
    dev.volumes.push({ type: 'bind', source: path.join(ctx.root, '.git'), target: '/workspace/gitdir' });
  })), 'UNSAFE', /writable bind exposes protected project control paths/);
  expectFinding(analyze(overrideDev(dev => {
    dev.volumes.push({ type: 'volume', source: 'x', target: '/etc/aic' });
  })), 'UNSAFE', /masks protected managed path \/etc\/aic/);
});

test('removing the read-only .git/config mount needs trust', () => {
  expectFinding(analyze(overrideDev(dev => {
    dev.volumes = dev.volumes.filter(v => v.target !== '/workspace/.git/config');
  })), 'UNSAFE', /removes managed protection for \/workspace\/\.git\/config/);
});

test('protected environment variables need trust', () => {
  for (const key of ['LD_PRELOAD', 'GIT_CONFIG_COUNT', 'PATH', 'DOCKER_HOST', 'HOME']) {
    expectFinding(analyze(overrideDev(dev => { dev.environment[key] = '/tmp/x'; })),
      'UNSAFE', new RegExp(`environment ${key} overrides a managed`));
  }
});

test('host namespaces, devices, capabilities, and runtime need trust', () => {
  const cases = [
    [dev => { dev.network_mode = 'host'; }, /network_mode: host/],
    [dev => { dev.ipc = 'container:other'; }, /ipc: container:other/],
    [dev => { dev.devices = [{ source: '/dev/kvm', target: '/dev/kvm' }]; }, /host devices/],
    [dev => { dev.cap_add = [...(dev.cap_add || []), 'SYS_ADMIN']; }, /cap_add includes SYS_ADMIN/],
    [dev => { dev.security_opt = ['seccomp=unconfined']; }, /security_opt/],
    [dev => { dev.user = 'root'; }, /changes the managed runtime user/],
    [dev => { dev.runtime = 'runc-custom'; }, /selects host runtime/],
    [dev => { dev.entrypoint = ['sh']; }, /changes managed entrypoint/],
    [dev => { dev.ports = [{ target: 22, published: '22' }]; }, /publishes port 22 beyond host loopback/],
    [dev => { dev.labels = { 'devcontainer.metadata': '[]' }; }, /reserved label devcontainer\.metadata/],
    [dev => { dev.annotations = { a: 'b' }; }, /annotations is not a reviewed Compose service key/],
  ];
  for (const [change, pattern] of cases) expectFinding(analyze(overrideDev(change)), 'UNSAFE', pattern);
});

test('changing a reserved service or an unreviewed top-level key needs trust', () => {
  expectFinding(analyze(ctx => {
    ctx.hasOverride = true;
    ctx.final.services['socket-proxy'].environment.EXEC = '1';
  }), 'UNSAFE', /reserved socket-proxy service/);
  expectFinding(analyze(ctx => { ctx.hasOverride = true; ctx.final.models = { m: {} }; }),
    'UNSAFE', /top-level models is not a reviewed key/);
});

test('a build tagged as a managed image is refused', () => {
  expectFinding(analyze(addService('builder', {
    image: 'ghcr.io/stefanoginella/aicontainer:v0.0.0',
    build: { context: path.join(os.tmpdir(), 'nowhere') },
  })), 'MANAGED', /build would tag .*replacing an image that managed aicontainer services run/);
});

// --- interpolation and pass-through ------------------------------------------

test('host environment interpolation in an override needs trust', () => {
  const withRaw = change => ctx => {
    ctx.hasOverride = true;
    change(ctx.rawFinal.services.devcontainer);
  };
  expectOnly(analyze(withRaw(dev => { dev.environment.TOKEN = '${HOST_TOKEN}'; })),
    'UNSAFE', /host environment interpolation at services\.devcontainer\.environment\.TOKEN \(HOST_TOKEN\)/);
  expectNone(analyze(withRaw(dev => { dev.environment.LITERAL = '$${NOT_EXPANDED}'; })));
  // Compose flips a merged environment map into a K=V list; managed
  // expressions must not read as additions.
  expectNone(analyze(withRaw(dev => {
    dev.environment = Object.entries(dev.environment).map(([k, v]) => `${k}=${v}`);
  })));
  expectOnly(analyze(withRaw(dev => {
    dev.environment = [...Object.entries(dev.environment).map(([k, v]) => `${k}=${v}`), 'HOST_TOKEN'];
  })), 'UNSAFE', /forwards host environment variable .*\(HOST_TOKEN\)/);
});

test('activeInterpolations treats an even dollar run as a literal', () => {
  assert.deepEqual(activeInterpolations('${A} $B $${C} $$$D ${E:-x}'), ['A', 'B', 'D', 'E']);
});

// --- host file indirections (no-env-resolution model) ------------------------

test('env_file, develop.watch exec, extends, and include need trust', () => {
  const noenvDev = change => ctx => { ctx.hasOverride = true; change(ctx.noenv.services.devcontainer, ctx); };
  expectOnly(analyze(noenvDev(dev => { dev.env_file = [{ path: '/etc/secrets.env' }]; })),
    'UNSAFE', /env_file reads host secrets outside the project/);
  expectOnly(analyze(noenvDev((dev, ctx) => {
    dev.develop = { watch: [{ path: path.join(ctx.root, 'src'), action: 'sync+exec', exec: { command: ['sh'] } }] };
  })), 'UNSAFE', /develop\.watch exec hook/);
  expectNone(analyze(noenvDev((dev, ctx) => {
    dev.develop = { watch: [{ path: path.join(ctx.root, 'src'), action: 'sync', exec: { command: null } }] };
  })));
  expectFinding(analyze(ctx => {
    ctx.hasOverride = true;
    fs.writeFileSync(path.join(ctx.root, '.devcontainer', 'docker-compose.override.yml'),
      'include:\n  - ../../other.yml\n');
  }), 'UNSAFE', /include imports additional Compose files/);
});

// --- project-owned Dockerfile build ------------------------------------------

test('a devcontainer build needs trust and must end on the aicontainer base', () => {
  const build = (from, context) => overrideDev((dev, ctx) => {
    const dir = context ? context(ctx.root) : path.join(ctx.root, '.devcontainer');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'Dockerfile.project'), `FROM ${from}\nRUN true\n`);
    dev.build = { context: dir, dockerfile: 'Dockerfile.project' };
  });
  const own = analyze(build('ghcr.io/stefanoginella/aicontainer:v0.0.0'));
  expectFinding(own, 'UNSAFE', /override build executes a project-owned Dockerfile/);
  assert.ok(!own.some(f => /final FROM/.test(f.message)));
  expectFinding(analyze(build('ubuntu:24.04')), 'UNSAFE', /final FROM is not the aicontainer base/);
  expectFinding(analyze(build('ghcr.io/stefanoginella/aicontainer:v0.0.0', root => root)),
    'VOLATILE', /build context extends outside \.devcontainer/);
});

// --- output safety and the CLI -----------------------------------------------

test('terminal controls in repository values are rendered visibly', () => {
  assert.equal(safeDiagnostic('a\u001b[2Jb‮'), 'a\\u001b[2Jb\\u202e');
  const findings = analyze(addService('x\u001b]8;;http://evil\u0007', { image: 'alpine', privileged: true }));
  assert.ok(findings.length > 0);
  for (const { message } of findings) assert.doesNotMatch(message, /[\u0000-\u001f\u007f-\u009f]/);
});

function runCli(ctx, extra = []) {
  const dir = fs.mkdtempSync(path.join(scratch, 'cli-'));
  const input = toInput(ctx);
  const files = {
    dev: ['devcontainer.json', input.devcontainer],
    template: ['template.json', input.templateDevcontainer],
    ...Object.fromEntries(Object.entries(input.compose).map(([k, v]) => [k, [`${k}.json`, v]])),
  };
  const file = key => {
    const [name, text] = files[key];
    fs.writeFileSync(path.join(dir, name), text);
    return path.join(dir, name);
  };
  if (ctx.hasOverride) {
    fs.writeFileSync(path.join(ctx.root, '.devcontainer', 'docker-compose.override.yml'), ctx.overrideText);
  }
  if (ctx.firewallPresetsText !== undefined) {
    fs.writeFileSync(path.join(ctx.root, '.devcontainer', 'firewall-presets'), ctx.firewallPresetsText);
  }
  const args = [
    file('dev'), file('template'), file('base'), file('expected'), file('final'), file('noenv'),
    file('rawBase'), file('rawFinal'), ctx.root, NAME, ctx.hasOverride ? '1' : '0',
    ctx.runtimeUser, ctx.statusRelay, ctx.statusProject, ctx.statusProjectId, ...extra,
  ];
  runCli.lastArgs = args;
  return spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8' });
}

test('firewall-presets: known preset names have no findings and need no trust', () => {
  // A preset only adds fixed hosts to the opt-in allowlist, exactly like
  // firewall-allowlist, so a selection is not a trust finding.
  expectNone(analyze(ctx => {
    ctx.firewallPresetsText = '# registries\ncrates\n  go  # module proxy\r\n\n' + FIREWALL_PRESETS.join('\n');
  }));
  expectNone(analyze(ctx => { ctx.firewallPresetsText = ''; }));
});

test('firewall-presets: an unknown name or a host is refused and cannot be trusted', () => {
  for (const line of ['evil.example.com', 'Go', 'crates io', 'go,crates', '../crates', 'x'.repeat(40)]) {
    expectOnly(analyze(ctx => { ctx.firewallPresetsText = `crates\n${line}\n`; }),
      'MANAGED', /^\.devcontainer\/firewall-presets line 2 is not a known firewall preset; use one of: crates, go, /);
  }
  // The diagnostic never echoes the raw line, so it cannot carry terminal controls.
  const [finding] = analyze(ctx => { ctx.firewallPresetsText = '\u001b]8;;http://x\u0007go\n'; });
  assert.equal(finding.kind, 'MANAGED');
  assert.doesNotMatch(finding.message, /http|\u001b|\\u001b/);
  assert.deepEqual(firewallPresetsProblems(undefined), ['.devcontainer/firewall-presets could not be read']);
});

test('firewall-presets: the CLI reads the project file', () => {
  const ok = runCli(scenario(ctx => { ctx.firewallPresetsText = 'crates\nnodejs\n'; }));
  assert.equal(ok.status, 0, ok.stderr);
  assert.equal(ok.stdout, '');
  const bad = runCli(scenario(ctx => { ctx.firewallPresetsText = 'pypi-mirror.example\n'; }));
  assert.equal(bad.status, 0, bad.stderr);
  assert.match(bad.stdout, /^MANAGED\t\.devcontainer\/firewall-presets line 1 is not a known firewall preset/m);
});

test('the CLI prints one TAB-separated finding per line and exits 0', () => {
  const clean = runCli(scenario());
  assert.equal(clean.status, 0, clean.stderr);
  assert.equal(clean.stdout, '');
  const result = runCli(scenario(addService('evil', { image: 'alpine', privileged: true })));
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^UNSAFE\tservice evil: privileged: true/m);
  for (const line of result.stdout.trimEnd().split('\n')) assert.match(line, /^(MANAGED|UNSAFE|VOLATILE|DOCKER)\t/);
});

test('the CLI exits non-zero when it cannot run, so aic fails closed', () => {
  const extra = runCli(scenario(), ['surplus']);
  assert.notEqual(extra.status, 0);
  assert.match(extra.stderr, /validator failed: expected 15 arguments/);
  const missing = spawnSync(process.execPath, [CLI, ...Array(15).fill(path.join(scratch, 'missing'))], { encoding: 'utf8' });
  assert.notEqual(missing.status, 0);
  assert.equal(missing.stdout, '');
});
