// The structural half of aic's pre-Docker security gate.
//
// aic resolves the Compose models with `docker compose config`, then runs
// validate-cli.mjs, which calls analyzeResolvedConfig() and prints one finding
// per line:
//
//   MANAGED<TAB>msg   managed configuration that cannot be trusted (aic sync)
//   UNSAFE<TAB>msg    a host-boundary expansion that exact trust may approve
//   VOLATILE<TAB>msg  an expansion that persistent trust cannot cover
//   DOCKER<TAB>msg    a Docker daemon mode that needs host consent
//
// analyzeResolvedConfig() takes file contents, not file names, so
// tests/test-aic-validate.mjs drives it with JSON fixtures and no Docker. It
// reads the filesystem only for paths below the project root: real paths of
// mount and build sources, the two Compose source files, and the Dockerfile of
// an override build.
//
// Only node: built-ins, no packages: this runs on the host before any trust
// decision. Node is already a package prerequisite (>=18).

import fs from 'node:fs';
import path from 'node:path';

// Findings include repository-controlled service names, paths, and values.
// Render terminal controls visibly so validation itself cannot spoof prompts,
// erase prior output, or plant clickable escape sequences on the host.
export const safeDiagnostic = value => String(value).replace(
  /[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g,
  char => `\\u${char.codePointAt(0).toString(16).padStart(4, '0')}`,
);

const isPlainObject = value => !!value && typeof value === 'object' && !Array.isArray(value);

export function parseJsonc(source) {
  // The Dev Containers CLI scanner also ends a // comment at a bare carriage
  // return, and other JSONC scanners treat U+2028/U+2029 as line breaks. Text
  // after one is a comment to one parser and live keys to the other, so refuse
  // the file instead of guessing which reading the CLI will act on.
  if (/\r(?!\n)|[\u2028\u2029]/.test(source)) {
    throw new Error('contains a bare carriage return or a Unicode line separator');
  }
  let out = '', string = false, escape = false;
  for (let i = 0; i < source.length; i++) {
    const c = source[i], n = source[i + 1];
    if (string) {
      out += c;
      if (escape) escape = false;
      else if (c === '\\') escape = true;
      else if (c === '"') string = false;
      continue;
    }
    if (c === '"') { string = true; out += c; continue; }
    if (c === '/' && n === '/') {
      out += '  '; i++;
      while (i + 1 < source.length && source[i + 1] !== '\n') { out += ' '; i++; }
      continue;
    }
    if (c === '/' && n === '*') {
      out += '  '; i++;
      let closed = false;
      while (i + 1 < source.length) {
        i++;
        if (source[i] === '*' && source[i + 1] === '/') { out += '  '; i++; closed = true; break; }
        out += source[i] === '\n' ? '\n' : ' ';
      }
      if (!closed) throw new Error('unterminated block comment');
      continue;
    }
    out += c;
  }
  // Remove trailing commas outside strings without touching string content.
  let clean = '', inString = false; escape = false;
  for (let i = 0; i < out.length; i++) {
    const c = out[i];
    if (inString) {
      clean += c;
      if (escape) escape = false;
      else if (c === '\\') escape = true;
      else if (c === '"') inString = false;
      continue;
    }
    if (c === '"') { inString = true; clean += c; continue; }
    if (c === ',') {
      let j = i + 1;
      while (j < out.length && /\s/.test(out[j])) j++;
      if (out[j] === '}' || out[j] === ']') continue;
    }
    clean += c;
  }
  return { value: JSON.parse(clean), source };
}

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, stable(value[key])]));
  }
  return value;
}
const equal = (a, b) => JSON.stringify(stable(a)) === JSON.stringify(stable(b));
const clone = value => JSON.parse(JSON.stringify(value));

// Compose interpolation is host input. Without this check an untrusted
// override could turn `TOKEN: ${HOST_TOKEN}` (or a build arg/path equivalent)
// into a secret bridge from the host shell to the unrestricted container.
// `--no-interpolate` preserves the expression without resolving its value;
// comparing against the managed base keeps the template's fixed HOME/socket/TZ
// expressions valid. An even-length dollar run (`$${VAR}`) is an escaped
// literal and deliberately remains frictionless.
export function activeInterpolations(value) {
  if (typeof value !== 'string') return [];
  const names = [], pattern = /(\$+)(?:\{([A-Za-z_][A-Za-z0-9_]*)[^}]*\}|([A-Za-z_][A-Za-z0-9_]*))/g;
  for (const match of value.matchAll(pattern)) {
    if (match[1].length % 2 === 1) names.push(match[2] || match[3]);
  }
  return names;
}

// Compose accepts `environment` / `build.args` as either a map or a `K=V`
// list, and merging an override flips the managed base's map into a list. The
// comparisons below key on position, so without this normalization every
// managed `${VAR}` in the base would read as override-added the moment any
// override exists. Compare by name instead.
function normalizeEnvShape(value) {
  if (!Array.isArray(value)) return value;
  const out = {};
  for (const entry of value) {
    if (typeof entry !== 'string') return value;
    const eq = entry.indexOf('=');
    if (eq === -1) out[entry] = null;
    else out[entry.slice(0, eq)] = entry.slice(eq + 1);
  }
  return out;
}
function normalizeInterpolationModel(model) {
  for (const service of Object.values((model && model.services) || {})) {
    if (!service || typeof service !== 'object') continue;
    if (service.environment) service.environment = normalizeEnvShape(service.environment);
    if (service.build && typeof service.build === 'object' && service.build.args) {
      service.build.args = normalizeEnvShape(service.build.args);
    }
  }
  return model;
}

function realpathLoose(input) {
  let current = path.resolve(input), suffix = [];
  while (!fs.existsSync(current)) {
    const parent = path.dirname(current);
    if (parent === current) break;
    suffix.unshift(path.basename(current)); current = parent;
  }
  try { current = fs.realpathSync.native(current); } catch (_) { current = path.resolve(current); }
  return path.resolve(current, ...suffix);
}

// input: {
//   devcontainer, templateDevcontainer   JSONC text of the project and template
//                                        devcontainer.json
//   compose: { base, expected, final, noenv, rawBase, rawFinal }
//                                        JSON text of the resolved models (see
//                                        validate_project_security in aic)
//   root                                 canonical project root
//   expectedName                         expected Compose project name
//   hasOverride                          docker-compose.override.yml exists
//   runtimeUser                          host runtime UID:GID
//   statusRelay, statusProject, statusProjectId
//                                        host-generated status relay values
// }
// Returns [{ kind, message }] in the order found. Messages are already passed
// through safeDiagnostic().
export function analyzeResolvedConfig(input) {
  const {
    devcontainer, templateDevcontainer, compose, root, expectedName, hasOverride,
    runtimeUser, statusRelay, statusProject, statusProjectId,
  } = input;
  const findings = [];
  const report = kind => msg => findings.push({ kind, message: safeDiagnostic(msg) });
  const managed = report('MANAGED');
  const unsafe = report('UNSAFE');
  const volatile = report('VOLATILE');
  const docker = report('DOCKER');

  let actualDev, templateDev;
  try {
    actualDev = parseJsonc(devcontainer);
    templateDev = parseJsonc(templateDevcontainer);
  } catch (error) {
    managed(`devcontainer.json is not valid JSONC: ${error.message}`);
    actualDev = { value: {}, source: '' };
    templateDev = { value: {}, source: '' };
  }

  if (!isPlainObject(actualDev.value)) managed('devcontainer.json must be an object');
  const dc = isPlainObject(actualDev.value) ? actualDev.value : {};
  const td = isPlainObject(templateDev.value) ? templateDev.value : {};
  const wantedCompose = hasOverride
    ? ['docker-compose.yml', 'docker-compose.override.yml']
    : ['docker-compose.yml'];
  if (JSON.stringify(dc.dockerComposeFile) !== JSON.stringify(wantedCompose)) {
    managed(`dockerComposeFile must be exactly ${JSON.stringify(wantedCompose)}; run aic sync`);
  }
  // Top-level keys are an allow-list taken from the pristine template, never a
  // deny-list. The Dev Containers CLI acts on keys aic does not write:
  // runServices starts extra Compose services, features and lifecycle commands
  // run code, and the spec keeps adding keys. aic rewrites only these merge
  // targets on sync; every other template key must match exactly.
  const devMergeTargets = new Set(['name', 'dockerComposeFile', 'containerEnv', 'customizations']);
  for (const key of Object.keys(dc)) {
    if (!Object.prototype.hasOwnProperty.call(td, key)) {
      managed(`devcontainer.json must not define unmanaged ${key}; run aic sync and use a documented project-owned extension point`);
    }
  }
  for (const key of Object.keys(td)) {
    if (!devMergeTargets.has(key) && JSON.stringify(dc[key]) !== JSON.stringify(td[key])) {
      managed(`devcontainer.json managed anchor ${key} differs from the template; run aic sync`);
    }
  }
  if (typeof dc.name !== 'string') managed('devcontainer.json name must be a string; run aic sync');
  // aic merges only VS Code extension ids and settings into customizations.
  const vscodeCustomizations = isPlainObject(dc.customizations) ? dc.customizations.vscode : undefined;
  if (!isPlainObject(dc.customizations) || Object.keys(dc.customizations).join() !== 'vscode'
      || !isPlainObject(vscodeCustomizations)
      || Object.keys(vscodeCustomizations).some(key => key !== 'extensions' && key !== 'settings')
      || !Array.isArray(vscodeCustomizations.extensions)
      || vscodeCustomizations.extensions.some(id => typeof id !== 'string')
      || !isPlainObject(vscodeCustomizations.settings)) {
    managed('devcontainer.json customizations may contain only vscode.extensions and vscode.settings; run aic sync');
  }
  if (!actualDev.source.includes('aic:vscode-extensions') || !actualDev.source.includes('aic:vscode-settings')) {
    managed('devcontainer.json is missing managed VS Code merge anchors; run aic sync');
  }
  if (dc.containerEnv !== undefined && !isPlainObject(dc.containerEnv)) {
    managed('devcontainer.json containerEnv must be an object; run aic sync');
  }
  const actualEnv = isPlainObject(dc.containerEnv) ? dc.containerEnv : {};
  const templateEnv = isPlainObject(td.containerEnv) ? td.containerEnv : {};
  for (const [key, value] of Object.entries(templateEnv)) {
    if (actualEnv[key] !== value) managed(`containerEnv.${key} differs from the managed template; run aic sync`);
  }
  if (!/^(claude-code|codex|opencode)(,(claude-code|codex|opencode))*$/.test(actualEnv.AIC_TOOLS || '')) {
    managed('containerEnv.AIC_TOOLS is missing or invalid; run aic sync');
  }
  if (!['zsh', 'bash', 'fish'].includes(actualEnv.AIC_SHELL)) {
    managed('containerEnv.AIC_SHELL is missing or invalid; run aic sync');
  }
  const allowedContainerEnv = new Set([...Object.keys(templateEnv), 'AIC_TOOLS', 'AIC_SHELL']);
  for (const key of Object.keys(actualEnv)) {
    if (!allowedContainerEnv.has(key)) {
      managed(`devcontainer.json contains unmanaged containerEnv.${key}; move project environment to docker-compose.override.yml and run aic sync`);
    }
  }
  // VS Code acts on these when it attaches: an extension runs code in the
  // container, and settings (terminal profiles, interpreter and tool paths) start
  // programs. sync writes the template's values plus the project-owned
  // vscode-extensions / vscode-settings.json, but a repository can also commit the
  // result directly. So every addition is project code that needs exact trust,
  // and a changed managed value is drift.
  const templateVscode = isPlainObject(td.customizations) && isPlainObject(td.customizations.vscode)
    ? td.customizations.vscode : {};
  const managedExtensions = new Set((Array.isArray(templateVscode.extensions) ? templateVscode.extensions : [])
    .map(id => String(id).toLowerCase()));
  const actualVscode = isPlainObject(vscodeCustomizations) ? vscodeCustomizations : {};
  for (const id of Array.isArray(actualVscode.extensions) ? actualVscode.extensions : []) {
    if (typeof id === 'string' && !managedExtensions.has(id.toLowerCase())) {
      unsafe(`devcontainer.json installs VS Code extension ${id}, which runs code in the container (vscode-extensions)`);
    }
  }
  const expectedSettings = { ...(isPlainObject(templateVscode.settings) ? templateVscode.settings : {}) };
  // Mirrors the per-shell rewrite in patch_devcontainer_json.
  if (['zsh', 'bash', 'fish'].includes(actualEnv.AIC_SHELL)) {
    if ('terminal.integrated.defaultProfile.linux' in expectedSettings) {
      expectedSettings['terminal.integrated.defaultProfile.linux'] = actualEnv.AIC_SHELL;
    }
    if ('terminal.integrated.fontFamily' in expectedSettings) {
      expectedSettings['terminal.integrated.fontFamily'] = actualEnv.AIC_SHELL === 'zsh' ? "'MesloLGS NF', monospace" : 'monospace';
    }
  }
  const actualSettings = isPlainObject(actualVscode.settings) ? actualVscode.settings : {};
  for (const [key, value] of Object.entries(actualSettings)) {
    if (!Object.prototype.hasOwnProperty.call(expectedSettings, key)) {
      unsafe(`devcontainer.json sets VS Code setting ${key}; settings can start programs in the container (vscode-settings.json)`);
    } else if (JSON.stringify(stable(value)) !== JSON.stringify(stable(expectedSettings[key]))) {
      managed(`devcontainer.json managed VS Code setting ${key} differs from the template; run aic sync`);
    }
  }
  for (const key of Object.keys(expectedSettings)) {
    if (!Object.prototype.hasOwnProperty.call(actualSettings, key)) {
      managed(`devcontainer.json is missing managed VS Code setting ${key}; run aic sync`);
    }
  }


  let base, expected, final, noenv, rawBase, rawFinal;
  try {
    base = JSON.parse(compose.base);
    expected = JSON.parse(compose.expected);
    final = JSON.parse(compose.final);
    noenv = JSON.parse(compose.noenv);
    rawBase = JSON.parse(compose.rawBase);
    rawFinal = JSON.parse(compose.rawFinal);
  } catch (error) {
    managed(`could not parse resolved Compose configuration: ${error.message}`);
    return findings;
  }
  if (base.name !== expectedName || final.name !== expectedName) {
    managed(`resolved Compose name must be ${expectedName}; run aic sync`);
  }

  function inspectInterpolation(value, baseline, parts = []) {
    if (typeof value === 'string') {
      const names = activeInterpolations(value);
      if (names.length && value !== baseline) {
        const location = parts.length ? parts.join('.') : '<root>';
        unsafe(`override uses host environment interpolation at ${location} (${[...new Set(names)].join(', ')})`);
      }
      return;
    }
    if (Array.isArray(value)) {
      value.forEach((entry, index) => inspectInterpolation(
        entry, Array.isArray(baseline) ? baseline[index] : undefined, [...parts, String(index)]));
      return;
    }
    if (value && typeof value === 'object') {
      for (const [key, entry] of Object.entries(value)) {
        const prior = baseline && typeof baseline === 'object' ? baseline[key] : undefined;
        inspectInterpolation(entry, prior, [...parts, key]);
      }
    }
  }
  function inspectPassThroughMap(value, baseline, parts) {
    if (Array.isArray(value)) {
      const prior = new Set(Array.isArray(baseline) ? baseline : []);
      for (const entry of value) {
        if (typeof entry === 'string' && /^[A-Za-z_][A-Za-z0-9_]*$/.test(entry) && !prior.has(entry)) {
          unsafe(`override forwards host environment variable at ${parts.join('.')} (${entry})`);
        }
      }
      return;
    }
    if (value && typeof value === 'object') {
      for (const [key, entry] of Object.entries(value)) {
        const prior = baseline && typeof baseline === 'object' ? baseline[key] : undefined;
        if (entry === null && prior !== null) {
          unsafe(`override forwards host environment variable at ${[...parts, key].join('.')} (${key})`);
        }
      }
    }
  }
  function inspectHostPassThrough(model, baseline) {
    for (const [serviceName, service] of Object.entries(model.services || {})) {
      const prior = (baseline.services || {})[serviceName] || {};
      inspectPassThroughMap(service.environment, prior.environment, ['services', serviceName, 'environment']);
      if (service.build) {
        inspectPassThroughMap(service.build.args, (prior.build || {}).args, ['services', serviceName, 'build', 'args']);
      }
    }
  }
  if (hasOverride) {
    normalizeInterpolationModel(rawBase);
    normalizeInterpolationModel(rawFinal);
    inspectInterpolation(rawFinal, rawBase);
    inspectHostPassThrough(rawFinal, rawBase);
  }

  const canonical = value => {
    try { return fs.realpathSync.native(value); } catch (_) { return path.resolve(value); }
  };
  // root is canonical, so each source below is its own real path only when no
  // component under root is a symlink. Docker follows such a symlink on the host.
  const managedProjectSources = new Map([
    ['/workspace', root],
    ['/workspace/.devcontainer', path.join(root, '.devcontainer')],
    ['/workspace/.git', path.join(root, '.git')],
    ['/workspace/.git/config', path.join(root, '.git', 'config')],
    ['/workspace/.git/config.worktree', path.join(root, '.git', 'config.worktree')],
    ['/workspace/.git/commondir', path.join(root, '.git', 'commondir')],
    ['/workspace/.git/hooks', path.join(root, '.git', 'hooks')],
  ]);

  function normalizeManaged(model, actual) {
    const m = clone(model);
    m.name = '<managed-project>';
    if (actual && String(m['x-aic-runtime-user'] || '') !== runtimeUser) {
      managed(`managed runtime user must be ${runtimeUser} on this host; run aic sync`);
    }
    if (Object.prototype.hasOwnProperty.call(m, 'x-aic-runtime-user')) {
      m['x-aic-runtime-user'] = '<managed-runtime-user>';
    }
    const aicImages = Object.values(m.services || {})
      .map(service => service && service.image)
      .filter(image => typeof image === 'string' && /^ghcr\.io\/stefanoginella\/aicontainer:/.test(image));
    if (actual && aicImages.length > 0 && new Set(aicImages).size !== 1) {
      managed('all managed aicontainer services must use the same pinned image tag; run aic sync');
    }
    if (m['x-aic-image']) {
      if (actual && !/^ghcr\.io\/stefanoginella\/aicontainer:v[0-9]+\.[0-9]+\.[0-9]+$/.test(m['x-aic-image'])) {
        managed('managed aicontainer image extension must be a version pin; run aic sync');
      }
      m['x-aic-image'] = '<managed-aicontainer-image>';
    }
    for (const [networkKey, network] of Object.entries(m.networks || {})) {
      if (network && typeof network === 'object' && network.name) {
        if (actual && network.name !== `${expectedName}_${networkKey}`) {
          managed(`managed network ${networkKey} must remain project-scoped; run aic sync`);
        }
        network.name = '<managed-network>';
      }
    }
    for (const volumeName of ['aic-sessions', 'aic-sanitized-seed']) {
      if (m.volumes && m.volumes[volumeName]) {
        if (actual && m.volumes[volumeName].name !== `${expectedName}_${volumeName}`) {
          managed(`managed volume ${volumeName} must remain project-scoped; run aic sync`);
        }
        m.volumes[volumeName].name = `<project-volume:${volumeName}>`;
      }
    }
    for (const [serviceName, service] of Object.entries(m.services || {})) {
      if (service.image && /^ghcr\.io\/stefanoginella\/aicontainer:/.test(service.image)) {
        if (actual && !/^ghcr\.io\/stefanoginella\/aicontainer:v[0-9]+\.[0-9]+\.[0-9]+$/.test(service.image)) {
          managed('managed aicontainer service image must be a version pin; run aic sync');
        }
        service.image = '<managed-aicontainer-image>';
      }
      if (service.build && service.build.context) {
        if (actual && canonical(service.build.context) !== canonical(path.join(root, '.devcontainer'))) {
          managed(`managed service ${serviceName} build context escaped .devcontainer; run aic sync`);
        }
        service.build.context = '<managed-build-context>';
      }
    }
    const dev = m.services && m.services.devcontainer;
    if (dev) {
      if (dev.image) {
        // Normalized above together with any managed helper using the same image.
      }
      for (const volume of dev.volumes || []) {
        if (managedProjectSources.has(volume.target)) {
          // Compare with the symlink-free path. Resolving both sides would pass
          // a symlinked .git or .git/config that points outside the checkout.
          if (actual && (volume.type !== 'bind' || realpathLoose(volume.source) !== managedProjectSources.get(volume.target))) {
            managed(`managed mount source for ${volume.target} escaped this project (a symlink, or a changed path); run aic sync`);
          }
          volume.source = `<managed-source:${volume.target}>`;
        }
      }
      const managedStatusEnvironment = {
        AIC_STATUS_RELAY: statusRelay,
        AIC_STATUS_PROJECT: statusProject,
        AIC_STATUS_PROJECT_ID: statusProjectId,
      };
      for (const [key, expected] of Object.entries(managedStatusEnvironment)) {
        const found = String((dev.environment || {})[key] || '');
        if (actual && found !== expected) {
          managed(`managed ${key} must match host-generated runtime state; run aic sync`);
        }
        if (dev.environment) dev.environment[key] = `<managed:${key}>`;
      }
    }
    const proxy = m.services && m.services['socket-proxy'];
    if (proxy && proxy.environment) {
      const readKeys = ['CONTAINERS', 'EVENTS', 'IMAGES', 'INFO', 'NETWORKS', 'VOLUMES'];
      const readValues = readKeys.map(key => String(proxy.environment[key]));
      const post = String(proxy.environment.POST), build = String(proxy.environment.BUILD);
      const coherentReads = readValues.every(value => value === '0') || readValues.every(value => value === '1');
      const coherentWrites = ['0', '1'].includes(post) && build === post;
      const writesWithoutReads = post === '1' && !readValues.every(value => value === '1');
      if (actual && (!coherentReads || !coherentWrites || writesWithoutReads)) {
        managed('socket-proxy Docker read/write toggles must encode one managed none/read/read-write mode; run aic sync');
      }
      for (const key of readKeys) proxy.environment[key] = '<managed-docker-read-mode>';
      proxy.environment.POST = '<managed-docker-mode>';
      proxy.environment.BUILD = '<managed-docker-mode>';
    }
    const authSync = m.services && m.services['aic-auth-sync'];
    if (authSync) {
      if (actual && String(authSync.user || '') !== runtimeUser) {
        managed(`managed aic-auth-sync user must be ${runtimeUser} on this host; run aic sync`);
      }
      authSync.user = '<managed-runtime-user>';
    }
    return m;
  }

  if (!equal(normalizeManaged(base, true), normalizeManaged(expected, false))) {
    managed('docker-compose.yml does not match the managed template invariants; run aic sync');
  }
  const dockerEnvironment = (((base.services || {})['socket-proxy'] || {}).environment || {});
  const dockerReadKeys = ['CONTAINERS', 'EVENTS', 'IMAGES', 'INFO', 'NETWORKS', 'VOLUMES'];
  const dockerReads = dockerReadKeys.every(key => String(dockerEnvironment[key]) === '1');
  const dockerWrites = String(dockerEnvironment.POST) === '1' && String(dockerEnvironment.BUILD) === '1';
  if (dockerWrites) {
    docker('managed Docker daemon read-write mode is enabled (object reads plus POST/BUILD)');
  } else if (dockerReads) {
    docker('managed Docker daemon read mode is enabled (host object metadata/log/file read APIs)');
  }

  const baseServices = base.services || {}, services = final.services || {};
  if (!services.devcontainer || !services['socket-proxy'] || !services['aic-auth-sync']) {
    managed('resolved Compose config must contain devcontainer, aic-auth-sync, and socket-proxy services');
    return findings;
  }

  for (const reserved of ['socket-proxy', 'aic-seed-sanitizer', 'aic-auth-sync', 'seed-sanitizer']) {
    if (baseServices[reserved] && !equal(services[reserved], baseServices[reserved])) {
      unsafe(`override changes the reserved ${reserved} service (image, command, mounts, environment, networks, or hardening)`);
    }
  }
  for (const networkName of Object.keys((baseServices['socket-proxy'] || {}).networks || {})) {
    if (!equal((final.networks || {})[networkName], (base.networks || {})[networkName])) {
      unsafe(`override changes the reserved socket-proxy network ${networkName}`);
    }
  }
  for (const volumeName of ['aic-auth-global', 'aic-shell-history', 'aic-sessions', 'aic-sanitized-seed']) {
    if (!equal((final.volumes || {})[volumeName], (base.volumes || {})[volumeName])) {
      unsafe(`override changes reserved volume definition ${volumeName}`);
    }
  }

  const withinRoot = input => {
    const resolved = realpathLoose(input);
    return resolved === root || resolved.startsWith(root + path.sep);
  };
  // Compare the whole mount spec, not a few fields. Compose merges mounts by
  // target, so an override entry with a managed target replaces the managed
  // mount; a key without volume.subpath/nocopy, bind.* or consistency would
  // accept a replacement that mounts the whole global auth volume.
  const volumeKey = v => JSON.stringify(stable({ ...v, type: v.type || 'volume', read_only: !!v.read_only }));
  const baselineMounts = new Map();
  for (const [serviceName, service] of Object.entries(baseServices)) {
    baselineMounts.set(serviceName, new Set((service.volumes || []).map(volumeKey)));
  }
  const protectedVolumes = new Set(['aic-auth-global', 'aic-shell-history', 'aic-sessions', 'aic-sanitized-seed']);
  const protectedPhysicalVolumes = new Set(
    ['aic-auth-global', 'aic-shell-history', ...Object.values(base.volumes || {}).map(v => v && v.name).filter(Boolean)]
  );
  const targetWithin = (target, prefix) => {
    const normalized = path.posix.normalize(String(target || ''));
    return normalized === prefix || normalized.startsWith(prefix + '/');
  };
  const isProtectedManagedTarget = target => {
    const normalized = path.posix.normalize(String(target || ''));
    return targetWithin(normalized, '/run') || targetWithin(normalized, '/etc') ||
      targetWithin(normalized, '/usr') || targetWithin(normalized, '/bin') ||
      targetWithin(normalized, '/sbin') || targetWithin(normalized, '/lib') ||
      targetWithin(normalized, '/lib64') || targetWithin(normalized, '/opt') ||
      targetWithin(normalized, '/workspace/.devcontainer') || targetWithin(normalized, '/workspace/.git');
  };
  const isApprovedDevcontainerDataTarget = target => {
    const normalized = path.posix.normalize(String(target || ''));
    if (targetWithin(normalized, '/workspace/.devcontainer') || targetWithin(normalized, '/workspace/.git')) return false;
    return targetWithin(normalized, '/workspace') || targetWithin(normalized, '/home/vscode/.cache');
  };

  // Compose environment outranks devcontainer.json/image ENV. Preserve the
  // root-managed tool homes, shell/Git startup, pre-policy dynamic loader, and
  // Docker proxy endpoint unless the host explicitly reviews the expansion.
  const protectedEnvironment = new Map(Object.entries(actualEnv));
  for (const key of ['DOCKER_HOST', 'AIC_STATUS_RELAY', 'AIC_STATUS_PROJECT', 'AIC_STATUS_PROJECT_ID']) {
    protectedEnvironment.set(key, String((baseServices.devcontainer.environment || {})[key] || ''));
  }
  protectedEnvironment.set('HOME', '/home/vscode');
  protectedEnvironment.set('ZDOTDIR', '/etc/aic/shell/zsh');
  protectedEnvironment.set('CODEX_HOME', '/home/vscode/.codex');
  protectedEnvironment.set('OPENCODE_CONFIG_DIR', '/home/vscode/.config/opencode');
  protectedEnvironment.set('OPENCODE_DATA_DIR', '/home/vscode/.local/share/opencode');
  const alwaysProtectedEnvironment = new Set([
    'PATH', 'BASH_ENV', 'ENV',
    'LD_PRELOAD', 'LD_AUDIT', 'LD_LIBRARY_PATH',
    'OPENCODE_CONFIG',
    'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME',
    'DOCKER_CONTEXT', 'DOCKER_CONFIG', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH',
  ]);
  const finalDevEnvironment = services.devcontainer.environment || {};
  for (const [key, value] of Object.entries(finalDevEnvironment)) {
    const expected = protectedEnvironment.get(key);
    const protectedKey = protectedEnvironment.has(key) || alwaysProtectedEnvironment.has(key) || /^GIT_CONFIG_/.test(key);
    if (protectedKey && (expected === undefined || String(value) !== String(expected))) {
      unsafe(`service devcontainer: environment ${key} overrides a managed startup or isolation boundary`);
    }
  }

  for (const [volumeName, spec] of Object.entries(final.volumes || {})) {
    if (protectedVolumes.has(volumeName) && (base.volumes || {})[volumeName]) continue; // exact definitions checked above
    const generatedName = `${expectedName}_${volumeName}`;
    if (spec && (spec.external || (spec.name && spec.name !== generatedName) || (spec.driver && spec.driver !== 'local') || Object.keys(spec.driver_opts || {}).length)) {
      unsafe(`volume ${volumeName} uses an external/custom name, driver, or driver_opts and may alias a host path or protected volume`);
    }
    if (spec && protectedPhysicalVolumes.has(spec.name)) {
      unsafe(`volume ${volumeName} aliases protected physical volume ${spec.name}`);
    }
  }

  for (const [networkName, spec] of Object.entries(final.networks || {})) {
    if ((base.networks || {})[networkName] && equal(spec, base.networks[networkName])) continue;
    const generatedName = `${expectedName}_${networkName}`;
    if (spec && (spec.external || (spec.name && spec.name !== generatedName) || (spec.driver && spec.driver !== 'bridge') || Object.keys(spec.driver_opts || {}).length)) {
      unsafe(`network ${networkName} uses an external/custom name, driver, or driver_opts`);
    }
  }

  // Compose top-level and service keys are allow-lists too. A key below is
  // either inspected by a dedicated check in this validator or only changes the
  // service's own container (resource limits, names, DNS, restart and stop
  // behavior). Any other key -- lifecycle hooks, annotations, cgroup placement,
  // or a key a later Compose release adds -- must equal the managed base or
  // needs exact trust.
  const reviewedTopLevelKeys = new Set(['name', 'services', 'networks', 'volumes', 'configs', 'secrets', 'include']);
  for (const key of new Set([...Object.keys(final), ...Object.keys(base)])) {
    if (reviewedTopLevelKeys.has(key) || key.startsWith('x-')) continue;
    if (!equal(final[key], base[key])) unsafe(`Compose top-level ${key} is not a reviewed key and may expand host access`);
  }
  const reviewedServiceKeys = new Set([
    // Inspected by dedicated checks.
    'build', 'cap_add', 'cap_drop', 'cgroup', 'command', 'configs', 'credential_spec',
    'depends_on', 'deploy', 'develop', 'device_cgroup_rules', 'devices', 'entrypoint',
    'env_file', 'environment', 'extends', 'gpus', 'group_add', 'healthcheck', 'image',
    'ipc', 'label_file', 'labels', 'models', 'network_mode', 'networks', 'pid', 'ports',
    'privileged', 'provider', 'runtime', 'secrets', 'security_opt', 'tmpfs',
    'use_api_socket', 'user', 'userns_mode', 'uts', 'volumes', 'volumes_from',
    // Limited to the service's own container.
    'attach', 'blkio_config', 'container_name', 'cpu_count', 'cpu_percent', 'cpu_period',
    'cpu_quota', 'cpu_shares', 'cpus', 'cpuset', 'dns', 'dns_opt', 'dns_search',
    'domainname', 'expose', 'extra_hosts', 'hostname', 'init', 'links', 'mac_address',
    'mem_limit', 'mem_reservation', 'mem_swappiness', 'memswap_limit', 'pids_limit',
    'platform', 'profiles', 'pull_policy', 'read_only', 'restart', 'scale', 'shm_size',
    'stdin_open', 'stop_grace_period', 'stop_signal', 'tty', 'ulimits', 'working_dir',
  ]);
  const lifecycleHookKeys = ['post_start', 'pre_stop'];
  const containerLocalLogDrivers = new Set(['json-file', 'local', 'none']);
  // Compose tags a build with the service image name (or <project>-<service>).
  const normalizeImageRef = ref => {
    let value = String(ref).trim().toLowerCase().replace(/@.*$/, '');
    value = value.replace(/^docker\.io\//, '').replace(/^library\//, '');
    return /:[^/]*$/.test(value) ? value : `${value}:latest`;
  };
  const managedImageOwners = new Map();
  for (const [name, managedService] of Object.entries(baseServices)) {
    const refs = managedService.image
      ? [managedService.image]
      : [`${expectedName}-${name}`, `${expectedName}_${name}`];
    for (const ref of refs.map(normalizeImageRef)) {
      managedImageOwners.set(ref, [...(managedImageOwners.get(ref) || []), name]);
    }
  }
  const labelMap = labels => Array.isArray(labels)
    ? Object.fromEntries(labels.map(entry => {
      const text = String(entry), eq = text.indexOf('=');
      return eq === -1 ? [text, ''] : [text.slice(0, eq), text.slice(eq + 1)];
    }))
    : (isPlainObject(labels) ? labels : {});

  for (const [serviceName, service] of Object.entries(services)) {
    const baseService = baseServices[serviceName] || {};
    for (const key of new Set([...Object.keys(service), ...Object.keys(baseService)])) {
      if (reviewedServiceKeys.has(key) || lifecycleHookKeys.includes(key) || key.startsWith('x-')) continue;
      if (key === 'logging' || key === 'sysctls') continue; // dedicated checks below
      if (!equal(service[key], baseService[key])) {
        unsafe(`service ${serviceName}: ${key} is not a reviewed Compose service key and may expand host access`);
      }
    }
    // Compose runs lifecycle hooks with docker exec semantics: each hook may set
    // its own user and privileged flag, so one can run as privileged root even
    // when the service itself is unprivileged.
    for (const hook of lifecycleHookKeys) {
      if (!equal(service[hook] || [], baseService[hook] || [])) {
        const escalated = (service[hook] || []).some(entry => entry && entry.privileged === true);
        unsafe(`service ${serviceName}: ${hook} lifecycle hook runs commands${escalated ? ' with privileged: true' : ''} outside the reviewed service command`);
      }
    }
    const reservedDevices = (((service.deploy || {}).resources || {}).reservations || {}).devices || [];
    if (reservedDevices.length) unsafe(`service ${serviceName}: deploy reserves host devices (GPUs/CDI)`);
    // The Dev Containers CLI reads devcontainer.* container labels as config
    // metadata, and aic's legacy ownership checks trust the Compose labels.
    const baseLabels = labelMap(baseService.labels);
    for (const [label, value] of Object.entries(labelMap(service.labels))) {
      if (/^(devcontainer\.|com\.docker\.compose\.)/.test(label) && baseLabels[label] !== value) {
        unsafe(`service ${serviceName}: sets reserved label ${label} that Dev Containers or aic ownership checks trust`);
      }
    }
    // Every project-owned build runs a Dockerfile as root. With pull_policy:
    // missing, a build tagged like an image that another managed service (or
    // another aic project) runs silently replaces that image, so such a tag is
    // refused outright rather than offered for trust.
    if (service.build && !equal(service.build, baseService.build)) {
      if (serviceName !== 'devcontainer') unsafe(`service ${serviceName}: build executes a project-owned Dockerfile as root`);
      const builtTags = [service.image || `${expectedName}-${serviceName}`, ...((service.build || {}).tags || [])];
      for (const tag of builtTags) {
        const ref = normalizeImageRef(tag);
        const owners = (managedImageOwners.get(ref) || []).filter(owner => owner !== serviceName);
        if (owners.length || ref.startsWith('ghcr.io/stefanoginella/aicontainer:')) {
          managed(`service ${serviceName}: build would tag ${tag}, replacing an image that managed aicontainer services run; give the build its own image: tag`);
        }
      }
    }
    if (service.logging && !equal(service.logging, baseService.logging)
        && !containerLocalLogDrivers.has(service.logging.driver)) {
      unsafe(`service ${serviceName}: logging driver ${service.logging.driver || '<daemon default>'} can send container output to a host or network endpoint`);
    }
    // Docker accepts only namespaced sysctls, so on an added service they stay in
    // that container. On a managed service they need review.
    if (baseServices[serviceName] && !equal(service.sysctls || {}, baseService.sysctls || {})) {
      unsafe(`service ${serviceName}: sysctls change kernel settings of a managed service`);
    }
    if (service.privileged === true) unsafe(`service ${serviceName}: privileged: true — full host device access`);
    if (baseServices[serviceName] && !equal(service.user, baseServices[serviceName].user)) {
      unsafe(`service ${serviceName}: changes the managed runtime user to ${service.user || '<image default>'}`);
    }
    if (baseServices[serviceName] && !equal(service.group_add || [], baseServices[serviceName].group_add || [])) {
      unsafe(`service ${serviceName}: group_add may grant access to host devices or the Docker socket`);
    }
    const allowedCaps = new Set((baseServices[serviceName] || {}).cap_add || []);
    for (const cap of service.cap_add || []) {
      if (!allowedCaps.has(cap)) unsafe(`service ${serviceName}: cap_add includes ${cap}`);
    }
    if (baseServices[serviceName] && !equal(service.cap_drop || [], baseServices[serviceName].cap_drop || [])) {
      unsafe(`service ${serviceName}: cap_drop changes the managed capability boundary`);
    }
    for (const key of ['network_mode', 'pid', 'ipc', 'uts', 'userns_mode', 'cgroup']) {
      const value = String(service[key] || '').toLowerCase();
      if (value === 'host' || value.startsWith('container:') || value.startsWith('service:')) {
        unsafe(`service ${serviceName}: ${key}: ${service[key]} shares another container or host namespace`);
      }
    }
    if ((service.security_opt || []).length && !equal(service.security_opt, (baseServices[serviceName] || {}).security_opt || [])) {
      unsafe(`service ${serviceName}: security_opt changes container isolation`);
    }
    if ((service.devices || []).length || (service.device_cgroup_rules || []).length) {
      unsafe(`service ${serviceName}: maps or grants access to host devices`);
    }
    if ((service.volumes_from || []).length) unsafe(`service ${serviceName}: volumes_from can inherit protected host mounts`);
    if (service.runtime && service.runtime !== (baseServices[serviceName] || {}).runtime) unsafe(`service ${serviceName}: selects host runtime ${service.runtime}`);
    if (service.provider) unsafe(`service ${serviceName}: provider executes an external Compose provider on the host`);
    if (service.use_api_socket) unsafe(`service ${serviceName}: use_api_socket exposes the host Docker API`);
    if (service.gpus || (service.models && Object.keys(service.models).length)) unsafe(`service ${serviceName}: requests GPUs/CDI/model runner host devices`);
    if (serviceName === 'devcontainer' && baseServices.devcontainer) {
      for (const key of ['command', 'entrypoint', 'healthcheck']) {
        if (!equal(service[key], baseServices.devcontainer[key])) {
          unsafe(`service devcontainer: changes managed ${key}, which can execute or bypass setup before post-create hardening`);
        }
      }
      for (const [dependency, condition] of Object.entries(baseServices.devcontainer.depends_on || {})) {
        if (!equal((service.depends_on || {})[dependency], condition)) {
          unsafe(`service devcontainer: changes managed dependency ${dependency}, bypassing setup readiness`);
        }
      }
    }
    for (const port of service.ports || []) {
      const hostIp = String(port.host_ip || '');
      if (!['127.0.0.1', '::1'].includes(hostIp)) {
        unsafe(`service ${serviceName}: publishes port ${port.published || port.target} beyond host loopback`);
      }
    }

    for (const volume of service.volumes || []) {
      const serviceBaseline = baselineMounts.get(serviceName) || new Set();
      if (serviceBaseline.has(volumeKey(volume))) continue;
      if (baseServices[serviceName] && isProtectedManagedTarget(volume.target)) {
        unsafe(`service ${serviceName}: added mount masks protected managed path ${volume.target}`);
      } else if (serviceName === 'devcontainer' && !isApprovedDevcontainerDataTarget(volume.target)) {
        unsafe(`service devcontainer: added mount target is outside approved project data paths: ${volume.target}`);
      }
      if (volume.type === 'bind') {
        const source = realpathLoose(volume.source || '');
        if (!withinRoot(source)) {
          if (/\/(var\/)?run\/docker\.sock$/.test(source)) unsafe(`service ${serviceName}: mounts the Docker socket — full host daemon control`);
          else unsafe(`service ${serviceName}: binds a sensitive host path outside the project: ${source}`);
        } else if (!volume.read_only && (
          source === root || source === path.join(root, '.devcontainer') || source.startsWith(path.join(root, '.devcontainer') + path.sep) ||
          source === path.join(root, '.git') || source.startsWith(path.join(root, '.git') + path.sep)
        )) {
          unsafe(`service ${serviceName}: writable bind exposes protected project control paths: ${source}`);
        }
      } else if (volume.type !== 'volume') {
        unsafe(`service ${serviceName}: uses host-facing mount type ${volume.type || 'unknown'}`);
      }
      if (protectedVolumes.has(volume.source) && !serviceBaseline.has(volumeKey(volume))) {
        unsafe(`service ${serviceName}: remounts protected volume ${volume.source}`);
      }
    }

    const build = service.build;
    if (build) {
      if (build.context && !withinRoot(build.context)) unsafe(`service ${serviceName}: build context is outside the project: ${build.context}`);
      const dockerfile = build.dockerfile && path.resolve(build.context || root, build.dockerfile);
      if (dockerfile && !withinRoot(dockerfile)) unsafe(`service ${serviceName}: Dockerfile is outside the project: ${dockerfile}`);
      for (const [key, context] of Object.entries(build.additional_contexts || {})) {
        if (typeof context === 'string' && !context.includes('://') && !context.startsWith('docker-image://') && !withinRoot(context)) {
          unsafe(`service ${serviceName}: additional build context ${key} is outside the project: ${context}`);
        }
      }
      if (build.ssh || build.secrets || build.privileged || (build.entitlements || []).length || build.network === 'host') {
        unsafe(`service ${serviceName}: build forwards host access (ssh/secrets/privileged/entitlements/host network)`);
      }
    }

    const baselineTmpfs = new Set((baseServices[serviceName] || {}).tmpfs || []);
    for (const entry of service.tmpfs || []) {
      if (baselineTmpfs.has(entry)) continue;
      const target = String(entry).split(':', 1)[0];
      if (baseServices[serviceName] && isProtectedManagedTarget(target)) {
        unsafe(`service ${serviceName}: tmpfs masks protected managed path ${target}`);
      } else if (serviceName === 'devcontainer' && !isApprovedDevcontainerDataTarget(target)) {
        unsafe(`service devcontainer: tmpfs target is outside approved project data paths: ${target}`);
      }
    }
    for (const kind of ['configs', 'secrets']) {
      const baselineRefs = new Set(((baseServices[serviceName] || {})[kind] || []).map(value => JSON.stringify(stable(value))));
      for (const ref of service[kind] || []) {
        if (baselineRefs.has(JSON.stringify(stable(ref)))) continue;
        const target = typeof ref === 'string' ? '' : ref.target;
        if (baseServices[serviceName] && isProtectedManagedTarget(target)) {
          unsafe(`service ${serviceName}: ${kind} mount masks protected managed path ${target}`);
        } else if (serviceName === 'devcontainer' && !isApprovedDevcontainerDataTarget(target)) {
          unsafe(`service devcontainer: ${kind} target is outside approved project data paths: ${target || '<default>'}`);
        }
      }
    }
  }

  // The managed writable workspace mount is safe only because control-plane
  // paths are mounted over it in the devcontainer service: read-only, or (.git
  // itself) as a mount point that the agent cannot rename or replace.
  const protectedTargets = ['/workspace/.devcontainer', '/workspace/.git', '/workspace/.git/config',
    '/workspace/.git/config.worktree', '/workspace/.git/commondir', '/workspace/.git/hooks'];
  for (const target of protectedTargets) {
    const baseline = (baseServices.devcontainer.volumes || []).find(v => v.target === target);
    const current = (services.devcontainer.volumes || []).find(v => baseline && volumeKey(v) === volumeKey(baseline));
    if (!current) unsafe(`devcontainer override removes managed protection for ${target}`);
  }

  for (const [serviceName, service] of Object.entries(noenv.services || {})) {
    for (const entry of service.env_file || []) {
      const file = typeof entry === 'string' ? entry : entry && entry.path;
      if (file && !withinRoot(file)) unsafe(`service ${serviceName}: env_file reads host secrets outside the project: ${file}`);
    }
    for (const entry of service.label_file || []) {
      const file = typeof entry === 'string' ? entry : entry && entry.path;
      if (file && !withinRoot(file)) unsafe(`service ${serviceName}: label_file reads a host file outside the project: ${file}`);
    }
    if (service.credential_spec && service.credential_spec.file) {
      unsafe(`service ${serviceName}: credential_spec.file reads host credentials: ${service.credential_spec.file}`);
    }
    for (const watch of (((service.develop || {}).watch) || [])) {
      if (watch.path && !withinRoot(watch.path)) unsafe(`service ${serviceName}: develop.watch path is outside the project: ${watch.path}`);
      // Compose emits exec: {command: null} for every entry; only a command runs.
      const execCommand = watch.exec && watch.exec.command;
      if (execCommand != null && [].concat(execCommand).length) {
        unsafe(`service ${serviceName}: develop.watch exec hook runs commands that may set their own user or privileged flag`);
      }
    }
    if (service.extends) unsafe(`service ${serviceName}: extends imports additional Compose configuration`);
  }
  if (noenv.include) unsafe('Compose include imports additional configuration outside the managed file list');

  // Compose normalizes include/extends away in some versions; retain a
  // conservative source-level check so those host-read indirections cannot hide.
  for (const file of ['.devcontainer/docker-compose.yml', '.devcontainer/docker-compose.override.yml']) {
    if (!fs.existsSync(path.join(root, file))) continue;
    const source = fs.readFileSync(path.join(root, file), 'utf8');
    if (/^\s*include\s*:/m.test(source)) unsafe(`${file}: include imports additional Compose files`);
    if (/^\s*extends\s*:/m.test(source)) unsafe(`${file}: extends imports additional Compose files`);
  }

  for (const kind of ['configs', 'secrets']) {
    for (const [name, spec] of Object.entries(final[kind] || {})) {
      if (spec && spec.file && !withinRoot(spec.file)) unsafe(`${kind}.${name} reads a host file outside the project: ${spec.file}`);
      if (spec && (spec.external || spec.name || spec.environment)) {
        unsafe(`${kind}.${name} references external/custom host-managed data`);
      }
    }
  }

  const baseDev = baseServices.devcontainer || {}, finalDev = services.devcontainer || {};
  if (!finalDev.build && finalDev.image !== baseDev.image) {
    unsafe(`devcontainer image changed from the managed aicontainer image to ${finalDev.image || '<none>'}`);
  }
  if (finalDev.build && !equal(finalDev.build, baseDev.build)) {
    unsafe('devcontainer override build executes a project-owned Dockerfile as root and can replace sandbox helpers/policy');
    const context = finalDev.build.context || root;
    const managedTree = realpathLoose(path.join(root, '.devcontainer'));
    const resolvedContext = realpathLoose(context);
    if (resolvedContext !== managedTree && !resolvedContext.startsWith(managedTree + path.sep)) {
      volatile('project-owned root build context extends outside .devcontainer, so persistent trust cannot cover every build input; use --allow-unsafe per run');
    }
    const dockerfile = finalDev.build.dockerfile && path.resolve(context, finalDev.build.dockerfile);
    if (!dockerfile || !fs.existsSync(dockerfile)) {
      unsafe('devcontainer override build does not point to a reviewable Dockerfile inside the project');
    } else {
      const fromLines = fs.readFileSync(dockerfile, 'utf8').split(/\r?\n/).filter(line => /^\s*FROM\s+/i.test(line));
      const last = fromLines[fromLines.length - 1] || '';
      if (!/^\s*FROM\s+(?:--platform=\S+\s+)?(?:ghcr\.io\/stefanoginella\/aicontainer|aicontainer-base)(?::|@|\s|$)/i.test(last)) {
        unsafe('Dockerfile.project: final FROM is not the aicontainer base — sandbox hardening may be absent');
      }
    }
  }

  return findings;
}

export const formatFindings = findings =>
  findings.map(({ kind, message }) => `${kind}\t${message}\n`).join('');
