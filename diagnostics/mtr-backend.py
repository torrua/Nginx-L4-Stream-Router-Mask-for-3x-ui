#!/usr/bin/env python3
"""
VPN Diagnostics and MTR Backend
High-performance, secure backend for network diagnostics, LibreSpeed and MTR.
Communicates via Unix domain socket with Nginx reverse proxy.
Hardened according to RELIABILITY_PLAN T18-T20:
- Bounded rate limiting with automatic pruning to prevent memory exhaustion
- Concurrency limiting via semaphores (global & per-client)
- Strict IP validation: loopback, private, link-local, multicast, reserved and IPv4-mapped bypass prevention
- Child process lifecycle tracking and guaranteed termination on shutdown
"""

import argparse
import ipaddress
import json
import logging
import os
import re
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# --- Constants ---
MAX_PACKET_COUNT = 100
MIN_PACKET_COUNT = 1
DEFAULT_PACKET_COUNT = 5
MTR_TIMEOUT = 360
RATE_LIMIT_WINDOW = 60
RATE_LIMIT_MAX = 3
MAX_RATE_STORE_ENTRIES = 1000
MAX_CONCURRENT_MTR = 2
MTR_BIN = "/usr/bin/mtr"
DEFAULT_CHUNK_SIZE = 1024 * 1024  # 1 MB chunk for streaming
MAX_DOWNLOAD_SIZE = 1024 * 1024 * 1024  # 1 GB max on-the-fly download
DEFAULT_DOWNLOAD_SIZE = 25 * 1024 * 1024  # 25 MB default

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("vpn-diagnostics")

# Concurrency and rate limiter synchronization
_mtr_semaphore = threading.Semaphore(MAX_CONCURRENT_MTR)
_rate_store = {}
_active_mtr_ips = set()
_active_lock = threading.Lock()
_active_subprocesses = set()
_subproc_lock = threading.Lock()


def rate_check(client_ip: str) -> bool:
    """Check rate limit for client IP with bounded store and automatic pruning."""
    now = time.monotonic()
    with _active_lock:
        # Periodic pruning if store grows
        if len(_rate_store) > MAX_RATE_STORE_ENTRIES:
            expired_ips = [
                ip for ip, tms in _rate_store.items()
                if not tms or (now - tms[-1] >= RATE_LIMIT_WINDOW)
            ]
            for ip in expired_ips:
                _rate_store.pop(ip, None)
            if len(_rate_store) > MAX_RATE_STORE_ENTRIES:
                for ip in list(_rate_store.keys())[:200]:
                    _rate_store.pop(ip, None)

        times = _rate_store.get(client_ip, [])
        times = [t for t in times if now - t < RATE_LIMIT_WINDOW]
        if len(times) >= RATE_LIMIT_MAX:
            _rate_store[client_ip] = times
            return False
        times.append(now)
        _rate_store[client_ip] = times
        return True


def validate_ip(raw: str) -> str:
    """Validate client IP, unmapping IPv4-mapped IPv6 and rejecting private/loopback/reserved."""
    cleaned = raw.strip()
    if not cleaned:
        raise ValueError("Missing client IP address")
    try:
        ip = ipaddress.ip_address(cleaned)
    except ValueError:
        raise ValueError(f"Invalid IP address format: {cleaned}")

    # Unmap IPv4-mapped IPv6 address (e.g. ::ffff:127.0.0.1 or ::ffff:10.0.0.1)
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped

    if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved or ip.is_unspecified:
        raise ValueError("MTR cannot be run against private, loopback, or reserved IP ranges")

    if not getattr(ip, "is_global", False):
        raise ValueError("MTR cannot be run against non-global IP ranges")

    return str(ip)


def parse_size_bytes(raw: str) -> int:
    """Parse size string like '15k', '100m', '1g' or integer bytes into integer."""
    raw = (raw or "").strip().lower()
    if not raw:
        return DEFAULT_DOWNLOAD_SIZE
    match = re.match(r"^(\d+)([kmg]?)$", raw)
    if not match:
        return DEFAULT_DOWNLOAD_SIZE
    val, unit = int(match.group(1)), match.group(2)
    multiplier = 1
    if unit == "k":
        multiplier = 1024
    elif unit == "m":
        multiplier = 1024 * 1024
    elif unit == "g":
        multiplier = 1024 * 1024 * 1024
    size = val * multiplier
    return min(max(size, 1024), MAX_DOWNLOAD_SIZE)


def format_mtr_json(json_str: str, target_ip: str, count: int) -> str:
    try:
        data = json.loads(json_str)
        report = data.get("report", {})
        mtr_meta = report.get("mtr", {})
        src = mtr_meta.get("src", "server")
        tests = mtr_meta.get("tests", count)
        hubs = report.get("hubs", [])
        if not hubs:
            return ""
        header = f"HOST: {src:<32} Loss%   Snt   Last    Avg   Best   Wrst  StDev\n"
        lines = [header]
        for hub in hubs:
            c = hub.get("count", 0)
            host = hub.get("host", "???")
            loss = hub.get("Loss%", 0.0)
            snt = hub.get("Snt", tests)
            last = hub.get("Last", 0.0)
            avg = hub.get("Avg", 0.0)
            best = hub.get("Best", 0.0)
            wrst = hub.get("Wrst", 0.0)
            stdev = hub.get("StDev", 0.0)
            prefix = f" {c:>2}.|-- {host:<30}"
            lines.append(f"{prefix} {loss:>5.1f}% {snt:>5} {last:>6.1f} {avg:>6.1f} {best:>6.1f} {wrst:>6.1f} {stdev:>6.1f}\n")
        return "".join(lines)
    except Exception as e:
        log.warning("Could not format MTR JSON: %s", e)
        return ""


def run_mtr(target_ip: str, count: int) -> dict:
    if not os.path.isfile(MTR_BIN):
        return {"success": False, "error": "mtr binary not installed (/usr/bin/mtr)", "output": ""}
    # Use --json mode to prevent buffer overflow crashes present in mtr 0.95 report mode under glibc fortify
    cmd = [
        MTR_BIN,
        "--json",
        "--no-dns",
        "--max-ttl", "30",
        "--report-cycles", str(count),
        "--",
        target_ip,
    ]
    log.info("Executing MTR: %s cycles -> %s", count, target_ip)
    proc = None
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            stdin=subprocess.DEVNULL,
            env={"PATH": "/usr/bin:/bin", "HOME": "/tmp", "LC_ALL": "C"},
        )
        with _subproc_lock:
            _active_subprocesses.add(proc)
        stdout, stderr = proc.communicate(timeout=MTR_TIMEOUT)
        if proc.returncode != 0:
            # Fallback to --raw mode if --json fails
            fallback_cmd = [
                MTR_BIN,
                "--raw",
                "--no-dns",
                "--max-ttl", "30",
                "--report-cycles", str(count),
                "--",
                target_ip,
            ]
            try:
                proc2 = subprocess.Popen(
                    fallback_cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    stdin=subprocess.DEVNULL,
                    env={"PATH": "/usr/bin:/bin", "HOME": "/tmp", "LC_ALL": "C"},
                )
                with _subproc_lock:
                    _active_subprocesses.add(proc2)
                f_stdout, f_stderr = proc2.communicate(timeout=MTR_TIMEOUT)
                if proc2.returncode == 0:
                    return {"success": True, "output": f_stdout or "", "error": ""}
            except Exception:
                pass
            return {"success": False, "error": f"mtr failed ({proc.returncode}): {stderr[:400]}", "output": stdout or ""}

        formatted_table = format_mtr_json(stdout, target_ip, count)
        output_text = formatted_table if formatted_table else stdout
        return {"success": True, "output": output_text, "error": ""}
    except subprocess.TimeoutExpired:
        if proc:
            try:
                proc.kill()
                proc.communicate()
            except Exception:
                pass
        return {"success": False, "error": "mtr execution timed out", "output": ""}
    except Exception as exc:
        log.error("mtr exception: %s", exc)
        return {"success": False, "error": str(exc), "output": ""}
    finally:
        if proc:
            with _subproc_lock:
                _active_subprocesses.discard(proc)


class DiagnosticsHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log.debug("http: " + fmt, *args)

    def _client_ip(self) -> str:
        # Strictly trust X-Real-IP passed by Nginx from proxy_protocol
        ip = self.headers.get("X-Real-IP", "").strip()
        if ip:
            return ip
        # Fallback to direct socket peer
        if isinstance(self.client_address, tuple):
            return self.client_address[0]
        return "127.0.0.1"

    def _send_json(self, code: int, body: dict) -> None:
        payload = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(payload)

    def _send_text(self, code: int, text: str) -> None:
        payload = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path in ("/health", "/healthz") or path.endswith("/health"):
            self._send_json(200, {"ok": True, "service": "vpn-diagnostics"})
            return

        if path in ("/api/st/getip", "/getip", "/api/st/getIP", "/getIP") or path.lower().endswith(("/api/st/getip", "/getip")):
            self._send_text(200, self._client_ip() + "\n")
            return

        # On-the-fly streaming download test (zero disk space consumed!)
        if (
            path in ("/api/st/down", "/down", "/api/st/download", "/download")
            or path.endswith(("/api/st/down", "/down", "/api/st/download", "/download"))
            or "/testfiles/" in path
        ):
            params = parse_qs(parsed.query)
            size_param = params.get("size", [""])[0]
            if not size_param and "test-" in path:
                m = re.search(r"test-([0-9]+[kmg]?)\.bin", path)
                if m:
                    size_param = m.group(1)

            total_bytes = parse_size_bytes(size_param)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(total_bytes))
            self.send_header("Content-Disposition", f'attachment; filename="test-{total_bytes}.bin"')
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()

            chunk = b"\x00" * DEFAULT_CHUNK_SIZE
            bytes_left = total_bytes
            try:
                while bytes_left > 0:
                    send_size = min(bytes_left, DEFAULT_CHUNK_SIZE)
                    if send_size == DEFAULT_CHUNK_SIZE:
                        self.wfile.write(chunk)
                    else:
                        self.wfile.write(chunk[:send_size])
                    bytes_left -= send_size
            except (BrokenPipeError, ConnectionResetError):
                pass
            return

        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        # Upload sink: read and discard payload up to 128MB (supporting Content-Length and Transfer-Encoding: chunked)
        if (
            path in ("/api/st/up", "/up", "/api/st/upload", "/upload")
            or path.endswith(("/api/st/up", "/up", "/api/st/upload", "/upload"))
        ):
            te = self.headers.get("Transfer-Encoding", "").lower()
            if "chunked" in te:
                received = 0
                max_bytes = 128 * 1024 * 1024
                try:
                    while received < max_bytes:
                        line = self.rfile.readline(64)
                        if not line:
                            break
                        chunk_sz = int(line.strip().split(b";")[0] or b"0", 16)
                        if chunk_sz == 0:
                            self.rfile.read(2)
                            break
                        to_read = min(chunk_sz, max_bytes - received)
                        self.rfile.read(to_read)
                        received += to_read
                        if to_read < chunk_sz:
                            self.rfile.read(chunk_sz - to_read)
                        self.rfile.read(2)
                except Exception:
                    pass
            else:
                try:
                    content_length = int(self.headers.get("Content-Length", "0"))
                except ValueError:
                    content_length = 0
                to_read = min(content_length, 128 * 1024 * 1024)
                received = 0
                buf_size = 512 * 1024
                while received < to_read:
                    chunk = self.rfile.read(min(buf_size, to_read - received))
                    if not chunk:
                        break
                    received += len(chunk)
            self._send_text(200, "")
            return

        # MTR Traceroute endpoint with concurrency and rate limits (T20)
        if path in ("/api/mtr", "/mtr") or path.endswith("/api/mtr"):
            raw_ip = self._client_ip()
            if not rate_check(raw_ip):
                self._send_json(429, {"error": "Rate limit exceeded. Please wait 60 seconds before running MTR again."})
                return

            try:
                target_ip = validate_ip(raw_ip)
            except ValueError as e:
                self._send_json(400, {"error": str(e)})
                return

            with _active_lock:
                if target_ip in _active_mtr_ips:
                    self._send_json(429, {"error": "An active MTR session is already running for this target."})
                    return
                _active_mtr_ips.add(target_ip)

            acquired = _mtr_semaphore.acquire(blocking=False)
            if not acquired:
                with _active_lock:
                    _active_mtr_ips.discard(target_ip)
                self._send_json(429, {"error": "Global MTR concurrency limit reached. Please try again shortly."})
                return

            try:
                content_length = int(self.headers.get("Content-Length", "0"))
                packet_count = DEFAULT_PACKET_COUNT
                if 0 < content_length < 1024:
                    body_raw = self.rfile.read(content_length).decode("utf-8", errors="replace")
                    try:
                        if self.headers.get("Content-Type", "").startswith("application/json"):
                            data = json.loads(body_raw)
                            packet_count = int(data.get("count", DEFAULT_PACKET_COUNT))
                        else:
                            params = parse_qs(body_raw)
                            packet_count = int(params.get("count", [str(DEFAULT_PACKET_COUNT)])[0])
                    except Exception:
                        packet_count = DEFAULT_PACKET_COUNT

                packet_count = max(MIN_PACKET_COUNT, min(packet_count, MAX_PACKET_COUNT))
                result = run_mtr(target_ip, packet_count)
                code = 200 if result["success"] else 500
                result["target"] = target_ip
                result["count"] = packet_count
                self._send_json(code, result)
                return
            finally:
                _mtr_semaphore.release()
                with _active_lock:
                    _active_mtr_ips.discard(target_ip)

        self._send_json(404, {"error": "not found"})


if hasattr(socketserver, "UnixStreamServer"):
    class UnixThreadingHTTPServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
        daemon_threads = True

        def server_bind(self):
            super().server_bind()
            self.server_name = "localhost"
            self.server_port = 80
else:
    UnixThreadingHTTPServer = None


def main():
    parser = argparse.ArgumentParser(description="VPN Diagnostics and MTR Backend")
    parser.add_argument("--socket", type=str, default="/run/vpn-diagnostics/mtr-backend.sock", help="Unix domain socket path")
    parser.add_argument("--port", type=int, default=0, help="Optional TCP port (127.0.0.1)")
    args = parser.parse_args()

    # Signal handlers to ensure active child processes are killed on stop
    def _cleanup_signal_handler(signum, frame):
        log.info("Shutdown signal received (%s), terminating active child processes...", signum)
        with _subproc_lock:
            for p in list(_active_subprocesses):
                try:
                    p.kill()
                except Exception:
                    pass
            _active_subprocesses.clear()
        sys.exit(0)

    try:
        signal.signal(signal.SIGTERM, _cleanup_signal_handler)
        signal.signal(signal.SIGINT, _cleanup_signal_handler)
    except Exception:
        pass

    if args.port > 0:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), DiagnosticsHandler)
        server.daemon_threads = True
        log.info("Diagnostics backend listening on TCP 127.0.0.1:%d", args.port)
    else:
        if UnixThreadingHTTPServer is None:
            sys.exit("Unix domain sockets are not supported on this platform. Use --port instead.")
        sock_path = args.socket
        sock_dir = os.path.dirname(sock_path)
        if sock_dir and not os.path.exists(sock_dir):
            os.makedirs(sock_dir, exist_ok=True)

        if os.path.exists(sock_path):
            try:
                os.unlink(sock_path)
            except OSError as e:
                log.warning("Could not unlink existing socket %s: %s", sock_path, e)
        server = UnixThreadingHTTPServer(sock_path, DiagnosticsHandler)
        try:
            # Grant rw access to reverse proxy (nginx / www-data)
            os.chmod(sock_path, 0o666)
            import grp
            for grp_name in ("nginx", "www-data"):
                try:
                    gid = grp.getgrnam(grp_name).gr_gid
                    os.chown(sock_path, -1, gid)
                    break
                except (KeyError, PermissionError):
                    continue
        except Exception as e:
            log.warning("Could not set socket permissions/ownership: %s", e)
        log.info("Diagnostics backend listening on Unix socket %s", sock_path)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        with _subproc_lock:
            for p in list(_active_subprocesses):
                try:
                    p.kill()
                except Exception:
                    pass
            _active_subprocesses.clear()
        if args.port == 0 and os.path.exists(args.socket):
            try:
                os.unlink(args.socket)
            except OSError:
                pass


if __name__ == "__main__":
    main()
