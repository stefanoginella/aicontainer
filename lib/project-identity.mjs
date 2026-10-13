// Project identity and the .git control paths, for the checks that aic runs
// before Docker starts. The rules are in docs/contributing/project-identity.md.
//
// Both functions work on paths relative to the current directory: aic runs
// lib/cli.mjs from the project root.
//
// Only node: built-ins, no packages: this runs on the host before any trust
// decision.

import fs from 'node:fs';

// Which source would replace the managed Compose name in a direct Dev
// Containers start. Mirrors the lookup and normalization of the Dev Containers
// CLI (@devcontainers/cli, Compose >= 1.21): COMPOSE_PROJECT_NAME in the
// environment, then the first COMPOSE_PROJECT_NAME= line of the
// repository-root .env. The Compose `name:` comes last, and the managed file
// interpolates it from AIC_PROJECT_NAME: Compose reads that variable from the
// environment first, then from .devcontainer/.env, which aic writes. So these
// also conflict: an AIC_PROJECT_NAME in the environment that is not exactly
// `managed`, and a set COMPOSE_ENV_FILES or COMPOSE_DISABLE_ENV_FILE, which
// replace or turn off that .env. `expected` is the name that aic resolves for
// this checkout (the legacy name of a project that is not synced yet);
// `managed` is expected_project_name(). Returns '' (no conflict),
// 'env-files', 'env-disabled', 'managed-environment', 'environment',
// 'dotenv', or 'unreadable'. It names only the source that conflicts, never a
// value read from the environment or .env.
export function composeNameConflict(expected, env = process.env, managed = expected) {
  if (env.COMPOSE_ENV_FILES !== undefined) return 'env-files';
  if (env.COMPOSE_DISABLE_ENV_FILE !== undefined) return 'env-disabled';
  if (env.AIC_PROJECT_NAME !== undefined && env.AIC_PROJECT_NAME !== managed) {
    return 'managed-environment';
  }
  const normalize = (value) => String(value).toLowerCase().replace(/[^-_a-z0-9]/g, '');
  const fromEnv = normalize(env.COMPOSE_PROJECT_NAME || '');
  if (fromEnv) {
    if (fromEnv !== expected) return 'environment';
    return '';
  }
  let text;
  try {
    const stat = fs.statSync('.env');
    if (stat.isDirectory()) return '';
    // The CLI reads any file here. Refuse what could hang it or is too
    // large to be a plausible .env, rather than guess the name it picks.
    if (!stat.isFile() || stat.size > 1048576) {
      return 'unreadable';
    }
    text = fs.readFileSync('.env').toString();
  } catch (error) {
    if (error && (error.code === 'ENOENT' || error.code === 'EISDIR')) return '';
    return 'unreadable';
  }
  const match = /^COMPOSE_PROJECT_NAME=(.+)$/m.exec(text);
  const fromFile = normalize((match && match[1].trim()) || '');
  if (fromFile && fromFile !== expected) return 'dotenv';
  return '';
}

// Create the control files that Git does not make for a main checkout, so the
// read-only mounts have a regular-file source. A main checkout never has
// commondir; "." keeps Git on this .git. The "wx" flag is O_EXCL: it never
// follows or replaces a path that already exists, including a symlink planted
// there. aic's later check reports what it found instead.
export function createGitControlFiles() {
  for (const [file, content] of [['.git/commondir', '.\n'], ['.git/config.worktree', '']]) {
    try { fs.writeFileSync(file, content, { flag: 'wx' }); }
    catch (error) { if (!error || error.code !== 'EEXIST') throw error; }
  }
}
