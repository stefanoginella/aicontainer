"""The seed sanitizer (`post-create.py sanitize-seeds`).

It runs as root in the networkless aic-seed-sanitizer service. It is the only
code that reads raw host config. See "Seed sanitizer" in
docs/contributing/seeds-and-auth.md.
"""

import json
import os
import subprocess
import tempfile
import tomllib
from pathlib import Path

from .post_create_common import RAW_HOST_SEED, SANITIZED_HOST_SEED, log
from .post_create_overlays import MAX_PERSONAL_OVERLAY_BYTES, STATUSLINE_VARIANTS

# Claude settings.json fields safe to copy from the host. Anything outside
# this set — permissions, hooks, apiKeyHelper, awsAuthRefresh,
# awsCredentialExpiration — is dropped because it would either defeat the
# sandbox boundary or carry host-specific auth secrets/paths.
#
# statusLine stays out on purpose: it is an arbitrary host command string with
# host-only paths. Bringing a personal statusline into the sandbox goes through
# the opt-in verbatim overlay instead (see the STATUSLINE_* constants), which
# installs the script root-owned and runs it through a fixed launcher.
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


def _remove_verbatim_seed(name: str) -> None:
    """Remove one fixed overlay output whose host source is gone or rejected.

    unlink never follows a link. Any error except "already absent" propagates
    and fails the sanitizer, and with it the devcontainer start: a stale copy
    that cannot be removed would still be installed and sourced.
    """
    try:
        os.unlink(SANITIZED_HOST_SEED / name)
    except FileNotFoundError:
        return
    log(f"sanitizer: removed personal {name} (host source absent or rejected)")


def _copy_verbatim_seed(name: str, raw_src: Path) -> None:
    """Copy one opt-in personal overlay file verbatim into the sanitized volume.

    Unlike the four JSON seeds, a personal shell rc / p10k config / Claude
    statusline is code and CANNOT be allowlist-sanitized, so it is copied
    byte-for-byte from the trusted human's input. This is not a security
    downgrade of the sanitizer: the file lands root-owned 0444 (an in-container
    agent cannot tamper with it) and its contents still execute only as the
    unprivileged `vscode` user — the same authority the agent already has.
    Absent/empty/oversized/non-regular inputs are skipped (opt-in by presence),
    and a copy left by an earlier run is removed: the volume outlives the
    container, so deleting the host file must opt out on the next create.
    """
    try:
        if raw_src.is_symlink() or not raw_src.is_file():
            _remove_verbatim_seed(name)
            return
        data = raw_src.read_bytes()
    except OSError as e:
        log(f"sanitizer: skipping personal {name} ({e})")
        _remove_verbatim_seed(name)
        return
    if not data or len(data) > MAX_PERSONAL_OVERLAY_BYTES:
        if len(data) > MAX_PERSONAL_OVERLAY_BYTES:
            log(f"sanitizer: personal {name} exceeds {MAX_PERSONAL_OVERLAY_BYTES} bytes; skipping")
        _remove_verbatim_seed(name)
        return
    SANITIZED_HOST_SEED.mkdir(parents=True, exist_ok=True)
    os.chmod(SANITIZED_HOST_SEED, 0o700)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{name}.", dir=SANITIZED_HOST_SEED)
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        tmp.chmod(0o444)
        os.replace(tmp, SANITIZED_HOST_SEED / name)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def sanitize_seeds() -> int:
    """One-shot Compose service entry point. It alone sees raw host inputs; the
    long-running devcontainer receives only root-owned products through a
    read-only volume: four allowlisted JSON seeds plus, when present, the opt-in
    personal overlay files copied verbatim (see _copy_verbatim_seed)."""
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
    # Opt-in personal overlay from the host ~/.config/aicontainer/ dir: zsh
    # startup, the p10k prompt, and the Claude Code statusline script. Every
    # name here is fixed; nothing is discovered by globbing the seed dir.
    aic_config = RAW_HOST_SEED / "aic-config"
    _copy_verbatim_seed("shell-rc.zsh", aic_config / "rc.zsh")
    _copy_verbatim_seed("p10k.zsh", aic_config / "p10k.zsh")
    for statusline_name, _ in STATUSLINE_VARIANTS:
        _copy_verbatim_seed(statusline_name, aic_config / statusline_name)
    os.chmod(SANITIZED_HOST_SEED, 0o555)
    log("sanitizer: wrote fixed allowlisted seeds")
    return 0
