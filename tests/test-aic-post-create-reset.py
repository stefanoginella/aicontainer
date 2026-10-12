#!/usr/bin/env python3
"""Per-create reset of the managed tool memory/config files.

A previous autonomous session owns the tool homes, so it can leave a symlink
or a hard link at CLAUDE.md, AGENTS.md, or a config file, or swap a whole tool
home for a link. post-create.py must replace each of them with a new file and
must never write through the link or keep the old text. One failed step must
not skip the later reset/lock steps.
"""
from __future__ import annotations

import contextlib
import importlib
import io
import json
import os
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
CLAUDE_RESET = importlib.import_module("aic_post_create.post_create_claude_reset")
TOOLS = importlib.import_module("aic_post_create.post_create_tools")
MAIN = importlib.import_module("aic_post_create.post_create_main")

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
        original_path = TOOLS.sys.path[:]
        self.addCleanup(TOOLS.sys.path.__setitem__, slice(None), original_path)
        for patch in (
            mock.patch.object(TOOLS, "CLAUDE_HOME", self.claude_home),
            mock.patch.object(TOOLS, "CODEX_HOME", self.codex_home),
            mock.patch.object(TOOLS, "OPENCODE_CONFIG_DIR", self.opencode_config),
            mock.patch.object(TOOLS, "OPENCODE_DATA_DIR", self.tool_homes / "opencode-data"),
            mock.patch.object(TOOLS, "HOST_SEED_CLAUDE", missing),
            mock.patch.object(TOOLS, "HOST_SEED_CODEX", missing),
            mock.patch.object(TOOLS, "HOST_SEED_OPENCODE", missing),
            mock.patch.dict(
                TOOLS.sys.modules,
                {"tomli_w": mock.Mock(dumps=lambda _value: 'approval_policy = "never"\n')},
            ),
        ):
            patch.start()
            self.addCleanup(patch.stop)
        self.addCleanup(self._temp.cleanup)

    @staticmethod
    def patch_replace(side_effect) -> contextlib.ExitStack:
        """Patch _replace_managed_file in each module that setup_claude() calls
        it from, as one patch did when post-create was one file."""
        stack = contextlib.ExitStack()
        for module in (TOOLS, CLAUDE_RESET):
            stack.enter_context(mock.patch.object(
                module, "_replace_managed_file", side_effect=side_effect))
        return stack

    def run_setup(self) -> str:
        captured = io.StringIO()
        with redirect_stderr(captured):
            TOOLS.setup_claude()
            TOOLS.setup_codex()
            TOOLS.setup_opencode()
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
            self.assertIn(TOOLS.SANDBOX_MEMORY_BEGIN, path.read_text(), path)

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
            TOOLS.setup_claude()

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
        original = COMMON._replace_managed_file

        def fail_settings(path: Path, text: str) -> None:
            if path.name == "settings.json":
                raise OSError("blocked")
            original(path, text)

        with self.patch_replace(fail_settings), \
                self.assertRaises(OSError), redirect_stderr(io.StringIO()):
            TOOLS.setup_claude()

        self.assert_fresh_managed_file(self.claude_home / "CLAUDE.md")

    def test_failed_memory_reset_still_resets_config(self) -> None:
        (self.claude_home / "settings.json").write_text(PLANTED)
        original = COMMON._replace_managed_file

        def fail_memory(path: Path, text: str) -> None:
            if path.name == "CLAUDE.md":
                raise OSError("blocked")
            original(path, text)

        with self.patch_replace(fail_memory), \
                self.assertRaises(OSError), redirect_stderr(io.StringIO()):
            TOOLS.setup_claude()

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
            COMMON._replace_managed_file(link / "CLAUDE.md", "text")
        self.assertFalse((self.claude_home / "CLAUDE.md").exists())

    # --- Claude user rules -------------------------------------------------

    def assert_empty_rules(self) -> None:
        rules = self.claude_home / "rules"
        self.assertTrue(rules.is_dir() and not rules.is_symlink(), rules)
        self.assertEqual(list(rules.iterdir()), [])
        leftovers = [p.name for p in self.claude_home.iterdir()
                     if p.name.startswith(CLAUDE_RESET.CLAUDE_RULES_RESET_PREFIX)]
        self.assertEqual(leftovers, [])

    def test_planted_rules_are_removed(self) -> None:
        rules = self.claude_home / "rules"
        (rules / "nested" / "deeper").mkdir(parents=True)
        (rules / "planted.md").write_text(PLANTED)
        (rules / "nested" / "deeper" / "planted.md").write_text(PLANTED)

        self.run_setup()

        self.assert_empty_rules()

    def test_new_project_gets_an_empty_rules_dir(self) -> None:
        self.run_setup()

        self.assert_empty_rules()

    def test_symlinked_rules_dir_is_replaced_and_its_target_kept(self) -> None:
        planted_rules = self.outside / "rules"
        planted_rules.mkdir()
        (planted_rules / "planted.md").write_text(PLANTED)
        (self.claude_home / "rules").symlink_to(planted_rules)

        self.run_setup()

        self.assert_empty_rules()
        self.assertEqual((planted_rules / "planted.md").read_text(), PLANTED)

    def test_links_inside_rules_are_removed_not_followed(self) -> None:
        rules = self.claude_home / "rules"
        rules.mkdir()
        outside_dir = self.outside / "rules-target"
        outside_dir.mkdir()
        (outside_dir / "keep.md").write_text(PLANTED)
        (rules / "file-link.md").symlink_to(self.planted)
        (rules / "dir-link").symlink_to(outside_dir)
        (rules / "dangling.md").symlink_to(self.outside / "never-created")
        os.link(self.planted, rules / "hard-link.md")

        self.run_setup()

        self.assert_empty_rules()
        self.assertEqual(self.planted.read_text(), PLANTED)
        self.assertEqual(self.planted.stat().st_nlink, 1)
        self.assertEqual((outside_dir / "keep.md").read_text(), PLANTED)
        self.assertFalse((self.outside / "never-created").exists())

    def test_rules_with_removed_write_bits_are_still_removed(self) -> None:
        rules = self.claude_home / "rules"
        locked = rules / "locked"
        locked.mkdir(parents=True)
        (locked / "planted.md").write_text(PLANTED)
        locked.chmod(0o500)
        rules.chmod(0o500)
        self.addCleanup(lambda: [p.chmod(0o700) for p in (rules, locked) if p.exists()])

        self.run_setup()

        self.assert_empty_rules()

    def test_unreadable_old_rules_do_not_block_the_reset(self) -> None:
        # Without lchmod (Linux), a 0000 subdirectory cannot be emptied. The
        # old tree then stays under the dot-named aside name, which Claude does
        # not load; `rules` itself must still be a new, empty directory.
        locked = self.claude_home / "rules" / "locked"
        locked.mkdir(parents=True)
        (locked / "planted.md").write_text(PLANTED)
        locked.chmod(0)

        def unlock() -> None:
            for path in self.claude_home.glob(f"{CLAUDE_RESET.CLAUDE_RULES_RESET_PREFIX}*/locked"):
                path.chmod(0o700)
        self.addCleanup(unlock)

        self.run_setup()

        rules = self.claude_home / "rules"
        self.assertTrue(rules.is_dir() and not rules.is_symlink())
        self.assertEqual(list(rules.iterdir()), [])

    def test_old_rules_left_by_an_interrupted_reset_are_deleted(self) -> None:
        leftover = self.claude_home / f"{CLAUDE_RESET.CLAUDE_RULES_RESET_PREFIX}0123456789abcdef"
        leftover.mkdir()
        (leftover / "planted.md").write_text(PLANTED)

        self.run_setup()

        self.assert_empty_rules()

    # --- Claude state file (.claude.json) ---------------------------------

    def claude_state(self) -> Path:
        return self.claude_home / ".claude.json"

    def test_mcp_servers_and_grants_are_removed_and_other_state_kept(self) -> None:
        kept_project = {
            "hasTrustDialogAccepted": True,
            "allowedTools": [],
            "disabledMcpjsonServers": ["refused"],
            "projectOnboardingSeenCount": 3,
        }
        planted_server = {"command": "sh", "args": ["-c", PLANTED]}
        state = {
            "numStartups": 7,
            "installMethod": "native",
            "hasCompletedOnboarding": True,
            "oauthAccount": {"emailAddress": "user@example.invalid"},
            "disabledMcpServers": ["off"],
            "mcpServers": {"planted": planted_server},
            "enabledMcpServers": ["builtin"],
            "env": {"NODE_OPTIONS": f"--require /tmp/{PLANTED}.js"},
            "apiKeyHelper": f"/tmp/{PLANTED}",
            "projects": {
                "/workspace": {
                    **kept_project,
                    "mcpServers": {"planted": planted_server},
                    "enabledMcpjsonServers": ["planted"],
                    "enableAllProjectMcpServers": True,
                    "enabledMcpServers": ["builtin"],
                    "mcpContextUris": [f"planted://{PLANTED}"],
                },
                "/other": "not an object",
            },
        }
        self.claude_state().write_text(json.dumps(state))

        self.run_setup()

        self.assert_fresh_managed_file(self.claude_state())
        result = json.loads(self.claude_state().read_text())
        self.assertEqual(result, {
            "numStartups": 7,
            "installMethod": "native",
            "hasCompletedOnboarding": True,
            "oauthAccount": {"emailAddress": "user@example.invalid"},
            "disabledMcpServers": ["off"],
            "projects": {"/workspace": kept_project, "/other": "not an object"},
        })

    def test_suffixed_state_files_are_reset_too(self) -> None:
        planted = {"keep": 1, "mcpServers": {"planted": {"command": PLANTED}}}
        for name in CLAUDE_RESET.CLAUDE_STATE_FILES:
            (self.claude_home / name).write_text(json.dumps(planted))

        self.run_setup()

        for name in CLAUDE_RESET.CLAUDE_STATE_FILES:
            self.assertEqual(json.loads((self.claude_home / name).read_text()), {"keep": 1}, name)

    def test_legacy_config_json_that_loads_in_place_of_state_is_removed(self) -> None:
        legacy = self.claude_home / ".config.json"
        with self.subTest("file"):
            legacy.write_text(json.dumps({"mcpServers": {"planted": {"command": PLANTED}}}))
            self.run_setup()
            self.assertFalse(os.path.lexists(legacy))
        with self.subTest("symlink"):
            legacy.symlink_to(self.planted)
            self.run_setup()
            self.assertFalse(os.path.lexists(legacy))
            self.assertEqual(self.planted.read_text(), PLANTED)

    def test_clean_state_file_is_not_rewritten(self) -> None:
        self.claude_state().write_text('{"numStartups": 1, "projects": {"/workspace": {}}}\n')
        self.claude_state().chmod(0o600)
        before = self.claude_state().stat()

        self.run_setup()

        after = self.claude_state().stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))

    def test_missing_state_file_is_left_for_the_updater_seed(self) -> None:
        self.run_setup()

        self.assertFalse(os.path.lexists(self.claude_state()))

    def assert_seed_state(self) -> None:
        self.assert_fresh_managed_file(self.claude_state())
        self.assertEqual(json.loads(self.claude_state().read_text()), CLAUDE_RESET.CLAUDE_STATE_SEED)

    def test_unusable_state_contents_are_replaced_with_the_seed(self) -> None:
        planted = json.dumps({"mcpServers": {"planted": {"command": PLANTED}}})
        cases = {
            "invalid JSON": planted[:-1].encode(),
            "invalid UTF-8": b'{"mcpServers": "\xff' + PLANTED.encode() + b'"}',
            "non-standard constant": planted[:-1].encode() + b', "n": NaN}',
            "array": f"[{planted}]".encode(),
            "projects not an object": b'{"projects": ["' + PLANTED.encode() + b'"]}',
            "oversized": b'{"pad": "' + b"x" * CLAUDE_RESET.CLAUDE_STATE_MAX_BYTES + b'"}',
        }
        for name, payload in cases.items():
            with self.subTest(name):
                self.claude_state().write_bytes(payload)
                output = self.run_setup()
                self.assert_seed_state()
                self.assertIn("replacing unusable Claude state", output)

    def test_state_with_a_byte_order_mark_is_stripped_and_rewritten(self) -> None:
        payload = {"numStartups": 2, "mcpServers": {"planted": {"command": PLANTED}}}
        self.claude_state().write_bytes(b"\xef\xbb\xbf" + json.dumps(payload).encode())

        self.run_setup()

        self.assert_fresh_managed_file(self.claude_state())
        self.assertFalse(self.claude_state().read_bytes().startswith(b"\xef\xbb\xbf"))
        self.assertEqual(json.loads(self.claude_state().read_text()), {"numStartups": 2})

    def test_symlinked_state_file_is_replaced_and_its_target_kept(self) -> None:
        target = self.outside / "claude.json"
        target.write_text(json.dumps({"mcpServers": {"planted": {"command": PLANTED}}}))
        original = target.read_text()
        self.claude_state().symlink_to(target)

        self.run_setup()

        self.assert_seed_state()
        self.assertEqual(target.read_text(), original)

    def test_hard_linked_state_file_is_replaced_and_other_link_kept(self) -> None:
        other = self.tool_homes / "other-claude.json"
        other.write_text(json.dumps({"mcpServers": {"planted": {"command": PLANTED}}}))
        original = other.read_text()
        os.link(other, self.claude_state())

        self.run_setup()

        self.assert_seed_state()
        self.assertEqual(other.read_text(), original)

    def test_special_state_files_are_replaced(self) -> None:
        with self.subTest("directory"):
            self.claude_state().mkdir()
            (self.claude_state() / "planted.md").write_text(PLANTED)
            self.run_setup()
            self.assert_seed_state()
        with self.subTest("fifo"):
            self.claude_state().unlink()
            os.mkfifo(self.claude_state())
            self.run_setup()
            self.assert_seed_state()

    def test_failed_state_write_still_resets_rules_and_memory(self) -> None:
        self.claude_state().write_text(json.dumps({"mcpServers": {"x": {}}}))
        (self.claude_home / "CLAUDE.md").write_text(PLANTED)
        (self.claude_home / "rules").mkdir()
        (self.claude_home / "rules" / "planted.md").write_text(PLANTED)
        original = COMMON._replace_managed_file

        def fail_state(path: Path, text: str) -> None:
            if path.name == ".claude.json":
                raise OSError("blocked")
            original(path, text)

        with self.patch_replace(fail_state), \
                self.assertRaises(OSError), redirect_stderr(io.StringIO()):
            TOOLS.setup_claude()

        self.assert_fresh_managed_file(self.claude_home / "CLAUDE.md")
        self.assert_empty_rules()

    # --- What is kept on purpose -------------------------------------------

    def test_auto_memory_skills_and_commands_are_kept(self) -> None:
        kept = [
            self.claude_home / "projects" / "-workspace" / "memory" / "MEMORY.md",
            self.claude_home / "skills" / "kept" / "SKILL.md",
            self.claude_home / "commands" / "kept.md",
        ]
        for path in kept:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(PLANTED)

        self.run_setup()

        for path in kept:
            self.assertEqual(path.read_text(), PLANTED, path)

    def test_codex_rules_are_not_reset(self) -> None:
        # Codex rules are command-approval policy, not instructions; they stay.
        rule = self.codex_home / "rules" / "default.rules"
        rule.parent.mkdir()
        rule.write_text('prefix_rule(pattern=["git"], decision="allow")\n')

        self.run_setup()

        self.assertTrue(rule.is_file())


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

        # The resets run before the updaters start the tools, and the lock
        # runs before the updaters can wait on a slow network.
        names = [
            "fix_volume_ownership", "block_metadata",
            "setup_claude", "setup_codex", "setup_opencode",
            "setup_cli_homes", "setup_gitconfig", "setup_personal_shell",
            "setup_statusline", "lock_config", "apply_statusline",
            "verify_socket_proxy", "refresh_ai_tools", "run_project_hook",
            "verify_git_identity",
        ]
        patches: list = [
            mock.patch.object(MAIN, name, make(name, fail=name == "setup_claude"))
            for name in names
        ]
        patches.append(mock.patch.object(
            MAIN, "ENABLED_TOOLS", frozenset({"claude-code", "codex", "opencode"})
        ))
        captured = io.StringIO()
        for patch in patches:
            patch.start()
        try:
            with redirect_stderr(captured):
                status = MAIN.main()
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
            "fix_volume_ownership", "block_metadata",
            "setup_cli_homes", "setup_gitconfig", "setup_personal_shell",
            "setup_statusline", "lock_config", "apply_statusline",
            "verify_socket_proxy", "refresh_ai_tools", "run_project_hook",
            "verify_git_identity",
        ]
        patches: list = [mock.patch.object(MAIN, name, lambda: None) for name in names]
        patches.append(mock.patch.object(MAIN, "ENABLED_TOOLS", frozenset()))
        for patch in patches:
            patch.start()
        try:
            with redirect_stderr(io.StringIO()):
                self.assertEqual(MAIN.main(), 0)
        finally:
            for patch in reversed(patches):
                patch.stop()


class TemplateTests(unittest.TestCase):
    def test_vscode_waits_for_post_create(self) -> None:
        text = (ROOT / "template" / "devcontainer.json").read_text()
        self.assertRegex(text, r'"waitFor":\s*"postCreateCommand"')


if __name__ == "__main__":
    unittest.main()
