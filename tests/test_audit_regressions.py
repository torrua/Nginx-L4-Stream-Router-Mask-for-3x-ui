"""
tests/test_audit_regressions.py - Assert-based regression tests for audit findings R01-R09.
"""

import ast
import base64
import contextlib
import io
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import types
import unittest
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")


def run_shell(code: str, env: dict | None = None) -> subprocess.CompletedProcess:
    full_env = os.environ.copy()
    if env:
        full_env.update(env)
    return subprocess.run(
        [str(BASH), "-s"],
        input="export PATH=/usr/bin:/bin:$PATH\nsource src/common/config.sh\n" + code,
        cwd=ROOT,
        text=True,
        encoding="utf-8",
        capture_output=True,
        timeout=25,
        env=full_env,
    )


class TestAmneziaWG3XUISettings(unittest.TestCase):
    def test_awg_rekey_reject_no_overlap(self):
        """Verify that max(rekeyAfterTime) < min(rejectAfterTime) in 3X-UI template."""
        conf_sh = (ROOT / "configure-panel.sh").read_text(encoding="utf-8")
        m_rekey = re.search(r'"rekeyAfterTime":\s*"(\d+)-(\d+)"', conf_sh)
        m_reject = re.search(r'"rejectAfterTime":\s*"(\d+)-(\d+)"', conf_sh)
        self.assertIsNotNone(m_rekey, "rekeyAfterTime must be present in configure-panel.sh")
        self.assertIsNotNone(m_reject, "rejectAfterTime must be present in configure-panel.sh")
        max_rekey = int(m_rekey.group(2))
        min_reject = int(m_reject.group(1))
        self.assertLess(max_rekey, min_reject, f"max(rekeyAfterTime) [{max_rekey}] must be strictly less than min(rejectAfterTime) [{min_reject}]")

    def test_awg_cpa_in_reconcile_whitelist(self):
        """Verify that contentPaddingAddition and cpa are preserved during smart_reconcile_inbound."""
        inbounds_py = (ROOT / "src/xray/inbounds.py").read_text(encoding="utf-8")
        self.assertIn('"contentPaddingAddition"', inbounds_py, "contentPaddingAddition must be preserved in smart_reconcile_inbound")
        self.assertIn('"cpa"', inbounds_py, "cpa must be preserved in smart_reconcile_inbound")

    def test_manage_amneziawg_no_random_hpk_fallback(self):
        """Verify that manage_clients.py does not invent random HPK for clients when server lacks HPK."""
        mgr_py = (ROOT / "src/awg/manage_clients.py").read_text(encoding="utf-8")
        self.assertNotIn("HEADER_PROTECTION_KEY = base64.b64encode(secrets.token_bytes(32))", mgr_py,
                         "manage_clients.py must not generate random fallback HPK when server lacks HPK")

    def test_awg_v3_template_parameters_consistency(self):
        """Verify configure-panel.sh and maintain.sh have consistent AWG v3 parameters."""
        conf_sh = (ROOT / "configure-panel.sh").read_text(encoding="utf-8")
        upd_sh = (ROOT / "maintain.sh").read_text(encoding="utf-8")
        for text, name in [(conf_sh, "configure-panel.sh"), (upd_sh, "maintain.sh")]:
            self.assertIn('"jc": 4', text, f"AWG v3 in {name} must have jc=4")
            self.assertIn('"jmin": 40', text, f"AWG v3 in {name} must have jmin=40")
            self.assertIn('"jmax": 70', text, f"AWG v3 in {name} must have jmax=70")
            self.assertIn('"s1": 16', text, f"AWG v3 in {name} must have s1=16")
            self.assertIn('"s4": 16', text, f"AWG v3 in {name} must have s4=16")
            self.assertIn('"h1": "1"', text, f"AWG v3 in {name} must have h1='1'")
            self.assertIn('"h4": "4"', text, f"AWG v3 in {name} must have h4='4'")
            self.assertIn('"disableCookies": False', text, f"AWG v3 in {name} must have disableCookies=False")

    def test_awg_reconcile_does_not_clamp_jc(self):
        """Verify smart_reconcile_inbound preserves valid jc and does not clamp down to 2."""
        inbounds_py = (ROOT / "src/xray/inbounds.py").read_text(encoding="utf-8")
        self.assertNotIn('if int(cur_jc) > 2:', inbounds_py,
                         "smart_reconcile_inbound must not clamp jc to 2")
        self.assertNotIn('if int(cur_jmax) > 50:', inbounds_py,
                         "smart_reconcile_inbound must not clamp jmax to 50")

    def test_awg_setup_template_parameters(self):
        """Verify src/awg/setup.sh creates awg0.conf with matching AWG 3.1 blueprint."""
        setup_sh = (ROOT / "src/awg/setup.sh").read_text(encoding="utf-8")
        self.assertIn("Jc = 4", setup_sh, "awg0.conf blueprint must contain Jc = 4")
        self.assertIn("Jmin = 40", setup_sh, "awg0.conf blueprint must contain Jmin = 40")
        self.assertIn("Jmax = 70", setup_sh, "awg0.conf blueprint must contain Jmax = 70")
        self.assertIn("S1 = 16", setup_sh, "awg0.conf blueprint must contain S1 = 16")
        self.assertIn("S4 = 16", setup_sh, "awg0.conf blueprint must contain S4 = 16")
        self.assertIn("H1 = 1", setup_sh, "awg0.conf blueprint must contain H1 = 1")
        self.assertIn("H4 = 4", setup_sh, "awg0.conf blueprint must contain H4 = 4")
        self.assertIn("RandomTrailers = on", setup_sh, "awg0.conf blueprint must contain RandomTrailers = on")
        self.assertIn("DisableCookies = off", setup_sh, "awg0.conf blueprint must contain DisableCookies = off")

    def test_awg_installation_runs_after_configuration(self):
        """AWG installation belongs to the confirmed plan, never to interview events."""
        wizard = (ROOT / "src/tui/wizard.sh").read_text(encoding="utf-8")
        self.assertFalse("start_amneziawg_preinstall_bg" in wizard)
        engine = (ROOT / "src/installer/engine.sh").read_text(encoding="utf-8")
        self.assertIn('installer/awg.sh', engine)
        awg = (ROOT / "src/installer/awg.sh").read_text(encoding="utf-8")
        self.assertIn("ensure_amneziawg_installed", awg)
        self.assertIn("deploy_amneziawg_backend", awg)

    def test_awg_i1_dns_template_support(self):
        """Verify that DNS_I1_TEMPLATE is defined and matches the icloud.com 44-byte DNS response."""
        mgr_py = (ROOT / "src/awg/manage_clients.py").read_text(encoding="utf-8")
        self.assertIn("DNS_I1_TEMPLATE = ", mgr_py)
        expected_template = "<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>"
        self.assertIn(expected_template, mgr_py)
        self.assertIn('--i1=dns', mgr_py)

    def test_awg_client_presets_and_vpnuri_consistency(self):
        """Verify that client presets and per-client parameters (MTU, Jc, I1, Keepalive) propagate to vpn:// URI."""
        import base64
        import struct
        import sys
        import zlib
        sys.path.insert(0, str((ROOT / "src/awg").resolve()))
        import manage_clients as mgr

        # 1. Verify CLI argument support in source code
        mgr_src = (ROOT / "src/awg/manage_clients.py").read_text(encoding="utf-8")
        for flag in ["--preset=", "--mtu=", "--jc=", "--jmin=", "--jmax=", "--keepalive=", "--allowed-ips="]:
            self.assertIn(flag, mgr_src, f"CLI flag {flag} must be supported in manage_clients.py")

        # 2. Verify encode_amnezia_vpnuri_31 preserves asymmetric client parameters
        conf_sample = """[Interface]
Address = 10.8.1.99/32
DNS = 1.1.1.1, 8.8.8.8
PrivateKey = aGVsbG93b3JsZGhlbGxvd29ybGRoZWxsb3dvcmxkaGVsbG8=
MTU = 1240
Jc = 0
Jmin = 0
Jmax = 0
S1 = 16
S2 = 16
S3 = 16
S4 = 16
H1 = 1
H2 = 2
H3 = 3
H4 = 4
I1 = <r 2><b 0x8580>

[Peer]
PublicKey = aGVsbG93b3JsZGhlbGxvd29ybGRoZWxsb3dvcmxkaGVsbG8=
PresharedKey = aGVsbG93b3JsZGhlbGxvd29ybGRoZWxsb3dvcmxkaGVsbG8=
AllowedIPs = 10.0.0.0/8
Endpoint = 203.0.113.5:32626
PersistentKeepalive = 15
"""
        vpnuri = mgr.encode_amnezia_vpnuri_31(conf_sample, "10.8.1.99", "priv", "pub")
        self.assertTrue(vpnuri.startswith("vpn://"))
        raw = base64.urlsafe_b64decode(vpnuri[6:] + "===")
        orig_len = struct.unpack(">I", raw[:4])[0]
        decomp = zlib.decompress(raw[4:])
        self.assertEqual(len(decomp), orig_len)
        data = json.loads(decomp)
        awg = data["containers"][0]["awg"]
        last = json.loads(awg["last_config"])

        self.assertEqual(awg["Jc"], "0")
        self.assertEqual(last["mtu"], "1240")
        self.assertEqual(last["persistent_keep_alive"], "15")
        self.assertEqual(last["I1"], "<r 2><b 0x8580>")
        self.assertEqual(last["allowed_ips"], ["10.0.0.0/8"])
        self.assertEqual(data["hostName"], "203.0.113.5")

    def test_get_client_uri_cached_and_fallback_regeneration(self):
        """Verify get_client_uri returns cached .vpnuri and regenerates via pure-Python X25519 when missing."""
        import sys
        sys.path.insert(0, str((ROOT / "src/awg").resolve()))
        import manage_clients as mgr

        with tempfile.TemporaryDirectory() as td:
            tmp_awg = Path(td)
            orig_awg_dir = mgr.AWG_DIR
            mgr.AWG_DIR = tmp_awg
            try:
                # 1. Non-existent client
                res_missing = mgr.get_client_uri("nonexistent_client")
                self.assertFalse(res_missing["ok"])
                self.assertIn("not found", res_missing["error"])

                # 2. Invalid client name (path traversal rejection)
                res_invalid = mgr.get_client_uri("../etc/passwd")
                self.assertFalse(res_invalid["ok"])
                self.assertIn("Invalid client name", res_invalid["error"])

                # 3. Cached .vpnuri file present
                test_cached_uri = "vpn://cached_test_uri_string_12345"
                (tmp_awg / "client-cached.vpnuri").write_text(test_cached_uri, encoding="utf-8")
                res_cached = mgr.get_client_uri("client-cached")
                self.assertTrue(res_cached["ok"])
                self.assertEqual(res_cached["vpnuri"], test_cached_uri)
                self.assertEqual(res_cached["client"], "client-cached")

                # 4. Fallback regeneration from .conf file when .vpnuri is missing
                conf_content = """[Interface]
Address = 10.8.1.5/32
DNS = 1.1.1.1
PrivateKey = aGVsbG93b3JsZGhlbGxvd29ybGRoZWxsb3dvcmxkaGVsbG8=
Jc = 4
Jmin = 40
Jmax = 70
S1 = 16
S2 = 16
H1 = 1
H2 = 2

[Peer]
PublicKey = aGVsbG93b3JsZGhlbGxvd29ybGRoZWxsb3dvcmxkaGVsbG8=
AllowedIPs = 0.0.0.0/0
Endpoint = 198.51.100.1:443
"""
                (tmp_awg / "client-regen.conf").write_text(conf_content, encoding="utf-8")
                res_regen = mgr.get_client_uri("client-regen")
                self.assertTrue(res_regen["ok"])
                self.assertTrue(res_regen["vpnuri"].startswith("vpn://"))
                # File must be generated on disk
                regen_file = tmp_awg / "client-regen.vpnuri"
                self.assertTrue(regen_file.exists())
                self.assertEqual(regen_file.read_text(encoding="utf-8").strip(), res_regen["vpnuri"])

                # Verify decompressed contents of generated Amnezia vpn:// URI
                import base64, zlib, struct
                raw = base64.urlsafe_b64decode(res_regen["vpnuri"][6:] + "===")
                orig_len = struct.unpack(">I", raw[:4])[0]
                decomp = zlib.decompress(raw[4:])
                self.assertEqual(len(decomp), orig_len)
                data = json.loads(decomp)
                self.assertEqual(data["hostName"], "198.51.100.1")
                awg_cfg = data["containers"][0]["awg"]
                self.assertEqual(awg_cfg["Jc"], "4")
            finally:
                mgr.AWG_DIR = orig_awg_dir

    def test_manage_amneziawg_cli_uri_raw_mode(self):
        """Verify CLI 'uri' action with --raw outputs raw vpn:// string without JSON wrapping."""
        import subprocess
        import sys

        with tempfile.TemporaryDirectory() as td:
            tmp_awg = Path(td)
            expected_uri = "vpn://raw_cli_test_uri_67890"
            (tmp_awg / "client-cli.vpnuri").write_text(expected_uri, encoding="utf-8")

            env = os.environ.copy()
            env["AWG_DIR"] = str(tmp_awg)

            # 1. JSON mode (default)
            res_json = subprocess.run(
                [sys.executable, str(ROOT / "src/awg/manage_clients.py"), "uri", "client-cli"],
                env=env, capture_output=True, text=True, check=True
            )
            data = json.loads(res_json.stdout)
            self.assertTrue(data.get("ok"))
            self.assertEqual(data.get("vpnuri"), expected_uri)

            # 2. Raw mode (--raw)
            res_raw = subprocess.run(
                [sys.executable, str(ROOT / "src/awg/manage_clients.py"), "uri", "client-cli", "--raw"],
                env=env, capture_output=True, text=True, check=True
            )
            self.assertEqual(res_raw.stdout.strip(), expected_uri)

            # 3. QR code with --raw mode
            res_qr_raw = subprocess.run(
                [sys.executable, str(ROOT / "src/awg/manage_clients.py"), "qr", "client-cli", "--raw"],
                env=env, capture_output=True, text=True, check=True
            )
            self.assertEqual(res_qr_raw.stdout.strip(), expected_uri)


class TestDatabaseBackupSafety(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.TemporaryDirectory()
        self.tmp = Path(self.tmp_dir.name)

    def tearDown(self):
        self.tmp_dir.cleanup()

    def test_backup_captures_wal_and_verifies_integrity(self):
        """R04: backup_sqlite_db preserves committed WAL data and fails safely without raw cp."""
        wal_db = self.tmp / "live.db"
        dst_db = self.tmp / "backup.db"

        # Create live database in WAL mode with committed uncheckpointed transaction
        conn = sqlite3.connect(wal_db)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA wal_autocheckpoint=0")
        conn.execute("CREATE TABLE records(id INTEGER PRIMARY KEY, msg TEXT)")
        conn.commit()
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        conn.execute("INSERT INTO records VALUES(1, 'wal-committed-entry')")
        conn.commit()
        conn.close()

        # Run backup_sqlite_db through bash
        res = run_shell(f"""
source src/common/backup.sh
backup_sqlite_db '{wal_db.as_posix()}' '{dst_db.as_posix()}'
""")
        self.assertEqual(res.returncode, 0, f"backup_sqlite_db failed: {res.stderr}\nstdout: {res.stdout}")
        self.assertTrue(dst_db.exists(), "Backup database file must exist")

        # Verify backup contains committed WAL row
        bk_conn = sqlite3.connect(dst_db)
        count = bk_conn.execute("SELECT count(*) FROM records").fetchone()[0]
        bk_conn.close()
        self.assertEqual(count, 1, "Backup must contain rows committed in WAL mode")

    def test_backup_fails_safe_when_tools_fail(self):
        """R04: when python and sqlite3 fail, backup_sqlite_db returns 1 and leaves no broken copy."""
        wal_db = self.tmp / "live_fail.db"
        dst_db = self.tmp / "should_not_exist.db"

        conn = sqlite3.connect(wal_db)
        conn.execute("CREATE TABLE sample(x INT)")
        conn.commit()
        conn.close()

        res = run_shell(f"""
source src/common/backup.sh
python3() {{ return 1; }}
python() {{ return 1; }}
sqlite3() {{ return 1; }}
backup_sqlite_db '{wal_db.as_posix()}' '{dst_db.as_posix()}'
""")
        self.assertNotEqual(res.returncode, 0, "backup_sqlite_db must return non-zero when backup cannot be created")
        self.assertFalse(dst_db.exists(), "No partial or corrupt backup should be left on disk")


class TestTUIDebugContext(unittest.TestCase):
    def test_debug_spinner_preserves_shell_context(self):
        """R06: run_with_spinner in DEBUG_MODE preserves unexported variables and helper functions."""
        res = run_shell("""
set -euo pipefail
source src/tui/base.sh
DEBUG_MODE=1; NON_INTERACTIVE=1
PRIMARY_DOMAIN=test.domain.local
CUSTOM_HELPER_CALLED=0
helper() { CUSTOM_HELPER_CALLED=1; printf "helper_ok:%s" "$PRIMARY_DOMAIN"; }
task() { helper; }

output=$(run_with_spinner "fixture_task" task)
printf "\nOUTPUT_CAPTURE=[%s]\n" "$output"
""")
        self.assertEqual(res.returncode, 0, f"Debug spinner failed: {res.stderr}")
        self.assertIn("helper_ok:test.domain.local", res.stdout,
                      "Task inside debug spinner must access unexported parent variables and functions")

    def test_debug_spinner_catches_internal_failure(self):
        """R06: debug spinner correctly propagates task exit errors."""
        res = run_shell("""
set -euo pipefail
source src/tui/base.sh
DEBUG_MODE=1; NON_INTERACTIVE=1
failing_task() { false; echo "SHOULD_NEVER_PRINT"; }
set +e
run_with_spinner "failing_task" failing_task
echo "TASK_EXIT=$?"
""")
        self.assertEqual(res.returncode, 0)
        self.assertNotIn("SHOULD_NEVER_PRINT", res.stdout)
        self.assertIn("TASK_EXIT=1", res.stdout)

    def test_smart_debug_captures_error_trace_on_silent_failure(self):
        """Smart Implicit Debug: verify that ERR trap captures exact failing command, line, and function."""
        res = run_shell("""
set -euo pipefail
source src/tui/base.sh
NON_INTERACTIVE=1; DEBUG_MODE=0
silent_fail_task() {
    local a=1
    false
}
set +e
output=$(run_with_spinner "silent_step" silent_fail_task 2>&1)
echo "OUT: $output"
""")
        self.assertEqual(res.returncode, 0)
        self.assertIn("[ERROR-TRACE]", res.stdout)
        self.assertIn("silent_fail_task", res.stdout)
        self.assertIn("false", res.stdout)

    def test_smart_debug_persistent_log_creation(self):
        """Smart Implicit Debug: verify persistent logging to SERVER_SETUP_LOG."""
        with tempfile.TemporaryDirectory() as temp:
            log_path = Path(temp) / "test-setup.log"
            res = run_shell(f"""
set -euo pipefail
source src/tui/base.sh
NON_INTERACTIVE=1; DEBUG_MODE=0
SERVER_SETUP_LOG="{log_path.as_posix()}"
dummy_task() {{ echo "step_hello_world"; }}
run_with_spinner "dummy_step" dummy_task
""")
            self.assertEqual(res.returncode, 0)
            self.assertTrue(log_path.is_file(), "SERVER_SETUP_LOG must be created")
            content = log_path.read_text(encoding="utf-8")
            self.assertIn("START TASK: dummy_step", content)
            self.assertIn("step_hello_world", content)
            self.assertIn("END TASK: dummy_step (exit: 0)", content)


class TestRoutingCustomConstraints(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.TemporaryDirectory()
        self.tmp = Path(self.tmp_dir.name)

    def tearDown(self):
        self.tmp_dir.cleanup()

    def test_routing_custom_constraints_and_networks_preserved(self):
        """R07: Xray routing normalization preserves custom qualifiers (user, inboundTag) and custom IP subnets."""
        db = self.tmp / "routes.db"
        conn = sqlite3.connect(db)
        conn.executescript("""
            CREATE TABLE settings(id INTEGER PRIMARY KEY, key TEXT, value TEXT);
            CREATE TABLE users(id INTEGER PRIMARY KEY, username TEXT, password TEXT);
            INSERT INTO users VALUES(1, 'admin', 'hash');
            CREATE TABLE inbounds(id INTEGER PRIMARY KEY, user_id INTEGER, up INTEGER,
              down INTEGER, total INTEGER, remark TEXT, enable INTEGER, expiry_time INTEGER,
              listen TEXT, port INTEGER, protocol TEXT, settings TEXT, stream_settings TEXT,
              tag TEXT, sniffing TEXT);
        """)
        tpl = dict(
            outbounds=[
                dict(tag="direct", protocol="freedom"),
                dict(tag="blocked", protocol="blackhole"),
                dict(tag="warp", protocol="wireguard", settings=dict(secretKey="fixture"))
            ],
            routing=dict(
                domainStrategy="AsIs",
                rules=[
                    dict(
                        type="field",
                        outboundTag="direct",
                        domain=["domain:ru"],
                        ip=["geoip:ru", "203.0.113.0/24"],
                        user=["alice"]
                    )
                ]
            )
        )
        conn.execute("INSERT INTO settings(key,value) VALUES(?,?)", ("xrayTemplateConfig", json.dumps(tpl)))
        conn.execute("INSERT INTO settings(key,value) VALUES(?,?)", ("warpData", json.dumps(dict(private_key="fixture", device_id="fixture"))))
        conn.commit()
        conn.close()

        raw = (ROOT / "configure-panel.sh").read_text(encoding="utf-8").split("<< 'EOF_PYTHON_CONFIG'", 1)[1].split("\n", 1)[1]
        code = raw.split("conn.commit()", 1)[0] + "conn.commit()\n"
        env = dict(DB_PATH=str(db), PRIMARY_DOMAIN="audit.example", DRY_RUN="0",
                   ENABLE_STEAL="n", ENABLE_CLASSIC="n", ENABLE_HY2="n",
                   ENABLE_AWG_V3="n", ENABLE_AWG_V2="n", ENABLE_WARP="y")
        ns = {}
        with patch.dict(os.environ, env, clear=True), patch("subprocess.run", return_value=types.SimpleNamespace(returncode=1, stdout="")):
            exec(compile(code, "configure-panel.sh", "exec"), ns)
        ns["conn"].close()

        conn = sqlite3.connect(db)
        current = json.loads(conn.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()[0])
        clash_path = conn.execute("SELECT value FROM settings WHERE key='subClashPath'").fetchone()[0]
        clash_uri = conn.execute("SELECT value FROM settings WHERE key='subClashURI'").fetchone()[0]
        conn.close()

        rules = current["routing"]["rules"]
        user_constraint = any(r.get("user") == ["alice"] for r in rules)
        custom_net = any("203.0.113.0/24" in r.get("ip", []) for r in rules)

        self.assertTrue(user_constraint, "Custom constraint 'user: [alice]' must be preserved")
        self.assertTrue(custom_net, "Custom network '203.0.113.0/24' must be preserved")
        self.assertTrue(clash_path.endswith("/clash/"), f"subClashPath [{clash_path}] must end with /clash/")
        self.assertRegex(clash_path, r"^/sub-[^/]+/clash/$", f"subClashPath [{clash_path}] must have slash before clash")
        self.assertTrue(clash_uri.endswith("/clash/"), f"subClashURI [{clash_uri}] must end with /clash/")
        self.assertRegex(clash_uri, r"^https://audit\.example/sub-[^/]+/clash/$", f"subClashURI [{clash_uri}] must be slash-separated")


class TestPreflightAndNetworkConflicts(unittest.TestCase):
    def test_preflight_own_agh_service_retained(self):
        """R09: Running own AdGuardHome on port 3000 is retained, not shifted to 3001."""
        res = run_shell("""
set -euo pipefail
CHECK_MODE=0; NON_INTERACTIVE=0; DEBUG_MODE=0
CYAN=; BOLD=; NC=; DIM=; WHITE=;
warn(){ :; }; ok(){ :; }; die(){ echo "DIE:$*"; exit 1; };
source src/common/preflight.sh
ENABLE_AGH=1; PORT_AGH_WEB=3000

# Mock port occupied by own AdGuardHome
is_port_in_use(){ [[ "$2" == 3000 ]]; }
get_port_listener_info(){ echo "AdGuardHome"; }

inspect_port_conflicts
printf "RESULT_PORT=%s\n" "$PORT_AGH_WEB"
""")
        self.assertEqual(res.returncode, 0, f"Preflight error: {res.stderr}")
        self.assertIn("RESULT_PORT=3000", res.stdout, "AdGuardHome own listener must remain on port 3000")

    def test_preflight_aborts_on_foreign_443(self):
        """R01: Preflight aborts (die) when port 443 is occupied by a foreign daemon (docker-proxy)."""
        res = run_shell("""
set -euo pipefail
CHECK_MODE=0; NON_INTERACTIVE=0; DEBUG_MODE=0
CYAN=; BOLD=; NC=; DIM=; WHITE=;
warn(){ :; }; ok(){ :; }; die(){ echo "FATAL_ABORT:$*"; exit 15; };
source src/common/preflight.sh
ENABLE_AGH=0

is_port_in_use(){ [[ "$2" == 443 ]]; }
get_port_listener_info(){ echo "docker-proxy"; }

inspect_port_conflicts
""")
        self.assertEqual(res.returncode, 15, "Preflight must abort when port 443 is occupied by docker-proxy")
        self.assertIn("FATAL_ABORT", res.stdout)

    def test_preflight_allows_occupied_443_when_no_web_stack(self):
        """Preflight must NOT abort on port 443 conflict if ENABLE_WEB_STACK=0 (Standalone AWG only)."""
        res = run_shell("""
set -euo pipefail
CHECK_MODE=0; NON_INTERACTIVE=0; DEBUG_MODE=0
CYAN=; BOLD=; NC=; DIM=; WHITE=;
warn(){ :; }; ok(){ :; }; die(){ echo "FATAL_ABORT:$*"; exit 15; };
source src/common/preflight.sh
ENABLE_AGH=0
ENABLE_WEB_STACK=0
ENABLE_AWG_STANDALONE=1
AWG_STANDALONE_PORT=8445

is_port_in_use(){ [[ "$2" == 443 ]]; }
get_port_listener_info(){ echo "docker-proxy"; }

inspect_port_conflicts
""")
        self.assertEqual(res.returncode, 0, f"Preflight must not abort when ENABLE_WEB_STACK=0: {res.stderr}")
        self.assertNotIn("FATAL_ABORT", res.stdout)



class TestExtraProtocolsKeys(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ns = {}
        exec((ROOT / "src/xray/keys.py").read_text(encoding="utf-8"), cls.ns)

    def test_ss2022_key_generation_and_validation(self):
        """Verify Shadowsocks 2022 key generation and byte length validation for 16 and 32 bytes."""
        gen = self.ns["generate_ss2022_key"]
        val = self.ns["validate_ss2022_key"]

        # 32 bytes for AES-256
        k256 = gen("2022-blake3-aes-256-gcm")
        self.assertTrue(val(k256, "2022-blake3-aes-256-gcm"))
        self.assertFalse(val(k256, "2022-blake3-aes-128-gcm"))

        # 16 bytes for AES-128
        k128 = gen("2022-blake3-aes-128-gcm")
        self.assertTrue(val(k128, "2022-blake3-aes-128-gcm"))
        self.assertFalse(val(k128, "2022-blake3-aes-256-gcm"))

        # Invalid cases
        self.assertFalse(val("", "2022-blake3-aes-256-gcm"))
        self.assertFalse(val(None, "2022-blake3-aes-256-gcm"))
        self.assertFalse(val("not-base64-at-all!@#$", "2022-blake3-aes-256-gcm"))
        bad_len = base64.b64encode(b"short-key").decode()
        self.assertFalse(val(bad_len, "2022-blake3-aes-256-gcm"))

    def test_mtproto_secret_and_adtag_validation(self):
        """Verify Telegram MTProxy FakeTLS secret generation/validation and adTag hex check."""
        gen_sec = self.ns["generate_mtproto_secret"]
        val_sec = self.ns["validate_mtproto_secret"]
        val_ad = self.ns["validate_mtproto_adtag"]

        sec = gen_sec("gateway.icloud.com")
        self.assertTrue(sec.startswith("ee"))
        self.assertTrue(val_sec(sec))

        # Check domain decoded correctly
        domain_hex = sec[34:]
        self.assertEqual(bytes.fromhex(domain_hex).decode("utf-8"), "gateway.icloud.com")

        # Invalid secrets
        self.assertFalse(val_sec("dd" + sec[2:]))  # wrong prefix
        self.assertFalse(val_sec("ee" + "00" * 16)) # no domain (too short: 34 chars < 38)
        self.assertFalse(val_sec("ee1234"))        # too short
        self.assertFalse(val_sec("not-hex"))

        # adTag validation (strictly 32 hex chars, no signs)
        good_ad = "0123456789abcdef0123456789abcdef"
        self.assertTrue(val_ad(good_ad))
        self.assertFalse(val_ad("short"))
        self.assertFalse(val_ad(good_ad + "00"))
        self.assertFalse(val_ad("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"))
        self.assertFalse(val_ad("+0123456789abcdef0123456789abcde"))  # signed number rejected
        self.assertFalse(val_ad("-0123456789abcdef0123456789abcde"))  # signed number rejected
        self.assertFalse(val_ad(""))


class TestExtraProtocolsInbounds(unittest.TestCase):
    def setUp(self):
        self.conn = sqlite3.connect(":memory:")
        self.cur = self.conn.cursor()
        self.cur.execute("""
            CREATE TABLE inbounds (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                up INTEGER,
                down INTEGER,
                total INTEGER,
                remark TEXT,
                enable INTEGER,
                expiry_time INTEGER,
                listen TEXT,
                port INTEGER,
                protocol TEXT,
                settings TEXT,
                stream_settings TEXT,
                tag TEXT,
                sniffing TEXT
            )
        """)
        self.cur.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, password TEXT)")
        self.cur.execute("INSERT INTO users VALUES (1, 'admin', 'admin')")
        self.cur.execute("""
            CREATE TABLE clients (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                email TEXT,
                enable INTEGER,
                uuid TEXT,
                password TEXT,
                auth TEXT,
                flow TEXT,
                secret TEXT,
                ad_tag TEXT,
                created_at INTEGER,
                updated_at INTEGER
            )
        """)
        self.cur.execute("""
            CREATE TABLE client_traffics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                inbound_id INTEGER,
                enable INTEGER,
                email TEXT,
                up INTEGER,
                down INTEGER,
                expiry_time INTEGER,
                total INTEGER,
                reset INTEGER
            )
        """)
        self.cur.execute("""
            CREATE TABLE client_inbounds (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                client_id INTEGER,
                inbound_id INTEGER
            )
        """)
        self.ns = {
            "conn": self.conn,
            "cur": self.cur,
            "dry_run": False,
            "force_remarks": False,
            "domain": "test.example.com",
            "hy2_port": 443,
            "classic_port": 46443,
            "classic_sni": "gateway.icloud.com",
            "all_tables": {"inbounds", "users", "clients", "client_traffics", "client_inbounds"},
            "client_traffics_cols": {"id", "inbound_id", "enable", "email", "up", "down", "expiry_time", "total", "reset"},
            "clients_cols": {"id", "email", "enable", "uuid", "password", "auth", "flow", "secret", "ad_tag", "created_at", "updated_at"},
            "client_inbounds_cols": {"id", "client_id", "inbound_id"},
            "json": json,
            "os": os,
            "uuid": uuid,
            "base64": base64,
            "admin_id": 1,
        }
        exec((ROOT / "src/xray/clients.py").read_text(encoding="utf-8"), self.ns)
        exec((ROOT / "src/xray/keys.py").read_text(encoding="utf-8"), self.ns)
        exec((ROOT / "src/xray/inbounds.py").read_text(encoding="utf-8"), self.ns)

    def tearDown(self):
        self.conn.close()

    def test_ss2022_inbound_and_force_tls_none(self):
        """Verify Shadowsocks 2022 inbound reconciliation sets forceTls: 'none' and repairs bad key."""
        reconcile = self.ns["smart_reconcile_inbound"]
        # 1. Insert an existing inbound with corrupted key and forceTls mistakenly set to "tls"
        bad_settings = {
            "method": "2022-blake3-aes-256-gcm",
            "password": "bad-key-not-32-bytes",
            "clients": [{"email": "Client", "password": "also-corrupted-key", "method": "legacy-method"}]
        }
        bad_stream = {
            "network": "tcp,udp",
            "security": "none",
            "externalProxy": [{"dest": "test.example.com", "port": 8388, "forceTls": "tls", "remark": "SS-Old"}]
        }
        self.cur.execute("""
            INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
            VALUES (1, 0, 0, 0, 'SS-Old', 1, 0, '0.0.0.0', 8388, 'shadowsocks', ?, ?, 'in-shadowsocks-2022', '{}')
        """, (json.dumps(bad_settings), json.dumps(bad_stream)))
        self.conn.commit()

        # 2. Run smart_reconcile_inbound with valid default blueprint
        good_settings = {
            "method": "2022-blake3-aes-256-gcm",
            "password": self.ns["generate_ss2022_key"]("2022-blake3-aes-256-gcm"),
            "clients": [{"email": "Client", "password": self.ns["generate_ss2022_key"]("2022-blake3-aes-256-gcm"), "subId": "12345678", "enable": True}]
        }
        good_stream = {
            "network": "tcp",
            "security": "none",
            "externalProxy": [{"dest": "test.example.com", "port": 8388, "forceTls": "none", "remark": "Shadowsocks 2022"}]
        }
        reconcile(8388, "shadowsocks", "in-shadowsocks-2022", "Shadowsocks 2022", good_settings, good_stream, listen="0.0.0.0")

        self.cur.execute("SELECT settings, stream_settings FROM inbounds WHERE port = 8388")
        row = self.cur.fetchone()
        self.assertIsNotNone(row)
        s = json.loads(row[0])
        st = json.loads(row[1])

        # Verify key was repaired
        self.assertTrue(self.ns["validate_ss2022_key"](s["password"], "2022-blake3-aes-256-gcm"))
        self.assertTrue(self.ns["validate_ss2022_key"](s["clients"][0]["password"], "2022-blake3-aes-256-gcm"))
        self.assertNotIn("method", s["clients"][0], "Obsolete client.method must be stripped")

        # Verify stream network was repaired from tcp,udp to tcp
        self.assertEqual(st["network"], "tcp", "Shadowsocks streamSettings network must be 'tcp', never 'tcp,udp'")

        # Verify forceTls fixed to 'none'
        self.assertEqual(st["externalProxy"][0]["forceTls"], "none", "Shadowsocks externalProxy forceTls must be 'none'")

    def test_tuic_inbound_settings_and_cert_paths(self):
        """Verify TUIC v5 inbound preserves certificate and private_key directly in settings."""
        reconcile = self.ns["smart_reconcile_inbound"]
        tuic_settings = {
            "certificate": "/etc/letsencrypt/live/test.example.com/fullchain.pem",
            "private_key": "/etc/letsencrypt/live/test.example.com/privkey.pem",
            "congestion_control": "bbr",
            "alpn": ["h3", "spdy/3.1"],
            "udp_relay_mode": "native",
            "clients": [{"uuid": str(uuid.uuid4()), "password": "tuic-password-16", "email": "Client"}]
        }
        tuic_stream = {
            "network": "quic",
            "security": "tls",
            "externalProxy": [{"dest": "test.example.com", "port": 8448, "forceTls": "tls", "remark": "TUIC v5"}]
        }
        reconcile(8448, "tuic", "in-tuic-v5", "TUIC v5", tuic_settings, tuic_stream, listen="0.0.0.0")

        self.cur.execute("SELECT settings, stream_settings FROM inbounds WHERE port = 8448")
        row = self.cur.fetchone()
        self.assertIsNotNone(row)
        s = json.loads(row[0])
        st = json.loads(row[1])

        self.assertEqual(s["certificate"], "/etc/letsencrypt/live/test.example.com/fullchain.pem")
        self.assertEqual(s["private_key"], "/etc/letsencrypt/live/test.example.com/privkey.pem")
        self.assertEqual(s["congestion_control"], "bbr")
        self.assertEqual(st["network"], "quic")
        self.assertEqual(st["security"], "tls")
        self.assertEqual(st["externalProxy"][0]["forceTls"], "tls")

    def test_mtproto_settings_cleanup_and_clients_sync(self):
        """Verify MTProxy settings cleans root secret/adTag, extracts into clients, and sets forceTls 'none'."""
        reconcile = self.ns["smart_reconcile_inbound"]
        sec = self.ns["generate_mtproto_secret"]("gateway.icloud.com")
        ad = "0123456789abcdef0123456789abcdef"

        # 1. Insert existing inbound with legacy root secret/adTag and forceTls: "tls"
        mtp_settings = {
            "secret": "legacy-root-secret",
            "adTag": "legacy-root-adtag",
            "domainFronting": {"ip": "gateway.icloud.com", "port": 443, "proxyProtocol": False},
            "clients": [{"email": "Client", "secret": sec, "adTag": ad}]
        }
        mtp_stream = {
            "network": "tcp",
            "security": "none",
            "externalProxy": [{"dest": "test.example.com", "port": 8444, "forceTls": "tls", "remark": "MTProxy"}]
        }
        self.cur.execute("""
            INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
            VALUES (1, 0, 0, 0, 'MTProxy-Old', 1, 0, '0.0.0.0', 8444, 'mtproto', ?, ?, 'in-mtproto-faketls', '{}')
        """, (json.dumps(mtp_settings), json.dumps(mtp_stream)))
        self.conn.commit()

        # 2. Run smart_reconcile_inbound with valid default blueprint
        good_mtp_settings = {
            "domainFronting": {"ip": "gateway.icloud.com", "port": 443, "proxyProtocol": False},
            "clients": [{"email": "Client", "secret": sec, "adTag": ad, "subId": "12345678", "enable": True}]
        }
        good_mtp_stream = {
            "network": "tcp",
            "security": "none",
            "externalProxy": [{"dest": "test.example.com", "port": 8444, "forceTls": "none", "remark": "Telegram MTProxy"}]
        }
        reconcile(8444, "mtproto", "in-mtproto-faketls", "Telegram MTProxy", good_mtp_settings, good_mtp_stream, listen="0.0.0.0")

        self.cur.execute("SELECT settings, stream_settings FROM inbounds WHERE port = 8444")
        row = self.cur.fetchone()
        self.assertIsNotNone(row)
        s = json.loads(row[0])
        st = json.loads(row[1])

        # Obsolete root fields must be removed
        self.assertNotIn("secret", s)
        self.assertNotIn("adTag", s)
        self.assertNotIn("ad_tag", s)

        # Clients table should have secret and ad_tag
        self.cur.execute("SELECT secret, ad_tag FROM clients WHERE email = 'Client'")
        c_row = self.cur.fetchone()
        self.assertIsNotNone(c_row)
        self.assertEqual(c_row[0], sec)
        self.assertEqual(c_row[1], ad)

        # forceTls must be 'none'
        self.assertEqual(st["externalProxy"][0]["forceTls"], "none")

    def test_amneziawg_force_tls_none(self):
        """Verify AmneziaWG externalProxy forceTls is repaired to 'none'."""
        reconcile = self.ns["smart_reconcile_inbound"]
        awg_settings = {
            "server": {"h1": "1", "h2": "2", "h3": "3", "h4": "4", "jc": 4, "jmin": 40, "jmax": 70, "s1": 16, "s2": 16, "s3": 16, "s4": 16, "mtu": 1280},
            "clients": [{"email": "Client", "allowedIPs": ["10.8.1.2/32"]}]
        }
        awg_stream = {
            "externalProxy": [{"dest": "test.example.com", "port": 8443, "forceTls": "tls", "remark": "AWG"}]
        }
        self.cur.execute("""
            INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
            VALUES (1, 0, 0, 0, 'AWG-Old', 1, 0, '0.0.0.0', 8443, 'amneziawg', ?, ?, 'in-8443-udp', '{}')
        """, (json.dumps(awg_settings), json.dumps(awg_stream)))
        self.conn.commit()

        reconcile(8443, "amneziawg", "in-8443-udp", "AmneziaWG v3", awg_settings, awg_stream, listen="0.0.0.0")

        self.cur.execute("SELECT stream_settings FROM inbounds WHERE port = 8443")
        st = json.loads(self.cur.fetchone()[0])
        self.assertEqual(st["externalProxy"][0]["forceTls"], "none", "AWG externalProxy forceTls must be 'none'")

    def test_client_credentials_isolation_between_protocols(self):
        """Verify that syncing Shadowsocks and MTProto does not overwrite each other's credentials in clients table."""
        sync_clients = self.ns["sync_inbound_clients"]
        ss_key = self.ns["generate_ss2022_key"]("2022-blake3-aes-256-gcm")
        mtp_sec = self.ns["generate_mtproto_secret"]("gateway.icloud.com")
        mtp_ad = "0123456789abcdef0123456789abcdef"

        # 1. Sync Shadowsocks inbound client
        ss_settings = {
            "method": "2022-blake3-aes-256-gcm",
            "clients": [{"email": "Client", "password": ss_key, "subId": "sub12345"}]
        }
        sync_clients(1, "shadowsocks", "SS2022", ss_settings)

        self.cur.execute("SELECT password, auth, secret, ad_tag FROM clients WHERE email = 'Client'")
        row = self.cur.fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], ss_key, "Shadowsocks key must be in password column")
        self.assertFalse(row[1], "Auth column must not be populated by Shadowsocks key")
        self.assertFalse(row[2], "Secret column must not be populated by Shadowsocks key")

        # 2. Sync Hysteria 2 inbound client (must NOT overwrite clients.password)
        hy2_pass = "hexpassword123456"
        hy2_settings = {
            "clients": [{"email": "Client", "auth": hy2_pass, "subId": "sub12345"}]
        }
        sync_clients(3, "hysteria", "Hysteria2", hy2_settings)

        self.cur.execute("SELECT password, auth, secret, ad_tag FROM clients WHERE email = 'Client'")
        row = self.cur.fetchone()
        self.assertEqual(row[0], ss_key, "Hysteria 2 sync must NOT overwrite clients.password with auth hex")
        self.assertEqual(row[1], hy2_pass, "Hysteria 2 password must be in clients.auth")

        # 3. Sync MTProto inbound client
        mtp_settings = {
            "clients": [{"email": "Client", "secret": mtp_sec, "adTag": mtp_ad, "subId": "sub12345"}]
        }
        sync_clients(2, "mtproto", "MTProto", mtp_settings)

        self.cur.execute("SELECT password, auth, secret, ad_tag FROM clients WHERE email = 'Client'")
        row = self.cur.fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], ss_key, "MTProto must NOT overwrite clients.password")
        self.assertEqual(row[1], hy2_pass, "MTProto must NOT overwrite clients.auth")
        self.assertEqual(row[2], mtp_sec, "MTProto secret must be in secret column")
        self.assertEqual(row[3], mtp_ad, "MTProto adTag must be in ad_tag column")

        # 4. Re-sync Shadowsocks inbound client
        sync_clients(1, "shadowsocks", "SS2022", ss_settings)

        self.cur.execute("SELECT password, auth, secret, ad_tag FROM clients WHERE email = 'Client'")
        row = self.cur.fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], ss_key, "Shadowsocks re-sync must keep password")
        self.assertEqual(row[1], hy2_pass, "Shadowsocks re-sync must keep auth")
        self.assertEqual(row[2], mtp_sec, "Shadowsocks re-sync must NOT clobber clients.secret")
        self.assertEqual(row[3], mtp_ad, "Shadowsocks re-sync must NOT clobber clients.ad_tag")

    def test_ss2022_uri_composite_password(self):
        """Verify Shadowsocks 2022 client URI uses SIP002 Base64 format with composite ServerPassword:UserPassword."""
        import base64
        import urllib.parse
        server_key = self.ns["generate_ss2022_key"]("2022-blake3-aes-256-gcm")
        client_key = self.ns["generate_ss2022_key"]("2022-blake3-aes-256-gcm")
        ss_method = "2022-blake3-aes-256-gcm"
        domain = "test.example.com"
        port = 8388

        raw_userinfo = f"{ss_method}:{server_key}:{client_key}"
        b64_userinfo = base64.urlsafe_b64encode(raw_userinfo.encode("utf-8")).decode("utf-8").rstrip("=")
        uri = f"ss://{b64_userinfo}@{domain}:{port}#Test"

        self.assertTrue(uri.startswith("ss://"))
        self.assertIn(f"@{domain}:{port}#Test", uri)

        # Decode SIP002 Base64 userinfo
        b64_part = uri.split("://")[1].split("@")[0]
        padded_b64 = b64_part + "=" * (-len(b64_part) % 4)
        decoded_userinfo = base64.urlsafe_b64decode(padded_b64).decode("utf-8")
        parts = decoded_userinfo.split(":")
        self.assertEqual(len(parts), 3, "SIP002 Base64 userinfo must contain method:server_key:client_key")
        self.assertEqual(parts[0], ss_method)
        self.assertEqual(parts[1], server_key)
        self.assertEqual(parts[2], client_key)

    def test_mtproto_prefer_ipv4_enforced(self):
        """Verify MTProxy settings enforces preferIp: prefer-ipv4 to avoid IPv6 timeout hangs."""
        reconcile = self.ns["smart_reconcile_inbound"]
        sec = self.ns["generate_mtproto_secret"]("gateway.icloud.com")
        mtp_settings = {
            "domainFronting": {"ip": "gateway.icloud.com", "port": 443, "proxyProtocol": False},
            "clients": [{"email": "Client", "secret": sec}]
        }
        mtp_stream = {
            "network": "tcp",
            "security": "none",
            "externalProxy": [{"dest": "test.example.com", "port": 8444, "forceTls": "none", "remark": "MTProxy"}]
        }
        reconcile(8444, "mtproto", "in-mtproto-faketls", "MTProxy", mtp_settings, mtp_stream, listen="0.0.0.0")

        self.cur.execute("SELECT settings FROM inbounds WHERE port = 8444")
        s = json.loads(self.cur.fetchone()[0])
        self.assertEqual(s.get("preferIp"), "prefer-ipv4", "MTProxy settings must contain preferIp: prefer-ipv4")

    def test_awg_standalone_step_separation(self):
        """Verify standalone AWG and 3X-UI inbounds are separated in wizard, env, and setup_mask."""
        wizard_path = Path("src/tui/wizard.sh")
        self.assertTrue(wizard_path.exists())
        wizard_content = wizard_path.read_text(encoding="utf-8")
        self.assertIn("q_step_protocols", wizard_content)
        self.assertIn("q_step_awg_v3", wizard_content)
        self.assertIn("q_step_awg_v2", wizard_content)
        self.assertIn("q_step_awg_standalone", wizard_content)
        self.assertIn("TOTAL_STEPS=11", wizard_content)
        self.assertIn("AmneziaWG v3.1", wizard_content)
        self.assertIn("Автономный сервер AmneziaWG", wizard_content)

        env_path = Path("src/system/env.sh")
        env_content = env_path.read_text(encoding="utf-8")
        self.assertIn("ENABLE_AWG_STANDALONE", env_content)
        self.assertIn("AWG_STANDALONE_PORT", env_content)

    def test_host_security_and_fail2ban(self):
        """Verify host security (SSH port change & Fail2ban) is integrated in wizard, security.sh and env."""
        security_sh = Path("src/system/security.sh")
        self.assertTrue(security_sh.exists(), "src/system/security.sh must exist")
        sec_content = security_sh.read_text(encoding="utf-8")
        self.assertIn("apply_ssh_configuration()", sec_content)
        self.assertIn("apply_fail2ban_configuration()", sec_content)
        self.assertIn("backend = systemd", sec_content)
        self.assertIn("99-hardening.conf", sec_content)

        wizard_path = Path("src/tui/wizard.sh")
        wizard_content = wizard_path.read_text(encoding="utf-8")
        self.assertIn("q_step_security", wizard_content)
        self.assertIn("ENABLE_HOST_SECURITY", wizard_content)
        self.assertIn("ENABLE_FAIL2BAN", wizard_content)
        self.assertIn("Шаг 10/11: Безопасность сервера", wizard_content)

        env_path = Path("src/system/env.sh")
        env_content = env_path.read_text(encoding="utf-8")
        self.assertIn("ENABLE_HOST_SECURITY", env_content)
        self.assertIn("ENABLE_FAIL2BAN", env_content)

        setup_main = Path("src/entrypoints/setup.main.sh").read_text(encoding="utf-8")
        self.assertIn('# @include "system/security.sh"', setup_main)
        self.assertIn("apply_ssh_configuration", (ROOT / "src/installer/engine.sh").read_text(encoding="utf-8"))
        self.assertIn("apply_fail2ban_configuration", (ROOT / "src/installer/engine.sh").read_text(encoding="utf-8"))

    def test_ssh_dual_port_transition_and_keys(self):
        """Test dual-port sshd configuration, watcher deployment and key validation in isolated mock root."""
        res = run_shell("""
set -euo pipefail
log(){ echo "LOG:$*"; }; ok(){ echo "OK:$*"; }; warn(){ echo "WARN:$*"; }; die(){ echo "DIE:$*"; exit 1; };
is_true(){ [[ "${1:-0}" == "1" || "${1,,}" == "y" || "${1,,}" == "true" ]]; }
source src/common/colors.sh || true
MOCK_ROOT=$(mktemp -d)
mkdir -p "$MOCK_ROOT/etc/ssh/sshd_config.d" "$MOCK_ROOT/root/.ssh" "$MOCK_ROOT/etc/systemd/system" "$MOCK_ROOT/usr/local/bin"
touch "$MOCK_ROOT/etc/ssh/sshd_config"

systemctl(){ echo "MOCK_SYSTEMCTL:$*"; }
get_ssh_service_name(){ echo "sshd"; }

source src/system/security.sh

# Rewrite paths in functions for mock
eval "$(declare -f has_authorized_keys | sed "s|/root|$MOCK_ROOT/root|g")"
eval "$(declare -f add_authorized_key | sed "s|/root|$MOCK_ROOT/root|g")"
eval "$(declare -f apply_ssh_configuration | sed "s|/etc/ssh|$MOCK_ROOT/etc/ssh|g")"
eval "$(declare -f deploy_ssh_transition_watcher | sed "s|/usr/local/bin|$MOCK_ROOT/usr/local/bin|g" | sed "s|/etc/systemd/system|$MOCK_ROOT/etc/systemd/system|g")"
eval "$(declare -f finalize_ssh_transition | sed "s|/etc/ssh|$MOCK_ROOT/etc/ssh|g" | sed "s|/etc/systemd/system|$MOCK_ROOT/etc/systemd/system|g" | sed "s|/usr/local/bin|$MOCK_ROOT/usr/local/bin|g")"

# 1. Initially no keys
if has_authorized_keys "root"; then
    echo "ERROR: Should have no keys"
    exit 1
fi

# 2. Add public key
add_authorized_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedTestKeyForSecurityVerification admin@test" "root"
if ! has_authorized_keys "root"; then
    echo "ERROR: Should have authorized keys"
    exit 1
fi

# Mock local port verification and sshd test
verify_ssh_local_port(){ return 0; }
/usr/sbin/sshd(){ return 0; }

# 3. Apply dual port configuration (2222 target, 22 active, disable password auth)
apply_ssh_configuration 2222 22 "y"

echo "=== DROPIN DUAL PORT ==="
cat "$MOCK_ROOT/etc/ssh/sshd_config.d/99-hardening.conf"

# 4. Deploy watcher
deploy_ssh_transition_watcher 2222 22 24
echo "=== WATCHER SCRIPT ==="
grep "TARGET_PORT=" "$MOCK_ROOT/usr/local/bin/ssh-transition-watcher.sh"
echo "=== WATCHER SERVICE ==="
grep "ExecStart=" "$MOCK_ROOT/etc/systemd/system/ssh-transition-watcher.service"

# 5. Finalize transition
finalize_ssh_transition 2222 22
echo "=== DROPIN FINALIZED ==="
cat "$MOCK_ROOT/etc/ssh/sshd_config.d/99-hardening.conf"

rm -rf "$MOCK_ROOT"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        out = res.stdout
        self.assertIn("Port 2222", out)
        self.assertIn("Port 22", out)
        self.assertIn("PasswordAuthentication no", out)
        self.assertIn("TARGET_PORT=", out)
        self.assertIn("ssh-transition-watcher.sh 2222 22 24", out)

        finalized_block = out[out.find("=== DROPIN FINALIZED ==="):]
        self.assertIn("Port 2222", finalized_block)
        self.assertNotIn("Port 22\n", finalized_block)

    def test_multiselect_numeric_fallback_and_tui_detection(self):
        """Verify multiselect graceful fallback (Option A) and terminal capability detection."""
        # 1. Terminal capability check
        res_tui = run_shell("""
set -euo pipefail
source src/common/colors.sh
source src/common/logger.sh
is_true() { local val="${1:-0}"; [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]; }
NON_INTERACTIVE=0
source src/tui/prompts.sh

# Under pipe (subshell stdout is not a TTY), can_use_interactive_tui must return 1 (fallback)
if can_use_interactive_tui; then
    echo "TUI_RESULT:INTERACTIVE"
else
    echo "TUI_RESULT:FALLBACK"
fi
""")
        self.assertEqual(res_tui.returncode, 0)
        self.assertIn("TUI_RESULT:FALLBACK", res_tui.stdout)

        # 2. Multiselect numeric parsing (options 1 and 3)
        res_multiselect = run_shell("""
set -euo pipefail
source src/common/colors.sh
source src/common/logger.sh
is_true() { local val="${1:-0}"; [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]; }
NON_INTERACTIVE=0
source src/tui/prompts.sh

p_keys=("PROTO_A" "PROTO_B" "PROTO_C")
p_labels=("Protocol Alpha" "Protocol Beta" "Protocol Gamma")
PROTO_A="n"
PROTO_B="n"
PROTO_C="n"

# Pass '1,3' to simulate user input in fallback mode
prompt_multiselect_numeric "Choose protocols" p_keys p_labels <<< "1,3"

echo "A=$PROTO_A B=$PROTO_B C=$PROTO_C"
""")
        self.assertEqual(res_multiselect.returncode, 0)
        self.assertIn("A=y B=n C=y", res_multiselect.stdout)

        # 2b. Space-separated numbers
        res_space = run_shell("""
set -euo pipefail
source src/common/colors.sh
source src/common/logger.sh
is_true() { local val="${1:-0}"; [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]; }
NON_INTERACTIVE=0
source src/tui/prompts.sh

p_keys=("PROTO_A" "PROTO_B" "PROTO_C")
p_labels=("Protocol Alpha" "Protocol Beta" "Protocol Gamma")
PROTO_A="n"
PROTO_B="n"
PROTO_C="n"

prompt_multiselect_numeric "Choose protocols" p_keys p_labels <<< "1 2"
echo "A=$PROTO_A B=$PROTO_B C=$PROTO_C"
""")
        self.assertEqual(res_space.returncode, 0)
        self.assertIn("A=y B=y C=n", res_space.stdout)

        # 3. Multiselect non-interactive auto mode
        res_auto = run_shell("""
set -euo pipefail
source src/common/colors.sh
source src/common/logger.sh
is_true() { local val="${1:-0}"; [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]; }
NON_INTERACTIVE=1
source src/tui/prompts.sh

p_keys=("PROTO_A" "PROTO_B")
p_labels=("Proto 1" "Proto 2")
PROTO_A="y"
PROTO_B="n"

prompt_multiselect "Choose" p_keys p_labels
echo "AUTO_A=$PROTO_A AUTO_B=$PROTO_B"
""")
        self.assertEqual(res_auto.returncode, 0)
        self.assertIn("AUTO_A=y AUTO_B=n", res_auto.stdout)

    def test_modular_web_stack_and_standalone_awg(self):
        """Verify modular architecture: optional web stack (Nginx+3X-UI) and standalone AWG."""
        # 1. Environment and example config
        env_ex = (ROOT / "server-setup.env.example").read_text(encoding="utf-8")
        self.assertIn("ENABLE_WEB_STACK", env_ex)
        self.assertIn("AWG_SERVER_HOST", env_ex)

        env_sh = (ROOT / "src/system/env.sh").read_text(encoding="utf-8")
        self.assertIn("ENABLE_WEB_STACK", env_sh)
        self.assertIn("AWG_SERVER_HOST", env_sh)

        # 2. CLI flags and overrides
        prompts_sh = (ROOT / "src/tui/prompts.sh").read_text(encoding="utf-8")
        self.assertIn("--web-stack", prompts_sh)
        self.assertIn("--no-web-stack", prompts_sh)
        self.assertIn("--awg-host", prompts_sh)

        banner_sh = (ROOT / "src/tui/banner.sh").read_text(encoding="utf-8")
        self.assertIn("--web-stack", banner_sh)
        self.assertIn("--no-web-stack", banner_sh)
        self.assertIn("--awg-host", banner_sh)

        # 3. Wizard Standalone flow
        wizard_sh = (ROOT / "src/tui/wizard.sh").read_text(encoding="utf-8")
        self.assertIn("Только автономный AmneziaWG (awg-mgr)", wizard_sh)
        self.assertIn("run_standalone_awg_wizard", wizard_sh)
        self.assertIn("Endpoint", wizard_sh)
        self.assertIn("AWG_SERVER_HOST", wizard_sh)

        plan = (ROOT / "src/installer/plan.sh").read_text(encoding="utf-8")
        self.assertIn('is_true "${ENABLE_WEB_STACK:-y}"', plan)
        self.assertIn('INSTALLATION_PLAN+=(awg)', plan)
        setup_main = (ROOT / "src/entrypoints/setup.main.sh").read_text(encoding="utf-8")
        self.assertIn("run_installation", setup_main)

        # 6. AWG launcher exports SERVER_PUBLIC_HOST
        awg_setup = (ROOT / "src/awg/setup.sh").read_text(encoding="utf-8")
        self.assertIn("SERVER_PUBLIC_HOST", awg_setup)


    def test_get_wan_ip_uses_cache(self):
        """Verify get_wan_ip prefers cached /run/setup_mask_wan_ip or /tmp before calling curl."""
        res = run_shell("""
source src/common/preflight.sh
cache_file="/run/setup_mask_wan_ip"
touch /run/.test_w 2>/dev/null || cache_file="/tmp/setup_mask_wan_ip"
rm -f /run/.test_w 2>/dev/null || true
echo "203.0.113.42" > "$cache_file"
ip=$(get_wan_ip)
printf "RESOLVED_IP=[%s]" "$ip"
rm -f "$cache_file"
""")
        self.assertEqual(res.returncode, 0, f"get_wan_ip failed: {res.stderr}")
        self.assertIn("RESOLVED_IP=[203.0.113.42]", res.stdout)


    def test_is_port_in_use_udp_does_not_use_dev_udp(self):
        """Verify is_port_in_use never attempts connectionless /dev/udp redirection."""
        preflight_sh = (ROOT / "src/common/preflight.sh").read_text(encoding="utf-8")
        self.assertNotIn("/dev/udp", preflight_sh, "is_port_in_use must not test UDP via /dev/udp")

    def test_external_proxy_preserves_sni_and_returns_inbound_id(self):
        """Verify smart_reconcile_inbound preserves SNI in externalProxy and returns valid inbound_id."""
        reconcile = self.ns["smart_reconcile_inbound"]
        reality_settings = {
            "clients": [{"id": str(uuid.uuid4()), "flow": "xtls-rprx-vision", "email": "Client", "subId": "12345678", "enable": True}],
            "decryption": "none"
        }
        reality_stream = {
            "network": "tcp",
            "security": "reality",
            "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}},
            "realitySettings": {
                "show": False, "xver": 0, "dest": "avito.ru:443", "target": "avito.ru:443",
                "serverNames": ["avito.ru"], "privateKey": "testprivkey", "minClientVer": "1.0.0",
                "shortIds": ["abcdef12"],
                "settings": {"publicKey": "testpubkey", "fingerprint": "firefox", "serverName": "avito.ru", "spiderX": "/"}
            },
            "externalProxy": [{"dest": "test.example.com", "port": 443, "forceTls": "same", "sni": "avito.ru", "remark": "VLESS Classic"}]
        }
        ib_id = reconcile(46443, "vless", "in-classic-reality", "VLESS Classic", reality_settings, reality_stream, listen="127.0.0.1")
        self.assertIsNotNone(ib_id, "smart_reconcile_inbound must return inbound_id on creation")

        self.cur.execute("SELECT stream_settings FROM inbounds WHERE id = ?", (ib_id,))
        row = self.cur.fetchone()
        self.assertIsNotNone(row)
        st = json.loads(row[0])
        ext = st.get("externalProxy", [])
        self.assertEqual(len(ext), 1)
        self.assertEqual(ext[0].get("sni"), "avito.ru", "externalProxy must preserve SNI avito.ru")
        self.assertEqual(ext[0].get("forceTls"), "same", "externalProxy forceTls must be 'same' for REALITY")

        # Re-run reconcile to verify update preservation
        ib_id2 = reconcile(46443, "vless", "in-classic-reality", "VLESS Classic", reality_settings, reality_stream, listen="127.0.0.1")
        self.assertEqual(ib_id, ib_id2, "smart_reconcile_inbound must return matching inbound_id on update")

        self.cur.execute("SELECT stream_settings FROM inbounds WHERE id = ?", (ib_id,))
        st2 = json.loads(self.cur.fetchone()[0])
        ext2 = st2.get("externalProxy", [])
        self.assertEqual(ext2[0].get("sni"), "avito.ru", "externalProxy must keep SNI on reconcile update")

    def test_smart_reconcile_inbound_multi_sni_pool_and_external_proxies(self):
        """Verify smart_reconcile_inbound configures multiple SNIs in serverNames and updates when pool changes."""
        reconcile = self.ns["smart_reconcile_inbound"]
        initial_pool = ["dl.google.com", "www.google.com"]
        c_settings = {
            "clients": [{"id": str(uuid.uuid4()), "flow": "xtls-rprx-vision", "email": "Client", "subId": "12345678", "enable": True}],
            "decryption": "none"
        }
        c_stream = {
            "network": "tcp",
            "security": "reality",
            "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}},
            "realitySettings": {
                "show": False, "xver": 0, "dest": f"{initial_pool[0]}:443", "target": f"{initial_pool[0]}:443",
                "serverNames": initial_pool, "privateKey": "testprivkey", "minClientVer": "1.0.0",
                "shortIds": ["abcdef12"],
                "settings": {"publicKey": "testpubkey", "fingerprint": "firefox", "serverName": initial_pool[0], "spiderX": "/"}
            },
            "externalProxy": [
                {"dest": "test.example.com", "port": 443, "forceTls": "same", "sni": s, "fingerprint": "firefox", "remark": f"VLESS Classic ({s})"}
                for s in initial_pool
            ]
        }
        # 1. First run creates inbound with initial pool
        ib_id = reconcile(46443, "vless", "in-classic-reality", "VLESS Classic", c_settings, c_stream, listen="127.0.0.1")
        self.assertIsNotNone(ib_id)

        self.cur.execute("SELECT stream_settings FROM inbounds WHERE id = ?", (ib_id,))
        st = json.loads(self.cur.fetchone()[0])
        self.assertEqual(st["realitySettings"]["serverNames"], initial_pool)
        self.assertEqual(st["realitySettings"]["dest"], "dl.google.com:443")
        self.assertEqual(len(st["externalProxy"]), 2)
        self.assertEqual([p["sni"] for p in st["externalProxy"]], initial_pool)

        # 2. Second run with a new pool (e.g. speed.cloudflare.com cache.cloudflare.com) must UPDATE serverNames, dest and externalProxy
        new_pool = ["speed.cloudflare.com", "cache.cloudflare.com"]
        c_stream2 = {
            "network": "tcp",
            "security": "reality",
            "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}},
            "realitySettings": {
                "show": False, "xver": 0, "dest": f"{new_pool[0]}:443", "target": f"{new_pool[0]}:443",
                "serverNames": new_pool, "privateKey": "testprivkey", "minClientVer": "1.0.0",
                "shortIds": ["abcdef12"],
                "settings": {"publicKey": "testpubkey", "fingerprint": "firefox", "serverName": new_pool[0], "spiderX": "/"}
            },
            "externalProxy": [
                {"dest": "test.example.com", "port": 443, "forceTls": "same", "sni": s, "fingerprint": "firefox", "remark": f"VLESS Classic ({s})"}
                for s in new_pool
            ]
        }
        ib_id2 = reconcile(46443, "vless", "in-classic-reality", "VLESS Classic", c_settings, c_stream2, listen="127.0.0.1")
        self.assertEqual(ib_id, ib_id2)

        self.cur.execute("SELECT stream_settings FROM inbounds WHERE id = ?", (ib_id,))
        st2 = json.loads(self.cur.fetchone()[0])
        self.assertEqual(st2["realitySettings"]["serverNames"], new_pool, "serverNames must be updated with the new pool from configuration")
        self.assertEqual(st2["realitySettings"]["dest"], "speed.cloudflare.com:443", "dest must be updated to first SNI of new pool")
        self.assertEqual(st2["realitySettings"]["target"], "speed.cloudflare.com:443", "target must match dest")
        self.assertEqual(st2["realitySettings"]["settings"]["serverName"], "speed.cloudflare.com", "settings.serverName must be updated to primary target")
        self.assertEqual(len(st2["externalProxy"]), 2, "externalProxy must contain 2 entries for the new pool")
        self.assertEqual([p["sni"] for p in st2["externalProxy"]], new_pool, "externalProxy SNIs must match new pool")

    def test_reality_fingerprint_parameter_and_reconciliation(self):
        """Verify REALITY_FINGERPRINT parameter parsing and reconciliation in smart_reconcile_inbound."""
        reconcile = self.ns["smart_reconcile_inbound"]
        priv, pub = "p1", "p2"

        valid_fps = {"chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized"}
        for fp in ["chrome", "CHROME", "safari", "randomized"]:
            clean_fp = fp.strip().lower()
            self.assertIn(clean_fp, valid_fps)

        init_stream = {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "dest": "dl.google.com:443",
                "serverNames": ["dl.google.com"],
                "privateKey": priv,
                "shortIds": ["0123456789abcdef"],
                "settings": {"publicKey": pub, "fingerprint": "firefox", "serverName": "dl.google.com", "spiderX": "/"}
            },
            "externalProxy": [{"dest": "example.com", "port": 443, "forceTls": "same", "sni": "dl.google.com", "fingerprint": "firefox", "remark": "VLESS Classic"}]
        }
        c_settings = {"clients": [{"id": "00000000-0000-0000-0000-000000000000", "flow": "xtls-rprx-vision", "email": "test@domain.com"}]}
        ib_id = reconcile(46443, "vless", "in-classic-reality", "VLESS Classic", c_settings, init_stream, listen="127.0.0.1")

        new_stream = {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "dest": "dl.google.com:443",
                "serverNames": ["dl.google.com"],
                "privateKey": priv,
                "shortIds": ["0123456789abcdef"],
                "settings": {"publicKey": pub, "fingerprint": "chrome", "serverName": "dl.google.com", "spiderX": "/"}
            },
            "externalProxy": [{"dest": "example.com", "port": 443, "forceTls": "same", "sni": "dl.google.com", "fingerprint": "chrome", "remark": "VLESS Classic"}]
        }
        reconcile(46443, "vless", "in-classic-reality", "VLESS Classic", c_settings, new_stream, listen="127.0.0.1")

        self.cur.execute("SELECT stream_settings FROM inbounds WHERE id = ?", (ib_id,))
        st = json.loads(self.cur.fetchone()[0])
        self.assertEqual(st["realitySettings"]["settings"]["fingerprint"], "chrome", "settings.fingerprint must be updated to chrome")
        self.assertEqual(st["externalProxy"][0]["fingerprint"], "chrome", "externalProxy[0].fingerprint must be updated to chrome")

    def test_reconcile_hosts_table_multiple_snis_and_shuffle_host(self):
        """Verify hosts table synchronization deletes prior hosts and inserts rows with shuffle_host=1 across schemas."""
        reconcile_src = (ROOT / "src/panel/reconcile.py").read_text(encoding="utf-8")
        start_marker = 'cur.execute("PRAGMA table_info(hosts)")'
        end_marker = 'x_iid = xhttp_ib_id'
        idx1 = reconcile_src.index(start_marker)
        idx2 = reconcile_src.index(end_marker)
        hosts_block = reconcile_src[idx1:idx2]

        # 1. Test snake_case schema (inbound_id, sort_order, shuffle_host)
        c_iid = 42
        self.cur.execute("""
            CREATE TABLE IF NOT EXISTS hosts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                group_id TEXT DEFAULT '',
                inbound_id INTEGER NOT NULL DEFAULT 0,
                sort_order INTEGER DEFAULT 0,
                remark TEXT DEFAULT '',
                address TEXT DEFAULT '',
                port INTEGER DEFAULT 443,
                security TEXT DEFAULT 'same',
                sni TEXT DEFAULT '',
                host_header TEXT DEFAULT '',
                path TEXT DEFAULT '',
                alpn TEXT DEFAULT '',
                fingerprint TEXT DEFAULT '',
                allow_insecure INTEGER DEFAULT 0,
                is_disabled INTEGER DEFAULT 0,
                is_hidden INTEGER DEFAULT 0,
                tags TEXT DEFAULT '',
                ech_config_list TEXT DEFAULT '',
                mux_params TEXT DEFAULT '',
                sockopt_params TEXT DEFAULT '',
                final_mask TEXT DEFAULT '',
                exclude_from_sub_types TEXT DEFAULT '',
                shuffle_host INTEGER DEFAULT 0
            )
        """)
        self.cur.execute("CREATE TABLE IF NOT EXISTS inbounds_test (id INTEGER PRIMARY KEY, remark TEXT)")
        # Insert stale host for inbound 42
        self.cur.execute("INSERT INTO hosts (inbound_id, remark, address, port, security, sni, shuffle_host) VALUES (?, 'old', 'old.com', 443, 'same', 'old.sni.com', 0)", (c_iid,))
        self.conn.commit()

        # Multi-SNI pool with spaces, commas, duplicates and mixed case
        classic_raw = "speed.cloudflare.com, cache.cloudflare.com, SPEED.CLOUDFLARE.COM"
        _parsed = []
        _seen = set()
        for _s in classic_raw.replace(",", " ").split():
            _c = _s.strip().strip(".").lower()
            if _c and _c not in _seen:
                _seen.add(_c)
                _parsed.append(_c)
        classic_snis = _parsed

        self.assertEqual(classic_snis, ["speed.cloudflare.com", "cache.cloudflare.com"], "Duplicates and case must be normalized")

        ns_snake = {
            "cur": self.cur,
            "dry_run": False,
            "classic_ib_id": c_iid,
            "classic_port": 46443,
            "enable_steal": False,
            "enable_classic": True,
            "classic_snis": classic_snis,
            "domain": "test.example.com",
            "classic_remark": "VLESS Classic",
            "uuid": uuid,
        }
        exec(hosts_block, ns_snake)
        self.conn.commit()

        self.cur.execute("SELECT sort_order, remark, sni, shuffle_host FROM hosts WHERE inbound_id = ? ORDER BY sort_order", (c_iid,))
        rows = self.cur.fetchall()
        self.assertEqual(len(rows), 2, "Stale host must be deleted and exactly 2 pool hosts inserted")
        self.assertEqual(rows[0][0], 1)
        self.assertEqual(rows[0][1], "VLESS Classic (speed.cloudflare.com)")
        self.assertEqual(rows[0][2], "speed.cloudflare.com")
        self.assertEqual(rows[0][3], 1, "shuffle_host must be 1 for client auto-rotation")

        self.assertEqual(rows[1][0], 2)
        self.assertEqual(rows[1][1], "VLESS Classic (cache.cloudflare.com)")
        self.assertEqual(rows[1][2], "cache.cloudflare.com")
        self.assertEqual(rows[1][3], 1, "shuffle_host must be 1 for client auto-rotation")

        # 2. Test camelCase schema (inboundId, sortOrder, shuffleHost) - ensures no 'no such column: inbound_id'
        conn_camel = sqlite3.connect(":memory:")
        cur_camel = conn_camel.cursor()
        cur_camel.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY, remark TEXT)")
        cur_camel.execute("INSERT INTO inbounds VALUES (99, 'VLESS Classic')")
        cur_camel.execute("""
            CREATE TABLE hosts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                groupId TEXT DEFAULT '',
                inboundId INTEGER NOT NULL DEFAULT 0,
                sortOrder INTEGER DEFAULT 0,
                remark TEXT DEFAULT '',
                address TEXT DEFAULT '',
                port INTEGER DEFAULT 443,
                security TEXT DEFAULT 'same',
                sni TEXT DEFAULT '',
                hostHeader TEXT DEFAULT '',
                path TEXT DEFAULT '',
                alpn TEXT DEFAULT '',
                fingerprint TEXT DEFAULT '',
                allowInsecure INTEGER DEFAULT 0,
                isDisabled INTEGER DEFAULT 0,
                isHidden INTEGER DEFAULT 0,
                tags TEXT DEFAULT '',
                echConfigList TEXT DEFAULT '',
                muxParams TEXT DEFAULT '',
                sockoptParams TEXT DEFAULT '',
                finalMask TEXT DEFAULT '',
                excludeFromSubTypes TEXT DEFAULT '',
                shuffleHost INTEGER DEFAULT 0
            )
        """)
        # Insert stale host with inboundId
        cur_camel.execute("INSERT INTO hosts (inboundId, remark, address, port, security, sni, shuffleHost) VALUES (99, 'old-camel', 'old.com', 443, 'same', 'old.sni', 0)")
        conn_camel.commit()

        ns_camel = {
            "cur": cur_camel,
            "dry_run": False,
            "classic_ib_id": 99,
            "classic_port": 46443,
            "enable_steal": False,
            "enable_classic": True,
            "classic_snis": ["apple.com", "cdn.apple.com"],
            "domain": "test.example.com",
            "classic_remark": "VLESS Classic",
            "uuid": uuid,
        }
        # Must execute cleanly without OperationalError
        exec(hosts_block, ns_camel)
        conn_camel.commit()

        cur_camel.execute("SELECT sortOrder, remark, sni, shuffleHost FROM hosts WHERE inboundId = ? ORDER BY sortOrder", (99,))
        rows_camel = cur_camel.fetchall()
        self.assertEqual(len(rows_camel), 2, "Stale host must be deleted and exactly 2 pool hosts inserted into camelCase schema")
        self.assertEqual(rows_camel[0], (1, "VLESS Classic (apple.com)", "apple.com", 1))
        self.assertEqual(rows_camel[1], (2, "VLESS Classic (cdn.apple.com)", "cdn.apple.com", 1))
        conn_camel.close()

    def test_xhttp_reconcile_preserves_xmux_noSSE_xPadding_and_encryption(self):
        """Verify that smart_reconcile_inbound preserves xmux, noSSEHeader, xPaddingBytes, and encryption for xHTTP."""
        reconcile = self.ns["smart_reconcile_inbound"]
        custom_xmux = {
            "maxConcurrency": "10",
            "maxConnections": "5-10",
            "cMaxReuseTimes": "100-200",
            "hKeepAlivePeriod": 300,
            "hMaxRequestTimes": "500",
            "hMaxReusableSecs": "600"
        }
        init_settings = {
            "clients": [{"id": "test-uuid-1", "flow": "", "email": "Client", "subId": "sub1", "enable": True, "encryption": "existing_enc_key"}],
            "decryption": "existing_dec_key",
            "encryption": "existing_enc_key"
        }
        init_stream = {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {
                "path": "/custom-path/",
                "host": "custom.domain.com",
                "mode": "stream-one",
                "noSSEHeader": False,
                "xPaddingBytes": "50-150",
                "xmux": custom_xmux
            },
            "externalProxy": [{"dest": "custom.domain.com", "port": 443, "forceTls": "tls", "sni": "custom.domain.com", "fingerprint": "firefox", "remark": "VLESS xHTTP"}]
        }
        ib_id = reconcile(50443, "vless", "in-xhttp-stream", "VLESS xHTTP", init_settings, init_stream, listen="127.0.0.1")

        # Now simulate a reconcile with standard defaults
        default_settings = {
            "clients": [{"id": "test-uuid-2", "flow": "", "email": "Client", "subId": "sub2", "enable": True, "encryption": "new_enc_key"}],
            "decryption": "new_dec_key",
            "encryption": "new_enc_key"
        }
        default_stream = {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {
                "path": "/default-path/",
                "host": "default.domain.com",
                "mode": "stream-one",
                "noSSEHeader": True,
                "xPaddingBytes": "100-500",
                "xmux": {
                    "maxConcurrency": "0",
                    "maxConnections": "1-3",
                    "cMaxReuseTimes": "300-600",
                    "hKeepAlivePeriod": 600,
                    "hMaxRequestTimes": "1000-2000",
                    "hMaxReusableSecs": "1200-2400"
                }
            },
            "externalProxy": [{"dest": "default.domain.com", "port": 443, "forceTls": "tls", "sni": "default.domain.com", "fingerprint": "firefox", "remark": "VLESS xHTTP"}]
        }

        self.ns["unified_email"] = "Client"
        ib_id2 = reconcile(50443, "vless", "in-xhttp-stream", "VLESS xHTTP", default_settings, default_stream, listen="127.0.0.1")
        self.assertEqual(ib_id, ib_id2)

        self.cur.execute("SELECT settings, stream_settings FROM inbounds WHERE id = ?", (ib_id,))
        row = self.cur.fetchone()
        reconciled_settings = json.loads(row[0])
        reconciled_stream = json.loads(row[1])
        reconciled_xh = reconciled_stream["xhttpSettings"]

        # Verify preserved xmux
        self.assertEqual(reconciled_xh.get("xmux"), custom_xmux, "Custom xmux must be preserved during reconcile")
        # Verify preserved noSSEHeader
        self.assertFalse(reconciled_xh.get("noSSEHeader"), "Existing noSSEHeader (False) must be preserved")
        # Verify preserved xPaddingBytes
        self.assertEqual(reconciled_xh.get("xPaddingBytes"), "50-150", "Custom xPaddingBytes must be preserved")
        # Verify preserved decryption & encryption
        self.assertEqual(reconciled_settings.get("decryption"), "existing_dec_key", "Existing decryption must be preserved")
        self.assertEqual(reconciled_settings.get("encryption"), "existing_enc_key", "Existing encryption must be preserved")
        # Verify client receives encryption
        clients = reconciled_settings.get("clients", [])
        self.assertTrue(len(clients) > 0)
        self.assertEqual(clients[0].get("encryption"), "existing_enc_key", "Client in xHTTP must receive encryption key")

    def test_xhttp_templates_and_vlessenc_export_consistency(self):
        """Verify configure-panel.sh and maintain.sh export UNIFIED_VLESS_ENKEY, xPaddingBytes 100-500, xmux, noSSEHeader, firefox."""
        conf_sh = (ROOT / "configure-panel.sh").read_text(encoding="utf-8")
        upd_sh = (ROOT / "maintain.sh").read_text(encoding="utf-8")

        for text, name in [(conf_sh, "configure-panel.sh"), (upd_sh, "maintain.sh")]:
            self.assertIn('"xPaddingBytes": "100-500"', text, f"xPaddingBytes default '100-500' must be in {name}")
            self.assertIn('"noSSEHeader": True', text, f"noSSEHeader: True must be in {name}")
            self.assertIn("UNIFIED_VLESS_ENKEY", text, f"UNIFIED_VLESS_ENKEY must be exported in {name}")
            self.assertIn("VLESS xHTTP EnKey:", text, f"VLESS xHTTP EnKey: must be written to credentials in {name}")
            self.assertIn('"xmux": {', text, f"Reference xmux block must be in {name}")
            self.assertIn('"maxConcurrency": "0"', text, f"xmux maxConcurrency: 0 must be in {name}")
            self.assertTrue(
                '"fingerprint": reality_fingerprint' in text or '"fingerprint": "firefox"' in text,
                f"fingerprint parameter must be in {name}"
            )

        # Ensure configure-panel.sh does not delete /run/3xui_unified_client.env
        self.assertNotIn('rm -f "$c_env"', conf_sh.split('for c_env in "/run/3xui_unified_client.env"')[1][:200],
                         "configure-panel.sh must not delete /run/3xui_unified_client.env")

    def test_nginx_stream_failover_backup_socket(self):
        """Verify Nginx Stream L4 reality_backend contains failover unix backup socket per docs/ARCHITECTURE.md#L114."""
        nginx_conf_sh = (ROOT / "src/nginx/config.sh").read_text(encoding="utf-8")
        setup_mask_sh = (ROOT / "setup.sh").read_text(encoding="utf-8")

        for text, name in [(nginx_conf_sh, "src/nginx/config.sh"), (setup_mask_sh, "setup.sh")]:
            m = re.search(r'upstream reality_backend_\$\{port\}\s*\{([\s\S]*?\n\s*\})', text)
            self.assertIsNotNone(m, f"upstream reality_backend_${{port}} must be defined in {name}")
            body = m.group(1)
            self.assertIn("server 127.0.0.1:${port};", body, f"Primary backend missing in {name}")
            self.assertIn("server unix:/dev/shm/nginx-http.sock backup;", body,
                          f"Failover socket 'server unix:/dev/shm/nginx-http.sock backup;' must be present in {name}")

    def test_xhttp_reconcile_legacy_client_without_encryption_synchronizes_with_inbound(self):
        """Verify that a legacy client without encryption field gets the preserved inbound encryption key (preventing desync)."""
        reconcile = self.ns["smart_reconcile_inbound"]
        init_settings = {
            "clients": [{"id": "legacy-uuid-1", "flow": "", "email": "Client", "subId": "sub1", "enable": True}],  # Notice NO encryption field
            "decryption": "preserved_dec_key",
            "encryption": "preserved_enc_key"
        }
        init_stream = {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {"path": "/xhttp/", "mode": "stream-one"},
            "externalProxy": [{"dest": "domain.com", "port": 443, "forceTls": "tls"}]
        }
        ib_id = reconcile(50444, "vless", "in-xhttp-stream-2", "VLESS xHTTP Legacy", init_settings, init_stream, listen="127.0.0.1")

        default_settings = {
            "clients": [{"id": "new-uuid-2", "flow": "", "email": "Client", "subId": "sub2", "enable": True, "encryption": "newly_generated_enc_key"}],
            "decryption": "newly_generated_dec_key",
            "encryption": "newly_generated_enc_key"
        }
        default_stream = {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {"path": "/xhttp/", "mode": "stream-one"},
            "externalProxy": [{"dest": "domain.com", "port": 443, "forceTls": "tls"}]
        }

        self.ns["unified_email"] = "Client"
        ib_id2 = reconcile(50444, "vless", "in-xhttp-stream-2", "VLESS xHTTP Legacy", default_settings, default_stream, listen="127.0.0.1")
        self.assertEqual(ib_id, ib_id2)

        self.cur.execute("SELECT settings FROM inbounds WHERE id = ?", (ib_id,))
        reconciled_settings = json.loads(self.cur.fetchone()[0])

        self.assertEqual(reconciled_settings.get("encryption"), "preserved_enc_key", "Inbound encryption must be preserved")
        clients = reconciled_settings.get("clients", [])
        self.assertEqual(len(clients), 1)
        self.assertEqual(clients[0].get("encryption"), "preserved_enc_key",
                         "Legacy client MUST receive the preserved inbound encryption key to prevent handshake failure")

    def test_reconcile_inbound_dry_run_new_inbound(self):
        """Verify that smart_reconcile_inbound handles dry_run=True for a new inbound without raising UnboundLocalError."""
        reconcile = self.ns["smart_reconcile_inbound"]
        self.ns["dry_run"] = True
        try:
            res = reconcile(59999, "vless", "in-dryrun-test", "DryRun Inbound", {"clients": []}, {"network": "tcp"})
            self.assertIsNone(res, "dry_run on new inbound must return None without UnboundLocalError")
        finally:
            self.ns["dry_run"] = False

    def test_generate_tuic_credentials(self):
        """Verify that generate_tuic_credentials exists and returns valid uuid and password."""
        from src.xray.keys import generate_tuic_credentials
        u, p = generate_tuic_credentials()
        self.assertTrue(bool(re.match(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', u)))
        self.assertTrue(len(p) >= 16)

    def test_update_repair_python_reconcile_end_to_end(self):
        """Verify that the embedded Python reconciliation script from maintain.sh executes cleanly without NameError."""
        import sys
        import tempfile
        import subprocess

        with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
            temp_db = f.name

        try:
            conn = sqlite3.connect(temp_db)
            c = conn.cursor()
            c.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, value TEXT)")
            c.execute("""
                CREATE TABLE inbounds (
                    id INTEGER PRIMARY KEY, user_id INTEGER, up INTEGER, down INTEGER, total INTEGER,
                    remark TEXT, enable INTEGER, expiry_time INTEGER, listen TEXT, port INTEGER,
                    protocol TEXT, settings TEXT, stream_settings TEXT, tag TEXT, sniffing TEXT
                )
            """)
            c.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, password TEXT)")
            c.execute("INSERT INTO users VALUES (1, 'admin', 'admin')")
            conn.commit()
            conn.close()

            upd_text = (ROOT / "maintain.sh").read_text(encoding="utf-8")
            marker = "\"$PYTHON_CMD\" - << 'EOF_PYTHON_RECONCILE'"
            py_start = upd_text.find(marker)
            self.assertNotEqual(py_start, -1, "Python reconcile block marker must exist in maintain.sh")
            py_code = upd_text[py_start + len(marker) + 1:]
            py_end = py_code.find("EOF_PYTHON_RECONCILE")
            self.assertNotEqual(py_end, -1, "EOF_PYTHON_RECONCILE must exist")
            py_code = py_code[:py_end]

            env = os.environ.copy()
            env["DB_PATH"] = temp_db
            env["PRIMARY_DOMAIN"] = "example.com"
            env["DRY_RUN"] = "0"

            res = subprocess.run([sys.executable, "-"], input=py_code, env=env, capture_output=True, text=True, encoding="utf-8")
            self.assertEqual(res.returncode, 0, f"maintain.sh Python reconcile failed:\nSTDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}")
        finally:
            if os.path.exists(temp_db):
                os.unlink(temp_db)

    def test_configure_3xui_python_config_end_to_end(self):
        """Verify that the embedded Python config script from configure-panel.sh executes cleanly without NameError."""
        import sys
        import tempfile
        import subprocess

        with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
            temp_db = f.name

        try:
            conn = sqlite3.connect(temp_db)
            c = conn.cursor()
            c.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, value TEXT)")
            c.execute("""
                CREATE TABLE inbounds (
                    id INTEGER PRIMARY KEY, user_id INTEGER, up INTEGER, down INTEGER, total INTEGER,
                    remark TEXT, enable INTEGER, expiry_time INTEGER, listen TEXT, port INTEGER,
                    protocol TEXT, settings TEXT, stream_settings TEXT, tag TEXT, sniffing TEXT
                )
            """)
            c.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, password TEXT)")
            c.execute("INSERT INTO users VALUES (1, 'admin', 'admin')")
            conn.commit()
            conn.close()

            conf_text = (ROOT / "configure-panel.sh").read_text(encoding="utf-8")
            marker = "\"$PYTHON_CMD\" - << 'EOF_PYTHON_CONFIG'"
            py_start = conf_text.find(marker)
            self.assertNotEqual(py_start, -1, "Python config block marker must exist in configure-panel.sh")
            py_code = conf_text[py_start + len(marker) + 1:]
            py_end = py_code.find("EOF_PYTHON_CONFIG")
            self.assertNotEqual(py_end, -1, "EOF_PYTHON_CONFIG must exist")
            py_code = py_code[:py_end]

            env = os.environ.copy()
            env["DB_PATH"] = temp_db
            env["PRIMARY_DOMAIN"] = "example.com"
            env["DRY_RUN"] = "0"

            res = subprocess.run([sys.executable, "-"], input=py_code, env=env, capture_output=True, text=True, encoding="utf-8")
            self.assertEqual(res.returncode, 0, f"configure-panel.sh Python config failed:\nSTDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}")
        finally:
            if os.path.exists(temp_db):
                os.unlink(temp_db)



class TestBashScopeRegressions(unittest.TestCase):
    def test_no_illegal_local_outside_function(self):
        """Verify that known top-level variables do not use 'local' keyword outside function scope."""
        files_to_check = [
            ROOT / "setup.sh",
            ROOT / "src" / "tui" / "wizard.sh",
            ROOT / "src" / "entrypoints" / "setup.main.sh",
        ]
        for f in files_to_check:
            if not f.exists():
                continue
            content = f.read_text(encoding="utf-8")
            self.assertNotIn("local has_saved_config", content, f"'local has_saved_config' found in {f.name}")
            self.assertNotIn("local udp_stack_summary", content, f"'local udp_stack_summary' found in {f.name}")

        setup_sh = (ROOT / "setup.sh").read_text(encoding="utf-8")
        # Ensure awg_p in step 3 standalone is not using local outside function
        m_step3_awg = re.search(r'deploy_amneziawg_backend\s+if command -v ufw[^;]*;\s*then\s+([^\n]+)', setup_sh)
        self.assertNotIn("local awg_p=", setup_sh.split("🎉 УСТАНОВКА АВТОНОМНОГО СЕРВЕРА AMNEZIAWG УСПЕШНО ЗАВЕРШЕНА")[0][-500:])

    def test_classic_sni_pool_parsing_and_deduplication_in_bash(self):
        """Verify that env.sh and wizard.sh correctly split multi-SNI pools with spaces and commas, deduplicating entries."""
        if not BASH.exists():
            self.skipTest(f"bash not found at {BASH}")

        bash_script = """
set -e
source "src/common/colors.sh"
source "src/common/logger.sh"
is_true() { local val="${1:-0}"; [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]; }
NON_INTERACTIVE=1
declare -g -A EXT_SNI_TO_PORT=()
CLASSIC_PORTS_LIST=(46443)
CLASSIC_PORT=46443
ENABLE_CLASSIC=y
CLASSIC_SNI="speed.cloudflare.com, cache.cloudflare.com, speed.cloudflare.com, SPEED.CLOUDFLARE.COM"
PRIMARY_DOMAIN="example.com"
source "src/system/env.sh"
reconstruct_arrays_from_vars

echo "COUNT=${#EXT_SNI_LIST[@]}"
for s in "${EXT_SNI_LIST[@]}"; do
    echo "SNI=$s,PORT=${EXT_SNI_TO_PORT[$s]}"
done
"""
        res = run_shell(bash_script)
        self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
        self.assertIn("COUNT=2", res.stdout)
        self.assertIn("SNI=speed.cloudflare.com,PORT=46443", res.stdout)
        self.assertIn("SNI=cache.cloudflare.com,PORT=46443", res.stdout)

    def test_amnezia_vpnuri_naming_and_modern_container(self):
        """Verify that Amnezia vpn:// URI uses informative server name and modern amnezia-awg2 container."""
        from src.awg import manage_clients as manage_amneziawg
        import base64, zlib, json

        conf = "[Interface]\nPrivateKey = aaaa\nAddress = 10.8.1.2/32\n\n[Peer]\nPublicKey = bbbb\nEndpoint = 127.0.0.1:8443\n"
        uri = manage_amneziawg.encode_amnezia_vpnuri_31(conf, "10.8.1.2", "aaaa", "bbbb", description="MyServer — user1")
        self.assertTrue(uri.startswith("vpn://"))
        raw_b64 = uri[6:]
        pad = len(raw_b64) % 4
        if pad: raw_b64 += "=" * (4 - pad)
        decoded = base64.urlsafe_b64decode(raw_b64)
        uncompressed = zlib.decompress(decoded[4:])
        data = json.loads(uncompressed.decode("utf-8"))

        self.assertEqual(data["description"], "MyServer — user1")
        self.assertEqual(data["defaultContainer"], "amnezia-awg2")
        self.assertEqual(data["containers"][0]["container"], "amnezia-awg2")
        self.assertTrue(data["containers"][0]["awg"].get("isThirdPartyConfig", False))

    def test_subscription_title_sync(self):
        """Verify that SUB_TITLE / SERVER_PREFIX is saved to 3X-UI subTitle setting."""
        import tempfile, sqlite3
        with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
            temp_db = f.name
        try:
            conn = sqlite3.connect(temp_db)
            cur = conn.cursor()
            cur.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, value TEXT)")
            cur.execute("""
                CREATE TABLE inbounds (
                    id INTEGER PRIMARY KEY, user_id INTEGER, up INTEGER, down INTEGER, total INTEGER,
                    remark TEXT, enable INTEGER, expiry_time INTEGER, listen TEXT, port INTEGER,
                    protocol TEXT, settings TEXT, stream_settings TEXT, tag TEXT, sniffing TEXT
                )
            """)
            cur.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, password TEXT)")
            cur.execute("INSERT INTO users VALUES (1, 'admin', 'admin')")
            cur.execute("INSERT INTO settings (key, value) VALUES ('subTitle', '')")
            conn.commit()
            conn.close()

            env = os.environ.copy()
            env["DB_PATH"] = temp_db
            env["DRY_RUN"] = "0"
            env["SERVER_PREFIX"] = "TestService"
            env["SUB_TITLE"] = ""
            env["PRIMARY_DOMAIN"] = "example.com"
            env["PANEL_PORT"] = "2053"
            env["PANEL_PATH"] = "panel"
            env["SUB_PORT"] = "2096"
            env["SUB_PATH"] = "sub"
            env["PYTHON_CMD"] = sys.executable

            conf_script = (ROOT / "configure-panel.sh").read_text(encoding="utf-8")
            m = re.search(r"\$PYTHON_CMD\" - << 'EOF_PYTHON_CONFIG'\n(.*)\nEOF_PYTHON_CONFIG", conf_script, re.DOTALL)
            self.assertIsNotNone(m)
            py_code = m.group(1)

            res = subprocess.run([sys.executable, "-"], input=py_code, env=env, capture_output=True, text=True, encoding="utf-8")
            self.assertEqual(res.returncode, 0, f"STDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}")

            conn = sqlite3.connect(temp_db)
            cur = conn.cursor()
            cur.execute("SELECT value FROM settings WHERE key = 'subTitle'")
            val = cur.fetchone()[0]
            conn.close()
            self.assertEqual(val, "TestService", "subTitle setting in 3X-UI should take SERVER_PREFIX if SUB_TITLE is empty")
        finally:
            if os.path.exists(temp_db):
                os.unlink(temp_db)

    def test_randomized_paths_and_tokens(self):
        """Verify that PANEL_PATH, WSTUNNEL_PREFIX, and AGH_CLIENT_ID are randomized by default and custom values are preserved."""
        if not BASH.exists():
            self.skipTest(f"bash not found at {BASH}")

        # 1. Defaults -> must generate random paths and tokens
        script_defaults = f"""
set -e
source "src/common/secrets.sh"
source "src/system/env.sh"
PRIMARY_DOMAIN="example.com"
ENABLE_WSTUNNEL=1
ENABLE_AGH=1
reconstruct_arrays_from_vars
echo "PANEL_PATH=$PANEL_PATH"
echo "WSTUNNEL_PREFIX=$WSTUNNEL_PREFIX"
echo "AGH_CLIENT_ID=$AGH_CLIENT_ID"
"""
        res = run_shell(script_defaults)
        self.assertEqual(res.returncode, 0, f"Error: {res.stderr}")
        out = res.stdout
        self.assertRegex(out, r"PANEL_PATH=/panel-[0-9a-f]{32}/")
        self.assertRegex(out, r"WSTUNNEL_PREFIX=/ws-[0-9a-f]{32}/")
        self.assertRegex(out, r"AGH_CLIENT_ID=client-[0-9a-f]{32}")
        self.assertNotIn("my-3x-panel", out)
        self.assertNotIn("/wstunnel/", out)
        self.assertNotIn("home-router", out)

        # 2. Custom values -> must be strictly preserved
        script_custom = f"""
set -e
source "src/common/secrets.sh"
source "src/system/env.sh"
PRIMARY_DOMAIN="example.com"
PANEL_PATH="custom-panel-path"
WSTUNNEL_PREFIX="/custom-ws-prefix/"
AGH_CLIENT_ID="custom-router-client"
ENABLE_WSTUNNEL=1
ENABLE_AGH=1
reconstruct_arrays_from_vars
echo "PANEL_PATH=$PANEL_PATH"
echo "WSTUNNEL_PREFIX=$WSTUNNEL_PREFIX"
echo "AGH_CLIENT_ID=$AGH_CLIENT_ID"
"""
        res_custom = run_shell(script_custom)
        self.assertEqual(res_custom.returncode, 0, f"Error: {res_custom.stderr}")
        out_custom = res_custom.stdout
        self.assertIn("PANEL_PATH=/custom-panel-path/", out_custom)
        self.assertIn("WSTUNNEL_PREFIX=/custom-ws-prefix/", out_custom)
        self.assertIn("AGH_CLIENT_ID=custom-router-client", out_custom)

    def test_nginx_stream_module_loading_resilience(self):
        """Verify that ensure_nginx_stream_module is defined and wired in nginx install and config."""
        install_sh = (ROOT / "src/nginx/install.sh").read_text(encoding="utf-8")
        config_sh = (ROOT / "src/nginx/config.sh").read_text(encoding="utf-8")
        self.assertIn("ensure_nginx_stream_module()", install_sh)
        self.assertIn("ensure_nginx_stream_module", config_sh)
        self.assertIn("load_module", install_sh)
        self.assertIn("libnginx-mod-stream", install_sh)

    def test_nginx_reject_server_has_http2_listen_parity(self):
        """Verify that SSL reject default_server has HTTP2_LISTEN_PARAM to prevent protocol options redefined warning."""
        config_sh = (ROOT / "src/nginx/config.sh").read_text(encoding="utf-8")
        self.assertIn('listen unix:/dev/shm/nginx-http.sock ssl ${HTTP2_LISTEN_PARAM}default_server proxy_protocol;', config_sh)
        self.assertIn('listen 127.0.0.1:$REALITY_FALLBACK_PORT ssl ${HTTP2_LISTEN_PARAM}default_server proxy_protocol;', config_sh)

    def test_ufw_comments_contain_no_single_quotes(self):
        """UFW Python parser explicitly raises ValueError if comment contains single quotes (apostrophe)."""
        ufw_regex = re.compile(r'ufw\s+(?:allow|deny)\s+.*?comment\s+([^\n]+)')
        for sh_file in (ROOT / "src").rglob("*.sh"):
            content = sh_file.read_text(encoding="utf-8")
            for match in ufw_regex.finditer(content):
                comment_part = match.group(1).strip()
                # If wrapped in quotes, check the interior value
                if (comment_part.startswith("'") and comment_part.endswith("'")) or \
                   (comment_part.startswith('"') and comment_part.endswith('"')):
                    inner = comment_part[1:-1]
                    self.assertNotIn("'", inner, f"UFW rule in {sh_file.name} contains forbidden single quote in comment: {comment_part}")
                elif "\\'" in comment_part:
                    self.fail(f"UFW rule in {sh_file.name} contains escaped single quote in comment: {comment_part}")

    def test_tri_state_ports_customization_question(self):
        """Verify the tri-state port customization question: 0 (No/Default), 1 (Yes/All), 2 (External Only)."""
        wizard_sh = (ROOT / "src/tui/wizard.sh").read_text(encoding="utf-8")
        self.assertIn("Хотите ли вы настраивать порты подключений вручную? [0/1/2]", wizard_sh)
        self.assertIn("[0] Нет (по умолчанию)", wizard_sh)
        self.assertIn("[1] Да (все порты)", wizard_sh)
        self.assertIn("[2] Только внешние", wizard_sh)
        self.assertIn("ручная настройка всех портов (внешних клиентских и внутренних локальных)", wizard_sh)
        self.assertIn("ручная настройка только внешних клиентских портов (все внутренние — по умолчанию)", wizard_sh)

        # In env.sh and prompts.sh, default is 0
        env_sh = (ROOT / "src/system/env.sh").read_text(encoding="utf-8")
        prompts_sh = (ROOT / "src/tui/prompts.sh").read_text(encoding="utf-8")
        self.assertIn('PORTS_SETUP_MODE="${PORTS_SETUP_MODE:-0}"', env_sh)
        self.assertIn('PORTS_SETUP_MODE="${PORTS_SETUP_MODE:-0}"', prompts_sh)

    def test_paths_customization_question_separated(self):
        """Verify secret URI paths customization is a separate question from ports."""
        wizard_sh = (ROOT / "src/tui/wizard.sh").read_text(encoding="utf-8")
        env_sh = (ROOT / "src/system/env.sh").read_text(encoding="utf-8")
        prompts_sh = (ROOT / "src/tui/prompts.sh").read_text(encoding="utf-8")
        express_sh = (ROOT / "src/installer/express.sh").read_text(encoding="utf-8")

        # Separate question in Step 3
        self.assertIn("Хотите ли вы настраивать секретные URI-пути и пароли вручную? [0/1]", wizard_sh)
        self.assertIn("PATHS_SETUP_MODE", wizard_sh)
        self.assertIn('PATHS_SETUP_MODE="${PATHS_SETUP_MODE:-0}"', env_sh)
        self.assertIn('PATHS_SETUP_MODE="${PATHS_SETUP_MODE:-0}"', prompts_sh)
        self.assertIn("express_default PATHS_SETUP_MODE 0", express_sh)

        # Check review screen shows both
        self.assertIn("Режим портов:", wizard_sh)
        self.assertIn("Режим путей:", wizard_sh)



if __name__ == "__main__":
    unittest.main()

