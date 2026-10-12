"""The opt-in personal overlay: the zsh rc, the p10k config, and the Claude
Code statusline.

See "Personal config overlay" in docs/contributing/shell-and-overlays.md.
"""

import json
from pathlib import Path

from .post_create_common import (
    CLAUDE_HOME,
    ENABLED_TOOLS,
    HOME,
    HOST_SEED,
    _replace_managed_file,
    log,
)

# Project-owned control inputs live here, RO-mounted from the repository.
PROJECT_DEVCONTAINER = Path("/workspace/.devcontainer")

# Personal-config overlay (opt-in). A project-owned .devcontainer/{shell-rc,p10k}
# or the host ~/.config/aicontainer/{rc,p10k} — routed verbatim through the
# sanitizer — is staged here (vscode) and installed root-owned 0444 by
# aic-lock-user-config into the managed shell dir, then sourced by the baked
# .zshrc AFTER the managed baseline. It is code, not data: it cannot be
# allowlist-sanitized, so it is copied verbatim from the trusted human's config.
# See docs/contributing/shell-and-overlays.md. The project file wins over the host
# seed; each MUST match aic-lock-user-config's TARGETS staging paths.
SHELL_MANAGED_DIR = Path("/etc/aic/user-config/shell")
SHELL_RC_MANAGED = SHELL_MANAGED_DIR / "rc.zsh"
P10K_MANAGED = SHELL_MANAGED_DIR / "p10k.zsh"
SHELL_RC_STAGING = HOME / ".aic-shell-rc.staging"
P10K_STAGING = HOME / ".aic-p10k.staging"
PROJECT_SHELL_RC = PROJECT_DEVCONTAINER / "shell-rc.zsh"
PROJECT_P10K = PROJECT_DEVCONTAINER / "p10k.zsh"
HOST_SEED_SHELL_RC = HOST_SEED / "shell-rc.zsh"
HOST_SEED_P10K = HOST_SEED / "p10k.zsh"
MAX_PERSONAL_OVERLAY_BYTES = 1024 * 1024

# Personal statusline overlay (opt-in, Claude Code only). Same channel and trust
# class as the personal shell overlay above: a project-owned
# .devcontainer/statusline.<ext> — or the host ~/.config/aicontainer/statusline.<ext>
# routed verbatim through the sanitizer — staged here and installed root-owned
# 0444 by aic-lock-user-config, then executed by the baked, root-owned
# /usr/local/bin/aic-statusline launcher.
#
# The host settings.json "statusLine" field itself is NEVER seeded: it is an
# arbitrary command string, it stays off CLAUDE_ALLOWED_FIELDS, and its host
# paths do not exist here. What aic writes into settings.json is the fixed
# launcher path, and the launcher picks the interpreter from the installed
# file's fixed extension — so no host-provided string is ever executed and no
# command-line rewriting heuristic is involved. See
# docs/contributing/shell-and-overlays.md.
STATUSLINE_MANAGED_DIR = Path("/etc/aic/user-config/statusline")
STATUSLINE_COMMAND = "/usr/local/bin/aic-statusline"
# (managed filename, staging path) in fixed resolution order. MUST stay aligned
# with aic-lock-user-config's TARGETS and the launcher's lookup order.
STATUSLINE_VARIANTS = (
    ("statusline.sh", HOME / ".aic-statusline-sh.staging"),
    ("statusline.mjs", HOME / ".aic-statusline-mjs.staging"),
    ("statusline.js", HOME / ".aic-statusline-js.staging"),
    ("statusline.py", HOME / ".aic-statusline-py.staging"),
)


def _is_overlay_source(candidate: Path) -> bool:
    """A usable personal-overlay input: a real, non-symlinked regular file."""
    try:
        return not candidate.is_symlink() and candidate.is_file()
    except OSError:
        return False


def _clear_overlay_staging(staging: Path, label: str) -> bool:
    """Remove a stale staging file left by a prior run. False = unusable path."""
    if staging.is_symlink() or staging.exists():
        if staging.is_dir():
            log(f"warning: refusing non-file {label} staging path {staging}")
            return False
        staging.unlink()
    return True


def _write_overlay_staging(src: Path, staging: Path, label: str) -> None:
    """Copy one personal-overlay source verbatim into its fixed staging path."""
    try:
        data = src.read_bytes()
    except OSError as e:
        log(f"warning: could not read personal {label} source {src}: {e}")
        return
    if len(data) > MAX_PERSONAL_OVERLAY_BYTES:
        log(f"warning: personal {label} {src} exceeds {MAX_PERSONAL_OVERLAY_BYTES} bytes; skipping")
        return

    staging.touch(mode=0o600)
    staging.write_bytes(data)
    # World-readable so the fixed sudo helper (which lacks broad DAC_OVERRIDE)
    # can read it; its inode/owner/link checks still prevent path substitution.
    staging.chmod(0o644)
    log(f"staged personal {label} from {src} for root-owned install")


def _stage_personal_shell_file(
    project_src: Path, seed_src: Path, staging: Path, managed: Path, label: str
) -> None:
    """Stage the winning personal-overlay source for the root-owned install.

    The project-owned .devcontainer/ file beats the host ~/.config/aicontainer/
    seed. Verbatim copy — the content is code and can't be allowlist-checked; the
    trust chain is (1) it comes from the human's config, staged before any agent
    session runs, and (2) aic-lock-user-config installs it root-owned 0444 so an
    agent can't tamper with it, while it still executes only as vscode when
    sourced.
    """
    if managed.is_file():
        # Already installed in this container; a rebuild starts from a fresh
        # image and re-stages. Mirrors setup_gitconfig's re-run guard.
        return
    if not _clear_overlay_staging(staging, label):
        return

    src = next((c for c in (project_src, seed_src) if _is_overlay_source(c)), None)
    if src is None:
        return
    _write_overlay_staging(src, staging, label)


def setup_personal_shell() -> None:
    """Stage the opt-in personal shell overlay (rc.zsh + p10k.zsh) for install.

    zsh only: p10k and the overlay `source` lines live in the managed .zshrc, so
    bash/fish users keep the managed baseline unchanged. Both slots are optional
    and independent — a project may ship only a p10k.zsh, only a shell-rc.zsh, or
    both, and likewise for the host seed.
    """
    _stage_personal_shell_file(
        PROJECT_SHELL_RC, HOST_SEED_SHELL_RC, SHELL_RC_STAGING, SHELL_RC_MANAGED, "shell rc"
    )
    _stage_personal_shell_file(
        PROJECT_P10K, HOST_SEED_P10K, P10K_STAGING, P10K_MANAGED, "p10k config"
    )


def _installed_statusline() -> str | None:
    """The one managed statusline filename installed in this container, if any."""
    for name, _ in STATUSLINE_VARIANTS:
        if (STATUSLINE_MANAGED_DIR / name).is_file():
            return name
    return None


def setup_statusline() -> None:
    """Stage the opt-in personal Claude Code statusline for root-owned install.

    Exactly one variant is ever staged. The project-owned
    .devcontainer/statusline.<ext> group beats the host seed group, and within a
    group the fixed STATUSLINE_VARIANTS order decides — no globbing, no
    discovery of arbitrary filenames, and no host command string anywhere in the
    chain (see the STATUSLINE_* constants).
    """
    if "claude-code" not in ENABLED_TOOLS:
        return
    for _, staging in STATUSLINE_VARIANTS:
        if not _clear_overlay_staging(staging, "statusline"):
            return
    if _installed_statusline() is not None:
        # Already installed in this container; a rebuild starts fresh and
        # re-stages. Mirrors setup_gitconfig's re-run guard.
        return

    for source_root in (PROJECT_DEVCONTAINER, HOST_SEED):
        for name, staging in STATUSLINE_VARIANTS:
            candidate = source_root / name
            if _is_overlay_source(candidate):
                _write_overlay_staging(candidate, staging, f"statusline ({name})")
                return


def apply_statusline() -> None:
    """Point Claude Code's per-project settings at the installed statusline.

    Runs after lock_config(), so it keys off what actually landed root-owned
    rather than what was staged: a failed or refused install simply leaves
    settings.json without a statusLine instead of pointing Claude at a file that
    is not there. The command written is the fixed launcher constant.
    """
    if "claude-code" not in ENABLED_TOOLS:
        return
    installed = _installed_statusline()
    if installed is None:
        return
    settings_file = CLAUDE_HOME / "settings.json"
    try:
        settings = json.loads(settings_file.read_text())
    except (OSError, json.JSONDecodeError) as e:
        log(f"warning: could not read {settings_file} to wire the statusline: {e}")
        return
    if not isinstance(settings, dict):
        log(f"warning: {settings_file} is not a JSON object; skipping statusline")
        return
    settings["statusLine"] = {"type": "command", "command": STATUSLINE_COMMAND}
    try:
        _replace_managed_file(settings_file, json.dumps(settings, indent=2) + "\n")
    except OSError as e:
        log(f"warning: could not wire the statusline into {settings_file}: {e}")
        return
    log(f"personal statusline wired: {STATUSLINE_MANAGED_DIR / installed}")
