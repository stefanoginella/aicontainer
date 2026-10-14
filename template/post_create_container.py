"""Container steps: a declared firewall, volume ownership, the metadata block,
the socket-proxy check, and the project hook (post-create.project.sh).

See docs/contributing/project-overrides.md and docs/contributing/runtime-policy.md.
"""

import os
import subprocess
from pathlib import Path

from .post_create_common import AUTH, HOME, SESSIONS, log

# Optional project-declared volume mountpoints to re-own, one path per line in
# .devcontainer/chown-paths. The prefix allowlist mirrors (advisory-only) the
# authoritative check in aic-chown-volumes; the root script re-validates, so a
# bad entry that slips past here is still refused where it matters.
PROJECT_CHOWN_FILE = Path("/workspace/.devcontainer/chown-paths")
CHOWN_ALLOWED_PREFIXES = ("/workspace/", "/home/vscode/.cache/")

# Optional project-owned post-create extension. Runs last, after all aic-managed
# setup, as the sync-safe / pull-mode-compatible place for per-project steps
# (e.g. `npm ci`). See run_project_hook().
PROJECT_POST_CREATE = Path("/workspace/.devcontainer/post-create.project.sh")

# Optional project-owned marker: the project declares that the outbound
# allowlist is on. The Compose start command already enables it on every start;
# apply_declared_firewall() makes post-create wait for that run.
FIREWALL_ENABLE_MARKER = Path("/workspace/.devcontainer/firewall-enable")


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


def apply_declared_firewall() -> None:
    """With .devcontainer/firewall-enable, make sure that the allowlist is on
    before any post-create step uses the network.

    The managed Compose command runs `aic-firewall auto` when the container
    starts, but Dev Containers can start post-create while that run still
    resolves DNS. `auto` waits for it, and enables the firewall itself when no
    generation is active. A failure raises: main() then skips the steps that
    use open egress (the AI-tool refresh and the project hook).
    """
    if not (FIREWALL_ENABLE_MARKER.exists() or FIREWALL_ENABLE_MARKER.is_symlink()):
        return
    subprocess.run(
        ["/usr/bin/sudo", "-n", "/usr/local/bin/aic-firewall", "auto"],
        check=True,
    )
    log("outbound firewall is on (.devcontainer/firewall-enable)")


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
    own setup steps (`npm ci`, ...; not Git hook installers: .git/hooks is RO)
    without editing the aic-managed devcontainer.json (clobbered every sync)
    or post-create.py (baked into the image and absent from the repo in pull
    mode). Opt-in by presence, mirroring chown-paths / firewall-allowlist /
    Dockerfile.project.

    Runs as `vscode` with cwd /workspace and inherited env, but before any
    agent prompt, with open egress and the tool logins. So the host CLI
    treats it as project code: `aic` refuses to start the container until the
    exact file has `aic trust` (or a one-run `--allow-unsafe`). The file lives under
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
