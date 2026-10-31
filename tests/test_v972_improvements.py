import json
import sqlite3
import subprocess
from pathlib import Path
from unittest import TestCase
from unittest.mock import patch, MagicMock

ROOT = Path(__file__).resolve().parent.parent

class TestV972Improvements(TestCase):

    def test_point1_panel_proxy_headers_and_env(self):
        """Test Point 1: Nginx headers X-Real-IP, X-Forwarded-Proto https, X-Forwarded-Port 443 and env exports."""
        nginx_conf = (ROOT / "src/nginx/config.sh").read_text(encoding="utf-8")
        self.assertIn(r"proxy_set_header X-Real-IP \$remote_addr;", nginx_conf)
        self.assertIn(r"proxy_set_header X-Forwarded-Proto https;", nginx_conf)
        self.assertIn(r"proxy_set_header X-Forwarded-Port 443;", nginx_conf)

        env_sh = (ROOT / "src/system/env.sh").read_text(encoding="utf-8")
        self.assertIn('PANEL_PUBLIC_URL="https://${PRIMARY_DOMAIN:-}/${_save_panel_path}/"', env_sh)
        self.assertIn('PANEL_EXTERNAL_PORT="443"', env_sh)

        cred_sh = (ROOT / "src/panel/configure.sh").read_text(encoding="utf-8")
        self.assertIn('PANEL_PUBLIC_URL="https://${PRIMARY_DOMAIN}${PANEL_PATH%/}/"', cred_sh)
        self.assertIn('PANEL_EXTERNAL_PORT=443', cred_sh)

    def test_point2_alpine_compatibility_and_launcher(self):
        """Test Point 2: Alpine installs bash, python3, iproute2, iptables; manage-clients.sh uses #!/bin/sh."""
        pkg_sh = (ROOT / "src/system/packages.sh").read_text(encoding="utf-8")
        self.assertIn("apk add --no-cache bash python3 iproute2 iptables", pkg_sh)

        launcher = (ROOT / "src/awg/manage-clients.sh").read_text(encoding="utf-8")
        self.assertTrue(launcher.startswith("#!/bin/sh"), "Launcher must use POSIX #!/bin/sh")
        self.assertNotIn("set -euo pipefail", launcher, "POSIX sh must not use pipefail flag")

    def test_point3_amneziawg_inbound_external_proxy_in_settings(self):
        """Test Point 3: 3X-UI AmneziaWG inbound writes externalProxy into settings with forceTls='same'."""
        db = sqlite3.connect(":memory:")
        cur = db.cursor()
        cur.execute("""
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

        # Execute inbounds.py inside test namespace
        inbounds_code = (ROOT / "src/xray/inbounds.py").read_text(encoding="utf-8")
        ns = {
            "cur": cur,
            "admin_id": 1,
            "dry_run": False,
            "domain": "mask.example.com",
            "inbounds_cols": {"id", "user_id", "up", "down", "total", "remark", "enable", "expiry_time", "listen", "port", "protocol", "settings", "stream_settings", "tag", "sniffing"},
            "json": json
        }
        exec(inbounds_code, ns)
        reconcile = ns["smart_reconcile_inbound"]

        awg_set = {
            "server": {"h1": "1", "h2": "2", "h3": "3", "h4": "4", "jc": 4, "jmin": 40, "jmax": 70, "s1": 16, "s2": 16, "s3": 16, "s4": 16, "mtu": 1280},
            "clients": [{"email": "Client", "allowedIPs": ["10.8.1.2/32"]}]
        }
        awg_str = {"externalProxy": [{"dest": "mask.example.com", "port": 8443, "remark": "AWG v3"}]}

        reconcile(8443, "amneziawg", "in-8443-udp", "AmneziaWG v3", awg_set, awg_str, listen="0.0.0.0")

        cur.execute("SELECT settings, stream_settings FROM inbounds WHERE port = 8443")
        row = cur.fetchone()
        self.assertIsNotNone(row)
        settings = json.loads(row[0])
        stream = json.loads(row[1])

        # Verify settings has externalProxy with domain, port 8443, forceTls same
        self.assertIn("externalProxy", settings)
        self.assertEqual(settings["externalProxy"][0]["dest"], "mask.example.com")
        self.assertEqual(settings["externalProxy"][0]["port"], 8443)
        self.assertEqual(settings["externalProxy"][0]["forceTls"], "same")

        # Verify stream_settings retains forceTls none for UDP
        self.assertEqual(stream["externalProxy"][0]["forceTls"], "none")

    def test_point4_subnet_isolation(self):
        """Test Point 4: Subnets isolated: Standalone AWG on 10.8.0.0/24 (gateway 10.8.0.1), 3X-UI on 10.8.1.0/24."""
        awg_setup = (ROOT / "src/awg/setup.sh").read_text(encoding="utf-8")
        self.assertIn("Address = 10.8.0.1/24", awg_setup)

        from src.awg import manage_clients
        # Check fallback subnet in manage_clients allocates within 10.8.0.0/24
        with patch.object(manage_clients, "load_clients_table", return_value=[]), \
             patch.object(manage_clients, "read_backend_file", return_value="[Interface]\nAddress = 10.8.0.1/24\n"):
            ip = manage_clients.find_next_ip()
            self.assertTrue(ip.startswith("10.8.0."), f"Expected 10.8.0.x IP for standalone, got {ip}")

        # Check 3X-UI configure.sh and reconcile.py defaults to 10.8.1.0/24
        conf_sh = (ROOT / "src/panel/configure.sh").read_text(encoding="utf-8")
        self.assertIn('AWG_SUBNET_IP="${AWG_SUBNET_IP:-10.8.1.0}"', conf_sh)
        self.assertIn('AWG_SUBNET_CIDR="${AWG_SUBNET_CIDR:-24}"', conf_sh)

        reconcile_py = (ROOT / "src/panel/reconcile.py").read_text(encoding="utf-8")
        self.assertIn('awg_subnet_ip = os.environ.get("AWG_SUBNET_IP") or "10.8.1.0"', reconcile_py)
        self.assertIn('awg_subnet_cidr = int(os.environ.get("AWG_SUBNET_CIDR") or "24")', reconcile_py)

    @patch("subprocess.run")
    def test_point5_ufw_persistence_on_port_change(self, mock_run):
        """Test Point 5: Firewall logic uses UFW when active with delete of old port and iptables fallback."""
        from src.awg import manage_clients

        # Case A: UFW active
        mock_run.return_value = MagicMock(stdout="Status: active\nLogging: on", returncode=0)
        res_ufw = manage_clients.update_firewall_port(8445, old_port=8443)
        self.assertEqual(res_ufw["method"], "ufw")
        calls = [c[0][0] for c in mock_run.call_args_list]
        self.assertIn(["ufw", "allow", "8445/udp", "comment", "AmneziaWG UDP Port"], calls)
        self.assertIn(["ufw", "delete", "allow", "8443/udp"], calls)

        # Case B: UFW inactive / not found -> iptables fallback
        mock_run.reset_mock()
        def fake_run(cmd, *args, **kwargs):
            if cmd[0] == "ufw":
                raise FileNotFoundError()
            return MagicMock(returncode=0)

        mock_run.side_effect = fake_run
        res_iptables = manage_clients.update_firewall_port(9445)
        self.assertEqual(res_iptables["method"], "iptables")

    def test_point6_awg_mgr_binary_permissions_and_wrapper(self):
        """Test Point 6: Symlinks /usr/local/bin/awg-mgr set to chmod 755 and wrappers execute binaries directly."""
        awg_setup = (ROOT / "src/awg/setup.sh").read_text(encoding="utf-8")
        self.assertIn("chmod 755 /usr/local/bin/awg-mgr /usr/local/bin/awg-cli", awg_setup)

        launcher = (ROOT / "src/awg/manage-clients.sh").read_text(encoding="utf-8")
        self.assertIn('exec "$AWG_DIR/awg-mgr" "$@"', launcher)

    def test_classic_sni_deduplication_repairs_multiline_to_single(self):
        """Verify that an inbound with 8 externalProxy entries is automatically pruned to 1 entry by default."""
        db = sqlite3.connect(":memory:")
        cur = db.cursor()
        cur.execute("""
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

        inbounds_code = (ROOT / "src/xray/inbounds.py").read_text(encoding="utf-8")
        ns = {
            "cur": cur,
            "admin_id": 1,
            "dry_run": False,
            "domain": "mask.example.com",
            "inbounds_cols": {"id", "user_id", "up", "down", "total", "remark", "enable", "expiry_time", "listen", "port", "protocol", "settings", "stream_settings", "tag", "sniffing"},
            "json": json
        }
        exec(inbounds_code, ns)
        reconcile = ns["smart_reconcile_inbound"]

        c_set = {"clients": [{"id": "uuid", "email": "Client"}]}
        # Simulate 8 existing entries in database
        old_8_ext = [
            {"dest": "mask.example.com", "port": 443, "forceTls": "same", "sni": f"sni{i}.example.com", "remark": "VLESS Classic"}
            for i in range(1, 9)
        ]
        cur.execute("""
            INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
            VALUES (1, 0, 0, 0, 'VLESS Classic', 1, 0, '127.0.0.1', 46443, 'vless', ?, ?, 'in-classic-reality', '{}')
        """, (json.dumps(c_set), json.dumps({"network": "tcp", "security": "reality", "externalProxy": old_8_ext})))
        db.commit()

        # Reconcile with 1 target entry (default deduplication)
        new_1_ext = [{"dest": "mask.example.com", "port": 443, "forceTls": "same", "sni": "sni1.example.com", "remark": "VLESS Classic"}]
        reconcile(46443, "vless", "in-classic-reality", "VLESS Classic", c_set, {"network": "tcp", "security": "reality", "externalProxy": new_1_ext}, listen="127.0.0.1")

        cur.execute("SELECT stream_settings FROM inbounds WHERE port = 46443")
        res_st = json.loads(cur.fetchone()[0])
        # Assert pruned from 8 to exactly 1
        self.assertEqual(len(res_st["externalProxy"]), 1, f"Expected 1 externalProxy item, got {len(res_st['externalProxy'])}")
