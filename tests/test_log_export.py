"""Tests for debug log export and retrieval engine."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")


class LogExportTests(unittest.TestCase):
    def run_bash(self, script_code):
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            prelude = """export PATH=/usr/bin:/bin:$PATH
set -euo pipefail
source src/common/colors.sh
source src/common/logger.sh
source src/system/log-export.sh
"""
            script = work / "test.sh"
            script.write_text(prelude + script_code, encoding="utf-8", newline="\n")
            env = os.environ.copy()
            env["TEST_WORK"] = work.as_posix()
            res = subprocess.run([str(BASH), script.as_posix()], cwd=ROOT, env=env,
                                 capture_output=True, text=True, encoding="utf-8", timeout=15)
            return res

    def test_sanitize_debug_log_masks_sensitive_data(self):
        res = self.run_bash(r'''
src="$TEST_WORK/raw.log"
dst="$TEST_WORK/clean.log"
cat << 'EOF' > "$src"
ADMIN_PASSWORD=my_super_secret_password_123
AGH_PASS=agh_secret_password_456
NODE_TOKEN=node_token_secret_789
UUID=6ba7b810-9dad-11d1-80b4-00c04fd430c8
Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w
Regular log line with no secrets
EOF
sanitize_debug_log "$src" "$dst"
cat "$dst"
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertNotIn("my_super_secret_password_123", res.stdout)
        self.assertNotIn("agh_secret_password_456", res.stdout)
        self.assertNotIn("node_token_secret_789", res.stdout)
        self.assertNotIn("6ba7b810-9dad-11d1-80b4-00c04fd430c8", res.stdout)
        self.assertIn("ADMIN_PASSWORD=***MASKED***", res.stdout)
        self.assertIn("Regular log line with no secrets", res.stdout)

    def test_create_web_download_link_in_webroot(self):
        res = self.run_bash(r'''
webroot="$TEST_WORK/webroot"
mkdir -p "$webroot"
log_file="$TEST_WORK/server-setup.log"
echo "fixture log content" > "$log_file"

WEBROOT="$webroot"
PRIMARY_DOMAIN="vpn.example.com"
url=$(create_web_download_link "$log_file")
echo "URL=$url"
ls "$webroot"/debug-*.log
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("URL=http://vpn.example.com/debug-", res.stdout)
        self.assertIn(".log", res.stdout)

    def test_offer_debug_log_export_outputs_scp_command(self):
        res = self.run_bash(r'''
log_file="$TEST_WORK/server-setup.log"
echo "install log" > "$log_file"
SERVER_SETUP_LOG="$log_file"
SSH_PORT=2222
WAN_IP="203.0.113.10"
NON_INTERACTIVE=1

offer_debug_log_export
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("scp -P 2222 root@203.0.113.10:", res.stdout)
        self.assertIn("Журнал выполнения отладки (Debug Log)", res.stdout)


if __name__ == "__main__":
    unittest.main()
