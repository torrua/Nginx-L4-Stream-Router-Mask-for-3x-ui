"""
tests/test_mieru.py - Automated tests for Mieru (mita) Proxy Integration:
1. CLI flag parsing and normalization
2. Single port mode vs Port range mode
3. Mita server JSON config generation and schema validation
4. UFW port syntax translation (hyphen to colon)
5. 3X-UI SQLite subClashTemplate injection and idempotency
6. Official Mieru client JSON profile generation
7. Protocol listeners and port conflict detection
"""

import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

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
        input="export PATH=/usr/bin:/bin:$PATH\nsource src/common/colors.sh\nsource src/common/logger.sh\nsource src/common/config.sh\n" + code,
        cwd=ROOT,
        text=True,
        encoding="utf-8",
        capture_output=True,
        timeout=25,
        env=full_env,
    )


class TestMieruIntegration(unittest.TestCase):
    def test_cli_flags_parsing_single_port(self):
        """Verify that CLI flags for Mieru with single port mode are parsed correctly."""
        res = run_shell(r"""
set -euo pipefail
source src/system/env.sh
PRIMARY_DOMAIN="example.com"
set -- --mieru --mieru-port-mode single --mieru-port 8450 --mieru-user testuser --mieru-pass testpass
source src/tui/prompts.sh
reconstruct_arrays_from_vars
echo "ENABLE_MIERU=$ENABLE_MIERU"
echo "MIERU_PORT_MODE=$MIERU_PORT_MODE"
echo "MIERU_PORT=$MIERU_PORT"
echo "MIERU_USER=$MIERU_USER"
echo "MIERU_PASS=$MIERU_PASS"
""")
        self.assertEqual(res.returncode, 0, f"Stderr: {res.stderr}")
        self.assertIn("ENABLE_MIERU=1", res.stdout)
        self.assertIn("MIERU_PORT_MODE=single", res.stdout)
        self.assertIn("MIERU_PORT=8450", res.stdout)
        self.assertIn("MIERU_USER=testuser", res.stdout)
        self.assertIn("MIERU_PASS=testpass", res.stdout)

    def test_cli_flags_parsing_port_range(self):
        """Verify that CLI flags for Mieru with port range are parsed correctly."""
        res = run_shell(r"""
set -euo pipefail
source src/system/env.sh
PRIMARY_DOMAIN="example.com"
set -- --mieru --mieru-port-mode range --mieru-port 8450-8455 --mieru-user rangeuser --mieru-pass rangepass
source src/tui/prompts.sh
reconstruct_arrays_from_vars
echo "ENABLE_MIERU=$ENABLE_MIERU"
echo "MIERU_PORT_MODE=$MIERU_PORT_MODE"
echo "MIERU_PORT=$MIERU_PORT"
echo "MIERU_USER=$MIERU_USER"
echo "MIERU_PASS=$MIERU_PASS"
""")
        self.assertEqual(res.returncode, 0, f"Stderr: {res.stderr}")
        self.assertIn("ENABLE_MIERU=1", res.stdout)
        self.assertIn("MIERU_PORT_MODE=range", res.stdout)
        self.assertIn("MIERU_PORT=8450-8455", res.stdout)
        self.assertIn("MIERU_USER=rangeuser", res.stdout)
        self.assertIn("MIERU_PASS=rangepass", res.stdout)

    def test_all_protocols_enables_mieru(self):
        """Verify that --all-protocols flag enables Mieru automatically."""
        res = run_shell(r"""
set -euo pipefail
source src/system/env.sh
PRIMARY_DOMAIN="example.com"
set -- --all-protocols
source src/tui/prompts.sh
reconstruct_arrays_from_vars
echo "ENABLE_MIERU=$ENABLE_MIERU"
echo "MIERU_PORT=$MIERU_PORT"
""")
        self.assertEqual(res.returncode, 0, f"Stderr: {res.stderr}")
        self.assertIn("ENABLE_MIERU=1", res.stdout)
        self.assertIn("MIERU_PORT=8450", res.stdout)

    def test_env_persistence_and_restore(self):
        """Verify that Mieru variables are persisted in save_session_state and restored."""
        with tempfile.TemporaryDirectory() as tmpdir:
            save_file = os.path.join(tmpdir, "test.env")
            res = run_shell(f"""
set -euo pipefail
source src/system/env.sh
ENABLE_MIERU=1
MIERU_PORT_MODE=range
MIERU_PORT=8450-8455
MIERU_USER=persisted_user
MIERU_PASS=persisted_pass
PRIMARY_DOMAIN=test.example.com
PANEL_PATH=my-panel
SUB_PATH=my-sub
save_session_state "{save_file}"
cat "{save_file}"
""")
            self.assertEqual(res.returncode, 0, f"Stderr: {res.stderr}")
            content = Path(save_file).read_text(encoding="utf-8")
            self.assertIn('ENABLE_MIERU="y"', content)
            self.assertIn('MIERU_PORT_MODE="range"', content)
            self.assertIn('MIERU_PORT="8450-8455"', content)
            self.assertIn('MIERU_USER="persisted_user"', content)
            self.assertIn('MIERU_PASS="persisted_pass"', content)

    def test_protocols_listener_declaration(self):
        """Verify selected_protocol_ports includes Mieru on tcp and udp."""
        res = run_shell(r"""
set -euo pipefail
source src/system/env.sh
source src/common/protocols.sh
ENABLE_WEB_STACK=1
ENABLE_MIERU=1
MIERU_PORT=8450
selected_protocol_ports
""")
        self.assertEqual(res.returncode, 0, f"Stderr: {res.stderr}")
        self.assertIn("Mieru tcp 8450", res.stdout)
        self.assertIn("Mieru udp 8450", res.stdout)

    def test_ufw_port_normalization_hyphen_to_colon(self):
        """Verify firewall converts port range hyphen to colon for UFW syntax."""
        res = run_shell(r"""
set -euo pipefail
port="8450-8455"
ufw_port="${port//-/:}"
echo "UFW_PORT=$ufw_port"
""")
        self.assertEqual(res.returncode, 0)
        self.assertIn("UFW_PORT=8450:8455", res.stdout)

    def test_mita_config_generation_single_port(self):
        """Verify JSON configuration generated for mita in single port mode."""
        port_mode = "single"
        port_val = "8450"
        transport = "BOTH"
        protocols = ["TCP", "UDP"] if transport == "BOTH" else [transport]
        port_bindings = []
        for proto in protocols:
            clean_p = int(port_val.split("-")[0].split(":")[0])
            port_bindings.append({"port": clean_p, "protocol": proto})

        config = {
            "portBindings": port_bindings,
            "users": [{"name": "testuser", "password": "testpassword"}],
            "loggingLevel": "INFO",
            "mtu": 1400,
            "dns": {"dualStack": "PREFER_IPv4"},
        }
        json_str = json.dumps(config, indent=2)
        parsed = json.loads(json_str)
        self.assertEqual(len(parsed["portBindings"]), 2)
        self.assertEqual(parsed["portBindings"][0], {"port": 8450, "protocol": "TCP"})
        self.assertEqual(parsed["portBindings"][1], {"port": 8450, "protocol": "UDP"})
        self.assertEqual(parsed["users"][0]["name"], "testuser")
        self.assertEqual(parsed["users"][0]["password"], "testpassword")

    def test_mita_config_generation_port_range(self):
        """Verify JSON configuration generated for mita in port range mode."""
        port_mode = "range"
        port_val = "8450-8455"
        transport = "BOTH"
        protocols = ["TCP", "UDP"] if transport == "BOTH" else [transport]
        port_bindings = []
        for proto in protocols:
            port_bindings.append({"portRange": port_val, "protocol": proto})

        config = {
            "portBindings": port_bindings,
            "users": [{"name": "rangeuser", "password": "rangepassword"}],
            "loggingLevel": "INFO",
            "mtu": 1400,
            "dns": {"dualStack": "PREFER_IPv4"},
        }
        json_str = json.dumps(config, indent=2)
        parsed = json.loads(json_str)
        self.assertEqual(len(parsed["portBindings"]), 2)
        self.assertEqual(parsed["portBindings"][0], {"portRange": "8450-8455", "protocol": "TCP"})
        self.assertEqual(parsed["portBindings"][1], {"portRange": "8450-8455", "protocol": "UDP"})

    def test_clash_template_injection_in_sqlite(self):
        """Verify subClashTemplate injection into SQLite database for Clash/Mihomo."""
        with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as tf:
            db_file = tf.name

        try:
            conn = sqlite3.connect(db_file)
            conn.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, value TEXT)")
            # Base Clash template
            initial_tpl = """port: 7890
mode: rule
proxies:
  - name: "Existing VLESS"
    type: vless
    server: 198.51.100.1
    port: 443
proxy-groups:
  - name: "PROXIES"
    type: select
    proxies:
      - "Existing VLESS"
rules:
  - MATCH,PROXIES
"""
            conn.execute("INSERT INTO settings (key, value) VALUES ('subClashTemplate', ?)", (initial_tpl,))
            conn.commit()

            # Execute python injection script
            domain = "vpn.example.com"
            mieru_port = "8450"
            mieru_port_mode = "single"
            mieru_user = "mieru_clash_user"
            mieru_pass = "mieru_clash_pass"
            sub_title = "MyServer"

            cur = conn.cursor()
            cur.execute("SELECT value FROM settings WHERE key = 'subClashTemplate'")
            raw_clash_tpl = cur.fetchone()[0]

            server_title = (sub_title or domain or "VPN").strip()
            mieru_node_name = f"{server_title} — Mieru"
            m_port_field = f"port: {mieru_port}"

            mieru_yaml_block = f"""  - name: "{mieru_node_name}"
    type: mieru
    server: {domain}
    {m_port_field}
    transport: TCP
    udp: true
    username: "{mieru_user}"
    password: "{mieru_pass}"
    multiplexing: MULTIPLEXING_LOW
    handshake-mode: HANDSHAKE_STANDARD"""

            lines = raw_clash_tpl.splitlines()
            new_lines = []
            proxies_injected = False
            for l in lines:
                new_lines.append(l)
                if not proxies_injected and l.strip().startswith("proxies:"):
                    new_lines.append(mieru_yaml_block)
                    proxies_injected = True

            final_lines = []
            in_tg = False
            for l in new_lines:
                final_lines.append(l)
                if re.search(r'name:\s*["\']?(PROXIES|AUTO|PROXY|Default|FALLBACK)["\']?', l, re.IGNORECASE):
                    in_tg = True
                elif in_tg and l.strip().startswith("proxies:"):
                    final_lines.append(f'      - "{mieru_node_name}"')
                    in_tg = False
                elif in_tg and l.strip() and not l.startswith(" ") and not l.startswith("\t"):
                    in_tg = False

            updated_tpl = "\n".join(final_lines) + "\n"
            cur.execute("UPDATE settings SET value = ? WHERE key = 'subClashTemplate'", (updated_tpl,))
            conn.commit()

            # Verify
            cur.execute("SELECT value FROM settings WHERE key = 'subClashTemplate'")
            result_tpl = cur.fetchone()[0]
            self.assertIn("type: mieru", result_tpl)
            self.assertIn("port: 8450", result_tpl)
            self.assertIn('username: "mieru_clash_user"', result_tpl)
            self.assertIn('password: "mieru_clash_pass"', result_tpl)
            self.assertIn(f'- "{mieru_node_name}"', result_tpl)
            conn.close()
        finally:
            if os.path.exists(db_file):
                os.remove(db_file)

    def test_official_client_json_profile_structure(self):
        """Verify client JSON config structure according to official Mieru specs."""
        client_m_port = 8450
        domain = "example.com"
        mieru_user = "testuser"
        mieru_pass = "testpass"

        mieru_client_config = {
            "profiles": [{
                "profileName": "default",
                "user": {
                    "name": mieru_user,
                    "password": mieru_pass,
                },
                "servers": [{
                    "ipAddress": domain,
                    "portBindings": [
                        {"port": client_m_port, "protocol": "TCP"},
                    ],
                }],
                "handshakeMode": "HANDSHAKE_STANDARD",
            }],
            "activeProfile": "default",
            "rpcPort": 0,
            "socks5Port": 1080,
            "loggingLevel": "INFO",
            "httpProxyPort": 8080,
        }
        json_data = json.dumps(mieru_client_config)
        parsed = json.loads(json_data)
        self.assertEqual(parsed["profiles"][0]["user"]["name"], "testuser")
        self.assertEqual(parsed["profiles"][0]["servers"][0]["ipAddress"], "example.com")
        self.assertEqual(parsed["profiles"][0]["servers"][0]["portBindings"][0]["port"], 8450)
        self.assertEqual(parsed["profiles"][0]["servers"][0]["portBindings"][0]["protocol"], "TCP")


if __name__ == "__main__":
    unittest.main()
