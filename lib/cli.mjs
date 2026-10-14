// Entry point for the small host-side helpers that aic runs:
//
//   node lib/cli.mjs <subcommand> args...
//
// Each subcommand keeps the stdout, stderr, and exit-status contract of the
// aic function that calls it; the comments below name that function. The
// logic lives in the modules it imports, so the tests import it directly.
//
// One entry point that always runs, rather than a "run when main" check in
// each module: Node before 24 has no import.meta.main, so that check compares
// paths, and a module that silently did nothing would exit 0, which the volume
// and ownership callers read as a pass. An unknown subcommand or a wrong
// argument count exits 2. An unexpected error stays uncaught, so Node prints
// it and exits 1.
//
// lib/validate-cli.mjs stays separate: aic names it in its own MANAGED
// finding, and the validator must fail closed on its own.

import { volumeIsSafe, ownsSessionVolume, volumeUserIsOwner, containerIsOwned, isAuxiliaryContainer } from './docker-inspect.mjs';
import { composeNameConflict, createGitControlFiles } from './project-identity.mjs';
import { hashValidationInputs } from './trust-hash.mjs';
import { vscodeSettingsBlock } from './vscode-settings.mjs';

// A docker inspect check: the first argument is the inspect JSON. Exit 0 when
// the check holds, 1 when it does not, 2 when the JSON does not parse.
const inspectCheck = check => (json, ...rest) => {
  let value;
  try { value = JSON.parse(json); } catch (_) { return 2; }
  return check(value, ...rest) ? 0 : 1;
};

const COMMANDS = {
  // check_devcontainer_project_name: <expected> <managed>. Prints '' or the
  // conflicting source that composeNameConflict() returns.
  'compose-name-conflict': [2, (expected, managed) => {
    process.stdout.write(composeNameConflict(expected, process.env, managed));
    return 0;
  }],
  // ensure_git_control_paths: no output; non-zero when a file cannot be created.
  'git-control-files': [0, () => {
    createGitControlFiles();
    return 0;
  }],
  // build_vscode_settings_block: the block on stdout, one warning per
  // ignored managed key on stderr, and the status of vscodeSettingsBlock().
  'vscode-settings': [2, (file, templateFile) => {
    const { status, block, ignored } = vscodeSettingsBlock(file, templateFile);
    for (const key of ignored) {
      process.stderr.write(`aic: ignoring vscode-settings.json key managed by aic: ${key}\n`);
    }
    process.stdout.write(block);
    return status;
  }],
  // hash_validation_inputs: the hex digest, with no newline.
  'trust-hash': [1, resolved => {
    process.stdout.write(hashValidationInputs(resolved));
    return 0;
  }],
  // docker_volume_metadata_is_safe
  'volume-safe': [1, inspectCheck(volumeIsSafe)],
  // legacy_session_volume_owned_by_workspace: <json> <workspace> <project> <volume>
  'owns-session-volume': [4, inspectCheck(ownsSessionVolume)],
  'volume-user-is-owner': [4, inspectCheck(volumeUserIsOwner)],
  // stop_owned_stack_named: <json> <workspace> <project>, then <json> <project>
  'container-owned': [3, inspectCheck(containerIsOwned)],
  'auxiliary-container': [2, inspectCheck(isAuxiliaryContainer)],
};

const [subcommand, ...args] = process.argv.slice(2);
const command = Object.hasOwn(COMMANDS, subcommand ?? '') ? COMMANDS[subcommand] : null;
if (!command || args.length !== command[0]) {
  process.stderr.write(`aic: lib/cli.mjs: unknown subcommand or wrong argument count: ${String(subcommand)}\n`);
  process.exitCode = 2;
} else {
  process.exitCode = command[1](...args);
}
