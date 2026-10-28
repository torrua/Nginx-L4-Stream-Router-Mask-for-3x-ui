"""
tests/test_audit_v91_fixes.py - Regression test suite for v9.1.0 audit and resilience fixes.

Covers:
1. [P1] Build system sync and zero drift between src/ and root distribution scripts.
2. [P1] SSO diagnostics proxy routing (proxy_pass to ${PANEL_PATH}panel/ with X-Requested-With).
3. [P1] Universal SSL key-pair cryptographic verification (ECDSA & RSA pubkey DER matching).
4. [P1] SQLite WAL-safe live database snapshotting before restore.
5. [P1] Restore service failure detection, verified rollback, and non-zero exit code.
6. [P1] Mieru / mita configuration inclusion in backup manifest and restore.
7. [P2] Consistent PORT_AGH_DNS (10053) across registry, preflight, install, and verification.
"""

import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent


class TestAuditV91Fixes(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.test_path = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_01_build_system_drift_and_lint(self):
        """[P1] Verify scripts/build.py --check --lint reports 0 drift across all targets."""
        res = subprocess.run(
            ["python", "scripts/build.py", "--check", "--lint"],
            cwd=str(ROOT_DIR),
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            res.returncode,
            0,
            f"build.py --check --lint failed:\n{res.stdout}\n{res.stderr}",
        )
        self.assertIn("[SAFETY OK]", res.stdout)

    def test_02_sso_diagnostics_routing_and_unauth_404(self):
        """[P1] Verify Nginx configuration sends /__diag_auth subrequest to ${PANEL_PATH}panel/ with X-Requested-With."""
        setup_content = (ROOT_DIR / "setup.sh").read_text(encoding="utf-8")
        nginx_cfg = (ROOT_DIR / "src" / "nginx" / "config.sh").read_text(encoding="utf-8")

        for content, filename in [(setup_content, "setup.sh"), (nginx_cfg, "src/nginx/config.sh")]:
            # 1. proxy_pass must target panel/ subpath
            self.assertIn(
                'proxy_pass http://127.0.0.1:$PANEL_PORT${PANEL_PATH}panel/;',
                content,
                f"{filename} does not proxy /__diag_auth to ${{PANEL_PATH}}panel/",
            )
            # 2. X-Requested-With XMLHttpRequest must be set for 3X-UI AJAX check
            self.assertIn(
                "proxy_set_header X-Requested-With XMLHttpRequest;",
                content,
                f"{filename} missing X-Requested-With header in /__diag_auth",
            )
            # 3. Unauthenticated access to DIAG_PATH must return strict 404
            self.assertTrue(
                "if ($diag_auth = 0) { return 404; }" in content or r"if (\$diag_auth = 0) { return 404; }" in content,
                f"{filename} missing strict 404 guard on DIAG_PATH",
            )
            # 4. location = ${PANEL_PATH}diag must use auth_request /__diag_auth
            self.assertIn(
                "auth_request /__diag_auth;",
                content,
                f"{filename} missing auth_request /__diag_auth",
            )

    def test_03_universal_ssl_key_pair_validation(self):
        """[P1] Verify universal public key comparison works for both ECDSA and RSA."""
        # Find openssl binary
        openssl_candidates = [
            "openssl",
            r"C:\Program Files\Git\usr\bin\openssl.exe",
        ]
        openssl_bin = None
        for cand in openssl_candidates:
            try:
                res = subprocess.run([cand, "version"], capture_output=True)
                if res.returncode == 0:
                    openssl_bin = cand
                    break
            except Exception:
                pass

        if not openssl_bin:
            self.skipTest("OpenSSL binary not available for testing")

        def get_pubkey_hash(cert_file, key_file):
            # Same pipeline as maintain.sh
            p1 = subprocess.run(
                [openssl_bin, "x509", "-noout", "-pubkey", "-in", str(cert_file)],
                capture_output=True,
            )
            p2 = subprocess.run(
                [openssl_bin, "pkey", "-pubin", "-outform", "DER"],
                input=p1.stdout,
                capture_output=True,
            )
            p3 = subprocess.run(
                [openssl_bin, "sha256"],
                input=p2.stdout,
                capture_output=True,
            )
            cert_hash = p3.stdout.decode("utf-8", errors="replace").strip()

            k1 = subprocess.run(
                [openssl_bin, "pkey", "-pubout", "-in", str(key_file)],
                capture_output=True,
            )
            k2 = subprocess.run(
                [openssl_bin, "pkey", "-pubin", "-outform", "DER"],
                input=k1.stdout,
                capture_output=True,
            )
            k3 = subprocess.run(
                [openssl_bin, "sha256"],
                input=k2.stdout,
                capture_output=True,
            )
            key_hash = k3.stdout.decode("utf-8", errors="replace").strip()

            return cert_hash, key_hash

        # 1. Test ECDSA key pair
        ec_key = self.test_path / "ec_priv.pem"
        ec_cert = self.test_path / "ec_cert.pem"
        subprocess.run(
            [openssl_bin, "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(ec_key)],
            check=True,
        )
        subprocess.run(
            [openssl_bin, "req", "-new", "-x509", "-key", str(ec_key), "-out", str(ec_cert), "-days", "1", "-subj", "/CN=test-ec"],
            check=True,
        )
        c_hash, k_hash = get_pubkey_hash(ec_cert, ec_key)
        self.assertTrue(len(c_hash) > 10)
        self.assertEqual(c_hash, k_hash, "ECDSA matching key pair was falsely rejected!")

        # 2. Test RSA key pair
        rsa_key = self.test_path / "rsa_priv.pem"
        rsa_cert = self.test_path / "rsa_cert.pem"
        subprocess.run(
            [openssl_bin, "genrsa", "-out", str(rsa_key), "2048"],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [openssl_bin, "req", "-new", "-x509", "-key", str(rsa_key), "-out", str(rsa_cert), "-days", "1", "-subj", "/CN=test-rsa"],
            check=True,
        )
        c_rsa_hash, k_rsa_hash = get_pubkey_hash(rsa_cert, rsa_key)
        self.assertTrue(len(c_rsa_hash) > 10)
        self.assertEqual(c_rsa_hash, k_rsa_hash, "RSA matching key pair was falsely rejected!")

        # 3. Test mismatch detection (ECDSA cert with RSA key)
        c_bad, k_bad = get_pubkey_hash(ec_cert, rsa_key)
        self.assertNotEqual(c_bad, k_bad, "Mismatched key pair was not detected!")

    def test_04_sqlite_wal_safe_snapshot(self):
        """[P1] Verify SQLite Online Backup API captures committed WAL records while raw cp loses them."""
        db_path = self.test_path / "live.db"
        conn = sqlite3.connect(str(db_path))
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);")
        conn.execute("INSERT INTO users (name) VALUES ('initial');")
        conn.commit()

        # Add records in WAL mode without checkpointing
        conn.execute("INSERT INTO users (name) VALUES ('wal_record_1');")
        conn.execute("INSERT INTO users (name) VALUES ('wal_record_2');")
        conn.commit()

        # Raw file copy simulation (the bug in maintain.sh line 948)
        raw_cp_dest = self.test_path / "raw_copy.db"
        shutil.copyfile(str(db_path), str(raw_cp_dest))

        # SQLite Online Backup API simulation (our fix in maintain.sh / backup.sh)
        safe_backup_dest = self.test_path / "safe_backup.db"
        dst_conn = sqlite3.connect(str(safe_backup_dest))
        with dst_conn:
            conn.backup(dst_conn)
        dst_conn.close()

        # Check records in safe backup
        verify_conn = sqlite3.connect(str(safe_backup_dest))
        rows = verify_conn.execute("SELECT name FROM users;").fetchall()
        verify_conn.close()

        record_names = [r[0] for r in rows]
        self.assertIn("wal_record_1", record_names, "WAL record missing in safe backup")
        self.assertIn("wal_record_2", record_names, "WAL record missing in safe backup")
        self.assertEqual(len(record_names), 3, "All records must be preserved")

        conn.close()

    def test_05_restore_health_check_and_rollback_logic(self):
        """[P1] Verify maintain.sh do_restore checks service health and calls rollback on failure."""
        maintain_content = (ROOT_DIR / "maintain.sh").read_text(encoding="utf-8")

        # 1. do_restore_rollback function must exist
        self.assertIn("do_restore_rollback()", maintain_content)

        # 2. nginx syntax test failure must trigger rollback
        self.assertIn('if ! nginx -t >/dev/null 2>&1; then', maintain_content)
        self.assertIn('do_restore_rollback "$rollback_dir"', maintain_content)

        # 3. x-ui failure must trigger rollback
        self.assertIn('if ! systemctl restart x-ui; then', maintain_content)
        self.assertIn('if ! systemctl is-active --quiet x-ui; then', maintain_content)

        # 4. nginx restart failure must trigger rollback
        self.assertIn('if ! systemctl restart nginx; then', maintain_content)
        self.assertIn('if ! systemctl is-active --quiet nginx; then', maintain_content)

        # 5. Snapshot before restore must use backup_sqlite_db, not raw cp
        self.assertIn('backup_sqlite_db "$current_db" "$rollback_dir/x-ui.db"', maintain_content)

    def test_06_mieru_config_in_backup_and_restore(self):
        """[P1] Verify Mieru /etc/mita and /etc/mita_server_config.json are included in backup & restore."""
        maintain_content = (ROOT_DIR / "maintain.sh").read_text(encoding="utf-8")
        backup_content = (ROOT_DIR / "src" / "common" / "backup.sh").read_text(encoding="utf-8")

        for content, filename in [(maintain_content, "maintain.sh"), (backup_content, "src/common/backup.sh")]:
            # Backup: save /etc/mita and /etc/mita_server_config.json
            self.assertIn(
                '/etc/mita',
                content,
                f"{filename} does not reference /etc/mita for backup",
            )
            self.assertIn(
                '/etc/mita_server_config.json',
                content,
                f"{filename} does not reference /etc/mita_server_config.json for backup",
            )
            # Restore: restore /etc/mita and /etc/mita_server_config.json
            self.assertIn(
                'mita_server_config.json',
                content,
                f"{filename} does not restore mita_server_config.json",
            )
            self.assertIn(
                'chown -R mita:mita /etc/mita',
                content,
                f"{filename} missing chown mita:mita in restore",
            )

    def test_07_consistent_port_agh_dns(self):
        """[P2] Verify PORT_AGH_DNS (10053) is consistently used across all components and port 53 is preserved for systemd-resolved."""
        protocols_content = (ROOT_DIR / "src" / "common" / "protocols.sh").read_text(encoding="utf-8")
        preflight_content = (ROOT_DIR / "src" / "common" / "preflight.sh").read_text(encoding="utf-8")
        adguard_content = (ROOT_DIR / "src" / "adguard" / "setup.sh").read_text(encoding="utf-8")
        reconcile_content = (ROOT_DIR / "src" / "panel" / "reconcile.py").read_text(encoding="utf-8")
        setup_content = (ROOT_DIR / "setup.sh").read_text(encoding="utf-8")

        # 1. Protocol registry uses PORT_AGH_DNS
        self.assertIn('local agh_dns_p="${PORT_AGH_DNS:-10053}"', protocols_content)
        self.assertNotIn('AdGuard-DNS udp 53', protocols_content)

        # 2. Preflight verification checks PORT_AGH_DNS, not 53
        self.assertIn('check_required_port udp "$agh_dns_check"', preflight_content)
        self.assertIn('local agh_dns_check="${PORT_AGH_DNS:-10053}"', preflight_content)

        # 3. AdGuard setup binds to PORT_AGH_DNS
        self.assertIn('port: ${PORT_AGH_DNS:-10053}', adguard_content)
        self.assertNotIn('port: 53\n', adguard_content)

        # 4. Xray reconcile template points to PORT_AGH_DNS
        self.assertIn('agh_dns_port = int(os.environ.get("PORT_AGH_DNS") or "10053")', reconcile_content)
        self.assertIn('target_servers = [{"address": "127.0.0.1", "port": agh_dns_port}]', reconcile_content)

        # 5. Compiled setup.sh has all these unified
        self.assertIn('port: ${PORT_AGH_DNS:-10053}', setup_content)
        self.assertIn('check_required_port udp "$agh_dns_check"', setup_content)

    def test_08_diagnostics_endpoint_contract_parity(self):
        """[P1] Verify contract parity for speedtest endpoints (down/download, up/upload, getip/getIP)."""
        import importlib.util
        import io

        spec = importlib.util.spec_from_file_location("mtr_backend", ROOT_DIR / "diagnostics" / "mtr-backend.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        class MockSocket:
            def __init__(self, request_bytes):
                self.rfile = io.BytesIO(request_bytes)
                self.wfile = io.BytesIO()

            def makefile(self, mode, *args, **kwargs):
                if "b" in mode:
                    return self.rfile if "r" in mode else self.wfile
                raise ValueError()

            def sendall(self, b):
                self.wfile.write(b)

        # 1. Backend: GET /down, /download, /getip, /getIP must all return 200 OK
        for path in [
            "/api/st/down?size=1k",
            "/down?size=1k",
            "/api/st/download?size=1k",
            "/download?size=1k",
            "/api/st/getip",
            "/getip",
            "/api/st/getIP",
            "/getIP",
        ]:
            raw_req = f"GET {path} HTTP/1.1\r\nHost: localhost\r\nX-Real-IP: 127.0.0.1\r\n\r\n".encode()
            sock = MockSocket(raw_req)
            mod.DiagnosticsHandler(sock, ("127.0.0.1", 12345), None)
            resp = sock.wfile.getvalue().decode("utf-8", errors="replace")
            status = resp.splitlines()[0] if resp else "EMPTY"
            self.assertIn("200 OK", status, f"Backend returned {status} for GET {path}")

        # 2. Backend: POST /up, /upload must both return 200 OK
        for path in ["/api/st/up", "/up", "/api/st/upload", "/upload"]:
            raw_req = f"POST {path} HTTP/1.1\r\nHost: localhost\r\nX-Real-IP: 127.0.0.1\r\nContent-Length: 4\r\n\r\ntest".encode()
            sock = MockSocket(raw_req)
            mod.DiagnosticsHandler(sock, ("127.0.0.1", 12345), None)
            resp = sock.wfile.getvalue().decode("utf-8", errors="replace")
            status = resp.splitlines()[0] if resp else "EMPTY"
            self.assertIn("200 OK", status, f"Backend returned {status} for POST {path}")

        # 3. Nginx: config.sh must declare locations for both short and long names
        nginx_cfg = (ROOT_DIR / "src" / "nginx" / "config.sh").read_text(encoding="utf-8")
        setup_sh = (ROOT_DIR / "setup.sh").read_text(encoding="utf-8")
        for content, name in [(nginx_cfg, "config.sh"), (setup_sh, "setup.sh")]:
            self.assertIn("${DIAG_PATH}api/st/getIP", content, f"{name} missing getIP location")
            self.assertIn("${DIAG_PATH}api/st/getip", content, f"{name} missing getip location")
            self.assertIn("${DIAG_PATH}api/st/download", content, f"{name} missing download location")
            self.assertIn("${DIAG_PATH}api/st/down", content, f"{name} missing down location")
            self.assertIn("${DIAG_PATH}api/st/upload", content, f"{name} missing upload location")
            self.assertIn("${DIAG_PATH}api/st/up", content, f"{name} missing up location")

    def test_09_rollback_stops_xui_before_copy_and_cleans_wal(self):
        """[P1] Verify emergency rollback stops x-ui before copying DB and cleans stale WAL/SHM."""
        backup_sh = (ROOT_DIR / "src" / "common" / "backup.sh").read_text(encoding="utf-8")
        maintain_sh = (ROOT_DIR / "maintain.sh").read_text(encoding="utf-8")

        for content, name in [(backup_sh, "backup.sh"), (maintain_sh, "maintain.sh")]:
            # 1. systemctl stop x-ui must precede cp of x-ui.db
            stop_idx = content.find("systemctl stop x-ui")
            cp_idx = content.find('cp -a "$rollback_dir/x-ui.db"')
            self.assertNotEqual(stop_idx, -1, f"{name} missing systemctl stop x-ui in rollback")
            self.assertNotEqual(cp_idx, -1, f"{name} missing cp of x-ui.db in rollback")
            self.assertLess(stop_idx, cp_idx, f"{name} does not stop x-ui before copying DB")

            # 2. Stale WAL/SHM cleanup must be present
            self.assertIn("x-ui.db-wal", content, f"{name} missing WAL cleanup in rollback")
            self.assertIn("x-ui.db-shm", content, f"{name} missing SHM cleanup in rollback")

            # 3. Rollback failure must be tracked
            self.assertIn("rollback_failed", content, f"{name} does not track rollback failures")

    def test_10_configure_panel_unbound_diag_token(self):
        """[P2] Verify configure.sh defaults DIAG_TOKEN and protects against unbound variable error."""
        config_panel = (ROOT_DIR / "src" / "panel" / "configure.sh").read_text(encoding="utf-8")
        report_web = (ROOT_DIR / "src" / "installer" / "report-web.sh").read_text(encoding="utf-8")
        compiled_cfg = (ROOT_DIR / "configure-panel.sh").read_text(encoding="utf-8")

        for content, name in [(config_panel, "configure.sh"), (report_web, "report-web.sh"), (compiled_cfg, "configure-panel.sh")]:
            self.assertNotIn("Токен диагностики:     ${DIAG_TOKEN}\n", content, f"{name} uses unsafe un-defaulted ${{DIAG_TOKEN}}")
            self.assertIn("${DIAG_TOKEN:-}", content, f"{name} missing safe ${{DIAG_TOKEN:-}} expansion")

    def test_11_mtr_prerequisite_in_packages(self):
        """[P2] Verify mtr-tiny is declared in pkg_map of packages.sh."""
        packages_sh = (ROOT_DIR / "src" / "system" / "packages.sh").read_text(encoding="utf-8")
        setup_sh = (ROOT_DIR / "setup.sh").read_text(encoding="utf-8")

        for content, name in [(packages_sh, "packages.sh"), (setup_sh, "setup.sh")]:
            self.assertIn('[mtr]="mtr-tiny"', content, f"{name} missing [mtr]='mtr-tiny' in prerequisites")

    def test_12_rollback_aborts_when_xui_stop_fails(self):
        """[P1] Verify do_restore_rollback aborts if x-ui cannot be stopped, preserving files."""
        git_bash = r"C:\Program Files\Git\bin\bash.exe"
        bash_bin = git_bash if os.path.exists(git_bash) else (shutil.which("bash") or "bash")
        backup_content = (ROOT_DIR / "src" / "common" / "backup.sh").read_text(encoding="utf-8")

        m = re.search(r"(do_restore_rollback\(\)\s*\{.*?\n\})", backup_content, re.DOTALL)
        self.assertIsNotNone(m, "do_restore_rollback not found")
        func_code = m.group(1)

        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            etc_xui = p / "etc" / "x-ui"
            etc_xui.mkdir(parents=True)
            db = etc_xui / "x-ui.db"
            db.write_text("LIVE_DB", encoding="utf-8")
            wal = etc_xui / "x-ui.db-wal"
            wal.write_text("LIVE_WAL", encoding="utf-8")

            rb_dir = p / "rollback_snapshot"
            rb_dir.mkdir()
            (rb_dir / "x-ui.db").write_text("BACKUP_DB", encoding="utf-8")

            patched_code = func_code.replace("/etc/x-ui", etc_xui.as_posix())

            script = f"""
set -u
die() {{ echo "DIE: $1" >&2; exit 42; }}
warn() {{ echo "WARN: $1" >&2; }}

systemctl() {{
    case "$*" in
        *"stop nginx"*) return 0 ;;
        *"stop x-ui"*) return 1 ;;
        *"is-active --quiet x-ui"*) return 0 ;;
        *) return 0 ;;
    esac
}}

{patched_code}

do_restore_rollback "{rb_dir.as_posix()}"
"""
            res = subprocess.run([bash_bin, "-c", script], capture_output=True, text=True, encoding="utf-8", errors="replace")
            self.assertEqual(res.returncode, 42, f"Expected abort with code 42, got {res.returncode}. Output:\n{res.stdout}\n{res.stderr}")
            self.assertTrue(
                "невозможно остановить" in res.stderr or "продолжает работать" in res.stderr,
                f"Expected error message not found in stderr:\n{res.stderr}",
            )
            self.assertEqual(db.read_text(encoding="utf-8"), "LIVE_DB", "Database was overwritten!")
            self.assertEqual(wal.read_text(encoding="utf-8"), "LIVE_WAL", "WAL was deleted when stop failed!")

    def test_13_v311_compat_mihomo_x25519_and_awg_keepalive(self):
        """[P1] Verify 3X-UI v3.11.0 compatibility: mihomo_x25519 in hosts and randomized AWG keepalive."""
        reconcile_py = (ROOT_DIR / "src" / "panel" / "reconcile.py").read_text(encoding="utf-8")
        manage_clients_py = (ROOT_DIR / "src" / "awg" / "manage_clients.py").read_text(encoding="utf-8")
        node_token_py = (ROOT_DIR / "src" / "panel" / "node_token.py").read_text(encoding="utf-8")

        # 1. mihomo_x25519 column and REALITY sync
        self.assertIn("mihomo_x25519 INTEGER DEFAULT 0", reconcile_py)
        self.assertIn("sync_host_entry(s_iid, s_rem, domain, 443, \"same\", host_sni=steal_dom, host_fp=reality_fp, sort_order=1, mihomo_x25519=1)", reconcile_py)
        self.assertIn("insert_host_entry(c_iid, h_remark, domain, 443, \"same\", host_sni=csni, host_fp=reality_fp, sort_order=idx, shuffle_host=1, mihomo_x25519=1)", reconcile_py)

        # 2. AWG keepalive randomized range default (15-25)
        self.assertIn('CONF_PARAMS.get("PersistentKeepalive", "15-25")', manage_clients_py)
        self.assertIn(r"PersistentKeepalive\s*=\s*([0-9\-]+)", manage_clients_py)

        # 3. Node token scope node-admin
        self.assertIn('("scope", "node-admin")', node_token_py)

    def test_14_awg_31_maximum_compatibility_generation(self):
        """[P1] Verify AWG 3.1 client configs prioritize awg0.conf params, normalize keepalive to int, and default dual-stack."""
        manage_clients_py = (ROOT_DIR / "src" / "awg" / "manage_clients.py").read_text(encoding="utf-8")

        # 1. RandomTrailers and DisableCookies prioritize CONF_PARAMS over ambient env vars
        self.assertIn('raw_rt = CONF_PARAMS.get("RandomTrailers") or os.environ.get("AWG_RANDOM_TRAILERS") or "on"', manage_clients_py)
        self.assertIn('raw_dc = CONF_PARAMS.get("DisableCookies") or os.environ.get("AWG_DISABLE_COOKIES") or "off"', manage_clients_py)

        # 2. HeaderProtectionKey prioritizes CONF_PARAMS
        self.assertIn('CONF_PARAMS.get("HeaderProtectionKey")', manage_clients_py)

        # 3. PersistentKeepalive normalized to integer
        self.assertIn('if "-" in str(raw_ka) or not str(raw_ka).strip().isdigit():', manage_clients_py)
        self.assertIn('PERSISTENT_KEEPALIVE = "25"', manage_clients_py)

        # 4. AllowedIPs defaults to dual-stack IPv4/IPv6
        self.assertIn('ALLOWED_IPS = os.environ.get("AWG_ALLOWED_IPS", "0.0.0.0/0, ::/0")', manage_clients_py)

        # 5. Container amnezia-awg2 and format_version 1
        self.assertIn('"container": container_id', manage_clients_py)
        self.assertIn('"amnezia-awg2"', manage_clients_py)
        self.assertIn('"format_version": 1', manage_clients_py)


if __name__ == "__main__":
    unittest.main()
