"""
src/common/backup_engine.py - Unified Backup & Verification Engine.

Structured Python engine for SQLite WAL-safe live backups, integrity verification,
SHA-256 backup manifest generation/verification, and secure tarfile archive handling.
"""

import hashlib
import json
import os
import sqlite3
import sys
import tarfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Union


def _sha256_file(file_path: Union[str, Path]) -> Optional[str]:
    """Calculate SHA-256 digest of a file in memory-efficient 64KB chunks."""
    h = hashlib.sha256()
    try:
        with open(str(file_path), "rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None


def verify_db(db_path: Union[str, Path]) -> bool:
    """Verify SQLite database integrity using PRAGMA integrity_check."""
    p = str(db_path)
    if not os.path.isfile(p) or os.path.getsize(p) == 0:
        return False
    conn = None
    try:
        abs_p = os.path.abspath(p)
        try:
            conn = sqlite3.connect(f"file:{abs_p}?mode=ro", uri=True, timeout=10.0)
        except Exception:
            conn = sqlite3.connect(p, timeout=10.0)
        res = conn.execute("PRAGMA integrity_check;").fetchall()
        return bool(res and res[0][0] == "ok")
    except Exception:
        return False
    finally:
        if conn:
            try:
                conn.close()
            except Exception:
                pass


def backup_db(src_path: Union[str, Path], dst_path: Union[str, Path]) -> bool:
    """Perform atomic, WAL-safe online backup of an SQLite database."""
    src_p = str(src_path)
    dst_p = str(dst_path)

    if not os.path.isfile(src_p):
        return False

    # Ensure parent directory for destination exists
    dst_dir = os.path.dirname(os.path.abspath(dst_p))
    if dst_dir:
        os.makedirs(dst_dir, exist_ok=True)

    src_conn = None
    dst_conn = None
    try:
        try:
            src_conn = sqlite3.connect(f"file:{src_p}?mode=ro", uri=True, timeout=10.0)
        except Exception:
            src_conn = sqlite3.connect(src_p, timeout=10.0)

        dst_conn = sqlite3.connect(dst_p, timeout=10.0)
        with dst_conn:
            src_conn.backup(dst_conn)
        dst_conn.close()
        dst_conn = None
        src_conn.close()
        src_conn = None

        return verify_db(dst_p)
    except Exception:
        try:
            if os.path.exists(dst_p):
                os.remove(dst_p)
        except OSError:
            pass
        return False
    finally:
        if dst_conn:
            try:
                dst_conn.close()
            except Exception:
                pass
        if src_conn:
            try:
                src_conn.close()
            except Exception:
                pass


def create_manifest(staging_dir: Union[str, Path], output_path: Optional[Union[str, Path]] = None) -> bool:
    """Generate manifest.json with SHA-256 hashes of all files in staging directory."""
    staging = str(staging_dir)
    manifest_path = str(output_path) if output_path else os.path.join(staging, "manifest.json")
    files_map: Dict[str, str] = {}

    for root, _, files in os.walk(staging):
        for f in sorted(files):
            if f == "manifest.json":
                continue
            full_p = os.path.join(root, f)
            rel_p = os.path.relpath(full_p, staging).replace("\\", "/")
            h = _sha256_file(full_p)
            if h is not None:
                files_map[rel_p] = h

    created_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    data = {
        "format_version": "2.0",
        "project_version": os.environ.get("SCRIPT_VERSION", "__VERSION__"),
        "created_at": created_iso,
        "db_path": os.environ.get("DB_PATH", "/etc/x-ui/x-ui.db"),
        "files": files_map,
    }

    try:
        with open(manifest_path, "w", encoding="utf-8") as out:
            json.dump(data, out, indent=2)
        return True
    except Exception:
        return False


def verify_manifest(staging_dir: Union[str, Path], manifest_path: Optional[Union[str, Path]] = None) -> bool:
    """Verify integrity of backed up files against manifest.json with path traversal protection."""
    staging = str(staging_dir)
    man_p = str(manifest_path) if manifest_path else os.path.join(staging, "manifest.json")

    if not os.path.isfile(man_p):
        print(f"[ERROR] Manifest file not found: {man_p}", file=sys.stderr)
        return False

    try:
        with open(man_p, "r", encoding="utf-8") as fp:
            manifest = json.load(fp)
    except Exception as e:
        print(f"[ERROR] Failed to parse manifest {man_p}: {e}", file=sys.stderr)
        return False

    staging_real = os.path.realpath(staging)

    for rel_p, expected_h in manifest.get("files", {}).items():
        # Security: reject entries attempting path traversal or absolute references
        norm_rel = rel_p.replace("\\", "/")
        if os.path.isabs(norm_rel) or norm_rel.startswith("/") or ".." in norm_rel.split("/"):
            print(f"[ERROR] Path traversal detected in manifest entry: {rel_p}", file=sys.stderr)
            return False

        full_p = os.path.realpath(os.path.join(staging, rel_p))
        if not full_p.startswith(staging_real + os.sep) and full_p != staging_real:
            print(f"[ERROR] Manifest entry escapes staging directory: {rel_p}", file=sys.stderr)
            return False

        if not os.path.isfile(full_p):
            print(f"[ERROR] Missing backed up file: {rel_p}", file=sys.stderr)
            return False

        actual_h = _sha256_file(full_p)
        if actual_h is None or actual_h != expected_h:
            print(f"[ERROR] Checksum mismatch for {rel_p}: expected {expected_h}, got {actual_h}", file=sys.stderr)
            return False

    return True


def create_archive(archive_path: Union[str, Path], staging_dir: Union[str, Path]) -> bool:
    """Create gzip-compressed tar archive from items in staging directory."""
    archive = str(archive_path)
    staging = str(staging_dir)

    try:
        with tarfile.open(archive, "w:gz") as tar:
            for item in sorted(os.listdir(staging)):
                tar.add(os.path.join(staging, item), arcname=item)
        return True
    except Exception as e:
        print(f"[ERROR] Failed to create tar archive {archive}: {e}", file=sys.stderr)
        return False


def extract_archive(archive_path: Union[str, Path], target_dir: Union[str, Path]) -> bool:
    """Safely extract gzip-compressed tar archive with path traversal protection."""
    archive = str(archive_path)
    target = str(target_dir)

    os.makedirs(target, exist_ok=True)
    dest = os.path.realpath(target)

    try:
        with tarfile.open(archive, "r:gz") as tar:
            if hasattr(tarfile, "data_filter"):
                tar.extractall(target, filter="data")
            else:
                for m in tar.getmembers():
                    mp = os.path.realpath(os.path.join(dest, m.name))
                    if not mp.startswith(dest + os.sep) and mp != dest:
                        raise RuntimeError(f"Path Traversal detected: {m.name}")
                    if m.islnk() or m.issym():
                        continue
                    tar.extract(m, dest)
        return True
    except Exception as e:
        print(f"[ERROR] Failed to safely extract archive {archive}: {e}", file=sys.stderr)
        return False


def main(argv: Optional[List[str]] = None) -> int:
    """CLI dispatcher for backup engine operations."""
    if argv is None:
        argv = sys.argv[1:]
    if not argv:
        print("Usage: backup_engine.py <command> [args...]", file=sys.stderr)
        return 1

    cmd = argv[0]
    if cmd == "backup_db":
        if len(argv) < 3:
            print("Usage: backup_engine.py backup_db <src> <dst>", file=sys.stderr)
            return 1
        return 0 if backup_db(argv[1], argv[2]) else 1
    elif cmd == "verify_db":
        if len(argv) < 2:
            print("Usage: backup_engine.py verify_db <db_path>", file=sys.stderr)
            return 1
        return 0 if verify_db(argv[1]) else 1
    elif cmd == "create_manifest":
        if len(argv) < 2:
            print("Usage: backup_engine.py create_manifest <staging_dir> [manifest_path]", file=sys.stderr)
            return 1
        out_p = argv[2] if len(argv) > 2 else None
        return 0 if create_manifest(argv[1], out_p) else 1
    elif cmd == "verify_manifest":
        if len(argv) < 2:
            print("Usage: backup_engine.py verify_manifest <staging_dir> [manifest_path]", file=sys.stderr)
            return 1
        man_p = argv[2] if len(argv) > 2 else None
        return 0 if verify_manifest(argv[1], man_p) else 1
    elif cmd == "create_archive":
        if len(argv) < 3:
            print("Usage: backup_engine.py create_archive <archive_path> <staging_dir>", file=sys.stderr)
            return 1
        return 0 if create_archive(argv[1], argv[2]) else 1
    elif cmd == "extract_archive":
        if len(argv) < 3:
            print("Usage: backup_engine.py extract_archive <archive_path> <target_dir>", file=sys.stderr)
            return 1
        return 0 if extract_archive(argv[1], argv[2]) else 1
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
