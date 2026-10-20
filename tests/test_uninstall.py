"""
tests/test_uninstall.py - Unit and regression tests for Initial State Snapshot and Uninstall/Rollback Engine.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")


class TestSnapshotAndUninstall(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.work = Path(self.temp_dir.name)
        self.target_root = self.work / "rootfs"
        self.target_root.mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_bash_snippet(self, snippet: str, env: dict = None) -> subprocess.CompletedProcess:
        script = self.work / "test_snippet.sh"
        script.write_text(snippet, encoding="utf-8", newline="\n")
        run_env = os.environ.copy()
        if env:
            run_env.update(env)
        return subprocess.run(
            [str(BASH), str(script)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=run_env,
            timeout=25
        )

    def test_snapshot_creation_and_manifest(self):
        """Verify that create_initial_state_snapshot records filesystem state and creates manifest."""
        etc_ssh = self.target_root / "etc/ssh"
        etc_ssh.mkdir(parents=True, exist_ok=True)
        (etc_ssh / "sshd_config").write_text("Port 2222\nPermitRootLogin yes\n", encoding="utf-8")

        etc_ufw = self.target_root / "etc/ufw"
        etc_ufw.mkdir(parents=True, exist_ok=True)
        (etc_ufw / "before.rules").write_text("*filter\n:ufw-before-input - [0:0]\nCOMMIT\n", encoding="utf-8")

        snap_dir = self.work / "backups/server_setup"

        snippet = f"""
set -euo pipefail
TARGET_ROOT="{self.target_root.as_posix()}"
SNAPSHOT_DIR="{snap_dir.as_posix()}"
SNAPSHOT_ARCHIVE="{snap_dir.as_posix()}/initial_state.tar.gz"
SNAPSHOT_MANIFEST="{snap_dir.as_posix()}/snapshot_manifest.json"
SSH_PORT="2222"

source "{ROOT.as_posix()}/src/common/colors.sh"
source "{ROOT.as_posix()}/src/common/logger.sh"
source "{ROOT.as_posix()}/src/system/snapshot.sh"

create_initial_state_snapshot
verify_initial_state_snapshot
"""
        res = self.run_bash_snippet(snippet)
        self.assertEqual(res.returncode, 0, f"Error: {res.stderr}\nStdout: {res.stdout}")

        manifest_file = snap_dir / "snapshot_manifest.json"
        archive_file = snap_dir / "initial_state.tar.gz"

        self.assertTrue(manifest_file.is_file(), "Manifest file must exist")
        self.assertTrue(archive_file.is_file(), "Archive file must exist")

        data = json.loads(manifest_file.read_text(encoding="utf-8"))
        self.assertEqual(data.get("version"), "1.0")
        self.assertEqual(data.get("ssh_active_port"), 2222)
        self.assertTrue(data.get("archive_sha256"), "Manifest must have archive_sha256")

    def test_snapshot_no_overwrite(self):
        """Verify that an existing snapshot is preserved and never overwritten."""
        snap_dir = self.work / "backups/server_setup"
        snap_dir.mkdir(parents=True, exist_ok=True)
        manifest_file = snap_dir / "snapshot_manifest.json"
        archive_file = snap_dir / "initial_state.tar.gz"

        # Pre-seed existing snapshot
        manifest_file.write_text('{"version":"1.0","original":true,"ssh_active_port":22}\n', encoding="utf-8")
        archive_file.write_text("existing-archive-payload\n", encoding="utf-8")

        snippet = f"""
set -euo pipefail
TARGET_ROOT="{self.target_root.as_posix()}"
SNAPSHOT_DIR="{snap_dir.as_posix()}"
SNAPSHOT_ARCHIVE="{archive_file.as_posix()}"
SNAPSHOT_MANIFEST="{manifest_file.as_posix()}"

source "{ROOT.as_posix()}/src/common/colors.sh"
source "{ROOT.as_posix()}/src/common/logger.sh"
source "{ROOT.as_posix()}/src/system/snapshot.sh"

create_initial_state_snapshot
"""
        res = self.run_bash_snippet(snippet)
        self.assertEqual(res.returncode, 0, f"Error: {res.stderr}\nStdout: {res.stdout}")
        self.assertIn("сохранен без изменений", res.stdout)

        # Check content unchanged
        data = json.loads(manifest_file.read_text(encoding="utf-8"))
        self.assertTrue(data.get("original"))

    def test_uninstall_removes_vpn_units_and_directories(self):
        """Verify that run_uninstall tears down custom units, VPN directories, and credentials."""
        # Setup mock installed services and dirs
        systemd_dir = self.target_root / "etc/systemd/system"
        systemd_dir.mkdir(parents=True, exist_ok=True)
        (systemd_dir / "x-ui.service").write_text("[Unit]\nDescription=3X-UI\n", encoding="utf-8")
        (systemd_dir / "sing-box-masque.service").write_text("[Unit]\nDescription=MASQUE\n", encoding="utf-8")
        (systemd_dir / "zapret.service").write_text("[Unit]\nDescription=Zapret\n", encoding="utf-8")

        xui_dir = self.target_root / "usr/local/x-ui"
        xui_dir.mkdir(parents=True, exist_ok=True)
        (xui_dir / "x-ui").write_text("binary", encoding="utf-8")

        singbox_dir = self.target_root / "etc/sing-box"
        singbox_dir.mkdir(parents=True, exist_ok=True)
        (singbox_dir / "config.json").write_text("{}", encoding="utf-8")

        opt_zapret = self.target_root / "opt/zapret"
        opt_zapret.mkdir(parents=True, exist_ok=True)
        (opt_zapret / "nfqws").write_text("binary", encoding="utf-8")

        creds = self.target_root / "root/vpn_credentials.txt"
        creds.parent.mkdir(parents=True, exist_ok=True)
        creds.write_text("SECRET", encoding="utf-8")

        # Mock ufw before.rules with hy2 port hopping rule
        etc_ufw = self.target_root / "etc/ufw"
        etc_ufw.mkdir(parents=True, exist_ok=True)
        (etc_ufw / "before.rules").write_text(
            "*nat\n# Port Hopping for Hysteria 2\n-A PREROUTING -p udp -j REDIRECT\nCOMMIT\n*filter\nCOMMIT\n",
            encoding="utf-8"
        )

        snap_dir = self.work / "backups/server_setup"

        snippet = f"""
set -euo pipefail
TARGET_ROOT="{self.target_root.as_posix()}"
SNAPSHOT_DIR="{snap_dir.as_posix()}"
UNINSTALL_FORCE=1

source "{ROOT.as_posix()}/src/common/colors.sh"
source "{ROOT.as_posix()}/src/common/logger.sh"
source "{ROOT.as_posix()}/src/system/snapshot.sh"
source "{ROOT.as_posix()}/src/system/uninstall.sh"

run_uninstall
"""
        res = self.run_bash_snippet(snippet)
        self.assertEqual(res.returncode, 0, f"Error: {res.stderr}\nStdout: {res.stdout}")

        # Assertions
        self.assertFalse((systemd_dir / "x-ui.service").exists(), "x-ui.service must be removed")
        self.assertFalse((systemd_dir / "sing-box-masque.service").exists(), "sing-box-masque.service must be removed")
        self.assertFalse((systemd_dir / "zapret.service").exists(), "zapret.service must be removed")
        self.assertFalse(xui_dir.exists(), "usr/local/x-ui must be removed")
        self.assertFalse(singbox_dir.exists(), "etc/sing-box must be removed")
        self.assertFalse(opt_zapret.exists(), "opt/zapret must be removed")
        self.assertFalse(creds.exists(), "vpn_credentials.txt must be removed")

        # Port hopping cleaned from before.rules
        rules_text = (etc_ufw / "before.rules").read_text(encoding="utf-8")
        self.assertNotIn("Port Hopping for Hysteria 2", rules_text)

    def test_uninstall_cli_help(self):
        """Verify uninstall.sh and setup.sh help outputs."""
        uninstall_sh = ROOT / "uninstall.sh"
        self.assertTrue(uninstall_sh.is_file())
        res = subprocess.run([str(BASH), str(uninstall_sh), "--help"], capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(res.returncode, 0)
        self.assertIn("uninstall.sh [", res.stdout)
        self.assertIn("--purge", res.stdout)
        self.assertIn("--remove-certs", res.stdout)

        setup_sh = ROOT / "setup.sh"
        res_setup = subprocess.run([str(BASH), str(setup_sh), "--help"], capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(res_setup.returncode, 0)
        self.assertIn("--uninstall", res_setup.stdout)


if __name__ == "__main__":
    unittest.main()
