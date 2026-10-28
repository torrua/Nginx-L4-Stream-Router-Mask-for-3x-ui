#!/usr/bin/env python3
"""
scripts/check_components_manifest.py - Track & Auto-Update External Component Versions

Audits upstream releases for all external packages used in the stack:
- shadow-tls (ihciah/shadow-tls)
- wstunnel (erebe/wstunnel)
- sing-box (SagerNet/sing-box)
- zapret (bol-van/zapret)
- AdGuardHome (AdguardTeam/AdGuardHome)
- acme.sh (acmesh-official/acme.sh)
- mieru / mita (enfein/mieru)
- Xray-core (XTLS/Xray-core)

Features:
- Queries GitHub Releases API (with GITHUB_TOKEN support to bypass rate limits).
- Re-calculates SHA-256 digests and asset URLs.
- Updates components-manifest.json.
- Synchronizes FALLBACK dictionary in src/common/download.sh.
- Synchronizes mita_ver in src/installer/steps.sh.
- Synchronizes Xray LATEST_TAG fallback in src/panel/configure.sh.
- Rebuilds monolithic distribution scripts via scripts/build.py.
- Provides a summary report formatted for PR descriptions.

Usage:
    python scripts/check_components_manifest.py           # Check and print status
    python scripts/check_components_manifest.py --update  # Update manifest & codebase
    python scripts/check_components_manifest.py --check   # Exit 1 if any version outdated
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

ROOT_DIR = Path(__file__).resolve().parent.parent
MANIFEST_FILE = ROOT_DIR / "components-manifest.json"
DOWNLOAD_SH = ROOT_DIR / "src" / "common" / "download.sh"
STEPS_SH = ROOT_DIR / "src" / "installer" / "steps.sh"
PANEL_CONF_SH = ROOT_DIR / "src" / "panel" / "configure.sh"
BUILD_PY = ROOT_DIR / "scripts" / "build.py"

GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "").strip()


def github_api_get(url: str) -> dict[str, Any] | list[dict[str, Any]]:
    """Fetch JSON from GitHub API with optional token authentication."""
    headers = {
        "User-Agent": "Antigravity-Component-Tracker/1.0",
        "Accept": "application/vnd.github.v3+json",
    }
    if GITHUB_TOKEN:
        headers["Authorization"] = f"Bearer {GITHUB_TOKEN}"

    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"[!] GitHub API Error ({url}): HTTP {e.code} - {e.reason}\n")
        raise


def get_latest_release(repo: str, allow_prerelease: bool = False) -> dict[str, Any]:
    """Get latest release info for a GitHub repo."""
    if not allow_prerelease:
        url = f"https://api.github.com/repos/{repo}/releases/latest"
        return github_api_get(url)  # type: ignore

    url = f"https://api.github.com/repos/{repo}/releases?per_page=5"
    releases = github_api_get(url)
    if isinstance(releases, list) and releases:
        return releases[0]
    raise RuntimeError(f"No releases found for {repo}")


def fetch_url_sha256(url: str) -> str:
    """Download a remote file into memory and calculate its SHA-256 hex digest."""
    headers = {"User-Agent": "Antigravity-Component-Tracker/1.0"}
    if GITHUB_TOKEN and "api.github.com" in url:
        headers["Authorization"] = f"Bearer {GITHUB_TOKEN}"

    req = urllib.request.Request(url, headers=headers)
    hasher = hashlib.sha256()
    with urllib.request.urlopen(req, timeout=60) as resp:
        while chunk := resp.read(65536):
            hasher.update(chunk)
    return hasher.hexdigest().lower()


def clean_tag(tag: str) -> str:
    """Strip leading 'v' or 'AdGuardHome v' prefixes."""
    tag = tag.strip()
    if " " in tag:
        tag = tag.split()[-1]
    if tag.startswith("v"):
        tag = tag[1:]
    return tag


def check_and_update_manifest(update: bool = False) -> dict[str, Any]:
    """Audit all components, optionally updating manifest and code."""
    if not MANIFEST_FILE.is_file():
        raise FileNotFoundError(f"Manifest not found: {MANIFEST_FILE}")

    manifest_data = json.loads(MANIFEST_FILE.read_text(encoding="utf-8"))
    components = manifest_data.get("components", {})
    changes: list[dict[str, str]] = []

    print("=" * 72)
    print("🔍 Проверка актуальности версий всех внешних компонентов стека")
    print("=" * 72)

    # 1. shadow-tls
    try:
        st_rel = get_latest_release("ihciah/shadow-tls")
        st_tag = clean_tag(st_rel.get("tag_name", ""))
        current_st = components.get("shadow-tls", {}).get("version", "")
        if st_tag and st_tag != current_st:
            changes.append({
                "component": "shadow-tls",
                "old": current_st,
                "new": st_tag,
                "repo": "ihciah/shadow-tls",
            })
            if update:
                components["shadow-tls"]["version"] = st_tag
                for asset in st_rel.get("assets", []):
                    aname = asset.get("name", "")
                    if aname == "shadow-tls-x86_64-unknown-linux-musl":
                        digest = asset.get("digest", "")
                        sha = digest.replace("sha256:", "") if digest else fetch_url_sha256(asset["browser_download_url"])
                        components["shadow-tls"]["artifacts"]["x86_64"] = {
                            "url": asset["browser_download_url"],
                            "sha256": sha,
                        }
                    elif aname == "shadow-tls-aarch64-unknown-linux-musl":
                        digest = asset.get("digest", "")
                        sha = digest.replace("sha256:", "") if digest else fetch_url_sha256(asset["browser_download_url"])
                        components["shadow-tls"]["artifacts"]["aarch64"] = {
                            "url": asset["browser_download_url"],
                            "sha256": sha,
                        }
        print(f"  • shadow-tls: {current_st} -> upstream {st_tag} {'(ОБНОВЛЕНИЕ)' if st_tag != current_st else '(актуально)'}")
    except Exception as e:
        print(f"  [!] shadow-tls error: {e}")

    # 2. wstunnel
    try:
        ws_rel = get_latest_release("erebe/wstunnel")
        ws_tag = clean_tag(ws_rel.get("tag_name", ""))
        current_ws = components.get("wstunnel", {}).get("version", "")
        if ws_tag and ws_tag != current_ws:
            changes.append({
                "component": "wstunnel",
                "old": current_ws,
                "new": ws_tag,
                "repo": "erebe/wstunnel",
            })
            if update:
                components["wstunnel"]["version"] = ws_tag
                for asset in ws_rel.get("assets", []):
                    aname = asset.get("name", "")
                    if aname.endswith("linux_amd64.tar.gz"):
                        digest = asset.get("digest", "")
                        sha = digest.replace("sha256:", "") if digest else fetch_url_sha256(asset["browser_download_url"])
                        components["wstunnel"]["artifacts"]["x86_64"] = {
                            "url": asset["browser_download_url"],
                            "sha256": sha,
                        }
                    elif aname.endswith("linux_arm64.tar.gz"):
                        digest = asset.get("digest", "")
                        sha = digest.replace("sha256:", "") if digest else fetch_url_sha256(asset["browser_download_url"])
                        components["wstunnel"]["artifacts"]["aarch64"] = {
                            "url": asset["browser_download_url"],
                            "sha256": sha,
                        }
        print(f"  • wstunnel:   {current_ws} -> upstream {ws_tag} {'(ОБНОВЛЕНИЕ)' if ws_tag != current_ws else '(актуально)'}")
    except Exception as e:
        print(f"  [!] wstunnel error: {e}")

    # 3. sing-box
    try:
        sb_rel = get_latest_release("SagerNet/sing-box")
        sb_tag = clean_tag(sb_rel.get("tag_name", ""))
        current_sb = components.get("sing-box", {}).get("version", "")
        if sb_tag and sb_tag != current_sb:
            changes.append({
                "component": "sing-box",
                "old": current_sb,
                "new": sb_tag,
                "repo": "SagerNet/sing-box",
            })
            if update:
                components["sing-box"]["version"] = sb_tag
                for asset in sb_rel.get("assets", []):
                    aname = asset.get("name", "")
                    if aname.startswith(f"sing-box-{sb_tag}-linux-amd64.tar.gz"):
                        digest = asset.get("digest", "")
                        sha = digest.replace("sha256:", "") if digest else fetch_url_sha256(asset["browser_download_url"])
                        components["sing-box"]["artifacts"]["x86_64"] = {
                            "url": asset["browser_download_url"],
                            "sha256": sha,
                        }
                    elif aname.startswith(f"sing-box-{sb_tag}-linux-arm64.tar.gz"):
                        digest = asset.get("digest", "")
                        sha = digest.replace("sha256:", "") if digest else fetch_url_sha256(asset["browser_download_url"])
                        components["sing-box"]["artifacts"]["aarch64"] = {
                            "url": asset["browser_download_url"],
                            "sha256": sha,
                        }

        # Also check sing-box experimental
        sb_exp_rel = get_latest_release("SagerNet/sing-box", allow_prerelease=True)
        sb_exp_tag = clean_tag(sb_exp_rel.get("tag_name", ""))
        current_sb_exp = components.get("sing-box", {}).get("experimental", {}).get("version", "")
        if sb_exp_tag and sb_exp_tag != current_sb_exp:
            changes.append({
                "component": "sing-box (experimental)",
                "old": current_sb_exp,
                "new": sb_exp_tag,
                "repo": "SagerNet/sing-box",
            })
            if update and "experimental" in components["sing-box"]:
                components["sing-box"]["experimental"]["version"] = sb_exp_tag

        print(f"  • sing-box:   {current_sb} (exp: {current_sb_exp}) -> upstream {sb_tag} (exp: {sb_exp_tag})")
    except Exception as e:
        print(f"  [!] sing-box error: {e}")

    # 4. zapret
    try:
        zp_rel = get_latest_release("bol-van/zapret")
        zp_tag = clean_tag(zp_rel.get("tag_name", ""))
        current_zp = components.get("zapret", {}).get("version", "")
        if zp_tag and zp_tag != current_zp:
            changes.append({
                "component": "zapret",
                "old": current_zp,
                "new": zp_tag,
                "repo": "bol-van/zapret",
            })
            if update:
                components["zapret"]["version"] = zp_tag
                for asset in zp_rel.get("assets", []):
                    aname = asset.get("name", "")
                    if aname == f"zapret-v{zp_tag}.tar.gz":
                        digest = asset.get("digest", "")
                        sha = digest.replace("sha256:", "") if digest else fetch_url_sha256(asset["browser_download_url"])
                        components["zapret"]["artifacts"]["all"] = {
                            "url": asset["browser_download_url"],
                            "sha256": sha,
                        }
        print(f"  • zapret:     {current_zp} -> upstream {zp_tag} {'(ОБНОВЛЕНИЕ)' if zp_tag != current_zp else '(актуально)'}")
    except Exception as e:
        print(f"  [!] zapret error: {e}")

    # 5. AdGuardHome
    try:
        agh_rel = get_latest_release("AdguardTeam/AdGuardHome")
        agh_tag = clean_tag(agh_rel.get("tag_name", ""))
        current_agh = components.get("AdGuardHome", {}).get("version", "")
        if agh_tag and agh_tag != current_agh:
            changes.append({
                "component": "AdGuardHome",
                "old": current_agh,
                "new": agh_tag,
                "repo": "AdguardTeam/AdGuardHome",
            })
            if update:
                components["AdGuardHome"]["version"] = agh_tag
                for asset in agh_rel.get("assets", []):
                    aname = asset.get("name", "")
                    if aname == "AdGuardHome_linux_amd64.tar.gz":
                        digest = asset.get("digest", "")
                        sha = digest.replace("sha256:", "") if digest else fetch_url_sha256(asset["browser_download_url"])
                        components["AdGuardHome"]["artifacts"]["x86_64"] = {
                            "url": asset["browser_download_url"],
                            "sha256": sha,
                        }
                    elif aname == "AdGuardHome_linux_arm64.tar.gz":
                        digest = asset.get("digest", "")
                        sha = digest.replace("sha256:", "") if digest else fetch_url_sha256(asset["browser_download_url"])
                        components["AdGuardHome"]["artifacts"]["aarch64"] = {
                            "url": asset["browser_download_url"],
                            "sha256": sha,
                        }
        print(f"  • AdGuardHome:{current_agh} -> upstream {agh_tag} {'(ОБНОВЛЕНИЕ)' if agh_tag != current_agh else '(актуально)'}")
    except Exception as e:
        print(f"  [!] AdGuardHome error: {e}")

    # 6. acme.sh
    try:
        acme_rel = get_latest_release("acmesh-official/acme.sh")
        acme_tag = clean_tag(acme_rel.get("tag_name", ""))
        current_acme = components.get("acme.sh", {}).get("version", "")
        if acme_tag and acme_tag != current_acme:
            changes.append({
                "component": "acme.sh",
                "old": current_acme,
                "new": acme_tag,
                "repo": "acmesh-official/acme.sh",
            })
            if update:
                components["acme.sh"]["version"] = acme_tag
                archive_url = f"https://github.com/acmesh-official/acme.sh/archive/refs/tags/{acme_tag}.tar.gz"
                sha = fetch_url_sha256(archive_url)
                components["acme.sh"]["artifacts"]["all"] = {
                    "url": archive_url,
                    "sha256": sha,
                }
        print(f"  • acme.sh:    {current_acme} -> upstream {acme_tag} {'(ОБНОВЛЕНИЕ)' if acme_tag != current_acme else '(актуально)'}")
    except Exception as e:
        print(f"  [!] acme.sh error: {e}")

    # 7. mieru (mita)
    current_mita = ""
    try:
        if STEPS_SH.is_file():
            steps_content = STEPS_SH.read_text(encoding="utf-8")
            m_mita = re.search(r'local mita_ver="([^"]+)"', steps_content)
            if m_mita:
                current_mita = m_mita.group(1)

        mita_rel = get_latest_release("enfein/mieru")
        mita_tag = clean_tag(mita_rel.get("tag_name", ""))
        if mita_tag and current_mita and mita_tag != current_mita:
            changes.append({
                "component": "mieru (mita)",
                "old": current_mita,
                "new": mita_tag,
                "repo": "enfein/mieru",
            })
            if update and STEPS_SH.is_file():
                steps_content = re.sub(
                    r'local mita_ver="[^"]+"',
                    f'local mita_ver="{mita_tag}"',
                    steps_content,
                )
                STEPS_SH.write_text(steps_content, encoding="utf-8")
        print(f"  • mieru(mita):{current_mita} -> upstream {mita_tag} {'(ОБНОВЛЕНИЕ)' if mita_tag != current_mita else '(актуально)'}")
    except Exception as e:
        print(f"  [!] mieru error: {e}")

    # 8. Xray-core
    current_xray = ""
    try:
        if PANEL_CONF_SH.is_file():
            panel_content = PANEL_CONF_SH.read_text(encoding="utf-8")
            m_xray = re.search(r'LATEST_TAG="(v[^"]+)"', panel_content)
            if m_xray:
                current_xray = m_xray.group(1)

        xray_rel = get_latest_release("XTLS/Xray-core")
        xray_tag = xray_rel.get("tag_name", "").strip()
        if not xray_tag.startswith("v") and xray_tag:
            xray_tag = f"v{xray_tag}"
        if xray_tag and current_xray and xray_tag != current_xray:
            changes.append({
                "component": "Xray-core",
                "old": current_xray,
                "new": xray_tag,
                "repo": "XTLS/Xray-core",
            })
            if update and PANEL_CONF_SH.is_file():
                panel_content = re.sub(
                    r'LATEST_TAG="v[^"]+"',
                    f'LATEST_TAG="{xray_tag}"',
                    panel_content,
                )
                PANEL_CONF_SH.write_text(panel_content, encoding="utf-8")
        print(f"  • Xray-core:  {current_xray} -> upstream {xray_tag} {'(ОБНОВЛЕНИЕ)' if xray_tag != current_xray else '(актуально)'}")
    except Exception as e:
        print(f"  [!] Xray-core error: {e}")

    print("=" * 72)

    if update and changes:
        # 1. Save updated components-manifest.json
        MANIFEST_FILE.write_text(json.dumps(manifest_data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"[✓] Обновлён {MANIFEST_FILE.name}")

        # 2. Sync FALLBACK dictionary in src/common/download.sh
        sync_download_fallback(components)

        # 3. Rebuild root scripts
        print("[*] Пересборка монолитных скриптов через scripts/build.py...")
        subprocess.run([sys.executable, str(BUILD_PY)], check=True)
        print("[✓] Монолитные скрипты успешно пересобраны.")

    return {"changes": changes}


def sync_download_fallback(components: dict[str, Any]) -> None:
    """Generate and replace FALLBACK dictionary in src/common/download.sh."""
    if not DOWNLOAD_SH.is_file():
        return

    content = DOWNLOAD_SH.read_text(encoding="utf-8")

    lines = ["FALLBACK = {"]
    comp_items = list(components.items())
    for idx, (cname, cinfo) in enumerate(comp_items):
        lines.append(f"    '{cname}': {{")
        arts = list(cinfo.get("artifacts", {}).items())
        for aidx, (arch, art) in enumerate(arts):
            comma = "," if aidx < len(arts) - 1 else ""
            lines.append(f"        '{arch}': ('{art['url']}', '{art['sha256']}', {cinfo.get('max_size_bytes', 0)}, '{cinfo.get('version', '')}'){comma}")
        comma = "," if idx < len(comp_items) - 1 else ""
        lines.append(f"    }}{comma}")
    lines.append("}")
    new_fallback_block = "\n".join(lines)

    pattern = re.compile(r"FALLBACK\s*=\s*\{.*?^\}", re.MULTILINE | re.DOTALL)
    if pattern.search(content):
        updated_content = pattern.sub(new_fallback_block, content, count=1)
        DOWNLOAD_SH.write_text(updated_content, encoding="utf-8")
        print(f"[✓] Синхронизирован FALLBACK в {DOWNLOAD_SH.relative_to(ROOT_DIR)}")


def generate_pr_body(changes: list[dict[str, str]]) -> str:
    """Format changes list into Markdown for a Pull Request."""
    body = [
        "## 🤖 Автоматическое обновление внешних компонентов",
        "",
        "Обнаружены новые релизы в официальных upstream-репозиториях.",
        "",
        "| Компонент | Текущая версия | Новая версия | Репозиторий |",
        "| :--- | :--- | :--- | :--- |",
    ]
    for c in changes:
        body.append(f"| **{c['component']}** | `{c['old']}` | `{c['new']}` | [{c['repo']}](https://github.com/{c['repo']}) |")
    body.extend([
        "",
        "### Что было автоматически обновлено:",
        "- `components-manifest.json` (новые версии, URL и SHA-256)",
        "- `src/common/download.sh` (встроенный словарь FALLBACK)",
        "- `src/installer/steps.sh` / `src/panel/configure.sh` (mita, Xray)",
        "- Корневые скрипты пересобраны через `python scripts/build.py`",
        "",
        "Перед слиянием убедитесь, что тесты CI завершились успешно.",
    ])
    return "\n".join(body)


def main():
    parser = argparse.ArgumentParser(description="Track and update external components versions.")
    parser.add_argument("--update", action="store_true", help="Automatically update manifest, source files and rebuild scripts.")
    parser.add_argument("--check", action="store_true", help="Exit with code 1 if any component is outdated.")
    parser.add_argument("--format-pr-body", action="store_true", help="Output PR markdown body if changes found.")
    parser.add_argument("--pr-body-file", type=str, default="", help="Write PR description Markdown to this file path.")
    args = parser.parse_args()

    result = check_and_update_manifest(update=args.update)
    changes = result["changes"]

    pr_body_text = generate_pr_body(changes) if changes else ""

    if args.pr_body_file and pr_body_text:
        target_path = Path(args.pr_body_file)
        target_path.parent.mkdir(parents=True, exist_ok=True)
        target_path.write_text(pr_body_text, encoding="utf-8")
        print(f"[✓] Описание PR сохранено в {target_path}")

    step_summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary_file:
        try:
            with open(step_summary_file, "a", encoding="utf-8") as f:
                if changes:
                    f.write(pr_body_text + "\n")
                else:
                    f.write("### 🟢 Внешние компоненты\n\nВсе компоненты находятся на актуальных релизах!\n")
        except Exception as e:
            sys.stderr.write(f"[!] Не удалось записать GITHUB_STEP_SUMMARY: {e}\n")

    if args.format_pr_body:
        if changes:
            print("\n--- PR_BODY_START ---")
            print(pr_body_text)
            print("--- PR_BODY_END ---")

    if changes:
        print(f"\n[!] Обнаружено обновлений: {len(changes)}")
        for c in changes:
            print(f"    - {c['component']}: {c['old']} -> {c['new']}")
        if args.check:
            sys.exit(1)
    else:
        print("\n[✓] Все внешние компоненты находятся на самых свежих релизах!")
        sys.exit(0)


if __name__ == "__main__":
    main()
