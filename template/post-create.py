#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# ///
"""Post-create configuration for aicontainer.

Runs once per container creation. Wires up:

- bypassPermissions for Claude Code + PreToolUse hook registration
- Auto-approve / sandbox-off for Codex
- permission=allow for OpenCode + shared guardrail wired as a plugin
- A root-only sanitizer mode that turns fixed host config inputs into strict,
  JSON-only allowlisted seeds before the unrestricted devcontainer can see them
- Whole per-project tool homes under ~/.aic-sessions. A separate networkless
  sidecar syncs only the tools' exact JSON credential files, plus the login
  entries of gh's hosts.yml and npm's npmrc, with the global auth volume, so
  login persists without sharing config, prompts, or plugins.
- Ownership fix for named volumes (they come up root-owned the first time)
- Container-only git config installed into a root-owned system path

This file is only the entry point. The code is in the aic_post_create
package, which the image keeps root-owned and read-only under
/opt/aic-post-create (see _load_package()). The commands:

  /usr/bin/python3 -I /opt/post-create.py                 post-create steps
  /usr/bin/python3 -I /opt/post-create.py sanitize-seeds  seed sanitizer
  /usr/bin/python3 -I /opt/post-create.py auth-sync       credential bridge
"""

import sys

# Never write bytecode into the package directory. -I ignores
# PYTHONDONTWRITEBYTECODE, and the seed sanitizer runs as root. Set this
# before the first import of the package.
sys.dont_write_bytecode = True

import importlib  # noqa: E402
import importlib.util  # noqa: E402
import os  # noqa: E402

PACKAGE = "aic_post_create"
# Root-owned and read-only in the image (template/Dockerfile). It holds only
# the package directory, so no other module name resolves from it.
PACKAGE_PARENT = "/opt/aic-post-create"
# The PATH of a root run (the seed sanitizer). The image PATH starts with the
# vscode-owned ~/.local/bin, so a root run never searches it.
ROOT_PATH = "/usr/sbin:/usr/bin:/sbin:/bin"


def _use_system_path_as_root() -> None:
    """Give a root run a PATH with only root-owned system directories.

    Docker gives the image PATH to every process, root ones too. A
    subprocess with a bare name would otherwise run what an agent put in a
    vscode-owned directory. Runs before anything else in the entry.
    """
    if os.geteuid() == 0:
        os.environ["PATH"] = ROOT_PATH


def _load_package(parent: str = PACKAGE_PARENT):
    """Import the aic_post_create package from parent, and from nowhere else.

    -I keeps the script directory and the current directory off sys.path.
    parent goes at the end of sys.path, so a module in it can never shadow
    the standard library. find_spec() finds the package without running it,
    and the import runs only when the package resolves to parent. A package
    with the same name earlier on sys.path fails closed.
    """
    expected = os.path.join(parent, PACKAGE)
    sys.path.append(parent)
    spec = importlib.util.find_spec(PACKAGE)
    if (
        spec is None
        or spec.origin != os.path.join(expected, "__init__.py")
        or list(spec.submodule_search_locations or ()) != [expected]
    ):
        found = "nothing" if spec is None else spec.origin
        raise ImportError(f"{PACKAGE} must load from {expected}, found {found}")
    return importlib.import_module(PACKAGE)


if __name__ == "__main__":
    _use_system_path_as_root()
    try:
        _load_package()
    except ImportError as error:
        print(f"[post-create] error: {error}", file=sys.stderr)
        raise SystemExit(1) from None
    if sys.argv[1:] == ["sanitize-seeds"]:
        from aic_post_create.post_create_seeds import sanitize_seeds
        raise SystemExit(sanitize_seeds())
    if sys.argv[1:] == ["auth-sync"]:
        from aic_post_create.post_create_auth_sync import auth_sync_main
        raise SystemExit(auth_sync_main())
    if sys.argv[1:]:
        from aic_post_create.post_create_common import log
        log(f"unknown arguments: {' '.join(sys.argv[1:])}")
        raise SystemExit(2)
    from aic_post_create.post_create_main import main
    raise SystemExit(main())
