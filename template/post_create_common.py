"""Shared paths, the tool selection, logging, and the safe file helpers.

The helpers open, write, and delete files in the agent-writable tool homes
without following a link. See docs/contributing/seeds-and-auth.md.
"""

import json
import os
import secrets
import stat
import sys
from pathlib import Path

HOME = Path.home()
AUTH = HOME / ".config" / "aic-auth"            # global volume
SESSIONS = HOME / ".aic-sessions"                # per-project volume
TOOL_HOMES = SESSIONS / "tool-homes"
CLAUDE_HOME = TOOL_HOMES / "claude"
CODEX_HOME = TOOL_HOMES / "codex"
# OpenCode splits config from data. Both whole directories are per-project;
# auth.json/account.json in the data dir are the only paths synchronized to the
# global auth volume by the dedicated sidecar.
OPENCODE_CONFIG_DIR = TOOL_HOMES / "opencode-config"
OPENCODE_DATA_DIR = TOOL_HOMES / "opencode-data"
# ~/.config/gh and ~/.config/npm are image-baked symlinks to these homes.
GH_HOME = TOOL_HOMES / "gh"
NPM_HOME = TOOL_HOMES / "npm"

# The unrestricted devcontainer sees only these root-owned JSON outputs from
# the one-shot Compose sanitizer. Raw host files are mounted exclusively into
# that networkless service at RAW_HOST_SEED and never enter this container.
HOST_SEED = Path("/host-seed")
RAW_HOST_SEED = Path("/raw-host-seed")
SANITIZED_HOST_SEED = Path("/sanitized-host-seed")
HOST_SEED_CLAUDE = HOST_SEED / "claude.json"
HOST_SEED_CODEX = HOST_SEED / "codex.json"
HOST_SEED_OPENCODE = HOST_SEED / "opencode.json"
HOST_SEED_GIT = HOST_SEED / "git.json"

# Per-project tool selection. Set by `aic init`/`aic sync` as
# containerEnv.AIC_TOOLS in .devcontainer/devcontainer.json. Empty/unset
# defaults to both tools (preserves behavior for projects pinned before the
# flag existed).
KNOWN_TOOLS = frozenset({"claude-code", "codex", "opencode"})
ENABLED_TOOLS = frozenset(
    t.strip() for t in os.environ.get("AIC_TOOLS", "claude-code,codex,opencode").split(",") if t.strip()
) or KNOWN_TOOLS


def log(msg: str) -> None:
    print(f"[post-create] {msg}", file=sys.stderr)


def _safe_write_text(path: Path, text: str, *, create: bool = False) -> None:
    """Write one fixed config/memory file without following links.

    Tool homes are ordinary directories in the per-project sessions volume.
    Validate the parent and existing inode before writing so a stale or hostile
    symlink cannot redirect the create-time seed outside that tool home.
    """
    parent = path.parent
    try:
        parent_info = parent.lstat()
        if not stat.S_ISDIR(parent_info.st_mode) or parent.is_symlink():
            raise OSError(f"unsafe non-directory parent: {parent}")
        if parent.resolve(strict=True) != parent:
            raise OSError(f"unsafe symlinked parent: {parent}")
    except (OSError, RuntimeError) as error:
        raise OSError(f"cannot safely resolve parent for {path}: {error}") from error

    flags = os.O_WRONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    before: os.stat_result | None
    try:
        before = path.lstat()
    except FileNotFoundError:
        before = None
    if before is None:
        if not create:
            raise OSError(f"required mounted file is missing: {path}")
        flags |= os.O_CREAT | os.O_EXCL
    elif not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise OSError(f"refusing symlink/non-regular/hard-linked file: {path}")

    fd = os.open(path, flags, 0o600)
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1:
            raise OSError(f"opened unsafe file: {path}")
        if before is not None and (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            raise OSError(f"file changed while opening: {path}")
        os.ftruncate(fd, 0)
        payload = text.encode()
        view = memoryview(payload)
        while view:
            written = os.write(fd, view)
            view = view[written:]
        os.fchmod(fd, 0o600)
    finally:
        os.close(fd)


def _open_directory_nofollow(path: Path) -> int:
    """Open an absolute directory one component at a time, never following a
    link, so a swapped ancestor cannot redirect the operation."""
    if not path.is_absolute():
        raise OSError(f"managed directory must be absolute: {path}")
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open("/", flags)
    try:
        for part in path.parts[1:]:
            child = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = child
    except OSError as error:
        os.close(fd)
        raise OSError(f"refusing symlinked or non-directory path: {path}: {error}") from error
    return fd


def _ensure_tool_home(path: Path) -> None:
    """Make one fixed tool home, and the tool-homes directory above it, real
    directories.

    Both are vscode-owned, so a previous session can swap one for a link to a
    directory with its own memory/config. Remove only the link (or other
    non-directory) entry, never what it points to, then recreate it.
    """
    for directory in (path.parent, path):
        try:
            info = directory.lstat()
        except FileNotFoundError:
            info = None
        if info is not None and not stat.S_ISDIR(info.st_mode):
            directory.unlink()
            log(f"replaced non-directory tool home {directory}")
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        # Fail here, not later, when an ancestor is still a link. A previous
        # session can also remove its own write bit to block the reset.
        fd = _open_directory_nofollow(directory)
        try:
            mode = 0o700 if directory == path else stat.S_IMODE(os.fstat(fd).st_mode) | 0o700
            os.fchmod(fd, mode)
        finally:
            os.close(fd)


def _quarantine_directory(name: str, dir_fd: int) -> None:
    """Rename a directory at a fixed managed name aside, so the name can be
    replaced. A tool does not load a dot-named quarantine directory."""
    try:
        info = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if stat.S_ISDIR(info.st_mode):
        aside = f".{name}.aic-quarantine-{secrets.token_hex(8)}"
        os.rename(name, aside, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        log(f"moved directory at managed name {name} aside to {aside}")


def _remove_managed_name(path: Path) -> None:
    """Remove a file that would load before or over a managed file. A link is
    removed, never followed; a directory is moved aside."""
    dir_fd = _open_directory_nofollow(path.parent)
    try:
        _quarantine_directory(path.name, dir_fd)
        try:
            os.unlink(path.name, dir_fd=dir_fd)
            log(f"removed unmanaged {path}")
        except FileNotFoundError:
            pass
    finally:
        os.close(dir_fd)


def _reset_managed_files(*resets) -> None:
    """Run every reset even when one fails, then raise the first error, so a
    blocked config file cannot keep the memory reset from running (or the
    other way around)."""
    first: BaseException | None = None
    for reset in resets:
        try:
            reset()
        except Exception as error:  # noqa: BLE001 - run the other resets first
            log(f"error: managed reset failed: {type(error).__name__}: {error}")
            first = first or error
    if first is not None:
        raise first


def _replace_managed_file(path: Path, text: str) -> None:
    """Replace one fixed managed config/memory file with a new inode.

    These files are regenerated on every create, so nothing at the path is
    kept: a new 0600 file is created beside it with O_EXCL and renamed over the
    entry. The rename replaces a symlink or hard-link name without writing
    through it, so a previous session cannot keep its own text this way. A
    directory at the name is moved aside first.
    """
    dir_fd = _open_directory_nofollow(path.parent)
    temp_name = f".{path.name}.aic-{secrets.token_hex(8)}"
    flags = (
        os.O_WRONLY | os.O_CREAT | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        fd = os.open(temp_name, flags, 0o600, dir_fd=dir_fd)
        try:
            try:
                view = memoryview(text.encode())
                while view:
                    written = os.write(fd, view)
                    view = view[written:]
                os.fchmod(fd, 0o600)
            finally:
                os.close(fd)
            _quarantine_directory(path.name, dir_fd)
            os.replace(temp_name, path.name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        except BaseException:
            try:
                os.unlink(temp_name, dir_fd=dir_fd)
            except OSError:
                pass
            raise
    finally:
        os.close(dir_fd)


def _list_directory(dir_fd: int) -> list[str]:
    """List an open directory through a new open file of it.

    os.listdir(fd) reads through a duplicate that shares the file position of
    dir_fd, and on overlayfs it can return nothing after the directory changed
    through dir_fd. A new open file of "." has its own position.
    """
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(".", flags, dir_fd=dir_fd)
    try:
        return os.listdir(fd)
    finally:
        os.close(fd)


def _remove_tree_at(name: str, dir_fd: int) -> None:
    """Delete one entry below an open directory without following a link.

    A link or other non-directory is unlinked, never followed, so a link inside
    the tree cannot send the delete outside it. A directory is opened with
    O_NOFOLLOW, given back its owner bits (a previous session can remove them),
    emptied the same way, and removed.
    """
    info = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    if not stat.S_ISDIR(info.st_mode):
        os.unlink(name, dir_fd=dir_fd)
        return
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(name, flags, dir_fd=dir_fd)
    except PermissionError:
        # Never follows: lchmod semantics, or no change at all.
        if os.chmod not in os.supports_follow_symlinks:
            raise
        os.chmod(name, 0o700, dir_fd=dir_fd, follow_symlinks=False)
        fd = os.open(name, flags, dir_fd=dir_fd)
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
            raise OSError(f"directory changed while opening: {name}")
        os.fchmod(fd, 0o700)
        for child in _list_directory(fd):
            _remove_tree_at(child, fd)
    finally:
        os.close(fd)
    os.rmdir(name, dir_fd=dir_fd)


def _load_sanitized_seed(path: Path) -> dict:
    """Load one root-owned JSON product from the sanitizer service."""
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        log(f"warning: sanitized seed {path.name} unavailable/invalid ({e}); using defaults")
        return {}
    return value if isinstance(value, dict) else {}
