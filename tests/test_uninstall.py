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

        # Mock cron and systemd-resolved files
        cron_file = self.target_root / "etc/cron.d/awg-purge-expired"
        cron_file.parent.mkdir(parents=True, exist_ok=True)
        cron_file.write_text("0 4 * * * root awg-mgr purge-expired\n", encoding="utf-8")

        resolved_conf = self.target_root / "etc/systemd/resolved.conf.d/adguard.conf"
        resolved_conf.parent.mkdir(parents=True, exist_ok=True)
        resolved_conf.write_text("[Resolve]\nDNSStubListener=no\n", encoding="utf-8")

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
        self.assertFalse(cron_file.exists(), "awg-purge-expired cron file must be removed")
        self.assertFalse(resolved_conf.exists(), "adguard resolved.conf.d override must be removed")

        # Port hopping cleaned from before.rules
        rules_text = (etc_ufw / "before.rules").read_text(encoding="utf-8")
        self.assertNotIn("Port Hopping for Hysteria 2", rules_text)

    def test_uninstall_ssl_certs_retention_and_removal(self):
        """Verify that SSL certs are kept by default and purged only when requested."""
        le_dir = self.target_root / "etc/letsencrypt"
        le_dir.mkdir(parents=True, exist_ok=True)
        (le_dir / "live").mkdir(parents=True, exist_ok=True)
        (le_dir / "live/cert.pem").write_text("MOCK CERT", encoding="utf-8")

        acme_dir = self.target_root / "root/.acme.sh"
        acme_dir.mkdir(parents=True, exist_ok=True)
        (acme_dir / "account.conf").write_text("ACCOUNT", encoding="utf-8")

        snap_dir = self.work / "backups/server_setup"

        # Case 1: UNINSTALL_KEEP_CERTS=1 (Default)
        snippet_keep = f"""
set -euo pipefail
TARGET_ROOT="{self.target_root.as_posix()}"
SNAPSHOT_DIR="{snap_dir.as_posix()}"
UNINSTALL_FORCE=1
UNINSTALL_KEEP_CERTS=1

source "{ROOT.as_posix()}/src/common/colors.sh"
source "{ROOT.as_posix()}/src/common/logger.sh"
source "{ROOT.as_posix()}/src/system/snapshot.sh"
source "{ROOT.as_posix()}/src/system/uninstall.sh"

run_uninstall
"""
        res = self.run_bash_snippet(snippet_keep)
        self.assertEqual(res.returncode, 0, f"Error: {res.stderr}\nStdout: {res.stdout}")
        self.assertTrue((le_dir / "live/cert.pem").exists(), "Certificates must be preserved when UNINSTALL_KEEP_CERTS=1")
        self.assertTrue((acme_dir / "account.conf").exists(), "acme.sh must be preserved when UNINSTALL_KEEP_CERTS=1")

        # Case 2: UNINSTALL_KEEP_CERTS=0 (Remove)
        snippet_remove = f"""
set -euo pipefail
TARGET_ROOT="{self.target_root.as_posix()}"
SNAPSHOT_DIR="{snap_dir.as_posix()}"
UNINSTALL_FORCE=1
UNINSTALL_KEEP_CERTS=0

source "{ROOT.as_posix()}/src/common/colors.sh"
source "{ROOT.as_posix()}/src/common/logger.sh"
source "{ROOT.as_posix()}/src/system/snapshot.sh"
source "{ROOT.as_posix()}/src/system/uninstall.sh"

run_uninstall
"""
        res2 = self.run_bash_snippet(snippet_remove)
        self.assertEqual(res2.returncode, 0, f"Error: {res2.stderr}\nStdout: {res2.stdout}")
        self.assertFalse(le_dir.exists(), "Letsencrypt dir must be deleted when UNINSTALL_KEEP_CERTS=0")
        self.assertFalse(acme_dir.exists(), ".acme.sh dir must be deleted when UNINSTALL_KEEP_CERTS=0")

    def test_uninstall_snapshot_restoration(self):
        """Verify that UFW, SSH, and Nginx configurations are restored from initial_state.tar.gz."""
        # Mock binaries so snapshot detects pre-existence
        mock_bin = self.work / "bin"
        mock_bin.mkdir(parents=True, exist_ok=True)
        (mock_bin / "nginx").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")

        etc_ufw = self.target_root / "etc/ufw"
        etc_ufw.mkdir(parents=True, exist_ok=True)
        (etc_ufw / "user.rules").write_text("# ORIG_UFW_RULE\n", encoding="utf-8")

        etc_ssh = self.target_root / "etc/ssh"
        etc_ssh.mkdir(parents=True, exist_ok=True)
        (etc_ssh / "sshd_config").write_text("Port 2222\nPermitRootLogin yes\n", encoding="utf-8")

        etc_nginx = self.target_root / "etc/nginx"
        etc_nginx.mkdir(parents=True, exist_ok=True)
        (etc_nginx / "nginx.conf").write_text("# ORIG_NGINX\n", encoding="utf-8")

        snap_dir = self.work / "backups/server_setup"

        # 1. Create snapshot
        snippet_snap = f"""
set -euo pipefail
if command -v cygpath >/dev/null 2>&1; then
    export PATH="$(cygpath -u "{mock_bin.as_posix()}"):$PATH"
else
    export PATH="{mock_bin.as_posix()}:$PATH"
fi
chmod +x "{mock_bin.as_posix()}/nginx" || true
TARGET_ROOT="{self.target_root.as_posix()}"
SNAPSHOT_DIR="{snap_dir.as_posix()}"
SNAPSHOT_ARCHIVE="{snap_dir.as_posix()}/initial_state.tar.gz"
SNAPSHOT_MANIFEST="{snap_dir.as_posix()}/snapshot_manifest.json"
SSH_PORT="2222"

source "{ROOT.as_posix()}/src/common/colors.sh"
source "{ROOT.as_posix()}/src/common/logger.sh"
source "{ROOT.as_posix()}/src/system/snapshot.sh"

create_initial_state_snapshot
"""
        res_snap = self.run_bash_snippet(snippet_snap)
        self.assertEqual(res_snap.returncode, 0, f"Snapshot error: {res_snap.stderr}")

        # 2. Modify files as installer would
        (etc_ufw / "user.rules").write_text("# MODIFIED_BY_INSTALLER\n", encoding="utf-8")
        (etc_ssh / "sshd_config").write_text("Port 9999\n", encoding="utf-8")
        (etc_nginx / "nginx.conf").write_text("# MODIFIED_NGINX\n", encoding="utf-8")

        # 3. Run uninstall
        snippet_uninstall = f"""
set -euo pipefail
if command -v cygpath >/dev/null 2>&1; then
    export PATH="$(cygpath -u "{mock_bin.as_posix()}"):$PATH"
else
    export PATH="{mock_bin.as_posix()}:$PATH"
fi
TARGET_ROOT="{self.target_root.as_posix()}"
SNAPSHOT_DIR="{snap_dir.as_posix()}"
SNAPSHOT_ARCHIVE="{snap_dir.as_posix()}/initial_state.tar.gz"
SNAPSHOT_MANIFEST="{snap_dir.as_posix()}/snapshot_manifest.json"
UNINSTALL_FORCE=1

source "{ROOT.as_posix()}/src/common/colors.sh"
source "{ROOT.as_posix()}/src/common/logger.sh"
source "{ROOT.as_posix()}/src/system/snapshot.sh"
source "{ROOT.as_posix()}/src/system/uninstall.sh"

run_uninstall
"""
        res_uninst = self.run_bash_snippet(snippet_uninstall)
        self.assertEqual(res_uninst.returncode, 0, f"Uninstall error: {res_uninst.stderr}\nStdout: {res_uninst.stdout}")

        # 4. Verify restoration
        self.assertIn("Конфигурация UFW успешно восстановлена", res_uninst.stdout)
        self.assertIn("Конфигурация SSH успешно восстановлена", res_uninst.stdout)
        self.assertIn("Исходная конфигурация Nginx восстановлена", res_uninst.stdout)

        self.assertEqual((etc_ufw / "user.rules").read_text(encoding="utf-8"), "# ORIG_UFW_RULE\n")
        self.assertEqual((etc_ssh / "sshd_config").read_text(encoding="utf-8"), "Port 2222\nPermitRootLogin yes\n")
        self.assertEqual((etc_nginx / "nginx.conf").read_text(encoding="utf-8"), "# ORIG_NGINX\n")

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

    def test_uninstall_preserves_user_files_in_var_www_html(self):
        """Verify that uninstall only removes decoy files and preserves user websites/files in /var/www/html."""
        html_dir = self.target_root / "var/www/html"
        html_dir.mkdir(parents=True, exist_ok=True)

        # 1. User files
        (html_dir / "my_app.php").write_text("<?php echo 'Dokploy/User Site'; ?>", encoding="utf-8")
        custom_sub = html_dir / "custom_dir"
        custom_sub.mkdir()
        (custom_sub / "data.json").write_text('{"user":"data"}', encoding="utf-8")

        # 2. Decoy files added by stack
        decoy_assets = html_dir / "assets/css"
        decoy_assets.mkdir(parents=True, exist_ok=True)
        (decoy_assets / "datasphere.css").write_text("body { background: #000; }", encoding="utf-8")
        (html_dir / "404.html").write_text("404 Not Found", encoding="utf-8")
        (html_dir / "index.html").write_text("<!DOCTYPE html><html><body>DataSphere Cloud Systems</body></html>", encoding="utf-8")

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

        # Assert decoy files removed
        self.assertFalse((html_dir / "assets").exists(), "Decoy assets dir must be removed")
        self.assertFalse((html_dir / "404.html").exists(), "Decoy 404.html must be removed")
        self.assertFalse((html_dir / "index.html").exists(), "Decoy index.html must be removed")

        # Assert user files preserved
        self.assertTrue(html_dir.is_dir(), "/var/www/html must be preserved because it has user files")
        self.assertTrue((html_dir / "my_app.php").is_file(), "User php script must be intact")
        self.assertTrue((custom_sub / "data.json").is_file(), "User custom directory must be intact")

    def test_uninstall_preserves_user_ufw_rules(self):
        """Verify that uninstall removes only [vpn-stack] UFW rules and preserves third-party rules like Dokploy."""
        etc_ufw = self.target_root / "etc/ufw"
        etc_ufw.mkdir(parents=True, exist_ok=True)
        user_rules_content = (
            "# START USER RULES\n"
            "### tuple ### allow tcp 80 0.0.0.0/0 any 0.0.0.0/0 in comment=[vpn-stack]%20HTTP%20(ACME%20/%20Decoy)\n"
            "-A ufw-user-input -p tcp --dport 80 -j ACCEPT -m comment --comment '[vpn-stack] HTTP (ACME / Decoy)'\n"
            "### tuple ### allow tcp 443 0.0.0.0/0 any 0.0.0.0/0 in comment=[vpn-stack]%20HTTPS%20(Nginx%20L4%20Stream%20Router)\n"
            "-A ufw-user-input -p tcp --dport 443 -j ACCEPT -m comment --comment '[vpn-stack] HTTPS (Nginx L4 Stream Router)'\n"
            "### tuple ### allow tcp 3000 0.0.0.0/0 any 0.0.0.0/0 in comment=Dokploy\n"
            "-A ufw-user-input -p tcp --dport 3000 -j ACCEPT -m comment --comment 'Dokploy'\n"
            "### tuple ### allow tcp 8080 0.0.0.0/0 any 0.0.0.0/0 in\n"
            "-A ufw-user-input -p tcp --dport 8080 -j ACCEPT\n"
            "# END USER RULES\n"
        )
        (etc_ufw / "user.rules").write_text(user_rules_content, encoding="utf-8")

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

        cleaned_rules = (etc_ufw / "user.rules").read_text(encoding="utf-8")

        # Stack rules with [vpn-stack] tag must be removed
        self.assertNotIn("vpn-stack", cleaned_rules)
        self.assertNotIn("HTTP (ACME / Decoy)", cleaned_rules)
        self.assertNotIn("HTTPS (Nginx L4 Stream Router)", cleaned_rules)

        # User rules must be preserved
        self.assertIn("Dokploy", cleaned_rules)
        self.assertIn("--dport 3000", cleaned_rules)
        self.assertIn("--dport 8080", cleaned_rules)

    def test_package_purge_whitelist_filter(self):
        """Verify that stack_pkg_regex safely filters stack packages while safeguarding third-party software."""
        import re
        stack_pkg_regex = re.compile(r"^(nginx.*|libnginx.*|certbot|python3-certbot.*|fail2ban|python3-systemd|amneziawg.*|wireguard.*|libnetfilter-queue.*|apache2-utils|python3-bcrypt|mtr-tiny|socat)$")

        stack_pkgs = [
            "nginx", "nginx-common", "nginx-core", "libnginx-mod-stream", "nginx-module-stream",
            "certbot", "python3-certbot", "python3-certbot-nginx", "fail2ban", "python3-systemd",
            "amneziawg", "amneziawg-tools", "wireguard", "wireguard-tools", "libnetfilter-queue1",
            "apache2-utils", "python3-bcrypt", "mtr-tiny", "socat"
        ]
        for pkg in stack_pkgs:
            self.assertTrue(stack_pkg_regex.match(pkg), f"Stack package {pkg} should be matched by regex")

        user_third_party_pkgs = [
            "docker-ce", "docker-ce-cli", "containerd.io", "docker-compose-plugin",
            "dokploy", "postgresql", "postgresql-14", "mysql-server", "mariadb-server",
            "redis-server", "git", "htop", "tmux", "zsh", "python3-pip", "curl", "bash"
        ]
        for pkg in user_third_party_pkgs:
            self.assertFalse(stack_pkg_regex.match(pkg), f"Third-party package {pkg} must NEVER be matched by purge regex")


if __name__ == "__main__":
    unittest.main()
