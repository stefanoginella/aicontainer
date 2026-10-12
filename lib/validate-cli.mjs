// Entry point that aic runs: analyze_resolved_config passes 15 arguments.
// Prints the findings of lib/validate.mjs. Exits non-zero when it cannot read
// an input or the analysis throws; aic then fails validation closed, because
// an empty output would otherwise read as "no findings".

import fs from 'node:fs';
import { analyzeResolvedConfig, formatFindings, safeDiagnostic } from './validate.mjs';

const ARGS = [
  'devcontainer.json', 'template devcontainer.json',
  'base Compose JSON', 'expected Compose JSON', 'final Compose JSON',
  'no-env-resolution Compose JSON', 'raw base Compose JSON', 'raw final Compose JSON',
  'project root', 'expected Compose name', 'override flag', 'runtime user',
  'status relay', 'status project', 'status project id',
];

try {
  const argv = process.argv.slice(2);
  if (argv.length !== ARGS.length) {
    throw new Error(`expected ${ARGS.length} arguments (${ARGS.join(', ')}), got ${argv.length}`);
  }
  const [devFile, templateDevFile, baseFile, expectedFile, finalFile, noenvFile,
    rawBaseFile, rawFinalFile, rootArg, expectedName, hasOverrideRaw, runtimeUser,
    statusRelay, statusProject, statusProjectId] = argv;
  const read = file => fs.readFileSync(file, 'utf8');
  const findings = analyzeResolvedConfig({
    devcontainer: read(devFile),
    templateDevcontainer: read(templateDevFile),
    compose: {
      base: read(baseFile),
      expected: read(expectedFile),
      final: read(finalFile),
      noenv: read(noenvFile),
      rawBase: read(rawBaseFile),
      rawFinal: read(rawFinalFile),
    },
    root: fs.realpathSync.native(rootArg),
    expectedName,
    hasOverride: hasOverrideRaw === '1',
    runtimeUser,
    statusRelay,
    statusProject,
    statusProjectId,
  });
  process.stdout.write(formatFindings(findings));
} catch (error) {
  process.stderr.write(`aic: validator failed: ${safeDiagnostic(error && error.message)}\n`);
  process.exitCode = 1;
}
