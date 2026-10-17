"""
tests/test_audit_regressions.py - Assert-based regression tests for audit findings R01-R09.
"""

import ast
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
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")


def run_shell(code: str, env: dict | None = None) -> subprocess.CompletedProcess:
    full_env = os.environ.copy()
    if env:
        full_env.update(env)
    return subprocess.run(
        [str(BASH), "-s"],
        input="export PATH=/usr/bin:/bin:$PATH\n" + code,
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
        conf_sh = (ROOT / "configure_3xui.sh").read_text(encoding="utf-8")
        m_rekey = re.search(r'"rekeyAfterTime":\s*"(\d+)-(\d+)"', conf_sh)
        m_reject = re.search(r'"rejectAfterTime":\s*"(\d+)-(\d+)"', conf_sh)
        self.assertIsNotNone(m_rekey, "rekeyAfterTime must be present in configure_3xui.sh")
        self.assertIsNotNone(m_reject, "rejectAfterTime must be present in configure_3xui.sh")
        max_rekey = int(m_rekey.group(2))
        min_reject = int(m_reject.group(1))
        self.assertLess(max_rekey, min_reject, f"max(rekeyAfterTime) [{max_rekey}] must be strictly less than min(rejectAfterTime) [{min_reject}]")

    def test_awg_cpa_in_reconcile_whitelist(self):
        """Verify that contentPaddingAddition and cpa are preserved during smart_reconcile_inbound."""
        inbounds_py = (ROOT / "src/xray/inbounds.py").read_text(encoding="utf-8")
        self.assertIn('"contentPaddingAddition"', inbounds_py, "contentPaddingAddition must be preserved in smart_reconcile_inbound")
        self.assertIn('"cpa"', inbounds_py, "cpa must be preserved in smart_reconcile_inbound")

    def test_manage_amneziawg_no_random_hpk_fallback(self):
        """Verify that manage_amneziawg.py does not invent random HPK for clients when server lacks HPK."""
        mgr_py = (ROOT / "src/awg/manage_amneziawg.py").read_text(encoding="utf-8")
        self.assertNotIn("HEADER_PROTECTION_KEY = base64.b64encode(secrets.token_bytes(32))", mgr_py,
                         "manage_amneziawg.py must not generate random fallback HPK when server lacks HPK")

    def test_awg_v3_template_parameters_consistency(self):
        """Verify configure_3xui.sh and update_repair.sh have consistent AWG v3 parameters."""
        conf_sh = (ROOT / "configure_3xui.sh").read_text(encoding="utf-8")
        upd_sh = (ROOT / "update_repair.sh").read_text(encoding="utf-8")
        for text, name in [(conf_sh, "configure_3xui.sh"), (upd_sh, "update_repair.sh")]:
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

    def test_awg_event_driven_prewarm_architecture(self):
        """Verify event-driven AWG pre-warm: definition before wizard, opt-in triggers, and sync."""
        entrypoint_sh = (ROOT / "src/entrypoints/setup_mask.main.sh").read_text(encoding="utf-8")
        idx_awg_include = entrypoint_sh.find('# @include "awg/setup.sh"')
        idx_wizard_include = entrypoint_sh.find('# @include "tui/wizard.sh"')
        self.assertNotEqual(idx_awg_include, -1, "awg/setup.sh must be included in setup_mask.main.sh")
        self.assertNotEqual(idx_wizard_include, -1, "tui/wizard.sh must be included in setup_mask.main.sh")
        self.assertLess(idx_awg_include, idx_wizard_include,
                        "awg/setup.sh must be included BEFORE tui/wizard.sh for event-driven pre-warm")

        setup_sh = (ROOT / "src/awg/setup.sh").read_text(encoding="utf-8")
        self.assertIn("start_amneziawg_preinstall_bg()", setup_sh)
        self.assertIn("sync_amneziawg_preinstall()", setup_sh)
        self.assertIn("install_amneziawg_packages_task()", setup_sh)

        wizard_sh = (ROOT / "src/tui/wizard.sh").read_text(encoding="utf-8")
        self.assertIn("start_amneziawg_preinstall_bg", wizard_sh)

        compiled_sh = (ROOT / "setup_mask.sh").read_text(encoding="utf-8")
        def_pos = compiled_sh.find("start_amneziawg_preinstall_bg()")
        self.assertNotEqual(def_pos, -1, "setup_mask.sh must contain start_amneziawg_preinstall_bg definition")
        trigger_count = compiled_sh.count("start_amneziawg_preinstall_bg")
        self.assertGreaterEqual(trigger_count, 4,
                                "setup_mask.sh must have multiple event-driven prewarm trigger points")

    def test_awg_i1_dns_template_support(self):
        """Verify that DNS_I1_TEMPLATE is defined and matches the icloud.com 44-byte DNS response."""
        mgr_py = (ROOT / "src/awg/manage_amneziawg.py").read_text(encoding="utf-8")
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
        import manage_amneziawg as mgr

        # 1. Verify CLI argument support in source code
        mgr_src = (ROOT / "src/awg/manage_amneziawg.py").read_text(encoding="utf-8")
        for flag in ["--preset=", "--mtu=", "--jc=", "--jmin=", "--jmax=", "--keepalive=", "--allowed-ips="]:
            self.assertIn(flag, mgr_src, f"CLI flag {flag} must be supported in manage_amneziawg.py")

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
Endpoint = 193.180.208.5:32626
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
        self.assertEqual(data["hostName"], "193.180.208.5")


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

        raw = (ROOT / "configure_3xui.sh").read_text(encoding="utf-8").split("<< 'EOF_PYTHON_CONFIG'", 1)[1].split("\n", 1)[1]
        code = raw.split("conn.commit()", 1)[0] + "conn.commit()\n"
        env = dict(DB_PATH=str(db), PRIMARY_DOMAIN="audit.example", DRY_RUN="0",
                   ENABLE_STEAL="n", ENABLE_CLASSIC="n", ENABLE_HY2="n",
                   ENABLE_AWG_V3="n", ENABLE_AWG_V2="n", ENABLE_WARP="y")
        ns = {}
        with patch.dict(os.environ, env, clear=True), patch("subprocess.run", return_value=types.SimpleNamespace(returncode=1, stdout="")):
            exec(compile(code, "configure_3xui.sh", "exec"), ns)
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


if __name__ == "__main__":
    unittest.main()
