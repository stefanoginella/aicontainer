"""The credential bridge (`post-create.py auth-sync`).

It runs in the networkless aic-auth-sync service as the runtime user. See
"Credential bridge" in docs/contributing/seeds-and-auth.md.
"""

import fcntl
import hashlib
import json
import os
import secrets
import stat
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from .post_create_auth_logins import _canonical_login, _merge_npmrc

# ---------------------------------------------------------------------------
# Credential-only synchronization sidecar
# ---------------------------------------------------------------------------
# The long-running devcontainer never mounts these global tool directories.
# Only the networkless auth-sync service sees them, and only these exact
# filenames are considered. Config, memory, sessions, skills, plugins, and all
# unknown future files remain in the per-project tool home.
#
# The JSON files hold only credentials and are copied whole. gh's hosts.yml and
# npm's npmrc mix login state with settings that run code (gh pager/editor/
# browser per host; npm registry, script-shell, node-options, ...), so for
# them only the login entries that match a strict grammar cross the project
# boundary. The global copy holds nothing else, and the project copy keeps its
# own settings.
AUTH_SYNC_GLOBAL = Path("/auth-global")
AUTH_SYNC_PROJECT = Path("/project-sessions")
AUTH_SYNC_READY = Path("/run/aic-auth-sync.ready")
AUTH_SYNC_MAX_BYTES = 1024 * 1024
AUTH_SYNC_INTERVAL_SECONDS = 1.0
# gh and npm rewrite their files in place (truncate, then write). Leave a file
# alone until it has been stable this long, so a half-written file is never
# read as a logout or as a cut-off token.
AUTH_SYNC_SETTLE_NS = 2_000_000_000
AUTH_SYNC_SPECS = (
    ("Claude", "claude", "claude", ".credentials.json", "json"),
    ("Codex", "codex", "codex", "auth.json", "json"),
    ("OpenCode", "opencode", "opencode-data", "auth.json", "json"),
    ("OpenCode", "opencode", "opencode-data", "account.json", "json"),
    ("GitHub CLI", "gh", "gh", "hosts.yml", "gh-hosts"),
    ("npm", "npm", "npm", "npmrc", "npmrc"),
)
_AUTH_SYNC_WARNED: set[tuple[str, str]] = set()


def auth_sync_log(message: str) -> None:
    print(f"[auth-sync] {message}", file=sys.stderr, flush=True)


@dataclass(frozen=True)
class _CredentialState:
    kind: str  # absent | invalid | valid
    payload: bytes | None = None
    digest: str = ""
    mtime_ns: int = 0
    detail: str = ""
    # gh/npm only: the whole file as read. payload holds the canonical login
    # entries; raw is the base that keeps project settings on a project write.
    raw: bytes | None = None

    @property
    def fingerprint(self) -> tuple[str, str]:
        if self.kind == "valid":
            return (self.kind, self.digest)
        if self.kind == "invalid":
            return (self.kind, self.detail)
        return (self.kind, "")


def _auth_sync_warn(label: str, reason: str) -> None:
    key = (label, reason)
    if key not in _AUTH_SYNC_WARNED:
        _AUTH_SYNC_WARNED.add(key)
        auth_sync_log(f"ignoring unsafe/invalid {label}: {reason}")


def _open_auth_directory(path: Path) -> int:
    """Open one fixed mount directory without following an ancestor link."""
    try:
        before = path.lstat()
    except FileNotFoundError as error:
        raise OSError(f"required auth-sync directory is missing: {path}") from error
    if path.is_symlink() or not stat.S_ISDIR(before.st_mode):
        raise OSError(f"refusing non-directory auth-sync path: {path}")
    if path.resolve(strict=True) != path:
        raise OSError(f"refusing symlinked auth-sync directory: {path}")
    if before.st_uid != os.getuid():
        raise OSError(f"auth-sync directory has unexpected owner: {path}")
    if stat.S_IMODE(before.st_mode) & 0o077:
        raise OSError(f"auth-sync directory must be mode 0700: {path}")
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    opened = os.fstat(fd)
    if (
        not stat.S_ISDIR(opened.st_mode)
        or (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino)
    ):
        os.close(fd)
        raise OSError(f"auth-sync directory changed while opening: {path}")
    return fd


def _read_credential(
    directory_fd: int, name: str, label: str, fmt: str = "json"
) -> _CredentialState:
    # npm deletes an emptied npmrc, but a user may leave an empty gh/npm file.
    min_size = 1 if fmt == "json" else 0
    try:
        before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return _CredentialState("absent")
    detail = f"{before.st_ino}:{before.st_mtime_ns}:{before.st_size}"
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        _auth_sync_warn(label, "not a single-link regular file")
        return _CredentialState("invalid", mtime_ns=before.st_mtime_ns, detail=detail)
    if before.st_uid != os.getuid():
        _auth_sync_warn(label, "unexpected owner")
        return _CredentialState("invalid", mtime_ns=before.st_mtime_ns, detail=detail)
    if before.st_size < min_size or before.st_size > AUTH_SYNC_MAX_BYTES:
        _auth_sync_warn(label, f"size is outside {min_size}..{AUTH_SYNC_MAX_BYTES} bytes")
        return _CredentialState("invalid", mtime_ns=before.st_mtime_ns, detail=detail)

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(name, flags, dir_fd=directory_fd)
    except OSError as error:
        _auth_sync_warn(label, f"safe open failed ({error.errno})")
        return _CredentialState("invalid", mtime_ns=before.st_mtime_ns, detail=detail)
    try:
        opened = os.fstat(fd)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or opened.st_uid != os.getuid()
            or opened.st_size < min_size
            or opened.st_size > AUTH_SYNC_MAX_BYTES
            or (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino)
        ):
            _auth_sync_warn(label, "file changed during validation")
            return _CredentialState("invalid", mtime_ns=opened.st_mtime_ns, detail=detail)
        payload = bytearray()
        while len(payload) <= AUTH_SYNC_MAX_BYTES:
            chunk = os.read(fd, min(64 * 1024, AUTH_SYNC_MAX_BYTES + 1 - len(payload)))
            if not chunk:
                break
            payload.extend(chunk)
        after = os.fstat(fd)
        if len(payload) > AUTH_SYNC_MAX_BYTES or (
            opened.st_dev,
            opened.st_ino,
            opened.st_size,
            opened.st_mtime_ns,
        ) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
        ):
            _auth_sync_warn(label, "file changed while reading")
            return _CredentialState("invalid", mtime_ns=after.st_mtime_ns, detail=detail)
        if fmt != "json":
            raw = bytes(payload)
            login = _canonical_login(fmt, raw)
            if login is None:
                _auth_sync_warn(label, f"not readable as {name}")
                return _CredentialState("invalid", mtime_ns=after.st_mtime_ns, detail=detail)
            os.fchmod(fd, 0o600)
            if not login:
                return _CredentialState("absent", mtime_ns=after.st_mtime_ns, raw=raw)
            return _CredentialState(
                "valid",
                payload=login,
                digest=hashlib.sha256(login).hexdigest(),
                mtime_ns=after.st_mtime_ns,
                raw=raw,
            )
        try:
            parsed = json.loads(bytes(payload))
        except (UnicodeDecodeError, json.JSONDecodeError):
            _auth_sync_warn(label, "not valid UTF-8 JSON")
            return _CredentialState("invalid", mtime_ns=after.st_mtime_ns, detail=detail)
        if not isinstance(parsed, dict):
            _auth_sync_warn(label, "JSON root is not an object")
            return _CredentialState("invalid", mtime_ns=after.st_mtime_ns, detail=detail)
        os.fchmod(fd, 0o600)
        raw = bytes(payload)
        return _CredentialState(
            "valid",
            payload=raw,
            digest=hashlib.sha256(raw).hexdigest(),
            mtime_ns=after.st_mtime_ns,
        )
    finally:
        os.close(fd)


def _atomic_write_credential(directory_fd: int, name: str, payload: bytes) -> None:
    temp_name = f".aic-auth-sync.{name}.{os.getpid()}.{secrets.token_hex(6)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    temp_fd = os.open(temp_name, flags, 0o600, dir_fd=directory_fd)
    installed = False
    try:
        view = memoryview(payload)
        while view:
            written = os.write(temp_fd, view)
            view = view[written:]
        os.fchmod(temp_fd, 0o600)
        os.fsync(temp_fd)
        os.replace(temp_name, name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        installed = True
        os.fsync(directory_fd)
    finally:
        os.close(temp_fd)
        if not installed:
            try:
                os.unlink(temp_name, dir_fd=directory_fd)
            except FileNotFoundError:
                pass


def _delete_credential(directory_fd: int, name: str, label: str) -> None:
    try:
        info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
        _auth_sync_warn(label, "refusing to delete a non-regular or foreign-owned path")
        return
    os.unlink(name, dir_fd=directory_fd)
    os.fsync(directory_fd)


def _open_auth_lock(global_fd: int) -> int:
    name = ".aic-auth-sync.lock"
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(name, flags, 0o600, dir_fd=global_fd)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
        os.close(fd)
        raise OSError("refusing unsafe auth-sync lock file")
    os.fchmod(fd, 0o600)
    return fd


@dataclass(frozen=True)
class _CredentialPair:
    """One synchronized file: the global copy and this project's copy."""

    tool: str
    filename: str
    fmt: str
    global_fd: int
    local_fd: int
    local: _CredentialState  # this cycle's project copy, the npmrc merge base

    @property
    def repairs_project(self) -> bool:
        # gh and npm rewrite their files in place, and a project npmrc also
        # holds project settings: never replace a project file that is unsafe
        # or cannot be read. Only whole JSON credential files are repaired.
        return self.fmt == "json"

    def _write(self, directory_fd: int, payload: bytes, direction: str) -> None:
        _atomic_write_credential(directory_fd, self.filename, payload)
        auth_sync_log(f"{self.tool} {self.filename}: synchronized {direction}")

    def to_global(self, source: _CredentialState) -> None:
        if source.kind != "valid" or source.payload is None:
            raise OSError("internal auth-sync copy without a valid source")
        # For gh/npm the payload is the canonical login entries only.
        self._write(self.global_fd, source.payload, "project -> global")

    def to_project(self, source: _CredentialState) -> None:
        if source.kind != "valid" or source.payload is None:
            raise OSError("internal auth-sync copy without a valid source")
        payload = source.payload
        if self.fmt == "npmrc":
            payload = _merge_npmrc(self.local.raw, payload)
        self._write(self.local_fd, payload, "global -> project")

    def clear_global(self) -> None:
        _delete_credential(self.global_fd, self.filename, f"global {self.tool} {self.filename}")
        auth_sync_log(f"{self.tool} {self.filename}: synchronized project logout")

    def clear_project(self) -> None:
        remaining = _merge_npmrc(self.local.raw, b"") if self.fmt == "npmrc" else b""
        if remaining.strip():
            _atomic_write_credential(self.local_fd, self.filename, remaining)
        else:
            _delete_credential(self.local_fd, self.filename, f"project {self.tool} {self.filename}")
        auth_sync_log(f"{self.tool} {self.filename}: synchronized global logout")


def _initial_reconcile(
    global_state: _CredentialState,
    local_state: _CredentialState,
    pair: _CredentialPair,
) -> None:
    if global_state.kind == "valid" and local_state.kind == "valid":
        if global_state.digest == local_state.digest:
            return
        if local_state.mtime_ns > global_state.mtime_ns:
            pair.to_global(local_state)
        else:
            pair.to_project(global_state)
    elif global_state.kind == "valid":
        if local_state.kind == "absent" or pair.repairs_project:
            pair.to_project(global_state)
    elif local_state.kind == "valid":
        pair.to_global(local_state)


def _poll_reconcile(
    global_state: _CredentialState,
    local_state: _CredentialState,
    previous: tuple[tuple[str, str], tuple[str, str]],
    pair: _CredentialPair,
) -> None:
    previous_global, previous_local = previous
    global_changed = global_state.fingerprint != previous_global
    local_changed = local_state.fingerprint != previous_local

    # Malformed/symlinked files never propagate. Repair them from the valid
    # peer when possible; otherwise preserve the last known global state.
    if global_state.kind == "invalid" or local_state.kind == "invalid":
        if global_state.kind == "valid" and local_state.kind != "valid":
            if pair.repairs_project:
                pair.to_project(global_state)
        elif local_state.kind == "valid" and global_state.kind != "valid":
            pair.to_global(local_state)
        return

    if local_changed and not global_changed:
        if local_state.kind == "valid":
            pair.to_global(local_state)
        elif local_state.kind == "absent":
            pair.clear_global()
        return
    if global_changed and not local_changed:
        if global_state.kind == "valid":
            pair.to_project(global_state)
        elif global_state.kind == "absent":
            pair.clear_project()
        return
    if global_changed and local_changed:
        # Concurrent writes are rare (usually token refreshes). Keep a valid
        # credential rather than turning a racing logout into a surprise login
        # failure; when both are valid, the newer atomic write wins.
        if global_state.kind == "valid" and local_state.kind == "valid":
            if global_state.digest == local_state.digest:
                return
            if local_state.mtime_ns > global_state.mtime_ns:
                pair.to_global(local_state)
            else:
                pair.to_project(global_state)
        elif global_state.kind == "valid":
            pair.to_project(global_state)
        elif local_state.kind == "valid":
            pair.to_global(local_state)
        return

    # A sidecar restart loses its in-memory change history. If files somehow
    # diverge without a detected change, converge deterministically.
    if global_state.fingerprint != local_state.fingerprint:
        _initial_reconcile(global_state, local_state, pair)


def _unsettled(*states: _CredentialState) -> bool:
    """True while a file was written too recently to be read as complete."""
    now = time.time_ns()
    return any(
        state.mtime_ns and 0 <= now - state.mtime_ns < AUTH_SYNC_SETTLE_NS
        for state in states
    )


def _sync_credential_pair(
    tool: str,
    global_dir: str,
    local_dir: str,
    filename: str,
    fmt: str,
    states: dict[tuple[str, str], tuple[tuple[str, str], tuple[str, str]]],
) -> None:
    global_path = AUTH_SYNC_GLOBAL / global_dir
    local_path = AUTH_SYNC_PROJECT / "tool-homes" / local_dir
    global_fd = _open_auth_directory(global_path)
    local_fd = _open_auth_directory(local_path)
    lock_fd = -1
    try:
        lock_fd = _open_auth_lock(global_fd)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        global_label = f"global {tool} {filename}"
        local_label = f"project {tool} {filename}"
        global_state = _read_credential(global_fd, filename, global_label, fmt)
        local_state = _read_credential(local_fd, filename, local_label, fmt)
        if fmt != "json" and _unsettled(global_state, local_state):
            return  # look again next cycle, against the same previous state
        key = (global_dir, filename)
        previous = states.get(key)
        pair = _CredentialPair(tool, filename, fmt, global_fd, local_fd, local_state)
        if previous is None:
            _initial_reconcile(global_state, local_state, pair)
        else:
            _poll_reconcile(global_state, local_state, previous, pair)
        # Re-read after our atomic copy/delete so polling compares against the
        # state we actually committed, not the stale pre-reconciliation view.
        global_state = _read_credential(global_fd, filename, global_label, fmt)
        local_state = _read_credential(local_fd, filename, local_label, fmt)
        states[key] = (global_state.fingerprint, local_state.fingerprint)
    finally:
        if lock_fd >= 0:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            finally:
                os.close(lock_fd)
        os.close(local_fd)
        os.close(global_fd)


def auth_sync_main() -> int:
    """Continuously synchronize exact credential files, never tool config."""
    # This service commonly creates/mounts the project volume before the main
    # container. Make the volume root private before advertising readiness;
    # its fixed tool-home children are independently validated as 0700 below.
    project_fd = -1
    try:
        before = AUTH_SYNC_PROJECT.lstat()
        if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
            raise OSError("project sessions root is not a real directory")
        flags = (
            os.O_RDONLY
            | os.O_DIRECTORY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        project_fd = os.open(AUTH_SYNC_PROJECT, flags)
        opened = os.fstat(project_fd)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != os.getuid()
            or (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino)
        ):
            raise OSError("project sessions root changed or has an unexpected owner")
        os.fchmod(project_fd, 0o700)
    except OSError as error:
        auth_sync_log(f"refusing unsafe project sessions root ({error})")
        return 1
    finally:
        if project_fd >= 0:
            os.close(project_fd)

    states: dict[tuple[str, str], tuple[tuple[str, str], tuple[str, str]]] = {}
    failures = 0
    first_cycle = True
    while True:
        try:
            for spec in AUTH_SYNC_SPECS:
                _sync_credential_pair(*spec, states)
            AUTH_SYNC_READY.touch(mode=0o600, exist_ok=True)
            os.utime(AUTH_SYNC_READY, None)
            if first_cycle:
                auth_sync_log("initial credential reconciliation complete")
                first_cycle = False
            failures = 0
        except (OSError, RuntimeError) as error:
            failures += 1
            auth_sync_log(f"synchronization cycle failed ({type(error).__name__}: {error})")
            if failures >= 5:
                try:
                    AUTH_SYNC_READY.unlink()
                except FileNotFoundError:
                    pass
                return 1
        time.sleep(AUTH_SYNC_INTERVAL_SECONDS)
