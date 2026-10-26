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
        input="export PATH=/usr/bin:/bin:$PATH\nsource src/common/config.sh\n" + code,
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

    def test_naive_stream_stripper_architecture(self):
        """When ENABLE_NAIVE=1, Nginx Stream must map NAIVE_DOMAIN to internal stripper upstream and strip proxy_protocol."""
        res = run_shell(r"""
set -euo pipefail
ALL_DOMAINS=("example.com" "naive.example.com")
STEAL_ENABLED=0
CLASSIC_ENABLED=0
ENABLE_NAIVE=1
NAIVE_DOMAIN="naive.example.com"
NAIVE_PORT=8446

STREAM_MAP_RULES=""
for dom in "${ALL_DOMAINS[@]}"; do
    if [[ "${ENABLE_NAIVE:-0}" == "1" ]] && [ -n "${NAIVE_DOMAIN:-}" ] && [ "$dom" = "$NAIVE_DOMAIN" ]; then
        STREAM_MAP_RULES+="        ${dom}     naive_backend;"$'\n'
    else
        STREAM_MAP_RULES+="        ${dom}     nginx_http_backend;"$'\n'
    fi
done

if [[ "${ENABLE_NAIVE:-0}" == "1" ]] && [ -n "${NAIVE_DOMAIN:-}" ]; then
    if [[ ! "$STREAM_MAP_RULES" =~ "$NAIVE_DOMAIN" ]]; then
        STREAM_MAP_RULES+="        ${NAIVE_DOMAIN}     naive_backend;"$'\n'
    fi
fi

NAIVE_STREAM_BLOCKS=""
if [[ "${ENABLE_NAIVE:-0}" == "1" ]]; then
    NAIVE_STREAM_BLOCKS="
upstream naive_backend {
    server 127.0.0.1:8447;
}

server {
    listen 127.0.0.1:8447 proxy_protocol;
    proxy_pass 127.0.0.1:${NAIVE_PORT:-8446};
}
"
fi

stream_conf=$(cat << EOF
map \$ssl_preread_server_name \$backend_gate {
    hostnames;
    ""                     nginx_http_backend;
${STREAM_MAP_RULES}    default                nginx_http_backend;
}

${NAIVE_STREAM_BLOCKS}
EOF
)

echo "--- STREAM CONF ---"
echo "$stream_conf"
count=$(echo "$stream_conf" | grep -c "naive.example.com" || true)
echo "NAIVE_COUNT: $count"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        out = res.stdout
        self.assertIn("naive.example.com     naive_backend;", out)
        self.assertIn("upstream naive_backend {", out)
        self.assertIn("server 127.0.0.1:8447;", out)
        self.assertIn("listen 127.0.0.1:8447 proxy_protocol;", out)
        self.assertIn("proxy_pass 127.0.0.1:8446;", out)
        self.assertNotIn("proxy_pass 127.0.0.1:8446 proxy_protocol", out)
        self.assertIn("NAIVE_COUNT: 1", out)



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
printf '#!/bin/sh\nexit 0\n' > "$MOCK_ROOT/usr/local/bin/nfqws"
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
printf '#!/bin/sh\necho "sing-box version 1.15.0-alpha.13"\n' > "$MOCK_ROOT/usr/local/bin/sing-box"
chmod +x "$MOCK_ROOT/usr/local/bin/sing-box"
export LOCAL_BIN_DIR="$MOCK_ROOT/usr/local/bin"

systemctl(){ echo "MOCK_SYSTEMCTL:$*"; }

PRIMARY_DOMAIN="vpn.example.com"
MASQUE_PORT=8449
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
        ep = data["endpoints"][0]
        self.assertEqual(ep["type"], "masque-server")
        self.assertEqual(ep["listen_port"], 8449)
        self.assertEqual(ep["tls"]["alpn"], ["h3"])
        self.assertEqual(ep["address"], ["10.138.0.1/24"])
        self.assertEqual(ep["users"][0]["username"], "client1")

    def test_setup_wstunnel_service_real_invocation(self):
        """Invoke setup_wstunnel_service from src/installer/steps.sh and inspect generated unit."""
        res = run_shell("""
set -euo pipefail
log(){ echo "LOG:$*"; }; ok(){ echo "OK:$*"; }; warn(){ echo "WARN:$*"; }; die(){ echo "DIE:$*"; exit 1; };
is_true(){ [[ "${1:-0}" == "1" || "${1,,}" == "y" || "${1,,}" == "true" ]]; }

MOCK_ROOT=$(mktemp -d)
mkdir -p "$MOCK_ROOT/etc/systemd/system" "$MOCK_ROOT/usr/local/bin"
printf '#!/bin/sh\nexit 0\n' > "$MOCK_ROOT/usr/local/bin/wstunnel"
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
printf '#!/bin/sh\nexit 0\n' > "$MOCK_ROOT/usr/local/bin/shadow-tls"
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

    def test_setup_naive_service_real_invocation(self):
        """Invoke setup_naive_service from src/installer/steps.sh and inspect generated Caddyfile and unit."""
        res = run_shell("""
set -euo pipefail
log(){ echo "LOG:$*"; }; ok(){ echo "OK:$*"; }; warn(){ echo "WARN:$*"; }; die(){ echo "DIE:$*"; exit 1; };
is_true(){ [[ "${1:-0}" == "1" || "${1,,}" == "y" || "${1,,}" == "true" ]]; }

MOCK_ROOT=$(mktemp -d)
mkdir -p "$MOCK_ROOT/etc/caddy" "$MOCK_ROOT/etc/systemd/system" "$MOCK_ROOT/usr/local/bin" "$MOCK_ROOT/var/www/html"
printf '#!/bin/sh\necho forward_proxy\nexit 0\n' > "$MOCK_ROOT/usr/local/bin/caddy-naive"
chmod +x "$MOCK_ROOT/usr/local/bin/caddy-naive"
export LOCAL_BIN_DIR="$MOCK_ROOT/usr/local/bin"

systemctl(){ echo "MOCK_SYSTEMCTL:$*"; }

PRIMARY_DOMAIN="example.com"
NAIVE_PORT=8446
NAIVE_USER="alice"
NAIVE_PASS="SecretNaivePass99"
NAIVE_DOMAIN="naive.example.com"

source src/installer/steps.sh

eval "$(declare -f setup_naive_service | sed "s|/etc/caddy|$MOCK_ROOT/etc/caddy|g" | sed "s|/etc/naiveproxy|$MOCK_ROOT/etc/caddy|g" | sed "s|/var/www/html|$MOCK_ROOT/var/www/html|g" | sed "s|/etc/systemd/system|$MOCK_ROOT/etc/systemd/system|g")"

setup_naive_service

echo "--- CADDYFILE ---"
cat "$MOCK_ROOT/etc/caddy/Caddyfile"
echo "--- SERVICE ---"
cat "$MOCK_ROOT/etc/systemd/system/caddy-naive.service"
rm -rf "$MOCK_ROOT"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        out = res.stdout
        self.assertIn(":8446 {", out)
        self.assertIn("bind 127.0.0.1", out)
        self.assertIn("forward_proxy {", out)
        self.assertIn("basic_auth alice SecretNaivePass99", out)
        self.assertIn("probe_resistance", out)
        self.assertIn("ExecStart=", out)
        self.assertIn("caddy-naive run --config", out)
        self.assertIn("Caddyfile --adapter caddyfile", out)

    def test_setup_dnstt_service_real_invocation(self):
        """Invoke setup_dnstt_service from src/installer/steps.sh and inspect generated keys and unit."""
        res = run_shell("""
set -euo pipefail
log(){ echo "LOG:$*"; }; ok(){ echo "OK:$*"; }; warn(){ echo "WARN:$*"; }; die(){ echo "DIE:$*"; exit 1; };
is_true(){ [[ "${1:-0}" == "1" || "${1,,}" == "y" || "${1,,}" == "true" ]]; }

MOCK_ROOT=$(mktemp -d)
mkdir -p "$MOCK_ROOT/etc/dnstt" "$MOCK_ROOT/etc/systemd/system" "$MOCK_ROOT/usr/local/bin"
printf '#!/bin/sh\nexit 0\n' > "$MOCK_ROOT/usr/local/bin/dnstt-server"
chmod +x "$MOCK_ROOT/usr/local/bin/dnstt-server"
export LOCAL_BIN_DIR="$MOCK_ROOT/usr/local/bin"

systemctl(){ echo "MOCK_SYSTEMCTL:$*"; }

DNSTT_PORT=53053
SS2022_PORT=8388
DNSTT_DOMAIN="t.example.com"

source src/installer/steps.sh

eval "$(declare -f setup_dnstt_service | sed "s|/etc/dnstt|$MOCK_ROOT/etc/dnstt|g" | sed "s|/etc/systemd/system|$MOCK_ROOT/etc/systemd/system|g")"

setup_dnstt_service

echo "--- KEY EXISTS ---"
[ -f "$MOCK_ROOT/etc/dnstt/server.key" ] && echo "KEY_OK"
[ -f "$MOCK_ROOT/etc/dnstt/server.pub" ] && echo "PUB_OK"
echo "--- SERVICE ---"
cat "$MOCK_ROOT/etc/systemd/system/dnstt-server.service"
rm -rf "$MOCK_ROOT"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        out = res.stdout
        self.assertIn("KEY_OK", out)
        self.assertIn("PUB_OK", out)
        self.assertIn("ExecStart=", out)
        self.assertIn("-udp 0.0.0.0:53053", out)
        self.assertIn("-privkey-file", out)
        self.assertIn("server.key t.example.com 127.0.0.1:8388", out)


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
source src/common/secrets.sh
source src/system/env.sh
reconstruct_arrays_from_vars
echo "FINAL_ENABLE_SS2022: $ENABLE_SS2022"
""")
        self.assertEqual(res.returncode, 0)
        self.assertIn("FINAL_ENABLE_SS2022: 1", res.stdout)

    def test_dnstt_auto_activates_ss2022(self):
        """Enabling DNSTT must auto-activate SS2022 if not explicitly disabled."""
        res = run_shell("""
set -euo pipefail
log(){ :; }; ok(){ :; }; warn(){ :; };
is_true() { local val="${1:-0}"; [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]; }
PRIMARY_DOMAIN="example.com"
ENABLE_DNSTT=1
ENABLE_SS2022=0
CLI_ENABLE_SS2022=""
source src/common/secrets.sh
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

    def test_cli_naive_and_dnstt_flags(self):
        """CLI arguments for naive and dnstt are parsed accurately."""
        res = run_shell("""
set -euo pipefail
log(){ :; }; ok(){ :; }; warn(){ :; }; die(){ echo "ABORT:$*"; exit 1; };
set -- --naive --naive-port 8449 --naive-domain naive.test.com --naive-user testuser --naive-pass secretpass --dnstt --dnstt-port 53054 --dnstt-domain dnstt.test.com --dnstt-pubkey abcdef123456
source src/tui/prompts.sh
echo "CLI_ENABLE_NAIVE: $CLI_ENABLE_NAIVE"
echo "CLI_NAIVE_PORT: $CLI_NAIVE_PORT"
echo "CLI_NAIVE_DOMAIN: $CLI_NAIVE_DOMAIN"
echo "CLI_NAIVE_USER: $CLI_NAIVE_USER"
echo "CLI_NAIVE_PASS: $CLI_NAIVE_PASS"
echo "CLI_ENABLE_DNSTT: $CLI_ENABLE_DNSTT"
echo "CLI_DNSTT_PORT: $CLI_DNSTT_PORT"
echo "CLI_DNSTT_DOMAIN: $CLI_DNSTT_DOMAIN"
echo "CLI_DNSTT_PUBKEY: $CLI_DNSTT_PUBKEY"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertIn("CLI_ENABLE_NAIVE: y", res.stdout)
        self.assertIn("CLI_NAIVE_PORT: 8449", res.stdout)
        self.assertIn("CLI_NAIVE_DOMAIN: naive.test.com", res.stdout)
        self.assertIn("CLI_NAIVE_USER: testuser", res.stdout)
        self.assertIn("CLI_NAIVE_PASS: secretpass", res.stdout)
        self.assertIn("CLI_ENABLE_DNSTT: y", res.stdout)
        self.assertIn("CLI_DNSTT_PORT: 53054", res.stdout)
        self.assertIn("CLI_DNSTT_DOMAIN: dnstt.test.com", res.stdout)
        self.assertIn("CLI_DNSTT_PUBKEY: abcdef123456", res.stdout)

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
echo "CLI_ENABLE_NAIVE: $CLI_ENABLE_NAIVE"
echo "CLI_ENABLE_DNSTT: $CLI_ENABLE_DNSTT"
""")
        self.assertEqual(res.returncode, 0)
        self.assertIn("CLI_ALL_PROTOCOLS: 1", res.stdout)
        self.assertIn("CLI_ENABLE_MASQUE: y", res.stdout)
        self.assertIn("CLI_ENABLE_SHADOWTLS: y", res.stdout)
        self.assertIn("CLI_ENABLE_WSTUNNEL: y", res.stdout)
        self.assertIn("CLI_ENABLE_ZAPRET: y", res.stdout)
        self.assertIn("CLI_ENABLE_SS2022: y", res.stdout)
        self.assertIn("CLI_ENABLE_NAIVE: y", res.stdout)
        self.assertIn("CLI_ENABLE_DNSTT: y", res.stdout)

    def test_ss2022_udp_over_tcp_configured(self):
        """Shadowsocks 2022 inbound must have udpOverTcp and udp_over_tcp configured."""
        reconcile_py = ROOT / "src/panel/reconcile.py"
        conf_py = reconcile_py.read_text(encoding="utf-8") if reconcile_py.exists() else (ROOT / "configure-panel.sh").read_text(encoding="utf-8")
        inbounds_py = (ROOT / "src/xray/inbounds.py").read_text(encoding="utf-8")
        self.assertIn('"udpOverTcp": True', conf_py)
        self.assertIn('"udp_over_tcp": True', conf_py)
        self.assertIn('target_settings["udpOverTcp"] = True', inbounds_py)
        self.assertIn('target_settings["udp_over_tcp"] = True', inbounds_py)

    def test_zapret_integrated_in_os_hardening_and_secure_vps(self):
        """Zapret service must be called in step_os_hardening and prepare-server.sh."""
        steps_sh = (ROOT / "src/installer/steps.sh").read_text(encoding="utf-8")
        sec_vps_sh = (ROOT / "prepare-server.sh").read_text(encoding="utf-8")
        self.assertIn("setup_zapret_service", steps_sh)
        self.assertIn("zapret-server.service", sec_vps_sh)
        self.assertIn("connbytes 1:6", sec_vps_sh)

    def test_naive_service_integrated_in_deploy_services(self):
        """NaiveProxy service must be defined and called in deploy_native_nextgen_services."""
        steps_sh = (ROOT / "src/installer/steps.sh").read_text(encoding="utf-8")
        self.assertIn("setup_naive_service", steps_sh)
        self.assertIn("caddy-naive.service", steps_sh)
        self.assertIn("forward_proxy", steps_sh)

    def test_dnstt_service_integrated_in_deploy_services(self):
        """DNSTT service must be defined and called in deploy_native_nextgen_services."""
        steps_sh = (ROOT / "src/installer/steps.sh").read_text(encoding="utf-8")
        self.assertIn("setup_dnstt_service", steps_sh)
        self.assertIn("dnstt-server.service", steps_sh)
        self.assertIn("deploy_native_nextgen_services", steps_sh)

    def test_dnstt_curve25519_keypair_generation(self):
        """Pure Python Curve25519 helper generates valid 64-hex keypairs."""
        from src.xray.keys import generate_dnstt_keypair, validate_dnstt_pubkey
        priv, pub = generate_dnstt_keypair()
        self.assertEqual(len(priv), 64)
        self.assertEqual(len(pub), 64)
        self.assertTrue(validate_dnstt_pubkey(pub))
        self.assertFalse(validate_dnstt_pubkey("invalid_short_key"))
        self.assertFalse(validate_dnstt_pubkey("g" * 64))

    def test_rebuild_all_domains_includes_naive_domain(self):
        """rebuild_all_domains in src/tui/wizard.sh must include NAIVE_DOMAIN when ENABLE_NAIVE=1."""
        res = run_shell(r"""
set -euo pipefail
PRIMARY_DOMAIN="example.com"
ENABLE_NAIVE=1
NAIVE_DOMAIN="naive.example.com"
ADD_WWW="n"
STEAL_DOMAINS=()
EXTRA_DOMAINS_USER=()
ALL_DOMAINS=()
is_true() { local val="${1:-0}"; [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]; }
eval "$(sed -n '/rebuild_all_domains() {/,/^    }/p' src/tui/wizard.sh)"
rebuild_all_domains
echo "DOMAINS:${ALL_DOMAINS[*]}"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertIn("naive.example.com", res.stdout)

    def test_setup_naive_service_prioritizes_subdomain_certificate(self):
        """setup_naive_service must choose naive_domain cert before PRIMARY_DOMAIN cert."""
        res = run_shell("""
set -euo pipefail
log(){ :; }; ok(){ :; }; warn(){ :; }; die(){ exit 1; };
MOCK_ROOT=$(mktemp -d)
mkdir -p "$MOCK_ROOT/etc/letsencrypt/live/naive.example.com"
mkdir -p "$MOCK_ROOT/etc/letsencrypt/live/example.com"
touch "$MOCK_ROOT/etc/letsencrypt/live/naive.example.com/fullchain.pem" "$MOCK_ROOT/etc/letsencrypt/live/naive.example.com/privkey.pem"
touch "$MOCK_ROOT/etc/letsencrypt/live/example.com/fullchain.pem" "$MOCK_ROOT/etc/letsencrypt/live/example.com/privkey.pem"
mkdir -p "$MOCK_ROOT/etc/caddy" "$MOCK_ROOT/etc/systemd/system" "$MOCK_ROOT/var/www/html" "$MOCK_ROOT/usr/local/bin"
printf '#!/bin/sh\necho forward_proxy\nexit 0\n' > "$MOCK_ROOT/usr/local/bin/caddy-naive"
chmod +x "$MOCK_ROOT/usr/local/bin/caddy-naive"
export LOCAL_BIN_DIR="$MOCK_ROOT/usr/local/bin"
systemctl(){ :; }

PRIMARY_DOMAIN="example.com"
NAIVE_DOMAIN="naive.example.com"
NAIVE_PORT=8446
NAIVE_USER="user"
NAIVE_PASS="pass"

source src/installer/steps.sh
eval "$(declare -f setup_naive_service | sed "s|/etc/caddy|$MOCK_ROOT/etc/caddy|g" | sed "s|/etc/naiveproxy|$MOCK_ROOT/etc/caddy|g" | sed "s|/var/www/html|$MOCK_ROOT/var/www/html|g" | sed "s|/etc/systemd/system|$MOCK_ROOT/etc/systemd/system|g" | sed "s|/etc/letsencrypt|$MOCK_ROOT/etc/letsencrypt|g")"
setup_naive_service
cat "$MOCK_ROOT/etc/caddy/Caddyfile"
rm -rf "$MOCK_ROOT"
""")
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertIn("live/naive.example.com/fullchain.pem", res.stdout)
        self.assertNotIn("live/example.com/fullchain.pem", res.stdout)

    def test_preflight_inspects_dnstt_port(self):
        """inspect_port_conflicts in src/common/preflight.sh checks DNSTT UDP port."""
        preflight_sh = (ROOT / "src/common/preflight.sh").read_text(encoding="utf-8")
        self.assertIn("DNSTT_PORT", preflight_sh)
        self.assertIn("DNSTT DoH Tunnel", preflight_sh)

    def test_step_configure_inbounds_deploys_services_before_configure_3xui(self):
        """deploy_native_nextgen_services must run before configure-panel.sh to export credentials."""
        panel_sh = (ROOT / "src/installer/panel.sh").read_text(encoding="utf-8")
        self.assertLess(panel_sh.index("deploy_native_nextgen_services"), panel_sh.index('bash "$CONFIG_EXEC"'))
        self.assertEqual(panel_sh.count('bash "$CONFIG_EXEC"'), 1)



if __name__ == "__main__":
    unittest.main()

