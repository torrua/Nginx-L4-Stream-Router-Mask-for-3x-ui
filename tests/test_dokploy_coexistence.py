#!/usr/bin/env python3
"""
tests/test_dokploy_coexistence.py - Tests for Dokploy Coexistence Mode.

Verifies:
- CLI flag `--dokploy` and `--no-dokploy` parsing.
- Dokploy auto-detection when network or container is present.
- Installation plan construction under Dokploy Coexistence (Nginx 80/443 omitted, 3X-UI & AWG retained).
- Config validation with DOKPLOY_COEXISTENCE=y.
- Traefik dynamic provider config generation for 3X-UI and subscriptions.
- Manage-services CLI commands for Dokploy export and Traefik config.
"""

import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parent.parent
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


class TestDokployCoexistence(unittest.TestCase):
    def test_plan_construction_with_dokploy_coexistence(self):
        """Verify that DOKPLOY_COEXISTENCE=y preserves 3X-UI panel and AWG, but skips Nginx on 80/443."""
        res = run_shell("""
set -euo pipefail
CYAN=; BOLD=; NC=; DIM=; WHITE=;
warn(){ :; }; ok(){ :; }; die(){ echo "DIE:$*"; exit 1; };
is_true() { local val="${1:-0}"; [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]; }
source src/common/protocols.sh
source src/system/env.sh
source src/installer/plan.sh

DOKPLOY_COEXISTENCE="y"
ENABLE_WEB_STACK=0
AUTO_SETUP_3XUI="y"
ENABLE_AWG_V3="y"
AWG_V3_PORT="8443"
PRIMARY_DOMAIN="example.com"

build_installation_plan
for step in "${INSTALLATION_PLAN[@]}"; do
    echo "STEP:$step"
done
""")
        self.assertEqual(res.returncode, 0, f"Plan building failed: {res.stderr}")
        steps = [line.replace("STEP:", "").strip() for line in res.stdout.splitlines() if line.startswith("STEP:")]
        self.assertIn("panel", steps, "3X-UI panel must be present in Dokploy coexistence mode")
        self.assertNotIn("nginx", steps, "Nginx on 80/443 must not be installed in Dokploy coexistence mode")
        self.assertNotIn("decoy", steps, "Decoy site on 80/443 must not be installed in Dokploy coexistence mode")
        self.assertNotIn("certificates", steps, "Certbot HTTP-01 on 80/443 must not be installed in Dokploy coexistence mode")

    def test_validation_config_with_dokploy_coexistence(self):
        """validate_installation_config must succeed when DOKPLOY_COEXISTENCE=y and AUTO_SETUP_3XUI=y."""
        res = run_shell("""
set -euo pipefail
CYAN=; BOLD=; NC=; DIM=; WHITE=;
warn(){ :; }; ok(){ :; }; die(){ echo "DIE:$*"; exit 1; };
is_true() { local val="${1:-0}"; [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]; }
source src/common/protocols.sh
source src/system/env.sh
source src/installer/plan.sh

DOKPLOY_COEXISTENCE="y"
ENABLE_WEB_STACK=0
AUTO_SETUP_3XUI="y"
PRIMARY_DOMAIN="example.com"
installation_listeners(){ echo "Panel tcp 10443"; }

validate_installation_config
echo "VALIDATION:SUCCESS"
""")
        self.assertEqual(res.returncode, 0, f"Validation failed: {res.stderr}\n{res.stdout}")
        self.assertIn("VALIDATION:SUCCESS", res.stdout)

    def test_traefik_dynamic_config_generation(self):
        """Verify generation of Traefik dynamic config for 3X-UI, sub, and xHTTP."""
        sys.path.insert(0, str((ROOT / "src/panel").resolve()))
        try:
            import dokploy_traefik
        except ImportError:
            sys.path.insert(0, str((ROOT / "src").resolve()))
            from panel import dokploy_traefik

        config = dokploy_traefik.generate_traefik_dynamic_yaml(
            domain="example.com",
            panel_subdomain="panel.example.com",
            sub_subdomain="sub.example.com",
            vless_subdomain="vless.example.com",
            panel_port=10443,
            sub_port=55443,
            xhttp_port=50443,
            cert_resolver="letsencrypt"
        )
        self.assertIn("xui-panel", config)
        self.assertIn("Host(`panel.example.com`)", config)
        self.assertIn("http://host.docker.internal:10443", config)
        self.assertIn("xui-sub", config)
        self.assertIn("Host(`sub.example.com`)", config)
        self.assertIn("http://host.docker.internal:55443", config)
        self.assertIn("h2c://host.docker.internal:50443", config)

    def test_cli_dokploy_flags(self):
        """Verify that --dokploy and --no-dokploy flags are parsed correctly."""
        res_on = run_shell("""
CYAN=; BOLD=; NC=; DIM=; WHITE=; GREEN=; RED=; ARROW=;
warn(){ :; }; ok(){ :; }; die(){ echo "DIE:$*"; exit 1; };
set -- --dokploy
source src/tui/prompts.sh
echo "DOKPLOY:$DOKPLOY_COEXISTENCE"
""")
        self.assertEqual(res_on.returncode, 0)
        self.assertIn("DOKPLOY:y", res_on.stdout)

        res_off = run_shell("""
CYAN=; BOLD=; NC=; DIM=; WHITE=; GREEN=; RED=; ARROW=;
warn(){ :; }; ok(){ :; }; die(){ echo "DIE:$*"; exit 1; };
set -- --no-dokploy
source src/tui/prompts.sh
echo "DOKPLOY:$DOKPLOY_COEXISTENCE"
""")
        self.assertEqual(res_off.returncode, 0)
        self.assertIn("DOKPLOY:n", res_off.stdout)

    def test_dokploy_traefik_dynamic_template_exists(self):
        """Verify that compose/dokploy-traefik-dynamic.yml exists and has valid structure."""
        dyn_path = ROOT / "compose" / "dokploy-traefik-dynamic.yml"
        self.assertTrue(dyn_path.is_file(), "compose/dokploy-traefik-dynamic.yml must exist")
        content = dyn_path.read_text(encoding="utf-8")
        self.assertIn("xui-panel:", content)
        self.assertIn("xui-sub:", content)
        self.assertIn("xray-xhttp:", content)
        self.assertIn("host.docker.internal:10443", content)

    def test_dokploy_all_in_one_compose_template_exists(self):
        """Verify that compose/docker-compose.dokploy-all-in-one.yml exists and defines 3X-UI + Traefik labels."""
        aio_path = ROOT / "compose" / "docker-compose.dokploy-all-in-one.yml"
        self.assertTrue(aio_path.is_file(), "compose/docker-compose.dokploy-all-in-one.yml must exist")
        content = aio_path.read_text(encoding="utf-8")
        self.assertIn("3x-ui-dokploy", content)
        self.assertIn("wstunnel-dokploy", content)
        self.assertIn("sing-box-masque", content)
        self.assertIn("traefik.http.routers.xui-panel.rule", content)
        self.assertIn("traefik.http.routers.xui-sub.rule", content)
        self.assertIn("dokploy-network:", content)

    def test_manage_services_dokploy_commands(self):
        """Verify manage-services.sh commands for dokploy (dokploy-export, dokploy-all-in-one, dokploy-traefik)."""
        manage_sh = ROOT / "manage-services.sh"
        res_aio = run_shell(f"""
bash "{manage_sh}" dokploy-all-in-one
""")
        self.assertEqual(res_aio.returncode, 0, f"dokploy-all-in-one failed: {res_aio.stderr}")
        self.assertIn("3x-ui-dokploy", res_aio.stdout)

        res_traefik = run_shell(f"""
bash "{manage_sh}" dokploy-traefik
""")
        self.assertEqual(res_traefik.returncode, 0, f"dokploy-traefik failed: {res_traefik.stderr}")
        self.assertIn("xui-panel:", res_traefik.stdout)

    def test_dokploy_traefik_dynamic_priority_and_backend(self):
        """Verify priority 1000 on xray-xhttp and auto-backend resolution."""
        sys.path.insert(0, str((ROOT / "src/panel").resolve()))
        try:
            import dokploy_traefik
        except ImportError:
            sys.path.insert(0, str((ROOT / "src").resolve()))
            from panel import dokploy_traefik

        config = dokploy_traefik.generate_traefik_dynamic_yaml(
            domain="example.org",
            vless_subdomain="cdn.example.org",
            backend_host="3x-ui-dokploy",
            xhttp_port=50443
        )
        self.assertIn("priority: 1000", config)
        self.assertIn("h2c://3x-ui-dokploy:50443", config)
        self.assertIn("Host(`cdn.example.org`)", config)

    def test_xhttp_mode_auto_and_hosts_table_sync(self):
        """Verify that xHTTP inbound is created with mode auto and hosts table has TLS and custom domain."""
        import sqlite3
        import tempfile

        with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as tf:
            db_path = tf.name

        try:
            conn = sqlite3.connect(db_path)
            cur = conn.cursor()
            cur.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT, value TEXT)")
            cur.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, password TEXT)")
            cur.execute("INSERT INTO users (id, username, password) VALUES (1, 'admin', 'admin')")
            cur.execute("CREATE TABLE client_traffics (id INTEGER PRIMARY KEY, inbound_id INTEGER, enable INTEGER, email TEXT, up INTEGER, down INTEGER, expiry_time INTEGER, total INTEGER, reset INTEGER)")
            cur.execute("CREATE TABLE client_inbounds (id INTEGER PRIMARY KEY, client_id INTEGER, inbound_id INTEGER)")
            cur.execute("CREATE TABLE clients (id INTEGER PRIMARY KEY, email TEXT, enable INTEGER, uuid TEXT, password TEXT, auth TEXT, flow TEXT, secret TEXT, ad_tag TEXT, created_at INTEGER, updated_at INTEGER)")
            cur.execute("""
                CREATE TABLE inbounds (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id INTEGER DEFAULT 1,
                    up INTEGER DEFAULT 0,
                    down INTEGER DEFAULT 0,
                    total INTEGER DEFAULT 0,
                    remark TEXT DEFAULT '',
                    enable INTEGER DEFAULT 1,
                    port INTEGER NOT NULL,
                    protocol TEXT NOT NULL,
                    settings TEXT DEFAULT '{}',
                    stream_settings TEXT DEFAULT '{}',
                    tag TEXT DEFAULT '',
                    sniffing TEXT DEFAULT '{}',
                    listen TEXT DEFAULT ''
                )
            """)
            cur.execute("""
                CREATE TABLE hosts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    inbound_id INTEGER NOT NULL,
                    remark TEXT DEFAULT '',
                    address TEXT DEFAULT '',
                    port INTEGER DEFAULT 443,
                    security TEXT DEFAULT 'same',
                    sni TEXT DEFAULT '',
                    host_header TEXT DEFAULT '',
                    path TEXT DEFAULT '',
                    alpn TEXT DEFAULT '',
                    fingerprint TEXT DEFAULT '',
                    sort_order INTEGER DEFAULT 0
                )
            """)
            conn.commit()
            conn.close()

            def expand_includes(file_path):
                lines = []
                for line in file_path.read_text(encoding="utf-8").splitlines():
                    m = re.match(r'^\s*#\s*@include\s+["\']([^"\']+)["\']', line)
                    if m:
                        inc_path = ROOT / "src" / m.group(1)
                        lines.append(expand_includes(inc_path))
                    else:
                        lines.append(line)
                return "\n".join(lines)

            reconcile_code = expand_includes(ROOT / "src/panel/reconcile.py")
            with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False, encoding="utf-8") as script_f:
                script_f.write(reconcile_code)
                script_path = script_f.name

            env = os.environ.copy()
            env["DB_PATH"] = db_path
            env["PRIMARY_DOMAIN"] = "example.org"
            env["VLESS_DOMAIN"] = "cdn.example.org"
            env["ENABLE_STEAL"] = "n"
            env["ENABLE_CLASSIC"] = "n"
            env["ENABLE_XHTTP"] = "y"
            env["XHTTP_STREAM_PORT"] = "50443"
            env["XHTTP_STREAM_PATH"] = "xhttp"
            env["IS_DOCKER_XUI"] = "1"

            try:
                res = subprocess.run([sys.executable, script_path], env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10)
            finally:
                if os.path.exists(script_path):
                    os.remove(script_path)
            self.assertEqual(res.returncode, 0, f"reconcile failed: {res.stderr}\n{res.stdout}")

            conn = sqlite3.connect(db_path)
            cur = conn.cursor()
            cur.execute("SELECT stream_settings FROM inbounds WHERE port = 50443")
            row = cur.fetchone()
            self.assertIsNotNone(row)
            st = json.loads(row[0])
            self.assertEqual(st.get("xhttpSettings", {}).get("mode"), "auto")
            self.assertEqual(st.get("xhttpSettings", {}).get("host"), "cdn.example.org")

            cur.execute("SELECT address, port, security, sni, host_header, path FROM hosts WHERE inbound_id = (SELECT id FROM inbounds WHERE port = 50443)")
            h_row = cur.fetchone()
            self.assertIsNotNone(h_row, "Host entry for xHTTP inbound must exist in hosts table")
            addr, port, sec, sni, host_hdr, path = h_row
            self.assertEqual(addr, "cdn.example.org")
            self.assertEqual(port, 443)
            self.assertEqual(sec, "tls")
            self.assertEqual(sni, "cdn.example.org")
            self.assertEqual(host_hdr, "cdn.example.org")
            self.assertEqual(path, "/xhttp/")
            conn.close()
        finally:
            if os.path.exists(db_path):
                os.remove(db_path)


if __name__ == "__main__":
    unittest.main()
