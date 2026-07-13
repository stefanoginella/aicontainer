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
    "aic_lock_gitconfig", str(ROOT / "template" / "aic-lock-gitconfig")
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
    def validate(self, content: str) -> None:
        with tempfile.NamedTemporaryFile() as config:
            config.write(content.encode())
            config.flush()
            fd = os.open(config.name, os.O_RDONLY)
            try:
                LOCK.validate_config_contents(fd)
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


if __name__ == "__main__":
    unittest.main()
