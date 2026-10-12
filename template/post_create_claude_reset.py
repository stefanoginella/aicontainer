"""Resets of the Claude user rules and the Claude state file on every create.

A previous session owns these paths. See "Claude rules and state-file
resets" in docs/contributing/seeds-and-auth.md.
"""

import json
import os
import secrets
import stat
from pathlib import Path

from .post_create_common import (
    _list_directory,
    _open_directory_nofollow,
    _remove_tree_at,
    _replace_managed_file,
    log,
)

# Claude's state file ($CLAUDE_CONFIG_DIR/.claude.json) lives in the writable
# per-project tool home, so a previous session can leave keys in it that run
# code or add context when Claude next starts. reset_claude_state() removes
# them on every create and keeps everything else (onboarding, workspace trust,
# caches, counters). The host's MCP choices come back through settings.json,
# which is rewritten from the sanitized seed.
#
# Removed at the top level and in every projects.<path> entry: user/local MCP
# servers, the grants that approve a workspace .mcp.json server or turn on a
# built-in one, and MCP resources added as context. The denials
# (disabledMcpjsonServers, disabledMcpServers) stay: they can only stop a
# server, never start one.
CLAUDE_STATE_GRANT_KEYS = (
    "mcpServers",
    "enabledMcpjsonServers", "enableAllProjectMcpServers",
    "enabledMcpServers", "mcpContextUris",
)
# Removed at the top level only: Claude applies this `env` to its own process
# environment at startup (NODE_OPTIONS, BASH_ENV, PATH, ... would run code),
# and an API-key helper is a command.
CLAUDE_STATE_TOPLEVEL_CODE_KEYS = ("env", "apiKeyHelper")
CLAUDE_STATE_MAX_BYTES = 8 * 1024 * 1024
# Claude picks its state file name from its environment (".claude.json" in
# production, a suffixed name for another OAuth endpoint), so reset each one.
# A ".config.json" in the same directory would load in place of all of them;
# setup_claude() removes it.
CLAUDE_STATE_FILES = (
    ".claude.json", ".claude-staging-oauth.json",
    ".claude-local-oauth.json", ".claude-custom-oauth.json",
)
# What a new project starts with (see refresh_ai_tools()). An unusable state
# file is replaced with this, never kept or merged.
CLAUDE_STATE_SEED = {"installMethod": "native"}


CLAUDE_RULES_RESET_PREFIX = ".rules.aic-reset-"


def reset_claude_rules(claude_dir: Path) -> None:
    """Empty Claude's user rules directory (~/.claude/rules/**/*.md).

    Claude loads every rule file there into each session, like CLAUDE.md, so a
    previous session could plant instructions in it. A link at `rules` is
    removed, never followed. A real directory is renamed aside first, so
    `rules` is empty as soon as the new one exists; the old tree is then
    deleted without following any link inside it. Claude does not load the
    dot-named aside name, and a later create retries one that could not be
    deleted.
    """
    dir_fd = _open_directory_nofollow(claude_dir)
    try:
        try:
            info = os.stat("rules", dir_fd=dir_fd, follow_symlinks=False)
        except FileNotFoundError:
            info = None
        if info is not None:
            if stat.S_ISDIR(info.st_mode):
                aside = f"{CLAUDE_RULES_RESET_PREFIX}{secrets.token_hex(8)}"
                os.rename("rules", aside, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
            else:
                os.unlink("rules", dir_fd=dir_fd)
        os.mkdir("rules", 0o700, dir_fd=dir_fd)
        log(f"reset {claude_dir / 'rules'}")
        for name in _list_directory(dir_fd):
            if not name.startswith(CLAUDE_RULES_RESET_PREFIX):
                continue
            try:
                _remove_tree_at(name, dir_fd)
            except (OSError, RecursionError) as error:
                log(f"warning: could not delete old rules {claude_dir / name}: {error}; "
                    "Claude does not load it, and the next create retries")
    finally:
        os.close(dir_fd)


class _UnusableClaudeState(ValueError):
    """The Claude state file cannot be read safely or parsed as an object."""


def _read_claude_state(path: Path) -> bytes | None:
    """Read the Claude state file without following a link, or return None
    when it is missing. Anything but a single-link regular file of a bounded
    size is unusable."""
    dir_fd = _open_directory_nofollow(path.parent)
    try:
        try:
            info = os.stat(path.name, dir_fd=dir_fd, follow_symlinks=False)
        except FileNotFoundError:
            return None
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise _UnusableClaudeState("not a single-link regular file")
        flags = (
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
        )
        try:
            fd = os.open(path.name, flags, dir_fd=dir_fd)
        except OSError as error:
            raise _UnusableClaudeState(f"cannot open: {error}") from error
        try:
            opened = os.fstat(fd)
            if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1
                    or (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino)):
                raise _UnusableClaudeState("file changed while opening")
            chunks: list[bytes] = []
            size = 0
            while size <= CLAUDE_STATE_MAX_BYTES:
                chunk = os.read(fd, 1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
        finally:
            os.close(fd)
        if size > CLAUDE_STATE_MAX_BYTES:
            raise _UnusableClaudeState(f"larger than {CLAUDE_STATE_MAX_BYTES} bytes")
        return b"".join(chunks)
    finally:
        os.close(dir_fd)


def _reject_json_constant(name: str) -> None:
    raise ValueError(f"non-standard JSON constant {name}")


def _strip_claude_state(state: dict) -> list[str]:
    """Remove the keys that run code or start a server; return what went."""
    removed: list[str] = []
    for key in (*CLAUDE_STATE_GRANT_KEYS, *CLAUDE_STATE_TOPLEVEL_CODE_KEYS):
        if key in state:
            del state[key]
            removed.append(key)
    projects = state.get("projects")
    if projects is None:
        return removed
    if not isinstance(projects, dict):
        raise _UnusableClaudeState("projects is not a JSON object")
    for project_path, project in projects.items():
        if not isinstance(project, dict):
            continue
        for key in CLAUDE_STATE_GRANT_KEYS:
            if key in project:
                del project[key]
                removed.append(f"projects[{project_path!r}].{key}")
    return removed


def reset_claude_state(path: Path) -> None:
    """Remove MCP servers, MCP grants, and code-bearing keys from Claude's
    state file before Claude can start (see CLAUDE_STATE_GRANT_KEYS).

    Every other key is kept. A file that cannot be read safely (a link, a hard
    link, a directory or other special file, too large) or parsed into a JSON
    object is replaced with the new-project seed: the reset never follows it,
    never keeps it, and never fails open. Only a failed write is an error. A
    missing file is left to refresh_ai_tools(), which seeds it.
    """
    try:
        data = _read_claude_state(path)
        if data is None:
            return
        state = json.loads(data, parse_constant=_reject_json_constant)
        if not isinstance(state, dict):
            raise _UnusableClaudeState("not a JSON object")
        removed = _strip_claude_state(state)
        text = json.dumps(state, indent=2, allow_nan=False) + "\n"
    except (ValueError, RecursionError) as error:  # JSONDecodeError/UnicodeDecodeError too
        log(f"warning: replacing unusable Claude state {path} ({error}); "
            "Claude onboarding and workspace trust start fresh, login is kept")
        _replace_managed_file(path, json.dumps(CLAUDE_STATE_SEED, indent=2) + "\n")
        return
    if removed:
        _replace_managed_file(path, text)
        log(f"removed from {path}: {', '.join(removed)}")
