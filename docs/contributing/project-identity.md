# Project identity and the host control boundary

Read this page before you change the Compose project name, the checkout path logic, identity or volume migration, the `.devcontainer/` control files, or the Git control paths.

This page covers the first part of the host-side rules. The pre-Docker gate is in [Host-side validation](validation.md). The generated `.env` and the status relay consent are in [Generated host state](host-state.md).

## Path-unique project name

Each generated Compose project has a path-unique name:
`aic-<sanitized-basename>-<12-char-sha256(canonical-path)>`.

- `aic` writes the name as the top-level Compose `name:`.
- The name must exactly match `expected_project_name()`.

> **Warning:** Do not accept a project name from the repository. When a top-level name is present but malformed, do not fall back to the old basename. Otherwise `down`/`destroy` can target the resources of another checkout.

## The `COMPOSE_PROJECT_NAME` lookup of Dev Containers

The Dev Containers CLI reads the top-level `name:` last. Before that, it looks in two other places:

1. `COMPOSE_PROJECT_NAME` in its own environment.
2. The first `COMPOSE_PROJECT_NAME=` line of `<workspace>/.env`. This is the repository-root `.env` that app stacks commit.

Each of these silently moves the checkout into another stack and into the `_aic-sessions` volume of that stack. Two rules close this gap:

- Every aic command that runs the CLI calls `pin_compose_project_name()` **before** validation. These commands are `up`, `rebuild`, `shell`, `run`, the mutating `signing` actions, and the firewall-status exec. Thus validation and the CLI see the same name, and the `initialize` child inherits it.
- The generated initializer cannot set the environment of its parent. So `check_devcontainer_project_name()` mirrors the lookup and normalization of the CLI. It refuses before any Docker state changes.
  - `validate` and `doctor` fail on it.
  - `preflight` and the legacy `check-drift` warn.

> **Warning:** Do not print a value that `aic` reads from the environment or from `.env`.

When `@devcontainers/cli` changes its project-name lookup, check the mirror again against the CLI source.

## Stored path spelling and `canonical_root()`

The hash input is the **stored spelling** of the path. `canonical_root()` is the only way that `aic` reads the checkout path. It runs `/bin/pwd -P`. The reasons:

- The bash builtin `pwd -P` keeps the case that the user typed.
- macOS volumes ignore case.
- Node, the Dev Containers CLI, and VS Code get the stored spelling from `getcwd()`.

The builtin gave a second hash for the same folder. As a result, three things did not agree: validation, the `devcontainer.local_folder` ownership proof, and the sessions volume.

The Node code of the validator uses `fs.realpathSync.native` for the same reason. The JS `realpathSync` keeps the typed case, and Compose spells bind sources from `$PWD`.

> **Warning:** Do not use the bash builtin `pwd -P` again. A static check fails on it.

## Migration from an earlier identity

A project that `aic` hashed from a wrong-case path still has the old name in its Compose file.

- `previous_project_names()` finds earlier names of this workspace only from containers with all of these:
  - the exact canonical workspace label,
  - the label of this project,
  - a 12-hex hash.
- Then two actions copy the sessions volume and stop the old stack:
  - `aic sync`, when the name is different from the expected name,
  - every start.
- These actions use the same ownership proof as the legacy basename migration.
- If no such container exists, `aic` preserves the old volume and does not import it.

Do not pin the name in `validate`, `initialize`, or `trust`. Without the pin, these commands still see the top-level `name:` of a repository override. A direct start would use that name.

Guarded by the root-`.env` cases and the identity cases in `tests/test-aic-host-security.sh`, and by the proj-b smoke in `smoke.yml`. The identity cases are:

- the static builtin-`pwd -P` check,
- the earlier-identity migration,
- the wrong-case start on a case-insensitive volume.

## Migration of legacy projects

Projects from before this naming scheme have no top-level name. Three actions can copy their transcript volume automatically: `aic sync`, the next `up`, or the generated `initializeCommand` of VS Code.

The copy occurs only when all of these conditions are true:

- A container has the exact canonical-workspace label and the exact legacy-project label.
- That container actually mounts the volume at the managed session root.
- No container with a different label also mounts the volume.

A label candidate with the wrong mount or a conflicting owner is not proof.

### Cleanup of a legacy project

Project-wide legacy cleanup must inspect every container that has the Compose project label of that project.

- The cleanup needs at least one exact workspace owner.
- A missing workspace label is accepted only on the fixed managed sidecars: `socket-proxy`, `aic-auth-sync`, and `aic-seed-sanitizer`.
- Different owners, unknown unlabeled services, or unreadable containers preserve the whole stack.

> **Warning:** Do not use `--remove-orphans` in the cleanup. The trusted template cannot attribute the orphans.

### A shared basename volume

Sometimes no container can tell which project owns a basename volume that projects shared in the past. Then:

- `aic sync` preserves the volume and does not copy it.
- An interactive `aic up` asks one time. If the user declines, `aic` creates a new path-unique volume and preserves the source.
- A non-interactive start or a direct VS Code start fails with an `aic up` hint.

### Volume checks for migration

The migration uses the digest-pinned BusyBox helper. Before it mounts the volumes, it validates the source and the destination volumes. Each one must be an ordinary local-driver volume with no driver options.

The same metadata check applies to every managed volume that exists before the start. A `local` volume with the same name and `type=none,o=bind` is a host bind. It is not a safe volume.

Keep these properties:

- the prompt-free migration with ownership proof,
- data preservation,
- the exact ownership proof.

## The `.devcontainer/` control boundary

The host CLI treats `.devcontainer/` as a control boundary:

- `.devcontainer`, every known control file, and the managed hooks tree must be real files or directories. They must never be symlinks or special files.
- `aic` stages each managed copy next to its destination and renames it atomically. A change from build mode to pull mode removes every old managed build artifact.
- `aic` parses `vscode-settings.json` and serializes it again as a strict JSON object. It warns on invalid input and skips it. It ignores a key that the template owns, so the managed settings win.
- `project_name()` never evaluates untrusted Compose. `down`/`destroy` parse an installed trusted template with the exact `-p` name and `--remove-orphans`. Thus providers and includes in a repository override cannot run during cleanup.
- A non-interactive `destroy` requires `--yes`.

## Git control paths

The Git control paths of the checkout are a control boundary too. Host Git runs code that these paths name:

- `.git/config`,
- `.git/config.worktree` (Git reads it as config when `extensions.worktreeConfig` is set; sparse-checkout sets it),
- `.git/hooks`.

Git loads all of them from the directory that `.git/commondir` names. So both Compose templates mount these four paths read-only over the writable workspace. They also bind `.git` onto itself.

### Rules (do not change)

1. The `.git` self-bind stops the agent from renaming `.git` and creating a new one. Nested read-only mounts alone do not stop this, because a directory that only *contains* mount points can be renamed.
2. `ensure_git_control_paths()` creates these items with O_EXCL:
   - `commondir` (with the content `.`),
   - an empty `config.worktree`,
   - a missing `hooks/`.

   It runs on `init`/`sync` and before every Compose start (`up`, `rebuild`, `initialize`). Docker turns a missing bind source into a root-owned directory, and that breaks Git.
3. `git_control_path_problems()` refuses these problems:
   - a symlink or a wrong file type at `.git` or at any of the four paths (Docker resolves bind sources on the host, so a symlink would mount a host file outside the checkout),
   - a missing `.git` or a `.git` that is not a directory,
   - a `commondir` with any other content.

   A foreign `commondir` is planted. So `aic` refuses it and never repairs it. `validate` and `doctor` report the same problems. Only a missing file that `aic` creates is not a finding.
4. The validator compares each managed project source with the symlink-free path below the canonical root. It never compares it with its own resolved value.
5. Like every bind-source check, these checks run on the host just before Docker resolves the sources. Only a container that started before this protection could use that time window. When a protected container runs, all five paths are mount points that the agent cannot replace.

### Paths that stay writable

These items stay writable by the agent by design:

- submodule Git directories (`.git/modules`),
- nested repositories,
- hook scripts in the worktree (husky, lefthook, pre-commit).

A read-only `.git/modules` would break submodule work. It also would not stop the agent from adding a new nested repository to the index. The user guide documents these residual risks for host Git (see [Threat model](../user/security.md)).

Guarded by the Git-control cases in `tests/test-aic-host-security.sh` and the "Git control paths" smoke in `smoke.yml`.
