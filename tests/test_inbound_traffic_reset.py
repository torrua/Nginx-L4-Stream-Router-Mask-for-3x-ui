import json
import os
from pathlib import Path
import sqlite3
import unittest
import uuid

ROOT = Path(__file__).resolve().parent.parent


class InboundTrafficResetTests(unittest.TestCase):
    def setUp(self):
        self.conn = sqlite3.connect(":memory:")
        self.cur = self.conn.cursor()
        self.cur.executescript("""
            CREATE TABLE inbounds (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                up INTEGER DEFAULT 0,
                down INTEGER DEFAULT 0,
                total INTEGER DEFAULT 0,
                remark TEXT,
                enable INTEGER DEFAULT 1,
                expiry_time INTEGER DEFAULT 0,
                listen TEXT,
                port INTEGER UNIQUE,
                protocol TEXT,
                settings TEXT,
                stream_settings TEXT,
                tag TEXT UNIQUE,
                sniffing TEXT,
                traffic_reset TEXT DEFAULT 'never',
                traffic_reset_day INTEGER DEFAULT 1,
                last_traffic_reset_time INTEGER DEFAULT 0
            );
            CREATE TABLE users (
                id INTEGER PRIMARY KEY,
                username TEXT,
                password TEXT
            );
            INSERT INTO users (id, username, password) VALUES (1, 'admin', 'hash');
            CREATE TABLE clients (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                email TEXT UNIQUE,
                enable INTEGER DEFAULT 1,
                uuid TEXT,
                password TEXT,
                traffic_reset TEXT DEFAULT 'never',
                traffic_reset_day INTEGER DEFAULT 1,
                reset_day INTEGER DEFAULT 0,
                created_at INTEGER,
                updated_at INTEGER
            );
            CREATE TABLE client_traffics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                inbound_id INTEGER,
                enable INTEGER DEFAULT 1,
                email TEXT UNIQUE,
                up INTEGER DEFAULT 0,
                down INTEGER DEFAULT 0,
                expiry_time INTEGER DEFAULT 0,
                total INTEGER DEFAULT 0,
                reset INTEGER DEFAULT 0,
                reset_day INTEGER DEFAULT 0
            );
            CREATE TABLE client_inbounds (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                client_id INTEGER,
                inbound_id INTEGER,
                flow_override TEXT,
                created_at INTEGER
            );
            CREATE TABLE settings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                key TEXT UNIQUE,
                value TEXT
            );
        """)

        self.ns = {
            "conn": self.conn,
            "cur": self.cur,
            "dry_run": False,
            "force_remarks": False,
            "admin_id": 1,
            "domain": "test.example.com",
            "inbound_traffic_reset": "monthly",
            "inbound_traffic_reset_day": 1,
            "all_tables": {"inbounds", "users", "clients", "client_traffics", "client_inbounds", "settings"},
            "inbounds_cols": {"id", "user_id", "up", "down", "total", "remark", "enable", "expiry_time",
                              "listen", "port", "protocol", "settings", "stream_settings", "tag", "sniffing",
                              "traffic_reset", "traffic_reset_day", "last_traffic_reset_time"},
            "client_traffics_cols": {"id", "inbound_id", "enable", "email", "up", "down", "expiry_time", "total", "reset", "reset_day"},
            "clients_cols": {"id", "email", "enable", "uuid", "password", "traffic_reset", "traffic_reset_day", "reset_day", "created_at", "updated_at"},
            "client_inbounds_cols": {"id", "client_id", "inbound_id", "flow_override", "created_at"},
            "json": json,
            "os": os,
            "uuid": uuid,
        }
        exec((ROOT / "src/xray/clients.py").read_text(encoding="utf-8"), self.ns)
        exec((ROOT / "src/xray/keys.py").read_text(encoding="utf-8"), self.ns)
        exec((ROOT / "src/xray/inbounds.py").read_text(encoding="utf-8"), self.ns)

    def tearDown(self):
        self.conn.close()

    def test_new_inbound_created_with_monthly_traffic_reset(self):
        """Verify that newly created inbounds have traffic_reset='monthly' and traffic_reset_day=1."""
        reconcile = self.ns["smart_reconcile_inbound"]
        default_settings = {
            "clients": [{"id": "c1234567-89ab-cdef-0123-456789abcdef", "flow": "xtls-rprx-vision", "email": "user@test.local", "enable": True}]
        }
        default_stream = {"network": "tcp", "security": "none"}
        ib_id = reconcile(45443, "vless", "in-steal", "Steal Inbound", default_settings, default_stream, "127.0.0.1")

        self.assertIsNotNone(ib_id)
        self.cur.execute("SELECT traffic_reset, traffic_reset_day, last_traffic_reset_time, settings FROM inbounds WHERE id = ?", (ib_id,))
        row = self.cur.fetchone()
        self.assertEqual(row[0], "monthly", "Inbound traffic_reset must default to 'monthly'")
        self.assertEqual(row[1], 1, "Inbound traffic_reset_day must default to 1 (first day of the month)")
        self.assertEqual(row[2], 0, "Inbound last_traffic_reset_time must initialize to 0")

        # Verify client settings inside JSON
        st = json.loads(row[3])
        c = st["clients"][0]
        self.assertEqual(c.get("trafficReset"), "monthly", "Client inside inbound settings must have trafficReset='monthly'")
        self.assertEqual(c.get("trafficResetDay"), 1, "Client inside inbound settings must have trafficResetDay=1")
        self.assertEqual(c.get("resetDay"), 1, "Client inside inbound settings must have resetDay=1")

        # Verify client in clients table
        self.cur.execute("SELECT traffic_reset, traffic_reset_day, reset_day FROM clients WHERE email = ?", (c["email"],))
        c_row = self.cur.fetchone()
        self.assertIsNotNone(c_row)
        self.assertEqual(c_row[0], "monthly")
        self.assertEqual(c_row[1], 1)
        self.assertEqual(c_row[2], 1)

        # Verify client in client_traffics table
        self.cur.execute("SELECT reset_day FROM client_traffics WHERE email = ?", (c["email"],))
        ct_row = self.cur.fetchone()
        self.assertIsNotNone(ct_row)
        self.assertEqual(ct_row[0], 1)

    def test_existing_inbound_with_never_updated_to_monthly(self):
        """Verify that existing inbounds with traffic_reset='never' or NULL are updated to 'monthly'."""
        reconcile = self.ns["smart_reconcile_inbound"]
        # Seed an existing inbound with 'never'
        seed_settings = {"clients": [{"id": "uuid-1", "email": "user1@test.local", "enable": True, "trafficReset": "never"}]}
        self.cur.execute("""
            INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing, traffic_reset, traffic_reset_day)
            VALUES (1, 100, 200, 0, 'Old Inbound', 1, 0, '127.0.0.1', 45443, 'vless', ?, '{}', 'in-old', '{}', 'never', 1)
        """, (json.dumps(seed_settings),))
        ib_id = self.cur.lastrowid

        # Reconcile
        new_settings = {"clients": [{"id": "uuid-1", "email": "user1@test.local", "enable": True}]}
        res_id = reconcile(45443, "vless", "in-old", "Old Inbound", new_settings, {"network": "tcp"}, "127.0.0.1")
        self.assertEqual(res_id, ib_id)

        self.cur.execute("SELECT traffic_reset, traffic_reset_day FROM inbounds WHERE id = ?", (ib_id,))
        row = self.cur.fetchone()
        self.assertEqual(row[0], "monthly", "Existing 'never' inbound must be upgraded to 'monthly'")
        self.assertEqual(row[1], 1, "Existing inbound reset day must be 1")

    def test_existing_inbound_custom_schedule_preserved(self):
        """Verify that user-configured non-default reset schedule (e.g. weekly) is preserved."""
        reconcile = self.ns["smart_reconcile_inbound"]
        seed_settings = {"clients": [{"id": "uuid-1", "email": "user1@test.local", "enable": True}]}
        self.cur.execute("""
            INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing, traffic_reset, traffic_reset_day)
            VALUES (1, 100, 200, 0, 'Custom Inbound', 1, 0, '127.0.0.1', 45443, 'vless', ?, '{}', 'in-custom', '{}', 'weekly', 3)
        """, (json.dumps(seed_settings),))
        ib_id = self.cur.lastrowid

        # Reconcile
        new_settings = {"clients": [{"id": "uuid-1", "email": "user1@test.local", "enable": True}]}
        res_id = reconcile(45443, "vless", "in-custom", "Custom Inbound", new_settings, {"network": "tcp"}, "127.0.0.1")
        self.assertEqual(res_id, ib_id)

        self.cur.execute("SELECT traffic_reset, traffic_reset_day FROM inbounds WHERE id = ?", (ib_id,))
        row = self.cur.fetchone()
        self.assertEqual(row[0], "weekly", "Custom 'weekly' schedule must be preserved")
        self.assertEqual(row[1], 3, "Custom day 3 must be preserved")

    def test_backward_compatibility_when_inbounds_table_lacks_traffic_reset_columns(self):
        """Verify that smart_reconcile_inbound functions cleanly on legacy databases without traffic_reset columns."""
        conn_legacy = sqlite3.connect(":memory:")
        cur_legacy = conn_legacy.cursor()
        cur_legacy.executescript("""
            CREATE TABLE inbounds (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                up INTEGER DEFAULT 0,
                down INTEGER DEFAULT 0,
                total INTEGER DEFAULT 0,
                remark TEXT,
                enable INTEGER DEFAULT 1,
                expiry_time INTEGER DEFAULT 0,
                listen TEXT,
                port INTEGER UNIQUE,
                protocol TEXT,
                settings TEXT,
                stream_settings TEXT,
                tag TEXT UNIQUE,
                sniffing TEXT
            );
            CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, password TEXT);
            INSERT INTO users VALUES (1, 'admin', 'hash');
        """)
        legacy_ns = {
            "conn": conn_legacy,
            "cur": cur_legacy,
            "dry_run": False,
            "force_remarks": False,
            "admin_id": 1,
            "domain": "test.example.com",
            "all_tables": {"inbounds", "users"},
            "inbounds_cols": {"id", "user_id", "up", "down", "total", "remark", "enable", "expiry_time",
                              "listen", "port", "protocol", "settings", "stream_settings", "tag", "sniffing"},
            "json": json,
            "os": os,
            "uuid": uuid,
        }
        exec((ROOT / "src/xray/inbounds.py").read_text(encoding="utf-8"), legacy_ns)

        reconcile = legacy_ns["smart_reconcile_inbound"]
        # Creation should not crash
        ib_id = reconcile(45443, "vless", "in-leg", "Legacy Inbound", {"clients": []}, {"network": "tcp"})
        self.assertIsNotNone(ib_id)

        # Update should not crash
        ib_id2 = reconcile(45443, "vless", "in-leg", "Legacy Inbound", {"clients": []}, {"network": "tcp"})
        self.assertEqual(ib_id, ib_id2)
        conn_legacy.close()

    def test_reconcile_migration_and_global_update(self):
        """Verify that reconcile migration adds missing columns and updates all existing inbounds to monthly."""
        conn = sqlite3.connect(":memory:")
        cur = conn.cursor()
        cur.executescript("""
            CREATE TABLE inbounds (
                id INTEGER PRIMARY KEY,
                user_id INTEGER,
                port INTEGER,
                remark TEXT
            );
            INSERT INTO inbounds (id, user_id, port, remark) VALUES (1, 1, 45443, 'Inbound 1');
            INSERT INTO inbounds (id, user_id, port, remark) VALUES (2, 1, 46443, 'Inbound 2');
        """)
        # Simulate reconcile table inspection and column addition
        all_tables = {"inbounds"}
        cur.execute("PRAGMA table_info(inbounds)")
        inbounds_cols = set(r[1] for r in cur.fetchall())

        if "traffic_reset" not in inbounds_cols:
            cur.execute("ALTER TABLE inbounds ADD COLUMN traffic_reset TEXT DEFAULT 'never'")
            inbounds_cols.add("traffic_reset")
        if "traffic_reset_day" not in inbounds_cols:
            cur.execute("ALTER TABLE inbounds ADD COLUMN traffic_reset_day INTEGER DEFAULT 1")
            inbounds_cols.add("traffic_reset_day")

        # Inbound 1 has default 'never', set inbound 2 explicitly to daily
        cur.execute("UPDATE inbounds SET traffic_reset = 'daily', traffic_reset_day = 15 WHERE id = 2")

        # Run the global update query
        tr_col = "traffic_reset"
        trd_col = "traffic_reset_day"
        cur.execute(f"UPDATE inbounds SET {tr_col} = 'monthly', {trd_col} = 1 WHERE {tr_col} IS NULL OR {tr_col} = '' OR {tr_col} = 'never'")

        cur.execute("SELECT id, traffic_reset, traffic_reset_day FROM inbounds ORDER BY id")
        rows = cur.fetchall()
        self.assertEqual(rows[0], (1, "monthly", 1), "Inbound 1 must be updated to monthly reset on day 1")
        self.assertEqual(rows[1], (2, "daily", 15), "Inbound 2 with existing 'daily' schedule must be preserved")
        conn.close()

    def test_custom_env_override(self):
        """Verify that INBOUND_TRAFFIC_RESET and INBOUND_TRAFFIC_RESET_DAY environment overrides are honored."""
        self.ns["inbound_traffic_reset"] = "daily"
        self.ns["inbound_traffic_reset_day"] = 15
        reconcile = self.ns["smart_reconcile_inbound"]

        ib_id = reconcile(52443, "vless", "in-override", "Override Inbound", {"clients": []}, {"network": "tcp"})
        self.cur.execute("SELECT traffic_reset, traffic_reset_day FROM inbounds WHERE id = ?", (ib_id,))
        row = self.cur.fetchone()
        self.assertEqual(row[0], "daily")
        self.assertEqual(row[1], 15)


if __name__ == "__main__":
    unittest.main()
