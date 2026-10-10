#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import tempfile
import time
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

    def test_gh_and_npm_homes_are_private_and_project_local(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            with (
                mock.patch.object(POST_CREATE, "GH_HOME", root / "gh"),
                mock.patch.object(POST_CREATE, "NPM_HOME", root / "npm"),
            ):
                POST_CREATE.setup_cli_homes()
            for name in ("gh", "npm"):
                self.assertTrue((root / name).is_dir(), name)
                self.assertEqual(stat_mode(root / name), 0o700, name)
        self.assertEqual(POST_CREATE.GH_HOME, POST_CREATE.TOOL_HOMES / "gh")
        self.assertEqual(POST_CREATE.NPM_HOME, POST_CREATE.TOOL_HOMES / "npm")


class SyncFixture(unittest.TestCase):
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
        for name in ("gh", "npm"):
            (self.global_root / name).mkdir(mode=0o700)
            (self.project_root / "tool-homes" / name).mkdir(mode=0o700)
        POST_CREATE.AUTH_SYNC_GLOBAL = self.global_root
        POST_CREATE.AUTH_SYNC_PROJECT = self.project_root
        # Tests write files and sync at once; one test covers the settle delay.
        POST_CREATE.AUTH_SYNC_SETTLE_NS = 0
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
        SyncFixture.write_json(temp, value)
        temp.replace(path)

    def sync(
        self, tool: str, global_dir: str, local_dir: str, filename: str, fmt: str = "json"
    ) -> None:
        POST_CREATE._sync_credential_pair(
            tool, global_dir, local_dir, filename, fmt, self.states
        )


class AuthSyncTests(SyncFixture):
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


NPM_SETTINGS = (
    "registry=https://registry.evil.example/\n"
    "@corp:registry=https://registry.evil.example/\n"
    "script-shell=/workspace/payload.sh\n"
    "node-options=--require /workspace/payload.js\n"
    "git=/workspace/payload-git\n"
    "prefix=/workspace/payload-prefix\n"
)
GH_HOSTS_WITH_SETTINGS = f"""github.com:
    users:
        octocat:
            oauth_token: gho_{SECRET}
            pager: /workspace/payload.sh
    git_protocol: https
    oauth_token: gho_{SECRET}
    user: octocat
    pager: /workspace/payload.sh
    editor: /workspace/payload.sh
    browser: /workspace/payload.sh
    http_unix_socket: /workspace/payload.sock
    api_host: api.evil.example
ghe.example.com:
    git_protocol: ssh
    editor: /workspace/payload.sh
"""
GH_CONFIG_WITH_ALIASES = "aliases:\n    co: '!/workspace/payload.sh'\npager: /workspace/payload.sh\n"


class LoginEntrySyncTests(SyncFixture):
    """gh hosts.yml and npm npmrc: only login entries cross projects."""

    def gh(self) -> None:
        self.sync("GitHub CLI", "gh", "gh", "hosts.yml", "gh-hosts")

    def npm(self) -> None:
        self.sync("npm", "npm", "npm", "npmrc", "npmrc")

    def switch_project(self, name: str) -> Path:
        """Point the sidecar at another project's sessions volume."""
        root = self.root / name
        for tool_home in ("gh", "npm"):
            (root / "tool-homes" / tool_home).mkdir(parents=True, mode=0o700)
        POST_CREATE.AUTH_SYNC_PROJECT = root
        self.states = {}
        return root / "tool-homes"

    @staticmethod
    def write(path: Path, text: str) -> None:
        path.write_text(text)
        path.chmod(0o600)

    def test_spec_list_is_exact(self) -> None:
        self.assertEqual(
            {(spec[1], spec[3], spec[4]) for spec in POST_CREATE.AUTH_SYNC_SPECS},
            {
                ("claude", ".credentials.json", "json"),
                ("codex", "auth.json", "json"),
                ("opencode", "auth.json", "json"),
                ("opencode", "account.json", "json"),
                ("gh", "hosts.yml", "gh-hosts"),
                ("npm", "npmrc", "npmrc"),
            },
        )

    def test_npm_settings_never_leave_the_project(self) -> None:
        project_a = self.project_root / "tool-homes" / "npm" / "npmrc"
        self.write(
            project_a,
            NPM_SETTINGS
            + "//registry.npmjs.org/:_authToken=npm_project_a\n"
            + "//env.example/:_authToken=${GITHUB_TOKEN}\n"
            + "//quoted.example/:_authToken='npm_single_quoted'\n"
            + "//pkgs.example/npm/:_password=\"cGFzcw==\"\n"
            + "//pkgs.example/npm/:username=bob\n"
            + "//pkgs.example/npm/:certfile=/workspace/cert.pem\n"
            + "_authToken=npm_legacy_default_registry\n"
            + "[section]\n//section.example/:_authToken=npm_in_section\n",
        )
        self.npm()

        global_npmrc = (self.global_root / "npm" / "npmrc").read_text()
        self.assertEqual(
            global_npmrc,
            '//pkgs.example/npm/:_password="cGFzcw=="\n'
            "//pkgs.example/npm/:username=bob\n"
            "//registry.npmjs.org/:_authToken=npm_project_a\n",
        )
        self.assertEqual(stat_mode(self.global_root / "npm" / "npmrc"), 0o600)

        project_b = self.switch_project("project-b") / "npm" / "npmrc"
        self.write(project_b, "fund=false\n//registry.npmjs.org/:_authToken=npm_stale\n")
        os.utime(project_b, ns=(1_000_000_000, 1_000_000_000))
        self.npm()
        self.assertEqual(
            project_b.read_text(),
            global_npmrc + "fund=false\n",
            "project B keeps its own settings and gets only the login lines",
        )
        self.assertEqual(stat_mode(project_b), 0o600)

    def test_npm_login_update_and_logout_keep_project_settings(self) -> None:
        npmrc = self.project_root / "tool-homes" / "npm" / "npmrc"
        global_npmrc = self.global_root / "npm" / "npmrc"
        self.write(npmrc, "fund=false\n")
        self.npm()
        self.assertFalse(global_npmrc.exists(), "settings alone are not a login")

        self.write(npmrc, "fund=false\n//registry.npmjs.org/:_authToken=npm_one\n")
        self.npm()
        self.assertEqual(global_npmrc.read_text(), "//registry.npmjs.org/:_authToken=npm_one\n")

        # Only settings change: nothing to synchronize.
        self.write(npmrc, "fund=false\ncolor=false\n//registry.npmjs.org/:_authToken=npm_one\n")
        self.npm()
        self.assertEqual(global_npmrc.read_text(), "//registry.npmjs.org/:_authToken=npm_one\n")

        # Login in another project arrives here without touching settings.
        self.write(global_npmrc, "//registry.npmjs.org/:_authToken=npm_two\n")
        self.npm()
        self.assertEqual(
            npmrc.read_text(),
            "//registry.npmjs.org/:_authToken=npm_two\nfund=false\ncolor=false\n",
        )

        # Logout in another project removes only the login lines here.
        global_npmrc.unlink()
        self.npm()
        self.assertEqual(npmrc.read_text(), "fund=false\ncolor=false\n")

        # Logout here (npm deletes an emptied npmrc) reaches the global copy.
        self.write(npmrc, "//registry.npmjs.org/:_authToken=npm_three\n")
        self.npm()
        self.assertTrue(global_npmrc.exists())
        npmrc.unlink()
        self.npm()
        self.assertFalse(global_npmrc.exists(), "an observed project logout must propagate")

    def test_gh_shares_only_tokens_users_and_git_protocol(self) -> None:
        project_a = self.project_root / "tool-homes" / "gh"
        self.write(project_a / "hosts.yml", GH_HOSTS_WITH_SETTINGS)
        self.write(project_a / "config.yml", GH_CONFIG_WITH_ALIASES)
        captured = io.StringIO()
        with redirect_stderr(captured):
            self.gh()

        canonical = (
            '"github.com":\n'
            '    git_protocol: "https"\n'
            f'    oauth_token: "gho_{SECRET}"\n'
            '    user: "octocat"\n'
            "    users:\n"
            '        "octocat":\n'
            f'            oauth_token: "gho_{SECRET}"\n'
        )
        self.assertEqual((self.global_root / "gh" / "hosts.yml").read_text(), canonical)
        self.assertEqual(
            {path.name for path in (self.global_root / "gh").iterdir()},
            {"hosts.yml", ".aic-auth-sync.lock"},
        )

        project_b = self.switch_project("project-b") / "gh"
        with redirect_stderr(captured):
            self.gh()
        self.assertEqual((project_b / "hosts.yml").read_text(), canonical)
        self.assertFalse((project_b / "config.yml").exists())
        self.assertEqual(stat_mode(project_b / "hosts.yml"), 0o600)
        self.assertNotIn(SECRET, captured.getvalue())

    def test_gh_logout_and_account_switch_propagate(self) -> None:
        hosts = self.project_root / "tool-homes" / "gh" / "hosts.yml"
        global_hosts = self.global_root / "gh" / "hosts.yml"
        self.write(hosts, "github.com:\n    oauth_token: gho_one\n    user: octocat\n")
        self.gh()
        self.assertIn('oauth_token: "gho_one"', global_hosts.read_text())

        self.write(global_hosts, 'github.com:\n    oauth_token: "gho_two"\n    user: "hubot"\n')
        self.gh()
        self.assertIn('oauth_token: "gho_two"', hosts.read_text())
        self.assertIn('user: "hubot"', hosts.read_text())

        # gh writes "{}" after the last logout.
        self.write(hosts, "{}\n")
        self.gh()
        self.assertFalse(global_hosts.exists(), "an observed project logout must propagate")

    def test_unreadable_project_files_are_never_overwritten(self) -> None:
        global_hosts = self.global_root / "gh" / "hosts.yml"
        trusted = 'github.com:\n    oauth_token: "gho_trusted"\n'
        self.write(global_hosts, trusted)
        hosts = self.project_root / "tool-homes" / "gh" / "hosts.yml"
        unreadable = "github.com:\n    oauth_token: gho_x\n  - list item\n"
        self.write(hosts, unreadable)
        npmrc = self.project_root / "tool-homes" / "npm" / "npmrc"
        npmrc.write_bytes(b"fund=false\n\xff\xfe\n")
        npmrc.chmod(0o600)
        self.write(self.global_root / "npm" / "npmrc", "//r.example/:_authToken=npm_trusted\n")

        captured = io.StringIO()
        with redirect_stderr(captured):
            for _cycle in range(2):
                self.gh()
                self.npm()
        self.assertEqual(hosts.read_text(), unreadable)
        self.assertEqual(npmrc.read_bytes(), b"fund=false\n\xff\xfe\n")
        self.assertEqual(global_hosts.read_text(), trusted)

        outside = self.root / "outside"
        self.write(outside, "github.com:\n    oauth_token: gho_outside\n")
        hosts.unlink()
        hosts.symlink_to(outside)
        with redirect_stderr(captured):
            self.gh()
        self.assertTrue(hosts.is_symlink())
        self.assertEqual(global_hosts.read_text(), trusted)
        self.assertEqual(outside.read_text(), "github.com:\n    oauth_token: gho_outside\n")

    def test_yaml_features_gh_does_not_write_are_refused(self) -> None:
        for text in (
            "github.com:\n  - oauth_token: gho_x\n",
            "github.com: {oauth_token: gho_x}\n",
            "github.com:\n    pager: |\n        oauth_token: gho_x\n",
            "github.com:\n\toauth_token: gho_x\n",
            "github.com:\n    oauth_token: gho_x\n    oauth_token: gho_y\n",
            "github.com:\n    oauth_token: &a gho_x\n",
            "github.com:\n      user: a\n    oauth_token: gho_x\n",
            "evil host:\n    oauth_token: gho_x\n",
        ):
            with self.subTest(text=text):
                self.assertIsNone(POST_CREATE._canonical_login("gh-hosts", text.encode()))
        # Values outside the strict grammars are dropped, never passed through.
        for text in (
            "github.com:\n    oauth_token: gho x\n    user: a\n",
            "github.com:\n    oauth_token: gho_x # note\n    user: a\n",
            "github.com:\n    oauth_token: '${GH_TOKEN}'\n",
            "evil..host/x:\n    oauth_token: gho_x\n",
        ):
            with self.subTest(text=text):
                self.assertEqual(POST_CREATE._canonical_login("gh-hosts", text.encode()), b"")

    def test_half_written_files_wait_until_settled(self) -> None:
        POST_CREATE.AUTH_SYNC_SETTLE_NS = 2_000_000_000
        npmrc = self.project_root / "tool-homes" / "npm" / "npmrc"
        global_npmrc = self.global_root / "npm" / "npmrc"
        old = time.time_ns() - 10_000_000_000

        self.write(npmrc, "//registry.npmjs.org/:_authToken=npm_one\n")
        self.npm()
        self.assertFalse(global_npmrc.exists(), "a file written just now is not read yet")
        os.utime(npmrc, ns=(old, old))
        self.npm()
        self.assertEqual(global_npmrc.read_text(), "//registry.npmjs.org/:_authToken=npm_one\n")
        os.utime(global_npmrc, ns=(old, old))

        # npm truncates before it writes: a fresh empty file is not a logout,
        # and a cut-off token line does not reach other projects.
        self.write(npmrc, "")
        self.npm()
        self.write(npmrc, "//registry.npmjs.org/:_authToken=npm_t")
        self.npm()
        self.assertEqual(global_npmrc.read_text(), "//registry.npmjs.org/:_authToken=npm_one\n")


def stat_mode(path: Path) -> int:
    return path.stat().st_mode & 0o777


if __name__ == "__main__":
    unittest.main()
