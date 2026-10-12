#!/usr/bin/env python3
"""The managed hook files: one list in aic, named in the Dockerfile.

aic copies only the files in AIC_HOOK_FILES (lib/aic/identity.sh) from
template/hooks/, and the Dockerfile copies only the same names into
/etc/aic/hooks/. These tests fail when the list, the Dockerfile COPY, and the
files that git tracks in template/hooks/ disagree.
"""

from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path


# -I ignores PYTHONDONTWRITEBYTECODE. Never write bytecode into template/.
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "template"
DOCKERFILE = (TEMPLATE / "Dockerfile").read_text()
HOOKS_DIR = "/etc/aic/hooks/"


def shell_constant(name: str) -> list[str]:
    """The words of a constant after bash sources lib/aic/identity.sh."""
    result = subprocess.run(
        ["bash", "-c", f'source "$1"; printf "%s" "${name}"', "_",
         str(ROOT / "lib" / "aic" / "identity.sh")],
        check=True, capture_output=True, text=True,
    )
    return result.stdout.split()


def dockerfile_instructions() -> list[str]:
    """Each Dockerfile instruction on one line, without comment lines."""
    joined: list[str] = []
    current = ""
    for line in DOCKERFILE.splitlines():
        if line.lstrip().startswith("#"):
            continue
        current += line.rstrip("\\").rstrip() + " "
        if not line.rstrip().endswith("\\"):
            joined.append(current.strip())
            current = ""
    return joined


HOOK_FILES = shell_constant("AIC_HOOK_FILES")


class HookListTests(unittest.TestCase):
    def test_list_is_well_formed(self) -> None:
        self.assertTrue(HOOK_FILES, "AIC_HOOK_FILES is empty")
        self.assertEqual(len(HOOK_FILES), len(set(HOOK_FILES)), "a hook is listed twice")
        for name in HOOK_FILES:
            self.assertRegex(name, r"\A[a-z][a-z-]*\.(py|json|js|sh)\Z")

    def test_list_equals_the_tracked_template_hooks(self) -> None:
        tracked = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "--", "template/hooks"],
            check=True, capture_output=True, text=True,
        ).stdout.split()
        self.assertTrue(tracked, "git tracks no files in template/hooks")
        self.assertEqual(sorted(Path(p).name for p in tracked), sorted(HOOK_FILES))
        for path in tracked:
            self.assertEqual(Path(path).parent.as_posix(), "template/hooks", "no subdirectories")
            full = ROOT / path
            self.assertTrue(full.is_file() and not full.is_symlink(), path)

    def test_dockerfile_copies_exactly_the_listed_hooks(self) -> None:
        copies = [
            i for i in dockerfile_instructions()
            if re.match(r"(COPY|ADD)\s", i) and ("hooks/" in i)
        ]
        self.assertEqual(len(copies), 1, copies)
        words = copies[0].split()
        self.assertEqual(words[0], "COPY", "use COPY, never ADD, for the hooks")
        self.assertFalse([w for w in words if w.startswith("--")], "no COPY flags")
        self.assertEqual(words[-1], HOOKS_DIR)
        self.assertEqual(words[1:-1], [f"hooks/{name}" for name in HOOK_FILES],
                         "keep the COPY list equal to AIC_HOOK_FILES")


if __name__ == "__main__":
    unittest.main()
