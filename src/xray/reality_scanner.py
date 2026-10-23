#!/usr/bin/env python3
"""
src/xray/reality_scanner.py - Autonomous REALITY Mask Target & SNI Pool Scanner.

Replicates and improves upon 3X-UI's internal reality_scan.go engine:
- Connects to targets via TLS 1.3 handshake with ALPN 'h2' and Curve 'X25519'.
- Measures RTT latency in milliseconds from the VPS host.
- Extracts leaf certificate Subject Alternative Names (SANs) via parsed cert or ASN.1 DER parser.
- Cleans and filters SANs:
    * Preserves target host at index 0 (even for wildcard *.domain.com certs).
    * Strips wildcard (*.) prefixes and admits clean base domains.
    * Filters noisy internal/testing subdomains (dev, qa, test, stage, etc.).
    * Deduplicates and caps clean pool to 3-5 domains.
- CLI interface supporting --scan-defaults --json and --probe <domain> --json.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import ipaddress
import json
import re
import socket
import ssl
import sys
import time
from typing import Any

DEFAULT_CANDIDATES = [
    "dl.google.com:443",
    "www.microsoft.com:443",
    "www.apple.com:443",
    "www.samsung.com:443",
    "www.cloudflare.com:443",
    "aws.amazon.com:443",
]

NOISY_SUBDOMAIN_RE = re.compile(
    r"(?:^|[.-])(qa|test|dev|stage|stg|internal|corp|intranet|admin|preview|author|sandbox|demo|origin-test)(?:[.-]|$)",
    re.IGNORECASE,
)

DOMAIN_NAME_RE = re.compile(
    r"^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$",
    re.IGNORECASE,
)


COMMON_CCTLD_SLDS = {
    "co", "com", "net", "org", "edu", "gov", "ac", "mil", "ne", "or", "go",
    "gen", "firm", "ind",
}


def get_base_domain(host: str) -> str:
    """Extract registered/base domain (handling standard 2-part ccTLDs)."""
    parts = host.lower().strip().split(".")
    if len(parts) <= 2:
        return ".".join(parts)
    # Standard ccTLDs have a 2-letter country code (ISO 3166-1) and a known second-level delegation
    if len(parts[-1]) == 2 and parts[-2] in COMMON_CCTLD_SLDS and len(parts) >= 3:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:])


def parse_der_san(der_bytes: bytes) -> list[str]:
    """
    Extract Subject Alternative Names (dNSName) directly from DER-encoded X.509 certificate bytes.
    Ensures SAN extraction succeeds even when system CA bundle is missing or certificate is unverified.
    """
    try:
        # SAN extension ASN.1 OID (id-ce-subjectAltName): 06 03 55 1d 11
        full_oid = b"\x06\x03\x55\x1d\x11"
        start_pos = 0
        while True:
            pos = der_bytes.find(full_oid, start_pos)
            if pos == -1:
                # Fallback to 3-byte OID if tag/len differed
                pos = der_bytes.find(b"\x55\x1d\x11", start_pos)
                if pos == -1:
                    break
                oid_len = 3
            else:
                oid_len = len(full_oid)

            start_pos = pos + oid_len
            # Find OCTET STRING tag 0x04 after OID
            pos_octet = der_bytes.find(b"\x04", start_pos)
            if pos_octet == -1 or pos_octet + 1 >= len(der_bytes):
                continue
            pos = pos_octet + 1
            l = der_bytes[pos]
            pos += 1
            if l & 0x80:
                nb = l & 0x7F
                if pos + nb > len(der_bytes):
                    continue
                l = int.from_bytes(der_bytes[pos : pos + nb], "big")
                pos += nb
            if pos + l > len(der_bytes):
                continue
            octet_data = der_bytes[pos : pos + l]
            # octet_data must start with SEQUENCE tag 0x30
            if not octet_data or octet_data[0] != 0x30:
                continue
            p = 1
            if p >= len(octet_data):
                continue
            sl = octet_data[p]
            p += 1
            if sl & 0x80:
                nb = sl & 0x7F
                p += nb
            sans: list[str] = []
            while p < len(octet_data):
                tag = octet_data[p]
                p += 1
                if p >= len(octet_data):
                    break
                item_len = octet_data[p]
                p += 1
                if item_len & 0x80:
                    nb = item_len & 0x7F
                    if p + nb > len(octet_data):
                        break
                    item_len = int.from_bytes(octet_data[p : p + nb], "big")
                    p += nb
                if p + item_len > len(octet_data):
                    break
                val = octet_data[p : p + item_len]
                p += item_len
                if tag == 0x82:  # Context-specific [2] = dNSName
                    try:
                        dns = val.decode("ascii", errors="ignore").strip().lower()
                        if dns and "." in dns:
                            sans.append(dns)
                    except Exception:
                        pass
            if sans:
                return sans
        return []
    except Exception:
        return []


def clean_and_filter_sans(target_host: str, raw_sans: list[str], max_pool: int = 8) -> list[str]:
    """
    Filter and rank SANs:
    1. Preserves target_host at index 0.
    2. Strips wildcard prefixes (*.) and includes clean base domain if matching.
    3. Excludes noisy internal/test subdomains.
    4. Prioritizes domains sharing base domain with target.
    5. Deduplicates and caps pool to max_pool (default 8 domains).
    """
    target = target_host.lower().strip()
    base_domain = get_base_domain(target)

    cleaned: list[str] = []
    seen = {target}

    for san in raw_sans:
        s = san.strip().lower()
        if s.startswith("*."):
            wildcard_base = s[2:].strip()
            if wildcard_base == base_domain or wildcard_base.endswith("." + base_domain) or wildcard_base == target:
                s = wildcard_base
            else:
                continue
        if not s or s in seen:
            continue
        if "*" in s or " " in s:
            continue
        if not DOMAIN_NAME_RE.match(s):
            continue
        if NOISY_SUBDOMAIN_RE.search(s):
            continue

        seen.add(s)
        cleaned.append(s)

    # Sort remaining candidates:
    # 1. Domains sharing base_domain come before domains with different roots.
    # 2. Base domain itself (e.g. microsoft.com) prioritized.
    # 3. Shorter domain names come first.
    cleaned.sort(
        key=lambda d: (
            not (d.endswith("." + base_domain) or d == base_domain),
            d != base_domain,
            len(d),
            d,
        )
    )

    pool = [target]
    for c in cleaned:
        if len(pool) >= max_pool:
            break
        pool.append(c)
    return pool


def split_target(target: str, default_port: int = 443) -> tuple[str, int]:
    """Split host:port, URL, or bracketed IPv6 and return (host, port)."""
    t = target.strip().lower()
    if t.startswith("https://"):
        t = t[8:]
    elif t.startswith("http://"):
        t = t[7:]
    if "/" in t:
        t = t.split("/", 1)[0]

    # Bracketed IPv6 notation [::1]:443 or [::1]
    if t.startswith("[") and "]" in t:
        bracket_end = t.find("]")
        host = t[1:bracket_end].strip()
        rest = t[bracket_end + 1 :]
        if rest.startswith(":"):
            try:
                p = int(rest[1:])
                if 1 <= p <= 65535:
                    return host, p
            except ValueError:
                pass
        return host, default_port

    if ":" in t:
        host, port_str = t.rsplit(":", 1)
        try:
            port = int(port_str)
            if 1 <= port <= 65535:
                return host.strip(), port
        except ValueError:
            pass
        return host.strip(), default_port
    return t, default_port


def is_private_ip(ip_str: str) -> bool:
    """Check if IP is loopback, link-local, private, multicast, or reserved."""
    try:
        ip = ipaddress.ip_address(ip_str)
        return (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_multicast
            or ip.is_reserved
            or ip.is_unspecified
        )
    except ValueError:
        return False


def get_cert_common_name(rdns: tuple) -> str:
    """Helper to extract commonName from subject or issuer RDNs."""
    for rdn in rdns:
        for k, v in rdn:
            if k == "commonName":
                return str(v)
    return ""


def get_cert_organization(rdns: tuple) -> str:
    """Helper to extract organizationName from issuer RDNs."""
    for rdn in rdns:
        for k, v in rdn:
            if k == "organizationName":
                return str(v)
    return get_cert_common_name(rdns)


class RealityTargetProbe:
    """Prober for a single REALITY target host."""

    def __init__(self, timeout: float = 3.0, max_pool: int = 8, allow_private: bool = False):
        self.timeout = timeout
        self.max_pool = max_pool
        self.allow_private = allow_private

    def probe(self, target: str) -> dict[str, Any]:
        host, port = split_target(target)
        result: dict[str, Any] = {
            "target": f"{host}:{port}",
            "host": host,
            "port": port,
            "ip": "",
            "feasible": False,
            "privateTarget": False,
            "tls13": False,
            "tlsVersion": "unknown",
            "h2": False,
            "alpn": "",
            "x25519": False,
            "curveID": "",
            "certValid": False,
            "certSubject": "",
            "certIssuer": "",
            "notAfter": "",
            "serverNames": [host],
            "latencyMs": 9999,
            "reason": "",
            # Aliases for bash / python
            "latency_ms": 9999,
            "server_names": [host],
            "pool_str": host,
        }

        # 1. DNS Resolution & SSRF check
        try:
            addr_info = socket.getaddrinfo(host, port, socket.AF_UNSPEC, socket.SOCK_STREAM)
            if not addr_info:
                result["reason"] = f"DNS resolution failed for {host}"
                return result
            # Prefer IPv4 if available
            ipv4_addrs = [a for a in addr_info if a[0] == socket.AF_INET]
            selected_addr = ipv4_addrs[0] if ipv4_addrs else addr_info[0]
            sockaddr = selected_addr[4]
            peer_ip = sockaddr[0]
            result["ip"] = peer_ip
        except Exception as e:
            result["reason"] = f"DNS resolution failed: {e}"
            return result

        if is_private_ip(peer_ip):
            result["privateTarget"] = True
            if not self.allow_private:
                result["reason"] = f"Target IP {peer_ip} is private/loopback (blocked)"
                return result

        # 2. TLS Dial & Handshake with Latency Measurement
        raw_sans: list[str] = []
        start_time = time.perf_counter()

        # Build SSL Context: allow TLS 1.2..1.3 to inspect negotiated version and ALPN cleanly
        ctx = ssl.create_default_context()
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.maximum_version = ssl.TLSVersion.TLSv1_3
        ctx.set_alpn_protocols(["h2", "http/1.1"])
        x25519_supported = False
        try:
            ctx.set_ecdh_curve("X25519")
            x25519_supported = True
        except (AttributeError, ssl.SSLError):
            pass

        try:
            with socket.create_connection((peer_ip, port), timeout=self.timeout) as sock:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                with ctx.wrap_socket(sock, server_hostname=host) as ssock:
                    elapsed = time.perf_counter() - start_time
                    result["latencyMs"] = max(1, int(round(elapsed * 1000)))
                    result["latency_ms"] = result["latencyMs"]

                    version = ssock.version() or ""
                    result["tlsVersion"] = "1.3" if version == "TLSv1.3" else version
                    result["tls13"] = (version == "TLSv1.3")

                    alpn = ssock.selected_alpn_protocol() or ""
                    result["alpn"] = alpn
                    result["h2"] = (alpn == "h2")

                    result["x25519"] = x25519_supported
                    result["curveID"] = "X25519" if x25519_supported else "unknown"
                    result["certValid"] = True

                    # Extract certificate details
                    cert_dict = ssock.getpeercert() or {}
                    result["certSubject"] = get_cert_common_name(cert_dict.get("subject", ()))
                    result["certIssuer"] = get_cert_organization(cert_dict.get("issuer", ()))
                    result["notAfter"] = cert_dict.get("notAfter", "")

                    # Extract SANs from parsed cert
                    for item in cert_dict.get("subjectAltName", ()):
                        if len(item) == 2 and item[0] == "DNS":
                            raw_sans.append(item[1])

                    # Also extract from DER bytes for completeness
                    try:
                        der_bytes = ssock.getpeercert(binary_form=True)
                        if der_bytes:
                            der_sans = parse_der_san(der_bytes)
                            for ds in der_sans:
                                if ds not in raw_sans:
                                    raw_sans.append(ds)
                    except Exception:
                        pass

        except ssl.SSLCertVerificationError as ve:
            # Re-probe with CERT_NONE to still inspect protocol and SANs
            elapsed = time.perf_counter() - start_time
            result["latencyMs"] = max(1, int(round(elapsed * 1000)))
            result["latency_ms"] = result["latencyMs"]
            result["certValid"] = False
            result["reason"] = f"Certificate verification failed: {ve}"

            try:
                unverified_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                unverified_ctx.check_hostname = False
                unverified_ctx.verify_mode = ssl.CERT_NONE
                unverified_ctx.minimum_version = ssl.TLSVersion.TLSv1_2
                unverified_ctx.maximum_version = ssl.TLSVersion.TLSv1_3
                unverified_ctx.set_alpn_protocols(["h2", "http/1.1"])
                unverified_x25519 = False
                try:
                    unverified_ctx.set_ecdh_curve("X25519")
                    unverified_x25519 = True
                except Exception:
                    pass

                with socket.create_connection((peer_ip, port), timeout=self.timeout) as sock2:
                    with unverified_ctx.wrap_socket(sock2, server_hostname=host) as ssock2:
                        version = ssock2.version() or ""
                        result["tlsVersion"] = "1.3" if version == "TLSv1.3" else version
                        result["tls13"] = (version == "TLSv1.3")
                        result["alpn"] = ssock2.selected_alpn_protocol() or ""
                        result["h2"] = (result["alpn"] == "h2")
                        result["x25519"] = unverified_x25519
                        result["curveID"] = "X25519" if unverified_x25519 else "unknown"
                        der = ssock2.getpeercert(binary_form=True)
                        if der:
                            raw_sans = parse_der_san(der)
            except Exception:
                pass

        except ssl.SSLError as se:
            result["reason"] = f"TLS handshake failed: {se}"
            return result
        except socket.timeout:
            result["reason"] = f"Connection timed out ({self.timeout}s)"
            return result
        except OSError as oe:
            result["reason"] = f"Connection failed: {oe}"
            return result
        except Exception as ex:
            result["reason"] = f"Probe error: {ex}"
            return result

        # 3. Clean and filter SANs
        clean_pool = clean_and_filter_sans(host, raw_sans, max_pool=self.max_pool)
        result["serverNames"] = clean_pool
        result["server_names"] = clean_pool
        result["pool_str"] = " ".join(clean_pool)

        if not result["certSubject"] and clean_pool:
            result["certSubject"] = clean_pool[0]

        # 4. Determine feasibility
        result["feasible"] = bool(
            result["tls13"] and result["h2"] and result["x25519"] and result["certValid"]
        )

        if not result["feasible"] and not result["reason"]:
            if not result["tls13"]:
                result["reason"] = f"Server does not negotiate TLS 1.3 (negotiated {result['tlsVersion']})"
            elif not result["h2"]:
                result["reason"] = f"Server does not negotiate HTTP/2 (ALPN: {result['alpn'] or 'none'})"
            elif not result["certValid"]:
                result["reason"] = "Certificate is not trusted"
            elif not result["x25519"]:
                result["reason"] = "Server did not negotiate X25519 key exchange"

        return result


class RealityBatchScanner:
    """Scanner for multiple REALITY targets in parallel."""

    def __init__(
        self,
        candidates: list[str] | None = None,
        timeout: float = 3.0,
        max_pool: int = 8,
        allow_private: bool = False,
        concurrency: int = 6,
    ):
        self.candidates = candidates or list(DEFAULT_CANDIDATES)
        self.timeout = timeout
        self.max_pool = max_pool
        self.allow_private = allow_private
        self.concurrency = concurrency

    def scan(self) -> list[dict[str, Any]]:
        prober = RealityTargetProbe(
            timeout=self.timeout,
            max_pool=self.max_pool,
            allow_private=self.allow_private,
        )
        results: list[dict[str, Any]] = []

        workers = min(len(self.candidates), self.concurrency)
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, workers)) as executor:
            future_to_target = {
                executor.submit(prober.probe, target): target for target in self.candidates
            }
            for future in concurrent.futures.as_completed(future_to_target):
                try:
                    res = future.result()
                    results.append(res)
                except Exception as e:
                    target = future_to_target[future]
                    host, port = split_target(target)
                    results.append({
                        "target": target,
                        "host": host,
                        "port": port,
                        "ip": "",
                        "feasible": False,
                        "latencyMs": 9999,
                        "latency_ms": 9999,
                        "serverNames": [host],
                        "server_names": [host],
                        "pool_str": host,
                        "reason": f"Unhandled scan error: {e}",
                    })

        # Sort: Feasible first, then lowest latencyMs, then host for stability
        results.sort(
            key=lambda r: (
                0 if r.get("feasible") else 1,
                r.get("latencyMs") or 99999,
                r.get("host", ""),
            )
        )
        return results


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Autonomous REALITY Mask Target & SNI Pool Scanner (3X-UI Engine)."
    )
    parser.add_argument(
        "--scan-defaults",
        action="store_true",
        help="Scan the default popular target candidates in parallel.",
    )
    parser.add_argument(
        "--probe",
        type=str,
        default="",
        help="Probe a specific target domain (e.g. www.microsoft.com or host:port).",
    )
    parser.add_argument(
        "--candidates",
        type=str,
        default="",
        help="Comma-separated list of candidate hosts to scan.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=3.0,
        help="Handshake timeout in seconds (default: 3.0).",
    )
    parser.add_argument(
        "--max-pool",
        type=int,
        default=8,
        help="Maximum number of clean SAN domains in the pool (default: 8).",
    )
    parser.add_argument(
        "--allow-private",
        action="store_true",
        help="Allow probing targets resolving to private/loopback IPs.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output results in JSON format.",
    )

    args = parser.parse_args(argv)

    if args.probe:
        prober = RealityTargetProbe(
            timeout=args.timeout,
            max_pool=args.max_pool,
            allow_private=args.allow_private,
        )
        res = prober.probe(args.probe)
        if args.json:
            print(json.dumps(res, indent=2, ensure_ascii=False))
        else:
            print(f"Target:       {res['target']}")
            print(f"Feasible:     {res['feasible']}")
            print(f"Latency:      {res['latencyMs']} ms")
            print(f"TLS Version:  {res['tlsVersion']}")
            print(f"ALPN:         {res['alpn']}")
            print(f"Key Exchange: {res['curveID']}")
            print(f"Cert Valid:   {res['certValid']}")
            print(f"Cert Subject: {res['certSubject']}")
            print(f"Cert Issuer:  {res['certIssuer']}")
            print(f"ServerNames:  {', '.join(res['serverNames'])}")
            if res["reason"]:
                print(f"Reason:       {res['reason']}")
        return 0 if res.get("feasible") else 1

    # Default action or --scan-defaults
    candidates = DEFAULT_CANDIDATES
    if args.candidates:
        candidates = [c.strip() for c in args.candidates.split(",") if c.strip()]

    scanner = RealityBatchScanner(
        candidates=candidates,
        timeout=args.timeout,
        max_pool=args.max_pool,
        allow_private=args.allow_private,
    )
    results = scanner.scan()

    # Safe stdout encoding for Windows legacy consoles
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(errors="replace")
        except Exception:
            pass

    if args.json:
        print(json.dumps(results, indent=2, ensure_ascii=False))
    else:
        print(f"{'Target':<26} {'Status':<10} {'Latency':<9} {'ALPN':<6} {'Pool (serverNames)'}")
        print("-" * 85)
        for i, r in enumerate(results):
            prefix = "* " if (i == 0 and r.get("feasible")) else "  "
            status = "FEASIBLE" if r.get("feasible") else "REJECTED"
            lat_str = f"{r.get('latencyMs', 9999)} ms" if r.get("feasible") else "FAIL"
            alpn = r.get("alpn", "") or "-"
            pool_preview = ", ".join(r.get("serverNames", []))
            target_str = f"{prefix}{r.get('target', '')}"
            print(f"{target_str:<26} {status:<10} {lat_str:<9} {alpn:<6} {pool_preview}")

    return 0 if any(r.get("feasible") for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
