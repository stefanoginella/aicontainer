#!/usr/bin/env python3
"""The post-create modules: one list, one package, one import path.

post-create.py is the fixed entry point. Its code is in the aic_post_create
package. aic copies the modules flat into .devcontainer/ (build mode), and the
image installs them root-owned and read-only in
/opt/aic-post-create/aic_post_create/. These tests fail when:

- AIC_POST_CREATE_MODULES (lib/aic/identity.sh), the Dockerfile COPY list, and
  the post_create_*.py files in template/ disagree;
- aic names a module anywhere but in that one list;
- a module imports a module that is not in the list, or a listed module is
  never imported;
- the entry imports the package from any place but its fixed directory, lets a
  module shadow the standard library, or writes bytecode.
"""

from __future__ import annotations

import ast
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "template"
ENTRY = TEMPLATE / "post-create.py"
DOCKERFILE = (TEMPLATE / "Dockerfile").read_text()
PACKAGE = "aic_post_create"
PACKAGE_PARENT = "/opt/aic-post-create"
PACKAGE_DIR = f"{PACKAGE_PARENT}/{PACKAGE}/"


def shell_constant(name: str) -> list[str]:
    """The words of a constant after bash sources lib/aic/identity.sh."""
    result = subprocess.run(
        ["bash", "-c", f'source "$1"; printf "%s" "${name}"', "_",
         str(ROOT / "lib" / "aic" / "identity.sh")],
        check=True, capture_output=True, text=True,
    )
    return result.stdout.split()


MODULES = shell_constant("AIC_POST_CREATE_MODULES")
STEMS = [name.removesuffix(".py") for name in MODULES]


def dockerfile_instructions() -> list[str]:
    """Each Dockerfile instruction on one line, without comment lines."""
    joined: list[str] = []
    current = ""
    for line in DOCKERFILE.splitlines():
        if not current and line.lstrip().startswith("#"):
            continue
        if current and line.lstrip().startswith("#"):
            continue  # a comment line inside a continued instruction
        current += line.rstrip("\\").rstrip() + " "
        if not line.rstrip().endswith("\\"):
            joined.append(current.strip())
            current = ""
    return joined


def defined_names(tree: ast.Module) -> set[str]:
    names: set[str] = set()
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.ClassDef)):
            names.add(node.name)
        elif isinstance(node, ast.Assign):
            names.update(t.id for t in node.targets if isinstance(t, ast.Name))
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names.add(node.target.id)
    return names


class ModuleListTests(unittest.TestCase):
    def test_list_is_well_formed(self) -> None:
        self.assertTrue(MODULES, "AIC_POST_CREATE_MODULES is empty")
        self.assertEqual(len(MODULES), len(set(MODULES)), "a module is listed twice")
        for name in MODULES:
            self.assertRegex(name, r"\Apost_create_[a-z_]+\.py\Z")

    def test_template_holds_exactly_the_listed_modules(self) -> None:
        # Every Python file at the template root is the entry or a listed module.
        self.assertEqual(
            sorted(p.name for p in TEMPLATE.glob("*.py")),
            sorted(["post-create.py", *MODULES]),
        )
        for name in MODULES:
            path = TEMPLATE / name
            self.assertTrue(path.is_file() and not path.is_symlink(), name)

    def test_dockerfile_copies_exactly_the_listed_modules(self) -> None:
        into_package = [
            i for i in dockerfile_instructions()
            if re.match(r"(COPY|ADD)\s", i) and PACKAGE_PARENT in i
        ]
        self.assertEqual(len(into_package), 1, into_package)
        words = into_package[0].split()
        self.assertEqual(words[0], "COPY", "use COPY, never ADD, for the package")
        self.assertFalse([w for w in words if w.startswith("--")], "no COPY flags")
        self.assertEqual(words[-1], PACKAGE_DIR)
        sources = words[1:-1]
        self.assertEqual(sources, MODULES, "keep the COPY list equal to AIC_POST_CREATE_MODULES")
        for source in sources:
            self.assertNotRegex(source, r"[*?\[\]/]", "name each file; never a glob or a path")

    def test_dockerfile_locks_the_package_root_owned_and_read_only(self) -> None:
        run = next(
            (i for i in dockerfile_instructions()
             if i.startswith("RUN ") and f"{PACKAGE_DIR}__init__.py" in i),
            None,
        )
        self.assertIsNotNone(run, "no RUN creates the package __init__.py")
        assert run is not None
        self.assertIn(f": > {PACKAGE_DIR}__init__.py", run)
        self.assertRegex(run, rf"chown -R root:root [^&]*{re.escape(PACKAGE_PARENT)}(\s|$)")
        self.assertIn(f"find {PACKAGE_PARENT} -type d -exec chmod 0555 {{}} +", run)
        self.assertIn(f"find {PACKAGE_PARENT} -type f -exec chmod 0444 {{}} +", run)
        # The chmods run after the chown and after the __init__.py is created.
        self.assertLess(run.index(f": > {PACKAGE_DIR}"), run.index("-type f -exec chmod 0444"))
        self.assertLess(run.index("chown -R root:root"), run.index("-type d -exec chmod 0555"))

    def test_aic_names_the_modules_only_in_the_one_list(self) -> None:
        control = shell_constant("AIC_CONTROL_FILES")
        for name in MODULES:
            self.assertIn(name, control, f"{name} must be symlink-checked by the host CLI")
        for path in [ROOT / "aic", *sorted((ROOT / "lib" / "aic").glob("*.sh"))]:
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if line.lstrip().startswith("#") or "post_create_" not in line:
                    continue
                self.assertTrue(
                    path.name == "identity.sh" and line.startswith("AIC_POST_CREATE_MODULES="),
                    f"{path.name}:{number} names a post-create module; use $AIC_POST_CREATE_MODULES",
                )
        template_sh = (ROOT / "lib" / "aic" / "template.sh").read_text()
        self.assertIn('for name in $AIC_POST_CREATE_MODULES; do\n        rm -f "$dst/$name"', template_sh)
        self.assertIn(
            'for name in $AIC_POST_CREATE_MODULES; do\n        atomic_copy_file "$src/$name" "$dst/$name"',
            template_sh,
        )
        validation_sh = (ROOT / "lib" / "aic" / "validation.sh").read_text()
        self.assertRegex(validation_sh, r"for name in Dockerfile post-create\.py \$AIC_POST_CREATE_MODULES ")


class ImportGraphTests(unittest.TestCase):
    def setUp(self) -> None:
        self.trees = {stem: ast.parse((TEMPLATE / f"{stem}.py").read_text()) for stem in STEMS}
        self.entry = ast.parse(ENTRY.read_text())

    def test_modules_import_only_listed_modules_and_existing_names(self) -> None:
        for stem, tree in self.trees.items():
            for node in ast.walk(tree):
                if isinstance(node, ast.ImportFrom) and node.level:
                    self.assertEqual(node.level, 1, f"{stem}: use a one-dot relative import")
                    self.assertIn(node.module, STEMS, f"{stem} imports unlisted .{node.module}")
                    provided = defined_names(self.trees[node.module])
                    for alias in node.names:
                        self.assertIn(alias.name, provided, f"{stem}: .{node.module}.{alias.name}")

    def test_modules_import_only_the_standard_library(self) -> None:
        # tomli_w is the one baked dependency (/opt/aic-python), imported lazily.
        allowed = set(sys.stdlib_module_names) | {"tomli_w"}
        for stem, tree in self.trees.items():
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    roots = [alias.name.split(".")[0] for alias in node.names]
                elif isinstance(node, ast.ImportFrom) and not node.level:
                    roots = [(node.module or "").split(".")[0]]
                else:
                    continue
                for root in roots:
                    self.assertIn(root, allowed, f"{stem} imports {root}")

    def test_every_listed_module_is_reachable_from_the_entry(self) -> None:
        reached: set[str] = set()
        todo: list[str] = []
        for node in ast.walk(self.entry):
            if isinstance(node, ast.ImportFrom) and (node.module or "").startswith(f"{PACKAGE}."):
                stem = node.module.removeprefix(f"{PACKAGE}.")
                self.assertIn(stem, STEMS, f"the entry imports unlisted {stem}")
                todo.append(stem)
        while todo:
            stem = todo.pop()
            if stem in reached:
                continue
            reached.add(stem)
            todo.extend(
                node.module for node in ast.walk(self.trees[stem])
                if isinstance(node, ast.ImportFrom) and node.level
            )
        self.assertEqual(sorted(reached), sorted(STEMS), "a listed module is never imported")


class EntryTests(unittest.TestCase):
    """Run the real entry against a copy of the image layout."""

    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.parent = self.root / "opt" / "aic-post-create"
        self.package = self.parent / PACKAGE
        self.package.mkdir(parents=True)
        for name in MODULES:
            shutil.copyfile(TEMPLATE / name, self.package / name)
        (self.package / "__init__.py").write_text("")
        text = ENTRY.read_text()
        line = f'PACKAGE_PARENT = "{PACKAGE_PARENT}"\n'
        self.assertEqual(text.count(line), 1, "the entry has no fixed PACKAGE_PARENT")
        self.entry = self.root / "opt" / "post-create.py"
        self.entry.write_text(text.replace(line, f'PACKAGE_PARENT = "{self.parent}"\n'))
        self.cwd = self.root / "work"
        self.cwd.mkdir()
        self.marker = self.root / "planted-code-ran"
        # A planted module next to the entry, in the package parent, in the
        # package itself, and in the working directory must never load.
        planted = f"open({str(self.marker)!r}, 'w').close()\n"
        for directory in (self.entry.parent, self.parent, self.package, self.cwd):
            for module in ("json.py", "os.py", "subprocess.py", "stat.py"):
                (directory / module).write_text(planted)

    def run_entry(self, *args: str, isolated: bool = True) -> subprocess.CompletedProcess:
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.root)}
        flags = ["-I"] if isolated else []
        return subprocess.run(
            [sys.executable, *flags, str(self.entry), *args],
            cwd=self.cwd, env=env, capture_output=True, text=True, timeout=60,
        )

    def assert_no_bytecode_and_no_planted_code(self) -> None:
        self.assertFalse(self.marker.exists(), "a planted module ran")
        written = [str(p) for p in self.root.rglob("*") if p.name == "__pycache__" or p.suffix == ".pyc"]
        self.assertEqual(written, [], "the entry wrote bytecode")

    def test_bytecode_is_off_before_any_other_import(self) -> None:
        body = ast.parse(ENTRY.read_text()).body
        self.assertIsInstance(body[0], ast.Expr)  # the docstring
        self.assertEqual(ast.unparse(body[1]), "import sys")
        self.assertEqual(ast.unparse(body[2]), "sys.dont_write_bytecode = True")

    def test_unknown_arguments_keep_their_message_and_exit_code(self) -> None:
        result = self.run_entry("bogus", "args")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stderr, "[post-create] unknown arguments: bogus args\n")
        self.assert_no_bytecode_and_no_planted_code()

    def test_sidecar_modes_reach_their_modules(self) -> None:
        if not Path("/project-sessions").exists():
            result = self.run_entry("auth-sync")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertTrue(
                result.stderr.startswith("[auth-sync] refusing unsafe project sessions root ("),
                result.stderr,
            )
        if os.geteuid() != 0:
            result = self.run_entry("sanitize-seeds")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(result.stderr, "[post-create] sanitizer: must run as root\n")
        self.assert_no_bytecode_and_no_planted_code()

    def test_missing_package_fails_closed(self) -> None:
        shutil.rmtree(self.package)
        result = self.run_entry("bogus")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(
            result.stderr,
            f"[post-create] error: {PACKAGE} must load from {self.package}, found nothing\n",
        )
        self.assert_no_bytecode_and_no_planted_code()

    def test_same_named_package_earlier_on_the_path_is_refused_unrun(self) -> None:
        # Without -I, the script directory is first on sys.path. Only the
        # same-named package is planted there for this case.
        for module in ("json.py", "os.py", "subprocess.py", "stat.py"):
            (self.entry.parent / module).unlink()
        shadow = self.entry.parent / PACKAGE
        shadow.mkdir()
        (shadow / "__init__.py").write_text(f"open({str(self.marker)!r}, 'w').close()\n")
        result = self.run_entry("bogus", isolated=False)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(f"{PACKAGE} must load from {self.package}, found {shadow / '__init__.py'}",
                      result.stderr)
        self.assert_no_bytecode_and_no_planted_code()


if __name__ == "__main__":
    unittest.main()
