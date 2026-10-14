// Tests for docs/user/stability.md, the stability contract for tools.
//
// Tools that build on aic read that page to learn what they can rely on. So
// each list on the page must equal what the code really has, in both
// directions:
//   - the stable and internal commands, flags, and choices (lib/cli-spec.mjs);
//   - the JSON schema number, the members of each command, the doctor check
//     ids, and the validate finding ids with their levels (lib/aic/*.sh);
//   - the managed and project-owned files (AIC_CONTROL_FILES and the
//     template README);
//   - the public environment variables (the Env: section of aic help).
// The test reads files only: no Docker, no network.
//
// Run: node tests/test-aic-stability-contract.mjs

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { COMMANDS, publicCommands } from '../lib/cli-spec.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = rel => fs.readFileSync(path.join(REPO, rel), 'utf8');
const PAGE_PATH = 'docs/user/stability.md';
const PAGE = read(PAGE_PATH);
const LIB_AIC = fs.readdirSync(path.join(REPO, 'lib', 'aic')).filter(f => f.endsWith('.sh')).sort();
const SH = Object.fromEntries(LIB_AIC.map(f => [f, read(`lib/aic/${f}`)]));

// Every failure names the page, so the fix is clear.
const stale = what => `${PAGE_PATH} is out of date: ${what}. Update the page (and the CHANGELOG when the change is user-facing).`;
const sorted = values => [...new Set(values)].sort();
function sameSet(actual, expected, what) {
  const a = sorted(actual), e = sorted(expected);
  const missing = e.filter(x => !a.includes(x));
  const extra = a.filter(x => !e.includes(x));
  assert.ok(!missing.length && !extra.length,
    stale(`${what}: missing on the page [${missing.join(', ')}], not in the code [${extra.join(', ')}]`));
}

// --- page helpers -----------------------------------------------------------

// The lines below heading `title` up to the next heading of the same or a
// higher level. Fenced code is skipped.
function section(text, title) {
  const lines = text.split('\n');
  let fence = false, level = 0;
  const out = [];
  for (const line of lines) {
    if (/^```/.test(line)) fence = !fence;
    const h = !fence && /^(#{1,6}) (.*)$/.exec(line);
    if (level) {
      if (h && h[1].length <= level) break;
      out.push(line);
    } else if (h && h[2].trim() === title) {
      level = h[1].length;
    }
  }
  assert.ok(level, `${PAGE_PATH} has no "${title}" heading`);
  return out;
}

// The body rows of the first table in `lines`, as arrays of cells.
function tableRows(lines) {
  const rows = lines.filter(l => /^\|/.test(l))
    .map(l => l.replace(/^\|/, '').replace(/\|\s*$/, '').split('|').map(c => c.trim()));
  assert.ok(rows.length >= 2 && rows[1].every(c => /^:?-+:?$/.test(c)), 'expected a Markdown table');
  return rows.slice(2);
}

const ticks = text => [...text.matchAll(/`([^`]+)`/g)].map(m => m[1]);

// --- shell source helpers ---------------------------------------------------

// [{ file, fn, line }] for each line of lib/aic/*.sh, with its enclosing function.
const SH_LINES = LIB_AIC.flatMap(file => {
  let fn = '';
  return SH[file].split('\n').map(line => {
    const m = /^([A-Za-z_][A-Za-z0-9_]*) \(\) *\{/.exec(line);
    if (m) fn = m[1];
    return { file, fn, line };
  });
});
const isComment = line => /^\s*#/.test(line);

// --- commands and flags -----------------------------------------------------

test('the stable commands table equals the public commands of lib/cli-spec.mjs', () => {
  const rows = tableRows(section(PAGE, 'Stable commands'));
  const page = new Map();
  for (const [cmdCell, flagCell] of rows) {
    const names = ticks(cmdCell).map(t => /^aic (\S+)$/.exec(t)?.[1]);
    assert.ok(names.length && names.every(Boolean), stale(`bad command cell: ${cmdCell}`));
    // "`--allow-unsafe`; after `--`: `--log-level <level>`, …"
    const [own, after = ''] = flagCell.split('after `--`:');
    const tokens = ticks(own).map(t => t.replace(/ <[^>]+>$/, ''));
    page.set(names[0], {
      aliases: names.slice(1),
      flags: tokens.filter(t => t.startsWith('-')),
      choices: tokens.filter(t => /^[a-z][a-z0-9-]*$/.test(t)),
      passthrough: ticks(after).map(t => t.replace(/ <[^>]+>$/, '')),
      text: own,
    });
  }
  const pub = publicCommands();
  sameSet([...page.keys()], pub.map(c => c.name), 'stable commands');
  for (const cmd of pub) {
    const row = page.get(cmd.name);
    sameSet(row.aliases, cmd.aliases || [], `aliases of aic ${cmd.name}`);
    sameSet(row.flags, (cmd.flags || []).flatMap(f => [f.long, f.short].filter(Boolean)), `flags of aic ${cmd.name}`);
    sameSet(row.choices, cmd.positional?.choices || [], `arguments of aic ${cmd.name}`);
    sameSet(row.passthrough, cmd.passthrough || [], `options after -- of aic ${cmd.name}`);
    for (const flag of (cmd.flags || []).filter(f => f.values)) {
      assert.ok(row.text.includes(`\`${flag.long} <${flag.valueName}>\``),
        stale(`write aic ${cmd.name} ${flag.long} as \`${flag.long} <${flag.valueName}>\``));
    }
  }
});

test('the page names the values of --with and --shell', () => {
  const values = Object.fromEntries(COMMANDS.flatMap(c => c.flags || []).filter(f => f.values)
    .map(f => [f.valueName, f.values]));
  for (const [name, list] of Object.entries(values)) {
    // A list item with its continuation lines.
    const items = section(PAGE, 'Stable commands').join('\n').split(/\n(?! {2})/);
    const line = items.find(l => l.startsWith(`- \`<${name}>\``));
    assert.ok(line, stale(`no "- \`<${name}>\`" line below the stable commands table`));
    const words = new Set(list.flatMap(v => v.split(',')));
    sameSet(ticks(line).filter(t => t !== `<${name}>`), [...words], `values of <${name}>`);
  }
});

test('the internal commands table equals the internal commands of lib/cli-spec.mjs', () => {
  const rows = tableRows(section(PAGE, 'Internal commands'));
  const names = rows.map(([cell]) => /^`aic (\S+)`$/.exec(cell)?.[1]);
  assert.ok(names.every(Boolean), stale('each internal command cell is one `aic <name>`'));
  sameSet(names, COMMANDS.filter(c => c.internal).map(c => c.name), 'internal commands');
});

test('die exits 1 and usage_die exits 2, as the exit codes table says', () => {
  const aic = read('aic');
  assert.match(aic, /^die\(\) *\{ err "\$\*"; exit 1; \}$/m, stale('die no longer exits 1'));
  assert.match(aic, /^usage_die\(\) *\{ err "\$\*"; exit 2; \}$/m, stale('usage_die no longer exits 2'));
  assert.match(aic, /^ {2}\*\) cmd_help >&2; usage_die "unknown command: \$1" ;;$/m,
    stale('an unknown command is no longer a usage error'));
  // A usage error is only a parse error: never in the security gate.
  assert.doesNotMatch(SH['validation.sh'].replace(/^cmd_trust \(\) \{[\s\S]*?\n\}/m, ''), /usage_die/,
    'validation.sh uses usage_die outside the argument parse of cmd_trust; a security refusal must exit 1');
  const rows = tableRows(section(PAGE, 'Exit codes'));
  sameSet(rows.map(([result, code]) => `${result}=${code}`),
    ['Pass=0', 'Warning=0', 'Blocker=1', 'Usage error=2'], 'exit codes');
  // doctor: blockers return 1, warnings return 0.
  const doctor = SH['doctor.sh'];
  assert.match(doctor, /json_field_string result blocked\n[^\n]*\n {2}return 1\n/, stale('doctor blocker exit code'));
});

// --- JSON output ------------------------------------------------------------

test('the schema number on the page equals AIC_JSON_SCHEMA', () => {
  const m = /^AIC_JSON_SCHEMA=(\d+)$/m.exec(SH['json.sh']);
  assert.ok(m, 'lib/aic/json.sh has no AIC_JSON_SCHEMA=<n> line');
  const lines = section(PAGE, 'The schema rule').join('\n');
  const onPage = [...lines.matchAll(/"schema": (\d+)/g)].map(x => x[1]);
  assert.ok(onPage.length, stale('the schema rule names no "schema": <n>'));
  sameSet(onPage, [m[1]], 'the schema number');
  assert.match(read('docs/user/usage.md'), new RegExp(`The value is \`${m[1]}\``),
    'docs/user/usage.md names another schema number; update it too');
  for (const key of ['schema', 'command', 'ok', 'error']) {
    assert.match(SH['json.sh'], new RegExp(`"${key}":`), `json_run no longer prints ${key}`);
  }
  const common = section(PAGE, 'Members').find(l => l.startsWith('Each object has'));
  sameSet(ticks(common || ''), ['schema', 'command', 'ok', 'error'], 'the members of each object');
});

// The command of a function that records JSON fields or items.
function commandOf(fn) {
  for (const cmd of ['doctor', 'status', 'validate', 'version']) {
    if (fn.startsWith(`cmd_${cmd}`) || fn.startsWith(`${cmd}_`)) return cmd;
  }
  return '';
}

test('the members table equals the json_field calls and the json_run lists', () => {
  const expected = { doctor: [], status: [], validate: [], version: [] };
  for (const { file, fn, line } of SH_LINES) {
    if (isComment(line)) continue;
    const run = /\bjson_run (\w+) (\w+|"") /.exec(line);
    if (run && file !== 'json.sh') {
      assert.ok(run[1] in expected, stale(`new --json command ${run[1]}`));
      if (run[2] !== '""') expected[run[1]].push(run[2]);
    }
    if (file === 'json.sh') continue;
    for (const field of line.matchAll(/\bjson_field(?:_string)?\s+(\S+)/g)) {
      assert.match(field[1], /^[a-z_]+$/, `${file}: ${fn} records a JSON member without a literal name`);
      const cmd = commandOf(fn);
      assert.ok(cmd, `${file}: ${fn} records the JSON member ${field[1]}; teach commandOf() its command`);
      expected[cmd].push(field[1]);
    }
  }
  const rows = tableRows(section(PAGE, 'Members'));
  sameSet(rows.map(([c]) => ticks(c)[0]), Object.keys(expected), 'commands with --json');
  for (const [cell, members] of rows) {
    const cmd = ticks(cell)[0];
    sameSet(ticks(members), expected[cmd], `members of ${cmd} --json`);
  }
});

// The ids that the code can emit: { doctor: Map(id -> ''), validate: Map(id -> level) }.
function emittedIds() {
  const doctor = new Map(), validate = new Map();
  for (const { file, fn, line } of SH_LINES) {
    if (isComment(line)) continue;
    for (const m of line.matchAll(/\bdoctor_(?:ok|warn|fail)\s+(\S+)/g)) {
      if (m[1] === '()') continue; // the definition
      assert.match(m[1], /^[a-z][a-z0-9-]*$/, `${file}: ${fn} gives a doctor check without a literal id`);
      doctor.set(m[1], '');
    }
    for (const item of line.matchAll(/\bjson_item\s+(\S+)\s+(\S+)/g)) {
      if (item[1] === '()') continue; // the definition
      if (fn === 'doctor_report' && item[1] === '"$id"') continue;
      if (file === 'json.sh' && fn === 'json_findings') continue;
      assert.match(item[1], /^[a-z][a-z0-9-]*$/, `${file}: ${fn} adds a JSON item without a literal id; teach this test about it`);
      assert.equal(commandOf(fn), 'validate', `${file}: ${fn} adds the JSON item ${item[1]}; teach this test its command`);
      validate.set(item[1], item[2]);
    }
  }
  // json_findings <level> "$var": the categories that $var holds, in lower case.
  const gate = SH['validation.sh'];
  const holds = new Map();
  for (const [, v, cat] of gate.matchAll(/^\s*(\w+)="\$\(grep '\^([A-Z]+)'/gm)) holds.set(v, [cat]);
  for (const [, v, other] of gate.matchAll(/^\s*(\w+)="\$\{\1\}\$\{\1:\+\n\}\$\{(\w+)\}"/gm)) {
    holds.set(v, [...(holds.get(v) || []), ...(holds.get(other) || [])]);
  }
  const findings = [...gate.matchAll(/\bjson_findings (fail|warn) "\$(\w+)"/g)];
  assert.ok(findings.length, 'lib/aic/validation.sh has no json_findings call');
  for (const [, level, v] of findings) {
    assert.ok(holds.has(v), `validation.sh: json_findings reads $${v}, which this test cannot map to a category`);
    for (const cat of holds.get(v)) {
      const id = cat.toLowerCase();
      assert.ok(!validate.has(id) || validate.get(id) === level, `finding ${id} has two levels`);
      validate.set(id, level);
    }
  }
  // Each category that the gate writes reaches json_findings.
  const written = [
    ...[...read('lib/validate.mjs').matchAll(/\breport\('([A-Z]+)'\)/g)].map(m => m[1]),
    ...[...gate.matchAll(/printf '([A-Z]+)\\t/g)].map(m => m[1]),
  ];
  for (const cat of new Set(written)) {
    assert.ok(validate.has(cat.toLowerCase()), `the gate writes ${cat} findings, but aic validate --json never reports them`);
  }
  return { doctor, validate };
}

test('the doctor check ids equal the ids that doctor can report', () => {
  const rows = tableRows(section(PAGE, 'Doctor check ids'));
  sameSet(rows.map(([c]) => ticks(c)[0]), [...emittedIds().doctor.keys()], 'doctor check ids');
});

test('the validate finding ids and levels equal what validate can report', () => {
  const rows = tableRows(section(PAGE, 'Validate finding ids'));
  const page = rows.map(([id, level]) => `${ticks(id)[0]}=${ticks(level)[0]}`);
  sameSet(page, [...emittedIds().validate].map(([id, level]) => `${id}=${level}`), 'validate finding ids and levels');
});

// --- files in .devcontainer/ ------------------------------------------------

const POST_CREATE_MODULES = (/^AIC_POST_CREATE_MODULES="([^"]+)"$/m.exec(SH['identity.sh']) || [])[1]?.split(' ') || [];

// Expand `statusline.{sh,mjs,js,py}` and `post_create_*.py`.
function expand(names) {
  return names.flatMap(n => {
    const brace = /^(.*)\{([^}]+)\}(.*)$/.exec(n);
    if (brace) return brace[2].split(',').map(x => `${brace[1]}${x}${brace[3]}`);
    if (n === 'post_create_*.py') return POST_CREATE_MODULES;
    return [n];
  });
}

const pageProjectOwned = () => expand(tableRows(section(PAGE, 'Project-owned files')).map(([c]) => ticks(c)[0]));
const pageManaged = () => expand(section(PAGE, 'Managed files').filter(l => /^\s*- /.test(l) || /^\s{2,}\S/.test(l))
  .flatMap(l => ticks(l.replace(/\(.*?\)/g, ''))));

test('the managed and project-owned files equal AIC_CONTROL_FILES', () => {
  assert.ok(POST_CREATE_MODULES.length, 'lib/aic/identity.sh has no AIC_POST_CREATE_MODULES list');
  const m = /^AIC_CONTROL_FILES="([^"]+)"$/m.exec(SH['identity.sh']);
  assert.ok(m, 'lib/aic/identity.sh has no AIC_CONTROL_FILES list');
  const control = m[1].split(' ').flatMap(n => (n === '$AIC_POST_CREATE_MODULES' ? POST_CREATE_MODULES : [n]));
  const owned = pageProjectOwned(), managed = pageManaged();
  assert.deepEqual(owned.filter(n => managed.includes(n)), [], stale('a file is both managed and project-owned'));
  sameSet([...owned, ...managed.filter(n => !n.endsWith('/'))], control, 'managed and project-owned files');
  for (const dir of managed.filter(n => n.endsWith('/'))) {
    assert.ok(fs.statSync(path.join(REPO, 'template', dir)).isDirectory(), stale(`template/${dir} does not exist`));
  }
});

test('the file split equals the template README', () => {
  const readme = read('template/README.md').split('\n');
  const start = h => readme.findIndex(l => l.startsWith('## ') && l.includes(h));
  const table = from => {
    const out = [];
    for (const line of readme.slice(from + 1)) {
      if (line.startsWith('## ')) break;
      out.push(line);
    }
    return tableRows(out);
  };
  const owned = expand(table(start('Project-owned')).map(([c]) => ticks(c)[0]));
  const managed = expand(table(start('Managed by aic')).flatMap(([c]) => ticks(c)));
  sameSet(pageProjectOwned(), owned, 'project-owned files (template/README.md)');
  sameSet(pageManaged(), managed, 'managed files (template/README.md)');
});

test('the in-container paths on the page are real', () => {
  const rows = tableRows(section(PAGE, 'Paths inside the container'));
  sameSet(rows.map(([c]) => ticks(c)[0]), ['/etc/aic/', '/workspace', '/workspace/.devcontainer/'], 'in-container paths');
  assert.match(read('template/Dockerfile'), /chown -R root:root \/etc\/aic$/m, stale('/etc/aic is no longer root-owned'));
  assert.match(read('template/devcontainer.json'), /"workspaceFolder": "\/workspace"/, stale('the workspace is no longer /workspace'));
  for (const compose of ['template/docker-compose.pull.yml', 'template/docker-compose.build.yml']) {
    assert.match(read(compose), /- \.\.\/\.devcontainer:\/workspace\/\.devcontainer:ro$/m,
      stale(`${compose} no longer mounts .devcontainer/ read-only`));
  }
});

// --- environment variables --------------------------------------------------

test('the public environment variables match aic help and the code', () => {
  const rows = tableRows(section(PAGE, 'Environment variables'));
  const vars = rows.map(([name, where]) => ({ name: ticks(name)[0], where: where.trim() }));
  const help = SH['help.sh'];
  const from = help.indexOf('\nEnv:\n');
  assert.ok(from >= 0, 'aic help has no Env: section');
  const env = help.slice(from, help.indexOf('\nEOF', from));
  const helpVars = [...env.matchAll(/^ {2}(AIC_[A-Z_]+)\s/gm)].map(m => m[1]);
  sameSet(vars.filter(v => v.where === 'host' && v.name !== 'CI').map(v => v.name), helpVars, 'host variables (aic help Env:)');
  const code = [read('aic'), ...Object.values(SH), read('template/devcontainer.json'),
    read('lib/aic/template.sh'), ...fs.readdirSync(path.join(REPO, 'template')).filter(f => f.endsWith('.py'))
      .map(f => read(`template/${f}`))].join('\n');
  for (const { name } of vars) {
    assert.match(code, new RegExp(`\\b${name}\\b`), stale(`${name} is not used by the code`));
  }
});

// --- links and rules --------------------------------------------------------

test('the page is linked, and the change rule is in AGENTS.md and releasing.md', () => {
  for (const [file, link] of [['README.md', 'docs/user/stability.md'], ['docs/README.md', 'user/stability.md'],
    ['docs/user/usage.md', 'stability.md'], ['docs/contributing/releasing.md', '../user/stability.md']]) {
    assert.ok(read(file).includes(`(${link}`), `${file} does not link ${link}`);
  }
  assert.ok(read('AGENTS.md').includes('docs/user/stability.md'), 'AGENTS.md does not name docs/user/stability.md');
});
