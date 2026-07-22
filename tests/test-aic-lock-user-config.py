#!/usr/bin/env python3
from __future__ import annotations

import importlib.machinery
import importlib.util
import io
import os
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
LOADER = importlib.machinery.SourceFileLoader(
    "aic_lock_user_config", str(ROOT / "template" / "aic-lock-user-config")
)
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
LOCK = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(LOCK)

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
"""


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
