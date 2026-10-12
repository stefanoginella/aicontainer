#!/usr/bin/env python3
from __future__ import annotations

import importlib
import importlib.machinery
import importlib.util
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
# -I ignores PYTHONDONTWRITEBYTECODE. Never write bytecode into template/.
sys.dont_write_bytecode = True
LOADER = importlib.machinery.SourceFileLoader(
    "aic_lock_user_config", str(ROOT / "template" / "aic-lock-user-config")
)
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
LOCK = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(LOCK)

# Load the post-create modules as the aic_post_create package, as in the image
# (/opt/aic-post-create/aic_post_create/), to check the generated config
# against the validator.
PACKAGE = types.ModuleType("aic_post_create")
PACKAGE.__path__ = [str(ROOT / "template")]
sys.modules["aic_post_create"] = PACKAGE
GIT = importlib.import_module("aic_post_create.post_create_git")
SEEDS = importlib.import_module("aic_post_create.post_create_seeds")

# The exact managed GitHub credential helper block. Pinned here as text, so a
# change to the helper in either file fails this test.
GH_HELPER_BLOCK = """\
[credential "https://github.com"]
    helper =
    helper = !/usr/bin/gh auth git-credential
[credential "https://gist.github.com"]
    helper =
    helper = !/usr/bin/gh auth git-credential
"""

SAFE_CONFIG = """\
[user]
    name = Test User
    email = test@example.com
[core]
    excludesfile = /etc/aic/gitignore
    pager = delta
[interactive]
    diffFilter = delta --color-only
[delta]
    navigate = true
    line-numbers = true
[merge]
    conflictStyle = diff3
[diff]
    colorMoved = default
""" + GH_HELPER_BLOCK


class GitConfigValidationTests(unittest.TestCase):
    """The validated gitconfig target keeps the exact former allowlist."""

    def validate(self, content: str) -> None:
        with tempfile.NamedTemporaryFile() as config:
            config.write(content.encode())
            config.flush()
            fd = os.open(config.name, os.O_RDONLY)
            try:
                LOCK.validate_gitconfig_contents(fd)
            finally:
                os.close(fd)

    def test_accepts_generated_safe_contract(self) -> None:
        self.validate(SAFE_CONFIG)

    def test_rejects_command_bearing_key(self) -> None:
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.validate(SAFE_CONFIG + "[alias]\n    escape = !id\n")

    def test_rejects_replacement_pager_command(self) -> None:
        malicious = SAFE_CONFIG.replace("pager = delta", "pager = sh -c id")
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.validate(malicious)

    def test_requires_aic_owned_values(self) -> None:
        incomplete = SAFE_CONFIG.replace("    excludesfile = /etc/aic/gitignore\n", "")
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.validate(incomplete)


class GitHubCredentialHelperTests(unittest.TestCase):
    """Only aic's exact gh credential helper block passes. Every host or
    agent credential.* / url.* key, and every changed helper, is refused."""

    def validate(self, content: str) -> None:
        GitConfigValidationTests.validate(self, content)  # type: ignore[arg-type]

    def assert_rejected(self, content: str) -> None:
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.validate(content)

    def test_accepts_exact_managed_helper_block(self) -> None:
        self.assertIn(GH_HELPER_BLOCK, SAFE_CONFIG)
        self.validate(SAFE_CONFIG)

    def test_contract_names_absolute_root_owned_gh(self) -> None:
        self.assertEqual(LOCK.GH_CREDENTIAL_HELPER, "!/usr/bin/gh auth git-credential")
        self.assertEqual(
            LOCK.REQUIRED_EXACT_VALUE_LISTS,
            {
                "credential.https://github.com.helper": ("", LOCK.GH_CREDENTIAL_HELPER),
                "credential.https://gist.github.com.helper": ("", LOCK.GH_CREDENTIAL_HELPER),
            },
        )

    def test_requires_both_helper_blocks(self) -> None:
        without = SAFE_CONFIG.replace(GH_HELPER_BLOCK, "")
        self.assert_rejected(without)
        for url in ("https://github.com", "https://gist.github.com"):
            one = SAFE_CONFIG.replace(
                f'[credential "{url}"]\n    helper =\n'
                "    helper = !/usr/bin/gh auth git-credential\n",
                "",
            )
            self.assertNotEqual(one, SAFE_CONFIG)
            self.assert_rejected(one)

    def test_rejects_host_generic_credential_helper(self) -> None:
        for helper in ("store", "osxkeychain", "!/usr/bin/gh auth git-credential"):
            self.assert_rejected(SAFE_CONFIG + f"[credential]\n    helper = {helper}\n")

    def test_rejects_other_helper_values(self) -> None:
        for helper in (
            "!gh auth git-credential",              # relative: PATH has ~/.local/bin first
            "!./gh auth git-credential",
            "!/usr/local/bin/gh auth git-credential",
            "!/home/vscode/.local/bin/gh auth git-credential",
            # Quoted, so Git keeps the `;` and the space. (Unquoted, Git drops
            # a `; comment` and trailing spaces, and the parsed value is exact.)
            '"!/usr/bin/gh auth git-credential; id"',
            '"!/usr/bin/gh auth git-credential "',
            '"!/usr/bin/gh auth git-credential --hostname attacker.example"',
            "store",
            "/usr/bin/gh",
        ):
            changed = SAFE_CONFIG.replace(
                "    helper = !/usr/bin/gh auth git-credential\n",
                f"    helper = {helper}\n",
                1,
            )
            self.assertNotEqual(changed, SAFE_CONFIG)
            self.assert_rejected(changed)

    def test_rejects_value_before_or_after_the_managed_list(self) -> None:
        # A host value appended after the gh helper would win; one before the
        # reset is harmless to Git but still not the exact list.
        self.assert_rejected(
            SAFE_CONFIG + '[credential "https://github.com"]\n    helper = store\n'
        )
        self.assert_rejected(
            '[credential "https://github.com"]\n    helper = store\n' + SAFE_CONFIG
        )
        # A second copy of the reset after the helper turns gh off again.
        self.assert_rejected(SAFE_CONFIG + '[credential "https://github.com"]\n    helper =\n')
        # Without the reset, helpers from an earlier scope also answer.
        self.assert_rejected(
            SAFE_CONFIG.replace('[credential "https://github.com"]\n    helper =\n',
                                '[credential "https://github.com"]\n', 1)
        )

    def test_rejects_helper_for_another_url(self) -> None:
        for url in (
            "https://gitlab.com",
            "https://github.example.com",
            "https://github.com/",
            "https://github.com/owner/repo",
            "http://github.com",
            "https://*.github.com",
        ):
            self.assert_rejected(
                SAFE_CONFIG + f'[credential "{url}"]\n    helper =\n'
                "    helper = !/usr/bin/gh auth git-credential\n"
            )

    def test_rejects_case_variant_subsection(self) -> None:
        variant = SAFE_CONFIG.replace('[credential "https://github.com"]',
                                      '[credential "https://GitHub.com"]', 1)
        self.assert_rejected(variant)
        self.assert_rejected(
            SAFE_CONFIG + '[credential "https://GitHub.com"]\n    helper =\n'
            "    helper = !/usr/bin/gh auth git-credential\n"
        )

    def test_rejects_other_credential_and_url_keys(self) -> None:
        for extra in (
            '[credential "https://github.com"]\n    username = attacker\n',
            '[credential "https://github.com"]\n    useHttpPath = true\n',
            "[credential]\n    username = attacker\n",
            '[url "https://attacker.example/"]\n    insteadOf = https://github.com/\n',
        ):
            self.assert_rejected(SAFE_CONFIG + extra)

    def test_rejects_valueless_helper(self) -> None:
        # `helper` with no `=` is Git's boolean true, not the empty reset.
        self.assert_rejected(
            SAFE_CONFIG.replace('[credential "https://github.com"]\n    helper =\n',
                                '[credential "https://github.com"]\n    helper\n', 1)
        )


class GeneratedGitConfigTests(unittest.TestCase):
    """post-create's real staged config passes the validator, and a host
    credential helper never reaches it."""

    def test_post_create_helper_matches_validator(self) -> None:
        self.assertEqual(GIT.GH_CREDENTIAL_HELPER, LOCK.GH_CREDENTIAL_HELPER)
        self.assertEqual(GIT.GH_CREDENTIAL_CONFIG, GH_HELPER_BLOCK)

    def test_staged_config_from_hostile_host_seed_validates(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            raw = root / "raw"
            raw.mkdir()
            (raw / "gitconfig").write_text(
                "[user]\n    name = Host User\n    email = host@example.com\n"
                "[credential]\n    helper = store\n"
                '[credential "https://github.com"]\n    helper = !evil\n'
                '[url "https://attacker.example/"]\n    insteadOf = https://github.com/\n'
            )
            seed = root / "git.json"
            staging = root / ".aic-gitconfig.staging"
            patches = (
                mock.patch.object(SEEDS, "RAW_HOST_SEED", raw),
                mock.patch.object(GIT, "HOST_SEED_GIT", seed),
                mock.patch.object(GIT, "GITCONFIG_STAGING", staging),
                mock.patch.object(GIT, "GITCONFIG_MANAGED", root / "managed" / "gitconfig"),
                mock.patch.object(GIT, "SIGNING_KEY", root / "signing" / "id_ed25519"),
                mock.patch.object(GIT, "SIGNING_MODE", root / "signing" / "mode"),
            )
            for patch in patches:
                patch.start()
                self.addCleanup(patch.stop)
            with redirect_stderr(io.StringIO()):
                sanitized = SEEDS._sanitize_git_seed()
                self.assertFalse(any(k.startswith(("credential", "url")) for k in sanitized))
                seed.write_text(json.dumps(sanitized))
                GIT.setup_gitconfig()
            text = staging.read_text()
            self.assertTrue(text.endswith(GH_HELPER_BLOCK), text)
            self.assertNotIn("store", text)
            self.assertNotIn("evil", text)
            self.assertNotIn("attacker", text)
            GitConfigValidationTests.validate(self, text)  # type: ignore[arg-type]


class TargetTableContractTests(unittest.TestCase):
    """Guard the install table's security-relevant shape.

    The personal shell targets are installed *without* content validation (zsh
    can't be allowlisted), so their safety rests entirely on: staying inside the
    root-owned /etc/aic/user-config/shell dir, being optional, and — like every
    target — riding the shared create-once/root-locked install path. These
    assertions fail loudly if a future edit relaxes any of that.
    """

    def by_dest(self):
        return {(t.dest_dir.as_posix(), t.dest_name): t for t in LOCK.TARGETS}

    def test_gitconfig_is_required_and_validated(self) -> None:
        t = self.by_dest()[("/etc/aic/user-config", "gitconfig")]
        self.assertTrue(t.required)
        self.assertIs(t.validator, LOCK.validate_gitconfig_contents)
        self.assertEqual(t.staging.as_posix(), "/home/vscode/.aic-gitconfig.staging")

    def test_personal_shell_targets_are_optional_unvalidated_and_scoped(self) -> None:
        table = self.by_dest()
        for dest_name, staging in (
            ("rc.zsh", "/home/vscode/.aic-shell-rc.staging"),
            ("p10k.zsh", "/home/vscode/.aic-p10k.staging"),
        ):
            t = table[("/etc/aic/user-config/shell", dest_name)]
            self.assertFalse(t.required, f"{dest_name} must be optional")
            self.assertIsNone(t.validator, f"{dest_name} must have no content validator")
            self.assertEqual(t.staging.as_posix(), staging)

    def test_statusline_targets_are_optional_unvalidated_and_scoped(self) -> None:
        """The statusline slot is a FIXED per-extension table, not a discovered
        set: the destination filename is what tells /usr/local/bin/aic-statusline
        which interpreter to use, so a new extension must be added deliberately
        here (and to the launcher) rather than inferred at runtime."""
        table = self.by_dest()
        for dest_name, staging in (
            ("statusline.sh", "/home/vscode/.aic-statusline-sh.staging"),
            ("statusline.mjs", "/home/vscode/.aic-statusline-mjs.staging"),
            ("statusline.js", "/home/vscode/.aic-statusline-js.staging"),
            ("statusline.py", "/home/vscode/.aic-statusline-py.staging"),
        ):
            t = table[("/etc/aic/user-config/statusline", dest_name)]
            self.assertFalse(t.required, f"{dest_name} must be optional")
            self.assertIsNone(t.validator, f"{dest_name} must have no content validator")
            self.assertEqual(t.staging.as_posix(), staging)

    def test_staging_paths_are_unique_hardcoded_home_files(self) -> None:
        """Two targets sharing a staging path would let one overlay's bytes land
        at another's destination."""
        staging = [t.staging.as_posix() for t in LOCK.TARGETS]
        self.assertEqual(len(staging), len(set(staging)), "duplicate staging path")
        for path in staging:
            self.assertTrue(path.startswith("/home/vscode/."), path)

    def test_every_destination_is_under_the_root_owned_user_config_dir(self) -> None:
        for t in LOCK.TARGETS:
            self.assertTrue(
                t.dest_dir.as_posix().startswith("/etc/aic/user-config"),
                f"{t.dest_name} escapes the managed root-owned config dir",
            )

    def test_optional_absent_staging_is_skipped_not_fatal(self) -> None:
        # An optional target whose staging file does not exist returns None
        # (skipped); only a REQUIRED target's absence is fatal. The staging
        # PARENT must exist (it is exact-realpath checked), only the file is
        # absent — so anchor on a real, symlink-resolved temp dir.
        vscode_uid = os.getuid()
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp).resolve(strict=True)
            missing = parent / ".aic-absent.staging"

            optional = LOCK.Target(
                missing, Path("/etc/aic/user-config/shell"), "rc.zsh",
                required=False, validator=None,
            )
            with redirect_stderr(io.StringIO()):
                self.assertIsNone(LOCK.open_validated_source(optional, vscode_uid))

            required = LOCK.Target(
                missing, Path("/etc/aic/user-config"), "gitconfig",
                required=True, validator=LOCK.validate_gitconfig_contents,
            )
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                LOCK.open_validated_source(required, vscode_uid)


if __name__ == "__main__":
    unittest.main()
