#!/usr/bin/env python3
"""The personal statusline overlay is three fixed tables that must stay aligned.

post-create.py decides which host/project file wins and where it is staged;
aic-lock-user-config installs it root-owned at a fixed destination; the baked
/usr/local/bin/aic-statusline launcher maps that destination filename to an
interpreter. A drift between any two of them silently breaks the feature — or,
worse, installs a file nothing ever validates the interpreter for. These tests
fail loudly on drift, and pin the security properties that let an unvalidated
verbatim code file be installed at all.
"""

from __future__ import annotations

import importlib
import importlib.machinery
import importlib.util
import io
import json
import re
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent

# Load the template modules as the aic_post_create package, as in the image
# (/opt/aic-post-create/aic_post_create/). Patch a name on the module that
# reads it. Never write bytecode into template/.
sys.dont_write_bytecode = True
PACKAGE = types.ModuleType("aic_post_create")
PACKAGE.__path__ = [str(ROOT / "template")]
sys.modules["aic_post_create"] = PACKAGE
COMMON = importlib.import_module("aic_post_create.post_create_common")
SEEDS = importlib.import_module("aic_post_create.post_create_seeds")
OVERLAYS = importlib.import_module("aic_post_create.post_create_overlays")

LOADER = importlib.machinery.SourceFileLoader(
    "aic_lock_user_config_statusline", str(ROOT / "template" / "aic-lock-user-config")
)
LOCK_SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert LOCK_SPEC is not None
LOCK = importlib.util.module_from_spec(LOCK_SPEC)
LOADER.exec_module(LOCK)

DOCKERFILE = (ROOT / "template" / "Dockerfile").read_text()
COMPOSE_PULL = (ROOT / "template" / "docker-compose.pull.yml").read_text()
COMPOSE_BUILD = (ROOT / "template" / "docker-compose.build.yml").read_text()


def aic_source() -> str:
    """The text of aic plus every module in its load list, in load order.

    Only the listed modules run, so a definition in an unlisted file in
    lib/aic/ must not satisfy a test.
    """
    text = (ROOT / "aic").read_text()
    match = re.search(r"^for aic_module in ((?:[^;\\\n]|\\\n)+); do$", text, re.M)
    assert match is not None, "aic has no module load list"
    names = match.group(1).replace("\\\n", " ").split()
    assert names, "the aic module load list is empty"
    return text + "".join((ROOT / "lib" / "aic" / f"{name}.sh").read_text() for name in names)


AIC = aic_source()

MANAGED_DIR = "/etc/aic/user-config/statusline"


class FixedTableAlignmentTests(unittest.TestCase):
    def test_variants_match_the_privileged_install_table(self) -> None:
        lock_targets = {
            t.dest_name: t
            for t in LOCK.TARGETS
            if t.dest_dir.as_posix() == MANAGED_DIR
        }
        variants = {name: staging for name, staging in OVERLAYS.STATUSLINE_VARIANTS}
        self.assertEqual(
            sorted(lock_targets), sorted(variants),
            "post-create STATUSLINE_VARIANTS and aic-lock-user-config TARGETS diverged",
        )
        # post-create resolves staging under the runtime $HOME (which is not
        # /home/vscode when this module is imported on a dev machine), so pin
        # the filename and let the privileged helper own the absolute path.
        for name, staging in variants.items():
            self.assertEqual(
                lock_targets[name].staging.name, staging.name,
                f"staging filename for {name} diverged between the two tables",
            )
            self.assertEqual(
                lock_targets[name].staging.parent.as_posix(), "/home/vscode",
            )
            self.assertEqual(staging.parent, COMMON.HOME)

    def test_launcher_handles_every_variant_and_nothing_else(self) -> None:
        launcher = DOCKERFILE.split("cat > /usr/local/bin/aic-statusline", 1)
        self.assertEqual(len(launcher), 2, "the baked statusline launcher is missing")
        body = launcher[1].split("STATUSLINE_EOF", 2)[1]
        referenced = set(re.findall(r'\$dir/(statusline\.[a-z]+)', body))
        self.assertEqual(
            referenced, {name for name, _ in OVERLAYS.STATUSLINE_VARIANTS},
            "the launcher and STATUSLINE_VARIANTS support different extensions",
        )
        # Every dispatch is an exec of a hardcoded interpreter against a
        # hardcoded path — never an eval of file content or of an argument.
        self.assertNotIn("eval", body)
        self.assertNotIn('"$@"', body)
        self.assertIn(f"dir={MANAGED_DIR}", body)

    def test_managed_dir_is_created_root_owned_and_launcher_is_locked(self) -> None:
        self.assertIn("/etc/aic/user-config/statusline \\", DOCKERFILE)
        self.assertIn("chmod 0555 /usr/local/bin/aic-statusline", DOCKERFILE)
        self.assertIn("/usr/local/bin/aic-statusline", DOCKERFILE.split("chown -R root:root")[-1])

    def test_command_written_into_settings_is_the_fixed_launcher(self) -> None:
        self.assertEqual(OVERLAYS.STATUSLINE_COMMAND, "/usr/local/bin/aic-statusline")
        self.assertEqual(OVERLAYS.STATUSLINE_MANAGED_DIR.as_posix(), MANAGED_DIR)


class HostBoundaryTests(unittest.TestCase):
    def test_host_statusline_field_is_still_dropped_by_the_sanitizer(self) -> None:
        """The overlay must not become a reason to seed the host command string."""
        self.assertNotIn("statusLine", SEEDS.CLAUDE_ALLOWED_FIELDS)
        with mock.patch.object(SEEDS, "RAW_HOST_SEED", Path("/nonexistent")):
            with redirect_stderr(io.StringIO()):
                self.assertEqual(SEEDS._sanitize_claude_seed(), {})

    def test_sanitizer_reads_only_fixed_seed_filenames(self) -> None:
        copied: list[tuple[str, str]] = []
        with mock.patch.object(
            SEEDS, "_copy_verbatim_seed",
            lambda name, src: copied.append((name, src.as_posix())),
        ), mock.patch.object(SEEDS, "_write_sanitized_seed", lambda *a: None), \
                mock.patch.object(SEEDS.os, "geteuid", lambda: 0), \
                mock.patch.object(SEEDS.os, "chmod", lambda *a: None), \
                mock.patch.object(SEEDS, "_sanitize_claude_seed", dict), \
                mock.patch.object(SEEDS, "_sanitize_codex_seed", dict), \
                mock.patch.object(SEEDS, "_sanitize_opencode_seed", dict), \
                mock.patch.object(SEEDS, "_sanitize_git_seed", dict), \
                redirect_stderr(io.StringIO()):
            self.assertEqual(SEEDS.sanitize_seeds(), 0)
        seed_dir = (SEEDS.RAW_HOST_SEED / "aic-config").as_posix()
        for name, _ in SEEDS.STATUSLINE_VARIANTS:
            self.assertIn((name, f"{seed_dir}/{name}"), copied)
        # No glob/discovery: only the fixed overlay names are ever copied.
        self.assertEqual(
            sorted(name for name, _ in copied),
            sorted(["p10k.zsh", "shell-rc.zsh", *(n for n, _ in SEEDS.STATUSLINE_VARIANTS)]),
        )

    def _run_sanitizer(self, raw: Path, sanitized: Path) -> int:
        with mock.patch.object(SEEDS, "RAW_HOST_SEED", raw), \
                mock.patch.object(SEEDS, "SANITIZED_HOST_SEED", sanitized), \
                mock.patch.object(SEEDS.os, "geteuid", lambda: 0), \
                mock.patch.object(SEEDS, "_sanitize_claude_seed", dict), \
                mock.patch.object(SEEDS, "_sanitize_codex_seed", dict), \
                mock.patch.object(SEEDS, "_sanitize_opencode_seed", dict), \
                mock.patch.object(SEEDS, "_sanitize_git_seed", dict), \
                redirect_stderr(io.StringIO()):
            return SEEDS.sanitize_seeds()

    def test_removed_or_rejected_host_overlay_is_removed_from_the_volume(self) -> None:
        """The sanitized volume outlives the container. Deleting a host overlay
        file must opt out on the next create; a stale copy would stay installed
        and sourced, and a stale statusline.sh would beat a new statusline.py."""
        with tempfile.TemporaryDirectory() as tmp_raw:
            tmp = Path(tmp_raw).resolve()
            raw = tmp / "raw"
            aic_config = raw / "aic-config"
            sanitized = tmp / "sanitized"
            aic_config.mkdir(parents=True)
            sanitized.mkdir()
            outside = tmp / "outside"
            outside.write_text("keep\n")
            # Leftovers from an earlier run, one of them a planted link.
            (sanitized / "shell-rc.zsh").write_text("export TOKEN=old\n")
            (sanitized / "p10k.zsh").write_text("# old prompt\n")
            (sanitized / "statusline.sh").write_text("echo old\n")
            (sanitized / "statusline.js").symlink_to(outside)
            (sanitized / "statusline.mjs").write_text("// old\n")
            # Current host inputs: rc.zsh deleted, p10k.zsh emptied, a symlinked
            # and an oversized statusline (both rejected), and a new statusline.py.
            (aic_config / "p10k.zsh").write_text("")
            (aic_config / "statusline.js").symlink_to(outside)
            (aic_config / "statusline.mjs").write_bytes(
                b"x" * (SEEDS.MAX_PERSONAL_OVERLAY_BYTES + 1)
            )
            (aic_config / "statusline.py").write_text("print('new')\n")
            try:
                self.assertEqual(self._run_sanitizer(raw, sanitized), 0)
                overlay = sorted(
                    p.name for p in sanitized.iterdir()
                    if not p.name.endswith(".json")
                )
                self.assertEqual(overlay, ["statusline.py"])
                self.assertEqual((sanitized / "statusline.py").read_text(), "print('new')\n")
                self.assertEqual(outside.read_text(), "keep\n", "unlink must not follow a link")
            finally:
                sanitized.chmod(0o755)

    def test_unremovable_stale_overlay_fails_the_sanitizer(self) -> None:
        """Fail closed: the devcontainer depends on a successful sanitizer run,
        so a stale copy that cannot be removed must stop the start."""
        with tempfile.TemporaryDirectory() as tmp_raw:
            tmp = Path(tmp_raw).resolve()
            raw = tmp / "raw"
            sanitized = tmp / "sanitized"
            (raw / "aic-config").mkdir(parents=True)
            (sanitized / "shell-rc.zsh").mkdir(parents=True)
            try:
                with self.assertRaises(OSError):
                    self._run_sanitizer(raw, sanitized)
            finally:
                sanitized.chmod(0o755)

    def test_seed_dir_is_the_only_new_raw_mount(self) -> None:
        """The statusline seed rides the existing aic-config mount; adding a new
        raw host mount to the sanitizer would be a boundary change."""
        for compose in (COMPOSE_PULL, COMPOSE_BUILD):
            self.assertIn("/raw-host-seed/aic-config:ro", compose)
            self.assertNotIn("statusline", compose)

    def test_project_owned_statusline_files_are_control_boundary_paths(self) -> None:
        control = re.search(r'AIC_CONTROL_FILES="([^"]+)"', AIC)
        assert control is not None
        names = control.group(1).split()
        for name, _ in OVERLAYS.STATUSLINE_VARIANTS:
            self.assertIn(name, names, f"{name} must be symlink-checked by the host CLI")


class WiringTests(unittest.TestCase):
    def _settings(self, tmp: Path) -> Path:
        claude = tmp / "claude"
        claude.mkdir()
        settings = claude / "settings.json"
        settings.write_text('{"model": "opus"}\n')
        return settings

    def test_apply_statusline_is_a_no_op_without_an_installed_file(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw).resolve()
            settings = self._settings(tmp)
            with mock.patch.object(OVERLAYS, "CLAUDE_HOME", settings.parent), \
                    mock.patch.object(OVERLAYS, "STATUSLINE_MANAGED_DIR", tmp / "absent"), \
                    mock.patch.object(OVERLAYS, "ENABLED_TOOLS", frozenset({"claude-code"})), \
                    redirect_stderr(io.StringIO()):
                OVERLAYS.apply_statusline()
            self.assertNotIn("statusLine", json.loads(settings.read_text()))

    def test_apply_statusline_wires_the_installed_file(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw).resolve()
            settings = self._settings(tmp)
            managed = tmp / "managed"
            managed.mkdir()
            (managed / "statusline.mjs").write_text("// personal\n")
            with mock.patch.object(OVERLAYS, "CLAUDE_HOME", settings.parent), \
                    mock.patch.object(OVERLAYS, "STATUSLINE_MANAGED_DIR", managed), \
                    mock.patch.object(OVERLAYS, "ENABLED_TOOLS", frozenset({"claude-code"})), \
                    redirect_stderr(io.StringIO()):
                OVERLAYS.apply_statusline()
            written = json.loads(settings.read_text())
            self.assertEqual(
                written["statusLine"],
                {"type": "command", "command": OVERLAYS.STATUSLINE_COMMAND},
            )
            self.assertEqual(written["model"], "opus", "existing settings must survive")

    def test_apply_statusline_skips_when_claude_is_not_enabled(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw).resolve()
            settings = self._settings(tmp)
            managed = tmp / "managed"
            managed.mkdir()
            (managed / "statusline.sh").write_text("echo hi\n")
            with mock.patch.object(OVERLAYS, "CLAUDE_HOME", settings.parent), \
                    mock.patch.object(OVERLAYS, "STATUSLINE_MANAGED_DIR", managed), \
                    mock.patch.object(OVERLAYS, "ENABLED_TOOLS", frozenset({"codex"})), \
                    redirect_stderr(io.StringIO()):
                OVERLAYS.apply_statusline()
            self.assertNotIn("statusLine", json.loads(settings.read_text()))

    def test_project_file_wins_and_only_one_variant_is_staged(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw).resolve()
            project = tmp / "devcontainer"
            seed = tmp / "host-seed"
            staging_dir = tmp / "home"
            for d in (project, seed, staging_dir):
                d.mkdir()
            # The project ships a lower-priority extension than the host seed;
            # the project GROUP still wins outright.
            (project / "statusline.py").write_text("print('project')\n")
            (seed / "statusline.sh").write_text("echo seed\n")
            variants = tuple(
                (name, staging_dir / f".aic-{name}.staging")
                for name, _ in OVERLAYS.STATUSLINE_VARIANTS
            )
            with mock.patch.object(OVERLAYS, "PROJECT_DEVCONTAINER", project), \
                    mock.patch.object(OVERLAYS, "HOST_SEED", seed), \
                    mock.patch.object(OVERLAYS, "STATUSLINE_VARIANTS", variants), \
                    mock.patch.object(OVERLAYS, "STATUSLINE_MANAGED_DIR", tmp / "absent"), \
                    mock.patch.object(OVERLAYS, "ENABLED_TOOLS", frozenset({"claude-code"})), \
                    redirect_stderr(io.StringIO()):
                OVERLAYS.setup_statusline()
            staged = sorted(p.name for p in staging_dir.iterdir())
            self.assertEqual(staged, [".aic-statusline.py.staging"])
            self.assertEqual(
                (staging_dir / ".aic-statusline.py.staging").read_text(),
                "print('project')\n",
            )

    def test_symlinked_overlay_source_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw).resolve()
            project = tmp / "devcontainer"
            seed = tmp / "host-seed"
            staging_dir = tmp / "home"
            for d in (project, seed, staging_dir):
                d.mkdir()
            (tmp / "elsewhere.sh").write_text("echo pwned\n")
            (project / "statusline.sh").symlink_to(tmp / "elsewhere.sh")
            variants = tuple(
                (name, staging_dir / f".aic-{name}.staging")
                for name, _ in OVERLAYS.STATUSLINE_VARIANTS
            )
            with mock.patch.object(OVERLAYS, "PROJECT_DEVCONTAINER", project), \
                    mock.patch.object(OVERLAYS, "HOST_SEED", seed), \
                    mock.patch.object(OVERLAYS, "STATUSLINE_VARIANTS", variants), \
                    mock.patch.object(OVERLAYS, "STATUSLINE_MANAGED_DIR", tmp / "absent"), \
                    mock.patch.object(OVERLAYS, "ENABLED_TOOLS", frozenset({"claude-code"})), \
                    redirect_stderr(io.StringIO()):
                OVERLAYS.setup_statusline()
            self.assertEqual(list(staging_dir.iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
