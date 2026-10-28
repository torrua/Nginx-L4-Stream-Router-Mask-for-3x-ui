"""Node API token defaults, creation, reuse and visible installation results."""
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import closing

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from scripts.build import bundle_file, SRC_DIR

BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")
TOKEN = "fixture-node-key-" + "a" * 32
_NODE_BUNDLE_CACHE: dict[Path, str] = {}


def _get_bundle(path: Path) -> str:
    if path not in _NODE_BUNDLE_CACHE:
        _NODE_BUNDLE_CACHE[path] = bundle_file(path, SRC_DIR)
    return _NODE_BUNDLE_CACHE[path]


class NodeTokenTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.db = self.work / "panel.db"
        self.config = self.work / "server.env"
        self.config.write_text('PRIMARY_DOMAIN="example.com"\n', encoding="utf-8", newline="\n")

    def shell(self, code, source=""):
        prelude = """
export PATH=/usr/bin:/bin:$PATH
set -euo pipefail
source src/common/colors.sh
SCRIPT_VERSION=test
is_true() { [[ "${1:-}" == 1 || "${1:-}" == y || "${1:-}" == true ]]; }
log() { :; }; ok() { :; }; warn() { printf '%s\\n' "$*" >&2; }
die() { warn "$*"; exit 1; }
"""
        env = dict(os.environ, TEST_WORK=self.work.as_posix(), DB_PATH=self.db.as_posix(),
                   CONFIG_FILE=self.config.as_posix(), PYTHON_CMD=Path(sys.executable).as_posix(),
                   NODE_ENV_FILE=(self.work / "node.env").as_posix(), TOKEN_FIXTURE=TOKEN)
        return subprocess.run([str(BASH), "-s"], input=prelude + source + "\n" + code,
                              cwd=ROOT, env=env, capture_output=True, text=True, encoding="utf-8", timeout=20)

    def environment(self):
        return _get_bundle(SRC_DIR / "system/env.sh")

    def generation(self):
        return _get_bundle(SRC_DIR / "panel/node-token.sh")

    def create_table(self, token=None, name="Server-Node", expires=0):
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("CREATE TABLE api_tokens (id INTEGER PRIMARY KEY, name TEXT UNIQUE, token TEXT, "
                         "enabled INTEGER, scope TEXT NOT NULL DEFAULT 'admin', created_at INTEGER, "
                         "expires_at INTEGER NOT NULL DEFAULT 0)")
            if token is not None:
                conn.execute("INSERT INTO api_tokens(name,token,enabled,scope,expires_at) VALUES (?,?,1,'admin',?)",
                             (name, hashlib.sha256(token.encode()).hexdigest(), expires))

    def test_default_is_yes_in_both_profiles_and_explicit_no_is_preserved(self):
        cases = [("expert", ""), ("express", ""), ("express", "n")]
        blocks = []
        for profile, explicit in cases:
            code = '(\nPRIMARY_DOMAIN=example.com\n'
            if explicit:
                code += 'ENABLE_NODE_TOKEN=n\n'
            code += 'reconstruct_arrays_from_vars\n'
            if profile == "express":
                code += 'source src/installer/express.sh\napply_express_defaults\n'
            code += 'finalize_installation_config\nprintf "%s|%s\\n" "$ENABLE_NODE_TOKEN" "${NODE_TOKEN_NAME:-}"\n)\n'
            blocks.append(code)
        batched = 'echo "---CASE---"\n'.join(blocks)
        result = self.shell(batched, self.environment())
        self.assertEqual(result.returncode, 0, result.stderr)
        parts = [p.strip() for p in result.stdout.split("---CASE---")]
        self.assertEqual(len(parts), 3)
        self.assertEqual(parts[0], "y|Server-Node")
        self.assertEqual(parts[1], "y|Server-Node")
        self.assertTrue(parts[2].startswith("n|"), parts[2])

    def test_wizard_accepts_yes_for_node_token_when_enter_is_used(self):
        wizard = (SRC_DIR / "tui/wizard.sh").read_text(encoding="utf-8")
        block = wizard[wizard.index("    q_step_3xui_auto() {"):wizard.index("    q_step_warp() {")]
        result = self.shell('SHOW_TIPS=n; SERVER_PREFIX=Server; PORTS_SETUP_MODE=1\n'
                            'prompt_yes_no() { printf -v "$3" "%s" "$2"; }\n'
                            + block + '\nq_step_3xui_auto\nprintf "RESULT=%s" "$ENABLE_NODE_TOKEN"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RESULT=y", result.stdout)

    def test_generated_config_enables_node_token_by_default(self):
        for name in ("server-setup.env.example", "src/tui/banner.sh"):
            with self.subTest(name=name):
                self.assertTrue('ENABLE_NODE_TOKEN="y"' in (ROOT / name).read_text(encoding="utf-8"))

    def test_existing_valid_key_is_reused_without_calling_rotating_cli(self):
        self.create_table(TOKEN)
        result = self.shell(r'''
ENABLE_NODE_TOKEN=y; NODE_TOKEN_NAME=Server-Node; NODE_TOKEN="$TOKEN_FIXTURE"
fake_cli() { echo called >> "$TEST_WORK/calls"; echo 'apiToken: unwanted-new-key'; }
XUI_BIN=fake_cli
ensure_node_token
printf 'RESULT=%s' "$NODE_TOKEN"
''', self.generation())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RESULT=" + TOKEN, result.stdout)
        self.assertFalse((self.work / "calls").exists())

    def test_sqlite_fallback_creates_usable_key_and_persists_quoted_name(self):
        self.create_table()
        result = self.shell(r'''
ENABLE_NODE_TOKEN=y; NODE_TOKEN_NAME="Server/O'Brien"; NODE_TOKEN=""; XUI_BIN=""
ensure_node_token
printf 'RESULT=%s' "$NODE_TOKEN"
''', self.generation())
        self.assertEqual(result.returncode, 0, result.stderr)
        token = result.stdout.split("RESULT=", 1)[1].strip()
        self.assertRegex(token, r"^[0-9a-f]{64}$")
        with closing(sqlite3.connect(self.db)) as conn, conn:
            stored = conn.execute("SELECT token,enabled,scope FROM api_tokens WHERE name=?", ("Server/O'Brien",)).fetchone()
        self.assertEqual(stored, (hashlib.sha256(token.encode()).hexdigest(), 1, "node-sync"))
        self.assertIn(token, self.config.read_text(encoding="utf-8"))
        self.assertIn(token, (self.work / "node.env").read_text(encoding="utf-8"))
        if os.name != "nt":
            self.assertEqual((self.work / "node.env").stat().st_mode & 0o777, 0o600)

    def test_creation_failure_stops_instead_of_claiming_key_exists(self):
        with closing(sqlite3.connect(self.db)) as conn, conn:
            conn.execute("CREATE TABLE unrelated (id INTEGER)")
        result = self.shell('ENABLE_NODE_TOKEN=y; NODE_TOKEN_NAME=Server-Node; NODE_TOKEN=""; XUI_BIN=""\n'
                            'ensure_node_token\necho BAD_SUCCESS\n', self.generation())
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("BAD_SUCCESS", result.stdout)

    def test_native_cli_key_is_verified_and_saved(self):
        self.create_table(TOKEN)
        result = self.shell(r'''
ENABLE_NODE_TOKEN=y; NODE_TOKEN_NAME=Server-Node; NODE_TOKEN=""
fake_cli() { echo 'apiToken:' "$TOKEN_FIXTURE"; }
XUI_BIN=fake_cli
ensure_node_token
printf 'RESULT=%s' "$NODE_TOKEN"
''', self.generation())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RESULT=" + TOKEN, result.stdout)
        self.assertIn(TOKEN, self.config.read_text(encoding="utf-8"))

    def test_cli_prefers_node_sync_by_default(self):
        self.create_table(TOKEN)
        result = self.shell(r'''
ENABLE_NODE_TOKEN=y; NODE_TOKEN_NAME=Server-Node; NODE_TOKEN=""
fake_cli() {
    if [[ "$*" == *"-tokenScope node-sync"* ]]; then
        echo 'apiToken:' "$TOKEN_FIXTURE"
        return 0
    fi
    echo "Unexpected CLI args: $*" >&2
    return 1
}
XUI_BIN=fake_cli
ensure_node_token
printf 'RESULT=%s' "$NODE_TOKEN"
''', self.generation())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RESULT=" + TOKEN, result.stdout)

    def test_cli_falls_back_to_admin_if_node_sync_unsupported(self):
        self.create_table(TOKEN)
        result = self.shell(r'''
ENABLE_NODE_TOKEN=y; NODE_TOKEN_NAME=Server-Node; NODE_TOKEN=""
fake_cli() {
    # Emulate older 3X-UI that rejects node-sync scope
    if [[ "$*" == *"-tokenScope node-sync"* ]]; then
        echo "Error: invalid scope node-sync" >&2
        return 1
    fi
    if [[ "$*" == *"-tokenScope admin"* ]]; then
        echo 'apiToken:' "$TOKEN_FIXTURE"
        return 0
    fi
    return 1
}
XUI_BIN=fake_cli
ensure_node_token
printf 'RESULT=%s' "$NODE_TOKEN"
''', self.generation())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RESULT=" + TOKEN, result.stdout)

    def test_explicit_admin_scope_is_honored(self):
        self.create_table(TOKEN)
        result = self.shell(r'''
ENABLE_NODE_TOKEN=y; NODE_TOKEN_NAME=Server-Node; NODE_TOKEN_SCOPE=admin; NODE_TOKEN=""
fake_cli() {
    if [[ "$*" == *"-tokenScope admin"* ]]; then
        echo 'apiToken:' "$TOKEN_FIXTURE"
        return 0
    fi
    echo "Expected admin scope but got: $*" >&2
    return 1
}
XUI_BIN=fake_cli
ensure_node_token
printf 'RESULT=%s' "$NODE_TOKEN"
''', self.generation())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RESULT=" + TOKEN, result.stdout)

    def test_expired_key_is_replaced_and_expiry_is_cleared(self):
        self.create_table(TOKEN, expires=1)
        result = self.shell(r'''
ENABLE_NODE_TOKEN=y; NODE_TOKEN_NAME=Server-Node; NODE_TOKEN="$TOKEN_FIXTURE"; XUI_BIN=""
ensure_node_token
printf 'RESULT=%s' "$NODE_TOKEN"
''', self.generation())
        self.assertEqual(result.returncode, 0, result.stderr)
        token = result.stdout.split("RESULT=", 1)[1].strip()
        self.assertNotEqual(token, TOKEN)
        with closing(sqlite3.connect(self.db)) as conn:
            row = conn.execute("SELECT token,expires_at FROM api_tokens").fetchone()
        self.assertEqual(row, (hashlib.sha256(token.encode()).hexdigest(), 0))

    def test_generated_key_crosses_child_process_boundary_into_final_report(self):
        self.create_table()
        panel = bundle_file(SRC_DIR / "installer/panel.sh", SRC_DIR)
        panel = panel.replace('CONFIG_EXEC="$script_dir/configure-panel.sh"', 'CONFIG_EXEC="$TEST_WORK/configure-panel.sh"')
        report = bundle_file(SRC_DIR / "installer/report-web.sh", SRC_DIR)
        report = report.replace('"/root/vpn_credentials.txt"', '"$TEST_WORK/credentials.txt"')
        (self.work / "configure-panel.sh").write_text("# fixture\n", encoding="utf-8")
        source = self.environment() + "\n" + self.generation() + "\n" + panel
        result = self.shell(r'''
PRIMARY_DOMAIN=example.com; ENABLE_NODE_TOKEN=y; NODE_TOKEN_NAME=Server-Node; NODE_TOKEN=""
ENABLE_WARP=n; ENABLE_AGH=n; XUI_BIN=""; PANEL_PATH=/fixture-panel/
reconstruct_arrays_from_vars
finalize_installation_config
SAVED_CONFIG_FILE="$CONFIG_FILE"
x-ui() { :; }
deploy_native_nextgen_services() { :; }
save_session_state() { printf '%s' "${NODE_TOKEN:-}" > "$TEST_WORK/parent-key"; }
run_with_spinner() { if [ "$2" = run_configure_3xui_task ]; then ( ensure_node_token ); fi; }
install_step_panel
printf 'PARENT=%s\n' "$NODE_TOKEN"
SSL_BASE_DIR="$TEST_WORK/certs"; SHOW_MANUAL_STEPS=0
''' + report, source)
        self.assertEqual(result.returncode, 0, result.stderr)
        token = (self.work / "parent-key").read_text(encoding="utf-8")
        self.assertRegex(token, r"^[0-9a-f]{64}$")
        self.assertIn("PARENT=" + token, result.stdout)
        self.assertIn(token, (self.work / "credentials.txt").read_text(encoding="utf-8"))
        self.assertFalse((self.work / "node.env").exists())

    def test_runtime_result_is_data_and_never_executes_shell_expressions(self):
        helper = SRC_DIR / "common/node-token.sh"
        self.assertTrue(helper.is_file())
        runtime = self.work / "node.env"
        runtime.write_text('NODE_TOKEN_NAME="$(touch ' + (self.work / "unexpected").as_posix()
                           + ')"\nNODE_TOKEN="' + TOKEN + '"\n', encoding="utf-8", newline="\n")
        result = self.shell('load_node_token_result "$NODE_ENV_FILE"\nprintf "%s" "$NODE_TOKEN"',
                            bundle_file(helper, SRC_DIR))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, TOKEN)
        self.assertFalse((self.work / "unexpected").exists())

    def test_empty_runtime_result_cannot_reuse_stale_parent_key(self):
        (self.work / "node.env").write_text("", encoding="utf-8")
        result = self.shell('NODE_TOKEN="$TOKEN_FIXTURE"\n'
                            'if load_node_token_result "$NODE_ENV_FILE"; then echo BAD_SUCCESS; exit 9; fi\n',
                            bundle_file(SRC_DIR / "common/node-token.sh", SRC_DIR))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("BAD_SUCCESS", result.stdout)

    def test_explicit_cli_no_overrides_enabled_config(self):
        self.config.write_text('PRIMARY_DOMAIN="example.com"\nENABLE_NODE_TOKEN="y"\n', encoding="utf-8")
        prompts = bundle_file(SRC_DIR / "tui/prompts.sh", SRC_DIR)
        result = self.shell('set -- --config "$CONFIG_FILE" --no-node-token\n'
                            + prompts + '\nfinalize_installation_config\nprintf "RESULT=%s" "$ENABLE_NODE_TOKEN"\n',
                            self.environment())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RESULT=n", result.stdout)

    def test_actual_key_is_in_console_and_credentials_even_without_admin_password(self):
        report = bundle_file(SRC_DIR / "installer/report-web.sh", SRC_DIR)
        report = report.replace('"/root/vpn_credentials.txt"', '"$TEST_WORK/credentials.txt"')
        for password in ("fixture-admin-password", ""):
            with self.subTest(password=bool(password)):
                credentials = self.work / "credentials.txt"
                if credentials.exists():
                    credentials.unlink()
                code = ('PRIMARY_DOMAIN=example.com; ENABLE_NODE_TOKEN=y; NODE_TOKEN_NAME=Server-Node\n'
                        'NODE_TOKEN="$TOKEN_FIXTURE"; ENABLE_WARP=n; ENABLE_AGH=n\n'
                        'reconstruct_arrays_from_vars\nfinalize_installation_config\n'
                        f'ADMIN_PASSWORD={shlex.quote(password)}\n'
                        'SSL_BASE_DIR="$TEST_WORK/certs"; SHOW_MANUAL_STEPS=0\n')
                result = self.shell(code + report, self.environment())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(TOKEN, result.stdout)
                self.assertTrue(credentials.is_file(), "The node key must be saved even if the panel password is unchanged")
                self.assertIn(TOKEN, credentials.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
