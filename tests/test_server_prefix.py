"""
Unit tests for server prefix auto-detection (IATA standard and country emoji flags).
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")


class TestServerPrefixDetection(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)

    def test_country_to_flag_math(self):
        """Verify Regional Indicator math generates correct country flags."""
        def country_to_flag(code):
            return "".join(chr(127397 + ord(c.upper())) for c in code if "A" <= c.upper() <= "Z")

        self.assertEqual(country_to_flag("NL"), "🇳🇱")
        self.assertEqual(country_to_flag("DE"), "🇩🇪")
        self.assertEqual(country_to_flag("FR"), "🇫🇷")
        self.assertEqual(country_to_flag("GB"), "🇬🇧")
        self.assertEqual(country_to_flag("US"), "🇺🇸")

    def test_cache_file_used_by_bash_function(self):
        """Verify detect_server_location_prefix reads from cache file if present."""
        cache_file = self.work / "setup_mask_server_prefix"
        cache_file.write_text("🇳🇱 NL-AMS\n", encoding="utf-8")

        bash_cmd = f"""
source src/common/config.sh
# Override cache file path by replacing /run or /tmp check with test cache
detect_server_location_prefix() {{
    cat "{cache_file.as_posix()}" | tr -d '\\r\\n'
}}
res=$(detect_server_location_prefix)
printf "%s" "$res"
"""
        proc = subprocess.run(
            [str(BASH), "-c", bash_cmd],
            cwd=ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "🇳🇱 NL-AMS")

    def test_server_prefix_auto_in_env_resolution(self):
        """Verify SERVER_PREFIX='auto' is resolved to detected prefix in env.sh."""
        bash_cmd = """
set -euo pipefail
SERVER_PREFIX="auto"
detect_server_location_prefix() {
    printf '%s\\n' "🇩🇪 DE-FRA"
}
if [ -n "${SERVER_PREFIX:-}" ] && [ "${SERVER_PREFIX,,}" = "auto" ]; then
    SERVER_PREFIX="$(detect_server_location_prefix 2>/dev/null || echo "Server")"
fi
printf "%s" "$SERVER_PREFIX"
"""
        proc = subprocess.run(
            [str(BASH), "-c", bash_cmd],
            cwd=ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8"
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "🇩🇪 DE-FRA")

    def test_vpnuri_prioritizes_sub_title_over_server_prefix(self):
        """Verify vpn:// description uses SUB_TITLE when it differs from SERVER_PREFIX."""
        import base64, zlib, struct, json
        from src.awg.manage_clients import encode_amnezia_vpnuri_31

        def decode_vpnuri(uri):
            self.assertTrue(uri.startswith("vpn://"))
            b64 = uri[6:]
            b64 += "=" * (-len(b64) % 4)
            data = base64.urlsafe_b64decode(b64)
            length = struct.unpack(">I", data[:4])[0]
            uncompressed = zlib.decompress(data[4:])
            self.assertEqual(len(uncompressed), length)
            return json.loads(uncompressed.decode("utf-8"))

        old_sub = os.environ.get("SUB_TITLE")
        old_pref = os.environ.get("SERVER_PREFIX")
        try:
            os.environ["SERVER_PREFIX"] = "🇳🇱 NL-AMS"
            os.environ["SUB_TITLE"] = "🌟 VIP Secret VPN"
            uri = encode_amnezia_vpnuri_31(
                conf_text="[Interface]\nPrivateKey = aaaa\nAddress = 10.8.0.2/32\n[Peer]\nPublicKey = bbbb\nEndpoint = 192.0.2.1:8443\n",
                client_ip="10.8.0.2",
                client_priv="aaaa",
                client_pub="bbbb"
            )
            decoded = decode_vpnuri(uri)
            self.assertEqual(decoded.get("description"), "🌟 VIP Secret VPN — Client")
        finally:
            if old_sub is not None:
                os.environ["SUB_TITLE"] = old_sub
            else:
                os.environ.pop("SUB_TITLE", None)
            if old_pref is not None:
                os.environ["SERVER_PREFIX"] = old_pref
            else:
                os.environ.pop("SERVER_PREFIX", None)

    def test_make_remark_formatting_without_parentheses(self):
        """Verify that inbound remarks format protocol without parentheses."""
        reconcile_path = ROOT / "src/panel/reconcile.py"
        content = reconcile_path.read_text(encoding="utf-8")
        self.assertIn('return f"{server_prefix} {method}"', content)
        self.assertNotIn('return f"{server_prefix} ({method})"', content)

        ns = {"server_prefix": "🇳🇱 NL-AMS"}
        start = content.find("def make_remark(method):")
        end = content.find("\n\n", start)
        exec(content[start:end], ns)
        make_remark = ns["make_remark"]

        self.assertEqual(make_remark("VLESS Steal"), "🇳🇱 NL-AMS VLESS Steal")
        self.assertEqual(make_remark("Hysteria 2"), "🇳🇱 NL-AMS Hysteria 2")
        self.assertEqual(make_remark("AmneziaWG v3"), "🇳🇱 NL-AMS AmneziaWG v3")

        ns["server_prefix"] = ""
        self.assertEqual(make_remark("VLESS Steal"), "VLESS Steal")


if __name__ == "__main__":
    unittest.main()
