#!/usr/bin/env python3
"""Per-create reset of the managed tool memory/config files.

A previous autonomous session owns the tool homes, so it can leave a symlink
or a hard link at CLAUDE.md, AGENTS.md, or a config file, or swap a whole tool
home for a link. post-create.py must replace each of them with a new file and
must never write through the link or keep the old text. One failed step must
not skip the later reset/lock steps.
"""
from __future__ import annotations

import importlib.util
import io
import os
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "aic_post_create_reset", ROOT / "template" / "post-create.py"
)
assert SPEC is not None and SPEC.loader is not None
POST_CREATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POST_CREATE)

PLANTED = "AIC_PLANTED_INSTRUCTIONS"


class ManagedFileResetTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.root = Path(self._temp.name).resolve()
        self.tool_homes = self.root / "tool-homes"
        self.claude_home = self.tool_homes / "claude"
        self.codex_home = self.tool_homes / "codex"
        self.opencode_config = self.tool_homes / "opencode-config"
        for home in (self.claude_home, self.codex_home, self.opencode_config):
            home.mkdir(parents=True)
        self.outside = self.root / "outside"
        self.outside.mkdir()
        self.planted = self.outside / "planted.md"
        self.planted.write_text(PLANTED)
        missing = self.root / "missing-seed.json"
        original_path = POST_CREATE.sys.path[:]
        self.addCleanup(POST_CREATE.sys.path.__setitem__, slice(None), original_path)
        for patch in (
            mock.patch.object(POST_CREATE, "CLAUDE_HOME", self.claude_home),
            mock.patch.object(POST_CREATE, "CODEX_HOME", self.codex_home),
            mock.patch.object(POST_CREATE, "OPENCODE_CONFIG_DIR", self.opencode_config),
            mock.patch.object(POST_CREATE, "OPENCODE_DATA_DIR", self.tool_homes / "opencode-data"),
            mock.patch.object(POST_CREATE, "HOST_SEED_CLAUDE", missing),
            mock.patch.object(POST_CREATE, "HOST_SEED_CODEX", missing),
            mock.patch.object(POST_CREATE, "HOST_SEED_OPENCODE", missing),
            mock.patch.dict(
                POST_CREATE.sys.modules,
                {"tomli_w": mock.Mock(dumps=lambda _value: 'approval_policy = "never"\n')},
            ),
        ):
            patch.start()
            self.addCleanup(patch.stop)
        self.addCleanup(self._temp.cleanup)

    def run_setup(self) -> str:
        captured = io.StringIO()
        with redirect_stderr(captured):
            POST_CREATE.setup_claude()
            POST_CREATE.setup_codex()
            POST_CREATE.setup_opencode()
        return captured.getvalue()

    def managed_files(self) -> list[Path]:
        return [
            self.claude_home / "CLAUDE.md",
            self.claude_home / "settings.json",
            self.codex_home / "AGENTS.md",
            self.codex_home / "config.toml",
            self.opencode_config / "AGENTS.md",
            self.opencode_config / "opencode.json",
        ]

    def assert_fresh_managed_file(self, path: Path) -> None:
        info = path.lstat()
        self.assertTrue(path.is_file() and not path.is_symlink(), path)
        self.assertEqual(info.st_nlink, 1, path)
        self.assertEqual(info.st_mode & 0o777, 0o600, path)
        self.assertNotIn(PLANTED, path.read_text(), path)
        if path.name in ("CLAUDE.md", "AGENTS.md"):
            self.assertIn(POST_CREATE.SANDBOX_MEMORY_BEGIN, path.read_text(), path)

    def test_symlinked_managed_files_are_replaced_not_followed(self) -> None:
        for path in self.managed_files():
            path.symlink_to(self.planted)

        self.run_setup()

        for path in self.managed_files():
            self.assert_fresh_managed_file(path)
        self.assertEqual(self.planted.read_text(), PLANTED)

    def test_dangling_symlink_is_replaced_without_creating_its_target(self) -> None:
        target = self.outside / "created-through-link"
        (self.claude_home / "CLAUDE.md").symlink_to(target)

        self.run_setup()

        self.assert_fresh_managed_file(self.claude_home / "CLAUDE.md")
        self.assertFalse(target.exists())

    def test_hard_linked_managed_files_are_replaced_and_other_link_kept(self) -> None:
        for index, path in enumerate(self.managed_files()):
            other = self.tool_homes / f"other-link-{index}"
            other.write_text(PLANTED)
            os.link(other, path)

        self.run_setup()

        for index, path in enumerate(self.managed_files()):
            self.assert_fresh_managed_file(path)
            self.assertEqual((self.tool_homes / f"other-link-{index}").read_text(), PLANTED)

    def test_regular_planted_files_are_reset(self) -> None:
        for path in self.managed_files():
            path.write_text(PLANTED)
            path.chmod(0o644)

        self.run_setup()

        for path in self.managed_files():
            self.assert_fresh_managed_file(path)

    def test_symlinked_tool_home_is_replaced_with_a_real_directory(self) -> None:
        planted_home = self.outside / "claude-home"
        planted_home.mkdir()
        (planted_home / "CLAUDE.md").write_text(PLANTED)
        self.claude_home.rmdir()
        self.claude_home.symlink_to(planted_home)

        self.run_setup()

        self.assertFalse(self.claude_home.is_symlink())
        self.assertTrue(self.claude_home.is_dir())
        self.assert_fresh_managed_file(self.claude_home / "CLAUDE.md")
        self.assertEqual((planted_home / "CLAUDE.md").read_text(), PLANTED)

    def test_symlinked_tool_homes_parent_is_replaced(self) -> None:
        planted_parent = self.outside / "tool-homes"
        (planted_parent / "claude").mkdir(parents=True)
        (planted_parent / "claude" / "CLAUDE.md").write_text(PLANTED)
        moved = self.root / "moved-tool-homes"
        self.tool_homes.rename(moved)
        self.tool_homes.symlink_to(planted_parent)

        captured = io.StringIO()
        with redirect_stderr(captured):
            POST_CREATE.setup_claude()

        self.assertFalse(self.tool_homes.is_symlink())
        self.assert_fresh_managed_file(self.claude_home / "CLAUDE.md")
        self.assertEqual((planted_parent / "claude" / "CLAUDE.md").read_text(), PLANTED)

    def test_directories_at_managed_paths_are_moved_aside(self) -> None:
        for path in self.managed_files():
            path.mkdir()
            (path / "planted.md").write_text(PLANTED)

        self.run_setup()

        for path in self.managed_files():
            self.assert_fresh_managed_file(path)
            aside = [p for p in path.parent.iterdir()
                     if p.name.startswith(f".{path.name}.aic-quarantine-")]
            self.assertEqual(len(aside), 1, path)
            self.assertEqual((aside[0] / "planted.md").read_text(), PLANTED)

    def test_blocked_config_does_not_skip_the_memory_reset(self) -> None:
        (self.claude_home / "CLAUDE.md").write_text(PLANTED)
        original = POST_CREATE._replace_managed_file

        def fail_settings(path: Path, text: str) -> None:
            if path.name == "settings.json":
                raise OSError("blocked")
            original(path, text)

        with mock.patch.object(POST_CREATE, "_replace_managed_file", side_effect=fail_settings), \
                self.assertRaises(OSError), redirect_stderr(io.StringIO()):
            POST_CREATE.setup_claude()

        self.assert_fresh_managed_file(self.claude_home / "CLAUDE.md")

    def test_failed_memory_reset_still_resets_config(self) -> None:
        (self.claude_home / "settings.json").write_text(PLANTED)
        original = POST_CREATE._replace_managed_file

        def fail_memory(path: Path, text: str) -> None:
            if path.name == "CLAUDE.md":
                raise OSError("blocked")
            original(path, text)

        with mock.patch.object(POST_CREATE, "_replace_managed_file", side_effect=fail_memory), \
                self.assertRaises(OSError), redirect_stderr(io.StringIO()):
            POST_CREATE.setup_claude()

        self.assert_fresh_managed_file(self.claude_home / "settings.json")

    def test_read_only_tool_homes_do_not_block_the_reset(self) -> None:
        for path in self.managed_files():
            path.write_text(PLANTED)
        for home in (self.claude_home, self.codex_home, self.opencode_config):
            home.chmod(0o500)
        self.tool_homes.chmod(0o500)
        self.addCleanup(self.tool_homes.chmod, 0o700)

        self.run_setup()

        for path in self.managed_files():
            self.assert_fresh_managed_file(path)
        for home in (self.claude_home, self.codex_home, self.opencode_config):
            self.assertEqual(home.stat().st_mode & 0o777, 0o700, home)

    def test_files_that_load_over_the_managed_ones_are_removed(self) -> None:
        override = self.codex_home / "AGENTS.override.md"
        override.symlink_to(self.planted)
        (self.opencode_config / "opencode.jsonc").write_text(
            '{"instructions": ["%s"]}' % self.planted
        )
        (self.opencode_config / "config.json").mkdir()

        self.run_setup()

        self.assertFalse(os.path.lexists(override))
        self.assertFalse(os.path.lexists(self.opencode_config / "opencode.jsonc"))
        self.assertFalse(os.path.lexists(self.opencode_config / "config.json"))
        self.assertEqual(self.planted.read_text(), PLANTED)

    def test_replace_refuses_a_symlinked_ancestor(self) -> None:
        link = self.root / "linked-home"
        link.symlink_to(self.claude_home)

        with self.assertRaises(OSError):
            POST_CREATE._replace_managed_file(link / "CLAUDE.md", "text")
        self.assertFalse((self.claude_home / "CLAUDE.md").exists())


class MainStepIsolationTests(unittest.TestCase):
    def test_failed_step_does_not_skip_later_steps_and_fails_the_command(self) -> None:
        ran: list[str] = []

        def make(name: str, fail: bool = False):
            def step() -> None:
                ran.append(name)
                if fail:
                    raise OSError("planted symlink")
            step.__name__ = name
            return step

        # The resets run before the updaters start the tools.
        names = [
            "fix_volume_ownership", "block_metadata",
            "setup_claude", "setup_codex", "setup_opencode", "refresh_ai_tools",
            "setup_cli_homes", "setup_gitconfig", "setup_personal_shell",
            "setup_statusline", "lock_config", "apply_statusline",
            "verify_socket_proxy", "run_project_hook", "verify_git_identity",
        ]
        patches: list = [
            mock.patch.object(POST_CREATE, name, make(name, fail=name == "setup_claude"))
            for name in names
        ]
        patches.append(mock.patch.object(
            POST_CREATE, "ENABLED_TOOLS", frozenset({"claude-code", "codex", "opencode"})
        ))
        captured = io.StringIO()
        for patch in patches:
            patch.start()
        try:
            with redirect_stderr(captured):
                status = POST_CREATE.main()
        finally:
            for patch in reversed(patches):
                patch.stop()

        self.assertEqual(status, 1)
        # apply_statusline rewrites settings.json, so it is skipped when
        # setup_claude could not reset that file.
        self.assertEqual(ran, [name for name in names if name != "apply_statusline"])
        self.assertIn("setup_claude failed", captured.getvalue())
        self.assertNotIn("[post-create] done", captured.getvalue())

    def test_clean_run_returns_zero(self) -> None:
        names = [
            "fix_volume_ownership", "block_metadata", "refresh_ai_tools",
            "setup_cli_homes", "setup_gitconfig", "setup_personal_shell",
            "setup_statusline", "lock_config", "apply_statusline",
            "verify_socket_proxy", "run_project_hook", "verify_git_identity",
        ]
        patches: list = [mock.patch.object(POST_CREATE, name, lambda: None) for name in names]
        patches.append(mock.patch.object(POST_CREATE, "ENABLED_TOOLS", frozenset()))
        for patch in patches:
            patch.start()
        try:
            with redirect_stderr(io.StringIO()):
                self.assertEqual(POST_CREATE.main(), 0)
        finally:
            for patch in reversed(patches):
                patch.stop()


class TemplateTests(unittest.TestCase):
    def test_vscode_waits_for_post_create(self) -> None:
        text = (ROOT / "template" / "devcontainer.json").read_text()
        self.assertRegex(text, r'"waitFor":\s*"postCreateCommand"')


if __name__ == "__main__":
    unittest.main()
