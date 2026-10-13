// The one table of aic's commands and flags, and the shell completion
// scripts that it generates.
//
// `aic completion <shell>` runs this file:
//
//   node lib/cli-spec.mjs completion <bash|zsh|fish>
//
// and prints the script on stdout. `aic help` stays hand-written prose;
// tests/test-aic-cli-spec.mjs makes sure that the help and the `case` dispatcher
// at the end of `aic` name the same commands and flags as COMMANDS.
//
// Users run `eval "$(aic completion zsh)"` from their shell rc file, so this
// file must stay cheap: only node: built-ins, no I/O but stdout, no network.

import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

export const TOOLS = ['claude-code', 'codex', 'opencode', 'claude-code,codex,opencode'];
export const SHELLS = ['zsh', 'bash', 'fish'];
export const COMPLETION_SHELLS = ['bash', 'zsh', 'fish'];
export const SIGNING_ACTIONS = ['auto', 'byok', 'disable', 'status'];

// Flag: { long, short?, description, valueName?, values? }. A flag with
// `values` takes one argument and completes it from that list.
// Command: { name, description, flags?, positional?: { name, choices },
// aliases?, internal? }. `aliases` are extra dispatcher spellings that
// completions do not offer. An `internal` command is in the dispatcher only:
// never in the help or in a completion script.
const DOCKER_FLAGS = [
  { long: '--docker-read', description: 'enable sensitive Docker metadata/log/file reads' },
  { long: '--docker', description: 'enable Docker socket write access (POST/BUILD)' },
  { long: '--no-docker', description: 'disable Docker object APIs (default)' },
];
const TOOL_FLAGS = [
  { long: '--with', description: 'comma-separated tools', valueName: 'tools', values: TOOLS },
  { long: '--shell', description: 'interactive shell', valueName: 'shell', values: SHELLS },
];
const JSON_FLAG = { long: '--json', description: 'print one JSON object on stdout' };
const ALLOW_UNSAFE = {
  long: '--allow-unsafe', description: 'allow reviewed unsafe host access for this run only',
};

export const COMMANDS = [
  {
    name: 'init',
    description: 'Copy template into ./.devcontainer/',
    flags: [
      { long: '--build', description: 'full local build from template/Dockerfile' },
      { long: '--force', description: 'overwrite existing .devcontainer/' },
      ...DOCKER_FLAGS,
      ...TOOL_FLAGS,
    ],
  },
  {
    name: 'sync',
    description: 'Re-copy template into existing ./.devcontainer/',
    flags: [
      { long: '--pull', description: 'force pull-mode template' },
      { long: '--build', description: 'force build-mode template' },
      { long: '--bump-base', description: 'bump Dockerfile.project FROM tag to this aic version' },
      ...DOCKER_FLAGS,
      ...TOOL_FLAGS,
    ],
  },
  {
    name: 'doctor',
    description: 'Check host prerequisites and project wiring (read-only)',
    flags: [JSON_FLAG],
  },
  { name: 'status', description: 'Show project configuration and runtime state', flags: [JSON_FLAG] },
  {
    name: 'validate',
    description: 'Validate the resolved configuration non-interactively',
    flags: [JSON_FLAG],
  },
  { name: 'up', description: 'Pull/build and start the devcontainer', flags: [ALLOW_UNSAFE] },
  {
    name: 'trust',
    description: 'Approve this exact host-access configuration and project code outside the repository',
    flags: [{ long: '--revoke', description: "remove this project's stored host-access approval" }],
  },
  {
    name: 'preflight',
    description: "Print this project's trust boundary (mounts, secrets, network, sessions)",
  },
  {
    name: 'signing',
    description: 'Set up sandbox commit signing (auto/byok/disable/status)',
    flags: [{ long: '--register', description: 'register the signing key on GitHub via gh' }],
    positional: { name: 'action', choices: SIGNING_ACTIONS },
  },
  { name: 'shell', description: 'Open the configured shell inside the devcontainer' },
  { name: 'run', description: 'Run a command inside the devcontainer' },
  { name: 'rebuild', description: 'Recreate the container from a fresh image', flags: [ALLOW_UNSAFE] },
  { name: 'down', description: 'Stop the container (volumes preserved)' },
  {
    name: 'destroy',
    description: 'Stop + remove container + per-project volumes',
    flags: [{ long: '--yes', short: '-y', description: 'skip the confirmation prompt' }],
  },
  { name: 'upgrade', description: 'Update aic itself' },
  {
    name: 'completion',
    description: 'Emit shell completion script',
    positional: { name: 'shell', choices: COMPLETION_SHELLS },
  },
  {
    name: 'version', description: "Print this aic's version", flags: [JSON_FLAG], aliases: ['-v', '--version'],
  },
  { name: 'help', description: 'Show help', aliases: ['-h', '--help'] },
  { name: 'check-drift', description: 'VS Code initializeCommand hook', internal: true },
  { name: 'initialize', description: 'trusted host initialize hook', internal: true },
  { name: '__supports', description: 'initializer capability probe', internal: true },
];

export const publicCommands = (commands = COMMANDS) => commands.filter(c => !c.internal);

// Problems that would break a generated script. Descriptions go into single
// quotes (zsh, fish) and into zsh `_arguments` brackets; names and values go
// in unquoted. The tests call this.
export function checkSpec(commands = COMMANDS) {
  const problems = [];
  const names = new Set();
  const word = /^[A-Za-z0-9_][A-Za-z0-9_-]*$/;
  const text = /^[^\\[\]:"`$\n]+$/;
  for (const cmd of commands) {
    if (!word.test(cmd.name)) problems.push(`bad command name: ${cmd.name}`);
    for (const n of [cmd.name, ...(cmd.aliases || [])]) {
      if (names.has(n)) problems.push(`duplicate command name: ${n}`);
      names.add(n);
    }
    if (!text.test(cmd.description || '')) problems.push(`${cmd.name}: bad description`);
    const flags = new Set();
    for (const flag of cmd.flags || []) {
      if (!/^--[a-z][a-z-]*$/.test(flag.long)) problems.push(`${cmd.name}: bad flag ${flag.long}`);
      if (flag.short !== undefined && !/^-[a-z]$/.test(flag.short)) {
        problems.push(`${cmd.name}: bad short flag ${flag.short}`);
      }
      for (const f of [flag.long, flag.short].filter(Boolean)) {
        if (flags.has(f)) problems.push(`${cmd.name}: duplicate flag ${f}`);
        flags.add(f);
      }
      if (!text.test(flag.description || '')) problems.push(`${cmd.name} ${flag.long}: bad description`);
      if (flag.values && (!word.test(flag.valueName || '') || !flag.values.every(v => /^[A-Za-z0-9,_-]+$/.test(v)))) {
        problems.push(`${cmd.name} ${flag.long}: bad values`);
      }
    }
    if (cmd.positional && (!word.test(cmd.positional.name)
      || !cmd.positional.choices.length || !cmd.positional.choices.every(v => word.test(v)))) {
      problems.push(`${cmd.name}: bad positional`);
    }
    if (cmd.internal && (cmd.flags || cmd.positional || cmd.aliases)) {
      problems.push(`${cmd.name}: an internal command has no completion data`);
    }
  }
  return problems;
}

const zshQuote = s => `'${s.replace(/'/g, `'\\''`)}'`;
const fishQuote = s => `'${s.replace(/'/g, "\\'")}'`;
const valueFlags = commands => [...new Set(commands.flatMap(c => (c.flags || [])
  .filter(f => f.values).map(f => f.long)))];
const flagWords = cmd => (cmd.flags || []).flatMap(f => [f.long, f.short].filter(Boolean));

function bashScript(commands) {
  const pub = publicCommands(commands);
  const out = [
    '# aic bash completion. Install with:',
    `#   echo 'eval "$(aic completion bash)"' >> ~/.bashrc`,
    '_aic_complete () {',
    '  local cur prev cmd words i npos',
    '  COMPREPLY=()',
    '  cur="${COMP_WORDS[COMP_CWORD]}"',
    '  prev="${COMP_WORDS[COMP_CWORD-1]}"',
    '',
    '  if [ "$COMP_CWORD" -eq 1 ]; then',
    `    COMPREPLY=( $(compgen -W "${pub.map(c => c.name).join(' ')}" -- "$cur") )`,
    '    return',
    '  fi',
    '',
    '  # Count the arguments before the cursor that are not flags or flag values.',
    '  npos=0',
    '  for (( i = 2; i < COMP_CWORD; i++ )); do',
    '    case "${COMP_WORDS[i]}" in',
    `      ${valueFlags(pub).join('|')}) i=$((i + 1)) ;;`,
    '      -*) ;;',
    '      *) npos=$((npos + 1)) ;;',
    '    esac',
    '  done',
    '',
    '  words=""',
    '  cmd="${COMP_WORDS[1]}"',
    '  case "$cmd" in',
  ];
  for (const cmd of pub) {
    const flags = flagWords(cmd);
    const withValues = (cmd.flags || []).filter(f => f.values);
    if (!flags.length && !cmd.positional) continue;
    out.push(`    ${cmd.name})`);
    if (withValues.length) {
      out.push('      case "$prev" in');
      for (const f of withValues) {
        out.push(`        ${f.long}) COMPREPLY=( $(compgen -W "${f.values.join(' ')}" -- "$cur") ); return ;;`);
      }
      out.push('      esac');
    }
    if (flags.length) out.push(`      words="${flags.join(' ')}"`);
    if (cmd.positional) {
      const choices = cmd.positional.choices.join(' ');
      out.push('      if [ "$npos" -eq 0 ]; then');
      out.push(flags.length ? `        words="$words ${choices}"` : `        words="${choices}"`);
      out.push('      fi');
    }
    out.push('      ;;');
  }
  out.push(
    '  esac',
    '  COMPREPLY=( $(compgen -W "$words" -- "$cur") )',
    '}',
    'complete -F _aic_complete aic aicontainer',
  );
  return out.join('\n') + '\n';
}

function zshScript(commands) {
  const pub = publicCommands(commands);
  const out = [
    '#compdef aic aicontainer',
    '# aic zsh completion. Install with:',
    `#   echo 'eval "$(aic completion zsh)"' >> ~/.zshrc`,
    '# Or save this output to a file named _aic in any directory on $fpath.',
    '_aic () {',
    '  local -a commands',
    '  commands=(',
    ...pub.map(c => `    ${zshQuote(`${c.name}:${c.description}`)}`),
    '  )',
    '',
    '  _arguments -C \\',
    "    '1: :->command' \\",
    "    '*::arg:->args'",
    '',
    '  case $state in',
    '    command)',
    "      _describe -t commands 'aic command' commands",
    '      ;;',
    '    args)',
    '      case $words[1] in',
  ];
  for (const cmd of pub) {
    const specs = (cmd.flags || []).map(f => {
      const action = f.values ? `:${f.valueName}:(${f.values.join(' ')})` : '';
      const tail = zshQuote(`[${f.description}]${action}`);
      return f.short
        ? `'(${f.long} ${f.short})'{${f.long},${f.short}}${tail}`
        : zshQuote(`${f.long}[${f.description}]${action}`);
    });
    if (cmd.positional) {
      specs.push(zshQuote(`1:${cmd.positional.name}:(${cmd.positional.choices.join(' ')})`));
    }
    if (!specs.length) continue;
    out.push(`        ${cmd.name})`);
    out.push('          _arguments \\');
    specs.forEach((s, i) => out.push(`            ${s}${i < specs.length - 1 ? ' \\' : ''}`));
    out.push('          ;;');
  }
  out.push(
    '      esac',
    '      ;;',
    '  esac',
    '}',
    '',
    "# Bind the function whether this script is eval'd or autoloaded from $fpath.",
    'compdef _aic aic aicontainer 2>/dev/null',
  );
  return out.join('\n') + '\n';
}

function fishScript(commands) {
  const pub = publicCommands(commands);
  const width = Math.max(...pub.map(c => c.name.length));
  const out = [
    '# aic fish completion. Install with:',
    '#   aic completion fish > ~/.config/fish/completions/aic.fish',
    `set -l aic_cmds ${pub.map(c => c.name).join(' ')}`,
    '',
    'for cmd in aic aicontainer',
    '  complete -c $cmd -f',
    ...pub.map(c => `  complete -c $cmd -n "not __fish_seen_subcommand_from $aic_cmds" `
      + `-a ${c.name.padEnd(width)} -d ${fishQuote(c.description)}`),
  ];
  for (const cmd of pub) {
    if (!cmd.flags && !cmd.positional) continue;
    const seen = `__fish_seen_subcommand_from ${cmd.name}`;
    out.push('');
    for (const f of cmd.flags || []) {
      let line = `  complete -c $cmd -n "${seen}" -l ${f.long.slice(2)}`;
      if (f.short) line += ` -s ${f.short.slice(1)}`;
      line += ` -d ${fishQuote(f.description)}`;
      if (f.values) line += ` -xa ${fishQuote(f.values.join(' '))}`;
      out.push(line);
    }
    if (cmd.positional) {
      const choices = cmd.positional.choices.join(' ');
      out.push(`  complete -c $cmd -n "${seen}; and not __fish_seen_subcommand_from ${choices}" `
        + `-a ${fishQuote(choices)}`);
    }
  }
  out.push('end');
  return out.join('\n') + '\n';
}

const GENERATORS = { bash: bashScript, zsh: zshScript, fish: fishScript };

export function completionScript(shell, commands = COMMANDS) {
  if (!Object.hasOwn(GENERATORS, shell)) throw new Error(`unsupported shell: ${shell}`);
  return GENERATORS[shell](commands);
}

// Run as a script: `node cli-spec.mjs completion <shell>`. Node resolves the
// main module through symlinks, so compare real paths.
const isMain = (() => {
  try {
    return !!process.argv[1]
      && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
})();

if (isMain) {
  const [action, shell] = process.argv.slice(2);
  if (action !== 'completion' || !Object.hasOwn(GENERATORS, shell || '')) {
    process.stderr.write('usage: node cli-spec.mjs completion <bash|zsh|fish>\n');
    process.exitCode = 2;
  } else {
    process.stdout.write(completionScript(shell));
  }
}
