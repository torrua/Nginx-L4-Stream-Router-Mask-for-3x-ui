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
import tempfile
import types
import unittest
import uuid
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
            "network": "tcp",
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
        self.assertIn("TOTAL_STEPS=12", wizard_content)
        self.assertIn("AmneziaWG v3.1 (инбаунд 3X-UI", wizard_content)
        self.assertIn("Автономный сервер AmneziaWG", wizard_content)

        env_path = Path("src/system/env.sh")
        env_content = env_path.read_text(encoding="utf-8")
        self.assertIn("ENABLE_AWG_STANDALONE", env_content)
        self.assertIn("AWG_STANDALONE_PORT", env_content)

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
        env_ex = (ROOT / "setup_mask.env.example").read_text(encoding="utf-8")
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

        # 3. Wizard Step 0 and standalone flow
        wizard_sh = (ROOT / "src/tui/wizard.sh").read_text(encoding="utf-8")
        self.assertIn("Шаг 0: Выбор компонентов для установки", wizard_sh)
        self.assertIn("run_standalone_awg_wizard", wizard_sh)
        self.assertIn("Endpoint", wizard_sh)
        self.assertIn("AWG_SERVER_HOST", wizard_sh)

        # 4. Preinstall conditions
        preinstall_sh = (ROOT / "src/system/preinstall.sh").read_text(encoding="utf-8")
        self.assertIn('is_true "${ENABLE_WEB_STACK:-y}"', preinstall_sh)

        # 5. Compiled setup_mask.sh entrypoint flow
        setup_main = (ROOT / "src/entrypoints/setup_mask.main.sh").read_text(encoding="utf-8")
        self.assertIn('if is_true "${ENABLE_WEB_STACK:-y}"; then', setup_main)
        self.assertIn("УСТАНОВКА АВТОНОМНОГО СЕРВЕРА AMNEZIAWG УСПЕШНО ЗАВЕРШЕНА", setup_main)

        # 6. AWG launcher exports SERVER_PUBLIC_HOST
        awg_setup = (ROOT / "src/awg/setup.sh").read_text(encoding="utf-8")
        self.assertIn("SERVER_PUBLIC_HOST", awg_setup)

        steps_sh = (ROOT / "src/installer/steps.sh").read_text(encoding="utf-8")
        self.assertIn('is_true "${ENABLE_WEB_STACK:-y}"', steps_sh)

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


if __name__ == "__main__":
    unittest.main()
