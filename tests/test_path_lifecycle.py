"""Behavioral coverage for secret paths across installation and reconciliation."""
from contextlib import closing
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from scripts.build import bundle_file, SRC_DIR

BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")


class PathLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)

    def shell(self, code):
        # Redirect the system mirror as well: no test writes to the host /etc.
        env_source = bundle_file(SRC_DIR / "system/env.sh", SRC_DIR)
        env_source = env_source.replace("/etc/server-setup.env", (self.work / "system.env").as_posix())
        prelude = """export PATH=/usr/bin:/bin:$PATH
set -euo pipefail
is_true() { [[ "${1:-}" == 1 || "${1:-}" == y || "${1:-}" == true ]]; }
ok() { :; }
log() { :; }
warn() { printf '%s\\n' "$*" >&2; }
die() { warn "$*"; exit 1; }
"""
        return subprocess.run([str(BASH), "-s"], input=prelude + env_source + "\n" + code,
                              cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=25)

    def companion(self, name, panel_path, configured="", runs=1):
        db = self.work / (name + ".db")
        with closing(sqlite3.connect(db)) as conn, conn:
            conn.executescript("""
                CREATE TABLE settings (id INTEGER PRIMARY KEY, key TEXT, value TEXT);
                CREATE TABLE inbounds (id INTEGER PRIMARY KEY, user_id INTEGER, up INTEGER,
                    down INTEGER, total INTEGER, remark TEXT, enable INTEGER, expiry_time INTEGER,
                    listen TEXT, port INTEGER, protocol TEXT, settings TEXT, stream_settings TEXT,
                    tag TEXT, sniffing TEXT);
                CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, password TEXT);
                INSERT INTO users VALUES (1, 'admin', 'admin');
            """)
            if panel_path:
                conn.execute("INSERT INTO settings (key,value) VALUES ('webBasePath',?)", (panel_path,))
        source = bundle_file(SRC_DIR / "entrypoints" / (name + ".main.sh"), SRC_DIR)
        tag = "EOF_PYTHON_CONFIG" if name == "configure-panel" else "EOF_PYTHON_RECONCILE"
        python_code = source.split(f'"$PYTHON_CMD" - << \'{tag}\'\n', 1)[1].split("\n" + tag, 1)[0]
        runtime = self.work / "client.env"
        python_code = python_code.replace('"/run/3xui_unified_client.env"', repr(str(runtime)))
        python_code = python_code.replace('"/tmp/3xui_unified_client.env"', repr(str(runtime)))
        env = os.environ.copy()
        env.update(DB_PATH=str(db), DRY_RUN="0", PRIMARY_DOMAIN="audit.example", PANEL_PATH=configured,
                   ENABLE_WARP="n", ENABLE_NODE_TOKEN="n", ENABLE_STEAL="n", ENABLE_CLASSIC="n",
                   ENABLE_HY2="n", ENABLE_AWG_V3="n", ENABLE_AWG_V2="n", ENABLE_DNSTT="n",
                   ENABLE_NAIVE="n", ENABLE_SS2022="n", ENABLE_SHADOWTLS="n", ENABLE_MASQUE="n",
                   ENABLE_TUIC="n", ENABLE_MTPROTO="n", ENABLE_WSTUNNEL="y",
                   WSTUNNEL_PREFIX="/wstunnel/", WSTUNNEL_PORT="8080")
        # Exercise configure's real Bash defaults before its embedded Python.
        if name == "configure-panel":
            defaults = source.split("# Дефолтные значения переменных, если не определены в .env", 1)[1]
            defaults = defaults.split('SUB_PORT=', 1)[0]
            result = self.shell("PANEL_PATH=" + shlex.quote(configured) + "\n" + defaults + '\nprintf "%s" "$PANEL_PATH"\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            env["PANEL_PATH"] = result.stdout
        paths = []
        for _ in range(runs):
            result = subprocess.run([sys.executable, "-"], input=python_code, env=env,
                                    capture_output=True, text=True, encoding="utf-8", timeout=25)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            with closing(sqlite3.connect(db)) as conn:
                paths.append(conn.execute("SELECT value FROM settings WHERE key='webBasePath'").fetchone()[0])
        return paths, runtime.read_text(encoding="utf-8")

    def test_disabled_wstunnel_state_roundtrip(self):
        target = shlex.quote((self.work / "saved.env").as_posix())
        result = self.shell(f"""
PRIMARY_DOMAIN=example.com
reconstruct_arrays_from_vars
ENABLE_WSTUNNEL=0
WSTUNNEL_PREFIX=""
before="$PANEL_PATH|$AGH_CLIENT_ID"
save_session_state {target}
load_env_file {target}
[[ "$before" == "$PANEL_PATH|$AGH_CLIENT_ID" ]]
""")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_save_preserves_previous_file(self):
        target = self.work / "saved.env"
        target.write_text("previous configuration\n", encoding="utf-8")
        result = self.shell(f"""
PRIMARY_DOMAIN=example.com
reconstruct_arrays_from_vars
cat() {{ return 1; }}
if save_session_state {shlex.quote(target.as_posix())}; then exit 9; fi
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(target.read_text(encoding="utf-8"), "previous configuration\n")
        self.assertFalse(list(self.work.glob("*.tmp.*")))

    def test_cli_panel_override_survives_reconstruction(self):
        result = self.shell("""
PRIMARY_DOMAIN=example.com
PANEL_PATH=from-env
reconstruct_arrays_from_vars
PANEL_PATH=from-cli
reconstruct_arrays_from_vars
printf '%s' "$PANEL_PATH"
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "/from-cli/")

    def test_legacy_paths_survive_resume(self):
        result = self.shell("""
PRIMARY_DOMAIN=example.com
PANEL_PATH=my-3x-panel
WSTUNNEL_PREFIX=/wstunnel/
AGH_CLIENT_ID=home-router
reconstruct_arrays_from_vars
reconstruct_arrays_from_vars
printf '%s|%s|%s' "$PANEL_PATH" "$WSTUNNEL_PREFIX" "$AGH_CLIENT_ID"
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "/my-3x-panel/|/wstunnel/|home-router")

    def test_fresh_secrets_have_128_bits_and_are_stable(self):
        result = self.shell("""
PRIMARY_DOMAIN=example.com
reconstruct_arrays_from_vars
before="$PANEL_PATH|$WSTUNNEL_PREFIX|$AGH_CLIENT_ID"
reconstruct_arrays_from_vars
[[ "$before" == "$PANEL_PATH|$WSTUNNEL_PREFIX|$AGH_CLIENT_ID" ]]
printf '%s' "$before"
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"^/panel-[0-9a-f]{32}/\|/ws-[0-9a-f]{32}/\|client-[0-9a-f]{32}$")

    def test_express_panel_ignores_filtered_entropy_shortfall(self):
        result = self.shell("""
source src/installer/express.sh
PRIMARY_DOMAIN=example.com
ADMIN_PASSWORD=provided
head() { if [[ "${1:-}" == -c && "${2:-}" == 64 ]]; then printf '!!!!!!!!'; else command head "$@"; fi; }
apply_express_defaults
printf '%s' "$PANEL_PATH"
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"^/panel-[0-9a-f]{32}/$")

    def test_configure_preserves_custom_db_path_without_env(self):
        paths, _ = self.companion("configure-panel", "/existing-custom/", runs=2)
        self.assertEqual(paths, ["/existing-custom/"] * 2)

    def test_repair_preserves_legacy_db_path(self):
        paths, _ = self.companion("maintain", "/my-3x-panel/", configured="my-3x-panel", runs=2)
        self.assertEqual(paths, ["/my-3x-panel/"] * 2)

    def test_new_panel_path_persists_and_is_returned_to_shell(self):
        for name in ("configure-panel", "maintain"):
            with self.subTest(name=name):
                paths, runtime = self.companion(name, "", runs=2)
                self.assertRegex(paths[0], r"^/panel-[0-9a-f]{32}/$")
                self.assertEqual(paths[0], paths[1])
                assignments = dict(item.split("=", 1) for item in shlex.split(runtime))
                self.assertEqual(assignments["PANEL_PATH"], paths[1].strip("/"))
                self.assertEqual(assignments["PRIMARY_DOMAIN"], "audit.example")

    def test_reported_wstunnel_prefix_matches_legacy_server(self):
        for name in ("configure-panel", "maintain"):
            with self.subTest(name=name):
                _, runtime = self.companion(name, "/existing/")
                self.assertIn("--http-upgrade-path-prefix wstunnel ", runtime)

    def test_rotation_is_explicit_and_restarts_completed_steps(self):
        cfg = self.work / "input.env"
        cfg.write_text('PRIMARY_DOMAIN="example.com"\nPANEL_PATH="my-3x-panel"\n'
                       'WSTUNNEL_PREFIX="/wstunnel/"\nAGH_CLIENT_ID="home-router"\n'
                       'LAST_COMPLETED_STEP="7"\nAUTO_SETUP_3XUI="n"\n', encoding="utf-8", newline="\n")
        prompts = (SRC_DIR / "tui/prompts.sh").read_text(encoding="utf-8")
        result = self.shell("set -- --config " + shlex.quote(cfg.as_posix()) + " --rotate-paths --non-interactive\n" + prompts + """
printf '%s|%s|%s|%s|%s' "$PANEL_PATH" "$WSTUNNEL_PREFIX" "$AGH_CLIENT_ID" "$LAST_COMPLETED_STEP" "$AUTO_SETUP_3XUI"
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"/panel-[0-9a-f]{32}/\|/ws-[0-9a-f]{32}/\|client-[0-9a-f]{32}\|0\|y$")

    def test_report_uses_applied_service_prefix_over_stale_config(self):
        from src.xray.paths import resolve_wstunnel_prefix
        service = self.work / "wstunnel.service"
        service.write_text("[Service]\nExecStart=/usr/bin/wstunnel server "
                           "--restrict-http-upgrade-path-prefix=applied-prefix ws://127.0.0.1:8080\n", encoding="utf-8")
        self.assertEqual(resolve_wstunnel_prefix("/stale-prefix/", service), "applied-prefix")

    def test_missing_server_prefix_is_not_invented(self):
        from src.xray.paths import resolve_wstunnel_prefix
        self.assertEqual(resolve_wstunnel_prefix("", self.work / "missing.service"), "")

    def test_entropy_failure_stops_without_a_weak_fallback(self):
        result = self.shell("""
od() { return 1; }
if generate_secret_token; then exit 9; fi
[[ -z "${PANEL_PATH:-}" ]]
""")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_installer_recovers_existing_panel_path_when_env_is_missing(self):
        db = self.work / "installed.db"
        with closing(sqlite3.connect(db)) as conn, conn:
            conn.execute("CREATE TABLE settings (key TEXT, value TEXT)")
            conn.execute("INSERT INTO settings VALUES ('webBasePath','/installed-panel/')")
        # Use the current Python interpreter, not a platform-dependent python3 shim.
        result = self.shell("DB_PATH=" + shlex.quote(db.as_posix()) + "\n"
                            + "PYTHON_CMD=" + shlex.quote(Path(sys.executable).as_posix()) + "\n" + """
PRIMARY_DOMAIN=example.com
reconstruct_arrays_from_vars
printf '%s' "$PANEL_PATH"
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "/installed-panel/")

    def test_master_installer_generates_128_bit_panel_secret(self):
        result = self.shell("""
MAGENTA= BOLD= DIM= RESET= GREEN= CHECK= WHITE=
detect_active_ssh_port() { echo 22; }
source src/installer/express.sh
PRIMARY_DOMAIN=example.com
LE_EMAIL=admin@example.com
apply_express_defaults
printf 'SECRET=%s' "$RAW_PATH"
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"SECRET=panel-[0-9a-f]{32}$")

    def test_cli_paths_override_loaded_raw_aliases_when_saved(self):
        cfg = self.work / "existing.env"
        cfg.write_text('PRIMARY_DOMAIN="example.com"\nSUB_PATH="old-sub"\n'
                       'XHTTP_STREAM_PATH="old-stream"\n', encoding="utf-8")
        prompts = bundle_file(SRC_DIR / "tui/prompts.sh", SRC_DIR)
        result = self.shell("show_help() { :; }\nset -- --config " + shlex.quote(cfg.as_posix())
                            + " --sub-path /new-sub/ --xhttp-path /new-stream/\n"
                            + prompts + '\nsave_session_state "$SAVED_CONFIG_FILE"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = cfg.read_text(encoding="utf-8")
        self.assertIn('SUB_PATH="new-sub"', saved)
        self.assertIn('XHTTP_STREAM_PATH="new-stream"', saved)


if __name__ == "__main__":
    unittest.main()
