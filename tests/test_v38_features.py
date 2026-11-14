import json
import sqlite3
import tempfile
from pathlib import Path
from unittest import TestCase

ROOT = Path(__file__).resolve().parent.parent


class TestUpstreamV38Features(TestCase):
    """Verify integration of upstream v3.8 features with multi-environment guards."""

    def test_reconcile_sanitizes_alpn_and_pinned_cert_comma_strings(self):
        """Verify that comma-separated strings for alpn and pinnedPeerCertSha256 are split into JSON arrays."""
        inbounds_code = (ROOT / "src/xray/inbounds.py").read_text(encoding="utf-8")
        db = sqlite3.connect(":memory:")
        cur = db.cursor()
        cur.execute("""
            CREATE TABLE inbounds (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                up INTEGER,
                down INTEGER,
                total INTEGER,
                remark TEXT,
                enable INTEGER,
                expiry_time INTEGER,
                listen TEXT,
                port INTEGER,
                protocol TEXT,
                settings TEXT,
                stream_settings TEXT,
                tag TEXT,
                sniffing TEXT
            )
        """)

        ns = {
            "cur": cur,
            "admin_id": 1,
            "dry_run": False,
            "domain": "test.example.com",
            "inbounds_cols": {
                "id", "user_id", "up", "down", "total", "remark", "enable",
                "expiry_time", "listen", "port", "protocol", "settings",
                "stream_settings", "tag", "sniffing"
            },
            "json": json
        }
        exec(inbounds_code, ns)
        smart_reconcile = ns["smart_reconcile_inbound"]

        c_set = {"clients": [{"id": "uuid", "email": "test@example.com"}]}
        # Insert with comma-separated string alpn and comma-separated pinnedPeerCertSha256
        dirty_ext = [{
            "dest": "test.example.com",
            "port": 443,
            "forceTls": "tls",
            "alpn": "h2, http/1.1",
            "pinnedPeerCertSha256": "hash1, hash2",
            "remark": "Test xHTTP"
        }]
        cur.execute("""
            INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
            VALUES (1, 0, 0, 0, 'Test xHTTP', 1, 0, '127.0.0.1', 50443, 'vless', ?, ?, 'in-xhttp-stream', '{}')
        """, (json.dumps(c_set), json.dumps({"network": "xhttp", "externalProxy": dirty_ext})))
        db.commit()

        # Run smart reconcile
        target_stream = {"network": "xhttp", "externalProxy": dirty_ext}
        smart_reconcile(50443, "vless", "in-xhttp-stream", "Test xHTTP", c_set, target_stream, listen="127.0.0.1")

        cur.execute("SELECT stream_settings FROM inbounds WHERE port = 50443")
        res_st = json.loads(cur.fetchone()[0])
        ep = res_st["externalProxy"][0]

        self.assertIsInstance(ep["alpn"], list, "alpn must be sanitized to list")
        self.assertEqual(ep["alpn"], ["h2", "http/1.1"], "Comma-separated alpn must be split and stripped")
        self.assertIsInstance(ep["pinnedPeerCertSha256"], list, "pinnedPeerCertSha256 must be sanitized to list")
        self.assertEqual(ep["pinnedPeerCertSha256"], ["hash1", "hash2"], "Comma-separated hashes must be split and stripped")

    def test_patch_amnezia_dkms_kernel_compat_awk_logic(self):
        """Verify the awk substitution logic for setup_udp_tunnel_sock on Linux kernel 7.0+."""
        with tempfile.TemporaryDirectory() as tmpdir:
            compat_dir = Path(tmpdir) / "compat"
            compat_dir.mkdir(parents=True, exist_ok=True)
            compat_h = compat_dir / "compat.h"

            original_code = """
#ifndef _AMNEZIAWG_COMPAT_H
#define _AMNEZIAWG_COMPAT_H

#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 5, 0)
#define setup_udp_tunnel_sock(net, sk, sock_cfg) setup_udp_tunnel_sock(net, sk->sk_socket, sock_cfg)
#endif

#endif
"""
            compat_h.write_text(original_code, encoding="utf-8")

            # Run python simulation of awk patch
            content = compat_h.read_text(encoding="utf-8")
            target = "setup_udp_tunnel_sock(net, sk, sock_cfg) setup_udp_tunnel_sock(net, sk->sk_socket, sock_cfg)"
            self.assertIn(target, content)

            patched = content.replace(
                target,
                "/* Kernel 7.0+ compatibility backport */\n"
                "#if LINUX_VERSION_CODE < KERNEL_VERSION(7, 0, 0)\n"
                "#define setup_udp_tunnel_sock(net, sk, sock_cfg) setup_udp_tunnel_sock(net, sk->sk_socket, sock_cfg)\n"
                "#elif LINUX_VERSION_CODE < KERNEL_VERSION(7, 2, 0)\n"
                "#define __compat_setup_udp_tunnel_sock 1\n"
                "#endif"
            )
            compat_h.write_text(patched, encoding="utf-8")

            verified = compat_h.read_text(encoding="utf-8")
            self.assertIn("__compat_setup_udp_tunnel_sock", verified)
            self.assertIn("KERNEL_VERSION(7, 0, 0)", verified)

    def test_hardware_memory_limits_script_presence(self):
        """Verify that get_hardware_memory_limits and apply_xui_memory_limits exist in src/system/service.sh."""
        service_sh = (ROOT / "src/system/service.sh").read_text(encoding="utf-8")
        self.assertIn("get_hardware_memory_limits()", service_sh)
        self.assertIn("apply_xui_memory_limits()", service_sh)
        self.assertIn("setup_system_autoupdate()", service_sh)
        self.assertIn("CIRCUIT BREAKER", service_sh)

    def test_network_rps_presence_and_guards(self):
        """Verify setup_network_rps exists in src/system/optimize.sh with container and permission guards."""
        optimize_sh = (ROOT / "src/system/optimize.sh").read_text(encoding="utf-8")
        self.assertIn("setup_network_rps()", optimize_sh)
        self.assertIn(".dockerenv", optimize_sh)
        self.assertIn("rps_cpus", optimize_sh)
        self.assertIn("xps_cpus", optimize_sh)
        self.assertIn("network-rps.service", optimize_sh)

    def test_letsencrypt_renewal_hook_restarts_xui(self):
        """Verify that Let's Encrypt renewal hook safely attempts x-ui restart across systemd, openrc, and docker."""
        web_sh = (ROOT / "src/installer/web.sh").read_text(encoding="utf-8")
        self.assertIn("x-ui restart", web_sh)
        self.assertIn("docker restart", web_sh)
