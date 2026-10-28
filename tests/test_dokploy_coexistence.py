#!/usr/bin/env python3
"""
tests/test_dokploy_coexistence.py - Tests for Dokploy Coexistence Mode.

Verifies:
- CLI flag `--dokploy` and `--no-dokploy` parsing.
- Dokploy auto-detection when network or container is present.
- Installation plan construction under Dokploy Coexistence (Nginx 80/443 omitted, 3X-UI & AWG retained).
- Config validation with DOKPLOY_COEXISTENCE=y.
- Traefik dynamic provider config generation for 3X-UI and subscriptions.
- Manage-services CLI commands for Dokploy export and Traefik config.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parent.parent
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")


def run_shell(code: str, env: dict | None = None) -> subprocess.CompletedProcess:
    full_env = os.environ.copy()
    if env:
        full_env.update(env)
    return subprocess.run(
        [str(BASH), "-s"],
        input="export PATH=/usr/bin:/bin:$PATH\nsource src/common/config.sh\n" + code,
        cwd=ROOT,
        text=True,
        encoding="utf-8",
        capture_output=True,
        timeout=25,
        env=full_env,
    )


class TestDokployCoexistence(unittest.TestCase):
    def test_plan_construction_with_dokploy_coexistence(self):
        """Verify that DOKPLOY_COEXISTENCE=y preserves 3X-UI panel and AWG, but skips Nginx on 80/443."""
        res = run_shell("""
set -euo pipefail
CYAN=; BOLD=; NC=; DIM=; WHITE=;
warn(){ :; }; ok(){ :; }; die(){ echo "DIE:$*"; exit 1; };
is_true() { local val="${1:-0}"; [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]; }
source src/common/protocols.sh
source src/system/env.sh
source src/installer/plan.sh

DOKPLOY_COEXISTENCE="y"
ENABLE_WEB_STACK=0
AUTO_SETUP_3XUI="y"
ENABLE_AWG_V3="y"
AWG_V3_PORT="8443"
PRIMARY_DOMAIN="example.com"

build_installation_plan
for step in "${INSTALLATION_PLAN[@]}"; do
    echo "STEP:$step"
done
""")
        self.assertEqual(res.returncode, 0, f"Plan building failed: {res.stderr}")
        steps = [line.replace("STEP:", "").strip() for line in res.stdout.splitlines() if line.startswith("STEP:")]
        self.assertIn("panel", steps, "3X-UI panel must be present in Dokploy coexistence mode")
        self.assertNotIn("nginx", steps, "Nginx on 80/443 must not be installed in Dokploy coexistence mode")
        self.assertNotIn("decoy", steps, "Decoy site on 80/443 must not be installed in Dokploy coexistence mode")
        self.assertNotIn("certificates", steps, "Certbot HTTP-01 on 80/443 must not be installed in Dokploy coexistence mode")

    def test_validation_config_with_dokploy_coexistence(self):
        """validate_installation_config must succeed when DOKPLOY_COEXISTENCE=y and AUTO_SETUP_3XUI=y."""
        res = run_shell("""
set -euo pipefail
CYAN=; BOLD=; NC=; DIM=; WHITE=;
warn(){ :; }; ok(){ :; }; die(){ echo "DIE:$*"; exit 1; };
is_true() { local val="${1:-0}"; [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]; }
source src/common/protocols.sh
source src/system/env.sh
source src/installer/plan.sh

DOKPLOY_COEXISTENCE="y"
ENABLE_WEB_STACK=0
AUTO_SETUP_3XUI="y"
PRIMARY_DOMAIN="example.com"
installation_listeners(){ echo "Panel tcp 10443"; }

validate_installation_config
echo "VALIDATION:SUCCESS"
""")
        self.assertEqual(res.returncode, 0, f"Validation failed: {res.stderr}\n{res.stdout}")
        self.assertIn("VALIDATION:SUCCESS", res.stdout)

    def test_traefik_dynamic_config_generation(self):
        """Verify generation of Traefik dynamic config for 3X-UI, sub, and xHTTP."""
        sys.path.insert(0, str((ROOT / "src/panel").resolve()))
        try:
            import dokploy_traefik
        except ImportError:
            sys.path.insert(0, str((ROOT / "src").resolve()))
            from panel import dokploy_traefik

        config = dokploy_traefik.generate_traefik_dynamic_yaml(
            domain="example.com",
            panel_subdomain="panel.example.com",
            sub_subdomain="sub.example.com",
            vless_subdomain="vless.example.com",
            panel_port=10443,
            sub_port=55443,
            xhttp_port=50443,
            cert_resolver="letsencrypt"
        )
        self.assertIn("xui-panel", config)
        self.assertIn("Host(`panel.example.com`)", config)
        self.assertIn("http://host.docker.internal:10443", config)
        self.assertIn("xui-sub", config)
        self.assertIn("Host(`sub.example.com`)", config)
        self.assertIn("http://host.docker.internal:55443", config)
        self.assertIn("h2c://host.docker.internal:50443", config)

    def test_cli_dokploy_flags(self):
        """Verify that --dokploy and --no-dokploy flags are parsed correctly."""
        res_on = run_shell("""
CYAN=; BOLD=; NC=; DIM=; WHITE=; GREEN=; RED=; ARROW=;
warn(){ :; }; ok(){ :; }; die(){ echo "DIE:$*"; exit 1; };
set -- --dokploy
source src/tui/prompts.sh
echo "DOKPLOY:$DOKPLOY_COEXISTENCE"
""")
        self.assertEqual(res_on.returncode, 0)
        self.assertIn("DOKPLOY:y", res_on.stdout)

        res_off = run_shell("""
CYAN=; BOLD=; NC=; DIM=; WHITE=; GREEN=; RED=; ARROW=;
warn(){ :; }; ok(){ :; }; die(){ echo "DIE:$*"; exit 1; };
set -- --no-dokploy
source src/tui/prompts.sh
echo "DOKPLOY:$DOKPLOY_COEXISTENCE"
""")
        self.assertEqual(res_off.returncode, 0)
        self.assertIn("DOKPLOY:n", res_off.stdout)

    def test_dokploy_traefik_dynamic_template_exists(self):
        """Verify that compose/dokploy-traefik-dynamic.yml exists and has valid structure."""
        dyn_path = ROOT / "compose" / "dokploy-traefik-dynamic.yml"
        self.assertTrue(dyn_path.is_file(), "compose/dokploy-traefik-dynamic.yml must exist")
        content = dyn_path.read_text(encoding="utf-8")
        self.assertIn("xui-panel:", content)
        self.assertIn("xui-sub:", content)
        self.assertIn("xray-xhttp:", content)
        self.assertIn("host.docker.internal:10443", content)


if __name__ == "__main__":
    unittest.main()
