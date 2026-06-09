#!/usr/bin/env python3
# /// script
# requires-python = ">=3.13"
# dependencies = ["tomli-w"]
# ///
"""Post-create configuration for aicontainer.

Runs once per container creation. Wires up:

- bypassPermissions for Claude Code + PreToolUse hook registration
- Auto-approve / sandbox-off for Codex
- permission=allow for OpenCode + shared guardrail wired as a plugin
- Allowlisted seeding of host ~/.claude/settings.json, ~/.codex/config.toml and
  ~/.config/opencode/opencode.json (security-critical fields forced to container
  defaults; inline provider API keys are stripped from the opencode seed)
- Per-project session symlinks (~/.claude-sessions). Tool credentials (claude
  .credentials.json, codex auth.json, gh hosts.yml) persist via subpath
  mounts of aic-auth-global declared in docker-compose.yml — no leaf-file
  symlinks, which would be clobbered by atomic-rename writes.
- Ownership fix for named volumes (they come up root-owned the first time)
- Container-only git config that [include]s the read-only host gitconfig
"""

import json
import os
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

import tomli_w

HOME = Path.home()
AUTH = HOME / ".config" / "aic-auth"            # global volume
SESSIONS = HOME / ".claude-sessions"             # per-project volume
HOST_GITCONFIG = HOME / ".gitconfig"             # bind-mounted RO from host

# Sandbox commit-signing material, provisioned by `aic signing` and persisted
# in the aic-auth-global volume (so the pubkey is registered on GitHub once and
# survives rebuilds). The host's own signing key is never forwarded; see
# setup_commit_signing().
SIGNING = AUTH / "signing"
SIGNING_KEY = SIGNING / "id_ed25519"             # private key (0600, vscode-owned)
SIGNING_MODE = SIGNING / "mode"                  # "auto" | "byok" | "disabled"
SIGNING_ALLOWED = SIGNING / "allowed_signers"    # for in-container verification
HOST_SEED_CLAUDE = Path("/host-seed/claude")     # bind-mounted RO file/dir
HOST_SEED_CODEX = Path("/host-seed/codex")       # bind-mounted RO file
HOST_SEED_OPENCODE = Path("/host-seed/opencode") # bind-mounted RO file

# OpenCode splits config from data. The config dir holds opencode.json + the
# global AGENTS.md (rewritten fresh each create, like claude settings.json); the
# data dir is the aic-auth-global:opencode subpath mount where auth.json /
# account.json persist. The session db lives per-project, relocated via
# OPENCODE_DB (devcontainer.json) into the SESSIONS volume.
OPENCODE_CONFIG_DIR = HOME / ".config" / "opencode"
OPENCODE_DATA_DIR = HOME / ".local" / "share" / "opencode"

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
    "env", "attribution", "statusLine",
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
# are never forwarded; the user runs `opencode auth login` inside. `mcp` is
# seeded verbatim (parallel to Claude/Codex MCP seeding — server secrets in
# env/headers ride along under the same accepted trade-off).
OPENCODE_ALLOWED_KEYS = frozenset({
    "provider", "model", "small_model",
    "mcp", "agent", "instructions",
    "theme", "keybinds", "formatter", "lsp",
})

# Substrings (case-insensitive) marking a secret-bearing key to strip from the
# seeded `provider` subtree, so an inline apiKey/token in the host opencode.json
# (or an unforwarded "{env:...}" reference) is not written into the sandbox config.
OPENCODE_SECRET_KEY_HINTS = ("key", "token", "secret", "password")

# A managed note written into each enabled tool's user-level memory file
# (~/.claude/CLAUDE.md for Claude, ~/.codex/AGENTS.md for Codex,
# ~/.config/opencode/AGENTS.md for OpenCode — all auto-loaded by their tool on
# every session), so an agent doesn't burn tokens "fixing" the
# read-only git internals. .git/config, .git/hooks, and .devcontainer/ are
# bind-mounted read-only (see docker-compose.yml); the resulting write failures
# are by-design, not bugs. Marker-delimited so the note can evolve across
# versions and any user-added content in the same file is preserved.
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


def log(msg: str) -> None:
    print(f"[post-create] {msg}", file=sys.stderr)


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
        AUTH,
        SESSIONS,
        HOME / ".claude",
        HOME / ".codex",
        OPENCODE_DATA_DIR,
        HOME / ".config" / "gh",
        HOME / ".config" / "npm",
    ):
        path.mkdir(parents=True, exist_ok=True)
        if path.stat().st_uid != uid:
            needs_chown = True
    # NOTE: the signing dir (AUTH/signing) is intentionally NOT created here.
    # On first creation AUTH is a root-owned named volume, and mkdir-ing a NEW
    # subdir as vscode before the chown below would EACCES (the other entries
    # are pre-existing Docker mountpoints, so their mkdir is a harmless no-op).
    # `aic signing` creates signing/ as vscode once the volume is writable, and
    # aic-chown-volumes re-owns AUTH recursively, so it stays vscode-owned.
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


def _is_empty_placeholder(p: Path) -> bool:
    """True if p is a 0-byte file or empty directory — i.e. a placeholder
    created by `mkdir` in the Dockerfile (or `touch` from a previous run)
    rather than user/tool-written content."""
    if p.is_symlink() or not p.exists():
        return False
    if p.is_file():
        return p.stat().st_size == 0
    if p.is_dir():
        return not any(p.iterdir())
    return False


def _ensure_link_target(src: Path) -> None:
    """Create `src` (a symlink target) if it's missing, so the link never
    dangles. Heuristic: paths with a suffix (.json, .jsonl) are files;
    otherwise directories. Login/session flows that write through the symlink
    then land on the persistent volume immediately."""
    if src.exists():
        return
    src.parent.mkdir(parents=True, exist_ok=True)
    if src.suffix:
        src.touch()
    else:
        src.mkdir(parents=True, exist_ok=True)


def link(src: Path, dst: Path) -> None:
    """Make `dst` a symlink pointing at `src`.

    Cases handled:
    - dst already correctly points at src → ensure src exists (heal a dangling
      target), then no-op. This matters because the session symlinks live in
      the SHARED aic-auth-global volume but point into the PER-PROJECT
      aic-sessions volume: the first project to run creates both the symlink
      and its target, but every *other* project mounts the same shared volume,
      inherits the already-correct symlink, and would otherwise never create
      its own target — leaving it dangling so `mkdir` of the transcript dir
      fails ("File exists") and `/resume` finds nothing.
    - dst is a stale symlink → unlink and recreate
    - dst is an empty placeholder (0-byte file or empty dir) and src has real
      content → replace dst with the symlink (the rebuild case where the
      Dockerfile pre-creates dst but the persistent volume already holds the
      data — without this branch, `gh auth login` etc. silently appears lost)
    - dst is a real file/dir and src doesn't exist → move dst's contents into
      src, then symlink (first run after a fresh `gh auth login` etc.)
    - dst is a real file/dir and src also exists with content → leave dst
      alone and warn
    - dst doesn't exist → ensure src exists (as file or dir based on whether
      we're linking a file path or a dir path), then symlink
    """
    src.parent.mkdir(parents=True, exist_ok=True)
    dst.parent.mkdir(parents=True, exist_ok=True)

    if dst.is_symlink():
        if dst.resolve() == src.resolve():
            _ensure_link_target(src)
            return
        dst.unlink()
    elif dst.exists():
        src_has_content = src.exists() and not _is_empty_placeholder(src)
        if _is_empty_placeholder(dst) and src_has_content:
            if dst.is_dir():
                dst.rmdir()
            else:
                dst.unlink()
        elif src.exists():
            log(f"warning: both {dst} and {src} exist; leaving {dst} alone")
            return
        else:
            # shutil.move (not Path.rename) so dst on the container rootfs can
            # move to src on a named-volume mount — rename() fails EXDEV
            # across filesystems.
            shutil.move(str(dst), str(src))

    _ensure_link_target(src)

    dst.symlink_to(src)
    log(f"linked {dst} -> {src}")


def load_host_claude_settings() -> dict:
    """Read host's ~/.claude/settings.json (bind-mounted RO), keep only
    fields in CLAUDE_ALLOWED_FIELDS, and rewrite statusLine.command paths
    that reference the host ~/.claude/ directory to point at the RO seed
    mount. Returns an empty dict if no host file or unparseable."""
    src = HOST_SEED_CLAUDE / "settings.json"
    if not src.exists() or src.stat().st_size == 0:
        return {}
    try:
        host = json.loads(src.read_text())
    except json.JSONDecodeError as e:
        log(f"warning: host settings.json invalid JSON ({e}); skipping seed")
        return {}

    seeded = {k: v for k, v in host.items() if k in CLAUDE_ALLOWED_FIELDS}
    dropped = sorted(k for k in host if k not in CLAUDE_ALLOWED_FIELDS)
    if dropped:
        log(f"seed: dropped host settings.json fields {dropped} (forced by container)")

    sl = seeded.get("statusLine")
    if isinstance(sl, dict) and isinstance(sl.get("command"), str):
        cmd = sl["command"]
        if "/.claude/" in cmd:
            head, _, tail = cmd.partition("/.claude/")
            # `head` is e.g. "node /Users/stefano" — interpreter then host
            # HOME path. Drop the host HOME path; keep the interpreter.
            interp = head.rpartition(" ")[0].strip()
            host_script = f"/host-seed/claude/{tail}".split()[0]
            if not Path(host_script).exists():
                log(
                    f"warning: statusLine.command references {host_script}, but only "
                    f"~/.claude/statusline/ is bind-mounted into the container. The "
                    f"statusline may fail to run. Move the script under "
                    f"~/.claude/statusline/ on the host, or edit "
                    f".devcontainer/docker-compose.yml to mount its location."
                )
            new_cmd = f"{interp} /host-seed/claude/{tail}".strip()
            sl["command"] = new_cmd
            log(f"seed: rewrote statusLine.command -> {new_cmd}")

    return seeded


def ensure_sandbox_memory(path: Path) -> None:
    """Upsert the managed sandbox note (SANDBOX_MEMORY_NOTE) into a tool's
    user-level memory file. Three cases, all idempotent:

    - file absent → create it holding just the marker-wrapped note.
    - markers already present → replace only what's between them (so the note
      text can change in a future version without duplicating).
    - file exists without our markers → append the block, preserving the user's
      own content (they may keep personal notes in the same file).

    Best-effort: a write failure is logged, not fatal, matching the rest of
    post-create's defensive degradation."""
    # No trailing newline on the block itself: in the in-place-replace branch
    # the existing tail (the text after the END marker) supplies it, so a
    # re-run is byte-identical. The create/append branches add the final "\n".
    block = f"{SANDBOX_MEMORY_BEGIN}\n{SANDBOX_MEMORY_NOTE}\n{SANDBOX_MEMORY_END}"
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        existing = path.read_text() if path.is_file() else ""
        if SANDBOX_MEMORY_BEGIN in existing and SANDBOX_MEMORY_END in existing:
            head, _, rest = existing.partition(SANDBOX_MEMORY_BEGIN)
            _, _, tail = rest.partition(SANDBOX_MEMORY_END)
            updated = f"{head}{block}{tail}"
        elif existing.strip():
            updated = f"{existing.rstrip(chr(10))}\n\n{block}\n"
        else:
            updated = f"{block}\n"
        if updated != existing:
            path.write_text(updated)
            log(f"wrote sandbox note -> {path}")
    except OSError as e:
        log(f"warning: could not write sandbox note to {path}: {e}")


def setup_claude() -> None:
    """Configure Claude Code: seed allowlisted host settings, then force
    bypassPermissions + the PreToolUse hook. ~/.claude itself is the
    aic-auth-global:claude subpath mount, so .credentials.json persists
    by virtue of being inside that volume — no leaf-file symlink needed
    (which would be clobbered by Claude's atomic-rename writes)."""
    claude_dir = HOME / ".claude"
    claude_dir.mkdir(parents=True, exist_ok=True)

    settings_file = claude_dir / "settings.json"
    settings = load_host_claude_settings()

    # Force-override fields that are the actual security/sandbox boundary.
    # `permissions` is irrelevant in bypassPermissions mode but we set it
    # explicitly so the file is self-documenting.
    settings.setdefault("permissions", {})["defaultMode"] = "bypassPermissions"

    hook_spec = json.loads(Path("/etc/aic/hooks/claude-settings.json").read_text())
    settings["hooks"] = hook_spec["hooks"]
    settings_file.write_text(json.dumps(settings, indent=2) + "\n")
    log(f"wrote {settings_file}")

    # User-level memory Claude auto-loads every session.
    ensure_sandbox_memory(claude_dir / "CLAUDE.md")

    # sessions: ~/.claude/projects/ → per-project volume. This symlink lives
    # inside aic-auth-global (because claude_dir IS that mount) but its
    # target is an absolute path string that resolves into aic-sessions at
    # access time, so different projects see distinct project directories.
    link(SESSIONS / "claude-projects", claude_dir / "projects")
    # prompt history: ~/.claude/history.jsonl → per-project volume, so up-arrow
    # recall is scoped per project. Without this it lives in the shared
    # aic-auth-global:claude mount, and because every container's cwd is
    # /workspace, Claude's per-cwd history filter (entry.project === cwd) matches
    # *every* project's entries — so up-arrow bleeds across all projects.
    # A leaf-file symlink is safe here: Claude appends to history.jsonl (the
    # append follows the symlink to the target). The only rewrite-via-atomic-
    # rename is the explicit, confirmation-gated "delete project data" command;
    # if a user runs it the symlink is replaced by a regular file on the shared
    # mount (no data lost — just reverts to shared scope until the next rebuild
    # re-links). Mirrors the codex-history.jsonl handling in setup_codex().
    link(SESSIONS / "claude-history.jsonl", claude_dir / "history.jsonl")
    # Note: we deliberately do NOT symlink ~/.claude.json into the per-project
    # volume. Claude reads/writes that file via atomic rename, which would
    # replace any symlink with a regular file on first write — so the data
    # would land on the rootfs anyway and the symlink would only mislead.
    # The file therefore lives on the rootfs and is rebuild-volatile (only
    # onboarding state + project history; auth is in .credentials.json, which
    # is inside the aic-auth-global:claude subpath mount and persists).


def load_host_codex_config() -> dict:
    """Read host's ~/.codex/config.toml (bind-mounted RO), keep allowlisted
    top-level scalars and tables. [hooks*] is dropped (we own it),
    approval_policy / sandbox_mode are stripped (we force them)."""
    src = HOST_SEED_CODEX / "config.toml"
    if not src.exists() or src.stat().st_size == 0:
        return {}
    try:
        host = tomllib.loads(src.read_text())
    except tomllib.TOMLDecodeError as e:
        log(f"warning: host config.toml invalid TOML ({e}); skipping seed")
        return {}

    seeded: dict = {}
    dropped: list[str] = []
    for k, v in host.items():
        if isinstance(v, dict):
            if k in CODEX_ALLOWED_TABLES:
                seeded[k] = v
            else:
                dropped.append(k)
        else:
            if k in CODEX_ALLOWED_TOPLEVEL and k not in {"approval_policy", "sandbox_mode"}:
                seeded[k] = v
            else:
                dropped.append(k)
    if dropped:
        log(f"seed: dropped host config.toml entries {sorted(dropped)} (forced by container or unsafe to seed)")
    return seeded


def setup_codex() -> None:
    """Configure Codex: seed allowlisted host config, then force
    approval-policy=never and sandbox=danger-full-access. ~/.codex is itself the
    aic-auth-global:codex subpath mount; auth.json persists inside it (same
    atomic-rename reasoning as Claude).

    The shared PreToolUse hook is NOT wired here: Codex command hooks are
    trust-gated, so a hook in this (non-managed) config.toml would be skipped
    until interactively trusted via `/hooks`. It's instead baked as a *managed*
    hook in /etc/codex/requirements.toml (see template/Dockerfile), which Codex
    auto-trusts and the in-container user can't disable. A host `[hooks]` table
    is already dropped by load_host_codex_config()'s allowlist."""
    codex_dir = HOME / ".codex"
    codex_dir.mkdir(parents=True, exist_ok=True)

    cfg = load_host_codex_config()
    cfg["approval_policy"] = "never"
    cfg["sandbox_mode"] = "danger-full-access"

    config_toml = codex_dir / "config.toml"
    config_toml.write_text(tomli_w.dumps(cfg))
    log(f"wrote {config_toml}")

    # Global AGENTS.md Codex auto-loads for every project (verified on 0.135).
    ensure_sandbox_memory(codex_dir / "AGENTS.md")

    # sessions: ~/.codex/sessions/ and history.jsonl → per-project volume.
    # Same cross-volume symlink trick as the claude projects/ symlink.
    link(SESSIONS / "codex-sessions", codex_dir / "sessions")
    link(SESSIONS / "codex-history.jsonl", codex_dir / "history.jsonl")


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


def load_host_opencode_config() -> dict:
    """Read host's ~/.config/opencode/opencode.json (bind-mounted RO), keep only
    keys in OPENCODE_ALLOWED_KEYS, and scrub inline provider secrets. `permission`
    and `plugin` are dropped here (we force them in setup_opencode). Returns an
    empty dict if no host file or unparseable."""
    src = HOST_SEED_OPENCODE / "opencode.json"
    if not src.exists() or src.stat().st_size == 0:
        return {}
    try:
        host = json.loads(src.read_text())
    except json.JSONDecodeError as e:
        log(f"warning: host opencode.json invalid JSON ({e}); skipping seed")
        return {}
    if not isinstance(host, dict):
        return {}

    seeded = {k: v for k, v in host.items() if k in OPENCODE_ALLOWED_KEYS}
    dropped = sorted(k for k in host if k not in OPENCODE_ALLOWED_KEYS and k != "$schema")
    if dropped:
        log(f"seed: dropped host opencode.json keys {dropped} (forced by container or unsafe to seed)")

    prov = seeded.get("provider")
    if isinstance(prov, dict) and _scrub_provider_secrets(prov):
        log("seed: stripped inline provider API key(s) from opencode.json — host "
            "credentials are not forwarded; run 'opencode auth login' inside the container")
    return seeded


def setup_opencode() -> None:
    """Configure OpenCode: seed allowlisted host config, then force
    permission=allow (the bypass/autonomous boundary) and wire the shared
    PreToolUse guardrail as a plugin (absolute path to the root-owned shim).

    ~/.local/share/opencode is the aic-auth-global:opencode subpath mount, so
    auth.json / account.json persist inside it across rebuilds. Session
    transcripts stay project-scoped: the sqlite db is relocated per-project via
    OPENCODE_DB (devcontainer.json) into ~/.claude-sessions, and the file-based
    storage dir is symlinked there too — same cross-volume trick as setup_claude's
    projects/ symlink."""
    cfg = load_host_opencode_config()
    # Force the sandbox boundary regardless of what the host had.
    cfg["$schema"] = "https://opencode.ai/config.json"
    cfg["permission"] = {"*": "allow"}
    cfg["plugin"] = ["/etc/aic/hooks/opencode-guardrail.js"]

    OPENCODE_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    config_json = OPENCODE_CONFIG_DIR / "opencode.json"
    config_json.write_text(json.dumps(cfg, indent=2) + "\n")
    log(f"wrote {config_json}")

    # Global AGENTS.md OpenCode auto-loads for every session (it takes precedence
    # over ~/.claude/CLAUDE.md).
    ensure_sandbox_memory(OPENCODE_CONFIG_DIR / "AGENTS.md")

    # Per-project session isolation. OPENCODE_DB points the sqlite session db at
    # ~/.claude-sessions/opencode/opencode.db (the per-project SESSIONS volume) —
    # sqlite creates the file but not the parent dir, so make it here. Also
    # symlink the file-based session-artifact dirs out into SESSIONS so they stay
    # project-scoped too (kept on the SAME per-project side as the db, so it never
    # indexes them across a volume boundary). `storage/` is current; `snapshot/`
    # holds working-tree checkpoints — in 1.16 these are db-backed, but symlink it
    # anyway so a future version that revives file-based snapshots can't bleed one
    # project's file contents into another. (repos/ and log/ deliberately stay in
    # the shared global volume — clones and logs, the same accepted trade-off as
    # claude/codex shared metadata.)
    (SESSIONS / "opencode").mkdir(parents=True, exist_ok=True)
    link(SESSIONS / "opencode-storage", OPENCODE_DATA_DIR / "storage")
    link(SESSIONS / "opencode-snapshot", OPENCODE_DATA_DIR / "snapshot")


def _host_git_config(key: str) -> str:
    """Read a single value straight from the read-only host ~/.gitconfig
    (not the effective config, so we see the host's intent regardless of our
    own override ordering). Empty string if unset or git is unavailable."""
    try:
        r = subprocess.run(
            ["git", "config", "--file", str(HOST_GITCONFIG), "--get", key],
            capture_output=True, text=True,
        )
        return r.stdout.strip() if r.returncode == 0 else ""
    except FileNotFoundError:
        return ""


def setup_commit_signing() -> str:
    """Return the container-local commit-signing config to append to
    ~/.gitconfig.local *after* the host [include] (so it overrides the host's
    signing settings — inside the sandbox only; the host gitconfig is mounted
    read-only and never touched).

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

    Takes effect on container (re)create only: ~/.gitconfig.local is rewritten
    fresh each creation and then root-locked, so a mode change via `aic signing`
    lands on the next rebuild — no live edit of the locked file is needed (and
    no privileged unlock primitive, which a compromised session could abuse)."""
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
    """Write ~/.gitconfig.local (pointed at by GIT_CONFIG_GLOBAL in
    devcontainer.json). Includes the read-only host gitconfig and adds
    container-only settings."""
    excludes = HOME / ".gitignore_global"
    excludes.write_text(
        "# aicontainer global excludes\n"
        ".claude/\n.codex/\nnode_modules/\n.venv/\n__pycache__/\n"
        ".DS_Store\n*.pyc\n.env\n.env.local\n.env.*.local\n"
    )

    local = HOME / ".gitconfig.local"
    if local.exists() and local.stat().st_uid == 0:
        # Already locked by aic-lock-gitconfig from a previous post-create run
        # (file is root:root 0444). Skip the rewrite — we'd hit EACCES and the
        # contents are stable anyway.
        return
    # Commit-signing config goes LAST so it overrides the host [include] above
    # (git takes the last value for single-valued keys; the include is inlined
    # at the top, our block is appended at the bottom).
    signing = setup_commit_signing()
    local.write_text(
        f"# aicontainer container-local git config\n"
        f"[include]\n    path = {HOST_GITCONFIG}\n"
        f"[core]\n"
        f"    excludesfile = {excludes}\n"
        f"    pager = delta\n"
        f"[interactive]\n    diffFilter = delta --color-only\n"
        f"[delta]\n    navigate = true\n    line-numbers = true\n"
        f"[merge]\n    conflictstyle = diff3\n"
        f"[diff]\n    colorMoved = default\n"
        f"{signing}"
    )
    log(f"wrote {local}")


def lock_config() -> None:
    """Hand the self-protection files to root via aic-lock-gitconfig (root:root
    0444): ~/.gitconfig.local (so a compromised tool session can't inject
    credential.helper / core.sshCommand to capture tokens) and the baked
    login-shell rc files ~/.zshrc / ~/.bashrc / fish config (so it can't plant a
    payload that runs on the next `aic shell`). The wrapper locks a hardcoded
    list and skips absent targets, so we invoke it unconditionally each
    creation — the baked rc files ship owned by `vscode` and need re-locking on
    every rebuild, independent of the (freshly written) gitconfig.local."""
    try:
        subprocess.run(["sudo", "/usr/local/bin/aic-lock-gitconfig"], check=True)
        log("locked ~/.gitconfig.local + baked shell rc files")
    except subprocess.CalledProcessError as e:
        log(f"warning: aic-lock-gitconfig failed: {e}")


def verify_git_identity() -> None:
    """Loudly flag a missing commit identity at create time, so it surfaces here
    instead of cryptically mid-session on the first `git commit` ("Author
    identity unknown").

    The sandbox has NO identity of its own: ~/.gitconfig.local [include]s the
    read-only host ~/.gitconfig, so identity is whatever the host file provided
    when the container was (re)created. A host gitconfig that was empty/broken at
    that moment leaves no identity here — and it can't be fixed from inside:
    `git config --global` writes to the root-locked ~/.gitconfig.local, and
    `git config --local` writes to /workspace/.git/config, which is mounted
    read-only. The only fix is on the host, so that's where we point. Non-fatal —
    matches the rest of post-create's defensive degradation."""
    def configured(key: str) -> bool:
        # cwd=HOME (not a repo) reads system + global only — the include chain
        # through ~/.gitconfig.local — with no repo-local config or
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
        "from your host ~/.gitconfig (mounted read-only), which was empty/unset "
        "when this container was built. Fix it on the HOST, then 'aic rebuild' — "
        "it can't be fixed from inside (~/.gitconfig.local is root-locked and "
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
    # Our postCreateCommand is `uv run --no-project /opt/post-create.py`, which
    # activates an ephemeral env for THIS script — exporting VIRTUAL_ENV (and
    # prepending its bin/ to PATH) into the inherited environment. Passed
    # through, a project hook running `uv sync`/`uv run` would see VIRTUAL_ENV
    # pointing at .cache/uv/environments-v2/post-create-* instead of the
    # project's .venv and warn ("does not match the project environment path
    # `.venv` and will be ignored"). Strip the leaked activation so the hook's
    # uv resolves the project environment cleanly.
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
    which we force onto PATH for the updaters: `codex update` re-runs the official
    installer, which only edits a login-shell rc file (root-locked at runtime by
    aic-lock-gitconfig) when its bin dir is NOT already on PATH — keeping it on
    PATH makes the update a clean no-write. (`opencode upgrade` replaces the
    binary in place and was installed with --no-modify-path.)"""
    freeze = os.environ.get("AIC_FREEZE_TOOLS", "").strip().lower()
    if freeze not in ("", "0", "false", "no"):
        log("AIC_FREEZE_TOOLS set — keeping the baked Claude/Codex versions")
        return
    env = {**os.environ, "PATH": f"{HOME / '.local' / 'bin'}:{HOME / '.opencode' / 'bin'}:{os.environ.get('PATH', '')}"}
    updaters = []
    if "claude-code" in ENABLED_TOOLS:
        updaters.append(("claude", ["claude", "update"], 180))
    if "codex" in ENABLED_TOOLS:
        updaters.append(("codex", ["codex", "update"], 300))
    if "opencode" in ENABLED_TOOLS:
        updaters.append(("opencode", ["opencode", "upgrade"], 300))
    for name, cmd, timeout in updaters:
        try:
            subprocess.run(cmd, check=True, timeout=timeout, env=env)
            log(f"{name} refreshed to latest")
        except (subprocess.SubprocessError, OSError) as e:
            log(f"{name} refresh skipped ({e}); keeping baked version")


def main() -> None:
    log(f"starting (tools: {','.join(sorted(ENABLED_TOOLS)) or 'none'})")
    fix_volume_ownership()
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
    main()
