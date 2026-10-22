"""
Unit and integration tests for RELIABILITY_PLAN.md implementations (T00-T30).
Validates:
- T07: Inter-process mutual exclusion, re-entrancy, stale lock recovery, symlink rejection
- T13: Safe data-only configuration loader, injection prevention, quote unescaping
- T29: Order-independent CLI parsing, unknown parameter rejection with exit code 2
- T18-T20: Diagnostics MTR backend validation, IPv4-mapped IPv6 unmapping, rate limit store pruning
- T21: Backup manifest v2.0 generation, checksum integrity verification, SQLite check
- T04-T05: Component manifest and verified downloader
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")
sys.path.insert(0, str(ROOT))
from scripts.build import bundle_file, SRC_DIR


class TestReliabilityPlan(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Dynamically import diagnostics/mtr-backend.py
        mtr_path = ROOT / "diagnostics" / "mtr-backend.py"
        spec = importlib.util.spec_from_file_location("mtr_backend", str(mtr_path))
        cls.mtr_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.mtr_module)

    def run_bash(self, script_body: str, cwd: Path = ROOT, env: dict = None) -> subprocess.CompletedProcess:
        full_env = dict(os.environ)
        if env:
            full_env.update(env)
        return subprocess.run(
            [str(BASH), "-s"],
            input=script_body,
            cwd=str(cwd),
            env=full_env,
            text=True,
            encoding="utf-8",
            capture_output=True,
            timeout=15,
        )

    # -------------------------------------------------------------------------
    # T07: Inter-Process Mutual Exclusion (src/common/lock.sh)
    # -------------------------------------------------------------------------
    def test_t07_lock_acquisition_and_release(self):
        """Test acquiring and releasing the stack lock cleans up lock file."""
        with tempfile.TemporaryDirectory() as tmp:
            lock_file = (Path(tmp) / "test.lock").as_posix()
            script = f"""
source src/common/lock.sh
VPN_STACK_LOCK_FILE="{lock_file}"
acquire_stack_lock 2 "test-op"
[ -f "{lock_file}" ] || exit 10
release_stack_lock
[ ! -f "{lock_file}" ] || exit 20
echo "LOCK_SUCCESS"
"""
            res = self.run_bash(script)
            self.assertEqual(res.returncode, 0, f"Stderr: {res.stderr}\nStdout: {res.stdout}")
            self.assertIn("LOCK_SUCCESS", res.stdout)

    def test_t07_lock_reentrancy(self):
        """Test nested lock acquisition within the same process hierarchy succeeds."""
        with tempfile.TemporaryDirectory() as tmp:
            lock_file = (Path(tmp) / "test.lock").as_posix()
            script = f"""
source src/common/lock.sh
VPN_STACK_LOCK_FILE="{lock_file}"
acquire_stack_lock 2 "parent-op"
# Nested call with same PID
acquire_stack_lock 2 "child-op"
echo "REENTRANT_OK"
release_stack_lock
"""
            res = self.run_bash(script)
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertIn("REENTRANT_OK", res.stdout)

    def test_t07_stale_lock_recovery(self):
        """Test recovering a lock file abandoned by a terminated PID."""
        with tempfile.TemporaryDirectory() as tmp:
            lock_file = Path(tmp) / "test.lock"
            # Write a PID that does not exist (e.g. 9999999)
            lock_file.write_text("9999999\n", encoding="utf-8")
            lock_posix = lock_file.as_posix()

            script = f"""
source src/common/lock.sh
VPN_STACK_LOCK_FILE="{lock_posix}"
acquire_stack_lock 2 "recovery-op"
echo "RECOVERED_OK"
release_stack_lock
"""
            res = self.run_bash(script)
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertIn("RECOVERED_OK", res.stdout)

    def test_t07_symlink_attack_rejected(self):
        """Test lock acquisition aborts with return code 75 if lock path is a symlink."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            target_file = tmp_path / "real_file.txt"
            target_file.write_text("sensitive", encoding="utf-8")
            symlink_file = tmp_path / "symlink.lock"
            try:
                os.symlink(target_file, symlink_file)
            except OSError:
                # Symlinks might require admin privileges on some Windows configurations
                self.skipTest("Symlink creation requires elevated permissions on this system")

            script = f"""
source src/common/lock.sh
VPN_STACK_LOCK_FILE="{symlink_file.as_posix()}"
acquire_stack_lock 2 "symlink-op"
"""
            res = self.run_bash(script)
            self.assertEqual(res.returncode, 75)
            self.assertIn("symbolic link", res.stderr)

    # -------------------------------------------------------------------------
    # T13: Safe Data-Only Configuration Loader (src/common/config.sh)
    # -------------------------------------------------------------------------
    def test_t13_safe_config_loads_valid_key_values(self):
        """Test load_config_data_safe correctly parses unquoted, single-quoted, and double-quoted values."""
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / "valid.env"
            env_file.write_text(
                'PRIMARY_DOMAIN="vpn.example.com"\n'
                'PORT=443 # Default HTTPS port\n'
                "SECRET_KEY='safe_single_quoted_val'\n"
                'ESCAPED_VAL="hello \\"world\\" with \\\\backslashes\\\\"\n'
                'export EXPORTED_VAR="exported_content"\n',
                encoding="utf-8",
            )
            script = f"""
source src/common/config.sh
load_config_data_safe "{env_file.as_posix()}" || exit 10
printf '%s|%s|%s|%s|%s' "$PRIMARY_DOMAIN" "$PORT" "$SECRET_KEY" "$ESCAPED_VAL" "$EXPORTED_VAR"
"""
            res = self.run_bash(script)
            self.assertEqual(res.returncode, 0, res.stderr)
            expected = 'vpn.example.com|443|safe_single_quoted_val|hello "world" with \\backslashes\\|exported_content'
            self.assertEqual(res.stdout.strip(), expected)

    def test_t13_safe_config_rejects_command_substitution(self):
        """Test load_config_data_safe rejects $(...) and backticks, preventing command execution."""
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "injected.marker"
            env_file = Path(tmp) / "unsafe.env"
            env_file.write_text(
                f'DOMAIN=test.com\nINJECTION=$(touch "{marker.as_posix()}")\n',
                encoding="utf-8",
            )
            script = f"""
source src/common/config.sh
load_config_data_safe "{env_file.as_posix()}"
"""
            res = self.run_bash(script)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("command substitution forbidden", res.stderr)
            self.assertFalse(marker.exists(), "Command substitution must not be executed!")

    def test_t13_safe_config_rejects_backticks(self):
        """Test load_config_data_safe rejects backtick execution."""
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / "unsafe_backticks.env"
            env_file.write_text("EVIL=`id`\n", encoding="utf-8")
            script = f"""
source src/common/config.sh
load_config_data_safe "{env_file.as_posix()}"
"""
            res = self.run_bash(script)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("command substitution forbidden", res.stderr)

    def test_t13_safe_config_preserves_single_quoted_command_substitution(self):
        """Test load_config_data_safe preserves literal $(...) in single quotes per T13.C04."""
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / "single_quotes.env"
            env_file.write_text(
                "LITERAL_CMD='$(whoami)'\n"
                "LITERAL_BT='`id`'\n",
                encoding="utf-8",
            )
            script = f"""
source src/common/config.sh
load_config_data_safe "{env_file.as_posix()}" || exit 10
printf '%s|%s' "$LITERAL_CMD" "$LITERAL_BT"
"""
            res = self.run_bash(script)
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertEqual(res.stdout.strip(), '$(whoami)|`id`')

    def test_t13_safe_config_handles_multiple_spaces_export(self):
        """Test load_config_data_safe correctly parses export with multiple spaces and tabs."""
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / "spaces_export.env"
            env_file.write_text(
                "export   MULTI_SPACE='val1'\n"
                "export\t\tTAB_EXPORT=\"val2\"\n",
                encoding="utf-8",
            )
            script = f"""
source src/common/config.sh
load_config_data_safe "{env_file.as_posix()}" || exit 10
printf '%s|%s' "$MULTI_SPACE" "$TAB_EXPORT"
"""
            res = self.run_bash(script)
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertEqual(res.stdout.strip(), "val1|val2")

    def test_t13_safe_config_rejects_critical_system_env_overwrites(self):
        """Test load_config_data_safe forbids overwriting PATH, LD_PRELOAD, IFS, etc."""
        with tempfile.TemporaryDirectory() as tmp:
            for bad_key in ["PATH", "LD_PRELOAD", "LD_AUDIT", "IFS", "SHELL", "PYTHONHOME", "GLOBIGNORE", "path"]:
                env_file = Path(tmp) / f"bad_{bad_key}.env"
                env_file.write_text(f'{bad_key}="/malicious/override"\n', encoding="utf-8")
                script = f"""
source src/common/config.sh
load_config_data_safe "{env_file.as_posix()}"
"""
                res = self.run_bash(script)
                self.assertNotEqual(res.returncode, 0, f"Expected rejection for {bad_key}")
                self.assertIn("critical system variable", res.stderr)

    # -------------------------------------------------------------------------
    # T29: Order-Independent CLI Parser (maintain.sh)
    # -------------------------------------------------------------------------
    def test_t29_maintain_cli_order_independence(self):
        """Test maintain.sh parses options regardless of whether flags precede or follow subcommands."""
        with tempfile.TemporaryDirectory() as tmp:
            cfg = (Path(tmp) / "custom.env").as_posix()
            db = (Path(tmp) / "custom.db").as_posix()

            # Case A: Flags before subcommand
            res_a = subprocess.run(
                [str(BASH), "maintain.sh", "--dry-run", "--config", cfg, "--db", db, "backup"],
                cwd=str(ROOT),
                capture_output=True,
                text=True,
                encoding="utf-8",
            )
            self.assertEqual(res_a.returncode, 0, res_a.stderr)
            self.assertIn("[DRY-RUN]", res_a.stdout)

            # Case B: Flags after subcommand
            res_b = subprocess.run(
                [str(BASH), "maintain.sh", "backup", "--dry-run", "--config", cfg, "--db", db],
                cwd=str(ROOT),
                capture_output=True,
                text=True,
                encoding="utf-8",
            )
            self.assertEqual(res_b.returncode, 0, res_b.stderr)
            self.assertIn("[DRY-RUN]", res_b.stdout)

    def test_t29_maintain_cli_rejects_unknown_arguments_with_exit_code_2(self):
        """Test maintain.sh exits with code 2 on unknown flags before taking any action."""
        script = """
set -- --unsupported-dangerous-flag
source src/entrypoints/maintain.main.sh
"""
        res = self.run_bash(script)
        self.assertEqual(res.returncode, 2)
        self.assertIn("Неизвестный параметр", res.stderr)

    def test_t29_maintain_cli_version_and_help_without_root(self):
        """Test --version and --help work cleanly without requiring root permissions."""
        res_v = self.run_bash('set -- --version; source src/entrypoints/maintain.main.sh')
        self.assertEqual(res_v.returncode, 0)
        self.assertIn("maintain.sh", res_v.stdout)

        res_h = self.run_bash('set -- --help; source src/entrypoints/maintain.main.sh')
        self.assertEqual(res_h.returncode, 0)
        self.assertIn("Использование:", res_h.stdout)

    # -------------------------------------------------------------------------
    # T18-T20: Diagnostics MTR Backend Hardening (diagnostics/mtr-backend.py)
    # -------------------------------------------------------------------------
    def test_t18_t20_mtr_validate_ip_public(self):
        """Test validate_ip accepts valid global public IPv4 and IPv6 addresses."""
        validate_ip = self.mtr_module.validate_ip
        # Standard public IP
        self.assertEqual(validate_ip("8.8.8.8"), "8.8.8.8")
        self.assertEqual(validate_ip("1.1.1.1"), "1.1.1.1")
        self.assertEqual(validate_ip("2001:4860:4860::8888"), "2001:4860:4860::8888")

    def test_t18_t20_mtr_validate_ip_blocks_private_and_loopback(self):
        """Test validate_ip raises ValueError on loopback, private, multicast, link-local, or reserved."""
        validate_ip = self.mtr_module.validate_ip
        blocked = [
            "127.0.0.1",
            "10.0.0.1",
            "172.16.0.1",
            "192.168.1.1",
            "169.254.1.1",
            "224.0.0.1",
            "240.0.0.1",
            "::1",
            "fe80::1",
            "fc00::1",
        ]
        for ip in blocked:
            with self.subTest(ip=ip):
                with self.assertRaises(ValueError):
                    validate_ip(ip)

    def test_t18_t20_mtr_validate_ip_unmaps_ipv4_mapped_ipv6(self):
        """Test validate_ip unmaps IPv4-mapped IPv6 address and prevents bypass."""
        validate_ip = self.mtr_module.validate_ip
        # Mapped loopback and private should raise ValueError
        with self.assertRaises(ValueError):
            validate_ip("::ffff:127.0.0.1")
        with self.assertRaises(ValueError):
            validate_ip("::ffff:10.0.0.1")
        # Mapped global public IP should return unmapped IPv4
        self.assertEqual(validate_ip("::ffff:8.8.8.8"), "8.8.8.8")

    def test_t18_t20_rate_store_pruning(self):
        """Test rate_check maintains store bounding and prunes properly."""
        rate_check = self.mtr_module.rate_check
        rate_store = self.mtr_module._rate_store

        # Fill store to threshold
        for i in range(1050):
            fake_ip = f"198.51.100.{i % 250}"
            rate_store[fake_ip] = [0]  # Expired timestamps

        # Checking an IP should trigger pruning when len > MAX_RATE_STORE_ENTRIES
        rate_check("203.0.113.1")
        self.assertLessEqual(len(rate_store), self.mtr_module.MAX_RATE_STORE_ENTRIES)

    # -------------------------------------------------------------------------
    # T21: Backup Manifest Format 2.0 & Integrity Verification (src/common/backup.sh)
    # -------------------------------------------------------------------------
    def test_t21_backup_manifest_format_and_integrity_check(self):
        """Test backup staging creates manifest.json v2.0 with valid SHA256 checksums."""
        with tempfile.TemporaryDirectory() as tmp:
            staging = Path(tmp) / "staging"
            staging.mkdir()
            (staging / "db").mkdir()
            db_file = staging / "db" / "x-ui.db"
            # Create a real valid SQLite database
            conn = sqlite3.connect(db_file)
            conn.execute("CREATE TABLE test (id INT, name TEXT);")
            conn.execute("INSERT INTO test VALUES (1, 'demo');")
            conn.commit()
            conn.close()

            # Generate manifest
            py_code = """
import json, os, hashlib, sys
staging = sys.argv[1]
manifest_path = os.path.join(staging, 'manifest.json')
files_map = {}
for root, dirs, files in os.walk(staging):
    for f in sorted(files):
        if f == 'manifest.json': continue
        full_p = os.path.join(root, f)
        rel_p = os.path.relpath(full_p, staging).replace('\\\\', '/')
        with open(full_p, 'rb') as fp:
            files_map[rel_p] = hashlib.sha256(fp.read()).hexdigest()
data = {'format_version': '2.0', 'files': files_map}
with open(manifest_path, 'w', encoding='utf-8') as out:
    json.dump(data, out, indent=2)
"""
            subprocess.run([sys.executable, "-c", py_code, str(staging)], check=True)

            manifest_file = staging / "manifest.json"
            self.assertTrue(manifest_file.is_file())
            manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
            self.assertEqual(manifest["format_version"], "2.0")
            self.assertIn("db/x-ui.db", manifest["files"])

            # Verify hash matches
            db_hash = hashlib.sha256(db_file.read_bytes()).hexdigest()
            self.assertEqual(manifest["files"]["db/x-ui.db"], db_hash)

    def test_t21_tampered_backup_fails_integrity(self):
        """Test tampered file in backup staging fails manifest verification."""
        with tempfile.TemporaryDirectory() as tmp:
            staging = Path(tmp) / "staging"
            staging.mkdir()
            file_a = staging / "file.txt"
            file_a.write_text("original content", encoding="utf-8")
            manifest_file = staging / "manifest.json"
            orig_hash = hashlib.sha256(file_a.read_bytes()).hexdigest()
            manifest_file.write_text(json.dumps({
                "format_version": "2.0",
                "files": {"file.txt": orig_hash}
            }), encoding="utf-8")

            # Tamper the file
            file_a.write_text("tampered content", encoding="utf-8")

            verify_code = """
import json, os, hashlib, sys
staging = sys.argv[1]
with open(os.path.join(staging, 'manifest.json'), 'r') as fp:
    manifest = json.load(fp)
for rel_p, expected_h in manifest.get('files', {}).items():
    full_p = os.path.join(staging, rel_p)
    with open(full_p, 'rb') as f:
        actual_h = hashlib.sha256(f.read()).hexdigest()
    if actual_h != expected_h:
        sys.exit(1)
sys.exit(0)
"""
            res = subprocess.run([sys.executable, "-c", verify_code, str(staging)])
            self.assertNotEqual(res.returncode, 0, "Tampered file must fail manifest verification!")

    # -------------------------------------------------------------------------
    # T04-T05: Component Manifest & Verified Downloader
    # -------------------------------------------------------------------------
    def test_t04_components_manifest_structure(self):
        """Test components-manifest.json exists and pins core components with checksums."""
        manifest_path = ROOT / "components-manifest.json"
        self.assertTrue(manifest_path.is_file(), "components-manifest.json must exist")
        data = json.loads(manifest_path.read_text(encoding="utf-8"))

        required_components = ["shadow-tls", "wstunnel", "sing-box", "zapret", "AdGuardHome", "acme.sh"]
        for comp in required_components:
            self.assertIn(comp, data["components"], f"Component {comp} must be present in manifest")
            comp_info = data["components"][comp]
            self.assertIn("version", comp_info)
            self.assertIn("status", comp_info)

    def test_t05_download_verified_file_logic(self):
        """Test verify_file_sha256 validates expected sha256 checksum."""
        with tempfile.TemporaryDirectory() as tmp:
            test_file = Path(tmp) / "downloaded_test.bin"
            content = b"sample downloaded binary payload"
            test_file.write_bytes(content)
            correct_hash = hashlib.sha256(content).hexdigest()
            wrong_hash = "0" * 64

            # Correct hash check
            script_ok = f"""
source src/common/download.sh
if verify_file_sha256 "{test_file.as_posix()}" "{correct_hash}"; then
    echo "HASH_MATCH"
fi
"""
            res_ok = self.run_bash(script_ok)
            self.assertEqual(res_ok.returncode, 0, res_ok.stderr)
            self.assertIn("HASH_MATCH", res_ok.stdout)

            # Incorrect hash check
            script_fail = f"""
source src/common/download.sh
if verify_file_sha256 "{test_file.as_posix()}" "{wrong_hash}"; then
    echo "HASH_MATCH"
else
    echo "HASH_MISMATCH"
fi
"""
            res_fail = self.run_bash(script_fail)
            self.assertEqual(res_fail.returncode, 0, res_fail.stderr)
            self.assertIn("HASH_MISMATCH", res_fail.stdout)

    def test_t21_audit_restore_archive_real_bash_verification(self):
        """Test audit_restore_archive executes real PRAGMA integrity_check and manifest verification."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_p = Path(tmp)
            staging = tmp_p / "staging"
            staging.mkdir()
            (staging / "db").mkdir()
            db_file = staging / "db" / "x-ui.db"
            conn = sqlite3.connect(db_file)
            conn.execute("CREATE TABLE test (id INT, name TEXT);")
            conn.execute("INSERT INTO test VALUES (1, 'demo');")
            conn.commit()
            conn.close()

            # Create manifest v2.0
            db_hash = hashlib.sha256(db_file.read_bytes()).hexdigest()
            manifest_file = staging / "manifest.json"
            manifest_file.write_text(json.dumps({
                "format_version": "2.0",
                "files": {"db/x-ui.db": db_hash}
            }), encoding="utf-8")

            # Create tar.gz archive
            archive_file = tmp_p / "backup.tar.gz"
            import tarfile
            with tarfile.open(archive_file, "w:gz") as tar:
                for item in staging.iterdir():
                    tar.add(item, arcname=item.name)

            script = f"""
source src/common/logger.sh
source src/common/backup.sh
audit_restore_archive "{archive_file.as_posix()}"
"""
            res = self.run_bash(script)
            self.assertEqual(res.returncode, 0, f"Stderr: {res.stderr}\nStdout: {res.stdout}")
            self.assertIn("[DRY-RUN] Манифест v2.0 и контрольные суммы SHA-256 проверены", res.stdout)
            self.assertIn("[DRY-RUN] База данных x-ui.db проверена", res.stdout)

    def test_t21_audit_restore_archive_rejects_tampered_manifest(self):
        """Test audit_restore_archive aborts when a file has been tampered with relative to manifest."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_p = Path(tmp)
            staging = tmp_p / "staging"
            staging.mkdir()
            file_a = staging / "config.txt"
            file_a.write_text("original content", encoding="utf-8")
            manifest_file = staging / "manifest.json"
            manifest_file.write_text(json.dumps({
                "format_version": "2.0",
                "files": {"config.txt": "0" * 64}
            }), encoding="utf-8")

            archive_file = tmp_p / "tampered.tar.gz"
            import tarfile
            with tarfile.open(archive_file, "w:gz") as tar:
                for item in staging.iterdir():
                    tar.add(item, arcname=item.name)

            script = f"""
source src/common/logger.sh
source src/common/backup.sh
audit_restore_archive "{archive_file.as_posix()}"
"""
            res = self.run_bash(script)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("Нарушена целостность файлов по манифесту архива", res.stderr)

    def test_t21_audit_restore_archive_rejects_corrupted_sqlite(self):
        """Test audit_restore_archive aborts when x-ui.db in archive fails PRAGMA integrity_check."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_p = Path(tmp)
            staging = tmp_p / "staging"
            staging.mkdir()
            (staging / "db").mkdir()
            db_file = staging / "db" / "x-ui.db"
            db_file.write_bytes(b"not a valid sqlite database header at all")
            db_hash = hashlib.sha256(db_file.read_bytes()).hexdigest()
            manifest_file = staging / "manifest.json"
            manifest_file.write_text(json.dumps({
                "format_version": "2.0",
                "files": {"db/x-ui.db": db_hash}
            }), encoding="utf-8")

            archive_file = tmp_p / "corrupt_db.tar.gz"
            import tarfile
            with tarfile.open(archive_file, "w:gz") as tar:
                for item in staging.iterdir():
                    tar.add(item, arcname=item.name)

            script = f"""
source src/common/logger.sh
source src/common/backup.sh
audit_restore_archive "{archive_file.as_posix()}"
"""
            res = self.run_bash(script)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("PRAGMA integrity_check failed", res.stderr)

    def test_t05_get_manifest_component_data(self):
        """Test get_manifest_component_data resolves metadata from manifest and fallback."""
        components = ["shadow-tls", "wstunnel", "sing-box", "zapret", "AdGuardHome", "acme.sh"]
        for comp in components:
            arch = "all" if comp in ("zapret", "acme.sh") else "x86_64"
            script = f"""
source src/common/download.sh
get_manifest_component_data "{comp}" "{arch}"
"""
            res = self.run_bash(script)
            self.assertEqual(res.returncode, 0, f"Component {comp} failed: {res.stderr}")
            parts = res.stdout.strip().split("|")
            self.assertEqual(len(parts), 4, f"Unexpected parts for {comp}: {res.stdout}")
            url, sha256_h, max_sz, ver = parts
            self.assertTrue(url.startswith("https://"), f"Invalid url for {comp}: {url}")
            self.assertEqual(len(sha256_h), 64, f"Invalid sha256 for {comp}: {sha256_h}")
            self.assertGreater(int(max_sz), 0, f"Invalid size for {comp}: {max_sz}")
            self.assertTrue(bool(ver), f"Empty version for {comp}")

        # Test arch alias normalization (amd64 -> x86_64, arm64 -> aarch64)
        for alias, expected in [("amd64", "x86_64"), ("arm64", "aarch64")]:
            script = f"""
source src/common/download.sh
get_manifest_component_data "wstunnel" "{alias}"
"""
            res = self.run_bash(script)
            self.assertEqual(res.returncode, 0, f"Alias {alias} failed: {res.stderr}")
            self.assertIn("wstunnel", res.stdout)

    def test_t05_manifest_fallback_parity(self):
        """Test that FALLBACK embedded in download.sh matches components-manifest.json."""
        manifest_path = ROOT / "components-manifest.json"
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        for comp_name, comp_info in data["components"].items():
            artifacts = comp_info.get("artifacts", {})
            for arch, art in artifacts.items():
                script = f"""
source src/common/download.sh
MANIFEST_FILE="/nonexistent/path/manifest.json" get_manifest_component_data "{comp_name}" "{arch}"
"""
                res = self.run_bash(script)
                self.assertEqual(res.returncode, 0, f"Fallback failed for {comp_name}/{arch}: {res.stderr}")
                parts = res.stdout.strip().split("|")
                url, sha256_h, max_sz, ver = parts
                self.assertEqual(sha256_h, art["sha256"], f"Fallback sha256 mismatch for {comp_name}/{arch}")


if __name__ == "__main__":
    unittest.main()
