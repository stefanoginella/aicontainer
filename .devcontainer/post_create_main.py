"""The post-create steps (`post-create.py` with no arguments), in their fixed
order.

See "Post-create order" in docs/contributing/seeds-and-auth.md.
"""

from .post_create_common import ENABLED_TOOLS, log
from .post_create_container import (
    apply_declared_firewall,
    block_metadata,
    fix_volume_ownership,
    run_project_hook,
    verify_socket_proxy,
)
from .post_create_git import lock_config, setup_gitconfig, verify_git_identity
from .post_create_overlays import (
    apply_statusline,
    setup_personal_shell,
    setup_statusline,
)
from .post_create_tools import (
    refresh_ai_tools,
    setup_claude,
    setup_cli_homes,
    setup_codex,
    setup_opencode,
)


def _run_step(step, failed: list[str]) -> None:
    """Run one post-create step so its failure cannot skip the later ones.

    The reset, lock, and statusline steps must still run when an earlier step
    fails. A failed step is logged here and fails the command after all steps.
    """
    try:
        step()
    except Exception as error:  # noqa: BLE001 - every later step must still run
        log(f"error: {step.__name__} failed: {type(error).__name__}: {error}")
        failed.append(step.__name__)


def main() -> int:
    log(f"starting (tools: {','.join(sorted(ENABLED_TOOLS)) or 'none'})")
    # First: a declared firewall must be on before a step uses the network.
    steps = [apply_declared_firewall, fix_volume_ownership, block_metadata]
    for tool, step in (
        ("claude-code", setup_claude),
        ("codex", setup_codex),
        ("opencode", setup_opencode),
    ):
        if tool in ENABLED_TOOLS:
            steps.append(step)
        else:
            log(f"skipping {tool.removesuffix('-code')} setup (not in AIC_TOOLS)")
    steps += [
        setup_cli_homes,
        # semgrep: no setup needed. It is pointed at
        # ~/.config/aic-auth/semgrep/settings.yml via SEMGREP_SETTINGS_FILE
        # (devcontainer.json), inside a fixed subpath of the global auth volume —
        # no leaf-file symlink to be clobbered by its atomic-rename writes.
        setup_gitconfig,
        setup_personal_shell,
        setup_statusline,
        lock_config,
        # After the install, so it keys off the root-owned file that actually landed.
        apply_statusline,
        verify_socket_proxy,
        # After the resets: the updaters start the tools, which must not load a
        # previous session's settings, memory, or config. After the lock too: a
        # slow or offline network must not hold back the git identity and the
        # config. Before the project hook, which can use the updated tools.
        refresh_ai_tools,
        run_project_hook,
        # Last, so a missing-identity warning is the final thing in `aic rebuild`
        # output rather than scrolling past mid-flow.
        verify_git_identity,
    ]
    failed: list[str] = []
    for step in steps:
        if step is apply_statusline and "setup_claude" in failed:
            log("skipping apply_statusline: setup_claude failed")
            continue
        # The project declared the firewall but it is not on: do not give
        # these steps the open egress that the project asked to close.
        if step in (refresh_ai_tools, run_project_hook) and "apply_declared_firewall" in failed:
            log(f"skipping {step.__name__}: the declared firewall is not on")
            continue
        _run_step(step, failed)
    if failed:
        log(f"failed steps: {', '.join(failed)}; the sandbox may be half-configured. "
            "Fix the error above, then run 'aic rebuild'.")
        return 1
    log("done")
    return 0
