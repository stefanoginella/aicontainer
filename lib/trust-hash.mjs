// The exact-trust hash. aic trust stores it, and validate_project_security()
// (lib/aic/validation.sh) compares the stored value with a fresh one before
// Docker starts. The rules are in docs/contributing/validation.md.
//
// Do not change what goes into the hash or in which order. A different digest
// for the same project makes every stored approval stale.
//
// Only node: built-ins, no packages: this runs on the host before any trust
// decision.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

// Hash the resolved Compose model (the JSON file at `resolved`) and the full
// .devcontainer tree of the current directory: the kind, path, mode, and
// content or link target of each entry, in sorted order.
export function hashValidationInputs(resolved, env = process.env) {
  const h = crypto.createHash('sha256');
  h.update('<resolved-compose>\0');
  if (fs.existsSync(resolved)) {
    // The managed build passes TZ: ${TZ:-UTC}. A terminal often exports TZ
    // and a GUI-started editor does not, so hash the host value as a fixed
    // token; a repository literal that differs from it stays in the hash.
    const raw = fs.readFileSync(resolved, 'utf8');
    let model;
    try { model = JSON.parse(raw); } catch (_) { model = null; }
    if (model && model.services && typeof model.services === 'object') {
      const hostTz = env.TZ || 'UTC';
      let pinned = false;
      // The x-aic-build template anchor is resolved into the model too.
      const builds = [model['x-aic-build']];
      for (const service of Object.values(model.services)) builds.push(service && service.build);
      for (const build of builds) {
        const args = build && typeof build === 'object' && build.args;
        if (args && typeof args === 'object' && args.TZ === hostTz) { args.TZ = '<host-tz>'; pinned = true; }
      }
      // Unchanged models keep their raw bytes, so existing approvals stay valid.
      h.update(pinned ? JSON.stringify(model) : raw);
    } else {
      h.update(raw);
    }
  }
  h.update('\0<devcontainer-tree>\0');
  function walk(root, relative = '') {
    const full = relative ? path.join(root, relative) : root;
    const stat = fs.lstatSync(full);
    const kind = stat.isDirectory() ? 'd' : stat.isFile() ? 'f' : stat.isSymbolicLink() ? 'l' : 'o';
    h.update(`${kind}:${relative}:${stat.mode & 0o7777}\0`);
    if (kind === 'f') h.update(fs.readFileSync(full));
    else if (kind === 'l') h.update(fs.readlinkSync(full));
    h.update('\0');
    if (kind === 'd') {
      for (const name of fs.readdirSync(full).sort()) walk(root, path.join(relative, name));
    }
  }
  if (fs.existsSync('.devcontainer')) walk('.devcontainer');
  return h.digest('hex');
}
