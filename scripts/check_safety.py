#!/usr/bin/env python3
"""
scripts/check_safety.py - Automated Privacy & Security Guard for Repository.

Validates that no sensitive personal data, production cluster IPs, private keys,
database snapshots, or temporary scripts are tracked in Git or present in codebase.

Exits with code 0 on clean scan, code 1 on violations.
"""

from __future__ import annotations

import ipaddress
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent

# 1. Blocked file extensions / names that must NEVER be tracked in Git
FORBIDDEN_FILE_PATTERNS = [
    re.compile(r"\.(db|db-wal|db-shm|sqlite|sqlite3|dump|tar\.gz|tgz|7z|bak|old)$", re.IGNORECASE),
    re.compile(r"\.(key|pem|pfx|p12|csr|id_rsa|id_ed25519|ppk)$", re.IGNORECASE),
    re.compile(r"(^|/)(backups|scratch|\.tmp|temp_profiles)/", re.IGNORECASE),
    re.compile(r"(^|/)\.env(\.[^/]+)?$", re.IGNORECASE),  # except .env.example checked below
    re.compile(r"(^|/)run_remote_install\.py$", re.IGNORECASE),
]

ALLOWED_FILE_EXCEPTIONS = [
    re.compile(r"\.env\.example$", re.IGNORECASE),
    re.compile(r"setup_mask\.env\.example$", re.IGNORECASE),
    re.compile(r"logo\.webp$", re.IGNORECASE),
]

# 2. Hardcoded Forbidden Sensitive Strings & Regexes
FORBIDDEN_CONTENT_PATTERNS = [
    (re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"), "Private Key Header"),
    (re.compile(r"rutma\.top", re.IGNORECASE), "Production Domain Leak (rutma.top)"),
    (re.compile(r"\btg_\d{6,}\b"), "Telegram Client ID Leak"),
    (re.compile(r"\[AWG-BOT\]"), "AWG Bot Client Identifier"),
    (re.compile(r"\b23\.186\.104\.\d{1,3}\b"), "Cluster Master IP Leak"),
    (re.compile(r"\b192\.3\.95\.\d{1,3}\b"), "Cluster NY Node IP Leak"),
    (re.compile(r"\b23\.94\.67\.\d{1,3}\b"), "Cluster IE Node IP Leak"),
    (re.compile(r"\b193\.180\.208\.\d{1,3}\b"), "Cluster DK Node IP Leak"),
    (re.compile(r"\b143\.246\.43\.\d{1,3}\b"), "Cluster BG Node IP Leak"),
    (re.compile(r"\b93\.177\.101\.\d{1,3}\b"), "Cluster TR Server IP Leak"),
]

# 3. Permitted Public IP Whitelist (DNS, Documentation, Anycast CDN)
ALLOWED_PUBLIC_IPS = {
    # Public DNS Resolvers
    "1.1.1.1", "1.0.0.1",           # Cloudflare DNS
    "8.8.8.8", "8.8.4.4",           # Google DNS
    "9.9.9.9", "149.112.112.112",   # Quad9 DNS
    "76.76.2.0", "76.76.10.0",      # Control D Anycast
    "76.76.2.2", "76.76.10.2",      # Control D
    "77.88.8.8", "77.88.8.1",       # Yandex DNS
    "94.140.14.14", "94.140.15.15", # AdGuard DNS
    # Cloudflare WARP Anycast Egress
    "162.159.192.1", "162.159.193.10",
}

# Documentation RFC 5737 and Private subnets
ALLOWED_NETWORKS = [
    ipaddress.ip_network("0.0.0.0/8"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("192.0.2.0/24"),    # TEST-NET-1 (RFC 5737)
    ipaddress.ip_network("198.51.100.0/24"), # TEST-NET-2 (RFC 5737)
    ipaddress.ip_network("203.0.113.0/24"),  # TEST-NET-3 (RFC 5737)
    ipaddress.ip_network("224.0.0.0/4"),     # Multicast
    ipaddress.ip_network("240.0.0.0/4"),     # Reserved
]


def is_ip_allowed(ip_str: str) -> bool:
    """Check if IPv4 address is in allowed documentation/private/DNS whitelist."""
    if ip_str in ALLOWED_PUBLIC_IPS:
        return True
    try:
        ip = ipaddress.ip_address(ip_str)
        return any(ip in net for net in ALLOWED_NETWORKS)
    except ValueError:
        return True


def get_tracked_files(root_dir: Path = ROOT_DIR) -> list[Path]:
    """Retrieve all files tracked by Git."""
    try:
        res = subprocess.run(
            ["git", "ls-files"],
            cwd=root_dir,
            text=True,
            encoding="utf-8",
            capture_output=True,
            check=True,
        )
        return [root_dir / p.strip() for p in res.stdout.splitlines() if p.strip()]
    except Exception as e:
        print(f"[WARN] git ls-files failed: {e}. Falling back to directory scan.")
        tracked = []
        for root, _, files in os.walk(root_dir):
            for file in files:
                p = Path(root) / file
                if ".git" not in p.parts:
                    tracked.append(p)
        return tracked


def inspect_repository(root_dir: Path = ROOT_DIR) -> tuple[list[str], list[str]]:
    """Scan tracked repository files for sensitive files and content."""
    errors: list[str] = []
    warnings: list[str] = []

    tracked = get_tracked_files(root_dir)
    ipv4_pattern = re.compile(r"\b([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\b")

    for file_path in tracked:
        try:
            rel_posix = file_path.relative_to(root_dir).as_posix()
        except ValueError:
            rel_posix = file_path.as_posix()

        # 1. Check file path against forbidden list
        is_exception = any(exc.search(rel_posix) for exc in ALLOWED_FILE_EXCEPTIONS)
        if not is_exception:
            for pattern in FORBIDDEN_FILE_PATTERNS:
                if pattern.search(rel_posix):
                    errors.append(f"Forbidden file tracked in git: '{rel_posix}' (matches {pattern.pattern})")

        # Skip binary files from text analysis
        try:
            content = file_path.read_text(encoding="utf-8", errors="strict")
        except (UnicodeDecodeError, PermissionError):
            continue

        # Skip self from content string matching to prevent false positives on pattern definitions
        if rel_posix == "scripts/check_safety.py":
            continue

        # 2. Check content for sensitive string patterns
        for line_num, line in enumerate(content.splitlines(), start=1):
            for pattern, desc in FORBIDDEN_CONTENT_PATTERNS:
                if pattern.search(line):
                    errors.append(f"[{rel_posix}:{line_num}] {desc}: {line.strip()[:100]}")

            # 3. Check for unauthorized public IPv4 addresses
            for m in ipv4_pattern.finditer(line):
                ip_str = m.group(1)
                # Filter out obvious non-IP strings like software versions (e.g. 1.2.3.4)
                parts = ip_str.split(".")
                if all(0 <= int(p) <= 255 for p in parts):
                    if not is_ip_allowed(ip_str):
                        # Filter out common version numbers (e.g. 24.11.0.0)
                        if rel_posix.startswith("VERSION") or "version" in line.lower():
                            continue
                        errors.append(
                            f"[{rel_posix}:{line_num}] Unauthorized Public IP '{ip_str}': {line.strip()[:100]}"
                        )

    return errors, warnings


def main() -> int:
    try:
        if hasattr(sys.stdout, "reconfigure"):
            sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    print("================================================================================")
    print("[*] Repository Privacy & Security Safety Scanner")
    print("================================================================================")

    errors, warnings = inspect_repository()

    for w in warnings:
        print(f"[!] [WARNING] {w}")

    if errors:
        print(f"\n[X] [CRITICAL SAFETY CHECK FAILED]: Found {len(errors)} security violations:\n")
        for err in errors:
            print(f"  * {err}")
        print("\nPlease remove sensitive data or update .gitignore before committing/pushing.")
        return 1

    print("\n[OK] Repository is completely clean of personal data, cluster IPs, and secrets.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
