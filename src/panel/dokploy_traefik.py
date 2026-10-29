#!/usr/bin/env python3
"""
src/panel/dokploy_traefik.py - Traefik Dynamic Configuration Generator for Dokploy.

Generates Traefik file-provider dynamic configuration (YAML) allowing Dokploy Traefik
to route traffic directly to 3X-UI panel, Subscriptions, and xHTTP stream on host.docker.internal
with zero port conflicts on 80/443.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def detect_dokploy_backend_host() -> str:
    """Auto-detects the Docker container name or host for 3X-UI on Dokploy."""
    # 1. Search existing /etc/dokploy/traefik/dynamic/*.{yml,yaml} for upstream container name
    dyn_dir = Path("/etc/dokploy/traefik/dynamic")
    if dyn_dir.is_dir():
        for f in dyn_dir.glob("*.y*ml"):
            if f.name == "vpn.yml":
                continue
            try:
                txt = f.read_text(encoding="utf-8", errors="ignore")
                m = re.search(r'url:\s*["\']?https?://([^:/ \'"\n]+)(?::(?:2053|2096|10443|55443|50443|\d+))?', txt)
                if m:
                    cand = m.group(1).strip()
                    if cand and cand not in ("127.0.0.1", "localhost", "0.0.0.0"):
                        return cand
            except Exception:
                pass

    # 2. Inspect docker ps if docker CLI is available
    try:
        import subprocess
        res = subprocess.run(
            ["docker", "ps", "--format", "{{.Names}}"],
            capture_output=True, text=True, timeout=5
        )
        if res.returncode == 0:
            for name in res.stdout.splitlines():
                name = name.strip()
                if "3x-ui" in name or "x-ui" in name:
                    return name
    except Exception:
        pass

    return "3x-ui-dokploy"


def generate_traefik_dynamic_yaml(
    domain: str,
    panel_subdomain: str | None = None,
    sub_subdomain: str | None = None,
    vless_subdomain: str | None = None,
    panel_port: int = 10443,
    sub_port: int = 55443,
    xhttp_port: int = 50443,
    cert_resolver: str = "letsencrypt",
    backend_host: str = "host.docker.internal",
) -> str:
    """Generates Traefik dynamic configuration YAML string."""
    if backend_host in ("auto", None):
        backend_host = detect_dokploy_backend_host()

    clean_domain = (domain or "example.com").strip().lower()
    p_host = panel_subdomain or f"panel.{clean_domain}"
    s_host = sub_subdomain or f"sub.{clean_domain}"
    v_host = vless_subdomain or f"vless.{clean_domain}"

    yaml_lines = [
        "# ==============================================================================",
        "# DOKPLOY TRAEFIK DYNAMIC CONFIGURATION FOR 3X-UI & VPN SERVICES",
        "# Place this file in /etc/dokploy/traefik/dynamic/vpn.yml",
        "# ==============================================================================",
        "http:",
        "  routers:",
        "    xui-panel:",
        f"      rule: \"Host(`{p_host}`)\"",
        "      entryPoints:",
        "        - \"websecure\"",
        "      service: \"xui-panel-service\"",
        "      tls:",
        f"        certResolver: \"{cert_resolver}\"",
        "",
        "    xui-sub:",
        f"      rule: \"Host(`{s_host}`)\"",
        "      entryPoints:",
        "        - \"websecure\"",
        "      service: \"xui-sub-service\"",
        "      tls:",
        f"        certResolver: \"{cert_resolver}\"",
        "",
        "    xray-xhttp:",
        f"      rule: \"Host(`{v_host}`)\"",
        "      entryPoints:",
        "        - \"websecure\"",
        "      priority: 1000",
        "      service: \"xray-xhttp-service\"",
        "      tls:",
        f"        certResolver: \"{cert_resolver}\"",
        "",
        "  services:",
        "    xui-panel-service:",
        "      loadBalancer:",
        "        servers:",
        f"          - url: \"http://{backend_host}:{panel_port}\"",
        "",
        "    xui-sub-service:",
        "      loadBalancer:",
        "        servers:",
        f"          - url: \"http://{backend_host}:{sub_port}\"",
        "",
        "    xray-xhttp-service:",
        "      loadBalancer:",
        "        servers:",
        f"          - url: \"h2c://{backend_host}:{xhttp_port}\"",
    ]
    return "\n".join(yaml_lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Dokploy Traefik Dynamic YAML Generator")
    parser.add_argument("--domain", default="example.com", help="Primary domain")
    parser.add_argument("--panel-domain", default=None, help="Domain for 3X-UI Panel")
    parser.add_argument("--sub-domain", default=None, help="Domain for Subscriptions")
    parser.add_argument("--vless-domain", default=None, help="Domain for VLESS xHTTP")
    parser.add_argument("--panel-port", type=int, default=10443, help="Internal 3X-UI Web Port")
    parser.add_argument("--sub-port", type=int, default=55443, help="Internal 3X-UI Sub Port")
    parser.add_argument("--xhttp-port", type=int, default=50443, help="Internal Xray xHTTP Port")
    parser.add_argument("--cert-resolver", default="letsencrypt", help="Traefik certResolver name")
    parser.add_argument("--backend-host", default=None, help="Backend host or container name (default: auto)")
    parser.add_argument("--output", "-o", default=None, help="Output file path (default stdout)")

    args = parser.parse_args()
    config_yaml = generate_traefik_dynamic_yaml(
        domain=args.domain,
        panel_subdomain=args.panel_domain,
        sub_subdomain=args.sub_domain,
        vless_subdomain=args.vless_domain,
        panel_port=args.panel_port,
        sub_port=args.sub_port,
        xhttp_port=args.xhttp_port,
        cert_resolver=args.cert_resolver,
        backend_host=args.backend_host or "auto",
    )

    if args.output:
        out_path = Path(args.output).resolve()
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(config_yaml, encoding="utf-8")
        print(f"[OK] Traefik dynamic config saved to: {out_path}", file=sys.stderr)
    else:
        sys.stdout.write(config_yaml)


if __name__ == "__main__":
    main()
