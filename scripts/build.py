#!/usr/bin/env python3
"""
scripts/build.py - Monolithic Script Bundler for Nginx-L4-Stream-Router-Mask-for-3x-ui.

Assembles modular sources from src/ into standalone root scripts, preserving
100% compatibility with direct `curl -sSL ... | sudo bash` execution.

Usage:
    python scripts/build.py               # Assemble all available targets
    python scripts/build.py --check       # Verify that root files match src/ (exit 1 on drift)
    python scripts/build.py --lint        # Run syntax validation (bash -n and Python AST)
    python scripts/build.py --target NAME # Build only a specific target (e.g. setup_mask.sh)
"""

from __future__ import annotations

import argparse
import ast
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
SRC_DIR = ROOT_DIR / "src"

ENTRYPOINTS: dict[str, str] = {
    "setup_mask.sh": "entrypoints/setup_mask.main.sh",
    "configure_3xui.sh": "entrypoints/configure_3xui.main.sh",
    "update_repair.sh": "entrypoints/update_repair.main.sh",
    "install.sh": "entrypoints/install.main.sh",
}

INCLUDE_PATTERN = re.compile(r"^(\s*)#\s*@include\s+[\"']([^\"']+)[\"']\s*$")


def resolve_include_path(inc_str: str, current_file: Path, src_dir: Path) -> Path:
    """Resolve an include path relative to current file or src/."""
    if inc_str.startswith("./") or inc_str.startswith("../"):
        target = (current_file.parent / inc_str).resolve()
    else:
        target = (src_dir / inc_str).resolve()
    return target


def bundle_file(
    file_path: Path,
    src_dir: Path,
    call_stack: list[Path] | None = None,
) -> str:
    """Recursively bundles a file by expanding # @include directives."""
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
    # Ensure standard trailing newline
    return "\n".join(output_lines) + "\n"


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


def lint_output(target_name: str, content: str) -> list[str]:
    """Validate bash syntax and embedded Python blocks."""
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
            # Write to disk
            dest_path.write_text(bundled, encoding="utf-8", newline="\n")
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

    if has_errors:
        return 1

    if processed_count == 0:
        print("No entrypoints found in src/entrypoints/ yet.")

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Build and assemble monolithic root scripts from src/")
    parser.add_argument("--check", action="store_true", help="Check for drift without modifying files (CI mode)")
    parser.add_argument("--lint", action="store_true", help="Validate bash and embedded python syntax")
    parser.add_argument("--target", type=str, help="Build a specific target script")
    args = parser.parse_args()

    return build_all(check_mode=args.check, lint_mode=args.lint, target_filter=args.target)


if __name__ == "__main__":
    sys.exit(main())
