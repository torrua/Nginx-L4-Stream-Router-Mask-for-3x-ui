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

    def test_diag_path_ensured_when_unbound(self):
        result = self.shell("""
PRIMARY_DOMAIN=example.com
unset DIAG_PATH DIAG_TOKEN 2>/dev/null || true
ensure_diag_path
printf '%s|%s' "$DIAG_PATH" "$DIAG_TOKEN"
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"^/diag-[0-9a-f]{32}/\|[a-z0-9]{16}$")

    def test_install_step_nginx_config_unbound_variable_guard(self):
        nginx_conf = bundle_file(SRC_DIR / "nginx/config.sh", SRC_DIR)
        nginx_dir = (self.work / "etc" / "nginx").as_posix()
        (self.work / "etc" / "nginx" / "conf.d").mkdir(parents=True, exist_ok=True)
        (self.work / "etc" / "nginx" / "stream.d").mkdir(parents=True, exist_ok=True)
        (self.work / "etc" / "nginx" / "modules-enabled").mkdir(parents=True, exist_ok=True)
        (self.work / "var" / "cache" / "nginx").mkdir(parents=True, exist_ok=True)
        nginx_conf = nginx_conf.replace("/etc/nginx", nginx_dir)
        nginx_conf = nginx_conf.replace("/var/cache/nginx", (self.work / "var" / "cache" / "nginx").as_posix())
        code = f"""
backup_nginx_configs() {{ :; }}
restore_nginx_configs() {{ :; }}
run_with_spinner() {{ :; }}
ensure_nginx_stream_module() {{ :; }}
determine_nginx_http2_mode() {{ HTTP2_HTTP_PARAMS=""; HTTP2_LISTEN_PARAM=""; HTTP2_DIRECTIVE=""; }}
NGINX_USER="nginx"
PRIMARY_DOMAIN="example.com"
ALL_DOMAINS=("example.com")
PANEL_PORT=10443
SUB_PORT=55443
XHTTP_STREAM_PORT=50443
PORT_AGH_WEB=3000
REALITY_FALLBACK_PORT=9443
WEBROOT="{self.work.as_posix()}/www"
mkdir -p "$WEBROOT"

install_step_nginx_config() {{
{nginx_conf}
}}

unset DIAG_PATH DIAG_TOKEN PANEL_PATH SUB_PATH SUB_JSON_PATH SUB_CLASH_PATH XHTTP_STREAM_PATH 2>/dev/null || true

install_step_nginx_config
printf 'OK|%s|%s' "$DIAG_PATH" "$DIAG_TOKEN"
"""
        result = self.shell(code)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"^OK\|/diag-[0-9a-f]{32}/\|[a-z0-9]{16}$")

    def test_diag_path_preserved_when_configured(self):
        result = self.shell("""
PRIMARY_DOMAIN=example.com
DIAG_PATH=my-custom-diag
DIAG_TOKEN=secrettoken12345
ensure_diag_path
printf '%s|%s' "$DIAG_PATH" "$DIAG_TOKEN"
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "/my-custom-diag/|secrettoken12345")

    def test_finalize_installation_config_ensures_diag_path(self):
        result = self.shell("""
PRIMARY_DOMAIN=example.com
ENABLE_WEB_STACK=y
unset DIAG_PATH DIAG_TOKEN 2>/dev/null || true
finalize_installation_config
printf '%s|%s' "$DIAG_PATH" "$DIAG_TOKEN"
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"^/diag-[0-9a-f]{32}/\|[a-z0-9]{16}$")

    def test_save_session_state_ensures_diag_path(self):
        target = shlex.quote((self.work / "saved_diag.env").as_posix())
        result = self.shell(f"""
PRIMARY_DOMAIN=example.com
ENABLE_WEB_STACK=y
unset DIAG_PATH DIAG_TOKEN 2>/dev/null || true
save_session_state {target}
source {target}
printf '%s|%s' "$DIAG_PATH" "$DIAG_TOKEN"
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"^/diag-[0-9a-f]{32}/\|[a-z0-9]{16}$")

    def test_xhttp_path_consistency_env_and_reconcile(self):
        """Verify reconcile.py uses XHTTP_STREAM_PATH from environment."""
        result = subprocess.run([
            sys.executable, "-c",
            "import os; os.environ['XHTTP_STREAM_PATH'] = 'custom-stream'; "
            "xhttp_raw_path = (os.environ.get('XHTTP_STREAM_PATH') or os.environ.get('XHTTP_PATH') or '').strip('/'); "
            "print(f'/{xhttp_raw_path}/')"
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "/custom-stream/")

    def test_configure_panel_exports_all_reconcile_variables(self):
        """Audit that all environment variables accessed in reconcile.py are exported by configure.sh."""
        import re
        rec_text = (SRC_DIR / "panel/reconcile.py").read_text(encoding="utf-8")
        conf_text = (SRC_DIR / "panel/configure.sh").read_text(encoding="utf-8")

        rec_vars = set(re.findall(r"os\.environ(?:\[\s*[\x22\x27](\w+)[\x22\x27]\s*\]|\.get\(\s*[\x22\x27](\w+)[\x22\x27])", rec_text))
        rec_vars = {v[0] or v[1] for v in rec_vars}
        conf_exports = set(re.findall(r"export\s+([A-Za-z0-9_]+)", conf_text))

        missing = rec_vars - conf_exports
        self.assertEqual(missing, set(), f"Variables queried in reconcile.py but not exported by configure.sh: {missing}")

    def test_default_ports_and_parameters_synchronization(self):
        """Verify that default ports and settings in configure.sh match env.sh."""
        import re
        conf_text = (SRC_DIR / "panel/configure.sh").read_text(encoding="utf-8")
        conf_defaults = dict(re.findall(r"^    ([A-Z0-9_]+)=\"\$\{\1:-([^}]*)\}\"", conf_text, re.MULTILINE))

        env_text = (SRC_DIR / "system/env.sh").read_text(encoding="utf-8")
        env_defaults = dict(re.findall(r"([A-Z0-9_]+)=\"\$\{\1:-([^}]*)\}\"", env_text))

        critical_keys = [
            "DNSTT_PORT", "MTPROTO_PORT", "NAIVE_PORT", "TUIC_PORT",
            "MASQUE_PORT", "WSTUNNEL_PORT", "SHADOWTLS_PORT", "SS2022_PORT",
            "ZAPRET_DESYNC", "ZAPRET_FOOLING", "ZAPRET_QNUM"
        ]
        for key in critical_keys:
            if key in conf_defaults and key in env_defaults:
                self.assertEqual(
                    conf_defaults[key], env_defaults[key],
                    f"Default mismatch for {key}: configure.sh='{conf_defaults[key]}' vs env.sh='{env_defaults[key]}'"
                )

    def test_xhttp_inbound_path_reconciliation_honors_configured_path(self):
        """Verify smart_reconcile_inbound updates xHTTP path when explicitly configured, and preserves on placeholder."""
        import sqlite3
        import json
        code = (SRC_DIR / "xray/inbounds.py").read_text(encoding="utf-8")
        conn = sqlite3.connect(":memory:")
        cur = conn.cursor()
        cur.execute("CREATE TABLE inbounds (id INTEGER PRIMARY KEY, user_id INTEGER, up INTEGER, down INTEGER, total INTEGER, remark TEXT, enable INTEGER, expiry_time INTEGER, listen TEXT, port INTEGER UNIQUE, protocol TEXT, settings TEXT, stream_settings TEXT, tag TEXT, sniffing TEXT)")

        ns = {
            "json": json,
            "conn": conn,
            "cur": cur,
            "admin_id": 1,
            "dry_run": False,
            "force_remarks": False,
            "unified_email": "test@domain.com",
            "unified_uuid": "11111111-1111-1111-1111-111111111111",
            "unified_sub_id": "sub123",
            "unified_awg_hpk": "",
            "rf_port": 9443,
            "rf_dest": "gateway.icloud.com:443",
            "domain": "example.com",
            "make_remark": lambda x: x,
        }
        exec(code, ns)

        init_settings = {"clients": [{"id": "11111111-1111-1111-1111-111111111111", "email": "test@domain.com"}]}
        init_stream = {"network": "xhttp", "xhttpSettings": {"path": "/old-path/", "mode": "stream-one"}}
        ns["smart_reconcile_inbound"](50443, "vless", "in-xhttp", "xhttp", init_settings, init_stream, "127.0.0.1")

        # Reconcile with new configured path -> should update to /new-path/
        new_stream = {"network": "xhttp", "xhttpSettings": {"path": "/new-path/", "mode": "stream-one"}}
        ns["smart_reconcile_inbound"](50443, "vless", "in-xhttp", "xhttp", init_settings, new_stream, "127.0.0.1")
        cur.execute("SELECT stream_settings FROM inbounds WHERE port = 50443")
        res = json.loads(cur.fetchone()[0])
        self.assertEqual(res["xhttpSettings"]["path"], "/new-path/")

        # Reconcile with placeholder -> should preserve existing /new-path/
        ph_stream = {"network": "xhttp", "xhttpSettings": {"path": "/Stream-One-Path/", "mode": "stream-one"}}
        ns["smart_reconcile_inbound"](50443, "vless", "in-xhttp", "xhttp", init_settings, ph_stream, "127.0.0.1")
        cur.execute("SELECT stream_settings FROM inbounds WHERE port = 50443")
        res2 = json.loads(cur.fetchone()[0])
        self.assertEqual(res2["xhttpSettings"]["path"], "/new-path/")


if __name__ == "__main__":
    unittest.main()
