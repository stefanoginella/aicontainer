#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "aic_post_create_auth_sync", ROOT / "template" / "post-create.py"
)
assert SPEC is not None and SPEC.loader is not None
POST_CREATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POST_CREATE)

SECRET = "AIC_TEST_SECRET_MUST_NEVER_APPEAR_IN_LOGS"


class ToolRefreshTests(unittest.TestCase):
    def test_codex_refresh_downloads_before_unattended_install(self) -> None:
        script = b"#!/bin/sh\nexit 0\n"
        completed = subprocess.CompletedProcess(
            args=["curl"], returncode=0, stdout=script
        )
        env = {
            "PATH": "/home/vscode/.local/bin:/usr/bin",
            "CODEX_NON_INTERACTIVE": "1",
            "CODEX_HOME": "/home/vscode/.local/share/aic-tools/codex",
            "CODEX_INSTALL_DIR": "/home/vscode/.local/bin",
        }

        with mock.patch.object(
            POST_CREATE.subprocess, "run", side_effect=[completed, completed]
        ) as run:
            POST_CREATE._refresh_codex(env)

        download, install = run.call_args_list
        self.assertIn(POST_CREATE.CODEX_INSTALLER_URL, download.args[0])
        self.assertEqual(download.kwargs["stdout"], POST_CREATE.subprocess.PIPE)
        self.assertEqual(install.args[0], ["sh"])
        self.assertEqual(install.kwargs["input"], script)
        self.assertEqual(install.kwargs["env"], env)


class ToolHomeInitializationTests(unittest.TestCase):
    def test_fresh_tool_homes_include_every_isolated_prompt_code_root(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            claude_home = root / "claude"
            codex_home = root / "codex"
            missing_seed = root / "missing-seed.json"
            original_path = POST_CREATE.sys.path[:]
            fake_tomli_w = mock.Mock(dumps=lambda _value: "")
            try:
                with (
                    mock.patch.object(POST_CREATE, "CLAUDE_HOME", claude_home),
                    mock.patch.object(POST_CREATE, "CODEX_HOME", codex_home),
                    mock.patch.object(POST_CREATE, "HOST_SEED_CLAUDE", missing_seed),
                    mock.patch.object(POST_CREATE, "HOST_SEED_CODEX", missing_seed),
                    mock.patch.dict(POST_CREATE.sys.modules, {"tomli_w": fake_tomli_w}),
                ):
                    POST_CREATE.setup_claude()
                    POST_CREATE.setup_codex()
            finally:
                POST_CREATE.sys.path[:] = original_path

            for dirname in ("projects", "skills", "agents", "commands", "plugins"):
                self.assertTrue((claude_home / dirname).is_dir(), dirname)
            for dirname in ("sessions", "skills", "rules", "prompts", "plugins"):
                self.assertTrue((codex_home / dirname).is_dir(), dirname)


class AuthSyncTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        # macOS exposes /var as a symlink to /private/var. The production
        # sidecar deliberately rejects symlinked ancestors, so use the canonical
        # path in tests on every platform as well.
        self.root = Path(self.temp.name).resolve()
        self.global_root = self.root / "global"
        self.project_root = self.root / "project"
        for path in (
            self.global_root / "claude",
            self.global_root / "codex",
            self.global_root / "opencode",
            self.project_root / "tool-homes" / "claude",
            self.project_root / "tool-homes" / "codex",
            self.project_root / "tool-homes" / "opencode-data",
        ):
            path.mkdir(parents=True, exist_ok=True)
            path.chmod(0o700)
        POST_CREATE.AUTH_SYNC_GLOBAL = self.global_root
        POST_CREATE.AUTH_SYNC_PROJECT = self.project_root
        POST_CREATE._AUTH_SYNC_WARNED.clear()
        self.states: dict = {}

    def tearDown(self) -> None:
        self.temp.cleanup()

    @staticmethod
    def write_json(path: Path, value: object, *, mtime_ns: int | None = None) -> None:
        path.write_text(json.dumps(value))
        path.chmod(0o600)
        if mtime_ns is not None:
            os.utime(path, ns=(mtime_ns, mtime_ns))

    @staticmethod
    def atomic_json(path: Path, value: object) -> None:
        temp = path.with_name(f".{path.name}.tool-update")
        AuthSyncTests.write_json(temp, value)
        temp.replace(path)

    def sync(self, tool: str, global_dir: str, local_dir: str, filename: str) -> None:
        POST_CREATE._sync_credential_pair(
            tool, global_dir, local_dir, filename, self.states
        )

    def test_initial_reconciliation_is_newer_wins_in_both_directions(self) -> None:
        global_claude = self.global_root / "claude" / ".credentials.json"
        local_claude = (
            self.project_root / "tool-homes" / "claude" / ".credentials.json"
        )
        self.write_json(global_claude, {"token": "global-old"}, mtime_ns=1_000_000_000)
        self.write_json(local_claude, {"token": "project-new"}, mtime_ns=2_000_000_000)
        self.sync("Claude", "claude", "claude", ".credentials.json")
        self.assertEqual(json.loads(global_claude.read_text()), {"token": "project-new"})

        global_codex = self.global_root / "codex" / "auth.json"
        local_codex = self.project_root / "tool-homes" / "codex" / "auth.json"
        self.write_json(local_codex, {"token": "project-old"}, mtime_ns=1_000_000_000)
        self.write_json(global_codex, {"token": "global-new"}, mtime_ns=2_000_000_000)
        self.sync("Codex", "codex", "codex", "auth.json")
        self.assertEqual(json.loads(local_codex.read_text()), {"token": "global-new"})

    def test_atomic_updates_propagate_both_directions_and_logout(self) -> None:
        global_path = self.global_root / "claude" / ".credentials.json"
        local_path = self.project_root / "tool-homes" / "claude" / ".credentials.json"
        self.write_json(global_path, {"token": "initial"})
        self.sync("Claude", "claude", "claude", ".credentials.json")
        self.assertEqual(stat_mode(local_path), 0o600)

        self.atomic_json(local_path, {"token": "from-project"})
        self.sync("Claude", "claude", "claude", ".credentials.json")
        self.assertEqual(json.loads(global_path.read_text()), {"token": "from-project"})
        self.assertEqual(stat_mode(global_path), 0o600)

        self.atomic_json(global_path, {"token": "from-global"})
        self.sync("Claude", "claude", "claude", ".credentials.json")
        self.assertEqual(json.loads(local_path.read_text()), {"token": "from-global"})
        self.assertEqual(stat_mode(local_path), 0o600)

        local_path.unlink()
        self.sync("Claude", "claude", "claude", ".credentials.json")
        self.assertFalse(global_path.exists(), "an observed project logout must propagate")

    def test_invalid_symlink_and_oversize_inputs_never_poison_peer(self) -> None:
        global_path = self.global_root / "claude" / ".credentials.json"
        local_path = self.project_root / "tool-homes" / "claude" / ".credentials.json"
        trusted = {"token": SECRET}
        self.write_json(global_path, trusted)
        local_path.write_text("not-json")
        local_path.chmod(0o600)

        captured = io.StringIO()
        with redirect_stderr(captured):
            self.sync("Claude", "claude", "claude", ".credentials.json")
        self.assertEqual(json.loads(global_path.read_text()), trusted)
        self.assertEqual(json.loads(local_path.read_text()), trusted)

        outside = self.root / "outside.json"
        self.write_json(outside, {"outside": SECRET})
        local_path.unlink()
        local_path.symlink_to(outside)
        with redirect_stderr(captured):
            self.sync("Claude", "claude", "claude", ".credentials.json")
        self.assertFalse(local_path.is_symlink())
        self.assertEqual(json.loads(local_path.read_text()), trusted)
        self.assertEqual(json.loads(outside.read_text()), {"outside": SECRET})

        local_path.write_bytes(b"{" + b"x" * POST_CREATE.AUTH_SYNC_MAX_BYTES + b"}")
        local_path.chmod(0o600)
        with redirect_stderr(captured):
            self.sync("Claude", "claude", "claude", ".credentials.json")
        self.assertEqual(json.loads(global_path.read_text()), trusted)
        self.assertEqual(json.loads(local_path.read_text()), trusted)
        self.assertNotIn(SECRET, captured.getvalue())

    def test_only_exact_credential_json_files_are_copied(self) -> None:
        claude_home = self.project_root / "tool-homes" / "claude"
        codex_home = self.project_root / "tool-homes" / "codex"
        opencode_home = self.project_root / "tool-homes" / "opencode-data"
        (claude_home / "settings.json").write_text('{"mcpServers":{"payload":{}}}')
        (claude_home / "CLAUDE.md").write_text("persistent prompt")
        (claude_home / "plugins").mkdir()
        (claude_home / "plugins" / "payload").write_text("plugin code")
        (codex_home / "config.toml").write_text('[mcp_servers.payload]\ncommand="payload"\n')
        (codex_home / "skills").mkdir()
        (codex_home / "skills" / "SKILL.md").write_text("skill prompt")
        (opencode_home / "storage").mkdir()
        (opencode_home / "storage" / "payload").write_text("session data")
        (opencode_home / "opencode.db").write_text("database contents")
        self.write_json(claude_home / ".credentials.json", {"token": "claude"})
        self.write_json(codex_home / "auth.json", {"token": "codex"})
        self.write_json(opencode_home / "auth.json", {"token": "opencode"})
        self.write_json(opencode_home / "account.json", {"account": "opencode"})

        self.sync("Claude", "claude", "claude", ".credentials.json")
        self.sync("Codex", "codex", "codex", "auth.json")
        self.sync("OpenCode", "opencode", "opencode-data", "auth.json")
        self.sync("OpenCode", "opencode", "opencode-data", "account.json")

        self.assertEqual(
            {path.name for path in (self.global_root / "claude").iterdir()},
            {".credentials.json", ".aic-auth-sync.lock"},
        )
        self.assertEqual(
            {path.name for path in (self.global_root / "codex").iterdir()},
            {"auth.json", ".aic-auth-sync.lock"},
        )
        self.assertEqual(
            {path.name for path in (self.global_root / "opencode").iterdir()},
            {"auth.json", "account.json", ".aic-auth-sync.lock"},
        )


def stat_mode(path: Path) -> int:
    return path.stat().st_mode & 0o777


if __name__ == "__main__":
    unittest.main()
