"""Public names, backwards-compatible launchers and configuration discovery."""
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
ALIASES = {
    "setup_mask.sh": "setup.sh",
    "configure_3xui.sh": "configure-panel.sh",
    "update_repair.sh": "maintain.sh",
    "secure-vps.sh": "prepare-server.sh",
    "manage_nextgen.sh": "manage-services.sh",
}


class EntrypointNamesTests(unittest.TestCase):
    def test_new_setup_cli_generates_neutral_config(self):
        with tempfile.TemporaryDirectory() as temp:
            generated = Path(temp) / "server-setup.env"
            result = subprocess.run([str(BASH), str(ROOT / "setup.sh"), "--gen-config", generated.as_posix()],
                                    capture_output=True, text=True, encoding="utf-8", timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(generated.is_file())
            self.assertIn("PANEL_PATH=", generated.read_text(encoding="utf-8"))
            self.assertNotIn("setup_mask", generated.read_text(encoding="utf-8"))

    def test_legacy_names_forward_arguments_and_exit_status(self):
        for old, new in ALIASES.items():
            with self.subTest(old=old), tempfile.TemporaryDirectory(prefix="entrypoint with spaces ") as temp:
                text = (ROOT / old).read_text(encoding="utf-8")
                # Never run a full installation in this compatibility test.
                self.assertLess(len(text.splitlines()), 100, "Legacy entrypoint must be a small forwarding wrapper")
                work = Path(temp)
                alias = work / old
                alias.write_text(text, encoding="utf-8", newline="\n")
                (work / new).write_text("#!/usr/bin/env bash\nprintf 'ARG=<%s>\\n' \"$@\"\nexit 23\n",
                                       encoding="utf-8", newline="\n")
                result = subprocess.run([str(BASH), alias.as_posix(), "--config", "a path with spaces.env"],
                                        capture_output=True, text=True, encoding="utf-8", timeout=10)
                self.assertEqual(result.returncode, 23, result.stderr)
                self.assertIn("ARG=<a path with spaces.env>", result.stdout)

    def test_downloaded_legacy_launcher_can_fetch_new_name(self):
        text = (ROOT / "setup_mask.sh").read_text(encoding="utf-8")
        self.assertLess(len(text.splitlines()), 100, "Legacy entrypoint must be a small forwarding wrapper")
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            alias = work / "setup_mask.sh"
            alias.write_text(text, encoding="utf-8", newline="\n")
            fixture = work / "fixture.txt"
            fixture.write_text("printf 'FORWARDED=<%s>\\n' \"$@\"\nexit 23\n", encoding="utf-8", newline="\n")
            startup = work / "startup.sh"
            startup.write_text('export PATH=/usr/bin:/bin:$PATH\n'
                               'curl() { cp "$TARGET_FIXTURE" "${@: -1}"; }\n', encoding="utf-8", newline="\n")
            env = dict(os.environ, BASH_ENV=startup.as_posix(), TARGET_FIXTURE=fixture.as_posix())
            result = subprocess.run([str(BASH), alias.as_posix(), "--config", "with spaces.env"],
                                    env=env, capture_output=True, text=True, encoding="utf-8", timeout=10)
            self.assertEqual(result.returncode, 23, result.stderr)
            self.assertIn("FORWARDED=<with spaces.env>", result.stdout)

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
