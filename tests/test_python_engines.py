"""
tests/test_python_engines.py - Comprehensive Unit Tests for crypto_engine.py and backup_engine.py.
"""

import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

# Add project root and src/ to path
ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR))
sys.path.insert(0, str(ROOT_DIR / "src"))

from common import backup_engine, crypto_engine


class TestCryptoEngine(unittest.TestCase):
    def test_clamp_rfc7748(self):
        """Verify clamp clears lower 3 bits, clears highest bit, sets bit 254."""
        raw = bytearray([0xFF] * 32)
        clamped_int = crypto_engine.clamp(raw)
        clamped_bytes = clamped_int.to_bytes(32, "little")
        # byte 0: 0xFF & 248 = 248 = 0xF8
        self.assertEqual(clamped_bytes[0], 0xF8)
        # byte 31: (0xFF & 127) | 64 = 0x40 | 0x3F = 0x7F
        self.assertEqual(clamped_bytes[31], 0x7F)

    def test_x25519_rfc7748_test_vector(self):
        """Verify RFC 7748 Section 5.2 test vector for X25519 scalar multiplication."""
        scalar_hex = "a354b98b4614ff3abbd2aeac9cb20e984d6b181a3c50a65725f4577ebf997941"
        scalar_bytes = bytes.fromhex(scalar_hex)
        u_bytes = bytes.fromhex("0900000000000000000000000000000000000000000000000000000000000000")
        k = crypto_engine.clamp(scalar_bytes)
        u = int.from_bytes(u_bytes, "little")
        out_int = crypto_engine.x25519(k, u)
        out_bytes = out_int.to_bytes(32, "little")
        expected_hex = "d0e8b004e0562eef74ef64a8545df0de9d893cdaec1cf22beb4b979f5fbf0e32"
        self.assertEqual(out_bytes.hex(), expected_hex)

    def test_generate_wg_keypair_and_pubkey(self):
        """Verify WireGuard/AWG keypair generation and public key derivation."""
        priv, pub = crypto_engine.generate_wg_keypair()
        self.assertEqual(len(priv), 44)
        self.assertEqual(len(pub), 44)
        derived_pub = crypto_engine.curve25519_pubkey(priv)
        self.assertEqual(derived_pub, pub)

    def test_generate_reality_keypair_and_pubkey(self):
        """Verify Reality keypair generation (URL-safe base64, unpadded) and derivation."""
        priv, pub = crypto_engine.generate_reality_keypair()
        self.assertEqual(len(priv), 43)
        self.assertEqual(len(pub), 43)
        self.assertNotIn("=", priv)
        self.assertNotIn("=", pub)
        derived_pub = crypto_engine.curve25519_reality_pubkey(priv)
        self.assertEqual(derived_pub, pub)

    def test_generate_dnstt_keypair(self):
        """Verify DNSTT keypair generation returns 64-char hex strings."""
        priv_hex, pub_hex = crypto_engine.generate_dnstt_keypair()
        self.assertEqual(len(priv_hex), 64)
        self.assertEqual(len(pub_hex), 64)
        int(priv_hex, 16)
        int(pub_hex, 16)

    def test_clamp_rejects_invalid_length(self):
        """Verify clamp raises ValueError if input length != 32 bytes."""
        with self.assertRaises(ValueError):
            crypto_engine.clamp(b"too_short")
        with self.assertRaises(ValueError):
            crypto_engine.clamp(b"A" * 40)

    def test_curve25519_length_validation(self):
        """Verify curve25519_pubkey and reality_pubkey reject oversized and undersized decoded keys."""
        import base64
        # 16-byte key
        short_b64 = base64.b64encode(b"A" * 16).decode()
        self.assertIsNone(crypto_engine.curve25519_pubkey(short_b64))
        self.assertIsNone(crypto_engine.curve25519_reality_pubkey(short_b64))

        # 40-byte key
        long_b64 = base64.b64encode(b"A" * 40).decode()
        self.assertIsNone(crypto_engine.curve25519_pubkey(long_b64))
        self.assertIsNone(crypto_engine.curve25519_reality_pubkey(long_b64))

    def test_dnstt_pubkey_from_privkey_and_validation(self):
        """Verify dnstt_pubkey_from_privkey correctly derives public key from hex private key."""
        priv_hex, pub_hex = crypto_engine.generate_dnstt_keypair()
        derived_pub = crypto_engine.dnstt_pubkey_from_privkey(priv_hex)
        self.assertEqual(derived_pub, pub_hex)
        self.assertTrue(crypto_engine.validate_dnstt_pubkey(pub_hex))

        # Invalid lengths and formats
        self.assertIsNone(crypto_engine.dnstt_pubkey_from_privkey("1234"))
        self.assertIsNone(crypto_engine.dnstt_pubkey_from_privkey("not_hex!" * 4))
        self.assertFalse(crypto_engine.validate_dnstt_pubkey("1234"))
        self.assertFalse(crypto_engine.validate_dnstt_pubkey("z" * 64))
        self.assertFalse(crypto_engine.validate_dnstt_pubkey(12345))

    def test_crypto_engine_cli_subcommands(self):
        """Verify standalone CLI execution of crypto_engine.py."""
        import subprocess
        engine_file = ROOT_DIR / "src" / "common" / "crypto_engine.py"

        # wg_keypair & wg_pubkey
        res = subprocess.run([sys.executable, str(engine_file), "wg_keypair"], capture_output=True, text=True, check=True)
        parts = res.stdout.strip().split()
        self.assertEqual(len(parts), 2)
        priv, pub = parts
        res_pub = subprocess.run([sys.executable, str(engine_file), "wg_pubkey", priv], capture_output=True, text=True, check=True)
        self.assertEqual(res_pub.stdout.strip(), pub)

        # reality_keypair & reality_pubkey
        res = subprocess.run([sys.executable, str(engine_file), "reality_keypair"], capture_output=True, text=True, check=True)
        parts = res.stdout.strip().split()
        self.assertEqual(len(parts), 2)
        r_priv, r_pub = parts
        res_rpub = subprocess.run([sys.executable, str(engine_file), "reality_pubkey", r_priv], capture_output=True, text=True, check=True)
        self.assertEqual(res_rpub.stdout.strip(), r_pub)

        # dnstt_keypair to stdout and to files
        res = subprocess.run([sys.executable, str(engine_file), "dnstt_keypair"], capture_output=True, text=True, check=True)
        parts = res.stdout.strip().split()
        self.assertEqual(len(parts), 2)
        d_priv, d_pub = parts

        with tempfile.TemporaryDirectory() as td:
            kf = Path(td) / "srv.key"
            pf = Path(td) / "srv.pub"
            subprocess.run([sys.executable, str(engine_file), "dnstt_keypair", str(kf), str(pf)], check=True)
            self.assertTrue(kf.is_file())
            self.assertTrue(pf.is_file())
            file_priv = kf.read_text(encoding="utf-8").strip()
            file_pub = pf.read_text(encoding="utf-8").strip()
            self.assertEqual(len(file_priv), 64)
            self.assertEqual(len(file_pub), 64)
            res_dpub = subprocess.run([sys.executable, str(engine_file), "dnstt_pubkey", file_priv], capture_output=True, text=True, check=True)
            self.assertEqual(res_dpub.stdout.strip(), file_pub)


class TestBackupEngine(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.base = Path(self.temp_dir.name)

    def tearDown(self):
        import gc
        gc.collect()
        try:
            self.temp_dir.cleanup()
        except Exception:
            pass

    def test_verify_db_and_backup_db(self):
        """Verify SQLite integrity verification and online backup."""
        db_path = self.base / "test.db"
        conn = sqlite3.connect(str(db_path))
        conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);")
        conn.execute("INSERT INTO users (name) VALUES ('alice'), ('bob');")
        conn.commit()
        conn.close()

        self.assertTrue(backup_engine.verify_db(db_path))

        backup_dst = self.base / "nested" / "sub" / "backup.db"
        self.assertTrue(backup_engine.backup_db(db_path, backup_dst))
        self.assertTrue(backup_engine.verify_db(backup_dst))

        # Check backup content
        bconn = sqlite3.connect(str(backup_dst))
        rows = bconn.execute("SELECT name FROM users ORDER BY id;").fetchall()
        bconn.close()
        self.assertEqual([r[0] for r in rows], ["alice", "bob"])

        # Corrupted file verification
        corrupt_db = self.base / "corrupt.db"
        corrupt_db.write_text("not a sqlite database")
        self.assertFalse(backup_engine.verify_db(corrupt_db))

    def test_manifest_create_and_verify(self):
        """Verify backup manifest creation and SHA-256 integrity verification."""
        staging = self.base / "staging"
        staging.mkdir()
        (staging / "file1.txt").write_text("content 1", encoding="utf-8")
        (staging / "sub").mkdir()
        (staging / "sub" / "file2.txt").write_text("content 2", encoding="utf-8")

        self.assertTrue(backup_engine.create_manifest(staging))
        manifest_file = staging / "manifest.json"
        self.assertTrue(manifest_file.is_file())

        with open(manifest_file, "r", encoding="utf-8") as f:
            data = json.load(f)
        self.assertIn("file1.txt", data["files"])
        self.assertIn("sub/file2.txt", data["files"])

        # Verify untouched
        self.assertTrue(backup_engine.verify_manifest(staging))

        # Tamper with file
        (staging / "file1.txt").write_text("tampered content", encoding="utf-8")
        self.assertFalse(backup_engine.verify_manifest(staging))

    def test_manifest_path_traversal_rejection(self):
        """Verify verify_manifest strictly rejects entries attempting path traversal or absolute references."""
        staging = self.base / "traversal_staging"
        staging.mkdir()
        (staging / "valid.txt").write_text("valid content", encoding="utf-8")
        valid_hash = hashlib.sha256(b"valid content").hexdigest()

        # 1. Entry with '..' path traversal
        manifest_data = {
            "format_version": "2.0",
            "files": {
                "valid.txt": valid_hash,
                "../../outside.txt": "dummyhash"
            }
        }
        man_file = staging / "manifest.json"
        man_file.write_text(json.dumps(manifest_data), encoding="utf-8")
        self.assertFalse(backup_engine.verify_manifest(staging))

        # 2. Entry with absolute path
        manifest_data["files"] = {
            "valid.txt": valid_hash,
            "/etc/shadow": "dummyhash"
        }
        man_file.write_text(json.dumps(manifest_data), encoding="utf-8")
        self.assertFalse(backup_engine.verify_manifest(staging))

    def test_archive_create_extract_and_traversal_protection(self):
        """Verify safe archive creation and extraction with path traversal detection."""
        staging = self.base / "archive_staging"
        staging.mkdir()
        (staging / "data.bin").write_bytes(b"hello world")

        archive_file = self.base / "backup.tar.gz"
        self.assertTrue(backup_engine.create_archive(archive_file, staging))
        self.assertTrue(archive_file.is_file())

        unpack_dir = self.base / "unpacked"
        self.assertTrue(backup_engine.extract_archive(archive_file, unpack_dir))
        self.assertEqual((unpack_dir / "data.bin").read_bytes(), b"hello world")

        # Create malicious archive with path traversal
        evil_archive = self.base / "evil.tar.gz"
        with tarfile.open(evil_archive, "w:gz") as tar:
            ti = tarfile.TarInfo(name="../../evil.txt")
            data = b"evil content"
            ti.size = len(data)
            import io
            tar.addfile(ti, io.BytesIO(data))

        evil_target = self.base / "safe_extract"
        evil_target.mkdir()
        # Should safely reject extraction
        self.assertFalse(backup_engine.extract_archive(evil_archive, evil_target))
        self.assertFalse((self.base / "evil.txt").exists())

    def test_backup_engine_cli_subcommands(self):
        """Verify CLI dispatcher for backup_engine."""
        import subprocess
        engine_file = ROOT_DIR / "src" / "common" / "backup_engine.py"

        # 1. verify_db
        db_path = self.base / "cli_test.db"
        conn = sqlite3.connect(str(db_path))
        conn.executescript("CREATE TABLE t (x INT); INSERT INTO t VALUES (1);")
        conn.close()
        del conn

        res = subprocess.run([sys.executable, str(engine_file), "verify_db", str(db_path)], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0)

        # 2. backup_db
        dst_db = self.base / "cli_backup.db"
        res = subprocess.run([sys.executable, str(engine_file), "backup_db", str(db_path), str(dst_db)], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0)
        self.assertTrue(dst_db.is_file())

        # 3. create_manifest and verify_manifest
        staging = self.base / "cli_staging"
        staging.mkdir()
        (staging / "sample.txt").write_text("sample data")
        res = subprocess.run([sys.executable, str(engine_file), "create_manifest", str(staging)], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0)
        self.assertTrue((staging / "manifest.json").is_file())

        res = subprocess.run([sys.executable, str(engine_file), "verify_manifest", str(staging)], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0)

        # 4. create_archive and extract_archive
        archive_tar = self.base / "cli_test.tar.gz"
        res = subprocess.run([sys.executable, str(engine_file), "create_archive", str(archive_tar), str(staging)], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0)
        self.assertTrue(archive_tar.is_file())

        extract_dst = self.base / "cli_extracted"
        res = subprocess.run([sys.executable, str(engine_file), "extract_archive", str(archive_tar), str(extract_dst)], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0)
        self.assertTrue((extract_dst / "sample.txt").is_file())

    def test_isolated_execution_fallbacks(self):
        """Test keys.py and manage_clients.py import cleanly in isolated process with arbitrary cwd."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            # 1. Test keys.py
            code_keys = """
import sys, os
sys.path.insert(0, sys.argv[1])
import keys
priv, pub = keys.generate_reality_keypair()
assert len(priv) == 43 and len(pub) == 43
dpriv, dpub = keys.generate_dnstt_keypair()
assert len(dpriv) == 64 and len(dpub) == 64
print('KEYS_OK')
"""
            res_keys = subprocess.run(
                [sys.executable, "-c", code_keys, str(ROOT_DIR / "src" / "xray")],
                cwd=tmp_dir, capture_output=True, text=True
            )
            self.assertEqual(res_keys.returncode, 0, f"keys.py isolation failed: {res_keys.stderr}")
            self.assertIn("KEYS_OK", res_keys.stdout)

            # 2. Test manage_clients.py with crypto_engine present in target directory
            target_awg = Path(tmp_dir) / "awg"
            target_awg.mkdir()
            import shutil
            shutil.copy(str(ROOT_DIR / "src" / "awg" / "manage_clients.py"), str(target_awg / "manage_clients.py"))
            shutil.copy(str(ROOT_DIR / "src" / "common" / "crypto_engine.py"), str(target_awg / "crypto_engine.py"))
            code_awg = """
import sys
sys.path.insert(0, sys.argv[1])
import manage_clients
priv, pub = manage_clients.generate_wg_keypair()
assert len(priv) == 44 and len(pub) == 44
print('AWG_OK')
"""
            res_awg = subprocess.run(
                [sys.executable, "-c", code_awg, str(target_awg)],
                cwd=tmp_dir, capture_output=True, text=True
            )
            self.assertEqual(res_awg.returncode, 0, f"manage_clients.py isolation failed: {res_awg.stderr}")
            self.assertIn("AWG_OK", res_awg.stdout)

    def test_reconcile_defines_generate_dnstt_keypair(self):
        """Verify panel/reconcile.py properly imports and defines generate_dnstt_keypair."""
        reconcile_src = (ROOT_DIR / "src" / "panel" / "reconcile.py").read_text(encoding="utf-8")
        self.assertIn("generate_dnstt_keypair", reconcile_src)
        import ast
        tree = ast.parse(reconcile_src)
        defs = set()
        for n in ast.walk(tree):
            if isinstance(n, ast.FunctionDef):
                defs.add(n.name)
            elif isinstance(n, (ast.Import, ast.ImportFrom)):
                defs.update(a.name for a in n.names)
        self.assertIn("generate_dnstt_keypair", defs, "generate_dnstt_keypair must be imported/defined in reconcile.py")

    def test_awg_setup_deploys_crypto_engine(self):
        """Verify src/awg/setup.sh copies and embeds crypto_engine.py alongside manage_clients.py."""
        setup_sh = (ROOT_DIR / "src" / "awg" / "setup.sh").read_text(encoding="utf-8")
        self.assertIn('"$src_crypto" "$awg_dir/crypto_engine.py"', setup_sh)
        self.assertIn('EOF_AWG_CRYPTO', setup_sh)


if __name__ == "__main__":
    unittest.main()

