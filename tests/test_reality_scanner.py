"""
tests/test_reality_scanner.py - Unit tests for autonomous REALITY scanner engine.
"""

from __future__ import annotations

import io
import json
import socket
import ssl
import sys
import unittest
from unittest.mock import MagicMock, patch

from src.xray.reality_scanner import (
    DEFAULT_CANDIDATES,
    RealityBatchScanner,
    RealityTargetProbe,
    clean_and_filter_sans,
    get_base_domain,
    is_private_ip,
    main,
    parse_der_san,
    split_target,
)


class TestRealityScanner(unittest.TestCase):
    def test_get_base_domain(self):
        self.assertEqual(get_base_domain("www.microsoft.com"), "microsoft.com")
        self.assertEqual(get_base_domain("dl.google.com"), "google.com")
        self.assertEqual(get_base_domain("apple.com"), "apple.com")
        self.assertEqual(get_base_domain("www.apple.com.cn"), "apple.com.cn")
        self.assertEqual(get_base_domain("speed.cloudflare.co.uk"), "cloudflare.co.uk")
        self.assertEqual(get_base_domain("localhost"), "localhost")
        # Short SLDs across gTLDs must NOT be treated as ccTLD pairs
        self.assertEqual(get_base_domain("www.ibm.com"), "ibm.com")
        self.assertEqual(get_base_domain("dl.box.com"), "box.com")
        self.assertEqual(get_base_domain("api.app.io"), "app.io")
        self.assertEqual(get_base_domain("web.cdn.com"), "cdn.com")
        self.assertEqual(get_base_domain("www.dev.org"), "dev.org")

    def test_split_target(self):
        self.assertEqual(split_target("www.microsoft.com:443"), ("www.microsoft.com", 443))
        self.assertEqual(split_target("dl.google.com"), ("dl.google.com", 443))
        self.assertEqual(split_target("example.com:8443"), ("example.com", 8443))
        self.assertEqual(split_target("example.com:99999"), ("example.com", 443))
        # URL stripping and IPv6 brackets
        self.assertEqual(split_target("https://speed.cloudflare.com/"), ("speed.cloudflare.com", 443))
        self.assertEqual(split_target("http://dl.google.com:8080/test"), ("dl.google.com", 8080))
        self.assertEqual(split_target("[2600:1f18::1]:8443"), ("2600:1f18::1", 8443))
        self.assertEqual(split_target("[::1]"), ("::1", 443))
        self.assertEqual(split_target("WWW.MICROSOFT.COM"), ("www.microsoft.com", 443))

    def test_is_private_ip(self):
        self.assertTrue(is_private_ip("127.0.0.1"))
        self.assertTrue(is_private_ip("10.0.0.5"))
        self.assertTrue(is_private_ip("192.168.1.1"))
        self.assertTrue(is_private_ip("172.16.0.10"))
        self.assertTrue(is_private_ip("::1"))
        self.assertTrue(is_private_ip("224.0.0.1"))  # Multicast
        self.assertTrue(is_private_ip("240.0.0.1"))  # Reserved
        self.assertTrue(is_private_ip("0.0.0.0"))
        self.assertFalse(is_private_ip("1.1.1.1"))
        self.assertFalse(is_private_ip("8.8.8.8"))
        self.assertFalse(is_private_ip("invalid-ip"))

    def test_clean_and_filter_sans_preserves_target_at_index_zero(self):
        # Target dl.google.com with wildcard certificate where dl.google.com is not an explicit SAN
        raw_sans = ["*.google.com", "*.cloud.google.com", "*.origin-test.bdn.dev", "android.clients.google.com"]
        pool = clean_and_filter_sans("dl.google.com", raw_sans, max_pool=4)

        self.assertEqual(pool[0], "dl.google.com")
        self.assertIn("google.com", pool)
        self.assertIn("android.clients.google.com", pool)
        # origin-test.bdn.dev should be filtered out
        self.assertNotIn("origin-test.bdn.dev", pool)
        self.assertNotIn("*.origin-test.bdn.dev", pool)
        self.assertLessEqual(len(pool), 4)

    def test_clean_and_filter_sans_removes_noisy_subdomains(self):
        raw_sans = [
            "wwwqa.microsoft.com",
            "www.microsoft.com",
            "staticview.microsoft.com",
            "microsoft.com",
            "dev-admin.microsoft.com",
            "staging-test.microsoft.com",
            "internal.microsoft.com",
            "privacy.microsoft.com",
        ]
        pool = clean_and_filter_sans("www.microsoft.com", raw_sans, max_pool=4)

        self.assertEqual(pool[0], "www.microsoft.com")
        self.assertNotIn("dev-admin.microsoft.com", pool)
        self.assertNotIn("staging-test.microsoft.com", pool)
        self.assertNotIn("internal.microsoft.com", pool)
        self.assertLessEqual(len(pool), 4)

    def test_clean_and_filter_sans_caps_to_specified_limit(self):
        raw_sans = [f"sub{i}.example.com" for i in range(20)]
        pool = clean_and_filter_sans("www.example.com", raw_sans, max_pool=3)
        self.assertEqual(len(pool), 3)
        self.assertEqual(pool[0], "www.example.com")

    def test_clean_and_filter_sans_default_limit_is_eight(self):
        raw_sans = [f"sub{i}.example.com" for i in range(20)]
        pool = clean_and_filter_sans("www.example.com", raw_sans)
        self.assertEqual(len(pool), 8)
        self.assertEqual(pool[0], "www.example.com")

    def test_parse_der_san_synthetic_bytes(self):
        # Build synthetic ASN.1 DER with SAN extension (06 03 55 1d 11)
        # extnValue: OCTET STRING (04) containing SEQUENCE (30) of dNSName (82)
        dns1 = b"www.example.com"
        dns2 = b"api.example.com"
        gen_names = bytes([0x82, len(dns1)]) + dns1 + bytes([0x82, len(dns2)]) + dns2
        seq = bytes([0x30, len(gen_names)]) + gen_names
        octet = bytes([0x04, len(seq)]) + seq
        oid = b"\x06\x03\x55\x1d\x11"
        der = b"\x30\x50\x00\x00" + oid + octet + b"\x00\x00"

        sans = parse_der_san(der)
        self.assertEqual(sans, ["www.example.com", "api.example.com"])

    def test_parse_der_san_malformed_input(self):
        self.assertEqual(parse_der_san(b""), [])
        self.assertEqual(parse_der_san(b"\x00\x01\x02\x03"), [])
        self.assertEqual(parse_der_san(b"\x06\x03\x55\x1d\x11\x04\xff\xff"), [])

    @patch("src.xray.reality_scanner.socket.getaddrinfo")
    @patch("src.xray.reality_scanner.socket.create_connection")
    @patch("src.xray.reality_scanner.ssl.create_default_context")
    def test_probe_feasible_target(self, mock_ctx_factory, mock_create_conn, mock_getaddrinfo):
        mock_getaddrinfo.return_value = [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("1.1.1.1", 443))
        ]
        mock_sock = MagicMock()
        mock_create_conn.return_value.__enter__.return_value = mock_sock

        mock_ssock = MagicMock()
        mock_ssock.version.return_value = "TLSv1.3"
        mock_ssock.selected_alpn_protocol.return_value = "h2"
        mock_ssock.getpeercert.return_value = {
            "subject": ((("commonName", "www.example.com"),),),
            "issuer": ((("organizationName", "Example CA"),),),
            "notAfter": "Jan 01 00:00:00 2028 GMT",
            "subjectAltName": (
                ("DNS", "www.example.com"),
                ("DNS", "example.com"),
                ("DNS", "cdn.example.com"),
            ),
        }

        mock_ctx = MagicMock()
        mock_ctx.wrap_socket.return_value.__enter__.return_value = mock_ssock
        mock_ctx_factory.return_value = mock_ctx

        prober = RealityTargetProbe(timeout=2.0, max_pool=4)
        res = prober.probe("www.example.com:443")

        self.assertTrue(res["feasible"])
        self.assertTrue(res["tls13"])
        self.assertTrue(res["h2"])
        self.assertTrue(res["certValid"])
        self.assertEqual(res["host"], "www.example.com")
        self.assertEqual(res["serverNames"][0], "www.example.com")
        self.assertIn("example.com", res["serverNames"])
        self.assertEqual(res["reason"], "")

    @patch("src.xray.reality_scanner.socket.getaddrinfo")
    def test_probe_blocks_private_target(self, mock_getaddrinfo):
        mock_getaddrinfo.return_value = [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 443))
        ]
        prober = RealityTargetProbe(timeout=1.0, allow_private=False)
        res = prober.probe("localhost")

        self.assertFalse(res["feasible"])
        self.assertTrue(res["privateTarget"])
        self.assertIn("blocked", res["reason"])

    def test_reality_batch_scanner_sorts_feasible_first_and_lowest_latency(self):
        scanner = RealityBatchScanner(candidates=["a.com", "b.com", "c.com"])
        mock_results = [
            {"target": "c.com:443", "host": "c.com", "feasible": False, "latencyMs": 10},
            {"target": "b.com:443", "host": "b.com", "feasible": True, "latencyMs": 80},
            {"target": "a.com:443", "host": "a.com", "feasible": True, "latencyMs": 20},
        ]
        with patch.object(RealityTargetProbe, "probe", side_effect=mock_results):
            results = scanner.scan()
            self.assertEqual(len(results), 3)
            # a.com (20ms, feasible) must be first
            self.assertEqual(results[0]["host"], "a.com")
            # b.com (80ms, feasible) second
            self.assertEqual(results[1]["host"], "b.com")
            # c.com (infeasible) last
            self.assertEqual(results[2]["host"], "c.com")

    @patch("src.xray.reality_scanner.RealityTargetProbe.probe")
    def test_cli_probe_json(self, mock_probe):
        mock_probe.return_value = {
            "target": "www.microsoft.com:443",
            "host": "www.microsoft.com",
            "port": 443,
            "ip": "192.0.2.2",
            "feasible": True,
            "tls13": True,
            "tlsVersion": "1.3",
            "h2": True,
            "alpn": "h2",
            "x25519": True,
            "curveID": "X25519",
            "certValid": True,
            "certSubject": "www.microsoft.com",
            "certIssuer": "Microsoft Corporation",
            "notAfter": "2027-01-01T00:00:00Z",
            "serverNames": ["www.microsoft.com", "microsoft.com"],
            "latencyMs": 25,
            "reason": "",
            "latency_ms": 25,
            "server_names": ["www.microsoft.com", "microsoft.com"],
            "pool_str": "www.microsoft.com microsoft.com",
        }

        out = io.StringIO()
        with patch("sys.stdout", out):
            code = main(["--probe", "www.microsoft.com", "--json"])

        self.assertEqual(code, 0)
        parsed = json.loads(out.getvalue())
        self.assertEqual(parsed["host"], "www.microsoft.com")
        self.assertTrue(parsed["feasible"])
        self.assertEqual(parsed["pool_str"], "www.microsoft.com microsoft.com")

    @patch("src.xray.reality_scanner.RealityBatchScanner.scan")
    def test_cli_scan_defaults_json(self, mock_scan):
        mock_scan.return_value = [
            {
                "target": "www.cloudflare.com:443",
                "host": "www.cloudflare.com",
                "feasible": True,
                "latencyMs": 18,
                "serverNames": ["www.cloudflare.com"],
                "pool_str": "www.cloudflare.com",
            }
        ]

        out = io.StringIO()
        with patch("sys.stdout", out):
            code = main(["--scan-defaults", "--json"])

        self.assertEqual(code, 0)
        parsed = json.loads(out.getvalue())
        self.assertIsInstance(parsed, list)
        self.assertEqual(len(parsed), 1)
        self.assertEqual(parsed[0]["host"], "www.cloudflare.com")


    def test_clean_and_filter_sans_multilevel_wildcards(self):
        raw_sans = ["*.google.com", "*.cloud.google.com", "*.aistudio.google.com", "g.co"]
        pool = clean_and_filter_sans("dl.google.com", raw_sans, max_pool=4)
        self.assertEqual(pool[0], "dl.google.com")
        self.assertIn("google.com", pool)
        self.assertIn("cloud.google.com", pool)
        self.assertIn("aistudio.google.com", pool)

    def test_parse_der_san_with_false_positive_preceding_bytes(self):
        # Insert false positive b"\x55\x1d\x11" before the real extension
        dns = b"valid.example.com"
        gen_names = bytes([0x82, len(dns)]) + dns
        seq = bytes([0x30, len(gen_names)]) + gen_names
        octet = bytes([0x04, len(seq)]) + seq
        real_oid = b"\x06\x03\x55\x1d\x11"
        # Prefix contains random \x55\x1d\x11 without OID tag 0x06
        prefix = b"\x30\x20\x00\x55\x1d\x11\x99\x88\x77"
        der = prefix + real_oid + octet

        sans = parse_der_san(der)
        self.assertEqual(sans, ["valid.example.com"])

    @patch("src.xray.reality_scanner.socket.getaddrinfo")
    @patch("src.xray.reality_scanner.socket.create_connection")
    @patch("src.xray.reality_scanner.ssl.create_default_context")
    def test_probe_tls12_server_diagnostic(self, mock_ctx_factory, mock_create_conn, mock_getaddrinfo):
        mock_getaddrinfo.return_value = [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("1.1.1.1", 443))
        ]
        mock_sock = MagicMock()
        mock_create_conn.return_value.__enter__.return_value = mock_sock

        mock_ssock = MagicMock()
        mock_ssock.version.return_value = "TLSv1.2"
        mock_ssock.selected_alpn_protocol.return_value = "h2"
        mock_ssock.getpeercert.return_value = {
            "subject": ((("commonName", "www.example.com"),),),
            "issuer": ((("organizationName", "Example CA"),),),
        }

        mock_ctx = MagicMock()
        mock_ctx.wrap_socket.return_value.__enter__.return_value = mock_ssock
        mock_ctx_factory.return_value = mock_ctx

        prober = RealityTargetProbe(timeout=2.0)
        res = prober.probe("www.example.com")

        self.assertFalse(res["feasible"])
        self.assertFalse(res["tls13"])
        self.assertEqual(res["tlsVersion"], "TLSv1.2")
        self.assertIn("TLS 1.3", res["reason"])

    @patch("src.xray.reality_scanner.socket.getaddrinfo")
    @patch("src.xray.reality_scanner.socket.create_connection")
    @patch("src.xray.reality_scanner.ssl.create_default_context")
    def test_probe_non_h2_alpn_diagnostic(self, mock_ctx_factory, mock_create_conn, mock_getaddrinfo):
        mock_getaddrinfo.return_value = [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("1.1.1.1", 443))
        ]
        mock_sock = MagicMock()
        mock_create_conn.return_value.__enter__.return_value = mock_sock

        mock_ssock = MagicMock()
        mock_ssock.version.return_value = "TLSv1.3"
        mock_ssock.selected_alpn_protocol.return_value = "http/1.1"
        mock_ssock.getpeercert.return_value = {
            "subject": ((("commonName", "www.example.com"),),),
            "issuer": ((("organizationName", "Example CA"),),),
        }

        mock_ctx = MagicMock()
        mock_ctx.wrap_socket.return_value.__enter__.return_value = mock_ssock
        mock_ctx_factory.return_value = mock_ctx

        prober = RealityTargetProbe(timeout=2.0)
        res = prober.probe("www.example.com")

        self.assertFalse(res["feasible"])
        self.assertTrue(res["tls13"])
        self.assertFalse(res["h2"])
        self.assertEqual(res["alpn"], "http/1.1")
        self.assertIn("HTTP/2", res["reason"])

    def test_reality_batch_scanner_handles_none_latency(self):
        scanner = RealityBatchScanner(candidates=["a.com", "b.com"])
        mock_results = [
            {"target": "b.com:443", "host": "b.com", "feasible": False, "latencyMs": None},
            {"target": "a.com:443", "host": "a.com", "feasible": False, "latencyMs": 20},
        ]
        with patch.object(RealityTargetProbe, "probe", side_effect=mock_results):
            results = scanner.scan()
            self.assertEqual(len(results), 2)
            self.assertEqual(results[0]["host"], "a.com")
            self.assertEqual(results[1]["host"], "b.com")


if __name__ == "__main__":
    unittest.main()
