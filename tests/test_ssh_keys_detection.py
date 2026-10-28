"""
tests/test_ssh_keys_detection.py - TDD tests for SSH key detection, cloud-init unblocking,
and robust public key input handling.
"""

import os
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
        input="export PATH=/usr/bin:/bin:$PATH\n" + code,
        cwd=ROOT,
        text=True,
        encoding="utf-8",
        capture_output=True,
        timeout=25,
        env=full_env,
    )


class TestSSHKeyDetection(unittest.TestCase):
    def test_has_authorized_keys_detects_cloud_init_wrapped_key(self):
        """Cloud-init line with command='Please login as...' must be recognized as having keys."""
        res = run_shell(r"""
set -euo pipefail
log(){ echo "LOG:$*"; }; ok(){ echo "OK:$*"; }; warn(){ echo "WARN:$*"; }; die(){ echo "DIE:$*"; exit 1; };
MOCK_ROOT=$(mktemp -d)
mkdir -p "$MOCK_ROOT/root/.ssh"
cat << 'EOF' > "$MOCK_ROOT/root/.ssh/authorized_keys"
no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="echo 'Please login as the user \"ubuntu\" rather than the user \"root\".';echo;sleep 10;exit 142" ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC8cloudkey test@host
EOF

source src/system/security.sh
eval "$(declare -f has_authorized_keys | sed "s|/root|$MOCK_ROOT/root|g")"

if has_authorized_keys "root"; then
    echo "SUCCESS_HAS_KEYS"
else
    echo "FAIL_NO_KEYS"
fi
""")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("SUCCESS_HAS_KEYS", res.stdout)

    def test_has_authorized_keys_detects_keys_with_options(self):
        """Keys prefixed with options like from= or no-pty must be recognized."""
        res = run_shell(r"""
set -euo pipefail
log(){ echo "LOG:$*"; }; ok(){ echo "OK:$*"; }; warn(){ echo "WARN:$*"; }; die(){ echo "DIE:$*"; exit 1; };
MOCK_ROOT=$(mktemp -d)
mkdir -p "$MOCK_ROOT/root/.ssh"
cat << 'EOF' > "$MOCK_ROOT/root/.ssh/authorized_keys"
from="192.168.1.0/24",no-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedEd25519KeyWithOptions admin@lan
EOF

source src/system/security.sh
eval "$(declare -f has_authorized_keys | sed "s|/root|$MOCK_ROOT/root|g")"

if has_authorized_keys "root"; then
    echo "SUCCESS_HAS_KEYS"
else
    echo "FAIL_NO_KEYS"
fi
""")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("SUCCESS_HAS_KEYS", res.stdout)

    def test_has_authorized_keys_migrates_sudo_user_keys_when_root_empty(self):
        """When root authorized_keys is empty, keys from SUDO_USER should be recognized/migrated."""
        res = run_shell(r"""
set -euo pipefail
log(){ echo "LOG:$*"; }; ok(){ echo "OK:$*"; }; warn(){ echo "WARN:$*"; }; die(){ echo "DIE:$*"; exit 1; };
MOCK_ROOT=$(mktemp -d)
mkdir -p "$MOCK_ROOT/root/.ssh" "$MOCK_ROOT/home/ubuntu/.ssh"
touch "$MOCK_ROOT/root/.ssh/authorized_keys"
cat << 'EOF' > "$MOCK_ROOT/home/ubuntu/.ssh/authorized_keys"
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISudoUserKeyForTesting ubuntu@vps
EOF

export SUDO_USER="ubuntu"
source src/system/security.sh
eval "$(declare -f get_user_home | sed "s|/home/|$MOCK_ROOT/home/|g")"
eval "$(declare -f has_authorized_keys | sed "s|/root|$MOCK_ROOT/root|g")"

if has_authorized_keys "root"; then
    echo "SUCCESS_SUDO_KEYS_FOUND"
else
    echo "FAIL_NO_SUDO_KEYS"
fi
if [ -s "$MOCK_ROOT/root/.ssh/authorized_keys" ]; then
    echo "ROOT_FILE_POPULATED"
fi
""")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("SUCCESS_SUDO_KEYS_FOUND", res.stdout)
        self.assertIn("ROOT_FILE_POPULATED", res.stdout)

    def test_add_authorized_key_unblocks_existing_cloud_init_key(self):
        """Adding a key that exists with cloud-init restrictions should unblock it rather than ignoring it."""
        res = run_shell(r"""
set -euo pipefail
log(){ echo "LOG:$*"; }; ok(){ echo "OK:$*"; }; warn(){ echo "WARN:$*"; }; die(){ echo "DIE:$*"; exit 1; };
MOCK_ROOT=$(mktemp -d)
mkdir -p "$MOCK_ROOT/root/.ssh"
cat << 'EOF' > "$MOCK_ROOT/root/.ssh/authorized_keys"
no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="echo 'Please login as the user \"ubuntu\" rather than the user \"root\".';echo;sleep 10;exit 142" ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC8cloudkey test@host
EOF

source src/system/security.sh
eval "$(declare -f has_authorized_keys | sed "s|/root|$MOCK_ROOT/root|g")"
eval "$(declare -f add_authorized_key | sed "s|/root|$MOCK_ROOT/root|g")"

# User enters their public key which matches the cloud-init blocked key
add_authorized_key "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC8cloudkey test@host" "root"

if has_authorized_keys "root"; then
    echo "SUCCESS_UNBLOCKED_AND_FOUND"
else
    echo "FAIL_STILL_BLOCKED"
fi
grep -q 'command=".*Please login as' "$MOCK_ROOT/root/.ssh/authorized_keys" || echo "COMMAND_WRAPPER_REMOVED"
""")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("SUCCESS_UNBLOCKED_AND_FOUND", res.stdout)
        self.assertIn("COMMAND_WRAPPER_REMOVED", res.stdout)

    def test_add_authorized_key_from_file_path_and_quotes(self):
        """User providing a file path or quoted string should be resolved to public key contents."""
        res = run_shell(r"""
set -euo pipefail
log(){ echo "LOG:$*"; }; ok(){ echo "OK:$*"; }; warn(){ echo "WARN:$*"; }; die(){ echo "DIE:$*"; exit 1; };
MOCK_ROOT=$(mktemp -d)
mkdir -p "$MOCK_ROOT/root/.ssh" "$MOCK_ROOT/tmp"
KEY_FILE="$MOCK_ROOT/tmp/my_client.pub"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFileContentKey client@pc" > "$KEY_FILE"

source src/system/security.sh
eval "$(declare -f has_authorized_keys | sed "s|/root|$MOCK_ROOT/root|g")"
eval "$(declare -f add_authorized_key | sed "s|/root|$MOCK_ROOT/root|g")"

# Test 1: input as file path
add_authorized_key "$KEY_FILE" "root"
if has_authorized_keys "root"; then
    echo "SUCCESS_FILE_PATH_KEY"
fi
grep -q "AAAAC3NzaC1lZDI1NTE5AAAAIFileContentKey" "$MOCK_ROOT/root/.ssh/authorized_keys" && echo "FOUND_IN_FILE"

# Test 2: input with quotes
add_authorized_key "\"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQuotedKey client@quoted\"" "root"
grep -q "AAAAC3NzaC1lZDI1NTE5AAAAIQuotedKey" "$MOCK_ROOT/root/.ssh/authorized_keys" && echo "QUOTES_STRIPPED"
""")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("SUCCESS_FILE_PATH_KEY", res.stdout)
        self.assertIn("FOUND_IN_FILE", res.stdout)
        self.assertIn("QUOTES_STRIPPED", res.stdout)


if __name__ == "__main__":
    unittest.main()
