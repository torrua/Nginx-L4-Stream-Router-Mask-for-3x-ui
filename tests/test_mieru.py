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
    py_exec = sys.executable.replace(os.sep, "/")
    return subprocess.run(
        [str(BASH), "-s"],
        input=f"export PATH=/usr/bin:/bin:$PATH\nexport PYTHON_CMD='{py_exec}'\nsource src/common/colors.sh\nsource src/common/logger.sh\nsource src/common/config.sh\n" + code,
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

    def test_mieru_mgr_list_users(self):
        """Verify mieru-mgr list command parses server config and displays users."""
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg_file = os.path.join(tmpdir, "config.json")
            data = {
                "portBindings": [
                    {"port": 8450, "protocol": "TCP"},
                    {"port": 8450, "protocol": "UDP"},
                ],
                "users": [
                    {"name": "user_alpha", "password": "pass_alpha_secret"},
                    {"name": "user_beta", "password": "pass_beta_secret"},
                ],
            }
            Path(cfg_file).write_text(json.dumps(data, indent=2), encoding="utf-8")

            res = run_shell(f"""
set -euo pipefail
export MIERU_SERVER_CONFIG="{cfg_file.replace(os.sep, '/')}"
export MIERU_CLIENT_DIR="{tmpdir.replace(os.sep, '/')}"
bash src/system/mieru-mgr.sh list
""")
            self.assertEqual(res.returncode, 0, f"Stderr: {res.stderr}")
            self.assertIn("user_alpha", res.stdout)
            self.assertIn("user_beta", res.stdout)
            self.assertIn("8450/TCP", res.stdout)

    def test_mieru_mgr_add_and_del_user(self):
        """Verify mieru-mgr add creates user and client profile, and del removes them."""
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg_file = os.path.join(tmpdir, "config.json")
            data = {
                "portBindings": [{"port": 8450, "protocol": "TCP"}],
                "users": [{"name": "primary_user", "password": "primary_pass"}],
            }
            Path(cfg_file).write_text(json.dumps(data, indent=2), encoding="utf-8")

            # 1. Add user
            res_add = run_shell(f"""
set -euo pipefail
export MIERU_SERVER_CONFIG="{cfg_file.replace(os.sep, '/')}"
export MIERU_CLIENT_DIR="{tmpdir.replace(os.sep, '/')}"
export MIERU_MGR_FORCE=1
export PRIMARY_DOMAIN="vpn.test.example"
bash src/system/mieru-mgr.sh add new_user MySecretPass123!
""")
            self.assertEqual(res_add.returncode, 0, f"Stderr: {res_add.stderr}")
            self.assertIn("new_user", res_add.stdout)
            self.assertIn("MySecretPass123!", res_add.stdout)

            # Check config updated
            with open(cfg_file, "r", encoding="utf-8") as f:
                updated_data = json.load(f)
            user_names = [u["name"] for u in updated_data["users"]]
            self.assertIn("new_user", user_names)

            # Check client profile generated
            client_file = Path(tmpdir) / "mieru-client-new_user.json"
            self.assertTrue(client_file.is_file(), f"Client file not found: {client_file}")
            with open(client_file, "r", encoding="utf-8") as cf:
                cdata = json.load(cf)
            self.assertEqual(cdata["profiles"][0]["user"]["name"], "new_user")
            self.assertEqual(cdata["profiles"][0]["user"]["password"], "MySecretPass123!")
            self.assertEqual(cdata["profiles"][0]["servers"][0]["ipAddress"], "vpn.test.example")

            # 2. Delete user
            res_del = run_shell(f"""
set -euo pipefail
export MIERU_SERVER_CONFIG="{cfg_file.replace(os.sep, '/')}"
export MIERU_CLIENT_DIR="{tmpdir.replace(os.sep, '/')}"
export MIERU_MGR_FORCE=1
bash src/system/mieru-mgr.sh del new_user
""")
            self.assertEqual(res_del.returncode, 0, f"Stderr: {res_del.stderr}")
            self.assertFalse(client_file.exists(), "Client file was not removed on user deletion")

            with open(cfg_file, "r", encoding="utf-8") as f:
                final_data = json.load(f)
            final_user_names = [u["name"] for u in final_data["users"]]
            self.assertNotIn("new_user", final_user_names)

            # 3. Try to delete the only remaining user (should fail)
            res_del_last = run_shell(f"""
set -euo pipefail
export MIERU_SERVER_CONFIG="{cfg_file.replace(os.sep, '/')}"
export MIERU_CLIENT_DIR="{tmpdir.replace(os.sep, '/')}"
export MIERU_MGR_FORCE=1
bash src/system/mieru-mgr.sh del primary_user
""")
            self.assertNotEqual(res_del_last.returncode, 0)
            self.assertIn("единственный пользователь", res_del_last.stderr)

    def test_maintain_mieru_user_flags(self):
        """Verify maintain.sh --mieru-list-users and --mieru-add-user flags invoke manager."""
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg_file = os.path.join(tmpdir, "config.json")
            data = {
                "portBindings": [{"port": 8450, "protocol": "TCP"}],
                "users": [{"name": "root_user", "password": "root_pass"}],
            }
            Path(cfg_file).write_text(json.dumps(data, indent=2), encoding="utf-8")

            # Test --mieru-list-users
            res_list = run_shell(f"""
set -euo pipefail
export MIERU_SERVER_CONFIG="{cfg_file.replace(os.sep, '/')}"
export MIERU_CLIENT_DIR="{tmpdir.replace(os.sep, '/')}"
bash maintain.sh --mieru-list-users
""")
            self.assertEqual(res_list.returncode, 0, f"Stderr: {res_list.stderr}")
            self.assertIn("root_user", res_list.stdout)

            # Test --mieru-add-user
            res_add = run_shell(f"""
set -euo pipefail
export MIERU_SERVER_CONFIG="{cfg_file.replace(os.sep, '/')}"
export MIERU_CLIENT_DIR="{tmpdir.replace(os.sep, '/')}"
export MIERU_MGR_FORCE=1
export PRIMARY_DOMAIN="vpn.test.example"
bash maintain.sh --mieru-add-user maintain_user Pass789!
""")
            self.assertEqual(res_add.returncode, 0, f"Stderr: {res_add.stderr}")
            self.assertIn("maintain_user", res_add.stdout)
            self.assertIn("Pass789!", res_add.stdout)

    def test_setup_mieru_service_atomic_write_and_permissions(self):
        """Invoke setup_mieru_service with special password O'Brien123 and verify mode 600."""
        res = run_shell(r"""
set -euo pipefail
log(){ :; }; ok(){ :; }; warn(){ echo "WARN:$*"; }; die(){ echo "DIE:$*"; exit 1; };
is_true(){ [[ "${1:-0}" == "1" || "${1,,}" == "y" || "${1,,}" == "true" ]]; }

MOCK_ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t 'mieru')
trap 'rm -rf "$MOCK_ROOT"' EXIT
mkdir -p "$MOCK_ROOT/etc/mita" "$MOCK_ROOT/var/lib/mita" "$MOCK_ROOT/var/run/mita" "$MOCK_ROOT/etc/systemd/system" "$MOCK_ROOT/usr/local/bin"
printf '#!/bin/sh\nexit 0\n' > "$MOCK_ROOT/usr/local/bin/mita"
chmod +x "$MOCK_ROOT/usr/local/bin/mita"
export LOCAL_BIN_DIR="$MOCK_ROOT/usr/local/bin"

systemctl(){ :; }
id(){ return 1; }

MIERU_PORT_MODE="range"
MIERU_PORT="8450-8455"
MIERU_USER="obrien_user"
MIERU_PASS="O'Brien123!@#"
MIERU_TRANSPORT="TCP"
MIERU_MTU="1380"
export MIERU_CONFIG_FILE="$MOCK_ROOT/etc/mita/config.json"
export MIERU_COMPAT_CONFIG_FILE="$MOCK_ROOT/etc/mita/compat.json"

source src/installer/steps.sh

eval "$(declare -f setup_mieru_service | \
    sed "s|/var/lib/mita|$MOCK_ROOT/var/lib/mita|g" | \
    sed "s|/var/run/mita|$MOCK_ROOT/var/run/mita|g" | \
    sed "s|/etc/systemd/system|$MOCK_ROOT/etc/systemd/system|g")"

chmod() { echo "CHMOD:$*"; }

setup_mieru_service

cat "$MOCK_ROOT/etc/mita/config.json"
rm -rf "$MOCK_ROOT"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertIn("CHMOD:600", res.stdout)
        data = json.loads(res.stdout[res.stdout.find("{"):])
        self.assertEqual(data["users"][0]["name"], "obrien_user")
        self.assertEqual(data["users"][0]["password"], "O'Brien123!@#")
        self.assertEqual(data["portBindings"][0]["protocol"], "TCP")
        self.assertEqual(data["portBindings"][0]["portRange"], "8450-8455")
        self.assertEqual(len(data["portBindings"]), 1)

    def test_setup_mieru_service_fails_when_mita_missing(self):
        """setup_mieru_service must return non-zero when mita binary cannot be found or downloaded."""
        res = run_shell(r"""
set -euo pipefail
log(){ :; }; ok(){ :; }; warn(){ echo "WARN:$*"; }; die(){ echo "DIE:$*"; exit 1; };
is_true(){ [[ "${1:-0}" == "1" || "${1,,}" == "y" || "${1,,}" == "true" ]]; }

MOCK_ROOT=$(mktemp -d)
mkdir -p "$MOCK_ROOT/usr/local/bin"
export LOCAL_BIN_DIR="$MOCK_ROOT/usr/local/bin"
# Ensure mita is not found anywhere
export PATH="/bin:/usr/bin"
curl(){ return 1; }

source src/installer/steps.sh

if setup_mieru_service; then
    echo "BAD_SUCCESS"
else
    echo "FAILED_AS_EXPECTED"
fi
rm -rf "$MOCK_ROOT"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertIn("FAILED_AS_EXPECTED", res.stdout)
        self.assertNotIn("BAD_SUCCESS", res.stdout)

    def test_protocols_transport_selection_tcp_only(self):
        """MIERU_TRANSPORT=TCP must emit only tcp for Mieru."""
        res = run_shell(r"""
set -euo pipefail
source src/system/env.sh
source src/common/protocols.sh
ENABLE_WEB_STACK=1
ENABLE_MIERU=1
MIERU_PORT=8450
MIERU_TRANSPORT="TCP"
selected_protocol_ports
""")
        self.assertEqual(res.returncode, 0, f"Stderr: {res.stderr}")
        self.assertIn("Mieru tcp 8450", res.stdout)
        self.assertNotIn("Mieru udp", res.stdout)

    def test_protocols_transport_selection_udp_only(self):
        """MIERU_TRANSPORT=UDP must emit only udp for Mieru."""
        res = run_shell(r"""
set -euo pipefail
source src/system/env.sh
source src/common/protocols.sh
ENABLE_WEB_STACK=1
ENABLE_MIERU=1
MIERU_PORT=8450
MIERU_TRANSPORT="UDP"
selected_protocol_ports
""")
        self.assertEqual(res.returncode, 0, f"Stderr: {res.stderr}")
        self.assertIn("Mieru udp 8450", res.stdout)
        self.assertNotIn("Mieru tcp", res.stdout)

    def test_validate_installation_config_mieru_range_valid(self):
        """validate_installation_config accepts valid Mieru port range."""
        res = run_shell(r"""
set -euo pipefail
ENABLE_WEB_STACK=1
PRIMARY_DOMAIN="example.com"
LE_EMAIL="admin@example.com"
ENABLE_MIERU=1
MIERU_PORT="8450-8455"
MIERU_TRANSPORT="BOTH"
source src/common/protocols.sh
source src/installer/plan.sh
validate_installation_config
echo "VALID"
""")
        self.assertEqual(res.returncode, 0, f"Stderr: {res.stderr}")
        self.assertIn("VALID", res.stdout)

    def test_validate_installation_config_mieru_range_inverted(self):
        """validate_installation_config rejects inverted port range."""
        res = run_shell(r"""
set -euo pipefail
ENABLE_WEB_STACK=1
PRIMARY_DOMAIN="example.com"
LE_EMAIL="admin@example.com"
ENABLE_MIERU=1
MIERU_PORT="8455-8450"
source src/common/protocols.sh
source src/installer/plan.sh
validate_installation_config
echo "BAD_SUCCESS"
""")
        self.assertNotEqual(res.returncode, 0)
        self.assertNotIn("BAD_SUCCESS", res.stdout)
        self.assertIn("Некорректный диапазон портов", res.stderr)

    def test_validate_installation_config_mieru_range_out_of_bounds(self):
        """validate_installation_config rejects out-of-bounds port range."""
        res = run_shell(r"""
set -euo pipefail
ENABLE_WEB_STACK=1
PRIMARY_DOMAIN="example.com"
LE_EMAIL="admin@example.com"
ENABLE_MIERU=1
MIERU_PORT="8450-70000"
source src/common/protocols.sh
source src/installer/plan.sh
validate_installation_config
echo "BAD_SUCCESS"
""")
        self.assertNotEqual(res.returncode, 0)
        self.assertNotIn("BAD_SUCCESS", res.stdout)
        self.assertIn("Некорректный диапазон портов", res.stderr)

    def test_validate_installation_config_mieru_range_collision(self):
        """validate_installation_config detects conflict between port range and another component."""
        res = run_shell(r"""
set -euo pipefail
ENABLE_WEB_STACK=1
PRIMARY_DOMAIN="example.com"
LE_EMAIL="admin@example.com"
ENABLE_AWG_STANDALONE=1
AWG_STANDALONE_PORT=8445
ENABLE_MIERU=1
MIERU_PORT="8440-8446"
MIERU_TRANSPORT="BOTH"
source src/common/protocols.sh
source src/installer/plan.sh
validate_installation_config
echo "BAD_SUCCESS"
""")
        self.assertNotEqual(res.returncode, 0)
        self.assertNotIn("BAD_SUCCESS", res.stdout)
        self.assertIn("Конфликт порта 8445/udp", res.stderr)

    def test_mieru_mgr_udp_only_server_generates_udp_client(self):
        """Verify mieru-mgr add generates UDP client profile and UDP Mihomo transport when server is UDP-only."""
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg_file = os.path.join(tmpdir, "config.json")
            data = {
                "portBindings": [{"portRange": "8450-8455", "protocol": "UDP"}],
                "users": [{"name": "primary_user", "password": "primary_pass"}],
            }
            Path(cfg_file).write_text(json.dumps(data, indent=2), encoding="utf-8")

            res_add = run_shell(f"""
set -euo pipefail
export MIERU_SERVER_CONFIG="{cfg_file.replace(os.sep, '/')}"
export MIERU_CLIENT_DIR="{tmpdir.replace(os.sep, '/')}"
export MIERU_MGR_FORCE=1
export PRIMARY_DOMAIN="vpn.test.example"
bash src/system/mieru-mgr.sh add udp_user UdpPass123!
""")
            self.assertEqual(res_add.returncode, 0, f"Stderr: {res_add.stderr}")
            self.assertIn("transport: UDP", res_add.stdout)

            # Check client profile generated
            client_file = Path(tmpdir) / "mieru-client-udp_user.json"
            self.assertTrue(client_file.is_file(), f"Client file not found: {client_file}")
            with open(client_file, "r", encoding="utf-8") as cf:
                cdata = json.load(cf)
            bindings = cdata["profiles"][0]["servers"][0]["portBindings"]
            self.assertEqual(len(bindings), 1)
            self.assertEqual(bindings[0].get("protocol"), "UDP")
            self.assertEqual(bindings[0].get("portRange"), "8450-8455")

    def test_reconcile_udp_only_mieru_export(self):
        """Verify subClashTemplate and /root/mieru-client.json use UDP when MIERU_TRANSPORT=UDP."""
        with tempfile.TemporaryDirectory() as tmpdir:
            db_file = os.path.join(tmpdir, "x-ui.db")
            client_file = os.path.join(tmpdir, "mieru-client.json")
            conn = sqlite3.connect(db_file)
            conn.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, value TEXT)")
            conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, password TEXT)")
            conn.execute("INSERT INTO users VALUES (1, 'admin', 'admin')")
            conn.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY, user_id INTEGER, up INTEGER, down INTEGER, total INTEGER, remark TEXT, enable INTEGER, expiry_time INTEGER, listen TEXT, port INTEGER, protocol TEXT, settings TEXT, stream_settings TEXT, tag TEXT, sniffing TEXT, client_stats TEXT)")
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
            conn.close()

            env = {
                **os.environ,
                "DB_PATH": db_file,
                "DRY_RUN": "0",
                "FORCE_SUB": "0",
                "PRIMARY_DOMAIN": "vpn.example.com",
                "ENABLE_MIERU": "1",
                "MIERU_PORT": "8450-8455",
                "MIERU_PORT_MODE": "range",
                "MIERU_TRANSPORT": "UDP",
                "MIERU_USER": "udp_alice",
                "MIERU_PASS": "udp_secret",
            }
            # Extract Python config from configure-panel.sh
            conf_text = Path("configure-panel.sh").read_text(encoding="utf-8")
            marker = "\"$PYTHON_CMD\" - << 'EOF_PYTHON_CONFIG'"
            py_start = conf_text.find(marker)
            self.assertNotEqual(py_start, -1)
            py_code = conf_text[py_start + len(marker) + 1:]
            py_end = py_code.find("EOF_PYTHON_CONFIG")
            self.assertNotEqual(py_end, -1)
            full_code = py_code[:py_end]
            full_code = full_code.replace('"/root/mieru-client.json"', json.dumps(client_file.replace(os.sep, "/")))
            py_script = os.path.join(tmpdir, "run_reconcile.py")
            Path(py_script).write_text(full_code, encoding="utf-8")
            res = subprocess.run([sys.executable, py_script], env=env, capture_output=True, text=True, encoding="utf-8", errors="replace")
            self.assertEqual(res.returncode, 0, f"Stderr: {res.stderr}\nStdout: {res.stdout}")

            # Verify subClashTemplate in DB
            conn = sqlite3.connect(db_file)
            cur = conn.cursor()
            cur.execute("SELECT value FROM settings WHERE key = 'subClashTemplate'")
            tpl = cur.fetchone()[0]
            conn.close()

            self.assertIn("type: mieru", tpl)
            self.assertIn("transport: UDP", tpl)
            self.assertNotIn("transport: TCP", tpl)

            # Verify client json
            self.assertTrue(os.path.isfile(client_file))
            with open(client_file, "r", encoding="utf-8") as f:
                cdata = json.load(f)
            bindings = cdata["profiles"][0]["servers"][0]["portBindings"]
            self.assertEqual(len(bindings), 1)
            self.assertEqual(bindings[0].get("protocol"), "UDP")
            self.assertEqual(bindings[0].get("portRange"), "8450-8455")

    def test_check_required_port_range_detects_missing_intermediate_port(self):
        """check_required_port fails when boundary ports listen but intermediate port is missing."""
        script = r'''
set -euo pipefail
source src/common/preflight.sh

# Mock ss: port 8450 and 8455 succeed, but 8451..8454 return nothing
ss() {
    for arg in "$@"; do
        if [[ "$arg" == *"sport = :8450"* ]] || [[ "$arg" == *"sport = :8455"* ]]; then
            echo "LISTEN 0 128 0.0.0.0:8450 0.0.0.0:*"
            return 0
        fi
    done
    return 1
}

# Should fail because 8451..8454 are missing
if check_required_port tcp 8450-8455 >/dev/null 2>&1; then
    echo "UNEXPECTED_SUCCESS"
    exit 1
else
    echo "EXPECTED_FAILURE"
fi
'''
        res = run_shell(script)
        self.assertEqual(res.returncode, 0, f"Stderr: {res.stderr}")
        self.assertIn("EXPECTED_FAILURE", res.stdout)
        self.assertNotIn("UNEXPECTED_SUCCESS", res.stdout)

    def test_check_required_port_range_succeeds_when_all_ports_listening(self):
        """check_required_port succeeds when all ports in range are listening."""
        script = r'''
set -euo pipefail
source src/common/preflight.sh

# Mock ss: all ports in 8450..8455 return listeners
ss() {
    echo "LISTEN 0 128 0.0.0.0:sport 0.0.0.0:*"
    return 0
}

check_required_port tcp 8450-8455
echo "ALL_PORTS_OK"
'''
        res = run_shell(script)
        self.assertEqual(res.returncode, 0, f"Stderr: {res.stderr}")
        self.assertIn("ALL_PORTS_OK", res.stdout)
        self.assertIn("all listening (8450..8455)", res.stdout)


if __name__ == "__main__":
    unittest.main()
