"""
tests/test_nextgen_dokploy.py - Tests for Next-Gen protocols and Dokploy coexistence.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
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


class TestDokployPreflight(unittest.TestCase):
    def test_dokploy_coexistence_allows_occupied_443(self):
        """Preflight must NOT abort when port 443 is occupied if DOKPLOY_COEXISTENCE=y."""
        res = run_shell("""
set -euo pipefail
CHECK_MODE=0; NON_INTERACTIVE=0; DEBUG_MODE=0
CYAN=; BOLD=; NC=; DIM=; WHITE=;
warn(){ :; }; ok(){ echo "OK:$*"; }; die(){ echo "FATAL_ABORT:$*"; exit 15; };
source src/common/preflight.sh
ENABLE_AGH=0
ENABLE_WEB_STACK=y
DOKPLOY_COEXISTENCE=y

is_port_in_use(){ [[ "$2" == 443 ]]; }
get_port_listener_info(){ echo "docker-proxy"; }

inspect_port_conflicts
""")
        self.assertEqual(res.returncode, 0, f"Preflight must succeed with Dokploy coexistence: {res.stderr}")
        self.assertIn("Режим бесконфликтного сосуществования с Dokploy активен", res.stdout)
        self.assertNotIn("FATAL_ABORT", res.stdout)

    def test_preflight_inspects_nextgen_ports(self):
        """Preflight checks ports for MASQUE, ShadowTLS, and NaiveProxy when enabled."""
        res = run_shell("""
set -euo pipefail
CHECK_MODE=0; NON_INTERACTIVE=0; DEBUG_MODE=0
CYAN=; BOLD=; NC=; DIM=; WHITE=;
warn(){ echo "WARN:$*"; }; ok(){ echo "OK:$*"; }; die(){ echo "FATAL_ABORT:$*"; exit 15; };
source src/common/preflight.sh
ENABLE_AGH=0
ENABLE_WEB_STACK=0
ENABLE_MASQUE=y
MASQUE_PORT=8445
ENABLE_SHADOWTLS=y
SHADOWTLS_PORT=8543
ENABLE_NAIVE=y
NAIVE_PORT=8446

# Simulate 8543 occupied, 8445 and 8446 free
is_port_in_use(){ [[ "$2" == 8543 ]]; }
get_port_listener_info(){ echo "shadow-tls"; }

inspect_port_conflicts
""")
        self.assertEqual(res.returncode, 0)
        self.assertIn("MASQUE HTTP/3 Datagram", res.stdout)
        self.assertIn("WARN:Порт 8543/tcp (ShadowTLS v4) занят", res.stdout)
        self.assertIn("NaïveProxy", res.stdout)


class TestNextGenKeys(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ns = {}
        exec((ROOT / "src/xray/keys.py").read_text(encoding="utf-8"), cls.ns)

    def test_shadowtls_password(self):
        pw = self.ns["generate_shadowtls_password"]()
        self.assertIsInstance(pw, str)
        self.assertGreaterEqual(len(pw), 16)
        self.assertTrue(self.ns["validate_shadowtls_password"](pw))
        self.assertFalse(self.ns["validate_shadowtls_password"]("short"))
        self.assertFalse(self.ns["validate_shadowtls_password"](12345))

    def test_masque_credentials(self):
        user, pw = self.ns["generate_masque_credentials"]("custom_user")
        self.assertEqual(user, "custom_user")
        self.assertGreaterEqual(len(pw), 16)

    def test_naiveproxy_credentials(self):
        user, pw = self.ns["generate_naiveproxy_credentials"]("naive_admin")
        self.assertEqual(user, "naive_admin")
        self.assertGreaterEqual(len(pw), 16)


class TestComposeConfigs(unittest.TestCase):
    def test_masque_config_template_valid_json(self):
        tpl_path = ROOT / "compose" / "sing-box-masque" / "config.json.template"
        self.assertTrue(tpl_path.is_file(), "config.json.template must exist")
        data = json.loads(tpl_path.read_text(encoding="utf-8"))
        inbounds = data.get("inbounds", [])
        self.assertTrue(any(ib.get("type") == "masque" for ib in inbounds), "masque inbound must be defined")
        masque_ib = next(ib for ib in inbounds if ib.get("type") == "masque")
        self.assertEqual(masque_ib.get("listen_port"), 8449)
        self.assertIn("h3", masque_ib.get("tls", {}).get("alpn", []))
        self.assertTrue(masque_ib.get("connect_udp", {}).get("enabled"))
        self.assertTrue(masque_ib.get("connect_ip", {}).get("enabled"))

    def test_caddyfile_template_syntax(self):
        cf_path = ROOT / "compose" / "naiveproxy" / "Caddyfile.template"
        self.assertTrue(cf_path.is_file(), "Caddyfile.template must exist")
        content = cf_path.read_text(encoding="utf-8")
        self.assertIn("forward_proxy", content)
        self.assertIn("probe_resistance", content)
        self.assertIn("dns cloudflare", content)

    def test_zapret_entrypoint_connbytes(self):
        ep_path = ROOT / "compose" / "zapret" / "entrypoint.sh"
        self.assertTrue(ep_path.is_file(), "entrypoint.sh must exist")
        content = ep_path.read_text(encoding="utf-8")
        self.assertIn("connbytes 1:6", content)
        self.assertIn("NFQUEUE", content)
        self.assertIn("--queue-bypass", content)
        self.assertIn("trap cleanup", content)
        self.assertIn("mark ! --mark 0x40000000/0x40000000", content, "Rule must prevent loops for reinjected packets")
        self.assertNotIn("--tcp-flags SYN,ACK SYN,ACK", content, "Rule must not be restricted to SYN,ACK packets")

    def test_zapret_dockerfile_uses_debian_and_netfilter(self):
        df_path = ROOT / "compose" / "zapret" / "Dockerfile"
        self.assertTrue(df_path.is_file())
        content = df_path.read_text(encoding="utf-8")
        self.assertIn("debian:bookworm-slim", content, "Must use Debian for glibc binary compatibility")
        self.assertIn("libnetfilter-queue1", content, "Must install libnetfilter-queue1 runtime library")

    def test_dokploy_compose_traefik_labels(self):
        compose_path = ROOT / "compose" / "docker-compose.dokploy.yml"
        self.assertTrue(compose_path.is_file(), "docker-compose.dokploy.yml must exist")
        content = compose_path.read_text(encoding="utf-8")
        self.assertIn("traefik.enable=true", content)
        self.assertIn("wstunnel-dokploy", content)
        self.assertIn("sing-box-masque", content)
        self.assertIn("shadow-tls", content)
        self.assertIn("naiveproxy-caddy", content)
        self.assertIn("server-side-zapret", content)
        self.assertIn("dokploy-network:", content)
        self.assertIn("extra_hosts:", content, "Must support host.docker.internal")
        self.assertIn("host.docker.internal:51820", content)

    def test_naiveproxy_compose_build_block(self):
        for cname in ["docker-compose.nextgen.yml", "docker-compose.dokploy.yml"]:
            cpath = ROOT / "compose" / cname
            content = cpath.read_text(encoding="utf-8")
            self.assertIn("build:", content)
            self.assertIn("context: ./naiveproxy", content)
            self.assertIn("local-naiveproxy:latest", content)

    def test_shadowtls_tls_env(self):
        for cname in ["docker-compose.nextgen.yml", "docker-compose.dokploy.yml"]:
            cpath = ROOT / "compose" / cname
            content = cpath.read_text(encoding="utf-8")
            self.assertIn("TLS=", content, "Shadow-TLS must receive TLS env var for upstream entrypoint.sh")

    def test_dokploy_coexistence_forces_web_stack_off(self):
        """When DOKPLOY_COEXISTENCE=y, reconstruct_arrays_from_vars forces ENABLE_WEB_STACK=0."""
        res = run_shell("""
set -euo pipefail
CYAN=; BOLD=; NC=; DIM=; WHITE=;
warn(){ :; }; ok(){ :; }; die(){ exit 1; };
is_true() { local val="${1:-0}"; [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]; }
source src/common/secrets.sh
source src/system/env.sh
PRIMARY_DOMAIN="example.com"
ENABLE_WEB_STACK="y"
DOKPLOY_COEXISTENCE="y"

reconstruct_arrays_from_vars
echo "WEB_STACK:$ENABLE_WEB_STACK"
echo "DOKPLOY:$DOKPLOY_COEXISTENCE"
""")
        self.assertEqual(res.returncode, 0)
        self.assertIn("WEB_STACK:0", res.stdout)
        self.assertIn("DOKPLOY:y", res.stdout)

    def test_masque_awg_port_collision_preflight(self):
        """Preflight detects collision between MASQUE and AWG standalone ports."""
        res = run_shell("""
set -euo pipefail
CHECK_MODE=0; NON_INTERACTIVE=0; DEBUG_MODE=0
CYAN=; BOLD=; NC=; DIM=; WHITE=;
warn(){ echo "WARN:$*"; }; ok(){ echo "OK:$*"; }; die(){ exit 15; };
is_true() { local val="${1:-0}"; [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]; }
source src/common/preflight.sh
ENABLE_AGH=0
ENABLE_WEB_STACK=0
ENABLE_AWG_STANDALONE=y
AWG_STANDALONE_PORT=8445
ENABLE_MASQUE=y
MASQUE_PORT=8445

is_port_in_use(){ return 1; }
get_port_listener_info(){ echo ""; }

inspect_port_conflicts
""")
        self.assertEqual(res.returncode, 0)
        self.assertIn("Коллизия портов: MASQUE и AmneziaWG Standalone", res.stdout)

    def test_manage_nextgen_syntax(self):
        manage_sh = ROOT / "manage-services.sh"
        self.assertTrue(manage_sh.is_file(), "manage-services.sh must exist")
        if BASH.is_file():
            res = subprocess.run([str(BASH), "-n", str(manage_sh)], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"manage-services.sh bash -n failed: {res.stderr}")


if __name__ == "__main__":
    unittest.main()
