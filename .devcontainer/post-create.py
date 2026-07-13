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
  sidecar syncs only the tools' exact JSON credential files with the global
  auth volume, so login persists without sharing config, prompts, or plugins.
- Ownership fix for named volumes (they come up root-owned the first time)
- Container-only git config installed into a root-owned system path
"""

import fcntl
import hashlib
import json
import os
import secrets
import stat
import subprocess
import sys
import tempfile
import time
import tomllib
from dataclasses import dataclass
from pathlib import Path

HOME = Path.home()
AUTH = HOME / ".config" / "aic-auth"            # global volume
SESSIONS = HOME / ".aic-sessions"                # per-project volume
TOOL_HOMES = SESSIONS / "tool-homes"
CLAUDE_HOME = TOOL_HOMES / "claude"
CODEX_HOME = TOOL_HOMES / "codex"
OPENCODE_CONFIG_DIR = TOOL_HOMES / "opencode-config"
OPENCODE_DATA_DIR = TOOL_HOMES / "opencode-data"
CODEX_RUNTIME_HOME = HOME / ".local" / "share" / "aic-tools" / "codex"

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

# post-create writes the dynamic config as vscode to this fixed staging path;
# aic-lock-gitconfig validates and atomically installs it into the root-owned
# destination without granting a general-purpose privileged copy primitive.
GITCONFIG_STAGING = HOME / ".aic-gitconfig.staging"
GITCONFIG_MANAGED = Path("/etc/aic/user-config/gitconfig")
GITIGNORE_MANAGED = Path("/etc/aic/gitignore")

# Sandbox commit-signing material, provisioned by `aic signing` and persisted
# in the aic-auth-global volume (so the pubkey is registered on GitHub once and
# survives rebuilds). The host's own signing key is never forwarded; see
# setup_commit_signing().
SIGNING = AUTH / "signing"
SIGNING_KEY = SIGNING / "id_ed25519"             # private key (0600, vscode-owned)
SIGNING_MODE = SIGNING / "mode"                  # "auto" | "byok" | "disabled"
SIGNING_ALLOWED = SIGNING / "allowed_signers"    # for in-container verification
# OpenCode splits config from data. Both whole directories are per-project;
# auth.json/account.json in the data dir are the only paths synchronized to the
# global auth volume by the dedicated sidecar.

# Optional project-declared volume mountpoints to re-own, one path per line in
# .devcontainer/chown-paths. The prefix allowlist mirrors (advisory-only) the
# authoritative check in aic-chown-volumes; the root script re-validates, so a
# bad entry that slips past here is still refused where it matters.
PROJECT_CHOWN_FILE = Path("/workspace/.devcontainer/chown-paths")
CHOWN_ALLOWED_PREFIXES = ("/workspace/", "/home/vscode/.cache/")

# Optional project-owned post-create extension. Runs last, after all aic-managed
# setup, as the sync-safe / pull-mode-compatible place for per-project steps
# (e.g. `lefthook install`). See run_project_hook().
PROJECT_POST_CREATE = Path("/workspace/.devcontainer/post-create.project.sh")

# Per-project tool selection. Set by `aic init`/`aic sync` as
# containerEnv.AIC_TOOLS in .devcontainer/devcontainer.json. Empty/unset
# defaults to both tools (preserves behavior for projects pinned before the
# flag existed).
KNOWN_TOOLS = frozenset({"claude-code", "codex", "opencode"})
ENABLED_TOOLS = frozenset(
    t.strip() for t in os.environ.get("AIC_TOOLS", "claude-code,codex,opencode").split(",") if t.strip()
) or KNOWN_TOOLS

# Claude settings.json fields safe to copy from the host. Anything outside
# this set — permissions, hooks, apiKeyHelper, awsAuthRefresh,
# awsCredentialExpiration — is dropped because it would either defeat the
# sandbox boundary or carry host-specific auth secrets/paths.
#
# MCP fields ARE seeded (parallel to [mcp_servers.*] in Codex). MCPs that
# reference host-only binaries fail to start in the container (harmless,
# logged by Claude); URL-based and npm-installed ones work as usual. The
# user already trusts their host MCPs by virtue of having them in
# ~/.claude/settings.json — re-applying that trust inside the container
# matches how Codex handles its mcp_servers tables.
CLAUDE_ALLOWED_FIELDS = frozenset({
    "attribution",
    "enabledPlugins", "extraKnownMarketplaces",
    "mcpServers", "enabledMcpjsonServers",
    "disabledMcpjsonServers", "enableAllProjectMcpServers",
    "effortLevel", "autoMemoryEnabled",
    "skipDangerousModePermissionPrompt", "editorMode",
    "verbose", "fileCheckpointingEnabled",
    "theme", "model", "outputStyle",
    "includeCoAuthoredBy", "cleanupPeriodDays",
    "alwaysThinkingEnabled", "autoUpdates",
    "forceLoginMethod", "forceLoginOrgUUID",
    "customApiKeyResponses", "spinnerTipsEnabled",
    "shiftEnterKeyBindingInstalled",
    "messageIdleNotifThresholdMs",
})

# Codex config.toml: top-level scalars and tables to keep. We force
# approval_policy / sandbox_mode / [hooks] regardless of what the host has.
# [mcp_servers.*] is preserved even though some entries may reference host
# paths that don't exist in the container — codex logs the error and
# continues; URL-based MCP servers (openaiDeveloperDocs etc.) still work.
CODEX_ALLOWED_TOPLEVEL = frozenset({
    "model", "model_reasoning_effort", "personality",
    "model_provider", "disable_response_storage",
    "preferred_auth_method",
})
CODEX_ALLOWED_TABLES = frozenset({
    "features", "notice", "projects", "mcp_servers",
})

# OpenCode opencode.json: keys safe to seed from the host. We force `permission`
# (-> allow, the bypass/autonomous boundary) and `plugin` (-> the shared
# guardrail) regardless, and never seed `$schema` (we write our own). `provider`
# is seeded so custom providers (e.g. a DeepSeek endpoint) carry over — but any
# inline API key under it is scrubbed (see _scrub_provider_secrets): credentials
# are never forwarded; the user runs `opencode auth login` inside. MCP command
# metadata is preserved in parallel with Claude/Codex, but inline env/header
# maps are recursively stripped; non-secret environment-variable references
# can still be represented by the tool's ordinary config syntax.
OPENCODE_ALLOWED_KEYS = frozenset({
    "provider", "model", "small_model",
    "mcp", "agent", "instructions",
    "theme", "keybinds", "formatter", "lsp",
})

# Substrings (case-insensitive) marking a secret-bearing key to strip from the
# seeded `provider` subtree, so an inline apiKey/token in the host opencode.json
# (or an unforwarded "{env:...}" reference) is not written into the sandbox config.
OPENCODE_SECRET_KEY_HINTS = ("key", "token", "secret", "password")

# Exact names that conventionally carry literal credentials. Apply this across
# every allowlisted seed subtree, not just known MCP/provider locations: config
# formats evolve, and preserving an unknown inline secret is worse than making
# that one host convenience require an in-container login. Environment-variable
# *references* such as env_vars / env_http_headers / bearer_token_env_var do not
# match these exact names and remain available.
INLINE_SECRET_FIELDS = frozenset({
    "env", "environment", "headers", "http_headers",
    "apikey", "api_key", "token", "access_token", "bearer_token",
    "secret", "password", "authorization",
})

# A managed note written into each enabled tool's user-level memory file
# (~/.claude/CLAUDE.md for Claude, ~/.codex/AGENTS.md for Codex,
# ~/.config/opencode/AGENTS.md for OpenCode — all auto-loaded by their tool on
# every session), so an agent doesn't burn tokens "fixing" the
# read-only git internals. .git/config, .git/hooks, and .devcontainer/ are
# bind-mounted read-only (see docker-compose.yml); the resulting write failures
# are by-design, not bugs. These user-level instruction files are deliberately
# reset on every create; intentional project instructions belong in the repo's
# CLAUDE.md/AGENTS.md, where they remain project-owned and reviewable.
SANDBOX_MEMORY_BEGIN = "<!-- BEGIN aicontainer sandbox notes (managed) -->"
SANDBOX_MEMORY_END = "<!-- END aicontainer sandbox notes (managed) -->"
SANDBOX_MEMORY_NOTE = """\
## Sandbox: read-only git internals (don't try to "fix" this)

This is an aicontainer sandbox. By design, `.git/config`, `.git/hooks`, and
`.devcontainer/` are bind-mounted **read-only** so a tool can't rewrite its own
sandbox or git's code-execution surface.

These are **expected, not bugs** — don't investigate, retry, remount, or `sudo`
around them:

- Any write to `.git/config` fails: `could not write config file .git/config:
  Device or resource busy` (EBUSY). This includes the upstream-tracking write
  from `git push -u` / `git switch -c --track` — the push or branch itself
  **succeeds**, only the local tracking config is skipped, so don't retry it.
  Reading config and ordinary git (commit, push, pull, fetch, branch, switch) work.
- Installing git hooks (`lefthook install`, `husky`, `pre-commit install`) fails
  writing to `.git/hooks/`.

If a change to `.git/config` or `.git/hooks` is genuinely required, make it from
the host, outside the container."""

# Host git keys that are data/preferences rather than executable behavior or
# paths. Deliberately absent: include/includeIf, credential.*, url.*, alias.*,
# core.sshCommand, core.hooksPath, pagers/editors, signing-key paths, and every
# other command/path-bearing key. Signing *intent* is retained so the sandbox
# can decide whether to enable its own isolated key or disable signing cleanly.
GIT_SEED_KEYS = (
    "user.name", "user.email", "user.useConfigOnly",
    "init.defaultBranch",
    "core.autocrlf", "core.safecrlf", "core.ignoreCase", "core.precomposeUnicode",
    "pull.rebase", "pull.ff",
    "push.default", "push.autoSetupRemote", "push.followTags",
    "fetch.prune", "fetch.pruneTags",
    "rebase.autoStash", "rebase.autoSquash", "rebase.updateRefs",
    "branch.autoSetupMerge", "branch.autoSetupRebase",
    "diff.algorithm", "diff.colorMoved",
    "merge.conflictStyle",
    "commit.gpgSign", "tag.gpgSign",
)


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


def _project_chown_paths() -> list[Path]:
    """Parse .devcontainer/chown-paths (project-owned, RO-mounted) into the
    list of extra volume mountpoints to re-own. Entries outside the prefix
    allowlist are skipped here with a warning; aic-chown-volumes re-validates
    them as the authoritative (root-side) gate, so this is advisory only."""
    if not PROJECT_CHOWN_FILE.is_file():
        return []
    paths: list[Path] = []
    for raw in PROJECT_CHOWN_FILE.read_text().splitlines():
        entry = raw.split("#", 1)[0].strip()
        if not entry:
            continue
        if ".." in entry.split("/") or not entry.startswith(CHOWN_ALLOWED_PREFIXES):
            log(f"warning: ignoring out-of-allowlist chown-paths entry: {entry!r}")
            continue
        paths.append(Path(entry))
    return paths


def fix_volume_ownership() -> None:
    """Named volumes mount as root:root on first creation. Re-own them via
    the scoped /usr/local/bin/aic-chown-volumes wrapper (fixed targets + the
    project chown-paths allowlist, -h to block symlink-following) so the sudo
    grant cannot be turned into an arbitrary-path chown."""
    uid = os.getuid()
    needs_chown = False
    for path in (
        HOME / ".shell-history",
        AUTH / "signing",
        AUTH / "semgrep",
        SESSIONS,
        HOME / ".config" / "gh",
        HOME / ".config" / "npm",
    ):
        path.mkdir(parents=True, exist_ok=True)
        if path.stat().st_uid != uid:
            needs_chown = True
    # Signing and semgrep are exact subpath mounts; the broad auth-volume root
    # is deliberately not exposed at AUTH.
    # Project-declared mountpoints: don't mkdir (they're volume mounts that
    # exist iff the volume is attached); only flag a chown when one is present
    # and still root-owned — e.g. a rebuild where aic's own volumes are already
    # correct but a freshly-created project volume isn't.
    for path in _project_chown_paths():
        if path.exists() and path.stat().st_uid != uid:
            needs_chown = True
    if needs_chown:
        try:
            subprocess.run(["sudo", "/usr/local/bin/aic-chown-volumes"], check=True)
            log("re-owned persistent volumes")
        except subprocess.CalledProcessError as e:
            log(f"warning: aic-chown-volumes failed: {e}")

    # Docker creates a named volume's root with the mode inherited from the
    # first container that mounts it. The auth-sync sidecar can win that race,
    # leaving this otherwise-private root at 0755 even though its tool-home
    # children are 0700. It is owned by the runtime user after the fixed helper
    # above, so tightening it here needs no additional sudo grant.
    try:
        SESSIONS.chmod(0o700)
    except OSError as error:
        log(f"warning: could not make {SESSIONS} private: {error}")


def _load_sanitized_seed(path: Path) -> dict:
    """Load one root-owned JSON product from the sanitizer service."""
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        log(f"warning: sanitized seed {path.name} unavailable/invalid ({e}); using defaults")
        return {}
    return value if isinstance(value, dict) else {}


def load_host_claude_settings() -> dict:
    """Load the already-allowlisted Claude JSON emitted by the sanitizer."""
    return _load_sanitized_seed(HOST_SEED_CLAUDE)


def ensure_sandbox_memory(path: Path, *, create: bool = False) -> None:
    """Replace an auto-loaded user-memory file with the managed sandbox note.

    Preserving arbitrary prior text lets one compromised session plant prompts
    that execute in a later create. Users keep intentional project instructions
    in the repository's CLAUDE.md/AGENTS.md; these user-level files are managed
    security surfaces and are reset on every create.
    """
    block = f"{SANDBOX_MEMORY_BEGIN}\n{SANDBOX_MEMORY_NOTE}\n{SANDBOX_MEMORY_END}\n"
    try:
        _safe_write_text(path, block, create=create)
        log(f"reset managed sandbox note -> {path}")
    except OSError as e:
        log(f"warning: could not write sandbox note to {path}: {e}")


def setup_claude() -> None:
    """Configure Claude Code preferences. Autonomous mode and the PreToolUse
    hook are enforced separately in /etc/claude-code/managed-settings.json, at
    higher precedence than this writable, per-project user config. The
    auth-sync sidecar copies only .credentials.json between this whole home and
    the global credential store."""
    claude_dir = CLAUDE_HOME
    claude_dir.mkdir(parents=True, exist_ok=True)

    settings_file = claude_dir / "settings.json"
    settings = load_host_claude_settings()

    _safe_write_text(settings_file, json.dumps(settings, indent=2) + "\n", create=True)
    log(f"wrote {settings_file}")

    # User-level memory is project-local and reset to the managed note on every
    # create, preventing a prior autonomous session from planting instructions.
    ensure_sandbox_memory(claude_dir / "CLAUDE.md", create=True)

    # Every session/history/customization path now lives in this whole
    # per-project home; no globally writable directory controls it.
    (claude_dir / "projects").mkdir(exist_ok=True)


def load_host_codex_config() -> dict:
    """Load the already-allowlisted Codex JSON emitted by the sanitizer."""
    return _load_sanitized_seed(HOST_SEED_CODEX)


def setup_codex() -> None:
    """Configure Codex: seed allowlisted host config, then force
    approval-policy=never and sandbox=danger-full-access. The whole CODEX_HOME
    is per-project; the auth-sync sidecar shares only auth.json.

    The shared PreToolUse hook is NOT wired here: Codex command hooks are
    trust-gated, so a hook in this (non-managed) config.toml would be skipped
    until interactively trusted via `/hooks`. It's instead baked as a *managed*
    hook in /etc/codex/requirements.toml (see template/Dockerfile), which Codex
    auto-trusts and the in-container user can't disable. A host `[hooks]` table
    is already dropped by load_host_codex_config()'s allowlist."""
    codex_dir = CODEX_HOME
    codex_dir.mkdir(parents=True, exist_ok=True)

    cfg = load_host_codex_config()
    cfg["approval_policy"] = "never"
    cfg["sandbox_mode"] = "danger-full-access"

    config_toml = codex_dir / "config.toml"
    # Pinned and baked into /opt by the Dockerfile; importing lazily keeps the
    # networkless sanitizer mode stdlib-only.
    sys.path.insert(0, "/opt/aic-python")
    import tomli_w  # type: ignore[import-not-found]  # noqa: PLC0415

    _safe_write_text(config_toml, tomli_w.dumps(cfg), create=True)
    log(f"wrote {config_toml}")

    # AGENTS.md auto-loads for Codex, but is project-local and reset to the
    # managed note on every create.
    ensure_sandbox_memory(codex_dir / "AGENTS.md", create=True)

    (codex_dir / "sessions").mkdir(exist_ok=True)


def _scrub_provider_secrets(provider: dict) -> bool:
    """Recursively delete inline secret-bearing keys (apiKey/token/...) anywhere
    under the seeded `provider` table, so a host opencode.json that inlines an
    API key (or a non-forwarded "{env:VAR}" reference) does not leak it into the
    sandbox config. Returns True if anything was removed (so the caller can warn
    the user to `opencode auth login` inside)."""
    removed = False

    def walk(obj: object) -> None:
        nonlocal removed
        if isinstance(obj, dict):
            for k in list(obj):
                if isinstance(k, str) and any(h in k.lower() for h in OPENCODE_SECRET_KEY_HINTS):
                    del obj[k]
                    removed = True
                else:
                    walk(obj[k])
        elif isinstance(obj, list):
            for item in obj:
                walk(item)

    walk(provider)
    return removed


def _drop_keys_recursive(value: object, blocked: frozenset[str]) -> bool:
    """Remove fixed secret-bearing keys from a nested JSON/TOML subtree."""
    removed = False
    if isinstance(value, dict):
        for key in list(value):
            if isinstance(key, str) and key.lower() in blocked:
                del value[key]
                removed = True
            elif _drop_keys_recursive(value[key], blocked):
                removed = True
    elif isinstance(value, list):
        for item in value:
            if _drop_keys_recursive(item, blocked):
                removed = True
    return removed


def _read_json_object(path: Path, label: str) -> dict:
    if not path.is_file() or path.stat().st_size == 0:
        return {}
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        log(f"sanitizer: invalid {label} ({e}); emitting empty seed")
        return {}
    if not isinstance(value, dict):
        log(f"sanitizer: {label} is not an object; emitting empty seed")
        return {}
    return value


def _sanitize_claude_seed() -> dict:
    host = _read_json_object(RAW_HOST_SEED / "claude-settings.json", "Claude settings")
    seeded = {k: v for k, v in host.items() if k in CLAUDE_ALLOWED_FIELDS}
    dropped = sorted(k for k in host if k not in CLAUDE_ALLOWED_FIELDS)
    if dropped:
        log(f"sanitizer: dropped Claude settings fields {dropped}")
    if _drop_keys_recursive(seeded, INLINE_SECRET_FIELDS):
        log("sanitizer: dropped literal Claude config credentials")
    return seeded


def _sanitize_codex_seed() -> dict:
    src = RAW_HOST_SEED / "codex-config.toml"
    if not src.is_file() or src.stat().st_size == 0:
        return {}
    try:
        host = tomllib.loads(src.read_text())
    except (OSError, tomllib.TOMLDecodeError) as e:
        log(f"sanitizer: invalid Codex config ({e}); emitting empty seed")
        return {}

    seeded: dict = {}
    dropped: list[str] = []
    for key, value in host.items():
        try:
            json.dumps(value)
        except (TypeError, ValueError):
            dropped.append(key)
            continue
        if isinstance(value, dict):
            if key in CODEX_ALLOWED_TABLES:
                seeded[key] = value
            else:
                dropped.append(key)
        elif key in CODEX_ALLOWED_TOPLEVEL:
            seeded[key] = value
        else:
            dropped.append(key)
    if dropped:
        log(f"sanitizer: dropped Codex config entries {sorted(dropped)}")
    if _drop_keys_recursive(seeded, INLINE_SECRET_FIELDS):
        log("sanitizer: dropped literal Codex config credentials")
    return seeded


def _sanitize_opencode_seed() -> dict:
    host = _read_json_object(RAW_HOST_SEED / "opencode.json", "OpenCode config")
    seeded = {k: v for k, v in host.items() if k in OPENCODE_ALLOWED_KEYS}
    dropped = sorted(k for k in host if k not in OPENCODE_ALLOWED_KEYS and k != "$schema")
    if dropped:
        log(f"sanitizer: dropped OpenCode config keys {dropped}")
    if _drop_keys_recursive(seeded, INLINE_SECRET_FIELDS):
        log("sanitizer: dropped literal OpenCode config credentials")
    provider = seeded.get("provider")
    if isinstance(provider, dict) and _scrub_provider_secrets(provider):
        log("sanitizer: stripped inline OpenCode provider secret(s)")
    return seeded


def _sanitize_git_seed() -> dict:
    """Extract only fixed, non-executable keys from the raw host gitconfig.

    --no-includes is load-bearing: a host include can point anywhere, while the
    sanitizer receives exactly one raw input file by design.
    """
    src = RAW_HOST_SEED / "gitconfig"
    if not src.is_file() or src.stat().st_size == 0:
        return {}
    seeded: dict[str, str] = {}
    for key in GIT_SEED_KEYS:
        try:
            result = subprocess.run(
                ["/usr/bin/git", "config", "--file", str(src), "--no-includes", "--null", "--get-all", key],
                capture_output=True,
            )
        except OSError as e:
            log(f"sanitizer: git unavailable ({e}); emitting empty git seed")
            return {}
        if result.returncode == 0:
            values = [v for v in result.stdout.decode(errors="replace").split("\0") if v]
            if values:
                seeded[key.lower()] = values[-1]
    return seeded


def _write_sanitized_seed(name: str, value: dict) -> None:
    """Atomically replace one of four fixed JSON outputs without following a
    pre-existing symlink in the per-project sanitizer volume."""
    SANITIZED_HOST_SEED.mkdir(parents=True, exist_ok=True)
    os.chmod(SANITIZED_HOST_SEED, 0o700)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{name}.", dir=SANITIZED_HOST_SEED)
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(value, f, indent=2, sort_keys=True)
            f.write("\n")
        tmp.chmod(0o444)
        os.replace(tmp, SANITIZED_HOST_SEED / name)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def sanitize_seeds() -> int:
    """One-shot Compose service entry point. It alone sees raw host inputs;
    the long-running devcontainer receives only these four root-owned JSON
    products through a read-only volume."""
    if os.geteuid() != 0:
        log("sanitizer: must run as root")
        return 1
    outputs = {
        "claude.json": _sanitize_claude_seed(),
        "codex.json": _sanitize_codex_seed(),
        "opencode.json": _sanitize_opencode_seed(),
        "git.json": _sanitize_git_seed(),
    }
    for name, value in outputs.items():
        _write_sanitized_seed(name, value)
    os.chmod(SANITIZED_HOST_SEED, 0o555)
    log("sanitizer: wrote fixed allowlisted seeds")
    return 0


# ---------------------------------------------------------------------------
# Credential-only synchronization sidecar
# ---------------------------------------------------------------------------
# The long-running devcontainer never mounts these global tool directories.
# Only the networkless auth-sync service sees them, and only these exact JSON
# filenames are considered. Config, memory, sessions, skills, plugins, and all
# unknown future files remain in the per-project tool home.
AUTH_SYNC_GLOBAL = Path("/auth-global")
AUTH_SYNC_PROJECT = Path("/project-sessions")
AUTH_SYNC_READY = Path("/run/aic-auth-sync.ready")
AUTH_SYNC_MAX_BYTES = 1024 * 1024
AUTH_SYNC_INTERVAL_SECONDS = 1.0
AUTH_SYNC_SPECS = (
    ("Claude", "claude", "claude", ".credentials.json"),
    ("Codex", "codex", "codex", "auth.json"),
    ("OpenCode", "opencode", "opencode-data", "auth.json"),
    ("OpenCode", "opencode", "opencode-data", "account.json"),
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


def _read_credential(directory_fd: int, name: str, label: str) -> _CredentialState:
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
    if before.st_size <= 0 or before.st_size > AUTH_SYNC_MAX_BYTES:
        _auth_sync_warn(label, f"size is outside 1..{AUTH_SYNC_MAX_BYTES} bytes")
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
            or opened.st_size <= 0
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


def _copy_credential(
    source: _CredentialState,
    destination_fd: int,
    filename: str,
    tool: str,
    direction: str,
) -> None:
    if source.kind != "valid" or source.payload is None:
        raise OSError("internal auth-sync copy without a valid source")
    _atomic_write_credential(destination_fd, filename, source.payload)
    auth_sync_log(f"{tool} {filename}: synchronized {direction}")


def _initial_reconcile(
    global_state: _CredentialState,
    local_state: _CredentialState,
    global_fd: int,
    local_fd: int,
    filename: str,
    tool: str,
) -> None:
    if global_state.kind == "valid" and local_state.kind == "valid":
        if global_state.digest == local_state.digest:
            return
        if local_state.mtime_ns > global_state.mtime_ns:
            _copy_credential(local_state, global_fd, filename, tool, "project -> global")
        else:
            _copy_credential(global_state, local_fd, filename, tool, "global -> project")
    elif global_state.kind == "valid":
        _copy_credential(global_state, local_fd, filename, tool, "global -> project")
    elif local_state.kind == "valid":
        _copy_credential(local_state, global_fd, filename, tool, "project -> global")


def _poll_reconcile(
    global_state: _CredentialState,
    local_state: _CredentialState,
    previous: tuple[tuple[str, str], tuple[str, str]],
    global_fd: int,
    local_fd: int,
    filename: str,
    tool: str,
) -> None:
    previous_global, previous_local = previous
    global_changed = global_state.fingerprint != previous_global
    local_changed = local_state.fingerprint != previous_local

    # Malformed/symlinked files never propagate. Repair them from the valid
    # peer when possible; otherwise preserve the last known global state.
    if global_state.kind == "invalid" or local_state.kind == "invalid":
        if global_state.kind == "valid" and local_state.kind != "valid":
            _copy_credential(global_state, local_fd, filename, tool, "global -> project")
        elif local_state.kind == "valid" and global_state.kind != "valid":
            _copy_credential(local_state, global_fd, filename, tool, "project -> global")
        return

    if local_changed and not global_changed:
        if local_state.kind == "valid":
            _copy_credential(local_state, global_fd, filename, tool, "project -> global")
        elif local_state.kind == "absent":
            _delete_credential(global_fd, filename, f"global {tool} {filename}")
            auth_sync_log(f"{tool} {filename}: synchronized project logout")
        return
    if global_changed and not local_changed:
        if global_state.kind == "valid":
            _copy_credential(global_state, local_fd, filename, tool, "global -> project")
        elif global_state.kind == "absent":
            _delete_credential(local_fd, filename, f"project {tool} {filename}")
            auth_sync_log(f"{tool} {filename}: synchronized global logout")
        return
    if global_changed and local_changed:
        # Concurrent writes are rare (usually token refreshes). Keep a valid
        # credential rather than turning a racing logout into a surprise login
        # failure; when both are valid, the newer atomic write wins.
        if global_state.kind == "valid" and local_state.kind == "valid":
            if global_state.digest == local_state.digest:
                return
            if local_state.mtime_ns > global_state.mtime_ns:
                _copy_credential(local_state, global_fd, filename, tool, "project -> global")
            else:
                _copy_credential(global_state, local_fd, filename, tool, "global -> project")
        elif global_state.kind == "valid":
            _copy_credential(global_state, local_fd, filename, tool, "global -> project")
        elif local_state.kind == "valid":
            _copy_credential(local_state, global_fd, filename, tool, "project -> global")
        return

    # A sidecar restart loses its in-memory change history. If files somehow
    # diverge without a detected change, converge deterministically.
    if global_state.fingerprint != local_state.fingerprint:
        _initial_reconcile(global_state, local_state, global_fd, local_fd, filename, tool)


def _sync_credential_pair(
    tool: str,
    global_dir: str,
    local_dir: str,
    filename: str,
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
        global_state = _read_credential(global_fd, filename, global_label)
        local_state = _read_credential(local_fd, filename, local_label)
        key = (global_dir, filename)
        previous = states.get(key)
        if previous is None:
            _initial_reconcile(global_state, local_state, global_fd, local_fd, filename, tool)
        else:
            _poll_reconcile(
                global_state,
                local_state,
                previous,
                global_fd,
                local_fd,
                filename,
                tool,
            )
        # Re-read after our atomic copy/delete so polling compares against the
        # state we actually committed, not the stale pre-reconciliation view.
        global_state = _read_credential(global_fd, filename, global_label)
        local_state = _read_credential(local_fd, filename, local_label)
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


def load_host_opencode_config() -> dict:
    """Load the already-allowlisted OpenCode JSON emitted by the sanitizer."""
    return _load_sanitized_seed(HOST_SEED_OPENCODE)


def setup_opencode() -> None:
    """Configure OpenCode preferences. permission=allow and the shared
    guardrail plugin are enforced separately by /etc/opencode/opencode.json,
    OpenCode's highest-precedence root-managed configuration.

    Both OpenCode homes are per-project. The auth-sync sidecar copies only
    auth.json/account.json between the data home and the global credential
    store; config, plugins, databases, storage, and snapshots never cross the
    project boundary."""
    cfg = load_host_opencode_config()
    # Force the sandbox boundary regardless of what the host had.
    cfg["$schema"] = "https://opencode.ai/config.json"
    cfg["permission"] = {"*": "allow"}
    cfg["plugin"] = ["/etc/aic/hooks/opencode-guardrail.js"]

    OPENCODE_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    config_json = OPENCODE_CONFIG_DIR / "opencode.json"
    _safe_write_text(config_json, json.dumps(cfg, indent=2) + "\n", create=True)
    log(f"wrote {config_json}")

    # OpenCode AGENTS.md auto-loads every session (it takes precedence over
    # ~/.claude/CLAUDE.md) and is reset on every create.
    ensure_sandbox_memory(OPENCODE_CONFIG_DIR / "AGENTS.md", create=True)

    # sqlite creates the DB file but not its parent. Everything below this
    # directory is an ordinary per-project path, so OpenCode's atomic updates
    # retain their normal semantics.
    OPENCODE_DATA_DIR.mkdir(parents=True, exist_ok=True)
    (OPENCODE_DATA_DIR / "storage").mkdir(exist_ok=True)
    (OPENCODE_DATA_DIR / "snapshot").mkdir(exist_ok=True)


def _host_git_config(key: str) -> str:
    """Read one value from the fixed-key JSON git seed."""
    value = _load_sanitized_seed(HOST_SEED_GIT).get(key.lower(), "")
    return value if isinstance(value, str) else ""


def setup_commit_signing() -> str:
    """Return the container-local commit-signing config to append to
    the managed gitconfig after sanitized host preferences (so it overrides the
    host's signing intent inside the sandbox only).

    Why this exists: the host's signing key never enters the container (~/.ssh
    and the SSH agent are deliberately not forwarded), so a host configured for
    SSH/GPG commit signing would otherwise fail every `git commit` here with
    "Couldn't find key in agent". Instead `aic signing` provisions a
    sandbox-only ed25519 signing key in the aic-auth-global volume; this wires
    it up when present. Mode (set by `aic signing`, persisted in the volume):

      - key present (auto/byok) -> sign with it via gpg.format=ssh, regardless
        of whether the host signed with SSH or GPG (the switch is container-only).
      - mode 'disabled'         -> signing off in the sandbox (quiet).
      - host signs, but no key  -> signing off + LOUD notice (the safe default,
        so commits don't fail cryptically before a key is set up).
      - host doesn't sign       -> nothing.

    Takes effect on container (re)create only: the config is installed fresh
    into a root-owned directory, so a mode change via `aic signing` lands on the
    next rebuild without a privileged unlock primitive."""
    off = "[commit]\n    gpgsign = false\n[tag]\n    gpgsign = false\n"
    mode = SIGNING_MODE.read_text().strip() if SIGNING_MODE.is_file() else ""

    if mode == "disabled":
        log("commit signing: disabled in sandbox (your choice via 'aic signing')")
        return off

    if SIGNING_KEY.is_file():
        # ssh-keygen refuses keys with loose perms; we own the file (it's
        # created as vscode by `aic signing`), so tighten it each create.
        try:
            SIGNING_KEY.chmod(0o600)
        except OSError as e:
            log(f"warning: could not chmod signing key: {e}")
        block = (
            "[gpg]\n    format = ssh\n"
            f"[user]\n    signingkey = {SIGNING_KEY}\n"
            "[commit]\n    gpgsign = true\n"
        )
        # Also wire verification so in-container `git log --show-signature`
        # works instead of erroring on the host's allowedSignersFile (a
        # host-only path). Best-effort; signing itself doesn't need it.
        email = _host_git_config("user.email")
        pub = SIGNING_KEY.with_suffix(".pub")
        if email and pub.is_file():
            try:
                SIGNING_ALLOWED.write_text(f"{email} {pub.read_text().strip()}\n")
                block += f'[gpg "ssh"]\n    allowedSignersFile = {SIGNING_ALLOWED}\n'
            except OSError as e:
                log(f"warning: could not write allowed_signers: {e}")
        fp = ""
        try:
            r = subprocess.run(["ssh-keygen", "-lf", str(pub)], capture_output=True, text=True)
            if r.returncode == 0:
                fp = r.stdout.split()[1]
        except (FileNotFoundError, IndexError):
            pass
        log(f"commit signing: sandbox ssh key{(' ' + fp) if fp else ''} (mode={mode or 'auto'})")
        return block

    if _host_git_config("commit.gpgsign").lower() == "true":
        log("commit signing: host enables it but no sandbox key — commits are "
            "UNSIGNED here. Run 'aic signing' to provision a sandbox signing key "
            "(or 'aic signing disable' to silence this).")
        return off

    return ""


def setup_gitconfig() -> None:
    """Stage the dynamic global git config for privileged fixed-target install.

    The sanitizer emitted only fixed non-executable host keys. Git itself writes
    those values into the staging file so arbitrary names/emails are escaped
    correctly; aic's own settings and signing override are appended last.
    """
    if GITCONFIG_MANAGED.is_file():
        # Re-running post-create in the same container must not replace the
        # already-installed security config. A rebuild starts from a fresh image.
        return

    if GITCONFIG_STAGING.is_symlink() or GITCONFIG_STAGING.exists():
        if GITCONFIG_STAGING.is_dir():
            log(f"warning: refusing non-file gitconfig staging path {GITCONFIG_STAGING}")
            return
        GITCONFIG_STAGING.unlink()
    GITCONFIG_STAGING.touch(mode=0o600)

    seeded = _load_sanitized_seed(HOST_SEED_GIT)
    for key in GIT_SEED_KEYS:
        value = seeded.get(key.lower())
        if not isinstance(value, str):
            continue
        try:
            subprocess.run(
                ["git", "config", "--file", str(GITCONFIG_STAGING), key, value],
                check=True,
                capture_output=True,
                text=True,
            )
        except (OSError, subprocess.CalledProcessError) as e:
            log(f"warning: could not seed git preference {key}: {e}")

    # Container settings and signing go last so they override seeded values.
    signing = setup_commit_signing()
    with GITCONFIG_STAGING.open("a") as local:
        local.write(
            f"\n# aicontainer container-local git config\n"
            f"[core]\n"
            f"    excludesfile = {GITIGNORE_MANAGED}\n"
            f"    pager = delta\n"
            f"[interactive]\n    diffFilter = delta --color-only\n"
            f"[delta]\n    navigate = true\n    line-numbers = true\n"
            f"[merge]\n    conflictstyle = diff3\n"
            f"[diff]\n    colorMoved = default\n"
            f"{signing}"
        )
    # The staging config contains only the sanitizer's non-secret fixed-key
    # preferences plus aic-owned constants. Root intentionally lacks broad
    # DAC_OVERRIDE in the long-running container, so make this one file
    # readable by the fixed sudo helper while its ownership/inode/link checks
    # still prevent path substitution.
    GITCONFIG_STAGING.chmod(0o644)
    log(f"staged {GITCONFIG_STAGING} for root-owned install")


def block_metadata() -> None:
    """Drop egress to cloud metadata / link-local (169.254.0.0/16) on every
    container create, via the scoped /usr/local/bin/aic-firewall block-metadata
    wrapper. This is independent of the opt-in outbound allowlist: it closes the
    highest-severity network path (cloud credential theft via 169.254.169.254 on
    a cloud host) as an always-on baseline, even when the full firewall is never
    enabled. Strengthen-only (adds a DROP, never opens anything) and fail-soft —
    a runtime without NET_ADMIN just logs a warning and continues, matching the
    rest of post-create's defensive degradation. When the full firewall is later
    enabled its default-DROP policy covers the same range, so the two compose."""
    try:
        subprocess.run(
            ["sudo", "/usr/local/bin/aic-firewall", "block-metadata"],
            check=True, capture_output=True, text=True,
        )
        log("blocked cloud metadata / link-local egress (169.254.0.0/16)")
    except (subprocess.CalledProcessError, OSError) as e:
        log(f"warning: metadata egress block skipped ({e}); continuing")


def lock_config() -> None:
    """Install the fixed staging file at the hardcoded root-owned gitconfig
    target through the narrow aic-lock-gitconfig helper. The helper deliberately
    lacks DAC_OVERRIDE, so the unprivileged owner removes its own staging file
    only after the atomic install succeeds."""
    try:
        subprocess.run(["sudo", "/usr/local/bin/aic-lock-gitconfig"], check=True)
        GITCONFIG_STAGING.unlink()
        log(f"installed root-owned git config at {GITCONFIG_MANAGED}")
    except (OSError, subprocess.CalledProcessError) as e:
        log(f"warning: aic-lock-gitconfig failed: {e}")


def verify_git_identity() -> None:
    """Loudly flag a missing commit identity at create time, so it surfaces here
    instead of cryptically mid-session on the first `git commit` ("Author
    identity unknown").

    The sandbox has NO identity of its own: the root-only sanitizer copies only
    user.name/user.email from the host seed. A missing identity can't be fixed
    from inside: `git config --global` writes to the root-managed config, and
    `git config --local` writes to /workspace/.git/config, which is mounted
    read-only. The only fix is on the host, so that's where we point. Non-fatal —
    matches the rest of post-create's defensive degradation."""
    def configured(key: str) -> bool:
        # cwd=HOME (not a repo) reads system + managed-global only, with no repo-local config or
        # dubious-ownership checks to muddy the result.
        try:
            r = subprocess.run(
                ["git", "config", "--get", key],
                capture_output=True, text=True, cwd=str(HOME),
            )
        except FileNotFoundError:
            return True  # no git to check with — don't cry wolf
        return r.returncode == 0 and bool(r.stdout.strip())

    if configured("user.name") and configured("user.email"):
        return
    log("git identity: no user.name/user.email is configured — commits here will "
        "fail with 'Author identity unknown' (unless the repo sets its own). The "
        "sandbox inherits its identity "
        "from the sanitized host ~/.gitconfig seed, which was empty/unset "
        "when this container was built. Fix it on the HOST, then 'aic rebuild' — "
        f"it can't be fixed from inside ({GITCONFIG_MANAGED} is root-managed and "
        "/workspace/.git/config is read-only): "
        "git config --global user.name '<you>' && "
        "git config --global user.email '<you@example.com>'.")


def verify_socket_proxy() -> None:
    """Best-effort ping of the socket-proxy so we fail loudly if compose
    didn't bring it up. Non-fatal — devcontainer is still usable without
    Docker access."""
    try:
        result = subprocess.run(
            ["curl", "-fsS", "--max-time", "3", "http://socket-proxy:2375/_ping"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and result.stdout.strip() == "OK":
            log("socket-proxy reachable")
        else:
            log(f"warning: socket-proxy ping failed ({result.stderr.strip()})")
    except FileNotFoundError:
        log("warning: curl not available; skipping socket-proxy check")


def run_project_hook() -> None:
    """Run the project-owned post-create extension, if present.

    This is the sync-safe, pull-mode-compatible way for a project to add its
    own setup steps (`lefthook install`, `pre-commit install`, `npm ci`, ...)
    without editing the aic-managed devcontainer.json (clobbered every sync)
    or post-create.py (baked into the image and absent from the repo in pull
    mode). Opt-in by presence, mirroring chown-paths / firewall-allowlist /
    Dockerfile.project.

    Runs as `vscode` with cwd /workspace and inherited env — no privilege the
    in-container agent doesn't already have. The file lives under
    .devcontainer/, which the PreToolUse hook blocks the in-container agent
    from writing, so it stays host-only-editable. Invoked via `bash <file>`
    so the executable bit isn't required. A non-zero exit is logged but does
    not fail container creation, matching the rest of post-create's defensive
    degradation; output streams through so the user sees it during `aic up`."""
    if not PROJECT_POST_CREATE.is_file():
        return
    log(f"running project hook {PROJECT_POST_CREATE}")
    # postCreateCommand now uses the baked system Python directly, so it does
    # not create an ephemeral environment. Still strip any inherited
    # VIRTUAL_ENV defensively: a project hook running `uv sync`/`uv run` should
    # resolve the project's own .venv rather than an outer launcher environment.
    env = os.environ.copy()
    stale_venv = env.pop("VIRTUAL_ENV", None)
    if stale_venv:
        stale_bin = f"{stale_venv}/bin"
        env["PATH"] = os.pathsep.join(
            p for p in env.get("PATH", "").split(os.pathsep) if p != stale_bin
        )
    try:
        subprocess.run(["bash", str(PROJECT_POST_CREATE)], cwd="/workspace", env=env, check=True)
        log("project hook finished")
    except subprocess.CalledProcessError as e:
        log(f"warning: project hook exited {e.returncode}; continuing")


def refresh_ai_tools() -> None:
    """Float Claude Code, Codex and OpenCode to their latest release on every
    container (re)create. The image bakes a working copy of each (Dockerfile) as
    an offline floor; this updates them in place when there is network.
    Fail-soft: an offline or failed update is logged and the baked version is
    kept rather than blocking the container from coming up. Gated on AIC_TOOLS;
    set AIC_FREEZE_TOOLS=1 (e.g. in docker-compose.override.yml) to pin the baked
    versions for a reproducible sandbox.

    Claude/Codex live in ~/.local/bin and OpenCode in ~/.opencode/bin, both of
    which we force onto PATH for the updaters. Codex's standalone package lives
    in a separate rootfs directory, not the per-project CODEX_HOME; supplying
    CODEX_HOME/CODEX_INSTALL_DIR only to its updater preserves that split.
    (`opencode upgrade` replaces the binary in place and was installed with
    --no-modify-path.)"""
    freeze = os.environ.get("AIC_FREEZE_TOOLS", "").strip().lower()
    if freeze not in ("", "0", "false", "no"):
        log("AIC_FREEZE_TOOLS set — keeping the baked Claude/Codex versions")
        return
    env = {**os.environ, "PATH": f"{HOME / '.local' / 'bin'}:{HOME / '.opencode' / 'bin'}:{os.environ.get('PATH', '')}"}
    updaters: list[tuple[str, list[str], int, dict[str, str]]] = []
    if "claude-code" in ENABLED_TOOLS:
        # Claude's native updater records its install method in this ordinary
        # per-project state file. Seed only a missing file so a brand-new
        # project does not emit a migration warning before self-healing; never
        # replace or merge an existing user's state.
        claude_state = CLAUDE_HOME / ".claude.json"
        if not claude_state.exists():
            try:
                _safe_write_text(
                    claude_state,
                    json.dumps({"installMethod": "native"}, indent=2) + "\n",
                    create=True,
                )
            except OSError as error:
                log(f"warning: could not initialize Claude updater state: {error}")
        updaters.append(("claude", ["claude", "update"], 180, env))
    if "codex" in ENABLED_TOOLS:
        codex_update_env = {
            **env,
            "CODEX_HOME": str(CODEX_RUNTIME_HOME),
            "CODEX_INSTALL_DIR": str(HOME / ".local" / "bin"),
        }
        updaters.append(("codex", ["codex", "update"], 300, codex_update_env))
    if "opencode" in ENABLED_TOOLS:
        updaters.append(("opencode", ["opencode", "upgrade"], 300, env))
    for name, cmd, timeout, updater_env in updaters:
        try:
            subprocess.run(cmd, check=True, timeout=timeout, env=updater_env)
            log(f"{name} refreshed to latest")
        except (subprocess.SubprocessError, OSError) as e:
            log(f"{name} refresh skipped ({e}); keeping baked version")


def main() -> None:
    log(f"starting (tools: {','.join(sorted(ENABLED_TOOLS)) or 'none'})")
    fix_volume_ownership()
    block_metadata()
    refresh_ai_tools()
    if "claude-code" in ENABLED_TOOLS:
        setup_claude()
    else:
        log("skipping claude setup (not in AIC_TOOLS)")
    if "codex" in ENABLED_TOOLS:
        setup_codex()
    else:
        log("skipping codex setup (not in AIC_TOOLS)")
    if "opencode" in ENABLED_TOOLS:
        setup_opencode()
    else:
        log("skipping opencode setup (not in AIC_TOOLS)")
    # gh + semgrep: no setup needed. ~/.config/gh is a direct subpath mount of
    # aic-auth-global:gh, so `gh auth login` writes straight into the persistent
    # volume; semgrep is pointed at ~/.config/aic-auth/semgrep/settings.yml via
    # SEMGREP_SETTINGS_FILE (devcontainer.json), inside the same persistent
    # volume — no leaf-file symlink to be clobbered by its atomic-rename writes.
    setup_gitconfig()
    lock_config()
    verify_socket_proxy()
    run_project_hook()
    # Last, so a missing-identity warning is the final thing in `aic rebuild`
    # output rather than scrolling past mid-flow.
    verify_git_identity()
    log("done")


if __name__ == "__main__":
    if sys.argv[1:] == ["sanitize-seeds"]:
        raise SystemExit(sanitize_seeds())
    if sys.argv[1:] == ["auth-sync"]:
        raise SystemExit(auth_sync_main())
    if sys.argv[1:]:
        log(f"unknown arguments: {' '.join(sys.argv[1:])}")
        raise SystemExit(2)
    main()
