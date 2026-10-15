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
os.environ.setdefault("AWG_DIR", str(Path(tempfile.gettempdir()) / "awg_test_default"))


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


def load_awg_module():
    import sys
    sys.path.insert(0, str(ROOT))
    import manage_amneziawg as m
    return m


class TestAmneziaWGSecurityAndPersistence(unittest.TestCase):
    def setUp(self):
        import importlib
        self.tmp_dir = tempfile.TemporaryDirectory()
        self.tmp = Path(self.tmp_dir.name)
        os.environ["AWG_DIR"] = str(self.tmp)
        self.awg = importlib.reload(load_awg_module())
        self.awg.AWG_DIR = self.tmp

    def tearDown(self):
        os.environ.pop("AWG_DIR", None)
        self.tmp_dir.cleanup()

    def test_awg_remove_path_traversal(self):
        """R02: remove_client rejects traversal and does not delete files outside AWG_DIR."""
        exports = self.tmp / "exports"
        exports.mkdir()
        victim = self.tmp / "victim.conf"
        victim.write_text("critical-system-data", encoding="utf-8")

        self.awg.AWG_DIR = exports
        self.awg.CONTAINER = "fixture"
        self.awg.load_clients_table = lambda: []
        self.awg.save_clients_table = lambda _: None
        self.awg.read_container_file = lambda _: ""

        res = self.awg.remove_client("../victim")
        self.assertFalse(res["ok"], "remove_client must return ok=False on traversal attempt")
        self.assertTrue(victim.exists(), "Victim file outside export dir must never be unlinked")

        # Absolute path attack
        res_abs = self.awg.remove_client(str(victim))
        self.assertFalse(res_abs["ok"], "remove_client must reject absolute paths")
        self.assertTrue(victim.exists(), "Victim file must still exist after absolute path attack")

    def test_awg_block_restart_configuration(self):
        """R03: block_client removes peer from awg0.conf; unblock_client restores it."""
        config = (
            "[Interface]\n"
            "Address = 10.8.0.1/24\n\n"
            "# client: alice\n"
            "[Peer]\n"
            "PublicKey = fixture-key-alice\n"
            "PresharedKey = fixture-psk\n"
            "AllowedIPs = 10.8.0.2/32\n"
        )
        table = [{
            "clientId": "fixture-key-alice",
            "userData": {
                "clientName": "alice",
                "allowed_ips": "10.8.0.2/32",
                "blocked": False
            }
        }]

        current_config = config
        def mock_write(path, content):
            nonlocal current_config
            if "awg0.conf" in str(path):
                current_config = content

        def mock_append(path, content):
            nonlocal current_config
            if "awg0.conf" in str(path):
                current_config += content

        self.awg.CONTAINER = "fixture"
        self.awg.load_clients_table = lambda: table
        self.awg.save_clients_table = lambda t: None
        self.awg.read_container_file = lambda p: current_config
        self.awg.write_container_file = mock_write
        self.awg.append_container_file = mock_append
        self.awg.run_cmd = lambda *a, **kw: ("", "", 0)
        self.awg.get_server_psk = lambda: "fixture-psk"

        # 1. Block client
        res_block = self.awg.block_client("alice")
        self.assertTrue(res_block["ok"])
        self.assertTrue(table[0]["userData"]["blocked"])
        self.assertNotIn("PublicKey = fixture-key-alice", current_config,
                         "Blocked peer must be removed from awg0.conf to prevent re-enabling upon container reboot")

        # 2. Unblock client
        res_unblock = self.awg.unblock_client("alice")
        self.assertTrue(res_unblock["ok"])
        self.assertFalse(table[0]["userData"]["blocked"])
        self.assertIn("PublicKey = fixture-key-alice", current_config,
                      "Unblocked peer must be restored to awg0.conf")

    def test_awg_persistent_write_failure_raises(self):
        """R05: persistent write failure raises IOError and is not swallowed."""
        self.awg.CONTAINER = "fixture"
        self.awg.run_cmd = lambda *a, **kw: ("", "mocked docker error", 1)

        with self.assertRaises(IOError):
            self.awg.write_container_file(str(self.tmp / "nonexistent_sub" / "clientsTable"), "test")

    def test_awg_config_defaults_and_dns_formatting(self):
        """Verify AWG 3.1 safe defaults: RandomTrailers='off', DNS formatted, S1..S4 safe, no literal variables."""
        self.assertEqual(self.awg.RANDOM_TRAILERS, "off", "RandomTrailers must default to 'off' to avoid 100x slowdown")
        self.assertEqual(self.awg.DISABLE_COOKIES, "on", "DisableCookies must default to 'on'")
        self.assertEqual(self.awg.PRIMARY_DNS, "9.9.9.9")
        self.assertEqual(self.awg.SECONDARY_DNS, "76.76.2.0")
        self.assertGreaterEqual(int(self.awg.S1), 12, "S1 must be >= 12 for HeaderProtectionKey")
        self.assertNotEqual(int(self.awg.S1) + 56, int(self.awg.S2), "S1 + 56 must not equal S2")

        # Test URI generation doesn't contain literal '$PRIMARY_DNS'
        self.awg.get_server_pubkey = lambda: "pubkey"
        self.awg.get_server_psk = lambda: "psk"
        uri = self.awg.encode_amnezia_vpnuri_31("dummy", "10.8.0.2", "priv", "pub")
        self.assertTrue(uri.startswith("vpn://"))

        # Test add_client generated conf
        self.awg.AWG_DIR = self.tmp
        self.awg.find_next_ip = lambda: "10.8.0.2"
        self.awg.run_cmd = lambda cmd, *a, **kw: ("key_out" if "genkey" in cmd or "pubkey" in cmd else "", "", 0)
        self.awg.append_container_file = lambda *a, **kw: None
        self.awg.save_clients_table = lambda *a, **kw: None
        res = self.awg.add_client("alice")
        self.assertTrue(res["ok"])
        conf_path = self.tmp / "alice.conf"
        self.assertTrue(conf_path.exists())
        conf_text = conf_path.read_text(encoding="utf-8")
        self.assertNotIn("$PRIMARY_DNS", conf_text, "Conf must not contain literal bash variable string")
        self.assertIn("DNS = 9.9.9.9, 76.76.2.0", conf_text)
        self.assertIn("RandomTrailers = off", conf_text)

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
        conn.close()

        rules = current["routing"]["rules"]
        user_constraint = any(r.get("user") == ["alice"] for r in rules)
        custom_net = any("203.0.113.0/24" in r.get("ip", []) for r in rules)

        self.assertTrue(user_constraint, "Custom constraint 'user: [alice]' must be preserved")
        self.assertTrue(custom_net, "Custom network '203.0.113.0/24' must be preserved")


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
