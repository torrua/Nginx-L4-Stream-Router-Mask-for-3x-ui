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
PrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=
PresharedKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=
"password": "json_secret_password"
"privateKey": "json_secret_key"
  Пароль администратора:       super_secret_banner_pass
  Password: secret_user_password
DUMMY_KEY_BLOCK
Regular log line with no secrets
EOF
KEY_HDR="-----BEGIN ""OPENSSH PRIVATE KEY-----"
KEY_FTR="-----END ""OPENSSH PRIVATE KEY-----"
sed -i "s/DUMMY_KEY_BLOCK/${KEY_HDR}\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABlwAAAAdzc2gtcn\n${KEY_FTR}/" "$src"
sanitize_debug_log "$src" "$dst"
cat "$dst"
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertNotIn("my_super_secret_password_123", res.stdout)
        self.assertNotIn("agh_secret_password_456", res.stdout)
        self.assertNotIn("node_token_secret_789", res.stdout)
        self.assertNotIn("6ba7b810-9dad-11d1-80b4-00c04fd430c8", res.stdout)
        self.assertNotIn("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=", res.stdout)
        self.assertNotIn("json_secret_password", res.stdout)
        self.assertNotIn("super_secret_banner_pass", res.stdout)
        self.assertNotIn("secret_user_password", res.stdout)
        self.assertNotIn("b3BlbnNzaC1rZXktdjE", res.stdout)
        self.assertIn("ADMIN_PASSWORD=***MASKED***", res.stdout)
        self.assertIn("Пароль администратора: ***MASKED***", res.stdout)
        self.assertIn("Password: ***MASKED***", res.stdout)
        self.assertIn("***PRIVATE_KEY_BLOCK_MASKED***", res.stdout)
        self.assertIn('"password": ***MASKED***', res.stdout)
        self.assertIn("Regular log line with no secrets", res.stdout)

    def test_sanitize_debug_log_fails_safely_when_source_missing(self):
        res = self.run_bash(r'''
src="$TEST_WORK/nonexistent.log"
dst="$TEST_WORK/should_not_exist.log"
if sanitize_debug_log "$src" "$dst"; then
    echo "SHOULD_HAVE_FAILED"
else
    echo "FAILED_SAFELY"
fi
[ ! -f "$dst" ] && echo "NO_DEST_FILE"
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("FAILED_SAFELY", res.stdout)
        self.assertIn("NO_DEST_FILE", res.stdout)
        self.assertNotIn("SHOULD_HAVE_FAILED", res.stdout)

    def test_create_web_download_link_in_webroot_and_masks_secrets(self):
        res = self.run_bash(r'''
webroot="$TEST_WORK/webroot"
mkdir -p "$webroot"
log_file="$TEST_WORK/server-setup.log"
cat << 'EOF' > "$log_file"
ADMIN_PASSWORD=plain_text_admin_pass
Regular setup details
EOF

WEBROOT="$webroot"
PRIMARY_DOMAIN="vpn.example.com"
url=$(create_web_download_link "$log_file")
echo "URL=$url"
dest_file=$(ls "$webroot"/debug-*.log)
echo "CONTENT:"
cat "$dest_file"
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("URL=http://vpn.example.com/debug-", res.stdout)
        self.assertIn(".log", res.stdout)
        self.assertNotIn("plain_text_admin_pass", res.stdout)
        self.assertIn("ADMIN_PASSWORD=***MASKED***", res.stdout)
        self.assertIn("Regular setup details", res.stdout)

    def test_create_web_download_link_fails_when_no_webroot(self):
        res = self.run_bash(r'''
WEBROOT="$TEST_WORK/non_existent_webroot"
log_file="$TEST_WORK/server-setup.log"
echo "log" > "$log_file"
if create_web_download_link "$log_file"; then
    echo "SHOULD_NOT_SUCCEED"
else
    echo "FAILED_SAFELY"
fi
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("FAILED_SAFELY", res.stdout)
        self.assertNotIn("SHOULD_NOT_SUCCEED", res.stdout)

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
