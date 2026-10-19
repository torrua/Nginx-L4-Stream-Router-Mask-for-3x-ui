"""
tests/test_builder.py - Unit tests for scripts/build.py.
"""

import tempfile
import unittest
from pathlib import Path

# Add scripts directory to path
import sys

SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import build


class TestBundler(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.src_dir = Path(self.temp_dir.name) / "src"
        self.src_dir.mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_single_file_no_includes(self):
        f = self.src_dir / "simple.sh"
        f.write_text("#!/bin/bash\necho 'hello'\n", encoding="utf-8")
        result = build.bundle_file(f, self.src_dir)
        self.assertEqual(result, "#!/bin/bash\necho 'hello'\n")

    def test_nested_includes(self):
        # Create helper
        helper = self.src_dir / "lib" / "helper.sh"
        helper.parent.mkdir(parents=True, exist_ok=True)
        helper.write_text("do_something() {\n  echo 'done'\n}\n", encoding="utf-8")

        # Create sub-module
        sub = self.src_dir / "sub.sh"
        sub.write_text("# @include \"lib/helper.sh\"\ndo_something\n", encoding="utf-8")

        # Create main entrypoint
        main = self.src_dir / "main.sh"
        main.write_text("#!/bin/bash\n# @include \"sub.sh\"\nexit 0\n", encoding="utf-8")

        result = build.bundle_file(main, self.src_dir)
        expected = "#!/bin/bash\ndo_something() {\n  echo 'done'\n}\ndo_something\nexit 0\n"
        self.assertEqual(result, expected)

    def test_cycle_detection(self):
        a = self.src_dir / "a.sh"
        b = self.src_dir / "b.sh"
        a.write_text("# @include \"b.sh\"\n", encoding="utf-8")
        b.write_text("# @include \"a.sh\"\n", encoding="utf-8")

        with self.assertRaises(ValueError) as ctx:
            build.bundle_file(a, self.src_dir)
        self.assertIn("Cyclic include detected", str(ctx.exception))

    def test_indentation_preservation(self):
        mod = self.src_dir / "inner.py"
        mod.write_text("def helper():\n    return 42\n", encoding="utf-8")

        main = self.src_dir / "main.py"
        main.write_text("class MyClass:\n    # @include \"inner.py\"\n", encoding="utf-8")

        result = build.bundle_file(main, self.src_dir)
        expected = "class MyClass:\n    def helper():\n        return 42\n"
        self.assertEqual(result, expected)

    def test_python_ast_linting(self):
        valid_shell = """#!/bin/bash
python3 - << 'EOF'
import sys
print("hello world")
EOF
"""
        invalid_shell = """#!/bin/bash
python3 - << 'EOF'
def broken_syntax(:
EOF
"""
        errs_valid = build.lint_output("test_valid", valid_shell)
        self.assertEqual(errs_valid, [])

        errs_invalid = build.lint_output("test_invalid", invalid_shell)
        self.assertTrue(any("Embedded Python syntax error" in e for e in errs_invalid))

    def test_version_macro_substitution(self):
        root = Path(self.temp_dir.name)
        (root / "VERSION").write_text("v9.1.5\n", encoding="utf-8")

        main = self.src_dir / "main.sh"
        main.write_text('SCRIPT_VERSION="__VERSION__"\nRAW="__RAW_VERSION__"\n', encoding="utf-8")

        result = build.bundle_file(main, self.src_dir)
        self.assertEqual(result, 'SCRIPT_VERSION="v9.1.5"\nRAW="9.1.5"\n')

    def test_sync_version_in_docs(self):
        root = Path(self.temp_dir.name)
        readme = root / "README.md"
        readme.write_text("[![Версия](https://img.shields.io/badge/версия-v7.0.0-blue)](link)", encoding="utf-8")
        
        docs_dir = root / "docs"
        docs_dir.mkdir(parents=True, exist_ok=True)
        arch = docs_dir / "ARCHITECTURE.md"
        arch.write_text("# Архитектура (v7.0.0)\nТекст", encoding="utf-8")

        updated = build.sync_version_in_docs("8.5.0", root)
        self.assertEqual(len(updated), 2)
        self.assertIn("v8.5.0", readme.read_text(encoding="utf-8"))
        self.assertIn("(v8.5.0)", arch.read_text(encoding="utf-8"))

    def test_bump_version_validation(self):
        root = Path(self.temp_dir.name)
        rc_bad = build.bump_version("invalid_ver", root)
        self.assertEqual(rc_bad, 1)


if __name__ == "__main__":
    unittest.main()

