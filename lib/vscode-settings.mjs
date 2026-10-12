// The block of project-owned VS Code settings that patch_devcontainer_json()
// injects at the "// aic:vscode-settings" marker of devcontainer.json. The
// rules are in docs/contributing/project-overrides.md.
//
// Only node: built-ins, no packages.

import fs from 'node:fs';

// Read .devcontainer/vscode-settings.json (strict JSON, not JSONC: a
// non-array object) and serialize it again, so no text from the file lands
// between the braces of devcontainer.json as written. Returns { status,
// block, ignored }:
//   status 0  block holds the leading-comma lines to inject ('' for none)
//   status 2  the file cannot be read or is not strict JSON
//   status 3  the value is not a non-array object
//   status 4  the template has no settings block before the marker
// ignored lists the keys that aic manages and that the block leaves out. A
// template that cannot be read throws.
export function vscodeSettingsBlock(file, templateFile) {
  let value;
  try {
    value = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return { status: 2, block: '', ignored: [] };
  }
  if (value === null || Array.isArray(value) || typeof value !== 'object') {
    return { status: 3, block: '', ignored: [] };
  }

  // Project settings are appended at the managed marker. Duplicate JSON
  // keys are accepted by VS Code with the last value winning, so filter all
  // top-level keys owned by aic before serialization. Derive the set from
  // the installed template to keep this rule aligned as managed settings
  // evolve.
  const template = fs.readFileSync(templateFile, 'utf8');
  const marker = template.indexOf('// aic:vscode-settings');
  const start = template.lastIndexOf('"settings": {', marker);
  if (marker < 0 || start < 0) return { status: 4, block: '', ignored: [] };
  const managedBlock = template.slice(start, marker);
  const managedKeys = new Set();
  const keyPattern = /^        ("(?:[^"\\]|\\.)+")\s*:/gm;
  let match;
  while ((match = keyPattern.exec(managedBlock)) !== null) {
    managedKeys.add(JSON.parse(match[1]));
  }
  const ignored = [];
  for (const key of Object.keys(value)) {
    if (!managedKeys.has(key)) continue;
    ignored.push(key);
    delete value[key];
  }

  // Leading comma: the block stays valid JSON however the template object
  // ends.
  const entries = Object.entries(value);
  if (!entries.length) return { status: 0, block: '', ignored };
  const lines = JSON.stringify(value, null, 2).split('\n').slice(1, -1);
  lines[0] = ',' + lines[0].trimStart();
  return { status: 0, block: lines.map(line => '        ' + line).join('\n'), ignored };
}
