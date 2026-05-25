#!/usr/bin/env node
// Promote the hand-written `## [Unreleased]` section to the version being
// released. This does NOT generate content — you write the notes by hand under
// [Unreleased]; this only relabels them with the version + date, opens a fresh
// empty [Unreleased], and fixes the compare links.
//
// Runs in npm's `version` lifecycle (package.json is already bumped at that
// point), so the promoted CHANGELOG.md lands inside the tagged release commit.
// With `--check` it only validates that [Unreleased] is non-empty and exits —
// wired to `preversion` so an empty release fails before the bump, leaving the
// tree untouched. Zero dependencies on purpose. See AGENTS.md → "Releasing".

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const CHECK = process.argv.includes('--check');
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const changelogPath = join(root, 'CHANGELOG.md');
const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
const REPO = (pkg.repository?.url || '').replace(/^git\+/, '').replace(/\.git$/, '');
const version = pkg.version;

const die = (msg) => { console.error(`promote-changelog: ${msg}`); process.exit(1); };
const trimEnd = (arr) => { const a = [...arr]; while (a.length && a[a.length - 1].trim() === '') a.pop(); return a; };

const lines = readFileSync(changelogPath, 'utf8').split('\n');

// In promote mode, bail early if this version is already promoted (idempotent
// re-run). Skipped in --check, where `version` is still the pre-bump value.
if (!CHECK && lines.some((l) => l.startsWith(`## [${version}]`))) {
  console.log(`promote-changelog: CHANGELOG.md already has a [${version}] section; nothing to do.`);
  process.exit(0);
}

// Split off the trailing "[link]: url" reference block (starts at [Unreleased]:).
const linkStart = lines.findIndex((l) => /^\[Unreleased\]:\s/.test(l));
const bodyLines = linkStart === -1 ? lines : lines.slice(0, linkStart);
const linkLines = linkStart === -1 ? [] : trimEnd(lines.slice(linkStart));

const unreleasedIdx = bodyLines.findIndex((l) => /^## \[Unreleased\]/.test(l));
if (unreleasedIdx === -1) die('no "## [Unreleased]" heading found.');

// Next version heading after [Unreleased] = start of the latest released section.
let nextIdx = -1;
for (let i = unreleasedIdx + 1; i < bodyLines.length; i++) {
  if (/^## \[/.test(bodyLines[i])) { nextIdx = i; break; }
}

const content = (() => {
  const slice = bodyLines.slice(unreleasedIdx + 1, nextIdx === -1 ? bodyLines.length : nextIdx);
  const a = [...slice];
  while (a.length && a[0].trim() === '') a.shift();
  return trimEnd(a);
})();

if (content.length === 0) {
  die(`[Unreleased] is empty — add release notes under "## [Unreleased]" before releasing.`);
}
if (CHECK) {
  console.log('promote-changelog: [Unreleased] has content; OK to release.');
  process.exit(0);
}

// Previous released version, for the compare links.
const prev = nextIdx === -1 ? null : (bodyLines[nextIdx].match(/^## \[(\d+\.\d+\.\d+)\]/) || [])[1] || null;

const now = new Date();
const date = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;

const preamble = trimEnd(bodyLines.slice(0, unreleasedIdx));
const released = trimEnd(nextIdx === -1 ? [] : bodyLines.slice(nextIdx));

const out = [
  ...preamble,
  '',
  '## [Unreleased]',
  '',
  `## [${version}] - ${date}`,
  '',
  ...content,
  ...(released.length ? ['', ...released] : []),
];

// Rebuild the link block: re-point [Unreleased] at the new version and insert a
// definition for the new version above the previous ones.
const verLink = prev
  ? `[${version}]: ${REPO}/compare/v${prev}...v${version}`
  : `[${version}]: ${REPO}/releases/tag/v${version}`;
let link;
if (linkLines.length) {
  link = [...linkLines];
  const ui = link.findIndex((l) => /^\[Unreleased\]:/.test(l));
  link[ui] = `[Unreleased]: ${REPO}/compare/v${version}...HEAD`;
  link.splice(ui + 1, 0, verLink);
} else {
  link = [`[Unreleased]: ${REPO}/compare/v${version}...HEAD`, verLink];
}

writeFileSync(changelogPath, `${trimEnd(out).join('\n')}\n\n${link.join('\n')}\n`);
console.log(`promote-changelog: promoted [Unreleased] -> [${version}] - ${date}.`);
