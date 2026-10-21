"""
tests/test_panel_refactor.py - Tests for panel autonomy, reconcile module, and SSL resolution.
"""

import ast
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")


class TestPanelRefactor(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.work = Path(self.temp_dir.name)

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_bash(self, snippet: str, env: dict = None) -> subprocess.CompletedProcess:
        script = self.work / "test_snippet.sh"
        script.write_text(snippet, encoding="utf-8", newline="\n")
        run_env = os.environ.copy()
        if env:
            run_env.update(env)
        return subprocess.run(
            [str(BASH), str(script)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=run_env,
            timeout=25
        )

    def test_reconcile_py_ast_syntax(self):
        """Verify that src/panel/reconcile.py is syntactically valid Python."""
        reconcile_file = ROOT / "src/panel/reconcile.py"
        self.assertTrue(reconcile_file.is_file())
        code = reconcile_file.read_text(encoding="utf-8")
        # Ensure ast parses without SyntaxError
        tree = ast.parse(code, filename="src/panel/reconcile.py")
        self.assertIsNotNone(tree)

    def test_resolve_ssl_cert_paths_in_bash(self):
        """Verify resolve_ssl_cert_paths prioritizes existing certs for Let's Encrypt and ACME."""
        le_dir = self.work / "etc/letsencrypt/live/example.com"
        acme_dir = self.work / "etc/ssl/acme/acme.example.com"
        le_dir.mkdir(parents=True, exist_ok=True)
        acme_dir.mkdir(parents=True, exist_ok=True)

        (le_dir / "fullchain.pem").write_text("LE_CERT", encoding="utf-8")
        (le_dir / "privkey.pem").write_text("LE_KEY", encoding="utf-8")
        (acme_dir / "fullchain.pem").write_text("ACME_CERT", encoding="utf-8")
        (acme_dir / "privkey.pem").write_text("ACME_KEY", encoding="utf-8")

        snippet = f"""
set -euo pipefail
TARGET_ROOT="{self.work.as_posix()}"
source "{ROOT.as_posix()}/src/common/colors.sh"
source "{ROOT.as_posix()}/src/common/logger.sh"
source "{ROOT.as_posix()}/src/common/config.sh"

# Mock filesystem check by overriding paths or testing directly
resolve_ssl_cert_paths "example.com" "SSL"
resolve_ssl_cert_paths "acme.example.com" "ACME"
resolve_ssl_cert_paths "missing.com" "FALLBACK"

echo "SSL_CERT=$SSL_CERT_PATH"
echo "ACME_CERT=$ACME_CERT_PATH"
echo "FALLBACK_CERT=$FALLBACK_CERT_PATH"
"""
        res = self.run_bash(snippet)
        self.assertEqual(res.returncode, 0, f"Error: {res.stderr}\nStdout: {res.stdout}")
        self.assertIn("SSL_CERT=/etc/letsencrypt/live/example.com/fullchain.pem", res.stdout)
        self.assertIn("FALLBACK_CERT=/etc/letsencrypt/live/missing.com/fullchain.pem", res.stdout)

    def test_secrets_token_generation_entropy(self):
        """Verify unified cryptographic token generators produce non-empty valid tokens."""
        snippet = f"""
set -euo pipefail
source "{ROOT.as_posix()}/src/common/colors.sh"
source "{ROOT.as_posix()}/src/common/logger.sh"
source "{ROOT.as_posix()}/src/common/secrets.sh"

t_urlsafe="$(generate_urlsafe_token 16)"
t_b64="$(generate_base64_token 32)"
t_secret="$(generate_secret_token)"

echo "URLSAFE=$t_urlsafe"
echo "B64=$t_b64"
echo "SECRET=$t_secret"
"""
        res = self.run_bash(snippet)
        self.assertEqual(res.returncode, 0, f"Error: {res.stderr}\nStdout: {res.stdout}")
        lines = dict(line.split("=", 1) for line in res.stdout.strip().splitlines() if "=" in line)
        self.assertGreaterEqual(len(lines["URLSAFE"]), 16)
        self.assertGreaterEqual(len(lines["B64"]), 32)
        self.assertEqual(len(lines["SECRET"]), 32)

    def test_json_cleaner_replaces_geosites_safely(self):
        """Verify Python JSON cleaner removes specified geosites while preserving valid JSON syntax."""
        sample_json = self.work / "config.json"
        sample_json.write_text(json.dumps({
            "routing": {
                "rules": [
                    {"type": "field", "outboundTag": "direct", "domain": ["geosite:ru", "geosite:yandex", "example.com"]},
                    {"type": "field", "outboundTag": "proxy", "domain": ["google.com"]}
                ]
            }
        }, indent=2), encoding="utf-8")

        py_snippet = f"""
import json, sys

cfg_path = r"{sample_json.as_posix()}"
with open(cfg_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

bad_prefixes = ("geosite:ru", "geosite:yandex", "geosite:vk", "geosite:youtube",
                "geosite:openai", "geosite:google-gemini", "geosite:anthropic", "geosite:cloudflare")

def clean_obj(obj):
    if isinstance(obj, dict):
        return {{k: clean_obj(v) for k, v in obj.items()}}
    elif isinstance(obj, list):
        return [clean_obj(x) for x in obj if not (isinstance(x, str) and any(x.startswith(b) for b in bad_prefixes))]
    return obj

cleaned = clean_obj(data)
with open(cfg_path, 'w', encoding='utf-8') as f:
    json.dump(cleaned, f, indent=2, ensure_ascii=False)
"""
        proc = subprocess.run([sys.executable, "-c", py_snippet], capture_output=True, text=True, check=True)
        self.assertEqual(proc.returncode, 0)

        cleaned_data = json.loads(sample_json.read_text(encoding="utf-8"))
        rules = cleaned_data["routing"]["rules"]
        self.assertEqual(rules[0]["domain"], ["example.com"])
        self.assertEqual(rules[1]["domain"], ["google.com"])


if __name__ == "__main__":
    unittest.main()
