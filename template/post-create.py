#!/usr/bin/env python3
# /// script
# requires-python = ">=3.13"
# dependencies = ["tomli-w"]
# ///
"""Post-create configuration for aicontainer.

Runs once per container creation. Wires up:

- bypassPermissions for Claude Code + PreToolUse hook registration
- Auto-approve / sandbox-off for Codex
- Allowlisted seeding of host ~/.claude/settings.json and ~/.codex/config.toml
  (security-critical fields are forced to container defaults)
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
HOST_SEED_CLAUDE = Path("/host-seed/claude")     # bind-mounted RO file/dir
HOST_SEED_CODEX = Path("/host-seed/codex")       # bind-mounted RO file

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
KNOWN_TOOLS = frozenset({"claude-code", "codex"})
ENABLED_TOOLS = frozenset(
    t.strip() for t in os.environ.get("AIC_TOOLS", "claude-code,codex").split(",") if t.strip()
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
        HOME / ".config" / "gh",
        HOME / ".config" / "npm",
    ):
        path.mkdir(parents=True, exist_ok=True)
        if path.stat().st_uid != uid:
            needs_chown = True
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

    # sessions: ~/.codex/sessions/ and history.jsonl → per-project volume.
    # Same cross-volume symlink trick as the claude projects/ symlink.
    link(SESSIONS / "codex-sessions", codex_dir / "sessions")
    link(SESSIONS / "codex-history.jsonl", codex_dir / "history.jsonl")


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
    try:
        subprocess.run(["bash", str(PROJECT_POST_CREATE)], cwd="/workspace", check=True)
        log("project hook finished")
    except subprocess.CalledProcessError as e:
        log(f"warning: project hook exited {e.returncode}; continuing")


def main() -> None:
    log(f"starting (tools: {','.join(sorted(ENABLED_TOOLS)) or 'none'})")
    fix_volume_ownership()
    if "claude-code" in ENABLED_TOOLS:
        setup_claude()
    else:
        log("skipping claude setup (not in AIC_TOOLS)")
    if "codex" in ENABLED_TOOLS:
        setup_codex()
    else:
        log("skipping codex setup (not in AIC_TOOLS)")
    # gh + semgrep: no setup needed. ~/.config/gh is a direct subpath mount of
    # aic-auth-global:gh, so `gh auth login` writes straight into the persistent
    # volume; semgrep is pointed at ~/.config/aic-auth/semgrep/settings.yml via
    # SEMGREP_SETTINGS_FILE (devcontainer.json), inside the same persistent
    # volume — no leaf-file symlink to be clobbered by its atomic-rename writes.
    setup_gitconfig()
    lock_config()
    verify_socket_proxy()
    run_project_hook()
    log("done")


if __name__ == "__main__":
    main()
