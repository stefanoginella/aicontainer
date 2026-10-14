"""Per-project setup of Claude Code, Codex, OpenCode, gh, and npm, and the
AI-tool refresh.

See docs/contributing/seeds-and-auth.md and "AI-tool refresh on every
create" in docs/contributing/shell-and-overlays.md.
"""

import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .post_create_claude_reset import (
    CLAUDE_STATE_FILES,
    CLAUDE_STATE_SEED,
    reset_claude_rules,
    reset_claude_state,
)
from .post_create_common import (
    CLAUDE_HOME,
    CODEX_HOME,
    ENABLED_TOOLS,
    GH_HOME,
    HOME,
    HOST_SEED_CLAUDE,
    HOST_SEED_CODEX,
    HOST_SEED_OPENCODE,
    NPM_HOME,
    OPENCODE_CONFIG_DIR,
    OPENCODE_DATA_DIR,
    _ensure_tool_home,
    _load_sanitized_seed,
    _remove_managed_name,
    _replace_managed_file,
    _reset_managed_files,
    _safe_write_text,
    log,
)
from .post_create_container import FIREWALL_ENABLE_MARKER

CODEX_RUNTIME_HOME = HOME / ".local" / "share" / "aic-tools" / "codex"
CODEX_INSTALLER_URL = "https://chatgpt.com/codex/install.sh"
CODEX_INSTALLER_MAX_BYTES = 4 * 1024 * 1024

# A managed note written into each enabled tool's user-level memory file
# (~/.claude/CLAUDE.md for Claude, ~/.codex/AGENTS.md for Codex,
# ~/.config/opencode/AGENTS.md for OpenCode — all auto-loaded by their tool on
# every session), so an agent doesn't burn tokens "fixing" the
# read-only git internals. .devcontainer/ and the Git control files
# (.git/config, config.worktree, commondir, hooks) are bind-mounted read-only,
# and .git itself is a mount point (see docker-compose.yml); the resulting
# write failures are by-design, not bugs. These user-level instruction files
# are deliberately reset on every create; intentional project instructions
# belong in the repo's CLAUDE.md/AGENTS.md, where they remain project-owned and
# reviewable.
SANDBOX_MEMORY_BEGIN = "<!-- BEGIN aicontainer sandbox notes (managed) -->"
SANDBOX_MEMORY_END = "<!-- END aicontainer sandbox notes (managed) -->"
SANDBOX_MEMORY_NOTE = """\
## Sandbox: read-only git internals (don't try to "fix" this)

This is an aicontainer sandbox. By design, `.devcontainer/` and the Git
control files `.git/config`, `.git/config.worktree`, `.git/commondir`, and
`.git/hooks` are bind-mounted **read-only**, and `.git` itself is a mount
point. A tool can't rewrite its own sandbox or this repository's Git config
and hooks.

These are **expected, not bugs** — don't investigate, retry, remount, or `sudo`
around them:

- Any write to `.git/config` fails: `could not write config file .git/config:
  Device or resource busy` (EBUSY). This includes the upstream-tracking write
  from `git push -u` / `git switch -c --track` — the push or branch itself
  **succeeds**, only the local tracking config is skipped, so don't retry it.
  Reading config and ordinary git (commit, push, pull, fetch, branch, switch) work.
- Installing git hooks (`lefthook install`, `husky`, `pre-commit install`) fails
  writing to `.git/hooks/`.
- `git sparse-checkout set` and `git config --worktree` fail writing to
  `.git/config.worktree`.
- Moving, renaming, or deleting `.git` fails: `Device or resource busy`.

If a change to `.git/config` or `.git/hooks` is genuinely required, make it from
the host, outside the container."""


def load_host_claude_settings() -> dict:
    """Load the already-allowlisted Claude JSON emitted by the sanitizer."""
    return _load_sanitized_seed(HOST_SEED_CLAUDE)


def ensure_sandbox_memory(path: Path) -> None:
    """Replace an auto-loaded user-memory file with the managed sandbox note.

    Preserving arbitrary prior text lets one compromised session plant prompts
    that execute in a later create. Users keep intentional project instructions
    in the repository's CLAUDE.md/AGENTS.md; these user-level files are managed
    security surfaces and are reset on every create. A symlink or hard link at
    the path is replaced, never followed or kept, and a failed reset is an
    error (see main()), not a warning.
    """
    block = f"{SANDBOX_MEMORY_BEGIN}\n{SANDBOX_MEMORY_NOTE}\n{SANDBOX_MEMORY_END}\n"
    _replace_managed_file(path, block)
    log(f"reset managed sandbox note -> {path}")


def setup_claude() -> None:
    """Configure Claude Code preferences. Autonomous mode and the PreToolUse
    hook are enforced separately in /etc/claude-code/managed-settings.json, at
    higher precedence than this writable, per-project user config. The
    auth-sync sidecar copies only .credentials.json between this whole home and
    the global credential store."""
    claude_dir = CLAUDE_HOME
    _ensure_tool_home(claude_dir)

    settings_file = claude_dir / "settings.json"
    settings = load_host_claude_settings()

    def write_settings() -> None:
        _replace_managed_file(settings_file, json.dumps(settings, indent=2) + "\n")
        log(f"wrote {settings_file}")

    # User-level memory is project-local and reset to the managed note on every
    # create, preventing a prior autonomous session from planting instructions.
    # The same holds for user rules (loaded like CLAUDE.md) and for MCP servers
    # and other startup code in the state file. All of this runs before
    # refresh_ai_tools() first starts Claude.
    #
    # Auto memory (projects/<path>/memory/MEMORY.md), skills, agents, commands,
    # and plugins are kept on purpose: they are the project's working state.
    # They can still carry planted text; docs/user/security.md says so.
    _reset_managed_files(
        lambda: ensure_sandbox_memory(claude_dir / "CLAUDE.md"),
        write_settings,
        lambda: reset_claude_rules(claude_dir),
        # Claude reads a legacy .config.json in place of .claude.json.
        lambda: _remove_managed_name(claude_dir / ".config.json"),
        *(lambda name=name: reset_claude_state(claude_dir / name) for name in CLAUDE_STATE_FILES),
    )

    # Every session/history/customization path now lives in this whole
    # per-project home; no globally writable directory controls it. Precreate
    # all known prompt/code roots so a fresh project has the same isolated
    # surface as one where the CLI has already used a feature.
    # "statusline" is the conventional home for a statusline script's own state
    # (caches, counters). Precreate it so an overlay statusline can write there
    # on first render without special-casing a missing directory.
    for dirname in ("projects", "skills", "agents", "commands", "rules", "plugins", "statusline"):
        (claude_dir / dirname).mkdir(exist_ok=True)


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
    _ensure_tool_home(codex_dir)

    cfg = load_host_codex_config()
    cfg["approval_policy"] = "never"
    cfg["sandbox_mode"] = "danger-full-access"

    config_toml = codex_dir / "config.toml"
    # Pinned and baked into /opt by the Dockerfile; importing lazily keeps the
    # networkless sanitizer mode stdlib-only.
    sys.path.insert(0, "/opt/aic-python")
    import tomli_w  # type: ignore[import-not-found]  # noqa: PLC0415

    def write_config() -> None:
        _replace_managed_file(config_toml, tomli_w.dumps(cfg))
        log(f"wrote {config_toml}")

    # AGENTS.md auto-loads for Codex, but is project-local and reset to the
    # managed note on every create. Codex reads AGENTS.override.md in place of
    # AGENTS.md, so that name must not survive either.
    _reset_managed_files(
        lambda: ensure_sandbox_memory(codex_dir / "AGENTS.md"),
        lambda: _remove_managed_name(codex_dir / "AGENTS.override.md"),
        write_config,
    )

    for dirname in ("sessions", "skills", "rules", "prompts", "plugins"):
        (codex_dir / dirname).mkdir(exist_ok=True)


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

    _ensure_tool_home(OPENCODE_CONFIG_DIR)
    config_json = OPENCODE_CONFIG_DIR / "opencode.json"

    def write_config() -> None:
        _replace_managed_file(config_json, json.dumps(cfg, indent=2) + "\n")
        log(f"wrote {config_json}")

    # OpenCode AGENTS.md auto-loads every session (it takes precedence over
    # ~/.claude/CLAUDE.md) and is reset on every create. OpenCode also merges
    # config.json and opencode.jsonc from this directory (.jsonc last), which
    # could add instructions or override opencode.json, so remove both.
    _reset_managed_files(
        lambda: ensure_sandbox_memory(OPENCODE_CONFIG_DIR / "AGENTS.md"),
        lambda: _remove_managed_name(OPENCODE_CONFIG_DIR / "config.json"),
        lambda: _remove_managed_name(OPENCODE_CONFIG_DIR / "opencode.jsonc"),
        write_config,
    )

    # sqlite creates the DB file but not its parent. Everything below this
    # directory is an ordinary per-project path, so OpenCode's atomic updates
    # retain their normal semantics.
    OPENCODE_DATA_DIR.mkdir(parents=True, exist_ok=True)
    (OPENCODE_DATA_DIR / "storage").mkdir(exist_ok=True)
    (OPENCODE_DATA_DIR / "snapshot").mkdir(exist_ok=True)


def setup_cli_homes() -> None:
    """Keep the whole gh and npm config homes in this project's volume.

    ~/.config/gh and ~/.config/npm are image-baked symlinks to them, and
    NPM_CONFIG_USERCONFIG points npm at ~/.config/npm/npmrc. gh config.yml,
    gh per-host settings, and npm settings (registry, script-shell, ...) never
    leave the project; the auth-sync sidecar shares only the login entries of
    hosts.yml and npmrc. `aic initialize` creates both homes as 0700 before
    Compose starts; this only re-creates a missing one.
    """
    for home in (GH_HOME, NPM_HOME):
        try:
            home.mkdir(mode=0o700, parents=True, exist_ok=True)
            home.chmod(0o700)
        except OSError as error:
            log(f"warning: could not prepare {home}: {error}")


def _refresh_command(
    name: str, cmd: list[str], timeout: int, env: dict[str, str]
) -> None:
    """Run one fail-soft native tool updater."""
    try:
        subprocess.run(cmd, check=True, timeout=timeout, env=env)
        log(f"{name} refreshed to latest")
    except (subprocess.SubprocessError, OSError) as error:
        log(f"{name} refresh skipped ({error}); keeping baked version")


def _refresh_codex(env: dict[str, str]) -> None:
    """Refresh the standalone Codex install through its supported installer.

    Some standalone releases cannot identify their installation method for
    `codex update`. OpenAI documents rerunning install.sh with
    CODEX_NON_INTERACTIVE=1 for scripted updates. Download the whole script
    successfully before executing it so a failed transfer cannot run a partial
    installer; keep the same fail-soft baked-floor behavior as the other CLIs.
    """
    try:
        installer = subprocess.run(
            [
                "curl",
                "-fsSL",
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
                "--max-time",
                "60",
                "--max-filesize",
                str(CODEX_INSTALLER_MAX_BYTES),
                CODEX_INSTALLER_URL,
            ],
            check=True,
            timeout=75,
            stdout=subprocess.PIPE,
        )
        if len(installer.stdout) > CODEX_INSTALLER_MAX_BYTES:
            raise ValueError("Codex installer exceeded the download limit")
        subprocess.run(
            ["sh"],
            input=installer.stdout,
            check=True,
            timeout=300,
            env=env,
        )
        log("codex refreshed to latest")
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        log(f"codex refresh skipped ({error}); keeping baked version")


def _firewall_declared() -> bool:
    """The project declared the outbound allowlist. main() runs this step only
    after apply_declared_firewall() turned it on."""
    return FIREWALL_ENABLE_MARKER.exists() or FIREWALL_ENABLE_MARKER.is_symlink()


def _keep_baked_behind_firewall(name: str) -> None:
    log(f"firewall on: keeping the baked {name} version; run `aic rebuild` with "
        "the firewall off, or update the image, to get a newer one")


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
    the documented unattended-installer variables only to its updater preserves
    that split.
    (`opencode upgrade` replaces the binary in place and was installed with
    --no-modify-path.)

    The updaters run in parallel: each one writes only its own binary and
    package directory, so the wait is the slowest updater, not the sum of
    their time limits.

    With a declared firewall, Claude and Codex keep the baked version. Their
    updaters need a host that only the update uses and that the default
    allowlist does not hold: downloads.claude.ai for `claude update`, and
    releases.openai.com for Codex (chatgpt.com/codex/install.sh redirects
    there). They would wait for their time limits (about 90 s) and fail. Do
    not add these hosts to the default allowlist for an update. OpenCode still
    upgrades: `opencode upgrade` uses opencode.ai, which OpenCode needs to
    run, and GitHub hosts of the default allowlist (raw, API, releases)."""
    freeze = os.environ.get("AIC_FREEZE_TOOLS", "").strip().lower()
    if freeze not in ("", "0", "false", "no"):
        log("AIC_FREEZE_TOOLS set — keeping the baked Claude/Codex versions")
        return
    firewall = _firewall_declared()
    env = {**os.environ, "PATH": f"{HOME / '.local' / 'bin'}:{HOME / '.opencode' / 'bin'}:{os.environ.get('PATH', '')}"}
    updaters = []
    if "claude-code" in ENABLED_TOOLS:
        # Claude's native updater records its install method in this ordinary
        # per-project state file. Seed only a missing file so a brand-new
        # project does not emit a migration warning before self-healing.
        # setup_claude() already removed the MCP and startup-code keys from an
        # existing file; nothing else in it is replaced or merged here.
        claude_state = CLAUDE_HOME / ".claude.json"
        if not claude_state.exists():
            try:
                _safe_write_text(
                    claude_state,
                    json.dumps(CLAUDE_STATE_SEED, indent=2) + "\n",
                    create=True,
                )
            except OSError as error:
                log(f"warning: could not initialize Claude updater state: {error}")
        if firewall:
            _keep_baked_behind_firewall("claude")
        else:
            updaters.append(lambda: _refresh_command("claude", ["claude", "update"], 180, env))
    if "codex" in ENABLED_TOOLS and firewall:
        _keep_baked_behind_firewall("codex")
    elif "codex" in ENABLED_TOOLS:
        codex_update_env = {
            **env,
            "CODEX_NON_INTERACTIVE": "1",
            "CODEX_HOME": str(CODEX_RUNTIME_HOME),
            "CODEX_INSTALL_DIR": str(HOME / ".local" / "bin"),
        }
        updaters.append(lambda: _refresh_codex(codex_update_env))
    if "opencode" in ENABLED_TOOLS:
        updaters.append(lambda: _refresh_command("opencode", ["opencode", "upgrade"], 300, env))
    if not updaters:
        return
    with ThreadPoolExecutor(max_workers=len(updaters)) as pool:
        futures = [pool.submit(updater) for updater in updaters]
    for future in futures:
        future.result()
