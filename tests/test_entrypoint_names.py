"""Public names, canonical CLI tools and configuration discovery."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")
CANONICAL_ENTRYPOINTS = [
    "install.sh",
    "setup.sh",
    "uninstall.sh",
    "configure-panel.sh",
    "maintain.sh",
    "prepare-server.sh",
    "manage-services.sh",
]
LEGACY_NAMES = [
    "setup_mask.sh",
    "configure_3xui.sh",
    "update_repair.sh",
    "secure-vps.sh",
    "manage_nextgen.sh",
    "setup_mask.env.example",
]


class EntrypointNamesTests(unittest.TestCase):
    def test_canonical_entrypoints_exist_and_legacy_are_removed(self):
        for name in CANONICAL_ENTRYPOINTS:
            with self.subTest(canonical=name):
                self.assertTrue((ROOT / name).is_file(), f"Canonical entrypoint {name} must exist")
        for legacy in LEGACY_NAMES:
            with self.subTest(legacy=legacy):
                self.assertFalse((ROOT / legacy).exists(), f"Legacy file {legacy} should not exist in root")

    def test_new_setup_cli_generates_neutral_config(self):
        with tempfile.TemporaryDirectory() as temp:
            generated = Path(temp) / "server-setup.env"
            result = subprocess.run([str(BASH), str(ROOT / "setup.sh"), "--gen-config", generated.as_posix()],
                                    capture_output=True, text=True, encoding="utf-8", timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(generated.is_file())
            self.assertIn("PANEL_PATH=", generated.read_text(encoding="utf-8"))
            self.assertNotIn("setup_mask", generated.read_text(encoding="utf-8"))

    def test_config_discovery_preserves_legacy_files_and_prefers_new_name(self):
        helper = ROOT / "src/common/config.sh"
        self.assertTrue(helper.is_file(), "Shared config discovery must cover new and legacy names")
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            legacy = work / "setup_mask.env"
            canonical = work / "server-setup.env"
            legacy.write_text('PRIMARY_DOMAIN="example.com"\n', encoding="utf-8")
            code = "source " + shlex.quote(helper.as_posix()) + "\nfind_config_file " + shlex.quote(work.as_posix())
            def discover():
                return subprocess.run([str(BASH), "-c", code], cwd=ROOT, capture_output=True,
                                      text=True, encoding="utf-8", timeout=10)
            result = discover()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), legacy.as_posix())
            canonical.write_text('PRIMARY_DOMAIN="new.example"\n', encoding="utf-8")
            result = discover()
            self.assertEqual(result.stdout.strip(), canonical.as_posix())

    def test_client_launcher_uses_neutral_python_filename(self):
        launcher = ROOT / "src/awg/manage-clients.sh"
        self.assertTrue(launcher.is_file())
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            script = work / launcher.name
            shutil.copyfile(launcher, script)
            python = work / "manage_clients.py"
            python.write_text("import sys\nprint(repr(sys.argv[1:]))\nraise SystemExit(23)\n", encoding="utf-8")
            env = dict(os.environ, AWG_DIR=work.as_posix())
            # Stub only interpreter discovery; the real launcher still forwards argv.
            startup = work / "startup.sh"
            startup.write_text('command() { if [[ "$*" == "-v python3" ]]; then printf "%s\\n" '
                               + shlex.quote(Path(sys.executable).as_posix())
                               + '; else builtin command "$@"; fi; }\n', encoding="utf-8", newline="\n")
            env["BASH_ENV"] = startup.as_posix()
            result = subprocess.run([str(BASH), script.as_posix(), "uri", "client with spaces"], env=env,
                                    capture_output=True, text=True, encoding="utf-8", timeout=10)
            self.assertEqual(result.returncode, 23, result.stderr)
            self.assertIn("client with spaces", result.stdout)

    def test_safety_scan_checks_new_file_after_unstaged_rename(self):
        sys.path.insert(0, str(ROOT))
        from scripts.check_safety import get_tracked_files, inspect_repository
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            for args in (["git", "init", "-q"],):
                subprocess.run(args, cwd=work, capture_output=True, check=True)
            old = work / "old.sh"
            old.write_text("#!/bin/bash\n", encoding="utf-8")
            subprocess.run(["git", "add", "old.sh"], cwd=work, capture_output=True, check=True)
            new = work / "setup.sh"
            old.rename(new)
            self.assertEqual(set(get_tracked_files(work)), {new})
            self.assertEqual(inspect_repository(work), ([], []))


if __name__ == "__main__":
    unittest.main()
