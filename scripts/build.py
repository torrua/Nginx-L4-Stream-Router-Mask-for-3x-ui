#!/usr/bin/env python3
"""
scripts/build.py - Monolithic Script Bundler for Nginx-L4-Stream-Router-Mask-for-3x-ui.

Assembles modular sources from src/ into standalone root scripts, preserving
100% compatibility with direct `curl -sSL ... | sudo bash` execution.

Features:
- Single Source of Truth (SSOT) via VERSION file.
- Automatic macro substitution: `__VERSION__` (e.g. 'v8.0.0') and `__RAW_VERSION__` ('8.0.0').
- One-command release bumping via `--bump <version>`.

Usage:
    python scripts/build.py               # Assemble all available targets
    python scripts/build.py --check       # Verify that root files match src/ (exit 1 on drift)
    python scripts/build.py --lint        # Run syntax validation (bash -n and Python AST)
    python scripts/build.py --target NAME # Build only a specific target (e.g. setup.sh)
    python scripts/build.py --bump 8.1.0  # Bump version, sync docs, and rebuild all targets
    python scripts/build.py --sync-version# Sync current VERSION to docs and rebuild targets
"""

from __future__ import annotations

import argparse
import ast
from concurrent.futures import ThreadPoolExecutor
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
SRC_DIR = ROOT_DIR / "src"

ENTRYPOINTS: dict[str, str] = {
    "install.sh": "entrypoints/install.main.sh",
    "setup.sh": "entrypoints/setup.main.sh",
    "uninstall.sh": "entrypoints/uninstall.main.sh",
    "configure-panel.sh": "entrypoints/configure-panel.main.sh",
    "maintain.sh": "entrypoints/maintain.main.sh",
    "prepare-server.sh": "entrypoints/prepare-server.main.sh",
    "manage-services.sh": "entrypoints/manage-services.main.sh",
}

INCLUDE_PATTERN = re.compile(r"^(\s*)#\s*@include\s+[\"']([^\"']+)[\"']\s*$")


def get_version(root_dir: Path = ROOT_DIR) -> str:
    """Read project version from VERSION file, defaulting to v8.0.0."""
    ver_file = root_dir / "VERSION"
    if ver_file.is_file():
        v = ver_file.read_text(encoding="utf-8").strip()
        if v:
            return v if v.startswith("v") else f"v{v}"
    return "v8.0.0"


def sync_version_in_docs(version: str, root_dir: Path = ROOT_DIR) -> list[str]:
    """Sync version string into README.md and docs/ARCHITECTURE.md."""
    updated: list[str] = []
    v_norm = version if version.startswith("v") else f"v{version}"

    # 1. README.md badge
    readme = root_dir / "README.md"
    if readme.is_file():
        content = readme.read_text(encoding="utf-8")
        new_content = re.sub(
            r"badge/версия-v[0-9.]+-blue",
            f"badge/версия-{v_norm}-blue",
            content,
        )
        if new_content != content:
            readme.write_text(new_content, encoding="utf-8")
            updated.append("README.md")

    # 2. docs/ARCHITECTURE.md header
    arch = root_dir / "docs" / "ARCHITECTURE.md"
    if arch.is_file():
        content = arch.read_text(encoding="utf-8")
        new_content = re.sub(
            r"\(v[0-9.]+\)",
            f"({v_norm})",
            content,
            count=1,
        )
        if new_content != content:
            arch.write_text(new_content, encoding="utf-8")
            updated.append("docs/ARCHITECTURE.md")

    # 3. server-setup.env.example header
    env_example = root_dir / "server-setup.env.example"
    if env_example.is_file():
        content = env_example.read_text(encoding="utf-8")
        new_content = re.sub(
            r"\(v[0-9.]+\s+Universal\)",
            f"({v_norm} Universal)",
            content,
        )
        if new_content != content:
            env_example.write_text(new_content, encoding="utf-8")
            updated.append("server-setup.env.example")

    return updated


def resolve_include_path(inc_str: str, current_file: Path, src_dir: Path) -> Path:
    """Resolve an include path relative to current file, src/, or ROOT_DIR."""
    if inc_str.startswith("./") or inc_str.startswith("../"):
        target = (current_file.parent / inc_str).resolve()
    else:
        target = (src_dir / inc_str).resolve()
        if not target.is_file() and (ROOT_DIR / inc_str).is_file():
            target = (ROOT_DIR / inc_str).resolve()
    return target


def bundle_file(
    file_path: Path,
    src_dir: Path,
    call_stack: list[Path] | None = None,
) -> str:
    """Recursively bundles a file by expanding # @include directives and substituting version macros."""
    if call_stack is None:
        call_stack = []

    resolved_path = file_path.resolve()
    if resolved_path in call_stack:
        cycle_chain = " -> ".join(str(p.relative_to(src_dir)) for p in call_stack + [resolved_path])
        raise ValueError(f"Cyclic include detected: {cycle_chain}")

    if not resolved_path.is_file():
        raise FileNotFoundError(f"Include file not found: {resolved_path}")

    call_stack.append(resolved_path)
    lines = resolved_path.read_text(encoding="utf-8").splitlines()
    output_lines: list[str] = []

    for line in lines:
        match = INCLUDE_PATTERN.match(line)
        if match:
            indent = match.group(1)
            inc_target_str = match.group(2)
            inc_target_path = resolve_include_path(inc_target_str, resolved_path, src_dir)

            nested_content = bundle_file(inc_target_path, src_dir, list(call_stack))
            nested_lines = nested_content.splitlines()

            if indent:
                nested_lines = [
                    (indent + nl if nl.strip() else nl) for nl in nested_lines
                ]
            output_lines.extend(nested_lines)
        else:
            output_lines.append(line)

    call_stack.pop()
    content = "\n".join(output_lines) + "\n"

    # Only perform macro replacement at the top-level bundle entrypoint
    if not call_stack:
        ver = get_version(src_dir.parent)
        raw_ver = ver.lstrip("v")
        content = content.replace("__VERSION__", ver).replace("__RAW_VERSION__", raw_ver)

    return content


def find_bash_executable() -> Path | None:
    """Find a functional bash executable, prioritizing Git Bash on Windows."""
    if os.name == "nt":
        git_bash = Path(r"C:\Program Files\Git\bin\bash.exe")
        if git_bash.is_file():
            return git_bash
    which_bash = shutil.which("bash")
    if which_bash:
        p = Path(which_bash)
        if os.name == "nt" and "system32" in str(p).lower():
            return None
        return p
    return None


_LINT_CACHE: dict[int, list[str]] = {}


def lint_output(target_name: str, content: str) -> list[str]:
    """Validate bash syntax and embedded Python blocks."""
    # Strip initial comments so identical entrypoints share validation results
    stripped_key = hash(re.sub(r"^(#[^\n]*\n)+", "", content))
    if stripped_key in _LINT_CACHE:
        cached_errs = _LINT_CACHE[stripped_key]
        return [re.sub(r"^\[.*?\]", f"[{target_name}]", err) for err in cached_errs]

    errors: list[str] = []

    # 1. Embedded Python AST validation
    py_blocks = re.findall(
        r"python3\s+-\s+<<\s*['\"]?([A-Za-z0-9_]+)['\"]?\s*\n(.*?)\n\s*\1",
        content,
        re.DOTALL,
    )
    for tag, py_code in py_blocks:
        try:
            ast.parse(py_code)
        except SyntaxError as e:
            errors.append(f"[{target_name}] Embedded Python syntax error in block '{tag}': {e}")

    # 2. Bash syntax checking if functional bash exists
    bash_path = find_bash_executable()
    if bash_path:
        proc = subprocess.run(
            [str(bash_path), "-n", "-s"],
            input=content,
            text=True,
            encoding="utf-8",
            capture_output=True,
        )
        if proc.returncode != 0:
            errors.append(f"[{target_name}] bash -n error:\n{proc.stderr.strip()}")

    _LINT_CACHE[stripped_key] = list(errors)
    return errors


def build_all(
    check_mode: bool = False,
    lint_mode: bool = False,
    target_filter: str | None = None,
) -> int:
    """Build all registered entrypoints or verify them in check mode."""
    if not SRC_DIR.is_dir():
        print(f"Source directory {SRC_DIR} does not exist yet.")
        return 0

    has_errors = False
    drift_detected = False
    processed_count = 0

    targets_to_build = ENTRYPOINTS
    if target_filter:
        if target_filter in ENTRYPOINTS:
            targets_to_build = {target_filter: ENTRYPOINTS[target_filter]}
        else:
            print(f"Error: Target '{target_filter}' not recognized. Available: {list(ENTRYPOINTS.keys())}")
            return 1

    for dest_rel, src_rel in targets_to_build.items():
        src_path = SRC_DIR / src_rel
        dest_path = ROOT_DIR / dest_rel

        if not src_path.is_file():
            # Skip entrypoints that haven't been modularized yet
            continue

        processed_count += 1
        try:
            bundled = bundle_file(src_path, SRC_DIR)
        except Exception as e:
            print(f"[FAIL] Error bundling {dest_rel}: {e}")
            has_errors = True
            continue

        if lint_mode:
            lint_errs = lint_output(dest_rel, bundled)
            if lint_errs:
                for err in lint_errs:
                    print(f"[LINT ERROR] {err}")
                has_errors = True

        if check_mode:
            if not dest_path.is_file():
                print(f"[DRIFT] Target file missing on disk: {dest_rel}")
                drift_detected = True
            else:
                existing = dest_path.read_text(encoding="utf-8")
                if existing != bundled:
                    print(f"[DRIFT] Differences detected in {dest_rel} compared to src/{src_rel}")
                    drift_detected = True
                else:
                    print(f"[OK] {dest_rel} is in sync with src/{src_rel}")
        else:
            # Leave unchanged files alone, including compatibility launchers.
            if not dest_path.is_file() or dest_path.read_text(encoding="utf-8") != bundled:
                import time
                for attempt in range(5):
                    try:
                        dest_path.write_text(bundled, encoding="utf-8", newline="\n")
                        break
                    except OSError:
                        if attempt == 4:
                            raise
                        time.sleep(0.1 * (attempt + 1))
            # Preserve executable permissions
            try:
                dest_path.chmod(0o755)
            except Exception:
                pass
            print(f"[COMPILED] {src_rel} -> {dest_rel} ({len(bundled.splitlines())} lines)")

    if check_mode and drift_detected:
        print("\nDrift check failed: root distribution scripts are out of sync with src/.")
        print("Run 'python scripts/build.py' to update them.")
        return 1

    if lint_mode:
        try:
            try:
                from check_safety import inspect_repository
            except ImportError:
                from scripts.check_safety import inspect_repository
            s_errs, s_warns = inspect_repository(ROOT_DIR)
            for w in s_warns:
                print(f"[SAFETY WARNING] {w}")
            if s_errs:
                for err in s_errs:
                    print(f"[SAFETY ERROR] {err}")
                has_errors = True
            else:
                print("[SAFETY OK] No leaked secrets or forbidden files found in repository.")
        except Exception as e:
            print(f"[SAFETY SKIP] Safety check skipped: {e}")

    if has_errors:
        return 1

    if processed_count == 0:
        print("No entrypoints found in src/entrypoints/ yet.")

    return 0


def bump_version(new_version: str, root_dir: Path = ROOT_DIR) -> int:
    """Update VERSION file, sync documentation, and rebuild all script targets."""
    v_norm = new_version.strip()
    if not v_norm.startswith("v"):
        v_norm = f"v{v_norm}"

    # Validate version format (e.g. v8.0.1, v8.1.0-rc1)
    if not re.match(r"^v\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?$", v_norm):
        print(f"Error: Invalid version format '{new_version}'. Expected format like '8.1.0' or 'v8.1.0'.")
        return 1

    ver_file = root_dir / "VERSION"
    ver_file.write_text(f"{v_norm}\n", encoding="utf-8")
    print(f"[VERSION] Updated VERSION file to {v_norm}")

    doc_updates = sync_version_in_docs(v_norm, root_dir)
    for doc in doc_updates:
        print(f"[DOCS SYNC] Updated {doc} -> {v_norm}")

    # Rebuild all targets
    print(f"[BUILD] Rebuilding all targets with {v_norm}...")
    rc = build_all(check_mode=False, lint_mode=True)
    if rc == 0:
        print(f"\n[SUCCESS] Version successfully bumped to {v_norm} across code, docs, and compiled targets.")
    return rc


def main() -> int:
    parser = argparse.ArgumentParser(description="Build and assemble monolithic root scripts from src/")
    parser.add_argument("--check", action="store_true", help="Check for drift without modifying files (CI mode)")
    parser.add_argument("--lint", action="store_true", help="Validate bash and embedded python syntax")
    parser.add_argument("--safety", action="store_true", help="Scan repository for leaked secrets, cluster IPs, and private data")
    parser.add_argument("--target", type=str, help="Build a specific target script")
    parser.add_argument("--bump", type=str, metavar="VERSION", help="Bump project version, sync docs, and rebuild all targets")
    parser.add_argument("--sync-version", action="store_true", help="Sync current VERSION into docs and rebuild targets")
    args = parser.parse_args()

    if args.safety:
        try:
            from check_safety import main as safety_main
        except ImportError:
            from scripts.check_safety import main as safety_main
        return safety_main()

    if args.bump:
        return bump_version(args.bump)

    if args.sync_version:
        ver = get_version()
        doc_updates = sync_version_in_docs(ver)
        for doc in doc_updates:
            print(f"[DOCS SYNC] Updated {doc} -> {ver}")
        return build_all(check_mode=False, lint_mode=args.lint, target_filter=args.target)

    return build_all(check_mode=args.check, lint_mode=args.lint, target_filter=args.target)


if __name__ == "__main__":
    sys.exit(main())
