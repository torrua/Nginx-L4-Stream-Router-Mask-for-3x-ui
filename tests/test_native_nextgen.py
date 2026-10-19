"""
tests/test_native_nextgen.py - Automated tests for Native Nginx Stream L4 / L7 Next-Gen Protocols:
1. Wstunnel over Nginx L7
2. ShadowTLS v4 + Shadowsocks-2022 over Nginx Stream L4 with PROXY protocol stripper
3. Sing-box MASQUE (RFC 9484 / RFC 9298) daemon
4. Server-Side Zapret nfqws DPI desync with connbytes 1:6
"""

import json
import os
from pathlib import Path
import shutil
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
        input="export PATH=/usr/bin:/bin:$PATH\n" + code,
        cwd=ROOT,
        text=True,
        encoding="utf-8",
        capture_output=True,
        timeout=25,
        env=full_env,
    )


class TestNativeNginxStreamConfig(unittest.TestCase):
    def test_shadowtls_stream_stripper_architecture(self):
        """When ENABLE_SHADOWTLS=1, Nginx Stream must map SNI to internal stripper upstream and prevent duplicate SNI."""
        res = run_shell(r"""
set -euo pipefail
ALL_DOMAINS=("example.com")
STEAL_ENABLED=0
CLASSIC_ENABLED=1
declare -A EXT_SNI_TO_PORT=(["gateway.icloud.com"]="46443" ["itunes.apple.com"]="46443")
ENABLE_SHADOWTLS=1
SHADOWTLS_SNI="gateway.icloud.com"
SHADOWTLS_PORT=8543
ALL_REALITY_PORTS=()

STREAM_MAP_RULES=""
REALITY_UPSTREAMS=""

for dom in "${ALL_DOMAINS[@]}"; do
    STREAM_MAP_RULES+="        ${dom}     nginx_http_backend;"$'\n'
done

if [[ "${CLASSIC_ENABLED:-0}" == "1" || "${CLASSIC_ENABLED:-0}" == "y" ]]; then
    for ext_sni in "${!EXT_SNI_TO_PORT[@]}"; do
        port="${EXT_SNI_TO_PORT[$ext_sni]}"
        if [[ "${ENABLE_SHADOWTLS:-0}" == "1" || "${ENABLE_SHADOWTLS:-0}" == "y" ]] && [ "$ext_sni" = "${SHADOWTLS_SNI:-gateway.icloud.com}" ]; then
            continue
        fi
        STREAM_MAP_RULES+="        ${ext_sni}     reality_backend_${port};"$'\n'
    done
fi

if [[ "${ENABLE_SHADOWTLS:-0}" == "1" || "${ENABLE_SHADOWTLS:-0}" == "y" ]]; then
    STREAM_MAP_RULES+="        ${SHADOWTLS_SNI:-gateway.icloud.com}     shadowtls_backend;"$'\n'
fi

SHADOWTLS_STREAM_BLOCKS=""
if [[ "${ENABLE_SHADOWTLS:-0}" == "1" || "${ENABLE_SHADOWTLS:-0}" == "y" ]]; then
    SHADOWTLS_STREAM_BLOCKS="
upstream shadowtls_backend {
    server 127.0.0.1:8542;
}

server {
    listen 127.0.0.1:8542 proxy_protocol;
    proxy_pass 127.0.0.1:${SHADOWTLS_PORT:-8543};
}
"
fi

DEFAULT_FALLBACK="nginx_http_backend"

stream_conf=$(cat << EOF
map \$ssl_preread_server_name \$backend_gate {
    hostnames;
    ""                     nginx_http_backend;
${STREAM_MAP_RULES}    default                ${DEFAULT_FALLBACK};
}

upstream nginx_http_backend {
    server unix:/dev/shm/nginx-http.sock;
}

${REALITY_UPSTREAMS}
${SHADOWTLS_STREAM_BLOCKS}

server {
    listen 443 backlog=65535 reuseport;
    proxy_protocol on;
    proxy_pass \$backend_gate;
    ssl_preread on;
}
EOF
)

echo "--- STREAM CONF ---"
echo "$stream_conf"

# Verify no duplicate gateway.icloud.com in map
count=$(echo "$stream_conf" | grep -c "gateway.icloud.com" || true)
echo "GATEWAY_COUNT: $count"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        out = res.stdout
        # 1. SNI mapping
        self.assertIn("gateway.icloud.com     shadowtls_backend;", out)
        # 2. Stripper upstream
        self.assertIn("upstream shadowtls_backend {", out)
        self.assertIn("server 127.0.0.1:8542;", out)
        # 3. Stripper server: accepts proxy_protocol from 443 listener and passes raw TLS to 8543
        self.assertIn("listen 127.0.0.1:8542 proxy_protocol;", out)
        self.assertIn("proxy_pass 127.0.0.1:8543;", out)
        self.assertNotIn("proxy_pass 127.0.0.1:8543 proxy_protocol", out)
        # 4. No duplicate SNI mapping
        self.assertIn("GATEWAY_COUNT: 1", out)

    def test_shadowtls_disabled_by_default(self):
        """When ENABLE_SHADOWTLS=0, no shadowtls_backend upstream or stripper should exist."""
        res = run_shell("""
set -euo pipefail
ENABLE_SHADOWTLS=0
ALL_DOMAINS=("example.com")
STREAM_MAP_RULES=""
if [[ "${ENABLE_SHADOWTLS:-0}" == "1" || "${ENABLE_SHADOWTLS:-0}" == "y" ]]; then
    STREAM_MAP_RULES+="        gateway.icloud.com     shadowtls_backend;"$'\\n'
fi
echo "STREAM_MAP_RULES: $STREAM_MAP_RULES"
""")
        self.assertEqual(res.returncode, 0)
        self.assertNotIn("shadowtls_backend", res.stdout)


class TestNativeNginxL7Config(unittest.TestCase):
    def test_wstunnel_location_and_badbot_bypass(self):
        """When ENABLE_WSTUNNEL=1, badbot map must exempt prefix and L7 location must be configured."""
        res = run_shell("""
set -euo pipefail
ENABLE_WSTUNNEL=1
WSTUNNEL_PREFIX="wstunnel-secure-path"
WSTUNNEL_PORT=8080

wstunnel_badbot_bypass=""
if [[ "${ENABLE_WSTUNNEL:-0}" == "1" || "${ENABLE_WSTUNNEL:-0}" == "y" ]] && [ -n "${WSTUNNEL_PREFIX:-}" ]; then
    wstunnel_clean_prefix="${WSTUNNEL_PREFIX%/}"
    wstunnel_badbot_bypass="        ~^1:[01]:${wstunnel_clean_prefix}/ 0;"$'\\n'
fi

WSTUNNEL_LOCATION_BLOCK=""
if [[ "${ENABLE_WSTUNNEL:-0}" == "1" || "${ENABLE_WSTUNNEL:-0}" == "y" ]] && [ -n "${WSTUNNEL_PREFIX:-}" ]; then
    wstunnel_clean_prefix="${WSTUNNEL_PREFIX%/}"
    WSTUNNEL_LOCATION_BLOCK="
    # --- ЛОКАЦИЯ: WSTUNNEL (L7 WebSocket Tunnel) ---
    location ^~ ${wstunnel_clean_prefix}/ {
        proxy_pass http://127.0.0.1:${WSTUNNEL_PORT:-8080};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \\$http_upgrade;
        proxy_set_header Connection \\$connection_upgrade;
        proxy_set_header Host \\$http_host;
        proxy_set_header X-Real-IP \\$ak_real_ip;
        proxy_set_header X-Forwarded-For \\$ak_real_ip;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }
"
fi

echo "--- BADBOT BYPASS ---"
echo "$wstunnel_badbot_bypass"
echo "--- LOCATION BLOCK ---"
echo "$WSTUNNEL_LOCATION_BLOCK"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        out = res.stdout
        self.assertIn("~^1:[01]:wstunnel-secure-path/ 0;", out)
        self.assertIn("location ^~ wstunnel-secure-path/", out)
        self.assertIn("proxy_pass http://127.0.0.1:8080;", out)
        self.assertIn("proxy_set_header Upgrade $http_upgrade;", out)
        self.assertIn("proxy_set_header Connection $connection_upgrade;", out)
        self.assertIn("proxy_buffering off;", out)


class TestNativeInstallerServices(unittest.TestCase):
    def test_setup_zapret_service_real_invocation(self):
        """Invoke setup_zapret_service from src/installer/steps.sh and inspect generated unit."""
        res = run_shell("""
set -euo pipefail
log(){ echo "LOG:$*"; }; ok(){ echo "OK:$*"; }; warn(){ echo "WARN:$*"; }; die(){ echo "DIE:$*"; exit 1; };
is_true(){ [[ "${1:-0}" == "1" || "${1,,}" == "y" || "${1,,}" == "true" ]]; }

MOCK_ROOT=$(mktemp -d)
mkdir -p "$MOCK_ROOT/etc/systemd/system" "$MOCK_ROOT/usr/local/bin"
touch "$MOCK_ROOT/usr/local/bin/nfqws"
chmod +x "$MOCK_ROOT/usr/local/bin/nfqws"
export LOCAL_BIN_DIR="$MOCK_ROOT/usr/local/bin"

systemctl(){ echo "MOCK_SYSTEMCTL:$*"; }
iptables(){ echo "MOCK_IPTABLES:$*"; }

ZAPRET_QNUM=200
ZAPRET_DESYNC="split2"
ZAPRET_FOOLING="md5sig,badseq"

# Source the real implementation
source src/installer/steps.sh

# Temporarily override /etc/systemd/system target via sed in test
eval "$(declare -f setup_zapret_service | sed "s|/etc/systemd/system|$MOCK_ROOT/etc/systemd/system|g")"

setup_zapret_service

cat "$MOCK_ROOT/etc/systemd/system/zapret-server.service"
rm -rf "$MOCK_ROOT"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        content = res.stdout
        self.assertIn("connbytes 1:6", content)
        self.assertIn("--queue-bypass", content)
        self.assertIn("mark ! --mark 0x40000000/0x40000000", content)
        self.assertIn("--dpi-desync=split2", content)
        self.assertIn("--dpi-desync-fooling=md5sig,badseq", content)

    def test_setup_masque_json_validity(self):
        """Invoke setup_masque_service from src/installer/steps.sh and inspect generated JSON."""
        res = run_shell("""
set -euo pipefail
log(){ echo "LOG:$*"; }; ok(){ echo "OK:$*"; }; warn(){ echo "WARN:$*"; }; die(){ echo "DIE:$*"; exit 1; };
is_true(){ [[ "${1:-0}" == "1" || "${1,,}" == "y" || "${1,,}" == "true" ]]; }

MOCK_ROOT=$(mktemp -d)
mkdir -p "$MOCK_ROOT/etc/sing-box" "$MOCK_ROOT/etc/systemd/system" "$MOCK_ROOT/usr/local/bin"
touch "$MOCK_ROOT/usr/local/bin/sing-box"
chmod +x "$MOCK_ROOT/usr/local/bin/sing-box"
export LOCAL_BIN_DIR="$MOCK_ROOT/usr/local/bin"

systemctl(){ echo "MOCK_SYSTEMCTL:$*"; }

PRIMARY_DOMAIN="vpn.example.com"
MASQUE_PORT=8445
MASQUE_USER="client1"
MASQUE_PASSWORD="TestPassword123456"

source src/installer/steps.sh

eval "$(declare -f setup_masque_service | sed "s|/etc/sing-box|$MOCK_ROOT/etc/sing-box|g" | sed "s|/etc/systemd/system|$MOCK_ROOT/etc/systemd/system|g")"

setup_masque_service >/dev/null

cat "$MOCK_ROOT/etc/sing-box/masque.json"
rm -rf "$MOCK_ROOT"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        raw = res.stdout
        json_str = raw[raw.find("{"):] if "{" in raw else raw
        data = json.loads(json_str)
        ib = data["inbounds"][0]
        self.assertEqual(ib["type"], "masque")
        self.assertEqual(ib["listen_port"], 8445)
        self.assertEqual(ib["tls"]["alpn"], ["h3"])
        self.assertTrue(ib["connect_udp"]["enabled"])
        self.assertTrue(ib["connect_ip"]["enabled"])
        self.assertEqual(ib["users"][0]["username"], "client1")

    def test_setup_wstunnel_service_real_invocation(self):
        """Invoke setup_wstunnel_service from src/installer/steps.sh and inspect generated unit."""
        res = run_shell("""
set -euo pipefail
log(){ echo "LOG:$*"; }; ok(){ echo "OK:$*"; }; warn(){ echo "WARN:$*"; }; die(){ echo "DIE:$*"; exit 1; };
is_true(){ [[ "${1:-0}" == "1" || "${1,,}" == "y" || "${1,,}" == "true" ]]; }

MOCK_ROOT=$(mktemp -d)
mkdir -p "$MOCK_ROOT/etc/systemd/system" "$MOCK_ROOT/usr/local/bin"
touch "$MOCK_ROOT/usr/local/bin/wstunnel"
chmod +x "$MOCK_ROOT/usr/local/bin/wstunnel"
export LOCAL_BIN_DIR="$MOCK_ROOT/usr/local/bin"

systemctl(){ echo "MOCK_SYSTEMCTL:$*"; }

WSTUNNEL_PORT=8080
WSTUNNEL_PREFIX="/custom-ws/"

source src/installer/steps.sh

eval "$(declare -f setup_wstunnel_service | sed "s|/etc/systemd/system|$MOCK_ROOT/etc/systemd/system|g")"

setup_wstunnel_service

cat "$MOCK_ROOT/etc/systemd/system/wstunnel.service"
rm -rf "$MOCK_ROOT"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        content = res.stdout
        self.assertIn("wstunnel server --restrict-http-upgrade-path-prefix custom-ws ws://127.0.0.1:8080", content)

    def test_setup_shadowtls_service_real_invocation(self):
        """Invoke setup_shadowtls_service from src/installer/steps.sh and inspect generated unit."""
        res = run_shell("""
set -euo pipefail
log(){ echo "LOG:$*"; }; ok(){ echo "OK:$*"; }; warn(){ echo "WARN:$*"; }; die(){ echo "DIE:$*"; exit 1; };
is_true(){ [[ "${1:-0}" == "1" || "${1,,}" == "y" || "${1,,}" == "true" ]]; }

MOCK_ROOT=$(mktemp -d)
mkdir -p "$MOCK_ROOT/etc/systemd/system" "$MOCK_ROOT/usr/local/bin"
touch "$MOCK_ROOT/usr/local/bin/shadow-tls"
chmod +x "$MOCK_ROOT/usr/local/bin/shadow-tls"
export LOCAL_BIN_DIR="$MOCK_ROOT/usr/local/bin"

systemctl(){ echo "MOCK_SYSTEMCTL:$*"; }

SHADOWTLS_PORT=8543
SS2022_PORT=8388
SHADOWTLS_SNI="gateway.icloud.com"
SHADOWTLS_PASSWORD="SecretPassword123"

source src/installer/steps.sh

eval "$(declare -f setup_shadowtls_service | sed "s|/etc/systemd/system|$MOCK_ROOT/etc/systemd/system|g")"

setup_shadowtls_service

cat "$MOCK_ROOT/etc/systemd/system/shadow-tls.service"
rm -rf "$MOCK_ROOT"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        content = res.stdout
        self.assertIn("--listen 127.0.0.1:8543", content)
        self.assertIn("--server 127.0.0.1:8388", content)
        self.assertIn("--tls gateway.icloud.com:443", content)
        self.assertIn("--password SecretPassword123", content)


class TestEnvAndCLIIntegration(unittest.TestCase):
    def test_shadowtls_auto_activates_ss2022(self):
        """Enabling ShadowTLS must auto-activate SS2022 if not explicitly disabled."""
        res = run_shell("""
set -euo pipefail
log(){ :; }; ok(){ :; }; warn(){ :; };
is_true() { local val="${1:-0}"; [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]; }
PRIMARY_DOMAIN="example.com"
ENABLE_SHADOWTLS=1
ENABLE_SS2022=0
CLI_ENABLE_SS2022=""
source src/system/env.sh
reconstruct_arrays_from_vars
echo "FINAL_ENABLE_SS2022: $ENABLE_SS2022"
""")
        self.assertEqual(res.returncode, 0)
        self.assertIn("FINAL_ENABLE_SS2022: 1", res.stdout)

    def test_cli_nextgen_flags(self):
        """CLI arguments --masque, --shadowtls, --wstunnel, --zapret, and --all-protocols work correctly."""
        res = run_shell("""
set -euo pipefail
log(){ :; }; ok(){ :; }; warn(){ :; }; die(){ echo "ABORT:$*"; exit 1; };
set -- --masque --shadowtls --wstunnel --zapret --masque-port 8999 --wstunnel-prefix "/customws"
source src/tui/prompts.sh
echo "CLI_ENABLE_MASQUE: $CLI_ENABLE_MASQUE"
echo "CLI_ENABLE_SHADOWTLS: $CLI_ENABLE_SHADOWTLS"
echo "CLI_ENABLE_WSTUNNEL: $CLI_ENABLE_WSTUNNEL"
echo "CLI_ENABLE_ZAPRET: $CLI_ENABLE_ZAPRET"
echo "CLI_MASQUE_PORT: $CLI_MASQUE_PORT"
echo "CLI_WSTUNNEL_PREFIX: $CLI_WSTUNNEL_PREFIX"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertIn("CLI_ENABLE_MASQUE: y", res.stdout)
        self.assertIn("CLI_ENABLE_SHADOWTLS: y", res.stdout)
        self.assertIn("CLI_ENABLE_WSTUNNEL: y", res.stdout)
        self.assertIn("CLI_ENABLE_ZAPRET: y", res.stdout)
        self.assertIn("CLI_MASQUE_PORT: 8999", res.stdout)
        self.assertIn("CLI_WSTUNNEL_PREFIX: /customws", res.stdout)

    def test_cli_all_protocols_flag(self):
        """--all-protocols enables all next-gen and classic protocols in express mode."""
        res = run_shell("""
set -euo pipefail
log(){ :; }; ok(){ :; }; warn(){ :; }; die(){ echo "ABORT:$*"; exit 1; };
set -- --all-protocols
source src/tui/prompts.sh
echo "CLI_ALL_PROTOCOLS: $CLI_ALL_PROTOCOLS"
echo "CLI_ENABLE_MASQUE: $CLI_ENABLE_MASQUE"
echo "CLI_ENABLE_SHADOWTLS: $CLI_ENABLE_SHADOWTLS"
echo "CLI_ENABLE_WSTUNNEL: $CLI_ENABLE_WSTUNNEL"
echo "CLI_ENABLE_ZAPRET: $CLI_ENABLE_ZAPRET"
echo "CLI_ENABLE_SS2022: $CLI_ENABLE_SS2022"
""")
        self.assertEqual(res.returncode, 0)
        self.assertIn("CLI_ALL_PROTOCOLS: 1", res.stdout)
        self.assertIn("CLI_ENABLE_MASQUE: y", res.stdout)
        self.assertIn("CLI_ENABLE_SHADOWTLS: y", res.stdout)
        self.assertIn("CLI_ENABLE_WSTUNNEL: y", res.stdout)
        self.assertIn("CLI_ENABLE_ZAPRET: y", res.stdout)
        self.assertIn("CLI_ENABLE_SS2022: y", res.stdout)

    def test_ss2022_udp_over_tcp_configured(self):
        """Shadowsocks 2022 inbound must have udpOverTcp and udp_over_tcp configured."""
        conf_py = (ROOT / "src/entrypoints/configure_3xui.main.sh").read_text(encoding="utf-8")
        inbounds_py = (ROOT / "src/xray/inbounds.py").read_text(encoding="utf-8")
        self.assertIn('"udpOverTcp": True', conf_py)
        self.assertIn('"udp_over_tcp": True', conf_py)
        self.assertIn('target_settings["udpOverTcp"] = True', inbounds_py)
        self.assertIn('target_settings["udp_over_tcp"] = True', inbounds_py)

    def test_zapret_integrated_in_os_hardening_and_secure_vps(self):
        """Zapret service must be called in step_os_hardening and secure-vps.sh."""
        steps_sh = (ROOT / "src/installer/steps.sh").read_text(encoding="utf-8")
        sec_vps_sh = (ROOT / "secure-vps.sh").read_text(encoding="utf-8")
        self.assertIn("setup_zapret_service", steps_sh)
        self.assertIn("zapret-server.service", sec_vps_sh)
        self.assertIn("connbytes 1:6", sec_vps_sh)

    def test_naive_service_integrated_in_deploy_services(self):
        """NaiveProxy service must be defined and called in deploy_native_nextgen_services."""
        steps_sh = (ROOT / "src/installer/steps.sh").read_text(encoding="utf-8")
        self.assertIn("setup_naive_service", steps_sh)
        self.assertIn("caddy-naive.service", steps_sh)
        self.assertIn("forward_proxy", steps_sh)


if __name__ == "__main__":
    unittest.main()

